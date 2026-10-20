import Foundation

/// One reading of a server's load, as the status bar shows it.
///
/// Deliberately a value type with no knowledge of ssh or of where the numbers came
/// from: the probe produces key/value text, `SystemMetricsParser` turns that into
/// this, and the view formats it. Every arithmetic step is therefore testable
/// without a server.
public struct SystemMetrics: Equatable, Sendable {
    /// Percent of CPU time busy over the sample interval, 0…100.
    public var cpuPercent: Double
    /// Percent of memory in use, 0…100.
    public var memoryPercent: Double
    /// Total physical memory in bytes; 0 when the probe could not say.
    public var memoryTotal: UInt64
    /// Used memory in bytes.
    public var memoryUsed: UInt64
    /// 1, 5 and 15 minute load averages, when the platform reports them.
    public var loadAverage: [Double]
    /// Seconds since boot.
    public var uptime: UInt64?
    /// Swap in use, in bytes, when reported.
    public var swapUsed: UInt64?
    public var swapTotal: UInt64?

    public init(
        cpuPercent: Double,
        memoryPercent: Double,
        memoryTotal: UInt64 = 0,
        memoryUsed: UInt64 = 0,
        loadAverage: [Double] = [],
        uptime: UInt64? = nil,
        swapUsed: UInt64? = nil,
        swapTotal: UInt64? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.loadAverage = loadAverage
        self.uptime = uptime
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }

    /// `12%` — one decimal only when it adds information, so the bar does not
    /// jitter between "12%" and "12.0%".
    public var cpuText: String { Self.percentText(cpuPercent) }
    public var memoryText: String { Self.percentText(memoryPercent) }

    public var memoryDetail: String? {
        guard memoryTotal > 0 else { return nil }
        return "\(Self.bytes(memoryUsed)) / \(Self.bytes(memoryTotal))"
    }

    public var swapDetail: String? {
        guard let total = swapTotal, total > 0, let used = swapUsed else { return nil }
        return "\(Self.bytes(used)) / \(Self.bytes(total))"
    }

    public var loadDetail: String? {
        guard !loadAverage.isEmpty else { return nil }
        return loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    public var uptimeDetail: String? {
        guard let uptime else { return nil }
        let days = uptime / 86_400
        let hours = (uptime % 86_400) / 3_600
        let minutes = (uptime % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func percentText(_ value: Double) -> String {
        // `%.0f` rounds 62.5 to 62 (round-half-to-even), which reads as a bug in a
        // status bar that just went up. Round explicitly instead.
        value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value.rounded())
    }

    /// Human byte size, in the units macOS shows (`1.2 GB` = 1000³).
    ///
    /// Binary units would be technically tidier but would disagree with Activity
    /// Monitor and every other size in the system, which is worse.
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let digits = amount >= 100 || unit == 0 ? 0 : 1
        return String(format: "%.\(digits)f %@", amount, units[unit])
    }
}

/// Turns the probe's `key=value` lines into `SystemMetrics`.
///
/// The probe is a shell script because that is the only thing every server is
/// guaranteed to have; key/value keeps the parsing trivial and means a platform
/// adding a line cannot break an older client.
public enum SystemMetricsParser {

