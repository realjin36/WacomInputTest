using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using WacomMTDN;
using WintabDN;

namespace WacomLocalBridge;

internal sealed class WacomNativeInputSource : IDisposable
{
    private const int InputBufferCapacity = 16_384;
    private readonly Channel<NativeInputEvent> _events;
    private readonly object _publishLock = new();
    private readonly object _wintabStateLock = new();
    private readonly object _clientStateLock = new();
    private readonly Dictionary<Guid, long> _activeBrowserClients = [];
    private readonly Dictionary<Guid, CancellationTokenSource> _clientPromotionCancellations = [];
    private readonly List<TouchRegistration> _touchRegistrations = [];
    private readonly List<TouchDeviceInfo> _touchDevices = [];
    private readonly WacomMTCallback _touchCallback;
    private readonly long _startTimestamp = Stopwatch.GetTimestamp();
    private readonly long _startUnixUs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000;
    private bool _wacomMtInitialized;
    private CWintabContext? _wintabContext;
    private CWintabData? _wintabData;
    private Thread? _wintabPollingThread;
    private uint _wintabDeviceCount;
    private string? _wintabDeviceInfo;
    private int _wintabMaxPressure;
    private bool _wintabTiltSupported;
    private WintabAxisInfo? _wintabX;
    private WintabAxisInfo? _wintabY;
    private int _wintabContextStatus;
    private bool _penHardwareProximity;
    private bool _penContextProximity;
    private long _wintabOverlapMessages;
    private long _wintabPromotionAttempts;
    private long _wintabPromotionSuccesses;
    private long _wintabClientActivations;
    private long _wintabClientDeactivations;
    private long _wintabActivationPromotionRuns;
    private long _wintabPromotionSkips;
    private int _overlapPromotionGeneration;
    private long _lastPromotionTimestamp;
    private long _promotionBurstStarted;
    private int _promotionBurstCount;
    private long _sequence;
    private long _droppedInputEvents;
    private long _touchFrames;
    private long _penPackets;
    private long _proximityMessages;
    private bool _disposed;

    public WacomNativeInputSource()
    {
        _touchCallback = OnTouchPacket;
        _events = Channel.CreateBounded<NativeInputEvent>(
            new BoundedChannelOptions(InputBufferCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = false,
                AllowSynchronousContinuations = false
            },
            _ => Interlocked.Increment(ref _droppedInputEvents));
    }

    public ChannelReader<NativeInputEvent> Events => _events.Reader;
    public bool TouchReady { get; private set; }
    public bool PenReady { get; private set; }

    public void Start()
    {
        StartWacomMt();
        StartWintab();
    }

    public NativeInputStatus GetStatus()
    {
        return new NativeInputStatus(
            TouchReady,
            PenReady,
            _touchDevices.ToArray(),
            _wintabDeviceCount,
            _wintabDeviceInfo,
            _wintabMaxPressure,
            _wintabTiltSupported,
            _wintabX,
            _wintabY,
            Volatile.Read(ref _wintabContextStatus),
            Volatile.Read(ref _penHardwareProximity),
            Volatile.Read(ref _penContextProximity),
            Interlocked.Read(ref _wintabOverlapMessages),
            Interlocked.Read(ref _wintabPromotionAttempts),
            Interlocked.Read(ref _wintabPromotionSuccesses),
            Interlocked.Read(ref _wintabClientActivations),
            Interlocked.Read(ref _wintabClientDeactivations),
            Interlocked.Read(ref _wintabActivationPromotionRuns),
            Interlocked.Read(ref _wintabPromotionSkips),
            GetActiveBrowserClientCount(),
            Interlocked.Read(ref _sequence),
            Interlocked.Read(ref _droppedInputEvents),
            Interlocked.Read(ref _touchFrames),
            Interlocked.Read(ref _penPackets),
            Interlocked.Read(ref _proximityMessages));
    }

