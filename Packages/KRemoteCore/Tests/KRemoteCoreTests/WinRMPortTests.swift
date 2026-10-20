import XCTest
@testable import KRemoteCore

/// WinRM reachability and port selection.
///
/// The badge tries 5985 and then 5986 because RDP says nothing about which listener
/// a Windows host exposes. Both were verified against a real host; these pin the
/// decisions that do not need one.
final class WinRMPortTests: XCTestCase {

    /// The HTTPS port must imply TLS. Getting this wrong was a live bug: the
    /// configuration carried `useTLS` and the probe never set it, so a host that only
    /// allowed 5986 could never answer.
    func testTLSIsDerivedFromThePort() {
        // 5986 is the encrypted listener; 5985 is plaintext.
        XCTAssertTrue(WinRMMetricsProbe.tlsRequired(for: 5986))
        XCTAssertFalse(WinRMMetricsProbe.tlsRequired(for: 5985))
        // A custom port is treated as plaintext unless it is the known HTTPS one.
        XCTAssertFalse(WinRMMetricsProbe.tlsRequired(for: 5987))
    }

    /// A host with no WinRM must fail, not hang: the badge polls every five seconds
    /// and a stuck attempt would pile up behind itself.
    func testUnreachableHostFailsQuickly() async {
        let started = Date()
        do {
            _ = try await WinRMMetricsProbe.sampleAutomatically(
                host: "127.0.0.1",
                username: "nobody",
                password: "nothing",
                timeout: 2
            )
            XCTFail("a host with no WinRM on localhost must not report metrics")
        } catch {
            // Any failure is correct; the point is that it returns.
            XCTAssertTrue(error is WinRMError || error is MetricsError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 12,
                          "two attempts must both honour the timeout")
    }

    /// The parse contract, repeated here because the Windows probe is the one place
    /// where a silent misreading would be invisible: the badge would just show a
    /// plausible wrong number.
    func testParseContract() throws {
        let metrics = try XCTUnwrap(WinRMMetricsProbe.parse("26|28689564|67016040"))
        XCTAssertEqual(metrics.cpuPercent, 26)
        XCTAssertEqual(metrics.memoryPercent, 57.2, accuracy: 0.2)
    }
}
