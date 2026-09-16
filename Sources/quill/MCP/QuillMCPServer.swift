import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// Read-only MCP server for local Quill data. The HTTP multiplexer creates a
/// separate MCP Server/transport pair for every MCP session, allowing multiple
/// clients to connect at once without sharing request IDs or session state.
struct QuillMCPServer {
    let root: URL
    let port: Int

    func run() async throws {
        let router = MCPHTTPRouter(store: QuillMCPStore(root: root), port: port)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(router: router))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        FileHandle.standardError.write(Data(
            "quill MCP up · http://127.0.0.1:\(port)/mcp · read-only\n".utf8
        ))

        do {
            try await channel.closeFuture.get()
        } catch {
            await router.shutdown()
            try? await group.shutdownGracefully()
            throw error
        }

        await router.shutdown()
        try await group.shutdownGracefully()
    }
}

/// Owns the per-client stateful MCP sessions. StatefulHTTPServerTransport is
/// deliberately scoped to one session; this actor is the multi-client layer.
private actor MCPHTTPRouter {
    private let store: QuillMCPStore
    private let port: Int
    private var sessions: [String: MCPClientSession] = [:]

    init(store: QuillMCPStore, port: Int) {
        self.store = store
        self.port = port
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == nil || request.path == "/mcp" else {
            return .error(statusCode: 404, .invalidRequest("Not Found"))
        }

        if let sessionID = request.header(HTTPHeaderName.sessionID) {
            guard let session = sessions[sessionID] else {
                return .error(statusCode: 404, .invalidRequest("Unknown MCP session"))
            }
            let response = await session.handle(request)
            if request.method.uppercased() == "DELETE" {
                sessions.removeValue(forKey: sessionID)
                await session.stop()
            }
            return response
        }

        guard request.method.uppercased() == "POST", isInitialize(request.body) else {
            return .error(statusCode: 400, .invalidRequest("MCP session is required"))
        }

        do {
            let session = try await MCPClientSession(store: store, port: port)
            let response = await session.handle(request)
            guard let sessionID = response.headers[HTTPHeaderName.sessionID] else {
                await session.stop()
                return .error(statusCode: 500, .internalError("MCP session was not initialized"))
            }
            sessions[sessionID] = session
            return response
        } catch {
            return .error(statusCode: 500, .internalError(error.localizedDescription))
        }
    }

    func shutdown() async {
        let active = sessions.values
        sessions.removeAll()
        for session in active {
            await session.stop()
        }
    }

    private func isInitialize(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return object["method"] as? String == "initialize"
    }
}

