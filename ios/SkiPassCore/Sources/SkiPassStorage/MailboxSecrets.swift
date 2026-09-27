import Foundation

/// Per-mailbox secrets (docs/ARCHITECTURE.md §5):
/// - `password.<mailboxID>` → UTF-8 IMAP password
/// - `oauth.<mailboxID>` → NSKeyedArchiver data of AppAuth `OIDAuthState` (opaque here;
///   SkiPassStorage does not import AppAuth).
public struct CredentialStore: Sendable {
    private let secrets: any SecretStoring

    public init(secrets: any SecretStoring = KeychainStore()) {
        self.secrets = secrets
    }

    public func setIMAPPassword(_ password: String, for mailboxID: UUID) throws {
        try secrets.setData(Data(password.utf8), account: StorageConstants.KeychainAccount.password(mailboxID))
    }

    public func imapPassword(for mailboxID: UUID) throws -> String? {
        guard let data = try secrets.data(account: StorageConstants.KeychainAccount.password(mailboxID)) else {
            return nil
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidPasswordEncoding
        }
        return password
    }

    public func setOAuthStateData(_ data: Data, for mailboxID: UUID) throws {
        try secrets.setData(data, account: StorageConstants.KeychainAccount.oauth(mailboxID))
    }

    public func oauthStateData(for mailboxID: UUID) throws -> Data? {
        try secrets.data(account: StorageConstants.KeychainAccount.oauth(mailboxID))
    }

    /// Deletes both the password and the OAuth state of a mailbox.
    public func removeAll(for mailboxID: UUID) throws {
        try secrets.delete(account: StorageConstants.KeychainAccount.password(mailboxID))
        try secrets.delete(account: StorageConstants.KeychainAccount.oauth(mailboxID))
    }
}
