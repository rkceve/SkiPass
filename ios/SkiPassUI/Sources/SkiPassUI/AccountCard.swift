import SwiftUI

/// One mailbox card. Tapping the summary row expands it in place (accordion).
struct AccountCard: View {
    let account: MailAccount
    let isExpanded: Bool
    let passwordRevision: Int
    let onToggle: @MainActor () -> Void
    let onEdit: @MainActor () -> Void
    let onDelete: @MainActor () async throws -> Void
    let revealPassword: @MainActor () async -> String?

    @State private var isConfirmingDelete: Bool
    @State private var isShowingError: Bool
    @State private var errorMessage: String
    @Namespace private var glassNamespace

    // Explicit init: SDK 27 may not synthesize a memberwise init for views with @State.
    init(
        account: MailAccount,
        isExpanded: Bool,
        passwordRevision: Int = 0,
        onToggle: @escaping @MainActor () -> Void,
        onEdit: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () async throws -> Void,
        revealPassword: @escaping @MainActor () async -> String?
    ) {
        self.account = account
        self.isExpanded = isExpanded
        self.passwordRevision = passwordRevision
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.revealPassword = revealPassword
        self.isConfirmingDelete = false
        self.isShowingError = false
        self.errorMessage = ""
    }

    var body: some View {
        VStack(spacing: 14) {
            AccountSummaryRow(account: account, isExpanded: isExpanded, onToggle: onToggle, glassNamespace: glassNamespace)

            if isExpanded {
                VStack(spacing: 14) {
                    if account.kind == .imap, let server = account.server {
                        ServerDetailsBox(
                            address: account.address,
                            server: server,
                            passwordRevision: passwordRevision,
                            revealPassword: revealPassword
                        )
                    }
                    // docs/ARCHITECTURE.md §2: Google / Microsoft cards show no server rows, Delete only.
                    AccountActionRow(
                        address: account.address,
                        showsEdit: account.kind == .imap,
                        onEdit: onEdit,
                        onDelete: { isConfirmingDelete = true },
                        glassNamespace: glassNamespace
                    )
                }
                .transition(CardMotion.expandedContent)
            }
        }
        // iOS 26+: the chevron and the Edit / Delete controls are glass in one container,
        // so the action glass morphs in and out as the card expands and collapses.
        // The card surface itself stays non-glass (content layer).
        .glassGroup(spacing: 14)
        .padding(16)
        .cardSurface()
        .confirmationDialog(Copy.deleteConfirmTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(Copy.delete, role: .destructive) {
                Task { await performDelete() }
            }
            // No accessibility identifier: on iOS 26 the dialog renders this action as a button
            // nested in a button and both inherit it, so identifier queries are ambiguous.
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(account.address)
        }
        // Errors from delete are shown in a plain alert.
        .alert(Copy.errorTitle, isPresented: $isShowingError) {
            Button(Copy.ok, role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func performDelete() async {
        do {
            try await onDelete()
        } catch {
            guard let message = Copy.errorMessage(for: error) else { return }
            errorMessage = message
            isShowingError = true
        }
    }
}

// MARK: - Summary row

private struct AccountSummaryRow: View {
    let account: MailAccount
    let isExpanded: Bool
    let onToggle: @MainActor () -> Void
    let glassNamespace: Namespace.ID

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                ProviderIcon(kind: account.kind)

                VStack(alignment: .leading, spacing: 6) {
                    Text(account.address)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        // Long addresses shrink a little before the middle is truncated.
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                    StatusLabel(kind: account.kind, status: account.status)
                }

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .morphingGlassControl(
                        in: Circle(),
                        fallback: Theme.neutralFill,
                        id: "chevron",
                        namespace: glassNamespace
                    )
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? Copy.collapseAccount : Copy.expandAccount)
        .accessibilityIdentifier("account.\(account.address).expand")
    }
}

/// Status dot + provider label ("Custom domain" / "Google" / "Microsoft").
private struct StatusLabel: View {
    let kind: AccountKind
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(kindLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText)
    }

    private var kindLabel: String {
        switch kind {
        case .imap: Copy.kindCustomDomain
        case .google: Copy.kindGoogle
        case .microsoft: Copy.kindMicrosoft
        }
    }

    private var dotColor: Color {
        switch status {
        case .connected: Theme.statusGreen
        }
    }

    private var statusText: String {
        switch status {
        case .connected: Copy.statusConnected
        }
    }
}

// MARK: - Actions

private struct AccountActionRow: View {
    let address: String
    let showsEdit: Bool
    let onEdit: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    let glassNamespace: Namespace.ID

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 14) {
            if showsEdit {
                Button(action: onEdit) {
                    Label(Copy.edit, systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.primary)
                        .morphingGlassControl(
                            in: buttonShape,
                            fallback: Theme.neutralFill,
                            id: "edit",
                            namespace: glassNamespace
                        )
                        .contentShape(buttonShape)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account.\(address).edit")
            }

            Button(role: .destructive, action: onDelete) {
                Label(Copy.delete, systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(Theme.destructive)
                    .morphingGlassControl(
                        in: buttonShape,
                        tint: Theme.destructive.opacity(0.12),
                        fallback: Theme.destructive.opacity(0.10),
                        id: "delete",
                        namespace: glassNamespace
                    )
                    .contentShape(buttonShape)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.\(address).delete")
        }
        .font(.headline)
    }
}

#Preview("Card – IMAP expanded") {
    AccountCard(
        account: PreviewData.infoAccount,
        isExpanded: true,
        onToggle: {}, onEdit: {}, onDelete: {}, revealPassword: { "hunter2-demo" }
    )
    .padding()
    .background(PastelBackground())
}

#Preview("Card – Google expanded") {
    AccountCard(
        account: PreviewData.gmailAccount,
        isExpanded: true,
        onToggle: {}, onEdit: {}, onDelete: {}, revealPassword: { nil }
    )
    .padding()
    .background(PastelBackground())
}

#Preview("Card – collapsed") {
    AccountCard(
        account: PreviewData.supportAccount,
        isExpanded: false,
        onToggle: {}, onEdit: {}, onDelete: {}, revealPassword: { nil }
    )
    .padding()
    .background(PastelBackground())
}
