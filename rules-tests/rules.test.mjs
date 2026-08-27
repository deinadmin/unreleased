// Regression suite for unreleased's Firestore + Cloud Storage rules.
//
//   node exploit.mjs        (emulators must be running against the repo rules)
//
// ATTACK cases must be DENIED. FLOW cases must be ALLOWED. Any mismatch is a
// regression and exits non-zero.
import { initializeApp } from "firebase/app"
import {
  getAuth, connectAuthEmulator, signInAnonymously,
  createUserWithEmailAndPassword, signInWithEmailAndPassword,
} from "firebase/auth"
import {
  getFirestore, connectFirestoreEmulator, doc, setDoc, getDoc, getDocs, deleteDoc,
  collection, query, orderBy, startAt, endAt, limit, documentId, writeBatch,
  runTransaction, Timestamp,
} from "firebase/firestore"
import {
  getStorage, connectStorageEmulator, ref as sref, uploadBytes, getBytes, getDownloadURL,
} from "firebase/storage"

const PROJECT = "demo-unreleased"
let n = 0
function ctx(name) {
  const app = initializeApp(
    { projectId: PROJECT, apiKey: "fake", storageBucket: `${PROJECT}.appspot.com` },
    `${name}-${n++}`,
  )
  connectAuthEmulator(getAuth(app), "http://127.0.0.1:9099", { disableWarnings: true })
  connectFirestoreEmulator(getFirestore(app), "127.0.0.1", 8080)
  connectStorageEmulator(getStorage(app), "127.0.0.1", 9199)
  return app
}
async function asEmail(email) {
  const app = ctx(email.split("@")[0])
  const auth = getAuth(app)
  try { await createUserWithEmailAndPassword(auth, email, "password123") }
  catch { await signInWithEmailAndPassword(auth, email, "password123") }
  return app
}
async function asAnon() {
  const app = ctx("anon")
  await signInAnonymously(getAuth(app))
  return app
}
const admin = async (path, fields) => {
  const r = await fetch(
    `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents/${path}`,
    { method: "PATCH", headers: { Authorization: "Bearer owner", "Content-Type": "application/json" },
      body: JSON.stringify({ fields }) })
  if (!r.ok) throw new Error(`seed ${path}: ${await r.text()}`)
}
const S = (stringValue) => ({ stringValue })
const B = (booleanValue) => ({ booleanValue })

let failures = 0
const RED = "\x1b[31m", GREEN = "\x1b[32m", DIM = "\x1b[2m", OFF = "\x1b[0m"

/** `expect` is "deny" for attacks, "allow" for legitimate flows. */
async function check(expect, title, fn) {
  let ok, detail
  try { detail = await fn(); ok = true }
  catch (e) { ok = false; detail = String(e.message).replace(/\s+/g, " ").slice(0, 110) }
  const good = expect === "allow" ? ok : !ok
  if (!good) failures++
  const tag = good
    ? `${GREEN}${expect === "allow" ? "ok      " : "denied  "}${OFF}`
    : `${RED}${expect === "allow" ? "BROKEN  " : "EXPLOIT "}${OFF}`
  console.log(`  ${tag} ${title}`)
  if (detail && (!good || expect === "allow")) console.log(`           ${DIM}${detail}${OFF}`)
}
const attack = (t, fn) => check("deny", t, fn)
const flow = (t, fn) => check("allow", t, fn)
const must = (cond, msg) => { if (!cond) throw new Error(msg) }

// Each run starts from an empty emulator so leftover grants from a previous
// run can't make a denied case look allowed.
for (const url of [
  `http://127.0.0.1:8080/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
  `http://127.0.0.1:9099/emulator/v1/projects/${PROJECT}/accounts`,
]) {
  const r = await fetch(url, { method: "DELETE", headers: { Authorization: "Bearer owner" } })
  if (!r.ok) throw new Error(`reset ${url}: ${r.status}`)
}

// ── Seed ────────────────────────────────────────────────────────────────────
const victimApp = await asEmail("victim@example.com")
const victim = getAuth(victimApp).currentUser.uid
const vdb = getFirestore(victimApp), vst = getStorage(victimApp)

