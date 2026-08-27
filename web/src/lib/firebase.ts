import { initializeApp } from "firebase/app"
import { ReCaptchaEnterpriseProvider, initializeAppCheck } from "firebase/app-check"
import { getAuth } from "firebase/auth"
import { getFirestore } from "firebase/firestore"
import { getFunctions } from "firebase/functions"
import { getStorage } from "firebase/storage"

// Public web app config for the `unreleased-web` Firebase app.
const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
  measurementId: import.meta.env.VITE_FIREBASE_MEASUREMENT_ID,
}

export const app = initializeApp(firebaseConfig)

// App Check attests that requests come from this site rather than a script
// holding the (public) web config. Enforcement is toggled per-service in the
// Firebase console; until it is switched on, this only reports metrics, so
// shipping it is safe and lets the "verified requests" number be checked first.
//
// In development the debug token is used instead, which requires registering
// the token printed to the console under App Check > Apps > Manage debug tokens.
const recaptchaSiteKey = import.meta.env.VITE_FIREBASE_APPCHECK_SITE_KEY
export const appCheck = recaptchaSiteKey
  ? (() => {
      if (import.meta.env.DEV) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ;(globalThis as any).FIREBASE_APPCHECK_DEBUG_TOKEN = true
      }
      return initializeAppCheck(app, {
        provider: new ReCaptchaEnterpriseProvider(recaptchaSiteKey),
        isTokenAutoRefreshEnabled: true,
      })
    })()
  : undefined

if (!appCheck && import.meta.env.PROD) {
  console.error("VITE_FIREBASE_APPCHECK_SITE_KEY is required in production.")
}

export const auth = getAuth(app)
export const db = getFirestore(app)
export const storage = getStorage(app)
export const functions = getFunctions(app, "us-central1")
