import Foundation

/// The WSMan conversation over an already-authenticated connection.
///
/// WSMan is stateful and every message is a separate POST: `Command` → `ShellId`,
/// then `Send` runs it, then `Receive` collects the streams. Doing it in one request
/// is refused with "requires the following selector: ShellId".
///
/// Kept as its own type because the HTTP plumbing (`SocketConnection`) is about one
/// connection, and this is about the protocol spoken over it — the split makes both
/// testable on their own.
struct WinRMSession {
    let connection: SocketConnection
    let configuration: WinRMClient.Configuration
    let timeoutSeconds: Int

    private(set) var authenticated = false

    /// The connection's NTLM challenge must be answered on the connection that
    /// issued it — see `WinRMClient`.
    mutating func authenticate() throws {
        let body = Self.identityEnvelope()
        var response = try connection.request(
            path: "/wsman",
            contentType: "application/soap+xml;charset=UTF-8",
            authorization: "Negotiate " + NTLM.negotiateMessage().base64EncodedString(),
            body: body
        )
        if response.status == 200 {
            authenticated = true
            return
        }
        guard response.status == 401, let challenge = WinRMClient.challenge(in: response.headers) else {
            throw WinRMError.unreachable("WinRM did not offer an NTLM challenge.")
        }
        let split = WinRMClient.splitIdentity(configuration.username)
        guard let message = NTLM.authenticateMessage(
            challenge: challenge,
            user: split.user,
            domain: split.domain,
            password: configuration.password
        ) else {
            throw WinRMError.authenticationFailed("The NTLM challenge could not be read.")
        }
        response = try connection.request(
            path: "/wsman",
            contentType: "application/soap+xml;charset=UTF-8",
            authorization: "Negotiate " + message.base64EncodedString(),
            body: body
        )
        guard response.status == 200 else {
            throw WinRMError.authenticationFailed(
                "WinRM rejected the credentials for \(configuration.host)."
            )
        }
        authenticated = true
    }

    /// Opens a WinRS shell and returns its id.
    mutating func createShell() throws -> String {
        let response = try post(Self.createShellEnvelope(timeoutSeconds: timeoutSeconds))
        guard let shellID = Self.firstValue(of: "ShellId", in: response) else {
            throw WinRMError.commandFailed(
                Self.fault(in: Data(response)) ?? "WinRM did not return a shell id."
            )
        }
        return shellID
    }

    /// Runs `command` in the shell and returns its command id.
    ///
    /// `Receive` addresses a specific command, so the id from this answer is not
    /// optional: without it the server reports that the command identifier does not
    /// exist, because `/Receive` with no selector addresses nothing.
    mutating func start(command: String, shellID: String) throws -> String {
        let response = try post(Self.commandEnvelope(shellID: shellID, command: command))
        guard let commandID = Self.firstValue(of: "CommandId", in: response) else {
            throw WinRMError.commandFailed(
                Self.fault(in: response) ?? "WinRM started the command but returned no command id."
            )
        }
        return commandID
    }

    /// Reads every stream until `CommandState` reports the command is done.
    ///
    /// WSMan does not return the output with the command: `Receive` is polled and
    /// each answer carries a slice of the streams plus a state. Stopping at the
    /// first non-empty answer would truncate anything longer than one envelope.
    mutating func receiveOutput(shellID: String, commandID: String) throws -> String {
        var collected = Data()
        for _ in 0..<200 {
            let response = try post(Self.receiveEnvelope(shellID: shellID, commandID: commandID, timeoutSeconds: timeoutSeconds))
            for (isError, chunk) in Self.streams(in: response) where !isError {
                collected.append(chunk)
            }
            if Self.commandIsDone(response) { break }
            // A state of "Running" with no new data still needs a moment, or the
            // loop spins on an empty answer.
            usleep(50_000)
        }
        if collected.isEmpty {
            if let fault = Self.fault(in: Data()) { throw WinRMError.commandFailed(fault) }
            throw WinRMError.commandFailed("The command returned no output.")
        }
        return String(decoding: collected, as: UTF8.self)
    }

    mutating func deleteShell(_ shellID: String) throws {
        _ = try? post(Self.deleteShellEnvelope(shellID: shellID))
    }

    // MARK: - Transport

    private mutating func post(_ body: String) throws -> Data {
        let response = try connection.request(
            path: "/wsman",
            contentType: "application/soap+xml;charset=UTF-8",
            authorization: "",
            body: body
        )
        guard response.status == 200 else {
            throw WinRMError.unreachable(
                Self.fault(in: response.body) ?? "WinRM answered with HTTP \(response.status)."
            )
        }
        return response.body
    }

    // MARK: - SOAP

