import {
  Bell,
  Calendar,
  ChevronLeft,
  CircleHelp,
  CircleUser,
  Cloud,
  Infinity as InfinityIcon,
  Info,
  SlidersHorizontal,
  Star,
  User,
} from "lucide-react"
import { useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { AppHeader } from "@/components/app-header"
import { SettingsDivider, SettingsRow, SettingsSection } from "@/components/settings"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import {
  PLAN_TIERS,
  effectiveTier,
  expiryDescription,
  isPlanExpired,
  usePlan,
  type PlanTier,
} from "@/hooks/use-plan"
import { supportMailto } from "@/lib/app-meta"
import { cn } from "@/lib/utils"
import { usePlayer } from "@/player/player-provider"

const TIER_STYLE: Record<PlanTier, { icon: React.ReactNode; text: string; badge: string }> = {
  free: {
    icon: <CircleUser className="size-4.5" />,
    text: "text-muted-foreground",
    badge: "bg-foreground/8 text-muted-foreground",
  },
  premium: {
    icon: <Star className="size-4.5 fill-current" strokeWidth={0} />,
    text: "text-orange-500",
    badge: "bg-orange-500/12 text-orange-500",
  },
  unlimited: {
    icon: <InfinityIcon className="size-4.5" />,
    text: "text-purple-500",
    badge: "bg-purple-500/12 text-purple-500",
  },
}

export function ProfilePage() {
  const { user, username, signOut } = useAuth()
  const player = usePlayer()
  const navigate = useNavigate()
  const plan = usePlan()
  const [confirmSignOut, setConfirmSignOut] = useState(false)

  const tier = effectiveTier(plan)
  const tierMeta = PLAN_TIERS[tier]
  const tierStyle = TIER_STYLE[tier]
  const expiry = expiryDescription(plan)

  const primaryLabel = username ? `@${username}` : (user?.email ?? user?.displayName ?? "")

  const performSignOut = () => {
    player.stop()
    void signOut()
    navigate("/welcome", { replace: true })
  }

  return (
    <div className="min-h-dvh">
      <AppHeader />

      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <div className="flex h-12 items-center">
          <Link
            to="/"
            className="-ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
          >
            <ChevronLeft className="size-4.5" />
            Library
          </Link>
        </div>

        {/* ── Header ─────────────────────────────────────────────────── */}
        <div className="rise-in flex flex-col items-center pb-9 pt-6 text-center">
          <ProfileAvatar photoURL={user?.photoURL} size={108} />
          <h1 className="pt-4 text-[22px] font-bold">{primaryLabel}</h1>
          {username && user?.email && (
            <p className="pt-1 text-[15px] text-muted-foreground">{user.email}</p>
          )}
        </div>

        {/* ── My Plan ────────────────────────────────────────────────── */}
        <SettingsSection title="My Plan" className="rise-in" >
          <div className="flex items-center gap-3 px-4 py-3.5">
            <span className={cn("flex w-7 shrink-0 items-center justify-center", tierStyle.text)}>
              {tierStyle.icon}
            </span>
            <span className="flex min-w-0 flex-1 flex-col gap-0.5">
              <span className="text-[16px] font-semibold">{tierMeta.displayName}</span>
              <span className="text-[13px] text-muted-foreground">
                {tierMeta.storageDescription}
              </span>
            </span>
            <span
              className={cn(
                "shrink-0 rounded-full px-2.5 py-1 text-[11px] font-bold tracking-[0.5px]",
                tierStyle.badge,
              )}
            >
              {tierMeta.displayName.toUpperCase()}
            </span>
          </div>
          {expiry && (
            <>
              <SettingsDivider />
              <SettingsRow
                icon={<Calendar className="size-4" />}
                title={expiry}
                titleClassName={cn(
                  "text-[14px]",
                  isPlanExpired(plan) ? "text-destructive" : "text-muted-foreground",
                )}
              />
            </>
          )}
        </SettingsSection>

        {/* ── Settings ───────────────────────────────────────────────── */}
        <SettingsSection title="Settings" className="rise-in mt-6" >
          <SettingsRow
            icon={<Bell className="size-4" />}
            title="Notifications"
            chevron
            to="/profile/notifications"
          />
          <SettingsDivider />
          <SettingsRow
            icon={<SlidersHorizontal className="size-4" />}
            title="EQ"
            chevron
            disabled
          />
          <SettingsDivider />
          <SettingsRow
            icon={<Cloud className="size-4" />}
            title="Storage & Sync"
            chevron
            to="/profile/storage"
          />
          <SettingsDivider />
          <SettingsRow
            icon={<CircleHelp className="size-4" />}
            title="Help & Support"
            chevron
            href={supportMailto}
          />
          <SettingsDivider />
          <SettingsRow icon={<Info className="size-4" />} title="About" chevron to="/profile/about" />
        </SettingsSection>

        {/* ── Sign out ───────────────────────────────────────────────── */}
        <button
          type="button"
          onClick={() => setConfirmSignOut(true)}
          className="rise-in mt-8 flex h-13 w-full items-center justify-center rounded-[14px] bg-secondary text-[17px] font-semibold text-destructive transition hover:bg-secondary/70 active:scale-[0.99]"
        >
          Sign Out
        </button>
      </main>

      <Dialog open={confirmSignOut} onOpenChange={setConfirmSignOut}>
        <DialogContent className="rounded-3xl p-6 sm:max-w-xs">
          <DialogHeader>
            <DialogTitle>Sign Out?</DialogTitle>
            <DialogDescription>
              You'll need to sign in again to access your library.
            </DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-2 pt-2">
            <button
              type="button"
              onClick={performSignOut}
              className="flex h-11 items-center justify-center rounded-xl bg-destructive text-[15px] font-bold text-white transition hover:opacity-90 active:scale-[0.99]"
            >
              Sign Out
            </button>
            <button
              type="button"
              onClick={() => setConfirmSignOut(false)}
              className="flex h-11 items-center justify-center rounded-xl bg-secondary text-[15px] font-semibold transition hover:bg-secondary/70 active:scale-[0.99]"
            >
              Cancel
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}

export function ProfileAvatar({ photoURL, size }: { photoURL?: string | null; size: number }) {
  return (
    <span
      className="relative flex items-center justify-center overflow-hidden rounded-full border border-foreground/6 bg-secondary"
      style={{ width: size, height: size }}
    >
      {photoURL ? (
        <img src={photoURL} alt="Profile" className="h-full w-full object-cover" />
      ) : (
        <User
          className="text-muted-foreground/60"
          style={{ width: size * 0.36, height: size * 0.36 }}
        />
      )}
    </span>
  )
}
