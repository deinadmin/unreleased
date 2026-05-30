import Foundation
import SwiftUI

// MARK: - Plan tier

enum PlanTier: String, Codable {
    case free = "free"
    case premium = "premium"
    case unlimited = "unlimited"

    var displayName: String {
        switch self {
        case .free: "Free"
        case .premium: "Premium"
        case .unlimited: "Unlimited"
        }
    }

    /// Nil means no cap (unlimited).
    var storageLimitBytes: Int64? {
        switch self {
        case .free:      1_000_000_000       // 1 GB
        case .premium:   20_000_000_000      // 20 GB
        case .unlimited: nil
        }
    }

    var storageDescription: String {
        switch self {
        case .free:      "1 GB storage"
        case .premium:   "20 GB storage"
        case .unlimited: "Unlimited storage"
        }
    }

    var perks: [String] {
        switch self {
        case .free:
            return ["1 GB storage", "Cloud sync", "Unlimited projects"]
        case .premium:
            return ["20 GB storage", "Cloud sync", "Unlimited projects"]
        case .unlimited:
            return ["Unlimited storage", "Cloud sync", "Unlimited projects"]
        }
    }

    var icon: String {
        switch self {
        case .free:      "person.circle"
        case .premium:   "star.fill"
        case .unlimited: "infinity"
        }
    }

    var tintColor: Color {
        switch self {
        case .free:      Color(.secondaryLabel)
        case .premium:   .orange
        case .unlimited: .purple
        }
    }
}

// MARK: - User plan

struct UserPlan {
    let tier: PlanTier
    /// Nil means the plan never expires.
    let expiresAt: Date?

    static let `default` = UserPlan(tier: .free, expiresAt: nil)

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Degrades to `.free` if the plan is expired.
    var effectiveTier: PlanTier {
        isExpired ? .free : tier
    }

    var storageLimitBytes: Int64? {
        effectiveTier.storageLimitBytes
    }

    /// Human-readable expiry string, e.g. "Expires in 291 days." or "Expired 3 days ago."
    /// Nil for Free plans, which never expire.
    var expiryDescription: String? {
        guard effectiveTier != .free, let expiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        switch days {
        case 1...:
            return "Expires in \(days) \(days == 1 ? "day" : "days")."
        case 0:
            return "Expires today."
        default:
            let ago = abs(days)
            return "Expired \(ago) \(ago == 1 ? "day" : "days") ago."
        }
    }
}
