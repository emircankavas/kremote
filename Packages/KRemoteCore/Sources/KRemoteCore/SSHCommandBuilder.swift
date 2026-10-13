import Foundation
import Darwin

/// Builds the `ssh` command line (argv) for a connection.
///
/// Kept separate from the session so it can be unit-tested without connecting.
public struct SSHCommandBuilder {
    public var host: String
    public var port: Int
    public var username: String
    /// Path to a private key; empty means let ssh pick (config/agent/default keys).
    public var identityFile: String
    /// Command to run on connect instead of an interactive shell.
    public var remoteCommand: String
    public var additionalOptions: [String]

    public init(
        host: String,
        port: Int = 22,
        username: String = "",
        identityFile: String = "",
        remoteCommand: String = "",
        additionalOptions: [String] = []
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.remoteCommand = remoteCommand
        self.additionalOptions = additionalOptions
    }

    public var arguments: [String] {
        var args = ["ssh", "-o", "NumberOfPasswordPrompts=1"]

        // Force a PTY and a predictable terminal type; SwiftTerm emulates xterm-256color.
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive,gssapi-with-mic"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]

        if port > 0, port != 22 {
            args += ["-p", String(port)]
        }
        let key = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            args += ["-i", (key as NSString).expandingTildeInPath]
        }
        args += additionalOptions

        let target = username.isEmpty ? host : "\(username)@\(host)"
        args.append(target)

        // A remote command must come after the destination. Quoting keeps it a
        // single argv entry so ssh hands it to the shell intact.
        let command = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            args.append(command)
        }
        return args
    }

    /// The destination as a single string, for display.
    public var displayTarget: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }
}
