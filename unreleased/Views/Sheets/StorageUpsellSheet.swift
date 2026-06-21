import SwiftUI

// MARK: - Upsell context

/// Describes why the storage upsell is being shown. Drives the sheet's copy and
/// iconography. `Identifiable` so it can drive a single `.sheet(item:)` at the app root.
struct StorageUpsellContext: Identifiable, Equatable {
    enum Reason: Equatable {
        /// User tried to add/upload but is already at their limit.
        case uploadFull
        /// A specific file is larger than the remaining free space.
        case uploadTooLarge(fileName: String)
        /// User is over their limit (e.g. after a downgrade) and tried to stream a cloud track.
        case overLimitPlayback
        /// The server (Cloud Function) rejected an upload for exceeding the quota.
        case serverBlocked
    }

    let id = UUID()
    let reason: Reason

    static func == (lhs: StorageUpsellContext, rhs: StorageUpsellContext) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sheet

struct StorageUpsellSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let context: StorageUpsellContext
    /// Invoked when the user chooses to free up space; the host dismisses the
    /// sheet and navigates to Storage & Sync.
    var onManageStorage: () -> Void

    private var reason: StorageUpsellContext.Reason { context.reason }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                    .padding(.top, 12)

                usageCard

                plansCard

                actions
                    .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: accentGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: accentGradient.first?.opacity(0.35) ?? .clear, radius: 16, y: 8)

                Image(systemName: iconName)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Usage card

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.formattedTotalUsed)
                        .font(.system(size: 22, weight: .bold))
                    Text("used of \(store.formattedStorageLimit)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(usageTrailingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(store.isOverStorageLimit ? .red : .secondary)
            }

            UpsellStorageBar(
                fraction: store.storageUsedFraction,
                isOver: store.isOverStorageLimit
            )
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var usageTrailingText: String {
        store.isOverStorageLimit ? "Over limit" : "\(store.formattedFreeStorage) free"
    }

    // MARK: - Plans card

    private var plansCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plans")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                let tiers: [PlanTier] = [.free, .premium, .unlimited]
                ForEach(Array(tiers.enumerated()), id: \.element) { index, tier in
                    planRow(tier)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                    if index < tiers.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func planRow(_ tier: PlanTier) -> some View {
        let isCurrent = tier == store.currentPlan.effectiveTier
        return HStack(spacing: 12) {
            Image(systemName: tier.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tier.tintColor)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(tier.displayName)
                    .font(.system(size: 16, weight: .semibold))
                Text(tier.storageDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Text("CURRENT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tier.tintColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(tier.tintColor)
            }
        }
        .opacity(isCurrent ? 1 : 0.9)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
                onManageStorage()
            } label: {
                Text(primaryButtonTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(colors: accentGradient, startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
            }
            .buttonStyle(.scale)

            Button {
                dismiss()
            } label: {
                Text("Not Now")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.scale)
        }
    }

    // MARK: - Reason-driven copy

    private var iconName: String {
        switch reason {
        case .uploadFull, .serverBlocked: "externaldrive.fill.badge.xmark"
        case .uploadTooLarge: "doc.badge.ellipsis"
        case .overLimitPlayback: "lock.fill"
        }
    }

    private var accentGradient: [Color] {
        switch reason {
        case .overLimitPlayback: [Color(hex: "#FF6FD8"), Color(hex: "#C46FFF")]
        default: [.orange, Color(hex: "#FF6F61")]
        }
    }

    private var title: String {
        switch reason {
        case .uploadFull: "Storage Full"
        case .uploadTooLarge: "Not Enough Space"
        case .overLimitPlayback: "You're Over Your Limit"
        case .serverBlocked: "Upload Blocked"
        }
    }

    private var message: String {
        switch reason {
        case .uploadFull:
            return "You've used all \(store.formattedStorageLimit) of your \(store.currentPlan.effectiveTier.displayName) plan. Free up space or move to a plan with more storage to keep adding tracks."
        case .uploadTooLarge(let fileName):
            return "“\(fileName)” is larger than the \(store.formattedFreeStorage) you have left. Delete some tracks to make room, or move to a larger plan."
        case .overLimitPlayback:
            return "Your library is using more than your \(store.currentPlan.effectiveTier.displayName) plan allows. Downloaded tracks still play, but streaming from the cloud is paused until you're back under \(store.formattedStorageLimit)."
        case .serverBlocked:
            return "This upload would put you over your \(store.formattedStorageLimit) limit, so it wasn't saved to the cloud. Free up space to keep your tracks backed up."
        }
    }

    private var primaryButtonTitle: String {
        switch reason {
        case .overLimitPlayback, .serverBlocked: "Free Up Space"
        default: "Manage Storage"
        }
    }
}

// MARK: - Progress bar

private struct UpsellStorageBar: View {
    let fraction: Double
    let isOver: Bool

    private var barColor: Color {
        if isOver { return .red }
        return fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.systemFill))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(barColor)
                    .frame(width: max(12, geo.size.width * CGFloat(min(1, fraction))))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 12)
    }
}

#Preview {
    StorageUpsellSheet(
        context: StorageUpsellContext(reason: .overLimitPlayback),
        onManageStorage: {}
    )
    .environment(ProjectStore())
}
