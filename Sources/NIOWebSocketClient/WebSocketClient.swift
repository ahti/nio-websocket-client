import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOWebSocket

public enum WebSocketClientError: Error {
    case alreadyShutdown
}

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
    case createNew
}

extension HTTPRequestEncoder: RemovableChannelHandler { }

public final class WebSocketClient {
    public struct Configuration {
        public var maxFrameSize: Int
        public init(maxFrameSize: Int = 1 << 14) {
            self.maxFrameSize = maxFrameSize
        }
    }

    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: Configuration
    let isShutdown = Atomic<Bool>(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = .init()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.group = group
        case .createNew:
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
    }

    public func connect(
        host: String,
        port: Int,
        uri: String = "/",
        headers: HTTPHeaders = [:],
        onUpgrade: @escaping (Socket) -> ()
    ) -> EventLoopFuture<Void> {
        let bootstrap = ClientBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let httpEncoder = HTTPRequestEncoder()
                let httpDecoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                let webSocketUpgrader = WebSocketClientUpgradeHandler(maxFrameSize: self.configuration.maxFrameSize) { channel, response in
                    let webSocket = Socket(channel: channel)
                    return channel.pipeline.removeHandler(httpEncoder).flatMap {
                        return channel.pipeline.removeHandler(httpDecoder)
                    }.flatMap {
                        return channel.pipeline.addWebSocket(webSocket)
                    }.map {
                        onUpgrade(webSocket)
                    }
                }
                return channel.pipeline.addHandlers([httpEncoder, httpDecoder, webSocketUpgrader])
            }

        return bootstrap.connect(host: host, port: port)
            .flatMap { $0.closeFuture }
    }


    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            self.isShutdown.store(true)
            return
        case .createNew:
            if self.isShutdown.compareAndExchange(expected: false, desired: true) {
                try self.group.syncShutdownGracefully()
            } else {
                throw WebSocketClientError.alreadyShutdown
            }
        }
    }

    deinit {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            assert(self.isShutdown.load(), "WebSocketClient not shutdown before deinit.")
        }
    }
}

internal final class WebSocketClientUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let maxFrameSize: Int
    private let upgradePipelineHandler: (Channel, HTTPResponseHead) -> EventLoopFuture<Void>

    private enum State {
        case ready
        case awaitingResponseEnd(HTTPResponseHead)
    }

    private var state: State

    init(
        maxFrameSize: Int,
        upgradePipelineHandler: @escaping (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    ) {
        self.maxFrameSize = maxFrameSize
        self.upgradePipelineHandler = upgradePipelineHandler
        self.state = .ready
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .head(let head):
            self.state = .awaitingResponseEnd(head)
        case .body:
            // ignore bodies
            break
        case .end:
            switch self.state {
            case .awaitingResponseEnd(let head):
                #warning("TODO: don't ignore future result")
                _ = self.upgrade(context: context, upgradeResponse: head)
            case .ready:
                fatalError("Invalid response state")
            }
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let request = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: .GET, uri: "/",
            headers: self.buildUpgradeRequest()
        )
        context.write(self.wrapOutboundOut(.head(request)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }

    func buildUpgradeRequest() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "connection", value: "Upgrade")
        headers.add(name: "upgrade", value: "websocket")
        headers.add(name: "origin", value: "vapor/websocket")
        headers.add(name: "host", value: "echo.websocket.org")
        headers.add(name: "sec-websocket-version", value: "13")
        let bytes: [UInt8]  = [
            .random, .random, .random, .random,
            .random, .random, .random, .random,
            .random, .random, .random, .random,
            .random, .random, .random, .random
        ]
        headers.add(name: "sec-websocket-key", value: Data(bytes).base64EncodedString())
        return headers
    }

    func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        return context.channel.pipeline.addHandlers([
            WebSocketFrameEncoder(),
            ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: self.maxFrameSize))
        ], position: .first).flatMap {
            return context.pipeline.removeHandler(self)
        }.flatMap {
            return self.upgradePipelineHandler(context.channel, upgradeResponse)
        }
    }
}
