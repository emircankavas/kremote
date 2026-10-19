import SwiftUI
import KRemoteCore

/// Update window: checks on appear, shows the release notes and offers to
/// download + swap the app in place.
struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .checking
    @State private var info: UpdateInfo?
    @State private var message: String?
    /// Which release line to follow. Persisted by `UpdateChecker.channel`.
    @State private var channel: UpdateChannel = UpdateChecker.channel

    enum Phase { case checking, upToDate, available, installing, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Software Update").font(.headline)
                Spacer()
                Picker("Channel", selection: $channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Beta receives pre-release builds. Stable only sees finished releases.")
                if phase != .installing {
                    Button("Close") { dismiss() }
                }
            }
            .padding(12)
            Divider()

            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 460)
        .task { await check() }
        .onChange(of: channel) { _, newValue in
            UpdateChecker.channel = newValue
            Task { await check() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking:
            centered { ProgressView("Checking…") }

        case .upToDate:
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("You're up to date.")
                    Text("Version \(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
                }
            }

        case .available, .installing, .failed:
            VStack(alignment: .leading, spacing: 12) {
                if let info {
                    HStack(alignment: .firstTextBaseline) {
                        Text(info.name).font(.title3.bold())
                        Text("(\(info.currentVersion) → \(info.latestVersion))")
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(info.notes.isEmpty ? "(No release notes.)" : info.notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }

                if info == nil {
                    Text("No update information could be fetched.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if phase == .installing {
                        ProgressView().controlSize(.small)
                        Text("Downloading and installing…").foregroundStyle(.secondary)
                    } else if info != nil {
                        Button("Update and Relaunch") { install() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let info, !info.htmlURL.isEmpty, let url = URL(string: info.htmlURL) {
                        Button("Open Release Notes") { NSWorkspace.shared.open(url) }
                    }
                }
            }

        case .done:
            centered { Text("Updated. The app is restarting…") }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func check() async {
        phase = .checking
        info = nil
        message = nil
        do {
            if let result = try await UpdateChecker.check(channel: channel) {
                info = result
                phase = result.isNewer ? .available : .upToDate
            } else {
                info = nil
                phase = .failed
                message = channel == .beta
                    ? "No beta build has been published yet."
                    : "No release has been published yet."
            }
        } catch {
            phase = .failed
            message = error.localizedDescription
        }
    }

    private func install() {
        guard let info else { return }
        phase = .installing
        Task {
            do {
                try await UpdateService.downloadAndInstall(info)
                phase = .done
            } catch {
                phase = .failed
                message = error.localizedDescription
            }
        }
    }
}