    static func identityEnvelope() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsmid="http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd">
          <s:Header/>
          <s:Body><wsmid:Identify/></s:Body>
        </s:Envelope>
        """
    }

    /// Shared header: WSMan needs the resource URI on every message, plus a
    /// `ShellId` selector once a shell exists.
    private static func header(action: String, shellID: String?, timeoutSeconds: Int) -> String {
        var xml = """
          <s:Header>
            <wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>
            <wsman:ResourceURI s:mustUnderstand="true">http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd</wsman:ResourceURI>
            <wsa:Action s:mustUnderstand="true">\(action)</wsa:Action>
            <wsman:MaxEnvelopeSize s:mustUnderstand="true">153600</wsman:MaxEnvelopeSize>
            <wsa:MessageID>uuid:\(UUID().uuidString)</wsa:MessageID>
            <wsa:ReplyTo>
              <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
            </wsa:ReplyTo>
            <wsman:Locale xml:lang="en-US" s:mustUnderstand="false"/>
            <wsman:Timeout>PT\(timeoutSeconds)S</wsman:Timeout>
        """
        if let shellID {
            xml += """
            <wsman:OptionSet xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/>
            <wsman:SelectorSet>
              <wsman:Selector Name="ShellId">\(shellID)</wsman:Selector>
            </wsman:SelectorSet>
            """
        }
        xml += "  </s:Header>"
        return xml
    }

    private static func envelope(header: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
                    xmlns:rsp="http://schemas.microsoft.com/wbem/wsman/1/windows/shell">
        \(header)
          <s:Body>
        \(body)
          </s:Body>
        </s:Envelope>
        """
    }

    static func createShellEnvelope(timeoutSeconds: Int) -> String {
        envelope(
            header: header(
                action: "http://schemas.xmlsoap.org/ws/2004/09/transfer/Create",
                shellID: nil,
                timeoutSeconds: timeoutSeconds
            ),
            body: """
                <rsp:Shell>
                  <rsp:InputStreams>stdin</rsp:InputStreams>
                  <rsp:OutputStreams>stdout stderr</rsp:OutputStreams>
                </rsp:Shell>
            """
        )
    }

    static func commandEnvelope(shellID: String, command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return envelope(
            header: header(
                action: "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Command",
                shellID: shellID,
                timeoutSeconds: 60
            ),
            body: """
                <rsp:CommandLine>
                  <rsp:Command>\(escaped)</rsp:Command>
                </rsp:CommandLine>
            """
        )
    }

    static func receiveEnvelope(shellID: String, commandID: String, timeoutSeconds: Int) -> String {
        envelope(
            header: header(
                action: "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Receive",
                shellID: shellID,
                timeoutSeconds: timeoutSeconds
            ),
            body: """
                <rsp:Receive>
                  <rsp:DesiredStream CommandId="\(commandID)">stdout stderr</rsp:DesiredStream>
                </rsp:Receive>
            """
        )
    }

    static func deleteShellEnvelope(shellID: String) -> String {
        envelope(
            header: header(
                action: "http://schemas.xmlsoap.org/ws/2004/09/transfer/Delete",
                shellID: shellID,
                timeoutSeconds: 20
            ),
            body: ""
        )
    }

    // MARK: - Parsing

    /// Every `<rsp:Stream>` in a response, with whether it was stderr.
    static func streams(in data: Data) -> [(isError: Bool, data: Data)] {
        let xml = String(decoding: data, as: UTF8.self)
        var result: [(Bool, Data)] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let open = xml.range(of: "<rsp:Stream", range: searchRange) {
            guard let headerEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
                  let close = xml.range(of: "</rsp:Stream>", range: headerEnd.upperBound..<xml.endIndex) else {
                break
            }
            let header = xml[open.upperBound..<headerEnd.lowerBound]
            searchRange = close.upperBound..<xml.endIndex
            let payload = xml[headerEnd.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let chunk = Data(base64Encoded: payload) else { continue }
            result.append((header.contains("Name=\"stderr\""), chunk))
        }
        return result
    }

    static func commandIsDone(_ data: Data) -> Bool {
        let xml = String(decoding: data, as: UTF8.self)
        return xml.contains("CommandState>Done<")
            || xml.contains("CommandState State=\"Done\"")
            || xml.contains("CommandState>Error<") == false && xml.contains("</rsp:ReceiveResponse>")
                && xml.contains("CommandState")
                && !xml.contains("Running")
    }

    /// The text of the first `<tag>…</tag>`.
    static func firstValue(of tag: String, in data: Data) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        // ShellId is namespaced; accept any prefix.
        for candidate in ["<rsp:\(tag)>", "<\(tag)>"] {
            if let start = xml.range(of: candidate),
               let end = xml.range(of: "</", range: start.upperBound..<xml.endIndex) {
                let value = xml[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func fault(in data: Data) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        guard !xml.isEmpty else { return nil }
        for tag in ["f:Message", "s:Text", "Message"] {
            if let message = elementText(tag, in: xml) { return String(message.prefix(300)) }
        }
        return nil
    }

    static func fault(in response: SocketConnection.Response) -> String? {
        fault(in: response.body)
    }

    static func fault(in text: String) -> String? {
        fault(in: Data(text.utf8))
    }

    /// The text of `<tag>…</tag>`, tolerating attributes on the opening tag.
    ///
    /// Real faults look like `<s:Text xml:lang="en-US">reason</s:Text>`, and a
    /// parser that only matches the bare tag reports every fault as "unknown".
    static func elementText(_ tag: String, in xml: String) -> String? {
        var searchRange = xml.startIndex..<xml.endIndex
        while let open = xml.range(of: "<\(tag)", range: searchRange) {
            guard let openEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex) else { return nil }
            // Anything between the tag name and `>` is an attribute list.
            guard let close = xml.range(of: "</\(tag)", range: openEnd.upperBound..<xml.endIndex) else { return nil }
            let value = xml[openEnd.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
            searchRange = close.upperBound..<xml.endIndex
        }
        return nil
    }
}
