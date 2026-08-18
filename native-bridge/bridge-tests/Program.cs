using System.Net.WebSockets;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using WacomLocalBridge;

namespace WacomLocalBridge.Tests;

internal static class Program
{
    private static readonly List<(string Name, Func<Task> Run)> Tests =
    [
        ("BridgeOptions defaults", TestBridgeOptionsDefaults),
        ("BridgeOptions flags and URL normalization", TestBridgeOptionsFlags),
        ("BridgeOptions rejects unsafe or incomplete arguments", TestBridgeOptionsRejectsInvalidArguments),
        ("Protocol JSON uses web-compatible camelCase fields", TestProtocolSerialization),
        ("Product assembly contains all embedded web assets", TestEmbeddedWebAssets),
        ("WebSocket hub sends hello and input events", TestWebSocketHubBroadcast),
        ("WebSocket hub counts slow-client drops", TestWebSocketHubDropAccounting)
    ];

    private static async Task<int> Main()
    {
        var failures = 0;
        foreach (var (name, run) in Tests)
        {
            try
            {
                await run();
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
            }
        }

        Console.WriteLine($"windows-native-tests={Tests.Count - failures}/{Tests.Count}");
        return failures == 0 ? 0 : 1;
    }

    private static Task TestBridgeOptionsDefaults()
    {
        var options = BridgeOptions.Parse([]);
        Equal("http://127.0.0.1:8765", options.Url);
        Equal(null, options.WebRoot);
        Equal(null, options.Duration);
        True(options.OpenBrowser);
        True(options.ShowWindow);
        return Task.CompletedTask;
    }

    private static Task TestBridgeOptionsFlags()
    {
        var relativeWebRoot = Path.Combine("fixtures", "web");
        var options = BridgeOptions.Parse(
        [
            "--url", "http://localhost:9876/",
            "--web-root", relativeWebRoot,
            "--duration", "1.5",
            "--no-browser",
            "--no-window"
        ]);

        Equal("http://localhost:9876", options.Url);
        Equal(Path.GetFullPath(relativeWebRoot), options.WebRoot);
        Equal(TimeSpan.FromSeconds(1.5), options.Duration);
        False(options.OpenBrowser);
        False(options.ShowWindow);
        return Task.CompletedTask;
    }

    private static Task TestBridgeOptionsRejectsInvalidArguments()
    {
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--unknown"]));
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--url"]));
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--duration", "0"]));
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--url", "https://127.0.0.1:8765"]));
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--url", "http://0.0.0.0:8765"]));
        Throws<ArgumentException>(() => BridgeOptions.Parse(["--url", "http://example.com:8765"]));
        return Task.CompletedTask;
    }

