import SwiftUI

/// App icon tile, title, subtitle and the glass (i) button (shared by both tabs).
/// The (i) button opens "How SkiPass works", which morphs out of it (iOS 26+).
struct HeaderView: View {
    static let infoSourceID = "header.info"

    let store: SkiPassUIStore

    @State private var isShowingInfo: Bool
    @Namespace private var sheetNamespace

    // Explicit init: SDK 27 may not synthesize a memberwise init for views with @State.
    init(store: SkiPassUIStore) {
        self.store = store
        self.isShowingInfo = false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconTile()

            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.appName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Text(Copy.appSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            InfoButton { isShowingInfo = true }
                .zoomTransitionSource(id: Self.infoSourceID, in: sheetNamespace)
                .accessibilityLabel(Copy.infoLabel)
                .accessibilityIdentifier("header.info")
        }
        .sheet(isPresented: $isShowingInfo) {
            InfoSheet(store: store)
                .zoomTransition(sourceID: Self.infoSourceID, in: sheetNamespace)
        }
    }
}

/// The app icon artwork (same image as the app's AppIcon asset), shown as a rounded tile.
private struct AppIconTile: View {
    var body: some View {
        Image("AppIconArtwork", bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.10), radius: 10, x: 0, y: 4)
            .accessibilityHidden(true)
    }
}

#Preview("Header", traits: .sizeThatFitsLayout) {
    HeaderView(store: PreviewData.makeStore())
        .padding()
        .background(PastelBackground())
}
