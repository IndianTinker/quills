import Foundation

/// A paste-ready guide using the running app's configuration rather than defaults.
enum MCPConnectionDetails {
    static func text(port: Int, root: URL, state: MCPServerState) -> String {
        let status: String
        switch state {
        case .running: status = "running (at time of copy)"
        case .starting: status = "starting; wait for the menu to show running"
        case .stopped: status = "stopped; choose Start MCP server in the Quills menu"
        case .failed(let error): status = "failed (\(error)); restart MCP from the Quills menu"
        }
        return """
        Use Quills MCP to answer questions about my locally recorded meetings.

        Connection
        - Server name: Quills
        - Endpoint: http://127.0.0.1:\(port)/mcp
        - Host: 127.0.0.1; port: \(port)
        - Transport: MCP Streamable HTTP, stateful sessions (not stdio).
        - Authentication: none; loopback only. The MCP client must run on this Mac.
        - Server status: \(status).
        - Recordings folder: \(root.path)
        - Port config: mcp_port in ~/.config/quill/config.json; this endpoint uses the app's current port.

        Connect your MCP client to that URL. If already connected, use its Quills tools directly.
        If writing an HTTP client, perform MCP initialize, send notifications/initialized,
        and retain the returned Mcp-Session-Id for subsequent requests. Use the negotiated
        MCP protocol version and Accept: application/json, text/event-stream.
        This is an MCP endpoint, not a REST API. There is no /health route or /tools route.

        Available read-only tools (arguments are JSON objects)
        - get_status {}: recording and pause state, transcription progress, queue, and MCP endpoint.
        - list_meetings {"limit":10}: newest meetings first; returns id, started, ended,
          durationSeconds, status, transcriptAvailable. Default limit 50, maximum 200.
        - search_transcripts {"query":"topic","limit":10}: case-insensitive literal substring
          search; returns meeting_id, speaker, start_ms, end_ms, text. Query is required.
          Default limit 50, maximum 200. Use short distinctive phrases, not natural-language questions.
        - get_transcript {"meeting_id":"<id from list_meetings or search_transcripts>"}:
          complete transcript with engine, model, created_at, and timed segments.
          Speakers: me = microphone, them = system audio. Times are milliseconds.

        Resources
        - quills://status (application/json)
        - quills://meetings/{meeting_id}/transcript (application/json)

        Fast workflow
        - Latest meeting: list_meetings with a small limit, then get_transcript for the
          first relevant meeting with transcriptAvailable=true.
        - Topic question: search_transcripts with a short keyword, then get_transcript
          only for relevant hits if more context is needed. Cite meeting IDs and timestamps.
        - Missing transcript: check get_status and the meeting status; queued/failed meetings
          may not have a transcript yet. A live recording is not listed until stopped.
        - Read tool results from MCP content text as JSON. Use these tools rather than
          scanning the filesystem, probing ports, guessing URLs, or fetching all transcripts.
        - MCP cannot start, stop, pause, edit, or delete recordings. If the connection is
          unavailable, report it and ask me to check the Quills MCP menu status.
        """
    }
}
