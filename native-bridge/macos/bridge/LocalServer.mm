#import <Foundation/Foundation.h>

#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include "BoundedQueue.h"
#include "BridgeTypes.h"
#include "LocalServer.h"
#include "NativeInputSource.h"
#include "OriginPolicy.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <locale>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr std::size_t kClientQueueCapacity = 1'024;
constexpr std::size_t kMaxHttpHeaderBytes = 16'384;
constexpr std::size_t kMaxClientMessageBytes = 4'096;
constexpr std::string_view kWebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

std::string Lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::string Trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

std::string Base64(const unsigned char* bytes, std::size_t length) {
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string output;
    output.reserve(((length + 2) / 3) * 4);
    for (std::size_t index = 0; index < length; index += 3) {
        const std::uint32_t first = bytes[index];
        const std::uint32_t second = index + 1 < length ? bytes[index + 1] : 0;
        const std::uint32_t third = index + 2 < length ? bytes[index + 2] : 0;
        const std::uint32_t value = (first << 16) | (second << 8) | third;
        output.push_back(alphabet[(value >> 18) & 0x3f]);
        output.push_back(alphabet[(value >> 12) & 0x3f]);
        output.push_back(index + 1 < length ? alphabet[(value >> 6) & 0x3f] : '=');
        output.push_back(index + 2 < length ? alphabet[value & 0x3f] : '=');
    }
    return output;
}

std::string WebSocketAccept(std::string_view key) {
    std::string source(key);
    source.append(kWebSocketGuid);
    std::array<unsigned char, CC_SHA1_DIGEST_LENGTH> digest{};
    CC_SHA1(source.data(), static_cast<CC_LONG>(source.size()), digest.data());
    return Base64(digest.data(), digest.size());
}

