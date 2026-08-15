#import <AppKit/AppKit.h>

#include <WacomMultiTouch.h>

#include "NativeInputSource.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <vector>

namespace {

constexpr std::size_t kInputQueueCapacity = 16'384;

bool IsMouseType(NSEventType type) {
    switch (type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeOtherMouseDragged:
            return true;
        default:
            return false;
    }
}

bool IsTabletPointEvent(NSEvent* event) {
    return event.type == NSEventTypeTabletPoint ||
           (IsMouseType(event.type) && event.subtype == NSEventSubtypeTabletPoint);
}

bool IsTabletProximityEvent(NSEvent* event) {
    return event.type == NSEventTypeTabletProximity ||
           (IsMouseType(event.type) && event.subtype == NSEventSubtypeTabletProximity);
}

CommonTouchState CommonState(WacomMTFingerState state) {
    switch (state) {
        case WMTFingerStateDown: return CommonTouchState::Down;
        case WMTFingerStateHold: return CommonTouchState::Hold;
        case WMTFingerStateUp: return CommonTouchState::Up;
        case WMTFingerStateNone: return CommonTouchState::None;
    }
    return CommonTouchState::None;
}

PointingDeviceKind CommonPointingDevice(NSPointingDeviceType type) {
    switch (type) {
        case NSPointingDeviceTypePen: return PointingDeviceKind::Pen;
        case NSPointingDeviceTypeCursor: return PointingDeviceKind::Cursor;
        case NSPointingDeviceTypeEraser: return PointingDeviceKind::Eraser;
        case NSPointingDeviceTypeUnknown: return PointingDeviceKind::Unknown;
    }
    return PointingDeviceKind::Unknown;
}

}  // namespace

struct NativeInputSource::Impl {
    Impl()
        : events(kInputQueueCapacity),
          startSteady(std::chrono::steady_clock::now()),
          startUnixUs(std::chrono::duration_cast<std::chrono::microseconds>(
              std::chrono::system_clock::now().time_since_epoch()).count()) {}

    BoundedQueue<NativeInputEvent> events;
    std::chrono::steady_clock::time_point startSteady;
    std::int64_t startUnixUs;
    mutable std::mutex publishMutex;
    std::vector<TouchDeviceInfo> touchDevices;
    std::vector<int> registeredTouchDevices;
    id globalMonitor = nil;
    id localMonitor = nil;
    bool wacomInitialized = false;
    std::atomic<bool> stopped{false};
    std::atomic<bool> touchReady{false};
    std::atomic<bool> penReady{false};
    std::atomic<bool> penHardwareProximity{false};
    std::atomic<PointingDeviceKind> currentPointingDevice{PointingDeviceKind::Unknown};
    std::atomic<std::uint64_t> currentUniqueId{0};
    std::atomic<std::uint64_t> sequence{0};
    std::atomic<std::uint64_t> producedEvents{0};
    std::atomic<std::uint64_t> touchFrames{0};
    std::atomic<std::uint64_t> touchContacts{0};
    std::atomic<std::uint64_t> truncatedTouchFrames{0};
    std::atomic<std::uint64_t> penPackets{0};
    std::atomic<std::uint64_t> proximityMessages{0};
    std::atomic<std::uint64_t> penLocalEvents{0};
    std::atomic<std::uint64_t> penGlobalEvents{0};
    std::atomic<std::uint64_t> deduplicatedPenEvents{0};
    std::atomic<std::uint64_t> penSerial{0};

    std::mutex dedupeMutex;
    double lastProximityTimestamp = -1;
    bool lastProximityEntering = false;
    std::uint64_t lastProximityDeviceId = 0;
    std::uint64_t lastProximityUniqueId = 0;
    double lastPointTimestamp = -1;
    double lastPointX = 0;
    double lastPointY = 0;
    std::uint64_t lastPointButtons = 0;

