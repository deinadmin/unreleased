import {
  Timestamp,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  onSnapshot,
  setDoc,
  writeBatch,
  type QuerySnapshot,
  type Unsubscribe,
} from "firebase/firestore"
import { httpsCallable } from "firebase/functions"
import { getToken } from "firebase/app-check"
import { decodeGradient, encodeGradient } from "./codec"
import { appCheck, db, functions } from "./firebase"
import type {
  InviteeInfo,
  PendingInviteInfo,
  Project,
  ProjectPreview,
  UserSearchResult,
} from "./types"

const publicWebOrigin = "https://unreleased.top"

/** Firestore stores project doc IDs as uppercase UUIDs (iOS `uuidString`). */
export function normalizeProjectID(raw: string): string {
  return raw.toUpperCase()
}

/** Web share URL for a project (works for guests while link sharing is on). */
export function shareLink(ownerUID: string, projectID: string): string {
  return `${publicWebOrigin}/shared/${encodeURIComponent(ownerUID)}/${encodeURIComponent(projectID.toLowerCase())}`
}

function publicProjectURL(ownerUID: string, projectID: string): URL {
  const firebaseProjectID = import.meta.env.VITE_FIREBASE_PROJECT_ID
  const url = new URL(
    `https://us-central1-${firebaseProjectID}.cloudfunctions.net/getPublicProject`,
  )
  url.searchParams.set("ownerId", ownerUID)
  url.searchParams.set("projectId", projectID.toLowerCase())
  return url
}

/** A track as exposed by `getPublicProject` — private versions are never included. */
export interface PublicTrack {
  id: string
  title: string
  fileName: string
  fileSize: number
  duration: number
  addedDate: string
  waveform?: string
  audioUrl: string
}

export interface PublicProject {
  id: string
  name: string
  ownerUsername: string
  gradient: { colors: string[]; startX: number; startY: number; endX: number; endY: number }
  accentColorHex?: string
  coverGradientColors?: string[]
  coverUrl?: string
  createdDate: string
  updatedDate: string
  tracks: PublicTrack[]
}

/**
 * Outcome of a public-projection load.
 *
 * `unavailable` is the endpoint's deliberate single answer for "link is off,
 * never shared, or no such project". Everything else is `error`: a share link
 * that is live must not be reported to the visitor as missing, and the two
 * cases need different copy and a retry affordance.
 */
export type PublicProjectResult =
  | { status: "ok"; project: PublicProject }
  | { status: "unavailable" }
  | { status: "error"; reason: "app-check" | "network" | "server" }

/**
 * Loads the sanitized public projection of a shared project.
 *
 * Listeners who are not the owner or an accepted invitee read the project from
 * here rather than from Firestore. The raw project document carries private
 * versions and per-track notes, and filtering those in the browser would mean
 * they had already been delivered to it. Returned media URLs are short-lived,
 * path-scoped Storage signatures rather than permanent download tokens.
 *
 * The endpoint enforces App Check, so a build without
 * `VITE_FIREBASE_APPCHECK_SITE_KEY` cannot open any share link. That is
 * intentional, but it must be loud: swallowing it made every public link look
 * like a deleted project.
 */
export async function fetchPublicProject(
  ownerUID: string,
  projectID: string,
): Promise<PublicProjectResult> {
  if (!appCheck) {
    console.error(
      "Public share links need App Check. Set VITE_FIREBASE_APPCHECK_SITE_KEY and rebuild.",
    )
    return { status: "error", reason: "app-check" }
  }
  const token = await getToken(appCheck, false).catch((error) => {
    console.error("Could not obtain an App Check token for the public project request:", error)
    return null
  })
  if (!token) return { status: "error", reason: "app-check" }

  const response = await fetch(publicProjectURL(ownerUID, projectID).toString(), {
    headers: { "X-Firebase-AppCheck": token.token },
  }).catch((error) => {
    console.error("getPublicProject request failed:", error)
    return null
  })
  if (!response) return { status: "error", reason: "network" }
  if (response.status === 404) return { status: "unavailable" }
  if (!response.ok) {
    console.error(`getPublicProject responded ${response.status}.`)
    return { status: "error", reason: "server" }
  }

  const project = (await response.json().catch(() => null)) as PublicProject | null
  if (!project) return { status: "error", reason: "server" }
  return { status: "ok", project }
}

