import { ChevronLeft } from "lucide-react"
import { useState, type FormEvent } from "react"
import { Navigate, useNavigate, useSearchParams } from "react-router-dom"
import { toast } from "sonner"
import { AppMark } from "@/components/app-mark"
import { Input } from "@/components/ui/input"
import { authErrorMessage, useAuth } from "@/hooks/use-auth"
import { nextPath } from "@/pages/welcome"

export function EmailAuthPage() {
  const { isSignedIn, initializing, signInWithEmail, createAccount, sendPasswordReset } = useAuth()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [creating, setCreating] = useState(false)
  const [busy, setBusy] = useState(false)

  if (!initializing && isSignedIn) return <Navigate to={nextPath(params)} replace />

  const canSubmit = email.includes("@") && password.length >= 6 && !busy

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!canSubmit) return
    setBusy(true)
    try {
      const trimmed = email.trim()
      if (creating) await createAccount(trimmed, password)
      else await signInWithEmail(trimmed, password)
    } catch (error) {
      const message = authErrorMessage(error)
      if (message) toast(message)
    } finally {
      setBusy(false)
    }
  }

  const resetPassword = async () => {
    try {
      await sendPasswordReset(email.trim())
      toast(`We sent a password reset link to ${email.trim()}.`)
    } catch (error) {
      const message = authErrorMessage(error)
      if (message) toast(message)
    }
  }

  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-sm flex-col px-5 pb-8">
      <div className="flex h-14 items-center">
        <button
          type="button"
          onClick={() => navigate(`/welcome?${params.toString()}`)}
          className="-ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
        >
          <ChevronLeft className="size-4.5" />
          Back
        </button>
      </div>

      <div className="rise-in flex flex-col items-center pt-2">
        <AppMark className="size-22" />
      </div>

      <form onSubmit={submit} className="rise-in flex flex-1 flex-col pt-8" style={{ animationDelay: "0.06s" }}>
        <h1 className="text-[22px] font-bold">
          {creating ? "Create your account" : "Sign in with email"}
        </h1>
        <p className="pt-2.5 text-[15px] text-muted-foreground">
          {creating
            ? "Use email and a password to keep your projects synced."
            : "Welcome back. Enter the email and password for your account."}
        </p>

        <div className="flex flex-col gap-3 pt-7">
          <Input
            type="email"
            placeholder="Email"
            autoComplete="email"
            autoFocus
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="h-13 rounded-xl bg-secondary px-4 text-[17px] font-medium md:text-[17px]"
          />
          <Input
            type="password"
            placeholder="Password"
            autoComplete={creating ? "new-password" : "current-password"}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="h-13 rounded-xl bg-secondary px-4 text-[17px] font-medium md:text-[17px]"
          />
        </div>

        {!creating && (
          <button
            type="button"
            disabled={busy || !email.includes("@")}
            onClick={() => void resetPassword()}
            className="pt-5 text-center text-[15px] font-semibold transition hover:opacity-70 disabled:opacity-40"
          >
            Forgot password?
          </button>
        )}

        <button
          type="button"
          onClick={() => setCreating((v) => !v)}
          className="pt-3 text-center text-[15px] font-semibold transition hover:opacity-70"
        >
          {creating ? "Already have an account? Sign in" : "New here? Create an account"}
        </button>

        <div className="flex-1" />

        <button
          type="submit"
          disabled={!canSubmit}
          className="mt-6 flex h-13 w-full items-center justify-center rounded-[14px] bg-foreground text-[17px] font-bold text-background transition active:scale-[0.99] disabled:opacity-30"
        >
          {busy ? "One moment…" : creating ? "Create account" : "Sign in"}
        </button>
      </form>
    </div>
  )
}
