import SwiftUI
import UIKit

/// What the "Diagnostics" part of "How SkiPass works" shows: the storage the app resolved, the last
/// identity registrations, and the last AutoFill requests the extension recorded. The host app
/// builds it from its shared records; the texts of a request are already readable lines.
public struct DiagnosticsInfo: Equatable, Sendable {
    /// One AutoFill request.
    public struct Request: Equatable, Sendable, Identifiable {
        public var id: String
        public var date: Date
        /// e.g. "noUI · skipass-demo.vercel.app".
        public var title: String
        public var isFilled: Bool
        /// Step-by-step lines (result, groups, mailboxes, folders, judge).
        public var lines: [String]

        public init(id: String, date: Date, title: String, isFilled: Bool, lines: [String]) {
            self.id = id
            self.date = date
            self.title = title
            self.isFilled = isFilled
            self.lines = lines
        }
    }

    public var bundleID: String?
    public var appGroup: String?
    public var keychainGroup: String?
    /// Summary lines of the last registration in the app and in the extension; nil = none yet.
    public var appRegistration: String?
    public var extensionRegistration: String?
    /// Newest first.
    public var requests: [Request]

    public init(bundleID: String?, appGroup: String?, keychainGroup: String?, appRegistration: String?,
                extensionRegistration: String?, requests: [Request]) {
        self.bundleID = bundleID
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
        self.appRegistration = appRegistration
        self.extensionRegistration = extensionRegistration
        self.requests = requests
    }

    struct Row: Hashable {
        var label: String
        var value: String
    }

    /// Label / value rows of the storage and registration part, in display order.
    var rows: [Row] {
        [
            Row(label: Copy.diagnosticsBundleID, value: bundleID ?? Copy.diagnosticsNone),
            Row(label: Copy.diagnosticsAppGroup, value: appGroup ?? Copy.diagnosticsNone),
            Row(label: Copy.diagnosticsKeychainGroup, value: keychainGroup ?? Copy.diagnosticsDefaultGroup),
            Row(label: Copy.diagnosticsRegistrationApp, value: appRegistration ?? Copy.diagnosticsNotYet),
            Row(label: Copy.diagnosticsRegistrationExtension, value: extensionRegistration ?? Copy.diagnosticsNotYet),
        ]
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    /// The text "Copy diagnostics" puts on the pasteboard.
    func plainText(versionText: String?) -> String {
        var lines = ["\(Copy.diagnosticsTextHeader) \(versionText ?? Copy.infoVersionUnknown)"]
        for row in rows {
            lines.append("\(row.label): \(row.value)")
        }
        lines.append("")
        lines.append("\(Copy.diagnosticsRequestsTitle):")
        if requests.isEmpty {
            lines.append(Copy.diagnosticsNoRequests)
        }
        for request in requests {
            lines.append("- \(Self.dateText(request.date)) \(request.title)")
            lines.append(contentsOf: request.lines.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

/// Content of the Diagnostics card.
struct DiagnosticsContent: View {
    let info: DiagnosticsInfo
    let versionText: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.diagnosticsIntro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(info.rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Text(Copy.diagnosticsRequestsTitle)
                .font(.subheadline.weight(.semibold))

            if info.requests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(Copy.diagnosticsNoRequests, systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("info.diagnostics.none")
                    Text(Copy.diagnosticsNoRequestsHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(info.requests) { request in
                    RequestRows(request: request)
                }
            }

            Button {
                UIPasteboard.general.string = info.plainText(versionText: versionText)
                copied = true
            } label: {
                Label(copied ? Copy.diagnosticsCopied : Copy.diagnosticsCopy,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .accessibilityIdentifier("info.diagnostics.copy")
        }
    }
}

private struct RequestRows: View {
    let request: DiagnosticsInfo.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: request.isFilled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(request.isFilled ? Theme.statusGreen : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DiagnosticsInfo.dateText(request.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(request.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
