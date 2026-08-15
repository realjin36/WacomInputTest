using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text;
using System.Threading.Channels;

namespace WacomLocalBridge;

internal sealed class WebSocketEventHub
{
    private const int ClientBufferCapacity = 1_024;
    private readonly ConcurrentDictionary<Guid, ClientSession> _clients = new();
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web);
    private long _broadcastEvents;
    private long _droppedClientMessages;

    public int ClientCount => _clients.Count;
    public long BroadcastEvents => Interlocked.Read(ref _broadcastEvents);
    public long DroppedClientMessages => Interlocked.Read(ref _droppedClientMessages);

    public async Task PumpAsync(ChannelReader<NativeInputEvent> reader, CancellationToken cancellationToken)
    {
        await foreach (var inputEvent in reader.ReadAllAsync(cancellationToken))
        {
            var payload = JsonSerializer.SerializeToUtf8Bytes(inputEvent, _jsonOptions);
            Interlocked.Increment(ref _broadcastEvents);
            foreach (var client in _clients.Values)
            {
                client.Enqueue(payload);
            }
        }
    }

    public async Task HandleClientAsync(
        WebSocket socket,
        Func<object> helloFactory,
        Action<Guid, string> onClientMessage,
        Action<Guid> onClientDisconnected,
        CancellationToken requestAborted)
    {
        var id = Guid.NewGuid();
        var session = new ClientSession(
            socket,
            ClientBufferCapacity,
            () => Interlocked.Increment(ref _droppedClientMessages));
        session.Enqueue(JsonSerializer.SerializeToUtf8Bytes(helloFactory(), _jsonOptions));
        _clients[id] = session;

        try
        {
            var sendTask = session.SendLoopAsync(requestAborted);
            var receiveTask = ReceiveUntilClosedAsync(socket, message => onClientMessage(id, message), requestAborted);
            await Task.WhenAny(sendTask, receiveTask);
        }
        finally
        {
            _clients.TryRemove(id, out _);
            onClientDisconnected(id);
            session.Complete();
            if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
            {
                try
                {
                    await socket.CloseAsync(
                        WebSocketCloseStatus.NormalClosure,
                        "bridge closing",
                        CancellationToken.None);
                }
                catch (WebSocketException)
                {
                }
            }

            socket.Dispose();
        }
    }

    private static async Task ReceiveUntilClosedAsync(
        WebSocket socket,
        Action<string> onClientMessage,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[512];
        using var message = new MemoryStream();
        while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
        {
            var result = await socket.ReceiveAsync(buffer, cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return;
            }

            if (result.MessageType != WebSocketMessageType.Text)
            {
                continue;
            }

            message.Write(buffer, 0, result.Count);
            if (message.Length > 4096)
            {
                return;
            }

            if (result.EndOfMessage)
            {
                onClientMessage(Encoding.UTF8.GetString(message.GetBuffer(), 0, checked((int)message.Length)));
                message.SetLength(0);
            }
        }
    }

    private sealed class ClientSession
    {
        private readonly WebSocket _socket;
        private readonly Channel<byte[]> _outgoing;

        public ClientSession(WebSocket socket, int capacity, Action onDropped)
        {
            _socket = socket;
            _outgoing = Channel.CreateBounded<byte[]>(
                new BoundedChannelOptions(capacity)
                {
                    FullMode = BoundedChannelFullMode.DropOldest,
                    SingleReader = true,
                    SingleWriter = false,
                    AllowSynchronousContinuations = false
                },
                _ => onDropped());
        }

        public void Enqueue(byte[] payload) => _outgoing.Writer.TryWrite(payload);
        public void Complete() => _outgoing.Writer.TryComplete();

        public async Task SendLoopAsync(CancellationToken cancellationToken)
        {
            await foreach (var payload in _outgoing.Reader.ReadAllAsync(cancellationToken))
            {
                if (_socket.State != WebSocketState.Open)
                {
                    return;
                }

                await _socket.SendAsync(
                    payload,
                    WebSocketMessageType.Text,
                    endOfMessage: true,
                    cancellationToken);
            }
        }
    }
}
