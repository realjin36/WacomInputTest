#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

constexpr std::size_t kMaxContactsPerFrame = 32;

enum class NativeEventKind {
    TouchFrame,
    PenPacket,
    PenProximity,
};

enum class CommonTouchState {
    None,
    Down,
    Hold,
    Up,
};

enum class PointingDeviceKind {
    Unknown,
    Pen,
    Cursor,
    Eraser,
};

struct TouchContactSnapshot {
    int id = 0;
    CommonTouchState state = CommonTouchState::None;
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
    std::uint16_t sensitivity = 0;
    float orientation = 0;
    bool confidence = false;
};

struct TouchFrameSnapshot {
    std::uint32_t frameNumber = 0;
    std::size_t contactCount = 0;
    std::array<TouchContactSnapshot, kMaxContactsPerFrame> contacts{};
};

struct PenPacketSnapshot {
    std::uint64_t serial = 0;
    double eventTimestamp = 0;
    double absoluteX = 0;
    double absoluteY = 0;
    double absoluteZ = 0;
    double screenX = 0;
    double screenY = 0;
    bool hasScreenLocation = false;
    double pressure = 0;
    double tangentialPressure = 0;
    double tiltX = 0;
    double tiltY = 0;
    double rotation = 0;
    std::uint64_t buttons = 0;
    PointingDeviceKind pointingDevice = PointingDeviceKind::Unknown;
    std::uint64_t uniqueId = 0;
};

struct PenProximitySnapshot {
    bool entering = false;
    PointingDeviceKind pointingDevice = PointingDeviceKind::Unknown;
    std::uint64_t pointingDeviceId = 0;
    std::uint64_t systemTabletId = 0;
    std::uint64_t tabletId = 0;
    std::uint64_t uniqueId = 0;
    std::uint64_t vendorId = 0;
    std::uint64_t vendorPointingDeviceType = 0;
    std::uint64_t capabilityMask = 0;
};

struct NativeInputEvent {
    std::uint64_t sequence = 0;
    std::int64_t timestampUs = 0;
    NativeEventKind kind = NativeEventKind::TouchFrame;
    int deviceId = 0;
    TouchFrameSnapshot touch;
    PenPacketSnapshot pen;
    PenProximitySnapshot proximity;
};

struct TouchDeviceInfo {
    int deviceId = 0;
    std::string type;
    float logicalOriginX = 0;
    float logicalOriginY = 0;
    float logicalWidth = 0;
    float logicalHeight = 0;
    float physicalSizeX = 0;
    float physicalSizeY = 0;
    int reportedSizeX = 0;
    int reportedSizeY = 0;
    int fingerMax = 0;
    int scanSizeX = 0;
    int scanSizeY = 0;
    bool rawAvailable = false;
    bool blobAvailable = false;
    bool sensitivityAvailable = false;
};

struct NativeStatusSnapshot {
    bool touchReady = false;
    bool penReady = false;
    std::vector<TouchDeviceInfo> touchDevices;
    bool penHardwareProximity = false;
    PointingDeviceKind pointingDevice = PointingDeviceKind::Unknown;
    std::uint64_t penUniqueId = 0;
    std::uint64_t producedEvents = 0;
    std::uint64_t droppedInputEvents = 0;
    std::uint64_t touchFrames = 0;
    std::uint64_t touchContacts = 0;
    std::uint64_t truncatedTouchFrames = 0;
    std::uint64_t penPackets = 0;
    std::uint64_t proximityMessages = 0;
    std::uint64_t penLocalEvents = 0;
    std::uint64_t penGlobalEvents = 0;
    std::uint64_t deduplicatedPenEvents = 0;
};
