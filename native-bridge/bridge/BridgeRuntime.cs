using System.Net.WebSockets;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace WacomNativeBridge;

internal sealed class BridgeRuntime : IAsyncDisposable
{
    private readonly BridgeOptions _options;
    private readonly CancellationTokenSource _stop = new();
    private WacomNativeInputSource? _input;
    private WebSocketEventHub? _hub;
    private WebApplication? _app;
    private int _runStarted;

    public BridgeRuntime(BridgeOptions options)
    {
        _options = options;
    }

    public event Action? Stopped;

    public bool IsRunning { get; private set; }
    public string? StartupError { get; private set; }

    public BridgeStatus? GetStatus()
    {
        var input = _input;
        var hub = _hub;
        return input is null || hub is null ? null : BuildStatus(input, hub);
    }

    public void RequestStop()
    {
        if (!_stop.IsCancellationRequested)
        {
            _stop.Cancel();
        }
    }

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _runStarted, 1) != 0)
        {
            throw new InvalidOperationException("BridgeRuntime can only be run once.");
        }

        using var duration = _options.Duration is null
            ? null
            : new CancellationTokenSource(_options.Duration.Value);
        using var lifetime = duration is null
            ? CancellationTokenSource.CreateLinkedTokenSource(_stop.Token, cancellationToken)
            : CancellationTokenSource.CreateLinkedTokenSource(_stop.Token, cancellationToken, duration.Token);

        Task? pumpTask = null;
        var exitCode = 0;
        try
        {
            _input = new WacomNativeInputSource();
            _input.Start();
            _hub = new WebSocketEventHub();
            _app = BuildWebApplication(_input, _hub, lifetime.Token);
            pumpTask = _hub.PumpAsync(_input.Events, lifetime.Token);

            await _app.StartAsync(lifetime.Token);
            IsRunning = true;

            Console.WriteLine($"Wacom local bridge: {_options.Url}");
            Console.WriteLine($"Touch ready: {_input.TouchReady}, Pen ready: {_input.PenReady}");
            Console.WriteLine($"WebSocket: {_options.Url.Replace("http://", "ws://")}/ws");

            await _app.WaitForShutdownAsync(lifetime.Token);
            exitCode = _input.TouchReady && _input.PenReady ? 0 : 2;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            exitCode = _input is { TouchReady: true, PenReady: true } ? 0 : 2;
        }
        catch (IOException exception)
        {
            StartupError = $"Local server startup failed for {_options.Url}: {exception.Message}";
            Console.Error.WriteLine(StartupError);
            exitCode = 3;
        }
        catch (Exception exception)
        {
            StartupError = $"Bridge startup failed: {exception.Message}";
            Console.Error.WriteLine(StartupError);
            exitCode = 2;
        }
        finally
        {
            IsRunning = false;
            lifetime.Cancel();

            if (_app is not null)
            {
                try
                {
                    using var stopTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    await _app.StopAsync(stopTimeout.Token);
                }
                catch (OperationCanceledException)
                {
                    Console.Error.WriteLine("Timed out while stopping the local server.");
                }
                catch (Exception exception)
                {
                    Console.Error.WriteLine($"Local server stop failed: {exception.Message}");
                }

                try
                {
                    await _app.DisposeAsync();
                }
                catch (Exception exception)
                {
                    Console.Error.WriteLine($"Local server dispose failed: {exception.Message}");
                }
            }

            if (_input is not null && _hub is not null)
            {
                var status = BuildStatus(_input, _hub);
                Console.WriteLine(
                    $"SUMMARY produced={status.Native.ProducedEvents} " +
                    $"touchFrames={status.Native.TouchFrames} penPackets={status.Native.PenPackets} " +
                    $"proximity={status.Native.ProximityMessages} inputDropped={status.Native.DroppedInputEvents} " +
                    $"overlap={status.Native.WintabOverlapMessages} " +
                    $"promote={status.Native.WintabPromotionSuccesses}/{status.Native.WintabPromotionAttempts} " +
                    $"broadcast={status.BroadcastEvents} clientDropped={status.DroppedClientMessages}");
            }

            try
            {
                _input?.Dispose();
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine($"Native input cleanup failed: {exception.Message}");
            }
            if (pumpTask is not null)
            {
                try
                {
                    await pumpTask;
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
                {
                }
                catch (Exception exception)
                {
                    Console.Error.WriteLine($"WebSocket event pump stopped with an error: {exception.Message}");
                }
            }

            try
            {
                Stopped?.Invoke();
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine($"Stopped handler failed: {exception.Message}");
            }
        }

        return exitCode;
    }

    private WebApplication BuildWebApplication(
        WacomNativeInputSource input,
        WebSocketEventHub hub,
        CancellationToken runtimeCancellation)
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = [],
            ApplicationName = typeof(Program).Assembly.FullName
        });
        builder.WebHost.UseUrls(_options.Url);
        builder.Logging.ClearProviders();
        builder.Logging.AddSimpleConsole(console => console.SingleLine = true);

        var app = builder.Build();
        var originPolicy = new OriginPolicy(_options.AllowedOrigins);
        app.Use(async (context, next) =>
        {
            var origin = context.Request.Headers["Origin"].ToString();
            if (!originPolicy.IsAllowed(origin))
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                await context.Response.WriteAsync("Origin not allowed");
                return;
            }

            if (!string.IsNullOrEmpty(origin))
            {
                context.Response.Headers["Access-Control-Allow-Origin"] = origin;
                context.Response.Headers["Vary"] = "Origin";
                if (HttpMethods.IsOptions(context.Request.Method))
                {
                    context.Response.Headers["Access-Control-Allow-Methods"] = "GET";
                    context.Response.StatusCode = StatusCodes.Status204NoContent;
                    return;
                }
            }

            await next(context);
        });
        app.UseWebSockets(new WebSocketOptions
        {
            KeepAliveInterval = TimeSpan.FromSeconds(15)
        });

        app.MapGet("/", () => Results.Json(new
        {
            name = "Wacom Native Input Bridge",
            protocolVersion = 1,
            health = "/health",
            status = "/api/status",
            webSocket = "/ws"
        }));
        app.MapGet("/api/status", () => Results.Json(BuildStatus(input, hub)));
        app.MapGet("/health", () => Results.Json(new
        {
            ok = input.TouchReady && input.PenReady,
            touchReady = input.TouchReady,
            penReady = input.PenReady
        }));

        app.Map("/ws", async context =>
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            using var connectionLifetime = CancellationTokenSource.CreateLinkedTokenSource(
                context.RequestAborted,
                runtimeCancellation);
            await hub.HandleClientAsync(
                socket,
                () => new
                {
                    type = "bridge.hello",
                    protocolVersion = 1,
                    status = BuildStatus(input, hub)
                },
                (clientId, message) => HandleClientMessage(input, clientId, message),
                input.RemoveBrowserClient,
                connectionLifetime.Token);
        });
        return app;
    }

    private static void HandleClientMessage(
        WacomNativeInputSource input,
        Guid clientId,
        string message)
    {
        try
        {
            using var json = System.Text.Json.JsonDocument.Parse(message);
            if (!json.RootElement.TryGetProperty("type", out var type))
            {
                return;
            }

            var generation = json.RootElement.TryGetProperty("generation", out var generationElement)
                ? generationElement.GetInt64()
                : 0;
            if (type.GetString() == "bridge.activate")
            {
                input.SetBrowserClientActive(clientId, generation, true);
            }
            else if (type.GetString() == "bridge.deactivate")
            {
                input.SetBrowserClientActive(clientId, generation, false);
            }
        }
        catch (System.Text.Json.JsonException)
        {
        }
    }

    private BridgeStatus BuildStatus(WacomNativeInputSource input, WebSocketEventHub hub)
    {
        return new BridgeStatus(
            1,
            _options.Url,
            input.GetStatus(),
            hub.ClientCount,
            hub.BroadcastEvents,
            hub.DroppedClientMessages);
    }

    public ValueTask DisposeAsync()
    {
        RequestStop();
        _stop.Dispose();
        return ValueTask.CompletedTask;
    }
}
