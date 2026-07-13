import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onObjectFinalized, onObjectDeleted } from "firebase-functions/v2/storage";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";

initializeApp();

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
// `users/{uid}/audio/{trackId}.{ext}`. Storage security rules can only validate
// ownership and per-object size — they cannot enforce a *cumulative* quota.
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
  premium: 20_000_000_000, // 20 GB
  unlimited: null,
};

const AUDIO_PREFIX_RE = /^users\/([^/]+)\/audio\/([^/]+)$/;

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
    const fileName = match[2];
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
      const trackId = fileName.replace(/\.[^.]+$/, "");
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
