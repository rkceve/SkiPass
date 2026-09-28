import XCTest

/// Exactly one complete/cancel per credential request, across every path.
@MainActor
final class ExtensionRequestGateTests: XCTestCase {

    /// Terminal calls in order, e.g. "complete:a", "cancel".
    @MainActor private final class Terminals {
        var calls: [String] = []
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func run(_ gate: ExtensionRequestGate, _ terminals: Terminals,
                     delay: UInt64 = 0, value: String?) {
        gate.run(
            resolve: { () async -> String? in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                return value
            },
            complete: { terminals.calls.append("complete:\($0)") },
            cancel: { terminals.calls.append("cancel") }
        )
    }

    func testResolvedValueCompletesExactlyOnce() async {
        let gate = ExtensionRequestGate()
        let terminals = Terminals()
        run(gate, terminals, value: "123456")
        await waitUntil { !gate.isPending }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminals.calls, ["complete:123456"])
    }

    func testNoValueCancelsExactlyOnce() async {
        let gate = ExtensionRequestGate()
        let terminals = Terminals()
        run(gate, terminals, value: nil)
        await waitUntil { !gate.isPending }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminals.calls, ["cancel"])
    }

    func testSupersededRequestNeverReachesTheContext() async {
        let gate = ExtensionRequestGate()
        let terminals = Terminals()
        run(gate, terminals, delay: 300_000_000, value: "old")
        run(gate, terminals, value: "new")
        await waitUntil { !gate.isPending }
        // Let the superseded work finish too; it must not add a terminal call.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(terminals.calls, ["complete:new"])
    }

    func testFinishRunsOnlyOncePerTicketAndIgnoresStaleTickets() {
        let gate = ExtensionRequestGate()
        var count = 0
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.finish(first) { count += 1 }, "superseded ticket")
        XCTAssertTrue(gate.finish(second) { count += 1 })
        XCTAssertFalse(gate.finish(second) { count += 1 }, "already finished")
        XCTAssertEqual(count, 1)
        XCTAssertFalse(gate.isPending)
    }

    func testManyConcurrentFinishAttemptsRunOneTerminal() async {
        let gate = ExtensionRequestGate()
        let ticket = gate.begin()
        let terminals = Terminals()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { @MainActor in
                    _ = gate.finish(ticket) { terminals.calls.append("finish:\(index)") }
                }
            }
        }
        XCTAssertEqual(terminals.calls.count, 1)
    }

    func testImmediateCancelPathAndLaterRequestEachGetOneTerminal() async {
        let gate = ExtensionRequestGate()
        let terminals = Terminals()
        gate.finishNow { terminals.calls.append("cancel:unsupported") }
        XCTAssertFalse(gate.isPending)
        run(gate, terminals, value: "654321")
        await waitUntil { !gate.isPending }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(terminals.calls, ["cancel:unsupported", "complete:654321"])
    }
}
