@testable import SkiPassUI
import XCTest

@MainActor
private final class StubActions: SkiPassUIActions {
    func addAccount(email: String) async throws -> MailAccount { throw SkiPassUIError.needsServerSettings }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        MailAccount(id: PreviewData.infoAccountID, address: address, kind: .imap, status: .connected, server: settings)
    }

    func deleteAccount(id: UUID) async throws {}
    func revealPassword(id: UUID) async -> String? { nil }
    func selectPlan(id: String) async {}
}

@MainActor
final class SkiPassUIStoreTests: XCTestCase {
    /// Saving an account (new password) must hide a revealed password on the expanded card.
    func testSavingAnAccountChangesItsPasswordRevision() async throws {
        let store = SkiPassUIStore(accounts: [PreviewData.infoAccount], plans: [], usage: nil, actions: StubActions())
        let before = store.passwordRevision(for: PreviewData.infoAccountID)

        try await store.saveIMAP(address: "info@myshop.jp",
                                 settings: PreviewData.infoAccount.server!, password: "new")

        XCTAssertNotEqual(store.passwordRevision(for: PreviewData.infoAccountID), before)
        XCTAssertEqual(store.passwordRevision(for: PreviewData.supportAccountID), 0)
    }

    func testPlansAreAvailableUnlessTheHostSaysOtherwise() {
        XCTAssertTrue(SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: StubActions()).plansAvailable)
        XCTAssertFalse(SkiPassUIStore(accounts: [], plans: [], usage: nil, plansAvailable: false,
                                      actions: StubActions()).plansAvailable)
    }
}

final class CopyErrorMessageTests: XCTestCase {
    /// A cancelled provider sign-in shows nothing.
    func testCancellationShowsNothing() {
        XCTAssertNil(Copy.errorMessage(for: CancellationError()))
    }

    /// Messages come from Copy, never from a raw `localizedDescription`.
    func testErrorsMapToCopyStrings() {
        XCTAssertEqual(Copy.errorMessage(for: SkiPassUIError.googleSignInNotConfigured),
                       "Google sign-in is not configured in this build.")
        XCTAssertEqual(Copy.errorMessage(for: SkiPassUIError.microsoftSignInNotConfigured),
                       "Microsoft sign-in is not configured in this build.")
        XCTAssertEqual(Copy.errorMessage(for: SkiPassUIError.signInFailed), Copy.signInFailed)
        XCTAssertEqual(Copy.errorMessage(for: SkiPassUIError.saveFailed), Copy.saveFailed)
        XCTAssertEqual(Copy.errorMessage(for: SkiPassUIError.deleteFailed), Copy.deleteFailed)
        let raw = NSError(domain: "SkiPassStorage.StorageError", code: 3)
        XCTAssertEqual(Copy.errorMessage(for: raw), Copy.errorTryAgain)
    }

    func testFreePlanRowHasCopy() {
        let free = PlanOption.free(isCurrent: true)
        XCTAssertEqual(free.id, "free")
        XCTAssertFalse(free.name.isEmpty)
        XCTAssertFalse(free.tagline.isEmpty)
        XCTAssertFalse(free.priceText.isEmpty)
        XCTAssertEqual(PlanOption.paidPlanName(planID: "pro"), "Pro")
        XCTAssertEqual(PlanOption.paidPlanName(planID: "standard"), "Standard")
        XCTAssertNil(PlanOption.paidPlanName(planID: "free"))
    }
}
