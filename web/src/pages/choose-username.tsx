import { AtSign, CircleAlert, CircleCheck, CircleX, Loader2 } from "lucide-react"
import { useEffect, useState } from "react"
import { useAuth } from "@/hooks/use-auth"
import {
  USERNAME_HINT,
  UsernameTakenError,
  claimUsername,
  isUsernameAvailable,
  isValidUsernameFormat,
} from "@/lib/user-profile"
import { cn } from "@/lib/utils"

type Availability =
  | { status: "idle" }
  | { status: "checking" }
  | { status: "available" }
  | { status: "taken" }
  | { status: "invalid" }
  | { status: "checkFailed" }
  | { status: "saveFailed"; message: string }

/**
 * First-run onboarding: pick a unique username before entering the app,
 * mirroring the iOS `UsernamePickerSheet` (debounced availability check
 * against `usernames/{name}`, atomic claim on continue).
 */
export function ChooseUsernamePage() {
  const { user } = useAuth()
  const [username, setUsername] = useState("")
  const [availability, setAvailability] = useState<Availability>({ status: "idle" })
  const [saving, setSaving] = useState(false)

  const handleInput = (raw: string) => {
    const cleaned = raw.toLowerCase().replace(/\s/g, "")
    setUsername(cleaned)
    if (!cleaned) setAvailability({ status: "idle" })
    else if (!isValidUsernameFormat(cleaned)) setAvailability({ status: "invalid" })
    else setAvailability({ status: "checking" })
  }

  // Debounced availability check while in the "checking" state.
  useEffect(() => {
    if (availability.status !== "checking") return
    let cancelled = false
    const timer = setTimeout(() => {
      isUsernameAvailable(username)
        .then((available) => {
          if (!cancelled) setAvailability({ status: available ? "available" : "taken" })
        })
        .catch(() => {
          if (!cancelled) setAvailability({ status: "checkFailed" })
        })
    }, 500)
    return () => {
      cancelled = true
      clearTimeout(timer)
    }
  }, [availability.status, username])

  const isReady = availability.status === "available" && !saving

  const save = async () => {
    if (!user || !isReady) return
    setSaving(true)
    try {
      await claimUsername(user.uid, username)
      // The profile snapshot flips the onboarding gate — nothing else to do.
    } catch (error) {
      setSaving(false)
      if (error instanceof UsernameTakenError) {
        setAvailability({ status: "taken" })
      } else {
        console.error("claiming username failed", error)
        setAvailability({
          status: "saveFailed",
          message: "Couldn't save your username. Please try again.",
        })
      }
    }
  }

  return (
    <div className="relative flex min-h-dvh flex-col items-center overflow-hidden px-5">
      <div
        aria-hidden
        className="pointer-events-none absolute -top-40 left-1/2 h-[480px] w-[640px] -translate-x-1/2 rounded-full opacity-25 blur-3xl dark:opacity-20"
        style={{ background: "radial-gradient(closest-side, var(--brand), transparent 70%)" }}
      />

      <div className="flex w-full max-w-sm flex-1 flex-col items-center justify-center">
        <div className="rise-in flex flex-col items-center">
          <div className="flex size-16 items-center justify-center rounded-full bg-secondary">
            <AtSign className="size-7" strokeWidth={2.25} />
          </div>
          <h1 className="mt-6 text-[22px] font-bold">Choose a username</h1>
          <p className="mt-1.5 max-w-xs text-center text-[15px] text-muted-foreground">
            Others see this when you share a project.
          </p>
        </div>

        <div className="rise-in mt-8 w-full" style={{ animationDelay: "0.08s" }}>
          <div className="flex h-13 items-center rounded-[14px] border border-foreground/6 bg-secondary pl-4 pr-2 transition-colors focus-within:border-ring">
            <span className="text-[17px] font-medium text-muted-foreground">@</span>
            <input
              value={username}
              autoFocus
              placeholder="username"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              maxLength={20}
              onChange={(event) => handleInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void save()
              }}
              className="h-full min-w-0 flex-1 bg-transparent pl-1 text-[17px] outline-none placeholder:text-muted-foreground/50"
            />
            <span className="flex size-9 items-center justify-center">
              <StatusIndicator availability={availability} />
            </span>
          </div>

          <p
            className={cn(
              "min-h-9 pt-2 text-[13px] leading-snug transition-colors duration-200",
              hintColor(availability),
            )}
          >
            {hintText(availability, username)}
          </p>

          <button
            type="button"
            disabled={!isReady}
            onClick={() => void save()}
            className={cn(
              "flex h-13 w-full items-center justify-center rounded-[14px] text-[17px] font-bold transition-all duration-200 active:scale-[0.99]",
              isReady
                ? "bg-foreground text-background hover:opacity-90"
                : "bg-secondary text-muted-foreground/50",
            )}
          >
            {saving ? <Loader2 className="size-5 animate-spin" /> : "Continue"}
          </button>
        </div>
      </div>
    </div>
  )
}

function StatusIndicator({ availability }: { availability: Availability }) {
  switch (availability.status) {
    case "idle":
      return null
    case "checking":
      return <Loader2 className="size-4.5 animate-spin text-muted-foreground" />
    case "available":
      return <CircleCheck className="size-5 text-green-500 duration-200 animate-in zoom-in-50" />
    case "checkFailed":
      return <CircleAlert className="size-5 text-orange-500 duration-200 animate-in zoom-in-50" />
    default:
      return <CircleX className="size-5 text-destructive duration-200 animate-in zoom-in-50" />
  }
}

function hintText(availability: Availability, username: string): string {
  switch (availability.status) {
    case "taken":
      return `@${username} is already taken.`
    case "available":
      return `@${username} is available.`
    case "checkFailed":
      return "Couldn't check availability. Check your connection."
    case "saveFailed":
      return availability.message
    default:
      return USERNAME_HINT
  }
}

function hintColor(availability: Availability): string {
  switch (availability.status) {
    case "taken":
    case "invalid":
    case "saveFailed":
      return "text-destructive"
    case "available":
      return "text-green-600 dark:text-green-500"
    case "checkFailed":
      return "text-orange-500"
    default:
      return "text-muted-foreground"
  }
}
