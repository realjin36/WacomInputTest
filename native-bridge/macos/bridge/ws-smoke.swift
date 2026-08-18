import Darwin
import Foundation

@main
struct WebSocketSmokeTest {
    static func main() async {
        let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8765 : 8765
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        do {
            let message = try await task.receive()
            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let value):
                text = String(decoding: value, as: UTF8.self)
            @unknown default:
                throw SmokeError.invalidHello
            }

            guard let data = text.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "bridge.hello",
                  (json["protocolVersion"] as? NSNumber)?.intValue == 2,
                  let status = json["status"] as? [String: Any],
                  let native = status["native"] as? [String: Any],
                  native["touchReady"] as? Bool == true,
                  native["penReady"] as? Bool == true else {
                throw SmokeError.invalidHello
            }

            try await task.send(.string("{\"type\":\"bridge.activate\",\"generation\":1}"))
            task.cancel(with: .normalClosure, reason: nil)
            print("websocket=ok protocolVersion=2 hello=ok")
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            FileHandle.standardError.write(Data("WebSocket smoke test failed: \(error)\n".utf8))
            exit(2)
        }
    }

    enum SmokeError: Error {
        case invalidHello
    }
}