    std::int64_t TimestampUs() const {
        const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - startSteady).count();
        return startUnixUs + elapsed;
    }

    void Publish(NativeInputEvent event) {
        std::lock_guard lock(publishMutex);
        event.sequence = sequence.fetch_add(1, std::memory_order_relaxed) + 1;
        event.timestampUs = TimestampUs();
        producedEvents.fetch_add(1, std::memory_order_relaxed);
        events.Push(std::move(event));
    }

    static int FingerCallback(WacomMTFingerCollection* packet, void* userData) {
        if (packet == nullptr || userData == nullptr || packet->FingerCount < 0) {
            return 0;
        }
        auto& self = *static_cast<Impl*>(userData);
        if (self.stopped.load(std::memory_order_relaxed)) {
            return 0;
        }

        NativeInputEvent event;
        event.kind = NativeEventKind::TouchFrame;
        event.deviceId = packet->DeviceID;
        event.touch.frameNumber = static_cast<std::uint32_t>(packet->FrameNumber);
        event.touch.contactCount = std::min(
            static_cast<std::size_t>(packet->FingerCount),
            kMaxContactsPerFrame);
        if (static_cast<std::size_t>(packet->FingerCount) > kMaxContactsPerFrame) {
            self.truncatedTouchFrames.fetch_add(1, std::memory_order_relaxed);
        }

        for (std::size_t index = 0; index < event.touch.contactCount; ++index) {
            const auto& finger = packet->Fingers[index];
            event.touch.contacts[index] = TouchContactSnapshot{
                finger.FingerID,
                CommonState(finger.TouchState),
                finger.X,
                finger.Y,
                finger.Width,
                finger.Height,
                finger.Sensitivity,
                finger.Orientation,
                finger.Confidence,
            };
        }

        self.touchFrames.fetch_add(1, std::memory_order_relaxed);
        self.touchContacts.fetch_add(event.touch.contactCount, std::memory_order_relaxed);
        self.Publish(std::move(event));
        return 0;
    }

    bool StartTouch() {
        if (WacomMTInitialize == nullptr) {
            std::cerr << "WacomMultiTouch.framework is unavailable\n";
            return false;
        }
        const auto initializeResult = WacomMTInitialize(WACOM_MULTI_TOUCH_API_VERSION);
        if (initializeResult != WMTErrorSuccess) {
            std::cerr << "WacomMTInitialize failed: " << static_cast<int>(initializeResult) << '\n';
            return false;
        }
        wacomInitialized = true;

        std::array<int, 64> deviceIds{};
        const int reportedCount = WacomMTGetAttachedDeviceIDs(
            deviceIds.data(), deviceIds.size() * sizeof(deviceIds[0]));
        const int readableCount = std::max(
            0, std::min(reportedCount, static_cast<int>(deviceIds.size())));

        for (int index = 0; index < readableCount; ++index) {
            WacomMTCapability capability{};
            const int deviceId = deviceIds[index];
            if (WacomMTGetDeviceCapabilities(deviceId, &capability) != WMTErrorSuccess) {
                continue;
            }
            touchDevices.push_back(TouchDeviceInfo{
                deviceId,
                capability.Type == WMTDeviceTypeIntegrated ? "integrated" : "opaque",
                capability.LogicalOriginX,
                capability.LogicalOriginY,
                capability.LogicalWidth,
                capability.LogicalHeight,
                capability.PhysicalSizeX,
                capability.PhysicalSizeY,
                capability.ReportedSizeX,
                capability.ReportedSizeY,
                capability.FingerMax,
                capability.ScanSizeX,
                capability.ScanSizeY,
                (capability.CapabilityFlags & WMTCapabilityFlagsRawAvailable) != 0,
                (capability.CapabilityFlags & WMTCapabilityFlagsBlobAvailable) != 0,
                (capability.CapabilityFlags & WMTCapabilityFlagsSensitivityAvailable) != 0,
            });

            const auto result = WacomMTRegisterFingerReadCallback(
                deviceId,
                nullptr,
                WMTProcessingModeObserver,
                FingerCallback,
                this);
            if (result == WMTErrorSuccess) {
                registeredTouchDevices.push_back(deviceId);
            } else {
                std::cerr << "Touch registration failed for device " << deviceId
                          << ": " << static_cast<int>(result) << '\n';
            }
        }

        const bool ready = !registeredTouchDevices.empty();
        touchReady.store(ready, std::memory_order_release);
        return ready;
    }

    bool IsDuplicateProximity(NSEvent* event) {
        const auto deviceId = static_cast<std::uint64_t>(event.deviceID);
        const auto uniqueId = static_cast<std::uint64_t>(event.uniqueID);
        const bool entering = event.enteringProximity;
        std::lock_guard lock(dedupeMutex);
        const bool duplicate = lastProximityTimestamp >= 0 &&
            std::abs(event.timestamp - lastProximityTimestamp) < 0.005 &&
            entering == lastProximityEntering &&
            deviceId == lastProximityDeviceId &&
            uniqueId == lastProximityUniqueId;
        lastProximityTimestamp = event.timestamp;
        lastProximityEntering = entering;
        lastProximityDeviceId = deviceId;
        lastProximityUniqueId = uniqueId;
        return duplicate;
    }

    bool IsDuplicatePoint(NSEvent* event) {
        std::lock_guard lock(dedupeMutex);
        const bool duplicate = lastPointTimestamp >= 0 &&
            std::abs(event.timestamp - lastPointTimestamp) < 0.001 &&
            std::abs(event.absoluteX - lastPointX) < 0.5 &&
            std::abs(event.absoluteY - lastPointY) < 0.5 &&
            event.buttonMask == lastPointButtons;
        lastPointTimestamp = event.timestamp;
        lastPointX = event.absoluteX;
        lastPointY = event.absoluteY;
        lastPointButtons = event.buttonMask;
        return duplicate;
    }

    void CapturePenEvent(NSEvent* event, bool local) {
        const bool isPoint = IsTabletPointEvent(event);
        const bool isProximity = IsTabletProximityEvent(event);
        if (!isPoint && !isProximity) {
            return;
        }
        (local ? penLocalEvents : penGlobalEvents).fetch_add(1, std::memory_order_relaxed);

        if (isProximity) {
            if (IsDuplicateProximity(event)) {
                deduplicatedPenEvents.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            NativeInputEvent output;
            output.kind = NativeEventKind::PenProximity;
            output.deviceId = static_cast<int>(event.deviceID);
            output.proximity.entering = event.enteringProximity;
            output.proximity.pointingDevice = CommonPointingDevice(event.pointingDeviceType);
            output.proximity.pointingDeviceId = event.pointingDeviceID;
            output.proximity.systemTabletId = event.systemTabletID;
            output.proximity.tabletId = event.tabletID;
            output.proximity.uniqueId = event.uniqueID;
            output.proximity.vendorId = event.vendorID;
            output.proximity.vendorPointingDeviceType = event.vendorPointingDeviceType;
            output.proximity.capabilityMask = event.capabilityMask;

            penHardwareProximity.store(event.enteringProximity, std::memory_order_release);
            currentPointingDevice.store(output.proximity.pointingDevice, std::memory_order_release);
            currentUniqueId.store(output.proximity.uniqueId, std::memory_order_release);
            proximityMessages.fetch_add(1, std::memory_order_relaxed);
            Publish(std::move(output));
            if (!event.enteringProximity) {
                currentPointingDevice.store(PointingDeviceKind::Unknown, std::memory_order_release);
                currentUniqueId.store(0, std::memory_order_release);
            }
            return;
        }

        if (IsDuplicatePoint(event)) {
            deduplicatedPenEvents.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        NativeInputEvent output;
        output.kind = NativeEventKind::PenPacket;
        output.deviceId = static_cast<int>(event.deviceID);
        output.pen.serial = penSerial.fetch_add(1, std::memory_order_relaxed) + 1;
        output.pen.eventTimestamp = event.timestamp;
        output.pen.absoluteX = event.absoluteX;
        output.pen.absoluteY = event.absoluteY;
        output.pen.absoluteZ = event.absoluteZ;
        if (CGEventRef cgEvent = event.CGEvent) {
            const CGPoint location = CGEventGetLocation(cgEvent);
            output.pen.screenX = location.x;
            output.pen.screenY = location.y;
            output.pen.hasScreenLocation = true;
        }
        output.pen.pressure = event.pressure;
        output.pen.tangentialPressure = event.tangentialPressure;
        output.pen.tiltX = event.tilt.x;
        output.pen.tiltY = event.tilt.y;
        output.pen.rotation = event.rotation;
        output.pen.buttons = event.buttonMask;
        output.pen.pointingDevice = currentPointingDevice.load(std::memory_order_acquire);
        output.pen.uniqueId = currentUniqueId.load(std::memory_order_acquire);
        penPackets.fetch_add(1, std::memory_order_relaxed);
        Publish(std::move(output));
    }

    bool StartPen() {
        const NSEventMask mask = NSEventMaskTabletPoint |
                                 NSEventMaskTabletProximity |
                                 NSEventMaskMouseMoved |
                                 NSEventMaskLeftMouseDown |
                                 NSEventMaskLeftMouseUp |
                                 NSEventMaskLeftMouseDragged |
                                 NSEventMaskRightMouseDown |
                                 NSEventMaskRightMouseUp |
                                 NSEventMaskRightMouseDragged |
                                 NSEventMaskOtherMouseDown |
                                 NSEventMaskOtherMouseUp |
                                 NSEventMaskOtherMouseDragged;
        Impl* self = this;
        globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                                               handler:^(NSEvent* event) {
            self->CapturePenEvent(event, false);
        }];
        localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                             handler:^NSEvent* (NSEvent* event) {
            self->CapturePenEvent(event, true);
            return event;
        }];
        const bool ready = globalMonitor != nil && localMonitor != nil;
        penReady.store(ready, std::memory_order_release);
        return ready;
    }

    void Stop() {
        if (stopped.exchange(true, std::memory_order_acq_rel)) {
            return;
        }
        if (globalMonitor != nil) {
            [NSEvent removeMonitor:globalMonitor];
            globalMonitor = nil;
        }
        if (localMonitor != nil) {
            [NSEvent removeMonitor:localMonitor];
            localMonitor = nil;
        }
        penReady.store(false, std::memory_order_release);

        for (const int deviceId : registeredTouchDevices) {
            WacomMTUnRegisterFingerReadCallback(
                deviceId,
                nullptr,
                WMTProcessingModeObserver,
                this);
        }
        registeredTouchDevices.clear();
        touchReady.store(false, std::memory_order_release);
        if (wacomInitialized) {
            WacomMTQuit();
            wacomInitialized = false;
        }
        events.Stop();
    }
};

