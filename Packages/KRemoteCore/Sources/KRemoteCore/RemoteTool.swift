import Foundation

/// Ready-made diagnostics for a remote host.
///
/// MobaXterm ships a Unix userland because Windows has none. macOS does, so copying
/// that idea would mean re-implementing `ls` — pointless. What is actually missing
/// while working on a server is knowing *which* command answers the question in front
/// of you, and typing it correctly at 2am. So these are curated commands, run the same
/// way a snippet runs: one shell, output in the terminal.
///
/// Each one is read-only. A tools menu that can change state is a menu people stop
/// opening.
public struct RemoteTool: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Shown as the menu item's subtitle.
    public let summary: String
    public let command: String
    public let group: String

    public init(id: String, name: String, summary: String, command: String, group: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.command = command
        self.group = group
    }
}

extension RemoteTool {
    /// The catalogue, grouped for the menu.
    ///
    /// Portable across Linux and macOS wherever possible; the few that are not say so
    /// in their summary so the wrong one is obvious rather than mysterious.
    public static let catalogue: [RemoteTool] = [
        // System
        RemoteTool(
            id: "uptime",
            name: "Uptime and load",
            summary: "how long the host has been up, and its load",
            command: "uptime",
            group: "System"
        ),
        RemoteTool(
            id: "sysinfo",
            name: "System information",
            summary: "kernel, architecture, distribution",
            command: "uname -a; echo; cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null",
            group: "System"
        ),
        RemoteTool(
            id: "who",
            name: "Logged-in users",
            summary: "who is on the box right now",
            command: "who; echo; w 2>/dev/null || true",
            group: "System"
        ),
        RemoteTool(
            id: "date",
            name: "Time and timezone",
            summary: "clock, timezone and NTP sync state",
            command: "date; echo; timedatectl 2>/dev/null || systemsetup -getusingnetworktime 2>/dev/null",
            group: "System"
        ),

        // Resources
        RemoteTool(
            id: "disk",
            name: "Disk usage by filesystem",
            summary: "what is full, in human units",
            command: "df -h",
            group: "Resources"
        ),
        RemoteTool(
            id: "memory",
            name: "Memory and swap",
            summary: "free memory, buffers and swap",
            command: "free -h 2>/dev/null || vm_stat",
            group: "Resources"
        ),
        RemoteTool(
            id: "top-cpu",
            name: "Busiest processes",
            summary: "top ten by CPU",
            command: "ps aux 2>/dev/null | sort -nrk 3 | head -11 || ps -Ao pid,pcpu,pmem,comm -r | head -11",
            group: "Resources"
        ),
        RemoteTool(
            id: "biggest",
            name: "Largest directories",
            summary: "the ten biggest folders under / (slow)",
            command: "du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -10",
            group: "Resources"
        ),

        // Network
        RemoteTool(
            id: "addresses",
            name: "IP addresses",
            summary: "interfaces and their addresses",
            command: "ip -brief addr 2>/dev/null || ifconfig",
            group: "Network"
        ),
        RemoteTool(
            id: "listening",
            name: "Listening ports",
            summary: "what is accepting connections",
            command: "ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || lsof -iTCP -sTCP:LISTEN -P -n",
            group: "Network"
        ),
        RemoteTool(
            id: "routes",
            name: "Routing table",
            summary: "where traffic goes, including the default route",
            command: "ip route 2>/dev/null || netstat -rn",
            group: "Network"
        ),
        RemoteTool(
            id: "connections",
            name: "Established connections",
            summary: "who this host is talking to",
            command: "ss -tn state established 2>/dev/null || netstat -tn | grep ESTABLISHED",
            group: "Network"
        ),

        // Services
        RemoteTool(
            id: "failed-units",
            name: "Failed services",
            summary: "systemd units in a failed state",
            command: "systemctl --failed 2>/dev/null || launchctl list 2>/dev/null | grep -v '^\\-' | head -20",
            group: "Services"
        ),
        RemoteTool(
            id: "services-running",
            name: "Running services",
            summary: "active systemd units",
            command: "systemctl list-units --type=service --state=running 2>/dev/null || true",
            group: "Services"
        ),

        // Logs
        RemoteTool(
            id: "errors-today",
            name: "Errors in today's log",
            summary: "journal errors since midnight",
            command: "journalctl --since today -p err --no-pager 2>/dev/null | tail -50 || log show --last 1h --style compact 2>/dev/null | grep -i error | tail -50",
            group: "Logs"
        ),
        RemoteTool(
            id: "recent-logins",
            name: "Recent logins",
            summary: "successful and failed authentication attempts",
            command: "last -n 20 2>/dev/null; echo; grep -i 'failed password' /var/log/auth.log 2>/dev/null | tail -10 || true",
            group: "Logs"
        ),
    ]

    /// Group names in catalogue order, for a stable menu.
    public static var groups: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for tool in catalogue where !seen.contains(tool.group) {
            seen.insert(tool.group)
            order.append(tool.group)
        }
        return order
    }

    public static func tools(in group: String) -> [RemoteTool] {
        catalogue.filter { $0.group == group }
    }
}
