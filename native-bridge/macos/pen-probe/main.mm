#import <AppKit/AppKit.h>

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

namespace {

constexpr std::size_t kQueueCapacity = 4096;

enum class MonitorSource : std::uint8_t {
    Local,
    Global,
};

struct PenEventSnapshot {
    std::chrono::steady_clock::time_point receivedAt;
    MonitorSource monitor = MonitorSource::Local;
    NSEventType type = NSEventTypeApplicationDefined;
    NSEventSubtype subtype = NSEventSubtypeWindowExposed;
    NSTimeInterval eventTimestamp = 0;
    NSInteger eventNumber = 0;
    CGFloat absoluteX = 0;
    CGFloat absoluteY = 0;
    CGFloat absoluteZ = 0;
    CGFloat screenX = 0;
    CGFloat screenY = 0;
    BOOL hasScreenLocation = NO;
    CGFloat pressure = 0;
    CGFloat tangentialPressure = 0;
    CGFloat tiltX = 0;
    CGFloat tiltY = 0;
    CGFloat rotation = 0;
    NSUInteger buttonMask = 0;
    BOOL enteringProximity = NO;
    NSPointingDeviceType pointingDeviceType = NSPointingDeviceTypeUnknown;
    NSUInteger deviceID = 0;
    NSUInteger pointingDeviceID = 0;
    NSUInteger systemTabletID = 0;
    NSUInteger tabletID = 0;
    unsigned long long uniqueID = 0;
    NSUInteger vendorID = 0;
    NSUInteger vendorPointingDeviceType = 0;
    NSUInteger capabilityMask = 0;
};

class EventQueue {
public:
    void Push(const PenEventSnapshot& event) {
        {
            std::lock_guard lock(mutex_);
            if (count_ == events_.size()) {
                readIndex_ = (readIndex_ + 1) % events_.size();
                --count_;
                ++dropped_;
            }
            events_[writeIndex_] = event;
            writeIndex_ = (writeIndex_ + 1) % events_.size();
            ++count_;
        }
        available_.notify_one();
    }

