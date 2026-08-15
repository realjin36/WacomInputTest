namespace WacomLocalBridge;

internal sealed record NativeInputEvent(
    long Sequence,
    long TimestampUs,
    string Source,
    string Type,
    int DeviceId,
    TouchFrameData? Touch = null,
    PenPacketData? Pen = null,
    PenProximityData? Proximity = null);

internal sealed record TouchFrameData(
    uint FrameNumber,
    TouchContactData[] Contacts);

internal sealed record TouchContactData(
    int Id,
    string State,
    float X,
    float Y,
    float Width,
    float Height,
    ushort Sensitivity,
    float Orientation,
    bool Confidence);

internal sealed record PenPacketData(
    uint Serial,
    uint Cursor,
    int X,
    int Y,
    int Z,
    uint Pressure,
    uint TangentialPressure,
    uint Buttons,
    int Azimuth,
    int Altitude,
    int Twist,
    uint Status,
    uint Changed);

internal sealed record PenProximityData(
    bool Hardware,
    bool Context);

internal sealed record TouchDeviceInfo(
    int DeviceId,
    string Type,
    float LogicalOriginX,
    float LogicalOriginY,
    float LogicalWidth,
    float LogicalHeight,
    float PhysicalSizeX,
    float PhysicalSizeY,
    uint FingerMax,
    uint ScanSizeX,
    uint ScanSizeY,
    bool RawAvailable,
    bool BlobAvailable,
    bool SensitivityAvailable);

internal sealed record NativeInputStatus(
    string Platform,
    bool TouchReady,
    bool PenReady,
    IReadOnlyList<TouchDeviceInfo> TouchDevices,
    uint WintabDeviceCount,
    string? WintabDeviceInfo,
    int WintabMaxPressure,
    bool WintabTiltSupported,
    WintabAxisInfo? WintabX,
    WintabAxisInfo? WintabY,
    int WintabContextStatus,
    bool PenHardwareProximity,
    bool PenContextProximity,
    long WintabOverlapMessages,
    long WintabPromotionAttempts,
    long WintabPromotionSuccesses,
    long WintabClientActivations,
    long WintabClientDeactivations,
    long WintabActivationPromotionRuns,
    long WintabPromotionSkips,
    int ActiveBrowserClients,
    long ProducedEvents,
    long DroppedInputEvents,
    long TouchFrames,
    long PenPackets,
    long ProximityMessages);

internal sealed record WintabAxisInfo(int Min, int Max);
