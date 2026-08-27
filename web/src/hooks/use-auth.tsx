import {
  GoogleAuthProvider,
  OAuthProvider,
  createUserWithEmailAndPassword,
  onAuthStateChanged,
  sendPasswordResetEmail,
  signInAnonymously,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut as firebaseSignOut,
  type User,
} from "firebase/auth"
import { doc, onSnapshot } from "firebase/firestore"
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react"
import { auth, db } from "@/lib/firebase"
import { clearDownloadURLCache } from "@/lib/storage-urls"
import { clearProjectCoverCache } from "@/lib/project-cover-cache"
import { clearPlayedTrackCache } from "@/lib/track-cache"

interface AuthContextValue {
  user: User | null
  /** True until the initial auth state has been resolved. */
  initializing: boolean
  /** True when signed in with a full (non-anonymous) account. */
  isSignedIn: boolean
  /** True for anonymous guest sessions (shared-link listening). */
  isGuest: boolean
  username: string | null
  /** True once the profile snapshot has delivered (even if username is null). */
  usernameLoaded: boolean
  /** Display handle used when writing invitee docs / previews (username or fallback). */
  displayUsername: string
  signInWithGoogle: () => Promise<void>
  signInWithApple: () => Promise<void>
  signInWithEmail: (email: string, password: string) => Promise<void>
  createAccount: (email: string, password: string) => Promise<void>
  sendPasswordReset: (email: string) => Promise<void>
  signInAsGuest: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [initializing, setInitializing] = useState(true)
  // Keyed by uid so the profile is never mistaken for another account's (or a
  // signed-out session's) result — a stale `null` username would otherwise
  // flash the username onboarding while the real profile is still loading.
  const [profile, setProfile] = useState<{ uid: string | null; username: string | null }>({
    uid: null,
    username: null,
  })

  useEffect(() => {
    return onAuthStateChanged(auth, (nextUser) => {
      setUser(nextUser)
      setInitializing(false)
    })
  }, [])

  // Guests and signed-out sessions have no profile document to read.
  const profileUid = user && !user.isAnonymous ? user.uid : null

  useEffect(() => {
    if (!profileUid) {
      setProfile({ uid: null, username: null })
      return
    }
    return onSnapshot(
      doc(db, "userProfiles", profileUid),
      (snapshot) => {
        setProfile({
          uid: profileUid,
          username: (snapshot.data()?.username as string | undefined) ?? null,
        })
      },
      () => setProfile({ uid: profileUid, username: null }),
    )
  }, [profileUid])

  const usernameLoaded = profile.uid === profileUid
  const username = usernameLoaded ? profile.username : null

  // Memoized because consumers legitimately depend on these callbacks. The
  // shared-link page keys its load effect on `signInAsGuest`; a fresh identity
  // on every provider render re-ran that effect, re-requesting the rate-limited
  // public projection and re-triggering anonymous sign-in.
  const value: AuthContextValue = useMemo(
    () => ({
      user,
      initializing,
      isSignedIn: !!user && !user.isAnonymous,
      isGuest: !!user && user.isAnonymous,
      username,
      usernameLoaded,
      displayUsername:
        username ??
        user?.displayName?.replace(/\s+/g, "").toLowerCase() ??
        user?.email?.split("@")[0]?.toLowerCase() ??
        "listener",
      signInWithGoogle: async () => {
        await signInWithPopup(auth, new GoogleAuthProvider())
      },
      signInWithApple: async () => {
        const provider = new OAuthProvider("apple.com")
        provider.addScope("email")
        provider.addScope("name")
        await signInWithPopup(auth, provider)
      },
      signInWithEmail: async (email: string, password: string) => {
        await signInWithEmailAndPassword(auth, email, password)
      },
      createAccount: async (email: string, password: string) => {
        await createUserWithEmailAndPassword(auth, email, password)
      },
      sendPasswordReset: async (email: string) => {
        await sendPasswordResetEmail(auth, email)
      },
      signInAsGuest: async () => {
        await signInAnonymously(auth)
      },
      signOut: async () => {
        await Promise.allSettled([
          clearProjectCoverCache(),
          clearPlayedTrackCache(),
        ])
        clearDownloadURLCache()
        await firebaseSignOut(auth)
      },
    }),
    [user, initializing, username, usernameLoaded],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error("useAuth must be used within AuthProvider")
  return context
}

/** Human-readable message for Firebase auth errors. */
export function authErrorMessage(error: unknown): string {
  const code = (error as { code?: string })?.code ?? ""
  switch (code) {
    case "auth/invalid-credential":
    case "auth/wrong-password":
    case "auth/user-not-found":
      return "Incorrect email or password."
    case "auth/email-already-in-use":
      return "An account with this email already exists."
    case "auth/invalid-email":
      return "That email address doesn't look right."
    case "auth/weak-password":
      return "Please choose a stronger password (at least 6 characters)."
    case "auth/too-many-requests":
      return "Too many attempts. Please try again later."
    case "auth/popup-closed-by-user":
    case "auth/cancelled-popup-request":
      return ""
    default:
      return "Something went wrong signing you in. Please try again."
  }
}
