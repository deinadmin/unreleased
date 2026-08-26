import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import ffmpegPath from "ffmpeg-static";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onObjectDeleted, onObjectFinalized } from "firebase-functions/v2/storage";

const ORIGINAL_AUDIO_RE =
  /^users\/([^/]+)\/audio\/(?:versions\/([^/]+)\/)?([^/]+)$/;
const WAV_CONTENT_TYPES = new Set(["audio/wav", "audio/x-wav", "audio/wave"]);
const BACKFILL_STATE_PATH = "_system/audioRenditionBackfill";
const BACKFILL_PAGE_SIZE = 100;
const BACKFILL_TRANSCODE_LIMIT = 6;

export const AUDIO_RENDITIONS = Object.freeze({
  standard: { bitrate: "160k", fileName: "standard.m4a" },
  high: { bitrate: "256k", fileName: "high.m4a" },
});

function originalAudioDescriptor(storagePath) {
  const match = ORIGINAL_AUDIO_RE.exec(storagePath);
  if (!match) return null;
  const [, userId, versionId, fileName] = match;
  const extension = fileName.split(".").pop()?.toLowerCase();
  const trackId = fileName.replace(/\.[^.]+$/, "");
  return {
    userId,
    assetId: versionId ?? trackId,
    kind: versionId ? "versions" : "tracks",
    extension,
  };
}

function isWaveOriginal(file) {
  const descriptor = originalAudioDescriptor(file.name);
  if (!descriptor) return false;
  const contentType = String(file.metadata?.contentType ?? "").toLowerCase();
  return descriptor.extension === "wav" || WAV_CONTENT_TYPES.has(contentType);
}

export function renditionStoragePath(originalStoragePath, quality) {
  const descriptor = originalAudioDescriptor(originalStoragePath);
  const rendition = AUDIO_RENDITIONS[quality];
  if (!descriptor || !rendition) return null;
  return [
    "users",
    descriptor.userId,
    "audio-renditions",
    descriptor.kind,
    descriptor.assetId,
    rendition.fileName,
  ].join("/");
}

async function renditionMatchesGeneration(bucket, storagePath, sourceGeneration) {
  try {
    const [metadata] = await bucket.file(storagePath).getMetadata();
    return (
      metadata.metadata?.sourceGeneration === sourceGeneration &&
      typeof metadata.metadata?.firebaseStorageDownloadTokens === "string" &&
      metadata.metadata.firebaseStorageDownloadTokens.length > 0
    );
  } catch (error) {
    if (error?.code === 404) return false;
    throw error;
  }
}

