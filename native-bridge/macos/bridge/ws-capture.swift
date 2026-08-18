import Darwin
import Foundation

private struct Summary {
    var hello = false
    var protocolVersion = 0
    var events = 0
    var touchFrames = 0
    var touchContacts = 0
    var maxTouches = 0
    var penPackets = 0
    var positivePressurePackets = 0
    var proximityMessages = 0
    var sequenceGaps = 0
    var firstSequence: Int64 = 0
    var lastSequence: Int64 = 0
    var invalidMessages = 0

    var json: [String: Any] {
        [
            "hello": hello,
            "protocolVersion": protocolVersion,
            "events": events,
            "touchFrames": touchFrames,
            "touchContacts": touchContacts,
            "maxTouches": maxTouches,
            "penPackets": penPackets,
            "positivePressurePackets": positivePressurePackets,
            "proximityMessages": proximityMessages,
            "sequenceGaps": sequenceGaps,
            "firstSequence": firstSequence,
            "lastSequence": lastSequence,
            "invalidMessages": invalidMessages
        ]
    }
}

@main
struct WebSocketCapture {
    static func main() async {
        let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8765 : 8765
        let durationMs = max(1_000, CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 18_000 : 18_000)
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        try? await task.send(.string("{\"type\":\"bridge.activate\",\"generation\":1}"))

        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            task.cancel(with: .goingAway, reason: nil)
        }

        var summary = Summary()
        while true {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let value):
                    text = String(decoding: value, as: UTF8.self)
                @unknown default:
                    summary.invalidMessages += 1
                    continue
                }
                print(text)
                record(text, summary: &summary)
            } catch {
                break
            }
        }
        timeout.cancel()

        if let data = try? JSONSerialization.data(withJSONObject: summary.json, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data("\(text)\n".utf8))
        }

        let passed = summary.hello && summary.protocolVersion == 2 &&
            summary.touchFrames > 0 && summary.penPackets > 0 && summary.proximityMessages > 0 &&
            summary.sequenceGaps == 0 && summary.invalidMessages == 0
        exit(passed ? 0 : 3)
    }

    private static func record(_ text: String, summary: inout Summary) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else {
            summary.invalidMessages += 1
            return
        }

        if type == "bridge.hello" {
            summary.hello = true
            summary.protocolVersion = (message["protocolVersion"] as? NSNumber)?.intValue ?? 0
            guard let status = message["status"] as? [String: Any],
                  let native = status["native"] as? [String: Any],
                  native["touchReady"] as? Bool == true,
                  native["penReady"] as? Bool == true else {
                summary.invalidMessages += 1
                return
            }
            return
        }

        summary.events += 1
        guard let sequence = (message["sequence"] as? NSNumber)?.int64Value else {
            summary.invalidMessages += 1
            return
        }
        if summary.firstSequence == 0 { summary.firstSequence = sequence }
        if summary.lastSequence != 0 && sequence > summary.lastSequence + 1 {
            summary.sequenceGaps += Int(sequence - summary.lastSequence - 1)
        }
        summary.lastSequence = max(summary.lastSequence, sequence)

        switch type {
        case "touch.frame":
            summary.touchFrames += 1
            guard let touch = message["touch"] as? [String: Any],
                  let contacts = touch["contacts"] as? [[String: Any]] else {
                summary.invalidMessages += 1
                return
            }
            summary.touchContacts += contacts.count
            summary.maxTouches = max(summary.maxTouches, contacts.count)
            if contacts.contains(where: {
                $0["state"] as? String == nil || $0["commonState"] as? String == nil ||
                    $0["x"] as? NSNumber == nil
            }) {
                summary.invalidMessages += 1
            }
        case "pen.packet":
            summary.penPackets += 1
            guard let pen = message["pen"] as? [String: Any] else {
                summary.invalidMessages += 1
                return
            }
            if ((pen["normalizedPressure"] as? NSNumber)?.doubleValue ?? 0) > 0 {
                summary.positivePressurePackets += 1
            }
            if pen["screenX"] as? NSNumber == nil || pen["screenY"] as? NSNumber == nil ||
                pen["absoluteX"] as? NSNumber == nil || pen["tiltX"] as? NSNumber == nil ||
                pen["pointingDeviceType"] as? String == nil {
                summary.invalidMessages += 1
            }
        case "pen.proximity":
            summary.proximityMessages += 1
            guard let proximity = message["proximity"] as? [String: Any],
                  proximity["entering"] as? Bool != nil,
                  proximity["pointingDeviceType"] as? String != nil else {
                summary.invalidMessages += 1
                return
            }
        default:
            summary.invalidMessages += 1
        }
    }
}