const SHARED = "11111111-1111-4111-8111-111111111111".toUpperCase()
const SECRET = "22222222-2222-4222-8222-222222222222".toUpperCase()
const V_PUBLIC = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
const V_SECRET = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
const V_LEGACY = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
const V_NEW = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4"
const LEGACY_PRIVATE = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1.wav"
const LEGACY_PUBLIC = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2.wav"

await admin(`usernames/victim`, { uid: S(victim) })
await admin(`userProfiles/${victim}`, { username: S("victim") })
await admin(`users/${victim}/projectPreviews/${SHARED}`,
  { name: S("Demo EP"), ownerUsername: S("victim"), linkEnabled: B(true) })
await admin(`users/${victim}/projectPreviews/${SECRET}`,
  { name: S("Unreleased Album"), ownerUsername: S("victim"), linkEnabled: B(false) })

await setDoc(doc(vdb, "users", victim, "projects", SHARED), {
  id: SHARED, name: "Demo EP", ownerUsername: "victim",
  tracks: [{
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Single",
    notes: "PRIVATE NOTE: sample not cleared",
    versions: [
      { id: V_PUBLIC, isPublic: true,  storagePath: `users/${victim}/audio/versions/${V_PUBLIC}/audio.wav` },
      { id: V_SECRET, isPublic: false, storagePath: `users/${victim}/audio/versions/${V_SECRET}/audio.wav` },
      { id: V_LEGACY, isPublic: false, storagePath: `users/${victim}/audio/${LEGACY_PRIVATE}` },
    ],
  }],
})
await setDoc(doc(vdb, "users", victim, "projects", SECRET), { id: SECRET, name: "Unreleased Album", tracks: [] })

// Access indexes as the (updated) syncProjectAudioAccess trigger writes them.
await admin(`users/${victim}/versionAccess/${V_PUBLIC}`, { projectID: S(SHARED), isPublic: B(true) })
await admin(`users/${victim}/versionAccess/${V_SECRET}`, { projectID: S(SHARED), isPublic: B(false) })
await admin(`users/${victim}/versionAccess/${V_LEGACY}`, { projectID: S(SHARED), isPublic: B(false) })
await admin(`users/${victim}/trackFileAccess/${LEGACY_PRIVATE}`, { projectID: S(SHARED), isPublic: B(false) })
await admin(`users/${victim}/trackFileAccess/${LEGACY_PUBLIC}`,  { projectID: S(SHARED), isPublic: B(true) })

for (const p of [`audio/versions/${V_PUBLIC}/audio.wav`, `audio/versions/${V_SECRET}/audio.wav`,
                 `audio/${LEGACY_PRIVATE}`, `audio/${LEGACY_PUBLIC}`]) {
  await uploadBytes(sref(vst, `users/${victim}/${p}`), new Uint8Array([1, 2, 3]),
    { contentType: "audio/wav" })
}

const attackerApp = await asEmail("attacker@example.com")
const attacker = getAuth(attackerApp).currentUser.uid
const adb = getFirestore(attackerApp), ast = getStorage(attackerApp)
const anonApp = await asAnon()
const andb = getFirestore(anonApp), anst = getStorage(anonApp)

// ── Attacks ─────────────────────────────────────────────────────────────────
console.log("\nENUMERATION")
await attack("list all usernames", async () => {
  const s = await getDocs(collection(adb, "usernames")); must(s.size > 0, "empty"); return `${s.size} uids`
})
await attack("prefix-scan usernames (the old searchUsers query)", async () => {
  const s = await getDocs(query(collection(adb, "usernames"), orderBy(documentId()),
    startAt("v"), endAt("v\uf8ff"), limit(20)))
  must(s.size > 0, "empty"); return `${s.size} hits`
})
await attack("list all userProfiles", async () => {
  const s = await getDocs(collection(adb, "userProfiles")); must(s.size > 0, "empty"); return `${s.size}`
})
await attack("list a victim's projectPreviews", async () => {
  const s = await getDocs(collection(adb, "users", victim, "projectPreviews"))
  must(s.size > 0, "empty"); return `${s.size} project ids`
})
await attack("get the preview of a link-OFF project", async () => {
  const s = await getDoc(doc(adb, "users", victim, "projectPreviews", SECRET))
  must(s.exists(), "denied"); return s.data().name
})
await attack("list a victim's projects collection", async () => {
  const s = await getDocs(collection(adb, "users", victim, "projects")); must(s.size > 0, "empty"); return `${s.size}`
})