private actor MCPClientSession {
    private let server: Server
    private let transport: StatefulHTTPServerTransport
    private let port: Int

    init(store: QuillMCPStore, port: Int) async throws {
        self.port = port
        transport = StatefulHTTPServerTransport()
        server = Server(
            name: "Quill",
            version: "0.1.0",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        let tools = Self.tools
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await Self.call(params, store: store, port: port)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "quill-status",
                    uri: "quill://status",
                    title: "Quill status",
                    description: "Current local Quill and MCP server status.",
                    mimeType: "application/json"
                )
            ])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: [
                Resource.Template(
                    uriTemplate: "quill://meetings/{meeting_id}/transcript",
                    name: "meeting-transcript",
                    title: "Meeting transcript",
                    description: "Canonical transcript for a local Quill meeting.",
                    mimeType: "application/json"
                )
            ])
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard let resource = store.resourceText(uri: params.uri, mcpPort: port) else {
                throw MCPError.invalidParams("Unknown or unavailable resource")
            }
            return ReadResource.Result(contents: [
                Resource.Content.text(resource.text, uri: params.uri, mimeType: resource.mimeType)
            ])
        }

        try await server.start(transport: transport)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        await transport.handleRequest(request)
    }

    func stop() async {
        await server.stop()
    }

    private static let readOnlyAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static let tools: [Tool] = [
        Tool(
            name: "get_status",
            title: "Get Quill status",
            description: "Read local Quill recording/transcription status and this MCP server's loopback endpoint.",
            inputSchema: .object(["type": .string("object")]),
            annotations: readOnlyAnnotations
        ),
        Tool(
            name: "list_meetings",
            title: "List meetings",
            description: "List local Quill meetings by newest first. Returns metadata only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum meetings to return; default 50, maximum 200.")
                    ])
                ])
            ]),
            annotations: readOnlyAnnotations
        ),
        Tool(
            name: "search_transcripts",
            title: "Search transcripts",
            description: "Search local Quill transcript text and return timestamped snippets.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Text to search for.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum snippets to return; default 50, maximum 200.")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: readOnlyAnnotations
        ),
        Tool(
            name: "get_transcript",
            title: "Get transcript",
            description: "Read one complete local Quill transcript by meeting ID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "meeting_id": .object([
                        "type": .string("string"),
                        "description": .string("Meeting folder name, for example 2026.09.15-1601.")
                    ])
                ]),
                "required": .array([.string("meeting_id")])
            ]),
            annotations: readOnlyAnnotations
        )
    ]

    private static func call(
        _ params: CallTool.Parameters,
        store: QuillMCPStore,
        port: Int
    ) async throws -> CallTool.Result {
        let output: String
        switch params.name {
        case "get_status":
            output = try encode(store.statusSnapshot(mcpPort: port))
        case "list_meetings":
            let limit = boundedInt(params.arguments?["limit"]?.intValue, default: 50)
            output = try encode(store.listMeetings(limit: limit))
        case "search_transcripts":
            guard let query = params.arguments?["query"]?.stringValue else {
                throw MCPError.invalidParams("query is required")
            }
            let limit = boundedInt(params.arguments?["limit"]?.intValue, default: 50)
            output = try encode(store.search(query: query, limit: limit))
        case "get_transcript":
            guard let id = params.arguments?["meeting_id"]?.stringValue else {
                throw MCPError.invalidParams("meeting_id is required")
            }
            guard let transcript = store.readTranscript(id: id) else {
                throw MCPError.invalidParams("Transcript not found")
            }
            output = try encode(transcript)
        default:
            throw MCPError.methodNotFound(params.name)
        }

        return CallTool.Result(content: [.text(text: output, annotations: nil, _meta: nil)])
    }

    private static func boundedInt(_ value: Int?, default defaultValue: Int) -> Int {
        min(max(value ?? defaultValue, 1), 200)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: MCPHTTPRouter
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(router: MCPHTTPRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
        case .body(var buffer):
            body.writeBuffer(&buffer)
        case .end:
            guard let head else { return }
            let request = HTTPRequest(
                method: head.method.rawValue,
                headers: Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name, $0.value) }),
                body: body.readBytes(length: body.readableBytes).map { Data($0) },
                path: head.uri.split(separator: "?", maxSplits: 1).first.map(String.init)
            )
            self.head = nil
            self.body.clear()

            let router = self.router
            let writer = MCPHTTPResponseWriter(context: context)
            Task {
                let response = await router.handle(request)
                await writer.write(response)
            }
        }
    }
}

private final class MCPHTTPResponseWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext

    init(context: ChannelHandlerContext) {
        self.context = context
    }

    func write(_ response: HTTPResponse) async {
        switch response {
        case .stream(let stream, let responseHeaders):
            var headers = HTTPHeaders()
            for (name, value) in responseHeaders { headers.add(name: name, value: value) }
            headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            headers.remove(name: "Content-Length")
            try? await writePart(.head(.init(
                version: .http1_1,
                status: HTTPResponseStatus(statusCode: response.statusCode),
                headers: headers
            )))
            do {
                for try await data in stream {
                    try await writeData(data, flush: true)
                }
                try await writePart(.end(nil), flush: true)
            } catch {
                context.eventLoop.execute { self.context.close(promise: nil) }
            }
        default:
            let data = response.bodyData ?? Data()
            var headers = HTTPHeaders()
            for (name, value) in response.headers { headers.add(name: name, value: value) }
            headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
            try? await writePart(.head(.init(
                version: .http1_1,
                status: HTTPResponseStatus(statusCode: response.statusCode),
                headers: headers
            )))
            if !data.isEmpty {
                try? await writeData(data)
            }
            try? await writePart(.end(nil), flush: true)
        }
    }

    private func writePart(
        _ part: HTTPServerResponsePart,
        flush: Bool = false
    ) async throws {
        try await context.eventLoop.submit {
            if flush {
                self.context.writeAndFlush(NIOAny(part), promise: nil)
            } else {
                self.context.write(NIOAny(part), promise: nil)
            }
        }.get()
    }

    private func writeData(_ data: Data, flush: Bool = false) async throws {
        try await context.eventLoop.submit {
            var buffer = self.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let part = HTTPServerResponsePart.body(.byteBuffer(buffer))
            if flush {
                self.context.writeAndFlush(NIOAny(part), promise: nil)
            } else {
                self.context.write(NIOAny(part), promise: nil)
            }
        }.get()
    }
}
