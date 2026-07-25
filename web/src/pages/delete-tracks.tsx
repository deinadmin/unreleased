import {
  ArrowDownUp,
  ArrowDownWideNarrow,
  ArrowUpNarrowWide,
  AudioWaveform,
  Calendar,
  CaseSensitive,
  Check,
  HardDrive,
  Trash2,
} from "lucide-react"
import { Fragment, useEffect, useMemo, useState, type ReactNode } from "react"
import { toast } from "sonner"
import { AppHeader } from "@/components/app-header"
import { SettingsPageHeader } from "@/components/settings"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { useAuth } from "@/hooks/use-auth"
import { useProjects } from "@/hooks/use-projects"
import { formatFileSize, formatShortDate } from "@/lib/format"
import { deleteTracks, type TrackLocation } from "@/lib/project-edits"
import { trackStorageBytes, type Track } from "@/lib/types"
import { cn } from "@/lib/utils"
import { usePlayer } from "@/player/player-provider"

type SortField = "size" | "title" | "date"
type SortDirection = "ascending" | "descending"

const SORT_FIELDS: { value: SortField; label: string; icon: ReactNode }[] = [
  { value: "size", label: "Size", icon: <HardDrive /> },
  { value: "title", label: "Title", icon: <CaseSensitive /> },
  { value: "date", label: "Date", icon: <Calendar /> },
]

interface TrackItem {
  /** Stable identity across projects, since track IDs are only project-unique. */
  key: string
  projectID: string
  track: Track
}

