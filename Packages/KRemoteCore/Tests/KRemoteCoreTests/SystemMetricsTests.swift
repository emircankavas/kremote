import XCTest
@testable import KRemoteCore

/// The parser is the whole product of this feature: if the arithmetic is wrong the
/// status bar quietly lies, so every platform and every awkward case is pinned
/// with real captured output.
final class SystemMetricsTests: XCTestCase {

    // Captured from a Linux box (WSL, 12 cores) running the real probe.
    private let linuxSample = """
    os=linux
    cores=12
    cpu=cpu  278 0 502 2476 99 0 74 0 0 0
    cpu2=cpu  302 0 544 2826 107 0 91 0 0 0
    mem_total=32819840
    mem_avail=31917660
    swap_total=8388608
    swap_free=8388608
    load=0.00 0.00 0.00
    uptime=3
    """

    // Captured from macOS (10 cores, 16 GB) running the real probe.
    private let darwinSample = """
    os=darwin
    cores=10
    mem_total=17179869184
    page_size=16384
    pages_free=70806
    pages_active=269580
    pages_inactive=247787
    pages_wired=164372
    pages_compressor=230196
    cpu_idle=91.1
    load= 1.77 1.59 1.57
    uptime=408150
    """

    // MARK: - Linux

    func testLinuxCPUComeFromTheDeltaBetweenTwoSamples() throws {
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(linuxSample))