console.log("\nUNAUTHORIZED PROJECT / AUDIO ACCESS")
await attack("signed-in non-member reads the raw project doc (link ON)", async () => {
  const s = await getDoc(doc(adb, "users", victim, "projects", SHARED))
  must(s.exists(), "denied"); return `notes leaked: ${s.data().tracks[0].notes}`
})
await attack("anonymous guest reads the raw project doc (link ON)", async () => {
  const s = await getDoc(doc(andb, "users", victim, "projects", SHARED))
  must(s.exists(), "denied"); return "full doc incl. private versions"
})
await attack("read a project whose link is OFF", async () => {
  const s = await getDoc(doc(adb, "users", victim, "projects", SECRET)); must(s.exists(), "denied"); return "leaked"
})
await attack("anonymous streams PRIVATE version (legacy flat path)", async () => {
  const b = await getBytes(sref(anst, `users/${victim}/audio/${LEGACY_PRIVATE}`)); return `${b.byteLength}B`
})
await attack("anonymous streams PRIVATE version (versions/ path)", async () => {
  const b = await getBytes(sref(anst, `users/${victim}/audio/versions/${V_SECRET}/audio.wav`)); return `${b.byteLength}B`
})
await attack("self-enroll as invitee of a link-OFF project", () =>
  setDoc(doc(adb, "users", victim, "projects", SECRET, "invitees", attacker),
    { uid: attacker, username: "attacker", acceptedAt: Timestamp.now() }))
await attack("write another user's project", () =>
  setDoc(doc(adb, "users", victim, "projects", SHARED), { name: "pwned" }, { merge: true }))
await attack("enable another user's share link", () =>
  setDoc(doc(adb, "users", victim, "projectPreviews", SECRET), { linkEnabled: true }, { merge: true }))
await attack("write another user's versionAccess index", () =>
  setDoc(doc(adb, "users", victim, "versionAccess", V_SECRET), { isPublic: true, projectID: SHARED }, { merge: true }))
await attack("upload into another user's storage prefix", () =>
  uploadBytes(sref(ast, `users/${victim}/audio/evil.wav`), new Uint8Array(8)))

console.log("\nSTORAGE BLOAT")
await attack("2 MB junk at an arbitrary covers/ filename", () =>
  uploadBytes(sref(ast, `users/${attacker}/covers/junk.jpg`),
    new Uint8Array(2 * 1024 * 1024 - 1024), { contentType: "image/jpeg" }))
await attack("cover that is not a JPEG", () =>
  uploadBytes(sref(ast, `users/${attacker}/covers/${SHARED}-1.jpg`),
    new Uint8Array(1024), { contentType: "application/zip" }))
await attack("oversized cover (3 MB)", () =>
  uploadBytes(sref(ast, `users/${attacker}/covers/${SHARED}-1.jpg`),
    new Uint8Array(3 * 1024 * 1024), { contentType: "image/jpeg" }))
await attack("arbitrary filename under profile/", () =>
  uploadBytes(sref(ast, `users/${attacker}/profile/junk-1.jpg`),
    new Uint8Array(1000), { contentType: "image/jpeg" }))
await attack("oversized avatar (2 MB)", () =>
  uploadBytes(sref(ast, `users/${attacker}/profile/avatar.jpg`),
    new Uint8Array(2 * 1024 * 1024), { contentType: "image/jpeg" }))
await attack("non-audio blob under audio/", () =>
  uploadBytes(sref(ast, `users/${attacker}/audio/not-audio.exe`),
    new Uint8Array(1024), { contentType: "application/x-msdownload" }))
await attack("extensionless object under audio/", () =>
  uploadBytes(sref(ast, `users/${attacker}/audio/blob`), new Uint8Array(1024)))
await attack("non-audio content type disguised as mp3", () =>
  uploadBytes(sref(ast, `users/${attacker}/audio/00000000-0000-4000-8000-000000000001.mp3`),
    new Uint8Array(1024), { contentType: "text/html" }))
await attack("non-UUID legacy audio filename", () =>
  uploadBytes(sref(ast, `users/${attacker}/audio/unbounded-object.mp3`),
    new Uint8Array(1024), { contentType: "audio/mpeg" }))

