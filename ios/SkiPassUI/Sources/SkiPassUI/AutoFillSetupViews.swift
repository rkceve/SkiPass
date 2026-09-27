import SwiftUI

/// Compact card at the top of the Home list while the SkiPass AutoFill extension is off.
/// The host app decides when it is off (`RootView(autoFillEnabled:)`); the card leaves with an
/// animation once the host reports it on.
struct AutoFillCard: View {
    let store: SkiPassUIStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                GuideSymbol(systemImage: "key.fill", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.autoFillCardTitle)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.autoFillCardBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            AutoFillEnableControls(store: store, identifierPrefix: "autofill")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autofill.card")
    }
}

/// "Turn On" (system prompt) and, after a request that did not turn AutoFill on, "Open Settings".
/// Shared by the Home card and the information sheet's setup step, so both show the same state.
struct AutoFillEnableControls: View {
    let store: SkiPassUIStore
    /// Accessibility identifiers are `<prefix>.turnOn` and `<prefix>.openSettings`.
    let identifierPrefix: String

    var body: some View {
        HStack(spacing: 10) {
            turnOnButton
                .accessibilityIdentifier("\(identifierPrefix).turnOn")
            if store.autoFillSettingsOffered {
                settingsButton
                    .accessibilityIdentifier("\(identifierPrefix).openSettings")
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .disabled(store.isRequestingAutoFill)
        .animation(CardMotion.toggle, value: store.autoFillSettingsOffered)
        .glassGroup(spacing: 10)
    }

    /// iOS 26+: system `.glassProminent`, accent tint (like Add). Before: the tinted capsule.
    @ViewBuilder
    private var turnOnButton: some View {
        if #available(iOS 26, *) {
            Button { Task { await store.requestAutoFill() } } label: {
                Text(Copy.autoFillTurnOn)
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.accent.opacity(0.85))
        } else {
            Button { Task { await store.requestAutoFill() } } label: {
                Text(Copy.autoFillTurnOn)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Theme.accent.opacity(0.85), in: Capsule())
        }
    }

    /// iOS 26+: system `.glass`. Before: a neutral capsule.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(iOS 26, *) {
            Button { Task { await store.openAutoFillSettings() } } label: {
                Text(Copy.autoFillOpenSettings)
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.primary)
        } else {
            Button { Task { await store.openAutoFillSettings() } } label: {
                Text(Copy.autoFillOpenSettings)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Theme.neutralFill, in: Capsule())
        }
    }
}

/// Symbol on a soft accent circle (same treatment as the plan icons).
struct GuideSymbol: View {
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42))
            .foregroundStyle(
                LinearGradient(
                    colors: [Theme.accentBlue, Theme.accent],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}

#Preview("AutoFill card") {
    ScrollView {
        AutoFillCard(store: PreviewData.makeStore(autoFillEnabled: false))
            .padding(20)
    }
    .background(PastelBackground())
}