const previewDoc = (ownerUID: string, projectID: string) =>
  doc(db, "users", ownerUID, "projectPreviews", projectID)
const inviteesCol = (ownerUID: string, projectID: string) =>
  collection(db, "users", ownerUID, "projects", projectID, "invitees")
const pendingCol = (ownerUID: string, projectID: string) =>
  collection(db, "users", ownerUID, "projects", projectID, "pendingInvites")
/** Doc holding the shared projects this user accepted: `users/{uid}/private/sharedProjects`. */
const sharedRefsDoc = (uid: string) => doc(db, "users", uid, "private", "sharedProjects")

const inviteNotificationID = (ownerUID: string, projectID: string) =>
  `projectInvite-${ownerUID}-${normalizeProjectID(projectID)}`

// MARK: - Invite preview

/**
 * Writes (or refreshes) the invite preview. Merge-writes and only seeds
 * `linkEnabled` when missing, matching the iOS `writePreview`.
 */
export async function ensurePreview(
  project: Project,
  ownerUID: string,
  ownerUsername: string,
): Promise<void> {
  const ref = previewDoc(ownerUID, project.id)
  const data: Record<string, unknown> = {
    name: project.name,
    ownerUID,
    ownerUsername,
    gradient: encodeGradient(project.gradient),
    coverStoragePath: project.coverStoragePath ?? deleteField(),
    updatedAt: Timestamp.now(),
  }
  if (project.accentColorHex) data.accentColorHex = project.accentColorHex
  const existing = await getDoc(ref).catch(() => null)
  if (existing?.data()?.linkEnabled === undefined) data.linkEnabled = true
  await setDoc(ref, data, { merge: true })
}

/**
 * Keeps an already-shared project's live invite preview in sync. It deliberately
 * does not create a preview for projects that have never been shared.
 */
export async function refreshPreviewIfExists(
  project: Project,
  ownerUID: string,
  ownerUsername?: string,
): Promise<void> {
  const ref = previewDoc(ownerUID, project.id)
  const existing = await getDoc(ref).catch(() => null)
  if (!existing?.exists()) return

  await setDoc(
    ref,
    {
      name: project.name,
      gradient: encodeGradient(project.gradient),
      coverStoragePath: project.coverStoragePath ?? deleteField(),
      accentColorHex: project.accentColorHex ?? deleteField(),
      ...(ownerUsername ? { ownerUsername } : {}),
      updatedAt: Timestamp.now(),
    },
    { merge: true },
  ).catch(() => {})
}

export async function fetchPreview(
  ownerUID: string,
  projectID: string,
): Promise<ProjectPreview | null> {
  const snapshot = await getDoc(previewDoc(ownerUID, projectID)).catch(() => null)
  const data = snapshot?.data()
  if (!data) return null
  const gradient = decodeGradient(data.gradient)
  if (typeof data.name !== "string" || !gradient) return null
  return {
    projectID,
    ownerUID,
    ownerUsername: typeof data.ownerUsername === "string" ? data.ownerUsername : "",
    name: data.name,
    gradient,
    coverStoragePath:
      typeof data.coverStoragePath === "string" ? data.coverStoragePath : undefined,
    accentColorHex: typeof data.accentColorHex === "string" ? data.accentColorHex : undefined,
    linkEnabled: data.linkEnabled === true,
  }
}

export async function setLinkEnabled(
  enabled: boolean,
  ownerUID: string,
  projectID: string,
): Promise<void> {
  await setDoc(previewDoc(ownerUID, projectID), { linkEnabled: enabled }, { merge: true })
}

// MARK: - Invitees