bool SendAll(int socket, const void* bytes, std::size_t length) {
    const auto* cursor = static_cast<const std::uint8_t*>(bytes);
    while (length > 0) {
        const ssize_t written = send(socket, cursor, length, 0);
        if (written > 0) {
            cursor += written;
            length -= static_cast<std::size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

bool ReceiveExact(int socket, void* bytes, std::size_t length) {
    auto* cursor = static_cast<std::uint8_t*>(bytes);
    while (length > 0) {
        const ssize_t received = recv(socket, cursor, length, 0);
        if (received > 0) {
            cursor += received;
            length -= static_cast<std::size_t>(received);
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

std::string JsonEscape(std::string_view value) {
    std::string output;
    output.reserve(value.size() + 8);
    for (const unsigned char character : value) {
        switch (character) {
            case '"': output += "\\\""; break;
            case '\\': output += "\\\\"; break;
            case '\b': output += "\\b"; break;
            case '\f': output += "\\f"; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default:
                if (character < 0x20) {
                    static constexpr char hex[] = "0123456789abcdef";
                    output += "\\u00";
                    output.push_back(hex[(character >> 4) & 0xf]);
                    output.push_back(hex[character & 0xf]);
                } else {
                    output.push_back(static_cast<char>(character));
                }
        }
    }
    return output;
}

const char* CommonStateName(CommonTouchState state) {
    switch (state) {
        case CommonTouchState::None: return "none";
        case CommonTouchState::Down: return "down";
        case CommonTouchState::Hold: return "hold";
        case CommonTouchState::Up: return "up";
    }
    return "none";
}

const char* LegacyStateName(CommonTouchState state) {
    switch (state) {
        case CommonTouchState::None: return "WMTFingerStateNone";
        case CommonTouchState::Down: return "WMTFingerStateDown";
        case CommonTouchState::Hold: return "WMTFingerStateHold";
        case CommonTouchState::Up: return "WMTFingerStateUp";
    }
    return "WMTFingerStateNone";
}

const char* PointingDeviceName(PointingDeviceKind kind) {
    switch (kind) {
        case PointingDeviceKind::Pen: return "pen";
        case PointingDeviceKind::Cursor: return "cursor";
        case PointingDeviceKind::Eraser: return "eraser";
        case PointingDeviceKind::Unknown: return "unknown";
    }
    return "unknown";
}

void AppendNumber(std::ostringstream& output, double value) {
    if (std::isfinite(value)) {
        output << std::setprecision(10) << value;
    } else {
        output << "null";
    }
}

std::string SerializeEvent(const NativeInputEvent& event) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << "{\"sequence\":" << event.sequence
           << ",\"timestampUs\":" << event.timestampUs;

    if (event.kind == NativeEventKind::TouchFrame) {
        output << ",\"source\":\"wacommt\",\"type\":\"touch.frame\",\"deviceId\":"
               << event.deviceId << ",\"touch\":{\"frameNumber\":" << event.touch.frameNumber
               << ",\"contacts\":[";
        for (std::size_t index = 0; index < event.touch.contactCount; ++index) {
            if (index != 0) output << ',';
            const auto& contact = event.touch.contacts[index];
            output << "{\"id\":" << contact.id
                   << ",\"state\":\"" << LegacyStateName(contact.state)
                   << "\",\"commonState\":\"" << CommonStateName(contact.state)
                   << "\",\"x\":";
            AppendNumber(output, contact.x);
            output << ",\"y\":";
            AppendNumber(output, contact.y);
            output << ",\"width\":";
            AppendNumber(output, contact.width);
            output << ",\"height\":";
            AppendNumber(output, contact.height);
            output << ",\"sensitivity\":" << contact.sensitivity
                   << ",\"orientation\":";
            AppendNumber(output, contact.orientation);
            output << ",\"confidence\":" << (contact.confidence ? "true" : "false") << '}';
        }
        output << "]}}";
        return output.str();
    }

    if (event.kind == NativeEventKind::PenProximity) {
        const auto& proximity = event.proximity;
        output << ",\"source\":\"appkit\",\"type\":\"pen.proximity\",\"deviceId\":"
               << event.deviceId << ",\"proximity\":{\"hardware\":"
               << (proximity.entering ? "true" : "false")
               << ",\"context\":" << (proximity.entering ? "true" : "false")
               << ",\"entering\":" << (proximity.entering ? "true" : "false")
               << ",\"pointingDeviceType\":\"" << PointingDeviceName(proximity.pointingDevice)
               << "\",\"pointingDeviceId\":" << proximity.pointingDeviceId
               << ",\"systemTabletId\":" << proximity.systemTabletId
               << ",\"tabletId\":" << proximity.tabletId
               << ",\"uniqueId\":" << proximity.uniqueId
               << ",\"vendorId\":" << proximity.vendorId
               << ",\"vendorPointingDeviceType\":" << proximity.vendorPointingDeviceType
               << ",\"capabilityMask\":" << proximity.capabilityMask << "}}";
        return output.str();
    }

    const auto& pen = event.pen;
    const bool eraser = pen.pointingDevice == PointingDeviceKind::Eraser;
    const std::uint64_t cursor = eraser ? 2 : 1;
    const long compatibilityX = std::lround(pen.hasScreenLocation ? pen.screenX : pen.absoluteX);
    const long compatibilityY = std::lround(pen.hasScreenLocation ? pen.screenY : pen.absoluteY);
    const long compatibilityZ = std::lround(pen.absoluteZ);
    const auto compatibilityPressure = static_cast<std::uint32_t>(
        std::lround(std::clamp(pen.pressure, 0.0, 1.0) * 65'535.0));
    output << ",\"source\":\"appkit\",\"type\":\"pen.packet\",\"deviceId\":"
           << event.deviceId << ",\"pen\":{\"serial\":" << pen.serial
           << ",\"cursor\":" << cursor
           << ",\"x\":" << compatibilityX
           << ",\"y\":" << compatibilityY
           << ",\"z\":" << compatibilityZ
           << ",\"pressure\":" << compatibilityPressure
           << ",\"tangentialPressure\":0"
           << ",\"buttons\":" << pen.buttons
           << ",\"azimuth\":0,\"altitude\":0,\"twist\":" << std::lround(pen.rotation * 10.0)
           << ",\"status\":" << (eraser ? 16 : 0)
           << ",\"changed\":0,\"screenX\":";
    AppendNumber(output, pen.screenX);
    output << ",\"screenY\":";
    AppendNumber(output, pen.screenY);
    output << ",\"hasScreenLocation\":" << (pen.hasScreenLocation ? "true" : "false")
           << ",\"absoluteX\":";
    AppendNumber(output, pen.absoluteX);
    output << ",\"absoluteY\":";
    AppendNumber(output, pen.absoluteY);
    output << ",\"absoluteZ\":";
    AppendNumber(output, pen.absoluteZ);
    output << ",\"normalizedPressure\":";
    AppendNumber(output, pen.pressure);
    output << ",\"normalizedTangentialPressure\":";
    AppendNumber(output, pen.tangentialPressure);
    output << ",\"tiltX\":";
    AppendNumber(output, pen.tiltX);
    output << ",\"tiltY\":";
    AppendNumber(output, pen.tiltY);
    output << ",\"rotation\":";
    AppendNumber(output, pen.rotation);
    output << ",\"tipDown\":" << ((pen.buttons & 1) != 0 ? "true" : "false")
           << ",\"pointingDeviceType\":\"" << PointingDeviceName(pen.pointingDevice)
           << "\",\"uniqueId\":" << pen.uniqueId
           << ",\"eventTimestamp\":";
    AppendNumber(output, pen.eventTimestamp);
    output << "}}";
    return output.str();
}

struct HttpRequest {
    std::string method;
    std::string path;
    std::unordered_map<std::string, std::string> headers;
};

bool ReadHttpRequest(int socket, HttpRequest& request) {
    std::string data;
    data.reserve(2048);
    std::array<char, 2048> buffer{};
    while (data.find("\r\n\r\n") == std::string::npos) {
        const ssize_t received = recv(socket, buffer.data(), buffer.size(), 0);
        if (received <= 0) return false;
        data.append(buffer.data(), static_cast<std::size_t>(received));
        if (data.size() > kMaxHttpHeaderBytes) return false;
    }

    std::istringstream stream(data.substr(0, data.find("\r\n\r\n")));
    stream.imbue(std::locale::classic());
    std::string line;
    if (!std::getline(stream, line)) return false;
    line = Trim(line);
    std::istringstream firstLine(line);
    std::string version;
    if (!(firstLine >> request.method >> request.path >> version)) return false;
    const auto query = request.path.find('?');
    if (query != std::string::npos) request.path.resize(query);

    while (std::getline(stream, line)) {
        line = Trim(line);
        if (line.empty()) continue;
        const auto separator = line.find(':');
        if (separator == std::string::npos) continue;
        request.headers[Lower(Trim(line.substr(0, separator)))] = Trim(line.substr(separator + 1));
    }
    return true;
}

}  // namespace

struct LocalServer::Impl {
    struct Client;

    Impl(NativeInputSource& source, std::uint16_t serverPort,
         std::vector<std::string> origins)
        : input(source), port(serverPort), allowedOrigins(std::move(origins)) {}

    NativeInputSource& input;
    std::uint16_t port;
    std::vector<std::string> allowedOrigins;
    std::atomic<bool> stopping{false};
    int listener = -1;
    std::thread acceptThread;
    std::thread pumpThread;
    mutable std::mutex clientsMutex;
    std::unordered_map<std::uint64_t, std::shared_ptr<Client>> clients;
    std::atomic<std::uint64_t> nextClientId{0};
    std::atomic<std::uint64_t> broadcastEvents{0};
    std::atomic<std::uint64_t> droppedClientMessages{0};
    std::mutex connectionThreadsMutex;
    std::vector<std::thread> connectionThreads;

    struct Client : std::enable_shared_from_this<Client> {
        Client(Impl& owner, std::uint64_t clientId, int clientSocket)
            : server(owner), id(clientId), socket(clientSocket), outgoing(kClientQueueCapacity) {}

        Impl& server;
        std::uint64_t id;
        int socket;
        BoundedQueue<std::string> outgoing;
        std::atomic<bool> stopped{false};
        std::atomic<bool> active{false};
        std::mutex sendMutex;

        void Enqueue(const std::string& payload) {
            const auto before = outgoing.Dropped();
            outgoing.Push(payload);
            const auto after = outgoing.Dropped();
            if (after > before) {
                server.droppedClientMessages.fetch_add(after - before, std::memory_order_relaxed);
            }
        }

        bool SendFrame(std::uint8_t opcode, std::string_view payload) {
            std::lock_guard lock(sendMutex);
            std::array<std::uint8_t, 10> header{};
            std::size_t headerLength = 2;
            header[0] = static_cast<std::uint8_t>(0x80 | opcode);
            if (payload.size() <= 125) {
                header[1] = static_cast<std::uint8_t>(payload.size());
            } else if (payload.size() <= 0xffff) {
                header[1] = 126;
                header[2] = static_cast<std::uint8_t>((payload.size() >> 8) & 0xff);
                header[3] = static_cast<std::uint8_t>(payload.size() & 0xff);
                headerLength = 4;
            } else {
                header[1] = 127;
                const std::uint64_t size = payload.size();
                for (int index = 0; index < 8; ++index) {
                    header[2 + index] = static_cast<std::uint8_t>(size >> (56 - index * 8));
                }
                headerLength = 10;
            }
            return SendAll(socket, header.data(), headerLength) &&
                   SendAll(socket, payload.data(), payload.size());
        }

        void Stop() {
            if (stopped.exchange(true, std::memory_order_acq_rel)) return;
            active.store(false, std::memory_order_release);
            outgoing.Stop();
            shutdown(socket, SHUT_RDWR);
        }

        void ReceiveLoop() {
            while (!stopped.load(std::memory_order_acquire)) {
                std::array<std::uint8_t, 2> header{};
                if (!ReceiveExact(socket, header.data(), header.size())) break;
                const std::uint8_t opcode = header[0] & 0x0f;
                const bool masked = (header[1] & 0x80) != 0;
                std::uint64_t length = header[1] & 0x7f;
                if (length == 126) {
                    std::array<std::uint8_t, 2> extended{};
                    if (!ReceiveExact(socket, extended.data(), extended.size())) break;
                    length = (static_cast<std::uint64_t>(extended[0]) << 8) | extended[1];
                } else if (length == 127) {
                    std::array<std::uint8_t, 8> extended{};
                    if (!ReceiveExact(socket, extended.data(), extended.size())) break;
                    length = 0;
                    for (const auto byte : extended) length = (length << 8) | byte;
                }
                if (length > kMaxClientMessageBytes) break;

                std::array<std::uint8_t, 4> mask{};
                if (masked && !ReceiveExact(socket, mask.data(), mask.size())) break;
                std::string payload(static_cast<std::size_t>(length), '\0');
                if (length > 0 && !ReceiveExact(socket, payload.data(), payload.size())) break;
                if (masked) {
                    for (std::size_t index = 0; index < payload.size(); ++index) {
                        payload[index] ^= static_cast<char>(mask[index % mask.size()]);
                    }
                }

                if (opcode == 0x8) break;
                if (opcode == 0x9) {
                    if (!SendFrame(0xA, payload)) break;
                    continue;
                }
                if (opcode != 0x1) continue;
                if (payload.find("\"type\":\"bridge.activate\"") != std::string::npos ||
                    payload.find("\"type\": \"bridge.activate\"") != std::string::npos) {
                    active.store(true, std::memory_order_release);
                } else if (payload.find("\"type\":\"bridge.deactivate\"") != std::string::npos ||
                           payload.find("\"type\": \"bridge.deactivate\"") != std::string::npos) {
                    active.store(false, std::memory_order_release);
                }
            }
            Stop();
        }

        void Run() {
            server.AddClient(shared_from_this());
            Enqueue(server.HelloJson());
            std::thread receiver([self = shared_from_this()] { self->ReceiveLoop(); });
            std::string payload;
            while (outgoing.Pop(payload)) {
                if (!SendFrame(0x1, payload)) {
                    Stop();
                    break;
                }
            }
            Stop();
            if (receiver.joinable()) receiver.join();
            server.RemoveClient(id);
            close(socket);
        }
    };

    void AddClient(const std::shared_ptr<Client>& client) {
        std::lock_guard lock(clientsMutex);
        clients[client->id] = client;
    }

    void RemoveClient(std::uint64_t id) {
        std::lock_guard lock(clientsMutex);
        clients.erase(id);
    }

    ServerStatusSnapshot ServerStatus() const {
        ServerStatusSnapshot status;
        std::lock_guard lock(clientsMutex);
        status.webSocketClients = clients.size();
        for (const auto& [id, client] : clients) {
            (void)id;
            if (client->active.load(std::memory_order_acquire)) ++status.activeBrowserClients;
        }
        status.broadcastEvents = broadcastEvents.load(std::memory_order_relaxed);
        status.droppedClientMessages = droppedClientMessages.load(std::memory_order_relaxed);
        return status;
    }

    std::string NativeStatusJson() const {
        const auto native = input.Status();
        const auto server = ServerStatus();
        std::ostringstream output;
        output.imbue(std::locale::classic());
        output << "{\"platform\":\"macos\",\"touchReady\":" << (native.touchReady ? "true" : "false")
               << ",\"penReady\":" << (native.penReady ? "true" : "false")
               << ",\"touchDevices\":[";
        for (std::size_t index = 0; index < native.touchDevices.size(); ++index) {
            if (index != 0) output << ',';
            const auto& device = native.touchDevices[index];
            output << "{\"deviceId\":" << device.deviceId
                   << ",\"type\":\"" << JsonEscape(device.type)
                   << "\",\"logicalOriginX\":";
            AppendNumber(output, device.logicalOriginX);
            output << ",\"logicalOriginY\":";
            AppendNumber(output, device.logicalOriginY);
            output << ",\"logicalWidth\":";
            AppendNumber(output, device.logicalWidth);
            output << ",\"logicalHeight\":";
            AppendNumber(output, device.logicalHeight);
            output << ",\"physicalSizeX\":";
            AppendNumber(output, device.physicalSizeX);
            output << ",\"physicalSizeY\":";
            AppendNumber(output, device.physicalSizeY);
            output << ",\"reportedSizeX\":" << device.reportedSizeX
                   << ",\"reportedSizeY\":" << device.reportedSizeY
                   << ",\"fingerMax\":" << device.fingerMax
                   << ",\"scanSizeX\":" << device.scanSizeX
                   << ",\"scanSizeY\":" << device.scanSizeY
                   << ",\"rawAvailable\":" << (device.rawAvailable ? "true" : "false")
                   << ",\"blobAvailable\":" << (device.blobAvailable ? "true" : "false")
                   << ",\"sensitivityAvailable\":" << (device.sensitivityAvailable ? "true" : "false")
                   << '}';
        }
        output << ']';

        if (!native.touchDevices.empty()) {
            const auto& device = native.touchDevices.front();
            output << ",\"penX\":{\"min\":";
            AppendNumber(output, device.logicalOriginX);
            output << ",\"max\":";
            AppendNumber(output, device.logicalOriginX + device.logicalWidth);
            output << "},\"penY\":{\"min\":";
            AppendNumber(output, device.logicalOriginY);
            output << ",\"max\":";
            AppendNumber(output, device.logicalOriginY + device.logicalHeight);
            output << "},\"wintabX\":{\"min\":";
            AppendNumber(output, device.logicalOriginX);
            output << ",\"max\":";
            AppendNumber(output, device.logicalOriginX + device.logicalWidth);
            output << "},\"wintabY\":{\"min\":";
            AppendNumber(output, device.logicalOriginY);
            output << ",\"max\":";
            AppendNumber(output, device.logicalOriginY + device.logicalHeight);
            output << '}';
        } else {
            output << ",\"penX\":null,\"penY\":null,\"wintabX\":null,\"wintabY\":null";
        }

        output << ",\"touchCoordinateSpace\":\"core-graphics-global-logical\""
               << ",\"penCoordinateSpace\":\"core-graphics-global-logical\""
               << ",\"penMaxPressure\":1,\"wintabDeviceCount\":" << (native.penReady ? 1 : 0)
               << ",\"wintabDeviceInfo\":\"AppKit NSEvent\",\"wintabMaxPressure\":65535"
               << ",\"wintabTiltSupported\":true,\"wintabContextStatus\":0"
               << ",\"penHardwareProximity\":" << (native.penHardwareProximity ? "true" : "false")
               << ",\"penContextProximity\":" << (native.penHardwareProximity ? "true" : "false")
               << ",\"pointingDeviceType\":\"" << PointingDeviceName(native.pointingDevice)
               << "\",\"penUniqueId\":" << native.penUniqueId
               << ",\"wintabOverlapMessages\":0,\"wintabPromotionAttempts\":0"
               << ",\"wintabPromotionSuccesses\":0,\"wintabClientActivations\":0"
               << ",\"wintabClientDeactivations\":0,\"wintabActivationPromotionRuns\":0"
               << ",\"wintabPromotionSkips\":0,\"activeBrowserClients\":" << server.activeBrowserClients
               << ",\"producedEvents\":" << native.producedEvents
               << ",\"droppedInputEvents\":" << native.droppedInputEvents
               << ",\"touchFrames\":" << native.touchFrames
               << ",\"touchContacts\":" << native.touchContacts
               << ",\"truncatedTouchFrames\":" << native.truncatedTouchFrames
               << ",\"penPackets\":" << native.penPackets
               << ",\"proximityMessages\":" << native.proximityMessages
               << ",\"penLocalEvents\":" << native.penLocalEvents
               << ",\"penGlobalEvents\":" << native.penGlobalEvents
               << ",\"deduplicatedPenEvents\":" << native.deduplicatedPenEvents
               << '}';
        return output.str();
    }

    std::string StatusJson() const {
        const auto server = ServerStatus();
        std::ostringstream output;
        output << "{\"protocolVersion\":2,\"url\":\"http://127.0.0.1:" << port
               << "\",\"native\":" << NativeStatusJson()
               << ",\"webSocketClients\":" << server.webSocketClients
               << ",\"broadcastEvents\":" << server.broadcastEvents
               << ",\"droppedClientMessages\":" << server.droppedClientMessages << '}';
        return output.str();
    }

    std::string HelloJson() const {
        return "{\"type\":\"bridge.hello\",\"protocolVersion\":2,\"status\":" + StatusJson() + '}';
    }

    std::string HealthJson() const {
        const auto status = input.Status();
        std::ostringstream output;
        output << "{\"ok\":" << (status.touchReady && status.penReady ? "true" : "false")
               << ",\"touchReady\":" << (status.touchReady ? "true" : "false")
               << ",\"penReady\":" << (status.penReady ? "true" : "false") << '}';
        return output.str();
    }

    std::string ServiceJson() const {
        return "{\"name\":\"Wacom Native Input Bridge\",\"protocolVersion\":2,"
               "\"health\":\"/health\",\"status\":\"/api/status\",\"webSocket\":\"/ws\"}";
    }

    void Broadcast(const std::string& payload) {
        std::vector<std::shared_ptr<Client>> snapshot;
        {
            std::lock_guard lock(clientsMutex);
            snapshot.reserve(clients.size());
            for (const auto& [id, client] : clients) {
                (void)id;
                snapshot.push_back(client);
            }
        }
        broadcastEvents.fetch_add(1, std::memory_order_relaxed);
        for (const auto& client : snapshot) client->Enqueue(payload);
    }

    void PumpLoop() {
        NativeInputEvent event;
        while (input.Events().Pop(event)) {
            Broadcast(SerializeEvent(event));
        }
    }

    void SendHttp(int socket, int status, std::string_view statusText,
                  std::string_view contentType, std::string_view body,
                  std::string_view corsOrigin = {}, bool preflight = false) {
        std::ostringstream header;
        header << "HTTP/1.1 " << status << ' ' << statusText << "\r\n"
               << "Content-Type: " << contentType << "\r\n"
               << "Content-Length: " << body.size() << "\r\n"
               << "Cache-Control: no-store\r\n";
        if (!corsOrigin.empty()) {
            header << "Access-Control-Allow-Origin: " << corsOrigin << "\r\n"
                   << "Vary: Origin\r\n";
            if (preflight) header << "Access-Control-Allow-Methods: GET\r\n";
        }
        header << "Connection: close\r\n\r\n";
        const std::string headers = header.str();
        SendAll(socket, headers.data(), headers.size());
        SendAll(socket, body.data(), body.size());
    }

    bool UpgradeWebSocket(int socket, const HttpRequest& request) {
        const auto key = request.headers.find("sec-websocket-key");
        const auto upgrade = request.headers.find("upgrade");
        if (key == request.headers.end() || upgrade == request.headers.end() ||
            Lower(upgrade->second) != "websocket") {
            SendHttp(socket, 400, "Bad Request", "text/plain; charset=utf-8", "WebSocket upgrade required");
            return false;
        }
        const std::string accept = WebSocketAccept(key->second);
        const std::string response =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";
        return SendAll(socket, response.data(), response.size());
    }

    void HandleConnection(int socket) {
        @autoreleasepool {
            int noSigPipe = 1;
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            timeval timeout{5, 0};
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

            HttpRequest request;
            if (!ReadHttpRequest(socket, request)) {
                SendHttp(socket, 400, "Bad Request", "text/plain; charset=utf-8", "Bad request");
                close(socket);
                return;
            }

            std::string corsOrigin;
            const auto origin = request.headers.find("origin");
            if (origin != request.headers.end()) {
                if (!BridgeOriginPolicy::IsAllowed(origin->second, allowedOrigins)) {
                    SendHttp(socket, 403, "Forbidden", "text/plain; charset=utf-8", "Origin not allowed");
                    close(socket);
                    return;
                }
                corsOrigin = origin->second;
            }
            if (request.method == "OPTIONS") {
                SendHttp(socket, 204, "No Content", "text/plain; charset=utf-8", "",
                         corsOrigin, true);
                close(socket);
                return;
            }
            if (request.method != "GET") {
                SendHttp(socket, 400, "Bad Request", "text/plain; charset=utf-8", "Bad request",
                         corsOrigin);
                close(socket);
                return;
            }

            if (request.path == "/ws") {
                if (!UpgradeWebSocket(socket, request)) {
                    close(socket);
                    return;
                }
                timeval blocking{0, 0};
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &blocking, sizeof(blocking));
                const auto id = nextClientId.fetch_add(1, std::memory_order_relaxed) + 1;
                std::make_shared<Client>(*this, id, socket)->Run();
                return;
            }

            if (request.path == "/") {
                SendHttp(socket, 200, "OK", "application/json; charset=utf-8", ServiceJson(), corsOrigin);
                close(socket);
                return;
            }
            if (request.path == "/health") {
                SendHttp(socket, 200, "OK", "application/json; charset=utf-8", HealthJson(), corsOrigin);
                close(socket);
                return;
            }
            if (request.path == "/api/status") {
                SendHttp(socket, 200, "OK", "application/json; charset=utf-8", StatusJson(), corsOrigin);
                close(socket);
                return;
            }

            SendHttp(socket, 404, "Not Found", "text/plain; charset=utf-8", "Not found", corsOrigin);
            close(socket);
        }
    }

    void AcceptLoop() {
        while (!stopping.load(std::memory_order_acquire)) {
            sockaddr_in address{};
            socklen_t addressLength = sizeof(address);
            const int socket = accept(listener, reinterpret_cast<sockaddr*>(&address), &addressLength);
            if (socket < 0) {
                if (errno == EINTR) continue;
                if (stopping.load(std::memory_order_acquire)) break;
                continue;
            }
            std::lock_guard lock(connectionThreadsMutex);
            connectionThreads.emplace_back([this, socket] { HandleConnection(socket); });
        }
    }

    bool Start() {
        listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0) {
            std::cerr << "socket failed: " << std::strerror(errno) << '\n';
            return false;
        }
        int reuse = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        int noSigPipe = 1;
        setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
            std::cerr << "bind 127.0.0.1:" << port << " failed: " << std::strerror(errno) << '\n';
            close(listener);
            listener = -1;
            return false;
        }
        if (listen(listener, 64) != 0) {
            std::cerr << "listen failed: " << std::strerror(errno) << '\n';
            close(listener);
            listener = -1;
            return false;
        }
        pumpThread = std::thread([this] { PumpLoop(); });
        acceptThread = std::thread([this] { AcceptLoop(); });
        return true;
    }

    void Stop() {
        if (stopping.exchange(true, std::memory_order_acq_rel)) return;
        if (listener >= 0) {
            shutdown(listener, SHUT_RDWR);
            close(listener);
            listener = -1;
        }
        if (acceptThread.joinable()) acceptThread.join();

        std::vector<std::shared_ptr<Client>> clientSnapshot;
        {
            std::lock_guard lock(clientsMutex);
            for (const auto& [id, client] : clients) {
                (void)id;
                clientSnapshot.push_back(client);
            }
        }
        for (const auto& client : clientSnapshot) client->Stop();

        if (pumpThread.joinable()) pumpThread.join();
        std::vector<std::thread> threads;
        {
            std::lock_guard lock(connectionThreadsMutex);
            threads.swap(connectionThreads);
        }
        for (auto& thread : threads) {
            if (thread.joinable()) thread.join();
        }
    }
};

LocalServer::LocalServer(NativeInputSource& input, std::uint16_t port,
                         std::vector<std::string> allowedOrigins)
    : impl_(std::make_unique<Impl>(input, port, std::move(allowedOrigins))) {}

LocalServer::~LocalServer() {
    Stop();
}

bool LocalServer::Start() {
    return impl_->Start();
}

void LocalServer::Stop() {
    if (impl_) impl_->Stop();
}

ServerStatusSnapshot LocalServer::Status() const {
    return impl_->ServerStatus();
}
