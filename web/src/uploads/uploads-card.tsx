import { AlertCircle, CheckCircle2, Music } from "lucide-react"
import { useUploads, type UploadItem } from "@/uploads/uploads-provider"

/** Floating import progress card, the web counterpart of the iOS `ImportingOverlay`. */
export function UploadsCard() {
  const { uploads } = useUploads()
  if (uploads.length === 0) return null

  return (
    <div className="fixed bottom-24 right-4 z-40 w-72 rounded-2xl border border-border/60 bg-background/95 p-3 shadow-xl backdrop-blur-xl">
      <p className="px-1 pb-2 text-[13px] font-semibold text-muted-foreground">
        Importing {uploads.length === 1 ? "1 track" : `${uploads.length} tracks`}
      </p>
      <div className="flex flex-col gap-2">
        {uploads.map((item) => (
          <UploadRow key={item.id} item={item} />
        ))}
      </div>
    </div>
  )
}

function UploadRow({ item }: { item: UploadItem }) {
  return (
    <div className="flex items-center gap-2.5 rounded-xl bg-secondary px-3 py-2">
      <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-background">
        {item.status === "done" ? (
          <CheckCircle2 className="size-3.5 text-green-600 dark:text-green-500" />
        ) : item.status === "error" ? (
          <AlertCircle className="size-3.5 text-destructive" />
        ) : (
          <Music className="size-3.5 text-muted-foreground" />
        )}
      </span>
      <span className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="truncate text-[13px] font-medium">{item.title}</span>
        {item.status === "analyzing" && (
          <span className="text-[11px] text-muted-foreground">Analyzing waveform…</span>
        )}
        {item.status === "uploading" && (
          <span className="h-1 overflow-hidden rounded-full bg-foreground/8">
            <span
              className="block h-full rounded-full bg-brand transition-[width] duration-200"
              style={{ width: `${Math.round(item.progress * 100)}%` }}
            />
          </span>
        )}
        {item.status === "saving" && (
          <span className="text-[11px] text-muted-foreground">Saving…</span>
        )}
        {item.status === "error" && (
          <span className="text-[11px] text-destructive">Import failed</span>
        )}
      </span>
    </div>
  )
}
