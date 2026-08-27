import {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentWritten,
} from "firebase-functions/v2/firestore";
import { onObjectFinalized, onObjectDeleted } from "firebase-functions/v2/storage";
import { onCall, HttpsError, onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getFirestore, FieldPath, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";
import { createHash, randomUUID } from "node:crypto";
import { AUDIO_RENDITIONS, renditionStoragePath } from "./audio-renditions.js";

export {
  backfillAudioRenditions,
  cleanupAudioRenditions,
  generateAudioRenditions,
} from "./audio-renditions.js";
export {
  backfillAudioAccessIndexes,
  syncProjectAudioAccess,
} from "./audio-access.js";

initializeApp();

const PROJECT_INVITE_TYPE = "projectInvite";
const SHARED_RECONCILE_STATE_PATH = "_system/sharedProjectReconcileV2";
const SHARED_RECONCILE_PAGE_SIZE = 200;
const STALE_MESSAGING_TOKEN_CODES = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
]);

async function removePushTokenIfCurrent(pushRef, token) {
  await getFirestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(pushRef);
    if (snapshot.get("fcmToken") !== token) return;
    transaction.update(pushRef, {
      fcmToken: FieldValue.delete(),
      platform: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function ensureAcceptedSharedProjectReference(
  ownerId,
  projectId,
  inviteeId,
  acceptedAt = Timestamp.now()
) {
  await getFirestore()
    .doc(`users/${inviteeId}/private/sharedProjects`)
    .set(
      {
        refs: {
          [projectId]: {
            ownerID: ownerId,
            addedAt: acceptedAt instanceof Timestamp ? acceptedAt : Timestamp.now(),
          },
        },
      },
      { merge: true }
    );
}

/**
 * Makes the pending-invite document match an invite notification.
 *
 * A transaction is important here: an owner can withdraw an invite while this
 * trigger is starting. Re-reading the notification in the transaction prevents
 * a delayed function invocation from resurrecting a cancelled invite.
 */
async function ensurePendingInviteForNotification(notificationRef, recipientId) {
  const db = getFirestore();
  return db.runTransaction(async (transaction) => {
    const notificationSnap = await transaction.get(notificationRef);
    if (!notificationSnap.exists) return false;

    const data = notificationSnap.data();
    const ownerId = data.fromUID;
    const projectId = data.projectID;
    if (
      data.type !== PROJECT_INVITE_TYPE ||
      typeof ownerId !== "string" ||
      !ownerId ||
      typeof projectId !== "string" ||
      !projectId
    ) {
      return false;
    }

    const inviteeRef = db.doc(
      `users/${ownerId}/projects/${projectId}/invitees/${recipientId}`
    );
    const projectRef = db.doc(`users/${ownerId}/projects/${projectId}`);
    const pendingRef = db.doc(
      `users/${ownerId}/projects/${projectId}/pendingInvites/${recipientId}`
    );
    const profileRef = db.doc(`userProfiles/${recipientId}`);
    const [projectSnap, inviteeSnap, profileSnap, pendingSnap] = await Promise.all([
      transaction.get(projectRef),
      transaction.get(inviteeRef),
      transaction.get(profileRef),
      transaction.get(pendingRef),
    ]);

    if (!projectSnap.exists) {
      transaction.delete(notificationRef);
      transaction.delete(pendingRef);
      return true;
    }

    // Accepted users are listeners, not pending invitees. Remove any stale
    // invite notification instead of recreating pending state for them.
    if (inviteeSnap.exists) {
      transaction.delete(notificationRef);
      transaction.delete(pendingRef);
      return true;
    }

    const profileUsername = profileSnap.get("username");
    const username =
      typeof data.recipientUsername === "string" && data.recipientUsername
        ? data.recipientUsername
        : typeof profileUsername === "string" && profileUsername
          ? profileUsername
          : "listener";

    // Already correct: the periodic reconcile visits every invite notification,
    // so rewriting an unchanged document would reintroduce exactly the write
    // amplification this repair path was moved off the hot path to avoid.
    if (
      pendingSnap.exists &&
      pendingSnap.get("uid") === recipientId &&
      pendingSnap.get("username") === username &&
      pendingSnap.get("notificationID") === notificationRef.id
    ) {
      return false;
    }

    transaction.set(
      pendingRef,
      {
        uid: recipientId,
        username,
        invitedAt:
          data.createdAt instanceof Timestamp ? data.createdAt : Timestamp.now(),
        notificationID: notificationRef.id,
      },
      { merge: true }
    );
    return true;
  });
}

/**
 * Sends a push notification whenever a notification document is created at
 * `users/{userId}/notifications/{notificationId}`.
 *
 * The recipient's FCM token is read from `users/{userId}/private/push`,
 * which the iOS client writes after registering for remote notifications.
 */
export const sendNotificationPush = onDocumentCreated(
  "users/{userId}/notifications/{notificationId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    const userId = event.params.userId;

    if (data.type === PROJECT_INVITE_TYPE) {
      await ensurePendingInviteForNotification(snap.ref, userId);
    }

    // Look up the recipient's push token.
    const pushRef = getFirestore().doc(`users/${userId}/private/push`);
    const tokenSnap = await pushRef.get();
    const fcmToken = tokenSnap.get("fcmToken");
    if (!fcmToken) {
      logger.info(`No FCM token for user ${userId}; skipping push.`);
      return;
    }

    // Missing settings preserve notification behavior for existing users.
    if (tokenSnap.get("notificationsEnabled") === false) {
      logger.info(`Notifications disabled for user ${userId}; skipping push.`);
      return;
    }
    if (
      data.type === "projectInvite" &&
      tokenSnap.get("projectInvitesEnabled") === false
    ) {
      logger.info(`Project invite pushes disabled for user ${userId}; skipping push.`);
      return;
    }

    const { title, body } = buildMessage(data);

    try {
      await getMessaging().send({
        token: fcmToken,
        notification: { title, body },
        data: {
          type: String(data.type ?? ""),
          ownerID: String(data.fromUID ?? ""),
          projectID: String(data.projectID ?? ""),
        },
        apns: {
          payload: {
            aps: { sound: "default", badge: 1 },
          },
        },
      });
      logger.info(`Sent push to ${userId}.`);
    } catch (error) {
      if (STALE_MESSAGING_TOKEN_CODES.has(error?.code)) {
        try {
          await removePushTokenIfCurrent(pushRef, fcmToken);
          logger.info(`Removed stale push token for ${userId}.`);
        } catch (cleanupError) {
          logger.error(`Failed to remove stale push token for ${userId}:`, cleanupError);
        }
        return;
      }
      logger.error(`Failed to send push to ${userId}:`, error);
    }
  }
);

/**
 * Repairs shared-project state that the real-time triggers could not.
 *
 * Both invariants below are already maintained as they happen — invite
 * notifications by `sendNotificationPush`, membership references by
 * `ensureAcceptedSharedProjectIsIndexed`. This only catches what those missed:
 * orphans from older clients that wrote invites non-atomically, and references
 * lost to a transient client failure.
 *
 * It used to hang off every `projectPreviews` write, which both clients perform
 * on every project sync. That meant one Firestore write per listener on every
 * track rename or note edit — a cost that scaled with an owner's audience and
 * found nothing to fix virtually every time. Repair is not a real-time
 * requirement, so it runs on a schedule and writes only on an actual mismatch.
 */
export const reconcileSharedProjectState = onSchedule(
  {
    schedule: "every 24 hours",
    timeZone: "Etc/UTC",
    memory: "512MiB",
    timeoutSeconds: 540,
    maxInstances: 1,
  },
  async () => {
    const db = getFirestore();
    const stateReference = db.doc(SHARED_RECONCILE_STATE_PATH);
    const state = await stateReference.get();

    // ── Membership references ────────────────────────────────────────────────
    // Grouped by recipient so each user's reference document is read once
    // regardless of how many projects they follow.
    let inviteesQuery = db
      .collectionGroup("invitees")
      .orderBy(FieldPath.documentId())
      .limit(SHARED_RECONCILE_PAGE_SIZE);
    const inviteeCursor = String(state.get("inviteeCursor") ?? "");
    if (inviteeCursor) inviteesQuery = inviteesQuery.startAfter(inviteeCursor);
    const invitees = await inviteesQuery.get();
    const wantedByInvitee = new Map();
    for (const invitee of invitees.docs) {
      const projectRef = invitee.ref.parent.parent;
      const ownerRef = projectRef?.parent.parent;
      if (!projectRef || !ownerRef || ownerRef.parent.id !== "users") continue;
      const entry = wantedByInvitee.get(invitee.id) ?? [];
      entry.push({
        projectId: projectRef.id,
        ownerId: ownerRef.id,
        acceptedAt: invitee.get("acceptedAt"),
      });
      wantedByInvitee.set(invitee.id, entry);
    }

    let repairedReferences = 0;
    for (const [inviteeId, wanted] of wantedByInvitee) {
      const snapshot = await db.doc(`users/${inviteeId}/private/sharedProjects`).get();
      const existing = snapshot.get("refs") ?? {};
      const missing = wanted.filter(
        (entry) => existing[entry.projectId]?.ownerID !== entry.ownerId
      );
      for (const entry of missing) {
        await ensureAcceptedSharedProjectReference(
          entry.ownerId,
          entry.projectId,
          inviteeId,
          entry.acceptedAt
        );
        repairedReferences += 1;
      }
    }

    // ── Orphaned invite notifications ────────────────────────────────────────
    let notificationQuery = db
      .collectionGroup("notifications")
      .where("type", "==", PROJECT_INVITE_TYPE)
      .orderBy(FieldPath.documentId())
      .limit(SHARED_RECONCILE_PAGE_SIZE);
    const notificationCursor = String(state.get("notificationCursor") ?? "");
    if (notificationCursor) {
      notificationQuery = notificationQuery.startAfter(notificationCursor);
    }
    const notifications = await notificationQuery.get();
    let reconciledInvites = 0;
    for (const notification of notifications.docs) {
      const recipientId = notification.ref.parent.parent?.id;
      if (!recipientId) continue;
      if (await ensurePendingInviteForNotification(notification.ref, recipientId)) {
        reconciledInvites += 1;
      }
    }

    await stateReference.set({
      inviteeCursor:
        invitees.size < SHARED_RECONCILE_PAGE_SIZE
          ? FieldValue.delete()
          : invitees.docs.at(-1).ref.path,
      notificationCursor:
        notifications.size < SHARED_RECONCILE_PAGE_SIZE
          ? FieldValue.delete()
          : notifications.docs.at(-1).ref.path,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (repairedReferences > 0 || reconciledInvites > 0) {
      logger.info(
        `Reconciled ${repairedReferences} shared-project reference(s) and ` +
          `${reconciledInvites} invite notification(s).`
      );
    }
  }
);

/**
 * Membership and library visibility are one invariant. Clients write both in
 * one batch, while this trigger repairs references created by older builds or
 * removed by a transient client-side listener failure.
 */
export const ensureAcceptedSharedProjectIsIndexed = onDocumentWritten(
  "users/{ownerId}/projects/{projectId}/invitees/{inviteeId}",
  async (event) => {
    if (!event.data?.after.exists) return;
    await ensureAcceptedSharedProjectReference(
      event.params.ownerId,
      event.params.projectId,
      event.params.inviteeId,
      event.data.after.get("acceptedAt")
    );
  }
);

/**
 * Deleting pending state always withdraws its notification, including deletes
 * performed by older app versions after acceptance.
 */
export const removeWithdrawnInviteNotification = onDocumentDeleted(
  "users/{ownerId}/projects/{projectId}/pendingInvites/{inviteeId}",
  async (event) => {
    const { ownerId, projectId, inviteeId } = event.params;
    await deleteInviteNotifications(inviteeId, ownerId, projectId);
  }
);

/**
 * Removes the invite notification(s) a given owner addressed to a recipient
 * for one project.
 *
 * Invite notifications use a deterministic id, so the common case is a single
 * targeted delete. The bounded fallback query only exists for notifications
 * written by older clients with random ids — it is filtered and limited so a
 * recipient with a large notification collection can never turn this trigger
 * into a full-collection scan.
 */
async function deleteInviteNotifications(recipientId, ownerId, projectId) {
  const db = getFirestore();
  const collection = db.collection(`users/${recipientId}/notifications`);

  await collection.doc(inviteNotificationId(ownerId, projectId)).delete();

  const legacy = await collection
    .where("projectID", "==", projectId)
    .limit(20)
    .get();
  await Promise.all(
    legacy.docs
      .filter((notification) => {
        const data = notification.data();
        return data.type === PROJECT_INVITE_TYPE && data.fromUID === ownerId;
      })
      .map((notification) => notification.ref.delete())
  );
}

/** Mirrors `inviteNotificationID` in the clients and the Firestore rules. */
function inviteNotificationId(ownerId, projectId) {
  return `${PROJECT_INVITE_TYPE}-${ownerId}-${projectId}`;
}

/**
 * Removing a listener also removes the shared-project reference on every
 * device. If link sharing remains enabled, the user can still rejoin via link.
 */
export const removeRevokedSharedProjectReference = onDocumentDeleted(
  "users/{ownerId}/projects/{projectId}/invitees/{inviteeId}",
  async (event) => {
    const { ownerId, projectId, inviteeId } = event.params;
    const db = getFirestore();
    const batch = db.batch();
    batch.set(
      db.doc(`users/${inviteeId}/private/sharedProjects`),
      { refs: { [projectId]: FieldValue.delete() } },
      { merge: true }
    );
    batch.delete(
      db.doc(`users/${ownerId}/projects/${projectId}/pendingInvites/${inviteeId}`)
    );
    await batch.commit();
    await deleteInviteNotifications(inviteeId, ownerId, projectId);

    // Removing a listener has to actually cut them off. A Firebase download URL
    // is a bearer token that ignores Storage Rules, so any URL this listener
    // already resolved would keep working forever unless the object's token is
    // replaced. Rotating costs current members one silent re-resolve.
    await revokeProjectDownloadTokens(ownerId, projectId);
  }
);

// ── Download-token revocation ────────────────────────────────────────────────
//
// `getDownloadURL()` mints a long-lived, unauthenticated URL carrying the
// object's `firebaseStorageDownloadTokens` value. Storage Rules are evaluated
// when the URL is issued and never again, so revoking access in Firestore does
// not invalidate URLs already handed out. Replacing the token does.

/** Every object a project's listeners could hold a download URL for. */
function projectObjectPaths(project) {
  const paths = [];
  const addAudio = (storagePath) => {
    if (typeof storagePath !== "string" || !storagePath) return;
    paths.push(storagePath);
    for (const quality of Object.keys(AUDIO_RENDITIONS)) {
      const rendition = renditionStoragePath(storagePath, quality);
      if (rendition) paths.push(rendition);
    }
  };

  for (const track of Array.isArray(project?.tracks) ? project.tracks : []) {
    const versions = Array.isArray(track?.versions) ? track.versions : [];
    if (versions.length === 0) {
      addAudio(track?.storagePath);
      continue;
    }
    for (const version of versions) addAudio(version?.storagePath);
  }
  if (typeof project?.coverStoragePath === "string") paths.push(project.coverStoragePath);
  return paths;
}

async function rotateDownloadTokens(storagePaths) {
  const bucket = getStorage().bucket();
  const unique = [...new Set(storagePaths)];
  await Promise.all(
    unique.map(async (storagePath) => {
      try {
        await bucket
          .file(storagePath)
          .setMetadata({ metadata: { firebaseStorageDownloadTokens: randomUUID() } });
      } catch (error) {
        // A missing object needs no revocation.
        if (error?.code !== 404) {
          logger.warn(`Could not rotate download token for ${storagePath}:`, error);
        }
      }
    })
  );
  return unique.length;
}

async function revokeProjectDownloadTokens(ownerId, projectId) {
  const snapshot = await getFirestore().doc(`users/${ownerId}/projects/${projectId}`).get();
  if (!snapshot.exists) return;
  const rotated = await rotateDownloadTokens(projectObjectPaths(snapshot.data()));
  if (rotated > 0) {
    logger.info(`Rotated ${rotated} download token(s) for project ${projectId}.`);
  }
}

/**
 * Turning a share link off must revoke guests who already loaded the page, so
 * the transition to disabled rotates every object the project exposed.
 */
export const revokeTokensWhenLinkDisabled = onDocumentWritten(
  "users/{ownerId}/projectPreviews/{projectId}",
  async (event) => {
    const wasEnabled = event.data?.before.get("linkEnabled") === true;
    const isEnabled = event.data?.after.get("linkEnabled") === true;
    if (!wasEnabled || isEnabled) return;
    await revokeProjectDownloadTokens(event.params.ownerId, event.params.projectId);
  }
);

function buildMessage(data) {
  switch (data.type) {
    case "projectInvite":
      return {
        title: "New project invite",
        body: `@${data.fromUsername ?? "Someone"} invited you to “${
          data.projectName ?? "a project"
        }”`,
      };
    default:
      return { title: "unreleased", body: "You have a new notification." };
  }
}

// ── Storage limit enforcement ────────────────────────────────────────────────
//
// Clients upload directly to Cloud Storage:
//   users/{uid}/audio/{trackId}.{ext}                     legacy track audio
//   users/{uid}/audio/versions/{versionId}/audio.{ext}    version audio
//   users/{uid}/covers/{projectId}-{version}.jpg          project artwork
//   users/{uid}/profile/avatar.jpg                        profile picture
//
// Storage security rules can only validate ownership, per-object size and the
// object name — they cannot enforce a *cumulative* quota. These triggers are
// the authoritative, tamper-proof enforcement: if an upload pushes a user past
// their plan's limit the offending object is deleted and a rejection recorded.
// A modified client cannot bypass it because enforcement runs server-side after
// the bytes land, regardless of what the client believes.
//
// EVERY user-writable prefix is metered. Only counting audio/ left covers/ and
// profile/ as unlimited free storage, since rules permit writes there too.
// Server-generated audio-renditions/ are excluded: they are derived from
// already-metered originals and are not client-writable.

// Plan storage limits in bytes. MUST stay in sync with `PlanTier` in
// `unreleased/Models/UserPlan.swift`. `null` means unlimited (no cap).
const PLAN_STORAGE_LIMITS = {
  free: 1_000_000_000, // 1 GB
  premium: 30_000_000_000, // 30 GB
  unlimited: null,
};

const AUDIO_PREFIX_RE =
  /^users\/([^/]+)\/audio\/(?:versions\/([^/]+)\/)?([^/]+)$/;
/** Every prefix a client can write to, and therefore every prefix we meter. */
const METERED_PREFIX_RE = /^users\/([^/]+)\/(audio|covers|profile)\//;
const STORAGE_ACCOUNTING_VERSION = 2;
const MAX_METERED_OBJECTS = 5_000;
const STORAGE_INVENTORY_LIMIT = MAX_METERED_OBJECTS + 1;
const STORAGE_ACCOUNTING_LEASE_MS = 2 * 60 * 1000;

class StorageAccountingBusyError extends Error {}

function meteredUserId(objectName) {
  return METERED_PREFIX_RE.exec(objectName)?.[1] ?? null;
}

/** Returns the effective storage limit (bytes) for a user, honoring plan expiry. */
async function effectiveStorageLimit(userId) {
  const snap = await getFirestore().doc(`users/${userId}`).get();
  let tier = "free";
  if (snap.exists) {
    const planValue = snap.get("plan");
    if (planValue && Object.prototype.hasOwnProperty.call(PLAN_STORAGE_LIMITS, planValue)) {
      tier = planValue;
    }
    // Degrade to free when the plan has expired.
    const expiresAt = snap.get("planExpiresAt");
    if (expiresAt instanceof Timestamp && expiresAt.toMillis() < Date.now()) {
      tier = "free";
    }
  }
  return { tier, limitBytes: PLAN_STORAGE_LIMITS[tier] };
}

/** Bounded authoritative inventory of every metered object for one user. */
async function meteredInventory(bucket, userId) {
  const prefixes = ["audio", "covers", "profile"];
  const files = [];
  for (const prefix of prefixes) {
    const remaining = STORAGE_INVENTORY_LIMIT - files.length;
    if (remaining <= 0) break;
    const [page] = await bucket.getFiles({
      prefix: `users/${userId}/${prefix}/`,
      maxResults: remaining,
    });
    files.push(...page.slice(0, remaining));
  }
  const usedBytes = files.reduce((total, file) => {
    const size = Number(file.metadata?.size ?? 0);
    return total + (Number.isFinite(size) ? size : 0);
  }, 0);
  return {
    files,
    usedBytes,
    objectCount: files.length,
    truncated: files.length >= STORAGE_INVENTORY_LIMIT,
  };
}

function storageObjectReference(userId, objectName) {
  const objectId = createHash("sha256").update(objectName).digest("hex");
  return getFirestore().doc(`users/${userId}/storageObjects/${objectId}`);
}

async function objectPrefix(file, length = 16) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const stream = file.createReadStream({ start: 0, end: length - 1 });
    stream.on("data", (chunk) => chunks.push(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

function ascii(prefix, start, end) {
  return prefix.subarray(start, end).toString("ascii");
}

async function hasValidMeteredFileSignature(file, objectName) {
  const extension = objectName.split(".").pop()?.toLowerCase();
  if (!extension) return false;
  const prefix = await objectPrefix(file);
  if (extension === "jpg") {
    return prefix.length >= 3 && prefix[0] === 0xff && prefix[1] === 0xd8 && prefix[2] === 0xff;
  }
  if (extension === "wav") {
    return prefix.length >= 12 &&
      ["RIFF", "RF64"].includes(ascii(prefix, 0, 4)) &&
      ascii(prefix, 8, 12) === "WAVE";
  }
  if (extension === "aiff" || extension === "aif") {
    return prefix.length >= 12 &&
      ascii(prefix, 0, 4) === "FORM" &&
      ["AIFF", "AIFC"].includes(ascii(prefix, 8, 12));
  }
  if (extension === "flac") return ascii(prefix, 0, 4) === "fLaC";
  if (extension === "m4a") return prefix.length >= 8 && ascii(prefix, 4, 8) === "ftyp";
  if (extension === "mp3") {
    return ascii(prefix, 0, 3) === "ID3" ||
      (prefix.length >= 2 && prefix[0] === 0xff && (prefix[1] & 0xe0) === 0xe0);
  }
  if (extension === "aac") {
    return prefix.length >= 2 && prefix[0] === 0xff && (prefix[1] & 0xf0) === 0xf0;
  }
  return false;
}

async function syncStorageObjectRecords(userId, files) {
  const db = getFirestore();
  const desired = new Map(files.map((file) => [
    storageObjectReference(userId, file.name).id,
    {
      path: file.name,
      size: Number(file.metadata?.size ?? 0),
      generation: String(file.metadata?.generation ?? ""),
    },
  ]));
  const existing = await db
    .collection(`users/${userId}/storageObjects`)
    .limit(STORAGE_INVENTORY_LIMIT)
    .get();
  const existingById = new Map(existing.docs.map((snapshot) => [snapshot.id, snapshot]));
  const writes = [
    ...[...desired.entries()]
      .filter(([id, data]) => {
        const snapshot = existingById.get(id);
        return !snapshot ||
          snapshot.get("path") !== data.path ||
          Number(snapshot.get("size") ?? 0) !== data.size ||
          String(snapshot.get("generation") ?? "") !== data.generation;
      })
      .map(([id, data]) => ({ id, data })),
    ...existing.docs
      .filter((snapshot) => !desired.has(snapshot.id))
      .map((snapshot) => ({ id: snapshot.id, data: null })),
  ];
  for (let offset = 0; offset < writes.length; offset += 450) {
    const batch = db.batch();
    for (const write of writes.slice(offset, offset + 450)) {
      const reference = db.doc(`users/${userId}/storageObjects/${write.id}`);
      if (write.data) batch.set(reference, write.data);
      else batch.delete(reference);
    }
    await batch.commit();
  }
}

/** Establishes the per-object baseline once for users created by older builds. */
async function ensureStorageAccounting(bucket, userId, tier, limitBytes) {
  const db = getFirestore();
  const stateReference = db.doc(`users/${userId}/storage/state`);
  const leaseToken = randomUUID();

  // Only one event may establish the legacy-object baseline. Contenders fail
  // quickly and let Eventarc's exponential backoff retry them; waiting inside
  // a billed function instance amplified the cost of a burst of first uploads.
  const outcome = await db.runTransaction(async (transaction) => {
    const state = await transaction.get(stateReference);
    if (state.get("accountingVersion") === STORAGE_ACCOUNTING_VERSION) {
      return "ready";
    }
    const now = Timestamp.now();
    const leaseExpiresAt = state.get("initializationLeaseExpiresAt");
    const leaseActive =
      leaseExpiresAt instanceof Timestamp && leaseExpiresAt.toMillis() > now.toMillis();
    if (leaseActive) return "waiting";

    transaction.set(stateReference, {
      initializationLeaseToken: leaseToken,
      initializationLeaseExpiresAt: Timestamp.fromMillis(
        now.toMillis() + STORAGE_ACCOUNTING_LEASE_MS
      ),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return "acquired";
  });

  if (outcome === "ready") return;
  if (outcome === "waiting") {
    throw new StorageAccountingBusyError(
      `Storage accounting initialization is already running for ${userId}.`
    );
  }

  try {
    const inventory = await meteredInventory(bucket, userId);
    await syncStorageObjectRecords(userId, inventory.files);
    await db.runTransaction(async (transaction) => {
      const state = await transaction.get(stateReference);
      if (state.get("initializationLeaseToken") !== leaseToken) {
        throw new Error(`Storage accounting lease was lost for ${userId}.`);
      }
      transaction.set(stateReference, {
        tier,
        usedBytes: inventory.usedBytes,
        objectCount: inventory.objectCount,
        objectLimit: MAX_METERED_OBJECTS,
        limitBytes,
        overLimit:
          inventory.truncated ||
          inventory.objectCount > MAX_METERED_OBJECTS ||
          (limitBytes !== null && inventory.usedBytes > limitBytes),
        inventoryTruncated: inventory.truncated,
        accountingVersion: STORAGE_ACCOUNTING_VERSION,
        reconciliationNeeded: true,
        reconciliationVersion: 0,
        initializationLeaseToken: FieldValue.delete(),
        initializationLeaseExpiresAt: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    });
  } catch (error) {
    await db.runTransaction(async (transaction) => {
      const state = await transaction.get(stateReference);
      if (state.get("initializationLeaseToken") !== leaseToken) return;
      transaction.set(stateReference, {
        initializationLeaseToken: FieldValue.delete(),
        initializationLeaseExpiresAt: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }).catch((cleanupError) => {
      logger.error(`Could not release storage accounting lease for ${userId}:`, cleanupError);
    });
    throw error;
  }
}

function generationIsNewer(candidate, reference) {
  try {
    return BigInt(candidate) > BigInt(reference);
  } catch {
    return false;
  }
}

/** Writes the per-user storage state doc the client listens to for usage + rejections. */
async function writeStorageState(userId, fields) {
  await getFirestore()
    .doc(`users/${userId}/storage/state`)
    .set({ ...fields, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
}

/**
 * Enforces the cumulative storage quota whenever a metered object is finalized.
 * Deletes the upload that tips the user over their limit and records a rejection.
 */
export const enforceStorageLimit = onObjectFinalized(
  { memory: "256MiB", timeoutSeconds: 120, retry: true, maxInstances: 20 },
  async (event) => {
    const objectName = event.data.name ?? "";
    const userId = meteredUserId(objectName);
    if (!userId) return;
    const generation = String(event.data.generation ?? "");
    if (!generation) throw new Error(`Missing generation for ${objectName}.`);

    const bucket = getStorage().bucket(event.data.bucket);
    // Pin every read and delete to the generation that emitted this event. A
    // delayed event must never inspect or delete a newer overwrite at the same
    // path.
    const uploadedFile = bucket.file(objectName, { generation });
    let validSignature = false;
    try {
      validSignature = await hasValidMeteredFileSignature(uploadedFile, objectName);
    } catch (error) {
      if (error?.code === 404) return;
      logger.error(`Could not validate uploaded object ${objectName}:`, error);
      throw error;
    }
    if (!validSignature) {
      await uploadedFile.delete().catch((error) => {
        if (error?.code === 404) return;
        logger.error(`Could not delete invalid upload ${objectName}:`, error);
        throw error;
      });
      logger.warn(`Rejected upload with invalid file signature: ${objectName}.`);
      return;
    }
    const { tier, limitBytes } = await effectiveStorageLimit(userId);
    try {
      await ensureStorageAccounting(bucket, userId, tier, limitBytes);
    } catch (error) {
      if (error instanceof StorageAccountingBusyError) throw error;
      // Fail closed: an upload must never remain available when its quota
      // baseline could not be established safely.
      await uploadedFile.delete().catch((deleteError) => {
        if (deleteError?.code === 404) return;
        logger.error(`Could not delete unaccounted upload ${objectName}:`, deleteError);
        throw deleteError;
      });
      logger.error(`Rejected upload because storage accounting failed for ${userId}:`, error);
      await writeStorageState(userId, {
        overLimit: true,
        lastBlockedAt: FieldValue.serverTimestamp(),
        lastBlockedBytes: Number(event.data.size ?? 0),
      });
      return;
    }

    const objectSize = Number(event.data.size ?? 0);
    const stateReference = getFirestore().doc(`users/${userId}/storage/state`);
    const objectReference = storageObjectReference(userId, objectName);
    const result = await getFirestore().runTransaction(async (transaction) => {
      const [state, object] = await Promise.all([
        transaction.get(stateReference),
        transaction.get(objectReference),
      ]);
      const recordedGeneration = String(object.get("generation") ?? "");
      if (
        object.exists &&
        recordedGeneration !== generation &&
        generationIsNewer(recordedGeneration, generation)
      ) {
        return { accepted: true, duplicate: true, stale: true };
      }
      if (object.exists && recordedGeneration === generation) {
        // Initialization inventories objects before their finalize events are
        // processed. Presence in that baseline is not approval: if the
        // baseline is over quota, reject this exact generation and reduce the
        // cached total. This closes the first-upload quota bypass.
        if (state.get("overLimit") !== true) {
          return { accepted: true, duplicate: true };
        }
        const recordedSize = Number(object.get("size") ?? objectSize);
        const usedBytes = Math.max(0, Number(state.get("usedBytes") ?? 0) - recordedSize);
        const objectCount = Math.max(0, Number(state.get("objectCount") ?? 0) - 1);
        const inventoryTruncated = state.get("inventoryTruncated") === true;
        transaction.delete(objectReference);
        transaction.set(stateReference, {
          tier,
          usedBytes,
          objectCount,
          objectLimit: MAX_METERED_OBJECTS,
          limitBytes,
          overLimit:
            inventoryTruncated ||
            objectCount > MAX_METERED_OBJECTS ||
            (limitBytes !== null && usedBytes > limitBytes),
          lastBlockedAt: FieldValue.serverTimestamp(),
          lastBlockedBytes: recordedSize,
          reconciliationNeeded: true,
          reconciliationVersion: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        return {
          accepted: false,
          nextUsedBytes: Number(state.get("usedBytes") ?? 0),
          nextCount: Number(state.get("objectCount") ?? 0),
        };
      }

      const previousSize = object.exists ? Number(object.get("size") ?? 0) : 0;
      const previousCount = Number(state.get("objectCount") ?? 0);
      const nextCount = previousCount + (object.exists ? 0 : 1);
      const currentUsedBytes = Number(state.get("usedBytes") ?? 0);
      const nextUsedBytes = Math.max(0, currentUsedBytes - previousSize + objectSize);
      const accepted =
        state.get("inventoryTruncated") !== true &&
        nextCount <= MAX_METERED_OBJECTS &&
        (limitBytes === null || nextUsedBytes <= limitBytes);

      if (!accepted) {
        // An overwrite has already replaced the old generation. Once the new
        // generation is deleted there is no object at this path, so remove the
        // old accounting entry now rather than leaving phantom usage behind.
        if (object.exists) transaction.delete(objectReference);
        transaction.set(stateReference, {
          tier,
          usedBytes: Math.max(0, currentUsedBytes - previousSize),
          objectCount: Math.max(0, previousCount - (object.exists ? 1 : 0)),
          objectLimit: MAX_METERED_OBJECTS,
          limitBytes,
          overLimit: true,
          inventoryTruncated: state.get("inventoryTruncated") === true,
          accountingVersion: STORAGE_ACCOUNTING_VERSION,
          lastBlockedAt: FieldValue.serverTimestamp(),
          lastBlockedBytes: objectSize,
          reconciliationNeeded: true,
          reconciliationVersion: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        return { accepted: false, nextUsedBytes, nextCount };
      }

      transaction.set(objectReference, {
        path: objectName,
        size: objectSize,
        generation,
      });
      transaction.set(stateReference, {
        tier,
        usedBytes: nextUsedBytes,
        objectCount: nextCount,
        objectLimit: MAX_METERED_OBJECTS,
        limitBytes,
        overLimit: false,
        inventoryTruncated: false,
        accountingVersion: STORAGE_ACCOUNTING_VERSION,
        reconciliationNeeded: true,
        reconciliationVersion: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return { accepted: true, duplicate: false, nextUsedBytes, nextCount };
    });

    if (!result.accepted) {
      try {
        await uploadedFile.delete();
        logger.info(
          `Rejected over-quota upload for ${userId}: ${objectName} ` +
            `(would use ${result.nextUsedBytes} bytes / ${result.nextCount} objects).`
        );
      } catch (error) {
        if (error?.code === 404 || error?.code === 412) return;
        logger.error(`Failed to delete over-quota object ${objectName}:`, error);
        throw error;
      }

      const audioMatch = AUDIO_PREFIX_RE.exec(objectName);
      const blockedId = audioMatch
        ? (audioMatch[2] ?? audioMatch[3].replace(/\.[^.]+$/, ""))
        : null;
      if (blockedId) {
        await writeStorageState(userId, { lastBlockedTrackId: blockedId });
      }
      return;
    }
  }
);

/** Keeps the usage figure accurate after an object is deleted from Storage. */
export const refreshStorageUsage = onObjectDeleted(
  { memory: "256MiB", maxInstances: 20 },
  async (event) => {
    const userId = meteredUserId(event.data.name ?? "");
    if (!userId) return;
    const objectName = event.data.name ?? "";
    const generation = String(event.data.generation ?? "");
    const size = Number(event.data.size ?? 0);
    const objectReference = storageObjectReference(userId, objectName);
    const stateReference = getFirestore().doc(`users/${userId}/storage/state`);
    await getFirestore().runTransaction(async (transaction) => {
      const [state, object] = await Promise.all([
        transaction.get(stateReference),
        transaction.get(objectReference),
      ]);
      if (object.exists && object.get("generation") !== generation) return;

      const recordedSize = object.exists
        ? Number(object.get("size") ?? 0)
        : state.get("accountingVersion") === STORAGE_ACCOUNTING_VERSION
          ? 0
          : (Number.isFinite(size) ? size : 0);
      if (object.exists) transaction.delete(objectReference);
      if (!state.exists) return;
      const usedBytes = Math.max(0, Number(state.get("usedBytes") ?? 0) - recordedSize);
      const objectCount = Math.max(
        0,
        Number(state.get("objectCount") ?? 0) - (object.exists ? 1 : 0)
      );
      const limitBytes = state.get("limitBytes");
      transaction.set(stateReference, {
        usedBytes,
        objectCount,
        overLimit:
          state.get("inventoryTruncated") === true ||
          objectCount > MAX_METERED_OBJECTS ||
          (typeof limitBytes === "number" && usedBytes > limitBytes),
        reconciliationNeeded: true,
        reconciliationVersion: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    });
  }
);

/**
 * Heals any drift between the cached usage counter and the bucket.
 *
 * Delete deltas, overwrites and failed triggers can all leave the cached total
 * slightly off. Hot-path mutations mark the user dirty; reconciliation clears
 * that marker without touching `updatedAt`, so its own writes cannot keep a
 * user in an hourly inventory loop.
 */
export const reconcileStorageUsage = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
    memory: "512MiB",
    timeoutSeconds: 540,
    maxInstances: 1,
  },
  async () => {
    const db = getFirestore();
    const states = await db
      .collectionGroup("storage")
      .where("reconciliationNeeded", "==", true)
      .limit(200)
      .get();

    const bucket = getStorage().bucket();
    let reconciled = 0;
    for (const state of states.docs) {
      const userId = state.ref.parent.parent?.id;
      if (!userId || state.id !== "state") continue;
      const leaseExpiresAt = state.get("initializationLeaseExpiresAt");
      if (leaseExpiresAt instanceof Timestamp && leaseExpiresAt.toMillis() > Date.now()) {
        continue;
      }
      const reconciliationVersion = Number(state.get("reconciliationVersion") ?? 0);
      const { tier, limitBytes } = await effectiveStorageLimit(userId);
      const inventory = await meteredInventory(bucket, userId);
      await syncStorageObjectRecords(userId, inventory.files);
      const committed = await db.runTransaction(async (transaction) => {
        const latest = await transaction.get(state.ref);
        if (
          latest.get("reconciliationNeeded") !== true ||
          Number(latest.get("reconciliationVersion") ?? 0) !== reconciliationVersion
        ) {
          return false;
        }
        transaction.set(state.ref, {
          tier,
          usedBytes: inventory.usedBytes,
          objectCount: inventory.objectCount,
          objectLimit: MAX_METERED_OBJECTS,
          limitBytes,
          overLimit:
            inventory.truncated ||
            inventory.objectCount > MAX_METERED_OBJECTS ||
            (limitBytes !== null && inventory.usedBytes > limitBytes),
          inventoryTruncated: inventory.truncated,
          accountingVersion: STORAGE_ACCOUNTING_VERSION,
          reconciliationNeeded: false,
          lastReconciledAt: FieldValue.serverTimestamp(),
          initializationLeaseToken: FieldValue.delete(),
          initializationLeaseExpiresAt: FieldValue.delete(),
        }, { merge: true });
        return true;
      });
      if (committed) reconciled += 1;
    }
    if (reconciled > 0) logger.info(`Reconciled storage usage for ${reconciled} user(s).`);
  }
);

/**
 * Enforces "one cover per project" in Storage.
 *
 * Cover names are `{projectId}-{version}.jpg` so the object can be cached
 * immutably, which means replacing artwork writes a new object rather than
 * overwriting one. Clients delete the old file on a best-effort basis; this
 * makes it guaranteed, so a client that crashes — or simply skips the delete —
 * cannot leave paid-for bytes behind.
 */
export const sweepReplacedCovers = onObjectFinalized(
  { memory: "256MiB", maxInstances: 10 },
  async (event) => {
    const objectName = event.data.name ?? "";
    const match = /^users\/([^/]+)\/covers\/([0-9A-Fa-f-]{36})-[^/]+$/.exec(objectName);
    if (!match) return;

    const [, userId, projectId] = match;
    const bucket = getStorage().bucket(event.data.bucket);
    const [files] = await bucket.getFiles({
      prefix: `users/${userId}/covers/${projectId}-`,
      maxResults: 200,
    });
    // Finalize events may arrive out of order. Keep the newest Storage
    // generation, not whichever event happened to run last, so an old event
    // can never delete a newer cover.
    const newest = files.reduce((candidate, file) => {
      if (!candidate) return file;
      return generationIsNewer(
        String(file.metadata?.generation ?? "0"),
        String(candidate.metadata?.generation ?? "0")
      ) ? file : candidate;
    }, null);
    const stale = files.filter((file) => file.name !== newest?.name);
    if (stale.length === 0) return;

    await Promise.all(
      stale.map((file) =>
        file.delete().catch((error) => {
          if (error?.code !== 404) {
            logger.warn(`Could not delete superseded cover ${file.name}:`, error);
          }
        })
      )
    );
    logger.info(`Removed ${stale.length} superseded cover(s) for project ${projectId}.`);
  }
);

// ── Invite user search ───────────────────────────────────────────────────────
//
// The `usernames` collection is the uniqueness index, keyed by the lowercased
// name. Clients used to run the prefix query themselves, which required `list`
// permission — and `list` over that collection is a full directory dump of
// every uid in the system. That turned share-link UUIDs and project ids into
// enumerable values, so search now runs here and clients only get `get`.

const USERNAME_SEARCH_LIMIT = 10;
const MIN_SEARCH_PREFIX = 2;

function canonicalAvatarURL(rawValue, uid) {
  if (typeof rawValue !== "string") return null;
  try {
    const url = new URL(rawValue);
    const path = decodeURIComponent(url.pathname);
    return url.protocol === "https:" &&
      url.hostname === "firebasestorage.googleapis.com" &&
      path.endsWith(`/o/users/${uid}/profile/avatar.jpg`)
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

export const searchUsers = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    maxInstances: 20,
    enforceAppCheck: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in to search for people.");
    }
    // Guest sessions exist only to listen to a shared link; they never invite.
    if (request.auth.token?.firebase?.sign_in_provider === "anonymous") {
      throw new HttpsError("permission-denied", "Guest sessions cannot search for people.");
    }

    const prefix = String(request.data?.prefix ?? "").toLowerCase().trim();
    // A short prefix returns a large slice of the directory, which is the
    // enumeration this function exists to prevent.
    if (prefix.length < MIN_SEARCH_PREFIX || !/^[a-z0-9_]+$/.test(prefix)) return { results: [] };

    const db = getFirestore();
    const snapshot = await db
      .collection("usernames")
      .orderBy(FieldPath.documentId())
      .startAt(prefix)
      .endAt(`${prefix}\uf8ff`)
      .limit(USERNAME_SEARCH_LIMIT + 1)
      .get();

    const matches = snapshot.docs
      .flatMap((entry) => {
        const uid = entry.get("uid");
        if (typeof uid !== "string" || uid === request.auth.uid) return [];
        return [{ id: uid, username: entry.id }];
      })
      .slice(0, USERNAME_SEARCH_LIMIT);

    const results = await Promise.all(
      matches.map(async (match) => {
        const profile = await db.doc(`userProfiles/${match.id}`).get();
        const avatarURL = canonicalAvatarURL(profile.get("avatarURL"), match.id);
        return {
          ...match,
          avatarURL,
        };
      })
    );
    return { results };
  }
);

/**
 * Frees a user's previous username when they pick a new one.
 *
 * `usernames` entries can only be created (never updated or deleted) by
 * clients, so without this the index would accumulate one dead reservation per
 * rename and no name could ever be reused.
 */
export const releaseReplacedUsername = onDocumentWritten(
  "userProfiles/{userId}",
  async (event) => {
    const previous = event.data?.before.get("username");
    const current = event.data?.after.get("username");
    if (typeof previous !== "string" || !previous) return;
    if (typeof current === "string" && current.toLowerCase() === previous.toLowerCase()) return;

    const reference = getFirestore().doc(`usernames/${previous.toLowerCase()}`);
    await getFirestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      // Only release a reservation this user still holds — never one that has
      // already been claimed by somebody else.
      if (snapshot.exists && snapshot.get("uid") === event.params.userId) {
        transaction.delete(reference);
      }
    });
    logger.info(`Released username @${previous} for ${event.params.userId}.`);
  }
);

// ── Public project web listening ────────────────────────────────────────────
//
// Public links must not expose the owner's full Firestore project document.
// This endpoint verifies App Check, checks the share flag, selects only public
// versions, and returns short-lived signed media URLs.

const FIREBASE_UID_RE = /^[A-Za-z0-9:_-]{1,128}$/;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function publicTimestamp(value) {
  if (value && typeof value.toDate === "function") {
    return value.toDate().toISOString();
  }
  return new Date(0).toISOString();
}

function publicStoragePath(path, ownerId, category) {
  return (
    typeof path === "string" &&
    path.startsWith(`users/${ownerId}/${category}/`) &&
    !path.includes("..")
  );
}

const PUBLIC_LINK_RATE_WINDOW_MS = 60_000;
const PUBLIC_LINK_REQUESTS_PER_WINDOW = 30;
const PUBLIC_MEDIA_URL_LIFETIME_MS = 10 * 60_000;

async function hasValidAppCheck(request) {
  const token = request.get("X-Firebase-AppCheck");
  if (!token) return false;
  try {
    await getAppCheck().verifyToken(token);
    return true;
  } catch (error) {
    logger.warn("Rejected invalid App Check token on public project request:", error);
    return false;
  }
}

async function publicLinkRateLimitAllows(request, ownerId, projectId) {
  const clientAddress = request.ip || request.socket?.remoteAddress || "unknown";
  const key = createHash("sha256")
    .update(`${clientAddress}\n${ownerId}\n${projectId}`)
    .digest("hex");
  const reference = getFirestore().doc(`_rateLimits/publicProject-${key}`);
  const now = Date.now();
  return getFirestore().runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    const previousStart = Number(snapshot.get("windowStartMs") ?? 0);
    const sameWindow = now - previousStart < PUBLIC_LINK_RATE_WINDOW_MS;
    const count = sameWindow ? Number(snapshot.get("count") ?? 0) : 0;
    if (count >= PUBLIC_LINK_REQUESTS_PER_WINDOW) return false;
    transaction.set(reference, {
      windowStartMs: sameWindow ? previousStart : now,
      count: count + 1,
      // Configure this field as a Firestore TTL policy so abandoned IP/link
      // buckets are removed automatically.
      expiresAt: Timestamp.fromMillis(now + 24 * 60 * 60 * 1000),
    });
    return true;
  });
}

async function signedPublicMediaURL(bucket, storagePath, kind) {
  const extension = storagePath.split(".").pop()?.toLowerCase();
  const audioType = {
    mp3: "audio/mpeg",
    m4a: "audio/mp4",
    wav: "audio/wav",
    aiff: "audio/aiff",
    aif: "audio/aiff",
    flac: "audio/flac",
    aac: "audio/aac",
  }[extension] ?? "application/octet-stream";
  const [url] = await bucket.file(storagePath).getSignedUrl({
    version: "v4",
    action: "read",
    expires: Date.now() + PUBLIC_MEDIA_URL_LIFETIME_MS,
    responseDisposition: "inline",
    responseType: kind === "cover" ? "image/jpeg" : audioType,
  });
  return url;
}

function selectedPublicAudio(track) {
  let audio = track;
  const versions = Array.isArray(track?.versions) ? track.versions : [];
  if (versions.length > 0) {
    const publicVersions = versions.filter((version) => version?.isPublic !== false);
    audio =
      publicVersions.find((version) => version.id === track.activeVersionID) ??
      publicVersions[0];
  }
  return audio;
}

async function selectedPublicAudioPath(bucket, originalPath, requestedQuality) {
  if (requestedQuality !== "standard" && requestedQuality !== "high") {
    return originalPath;
  }
  const renditionPath = renditionStoragePath(originalPath, requestedQuality);
  if (!renditionPath) return originalPath;
  try {
    const [exists] = await bucket.file(renditionPath).exists();
    return exists ? renditionPath : originalPath;
  } catch (error) {
    logger.warn(`Could not resolve ${requestedQuality} rendition for ${originalPath}:`, error);
    return originalPath;
  }
}

function sanitizePublicTrack(track, ownerId, audioUrl) {
  if (!track || typeof track.id !== "string" || typeof track.title !== "string") {
    return null;
  }

  const audio = selectedPublicAudio(track);
  if (!audio) return null;
  if (!publicStoragePath(audio.storagePath, ownerId, "audio")) return null;

  return {
    id: track.id,
    title: track.title,
    fileName: String(audio.fileName ?? track.fileName ?? "audio"),
    fileSize: Number(audio.fileSize ?? track.fileSize ?? 0),
    duration: Number(audio.duration ?? track.duration ?? 0),
    addedDate: publicTimestamp(track.addedDate),
    waveform:
      typeof audio.waveform === "string"
        ? audio.waveform
        : typeof track.waveform === "string"
          ? track.waveform
          : undefined,
    audioUrl,
  };
}

export const getPublicProject = onRequest(
  // `maxInstances` is a billing circuit breaker. Media bytes bypass this
  // function through short-lived Storage signatures; only sanitized metadata
  // is generated here, guarded by App Check and a persistent token bucket.
  { region: "us-central1", cors: true, memory: "256MiB", maxInstances: 10 },
  async (request, response) => {
    response.set("Cache-Control", "private, no-store, max-age=0");

    if (request.method !== "GET") {
      response.status(405).json({ error: "method-not-allowed" });
      return;
    }

    if (!(await hasValidAppCheck(request))) {
      response.status(401).json({ error: "app-check-required" });
      return;
    }

    const ownerId = String(request.query.ownerId ?? "");
    const requestedProjectId = String(request.query.projectId ?? "");
    if (!FIREBASE_UID_RE.test(ownerId) || !UUID_RE.test(requestedProjectId)) {
      response.status(400).json({ error: "invalid-link" });
      return;
    }

    if (!(await publicLinkRateLimitAllows(request, ownerId, requestedProjectId))) {
      response.set("Retry-After", "60").status(429).json({ error: "rate-limited" });
      return;
    }

    // Swift stores UUID document IDs using uuidString (uppercase), while the
    // public URL intentionally uses lowercase for readability.
    const projectId = requestedProjectId.toUpperCase();
    const firestore = getFirestore();
    const previewReference = firestore.doc(
      `users/${ownerId}/projectPreviews/${projectId}`
    );
    const projectReference = firestore.doc(
      `users/${ownerId}/projects/${projectId}`
    );

    const [previewSnapshot, projectSnapshot] = await Promise.all([
      previewReference.get(),
      projectReference.get(),
    ]);
    const preview = previewSnapshot.data();
    const project = projectSnapshot.data();

    // Return the same response for missing and disabled links so the endpoint
    // does not reveal whether a private project exists. The flag must be
    // exactly `true`: testing for `=== false` treated a preview that is missing
    // the field as shared, which is the opposite of what the Firestore rules do.
    if (
      !previewSnapshot.exists ||
      preview?.linkEnabled !== true ||
      !projectSnapshot.exists ||
      !project
    ) {
      response.status(404).json({ error: "share-unavailable" });
      return;
    }

    const projectTracks = Array.isArray(project.tracks) ? project.tracks : [];
    const bucket = getStorage().bucket();
    const tracks = (await Promise.all(projectTracks.map(async (track) => {
      const audio = selectedPublicAudio(track);
      if (!audio || !publicStoragePath(audio.storagePath, ownerId, "audio")) return null;
      const storagePath = await selectedPublicAudioPath(
        bucket,
        audio.storagePath,
        "standard"
      );
      const audioUrl = await signedPublicMediaURL(bucket, storagePath, "track");
      return sanitizePublicTrack(track, ownerId, audioUrl);
    }))).filter(Boolean);

    let coverUrl;
    if (publicStoragePath(project.coverStoragePath, ownerId, "covers")) {
      coverUrl = await signedPublicMediaURL(bucket, project.coverStoragePath, "cover");
    }

    response.status(200).json({
      id: String(project.id ?? projectId),
      name: String(project.name ?? preview.name ?? "Untitled project"),
      ownerUsername: String(
        project.ownerUsername ?? preview.ownerUsername ?? "unknown"
      ),
      gradient: project.gradient ?? preview.gradient ?? {
        colors: ["#667EEA", "#764BA2"],
        startX: 0,
        startY: 0,
        endX: 1,
        endY: 1,
      },
      accentColorHex:
        typeof project.accentColorHex === "string"
          ? project.accentColorHex
          : preview.accentColorHex,
      coverGradientColors: Array.isArray(project.coverGradientColors)
        ? project.coverGradientColors
        : undefined,
      coverUrl,
      createdDate: publicTimestamp(project.createdDate),
      updatedDate: publicTimestamp(project.updatedDate),
      tracks,
    });
  }
);
