import AppKit
import Foundation
import KRemoteCore

/// Downloads a release's `.zip`, swaps it in for the running bundle and restarts
/// the app.
///
/// The replacement cannot happen from inside the process that is being replaced,
/// so a small shell script is spawned detached: it waits for this process to
/// exit, swaps the bundle, clears the quarantine flag (the release is ad-hoc
/// signed, not notarized) and reopens the app.
enum UpdateService {
    enum UpdateError: LocalizedError {
        case noAsset
        case download(Int)
        case extract
        case noAppInArchive
        case notWritable(String)
        case versionMismatch(expected: String, found: String)

        var errorDescription: String? {
            switch self {
            case .noAsset:
                return "The release has no downloadable .zip to install."
            case .download(let code):
                return "The update could not be downloaded (HTTP \(code))."
            case .extract:
                return "The downloaded archive could not be expanded."
            case .noAppInArchive:
                return "The downloaded archive did not contain an application."
            case .notWritable(let path):
                return "The application folder is not writable: \(path). Update it by hand."
            case .versionMismatch(let expected, let found):
                return "The downloaded build reports version \(found), but the release is \(expected)."
            }
        }
    }

    /// Downloads, expands, replaces and relaunches; then terminates this process.
    static func downloadAndInstall(_ info: UpdateInfo) async throws {
        guard let assetURLString = info.assetURL, let assetURL = URL(string: assetURLString) else {
            throw UpdateError.noAsset
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kremote-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 1) Download.
        let (data, response) = try await URLSession.shared.data(from: assetURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.download(http.statusCode)
        }
        let zipURL = tmp.appendingPathComponent(info.assetName ?? "update.zip")
        try data.write(to: zipURL)

        // 2) Expand with ditto: it preserves resource forks and permissions, which
        //    `unzip` does not do reliably for .app bundles.
        let extractDir = tmp.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])

        // 3) Find the .app inside.
        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInArchive
        }

        // 3b) The archive must actually be the release we asked for. The
        //     marketing version is compared as text, so a pre-release tag
        //     ("1.8.0-beta.2") round-trips verbatim through the filename, the
        //     appcast and `CFBundleShortVersionString`.
        let bundledVersion = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            .flatMap { $0["CFBundleShortVersionString"] as? String }
        if let bundledVersion, bundledVersion != info.latestVersion {
            throw UpdateError.versionMismatch(expected: info.latestVersion, found: bundledVersion)
        }

        // 4) The installed bundle must be replaceable.
        let oldAppPath = Bundle.main.bundlePath
        let oldDir = URL(fileURLWithPath: oldAppPath).deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: oldDir.path) else {
            throw UpdateError.notWritable(oldDir.path)
        }

        // 5) Hand the swap to a detached script: it can only run once we exit.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = tmp.appendingPathComponent("apply.sh")
        let scriptBody = """
        #!/bin/bash
        # Runs after KRemote exits; swaps the bundle and relaunches it.
        LOG="$HOME/Library/Logs/KRemote-update.log"
        exec >> "$LOG" 2>&1
        echo "[$(date)] update script started, waiting for pid=\(pid)"
        n=0
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.3
            n=$((n+1))
            [ $n -gt 100 ] && break
        done
        echo "[$(date)] app exited, swapping"
        rm -rf "\(oldAppPath).old"
        mv "\(oldAppPath)" "\(oldAppPath).old"
        if cp -R "\(newApp.path)" "\(oldAppPath)"; then
            echo "[$(date)] copied"
        else
            echo "[$(date)] COPY FAILED - restoring"
            rm -rf "\(oldAppPath)"
            mv "\(oldAppPath).old" "\(oldAppPath)"
        fi
        xattr -dr com.apple.quarantine "\(oldAppPath)" 2>/dev/null
        rm -rf "\(oldAppPath).old"
        open "\(oldAppPath)" && echo "[$(date)] relaunched"
        rm -rf "\(tmp.path)"
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try runDetached("/bin/bash", [script.path])

        // 6) Quit. `terminate` can be blocked by a modal/sheet, so make it final.
        await MainActor.run { NSApplication.shared.terminate(nil) }
        exit(0)
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.extract }
    }

    private static func runDetached(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
    }
}
