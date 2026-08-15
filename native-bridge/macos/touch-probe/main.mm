#include <WacomMultiTouch.h>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>

namespace {

constexpr std::size_t kQueueCapacity = 2048;
constexpr std::size_t kMaxContactsPerFrame = 32;

struct ContactSnapshot {
    int id = 0;
    WacomMTFingerState state = WMTFingerStateNone;
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
    unsigned short sensitivity = 0;
    float orientation = 0;
    bool confidence = false;
};

struct FrameSnapshot {
    std::chrono::steady_clock::time_point receivedAt;
    int deviceId = 0;
    int frameNumber = 0;
    std::size_t contactCount = 0;
    std::array<ContactSnapshot, kMaxContactsPerFrame> contacts{};
};

class FrameQueue {
public:
    void Push(const FrameSnapshot& frame) {
        {
            std::lock_guard lock(mutex_);
            if (count_ == frames_.size()) {
                readIndex_ = (readIndex_ + 1) % frames_.size();
                --count_;
                ++dropped_;
            }
            frames_[writeIndex_] = frame;
            writeIndex_ = (writeIndex_ + 1) % frames_.size();
            ++count_;
        }
        available_.notify_one();
    }

    bool Pop(FrameSnapshot& frame) {
        std::unique_lock lock(mutex_);
        available_.wait(lock, [this] { return stopped_ || count_ > 0; });
        if (count_ == 0) {
            return false;
        }
        frame = frames_[readIndex_];
        readIndex_ = (readIndex_ + 1) % frames_.size();
        --count_;
        return true;
    }

    void Stop() {
        {
            std::lock_guard lock(mutex_);
            stopped_ = true;
        }
        available_.notify_all();
    }

