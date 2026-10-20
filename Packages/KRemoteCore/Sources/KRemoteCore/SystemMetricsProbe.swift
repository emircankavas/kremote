import Foundation

/// The shell script the probe runs on the server.
///
/// Kept as a plain POSIX `sh` script because it must run on every Linux and macOS
/// box without installing anything: `/proc` on Linux, `sysctl`/`vm_stat`/`top` on
/// macOS. It prints `key=value` lines only, so the client parses rather than
/// scrapes prose, and a new platform line cannot break an older client.
public enum SystemMetricsProbe {

    /// The script. Two CPU samples on Linux; one live percentage on macOS.
    public static let script = """
    if [ -r /proc/stat ]; then
      echo "os=linux"
      echo "cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
      echo "cpu=$(head -1 /proc/stat)"
      sleep 0.35
      echo "cpu2=$(head -1 /proc/stat)"
      awk -F'[: ]+' '/^MemTotal/{print "mem_total="$2}
        /^MemAvailable/{print "mem_avail="$2}
        /^SwapTotal/{print "swap_total="$2}
        /^SwapFree/{print "swap_free="$2}' /proc/meminfo
      echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
      echo "uptime=$(cut -d'.' -f1 /proc/uptime)"
    else
      echo "os=darwin"
      echo "cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
      echo "mem_total=$(sysctl -n hw.memsize 2>/dev/null)"
      vm_stat | awk -F: '/page size of/{gsub(/[^0-9]/,"",$2); print "page_size="$2}
        /Pages free/{gsub(/[^0-9]/,"",$2); print "pages_free="$2}
        /Pages active/{gsub(/[^0-9]/,"",$2); print "pages_active="$2}
        /Pages inactive/{gsub(/[^0-9]/,"",$2); print "pages_inactive="$2}
        /Pages wired down/{gsub(/[^0-9]/,"",$2); print "pages_wired="$2}
        /Pages occupied by compressor/{gsub(/[^0-9]/,"",$2); print "pages_compressor="$2}'
      top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage/{line=$0} END{
        n=split(line,a,","); idle=0;
        for(i=1;i<=n;i++) if (a[i] ~ /idle/) { gsub(/[^0-9.]/,"",a[i]); idle=a[i] }
        printf "cpu_idle=%s\\n", idle }'
      echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
      echo "uptime=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \\([0-9]*\\).*/\\1/')"
    fi
    """

    /// Runs the probe over an already-configured shell and parses the result.
    ///
    /// The timeout is generous but finite: the script sleeps 0.35 s and macOS needs
    /// a 1 s `top` sample, so anything past a few seconds means the box is wedged,
    /// and a stuck poll must not pile up behind itself.
    public static func sample(using shell: RemoteShell, timeout: TimeInterval = 8) async throws
        -> SystemMetrics {
        let output = try await shell.run(script, timeout: timeout)
        guard let metrics = SystemMetricsParser.parse(output.stdoutText) else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetricsError.unreadable(detail.isEmpty ? output.stdoutText : detail)
        }
        return metrics
    }
}

public enum MetricsError: Error, LocalizedError, Equatable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The server did not report its load."
                : "The server did not report its load: \(trimmed.prefix(200))"
        }
    }
}

extension RemoteShell.Output {
    /// stdout as text; empty when the command wrote binary or nothing.
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}
