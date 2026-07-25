import {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentWritten,
} from "firebase-functions/v2/firestore";
import { onObjectFinalized, onObjectDeleted } from "firebase-functions/v2/storage";
import { onRequest } from "firebase-functions/v2/https";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";

initializeApp();

const PROJECT_INVITE_TYPE = "projectInvite";

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
  await db.runTransaction(async (transaction) => {
    const notificationSnap = await transaction.get(notificationRef);
    if (!notificationSnap.exists) return;

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
      return;
    }

    const inviteeRef = db.doc(
      `users/${ownerId}/projects/${projectId}/invitees/${recipientId}`
    );
    const projectRef = db.doc(`users/${ownerId}/projects/${projectId}`);
    const pendingRef = db.doc(
      `users/${ownerId}/projects/${projectId}/pendingInvites/${recipientId}`
    );
    const profileRef = db.doc(`userProfiles/${recipientId}`);
    const [projectSnap, inviteeSnap, profileSnap] = await Promise.all([
      transaction.get(projectRef),
      transaction.get(inviteeRef),
      transaction.get(profileRef),
    ]);

    if (!projectSnap.exists) {
      transaction.delete(notificationRef);
      transaction.delete(pendingRef);
      return;
    }

    // Accepted users are listeners, not pending invitees. Remove any stale
    // invite notification instead of recreating pending state for them.
    if (inviteeSnap.exists) {
      transaction.delete(notificationRef);
      transaction.delete(pendingRef);
      return;
    }

    const profileUsername = profileSnap.get("username");
    const username =
      typeof data.recipientUsername === "string" && data.recipientUsername
        ? data.recipientUsername
        : typeof profileUsername === "string" && profileUsername
          ? profileUsername
          : "listener";

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
    const tokenSnap = await getFirestore()
      .doc(`users/${userId}/private/push`)
      .get();
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
      logger.error(`Failed to send push to ${userId}:`, error);
    }
  }
);

/**
 * Opening either share sheet refreshes its preview. Use that write to repair
 * legacy orphan notifications created by older clients before invite creation
 * became atomic.
 */
export const reconcileProjectInvites = onDocumentWritten(
  "users/{ownerId}/projectPreviews/{projectId}",
  async (event) => {
    if (!event.data?.after.exists) return;

    const { ownerId, projectId } = event.params;
    const notifications = await getFirestore()
      .collectionGroup("notifications")
      .where("type", "==", PROJECT_INVITE_TYPE)
      .where("fromUID", "==", ownerId)
      .where("projectID", "==", projectId)
      .get();
    const invitees = await getFirestore()
      .collection(`users/${ownerId}/projects/${projectId}/invitees`)
      .get();

    await Promise.all([
      ...notifications.docs.map((notification) => {
        const recipientId = notification.ref.parent.parent?.id;
        if (!recipientId) return Promise.resolve();
        return ensurePendingInviteForNotification(notification.ref, recipientId);
      }),
      ...invitees.docs.map((invitee) =>
        ensureAcceptedSharedProjectReference(
          ownerId,
          projectId,
          invitee.id,
          invitee.get("acceptedAt")
        )
      ),
    ]);
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
    const notifications = await getFirestore()
      .collection(`users/${inviteeId}/notifications`)
      .get();
    const matching = notifications.docs.filter((notification) => {
      const data = notification.data();
      return (
        data.type === PROJECT_INVITE_TYPE &&
        data.fromUID === ownerId &&
        data.projectID === projectId
      );
    });
    await Promise.all(matching.map((notification) => notification.ref.delete()));
  }
);

/**
 * Removing a listener also removes the shared-project reference on every
 * device. If link sharing remains enabled, the user can still rejoin via link.
 */
