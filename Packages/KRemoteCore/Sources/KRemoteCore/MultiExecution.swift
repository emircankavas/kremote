import Foundation

/// One server's result in a multi-execution run.
public struct MultiExecResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The connection this ran on, so the UI can link back to it.
    public let nodeID: UUID
    public let name: String
    public let host: String
    /// Combined output; empty when the command produced none.
    public let output: String
    /// Non-empty when the run itself failed (unreachable, auth, refused).
    public let error: String
    /// Exit status when the server reported one; nil on connection failure.
    public let exitCode: Int32?
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(),
        nodeID: UUID,
        name: String,
        host: String,
        output: String,
        error: String,
        exitCode: Int32?,
        duration: TimeInterval
    ) {
        self.id = id
        self.nodeID = nodeID
        self.name = name
        self.host = host
        self.output = output
        self.error = error
        self.exitCode = exitCode
        self.duration = duration
    }

    /// Whether this server succeeded, for the summary line.
    public var succeeded: Bool { error.isEmpty && (exitCode ?? 0) == 0 }
}

/// Runs one command on several servers at once.
///
/// Same primitive as everything else that shells into a host: `RemoteShell`, i.e. one
/// `ssh -T` per server with the connection's own key, agent and config. Nothing is
/// shared between servers, so a slow or dead host cannot hold up the others — which
/// is the entire point of the feature and the reason each runs in its own task.
public enum MultiExecution {

    /// Sends `command` to every target and returns one result per target, in the same
    /// order they were given.
    ///
    /// Order is preserved deliberately: a results list that reshuffles as servers
    /// answer is unreadable when the operator is scanning for the one host that
    /// differs.
    public static func run(
        command: String,
        targets: [Target],
        timeout: TimeInterval = 60,
        onResult: (@Sendable (MultiExecResult) -> Void)? = nil
    ) async -> [MultiExecResult] {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return await withTaskGroup(of: (Int, MultiExecResult).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    (index, await runOne(command: command, target: target, timeout: timeout))
                }
            }

            var results = [MultiExecResult?](repeating: nil, count: targets.count)
            for await (index, result) in group {
                results[index] = result
                onResult?(result)
            }
            return results.compactMap { $0 }
        }
    }

    /// One server. Never throws: a failure becomes a result, because a multi-exec run
    /// where one host is down must still report the others.
    static func runOne(
        command: String,
        target: Target,
        timeout: TimeInterval
    ) async -> MultiExecResult {
        let started = Date()
        let shell = RemoteShell(
            host: target.host,
            port: target.port,
            username: target.username,
            identityFile: target.identityFile,
            password: target.password
        )
        do {
            let output = try await shell.run(command, timeout: timeout)
            let text = String(decoding: output.stdout, as: UTF8.self)
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return MultiExecResult(
                nodeID: target.nodeID,
                name: target.name,
                host: target.host,
                output: text,
                // stderr is part of what a command said, not necessarily a failure, so
                // it is appended rather than treated as an error.
                error: "",
                exitCode: 0,
                duration: Date().timeIntervalSince(started)
            ).withStderr(stderr)
        } catch {
            return MultiExecResult(
                nodeID: target.nodeID,
                name: target.name,
                host: target.host,
                output: "",
                error: error.localizedDescription,
                exitCode: nil,
                duration: Date().timeIntervalSince(started)
            )
        }
    }

    /// One server to run on.
    public struct Target: Sendable, Identifiable {
        public let nodeID: UUID
        public let name: String
        public let host: String
        public let port: Int
        public let username: String
        public let identityFile: String
        public let password: String

        public var id: UUID { nodeID }

        public init(
            nodeID: UUID,
            name: String,
            host: String,
            port: Int = 22,
            username: String = "",
            identityFile: String = "",
            password: String = ""
        ) {
            self.nodeID = nodeID
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.identityFile = identityFile
            self.password = password
        }
    }
}

extension MultiExecResult {
    /// Appends stderr to the output, so a command that wrote warnings is not silently
    /// shown as if it had said nothing else.
    func withStderr(_ stderr: String) -> MultiExecResult {
        guard !stderr.isEmpty else { return self }
        let combined = output.isEmpty ? stderr : output + (output.hasSuffix("\n") ? "" : "\n") + stderr
        return MultiExecResult(
            id: id, nodeID: nodeID, name: name, host: host,
            output: combined, error: error, exitCode: exitCode, duration: duration
        )
    }
}
