import SwiftUI
import KRemoteCore

/// Runs one command across several connections and shows what each said.
///
/// The results are kept in the order the servers were picked rather than the order they
/// answered: when the point is finding the one host that differs, a list that reshuffles
/// as replies arrive is unreadable.
struct MultiExecView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var command = ""
    @State private var selected: Set<UUID> = []
    @State private var results: [MultiExecResult] = []
    @State private var isRunning = false
    @State private var filter = ""
    @State private var showOnlyFailures = false

    private var targets: [MultiExecution.Target] {
        model.multiExecCandidates
    }

    private var chosen: [MultiExecution.Target] {
        targets.filter { selected.contains($0.nodeID) }
    }

    private var visibleResults: [MultiExecResult] {
        results.filter { result in
            if showOnlyFailures, result.succeeded { return false }
            guard !filter.isEmpty else { return true }
            let needle = filter.lowercased()
            return result.name.lowercased().contains(needle)
                || result.host.lowercased().contains(needle)
                || result.output.lowercased().contains(needle)
        }
    }

    private var summary: String {
        guard !results.isEmpty else { return "" }
        let ok = results.filter(\.succeeded).count
        return "\(ok) of \(results.count) succeeded"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Run on Several Servers")
                        .font(.headline)
                    Spacer()
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else if !results.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Command to run on every selected server", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { run() }

                HStack(spacing: 8) {
                    Button(selected.count == targets.count ? "Deselect All" : "Select All") {
                        if selected.count == targets.count {
                            selected.removeAll()
                        } else {
                            selected = Set(targets.map(\.nodeID))
                        }
                    }
                    .controlSize(.small)

                    Text("\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    TextField("Filter results", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)

                    Toggle("Failures only", isOn: $showOnlyFailures)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                targetList
            }
            .padding(16)

            Divider()

            resultsList
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRunning ? "Running…" : "Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
        }
        .onAppear {
            // Preseeding the selection with nothing means a stray Return cannot send a
            // command anywhere; the user names the targets.
            if selected.isEmpty, let first = targets.first, targets.count == 1 {
                selected = [first.nodeID]
            }
        }
    }

    private var targetList: some View {
        Group {
            if targets.isEmpty {
                Text("No SSH connections in the tree yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(targets) { target in
                            let isOn = selected.contains(target.nodeID)
                            Button {
                                if isOn { selected.remove(target.nodeID) } else { selected.insert(target.nodeID) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                        .font(.caption)
                                    Text(target.name)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isOn ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 34)
            }
        }
    }

    private var resultsList: some View {
        Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Pick servers, type a command, press Run.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleResults) { result in
                            resultCard(result)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func resultCard(_ result: MultiExecResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.succeeded ? .green : .red)
                Text(result.name)
                    .font(.caption.weight(.medium))
                Text(result.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let code = result.exitCode, code != 0 {
                    Text("exit \(code)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.red)
                }
                Text(String(format: "%.1fs", result.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if !result.error.isEmpty {
                Text(result.error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if result.output.isEmpty {
                Text("(no output)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(result.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(30)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(result.succeeded ? Color(nsColor: .separatorColor) : Color.red.opacity(0.4))
        )
    }

    private func run() {
        guard !isRunning, !chosen.isEmpty else { return }
        isRunning = true
        results = []

        let text = command
        let targets = chosen
        Task {
            let collected = await MultiExecution.run(command: text, targets: targets)
            await MainActor.run {
                results = collected
                isRunning = false
            }
        }
    }
}

extension AppModel {
    /// Every SSH connection in the tree, as multi-execution targets.
    ///
    /// Folders are skipped: they have no host to connect to, and inheriting a folder's
    /// credentials is already what `effective` does for the leaves.
    var multiExecCandidates: [MultiExecution.Target] {
        var found: [MultiExecution.Target] = []
        func walk(_ nodes: [ConnectionNode]) {
            for node in nodes {
                if !node.isFolder, node.supportsSSH, let effective = effective(node.id) {
                    found.append(MultiExecution.Target(
                        nodeID: node.id,
                        name: node.name,
                        host: effective.host,
                        port: effective.port,
                        username: effective.username,
                        identityFile: effective.identityFile,
                        password: effective.password
                    ))
                }
                if let children = node.childNodes {
                    walk(children)
                }
            }
        }
        walk(roots)
        return found
    }
}