    bool Pop(PenEventSnapshot& event) {
        std::unique_lock lock(mutex_);
        available_.wait(lock, [this] { return stopped_ || count_ > 0; });
        if (count_ == 0) {
            return false;
        }
        event = events_[readIndex_];
        readIndex_ = (readIndex_ + 1) % events_.size();
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
    std::array<PenEventSnapshot, kQueueCapacity> events_{};
    std::size_t readIndex_ = 0;
    std::size_t writeIndex_ = 0;
    std::size_t count_ = 0;
    std::uint64_t dropped_ = 0;
    bool stopped_ = false;
};

struct ProbeContext {
    EventQueue queue;
    std::atomic<std::uint64_t> localEvents{0};
    std::atomic<std::uint64_t> globalEvents{0};
    std::atomic<std::uint64_t> pointEvents{0};
    std::atomic<std::uint64_t> proximityEvents{0};
    std::atomic<std::uint64_t> tabletSubtypeEvents{0};
};

std::atomic<bool> gStopRequested{false};

void HandleSignal(int) {
    gStopRequested.store(true, std::memory_order_relaxed);
}

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

const char* MonitorName(MonitorSource source) {
    return source == MonitorSource::Local ? "local" : "global";
}

const char* EventTypeName(NSEventType type) {
    switch (type) {
        case NSEventTypeLeftMouseDown: return "leftMouseDown";
        case NSEventTypeLeftMouseUp: return "leftMouseUp";
        case NSEventTypeRightMouseDown: return "rightMouseDown";
        case NSEventTypeRightMouseUp: return "rightMouseUp";
        case NSEventTypeMouseMoved: return "mouseMoved";
        case NSEventTypeLeftMouseDragged: return "leftMouseDragged";
        case NSEventTypeRightMouseDragged: return "rightMouseDragged";
        case NSEventTypeOtherMouseDown: return "otherMouseDown";
        case NSEventTypeOtherMouseUp: return "otherMouseUp";
        case NSEventTypeOtherMouseDragged: return "otherMouseDragged";
        case NSEventTypeTabletPoint: return "tabletPoint";
        case NSEventTypeTabletProximity: return "tabletProximity";
        default: return "other";
    }
}

const char* DeviceTypeName(NSPointingDeviceType type) {
    switch (type) {
        case NSPointingDeviceTypePen: return "pen";
        case NSPointingDeviceTypeCursor: return "cursor";
        case NSPointingDeviceTypeEraser: return "eraser";
        case NSPointingDeviceTypeUnknown: return "unknown";
    }
    return "unknown";
}

void CaptureEvent(NSEvent* event, MonitorSource monitor, ProbeContext& context) {
    const bool isPoint = IsTabletPointEvent(event);
    const bool isProximity = IsTabletProximityEvent(event);
    if (!isPoint && !isProximity) {
        return;
    }

    PenEventSnapshot snapshot;
    snapshot.receivedAt = std::chrono::steady_clock::now();
    snapshot.monitor = monitor;
    snapshot.type = event.type;
    if (IsMouseType(event.type)) {
        snapshot.subtype = event.subtype;
    }
    snapshot.eventTimestamp = event.timestamp;

    if (isPoint) {
        if (IsMouseType(event.type)) {
            snapshot.eventNumber = event.eventNumber;
        }
        snapshot.absoluteX = event.absoluteX;
        snapshot.absoluteY = event.absoluteY;
        snapshot.absoluteZ = event.absoluteZ;
        if (CGEventRef cgEvent = event.CGEvent) {
            const CGPoint location = CGEventGetLocation(cgEvent);
            snapshot.screenX = location.x;
            snapshot.screenY = location.y;
            snapshot.hasScreenLocation = YES;
        }
        snapshot.pressure = event.pressure;
        snapshot.tangentialPressure = event.tangentialPressure;
        snapshot.tiltX = event.tilt.x;
        snapshot.tiltY = event.tilt.y;
        snapshot.rotation = event.rotation;
        snapshot.buttonMask = event.buttonMask;
        snapshot.deviceID = event.deviceID;
        context.pointEvents.fetch_add(1, std::memory_order_relaxed);
    }

    if (isProximity) {
        snapshot.enteringProximity = event.enteringProximity;
        snapshot.pointingDeviceType = event.pointingDeviceType;
        snapshot.deviceID = event.deviceID;
        snapshot.pointingDeviceID = event.pointingDeviceID;
        snapshot.systemTabletID = event.systemTabletID;
        snapshot.tabletID = event.tabletID;
        snapshot.uniqueID = event.uniqueID;
        snapshot.vendorID = event.vendorID;
        snapshot.vendorPointingDeviceType = event.vendorPointingDeviceType;
        snapshot.capabilityMask = event.capabilityMask;
        context.proximityEvents.fetch_add(1, std::memory_order_relaxed);
    }

    if (event.type != NSEventTypeTabletPoint &&
        event.type != NSEventTypeTabletProximity) {
        context.tabletSubtypeEvents.fetch_add(1, std::memory_order_relaxed);
    }
    if (monitor == MonitorSource::Local) {
        context.localEvents.fetch_add(1, std::memory_order_relaxed);
    } else {
        context.globalEvents.fetch_add(1, std::memory_order_relaxed);
    }
    context.queue.Push(snapshot);
}

double ParseDuration(int argc, char* argv[]) {
    double durationSeconds = 30.0;
    for (int index = 1; index + 1 < argc; ++index) {
        if (std::string_view(argv[index]) != "--duration") {
            continue;
        }
        char* end = nullptr;
        const double parsed = std::strtod(argv[index + 1], &end);
        if (end != argv[index + 1] && *end == '\0' && parsed > 0) {
            durationSeconds = parsed;
        }
    }
    return durationSeconds;
}

void PrintEvent(const PenEventSnapshot& event,
                std::chrono::steady_clock::time_point startedAt) {
    const auto elapsed = std::chrono::duration<double>(event.receivedAt - startedAt).count();
    const bool isProximity = event.type == NSEventTypeTabletProximity ||
                             event.subtype == NSEventSubtypeTabletProximity;
    std::cout << std::fixed << std::setprecision(4)
              << (isProximity ? "PROXIMITY" : "PEN")
              << " t=" << elapsed
              << " monitor=" << MonitorName(event.monitor)
              << " type=" << EventTypeName(event.type)
              << " subtype=" << static_cast<long>(event.subtype)
              << " eventTimestamp=" << event.eventTimestamp
              << " eventNumber=" << event.eventNumber;

    if (isProximity) {
        std::cout << " entering=" << (event.enteringProximity ? "true" : "false")
                  << " deviceType=" << DeviceTypeName(event.pointingDeviceType)
                  << " deviceID=" << event.deviceID
                  << " pointingDeviceID=" << event.pointingDeviceID
                  << " systemTabletID=" << event.systemTabletID
                  << " tabletID=" << event.tabletID
                  << " uniqueID=" << event.uniqueID
                  << " vendorID=" << event.vendorID
                  << " vendorType=" << event.vendorPointingDeviceType
                  << " capabilities=0x" << std::hex << event.capabilityMask << std::dec;
    } else {
        std::cout << " absolute=(" << event.absoluteX << ','
                  << event.absoluteY << ',' << event.absoluteZ << ')'
                  << " screen=";
        if (event.hasScreenLocation) {
            std::cout << '(' << event.screenX << ',' << event.screenY << ')';
        } else {
            std::cout << "unavailable";
        }
        std::cout
                  << " pressure=" << event.pressure
                  << " tangentialPressure=" << event.tangentialPressure
                  << " tilt=(" << event.tiltX << ',' << event.tiltY << ')'
                  << " rotation=" << event.rotation
                  << " buttons=0x" << std::hex << event.buttonMask << std::dec
                  << " deviceID=" << event.deviceID;
    }
    std::cout << '\n';
}

NSWindow* CreateProbeWindow() {
    NSScreen* screen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.mainScreen;
    const NSRect visible = screen.visibleFrame;
    const NSRect frame = NSMakeRect(
        NSMidX(visible) - 260,
        NSMidY(visible) - 90,
        520,
        180);
    auto* window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Wacom Pen Probe — local monitor target";
    auto* label = [[NSTextField alloc] initWithFrame:NSInsetRect(window.contentView.bounds, 24, 24)];
    label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    label.stringValue = @"First test the pen over this window (local).\nThen bring Chrome to the front and test again (global).";
    [window.contentView addSubview:label];
    return window;
}

}  // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
        std::cout.setf(std::ios::unitbuf);
        std::signal(SIGINT, HandleSignal);
        std::signal(SIGTERM, HandleSignal);
        const double durationSeconds = ParseDuration(argc, argv);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow* window = CreateProbeWindow();
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        ProbeContext contextStorage;
        ProbeContext* context = &contextStorage;
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