/** Web port of the iOS `DeleteTracksView` (sort, multi-select, bulk delete). */
export function DeleteTracksPage() {
  const { user } = useAuth()
  const { projects, loading } = useProjects()
  const player = usePlayer()
  const [sortField, setSortField] = useState<SortField>("size")
  const [sortDirection, setSortDirection] = useState<SortDirection>("descending")
  const [selection, setSelection] = useState<Set<string>>(new Set())
  const [confirming, setConfirming] = useState(false)
  const [deleting, setDeleting] = useState(false)

  // Only tracks in owned projects can be deleted — shared projects live in the
  // owner's storage, same filtering as iOS.
  const items = useMemo<TrackItem[]>(
    () =>
      projects
        .filter((project) => !project.ownerID)
        .flatMap((project) =>
          project.tracks.map((track) => ({
            key: `${project.id}/${track.id}`,
            projectID: project.id,
            track,
          })),
        ),
    [projects],
  )

  const sorted = useMemo(
    () => [...items].sort(trackComparator(sortField, sortDirection)),
    [items, sortField, sortDirection],
  )

  // Forget tracks that disappeared (deleted here or from another device).
  useEffect(() => {
    const available = new Set(items.map((item) => item.key))
    setSelection((previous) => {
      const next = new Set([...previous].filter((key) => available.has(key)))
      return next.size === previous.size ? previous : next
    })
  }, [items])

  const allSelected = items.length > 0 && selection.size === items.length
  const selectedItems = items.filter((item) => selection.has(item.key))
  const selectedBytes = selectedItems.reduce(
    (total, item) => total + trackStorageBytes(item.track),
    0,
  )

  const toggle = (key: string) => {
    setSelection((previous) => {
      const next = new Set(previous)
      if (!next.delete(key)) next.add(key)
      return next
    })
  }

  const remove = async () => {
    if (!user || selectedItems.length === 0) return
    const locations: TrackLocation[] = selectedItems.map(({ projectID, track }) => ({
      projectID,
      trackID: track.id,
    }))
    setDeleting(true)
    try {
      const playing = selectedItems.some(
        (item) => player.track?.id === item.track.id && player.project?.id === item.projectID,
      )
      if (playing) player.stop()
      await deleteTracks(user.uid, projects, locations)
      setSelection(new Set())
      toast(`Deleted ${locations.length} ${locations.length === 1 ? "track" : "tracks"}.`)
    } catch (error) {
      console.error("deleting tracks failed", error)
      toast("Couldn't delete these tracks. Please try again.")
    } finally {
      setDeleting(false)
    }
  }

  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader
          backTo="/profile/storage"
          backLabel="Storage & Sync"
          title="Delete tracks"
        />

        {items.length === 0 ? (
          !loading && (
            <div className="rise-in flex flex-col items-center gap-1.5 rounded-[14px] bg-secondary px-6 py-16 text-center">
              <AudioWaveform className="mb-1 size-7 text-muted-foreground/60" />
              <p className="text-[15px] font-semibold">No tracks to delete</p>
              <p className="max-w-64 text-[13px] leading-snug text-muted-foreground">
                Tracks from projects you own will appear here.
              </p>
            </div>
          )
        ) : (
          <>
            <div className="sticky top-14 z-20 -mx-5 flex items-center gap-2 bg-background px-5 pb-3 pt-1">
              <button
                type="button"
                onClick={() => setSelection(allSelected ? new Set() : new Set(items.map((i) => i.key)))}
                className="rounded-lg py-1.5 text-[14px] font-medium text-muted-foreground transition hover:text-foreground"
              >
                {allSelected ? "Deselect All" : "Select All"}
              </button>

              <span className="flex-1" />

              <SortMenu
                field={sortField}
                direction={sortDirection}
                onFieldChange={setSortField}
                onDirectionChange={setSortDirection}
              />

              <Button
                variant="destructive"
                size="lg"
                disabled={selection.size === 0 || deleting}
                onClick={() => setConfirming(true)}
              >
                <Trash2 />
                {deleting ? "Deleting…" : selection.size === 0 ? "Delete" : `Delete (${selection.size})`}
              </Button>
            </div>

            <div className="rise-in overflow-hidden rounded-[14px] bg-secondary">
              {sorted.map((item, index) => {
                const selected = selection.has(item.key)
                return (
                  <Fragment key={item.key}>
                    {index > 0 && <div className="ml-12 h-px bg-border/70" />}
                    <button
                      type="button"
                      role="checkbox"
                      aria-checked={selected}
                      onClick={() => toggle(item.key)}
                      className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-foreground/4"
                    >
                      <SelectionIndicator selected={selected} />
                      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                        <span className="truncate text-[15px] font-medium">{item.track.title}</span>
                        <span className="text-[13px] text-muted-foreground">
                          {formatFileSize(trackStorageBytes(item.track))} •{" "}
                          {formatShortDate(item.track.addedDate)}
                        </span>
                      </span>
                    </button>
                  </Fragment>
                )
              })}
            </div>
          </>
        )}
      </main>

      <Dialog open={confirming} onOpenChange={setConfirming}>
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          <DialogHeader className="min-w-0 pb-1">
            <DialogTitle>
              {selection.size === 1 ? "Delete track?" : `Delete ${selection.size} tracks?`}
            </DialogTitle>
          </DialogHeader>
          <p className="text-[13px] leading-5 text-muted-foreground">
            The selected tracks will be permanently deleted from the cloud, freeing{" "}
            {formatFileSize(selectedBytes)}. This can't be undone.
          </p>
          <div className="flex justify-end gap-2 pt-5">
            <Button variant="ghost" size="lg" onClick={() => setConfirming(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              size="lg"
              onClick={() => {
                setConfirming(false)
                void remove()
              }}
            >
              Delete
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function SortMenu({
  field,
  direction,
  onFieldChange,
  onDirectionChange,
}: {
  field: SortField
  direction: SortDirection
  onFieldChange: (field: SortField) => void
  onDirectionChange: (direction: SortDirection) => void
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="secondary" size="lg" aria-label="Sort tracks">
          <ArrowDownUp />
          {SORT_FIELDS.find((option) => option.value === field)?.label}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-40">
        <DropdownMenuLabel>Sort by</DropdownMenuLabel>
        <DropdownMenuRadioGroup
          value={field}
          onValueChange={(value) => onFieldChange(value as SortField)}
        >
          {SORT_FIELDS.map((option) => (
            <DropdownMenuRadioItem key={option.value} value={option.value}>
              {option.icon}
              {option.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
        <DropdownMenuSeparator />
        <DropdownMenuLabel>Order</DropdownMenuLabel>
        <DropdownMenuRadioGroup
          value={direction}
          onValueChange={(value) => onDirectionChange(value as SortDirection)}
        >
          <DropdownMenuRadioItem value="ascending">
            <ArrowUpNarrowWide />
            Ascending
          </DropdownMenuRadioItem>
          <DropdownMenuRadioItem value="descending">
            <ArrowDownWideNarrow />
            Descending
          </DropdownMenuRadioItem>
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function SelectionIndicator({ selected }: { selected: boolean }) {
  return (
    <span
      className={cn(
        "flex size-5.5 shrink-0 items-center justify-center rounded-full border-[1.5px] transition-colors",
        selected ? "border-brand bg-brand text-white" : "border-muted-foreground/45",
      )}
    >
      {selected && <Check className="size-3 stroke-[3]" />}
    </span>
  )
}

/** Sorts on the chosen field, falling back to title then key like iOS. */
function trackComparator(field: SortField, direction: SortDirection) {
  const sign = direction === "ascending" ? 1 : -1
  return (a: TrackItem, b: TrackItem): number => {
    let primary = 0
    if (field === "size") {
      primary = trackStorageBytes(a.track) - trackStorageBytes(b.track)
    } else if (field === "title") {
      primary = a.track.title.localeCompare(b.track.title, undefined, { numeric: true })
    } else {
      primary = a.track.addedDate.getTime() - b.track.addedDate.getTime()
    }
    if (primary !== 0) return sign * primary
    return (
      a.track.title.localeCompare(b.track.title, undefined, { numeric: true }) ||
      a.key.localeCompare(b.key)
    )
  }
}
