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
}
