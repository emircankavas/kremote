import Foundation

/// Turns an operation failure into the text the SFTP window shows.
///
/// The rule the card asks for is that a permission failure must never be a dead
/// end: the alert has to say whether elevation was attempted, and if it was not
/// available, why not. That sentence depends on three things — the error, whether
/// the node is set up for sudo, and whether sudo was actually tried — so it is
/// decided here once, in the core, rather than being spelled out per view.
public enum OperationFailureText {

    /// What the window knows about the connection when it reports a failure.
    public struct Context: Sendable, Equatable {
        /// Whether sudo elevation is on offer for this connection.
        public var elevation: ElevationAvailability

        public init(elevation: ElevationAvailability) {
            self.elevation = elevation
        }

        /// Why elevation was not attempted, or nil when it was available.
        var unavailableReason: String? {
            switch elevation {
            case .available:
                return nil
            case .disabled:
                return "Sudo is not enabled for this connection, so no elevated retry was made. "
                    + "Turn on “Use sudo for refused file operations” in the connection's settings to try it as root."
            case .noPassword:
                return "This connection has no saved password, so sudo could not be run. "
                    + "Save the login password on the connection to let refused operations retry as root."
            }
        }
    }

    /// The alert title for a failed operation.
    public static func title(for error: Error, subject: String) -> String {
        if isPermissionDenied(error) { return "“\(subject)” needs administrator rights" }
        if isCancellation(error) { return "“\(subject)” was cancelled" }
        return "“\(subject)” could not be completed"
    }

    /// The alert body: the server's own words, plus one sentence about elevation
    /// when the failure was a refusal.
    public static func message(for error: Error, context: Context) -> String {
        let server = describe(error)
        guard isPermissionDenied(error) else { return server }

        // An `elevationFailed` already carries the elevated channel's own text,
        // so the retry did happen and its outcome is the whole story.
        if case .elevationFailed = error as? SFTPError ?? .invalidArgument("") {
            return server + "\n\nSudo elevation was attempted and did not succeed, so the operation was not retried again."
        }

        if let reason = context.unavailableReason {
            return server + "\n\n" + reason
        }
        // Its own type rather than a phrase: the alert for a refused operation
        // always names what happened to the elevation attempt.
        return server + "\n\nSudo elevation was not successful for this item; it was retried once as root and refused again."
    }

    public static func isPermissionDenied(_ error: Error) -> Bool {
        if case .status(.permissionDenied, _) = error as? SFTPError ?? .invalidArgument("") { return true }
        return false
    }

    public static func isCancellation(_ error: Error) -> Bool {
        error is TransferCancelled
    }

    /// The server's words; never a generic "failed".
    public static func describe(_ error: Error) -> String {
        if error is TransferCancelled { return "The transfer was cancelled." }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

/// One batch of file operations, with an exact account of what happened.
///
/// A recursive delete of twelve items that fails on the seventh must not open
/// seven modals, and must not say "delete failed" either: the user needs to know
/// which six succeeded and which one did not. That tally is this type, built as
/// the batch runs and shown once at the end.
public struct BatchOutcome: Sendable, Equatable {
    public struct Failure: Sendable, Equatable, Identifiable {
        public var name: String
        public var reason: String
        public var id: String { name }

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public private(set) var succeeded: [String] = []
    public private(set) var failures: [Failure] = []
    /// Set when the user cancelled mid-batch, so the summary can say so instead
    /// of implying the remaining items failed.
    public var wasCancelled = false
    /// Items never attempted because the batch was cancelled.
    public var skipped: [String] = []

    public init() {}

    public mutating func recordSuccess(_ name: String) {
        succeeded.append(name)
    }

    public mutating func recordFailure(_ name: String, error: Error) {
        failures.append(Failure(name: name, reason: OperationFailureText.describe(error)))
    }

    public var isEmpty: Bool { succeeded.isEmpty && failures.isEmpty && skipped.isEmpty }

    /// True when nothing went wrong and nothing was skipped.
    public var isCompleteSuccess: Bool {
        failures.isEmpty && skipped.isEmpty && !succeeded.isEmpty
    }

    /// The one-line headline for the summary sheet.
    public var headline: String {
        if succeeded.isEmpty && failures.count == 1 { return "1 item could not be completed" }
        if succeeded.isEmpty && failures.count > 1 { return "\(failures.count) items could not be completed" }
        if failures.isEmpty && skipped.isEmpty {
            return succeeded.count == 1 ? "1 item completed" : "\(succeeded.count) items completed"
        }
        var parts = ["\(succeeded.count) of \(succeeded.count + failures.count) items completed"]
        if wasCancelled { parts.append("the rest were cancelled") }
        return parts.joined(separator: "; ")
    }

    /// The detail body: successes listed by name, then each failure with the
    /// server's own reason. One alert, both lists.
    public var detail: String {
        var lines: [String] = []
        if !failures.isEmpty {
            lines.append("Failed:")
            lines.append(contentsOf: failures.map { "  \($0.name) — \($0.reason)" })
        }
        if !succeeded.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Completed:")
            lines.append(contentsOf: succeeded.map { "  \($0)" })
        }
        if !skipped.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Not attempted:")
            lines.append(contentsOf: skipped.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// The subset of the batch that failed, so a retry can act on exactly those.
    public var failedNames: [String] { failures.map(\.name) }
}
