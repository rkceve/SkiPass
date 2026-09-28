import SwiftUI

/// Expanded IMAP details: incoming server (IMAP chip), port, username and masked password rows.
struct ServerDetailsBox: View {
    let address: String
    let server: ServerSettings
    /// Changes whenever the stored password changes; a revealed password is hidden again then.
    let passwordRevision: Int
    let revealPassword: @MainActor () async -> String?

    var body: some View {
        VStack(spacing: 0) {
            DetailRow(label: Copy.incomingServer, value: server.incomingHost, showsIMAPChip: true)
            Divider()
            DetailRow(label: Copy.incomingPort, value: String(server.incomingPort))
            Divider()
            DetailRow(label: Copy.username, value: server.username)
            Divider()
            PasswordRow(address: address, revealPassword: revealPassword)
                // New identity (fresh, masked state) after an edit, even if the card stays expanded.
                .id(PasswordRowID(server: server, revision: passwordRevision))
        }
        .padding(.horizontal, 16)
        .background(Theme.innerFill, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
    }
}

private struct PasswordRowID: Hashable {
    let server: ServerSettings
    let revision: Int
}

/// Label / value row with an optional "IMAP" chip. A value too long for the value column (a long
/// host name or address) moves below the label, so it is shown in full instead of truncated.
private struct DetailRow: View {
    let label: String
    let value: String
    var showsIMAPChip = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                labelText
                    .frame(width: 128, alignment: .leading)
                valueText
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                chip
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    labelText
                    Spacer(minLength: 0)
                    chip
                }
                valueText
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    @ViewBuilder private var chip: some View {
        if showsIMAPChip {
            ChipView(title: Copy.chipIMAP, color: Theme.chipIMAPForeground)
        }
    }
}

/// Static tinted capsule ("IMAP", "Current"). Content, not a control,
/// so it is intentionally not Liquid Glass.
struct ChipView: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Masked password with an eye toggle that asks the host app for the secret.
private struct PasswordRow: View {
    let address: String
    let revealPassword: @MainActor () async -> String?

    @State private var revealed: String?

    init(address: String, revealPassword: @escaping @MainActor () async -> String?) {
        self.address = address
        self.revealPassword = revealPassword
        self.revealed = nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(Copy.password)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(revealed ?? Copy.passwordMask)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(revealed == nil)
            Button {
                Task { await toggle() }
            } label: {
                Image(systemName: revealed == nil ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed == nil ? Copy.showPassword : Copy.hidePassword)
            .accessibilityIdentifier("account.\(address).password.reveal")
        }
        .font(.subheadline)
        .padding(.vertical, 6)
    }

    private func toggle() async {
        if revealed == nil {
            revealed = await revealPassword()
        } else {
            revealed = nil
        }
    }
}
