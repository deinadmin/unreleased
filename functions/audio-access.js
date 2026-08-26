import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";

const BACKFILL_STATE_PATH = "_system/projectStorageAccessIndexBackfillV2";

function projectAudioAccess(data, projectId) {
  const trackAccess = new Map();
  const trackFileAccess = new Map();
  const coverFileAccess = new Map();
  const versionAccess = new Map();
  const tracks = Array.isArray(data?.tracks) ? data.tracks : [];

  const indexFlatStoragePath = (storagePath) => {
    if (typeof storagePath !== "string") return;
    const match = /^users\/[^/]+\/audio\/([^/]+)$/.exec(storagePath);
    if (!match) return;
    const fileName = match[1];
    const trackId = fileName.replace(/\.[^.]+$/, "").toLowerCase();
    trackFileAccess.set(fileName, { projectID: projectId });
    trackAccess.set(trackId, { projectID: projectId });
  };

  if (typeof data?.coverStoragePath === "string") {
    const coverMatch = /^users\/[^/]+\/covers\/([^/]+)$/.exec(data.coverStoragePath);
    if (coverMatch) {
      coverFileAccess.set(coverMatch[1], { projectID: projectId });
    }
  }

  for (const track of tracks) {
    if (!track || typeof track !== "object") continue;

    if (typeof track.id === "string" && track.id) {
      trackAccess.set(track.id.toLowerCase(), { projectID: projectId });
    }
    indexFlatStoragePath(track.storagePath);

    const versions = Array.isArray(track.versions) ? track.versions : [];
    for (const version of versions) {
      if (!version || typeof version.id !== "string" || !version.id) continue;
      versionAccess.set(version.id, {
        projectID: projectId,
        isPublic: version.isPublic !== false,
      });
      indexFlatStoragePath(version.storagePath);
    }
  }

  return { trackAccess, trackFileAccess, coverFileAccess, versionAccess };
}

async function writeAccessEntries(ownerId, collection, entries) {
  if (entries.size === 0) return;
  const db = getFirestore();
  const writes = [...entries.entries()];
  for (let offset = 0; offset < writes.length; offset += 450) {
    const batch = db.batch();
    for (const [assetId, data] of writes.slice(offset, offset + 450)) {
      batch.set(
        db.doc(`users/${ownerId}/${collection}/${assetId}`),
        { ...data, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );
    }
    await batch.commit();
  }
}

async function deleteRemovedEntries(ownerId, collection, before, after, projectId) {
  const removed = [...before.keys()].filter((assetId) => !after.has(assetId));
  const db = getFirestore();
  await Promise.all(
    removed.map((assetId) => {
      const reference = db.doc(`users/${ownerId}/${collection}/${assetId}`);
      return db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(reference);
        // A track can be moved between projects. Never let the old project's
        // delayed trigger delete an index already reassigned to the new project.
        if (snapshot.exists && snapshot.get("projectID") === projectId) {
          transaction.delete(reference);
        }
      });
    })
  );
}

async function syncProjectAudioAccessEntries(ownerId, projectId, beforeData, afterData) {
  const before = projectAudioAccess(beforeData, projectId);
  const after = projectAudioAccess(afterData, projectId);

  await Promise.all([
    writeAccessEntries(ownerId, "trackAccess", after.trackAccess),
    writeAccessEntries(ownerId, "trackFileAccess", after.trackFileAccess),
    writeAccessEntries(ownerId, "coverFileAccess", after.coverFileAccess),
    writeAccessEntries(ownerId, "versionAccess", after.versionAccess),
  ]);
  await Promise.all([
    deleteRemovedEntries(
      ownerId,
      "trackAccess",
      before.trackAccess,
      after.trackAccess,
      projectId
    ),
    deleteRemovedEntries(
      ownerId,
      "trackFileAccess",
      before.trackFileAccess,
      after.trackFileAccess,
      projectId
    ),
    deleteRemovedEntries(
      ownerId,
      "coverFileAccess",
      before.coverFileAccess,
      after.coverFileAccess,
      projectId
    ),
    deleteRemovedEntries(
      ownerId,
      "versionAccess",
      before.versionAccess,
      after.versionAccess,
      projectId
    ),
  ]);
}

/** Keeps the Storage-rule access indexes in sync with the authoritative project. */
export const syncProjectAudioAccess = onDocumentWritten(
  "users/{ownerId}/projects/{projectId}",
  async (event) => {
    await syncProjectAudioAccessEntries(
      event.params.ownerId,
      event.params.projectId,
      event.data?.before.data(),
      event.data?.after.data()
    );
  }
);

/** One-time repair for projects created before the access-index trigger existed. */
export const backfillAudioAccessIndexes = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "Etc/UTC",
    memory: "512MiB",
    timeoutSeconds: 540,
    maxInstances: 1,
  },
  async () => {
    const db = getFirestore();
    const stateReference = db.doc(BACKFILL_STATE_PATH);
    const stateSnapshot = await stateReference.get();
    if (stateSnapshot.get("completed") === true) return;

    const projects = await db.collectionGroup("projects").get();
    let indexedProjects = 0;
    for (const project of projects.docs) {
      const owner = project.ref.parent.parent;
      if (!owner || owner.parent.id !== "users") continue;
      await syncProjectAudioAccessEntries(owner.id, project.id, undefined, project.data());
      indexedProjects += 1;
    }

    await stateReference.set(
      {
        completed: true,
        completedAt: FieldValue.serverTimestamp(),
        indexedProjects,
      },
      { merge: true }
    );
    logger.info(`Audio access index backfill completed for ${indexedProjects} projects.`);
  }
);