        id globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                                                  handler:^(NSEvent* event) {
            CaptureEvent(event, MonitorSource::Global, *context);
        }];
        id localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                                handler:^NSEvent* (NSEvent* event) {
            CaptureEvent(event, MonitorSource::Local, *context);
            return event;
        }];

        if (globalMonitor == nil || localMonitor == nil) {
            std::cerr << "FATAL monitor registration failed global="
                      << (globalMonitor != nil) << " local=" << (localMonitor != nil) << '\n';
            if (globalMonitor != nil) [NSEvent removeMonitor:globalMonitor];
            if (localMonitor != nil) [NSEvent removeMonitor:localMonitor];
            return 2;
        }

        const auto startedAt = std::chrono::steady_clock::now();
        std::thread consumer([&] {
            PenEventSnapshot event;
            while (context->queue.Pop(event)) {
                PrintEvent(event, startedAt);
            }
        });

        std::cout << "Wacom macOS pen probe\n"
                  << "duration=" << durationSeconds << "s globalMonitor=true localMonitor=true\n"
                  << "READY use pen over the probe window, then bring Chrome to front\n";

        const auto deadline = startedAt + std::chrono::duration<double>(durationSeconds);
        while (!gStopRequested.load(std::memory_order_relaxed) &&
               std::chrono::steady_clock::now() < deadline) {
            @autoreleasepool {
                NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                   untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
                                                      inMode:NSDefaultRunLoopMode
                                                     dequeue:YES];
                if (event != nil) {
                    [NSApp sendEvent:event];
                }
            }
        }

        [NSEvent removeMonitor:globalMonitor];
        [NSEvent removeMonitor:localMonitor];
        context->queue.Stop();
        consumer.join();
        [window orderOut:nil];

        const auto localCount = context->localEvents.load(std::memory_order_relaxed);
        const auto globalCount = context->globalEvents.load(std::memory_order_relaxed);
        std::cout << "SUMMARY local=" << localCount
                  << " global=" << globalCount
                  << " point=" << context->pointEvents.load(std::memory_order_relaxed)
                  << " proximity=" << context->proximityEvents.load(std::memory_order_relaxed)
                  << " tabletSubtype=" << context->tabletSubtypeEvents.load(std::memory_order_relaxed)
                  << " queueDropped=" << context->queue.Dropped()
                  << '\n';
        return globalCount > 0 && localCount > 0 ? 0 : 4;
    }
}
