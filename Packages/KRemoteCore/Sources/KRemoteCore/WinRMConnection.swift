import Foundation
#if canImport(Network)
import Network
#endif

/// One HTTP/1.1 connection to a WinRM listener, plain or TLS.
///
/// A socket that stays open across the whole conversation, because WinRM binds its
/// NTLM challenge to the connection that issued it: answering on a new connection is
/// refused with 401 even for a byte-identical message. `URLSession` cannot pin a
/// connection across two requests, which is why this is written by hand.
///
/// Two transports, one shape:
/// - plaintext on 5985, over a POSIX socket;
/// - TLS on 5986, over `NWConnection`. Secure Transport would be the obvious choice
///   and is deprecated since macOS 10.15, with Swift names that no longer match its
///   headers.
///
/// The transport is chosen once, at construction, and never mixed afterwards.
final class WinRMConnection {
    struct Response {
        let status: Int
        let headers: String
        let body: Data
    }

    private enum Transport {
        case plain(descriptor: Int32)
        #if canImport(Network)
        case tls(NWConnection, queue: DispatchQueue)
        #endif
    }

    private let transport: Transport

    init(host: String, port: Int, timeout: TimeInterval, useTLS: Bool) throws {
        if useTLS {
            #if canImport(Network)
            let tls = NWProtocolTLS.Options()
            // A WinRM HTTPS listener uses a certificate made by `New-WSManInstance`,
            // which no trust store knows; verifying it would make this work on no
            // default Windows install. The password is still encrypted in transit,
            // which is what 5986 is for. Identity pinning is not pretended here.
            let queue = DispatchQueue(label: "com.emircankavas.kremote.winrm.tls")
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue
            )
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                throw WinRMError.unreachable("\(port) is not a valid port.")
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            )