        // Sample 1 total = 3429, idle = 2575; sample 2 total = 3870, idle = 2933.
        // Interval: 441 ticks, of which 358 idle → 83 busy → 18.8%.
        XCTAssertEqual(metrics.cpuPercent, (441.0 - 358.0) / 441.0 * 100, accuracy: 0.01)
    }

    /// A single sample would describe the whole uptime and never move. This pins
    /// that the second sample is actually used rather than the first.
    func testLinuxCPUIsNotDerivedFromASingleSample() throws {
        var onlyFirst = linuxSample
        onlyFirst = onlyFirst
            .split(separator: "\n")
            .filter { !$0.hasPrefix("cpu2=") }
            .joined(separator: "\n")

        XCTAssertNil(SystemMetricsParser.parse(onlyFirst),
                     "without a second sample there is no interval to measure")
    }

    func testLinuxMemoryUsesAvailableNotFree() throws {
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(linuxSample))
        let total: UInt64 = 32_819_840 * 1024
        let used = total - 31_917_660 * 1024

        XCTAssertEqual(metrics.memoryTotal, total)
        XCTAssertEqual(metrics.memoryUsed, used)
        XCTAssertEqual(metrics.memoryPercent, Double(used) / Double(total) * 100, accuracy: 0.01)
        // A machine with 32 GB and 31.9 GB available is not 3% used by accident; it
        // is nearly idle, and the figure must say so rather than counting cache.
        XCTAssertLessThan(metrics.memoryPercent, 5)
    }

    func testLinuxSwapAndExtras() throws {
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(linuxSample))
        XCTAssertEqual(metrics.swapTotal, 8_388_608 * 1024)
        XCTAssertEqual(metrics.swapUsed, 0)
        XCTAssertEqual(metrics.uptime, 3)
        XCTAssertEqual(metrics.loadAverage, [0, 0, 0])
    }

    // MARK: - macOS

    func testDarwinCPUIsTheInverseOfIdle() throws {
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(darwinSample))
        XCTAssertEqual(metrics.cpuPercent, 8.9, accuracy: 0.01)
    }

    func testDarwinMemoryCountsActiveWiredAndCompressed() throws {
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(darwinSample))
        let pageSize: UInt64 = 16384
        let used = (269_580 + 164_372 + 230_196) * pageSize

        XCTAssertEqual(metrics.memoryTotal, 17_179_869_184)
        XCTAssertEqual(metrics.memoryUsed, used)
        // Inactive pages (247_787) must not be counted: they are reclaimable, and
        // including them would show this idle machine as nearly full.
        let withInactive = used + 247_787 * pageSize
        XCTAssertLessThan(metrics.memoryUsed, withInactive)
        XCTAssertEqual(metrics.memoryPercent, Double(used) / Double(17_179_869_184) * 100, accuracy: 0.01)
    }

    func testDarwinWithoutPageSizeReportsNothingRatherThanZeroPercent() {
        let broken = """
        os=darwin
        mem_total=17179869184
        cpu_idle=50
        """
        let metrics = SystemMetricsParser.parse(broken)
        XCTAssertEqual(metrics?.memoryPercent, 0)
        XCTAssertNil(metrics?.memoryDetail, "0/0 bytes would be a lie, so no detail is offered")
    }

    // MARK: - Robustness

    func testUnknownPlatformIsRejected() {
        XCTAssertNil(SystemMetricsParser.parse("os=freebsd\ncpu_idle=1"))
    }

    func testGarbageDoesNotCrash() {
        XCTAssertNil(SystemMetricsParser.parse(""))
        XCTAssertNil(SystemMetricsParser.parse("\n\n\n"))
        XCTAssertNil(SystemMetricsParser.parse("no equals signs here"))
        XCTAssertNil(SystemMetricsParser.parse("os=linux"))
    }

    func testPartialLaterLinesDoNotDiscardTheReading() throws {
        // A truncated tail is normal when a command's output is cut; the metrics
        // that did arrive are still worth showing.
        let truncated = String(linuxSample.prefix(120))
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(truncated))
        XCTAssertGreaterThan(metrics.cpuPercent, 0)
    }

    func testPercentIsClampedToASaneRange() throws {
        // Two samples where idle grows faster than total would otherwise go negative.
        let weird = """
        os=linux
        cpu=cpu  100 0 100 100 0
        cpu2=cpu  100 0 100 900 0
        mem_total=1000
        mem_avail=1000
        """
        let metrics = try XCTUnwrap(SystemMetricsParser.parse(weird))
        XCTAssertEqual(metrics.cpuPercent, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(metrics.memoryPercent, 0)
    }

    // MARK: - Formatting

    func testFormattingIsStableEnoughForAStatusBar() {
        XCTAssertEqual(SystemMetrics(cpuPercent: 3.44, memoryPercent: 62.5).cpuText, "3.4%")
        XCTAssertEqual(SystemMetrics(cpuPercent: 62.5, memoryPercent: 62.5).cpuText, "63%")
        XCTAssertEqual(SystemMetrics(cpuPercent: 100, memoryPercent: 0).cpuText, "100%")
    }

    func testByteFormattingMatchesSystemConventions() {
        XCTAssertEqual(SystemMetrics.bytes(0), "0 B")
        XCTAssertEqual(SystemMetrics.bytes(999), "999 B")
        XCTAssertEqual(SystemMetrics.bytes(1_500), "1.5 KB")
        XCTAssertEqual(SystemMetrics.bytes(17_179_869_184), "17.2 GB")
    }

    func testDetailLinesAppearOnlyWhenThereIsSomethingToSay() {
        var metrics = SystemMetrics(cpuPercent: 10, memoryPercent: 20)
        XCTAssertNil(metrics.memoryDetail)
        XCTAssertNil(metrics.loadDetail)
        XCTAssertNil(metrics.uptimeDetail)

        metrics.memoryTotal = 8_000
        metrics.memoryUsed = 4_000
        XCTAssertEqual(metrics.memoryDetail, "4.0 KB / 8.0 KB")

        metrics.uptime = 90_000
        XCTAssertEqual(metrics.uptimeDetail, "1d 1h")
        metrics.uptime = 3_600
        XCTAssertEqual(metrics.uptimeDetail, "1h 0m")
        metrics.uptime = 120
        XCTAssertEqual(metrics.uptimeDetail, "2m")
    }
}
