namespace WacomNativeBridge;

internal sealed record BridgeStatus(
    int ProtocolVersion,
    string Url,
    NativeInputStatus Native,
    int WebSocketClients,
    long BroadcastEvents,
    long DroppedClientMessages);
