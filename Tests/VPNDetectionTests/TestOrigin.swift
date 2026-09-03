import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A throwaway HTTP origin, so the redirect the download endpoint answers with
/// is exercised by the real transport rather than by a stub that cannot follow
/// anything.
///
/// An answer may promise a `Content-Length` far larger than the bytes it writes
/// and then never finish the response. A client that followed the redirect and
/// read the body would wait forever rather than merely be slow, which is the
/// point: the failure being guarded against is a multi-gigabyte transfer.
final class TestOrigin: Sendable {
    struct Answer: Sendable {
        var status: HTTPResponseStatus = .ok
        var headers: [(String, String)] = []
        var body: [UInt8] = []
        /// Leave false to stall after the body, promising more that never comes.
        var complete: Bool = true
    }

    let port: Int
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let log: RequestLog

    var receivedPaths: [String] { log.paths }

    static func start(_ answer: @escaping @Sendable (String) -> Answer) async throws -> TestOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = RequestLog()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Handler(answer: answer, log: log))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return TestOrigin(channel: channel, group: group, log: log)
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup, log: RequestLog) {
        self.channel = channel
        self.group = group
        self.log = log
        self.port = channel.localAddress?.port ?? 0
    }

    // A lock rather than an actor so a request is recorded BEFORE the response
    // is written; an actor would record it in a detached task, and an assertion
    // made the instant the client returns could beat it.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var paths: [String] {
            lock.withLock { storage }
        }

        func record(_ path: String) {
            lock.withLock { storage.append(path) }
        }
    }

    // Event-loop confined, which is the contract NIO handlers have always had
    // and which predates Sendable.
    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let answer: @Sendable (String) -> Answer
        private let log: RequestLog
        private var uri = "/"

        init(answer: @escaping @Sendable (String) -> Answer, log: RequestLog) {
            self.answer = answer
            self.log = log
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                uri = head.uri
            case .body:
                break
            case .end:
                respond(context: context)
            }
        }

        private func respond(context: ChannelHandlerContext) {
            let path = uri
            log.record(path)

            let answer = answer(path)
            var headers = HTTPHeaders()
            for (name, value) in answer.headers {
                headers.add(name: name, value: value)
            }
            let head = HTTPResponseHead(version: .http1_1, status: answer.status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !answer.body.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: answer.body.count)
                buffer.writeBytes(answer.body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            if answer.complete {
                context.write(wrapOutboundOut(.end(nil)), promise: nil)
            }
            context.flush()
        }
    }
}

extension TestOrigin.Answer {
    static func redirect(to location: String) -> Self {
        .init(status: .found, headers: [("Location", location), ("Content-Length", "0")])
    }

    /// Promises a gigabyte, writes sixteen bytes, and never ends the response.
    static var neverEndingGigabyte: Self {
        .init(
            status: .ok,
            headers: [("Content-Type", "application/octet-stream"), ("Content-Length", "1073741824")],
            body: Array(repeating: 0, count: 16),
            complete: false,
        )
    }
}