            let ready = DispatchSemaphore(value: 0)
            var failure: String?
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.signal()
                case .failed(let error):
                    failure = error.localizedDescription
                    ready.signal()
                // `.waiting` is not a terminal state, but a refused connection sits
                // here forever without ever failing. Surfacing it turns a five-second
                // silent timeout into an explanation, and a refused port is the most
                // common reason a WinRM badge stays empty.
                case .waiting(let error):
                    failure = error.localizedDescription
                    ready.signal()
                case .cancelled:
                    ready.signal()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            if ready.wait(timeout: .now() + timeout) == .timedOut {
                connection.cancel()
                throw WinRMError.unreachable("The TLS connection timed out.")
            }
            if let failure {
                connection.cancel()
                throw WinRMError.unreachable("TLS failed: \(failure)")
            }
            transport = .tls(connection, queue: queue)
            #else
            throw WinRMError.unreachable("TLS is not available on this platform.")
            #endif
        } else {
            transport = .plain(descriptor: try Self.openSocket(host: host, port: port, timeout: timeout))
        }
    }

    func close() {
        switch transport {
        case .plain(let descriptor):
            _ = Darwin.close(descriptor)
        #if canImport(Network)
        case .tls(let connection, _):
            connection.cancel()
        #endif
        }
    }

    /// Sends one request and reads exactly one response.
    func request(path: String, contentType: String, authorization: String, body: String) throws -> Response {
        var text = "POST \(path) HTTP/1.1\r\n"
        text += "Host: localhost\r\n"
        text += "Content-Type: \(contentType)\r\n"
        text += "Content-Length: \(body.utf8.count)\r\n"
        text += "Connection: keep-alive\r\n"
        if !authorization.isEmpty {
            text += "Authorization: \(authorization)\r\n"
        }
        text += "\r\n"
        text += body

        try send(Data(text.utf8))

        var buffer = Data()
        var headerEnd: Int?
        var contentLength = 0

        while true {
            // Stop as soon as the declared body is complete. A 401 carries
            // `Content-Length: 0`, and waiting for one more read after a complete
            // answer spends the whole read timeout doing nothing — which surfaced as
            // "the server did not answer in time" on a server that had answered.
            if let start = headerEnd, buffer.count >= start + contentLength { break }

            guard let chunk = try receive(maxLength: 16_384) else { break }
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if headerEnd == nil, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                for line in head.components(separatedBy: "\r\n")
                where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.components(separatedBy: ":").last?
                        .trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                }
            }
        }

        let all = String(decoding: buffer, as: UTF8.self)
        let head = all.components(separatedBy: "\r\n\r\n").first ?? ""
        let statusLine = head.components(separatedBy: "\r\n").first ?? ""
        let status = Int(statusLine.components(separatedBy: " ").dropFirst().first ?? "0") ?? 0

        var bodyData = Data()
        if let start = headerEnd, buffer.count > start {
            bodyData = buffer.subdata(in: start..<buffer.count)
        }
        return Response(status: status, headers: head, body: bodyData)
    }

    // MARK: - Transport plumbing

    private func send(_ data: Data) throws {
        switch transport {
        case .plain(let descriptor):
            let bytes = [UInt8](data)
            var sent = 0
            while sent < bytes.count {
                let written = bytes.withUnsafeBufferPointer {
                    Darwin.write(descriptor, $0.baseAddress! + sent, bytes.count - sent)
                }
                guard written > 0 else {
                    throw WinRMError.unreachable("The connection was closed while sending.")
                }
                sent += written
            }

        #if canImport(Network)
        case .tls(let connection, _):
            let done = DispatchSemaphore(value: 0)
            var failure: String?
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { failure = error.localizedDescription }
                done.signal()
            })
            if done.wait(timeout: .now() + 20) == .timedOut {
                throw WinRMError.unreachable("The TLS write timed out.")
            }
            if let failure { throw WinRMError.unreachable("TLS write failed: \(failure)") }
        #endif
        }
    }

    private func receive(maxLength: Int) throws -> Data? {
        switch transport {
        case .plain(let descriptor):
            var chunk = [UInt8](repeating: 0, count: maxLength)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 { throw WinRMError.unreachable("The server did not answer in time.") }
            if count == 0 { return nil }
            return Data(chunk[0..<count])

        #if canImport(Network)
        case .tls(let connection, _):
            let done = DispatchSemaphore(value: 0)
            var result: Data?
            var failure: String?
            var completed = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error { failure = error.localizedDescription }
                result = data
                completed = isComplete
                done.signal()
            }
            if done.wait(timeout: .now() + 25) == .timedOut {
                throw WinRMError.unreachable("The TLS read timed out.")
            }
            if let failure { throw WinRMError.unreachable("TLS read failed: \(failure)") }
            if result == nil, completed { return nil }
            return result
        #endif
        }
    }

    /// Opens a plain TCP socket to the first address that accepts a connection.
    ///
    /// Tries every address the name resolves to, IPv4 and IPv6, in the order the
    /// system prefers. A Windows WinRM listener bound to `::` reports IPv6 only, and
    /// a client that dialled IPv4 exclusively could never reach it — which is exactly
    /// what a `LocalAddress ::` listener in `Get-NetTCPConnection` means.
    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw WinRMError.unreachable(
                "Could not resolve \"\(host)\"\(status == 0 ? "" : " (error \(status))")."
            )
        }
        defer { freeaddrinfo(result) }

        var lastFailure = "no address to try"
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            let family = entry.pointee.ai_family
            guard family == AF_INET || family == AF_INET6,
                  let address = entry.pointee.ai_addr else { continue }

            let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
            if descriptor < 0 {
                lastFailure = "could not open a socket"
                continue
            }

            var seconds = Int(timeout)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<Int>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &seconds, socklen_t(MemoryLayout<Int>.size))

            let connected = Darwin.connect(descriptor, address, entry.pointee.ai_addrlen)
            if connected == 0 { return descriptor }

            // Report what actually happened: "refused" and "timed out" point at
            // different fixes (no listener vs. a firewall dropping the packet).
            lastFailure = String(cString: strerror(errno))
            _ = Darwin.close(descriptor)
        }

        throw WinRMError.unreachable(
            "Could not reach \(host):\(port) — \(lastFailure). "
                + "Check that WinRM is listening on that port and that the firewall allows it."
        )
    }

}
