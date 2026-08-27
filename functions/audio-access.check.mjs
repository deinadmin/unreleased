// Pure regression checks for bearer-token revocation path discovery.
// Run from functions/: node audio-access.check.mjs
process.env.GCLOUD_PROJECT ??= "demo-unreleased";
process.env.FIREBASE_CONFIG ??= JSON.stringify({
  projectId: "demo-unreleased",
  storageBucket: "demo-unreleased.appspot.com",
});

const { revokedStoragePaths } = await import("./audio-access.js");

const publicVersion = {
  id: "v1",
  isPublic: true,
  storagePath: "users/owner/audio/versions/v1/audio.wav",
};
const privateVersion = {
  ...publicVersion,
  isPublic: false,
};
const base = {
  coverStoragePath: "users/owner/covers/project-old.jpg",
  tracks: [{
    id: "track",
    storagePath: publicVersion.storagePath,
    versions: [publicVersion],
  }],
};

const cases = [
  [
    "public-to-private rotates the audio token",
    revokedStoragePaths(base, {
      ...base,
      tracks: [{ ...base.tracks[0], versions: [privateVersion] }],
    }).includes(publicVersion.storagePath),
  ],
  [
    "removed version rotates the audio token",
    revokedStoragePaths(base, { ...base, tracks: [] }).includes(publicVersion.storagePath),
  ],
  [
    "replaced cover rotates the old cover token",
    revokedStoragePaths(base, {
      ...base,
      coverStoragePath: "users/owner/covers/project-new.jpg",
    }).includes(base.coverStoragePath),
  ],
  [
    "project deletion rotates every remaining bearer token",
    revokedStoragePaths(base, undefined).length === 2,
  ],
  [
    "unchanged access does not rotate tokens",
    revokedStoragePaths(base, structuredClone(base)).length === 0,
  ],
];

let failed = 0;
for (const [label, ok] of cases) {
  if (!ok) failed += 1;
  console.log(`  ${ok ? "\x1b[32mok    \x1b[0m" : "\x1b[31mFAILED\x1b[0m"} ${label}`);
}
process.exit(failed === 0 ? 0 : 1);
