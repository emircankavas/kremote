import Foundation

/// Resumes a continuation exactly once, no matter how many racing sources try.
///
/// `CheckedContinuation.resume` traps on a second call, and the trap is a
/// `SIGTRAP` deep inside libswift_Concurrency — a crash report that names
/// `CheckedContinuation.resume` but not the code that called it twice. Racing a
/// blocking read against a timeout is exactly the shape that produces this, so
/// the "only one wins" rule lives here, in one tested place.
///
/// The mutex guards a plain `Bool`; `finish` returns whether *this* call was the
/// one that resumed, so the caller can do follow-up work (closing the pipe) only
/// on the winning branch.
final class ResumeOnce<Success, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<Success, Failure>?

    init(_ continuation: CheckedContinuation<Success, Failure>) {
        self.continuation = continuation
    }

    /// Returns true when this call resumed the continuation, false when some
    /// earlier call already did.
    @discardableResult
    func finish(_ result: Result<Success, Failure>) -> Bool {
        let taken: CheckedContinuation<Success, Failure>? = lock.withLock {
            guard !hasResumed, let pending = continuation else { return nil }
            hasResumed = true
            continuation = nil
            return pending
        }
        guard let taken else { return false }
        taken.resume(with: result)
        return true
    }
}
