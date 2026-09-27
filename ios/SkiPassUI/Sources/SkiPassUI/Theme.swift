import SwiftUI
import UIKit

/// Colors, radii and shared surface styles taken from the mockups.
enum Theme {
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.96)
    static let accentBlue = Color(red: 0.40, green: 0.60, blue: 0.98)
    static let accentPink = Color(red: 0.93, green: 0.62, blue: 0.86)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.78, green: 0.55, blue: 0.98), accentBlue],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static let statusGreen = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let destructive = Color(red: 0.90, green: 0.20, blue: 0.30)

    static let chipIMAPForeground = Color(red: 0.16, green: 0.52, blue: 0.93)

    static let cardRadius: CGFloat = 24
    static let innerRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 14

    /// Adapts to Dark Mode (system background), slightly translucent.
    static let innerFill = Color(uiColor: .systemBackground).opacity(0.7)
    static let neutralFill = Color(uiColor: .secondarySystemFill)
}

// MARK: - Surfaces

extension View {
    /// Content-layer card: light material + hairline border + soft shadow.
    /// Deliberately not Liquid Glass (glass is reserved for controls).
    func cardSurface() -> some View {
        modifier(CardSurface())
    }

    /// Control inside a card whose glass morphs when it appears / disappears (iOS 26+):
    /// interactive Liquid Glass tagged with `glassEffectID` so a surrounding
    /// `GlassEffectContainer` can morph it. Before iOS 26: the original flat fill.
    @ViewBuilder
    func morphingGlassControl<S: Shape, F: ShapeStyle>(
        in shape: S,
        tint: Color? = nil,
        fallback: F,
        id: String,
        namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            background(fallback, in: shape)
        }
    }

    /// iOS 26+: the floating Liquid Glass tab bar overlaps the end of a tab's ScrollView
    /// (measured in the UI tour: the last card's Delete stopped at y 749–802 pt while the tab
    /// bar starts near y 767 pt on iPhone 16). Extra bottom safe-area padding lets the last
    /// content scroll clear of it. Before iOS 26 the opaque tab bar already insets content.
    @ViewBuilder
    func tabBarClearance() -> some View {
        if #available(iOS 26, *) {
            safeAreaPadding(.bottom, 72)
        } else {
            self
        }
    }

    /// Groups glass controls in one `GlassEffectContainer` (iOS 26+) so they share a
    /// sampling region and can morph into one another. No-op before iOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Marks this view as the source of a zoom transition (iOS 26+ only, so the
    /// pre-26 presentation is unchanged).
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Zooms a presented sheet out of the matching `zoomTransitionSource` (iOS 26+ only).
    @ViewBuilder
    func zoomTransition(sourceID: String?, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *), let sourceID {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}

/// Spring used for the account card accordion. iOS 26+: a slightly livelier spring
/// so the glass controls visibly morph; before iOS 26 the original `.smooth`.
enum CardMotion {
    static var toggle: Animation {
        if #available(iOS 26, *) {
            return .spring(duration: 0.5, bounce: 0.18)
        }
        return .smooth
    }

    /// Expanded content: scales down from the summary row while fading (iOS 26+);
    /// the original opacity + move before.
    static var expandedContent: AnyTransition {
        if #available(iOS 26, *) {
            return .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
        }
        return .opacity.combined(with: .move(edge: .top))
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.55), lineWidth: 1)
            }
            .shadow(color: Theme.accent.opacity(0.08), radius: 16, x: 0, y: 6)
    }
}

// MARK: - Background

/// Soft pastel mesh gradient behind both tabs.
struct PastelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.5), SIMD2<Float>(0.6, 0.45), SIMD2<Float>(1, 0.5),
                SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 1), SIMD2<Float>(1, 1),
            ],
            colors: colorScheme == .dark ? Self.darkColors : Self.lightColors
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static let lightColors: [Color] = [
        Color(red: 0.93, green: 0.95, blue: 1.00), Color(red: 0.95, green: 0.95, blue: 1.00), Color(red: 0.98, green: 0.93, blue: 0.99),
        Color(red: 0.94, green: 0.96, blue: 1.00), Color(red: 0.97, green: 0.96, blue: 1.00), Color(red: 0.95, green: 0.93, blue: 1.00),
        Color(red: 0.97, green: 0.94, blue: 0.99), Color(red: 0.93, green: 0.94, blue: 1.00), Color(red: 0.98, green: 0.94, blue: 0.99),
    ]

    private static let darkColors: [Color] = [
        Color(red: 0.08, green: 0.09, blue: 0.16), Color(red: 0.10, green: 0.09, blue: 0.18), Color(red: 0.14, green: 0.09, blue: 0.18),
        Color(red: 0.08, green: 0.10, blue: 0.18), Color(red: 0.10, green: 0.10, blue: 0.19), Color(red: 0.11, green: 0.09, blue: 0.19),
        Color(red: 0.12, green: 0.09, blue: 0.17), Color(red: 0.08, green: 0.09, blue: 0.17), Color(red: 0.13, green: 0.09, blue: 0.17),
    ]
}
