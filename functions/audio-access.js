import { randomUUID } from "node:crypto";
import { getFirestore, FieldPath, FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { AUDIO_RENDITIONS, renditionStoragePath } from "./audio-renditions.js";

// V3 adds `isPublic` to the flat-path indexes. Storage Rules require that
// field, so this backfill must complete before the matching rules are
// deployed — otherwise legacy-path playback fails closed for collaborators.
const BACKFILL_STATE_PATH = "_system/projectStorageAccessIndexBackfillV4";
const BACKFILL_PAGE_SIZE = 100;

function projectAudioAccess(data, projectId, ownerId) {
  const trackAccess = new Map();
  const trackFileAccess = new Map();
  const coverFileAccess = new Map();
  const versionAccess = new Map();
  const tracks = Array.isArray(data?.tracks) ? data.tracks : [];

  // A legacy flat object can be referenced by both `track.storagePath` and the
  // migrated version 0 that mirrors it. Whenever two references disagree, the
  // most restrictive visibility wins so a private version can never be
  // published by the public reference that happens to share its path.
  const indexRestrictive = (map, key, isPublic) => {
    const existing = map.get(key);
    map.set(key, {
      projectID: projectId,
      isPublic: existing ? existing.isPublic && isPublic : isPublic,
    });
  };

  const indexFlatStoragePath = (storagePath, isPublic) => {
    if (typeof storagePath !== "string") return;
    const match = /^users\/([^/]+)\/audio\/([^/]+)$/.exec(storagePath);
    if (!match || match[1] !== ownerId) return;
    const fileName = match[2];
    const trackId = fileName.replace(/\.[^.]+$/, "").toLowerCase();
    indexRestrictive(trackFileAccess, fileName, isPublic);
    indexRestrictive(trackAccess, trackId, isPublic);
  };

  if (typeof data?.coverStoragePath === "string") {
    const coverMatch = /^users\/([^/]+)\/covers\/([^/]+)$/.exec(data.coverStoragePath);
    if (coverMatch?.[1] === ownerId) {
      coverFileAccess.set(coverMatch[2], { projectID: projectId });
    }
  }

  for (const track of tracks) {
    if (!track || typeof track !== "object") continue;

    const versions = Array.isArray(track.versions) ? track.versions : [];

    if (versions.length === 0) {
      // No per-version visibility to honor: the track's single object is as
      // visible as the project itself.
      if (typeof track.id === "string" && track.id) {
        indexRestrictive(trackAccess, track.id.toLowerCase(), true);
      }
      indexFlatStoragePath(track.storagePath, true);
      continue;
    }

    // Once versions exist, `track.storagePath` only mirrors whichever version
    // is active, so it is deliberately not indexed on its own — every real
    // object is covered by the version that owns it, at that version's
    // visibility. Indexing the mirror separately would either publish a
    // private active version or hide a public one.
    for (const version of versions) {
      if (!version || typeof version.id !== "string" || !version.id) continue;
      const isPublic = version.isPublic !== false;
      versionAccess.set(version.id, { projectID: projectId, isPublic });
      indexFlatStoragePath(version.storagePath, isPublic);
    }
  }

  return { trackAccess, trackFileAccess, coverFileAccess, versionAccess };
}

function changedAccessEntries(before, after) {
  return new Map(
    [...after.entries()].filter(([assetId, data]) => {
      const previous = before.get(assetId);
      return (
        !previous ||
        previous.projectID !== data.projectID ||
        previous.isPublic !== data.isPublic
      );
    })
  );
}

async function writeAccessEntries(ownerId, collection, before, after) {
  const entries = changedAccessEntries(before, after);
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

/**
 * Every object whose grant was removed or became private. Storage Rules stop
 * authorizing it immediately, but a previously issued `getDownloadURL()` is a
 * bearer credential and keeps working until the object's token changes.
 */
export function revokedStoragePaths(beforeData, afterData) {
  const visibilityByPath = (data) => {
    const map = new Map();
    for (const track of Array.isArray(data?.tracks) ? data.tracks : []) {
      const versions = Array.isArray(track?.versions) ? track.versions : [];
      if (versions.length === 0 && typeof track?.storagePath === "string") {
        map.set(track.storagePath, true);
      }
      for (const version of versions) {
        if (typeof version?.storagePath !== "string") continue;
        map.set(version.storagePath, version.isPublic !== false);
      }
    }
    if (typeof data?.coverStoragePath === "string") {
      map.set(data.coverStoragePath, true);
    }
    return map;
  };

  const before = visibilityByPath(beforeData);
  const after = visibilityByPath(afterData);
  return [...before.entries()]
    .filter(([storagePath, wasPublic]) => {
      const isPublic = after.get(storagePath);
      return isPublic === undefined || (wasPublic && !isPublic);
    })
    .map(([storagePath]) => storagePath);
}

async function syncProjectAudioAccessEntries(ownerId, projectId, beforeData, afterData) {
  const before = projectAudioAccess(beforeData, projectId, ownerId);
  const after = projectAudioAccess(afterData, projectId, ownerId);

  await Promise.all([
    writeAccessEntries(ownerId, "trackAccess", before.trackAccess, after.trackAccess),
    writeAccessEntries(ownerId, "trackFileAccess", before.trackFileAccess, after.trackFileAccess),
    writeAccessEntries(ownerId, "coverFileAccess", before.coverFileAccess, after.coverFileAccess),
    writeAccessEntries(ownerId, "versionAccess", before.versionAccess, after.versionAccess),
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
    const beforeData = event.data?.before.data();
    const afterData = event.data?.after.data();
    await syncProjectAudioAccessEntries(
      event.params.ownerId,
      event.params.projectId,
      beforeData,
      afterData
    );

    const ownerPrefix = `users/${event.params.ownerId}/`;
    const revoked = revokedStoragePaths(beforeData, afterData)
      .filter((storagePath) => storagePath.startsWith(ownerPrefix));
    if (revoked.length === 0) return;
    const bucket = getStorage().bucket();
    const paths = [...new Set(
      revoked.flatMap((storagePath) => [storagePath, ...renditionPathsFor(storagePath)])
    )];
    for (let offset = 0; offset < paths.length; offset += 50) {
      await Promise.all(paths.slice(offset, offset + 50).map(async (path) => {
        try {
          const file = bucket.file(path);
          const [metadata] = await file.getMetadata();
          await file.setMetadata({
            metadata: {
              ...(metadata.metadata ?? {}),
              firebaseStorageDownloadTokens: randomUUID(),
            },
          });
        } catch (error) {
          if (error?.code !== 404) {
            logger.warn(`Could not rotate download token for ${path}:`, error);
          }
        }
      }));
    }
    logger.info(
      `Rotated download tokens for ${revoked.length} revoked object(s) ` +
        `in project ${event.params.projectId}.`
    );
  }
);

function renditionPathsFor(storagePath) {
  return Object.keys(AUDIO_RENDITIONS)
    .map((quality) => renditionStoragePath(storagePath, quality))
    .filter(Boolean);
}

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

    const cursor = String(stateSnapshot.get("cursor") ?? "");
    let query = db
      .collectionGroup("projects")
      .orderBy(FieldPath.documentId())
      .limit(BACKFILL_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const projects = await query.get();

    let indexedProjects = Number(stateSnapshot.get("indexedProjects") ?? 0);
    for (const project of projects.docs) {
      const owner = project.ref.parent.parent;
      if (!owner || owner.parent.id !== "users") continue;
      await syncProjectAudioAccessEntries(owner.id, project.id, undefined, project.data());
      indexedProjects += 1;
    }

    const completed = projects.size < BACKFILL_PAGE_SIZE;
    await stateReference.set({
      completed,
      cursor: completed ? FieldValue.delete() : projects.docs.at(-1).ref.path,
      completedAt: completed ? FieldValue.serverTimestamp() : FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
      indexedProjects,
    }, { merge: true });
    logger.info(
      completed
        ? `Audio access index backfill completed for ${indexedProjects} projects.`
        : `Audio access index backfill advanced to ${indexedProjects} projects.`
    );
  }
);