export const removeRevokedSharedProjectReference = onDocumentDeleted(
  "users/{ownerId}/projects/{projectId}/invitees/{inviteeId}",
  async (event) => {
    const { projectId, inviteeId } = event.params;
    const db = getFirestore();
    const notifications = await db
      .collection(`users/${inviteeId}/notifications`)
      .get();
    const batch = db.batch();
    batch.set(
      db.doc(`users/${inviteeId}/private/sharedProjects`),
      { refs: { [projectId]: FieldValue.delete() } },
      { merge: true }
    );
    batch.delete(
      db.doc(
        `users/${event.params.ownerId}/projects/${projectId}/pendingInvites/${inviteeId}`
      )
    );
    await batch.commit();
    await Promise.all(
      notifications.docs
        .filter((notification) => {
          const data = notification.data();
          return (
            data.type === PROJECT_INVITE_TYPE &&
            data.fromUID === event.params.ownerId &&
            data.projectID === projectId
          );
        })
        .map((notification) => notification.ref.delete())
    );
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
// The iOS client uploads audio directly to Cloud Storage at
// `users/{uid}/audio/{trackId}.{ext}` for legacy tracks and
// `users/{uid}/audio/versions/{versionId}/audio.{ext}` for track versions.
// Storage security rules can only validate ownership and per-object size —
// they cannot enforce a *cumulative* quota.
//
// These triggers are the authoritative, tamper-proof enforcement: if an upload
// pushes a user past their plan's storage limit, the offending object is deleted
// immediately and a rejection is recorded so the client can surface an upsell.
// A modified app cannot bypass this because enforcement runs server-side after
// the bytes land, regardless of what the client believes.

// Plan storage limits in bytes. MUST stay in sync with `PlanTier` in
// `unreleased/Models/UserPlan.swift`. `null` means unlimited (no cap).
const PLAN_STORAGE_LIMITS = {
  free: 1_000_000_000, // 1 GB
  premium: 30_000_000_000, // 30 GB
  unlimited: null,
};

const AUDIO_PREFIX_RE =
  /^users\/([^/]+)\/audio\/(?:versions\/([^/]+)\/)?([^/]+)$/;

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

/** Sums the size (bytes) of every object under `users/{uid}/audio/`. */
async function totalAudioBytes(bucket, userId) {
  const [files] = await bucket.getFiles({ prefix: `users/${userId}/audio/` });
  return files.reduce((sum, file) => {
    const size = Number(file.metadata?.size ?? 0);
    return sum + (Number.isFinite(size) ? size : 0);
  }, 0);
}

/** Writes the per-user storage state doc the client listens to for usage + rejections. */
async function writeStorageState(userId, fields) {
  await getFirestore()
    .doc(`users/${userId}/storage/state`)
    .set({ ...fields, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
}

/**
 * Enforces the cumulative storage quota whenever an audio object is finalized.
 * Deletes the upload that tips the user over their limit and records a rejection.
 */
export const enforceAudioStorageLimit = onObjectFinalized(
  { memory: "256MiB" },
  async (event) => {
    const objectName = event.data.name ?? "";
    const match = AUDIO_PREFIX_RE.exec(objectName);
    if (!match) return; // Only audio objects count toward the limit.

    const userId = match[1];
    const versionId = match[2];
    const fileName = match[3];
    const bucket = getStorage().bucket(event.data.bucket);

    const { tier, limitBytes } = await effectiveStorageLimit(userId);

    // Unlimited plan: nothing to enforce, but keep usage fresh for the UI.
    if (limitBytes === null) {
      const usedBytes = await totalAudioBytes(bucket, userId);
      await writeStorageState(userId, {
        tier,
        usedBytes,
        limitBytes: null,
        overLimit: false,
      });
      return;
    }

    const usedBytes = await totalAudioBytes(bucket, userId);

    if (usedBytes > limitBytes) {
      // This upload pushed the user over their quota — reject it.
      const objectSize = Number(event.data.size ?? 0);
      try {
        await bucket.file(objectName).delete();
        logger.info(
          `Rejected over-quota upload for ${userId}: ${objectName} ` +
            `(used ${usedBytes} > limit ${limitBytes}).`
        );
      } catch (error) {
        logger.error(`Failed to delete over-quota object ${objectName}:`, error);
      }

      // Track id is the object's filename without extension.
      const trackId = versionId ?? fileName.replace(/\.[^.]+$/, "");
      await writeStorageState(userId, {
        tier,
        usedBytes: Math.max(0, usedBytes - objectSize),
        limitBytes,
        overLimit: true,
        lastBlockedAt: FieldValue.serverTimestamp(),
        lastBlockedTrackId: trackId,
        lastBlockedBytes: objectSize,
      });
      return;
    }

    await writeStorageState(userId, {
      tier,
      usedBytes,
      limitBytes,
      overLimit: false,
    });
  }
);

/** Keeps the usage figure accurate after a track is deleted from Storage. */
export const refreshAudioStorageUsage = onObjectDeleted(
  { memory: "256MiB" },
  async (event) => {
    const objectName = event.data.name ?? "";
    const match = AUDIO_PREFIX_RE.exec(objectName);
    if (!match) return;

    const userId = match[1];
    const bucket = getStorage().bucket(event.data.bucket);
    const { tier, limitBytes } = await effectiveStorageLimit(userId);
    const usedBytes = await totalAudioBytes(bucket, userId);

    await writeStorageState(userId, {
      tier,
      usedBytes,
      limitBytes,
      overLimit: limitBytes !== null && usedBytes > limitBytes,
    });
  }
);

// ── Public project web listening ────────────────────────────────────────────
//
// Public links must not expose the owner's full Firestore project document:
// tracks may contain private versions and notes. This endpoint checks the
// owner-controlled preview flag, selects only public audio versions, and
// streams only the exact cover/audio objects required by the browser player.

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

function publicMediaURL(request, ownerId, projectId, media, trackId) {
  const project = process.env.GCLOUD_PROJECT;
  const canonicalEndpoint = project
    ? `https://us-central1-${project}.cloudfunctions.net/getPublicProject`
    : new URL(request.originalUrl, `${request.protocol}://${request.get("host")}`);
  const url = new URL(canonicalEndpoint);
  url.searchParams.set("ownerId", ownerId);
  url.searchParams.set("projectId", projectId.toLowerCase());
  url.searchParams.set("media", media);
  if (trackId) url.searchParams.set("trackId", trackId);
  return url.toString();
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

async function streamPublicFile(request, response, storagePath) {
  const file = getStorage().bucket().file(storagePath);
  let metadata;
  try {
    [metadata] = await file.getMetadata();
  } catch (error) {
    logger.warn(`Public media is unavailable at ${storagePath}:`, error);
    response.status(404).json({ error: "media-unavailable" });
    return;
  }

  const size = Number(metadata.size ?? 0);
  const range = request.get("range");
  let start = 0;
  let end = Math.max(0, size - 1);

  if (range) {
    const match = /^bytes=(\d+)-(\d*)$/.exec(range);
    if (!match) {
      response.status(416).set("Content-Range", `bytes */${size}`).end();
      return;
    }
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : end;
    if (start >= size || end < start) {
      response.status(416).set("Content-Range", `bytes */${size}`).end();
      return;
    }
    end = Math.min(end, size - 1);
    response.status(206);
    response.set("Content-Range", `bytes ${start}-${end}/${size}`);
  }

  response.set({
    "Accept-Ranges": "bytes",
    "Content-Type": metadata.contentType ?? "application/octet-stream",
    "Content-Length": String(Math.max(0, end - start + 1)),
    "Cache-Control": "private, no-store, max-age=0",
  });

  if (request.method === "HEAD") {
    response.end();
    return;
  }

  await new Promise((resolve) => {
    const stream = file.createReadStream({ start, end });
    stream.on("error", (error) => {
      logger.warn(`Could not stream public media at ${storagePath}:`, error);
      if (!response.headersSent) {
        response.status(500).json({ error: "media-unavailable" });
      } else {
        response.destroy(error);
      }
      resolve();
    });
    response.on("finish", resolve);
    response.on("close", resolve);
    stream.pipe(response);
  });
}

export const getPublicProject = onRequest(
  { region: "us-central1", cors: true, memory: "256MiB" },
  async (request, response) => {
    response.set("Cache-Control", "private, no-store, max-age=0");

    if (request.method !== "GET" && request.method !== "HEAD") {
      response.status(405).json({ error: "method-not-allowed" });
      return;
    }

    const ownerId = String(request.query.ownerId ?? "");
    const requestedProjectId = String(request.query.projectId ?? "");
    if (!FIREBASE_UID_RE.test(ownerId) || !UUID_RE.test(requestedProjectId)) {
      response.status(400).json({ error: "invalid-link" });
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
    // does not reveal whether a private project exists.
    if (
      !previewSnapshot.exists ||
      preview?.linkEnabled === false ||
      !projectSnapshot.exists ||
      !project
    ) {
      response.status(404).json({ error: "share-unavailable" });
      return;
    }

    const projectTracks = Array.isArray(project.tracks) ? project.tracks : [];
    const media = String(request.query.media ?? "");
    if (media === "cover") {
      if (!publicStoragePath(project.coverStoragePath, ownerId, "covers")) {
        response.status(404).json({ error: "media-unavailable" });
        return;
      }
      await streamPublicFile(request, response, project.coverStoragePath);
      return;
    }
    if (media === "track") {
      const trackId = String(request.query.trackId ?? "");
      const track = projectTracks.find((item) => item?.id === trackId);
      const audio = selectedPublicAudio(track);
      if (!audio || !publicStoragePath(audio.storagePath, ownerId, "audio")) {
        response.status(404).json({ error: "media-unavailable" });
        return;
      }
      await streamPublicFile(request, response, audio.storagePath);
      return;
    }

    const tracks = projectTracks
      .map((track) =>
        sanitizePublicTrack(
          track,
          ownerId,
          publicMediaURL(request, ownerId, projectId, "track", track?.id)
        )
      )
      .filter(Boolean);

    let coverUrl;
    if (publicStoragePath(project.coverStoragePath, ownerId, "covers")) {
      coverUrl = publicMediaURL(request, ownerId, projectId, "cover");
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