console.log("\nFIRESTORE BLOAT / CROSS-USER WRITES")
await attack("squat 50 usernames in one batch", async () => {
  const b = writeBatch(adb)
  for (let i = 0; i < 50; i++) b.set(doc(adb, "usernames", `squat-${i}`), { uid: attacker })
  await b.commit()
})
await attack("claim a username without pointing the profile at it", () =>
  setDoc(doc(adb, "usernames", "drive-by"), { uid: attacker }))
await attack("set profile username to somebody else's reserved name", () =>
  setDoc(doc(adb, "userProfiles", attacker), { username: "victim" }, { merge: true }))
await attack("set an arbitrary external avatar URL", () =>
  setDoc(doc(adb, "userProfiles", attacker), {
    avatarURL: "https://attacker.example/tracking-pixel.jpg",
    avatarUpdatedAt: Timestamp.now(),
  }, { merge: true }))
await attack("spam 50 notifications into a victim's collection", async () => {
  const b = writeBatch(adb)
  for (let i = 0; i < 50; i++) {
    b.set(doc(adb, "users", victim, "notifications", `spam-${i}`), {
      type: "projectInvite", fromUID: attacker, projectID: SHARED, createdAt: Timestamp.now(),
    })
  }
  await b.commit()
})
await attack("invite notification for a project the sender does not own", () =>
  setDoc(doc(adb, "users", victim, "notifications", `projectInvite-${attacker}-${SHARED}`),
    { type: "projectInvite", fromUID: attacker, projectID: SHARED, createdAt: Timestamp.now() }))
await attack("100 arbitrary docs in own private/ subcollection", async () => {
  const b = writeBatch(adb)
  for (let i = 0; i < 100; i++) b.set(doc(adb, "users", attacker, "private", `bloat-${i}`), { x: "y".repeat(9000) })
  await b.commit()
})
await attack("project doc with 5000 tracks", () =>
  setDoc(doc(adb, "users", attacker, "projects", SECRET),
    { name: "x", tracks: Array.from({ length: 5000 }, (_, i) => ({ id: `t${i}` })) }))
await attack("grant self the unlimited plan", () =>
  setDoc(doc(adb, "users", attacker), { plan: "unlimited" }, { merge: true }))
await attack("forge own storage state to clear over-quota", () =>
  setDoc(doc(adb, "users", attacker, "storage", "state"), { usedBytes: 0, overLimit: false }, { merge: true }))

// ── Legitimate flows ────────────────────────────────────────────────────────
console.log("\nLEGITIMATE FLOWS (must keep working)")
const memberApp = await asEmail("member@example.com")
const member = getAuth(memberApp).currentUser.uid
const mdb = getFirestore(memberApp), mst = getStorage(memberApp)

await flow("new user claims a username (paired transaction)", () =>
  runTransaction(mdb, async (t) => {
    const r = doc(mdb, "usernames", "member")
    must(!(await t.get(r)).exists(), "taken")
    t.set(r, { uid: member })
    t.set(doc(mdb, "userProfiles", member), { username: "member" }, { merge: true })
  }))
await flow("owner publishes only their canonical avatar URL", () =>
  setDoc(doc(mdb, "userProfiles", member), {
    avatarURL: `https://firebasestorage.googleapis.com/v0/b/demo-unreleased.appspot.com/o/users%2F${member}%2Fprofile%2Favatar.jpg?alt=media&token=test`,
    avatarUpdatedAt: Timestamp.now(),
  }, { merge: true }))
await flow("check whether a username is free", async () => {
  const s = await getDoc(doc(mdb, "usernames", "definitely-free")); return `exists=${s.exists()}`
})
await flow("look up another user's profile by uid", async () => {
  const s = await getDoc(doc(mdb, "userProfiles", victim)); must(s.exists(), "missing"); return s.data().username
})
await flow("owner lists their own projects", async () => {
  const s = await getDocs(collection(vdb, "users", victim, "projects")); return `${s.size} projects`
})
await flow("owner writes their own project", () =>
  setDoc(doc(vdb, "users", victim, "projects", SHARED), { name: "Demo EP" }, { merge: true }))
