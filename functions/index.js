import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
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
