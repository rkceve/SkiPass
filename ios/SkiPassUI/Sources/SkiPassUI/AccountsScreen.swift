import SwiftUI

/// Screen 1 (Home tab): header, "Accounts" + Add, accordion account cards.
struct AccountsScreen: View {
    @Bindable var store: SkiPassUIStore

    /// Shared by the Add button (zoom source) and the add sheet (zoom destination).
    @Namespace private var sheetNamespace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The header's (i) button and Add are the glass controls; the container gives
                // them one sampling region.
                VStack(alignment: .leading, spacing: 24) {
                    HeaderView(store: store)

                    AccountsSectionHeader(sheetNamespace: sheetNamespace) {
                        store.accountSheet = .add
                    }
                }
                .glassGroup()

                VStack(spacing: 16) {
                    // Shown only while the AutoFill extension is off; leaves with a spring.
                    if !store.autoFillEnabled {
                        AutoFillCard(store: store)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    }

                    ForEach(store.accounts) { account in
                        AccountCard(
                            account: account,
                            isExpanded: store.expandedAccountID == account.id,
                            passwordRevision: store.passwordRevision(for: account.id),
                            onToggle: {
                                withAnimation(CardMotion.toggle) { store.toggleExpanded(account.id) }
                            },
                            onEdit: { store.accountSheet = .edit(account) },
                            onDelete: {
                                try await store.deleteAccount(id: account.id)
                            },
                            revealPassword: {
                                await store.revealPassword(id: account.id)
                            }
                        )
                    }
                }
                .animation(CardMotion.toggle, value: store.autoFillEnabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .tabBarClearance()
        .background(PastelBackground())
        .sheet(item: $store.accountSheet) { sheet in
            AccountFormSheet(sheet: sheet, store: store)
                // iOS 26+: the add sheet morphs out of the glass Add button.
                .zoomTransition(
                    sourceID: sheet == .add ? AccountsSectionHeader.addSourceID : nil,
                    in: sheetNamespace
                )
        }
    }
}

/// "Accounts" title with the glass "Add" button.
private struct AccountsSectionHeader: View {
    static let addSourceID = "accounts.add"

    let sheetNamespace: Namespace.ID
    let onAdd: @MainActor () -> Void

    var body: some View {
        HStack {
            Text(Copy.accountsTitle)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            addButton
                .zoomTransitionSource(id: Self.addSourceID, in: sheetNamespace)
                .accessibilityLabel(Copy.addAccountLabel)
                .accessibilityIdentifier("accounts.add")
        }
    }

    /// iOS 26+: system `.glassProminent` style tinted with the accent (mockup: purple capsule).
    /// Before iOS 26: the original tinted capsule.
    @ViewBuilder
    private var addButton: some View {
        if #available(iOS 26, *) {
            Button(action: onAdd) {
                Label(Copy.add, systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.accent.opacity(0.85))
        } else {
            Button(action: onAdd) {
                Label(Copy.add, systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Theme.accent.opacity(0.85), in: Capsule())
        }
    }
}

#Preview("Accounts – collapsed") {
    AccountsScreen(store: PreviewData.makeStore())
}

#Preview("Accounts – expanded IMAP") {
    AccountsScreen(store: PreviewData.makeStore(expanded: PreviewData.infoAccountID))
}

#Preview("Accounts – AutoFill off") {
    AccountsScreen(store: PreviewData.makeStore(autoFillEnabled: false))
}

#Preview("Accounts – expanded Google") {
    AccountsScreen(store: PreviewData.makeStore(expanded: PreviewData.gmailAccountID))
}
