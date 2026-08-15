using System.Runtime.InteropServices;
using WacomMTDN;
using WintabDN;

namespace WacomInputProbe;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        var duration = ParseDuration(args);

        Console.WriteLine("Wacom native input probe");
        Console.WriteLine($"process.arch={RuntimeInformation.ProcessArchitecture}, os.arch={RuntimeInformation.OSArchitecture}");
        Console.WriteLine($"duration={(duration == Timeout.InfiniteTimeSpan ? "infinite" : duration.TotalSeconds + "s")}");
        Console.WriteLine("Press Ctrl+C to stop.");

        using var stop = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            stop.Set();
        };

        try
        {
            using var probe = new NativeInputProbe();
            probe.Start();

            if (duration == Timeout.InfiniteTimeSpan)
            {
                stop.Wait();
            }
            else
            {
                stop.Wait(duration);
            }

            probe.PrintSummary();
            return probe.IsReady ? 0 : 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"FATAL {ex}");
            return 1;
        }
    }

    private static TimeSpan ParseDuration(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--duration" && i + 1 < args.Length &&
                double.TryParse(args[i + 1], out var seconds) && seconds > 0)
            {
                return TimeSpan.FromSeconds(seconds);
            }
        }

        return TimeSpan.FromSeconds(20);
    }
}

internal sealed class NativeInputProbe : IDisposable
{
    private readonly object _consoleLock = new();
    private readonly List<TouchRegistration> _touchRegistrations = [];
    private readonly WacomMTCallback _touchCallback;
    private bool _wacomMtInitialized;
    private CWintabContext? _wintabContext;
    private CWintabData? _wintabData;
    private long _touchFrames;
    private long _touchContacts;
    private long _penPackets;
    private long _proximityMessages;
    private bool _disposed;

    public NativeInputProbe()
    {
        _touchCallback = OnTouchPacket;
    }

    public bool TouchReady { get; private set; }
    public bool PenReady { get; private set; }
    public bool IsReady => TouchReady && PenReady;

    public void Start()
    {
        StartWacomMt();
        StartWintab();
        Console.WriteLine($"READY touch={TouchReady} pen={PenReady}");
        Console.WriteLine("Interact with the Cintiq now: multiple fingers, pen hover, tip and side buttons.");
    }

    private void StartWacomMt()
    {
        var initializeResult = CWacomMTInterface.WacomMTInitialize(
            WacomMTConstants.WACOM_MULTI_TOUCH_API_VERSION);

        Console.WriteLine($"WACOM_MT initialize={initializeResult} api={WacomMTConstants.WACOM_MULTI_TOUCH_API_VERSION}");
        if (initializeResult != WacomMTError.WMTErrorSuccess)
        {
            return;
        }

        _wacomMtInitialized = true;
        var deviceCount = CWacomMTInterface.WacomMTGetAttachedDeviceIDs(IntPtr.Zero, 0);
        Console.WriteLine($"WACOM_MT attachedDevices={deviceCount}");
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
                var deviceId = Marshal.ReadInt32(idsBuffer, index * sizeof(int));
                RegisterTouchDevice(deviceId);
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
            var capsResult = CWacomMTInterface.WacomMTGetDeviceCapabilities(deviceId, capsBuffer);
            if (capsResult != WacomMTError.WMTErrorSuccess)
            {
                Console.WriteLine($"WACOM_MT device={deviceId} capabilities={capsResult}");
                return;
            }

            var caps = Marshal.PtrToStructure<WacomMTCapability>(capsBuffer);
            Console.WriteLine(
                $"WACOM_MT device={caps.DeviceID} type={caps.Type} " +
                $"logical=({caps.LogicalOriginX},{caps.LogicalOriginY},{caps.LogicalWidth},{caps.LogicalHeight}) " +
                $"physicalMm=({caps.PhysicalSizeX},{caps.PhysicalSizeY}) " +
                $"fingerMax={caps.FingerMax} scan=({caps.ScanSizeX},{caps.ScanSizeY}) " +
                $"flags={caps.CapabilityFlags}");

            var hitRect = new WacomMTHitRect(
                caps.LogicalOriginX,
                caps.LogicalOriginY,
                caps.LogicalWidth,
                caps.LogicalHeight);
            var mode = WacomMTProcessingMode.WMTProcessingModeObserver;
            var registerResult = CWacomMTInterface.WacomMTRegisterFingerReadCallback(
                deviceId, ref hitRect, mode, _touchCallback, IntPtr.Zero);

            Console.WriteLine($"WACOM_MT observer device={deviceId} register={registerResult}");
            if (registerResult == WacomMTError.WMTErrorSuccess)
            {
                _touchRegistrations.Add(new TouchRegistration(deviceId, hitRect, mode));
            }
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
            Interlocked.Increment(ref _touchFrames);
            Interlocked.Add(ref _touchContacts, collection.FingerCount);

            var contacts = new string[collection.FingerCount];
            for (uint index = 0; index < collection.FingerCount; index++)
            {
                var finger = collection.GetFingerByIndex(index);
                contacts[index] =
                    $"id={finger.FingerID} state={finger.TouchState} " +
                    $"xy=({finger.X:F1},{finger.Y:F1}) size=({finger.Width:F1},{finger.Height:F1}) " +
                    $"sensitivity={finger.Sensitivity} orientation={finger.Orientation:F1} confidence={finger.Confidence}";
            }

            WriteEvent($"TOUCH frame={collection.FrameNumber} device={collection.DeviceID} count={collection.FingerCount} [{string.Join("; ", contacts)}]");
        }
        catch (Exception ex)
        {
            WriteEvent($"TOUCH_ERROR {ex.Message}");
        }