    /// Parses one probe run.
    ///
    /// Linux: two `/proc/stat` samples, whose delta gives CPU busy time — a single
    /// sample would only describe the whole uptime and never move.
    /// macOS: no such file, so `top` reports the live percentage directly.
    public static func parse(_ output: String) -> SystemMetrics? {
        let fields = dictionary(from: output)
        guard let os = fields["os"] else { return nil }

        let cpu: Double
        let memory: (percent: Double, total: UInt64, used: UInt64)

        switch os {
        case "linux":
            guard let busy = cpuPercentLinux(fields) else { return nil }
            cpu = busy
            memory = memoryLinux(fields)
        case "darwin":
            guard let value = fields["cpu_idle"].flatMap(Double.init) else { return nil }
            cpu = max(0, min(100, 100 - value))
            memory = memoryDarwin(fields)
        default:
            return nil
        }

        var metrics = SystemMetrics(
            cpuPercent: cpu,
            memoryPercent: memory.percent,
            memoryTotal: memory.total,
            memoryUsed: memory.used
        )
        metrics.loadAverage = fields["load"]?
            .split(separator: " ")
            .compactMap { Double($0) } ?? []
        metrics.uptime = fields["uptime"].flatMap(UInt64.init)

        if os == "linux" {
            if let total = fields["swap_total"].flatMap(UInt64.init),
               let free = fields["swap_free"].flatMap(UInt64.init) {
                metrics.swapTotal = total * 1024
                metrics.swapUsed = total > free ? (total - free) * 1024 : 0
            }
        }
        return metrics
    }

    // MARK: - Platform arithmetic

    /// CPU busy share from two `/proc/stat` samples.
    private static func cpuPercentLinux(_ fields: [String: String]) -> Double? {
        guard let first = fields["cpu"].flatMap(cpuTimes),
              let second = fields["cpu2"].flatMap(cpuTimes) else { return nil }

        // Total time and idle time both grow; the difference between the samples is
        // the interval, and within it the non-idle part is what "CPU usage" means.
        // iowait counts as idle: the CPU was waiting, not working.
        let total = Double(second.total - first.total)
        let idle = Double(second.idle - first.idle)
        guard total > 0, idle >= 0 else { return 0 }
        return max(0, min(100, (total - idle) / total * 100))
    }

    /// `cpu  user nice system idle iowait irq softirq steal …`
    private static func cpuTimes(_ line: String) -> (total: UInt64, idle: UInt64)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        // parts[0] is the "cpu" label.
        let numbers = parts.dropFirst().compactMap { UInt64($0) }
        guard numbers.count >= 4 else { return nil }
        let total = numbers.reduce(0, +)
        // idle (index 3) plus iowait (index 4) when present.
        let idle = numbers[3] + (numbers.count > 4 ? numbers[4] : 0)
        return (total, idle)
    }

    /// `/proc/meminfo` in kB. `MemAvailable` is the number to use: it accounts for
    /// cache the kernel would drop under pressure, unlike `MemFree`.
    private static func memoryLinux(_ fields: [String: String]) -> (Double, UInt64, UInt64) {
        guard let totalKB = fields["mem_total"].flatMap(UInt64.init) else { return (0, 0, 0) }
        let availableKB = fields["mem_avail"].flatMap(UInt64.init) ?? 0
        let total = totalKB * 1024
        let available = min(availableKB, totalKB) * 1024
        let used = total > available ? total - available : 0
        let percent = total > 0 ? Double(used) / Double(total) * 100 : 0
        return (max(0, min(100, percent)), total, used)
    }

    /// `vm_stat` pages, converted with the page size the probe reports.
    ///
    /// "Used" here matches Activity Monitor's Memory Used: active + wired +
    /// compressed. Inactive pages are reclaimable, so counting them would show a
    /// machine that is always nearly full.
    private static func memoryDarwin(_ fields: [String: String]) -> (Double, UInt64, UInt64) {
        guard let pageSize = fields["page_size"].flatMap(UInt64.init),
              pageSize > 0 else { return (0, 0, 0) }
        let total = fields["mem_total"].flatMap(UInt64.init) ?? 0

        func pages(_ key: String) -> UInt64 {
            (fields[key].flatMap(UInt64.init) ?? 0) * pageSize
        }
        let used = pages("pages_active") + pages("pages_wired") + pages("pages_compressor")
        guard total > 0 else { return (0, 0, 0) }
        let percent = min(100, Double(used) / Double(total) * 100)
        return (percent, total, min(used, total))
    }

    private static func dictionary(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let index = line.firstIndex(of: "=") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
