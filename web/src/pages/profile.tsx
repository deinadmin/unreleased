import {
  Bell,
  Calendar,
  Camera,
  ChevronLeft,
  CircleHelp,
  CircleUser,
  Cloud,
  Infinity as InfinityIcon,
  Info,
  Loader2,
  SlidersHorizontal,
  Star,
  User,
} from "lucide-react"
import { useRef, useState, type DragEvent } from "react"
import { Link, useNavigate } from "react-router-dom"
import { toast } from "sonner"
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
import { InvalidProfilePhotoError, setProfilePhoto } from "@/lib/profile-photo"
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
  const [photoURL, setPhotoURL] = useState(user?.photoURL)

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
          {user && (
            <ProfilePhotoUpload
              photoURL={photoURL}
              size={108}
              onUpload={async (file) => {
                const nextURL = await setProfilePhoto(user, file)
                setPhotoURL(nextURL)
              }}
            />
          )}
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

function ProfilePhotoUpload({
  photoURL,
  size,
  onUpload,
}: {
  photoURL?: string | null
  size: number
  onUpload: (file: File) => Promise<void>
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const dragDepth = useRef(0)
  const [isDragging, setIsDragging] = useState(false)
  const [isUploading, setIsUploading] = useState(false)

  const choosePhoto = async (file: File) => {
    if (isUploading) return
    setIsUploading(true)
    try {
      await onUpload(file)
      toast.success("Profile photo updated")
    } catch (error) {
      console.error("profile photo upload failed", error)
      toast.error(
        error instanceof InvalidProfilePhotoError
          ? error.message
          : "Couldn't update your profile photo. Please try again.",
      )
    } finally {
      setIsUploading(false)
    }
  }

  const acceptDrop = (event: DragEvent<HTMLButtonElement>) => {
    event.preventDefault()
    dragDepth.current = 0
    setIsDragging(false)
    const file = [...event.dataTransfer.files].find((candidate) =>
      candidate.type.startsWith("image/"),
    )
    if (file) {
      void choosePhoto(file)
    } else {
      toast.error("Drop an image file to update your profile photo.")
    }
  }

  return (
    <>
      <button
        type="button"
        aria-label={isUploading ? "Uploading profile photo" : "Change profile photo"}
        disabled={isUploading}
        onClick={() => inputRef.current?.click()}
        onDragEnter={(event) => {
          event.preventDefault()
          dragDepth.current += 1
          setIsDragging(true)
        }}
        onDragOver={(event) => {
          event.preventDefault()
          event.dataTransfer.dropEffect = "copy"
        }}
        onDragLeave={(event) => {
          event.preventDefault()
          dragDepth.current -= 1
          if (dragDepth.current <= 0) {
            dragDepth.current = 0
            setIsDragging(false)
          }
        }}
        onDrop={acceptDrop}
        className={cn(
          "group relative rounded-full outline-none transition duration-200 hover:scale-[1.02] focus-visible:ring-4 focus-visible:ring-brand/30 active:scale-[0.98]",
          isDragging && "scale-[1.04] ring-4 ring-brand/35",
        )}
      >
        <ProfileAvatar photoURL={photoURL} size={size} />
        <span
          className={cn(
            "pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-1 rounded-full bg-black/58 text-white opacity-0 backdrop-blur-[2px] transition-opacity duration-200 group-hover:opacity-100 group-focus-visible:opacity-100",
            (isDragging || isUploading) && "opacity-100",
          )}
        >
          {isUploading ? (
            <>
              <Loader2 className="size-6 animate-spin" />
              <span className="text-[11px] font-semibold">Uploading</span>
            </>
          ) : (
            <>
              <Camera className="size-6" strokeWidth={2.25} />
              <span className="text-[11px] font-semibold">
                {isDragging ? "Drop photo" : "Change photo"}
              </span>
            </>
          )}
        </span>
        {!isUploading && (
          <span className="pointer-events-none absolute bottom-0 right-0 flex size-8 items-center justify-center rounded-full border-[3px] border-background bg-foreground text-background shadow-sm transition-transform group-hover:scale-0 group-focus-visible:scale-0">
            <Camera className="size-3.5" strokeWidth={2.5} />
          </span>
        )}
      </button>

      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={(event) => {
          const file = event.target.files?.[0]
          event.target.value = ""
          if (file) void choosePhoto(file)
        }}
      />
    </>
  )
}
