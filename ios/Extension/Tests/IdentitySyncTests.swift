import XCTest
import SkiPassModels

/// A2-12 / A2-13: identity registration never runs twice at once, always ends with the latest state,
/// and a mailbox list that cannot be read does not wipe the registered identities.
final class IdentitySyncTests: XCTestCase {

    /// Records how registrations overlap and which "state version" each one registered.
    private actor Recorder {
        var version = 0
        private(set) var registered: [Int] = []
        private(set) var running = 0
        private(set) var peakRunning = 0

        func bump() -> Int {
            version += 1
            return version
        }

        func register() async {
            running += 1
            peakRunning = max(peakRunning, running)
            let snapshot = version
            try? await Task.sleep(nanoseconds: 100_000_000)
            registered.append(snapshot)
            running -= 1
        }
    }

    func testRegistrationsNeverOverlapAndCoalesce() async {
        let recorder = Recorder()
        let coordinator = IdentitySyncCoordinator { await recorder.register() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.sync() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            for _ in 0..<10 {
                group.addTask { await coordinator.sync() }
            }
        }

        let peak = await recorder.peakRunning
        let registered = await recorder.registered
        XCTAssertEqual(peak, 1, "replaceCredentialIdentities calls must not overlap")
        XCTAssertEqual(registered.count, 2, "ten requests during a run share one follow-up run")
    }

    func testRequestReturnsOnlyAfterARunThatSawItsState() async {
        let recorder = Recorder()
        let coordinator = IdentitySyncCoordinator { await recorder.register() }

        let first = Task { await coordinator.sync() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        // A new domain is recorded while the first registration (older snapshot) is running.
        let newVersion = await recorder.bump()
        await coordinator.sync()
        await first.value

        let registered = await recorder.registered
        XCTAssertEqual(registered.last, newVersion, "the last registration uses the newest state")
    }

    func testUnreadableMailboxListKeepsExistingIdentities() {
        struct Corrupt: Error {}
        let box = MailboxConfig(address: "me@example.com", kind: .imap, imapHost: "imap.example.com",
                                imapPort: 993, username: "me")

        XCTAssertEqual(IdentitySyncInput.decide(appGroupResolved: true, list: { [box] }), .register(["me@example.com"]))
        XCTAssertEqual(IdentitySyncInput.decide(appGroupResolved: true, list: { [] }), .register([]))
        guard case .keepExisting = IdentitySyncInput.decide(appGroupResolved: true, list: { throw Corrupt() }) else {
            return XCTFail("a read failure must not look like 'no mailboxes'")
        }
        guard case .keepExisting = IdentitySyncInput.decide(appGroupResolved: false, list: { [box] }) else {
            return XCTFail("without an App Group this process cannot see the app's mailboxes")
        }
    }
}
