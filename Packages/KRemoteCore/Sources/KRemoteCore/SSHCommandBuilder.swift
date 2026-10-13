import Foundation
import Darwin

/// Builds the `ssh` command line (argv) for a connection.
///
/// Kept separate from the session so it can be unit-tested without connecting.
public struct SSHCommandBuilder {
    public var host: String
    public var port: Int
    public var username: String
    /// Empty = let ssh prompt (or use keys/agent/config). Never put a password in argv:
    /// argv is world-readable via `ps`. Passwords are written to the PTY instead.
    public var additionalOptions: [String]

    public init(host: String, port: Int = 22, username: String = "", additionalOptions: [String] = []) {
        self.host = host
        self.port = port
        self.username = username
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
        args += additionalOptions

        let target = username.isEmpty ? host : "\(username)@\(host)"
        args.append(target)
        return args
    }

    /// The destination as a single string, for display.
    public var displayTarget: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }
}
