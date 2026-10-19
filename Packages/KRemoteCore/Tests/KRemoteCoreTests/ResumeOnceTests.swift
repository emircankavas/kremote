import XCTest
@testable import KRemoteCore

/// Guards the crash beta.5 shipped: two racing sources resumed one continuation
/// and `CheckedContinuation.resume` trapped with SIGTRAP.
final class ResumeOnceTests: XCTestCase {

    func testOnlyTheFirstCallResumes() async throws {
        let value = try await withCheckedThrowingContinuation { continuation in
            let state = ResumeOnce<Int, Error>(continuation)
            // Two racers, the first explicitly, the second from a queue — the
            // shape of read-versus-timeout.
            XCTAssertTrue(state.finish(.success(1)))
            let second = DispatchQueue.global()
            second.async {
                XCTAssertFalse(state.finish(.success(2)))
            }
        }
        XCTAssertEqual(value, 1)
    }

    func testManyRacingCallersResumeExactlyOnce() async throws {
        let results = try await withCheckedThrowingContinuation { continuation in
            let state = ResumeOnce<Int, Error>(continuation)
            let group = DispatchGroup()
            for index in 0..<50 {
                DispatchQueue.global().async(group: group) {
                    state.finish(.success(index))
                }
            }
            group.notify(queue: .global()) {
                // Nothing left to do: the continuation was already resumed by
                // whichever racer won.
            }
        }
        XCTAssertTrue((0..<50).contains(results))
    }

    func testTimeoutPathReportsATypedError() async {
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                let state = ResumeOnce<Data?, Error>(continuation)
                // Simulate the timeout winning, then the late read arriving.
                state.finish(.failure(SFTPError.connectionClosed("timed out")))
                state.finish(.success(Data("late".utf8)))
            }
            XCTFail("expected a timeout error")
        } catch let error as SFTPError {
            guard case .connectionClosed(let reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(reason, "timed out")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
