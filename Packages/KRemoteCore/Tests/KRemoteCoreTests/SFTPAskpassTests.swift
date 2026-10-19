import XCTest
@testable import KRemoteCore

/// The password path that a real Linux server exposed: without a TTY, ssh needs
/// an `SSH_ASKPASS` helper and dies with "ssh_askpass: exec(...): No such file or
/// directory" when there is none. These tests cover the helper itself and its
/// lifecycle; the live connection test needs a password-auth server.
final class SFTPAskpassTests: XCTestCase {

    private var helperDirectory: URL?

    override func tearDownWithError() throws {
        if let helperDirectory {
            try? FileManager.default.removeItem(at: helperDirectory)
        }
        helperDirectory = nil
    }

    /// Runs the generated script the way ssh does — as a program, with no stdin —
    /// and checks that its stdout is exactly the password.
    func testHelperPrintsExactlyThePassword() throws {
        let password = "p@ss w0rd !$`\"'\\"
        let script = try ProcessSFTPTransport.makeAskpassHelper(password: password)
        helperDirectory = script.deletingLastPathComponent()

        let output = try run(script, arguments: ["password:"])
        XCTAssertEqual(output, password, "the helper must print the password and nothing else")
    }

    func testHelperSurvivesAUnicodePassword() throws {
        let password = "şifre-测试-🔐"
        let script = try ProcessSFTPTransport.makeAskpassHelper(password: password)
        helperDirectory = script.deletingLastPathComponent()
        XCTAssertEqual(try run(script, arguments: ["Password: "]), password)
    }

    func testHelperScriptIsNotWorldReadable() throws {
        let script = try ProcessSFTPTransport.makeAskpassHelper(password: "secret")
        helperDirectory = script.deletingLastPathComponent()

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: script.path)
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(fileMode & 0o077, 0, "the helper must not be readable by group/other")

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: helperDirectory!.path)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(directoryMode & 0o077, 0, "the helper's directory must not be readable by others")
    }

    private func run(_ script: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // ssh closes stdin for askpass; mirror that so a helper that waits for
        // input would hang here too (and be caught), rather than pass by accident.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the helper must exit 0")
        return String(decoding: data, as: UTF8.self)
    }
}
