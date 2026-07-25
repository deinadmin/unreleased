import { Loader2 } from "lucide-react"
import { useEffect, useState } from "react"
import { toast } from "sonner"
import { CoverPickerGrid } from "@/components/cover-dialog"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { createProject, setProjectCoverImage } from "@/lib/project-edits"
import { randomGradient, type GradientTheme } from "@/lib/types"

/**
 * New project dialog: a seamless heading-style title input above the same
 * cover picker the edit dialog uses. Choices stay local until "Create"
 * (or Enter in the title input) writes the project.
 */
export function NewProjectDialog({
  open,
  onOpenChange,
  onCreated,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  onCreated: (projectID: string) => void
}) {
  const { user } = useAuth()
  const [title, setTitle] = useState("")
  const [gradient, setGradient] = useState<GradientTheme>(randomGradient)
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  // Fresh draft every time the dialog opens.
  useEffect(() => {
    if (!open) return
    setTitle("")
    setGradient(randomGradient())
    setImageFile(null)
    setCreating(false)
  }, [open])

  // Local preview for a picked cover photo.
  useEffect(() => {
    if (!imageFile) {
      setImageUrl(null)
      return
    }
    const url = URL.createObjectURL(imageFile)
    setImageUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [imageFile])

  const isSelected = (theme: GradientTheme) =>
    !imageFile &&
    theme.colors.join() === gradient.colors.join() &&
    theme.startX === gradient.startX &&
    theme.startY === gradient.startY

  const create = async () => {
    if (!user || creating) return
    setCreating(true)
    try {
      const project = await createProject(user.uid, title, gradient)
      if (imageFile) {
        // The project exists either way; a failed cover upload shouldn't block it.
        await setProjectCoverImage(user.uid, project, imageFile).catch((error) => {
          console.error("cover upload failed", error)
          toast("Couldn't upload the cover image. You can set it again from the project.")
        })
      }
      onOpenChange(false)
      onCreated(project.id)
    } catch (error) {
      console.error("creating project failed", error)
      toast("Couldn't create the project. Please try again.")
      setCreating(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto overflow-x-hidden rounded-3xl p-6 sm:max-w-md [--dialog-close-inset:calc(var(--radius-3xl)-0.875rem)]">
        <DialogTitle className="sr-only">New project</DialogTitle>

        <form
          onSubmit={(event) => {
            event.preventDefault()
            void create()
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
            imageUrl={imageUrl}
            usesImage={!!imageFile}
            isThemeSelected={isSelected}
            onPickGradient={(theme) => {
              setGradient(theme)
              setImageFile(null)
            }}
            onPickImage={setImageFile}
          />

          <button
            type="submit"
            disabled={creating}
            className="mt-6 flex h-11 w-full items-center justify-center gap-2 rounded-full bg-brand text-[14px] font-semibold text-white transition hover:bg-brand/85 active:scale-[0.99] disabled:opacity-60"
          >
            {creating && <Loader2 className="size-4 animate-spin" />}
            Create project
          </button>
        </form>
      </DialogContent>
    </Dialog>
  )
}