    std::uint64_t Dropped() const {
        std::lock_guard lock(mutex_);
        return dropped_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable available_;
    std::array<FrameSnapshot, kQueueCapacity> frames_{};
    std::size_t readIndex_ = 0;
    std::size_t writeIndex_ = 0;
    std::size_t count_ = 0;
    std::uint64_t dropped_ = 0;
    bool stopped_ = false;
};

struct ProbeContext {
    FrameQueue queue;
    std::atomic<std::uint64_t> frames{0};
    std::atomic<std::uint64_t> contacts{0};
    std::atomic<std::uint64_t> truncatedFrames{0};
};

std::atomic<bool> gStopRequested{false};

void HandleSignal(int) {
    gStopRequested.store(true, std::memory_order_relaxed);
}

const char* StateName(WacomMTFingerState state) {
    switch (state) {
        case WMTFingerStateNone: return "none";
        case WMTFingerStateDown: return "down";
        case WMTFingerStateHold: return "hold";
        case WMTFingerStateUp: return "up";
    }
    return "unknown";
}

const char* ErrorName(WacomMTError error) {
    switch (error) {
        case WMTErrorSuccess: return "success";
        case WMTErrorDriverNotFound: return "driver-not-found";
        case WMTErrorBadVersion: return "bad-version";
        case WMTErrorAPIOutdated: return "api-outdated";
        case WMTErrorInvalidParam: return "invalid-param";
        case WMTErrorQuit: return "quit";
        case WMTErrorBufferTooSmall: return "buffer-too-small";
    }
    return "unknown";
}

int OnFingerFrame(WacomMTFingerCollection* packet, void* userData) {
    if (packet == nullptr || userData == nullptr || packet->FingerCount < 0) {
        return 0;
    }

    auto& context = *static_cast<ProbeContext*>(userData);
    FrameSnapshot snapshot;
    snapshot.receivedAt = std::chrono::steady_clock::now();
    snapshot.deviceId = packet->DeviceID;
    snapshot.frameNumber = packet->FrameNumber;
    snapshot.contactCount = std::min(
        static_cast<std::size_t>(packet->FingerCount),
        kMaxContactsPerFrame);

    if (static_cast<std::size_t>(packet->FingerCount) > kMaxContactsPerFrame) {
        context.truncatedFrames.fetch_add(1, std::memory_order_relaxed);
    }

    for (std::size_t index = 0; index < snapshot.contactCount; ++index) {
        const auto& finger = packet->Fingers[index];
        snapshot.contacts[index] = ContactSnapshot{
            finger.FingerID,
            finger.TouchState,
            finger.X,
            finger.Y,
            finger.Width,
            finger.Height,
            finger.Sensitivity,
            finger.Orientation,
            finger.Confidence,
        };
    }

    context.frames.fetch_add(1, std::memory_order_relaxed);
    context.contacts.fetch_add(snapshot.contactCount, std::memory_order_relaxed);
    context.queue.Push(snapshot);
    return 0;
}

double ParseDuration(int argc, char* argv[]) {
    double durationSeconds = 20.0;
    for (int index = 1; index + 1 < argc; ++index) {
        if (std::string_view(argv[index]) == "--duration") {
            char* end = nullptr;
            const double parsed = std::strtod(argv[index + 1], &end);
            if (end != argv[index + 1] && *end == '\0' && parsed > 0) {
                durationSeconds = parsed;
            }
        }
    }
    return durationSeconds;
}

WacomMTProcessingMode ParseMode(int argc, char* argv[]) {
    for (int index = 1; index + 1 < argc; ++index) {
        if (std::string_view(argv[index]) != "--mode") {
            continue;
        }
        const std::string_view value(argv[index + 1]);
        if (value == "consumer") {
            return WMTProcessingModeNone;
        }
        if (value == "observer") {
            return WMTProcessingModeObserver;
        }
    }
    return WMTProcessingModeObserver;
}

const char* ModeName(WacomMTProcessingMode mode) {
    return mode == WMTProcessingModeObserver ? "observer" : "consumer";
}

void PrintFrame(const FrameSnapshot& frame,
                std::chrono::steady_clock::time_point startedAt) {
    const auto elapsed = std::chrono::duration<double>(frame.receivedAt - startedAt).count();
    std::cout << std::fixed << std::setprecision(3)
              << "TOUCH t=" << elapsed
              << " device=" << frame.deviceId
              << " frame=" << frame.frameNumber
              << " count=" << frame.contactCount;

    for (std::size_t index = 0; index < frame.contactCount; ++index) {
        const auto& contact = frame.contacts[index];
        std::cout << " [id=" << contact.id
                  << " state=" << StateName(contact.state)
                  << " xy=(" << contact.x << ',' << contact.y << ')'
                  << " size=(" << contact.width << ',' << contact.height << ')'
                  << " sensitivity=" << contact.sensitivity
                  << " orientation=" << contact.orientation
                  << " confidence=" << (contact.confidence ? "true" : "false")
                  << ']';
    }
    std::cout << '\n';
}

}  // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
    [NSApplication sharedApplication];
    const double durationSeconds = ParseDuration(argc, argv);
    const auto processingMode = ParseMode(argc, argv);
    std::signal(SIGINT, HandleSignal);
    std::signal(SIGTERM, HandleSignal);

    std::cout << "Wacom macOS touch probe\n"
              << "apiVersion=" << WACOM_MULTI_TOUCH_API_VERSION
              << " duration=" << durationSeconds << "s"
              << " mode=" << ModeName(processingMode) << "\n";

    if (WacomMTInitialize == nullptr) {
        std::cerr << "FATAL WacomMultiTouch.framework is unavailable\n";
        return 1;
    }

    const auto initializeResult = WacomMTInitialize(WACOM_MULTI_TOUCH_API_VERSION);
    std::cout << "INITIALIZE result=" << ErrorName(initializeResult)
              << " code=" << static_cast<int>(initializeResult) << '\n';
    if (initializeResult != WMTErrorSuccess) {
        return 2;
    }

