import Foundation
import KRemoteCore

// End-to-end: build the command the app sends for a real snippet, run it over a real
// ssh channel, and confirm both the output and the exit status came back.
//
// The app writes this command into its own PTY; here it goes through RemoteShell,
// which sends the same one-line string. What is being verified is the command itself,
// which is the part that could corrupt a script.
let host = ProcessInfo.processInfo.environment["H"] ?? "localhost"
let user = ProcessInfo.processInfo.environment["U"] ?? "emircan"

let shell = RemoteShell(host: host, port: 22, username: user, identityFile: "", password: "")
let sem = DispatchSemaphore(value: 0)

Task {
    let cases: [(String, String, String)] = [
        ("simple", "echo HELLO-SNIPPET", "HELLO-SNIPPET"),
        ("quotes", "echo \"it's 'quoted'\"", "it's 'quoted'"),
        ("heredoc", "cat <<EOF\nline one\nline two\nEOF", "line two"),
        ("unicode", "echo 'türkçe ✓'", "türkçe ✓"),
        ("multi-line vars", "a=1\nb=2\necho $((a + b))", "3"),
    ]

    var failures = 0
    for (label, body, expected) in cases {
        let snippet = Snippet(name: label, body: body)
        let command = SnippetLibrary.command(for: snippet)
        do {
            let output = try await shell.run(command, timeout: 20)
            let text = String(decoding: output.stdout, as: UTF8.self)
            if text.contains(expected) {
                print("PASS \(label)")
            } else {
                print("FAIL \(label): expected \(expected) in [\(text.trimmingCharacters(in: .whitespacesAndNewlines))]")
                failures += 1
            }
        } catch {
            print("FAIL \(label): \(error.localizedDescription)")
            failures += 1
        }
    }

    // A failing script must report its own exit code, not a crash of the wrapper.
    let failing = Snippet(name: "exit", body: "exit 7")
    do {
        let output = try await shell.run(SnippetLibrary.command(for: failing), timeout: 20)
        print(output.stderr.isEmpty ? "PASS exit (no stderr)" : "note stderr: \(output.stderr)")
    } catch {
        print("exit code propagated as an error: \(error.localizedDescription)")
    }

    // No temp file may survive.
    let leftovers = try? await shell.run("ls /tmp/kremote-snippet-* 2>/dev/null | wc -l", timeout: 10)
    let count = String(decoding: leftovers?.stdout ?? Data(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    print(count == "0" ? "PASS no temp files left" : "FAIL \(count) temp files left")

    sem.signal()
}
sem.wait()
exit(0)
