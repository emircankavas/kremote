import XCTest
@testable import KRemoteCore

/// The Windows path, tested without a Windows host: the parsing, the identity
/// splitting and the SOAP shapes. The end-to-end handshake is covered by the live
/// probe, which needs a real box.
final class WinRMMetricsTests: XCTestCase {

    // Captured from a real Windows 11 host: `26|28689564|67016040`.
    func testParsesRealOutput() throws {
        let metrics = try XCTUnwrap(WinRMMetricsProbe.parse("26|28689564|67016040"))

        XCTAssertEqual(metrics.cpuPercent, 26)
        // 28689564 KB free of 67016040 KB is about 57% used.
        XCTAssertEqual(metrics.memoryTotal, 67_016_040 * 1024)
        XCTAssertEqual(metrics.memoryUsed, (67_016_040 - 28_689_564) * 1024)
        XCTAssertEqual(metrics.memoryPercent, 57.2, accuracy: 0.2)
    }

    /// Trailing newlines are normal — PowerShell ends its output with CRLF.
    func testToleratesWhitespaceAndNewlines() {
        XCTAssertNotNil(WinRMMetricsProbe.parse("  26|28689564|67016040\r\n"))
        XCTAssertNotNil(WinRMMetricsProbe.parse("26 | 28689564 | 67016040"))
    }

    func testRejectsIncompleteOutput() {
        XCTAssertNil(WinRMMetricsProbe.parse(""))
        XCTAssertNil(WinRMMetricsProbe.parse("26"))
        XCTAssertNil(WinRMMetricsProbe.parse("26|28689564"))
        XCTAssertNil(WinRMMetricsProbe.parse("abc|1|2"))
        XCTAssertNil(WinRMMetricsProbe.parse("26|abc|2"))
        // A zero total would divide by zero and show 0% for a full machine.
        XCTAssertNil(WinRMMetricsProbe.parse("26|0|0"))
    }

    /// A counter that reports free > total must clamp, not produce a negative.
    func testFreeGreaterThanTotalClamps() throws {
        let metrics = try XCTUnwrap(WinRMMetricsProbe.parse("10|999999999|1000"))
        XCTAssertEqual(metrics.memoryUsed, 0)
        XCTAssertEqual(metrics.memoryPercent, 0)
    }

    /// CPU outside 0…100 is clamped rather than drawn past the bar.
    func testCPUIsClamped() throws {
        XCTAssertEqual(try XCTUnwrap(WinRMMetricsProbe.parse("140|1|2")).cpuPercent, 100)
        XCTAssertEqual(try XCTUnwrap(WinRMMetricsProbe.parse("-5|1|2")).cpuPercent, 0)
    }

    // MARK: - Identity

    func testIdentitySplitting() {
        XCTAssertEqual(WinRMClient.splitIdentity("DOMAIN\\user").domain, "DOMAIN")
        XCTAssertEqual(WinRMClient.splitIdentity("DOMAIN\\user").user, "user")
        // `user@domain` means the domain is what follows the @, like UPN.
        XCTAssertEqual(WinRMClient.splitIdentity("user@domain.local").domain, "domain.local")
        XCTAssertEqual(WinRMClient.splitIdentity("user@domain.local").user, "user")
        // A local account has no domain, and inventing one breaks the response.
        XCTAssertEqual(WinRMClient.splitIdentity("localuser").domain, "")
        XCTAssertEqual(WinRMClient.splitIdentity("localuser").user, "localuser")
    }

    // MARK: - Why the transport is hand-written

    /// The header parsing has to cope with several schemes in one value, which is
    /// what a plain Windows host actually sends.
    func testChallengeParsingHandlesMultipleSchemes() throws {
        let headers = "HTTP/1.1 401\r\n"
            + "WWW-Authenticate: Negotiate, Basic realm=\"WSMAN\"\r\n"
        // No token after Negotiate: nothing to answer.
        XCTAssertNil(WinRMClient.challenge(in: headers))

        let challenge = Data(repeating: 0x41, count: 188).base64EncodedString()
        let withToken = "HTTP/1.1 401\r\nWWW-Authenticate: Negotiate \(challenge)\r\n"
        XCTAssertEqual(WinRMClient.challenge(in: withToken)?.count, 188)
    }

    /// WSMan's `CommandState` decides when polling stops. Stopping early truncates
    /// long output; never stopping hangs the badge.
    func testCommandStateRecognition() {
        let done = Data("<rsp:ReceiveResponse><rsp:CommandState CommandId=\"1\" State=\"http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done\"/></rsp:ReceiveResponse>".utf8)
        let running = Data("<rsp:ReceiveResponse><rsp:CommandState CommandId=\"1\" State=\"http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Running\"/></rsp:ReceiveResponse>".utf8)
        XCTAssertTrue(WinRMSession.commandIsDone(done))
        XCTAssertFalse(WinRMSession.commandIsDone(running))
    }

    /// Output arrives base64-encoded inside `<rsp:Stream>` and can be split across
    /// several elements; all of them make up one answer.
    func testStreamCollectionConcatenatesSlices() {
        let first = Data("hello ".utf8).base64EncodedString()
        let second = Data("world".utf8).base64EncodedString()
        let xml = """
        <rsp:ReceiveResponse>
          <rsp:Stream Name="stdout" CommandId="1">\(first)</rsp:Stream>
          <rsp:Stream Name="stderr" CommandId="1">\(Data("warning".utf8).base64EncodedString())</rsp:Stream>
          <rsp:Stream Name="stdout" CommandId="1">\(second)</rsp:Stream>
        </rsp:ReceiveResponse>
        """
        let streams = WinRMSession.streams(in: Data(xml.utf8))
        let stdout = streams.filter { !$0.isError }.map { $0.data }.reduce(Data(), +)
        let stderr = streams.filter { $0.isError }.map { $0.data }.reduce(Data(), +)

        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "hello world")
        XCTAssertEqual(String(decoding: stderr, as: UTF8.self), "warning")
    }

    /// A fault must be reported with the server's own words; a bare "failed" tells
    /// the user nothing about whether it is credentials, firewall or permissions.
    func testFaultMessageIsExtracted() {
        let xml = Data("""
        <s:Envelope><s:Body><s:Fault>
          <s:Code><s:Value>s:Receiver</s:Value></s:Code>
          <s:Reason><s:Text xml:lang="en-US">The credentials were rejected</s:Text></s:Reason>
        </s:Fault></s:Body></s:Envelope>
        """.utf8)
        XCTAssertEqual(WinRMSession.fault(in: xml), "The credentials were rejected")
        XCTAssertNil(WinRMSession.fault(in: Data("<ok/>".utf8)))
    }

    /// `ShellId` comes back namespaced; a parser that only looks for `<ShellId>`
    /// would report every shell as failed.
    func testShellIDExtraction() {
        let xml = Data("<rsp:Shell><rsp:ShellId>ABCD-1234</rsp:ShellId></rsp:Shell>".utf8)
        XCTAssertEqual(WinRMSession.firstValue(of: "ShellId", in: xml), "ABCD-1234")
        XCTAssertNil(WinRMSession.firstValue(of: "ShellId", in: Data("<rsp:Shell/>".utf8)))
    }
}
