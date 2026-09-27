import Foundation
import SkiPassModels
@testable import SkiPassStorage
import XCTest

/// In-memory stand-in for the Keychain. SPM test bundles run without the
/// keychain-access-group entitlement, so the real `KeychainStore` is not exercised here.
final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func setData(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
    }

    func data(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }

    var accounts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(items.keys)
    }
}

final class MailboxStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "SkiPassStorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func gmail(_ address: String = "a@gmail.com") -> MailboxConfig {
        MailboxConfig(address: address, kind: .google, imapHost: "imap.gmail.com", imapPort: 993, username: address)
    }

    func testEmptyListByDefault() throws {
        XCTAssertEqual(try MailboxStore(defaults: defaults).list(), [])
    }

    func testAddUpdateRemove() throws {
        let store = MailboxStore(defaults: defaults)
        var box = gmail()
        let other = MailboxConfig(address: "me@icloud.com", kind: .imap, imapHost: "imap.mail.me.com",
                                  imapPort: 993, username: "me")
        try store.add(box)
        try store.add(other)
        XCTAssertEqual(try store.list(), [box, other])

        box.address = "b@gmail.com"
        try store.update(box)
        XCTAssertEqual(try store.list().first?.address, "b@gmail.com")

        try store.remove(id: box.id)
        XCTAssertEqual(try store.list(), [other])
    }

    func testDuplicateAndMissingIDsThrow() throws {
        let store = MailboxStore(defaults: defaults)
        let box = gmail()
        try store.add(box)
        XCTAssertThrowsError(try store.add(box)) {
            XCTAssertEqual($0 as? StorageError, .mailboxAlreadyExists(box.id))
        }
        let missing = gmail("x@gmail.com")
        XCTAssertThrowsError(try store.update(missing)) {
            XCTAssertEqual($0 as? StorageError, .mailboxNotFound(missing.id))
        }
        XCTAssertThrowsError(try store.remove(id: missing.id))
    }

    func testPersistsAsJSONArrayUnderContractKey() throws {
        let box = gmail()
        try MailboxStore(defaults: defaults).add(box)
        let data = try XCTUnwrap(defaults.data(forKey: "mailboxes.v1"))
        XCTAssertEqual(try JSONDecoder().decode([MailboxConfig].self, from: data), [box])
        // A second store instance over the same defaults (app vs. extension) sees the same list.
        XCTAssertEqual(try MailboxStore(defaults: defaults).list(), [box])
    }
}

final class AppGroupStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "SkiPassStorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRevenueCatAppUserID() {
        let state = AppGroupState(defaults: defaults)
        XCTAssertNil(state.revenueCatAppUserID)
        state.revenueCatAppUserID = "$RCAnonymousID:abc"
        XCTAssertEqual(defaults.string(forKey: "rc.appUserID"), "$RCAnonymousID:abc")
        XCTAssertEqual(AppGroupState(defaults: defaults).revenueCatAppUserID, "$RCAnonymousID:abc")
    }

    func testUsageSnapshotRoundTrip() throws {
        let state = AppGroupState(defaults: defaults)
        XCTAssertNil(state.usageSnapshot())
        // Shape of docs/API.md `GET /v1/usage` example.
        let resetsAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let snapshot = UsageSnapshot(plan: "free", used: 3, limit: 10, resetsAt: resetsAt)
        try state.setUsageSnapshot(snapshot)
        XCTAssertNotNil(defaults.data(forKey: "usage.snapshot.v1"))
        XCTAssertEqual(state.usageSnapshot(), snapshot)
        try state.setUsageSnapshot(nil)
        XCTAssertNil(state.usageSnapshot())
    }
}

final class CredentialStoreTests: XCTestCase {
    func testPasswordAndOAuthStateUseContractAccounts() throws {
        let secrets = InMemorySecrets()
        let store = CredentialStore(secrets: secrets)
        let id = try XCTUnwrap(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))

        XCTAssertNil(try store.imapPassword(for: id))
        XCTAssertNil(try store.oauthStateData(for: id))

        try store.setIMAPPassword("abcd-efgh-ijkl-mnop", for: id)
        try store.setOAuthStateData(Data([1, 2, 3]), for: id)

        XCTAssertEqual(try store.imapPassword(for: id), "abcd-efgh-ijkl-mnop")
        XCTAssertEqual(try store.oauthStateData(for: id), Data([1, 2, 3]))
        XCTAssertEqual(secrets.accounts, [
            "password.E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "oauth.E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        ])
        XCTAssertEqual(try secrets.data(account: "password.E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
                       Data("abcd-efgh-ijkl-mnop".utf8))
    }

    func testOverwriteAndRemoveAll() throws {
        let secrets = InMemorySecrets()
        let store = CredentialStore(secrets: secrets)
        let a = UUID(), b = UUID()
        try store.setIMAPPassword("one", for: a)
        try store.setIMAPPassword("two", for: a)
        try store.setIMAPPassword("other", for: b)
        try store.setOAuthStateData(Data([9]), for: a)
        XCTAssertEqual(try store.imapPassword(for: a), "two")

        try store.removeAll(for: a)
        XCTAssertNil(try store.imapPassword(for: a))
        XCTAssertNil(try store.oauthStateData(for: a))
        XCTAssertEqual(try store.imapPassword(for: b), "other")
    }

    func testNonUTF8PasswordThrows() throws {
        let secrets = InMemorySecrets()
        let id = UUID()
        try secrets.setData(Data([0xFF, 0xFE, 0xFD]), account: "password.\(id.uuidString)")
        XCTAssertThrowsError(try CredentialStore(secrets: secrets).imapPassword(for: id)) {
            XCTAssertEqual($0 as? StorageError, .invalidPasswordEncoding)
        }
    }

    func testKeychainStoreDefaultsMatchContract() {
        // The access group is resolved at runtime (SharedStorageResolverTests); the canonical
        // names stay those of docs/ARCHITECTURE.md §1 / §5.
        let keychain = KeychainStore(accessGroup: StorageConstants.keychainAccessGroup)
        XCTAssertEqual(keychain.service, "io.github.rkceve.skipass")
        XCTAssertEqual(keychain.accessGroup, "group.io.github.rkceve.skipass")
        XCTAssertEqual(StorageConstants.appGroupID, "group.io.github.rkceve.skipass")
    }
}
