import { Timestamp, doc, getDoc, setDoc } from "firebase/firestore"
import { BellRing, UserPlus } from "lucide-react"
import { useEffect, useState } from "react"
import { AppHeader } from "@/components/app-header"
import { SettingsPageHeader, SettingsRow, SettingsSection } from "@/components/settings"
import { Switch } from "@/components/ui/switch"
import { useAuth } from "@/hooks/use-auth"
import { db } from "@/lib/firebase"
import { cn } from "@/lib/utils"

interface Preferences {
  enabled: boolean
  projectInvites: boolean
}

const DEFAULTS: Preferences = { enabled: true, projectInvites: true }

/** Web port of the iOS `NotificationSettingsView` — same `private/push` prefs doc. */
export function ProfileNotificationsPage() {
  const { user } = useAuth()
  const [preferences, setPreferences] = useState<Preferences>(DEFAULTS)
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    if (!user) return
    let cancelled = false
    getDoc(doc(db, "users", user.uid, "private", "push"))
      .then((snapshot) => {
        if (cancelled) return
        const data = snapshot.data()
        setPreferences({
          enabled: data?.notificationsEnabled !== false,
          projectInvites: data?.projectInvitesEnabled !== false,
        })
        setLoaded(true)
      })
      .catch(() => setLoaded(true))
    return () => {
      cancelled = true
    }
  }, [user])

  const save = (next: Preferences) => {
    setPreferences(next)
    if (!user) return
    void setDoc(
      doc(db, "users", user.uid, "private", "push"),
      {
        notificationsEnabled: next.enabled,
        projectInvitesEnabled: next.projectInvites,
        updatedAt: Timestamp.now(),
      },
      { merge: true },
    ).catch(() => {})
  }

  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader backTo="/profile" backLabel="Profile" title="Notifications" />

        <SettingsSection title="General" className="rise-in">
          <SettingsRow
            icon={<BellRing className="size-4" />}
            iconClassName={preferences.enabled ? "text-green-600 dark:text-green-500" : undefined}
            title="Notifications"
            subtitle={
              preferences.enabled
                ? "Choose which alerts you want to receive."
                : "All notification categories are paused."
            }
            trailing={
              <Switch
                checked={preferences.enabled}
                disabled={!loaded}
                onCheckedChange={(checked) => save({ ...preferences, enabled: checked })}
              />
            }
          />
        </SettingsSection>

        <SettingsSection
          title="Project activity"
          className={cn(
            "rise-in mt-6 transition-opacity",
            !preferences.enabled && "pointer-events-none opacity-45",
          )}
        >
          <SettingsRow
            icon={<UserPlus className="size-4" />}
            title="New project invites"
            subtitle="When someone invites you to collaborate on a project."
            trailing={
              <Switch
                checked={preferences.projectInvites}
                disabled={!loaded || !preferences.enabled}
                onCheckedChange={(checked) => save({ ...preferences, projectInvites: checked })}
              />
            }
          />
        </SettingsSection>
      </main>
    </div>
  )
}