async function runFfmpeg(sourceFile, outputs) {
  if (!ffmpegPath) throw new Error("ffmpeg-static did not provide an executable");

  const args = ["-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-vn"];
  for (const output of outputs) {
    args.push(
      "-map",
      "0:a:0",
      "-c:a",
      "aac",
      "-profile:a",
      "aac_low",
      "-b:a",
      output.bitrate,
      "-movflags",
      "+faststart",
      "-y",
      output.localPath
    );
  }

  const child = spawn(ffmpegPath, args, { stdio: ["pipe", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = (stderr + chunk).slice(-8_192);
  });

  const exit = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg exited with ${code ?? signal}: ${stderr}`));
    });
  });

  await Promise.all([pipeline(sourceFile.createReadStream(), child.stdin), exit]);
}

/**
 * Creates both AAC renditions for one WAV object. The source generation is
 * recorded on each output so retries are idempotent and overwrites regenerate.
 */
export async function ensureAudioRenditions(file, sourceGeneration) {
  if (!isWaveOriginal(file)) return false;

  const bucket = file.bucket;
  const generation = String(sourceGeneration ?? file.metadata?.generation ?? "");
  if (!generation) throw new Error(`Missing generation for ${file.name}`);

  const desiredOutputs = Object.entries(AUDIO_RENDITIONS).map(([quality, config]) => ({
    quality,
    bitrate: config.bitrate,
    storagePath: renditionStoragePath(file.name, quality),
  }));
  if (desiredOutputs.some((output) => !output.storagePath)) return false;

  const matches = await Promise.all(
    desiredOutputs.map((output) =>
      renditionMatchesGeneration(bucket, output.storagePath, generation)
    )
  );
  if (matches.every(Boolean)) return false;

  const temporaryDirectory = await mkdtemp(join(tmpdir(), "audio-renditions-"));
  try {
    const outputs = desiredOutputs.map((output) => ({
      ...output,
      localPath: join(temporaryDirectory, `${output.quality}.m4a`),
    }));
    await runFfmpeg(file, outputs);

    // Do not publish stale output if this path was deleted or overwritten while
    // ffmpeg was running. A finalized event for the newer generation owns it.
    const [latestMetadata] = await file.getMetadata();
    if (String(latestMetadata.generation ?? "") !== generation) {
      logger.info(`Skipped stale renditions for ${file.name} generation ${generation}.`);
      return false;
    }

    await Promise.all(
      outputs.map((output, index) => {
        if (matches[index]) return Promise.resolve();
        return bucket.upload(output.localPath, {
          destination: output.storagePath,
          metadata: {
            contentType: "audio/mp4",
            cacheControl: "private, max-age=31536000, immutable",
            metadata: {
              sourcePath: file.name,
              sourceGeneration: generation,
              quality: output.quality,
              bitrate: output.bitrate,
              firebaseStorageDownloadTokens: randomUUID(),
            },
          },
        });
      })
    );
    logger.info(`Created AAC renditions for ${file.name} generation ${generation}.`);
    return true;
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}

export const generateAudioRenditions = onObjectFinalized(
  {
    memory: "2GiB",
    cpu: 2,
    timeoutSeconds: 540,
    maxInstances: 4,
  },
  async (event) => {
    const storagePath = event.data.name ?? "";
    const bucket = getStorage().bucket(event.data.bucket);
    const file = bucket.file(storagePath);
    await ensureAudioRenditions(file, event.data.generation);
  }
);

/** Removes derived files whenever their original is deleted. */
export const cleanupAudioRenditions = onObjectDeleted(
  { memory: "256MiB" },
  async (event) => {
    const storagePath = event.data.name ?? "";
    const descriptor = originalAudioDescriptor(storagePath);
    if (!descriptor) return;
    const prefix = [
      "users",
      descriptor.userId,
      "audio-renditions",
      descriptor.kind,
      descriptor.assetId,
      "",
    ].join("/");
    await getStorage().bucket(event.data.bucket).deleteFiles({ prefix });
  }
);

/**
 * One-time, cursor-backed migration for WAV files that predate the finalize
 * trigger. The schedule becomes a single cheap Firestore read after completion.
 */
export const backfillAudioRenditions = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "Etc/UTC",
    memory: "2GiB",
    cpu: 2,
    timeoutSeconds: 540,
    maxInstances: 1,
  },
  async () => {
    const stateReference = getFirestore().doc(BACKFILL_STATE_PATH);
    const stateSnapshot = await stateReference.get();
    if (stateSnapshot.get("completed") === true) return;

    const cursor = String(stateSnapshot.get("cursor") ?? "");
    const bucket = getStorage().bucket();
    const [files] = await bucket.getFiles({
      prefix: "users/",
      startOffset: cursor || undefined,
      maxResults: BACKFILL_PAGE_SIZE,
      autoPaginate: false,
    });
    const remaining = files.filter((file) => file.name > cursor);
    if (remaining.length === 0) {
      await stateReference.set(
        { completed: true, completedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );
      logger.info("Audio rendition backfill completed.");
      return;
    }

    let lastInspected = cursor;
    let transcodes = 0;
    let stoppedEarly = false;
    for (const file of remaining) {
      lastInspected = file.name;
      if (!isWaveOriginal(file)) continue;
      try {
        const created = await ensureAudioRenditions(file, file.metadata?.generation);
        if (created) transcodes += 1;
      } catch (error) {
        // Playback still falls back to the original. Continue so one malformed
        // legacy upload cannot permanently block the rest of the migration.
        logger.error(`Backfill failed for ${file.name}:`, error);
      }
      if (transcodes >= BACKFILL_TRANSCODE_LIMIT) {
        stoppedEarly = true;
        break;
      }
    }

    // `startOffset` is inclusive, so a full page after the first usually
    // contains the cursor itself. Use the raw page length to decide whether a
    // later page may still exist.
    const completed = !stoppedEarly && files.length < BACKFILL_PAGE_SIZE;
    await stateReference.set(
      {
        cursor: lastInspected,
        completed,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    logger.info(
      `Audio rendition backfill inspected through ${lastInspected}; ` +
        `created ${transcodes}, completed=${completed}.`
    );
  }
);
