import SwiftUI

/// Sections of the "How SkiPass works" sheet, in display order.
enum InfoSection: String, CaseIterable, Identifiable {
    case setup
    case choice
    case privacy
    case plans
    case version
    /// Shown only when the host supplies diagnostics (the live app does; the UI tour does not).
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: Copy.infoSetupTitle
        case .choice: Copy.infoChoiceTitle
        case .privacy: Copy.infoPrivacyTitle
        case .plans: Copy.infoPlansTitle
        case .version: Copy.infoVersionTitle
        case .diagnostics: Copy.infoDiagnosticsTitle
        }
    }

    var systemImage: String {
        switch self {
        case .setup: "checklist"
        case .choice: "text.magnifyingglass"
        case .privacy: "lock.fill"
        case .plans: "crown.fill"
        case .version: "info"
        case .diagnostics: "stethoscope"
        }
    }

    /// Bullet lines of the text-only sections (setup, version and diagnostics have their own layout).
    var lines: [String] {
        switch self {
        case .choice: Copy.infoChoiceLines
        case .privacy: Copy.infoPrivacyLines
        case .plans: Copy.infoPlansLines
        case .setup, .version, .diagnostics: []
        }
    }

    var accessibilityIdentifier: String { "info.section.\(rawValue)" }
}

/// Marketing version and build number of the running app, e.g. "0.1.6 (42)".
enum AppVersion {
    static func text(info: [String: Any]?) -> String? {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return Copy.versionText(version: version, build: build)
    }

    static var current: String? { text(info: Bundle.main.infoDictionary) }
}

/// The circular glass (i) button in the header; opens the information sheet.
/// iOS 26+: system `.glass` style with a circle border shape. Before: a material circle.
struct InfoButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(action: action) {
                Image(systemName: "info.circle")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            // The glass style colors the glyph with the tint (the app accent); keep it neutral.
            .tint(.primary)
        } else {
            Button(action: action) {
                Image(systemName: "info.circle")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// "How SkiPass works": setup steps (with the same AutoFill controls as the Home card), how the
/// code is chosen, privacy, plans and the app version.
struct InfoSheet: View {
    let store: SkiPassUIStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var diagnostics: DiagnosticsInfo?

    var body: some View {
        NavigationStack {
            ScrollView {
                InfoSheetContent(store: store, versionText: AppVersion.current, diagnostics: diagnostics)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            // Read the records each time the sheet opens and when the app returns to the foreground
            // (the AutoFill extension writes them while the app is in the background).
            .onAppear { diagnostics = store.loadDiagnostics?() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { diagnostics = store.loadDiagnostics?() }
            }
            .scrollIndicators(.hidden)
            .modifier(InfoSheetBackground())
            .navigationTitle(Copy.infoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.done) { dismiss() }
                        .accessibilityIdentifier("info.done")
                }
            }
        }
    }
}

/// The sheet's scrollable body (separate so tests can render it without a presentation).
struct InfoSheetContent: View {
    let store: SkiPassUIStore
    let versionText: String?
    /// nil hides the Diagnostics card.
    var diagnostics: DiagnosticsInfo? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(InfoSection.allCases) { section in
                switch section {
                case .setup:
                    InfoCard(section: section) { SetupSteps(store: store) }
                case .version:
                    InfoCard(section: section) {
                        Text(versionText ?? Copy.infoVersionUnknown)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("info.version")
                    }
                case .diagnostics:
                    if let diagnostics {
                        InfoCard(section: section) {
                            DiagnosticsContent(info: diagnostics, versionText: versionText)
                        }
                    }
                case .choice, .privacy, .plans:
                    InfoCard(section: section) { BulletLines(lines: section.lines) }
                }
            }
        }
        .animation(CardMotion.toggle, value: store.autoFillEnabled)
    }
}

/// One section: symbol and title, then its content, on the shared card surface.
private struct InfoCard<Content: View>: View {
    let section: InfoSection
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GuideSymbol(systemImage: section.systemImage, size: 36)
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(section.accessibilityIdentifier)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct SetupSteps: View {
    let store: SkiPassUIStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepRow(number: 1, text: Copy.infoSetupAddMailbox)
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 2, text: Copy.infoSetupTurnOnAutoFill)
                Group {
                    if store.autoFillEnabled {
                        Label(Copy.autoFillIsOn, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.statusGreen)
                            .accessibilityIdentifier("info.autofill.on")
                            .transition(.opacity)
                    } else {
                        AutoFillEnableControls(store: store, identifierPrefix: "info.autofill")
                            .transition(.opacity)
                    }
                }
                .padding(.leading, StepRow.textInset)
            }
            StepRow(number: 3, text: Copy.infoSetupOpenSite)
            StepRow(number: 4, text: Copy.infoSetupTapSuggestion)
        }
    }
}

private struct StepRow: View {
    /// Number badge width plus spacing, so content under a step lines up with its text.
    static let textInset: CGFloat = 26 + 12

    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BulletLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Theme.accent.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// iOS 26+: no custom background, so the system Liquid Glass sheet material shows (and the zoom
/// transition morphs glass out of the (i) button), as in the Add sheet. Before iOS 26: the pastel.
private struct InfoSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(PastelBackground())
        }
    }
}

#Preview("Info sheet – AutoFill off") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            InfoSheet(store: PreviewData.makeStore(autoFillEnabled: false))
        }
}

#Preview("Info sheet – AutoFill on") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            InfoSheet(store: PreviewData.makeStore())
        }
}
