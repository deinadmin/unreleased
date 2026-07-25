import { Check, MoreHorizontal, Pencil, Plus, SlidersHorizontal, Trash2 } from "lucide-react"
import { Fragment, useState } from "react"
import { AppHeader } from "@/components/app-header"
import { useContextMenu } from "@/components/context-menu"
import { EqualizerChart } from "@/components/equalizer-chart"
import { SettingsPageHeader, SettingsRow, SettingsSection } from "@/components/settings"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Switch } from "@/components/ui/switch"
import { cn } from "@/lib/utils"
import { EQUALIZER_PRESETS, isFlat, type CustomEqualizerPreset } from "@/player/equalizer"
import { useEqualizer } from "@/player/equalizer-provider"

type Prompt =
  | { kind: "save" }
  | { kind: "rename"; preset: CustomEqualizerPreset }
  | { kind: "delete"; preset: CustomEqualizerPreset }

/** Web port of the iOS `EqualizerView` (curve editor, on/off, presets). */
export function ProfileEqPage() {
  const eq = useEqualizer()
  const contextMenu = useContextMenu()
  const [prompt, setPrompt] = useState<Prompt | null>(null)
  const [presetName, setPresetName] = useState("")

  const activeTitle = eq.activePreset?.title ?? eq.activeCustomPreset?.title ?? "Custom"
  // iOS only offers "save as preset" while the curve doesn't match a preset.
  const canSaveCurrent = !eq.activePreset && !eq.activeCustomPreset

  const setGain = (gain: number, index: number) => {
    if (Math.abs((eq.gains[index] ?? 0) - gain) < 0.05) return
    eq.setGain(gain, index)
  }

  const beginSave = () => {
    setPresetName("")
    setPrompt({ kind: "save" })
  }

  const beginRename = (preset: CustomEqualizerPreset) => {
    setPresetName(preset.title)
    setPrompt({ kind: "rename", preset })
  }

  const openPresetMenu = (preset: CustomEqualizerPreset, x: number, y: number) => {
    contextMenu.openAt(x, y, [
      { label: "Rename", icon: <Pencil />, onSelect: () => beginRename(preset) },
      {
        label: "Delete",
        icon: <Trash2 />,
        destructive: true,
        onSelect: () => setPrompt({ kind: "delete", preset }),
      },
    ])
  }

  return (
    // `clip` (not `hidden`) so the chart's bleed can never add a scrollbar
    // without turning the page into a scroll container.
    <div className="min-h-dvh overflow-x-clip">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader backTo="/profile" backLabel="Profile" title="EQ" />

        {/* ── Curve editor ───────────────────────────────────────────── */}
        <section className="rise-in">
          <div className="flex items-start justify-between gap-4">
            <div className="flex min-w-0 flex-col gap-1">
              <h2 className="text-[22px] font-bold leading-tight">Shape your sound</h2>
              <p className="text-[14px] text-muted-foreground">Drag any point up or down.</p>
            </div>
            <button
              type="button"
              onClick={eq.reset}
              disabled={isFlat(eq.gains)}
              className="-mr-2 shrink-0 rounded-lg px-2 py-1 text-[14px] font-semibold text-brand transition hover:bg-brand/10 disabled:pointer-events-none disabled:opacity-40"
            >
              Reset
            </button>
          </div>

          <EqualizerChart
            gains={eq.gains}
            enabled={eq.enabled}
            onGainChange={setGain}
            onActivate={() => eq.setEnabled(true)}
          />
        </section>

        {/* ── On / off ───────────────────────────────────────────────── */}
        <div className="rise-in mt-6 overflow-hidden rounded-[14px] bg-secondary">
          <SettingsRow
            icon={<SlidersHorizontal className="size-4" />}
            iconClassName={eq.enabled ? "text-brand" : undefined}
            title="Equalizer"
            titleClassName="font-semibold"
            subtitle={eq.enabled ? "Applied to all playback" : "Turned off"}
            trailing={<Switch checked={eq.enabled} onCheckedChange={eq.setEnabled} />}
          />
        </div>

        {/* ── Presets ────────────────────────────────────────────────── */}
        <SettingsSection
          title="Presets"
          trailing={
            <span className="text-[13px] font-semibold text-muted-foreground">{activeTitle}</span>
          }
          className="rise-in mt-7"
        >
          {EQUALIZER_PRESETS.map((preset, index) => (
            <Fragment key={preset.id}>
              {index > 0 && <PresetDivider />}
              <PresetRow
                title={preset.title}
                detail={preset.detail}
                selected={eq.activePreset?.id === preset.id}
                onClick={() => eq.applyPreset(preset)}
              />
            </Fragment>
          ))}

          {eq.customPresets.map((preset) => (
            <Fragment key={preset.id}>
              <PresetDivider />
              <PresetRow
                title={preset.title}
                detail="Custom preset"
                selected={eq.activeCustomPreset?.id === preset.id}
                onClick={() => eq.applyCustomPreset(preset)}
                onOpenMenu={(x, y) => openPresetMenu(preset, x, y)}
              />
            </Fragment>
          ))}
        </SettingsSection>

        <button
          type="button"
          onClick={beginSave}
          disabled={!canSaveCurrent}
          className={cn(
            "rise-in mt-3 flex h-12 w-full items-center justify-center gap-2 rounded-[14px] bg-secondary text-[14px] font-semibold transition",
            "hover:bg-foreground/8 active:scale-[0.99]",
            !canSaveCurrent && "pointer-events-none opacity-45",
          )}
        >
          <Plus className="size-4" />
          Save Current as New Preset
        </button>
      </main>

      <Dialog
        open={!!prompt}
        onOpenChange={(open) => {
          if (!open) setPrompt(null)
        }}
      >
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          {prompt?.kind === "delete" ? (
            <>
              <DialogHeader className="min-w-0 pb-1">
                <DialogTitle>Delete EQ Preset?</DialogTitle>
              </DialogHeader>
              <p className="text-[13px] leading-5 text-muted-foreground">
                Are you sure you want to delete “{prompt.preset.title}”?
              </p>
              <div className="flex justify-end gap-2 pt-5">
                <Button variant="ghost" size="lg" onClick={() => setPrompt(null)}>
                  Cancel
                </Button>
                <Button
                  variant="destructive"
                  size="lg"
                  onClick={() => {
                    eq.deleteCustomPreset(prompt.preset.id)
                    setPrompt(null)
                  }}
                >
                  Delete
                </Button>
              </div>
            </>
          ) : (
            <form
              onSubmit={(event) => {
                event.preventDefault()
                if (!presetName.trim() || !prompt) return
                if (prompt.kind === "rename") eq.renameCustomPreset(prompt.preset.id, presetName)
                else eq.saveCustomPreset(presetName)
                setPrompt(null)
              }}
            >
              <DialogHeader className="min-w-0 pb-1">
                <DialogTitle>
                  {prompt?.kind === "rename" ? "Rename EQ Preset" : "Save EQ Preset"}
                </DialogTitle>
              </DialogHeader>
              <p className="pt-2 text-[13px] leading-5 text-muted-foreground">
                {prompt?.kind === "rename"
                  ? "Enter a new name for this preset."
                  : "Save the current curve as a new preset."}
              </p>
              <input
                autoFocus
                value={presetName}
                onChange={(event) => setPresetName(event.target.value)}
                placeholder="Preset name"
                aria-label="Preset name"
                maxLength={40}
                className="mt-4 h-11 w-full rounded-xl bg-secondary px-3.5 text-[15px] outline-none ring-brand/60 transition placeholder:text-muted-foreground/60 focus:ring-2"
              />
              <div className="flex justify-end gap-2 pt-5">
                <Button type="button" variant="ghost" size="lg" onClick={() => setPrompt(null)}>
                  Cancel
                </Button>
                <Button type="submit" size="lg" disabled={!presetName.trim()}>
                  {prompt?.kind === "rename" ? "Rename" : "Save"}
                </Button>
              </div>
            </form>
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}

function PresetDivider() {
  return <div className="ml-4 h-px bg-border/70" />
}

function PresetRow({
  title,
  detail,
  selected,
  onClick,
  onOpenMenu,
}: {
  title: string
  detail: string
  selected: boolean
  onClick: () => void
  /** Custom presets only: rename/delete, on right-click or the trailing button. */
  onOpenMenu?: (x: number, y: number) => void
}) {
  return (
    <div
      className="preset-row relative flex items-center"
      onContextMenu={
        onOpenMenu &&
        ((event) => {
          event.preventDefault()
          onOpenMenu(event.clientX, event.clientY)
        })
      }
    >
      <button
        type="button"
        onClick={onClick}
        aria-pressed={selected}
        className="flex min-h-14 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-foreground/4"
      >
        <span className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="truncate text-[15px] font-medium">{title}</span>
          <span className="truncate text-[13px] text-muted-foreground">{detail}</span>
        </span>
        <Check
          className={cn(
            "size-4 shrink-0 text-brand transition-opacity",
            selected ? "opacity-100" : "opacity-0",
            // Slides left in step with the menu button appearing.
            onOpenMenu && "preset-row-check",
          )}
        />
      </button>

      {onOpenMenu && (
        <button
          type="button"
          aria-label={`Actions for ${title}`}
          onClick={(event) => {
            const rect = event.currentTarget.getBoundingClientRect()
            onOpenMenu(rect.right, rect.bottom + 4)
          }}
          className="preset-row-action absolute right-2.5 flex size-7 items-center justify-center rounded-lg text-muted-foreground hover:bg-foreground/8 hover:text-foreground"
        >
          <MoreHorizontal className="size-4" />
        </button>
      )}
    </div>
  )
}