NativeInputSource::NativeInputSource()
    : impl_(std::make_unique<Impl>()) {}

NativeInputSource::~NativeInputSource() {
    Stop();
}

bool NativeInputSource::Start() {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    const bool touch = impl_->StartTouch();
    const bool pen = impl_->StartPen();
    return touch && pen;
}

void NativeInputSource::PumpAppEvent(double timeoutSeconds) {
    @autoreleasepool {
        NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:[NSDate dateWithTimeIntervalSinceNow:timeoutSeconds]
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES];
        if (event != nil) {
            [NSApp sendEvent:event];
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
    }
}

void NativeInputSource::Stop() {
    if (impl_) {
        impl_->Stop();
    }
}

BoundedQueue<NativeInputEvent>& NativeInputSource::Events() {
    return impl_->events;
}

NativeStatusSnapshot NativeInputSource::Status() const {
    NativeStatusSnapshot status;
    status.touchReady = impl_->touchReady.load(std::memory_order_acquire);
    status.penReady = impl_->penReady.load(std::memory_order_acquire);
    status.touchDevices = impl_->touchDevices;
    status.penHardwareProximity = impl_->penHardwareProximity.load(std::memory_order_acquire);
    status.pointingDevice = impl_->currentPointingDevice.load(std::memory_order_acquire);
    status.penUniqueId = impl_->currentUniqueId.load(std::memory_order_acquire);
    status.producedEvents = impl_->producedEvents.load(std::memory_order_relaxed);
    status.droppedInputEvents = impl_->events.Dropped();
    status.touchFrames = impl_->touchFrames.load(std::memory_order_relaxed);
    status.touchContacts = impl_->touchContacts.load(std::memory_order_relaxed);
    status.truncatedTouchFrames = impl_->truncatedTouchFrames.load(std::memory_order_relaxed);
    status.penPackets = impl_->penPackets.load(std::memory_order_relaxed);
    status.proximityMessages = impl_->proximityMessages.load(std::memory_order_relaxed);
    status.penLocalEvents = impl_->penLocalEvents.load(std::memory_order_relaxed);
    status.penGlobalEvents = impl_->penGlobalEvents.load(std::memory_order_relaxed);
    status.deduplicatedPenEvents = impl_->deduplicatedPenEvents.load(std::memory_order_relaxed);
    return status;
}

