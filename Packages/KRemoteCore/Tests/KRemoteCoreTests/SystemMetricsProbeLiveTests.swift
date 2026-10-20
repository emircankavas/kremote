import XCTest
@testable import KRemoteCore

/// Runs the exact script the app ships against the machine running the test.
///
/// The parser tests use captured text; this one proves the *script* still produces
/// text the parser understands. A quoting slip or a changed `awk` field in the
/// script would pass every other test and show an empty badge in the app.
final class SystemMetricsProbeLiveTests: XCTestCase {

    private func runLocally() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemMetricsProbe.script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testShippedScriptProducesParsableOutputOnThisMachine() throws {
        let output = try runLocally()

        guard let metrics = SystemMetricsParser.parse(output) else {
            return XCTFail("the shipped script's output did not parse:\n\(output)")
        }

        XCTAssertTrue((0...100).contains(metrics.cpuPercent), "cpu: \(metrics.cpuPercent)")
        XCTAssertTrue((0...100).contains(metrics.memoryPercent), "memory: \(metrics.memoryPercent)")
        XCTAssertGreaterThan(metrics.memoryTotal, 0, "total memory must be known")
        XCTAssertGreaterThan(metrics.memoryUsed, 0)
        // A machine running this test is using memory; 0% would mean the parser
        // found the keys but not the numbers.
        XCTAssertGreaterThan(metrics.memoryPercent, 0)
        // macOS reports `os=darwin`; a Linux runner reports `os=linux`. Either way
        // one of the two branches must have produced a reading.
        XCTAssertTrue(output.contains("os=darwin") || output.contains("os=linux"))
    }

    func testScriptNeverWritesToStderrWhenItWorks() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemMetricsProbe.script]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        // A probe that leaks diagnostics would be shown to the user as the reason
        // the badge is empty, which would be misleading.
        XCTAssertEqual(err.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
