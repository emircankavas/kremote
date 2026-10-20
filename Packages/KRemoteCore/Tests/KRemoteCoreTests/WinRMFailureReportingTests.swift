import XCTest
@testable import KRemoteCore

/// Failures must be reported, not waited out.
///
/// A Windows host with WinRM on 5986 and a firewall that drops it produced a silent
/// four-second timeout, because `NWConnection` reports a refused connection as
/// `.waiting` and that state was ignored. The badge then showed nothing at all, which
/// is indistinguishable from a feature that was never wired up.
final class WinRMFailureReportingTests: XCTestCase {

    /// A closed port must fail with the reason, quickly.
    ///
    /// Port 1 on localhost is never listening, so the connection is refused rather
    /// than dropped — that distinction is the point: "refused" means no listener,
    /// "timed out" means a firewall, and they need different fixes.
    func testRefusedConnectionIsReportedQuickly() async {
        let started = Date()
        do {
            _ = try await WinRMMetricsProbe.sample(
                host: "127.0.0.1",
                username: "u",
                password: "p",
                port: 1,
                timeout: 5
            )
            XCTFail("port 1 cannot be serving WinRM")
        } catch {
            let text = error.localizedDescription.lowercased()
            // Either wording is acceptable; silence is not.
            XCTAssertTrue(
                text.contains("refused") || text.contains("could not reach") || text.contains("timed out"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
        // Well under the timeout: a refusal is immediate and must not be waited out.
        XCTAssertLessThan(Date().timeIntervalSince(started), 4,
                          "a refused connection should not consume the whole timeout")
    }

    /// The auto-discovery path must not report success when neither port answers.
    func testAutoDiscoveryFailsWhenNoPortAnswers() async {
        do {
            _ = try await WinRMMetricsProbe.sampleAutomatically(
                host: "127.0.0.1",
                username: "u",
                password: "p",
                timeout: 2
            )
            XCTFail("localhost is not running WinRM")
        } catch {
            XCTAssertTrue(error is WinRMError || error is MetricsError)
        }
    }

    /// The message must name the port: "could not reach the host" alone gives the
    /// user nothing to check.
    func testErrorMessageNamesThePort() async {
        do {
            _ = try await WinRMMetricsProbe.sample(
                host: "127.0.0.1", username: "u", password: "p", port: 1, timeout: 3)
            XCTFail("port 1 cannot answer")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("1"),
                "the failing port should appear in: \(error.localizedDescription)"
            )
        }
    }
}
