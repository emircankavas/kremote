import XCTest
@testable import KRemoteCore

final class SSHCommandBuilderTests: XCTestCase {

    func testBasicArguments() {
        let builder = SSHCommandBuilder(host: "10.0.31.11", port: 22, username: "ansibleAdmin")
        let args = builder.arguments

        XCTAssertEqual(args.first, "ssh")
        XCTAssertEqual(args.last, "ansibleAdmin@10.0.31.11")
        // Default port 22 must not add -p.
        XCTAssertFalse(args.contains("-p"))
    }

    func testCustomPortAddsFlag() {
        let builder = SSHCommandBuilder(host: "h", port: 2222, username: "u")
        let args = builder.arguments
        let index = try? XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertNotNil(index)
        if let index { XCTAssertEqual(args[index + 1], "2222") }
    }

    func testNoUsernameUsesBareHost() {
        let builder = SSHCommandBuilder(host: "example.com")
        XCTAssertEqual(builder.arguments.last, "example.com")
        XCTAssertEqual(builder.displayTarget, "example.com")
    }

    func testPasswordNeverAppearsInArgv() {
        // The builder has no password field at all by design: argv is visible via ps.
        let builder = SSHCommandBuilder(host: "h", username: "u", additionalOptions: ["-o", "ConnectTimeout=5"])
        let joined = builder.arguments.joined(separator: " ")
        XCTAssertFalse(joined.lowercased().contains("password="))
        XCTAssertTrue(joined.contains("ConnectTimeout=5"))
    }

    func testOffersTheWideAuthenticationSet() {
        let joined = SSHCommandBuilder(host: "h").arguments.joined(separator: " ")
        // The whole point of using system ssh: these methods are all reachable.
        for method in ["publickey", "password", "keyboard-interactive", "gssapi-with-mic"] {
            XCTAssertTrue(joined.contains(method), "missing auth method \(method)")
        }
    }

    func testPasswordPromptDetection() {
        XCTAssertTrue(SSHPtySession.looksLikePasswordPrompt("ansibleAdmin@10.0.31.11's password:"))
        XCTAssertTrue(SSHPtySession.looksLikePasswordPrompt("Password: "))
        XCTAssertFalse(SSHPtySession.looksLikePasswordPrompt("Welcome to Ubuntu 22.04"))
        XCTAssertFalse(SSHPtySession.looksLikePasswordPrompt("Authenticated to 10.0.31.11"))
    }

    func testSSHPathExists() {
        // On macOS the system ssh is always at /usr/bin/ssh.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: SSHPtySession.sshPath))
    }
}
