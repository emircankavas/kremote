import XCTest
@testable import KRemoteCore

/// Path arithmetic for tree transfers.
///
/// Every case here guards a bug that only appears off the happy path: a symlinked
/// temp directory, a trailing slash, a root that is also a prefix of a sibling name.
final class TransferPathTests: XCTestCase {

    func testRelativeComponentsStripTheRoot() {
        XCTAssertEqual(
            SFTPClient.relativeComponents(of: "/srv/tree/a/b.txt", under: "/srv/tree"),
            ["a", "b.txt"]
        )
        XCTAssertEqual(
            SFTPClient.relativeComponents(of: "/srv/tree", under: "/srv/tree"),
            []
        )
    }

    /// `/srv/tree-upload` must not be read as "inside /srv/tree" — the classic
    /// prefix bug. Component comparison gets this right; string prefix does not.
    func testSiblingWithTheSamePrefixIsNotInside() {
        XCTAssertFalse(SFTPClient.isInside("/srv/tree-upload", root: "/srv/tree"))
        XCTAssertTrue(SFTPClient.isInside("/srv/tree", root: "/srv/tree"))
        XCTAssertTrue(SFTPClient.isInside("/srv/tree/a", root: "/srv/tree"))
        // Not under the root at all: the last component is used rather than a
        // truncated middle, so a file never lands in a nonsense folder.
        XCTAssertEqual(SFTPClient.relativeComponents(of: "/other/place/x.txt", under: "/srv/tree"), ["x.txt"])
    }

    func testTrailingSlashAndDotComponentsDoNotConfuseTheRoot() {
        XCTAssertEqual(
            SFTPClient.relativeComponents(of: "/srv/tree/./a//b.txt", under: "/srv/tree/"),
            ["a", "b.txt"]
        )
    }

    /// The live bug: `walkLocal` trimmed a prefix off a *resolved* path while the
    /// root had been given symlinked. Both forms must describe the same tree.
    func testWalkLocalUsesTheSameRootItWasGiven() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kremote-walk-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: nested.appendingPathComponent("two.txt"))
        try Data("y".utf8).write(to: base.appendingPathComponent("root.txt"))

        let files = try SFTPClient.walkLocal(base)
        XCTAssertEqual(Set(files.map(\.relativePath)), ["/root.txt", "/a/b/two.txt"])
        XCTAssertTrue(files.allSatisfy { $0.size > 0 })
    }

    /// A root that is itself a symlink must still produce the tree below it, with
    /// no fragment of the resolved path leaking into a filename.
    func testWalkLocalThroughASymlinkedRoot() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kremote-link-\(UUID().uuidString)")
        let real = parent.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("z".utf8).write(to: real.appendingPathComponent("sub/file.txt"))

        let files = try SFTPClient.walkLocal(link)
        XCTAssertEqual(files.map(\.relativePath), ["/sub/file.txt"])
    }
}
