import { useState, type ReactNode } from "react"
import { Navigate, useNavigate, useSearchParams } from "react-router-dom"
import { toast } from "@/lib/toast"
import { AppMark } from "@/components/app-mark"
import { authErrorMessage, useAuth } from "@/hooks/use-auth"

/** Sanitized post-login destination (`?next=`), restricted to in-app paths. */
export function nextPath(params: URLSearchParams): string {
  const next = params.get("next")
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/"
}

export function WelcomePage() {
  const { isSignedIn, initializing, signInWithApple, signInWithGoogle } = useAuth()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const [busy, setBusy] = useState(false)

  if (!initializing && isSignedIn) return <Navigate to={nextPath(params)} replace />

  const run = async (action: () => Promise<void>) => {
    setBusy(true)
    try {
      await action()
    } catch (error) {
      const message = authErrorMessage(error)
      if (message) toast(message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="relative flex min-h-dvh flex-col items-center overflow-hidden px-5">
      {/* Faint brand glow behind the icon. */}
      <div
        aria-hidden
        className="pointer-events-none absolute -top-40 left-1/2 h-[480px] w-[640px] -translate-x-1/2 rounded-full opacity-25 blur-3xl dark:opacity-20"
        style={{ background: "radial-gradient(closest-side, var(--brand), transparent 70%)" }}
      />

      <div className="flex w-full max-w-sm flex-1 flex-col items-center justify-center">
        <div className="rise-in flex flex-col items-center">
          <AppMark className="size-30" />
          <h1 className="mt-9 max-w-xs text-center text-[22px] font-bold leading-snug">
            Give your work-in-progress music a proper home
          </h1>
        </div>

        <div className="rise-in mt-10 flex w-full flex-col gap-2.5" style={{ animationDelay: "0.08s" }}>
          <SocialButton
            label="Continue with Apple"
            icon={<AppleLogo />}
            disabled={busy}
            onClick={() => void run(signInWithApple)}
          />
          <SocialButton
            label="Continue with Google"
            icon={<GoogleLogo />}
            disabled={busy}
            onClick={() => void run(signInWithGoogle)}
          />
          <button
            type="button"
            disabled={busy}
            onClick={() => navigate(`/welcome/email?${params.toString()}`)}
            className="mt-1 flex h-11 items-center justify-center text-[17px] font-bold transition-opacity hover:opacity-70 disabled:opacity-40"
          >
            Continue with email
          </button>
        </div>
      </div>

      <p className="rise-in max-w-70 pb-6 text-center text-xs leading-relaxed text-muted-foreground" style={{ animationDelay: "0.16s" }}>
        By continuing, you agree to our Terms of Service and acknowledge our Privacy Policy.
      </p>
    </div>
  )
}

function SocialButton({
  label,
  icon,
  disabled,
  onClick,
}: {
  label: string
  icon: ReactNode
  disabled: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      className="flex h-13 w-full items-center justify-center gap-2.5 rounded-[14px] border border-foreground/6 bg-secondary text-[17px] font-semibold transition hover:bg-secondary/70 active:scale-[0.99] disabled:opacity-40"
    >
      {icon}
      {label}
    </button>
  )
}

function AppleLogo() {
  return (
    <svg viewBox="0 0 24 24" className="size-5 fill-current" aria-hidden>
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  )
}

function GoogleLogo() {
  return (
    <svg viewBox="0 0 24 24" className="size-5" aria-hidden>
      <path
        fill="#4285F4"
        d="M23.49 12.27c0-.79-.07-1.54-.19-2.27H12v4.51h6.47a5.57 5.57 0 0 1-2.4 3.58v3h3.86c2.26-2.09 3.56-5.17 3.56-8.82z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.95-1.08 7.93-2.91l-3.86-3c-1.08.72-2.45 1.16-4.07 1.16-3.13 0-5.78-2.11-6.73-4.96H1.29v3.09A11.99 11.99 0 0 0 12 24z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.29A7.19 7.19 0 0 1 4.89 12c0-.8.14-1.57.38-2.29V6.62H1.29a11.99 11.99 0 0 0 0 10.76l3.98-3.09z"
      />
      <path
        fill="#EA4335"
        d="M12 4.75c1.77 0 3.35.61 4.6 1.8l3.42-3.42C17.95 1.19 15.24 0 12 0 7.31 0 3.26 2.69 1.29 6.62l3.98 3.09C6.22 6.86 8.87 4.75 12 4.75z"
      />
    </svg>
  )
}