    private static Task TestProtocolSerialization()
    {
        var inputEvent = new NativeInputEvent(
            42,
            1_700_000_000_000_000,
            "wintab",
            "pen.packet",
            7,
            Pen: new PenPacketData(1, 2, 3, 4, 5, 6, 7, 8, 900, 600, 120, 9, 10));
        var json = JsonSerializer.Serialize(inputEvent, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        Equal(42L, root.GetProperty("sequence").GetInt64());
        Equal("pen.packet", root.GetProperty("type").GetString());
        Equal(7, root.GetProperty("deviceId").GetInt32());
        Equal(900, root.GetProperty("pen").GetProperty("azimuth").GetInt32());
        True(root.TryGetProperty("touch", out var touch) && touch.ValueKind == JsonValueKind.Null);
        return Task.CompletedTask;
    }

    private static Task TestEmbeddedWebAssets()
    {
        var resources = typeof(BridgeOptions).Assembly.GetManifestResourceNames().ToHashSet(StringComparer.Ordinal);
        True(resources.Contains("WacomLocalBridge.Web.index.html"));
        True(resources.Contains("WacomLocalBridge.Web.app.js"));
        True(resources.Contains("WacomLocalBridge.Web.styles.css"));
        return Task.CompletedTask;
    }

    private static async Task TestWebSocketHubBroadcast()
    {
        var hub = new WebSocketEventHub();
        using var socket = new RecordingWebSocket();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var disconnected = false;
        var clientTask = hub.HandleClientAsync(
            socket,
            () => new { type = "bridge.hello", protocolVersion = 1 },
            (_, _) => { },
            _ => disconnected = true,
            cancellation.Token);

        await WaitUntilAsync(() => hub.ClientCount == 1 && socket.SentCount >= 1, cancellation.Token);

        var channel = Channel.CreateUnbounded<NativeInputEvent>();
        await channel.Writer.WriteAsync(new NativeInputEvent(1, 2, "wacommt", "touch.frame", 3,
            Touch: new TouchFrameData(4, [])), cancellation.Token);
        channel.Writer.Complete();
        await hub.PumpAsync(channel.Reader, cancellation.Token);
        await WaitUntilAsync(() => socket.SentCount >= 2, cancellation.Token);

        using var hello = JsonDocument.Parse(socket.Sent[0]);
        using var input = JsonDocument.Parse(socket.Sent[1]);
        Equal("bridge.hello", hello.RootElement.GetProperty("type").GetString());
        Equal("touch.frame", input.RootElement.GetProperty("type").GetString());
        Equal(1L, hub.BroadcastEvents);

        cancellation.Cancel();
        await clientTask;
        Equal(0, hub.ClientCount);
        True(disconnected);
    }

    private static async Task TestWebSocketHubDropAccounting()
    {
        var hub = new WebSocketEventHub();
        using var socket = new RecordingWebSocket(blockSends: true);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var clientTask = hub.HandleClientAsync(
            socket,
            () => new { type = "bridge.hello", protocolVersion = 1 },
            (_, _) => { },
            _ => { },
            cancellation.Token);

        await WaitUntilAsync(() => hub.ClientCount == 1, cancellation.Token);
        var channel = Channel.CreateUnbounded<NativeInputEvent>();
        for (var index = 0; index < 1_100; index++)
        {
            channel.Writer.TryWrite(new NativeInputEvent(index, index, "test", "pen.packet", 1));
        }
        channel.Writer.Complete();
        await hub.PumpAsync(channel.Reader, cancellation.Token);

        Equal(1_100L, hub.BroadcastEvents);
        True(hub.DroppedClientMessages > 0, "Expected the bounded client queue to report dropped messages.");
        cancellation.Cancel();
        await clientTask;
    }

    private static async Task WaitUntilAsync(Func<bool> condition, CancellationToken cancellationToken)
    {
        while (!condition())
        {
            await Task.Delay(10, cancellationToken);
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void True(bool condition, string? message = null)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message ?? "Expected condition to be true.");
        }
    }

    private static void False(bool condition) => True(!condition, "Expected condition to be false.");

    private static void Throws<TException>(Action action) where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private sealed class RecordingWebSocket(bool blockSends = false) : WebSocket
    {
        private readonly List<string> _sent = [];
        private readonly TaskCompletionSource _sendGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private WebSocketState _state = WebSocketState.Open;

        public IReadOnlyList<string> Sent
        {
            get
            {
                lock (_sent)
                {
                    return _sent.ToArray();
                }
            }
        }

        public int SentCount
        {
            get
            {
                lock (_sent)
                {
                    return _sent.Count;
                }
            }
        }

        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override WebSocketState State => _state;
        public override string? SubProtocol => null;

        public override void Abort()
        {
            _state = WebSocketState.Aborted;
            _sendGate.TrySetCanceled();
        }

        public override Task CloseAsync(
            WebSocketCloseStatus closeStatus,
            string? statusDescription,
            CancellationToken cancellationToken)
        {
            _state = WebSocketState.Closed;
            _sendGate.TrySetCanceled(cancellationToken);
            return Task.CompletedTask;
        }

        public override Task CloseOutputAsync(
            WebSocketCloseStatus closeStatus,
            string? statusDescription,
            CancellationToken cancellationToken)
        {
            _state = WebSocketState.Closed;
            _sendGate.TrySetCanceled(cancellationToken);
            return Task.CompletedTask;
        }

        public override void Dispose()
        {
            _state = WebSocketState.Closed;
            _sendGate.TrySetCanceled();
        }

        public override async Task<WebSocketReceiveResult> ReceiveAsync(
            ArraySegment<byte> buffer,
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("Unreachable");
        }

        public override async Task SendAsync(
            ArraySegment<byte> buffer,
            WebSocketMessageType messageType,
            bool endOfMessage,
            CancellationToken cancellationToken)
        {
            if (blockSends)
            {
                await _sendGate.Task.WaitAsync(cancellationToken);
            }

            lock (_sent)
            {
                _sent.Add(Encoding.UTF8.GetString(buffer.Array!, buffer.Offset, buffer.Count));
            }
        }
    }
}
