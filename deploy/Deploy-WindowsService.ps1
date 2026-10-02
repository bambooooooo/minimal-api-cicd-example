[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $true)]
    [string]$DeployRoot,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedCommit,

    [Parameter(Mandatory = $true)]
    [string]$HealthUrl,

    [int]$HealthTimeoutSeconds = 60,

    [int]$KeepReleases = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Deployment must run elevated (Administrator).'
    }
}

function Wait-ServiceState {
    param(
        [string]$Name,
        [System.ServiceProcess.ServiceControllerStatus]$DesiredState,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -eq $DesiredState) {
            return
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    $service = Get-Service -Name $Name -ErrorAction Stop
    throw "Service '$Name' did not reach state '$DesiredState'. Current state: '$($service.Status)'."
}

function Wait-HttpHealthy {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                return
            }
            $lastError = "HTTP $($response.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Health check failed for '$Url'. Last error: $lastError"
}

Assert-Administrator

$releasesRoot = Join-Path $DeployRoot 'releases'
$currentPath = Join-Path $DeployRoot 'current'
$backupPath = Join-Path $DeployRoot 'rollback'
$tmpRoot = Join-Path $DeployRoot 'staging'

New-Item -ItemType Directory -Force -Path $DeployRoot, $releasesRoot, $tmpRoot | Out-Null

$package = Get-ChildItem $ArtifactDirectory -Filter '*.zip' -File | Select-Object -First 1
if ($null -eq $package) {
    throw "Deployment package not found in '$ArtifactDirectory'."
}

$manifestPath = Join-Path $ArtifactDirectory 'manifest.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ($manifest.commit -ne $ExpectedCommit) {
    throw "Manifest commit mismatch. Expected '$ExpectedCommit', got '$($manifest.commit)'."
}

$version = $ExpectedCommit.Substring(0, 12)
$releasePath = Join-Path $releasesRoot $version
$stagingPath = Join-Path $tmpRoot $version

if (Test-Path $stagingPath) {
    Remove-Item -Recurse -Force $stagingPath
}
New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null

if (Test-Path $releasePath) {
    Write-Host "Release '$version' already exists. Reusing it after validation."
}
else {
    Write-Host "Extracting release '$version'."
    Expand-Archive -Path $package.FullName -DestinationPath $stagingPath -Force
    Move-Item -Path $stagingPath -Destination $releasePath
}

$exePath = Join-Path $releasePath 'MyComApi.exe'
if (-not (Test-Path $exePath)) {
    throw "Expected service executable not found: $exePath"
}

$service = Get-Service -Name $ServiceName -ErrorAction Stop
$previousTarget = $null
$currentItem = Get-Item $currentPath -Force -ErrorAction SilentlyContinue
if ($null -ne $currentItem) {
    $previousTarget = $currentItem.Target | Select-Object -First 1
}

Write-Host "Stopping service '$ServiceName'."
if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    Stop-Service -Name $ServiceName -Force
    Wait-ServiceState -Name $ServiceName -DesiredState Stopped
}

try {
    if (Test-Path $backupPath) {
        Remove-Item -Recurse -Force $backupPath
    }

    if (Test-Path $currentPath) {
        Write-Host "Backing up current release pointer."
        New-Item -ItemType Junction -Path $backupPath -Target $previousTarget | Out-Null
        Remove-Item -LiteralPath $currentPath -Force
    }

    New-Item -ItemType Junction -Path $currentPath -Target $releasePath | Out-Null
    if (-not (Test-Path -LiteralPath $currentPath)) {
        throw "Could not activate current release junction."
    }

    # Verify the service points to the stable 'current' path.
    $serviceCim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    if ($serviceCim.PathName -notmatch [regex]::Escape((Join-Path $currentPath 'MyComApi.exe'))) {
        throw "Windows service '$ServiceName' does not point to '$currentPath\MyComApi.exe'."
    }

    Write-Host "Starting service '$ServiceName'."
    Start-Service -Name $ServiceName
    Wait-ServiceState -Name $ServiceName -DesiredState Running

    Write-Host "Waiting for application health endpoint: $HealthUrl"
    Wait-HttpHealthy -Url $HealthUrl -TimeoutSeconds $HealthTimeoutSeconds

    Write-Host "Deployment succeeded: $ExpectedCommit"
}
catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"

    Write-Warning 'Attempting rollback.'

    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Wait-ServiceState -Name $ServiceName -DesiredState Stopped -TimeoutSeconds 30
        }

        if (Test-Path $currentPath) {
            Remove-Item -Force $currentPath
        }

        if ($previousTarget -and (Test-Path $previousTarget)) {
            New-Item -ItemType Junction -Path $currentPath -Target $previousTarget | Out-Null
            Write-Host "Restored previous release: $previousTarget"
        }
        elseif (Test-Path $backupPath) {
            # Fallback when Item.Target is unavailable on the current PowerShell/FS combination.
            $rollbackTarget = (Get-Item $backupPath -Force).Target | Select-Object -First 1
            if (-not $rollbackTarget) {
                throw 'Rollback junction has no target.'
            }
            New-Item -ItemType Junction -Path $currentPath -Target $rollbackTarget | Out-Null
            Write-Host "Restored previous release: $rollbackTarget"
        }
        else {
            Write-Warning 'No previous release pointer is available.'
        }

        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Wait-ServiceState -Name $ServiceName -DesiredState Running -TimeoutSeconds 30
        Wait-HttpHealthy -Url $HealthUrl -TimeoutSeconds 30
        Write-Host 'Rollback completed successfully.'
    }
    catch {
        Write-Error "Rollback failed: $($_.Exception.Message)"
    }

    throw
}
finally {
    # Keep the currently active release plus the configured number of newest older releases.
    $activeTarget = $null
    $currentItem = Get-Item $currentPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $currentItem) {
        $activeTarget = $currentItem.Target | Select-Object -First 1
    }

    $releases = Get-ChildItem $releasesRoot -Directory | Sort-Object LastWriteTime -Descending
    $keep = $releases | Select-Object -First ($KeepReleases + 1)

    foreach ($old in $releases | Where-Object { $_.FullName -notin $keep.FullName }) {
        if ($activeTarget -and ($old.FullName -eq $activeTarget)) {
            continue
        }
        Remove-Item -Recurse -Force $old.FullName -ErrorAction SilentlyContinue
    }

    if (Test-Path $backupPath) {
        Remove-Item -Recurse -Force $backupPath -ErrorAction SilentlyContinue
    }

    if (Test-Path $stagingPath) {
        Remove-Item -Recurse -Force $stagingPath -ErrorAction SilentlyContinue
    }
}