    private void StartWacomMt()
    {
        var result = CWacomMTInterface.WacomMTInitialize(WacomMTConstants.WACOM_MULTI_TOUCH_API_VERSION);
        if (result != WacomMTError.WMTErrorSuccess)
        {
            throw new InvalidOperationException($"WacomMTInitialize failed: {result}");
        }

        _wacomMtInitialized = true;
        var deviceCount = CWacomMTInterface.WacomMTGetAttachedDeviceIDs(IntPtr.Zero, 0);
        if (deviceCount <= 0)
        {
            return;
        }

        var idsBuffer = Marshal.AllocHGlobal(deviceCount * sizeof(int));
        try
        {
            var reportedCount = CWacomMTInterface.WacomMTGetAttachedDeviceIDs(
                idsBuffer, deviceCount * sizeof(int));
            var readableCount = Math.Min(deviceCount, reportedCount);

            for (var index = 0; index < readableCount; index++)
            {
                RegisterTouchDevice(Marshal.ReadInt32(idsBuffer, index * sizeof(int)));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(idsBuffer);
        }

        TouchReady = _touchRegistrations.Count > 0;
    }

    private void RegisterTouchDevice(int deviceId)
    {
        var capsBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<WacomMTCapability>());
        try
        {
            Marshal.StructureToPtr(new WacomMTCapability(), capsBuffer, false);
            var result = CWacomMTInterface.WacomMTGetDeviceCapabilities(deviceId, capsBuffer);
            if (result != WacomMTError.WMTErrorSuccess)
            {
                throw new InvalidOperationException($"WacomMTGetDeviceCapabilities({deviceId}) failed: {result}");
            }

            var caps = Marshal.PtrToStructure<WacomMTCapability>(capsBuffer);
            var flags = caps.CapabilityFlags;
            _touchDevices.Add(new TouchDeviceInfo(
                caps.DeviceID,
                caps.Type.ToString(),
                caps.LogicalOriginX,
                caps.LogicalOriginY,
                caps.LogicalWidth,
                caps.LogicalHeight,
                caps.PhysicalSizeX,
                caps.PhysicalSizeY,
                caps.FingerMax,
                caps.ScanSizeX,
                caps.ScanSizeY,
                (flags & WacomMTCapabilityFlags.WMTCapabilityFlagsRawAvailable) != 0,
                (flags & WacomMTCapabilityFlags.WMTCapabilityFlagsBlobAvailable) != 0,
                (flags & WacomMTCapabilityFlags.WMTCapabilityFlagsSensitivityAvailable) != 0));

            var hitRect = new WacomMTHitRect(
                caps.LogicalOriginX,
                caps.LogicalOriginY,
                caps.LogicalWidth,
                caps.LogicalHeight);
            var mode = WacomMTProcessingMode.WMTProcessingModeObserver;
            result = CWacomMTInterface.WacomMTRegisterFingerReadCallback(
                deviceId, ref hitRect, mode, _touchCallback, IntPtr.Zero);
            if (result != WacomMTError.WMTErrorSuccess)
            {
                throw new InvalidOperationException($"WacomMT observer registration failed: {result}");
            }

            _touchRegistrations.Add(new TouchRegistration(deviceId, hitRect, mode));
        }
        finally
        {
            Marshal.FreeHGlobal(capsBuffer);
        }
    }

    private uint OnTouchPacket(IntPtr packetPointer, IntPtr userData)
    {
        try
        {
            var collection = Marshal.PtrToStructure<WacomMTFingerCollection>(packetPointer);
            var contacts = new TouchContactData[collection.FingerCount];
            for (uint index = 0; index < collection.FingerCount; index++)
            {
                var finger = collection.GetFingerByIndex(index);
                contacts[index] = new TouchContactData(
                    finger.FingerID,
                    finger.TouchState.ToString(),
                    finger.X,
                    finger.Y,
                    finger.Width,
                    finger.Height,
                    finger.Sensitivity,
                    finger.Orientation,
                    finger.Confidence);
            }

            Interlocked.Increment(ref _touchFrames);
            Publish(new NativeInputEvent(
                0,
                TimestampUs(),
                "wacommt",
                "touch.frame",
                unchecked((int)collection.DeviceID),
                Touch: new TouchFrameData(collection.FrameNumber, contacts)));
        }
        catch
        {
            // Native callbacks must return quickly and must never unwind into the driver.
        }

        return 0;
    }

    private void StartWintab()
    {
        if (!CWintabInfo.IsWintabAvailable())
        {
            return;
        }

        _wintabDeviceCount = CWintabInfo.GetNumberOfDevices();
        _wintabDeviceInfo = CWintabInfo.GetDeviceInfo()?.Replace('\0', ' ').Trim();
        _wintabMaxPressure = CWintabInfo.GetMaxPressure();
        _ = CWintabInfo.GetDeviceOrientation(out _wintabTiltSupported);
        var deviceIndex = CWintabInfo.GetDefaultDeviceIndex();
        var xAxis = CWintabInfo.GetDeviceAxis(deviceIndex, EAxisDimension.AXIS_X);
        var yAxis = CWintabInfo.GetDeviceAxis(deviceIndex, EAxisDimension.AXIS_Y);
        _wintabX = new WintabAxisInfo(xAxis.axMin, xAxis.axMax);
        _wintabY = new WintabAxisInfo(yAxis.axMin, yAxis.axMax);

        _wintabContext = CWintabInfo.GetDefaultDigitizingContext(ECTXOptionValues.CXO_MESSAGES);
        if (_wintabContext is null)
        {
            return;
        }

        _wintabContext.Name = "Wacom Local WebSocket Bridge";
        if (!_wintabContext.Open())
        {
            return;
        }

        _wintabContext.Enable(true);
        _wintabContext.SetOverlapOrder(true);
        _wintabData = new CWintabData(_wintabContext);
        _wintabData.SetStatusEventHandler(OnWintabStatus);
        _wintabPollingThread = new Thread(PollWintabPackets)
        {
            IsBackground = true,
            Name = "Wintab packet polling"
        };
        _wintabPollingThread.Start();
        PenReady = true;
    }

