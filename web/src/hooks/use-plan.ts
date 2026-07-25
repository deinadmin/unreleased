import { Timestamp, doc, onSnapshot } from "firebase/firestore"
import { useEffect, useState } from "react"
import { useAuth } from "@/hooks/use-auth"
import { db } from "@/lib/firebase"

export type PlanTier = "free" | "premium" | "unlimited"

export interface UserPlan {
  tier: PlanTier
  /** Undefined means the plan never expires. */
  expiresAt?: Date
}

const DEFAULT_PLAN: UserPlan = { tier: "free" }

export const PLAN_TIERS: Record<
  PlanTier,
  { displayName: string; storageDescription: string; storageLimitBytes: number | null }
> = {
  free: { displayName: "Free", storageDescription: "1 GB storage", storageLimitBytes: 1_000_000_000 },
  premium: {
    displayName: "Premium",
    storageDescription: "20 GB storage",
    storageLimitBytes: 20_000_000_000,
  },
  unlimited: {
    displayName: "Unlimited",
    storageDescription: "Unlimited storage",
    storageLimitBytes: null,
  },
}

export function isPlanExpired(plan: UserPlan): boolean {
  return plan.expiresAt !== undefined && plan.expiresAt < new Date()
}

/** Degrades to `free` when expired, matching the iOS `UserPlan.effectiveTier`. */
export function effectiveTier(plan: UserPlan): PlanTier {
  return isPlanExpired(plan) ? "free" : plan.tier
}

/** "Expires in 291 days." / "Expires today." / "Expired 3 days ago." — nil for Free. */
export function expiryDescription(plan: UserPlan): string | null {
  if (effectiveTier(plan) === "free" || !plan.expiresAt) return null
  const days = Math.ceil((plan.expiresAt.getTime() - Date.now()) / 86_400_000)
  if (days > 0) return `Expires in ${days} ${days === 1 ? "day" : "days"}.`
  if (days === 0) return "Expires today."
  const ago = Math.abs(days)
  return `Expired ${ago} ${ago === 1 ? "day" : "days"} ago.`
}

/** Listens to `users/{uid}` for the console-managed plan fields. */
export function usePlan(): UserPlan {
  const { user, isSignedIn } = useAuth()
  const [plan, setPlan] = useState<UserPlan>(DEFAULT_PLAN)

  useEffect(() => {
    if (!user || !isSignedIn) {
      setPlan(DEFAULT_PLAN)
      return
    }
    return onSnapshot(
      doc(db, "users", user.uid),
      (snapshot) => {
        const data = snapshot.data()
        const tier = data?.plan
        if (tier === "free" || tier === "premium" || tier === "unlimited") {
          setPlan({
            tier,
            expiresAt:
              data?.planExpiresAt instanceof Timestamp ? data.planExpiresAt.toDate() : undefined,
          })
        } else {
          setPlan(DEFAULT_PLAN)
        }
      },
      () => setPlan(DEFAULT_PLAN),
    )
  }, [user, isSignedIn])

  return plan
}
