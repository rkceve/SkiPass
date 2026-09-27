import SwiftUI

/// Add / edit sheet (no mockup; decided behavior).
/// Add: ask for an email only -> `addAccount(email:)`. If the host throws
/// `SkiPassUIError.needsServerSettings`, continue in the same sheet with the IMAP form.
/// Edit (IMAP only): the same IMAP form, prefilled.
struct AccountFormSheet: View {
    private enum Step: Hashable {
        case email
        case imap
    }

    private enum Field: Hashable {
        case email, host, port, username, password
    }

    let store: SkiPassUIStore

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step
    @State private var email: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var isWorking: Bool
    @State private var errorMessage: String?
    @State private var emailSubmitAttempted = false
    @FocusState private var focusedField: Field?

    private let editingAccount: MailAccount?

    init(sheet: AccountSheet, store: SkiPassUIStore) {
        self.store = store
        switch sheet {
        case .add:
            editingAccount = nil
            step = .email
            email = ""
            host = ""
            portText = Copy.defaultIMAPPort
            username = ""
        case .edit(let account):
            editingAccount = account
            step = .imap
            email = account.address
            host = account.server?.incomingHost ?? ""
            portText = account.server.map { String($0.incomingPort) } ?? Copy.defaultIMAPPort
            username = account.server?.username ?? account.address
        }
        password = ""
        isWorking = false
        errorMessage = nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .email:
                    emailStep
                case .imap:
                    Form {
                        imapSections
                        if let errorMessage {
                            Section { errorText(errorMessage) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .modifier(SheetBackground())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editingAccount == nil ? Copy.addAccountTitle : Copy.editAccountTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .disabled(isWorking)
            .task { await prefillPasswordIfEditing() }
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Theme.destructive)
            .accessibilityIdentifier("accountForm.error")
    }

    // MARK: Email step

    /// Label above a large bordered field, inline validation, what happens next, and a prominent
    /// Continue that stays disabled until the text looks like an email address.
    private var emailStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.emailAddress)
                    .font(.headline)
                    .accessibilityHidden(true)  // the field carries the label for VoiceOver

                emailField

                if showsInvalidEmail {
                    Label(Copy.emailInvalid, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                        .accessibilityIdentifier("accountForm.emailInvalid")
                        .transition(.opacity)
                }

                Text(Copy.emailHelper)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    errorText(errorMessage)
                        .padding(.top, 4)
                }

                continueButton
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .animation(.smooth, value: showsInvalidEmail)
        }
        .defaultFocus($focusedField, .email)
        .onAppear { focusedField = .email }
    }

    private var emailField: some View {
        let isFocused = focusedField == .email
        return HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.title3)
                .foregroundStyle(isFocused ? Theme.accent : Color.secondary)
                .accessibilityHidden(true)
            TextField(Copy.emailPlaceholder, text: $email)
                .font(.title3)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focusedField, equals: .email)
                .onSubmit {
                    emailSubmitAttempted = true
                    Task { await submit() }
                }
                .accessibilityLabel(Copy.emailAddress)
                .accessibilityIdentifier("accountForm.email")
            if !email.isEmpty {
                Button {
                    email = ""
                    emailSubmitAttempted = false
                    focusedField = .email
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.clearEmail)
                .accessibilityIdentifier("accountForm.email.clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .background(Theme.innerFill, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .strokeBorder(emailBorderColor(focused: isFocused), lineWidth: isFocused || showsInvalidEmail ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .email }
    }

    private func emailBorderColor(focused: Bool) -> Color {
        if showsInvalidEmail { return Theme.destructive }
        return focused ? Theme.accent : Color(uiColor: .systemGray3)
    }

    /// iOS 26+: Liquid Glass prominent capsule like the Add button; before: bordered prominent.
    @ViewBuilder
    private var continueButton: some View {
        let button = Button {
            emailSubmitAttempted = true
            Task { await submit() }
        } label: {
            ZStack {
                Text(Copy.continueAction).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!canSubmit || isWorking)
        .accessibilityIdentifier("accountForm.continue")

        if #available(iOS 26, *) {
            button
                .buttonStyle(.glassProminent)
                .tint(Theme.accent.opacity(0.85))
        } else {
            button
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    /// Shown once the user tried to continue (Return) or left the field with text that is not an address.
    private var showsInvalidEmail: Bool {
        !trimmedEmail.isEmpty
            && !EmailAddressFormat.looksValid(trimmedEmail)
            && (emailSubmitAttempted || focusedField != .email)
    }

    @ViewBuilder
    private var imapSections: some View {
        Section(Copy.emailAddress) {
            Text(email)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("accountForm.address")
        }

        Section(Copy.serverSettingsSection) {
            LabeledContent(Copy.incomingServer) {
                TextField(Copy.host, text: $host)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .host)
                    .accessibilityIdentifier("accountForm.host")
            }
            LabeledContent(Copy.incomingPort) {
                TextField(Copy.port, text: $portText)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .port)
                    .accessibilityIdentifier("accountForm.port")
            }
            LabeledContent(Copy.username) {
                TextField(Copy.username, text: $username)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .accessibilityIdentifier("accountForm.username")
            }
            LabeledContent(Copy.password) {
                SecureField(Copy.password, text: $password)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .accessibilityIdentifier("accountForm.password")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(Copy.cancel) { dismiss() }
                .accessibilityIdentifier("accountForm.cancel")
        }
        // The email step has its own prominent Continue button in the content.
        if step == .imap {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button(Copy.save) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("accountForm.save")
                }
            }
        }
    }

    // MARK: Logic

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var port: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    private var canSubmit: Bool {
        switch step {
        case .email:
            return EmailAddressFormat.looksValid(trimmedEmail)
        case .imap:
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
                && port != nil
                && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && !password.isEmpty
        }
    }

    private func submit() async {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            switch step {
            case .email:
                try await store.addAccount(email: trimmedEmail)
                dismiss()
            case .imap:
                try await saveIMAP()
                dismiss()
            }
        } catch SkiPassUIError.needsServerSettings {
            email = trimmedEmail
            if username.isEmpty { username = trimmedEmail }
            withAnimation(.smooth) { step = .imap }
            focusedField = .host
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveIMAP() async throws {
        guard let port else { return }
        // Outgoing values are display-only and not edited here; keep what the host provided.
        let settings = ServerSettings(
            incomingHost: host.trimmingCharacters(in: .whitespaces),
            incomingPort: port,
            username: username.trimmingCharacters(in: .whitespaces),
            outgoingHost: editingAccount?.server?.outgoingHost,
            outgoingPort: editingAccount?.server?.outgoingPort
        )
        try await store.saveIMAP(address: email, settings: settings, password: password)
    }

    private func prefillPasswordIfEditing() async {
        guard let editingAccount, password.isEmpty else { return }
        if let stored = await store.revealPassword(id: editingAccount.id) {
            password = stored
        }
    }
}

/// iOS 26+: no custom background, so the system Liquid Glass sheet material shows
/// (and the zoom transition morphs glass out of the Add button). Before iOS 26: the pastel.
private struct SheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(PastelBackground())
        }
    }
}

#Preview("Add sheet – email step") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AccountFormSheet(sheet: .add, store: PreviewData.makeStore())
        }
}

#Preview("Edit sheet – IMAP") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AccountFormSheet(sheet: .edit(PreviewData.infoAccount), store: PreviewData.makeStore())
        }
}
