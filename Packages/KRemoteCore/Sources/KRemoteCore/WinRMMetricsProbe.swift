import Foundation

/// Samples a **Windows** host's CPU and memory over WinRM.
///
/// RDP carries a desktop, not counters: there is no RDP message that reports the
/// server's CPU. WinRM is the supported way to ask a Windows box, so an RDP session
/// uses this, and the badge stays hidden when the host does not answer — a Windows
/// machine with RDP open but WinRM off is a normal setup, not an error worth showing.
public enum WinRMMetricsProbe {

    /// One PowerShell expression, one round trip.
    ///
    /// Written as a single expression on purpose. A multi-line script works on the
    /// server but its output arrives across several `Receive` slices, and the
    /// incremental collection was truncated in practice. One expression yields one
    /// short line that always arrives whole.
    ///
    /// `Win32_Processor.LoadPercentage` is an instantaneous sample, not an average
    /// over an interval, which is why it is read fresh every poll rather than
    /// differenced like `/proc/stat` on Linux.
    public static let script = """
    [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average,0).ToString() + '|' + (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory.ToString() + '|' + (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize.ToString()
    """

    /// Samples once.
    ///
    /// `FreePhysicalMemory` and `TotalVisibleMemorySize` are in kilobytes.
    public static func sample(
        host: String,
        username: String,
        password: String,
        port: Int = 5985,
        timeout: TimeInterval = 12
    ) async throws -> SystemMetrics {
        let client = WinRMClient(configuration: .init(
            host: host,
            port: port,
            username: username,
            password: password,
            timeout: timeout
        ))
        let output = try await client.runPowerShell(script)
        guard let metrics = parse(output) else {
            throw MetricsError.unreadable("WinRM answered with \"\(output.prefix(120))\".")
        }
        return metrics
    }

    /// Parses `cpu|freeKB|totalKB`.
    ///
    /// Split out so the arithmetic is testable without a Windows host: the numbers
    /// come from two different counters and a sign error here would show a machine
    /// as 90% free while it is thrashing.
    public static func parse(_ output: String) -> SystemMetrics? {
        let fields = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 3,
              let cpu = Double(fields[0]),
              let freeKB = UInt64(fields[1]),
              let totalKB = UInt64(fields[2]),
              totalKB > 0 else {
            return nil
        }

        let total = totalKB * 1024
        let free = min(freeKB, totalKB) * 1024
        let used = total - free
        return SystemMetrics(
            cpuPercent: max(0, min(100, cpu)),
            memoryPercent: max(0, min(100, Double(used) / Double(total) * 100)),
            memoryTotal: total,
            memoryUsed: used
        )
    }
}
