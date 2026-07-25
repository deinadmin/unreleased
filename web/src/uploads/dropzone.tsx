import { Upload } from "lucide-react"
import { useRef, useState, type ReactNode } from "react"

export const AUDIO_ACCEPT = ".mp3,.m4a,.wav,.aiff,.aif,.flac,.aac,audio/*"

/**
 * Wraps a page in a drag-and-drop target for audio files and provides a
 * hidden file input via the `openPicker` render argument.
 */
export function AudioDropzone({
  disabled = false,
  overlayLabel,
  onFiles,
  children,
}: {
  disabled?: boolean
  overlayLabel: string
  onFiles: (files: File[]) => void
  children: (openPicker: () => void) => ReactNode
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const dragDepth = useRef(0)
  const [dragging, setDragging] = useState(false)

  const openPicker = () => inputRef.current?.click()

  if (disabled) return <>{children(openPicker)}</>

  return (
    <div
      className="relative min-h-dvh"
      onDragEnter={(event) => {
        if (!event.dataTransfer.types.includes("Files")) return
        event.preventDefault()
        dragDepth.current++
        setDragging(true)
      }}
      onDragOver={(event) => {
        if (!event.dataTransfer.types.includes("Files")) return
        event.preventDefault()
      }}
      onDragLeave={() => {
        dragDepth.current = Math.max(0, dragDepth.current - 1)
        if (dragDepth.current === 0) setDragging(false)
      }}
      onDrop={(event) => {
        event.preventDefault()
        dragDepth.current = 0
        setDragging(false)
        const files = Array.from(event.dataTransfer.files)
        if (files.length > 0) onFiles(files)
      }}
    >
      {children(openPicker)}

      <input
        ref={inputRef}
        type="file"
        accept={AUDIO_ACCEPT}
        multiple
        className="hidden"
        onChange={(event) => {
          const files = Array.from(event.target.files ?? [])
          event.target.value = ""
          if (files.length > 0) onFiles(files)
        }}
      />

      {dragging && (
        <div className="pointer-events-none fixed inset-0 z-50 flex items-center justify-center bg-background/80 backdrop-blur-sm">
          <div className="flex flex-col items-center gap-3 rounded-3xl border-2 border-dashed border-brand/60 bg-secondary/80 px-12 py-10">
            <Upload className="size-8 text-brand" />
            <p className="text-[15px] font-semibold">{overlayLabel}</p>
          </div>
        </div>
      )}
    </div>
  )
}
