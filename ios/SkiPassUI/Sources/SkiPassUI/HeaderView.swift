import SwiftUI

/// App icon tile, title and subtitle (shared by both tabs).
struct HeaderView: View {
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
    HeaderView()
        .padding()
        .background(PastelBackground())
}
