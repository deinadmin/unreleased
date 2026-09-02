# unreleased

iOS (SwiftUI) + web (Vite/React) client over Firebase: Auth, Firestore, Cloud
Storage and Cloud Functions. Project id `ancient-tractor-267017`.

## Layout

| Path | What it is |
| --- | --- |
| `unreleased/` | iOS app. Xcode uses a file-system synchronized group, so new `.swift` files under it are picked up without editing the project. |
| `web/` | Vite + React + TypeScript web app. |
| `functions/` | Cloud Functions (Node 22, ESM). |
| `firestore.rules`, `storage.rules` | Security rules. |
| `rules-tests/` | Adversarial regression suite for both rules files. |

## Verify

Run whatever the change touches; run the rules suite for anything under
`firestore.rules`, `storage.rules` or `functions/`.

```bash
# Security rules — 30 attacks that must be denied, 21 flows that must work.
# Do not run `npm install` here: rules-tests/node_modules is a tracked symlink
# to web/node_modules, and npm replaces it with a real directory.
cd rules-tests && npm test

# Shared-project reconciler (proves it repairs drift without rewriting
# documents that are already correct).
firebase emulators:exec --project demo-unreleased --only firestore \
  "node functions/reconcile.check.mjs"

# Web
cd web && npx tsc -b --force && npm run build

# Cloud Functions (syntax + module graph; no deploy)
cd functions && node --check index.js && \
  GCLOUD_PROJECT=demo-x FIREBASE_CONFIG='{"projectId":"demo-x","storageBucket":"demo-x.appspot.com"}' \
  node -e "import('./index.js').then(m=>console.log(Object.keys(m).length,'functions'))"

# iOS
xcodebuild -project unreleased.xcodeproj -scheme unreleased \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

The rules suite needs the Java-backed emulators; the jars land in
`~/.cache/firebase/emulators` on first run.

## Security invariants

These are enforced by `rules-tests/rules.test.mjs`. Do not weaken one without
adding a case that proves the replacement holds.

- **The `usernames` and `userProfiles` collections are not listable.** `list`
  over `usernames` is a uid directory for the whole app, which makes every
  user's project ids discoverable and share-link UUIDs guessable. Username
  search runs in the `searchUsers` callable; clients only get exact-key reads.
- **`projectPreviews` is not listable**, and `get` requires ownership, an
  accepted invite, a pending invite, or `linkEnabled == true`.
- **Non-members never read the raw project document.** It carries private
  versions and per-track notes. Guests and signed-in non-members read the
  sanitized projection from `getPublicProject`. Filtering in the client is not
  a substitute — the data has already been delivered by then.
- **`isPublic` gates every audio path.** Legacy flat objects under
  `users/{uid}/audio/{file}` are gated by `trackFileAccess`/`trackAccess`, which
  carry `isPublic` exactly like `versionAccess`. A migrated track's version 0
  keeps the flat path, so omitting the check there leaks private versions.
- **Every client-writable Storage prefix is metered.** `enforceStorageLimit`
  counts `audio/`, `covers/` and `profile/`. Metering only `audio/` left the
  other two as unlimited free storage. Add a prefix to the rules ⇒ add it to
  `METERED_PREFIX_RE` and `totalMeteredBytes`.
- **Storage paths are constrained, not wildcards.** Profile pictures must be
  `avatar.jpg`; covers must start with a project UUID; audio must carry a known
  audio extension and stay under 500 MB.
- **Download URLs are bearer tokens that ignore Storage Rules.** Revoking access
  in Firestore does not invalidate a URL already issued by `getDownloadURL()`.
  Any new revocation path must rotate `firebaseStorageDownloadTokens` — see
  `revokeProjectDownloadTokens`, `revokeTokensWhenLinkDisabled` and the
  newly-private branch of `syncProjectAudioAccess`.
- **Cross-user notification writes are pinned to one deterministic id**,
  `projectInvite-{ownerUid}-{PROJECT_UUID}`, for a project the sender owns. Both
  clients and the rules must agree on that format.
- **Triggers never read an unbounded collection.** A user's notification
  collection is attacker-influenced; query it with filters and a limit.
- **Server state that drives a modal must expire.** `lastBlockedAt` on
  `users/{uid}/storage/state` means "there is an outstanding upload rejection",
  not "one happened once": every write that recomputes `overLimit` to false
  retires it via `clearedBlockedMarkers`. Clients dedupe rejections against a
  UserDefaults high-water mark, which a reinstall or a new device wipes, so an
  immortal marker replays as an "Upload Blocked" sheet seconds after sign-in for
  a user who is nowhere near their quota. The client's freshness window
  (10 min) must stay below `BLOCKED_MARKER_GRACE_MS` (15 min) so the server
  never sweeps a rejection a client would still show.
- **Repair work stays off the write path.** Both clients refresh
  `projectPreviews` on every project sync, so anything hanging off that write
  runs on every track rename. `reconcileSharedProjectState` is a daily schedule
  and writes only on an actual mismatch; keep it that way rather than
  reattaching it to a document trigger.

## Deploying

Order matters for one release only — the one that adds `isPublic` to the
flat-path access indexes.

0. Configure the production App Check key and deploy Hosting first. The new
   web build sends the App Check header to both the old and new public-project
   endpoint; deploying the enforcing Function before this client would make
   existing public links fail closed during the rollout.
1. `firebase deploy --only functions` next, and accept the prompt to delete the
   renamed `enforceAudioStorageLimit` / `refreshAudioStorageUsage`.
2. Wait for `_system/projectStorageAccessIndexBackfillV4.completed == true`
   (the `backfillAudioAccessIndexes` schedule runs every 15 minutes).
3. `firebase deploy --only firestore:rules,firestore:indexes,storage`

   Note `storage`, not `storage:rules` — for storage the `:` suffix names a
   deploy target, so `storage:rules` fails with "Could not find rules for the
   following storage targets: rules". Firestore does use `firestore:rules`.

Deploying the rules first fails closed for collaborators and guests streaming
legacy flat-path audio until the backfill lands. Owners are unaffected.

## Console configuration

- **App Check** is initialized in both clients. `searchUsers` enforces it and
  `getPublicProject` verifies it before issuing ten-minute signed media URLs.
  Put the web app's reCAPTCHA Enterprise key in `web/.env` as
  `VITE_FIREBASE_APPCHECK_SITE_KEY`; the production web app deliberately fails
  closed without it. After confirming verified traffic, enable enforcement for
  Firestore, Storage, and Auth in the Firebase console as well.
- The Cloud Functions service account must have permission to sign blobs
  (`iam.serviceAccounts.signBlob`) because public share media now uses V4
  signed Storage URLs instead of proxying bytes through a function. This is not
  granted by default, and without it *every* share link 500s while the rest of
  the app is unaffected — grant the runtime account the role on itself:

  ```bash
  SA=822378430827-compute@developer.gserviceaccount.com
  gcloud iam service-accounts add-iam-policy-binding "$SA" \
    --member="serviceAccount:$SA" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project=ancient-tractor-267017
  ```

  `iamcredentials.googleapis.com` must also be enabled. `getPublicProject`
  answers `503 media-unavailable` and logs the remediation when signing fails,
  so check `firebase functions:log --only getPublicProject` before suspecting
  the client.
- Plans are set by hand on `users/{uid}` (`plan`, `planExpiresAt`). There is no
  StoreKit integration and clients cannot write the document.