    ProbeContext context;
    std::vector<int> registeredDevices;
    std::array<int, 64> deviceIds{};
    const int reportedDeviceCount = WacomMTGetAttachedDeviceIDs(
        deviceIds.data(), deviceIds.size() * sizeof(deviceIds[0]));
    const int readableDeviceCount = std::max(
        0, std::min(reportedDeviceCount, static_cast<int>(deviceIds.size())));
    std::cout << "DEVICES reported=" << reportedDeviceCount
              << " readable=" << readableDeviceCount << '\n';

    for (int index = 0; index < readableDeviceCount; ++index) {
        WacomMTCapability capabilities{};
        const int deviceId = deviceIds[index];
        const auto capabilitiesResult = WacomMTGetDeviceCapabilities(deviceId, &capabilities);
        std::cout << "CAPABILITIES device=" << deviceId
                  << " result=" << ErrorName(capabilitiesResult)
                  << " type=" << static_cast<int>(capabilities.Type)
                  << " logical=(" << capabilities.LogicalOriginX << ','
                  << capabilities.LogicalOriginY << ','
                  << capabilities.LogicalWidth << ','
                  << capabilities.LogicalHeight << ')'
                  << " physicalMm=(" << capabilities.PhysicalSizeX << ','
                  << capabilities.PhysicalSizeY << ')'
                  << " reported=(" << capabilities.ReportedSizeX << ','
                  << capabilities.ReportedSizeY << ')'
                  << " scan=(" << capabilities.ScanSizeX << ','
                  << capabilities.ScanSizeY << ')'
                  << " fingerMax=" << capabilities.FingerMax
                  << " flags=0x" << std::hex << capabilities.CapabilityFlags << std::dec
                  << '\n';
        if (capabilitiesResult != WMTErrorSuccess) {
            continue;
        }

        const auto registerResult = WacomMTRegisterFingerReadCallback(
            deviceId,
            nullptr,
            processingMode,
            OnFingerFrame,
            &context);
        std::cout << "REGISTER device=" << deviceId
                  << " mode=" << ModeName(processingMode)
                  << " result=" << ErrorName(registerResult)
                  << " code=" << static_cast<int>(registerResult) << '\n';
        if (registerResult == WMTErrorSuccess) {
            registeredDevices.push_back(deviceId);
        }
    }

    if (registeredDevices.empty()) {
        std::cerr << "FATAL no touch callback was registered\n";
        WacomMTQuit();
        return 3;
    }

    const auto startedAt = std::chrono::steady_clock::now();
    std::thread consumer([&] {
        FrameSnapshot frame;
        while (context.queue.Pop(frame)) {
            PrintFrame(frame, startedAt);
        }
    });

    std::cout << "READY touch the Cintiq now; press Ctrl+C to stop\n";
    const auto deadline = startedAt + std::chrono::duration<double>(durationSeconds);
    while (!gStopRequested.load(std::memory_order_relaxed) &&
           std::chrono::steady_clock::now() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    }

    for (const int deviceId : registeredDevices) {
        const auto unregisterResult = WacomMTUnRegisterFingerReadCallback(
            deviceId,
            nullptr,
            processingMode,
            &context);
        std::cout << "UNREGISTER device=" << deviceId
                  << " result=" << ErrorName(unregisterResult)
                  << " code=" << static_cast<int>(unregisterResult) << '\n';
    }

    WacomMTQuit();
    context.queue.Stop();
    consumer.join();

    const auto frameCount = context.frames.load(std::memory_order_relaxed);
    std::cout << "SUMMARY frames=" << frameCount
              << " contacts=" << context.contacts.load(std::memory_order_relaxed)
              << " queueDropped=" << context.queue.Dropped()
              << " truncatedFrames=" << context.truncatedFrames.load(std::memory_order_relaxed)
              << '\n';
    return frameCount > 0 ? 0 : 4;
    }
}
