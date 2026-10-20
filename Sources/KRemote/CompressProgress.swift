import SwiftUI

/// A compressed download in flight.
///
/// The archive's final size is not known while it is being built on the server,
/// so this reports bytes received rather than a percentage — a bar that jumps
/// around while `tar` works would be worse than an honest counter.
struct CompressProgress: Equatable {
    let name: String
    var bytes: Int64

    var label: String {
        "Compressing on the server — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) received"
    }
}

/// The banner shown while an archive is being built and streamed down.
struct CompressProgressBanner: View {
    let progress: CompressProgress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(progress.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4))
        .overlay(alignment: .bottom) { Divider() }
    }
}
