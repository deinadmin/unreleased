import { doc, getDocFromServer, runTransaction } from "firebase/firestore"
import { db } from "./firebase"

/**
 * Username claiming and lookup, mirroring the iOS `UserProfileService`:
 * `usernames/{username}` is the uniqueness index (`{ uid }`), and the chosen
 * name is stored on `userProfiles/{uid}`.
 */

export const USERNAME_HINT = "3–20 characters. Letters, numbers, and underscores only."

export function isValidUsernameFormat(value: string): boolean {
  return /^[a-z0-9_]{3,20}$/.test(value)
}

export class UsernameTakenError extends Error {
  constructor(username: string) {
    super(`@${username} is already taken.`)
    this.name = "UsernameTakenError"
  }
}

/**
 * Returns true when the username is not yet claimed. Always reads from the
 * server so a cached "not found" can't give a false positive.
 */
export async function isUsernameAvailable(username: string): Promise<boolean> {
  const snapshot = await getDocFromServer(doc(db, "usernames", username.toLowerCase()))
  return !snapshot.exists()
}

/** Atomically checks availability and claims `username` for `uid`. */
export async function claimUsername(uid: string, username: string): Promise<void> {
  const name = username.toLowerCase()
  await runTransaction(db, async (transaction) => {
    const usernameRef = doc(db, "usernames", name)
    const existing = await transaction.get(usernameRef)
    if (existing.exists()) throw new UsernameTakenError(name)
    transaction.set(usernameRef, { uid })
    transaction.set(doc(db, "userProfiles", uid), { username: name }, { merge: true })
  })
}
