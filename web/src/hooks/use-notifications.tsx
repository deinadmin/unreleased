import {
  Timestamp,
  collection,
  deleteDoc,
  doc,
  limit,
  onSnapshot,
  orderBy,
  query,
  setDoc,
} from "firebase/firestore"
import { createContext, useContext, useEffect, useState, type ReactNode } from "react"
import { useAuth } from "@/hooks/use-auth"
import { decodeGradient } from "@/lib/codec"
import { db } from "@/lib/firebase"
import type { AppNotification } from "@/lib/types"

interface NotificationsContextValue {
  notifications: AppNotification[]
  unreadCount: number
  markRead: (notification: AppNotification) => void
  markAllRead: () => void
  remove: (notification: AppNotification) => void
}

const NotificationsContext = createContext<NotificationsContextValue>({
  notifications: [],
  unreadCount: 0,
  markRead: () => {},
  markAllRead: () => {},
  remove: () => {},
})

export function NotificationsProvider({ children }: { children: ReactNode }) {
  const { user, isSignedIn } = useAuth()
  const [notifications, setNotifications] = useState<AppNotification[]>([])

  useEffect(() => {
    if (!user || !isSignedIn) {
      setNotifications([])
      return
    }
    const notificationsQuery = query(
      collection(db, "users", user.uid, "notifications"),
      orderBy("createdAt", "desc"),
      limit(50),
    )
    return onSnapshot(
      notificationsQuery,
      (snapshot) => {
        setNotifications(
          snapshot.docs.flatMap((docSnap) => {
            const data = docSnap.data()
            if (
              typeof data.type !== "string" ||
              typeof data.fromUID !== "string" ||
              typeof data.projectID !== "string"
            ) {
              return []
            }
            return [
              {
                id: docSnap.id,
                kind: data.type === "projectInvite" ? "projectInvite" : "unknown",
                fromUID: data.fromUID,
                fromUsername: typeof data.fromUsername === "string" ? data.fromUsername : "",
                projectID: data.projectID,
                projectName:
                  typeof data.projectName === "string" ? data.projectName : "a project",
                projectGradient: decodeGradient(data.projectGradient) ?? undefined,
                coverStoragePath:
                  typeof data.coverStoragePath === "string"
                    ? data.coverStoragePath
                    : undefined,
                createdAt:
                  data.createdAt instanceof Timestamp ? data.createdAt.toDate() : new Date(),
                read: data.read === true,
              } satisfies AppNotification,
            ]
          }),
        )
      },
      (error) => console.error("notifications listener failed", error),
    )
  }, [user, isSignedIn])

  const notificationDoc = (id: string) => doc(db, "users", user!.uid, "notifications", id)

  const value: NotificationsContextValue = {
    notifications,
    unreadCount: notifications.filter((n) => !n.read).length,
    markRead: (notification) => {
      if (!user || notification.read) return
      void setDoc(notificationDoc(notification.id), { read: true }, { merge: true }).catch(() => {})
    },
    markAllRead: () => {
      if (!user) return
      for (const notification of notifications.filter((n) => !n.read)) {
        void setDoc(notificationDoc(notification.id), { read: true }, { merge: true }).catch(
          () => {},
        )
      }
    },
    remove: (notification) => {
      if (!user) return
      void deleteDoc(notificationDoc(notification.id)).catch(() => {})
    },
  }

  return (
    <NotificationsContext.Provider value={value}>{children}</NotificationsContext.Provider>
  )
}

export function useNotifications(): NotificationsContextValue {
  return useContext(NotificationsContext)
}