export async function fetchInvitees(ownerUID: string, projectID: string): Promise<InviteeInfo[]> {
  const snapshot = await getDocs(inviteesCol(ownerUID, projectID)).catch(() => null)
  if (!snapshot) return []
  return decodeInvitees(snapshot)
}

function decodeInvitees(snapshot: QuerySnapshot): InviteeInfo[] {
  return snapshot.docs
    .flatMap((docSnap) => {
      const data = docSnap.data()
      if (typeof data.username !== "string" || !(data.acceptedAt instanceof Timestamp)) return []
      return [{ id: docSnap.id, username: data.username, acceptedAt: data.acceptedAt.toDate() }]
    })
    .sort((a, b) => a.acceptedAt.getTime() - b.acceptedAt.getTime())
}

export function observeInvitees(
  ownerUID: string,
  projectID: string,
  onChange: (invitees: InviteeInfo[]) => void,
  onError?: (error: Error) => void,
): Unsubscribe {
  return onSnapshot(
    inviteesCol(ownerUID, projectID),
    (snapshot) => onChange(decodeInvitees(snapshot)),
    (error) => onError?.(error),
  )
}

function decodePendingInvites(snapshot: QuerySnapshot): PendingInviteInfo[] {
  return snapshot.docs
    .flatMap((docSnap) => {
      const data = docSnap.data()
      if (typeof data.username !== "string" || !(data.invitedAt instanceof Timestamp)) return []
      return [
        {
          id: docSnap.id,
          username: data.username,
          invitedAt: data.invitedAt.toDate(),
          notificationID:
            typeof data.notificationID === "string" ? data.notificationID : undefined,
        },
      ]
    })
    .sort((a, b) => a.invitedAt.getTime() - b.invitedAt.getTime())
}

export function observePendingInvites(
  ownerUID: string,
  projectID: string,
  onChange: (pending: PendingInviteInfo[]) => void,
  onError?: (error: Error) => void,
): Unsubscribe {
  return onSnapshot(
    pendingCol(ownerUID, projectID),
    (snapshot) => onChange(decodePendingInvites(snapshot)),
    (error) => onError?.(error),
  )
}

export async function acceptInvite(
  ownerUID: string,
  projectID: string,
  recipientUID: string,
  recipientUsername: string,
): Promise<void> {
  const pendingRef = doc(pendingCol(ownerUID, projectID), recipientUID)
  const pendingSnapshot = await getDoc(pendingRef).catch(() => null)
  const pendingNotificationID = pendingSnapshot?.data()?.notificationID
  const batch = writeBatch(db)
  batch.set(doc(inviteesCol(ownerUID, projectID), recipientUID), {
    uid: recipientUID,
    username: recipientUsername,
    acceptedAt: Timestamp.now(),
  })
  batch.set(
    sharedRefsDoc(recipientUID),
    { refs: { [projectID]: { ownerID: ownerUID, addedAt: Timestamp.now() } } },
    { merge: true },
  )
  batch.delete(pendingRef)
  if (typeof pendingNotificationID === "string" && pendingNotificationID) {
    batch.delete(doc(db, "users", recipientUID, "notifications", pendingNotificationID))
  }
  await batch.commit()
}

export async function removeInvitee(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
): Promise<void> {
  await deleteDoc(doc(inviteesCol(ownerUID, projectID), inviteeUID))
}

/** Removes shared-library membership and access for this account on every device. */
export async function leaveSharedProject(
  ownerUID: string,
  projectID: string,
  userID: string,
): Promise<void> {
  const batch = writeBatch(db)
  batch.set(sharedRefsDoc(userID), { refs: { [projectID]: deleteField() } }, { merge: true })
  batch.delete(doc(inviteesCol(ownerUID, projectID), userID))
  batch.delete(doc(pendingCol(ownerUID, projectID), userID))
  await batch.commit()
}

// MARK: - Username invites

