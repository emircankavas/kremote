import Foundation
import Citadel
import NIOCore
import NIOSSH

/// Drives one interactive SSH session over Citadel: an interactive shell on a PTY,
/// with byte-in / byte-out callbacks that a terminal view can bridge to.
///
/// Kept UI-free and in the core so it is testable and reusable; the app supplies
/// the callbacks and renders output with SwiftTerm.
@available(macOS 15.0, *)
public actor SSHSessionController {

    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String?)
    }

    // Callbacks are @Sendable and expected to hop to the main actor themselves.
    private let onOutput: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (State) -> Void

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var runTask: Task<Void, Never>?
    private var isCancelled = false

    public init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.onOutput = onOutput
        self.onStateChange = onStateChange
    }

    // MARK: - Lifecycle

    public func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        columns: Int = 80,
        rows: Int = 24,
        knownHostsURL: URL = KnownHostsStore.defaultFileURL()
    ) {
        guard runTask == nil else { return }
        let validator = SSHHostKeyValidator.custom(
            TOFUHostKeyValidator(host: host, port: port, storeURL: knownHostsURL)
        )

        runTask = Task { [weak self] in
            await self?.run(
                host: host,
                port: port,
                username: username,
                password: password,
                columns: columns,
                rows: rows,
                validator: validator
            )
        }
    }

    private func run(
        host: String,
        port: Int,
        username: String,
        password: String,
        columns: Int,
        rows: Int,
        validator: SSHHostKeyValidator
    ) async {
        onStateChange(.connecting)
        do {
            let settings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: {
                    .passwordBased(username: username, password: password)
                },
                hostKeyValidator: validator
            )

            let client = try await SSHClient.connect(to: settings)
            self.client = client

            try await client.withPTY(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: columns,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )
            ) { inbound, outbound in
                await self.attach(outbound)
                for try await event in inbound {
                    switch event {
                    case .stdout(let buffer), .stderr(let buffer):
                        self.onOutput(Data(buffer: buffer))
                    }
                }
            }

            await self.detach(reason: nil)
        } catch {
            await self.detach(reason: "\(error)")
        }
    }

    private func attach(_ writer: TTYStdinWriter) {
        self.writer = writer
        onStateChange(.connected)
    }

    private func detach(reason: String?) {
        writer = nil
        client = nil
        runTask = nil
        if !isCancelled {
            onStateChange(.disconnected(reason))
        }
    }

    // MARK: - Input / resize

    public func send(_ data: Data) {
        guard let writer else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        Task { try? await writer.write(buffer) }
    }

    public func resize(columns: Int, rows: Int) {
        guard let writer, columns > 0, rows > 0 else { return }
        Task {
            try? await writer.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    public func disconnect() {
        isCancelled = true
        runTask?.cancel()
        let client = self.client
        self.client = nil
        self.writer = nil
        Task { try? await client?.close() }
        onStateChange(.disconnected(nil))
    }
}
