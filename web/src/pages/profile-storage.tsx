import {
  AudioWaveform,
  CircleUser,
  Cloud,
  CloudOff,
  CloudUpload,
  ListMusic,
  Trash2,
} from "lucide-react"
import { useSyncExternalStore } from "react"
import { AppHeader } from "@/components/app-header"
import { SettingsDivider, SettingsPageHeader, SettingsRow, SettingsSection } from "@/components/settings"
import { useAuth } from "@/hooks/use-auth"
import { PLAN_TIERS, effectiveTier, usePlanState } from "@/hooks/use-plan"
import { useProjects } from "@/hooks/use-projects"
import { formatFileSize } from "@/lib/format"
import { trackStorageBytes } from "@/lib/types"
import { cn } from "@/lib/utils"

/** Web port of the iOS `StorageSyncView` (storage usage + sync details). */
export function ProfileStoragePage() {
  const { user } = useAuth()
  const { projects, loading: projectsLoading } = useProjects()
  const { plan, loading: planLoading } = usePlanState()
  const online = useOnlineStatus()

  // Only own projects count against the storage limit (shared projects live in
  // the owner's storage) — same as the iOS `totalUsedStorageBytes`.
  const ownProjects = projects.filter((p) => !p.ownerID)
  const usedBytes = ownProjects
    .flatMap((p) => p.tracks)
    .reduce((total, track) => total + trackStorageBytes(track), 0)
  const limitBytes = PLAN_TIERS[effectiveTier(plan)].storageLimitBytes
  const fraction = limitBytes ? Math.min(1, usedBytes / limitBytes) : 0
  const freeBytes = limitBytes ? Math.max(0, limitBytes - usedBytes) : null

  const allTracks = projects.flatMap((p) => p.tracks)
  const uploadedCount = allTracks.filter((t) => t.storagePath).length

  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader backTo="/profile" backLabel="Profile" title="Storage & Sync" />

        <SettingsSection title="Storage" className="rise-in">
          <div className="flex flex-col gap-3.5 p-4">
            <div className="flex items-baseline justify-between">
              <div className="flex flex-col gap-0.5">
                <span className="text-[28px] font-bold leading-tight">
                  {formatFileSize(usedBytes)}
                </span>
                <span className="text-sm text-muted-foreground">
                  used of {limitBytes ? formatFileSize(limitBytes) : "Unlimited"}
                </span>
              </div>
              <div className="flex flex-col items-end gap-0.5">
                <span
                  className={cn(
                    "text-[17px] font-semibold",
                    fraction > 0.9 && "text-destructive",
                  )}
                >
                  {freeBytes === null ? "Unlimited" : formatFileSize(freeBytes)}
                </span>
                <span className="text-sm text-muted-foreground">available</span>
              </div>
            </div>

            {!projectsLoading && !planLoading && (
              <div className="h-2.5 overflow-hidden rounded-full bg-foreground/8">
                <div
                  className="h-full rounded-full bg-brand"
                  style={{ width: `${Math.max(fraction * 100, usedBytes > 0 ? 1.5 : 0)}%` }}
                />
              </div>
            )}

            <div className="flex items-center gap-4 text-[13px] text-muted-foreground">
              <span className="flex items-center gap-1.5">
                <ListMusic className="size-3.5" />
                {ownProjects.length} {ownProjects.length === 1 ? "project" : "projects"}
              </span>
              <span className="flex items-center gap-1.5">
                <AudioWaveform className="size-3.5" />
                {allTracks.length} {allTracks.length === 1 ? "track" : "tracks"}
              </span>
            </div>
          </div>
        </SettingsSection>

        <SettingsSection title="Sync" className="rise-in mt-6">
          <SettingsRow
            icon={
              online ? (
                <Cloud className="size-4.5" />
              ) : (
                <CloudOff className="size-4.5" />
              )
            }
            iconClassName={online ? "text-green-600 dark:text-green-500" : undefined}
            title={online ? "Synced" : "Offline"}
            subtitle={
              online
                ? "Your library updates in real time across devices."
                : "Changes will sync when you're back online."
            }
          />
          <SettingsDivider />
          {user?.email && (
            <>
              <SettingsRow
                icon={<CircleUser className="size-4" />}
                title="Account"
                value={user.email}
              />
              <SettingsDivider />
            </>
          )}
          <SettingsRow
            icon={<ListMusic className="size-4" />}
            title="Projects"
            value={String(projects.length)}
          />
          <SettingsDivider />
          <SettingsRow
            icon={<AudioWaveform className="size-4" />}
            title="Tracks"
            value={String(allTracks.length)}
          />
          <SettingsDivider />
          <SettingsRow
            icon={<Trash2 className="size-4" />}
            iconClassName="text-destructive"
            title="Delete tracks"
            titleClassName="text-destructive"
            chevron
            to="/profile/storage/delete-tracks"
          />
          <SettingsDivider />
          <SettingsRow
            icon={<CloudUpload className="size-4" />}
            title="Uploaded to cloud"
            value={`${uploadedCount} of ${allTracks.length}`}
          />
        </SettingsSection>
      </main>
    </div>
  )
}

function useOnlineStatus(): boolean {
  return useSyncExternalStore(
    (onChange) => {
      window.addEventListener("online", onChange)
      window.addEventListener("offline", onChange)
      return () => {
        window.removeEventListener("online", onChange)
        window.removeEventListener("offline", onChange)
      }
    },
    () => navigator.onLine,
  )
}