/** Invites a user by UID: pending-invite doc + in-app notification (iOS `inviteUser`). */
export async function inviteUser(
  recipient: UserSearchResult,
  project: Project,
  ownerUID: string,
  ownerUsername: string,
): Promise<void> {
  await ensurePreview(project, ownerUID, ownerUsername)

  const normalizedProjectID = normalizeProjectID(project.id)
  const noteRef = doc(
    db,
    "users",
    recipient.id,
    "notifications",
    inviteNotificationID(ownerUID, normalizedProjectID),
  )
  const pendingRef = doc(pendingCol(ownerUID, normalizedProjectID), recipient.id)
  const now = Timestamp.now()
  const batch = writeBatch(db)
  batch.set(noteRef, {
    type: "projectInvite",
    fromUID: ownerUID,
    fromUsername: ownerUsername,
    projectID: normalizedProjectID,
    projectName: project.name,
    projectGradient: encodeGradient(project.gradient),
    ...(project.coverStoragePath ? { coverStoragePath: project.coverStoragePath } : {}),
    recipientUsername: recipient.username,
    createdAt: now,
    read: false,
  })
  batch.set(pendingRef, {
    uid: recipient.id,
    username: recipient.username,
    invitedAt: now,
    notificationID: noteRef.id,
  })
  await batch.commit()
}

export async function hasPendingInvite(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
): Promise<boolean> {
  const snapshot = await getDoc(doc(pendingCol(ownerUID, projectID), inviteeUID)).catch(() => null)
  return snapshot?.exists() ?? false
}

export async function clearPendingInvite(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
): Promise<void> {
  await deleteDoc(doc(pendingCol(ownerUID, projectID), inviteeUID)).catch(() => {})
}

export async function fetchPendingInvites(
  ownerUID: string,
  projectID: string,
): Promise<PendingInviteInfo[]> {
  const snapshot = await getDocs(pendingCol(ownerUID, projectID)).catch(() => null)
  if (!snapshot) return []
  return decodePendingInvites(snapshot)
}

/** Withdraws a pending invite and best-effort deletes the recipient's notification. */
export async function cancelInvite(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
  notificationID: string | undefined,
): Promise<void> {
  const batch = writeBatch(db)
  if (notificationID) {
    batch.delete(doc(db, "users", inviteeUID, "notifications", notificationID))
  }
  const pendingRef = doc(pendingCol(ownerUID, projectID), inviteeUID)
  batch.delete(pendingRef)
  try {
    await batch.commit()
  } catch {
    // The recipient may already have deleted the notification, making the
    // cross-user delete unauthorizable. Revoke join access regardless; the
    // pending-delete trigger handles notification cleanup.
    await deleteDoc(pendingRef)
  }
}

// MARK: - User search

/**
 * Prefix search over the `usernames` index, run server-side.
 *
 * Doing this in the browser required `list` permission on `usernames`, which
 * is a directory dump of every uid in the system — enough to enumerate other
 * users' projects and share links. The callable applies the same prefix query
 * with the caller's identity and returns only what the UI needs.
 */
export async function searchUsers(
  rawPrefix: string,
  _excludingUID: string | null,
  maxResults = 10,
): Promise<UserSearchResult[]> {
  const prefix = rawPrefix.toLowerCase().trim()
  if (prefix.length < 2) return []
  const call = httpsCallable<{ prefix: string }, { results: UserSearchResult[] }>(
    functions,
    "searchUsers",
  )
  const response = await call({ prefix }).catch(() => null)
  if (!response) return []
  return (response.data.results ?? []).slice(0, maxResults)
}

// MARK: - Accepted shared-project refs (web library persistence)

export interface SharedRef {
  ownerID: string
  projectID: string
}

export async function addSharedRef(uid: string, ref: SharedRef): Promise<void> {
  await setDoc(
    sharedRefsDoc(uid),
    { refs: { [ref.projectID]: { ownerID: ref.ownerID, addedAt: Timestamp.now() } } },
    { merge: true },
  )
}

export async function removeSharedRef(uid: string, projectID: string): Promise<void> {
  await setDoc(sharedRefsDoc(uid), { refs: { [projectID]: deleteField() } }, { merge: true })
}

export { sharedRefsDoc }
