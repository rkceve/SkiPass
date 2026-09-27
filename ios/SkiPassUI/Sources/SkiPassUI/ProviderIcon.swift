import SwiftUI

/// Leading icon for an account card. No third-party logo artwork is bundled: Google and
/// Microsoft accounts use neutral SF Symbols.
struct ProviderIcon: View {
    let kind: AccountKind

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(foreground)
            .frame(width: 56, height: 56)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch kind {
        case .imap: "globe"
        case .google: "envelope.fill"
        case .microsoft: "building.2.fill"
        }
    }

    private var foreground: Color {
        switch kind {
        case .imap: Theme.chipIMAPForeground
        case .google, .microsoft: .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .imap: Theme.chipIMAPForeground.opacity(0.10)
        case .google, .microsoft: Theme.neutralFill
        }
    }
}

#Preview("Provider icons", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
        ProviderIcon(kind: .imap)
        ProviderIcon(kind: .google)
        ProviderIcon(kind: .microsoft)
    }
    .padding()
}
