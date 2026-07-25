import { Check, Copy, Search, X } from "lucide-react"
import { useCallback, useEffect, useRef, useState } from "react"
import { toast } from "sonner"
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Switch } from "@/components/ui/switch"
import { useAuth } from "@/hooks/use-auth"
import {
  cancelInvite,
  ensurePreview,
  fetchPreview,
  inviteUser,
  observeInvitees,
  observePendingInvites,
  removeInvitee,
  searchUsers,
  setLinkEnabled as writeLinkEnabled,
  shareLink,
} from "@/lib/invites"
import { formatRelativeDate } from "@/lib/format"
import { fetchProfilePhotoURL } from "@/lib/profile-photo"
import type { InviteeInfo, PendingInviteInfo, Project, UserSearchResult } from "@/lib/types"

/** Web port of the iOS `ProjectShareSheet`: username invites, link toggle, listeners. */
export function ShareDialog({
  project,
  open,
  onOpenChange,
}: {
  project: Project
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { user, displayUsername } = useAuth()
  const ownerUID = project.ownerID ?? user?.uid ?? ""
  const isOwner = !project.ownerID

  const [linkEnabled, setLinkEnabled] = useState(true)
  const [loadedLinkState, setLoadedLinkState] = useState(false)
  const [updatingLink, setUpdatingLink] = useState(false)
  const [didCopy, setDidCopy] = useState(false)

  const [invitees, setInvitees] = useState<InviteeInfo[]>([])
  const [pendingInvites, setPendingInvites] = useState<PendingInviteInfo[]>([])
  const [loadedListeners, setLoadedListeners] = useState(false)

  const [searchText, setSearchText] = useState("")
  const [searchResults, setSearchResults] = useState<UserSearchResult[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [invitedUIDs, setInvitedUIDs] = useState<Set<string>>(new Set())
  const [invitingUIDs, setInvitingUIDs] = useState<Set<string>>(new Set())
  const [confirmingRemoval, setConfirmingRemoval] = useState<string | null>(null)
  const searchTimer = useRef<ReturnType<typeof setTimeout>>(undefined)

  const link = shareLink(ownerUID, project.id)

  const load = useCallback(async () => {
    if (!user) return
    if (isOwner) await ensurePreview(project, ownerUID, displayUsername)
    const preview = await fetchPreview(ownerUID, project.id)
    setLinkEnabled(preview?.linkEnabled ?? true)
    setLoadedLinkState(true)
  }, [user, isOwner, project, ownerUID, displayUsername])

  useEffect(() => {
    if (!open) return
    setSearchText("")
    setSearchResults([])
    setInvitedUIDs(new Set())
    setConfirmingRemoval(null)
    setLoadedLinkState(false)
    setLoadedListeners(false)
    void load()
  }, [open, load])

  useEffect(() => {
    if (!open || !isOwner || !ownerUID) return
    let inviteesLoaded = false
    let pendingLoaded = false
    const markLoaded = () => {
      if (inviteesLoaded && pendingLoaded) setLoadedListeners(true)
    }
    const stopInvitees = observeInvitees(
      ownerUID,
      project.id,
      (next) => {
        inviteesLoaded = true
        setInvitees(next)
        markLoaded()
      },
      (error) => console.error("invitees listener failed", error),
    )
    const stopPending = observePendingInvites(
      ownerUID,
      project.id,
      (next) => {
        pendingLoaded = true
        setPendingInvites(next)
        markLoaded()
      },
      (error) => console.error("pending invites listener failed", error),
    )
    return () => {
      stopInvitees()
      stopPending()
    }
  }, [open, isOwner, ownerUID, project.id])

  const scheduleSearch = (text: string) => {
    setSearchText(text)
    clearTimeout(searchTimer.current)
    const trimmed = text.trim()
    if (!trimmed) {
      setSearchResults([])
      setIsSearching(false)
      return
    }
    setIsSearching(true)
    searchTimer.current = setTimeout(async () => {
      const results = await searchUsers(trimmed, user?.uid ?? null)
      setSearchResults(results)
      setIsSearching(false)
    }, 300)
  }

  const invite = async (recipient: UserSearchResult) => {
    setInvitingUIDs((prev) => new Set(prev).add(recipient.id))
    try {
      await inviteUser(recipient, project, ownerUID, displayUsername)
      setInvitedUIDs((prev) => new Set(prev).add(recipient.id))
    } catch {
      toast(`Couldn't invite @${recipient.username}. Please try again.`)
    } finally {
      setInvitingUIDs((prev) => {
        const next = new Set(prev)
        next.delete(recipient.id)
        return next
      })
    }
  }

  const toggleLink = async (enabled: boolean) => {
    setUpdatingLink(true)
    setLinkEnabled(enabled)
    try {
      await writeLinkEnabled(enabled, ownerUID, project.id)
    } catch {
      setLinkEnabled(!enabled)
      toast("Couldn't update link sharing. Please try again.")
    } finally {
      setUpdatingLink(false)
    }
  }

  const copyLink = async () => {
    await navigator.clipboard.writeText(link)
    setDidCopy(true)
    setTimeout(() => setDidCopy(false), 2000)
  }

  const removeListener = async (invitee: InviteeInfo) => {
    setConfirmingRemoval(null)
    try {
      await removeInvitee(ownerUID, project.id, invitee.id)
      setInvitees((prev) => prev.filter((i) => i.id !== invitee.id))
    } catch {
      toast(`Couldn't remove @${invitee.username}.`)
    }
  }

  const withdrawInvite = async (pending: PendingInviteInfo) => {
    setConfirmingRemoval(null)
    try {
      await cancelInvite(ownerUID, project.id, pending.id, pending.notificationID)
      setPendingInvites((prev) => prev.filter((p) => p.id !== pending.id))
      setInvitedUIDs((prev) => {
        const next = new Set(prev)
        next.delete(pending.id)
        return next
      })
    } catch {
      toast(`Couldn't withdraw the invite for @${pending.username}.`)
    }
  }

  const totalListeners = invitees.length + pendingInvites.length

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] gap-0 overflow-y-auto overflow-x-hidden rounded-3xl p-6 sm:max-w-md">
        <DialogHeader className="min-w-0 pb-5">
          <DialogTitle>Share Project</DialogTitle>
          <DialogDescription className="truncate">{project.name}</DialogDescription>
        </DialogHeader>

        {isOwner && (
          <section className="min-w-0 pb-6">
            <SectionTitle>Invite people</SectionTitle>
            <div className="flex h-12 items-center gap-2 rounded-[14px] bg-secondary px-3.5">
              <Search className="size-4 shrink-0 text-muted-foreground" />
              <input
                value={searchText}
                onChange={(e) => scheduleSearch(e.target.value)}
                placeholder="Search by username"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                className="h-full w-full bg-transparent text-[15px] outline-none placeholder:text-muted-foreground"
              />
              {searchText && (
                <button
                  type="button"
                  aria-label="Clear search"
                  onClick={() => scheduleSearch("")}
                  className="text-muted-foreground/70 hover:text-foreground"
                >
                  <X className="size-4" />
                </button>
              )}
            </div>

            {searchResults.length > 0 ? (
              <div className="mt-2.5 overflow-hidden rounded-[14px] bg-secondary">
                {searchResults.map((result) => (
                  <div key={result.id} className="flex items-center gap-3 px-4 py-2.5">
                    <InitialCircle
                      userID={result.id}
                      name={result.username}
                      photoURL={result.avatarURL}
                    />
                    <span className="min-w-0 flex-1 truncate text-[15px] font-medium">
                      @{result.username}
                    </span>
                    {invitedUIDs.has(result.id) ||
                    pendingInvites.some((pending) => pending.id === result.id) ||
                    invitees.some((invitee) => invitee.id === result.id) ? (
                      <span className="flex items-center gap-1 text-[13px] font-semibold text-green-600 dark:text-green-500">
                        <Check className="size-3.5" /> Invited
                      </span>
                    ) : invitingUIDs.has(result.id) ? (
                      <span className="text-[13px] text-muted-foreground">Inviting…</span>
                    ) : (
                      <button
                        type="button"
                        onClick={() => void invite(result)}
                        className="rounded-full bg-background px-3.5 py-1.5 text-[13px] font-semibold shadow-sm transition hover:opacity-80 active:scale-95"
                      >
                        Invite
                      </button>
                    )}
                  </div>
                ))}
              </div>
            ) : isSearching ? (
              <p className="px-1 pt-2.5 text-[13px] text-muted-foreground">Searching…</p>
            ) : searchText.trim() ? (
              <p className="px-1 pt-2.5 text-[13px] text-muted-foreground/70">
                No users found for “{searchText.trim()}”
              </p>
            ) : null}
          </section>
        )}

        <section className="min-w-0">
          <SectionTitle>Share link</SectionTitle>

          {isOwner && (
            <>
              <label className="flex items-center justify-between rounded-[14px] bg-secondary px-4 py-3.5">
                <span className="text-[15px]">Enable share link</span>
                <Switch
                  checked={linkEnabled}
                  disabled={!loadedLinkState || updatingLink}
                  onCheckedChange={(checked) => void toggleLink(checked)}
                />
              </label>
              {!linkEnabled && (
                <p className="px-1 pt-1.5 text-[13px] text-muted-foreground">
                  Link disabled. People already in this project keep their access.
                </p>
              )}
            </>
          )}

          <button
            type="button"
            disabled={!linkEnabled}
            onClick={() => void copyLink()}
            className="mt-2.5 flex h-13 w-full min-w-0 max-w-full items-center overflow-hidden rounded-[14px] bg-secondary transition disabled:opacity-55"
          >
            <span className="min-w-0 flex-1 truncate pl-4 text-left font-mono text-[13px] text-muted-foreground">
              {link}
            </span>
            <span className="flex size-13 shrink-0 items-center justify-center">
              {didCopy ? (
                <Check className="size-4 text-green-600 dark:text-green-500" />
              ) : (
                <Copy className="size-4 text-muted-foreground" />
              )}
            </span>
          </button>
          {linkEnabled && (
            <p className="px-1 pt-1.5 text-[13px] text-muted-foreground">
              Anyone with this link can listen — no account needed.
            </p>
          )}
        </section>

        {isOwner && loadedListeners && (
          <section className="min-w-0 pt-6">
            <SectionTitle>
              {totalListeners === 0 ? "No listeners yet" : `Listeners · ${totalListeners}`}
            </SectionTitle>
            {totalListeners > 0 && (
              <div className="overflow-hidden rounded-[14px] bg-secondary">
                {pendingInvites.map((pending) => (
                  <ListenerRow
                    key={pending.id}
                    userID={pending.id}
                    name={pending.username}
                    detail={`invited ${formatRelativeDate(pending.invitedAt)} · pending`}
                    confirmLabel="Cancel invite"
                    confirming={confirmingRemoval === pending.id}
                    onConfirmChange={(next) => setConfirmingRemoval(next ? pending.id : null)}
                    onConfirm={() => void withdrawInvite(pending)}
                  />
                ))}
                {invitees.map((invitee) => (
                  <ListenerRow
                    key={invitee.id}
                    userID={invitee.id}
                    name={invitee.username}
                    detail={`joined ${formatRelativeDate(invitee.acceptedAt)}`}
                    confirmLabel="Remove"
                    confirming={confirmingRemoval === invitee.id}
                    onConfirmChange={(next) => setConfirmingRemoval(next ? invitee.id : null)}
                    onConfirm={() => void removeListener(invitee)}
                  />
                ))}
              </div>
            )}
          </section>
        )}
      </DialogContent>
    </Dialog>
  )
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="pb-2.5 text-[13px] font-semibold text-muted-foreground">{children}</h3>
  )
}

