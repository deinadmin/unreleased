// Functional check for reconcileSharedProjectState against the Firestore
// emulator. Run from the repo root:
//   firebase emulators:exec --project demo-unreleased --only firestore \
//     "node functions/reconcile.check.mjs"
process.env.GCLOUD_PROJECT ??= "demo-unreleased";
process.env.FIREBASE_CONFIG ??= JSON.stringify({
  projectId: "demo-unreleased",
  storageBucket: "demo-unreleased.appspot.com",
});

const { reconcileSharedProjectState } = await import("./index.js");
const { getFirestore } = await import("firebase-admin/firestore");
const db = getFirestore();

const OWNER = "owner1";
const PROJECT = "11111111-1111-4111-8111-111111111111";
const SETTLED = "settledListener";
const ORPHANED = "orphanedListener";
const INVITED = "invitedListener";

await db.doc(`users/${OWNER}/projects/${PROJECT}`).set({ id: PROJECT, name: "EP" });
for (const uid of [SETTLED, ORPHANED]) {
  await db.doc(`users/${OWNER}/projects/${PROJECT}/invitees/${uid}`).set({ uid });
}
// One listener already indexed correctly, one missing its reference.
await db.doc(`users/${SETTLED}/private/sharedProjects`).set({
  refs: { [PROJECT]: { ownerID: OWNER } },
});
await db.doc(`users/${ORPHANED}/private/sharedProjects`).set({ refs: {} });

// A pending invite whose notification and pending doc already agree.
const noteId = `projectInvite-${OWNER}-${PROJECT}`;
await db.doc(`users/${INVITED}/notifications/${noteId}`).set({
  type: "projectInvite", fromUID: OWNER, projectID: PROJECT,
  recipientUsername: "invited", read: false,
});
await db.doc(`users/${OWNER}/projects/${PROJECT}/pendingInvites/${INVITED}`).set({
  uid: INVITED, username: "invited", notificationID: noteId,
});

const writeTimes = async () => ({
  settled: (await db.doc(`users/${SETTLED}/private/sharedProjects`).get()).updateTime.toMillis(),
  orphaned: (await db.doc(`users/${ORPHANED}/private/sharedProjects`).get()).updateTime.toMillis(),
  pending: (
    await db.doc(`users/${OWNER}/projects/${PROJECT}/pendingInvites/${INVITED}`).get()
  ).updateTime.toMillis(),
});

const before = await writeTimes();
await reconcileSharedProjectState.run({});
const after = await writeTimes();

const checks = [
  ["repairs the missing shared-project reference", after.orphaned !== before.orphaned],
  ["leaves the already-correct reference untouched", after.settled === before.settled],
  ["leaves the already-correct pending invite untouched", after.pending === before.pending],
  [
    "the repaired reference now points at the owner",
    (await db.doc(`users/${ORPHANED}/private/sharedProjects`).get()).get("refs")?.[PROJECT]
      ?.ownerID === OWNER,
  ],
];

// A listener who accepted must have their stale invite notification cleared.
await db.doc(`users/${SETTLED}/notifications/${noteId}`).set({
  type: "projectInvite", fromUID: OWNER, projectID: PROJECT, read: false,
});
await reconcileSharedProjectState.run({});
checks.push([
  "clears an invite notification for a listener who already accepted",
  !(await db.doc(`users/${SETTLED}/notifications/${noteId}`).get()).exists,
]);

let failed = 0;
for (const [label, ok] of checks) {
  if (!ok) failed += 1;
  console.log(`  ${ok ? "\x1b[32mok    \x1b[0m" : "\x1b[31mFAILED\x1b[0m"} ${label}`);
}
console.log(failed === 0 ? "\nreconciler behaves correctly." : `\n${failed} check(s) failed.`);
process.exit(failed === 0 ? 0 : 1);
