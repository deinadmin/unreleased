import { Loader2 } from "lucide-react"
import { useEffect, useState } from "react"
import { toast } from "sonner"
import { CoverPickerGrid } from "@/components/cover-dialog"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { useStorageUrl } from "@/hooks/use-storage-url"
import {
  setProjectCoverImage,
  setProjectGradient,
  updateProjectName,
} from "@/lib/project-edits"
import type { GradientTheme, Project } from "@/lib/types"

export function EditProjectDialog({
  project,
  open,
  onOpenChange,
}: {
  project: Project
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { user } = useAuth()
  const existingCoverUrl = useStorageUrl(project.coverStoragePath)
  const [title, setTitle] = useState(project.name)
  const [gradient, setGradient] = useState(project.gradient)
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const [keepsExistingImage, setKeepsExistingImage] = useState(!!project.coverStoragePath)
  const [coverChanged, setCoverChanged] = useState(false)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!open) return
    setTitle(project.name)
    setGradient(project.gradient)
    setImageFile(null)
    setKeepsExistingImage(!!project.coverStoragePath)
    setCoverChanged(false)
    setSaving(false)
  }, [open, project.id])

  useEffect(() => {
    if (!imageFile) {
      setImageUrl(null)
      return
    }
    const url = URL.createObjectURL(imageFile)
    setImageUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [imageFile])

  const usesImage = !!imageFile || keepsExistingImage
  const selectedImageUrl = imageUrl ?? (keepsExistingImage ? existingCoverUrl : null)
  const isThemeSelected = (theme: GradientTheme) =>
    !usesImage &&
    theme.colors.join() === gradient.colors.join() &&
    theme.startX === gradient.startX &&
    theme.startY === gradient.startY

  const save = async () => {
    if (!user || saving) return
    setSaving(true)
    try {
      await updateProjectName(user.uid, project, title)
      if (coverChanged && imageFile) {
        await setProjectCoverImage(user.uid, project, imageFile)
      } else if (coverChanged && !keepsExistingImage) {
        await setProjectGradient(user.uid, project, gradient)
      }
      onOpenChange(false)
    } catch (error) {
      console.error("updating project failed", error)
      toast("Couldn't update the project. Please try again.")
      setSaving(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto overflow-x-hidden rounded-3xl p-6 sm:max-w-md [--dialog-close-inset:calc(var(--radius-3xl)-0.875rem)]">
        <DialogTitle className="sr-only">Edit project</DialogTitle>
        <form
          onSubmit={(event) => {
            event.preventDefault()
            void save()
          }}
        >
          <input
            autoFocus
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="Project title"
            aria-label="Project title"
            className="w-full border-none bg-transparent pb-5 text-left text-[22px] font-bold outline-none placeholder:text-muted-foreground/50"
          />

          <CoverPickerGrid
            imageUrl={selectedImageUrl}
            usesImage={usesImage}
            isThemeSelected={isThemeSelected}
            onPickGradient={(theme) => {
              setGradient(theme)
              setImageFile(null)
              setKeepsExistingImage(false)
              setCoverChanged(true)
            }}
            onPickImage={(file) => {
              setImageFile(file)
              setKeepsExistingImage(false)
              setCoverChanged(true)
            }}
          />

          <button
            type="submit"
            disabled={saving}
            className="mt-6 flex h-11 w-full items-center justify-center gap-2 rounded-full bg-brand text-[14px] font-semibold text-white transition hover:bg-brand/85 active:scale-[0.99] disabled:opacity-60"
          >
            {saving && <Loader2 className="size-4 animate-spin" />}
            Save changes
          </button>
        </form>
      </DialogContent>
    </Dialog>
  )
}