function InitialCircle({
  userID,
  name,
  photoURL,
}: {
  userID: string
  name: string
  photoURL?: string
}) {
  const [resolvedPhotoURL, setResolvedPhotoURL] = useState(photoURL)

  useEffect(() => {
    let active = true
    setResolvedPhotoURL(photoURL)
    if (!photoURL) {
      void fetchProfilePhotoURL(userID).then((url) => {
        if (active) setResolvedPhotoURL(url)
      })
    }
    return () => {
      active = false
    }
  }, [photoURL, userID])

  return (
    <Avatar className="size-8 border-0 after:hidden">
      {resolvedPhotoURL && (
        <AvatarImage src={resolvedPhotoURL} alt="" className="object-cover" />
      )}
      <AvatarFallback className="bg-background text-[13px] font-semibold">
        {(name.charAt(0) || "?").toUpperCase()}
      </AvatarFallback>
    </Avatar>
  )
}

function ListenerRow({
  userID,
  name,
  detail,
  confirmLabel,
  confirming,
  onConfirmChange,
  onConfirm,
}: {
  userID: string
  name: string
  detail: string
  confirmLabel: string
  confirming: boolean
  onConfirmChange: (confirming: boolean) => void
  onConfirm: () => void
}) {
  return (
    <div className="flex items-center gap-3 px-4 py-2.5">
      <InitialCircle userID={userID} name={name} />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-[15px] font-medium">@{name}</span>
        <span className="truncate text-xs text-muted-foreground">{detail}</span>
      </span>
      {confirming ? (
        <span className="flex shrink-0 items-center gap-2">
          <button
            type="button"
            onClick={onConfirm}
            className="rounded-full bg-destructive px-3 py-1.5 text-[13px] font-semibold text-white transition hover:opacity-90"
          >
            {confirmLabel}
          </button>
          <button
            type="button"
            onClick={() => onConfirmChange(false)}
            className="text-[13px] font-medium text-muted-foreground hover:text-foreground"
          >
            Keep
          </button>
        </span>
      ) : (
        <button
          type="button"
          aria-label={`${confirmLabel} @${name}`}
          onClick={() => onConfirmChange(true)}
          className="shrink-0 rounded-full p-2 text-muted-foreground/70 transition hover:bg-background hover:text-destructive"
        >
          <X className="size-4" />
        </button>
      )}
    </div>
  )
}