    private void PollWintabPackets()
    {
        while (!_disposed)
        {
            try
            {
                uint packetCount = 0;
                var packets = _wintabData?.GetDataPackets(128, true, ref packetCount);
                if (packets is null || packetCount == 0)
                {
                    Thread.Sleep(2);
                    continue;
                }

                foreach (var packet in packets)
                {
                    PublishWintabPacket(packet);
                }
            }
            catch
            {
                Thread.Sleep(10);
            }
        }
    }

    private void PublishWintabPacket(WintabPacket packet)
    {
        if (packet.pkContext == 0)
        {
            return;
        }

        Interlocked.Increment(ref _penPackets);
        Publish(new NativeInputEvent(
            0,
            TimestampUs(),
            "wintab",
            "pen.packet",
            unchecked((int)(_wintabContext?.Device ?? 0u)),
            Pen: new PenPacketData(
                packet.pkSerialNumber,
                packet.pkCursor,
                packet.pkX,
                packet.pkY,
                packet.pkZ,
                packet.pkNormalPressure,
                packet.pkTangentPressure,
                packet.pkButtons,
                packet.pkOrientation.orAzimuth,
                packet.pkOrientation.orAltitude,
                packet.pkOrientation.orTwist,
                packet.pkStatus,
                packet.pkChanged)));
    }

    private void OnWintabStatus(object? sender, MessageReceivedEventArgs eventArgs)
    {
        if (eventArgs.Message.Msg == (int)EWintabEventMessage.WT_CTXOVERLAP)
        {
            var contextHandle = unchecked((uint)eventArgs.Message.WParam.ToInt64());
            if (_wintabContext is null || contextHandle != _wintabContext.HCtx)
            {
                return;
            }

            var status = unchecked((int)eventArgs.Message.LParam.ToInt64());
            Volatile.Write(ref _wintabContextStatus, status);
            Interlocked.Increment(ref _wintabOverlapMessages);

            if ((status & (int)ECTXStatusValues.CXS_OBSCURED) != 0)
            {
                ScheduleObscuredPromotion();
            }
            else if ((status & (int)ECTXStatusValues.CXS_ONTOP) != 0)
            {
                Interlocked.Increment(ref _overlapPromotionGeneration);
            }
            return;
        }

        if (eventArgs.Message.Msg != (int)EWintabEventMessage.WT_PROXIMITY)
        {
            return;
        }

        var value = eventArgs.Message.LParam.ToInt64();
        // Wintab: low word = context proximity, high word = hardware proximity.
        var contextProximity = (value & 0xffff) != 0;
        var hardwareProximity = ((value >> 16) & 0xffff) != 0;
        Volatile.Write(ref _penContextProximity, contextProximity);
        Volatile.Write(ref _penHardwareProximity, hardwareProximity);

        if ((contextProximity || hardwareProximity) && HasActiveBrowserClient())
        {
            TryPromoteWintabContext();
        }
        else
        {
            lock (_wintabStateLock)
            {
                _promotionBurstCount = 0;
                _promotionBurstStarted = 0;
            }
        }

        Interlocked.Increment(ref _proximityMessages);
        Publish(new NativeInputEvent(
            0,
            TimestampUs(),
            "wintab",
            "pen.proximity",
            0,
            Proximity: new PenProximityData(
                hardwareProximity,
                contextProximity)));
    }

    private bool TryPromoteWintabContext(bool bypassRateLimit = false)
    {
        var context = _wintabContext;
        if (context is null || context.HCtx == 0 || _disposed)
        {
            return false;
        }

        lock (_wintabStateLock)
        {
            var now = Stopwatch.GetTimestamp();
            var minInterval = Stopwatch.Frequency / 10; // 100 ms
            var burstWindow = Stopwatch.Frequency * 2; // 2 seconds

            if (!bypassRateLimit && _lastPromotionTimestamp != 0 && now - _lastPromotionTimestamp < minInterval)
            {
                Interlocked.Increment(ref _wintabPromotionSkips);
                return false;
            }

            if (_promotionBurstStarted == 0 || now - _promotionBurstStarted > burstWindow)
            {
                _promotionBurstStarted = now;
                _promotionBurstCount = 0;
            }

            if (!bypassRateLimit && _promotionBurstCount >= 3)
            {
                Interlocked.Increment(ref _wintabPromotionSkips);
                return false;
            }

            _lastPromotionTimestamp = now;
            _promotionBurstCount++;
            Interlocked.Increment(ref _wintabPromotionAttempts);
            var succeeded = context.SetOverlapOrder(true);
            if (succeeded)
            {
                Interlocked.Increment(ref _wintabPromotionSuccesses);
            }
            return succeeded;
        }
    }

