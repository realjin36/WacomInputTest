#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include "LocalServer.h"
#include "NativeInputSource.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

namespace {

struct Options {
    std::uint16_t port = 8765;
    std::optional<double> durationSeconds;
    bool showWindow = true;
};

std::atomic<bool> gStopRequested{false};

void HandleSignal(int) {
    gStopRequested.store(true, std::memory_order_relaxed);
}

Options ParseOptions(int argc, char* argv[]) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--duration" && index + 1 < argc) {
            char* end = nullptr;
            const double parsed = std::strtod(argv[++index], &end);
            if (end != argv[index] && *end == '\0' && parsed > 0) {
                options.durationSeconds = parsed;
            }
        } else if (argument == "--port" && index + 1 < argc) {
            char* end = nullptr;
            const long parsed = std::strtol(argv[++index], &end, 10);
            if (end != argv[index] && *end == '\0' && parsed > 0 && parsed <= 65535) {
                options.port = static_cast<std::uint16_t>(parsed);
            }
        } else if (argument == "--no-window") {
            options.showWindow = false;
        }
    }
    return options;
}

}  // namespace

@interface FeedbackButton : NSButton
@property(nonatomic, strong) NSColor* normalBackgroundColor;
@property(nonatomic, strong) NSColor* hoverBackgroundColor;
@property(nonatomic, strong) NSColor* pressedBackgroundColor;
@property(nonatomic, strong) NSTrackingArea* hoverTrackingArea;
- (void)applyNormalBackground;
@end

@implementation FeedbackButton

- (void)applyBackgroundColor:(NSColor*)color {
    self.layer.backgroundColor = color.CGColor;
}

- (void)applyNormalBackground {
    [self applyBackgroundColor:self.normalBackgroundColor];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea != nil) {
        [self removeTrackingArea:self.hoverTrackingArea];
    }
    self.hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}

- (void)mouseEntered:(NSEvent*)event {
    (void)event;
    if (self.enabled) [self applyBackgroundColor:self.hoverBackgroundColor];
}

- (void)mouseExited:(NSEvent*)event {
    (void)event;
    if (self.enabled) [self applyNormalBackground];
}

- (void)mouseDown:(NSEvent*)event {
    if (self.enabled) [self applyBackgroundColor:self.pressedBackgroundColor];
    [super mouseDown:event];
    if (!self.enabled) return;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds)) {
        [self applyBackgroundColor:self.hoverBackgroundColor];
    } else {
        [self applyNormalBackground];
    }
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alphaValue = enabled ? 1 : 0.55;
}

@end

@interface BridgeWindowController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSTextField* statusLabel;
@property(nonatomic, strong) NSTextField* touchDot;
@property(nonatomic, strong) NSTextField* touchLabel;
@property(nonatomic, strong) NSTextField* penDot;
@property(nonatomic, strong) NSTextField* penLabel;
@property(nonatomic, strong) NSTextField* metricsLabel;
@property(nonatomic, strong) FeedbackButton* quitButton;
- (instancetype)init;
- (void)updateNativeStatus:(const NativeStatusSnapshot&)nativeStatus
              serverStatus:(const ServerStatusSnapshot&)serverStatus;
@end

@implementation BridgeWindowController

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    const NSRect frame = NSMakeRect(0, 0, 360, 252);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"Wacom Native Input Bridge";
    self.window.backgroundColor = NSColor.whiteColor;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;

    NSBox* statusPanel = [[NSBox alloc] initWithFrame:NSMakeRect(24, 88, 312, 140)];
    statusPanel.boxType = NSBoxCustom;
    statusPanel.titlePosition = NSNoTitle;
    statusPanel.borderColor = [NSColor colorWithWhite:0.88 alpha:1];
    statusPanel.borderWidth = 1;
    statusPanel.cornerRadius = 10;
    statusPanel.fillColor = [NSColor colorWithWhite:0.98 alpha:1];
    [self.window.contentView addSubview:statusPanel];

    self.statusLabel = [NSTextField labelWithString:@"앱 시작 중…"];
    self.statusLabel.frame = NSMakeRect(20, 96, 272, 22);
    self.statusLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [statusPanel.contentView addSubview:self.statusLabel];

    self.touchDot = [NSTextField labelWithString:@"●"];
    self.touchDot.frame = NSMakeRect(20, 65, 14, 20);
    self.touchDot.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    self.touchDot.textColor = NSColor.systemGrayColor;
    [statusPanel.contentView addSubview:self.touchDot];

    self.touchLabel = [NSTextField labelWithString:@"터치 확인 중"];
    self.touchLabel.frame = NSMakeRect(38, 65, 108, 20);
    self.touchLabel.font = [NSFont systemFontOfSize:13];
    [statusPanel.contentView addSubview:self.touchLabel];

    self.penDot = [NSTextField labelWithString:@"●"];
    self.penDot.frame = NSMakeRect(164, 65, 14, 20);
    self.penDot.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    self.penDot.textColor = NSColor.systemGrayColor;
    [statusPanel.contentView addSubview:self.penDot];

    self.penLabel = [NSTextField labelWithString:@"펜 확인 중"];
    self.penLabel.frame = NSMakeRect(182, 65, 108, 20);
    self.penLabel.font = [NSFont systemFontOfSize:13];
    [statusPanel.contentView addSubview:self.penLabel];

    self.metricsLabel = [NSTextField labelWithString:@"이벤트 0  ·  클라이언트 0\n누락: 입력 0  ·  전송 0"];
    self.metricsLabel.frame = NSMakeRect(20, 16, 272, 38);
    self.metricsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.metricsLabel.textColor = NSColor.secondaryLabelColor;
    self.metricsLabel.maximumNumberOfLines = 2;
    [statusPanel.contentView addSubview:self.metricsLabel];

    self.quitButton = [[FeedbackButton alloc] initWithFrame:NSMakeRect(24, 24, 312, 48)];
    self.quitButton.title = @"종료";
    self.quitButton.bordered = NO;
    self.quitButton.wantsLayer = YES;
    self.quitButton.layer.cornerRadius = 10;
    self.quitButton.normalBackgroundColor = [NSColor colorWithSRGBRed:0.78 green:0.31 blue:0.33 alpha:1];
    self.quitButton.hoverBackgroundColor = [NSColor colorWithSRGBRed:0.83 green:0.36 blue:0.38 alpha:1];
    self.quitButton.pressedBackgroundColor = [NSColor colorWithSRGBRed:0.68 green:0.24 blue:0.27 alpha:1];
    [self.quitButton applyNormalBackground];
    self.quitButton.contentTintColor = NSColor.whiteColor;
    self.quitButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    self.quitButton.keyEquivalent = @"q";
    self.quitButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.quitButton.target = self;
    self.quitButton.action = @selector(requestQuit:);
    [self.window.contentView addSubview:self.quitButton];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    return self;
}