        return 0;
    }

    private void StartWintab()
    {
        var available = CWintabInfo.IsWintabAvailable();
        Console.WriteLine($"WINTAB available={available}");
        if (!available)
        {
            return;
        }

        var deviceInfo = CWintabInfo.GetDeviceInfo()?.Replace('\0', ' ').Trim();
        var deviceCount = CWintabInfo.GetNumberOfDevices();
        var maxPressure = CWintabInfo.GetMaxPressure();
        _ = CWintabInfo.GetDeviceOrientation(out var tiltSupported);
        Console.WriteLine(
            $"WINTAB devices={deviceCount} info=\"{deviceInfo}\" " +
            $"maxPressure={maxPressure} tiltSupported={tiltSupported}");

        _wintabContext = CWintabInfo.GetDefaultDigitizingContext(ECTXOptionValues.CXO_MESSAGES);
        if (_wintabContext is null)
        {
            Console.WriteLine("WINTAB digitizerContext=null");
            return;
        }

        _wintabContext.Name = "WacomInputProbe Digitizer Context";
        var opened = _wintabContext.Open();
        Console.WriteLine($"WINTAB digitizerContext.open={opened} handle={_wintabContext.HCtx}");
        if (!opened)
        {
            return;
        }

        var enabled = _wintabContext.Enable(true);
        var onTop = _wintabContext.SetOverlapOrder(true);
        Console.WriteLine($"WINTAB digitizerContext.enable={enabled} overlapTop={onTop}");

        _wintabData = new CWintabData(_wintabContext);
        _wintabData.SetWTPacketEventHandler(OnWintabPacket);
        _wintabData.SetStatusEventHandler(OnWintabStatus);
        PenReady = true;
    }

    private void OnWintabPacket(object? sender, MessageReceivedEventArgs eventArgs)
    {
        if (_wintabData is null || eventArgs.Message.Msg != (int)EWintabEventMessage.WT_PACKET)
        {
            return;
        }

        try
        {
            var packetId = unchecked((uint)eventArgs.Message.WParam.ToInt64());
            var contextHandle = unchecked((uint)eventArgs.Message.LParam.ToInt64());
            var packet = _wintabData.GetDataPacket(contextHandle, packetId);
            if (packet.pkContext == 0)
            {
                return;
            }

            Interlocked.Increment(ref _penPackets);
            WriteEvent(
                $"PEN serial={packet.pkSerialNumber} cursor={packet.pkCursor} " +
                $"xy=({packet.pkX},{packet.pkY}) z={packet.pkZ} pressure={packet.pkNormalPressure} " +
                $"tangentPressure={packet.pkTangentPressure} buttons=0x{packet.pkButtons:X} " +
                $"orientation=(azimuth={packet.pkOrientation.orAzimuth},altitude={packet.pkOrientation.orAltitude},twist={packet.pkOrientation.orTwist}) " +
                $"status=0x{packet.pkStatus:X} changed={packet.pkChanged}");
        }
        catch (Exception ex)
        {
            WriteEvent($"PEN_ERROR {ex.Message}");
        }
    }

    private void OnWintabStatus(object? sender, MessageReceivedEventArgs eventArgs)
    {
        if (eventArgs.Message.Msg != (int)EWintabEventMessage.WT_PROXIMITY)
        {
            return;
        }

        Interlocked.Increment(ref _proximityMessages);
        var value = eventArgs.Message.LParam.ToInt64();
        var hardwareProximity = (value & 0xffff) != 0;
        var contextProximity = ((value >> 16) & 0xffff) != 0;
        WriteEvent($"PEN_PROXIMITY hardware={hardwareProximity} context={contextProximity}");
    }

    private void WriteEvent(string message)
    {
        lock (_consoleLock)
        {
            Console.WriteLine($"{DateTimeOffset.Now:HH:mm:ss.fff} {message}");
        }
    }

    public void PrintSummary()
    {
        Console.WriteLine(
            $"SUMMARY touchFrames={Interlocked.Read(ref _touchFrames)} " +
            $"touchContacts={Interlocked.Read(ref _touchContacts)} " +
            $"penPackets={Interlocked.Read(ref _penPackets)} " +
            $"proximityMessages={Interlocked.Read(ref _proximityMessages)}");
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_wintabData is not null)
        {
            _wintabData.RemoveWTPacketEventHandler(OnWintabPacket);
            _wintabData.RemoveStatusEventHandler(OnWintabStatus);
        }

        if (_wintabContext is not null && _wintabContext.HCtx != 0)
        {
            _wintabContext.Close();
        }

        foreach (var registration in _touchRegistrations)
        {
            var hitRect = registration.HitRect;
            var result = CWacomMTInterface.WacomMTUnRegisterFingerReadCallback(
                registration.DeviceId,
                ref hitRect,
                registration.Mode,
                IntPtr.Zero);
            Console.WriteLine($"WACOM_MT observer device={registration.DeviceId} unregister={result}");
        }

        if (_wacomMtInitialized)
        {
            CWacomMTInterface.WacomMTQuit();
        }
    }

    private readonly record struct TouchRegistration(
        int DeviceId,
        WacomMTHitRect HitRect,
        WacomMTProcessingMode Mode);
}
