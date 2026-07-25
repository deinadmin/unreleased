import {
  Timestamp,
  collection,
  deleteDoc,
  deleteField,
  doc,
  endAt,
  documentId,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  setDoc,
  startAt,
} from "firebase/firestore"
import { decodeGradient, encodeGradient } from "./codec"
import { db } from "./firebase"
import type {
  InviteeInfo,
  PendingInviteInfo,
  Project,
  ProjectPreview,
  UserSearchResult,
} from "./types"

/** Firestore stores project doc IDs as uppercase UUIDs (iOS `uuidString`). */
export function normalizeProjectID(raw: string): string {
  return raw.toUpperCase()
}

/** Web share URL for a project (works for guests while link sharing is on). */
export function shareLink(ownerUID: string, projectID: string): string {
  return `${window.location.origin}/shared/${ownerUID}/${projectID.toLowerCase()}`
}

const previewDoc = (ownerUID: string, projectID: string) =>
  doc(db, "users", ownerUID, "projectPreviews", projectID)
const inviteesCol = (ownerUID: string, projectID: string) =>
  collection(db, "users", ownerUID, "projects", projectID, "invitees")
const pendingCol = (ownerUID: string, projectID: string) =>
  collection(db, "users", ownerUID, "projects", projectID, "pendingInvites")

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
    updatedAt: Timestamp.now(),
  }
  if (project.accentColorHex) data.accentColorHex = project.accentColorHex
  const existing = await getDoc(ref).catch(() => null)
  if (existing?.data()?.linkEnabled === undefined) data.linkEnabled = true
  await setDoc(ref, data, { merge: true })
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
  return snapshot.docs.flatMap((docSnap) => {
    const data = docSnap.data()
    if (typeof data.username !== "string" || !(data.acceptedAt instanceof Timestamp)) return []
    return [{ id: docSnap.id, username: data.username, acceptedAt: data.acceptedAt.toDate() }]
  })
}

export async function acceptInvite(
  ownerUID: string,
  projectID: string,
  recipientUID: string,
  recipientUsername: string,
): Promise<void> {
  await setDoc(doc(inviteesCol(ownerUID, projectID), recipientUID), {
    uid: recipientUID,
    username: recipientUsername,
    acceptedAt: Timestamp.now(),
  })
}

export async function removeInvitee(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
): Promise<void> {
  await deleteDoc(doc(inviteesCol(ownerUID, projectID), inviteeUID))
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

  const noteRef = doc(collection(db, "users", recipient.id, "notifications"))
  await setDoc(noteRef, {
    type: "projectInvite",
    fromUID: ownerUID,
    fromUsername: ownerUsername,
    projectID: project.id,
    projectName: project.name,
    createdAt: Timestamp.now(),
    read: false,
  })

  await setDoc(doc(pendingCol(ownerUID, project.id), recipient.id), {
    uid: recipient.id,
    username: recipient.username,
    invitedAt: Timestamp.now(),
    notificationID: noteRef.id,
  })
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
  return snapshot.docs.flatMap((docSnap) => {
    const data = docSnap.data()
    if (typeof data.username !== "string" || !(data.invitedAt instanceof Timestamp)) return []
    return [
      {
        id: docSnap.id,
        username: data.username,
        invitedAt: data.invitedAt.toDate(),
        notificationID: typeof data.notificationID === "string" ? data.notificationID : undefined,
      },
    ]
  })
}

/** Withdraws a pending invite and best-effort deletes the recipient's notification. */
export async function cancelInvite(
  ownerUID: string,
  projectID: string,
  inviteeUID: string,
  notificationID: string | undefined,
): Promise<void> {
  if (notificationID) {
    await deleteDoc(doc(db, "users", inviteeUID, "notifications", notificationID)).catch(() => {})
  }
  await clearPendingInvite(ownerUID, projectID, inviteeUID)
}

// MARK: - User search

/** Prefix search over the `usernames` index (doc ID = lowercased username). */
export async function searchUsers(
  rawPrefix: string,
  excludingUID: string | null,
  maxResults = 10,
): Promise<UserSearchResult[]> {
  const prefix = rawPrefix.toLowerCase().trim()
  if (!prefix) return []
  const usersQuery = query(
    collection(db, "usernames"),
    orderBy(documentId()),
    startAt(prefix),
    endAt(prefix + "\uf8ff"),
    limit(maxResults + 1),
  )
  const snapshot = await getDocs(usersQuery).catch(() => null)
  if (!snapshot) return []
  return snapshot.docs
    .flatMap((docSnap) => {
      const uid = docSnap.data().uid
      if (typeof uid !== "string" || uid === excludingUID) return []
      return [{ id: uid, username: docSnap.id }]
    })
    .slice(0, maxResults)
}

// MARK: - Accepted shared-project refs (web library persistence)

/** Doc holding the shared projects this user accepted: `users/{uid}/private/sharedProjects`. */
const sharedRefsDoc = (uid: string) => doc(db, "users", uid, "private", "sharedProjects")

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
