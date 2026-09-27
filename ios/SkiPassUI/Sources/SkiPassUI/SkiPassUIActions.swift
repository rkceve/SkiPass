import Foundation

/// Side effects the UI asks the host app to perform. The app target injects
/// the real implementation; the UI package does no networking or storage.
@MainActor
public protocol SkiPassUIActions: AnyObject {
    /// The app decides google / microsoft (opens the official sign-in) vs imap.
    /// Throw `SkiPassUIError.needsServerSettings` to continue with the IMAP form.
    func addAccount(email: String) async throws -> MailAccount
    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount
    func deleteAccount(id: UUID) async throws
    func revealPassword(id: UUID) async -> String?
    func selectPlan(id: String) async
}
