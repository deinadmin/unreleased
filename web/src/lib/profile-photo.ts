import { updateProfile, type User as FirebaseUser } from "firebase/auth"
import { doc, getDoc, serverTimestamp, setDoc } from "firebase/firestore"
import { getDownloadURL, getMetadata, ref as storageRef, uploadBytes } from "firebase/storage"
import { db, storage } from "./firebase"
import { compressedSquareJpeg, PROFILE_PHOTO_LIMITS } from "./photo-compression"

const MAX_SOURCE_BYTES = 20 * 1024 * 1024

export class InvalidProfilePhotoError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "InvalidProfilePhotoError"
  }
}

/**
 * Center-crops a user-selected image, uploads a compact JPEG, and updates the
 * Firebase Auth profile so every avatar in the web app sees the new photo.
 */
export async function setProfilePhoto(user: FirebaseUser, file: File): Promise<string> {
  if (!file.type.startsWith("image/")) {
    throw new InvalidProfilePhotoError("Please choose an image file.")
  }
  if (file.size > MAX_SOURCE_BYTES) {
    throw new InvalidProfilePhotoError("Please choose an image smaller than 20 MB.")
  }

  let bitmap: ImageBitmap
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
  } catch {
    throw new InvalidProfilePhotoError("That image couldn't be opened. Please try another one.")
  }

  try {
    const blob = await compressedSquareJpeg(bitmap, PROFILE_PHOTO_LIMITS)
    const path = `users/${user.uid}/profile/avatar.jpg`
    const avatarRef = storageRef(storage, path)

    await uploadBytes(avatarRef, blob, {
      contentType: "image/jpeg",
      cacheControl: "public,max-age=3600",
    })

    // The storage path is intentionally stable. A version query prevents the
    // browser from continuing to display the previously cached avatar.
    const downloadURL = await getDownloadURL(avatarRef)
    const versionedURL = `${downloadURL}&v=${Date.now()}`
    await Promise.all([
      updateProfile(user, { photoURL: versionedURL }),
      setDoc(
        doc(db, "userProfiles", user.uid),
        { avatarURL: versionedURL, avatarUpdatedAt: serverTimestamp() },
        { merge: true },
      ),
    ])
    return versionedURL
  } finally {
    bitmap.close()
  }
}

/** Resolves another user's current avatar, including legacy Storage-only uploads. */
export async function fetchProfilePhotoURL(uid: string): Promise<string | undefined> {
  const profile = await getDoc(doc(db, "userProfiles", uid)).catch(() => null)
  const profileURL = profile?.data()?.avatarURL
  if (typeof profileURL === "string" && profileURL) return profileURL

  const avatarRef = storageRef(storage, `users/${uid}/profile/avatar.jpg`)
  try {
    const [downloadURL, metadata] = await Promise.all([
      getDownloadURL(avatarRef),
      getMetadata(avatarRef),
    ])
    const url = new URL(downloadURL)
    if (metadata.updated) {
      url.searchParams.set("v", String(new Date(metadata.updated).getTime()))
    }
    return url.toString()
  } catch {
    return undefined
  }
}
