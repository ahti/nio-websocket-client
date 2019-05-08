import NIO
import NIOWebSocket

extension WebSocketClient {
    /// Represents a client connected via WebSocket protocol.
    /// Use this to receive text/data frames and send responses.
    ///
    ///      ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///      }
    ///
    public final class Socket {
        public var eventLoop: EventLoop {
            return channel.eventLoop
        }

        /// Outbound `WebSocketEventHandler`.
        private let channel: Channel

        /// See `onText(...)`.
        var onTextCallback: (Socket, String) -> ()

        /// See `onBinary(...)`.
        var onBinaryCallback: (Socket, [UInt8]) -> ()

        /// See `onError(...)`.
        var onErrorCallback: (Socket, Error) -> ()

        /// See `onCloseCode(...)`.
        var onCloseCodeCallback: (WebSocketErrorCode) -> ()

        /// Creates a new `WebSocket` using the supplied `Channel` and `Mode`.
        /// Use `httpProtocolUpgrader(...)` to create a protocol upgrader that can create `WebSocket`s.
        init(channel: Channel) {
            self.channel = channel
            self.onTextCallback = { _, _ in }
            self.onBinaryCallback = { _, _ in }
            self.onErrorCallback = { _, _ in }
            self.onCloseCodeCallback = { _ in }
        }

        // MARK: Receive
        /// Adds a callback to this `WebSocket` to receive text-formatted messages.
        ///
        ///     ws.onText { ws, string in
        ///         ws.send(string.reversed())
        ///     }
        ///
        /// Use `onBinary(_:)` to handle binary-formatted messages.
        ///
        /// - parameters:
        ///     - callback: Closure to accept incoming text-formatted data.
        ///                 This will be called every time the connected client sends text.
        public func onText(_ callback: @escaping (Socket, String) -> ()) {
            self.onTextCallback = callback
        }

        /// Adds a callback to this `WebSocket` to receive binary-formatted messages.
        ///
        ///     ws.onBinary { ws, data in
        ///         print(data)
        ///     }
        ///
        /// Use `onText(_:)` to handle text-formatted messages.
        ///
        /// - parameters:
        ///     - callback: Closure to accept incoming binary-formatted data.
        ///                 This will be called every time the connected client sends binary-data.
        public func onBinary(_ callback: @escaping (Socket, [UInt8]) -> ()) {
            self.onBinaryCallback = callback
        }

        /// Adds a callback to this `WebSocket` to handle errors.
        ///
        ///     ws.onError { ws, error in
        ///         print(error)
        ///     }
        ///
        /// - parameters:
        ///     - callback: Closure to handle error's caught during this connection.
        public func onError(_ callback: @escaping (Socket, Error) -> ()) {
            self.onErrorCallback = callback
        }

        /// Adds a callback to this `WebSocket` to handle incoming close codes.
        ///
        ///     ws.onCloseCode { closeCode in
        ///         print(closeCode)
        ///     }
        ///
        /// - parameters:
        ///     - callback: Closure to handle received close codes.
        public func onCloseCode(_ callback: @escaping (WebSocketErrorCode) -> ()) {
            self.onCloseCodeCallback = callback
        }

        // MARK: Send
        /// Sends text-formatted data to the connected client.
        ///
        ///     ws.onText { ws, string in
        ///         ws.send(string.reversed())
        ///     }
        ///
        /// - parameters:
        ///     - text: `String` to send as text-formatted data to the client.
        ///     - promise: Optional `Promise` to complete when the send is finished.
        public func send<S>(text: S, promise: EventLoopPromise<Void>? = nil) where S: Collection, S.Element == Character {
            let string = String(text)
            var buffer = channel.allocator.buffer(capacity: text.count)
            buffer.writeString(string)
            self.send(buffer, opcode: .text, fin: true, promise: promise)

        }

        /// Sends binary-formatted data to the connected client.
        ///
        ///     ws.onText { ws, string in
        ///         ws.send([0x68, 0x69])
        ///     }
        ///
        /// - parameters:
        ///     - text: `Data` to send as binary-formatted data to the client.
        ///     - promise: Optional `Promise` to complete when the send is finished.
        public func send(binary: [UInt8], promise: EventLoopPromise<Void>? = nil) {
            self.send(raw: binary, opcode: .binary, promise: promise)
        }

        /// Sends raw-data to the connected client using the supplied WebSocket opcode.
        ///
        ///     // client will receive "Hello, world!" as one message
        ///     ws.send(raw: "Hello, ", opcode: .text, fin: false)
        ///     ws.send(raw: "world", opcode: .continuation, fin: false)
        ///     ws.send(raw: "!", opcode: .continuation)
        ///
        /// - parameters:
        ///     - data: `LosslessDataConvertible` to send to the client.
        ///     - opcode: `WebSocketOpcode` indicating data format. Usually `.text` or `.binary`.
        ///     - fin: If `false`, additional `.continuation` frames are expected.
        ///     - promise: Optional `Promise` to complete when the send is finished.
        public func send(raw data: [UInt8], opcode: WebSocketOpcode, fin: Bool = true, promise: EventLoopPromise<Void>? = nil) {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            self.send(buffer, opcode: opcode, fin: fin, promise: promise)
        }
        
        /// `true` if the `WebSocket` has been closed.
        public var isClosed: Bool {
            return !self.channel.isActive
        }

        /// A `Future` that will be completed when the `WebSocket` closes.
        public var onClose: EventLoopFuture<Void> {
            return self.channel.closeFuture
        }

        public func close(code: WebSocketErrorCode? = nil) -> EventLoopFuture<Void> {
            let promise = self.eventLoop.makePromise(of: Void.self)
            self.close(code: code, promise: promise)
            return promise.futureResult
        }

        public func close(code: WebSocketErrorCode? = nil, promise: EventLoopPromise<Void>?) {
            guard !self.isClosed else {
                promise?.succeed(())
                return
            }
            if let code = code {
                self.sendClose(code: code)
            }
            self.channel.close(mode: .all, promise: promise)
        }

        // MARK: Private

        internal func makeMaskKey() -> WebSocketMaskingKey? {
            return WebSocketMaskingKey([.random, .random, .random, .random])
        }

        private func sendClose(code: WebSocketErrorCode) {
            var buffer = channel.allocator.buffer(capacity: 2)
            buffer.write(webSocketErrorCode: code)
            send(buffer, opcode: .connectionClose, fin: true, promise: nil)
        }

        /// Private send that accepts a raw `WebSocketFrame`.
        private func send(_ buffer: ByteBuffer, opcode: WebSocketOpcode, fin: Bool, promise: EventLoopPromise<Void>?) {
            guard !self.isClosed else { return }
            let frame = WebSocketFrame(
                fin: fin,
                opcode: opcode,
                maskKey: self.makeMaskKey(),
                data: buffer
            )
            self.channel.writeAndFlush(frame, promise: promise)
        }

        deinit {
            assert(self.isClosed, "WebSocket was not closed before deinit.")
        }
    }
}