- (void)updateNativeStatus:(const NativeStatusSnapshot&)nativeStatus
              serverStatus:(const ServerStatusSnapshot&)serverStatus {
    self.statusLabel.stringValue = @"앱 실행 중";
    self.touchDot.textColor = nativeStatus.touchReady ? NSColor.systemGreenColor : NSColor.systemRedColor;
    self.touchLabel.stringValue = nativeStatus.touchReady ? @"터치 연결됨" : @"터치 연결 오류";
    self.penDot.textColor = nativeStatus.penReady ? NSColor.systemGreenColor : NSColor.systemRedColor;
    self.penLabel.stringValue = nativeStatus.penReady ? @"펜 연결됨" : @"펜 연결 오류";
    self.metricsLabel.stringValue = [NSString stringWithFormat:
        @"이벤트 %llu  ·  클라이언트 %llu\n누락: 입력 %llu  ·  전송 %llu",
        static_cast<unsigned long long>(nativeStatus.producedEvents),
        static_cast<unsigned long long>(serverStatus.webSocketClients),
        static_cast<unsigned long long>(nativeStatus.droppedInputEvents),
        static_cast<unsigned long long>(serverStatus.droppedClientMessages)];
}

- (void)requestQuit:(id)sender {
    (void)sender;
    self.statusLabel.stringValue = @"종료 중…";
    self.touchDot.textColor = NSColor.systemGrayColor;
    self.penDot.textColor = NSColor.systemGrayColor;
    self.quitButton.enabled = NO;
    gStopRequested.store(true, std::memory_order_relaxed);
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    [self requestQuit:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    [self requestQuit:nil];
    return NSTerminateCancel;
}

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        std::cout.setf(std::ios::unitbuf);
        std::signal(SIGINT, HandleSignal);
        std::signal(SIGTERM, HandleSignal);
        const Options options = ParseOptions(argc, argv);

        NativeInputSource input;
        const bool allInputReady = input.Start();
        LocalServer server(input, options.port);
        if (!server.Start()) {
            input.Stop();
            return 3;
        }

        const auto initialStatus = input.Status();
        std::cout << "Wacom macOS local bridge\n"
                  << "HTTP=http://127.0.0.1:" << options.port << '\n'
                  << "WebSocket=ws://127.0.0.1:" << options.port << "/ws\n"
                  << "protocolVersion=2 touchReady=" << initialStatus.touchReady
                  << " penReady=" << initialStatus.penReady << '\n';

        BridgeWindowController* windowController = nil;
        if (options.showWindow) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            windowController = [[BridgeWindowController alloc] init];
            NSApp.delegate = windowController;
            [windowController updateNativeStatus:initialStatus serverStatus:server.Status()];
            [NSApp activateIgnoringOtherApps:YES];
        }

        const auto startedAt = std::chrono::steady_clock::now();
        auto nextStatusUpdate = startedAt;
        while (!gStopRequested.load(std::memory_order_relaxed)) {
            if (options.durationSeconds.has_value() &&
                std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count() >=
                    *options.durationSeconds) {
                break;
            }
            input.PumpAppEvent(0.02);
            const auto now = std::chrono::steady_clock::now();
            if (windowController != nil && now >= nextStatusUpdate) {
                [windowController updateNativeStatus:input.Status() serverStatus:server.Status()];
                nextStatusUpdate = now + std::chrono::milliseconds(250);
            }
        }

        const auto nativeStatus = input.Status();
        const auto serverStatus = server.Status();
        input.Stop();
        server.Stop();

        std::cout << "SUMMARY produced=" << nativeStatus.producedEvents
                  << " touchFrames=" << nativeStatus.touchFrames
                  << " touchContacts=" << nativeStatus.touchContacts
                  << " penPackets=" << nativeStatus.penPackets
                  << " proximity=" << nativeStatus.proximityMessages
                  << " inputDropped=" << nativeStatus.droppedInputEvents
                  << " truncatedTouchFrames=" << nativeStatus.truncatedTouchFrames
                  << " deduplicatedPen=" << nativeStatus.deduplicatedPenEvents
                  << " broadcast=" << serverStatus.broadcastEvents
                  << " clientDropped=" << serverStatus.droppedClientMessages << '\n';
        return allInputReady ? 0 : 2;
    }
}
