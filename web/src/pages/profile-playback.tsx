import { Check, SlidersHorizontal, Volume2 } from "lucide-react"
import { Fragment } from "react"
import { AppHeader } from "@/components/app-header"
import {
  SettingsDivider,
  SettingsPageHeader,
  SettingsRow,
  SettingsSection,
} from "@/components/settings"
import { cn } from "@/lib/utils"
import { PLAYBACK_QUALITIES } from "@/player/playback-quality"
import { usePlayer } from "@/player/player-provider"

export function ProfilePlaybackPage() {
  const player = usePlayer()

  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader backTo="/profile" backLabel="Profile" title="Playback" />

        <SettingsSection title="Playback Quality" className="rise-in">
          {PLAYBACK_QUALITIES.map((quality, index) => {
            const selected = player.playbackQuality === quality.id
            return (
              <Fragment key={quality.id}>
                {index > 0 && <SettingsDivider />}
                <button
                  type="button"
                  onClick={() => player.setPlaybackQuality(quality.id)}
                  className="flex w-full items-center gap-3 px-4 py-3.5 text-left transition-colors hover:bg-foreground/4"
                  aria-pressed={selected}
                >
                  <span
                    className={cn(
                      "flex w-7 shrink-0 items-center justify-center",
                      selected ? "text-brand" : "text-muted-foreground",
                    )}
                  >
                    <Volume2 className="size-4" />
                  </span>
                  <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                    <span className="text-[15px] font-medium">{quality.title}</span>
                    <span className="text-[13px] leading-snug text-muted-foreground">
                      {quality.detail}
                    </span>
                  </span>
                  <Check
                    className={cn(
                      "size-4 shrink-0 text-brand transition-opacity",
                      selected ? "opacity-100" : "opacity-0",
                    )}
                    aria-hidden="true"
                  />
                </button>
              </Fragment>
            )
          })}
        </SettingsSection>

        <p className="rise-in px-1 pt-3 text-[13px] leading-relaxed text-muted-foreground">
          If the selected quality is still processing or unavailable, the original file plays automatically.
        </p>

        <SettingsSection title="Audio" className="rise-in mt-7">
          <SettingsRow
            icon={<SlidersHorizontal className="size-4" />}
            title="EQ"
            subtitle="Customize the sound of all playback"
            chevron
            to="/profile/eq"
          />
        </SettingsSection>
      </main>
    </div>
  )
}