await flow("owner writes each allowed private/ doc", async () => {
  for (const id of ["push", "sharedProjects", "equalizerPresets"]) {
    await setDoc(doc(vdb, "users", victim, "private", id), { updatedAt: Timestamp.now() }, { merge: true })
  }
})
await flow("owner invites by username (deterministic notification + pending)", async () => {
  const b = writeBatch(vdb)
  b.set(doc(vdb, "users", member, "notifications", `projectInvite-${victim}-${SHARED}`), {
    type: "projectInvite", fromUID: victim, fromUsername: "victim", projectID: SHARED,
    projectName: "Demo EP", recipientUsername: "member", createdAt: Timestamp.now(), read: false,
  })
  b.set(doc(vdb, "users", victim, "projects", SHARED, "pendingInvites", member),
    { uid: member, username: "member", invitedAt: Timestamp.now() })
  await b.commit()
})
await flow("invited user reads the preview before accepting", async () => {
  const s = await getDoc(doc(mdb, "users", victim, "projectPreviews", SHARED))
  must(s.exists(), "denied"); return s.data().name
})
await flow("invited user accepts (creates their invitee doc)", () =>
  setDoc(doc(mdb, "users", victim, "projects", SHARED, "invitees", member),
    { uid: member, username: "member", acceptedAt: Timestamp.now() }))
await flow("accepted invitee reads the project doc", async () => {
  const s = await getDoc(doc(mdb, "users", victim, "projects", SHARED))
  must(s.exists(), "denied"); return s.data().name
})
await flow("accepted invitee streams a PUBLIC version", async () => {
  const b = await getBytes(sref(mst, `users/${victim}/audio/versions/${V_PUBLIC}/audio.wav`)); return `${b.byteLength}B`
})
await flow("accepted invitee streams a PUBLIC legacy flat path", async () => {
  const b = await getBytes(sref(mst, `users/${victim}/audio/${LEGACY_PUBLIC}`)); return `${b.byteLength}B`
})
await attack("accepted invitee streams a PRIVATE legacy flat path", async () => {
  const b = await getBytes(sref(mst, `users/${victim}/audio/${LEGACY_PRIVATE}`)); return `${b.byteLength}B`
})
await flow("holder of a link-ON link saves the project to their library", async () => {
  const joinerApp = await asEmail("joiner@example.com")
  const jdb = getFirestore(joinerApp)
  const uid = getAuth(joinerApp).currentUser.uid
  await setDoc(doc(jdb, "users", victim, "projects", SHARED, "invitees", uid),
    { uid, username: "joiner", acceptedAt: Timestamp.now() })
  const s = await getDoc(doc(jdb, "users", victim, "projects", SHARED))
  must(s.exists(), "cannot read after joining")
  return "joined and readable"
})
await flow("guest with the link reads the preview (link ON)", async () => {
  const s = await getDoc(doc(andb, "users", victim, "projectPreviews", SHARED))
  must(s.exists(), "denied"); return s.data().name
})
await flow("guest with the link streams a PUBLIC version", async () => {
  const b = await getBytes(sref(anst, `users/${victim}/audio/versions/${V_PUBLIC}/audio.wav`)); return `${b.byteLength}B`
})
await flow("owner uploads audio (valid extension, under cap)", () =>
  uploadBytes(sref(vst, `users/${victim}/audio/versions/${V_NEW}/audio.m4a`),
    new Uint8Array(4096), { contentType: "audio/mp4" }))
await flow("owner uploads a cover named {projectId}-{version}.jpg", () =>
  uploadBytes(sref(vst, `users/${victim}/covers/${SHARED}-1756000000000-abc.jpg`),
    new Uint8Array(200_000), { contentType: "image/jpeg" }))
await flow("owner uploads avatar.jpg", () =>
  uploadBytes(sref(vst, `users/${victim}/profile/avatar.jpg`),
    new Uint8Array(200_000), { contentType: "image/jpeg" }))
await flow("owner deletes their own audio object", async () => {
  const { deleteObject } = await import("firebase/storage")
  await deleteObject(sref(vst, `users/${victim}/audio/versions/${V_NEW}/audio.m4a`))
})
await flow("invitee leaves the project", () =>
  deleteDoc(doc(mdb, "users", victim, "projects", SHARED, "invitees", member)))

console.log(`\n${"─".repeat(70)}`)
if (failures === 0) console.log(`${GREEN}All checks passed.${OFF}`)
else console.log(`${RED}${failures} check(s) failed.${OFF}`)
process.exit(failures === 0 ? 0 : 1)
