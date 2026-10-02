using Microsoft.Extensions.Hosting.WindowsServices;
using System.Net;

var options = new WebApplicationOptions
{
    Args = args,
    // Setting to allow the service to run both in IDE and as service
    ContentRootPath = WindowsServiceHelpers.IsWindowsService()
        ? AppContext.BaseDirectory
        : default
};
var builder = WebApplication.CreateBuilder(options);
builder.Host.UseWindowsService();

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

app.MapGet("/", () => "Hello from .NET");

app.MapGet("/health", () => "Ok.");

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

var localIp = Dns.GetHostEntry(Dns.GetHostName()).AddressList.FirstOrDefault(ip => ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
    && (ip.ToString().StartsWith("192.") || (ip.ToString().StartsWith("10."))));

string port = builder.Configuration["port"] ?? "5000";

app.Urls.Add($"http://{localIp}:{port}");
app.Urls.Add($"http://localhost:{port}");

app.Run();