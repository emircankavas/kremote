import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A minimal WinRM client: enough to ask a Windows host for its load.
///
/// Deliberately narrow — one command, one reply. A full WSMan implementation is
/// thousands of lines and none of it is needed here: no shells, no uploads, no
/// subscriptions.
///
/// **The transport is a raw socket on purpose.** WinRM binds its NTLM challenge to
/// the TCP connection that received it: answering on a fresh connection is refused
/// with 401 even when the message is byte-identical to one that works. `URLSession`
/// offers no way to pin a connection across two requests, so the handshake is done
/// over one socket, by hand. That single fact cost several wrong diagnoses —
/// including two that blamed the NTLM message, which was correct all along.
public struct WinRMClient: Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        /// `false` for the default 5985, `true` for 5986.
        public var useTLS: Bool
        public var timeout: TimeInterval

        public init(
            host: String,
            port: Int = 5985,
            username: String,
            password: String,
            useTLS: Bool = false,
            timeout: TimeInterval = 12
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.useTLS = useTLS
            self.timeout = timeout
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Runs a PowerShell expression and returns its stdout.
    public func runPowerShell(_ script: String) async throws -> String {
        let encoded = (script.data(using: .utf16LittleEndian) ?? Data()).base64EncodedString()
        let command = "powershell -NoProfile -NonInteractive -EncodedCommand \(encoded)"
        return try await run(command: command)
    }

    /// Runs one command through a WinRS shell.
    ///
    /// WSMan is stateful: `Command` returns a `ShellId` and a `CommandId`, and the
    /// output only arrives through `Receive` against that shell. Sending the command
    /// and expecting the answer in one reply is refused with "requires the following
    /// selector: ShellId" — which is exactly what a one-shot SOAP request does.
    ///
    /// The shell is closed afterwards so nothing accumulates on the server.
    public func run(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.runSync(command: command))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSync(command: String) throws -> String {
        let connection = try WinRMConnection(
            host: configuration.host,
            port: configuration.port,
            timeout: configuration.timeout,
            useTLS: configuration.useTLS
        )
        defer { connection.close() }

        var session = try WinRMSession(
            connection: connection,
            configuration: configuration,
            timeoutSeconds: Int(configuration.timeout)
        )
        try session.authenticate()

        let shellID = try session.createShell()
        defer { try? session.deleteShell(shellID) }

        let commandID = try session.start(command: command, shellID: shellID)
        return try session.receiveOutput(shellID: shellID, commandID: commandID)
    }

    /// True when the host answers WinRM at all. Used to decide whether to show a
    /// badge, so an unreachable host costs one short attempt and nothing else.
    public func isReachable() async -> Bool {
        do {
            _ = try await runPowerShell("'ok'")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Handshake

    static func splitIdentity(_ username: String) -> (domain: String, user: String) {
        if let slash = username.firstIndex(of: "\\") {
            return (String(username[..<slash]), String(username[username.index(after: slash)...]))
        }
        if let at = username.firstIndex(of: "@") {
            return (String(username[username.index(after: at)...]), String(username[..<at]))
        }
        return ("", username)
    }

    /// The base64 challenge out of a `WWW-Authenticate` header.
    ///
    /// The header can list several schemes separated by commas, so only the token
    /// after the word `Negotiate` is taken.
    static func challenge(in headers: String) -> Data? {
        for line in headers.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("www-authenticate:") else { continue }
            let value = String(line.dropFirst("www-authenticate:".count))
            for part in value.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("negotiate") else { continue }
                let token = trimmed.dropFirst("Negotiate".count).trimmingCharacters(in: .whitespaces)
                if let data = Data(base64Encoded: token), data.count >= 48 { return data }
            }
        }
        return nil
    }

    // MARK: - SOAP

    /// A WSMan `Command` request: run one command, no shell, no input.
    static func commandEnvelope(command: String, timeoutSeconds: Int) -> String {
        let escaped = command
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
                    xmlns:rsp="http://schemas.microsoft.com/wbem/wsman/1/windows/shell">
          <s:Header>
            <wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>
            <wsman:ResourceURI s:mustUnderstand="true">http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd</wsman:ResourceURI>
            <wsa:Action s:mustUnderstand="true">http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Command</wsa:Action>
            <wsman:MaxEnvelopeSize s:mustUnderstand="true">153600</wsman:MaxEnvelopeSize>
            <wsa:ReplyTo>
              <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
            </wsa:ReplyTo>
            <wsman:Locale xml:lang="en-US" s:mustUnderstand="false"/>
            <wsman:Timeout>PT\(timeoutSeconds)S</wsman:Timeout>
          </s:Header>
          <s:Body>
            <rsp:CommandLine>
              <rsp:Command>\(escaped)</rsp:Command>
            </rsp:CommandLine>
          </s:Body>
        </s:Envelope>
        """
    }

    /// The stdout text out of a WSMan response.
    ///
    /// WSMan wraps command output in base64 inside `<rsp:Stream Name="stdout">`, and
    /// splits a long line across several elements, so they are concatenated.
    static func commandOutput(from data: Data) throws -> String {
        let xml = String(decoding: data, as: UTF8.self)
        guard !xml.isEmpty else {
            throw WinRMError.unreachable("The server returned an empty response.")
        }

        var collected = Data()
        var searchRange = xml.startIndex..<xml.endIndex
        while let open = xml.range(of: "<rsp:Stream", range: searchRange) {
            guard let headerEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
                  let close = xml.range(of: "</rsp:Stream>", range: headerEnd.upperBound..<xml.endIndex) else {
                break
            }
            let header = xml[open.upperBound..<headerEnd.lowerBound]
            searchRange = close.upperBound..<xml.endIndex
            // stderr streams carry error text, which is not part of the answer.
            if header.contains("Name=\"stderr\"") { continue }
            let payload = xml[headerEnd.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let chunk = Data(base64Encoded: payload) { collected.append(chunk) }
        }

        if collected.isEmpty {
            if xml.contains("<s:Fault") || xml.contains("faultcode") {
                throw WinRMError.commandFailed(Self.faultMessage(in: xml))
            }
            throw WinRMError.commandFailed("The server returned no output.")
        }
        return String(decoding: collected, as: UTF8.self)
    }

    static func faultMessage(in xml: String) -> String {
        for tag in ["f:Message", "s:Text", "Message"] {
            if let start = xml.range(of: "<\(tag)>"),
               let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) {
                let message = xml[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty { return String(message.prefix(300)) }
            }
        }
        return "The server rejected the command."
    }

    static func describe(status: Int, body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("<s:Fault") || text.contains("faultcode") {
            return faultMessage(in: text)
        }
        switch status {
        case 404: return "WinRM is not listening at that address."
        case 500: return "The server reported an error."
        default: return "The server answered with HTTP \(status)."
        }
    }
}

public enum WinRMError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case authenticationFailed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return detail
        case .authenticationFailed(let detail): return detail
        case .commandFailed(let detail): return detail
        }
    }
}
