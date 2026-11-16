import Foundation

/// Holds a closure and its result while it runs on another thread.
private final class LargeStackBox<T>: @unchecked Sendable {
    var result: Result<T, CQLError>?
    let body: () throws(CQLError) -> T
    init(_ body: @escaping () throws(CQLError) -> T) { self.body = body }

    func run() {
        do throws(CQLError) {
            result = .success(try body())
        } catch {
            result = .failure(error)
        }
    }
}

/// Runs `body` synchronously on a thread with a large stack.
///
/// Matching ⊢ filters and walking long games is recursive, with a depth
/// proportional to the length of the game. Secondary threads (including Swift
/// concurrency and test threads) often have stacks of only 512 KB, which a
/// few hundred plies can exhaust.
func withLargeStack<T>(size: Int = 512 << 20, _ body: @escaping () throws(CQLError) -> T) throws(CQLError) -> T {
    let box = LargeStackBox(body)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.run()
        done.signal()
    }
    thread.stackSize = size
    thread.start()
    done.wait()
    return try box.result!.get()
}
