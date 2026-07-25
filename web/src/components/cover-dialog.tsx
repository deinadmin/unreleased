import { Check, ImagePlus, Loader2 } from "lucide-react"
import { useRef, useState } from "react"
import { toast } from "sonner"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { useStorageUrl } from "@/hooks/use-storage-url"
import { setProjectCoverImage, setProjectGradient } from "@/lib/project-edits"
import { GRADIENT_PRESETS, gradientCSS, type GradientTheme, type Project } from "@/lib/types"
import { cn } from "@/lib/utils"

/**
 * Cover editor matching the iOS `GradientPickerView`: a photo swatch first,
 * then the preset gradient grid (adaptive 60px cells, white ring + check on
 * the selection). Choices apply immediately.
 */
export function CoverDialog({
  project,
  open,
  onOpenChange,
}: {
  project: Project
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { user } = useAuth()
  const [uploading, setUploading] = useState(false)
  const coverUrl = useStorageUrl(project.coverStoragePath)

  const usesCoverImage = !!project.coverStoragePath

  const isSelected = (theme: GradientTheme) =>
    !usesCoverImage &&
    theme.colors.join() === project.gradient.colors.join() &&
    theme.startX === project.gradient.startX &&
    theme.startY === project.gradient.startY

  const chooseGradient = async (theme: GradientTheme) => {
    if (!user) return
    try {
      await setProjectGradient(user.uid, project, theme)
    } catch {
      toast("Couldn't update the cover. Please try again.")
    }
  }

  const chooseImage = async (file: File) => {
    if (!user) return
    setUploading(true)
    try {
      await setProjectCoverImage(user.uid, project, file)
    } catch (error) {
      console.error("cover upload failed", error)
      toast("Couldn't upload this image. Please try another one.")
    } finally {
      setUploading(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto overflow-x-hidden rounded-3xl p-6 sm:max-w-md">
        <DialogHeader className="min-w-0 pb-4">
          <DialogTitle>Cover</DialogTitle>
        </DialogHeader>

        <CoverPickerGrid
          imageUrl={coverUrl}
          usesImage={usesCoverImage}
          uploading={uploading}
          isThemeSelected={isSelected}
          onPickGradient={(theme) => void chooseGradient(theme)}
          onPickImage={(file) => void chooseImage(file)}
        />
      </DialogContent>
    </Dialog>
  )
}

/**
 * The picker itself (photo swatch + preset gradient grid), shared between the
 * cover editor above and the new-project dialog.
 */
export function CoverPickerGrid({
  imageUrl,
  usesImage,
  uploading = false,
  isThemeSelected,
  onPickGradient,
  onPickImage,
}: {
  imageUrl?: string | null
  usesImage: boolean
  uploading?: boolean
  isThemeSelected: (theme: GradientTheme) => boolean
  onPickGradient: (theme: GradientTheme) => void
  onPickImage: (file: File) => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)

  return (
    <>
      <div className="grid grid-cols-[repeat(auto-fill,minmax(60px,1fr))] gap-3">
        {/* Photo swatch (first cell, like iOS). */}
        <Swatch
          selected={usesImage}
          aria-label="Choose cover photo"
          onClick={() => inputRef.current?.click()}
          className="bg-foreground/8"
        >
          {imageUrl && (
            <img src={imageUrl} alt="" className="absolute inset-0 h-full w-full object-cover" />
          )}
          {!imageUrl && !uploading && (
            <ImagePlus className="size-5.5 text-muted-foreground" />
          )}
          {uploading && (
            <span className="absolute inset-0 flex items-center justify-center bg-black/30">
              <Loader2 className="size-5 animate-spin text-white" />
            </span>
          )}
        </Swatch>

        {GRADIENT_PRESETS.map((theme) => (
          <Swatch
            key={theme.colors.join()}
            selected={isThemeSelected(theme)}
            aria-label={`Gradient ${theme.colors.join(" to ")}`}
            onClick={() => onPickGradient(theme)}
            style={{ background: gradientCSS(theme) }}
          />
        ))}
      </div>

      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={(event) => {
          const file = event.target.files?.[0]
          event.target.value = ""
          if (file) onPickImage(file)
        }}
      />
    </>
  )
}

function Swatch({
  selected,
  onClick,
  className,
  style,
  children,
  ...props
}: {
  selected: boolean
  onClick: () => void
  className?: string
  style?: React.CSSProperties
  children?: React.ReactNode
} & React.AriaAttributes) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={style}
      className={cn(
        "relative flex aspect-square items-center justify-center overflow-hidden rounded-[14px] transition-transform duration-200 active:scale-95",
        selected && "scale-105",
        className,
      )}
      {...props}
    >
      {children}
      {selected && (
        <>
          <span className="pointer-events-none absolute inset-0 rounded-[14px] border-[3px] border-white" />
          <Check className="relative size-3.5 text-white drop-shadow-sm" strokeWidth={3.5} />
        </>
      )}
    </button>
  )
}
