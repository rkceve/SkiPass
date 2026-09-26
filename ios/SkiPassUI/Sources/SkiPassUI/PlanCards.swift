import SwiftUI

/// Current plan: icon, name, "Current" chip, tagline and the usage box.
struct CurrentPlanCard: View {
    let plan: PlanOption
    let usage: UsageInfo?
    let referenceDate: Date

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                PlanIcon(systemImage: plan.systemImage, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(plan.name)
                            .font(.title2.bold())
                        ChipView(title: Copy.currentChip, color: Theme.chipIMAPForeground)
                    }
                    Text(plan.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plan.current")

            if let usage {
                UsageBox(usage: usage, referenceDate: referenceDate)
            }
        }
        .padding(16)
        .cardSurface()
    }
}

/// "Remaining sends", "N of M left", progress bar, reset countdown and date.
private struct UsageBox: View {
    let usage: UsageInfo
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Copy.remainingSends)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(remainingText)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            UsageBar(fraction: usage.remainingFraction)
                .accessibilityHidden(true)

            HStack {
                Text(Copy.resetsIn(days: daysUntilReset))
                Spacer()
                Label {
                    Text(usage.resetsAt.formatted(.dateTime.month(.abbreviated).day().year()))
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(16)
        .background(Theme.innerFill, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        .accessibilityIdentifier("plan.usage")
    }

    private var remainingText: String {
        Copy.remainingOfLimit(usage.remaining.formatted(), usage.limit.formatted())
    }

    private var daysUntilReset: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.startOfDay(for: usage.resetsAt)
        return max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }
}

/// Gradient capsule showing the remaining fraction.
private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.neutralFill)
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 12)
    }
}

/// One row in "Other plans". Tapping forwards to `selectPlan(id:)`. A row for the current plan
/// is informational: no button, no chevron, no press effect.
struct PlanRow: View {
    let plan: PlanOption
    let onSelect: @MainActor () -> Void

    var body: some View {
        if plan.isCurrent {
            rowContent(showsChevron: false)
                .cardSurface()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("plan.\(plan.id)")
        } else {
            Button(action: onSelect) {
                rowContent(showsChevron: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardSurface()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plan.\(plan.id)")
        }
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(spacing: 16) {
            PlanIcon(systemImage: plan.systemImage, size: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.name)
                    .font(.title3.weight(.semibold))
                Text(plan.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(plan.priceText)
                .font(.body.weight(.medium))
            if showsChevron {
                RowChevron()
            }
        }
        .foregroundStyle(.primary)
        .padding(16)
    }
}

/// "Change Plan" row as in the mockup.
struct ChangePlanRow: View {
    let onTap: @MainActor () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text(Copy.changePlan)
                    .font(.title3.weight(.medium))
                Spacer()
                RowChevron()
            }
            .foregroundStyle(.primary)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
        .accessibilityIdentifier("plan.change")
    }
}

/// Plan symbol on a soft circle, tinted with the accent gradient.
private struct PlanIcon: View {
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

private struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Theme.neutralFill, in: Circle())
            .accessibilityHidden(true)
    }
}

#Preview("Current plan card", traits: .sizeThatFitsLayout) {
    CurrentPlanCard(
        plan: PreviewData.standardPlan,
        usage: PreviewData.usage,
        referenceDate: PreviewData.referenceDate
    )
    .padding()
    .background(PastelBackground())
}