    public void SetBrowserClientActive(Guid clientId, long generation, bool active)
    {
        CancellationTokenSource? previous = null;
        CancellationTokenSource? current = null;

        lock (_clientStateLock)
        {
            _clientPromotionCancellations.Remove(clientId, out previous);

            if (active)
            {
                _activeBrowserClients[clientId] = generation;
                current = new CancellationTokenSource();
                _clientPromotionCancellations[clientId] = current;
            }
            else
            {
                _activeBrowserClients.Remove(clientId);
                Interlocked.Increment(ref _overlapPromotionGeneration);
            }
        }

        previous?.Cancel();
        if (!active || current is null)
        {
            Interlocked.Increment(ref _wintabClientDeactivations);
            return;
        }

        Interlocked.Increment(ref _wintabClientActivations);
        _ = RunActivationPromotionsAsync(clientId, generation, current);
    }

    public void RemoveBrowserClient(Guid clientId)
    {
        SetBrowserClientActive(clientId, 0, false);
    }

    private async Task RunActivationPromotionsAsync(
        Guid clientId,
        long generation,
        CancellationTokenSource cancellation)
    {
        try
        {
            var previousDelay = 0;
            foreach (var targetDelay in new[] { 0, 75, 200 })
            {
                var delay = targetDelay - previousDelay;
                previousDelay = targetDelay;
                if (delay > 0)
                {
                    await Task.Delay(delay, cancellation.Token);
                }

                lock (_clientStateLock)
                {
                    if (!_activeBrowserClients.TryGetValue(clientId, out var currentGeneration) ||
                        currentGeneration != generation)
                    {
                        return;
                    }
                }

                Interlocked.Increment(ref _wintabActivationPromotionRuns);
                TryPromoteWintabContext(bypassRateLimit: true);
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            lock (_clientStateLock)
            {
                if (_clientPromotionCancellations.TryGetValue(clientId, out var current) &&
                    ReferenceEquals(current, cancellation))
                {
                    _clientPromotionCancellations.Remove(clientId);
                }
            }
            cancellation.Dispose();
        }
    }

    private void ScheduleObscuredPromotion()
    {
        if (!HasActiveBrowserClient())
        {
            Interlocked.Increment(ref _wintabPromotionSkips);
            return;
        }

        var generation = Interlocked.Increment(ref _overlapPromotionGeneration);
        _ = Task.Run(async () =>
        {
            await Task.Delay(50);
            if (generation == Volatile.Read(ref _overlapPromotionGeneration) && HasActiveBrowserClient())
            {
                TryPromoteWintabContext();
            }
        });
    }

    private bool HasActiveBrowserClient()
    {
        lock (_clientStateLock)
        {
            return _activeBrowserClients.Count > 0;
        }
    }

    private int GetActiveBrowserClientCount()
    {
        lock (_clientStateLock)
        {
            return _activeBrowserClients.Count;
        }
    }

    private long TimestampUs()
    {
        var elapsed = Stopwatch.GetElapsedTime(_startTimestamp);
        return _startUnixUs + elapsed.Ticks / 10;
    }

    private void Publish(NativeInputEvent inputEvent)
    {
        lock (_publishLock)
        {
            var sequencedEvent = inputEvent with
            {
                Sequence = Interlocked.Increment(ref _sequence)
            };
            _events.Writer.TryWrite(sequencedEvent);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        lock (_clientStateLock)
        {
            foreach (var cancellation in _clientPromotionCancellations.Values)
            {
                cancellation.Cancel();
            }
            _clientPromotionCancellations.Clear();
            _activeBrowserClients.Clear();
        }

        if (_wintabData is not null)
        {
            _wintabData.RemoveStatusEventHandler(OnWintabStatus);
        }

        _wintabPollingThread?.Join(250);

        if (_wintabContext is not null && _wintabContext.HCtx != 0)
        {
            _wintabContext.Close();
        }

        foreach (var registration in _touchRegistrations)
        {
            var hitRect = registration.HitRect;
            CWacomMTInterface.WacomMTUnRegisterFingerReadCallback(
                registration.DeviceId,
                ref hitRect,
                registration.Mode,
                IntPtr.Zero);
        }

        if (_wacomMtInitialized)
        {
            CWacomMTInterface.WacomMTQuit();
        }

        _events.Writer.TryComplete();
    }

    private readonly record struct TouchRegistration(
        int DeviceId,
        WacomMTHitRect HitRect,
        WacomMTProcessingMode Mode);
}
