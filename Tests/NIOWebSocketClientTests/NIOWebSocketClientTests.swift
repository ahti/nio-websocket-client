import XCTest
@testable import NIOWebSocketClient

final class NIOWebSocketClientTests: XCTestCase {
    func testExample() throws {
        let client = WebSocketClient(eventLoopGroupProvider: .createNew)
        defer { try! client.syncShutdown() }

        try client.connect(host: "echo.websocket.org", port: 80) { webSocket in
            webSocket.send(text: "Hello")
            webSocket.onText { webSocket, string in
                print(string)
                XCTAssertEqual(string, "Hello")
                webSocket.close(promise: nil)
            }
        }.wait()
    }
    
    public func testActivityExample() throws {
        let configuration = WebSocketClient.Configuration(tlsConfiguration: .forClient())
        let client = WebSocketClient(eventLoopGroupProvider: .createNew, configuration: configuration)
        defer { try! client.syncShutdown() }
        try client.connect(
            host: "api-activity.v2.vapor.cloud",
            port: 443,
            uri: "echo-test"
        ) { webSocket in
            var count = 0
            webSocket.send(text: "Hello")
            webSocket.onText { webSocket, string in
                count += 1
                guard count > 5 else {
                    sleep(2)
                    webSocket.send(text: "ayo \(count)")
                    return
                }
                webSocket.close(promise: nil)
            }
        }.wait()
    }
}
