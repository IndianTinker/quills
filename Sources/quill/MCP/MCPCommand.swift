import ArgumentParser
import Foundation

/// Run the local, read-only, multi-client MCP server. The menu-bar app owns
/// this process during normal use; the command is also available for testing.
struct MCPServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the local read-only MCP server."
    )

    @Option(name: .long, help: "Loopback TCP port (default: 47777).")
    var port: Int?

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Option(name: .long, help: "Parent process ID to monitor when owned by the menu-bar app.")
    var parentPID: Int32?

    func run() async throws {
        let selectedPort = port ?? Config.mcpPort()
        guard (1024...65535).contains(selectedPort) else {
            throw ValidationError("port must be between 1024 and 65535")
        }
        try await QuillMCPServer(
            root: Config.resolveRoot(cliOverride: out),
            port: selectedPort
        ).run(parentPID: parentPID)
    }
}
