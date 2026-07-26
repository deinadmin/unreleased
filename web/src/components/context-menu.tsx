import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { createPortal } from "react-dom"
import { cn } from "@/lib/utils"

export interface ContextMenuItem {
  label: string
  icon?: ReactNode
  destructive?: boolean
  disabled?: boolean
  onSelect: () => void
}

interface ContextMenuContextValue {
  /** Opens the custom menu at the pointer position of a `contextmenu` event. */
  open: (event: React.MouseEvent, items: ContextMenuItem[], onClose?: () => void) => void
  /** Opens the custom menu at explicit viewport coordinates. */
  openAt: (x: number, y: number, items: ContextMenuItem[], onClose?: () => void) => void
}

const ContextMenuContext = createContext<ContextMenuContextValue | null>(null)

/**
 * App-wide right-click handling: the native browser menu is suppressed
 * everywhere; components opt in to a styled custom menu via `useContextMenu`.
 */
interface MenuState {
  /** Bumped on every open so the menu node is rebuilt from scratch. */
  id: number
  x: number
  y: number
  items: ContextMenuItem[]
}

export function ContextMenuProvider({ children }: { children: ReactNode }) {
  const [menu, setMenu] = useState<MenuState | null>(null)
  const menuID = useRef(0)
  const menuRef = useRef<HTMLDivElement>(null)
  const onCloseRef = useRef<(() => void) | null>(null)

  const close = useCallback(() => {
    const onClose = onCloseRef.current
    onCloseRef.current = null
    setMenu(null)
    onClose?.()
  }, [])

  const show = useCallback(
    (x: number, y: number, items: ContextMenuItem[], onClose?: () => void) => {
      if (items.length === 0) return
      onCloseRef.current?.()
      onCloseRef.current = onClose ?? null
      setMenu({ id: ++menuID.current, x, y, items })
    },
    [],
  )

  // No right-click menu by default.
  useEffect(() => {
    const suppress = (event: MouseEvent) => event.preventDefault()
    window.addEventListener("contextmenu", suppress)
    return () => window.removeEventListener("contextmenu", suppress)
  }, [])

  const open = useCallback(
    (event: React.MouseEvent, items: ContextMenuItem[], onClose?: () => void) => {
      event.preventDefault()
      show(event.clientX, event.clientY, items, onClose)
    },
    [show],
  )

  const openAt = useCallback(
    (x: number, y: number, items: ContextMenuItem[], onClose?: () => void) => {
      show(x, y, items, onClose)
    },
    [show],
  )

  // The menu mounts hidden at the requested point; this clamps it into the
  // viewport and reveals it, all before the browser paints, so it is never seen
  // at the un-clamped spot. The position is written straight to the node rather
  // than through state, so it can't depend on React managing to render again
  // within the same frame. `offsetWidth`/`offsetHeight` are used because a
  // bounding rect would report the open animation's scaled-down box.
  useLayoutEffect(() => {
    const el = menuRef.current
    if (!menu || !el) return
    const x = Math.max(8, Math.min(menu.x, window.innerWidth - el.offsetWidth - 8))
    const y = Math.max(8, Math.min(menu.y, window.innerHeight - el.offsetHeight - 8))
    el.style.left = `${x}px`
    el.style.top = `${y}px`
    el.style.visibility = "visible"
  }, [menu])

  // Dismiss on outside press, Escape, scroll, or resize.
  useEffect(() => {
    if (!menu) return
    const onPointerDown = (event: PointerEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) close()
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") close()
    }
    window.addEventListener("pointerdown", onPointerDown, true)
    window.addEventListener("keydown", onKey)
    window.addEventListener("scroll", close, true)
    window.addEventListener("resize", close)
    return () => {
      window.removeEventListener("pointerdown", onPointerDown, true)
      window.removeEventListener("keydown", onKey)
      window.removeEventListener("scroll", close, true)
      window.removeEventListener("resize", close)
    }
  }, [close, menu])

  useEffect(() => () => onCloseRef.current?.(), [])

  // Portalled to the body, and mounted only once opened, so a modal dialog's
  // `aria-hidden` sweep (which runs when the dialog opens) never covers it.
  // `pointer-events-auto` restores clicks, since such a dialog switches
  // pointer events off on the body while it is open.
  return (
    <ContextMenuContext.Provider value={{ open, openAt }}>
      {children}
      {menu && createPortal(
        <div
          // Keyed per open so React always rebuilds the node with the hidden
          // starting style, leaving the layout effect free to reveal it.
          key={menu.id}
          ref={menuRef}
          role="menu"
          // `transition-none` matters: `duration-100` is only meant to time the
          // open animation, but it also sets `transition-duration`, and with no
          // transition-property the CSS default of `all` would make the
          // clamped-in left/top slide into place instead of starting there.
          className="pointer-events-auto fixed z-[70] min-w-44 origin-top-left animate-in rounded-xl border bg-popover p-1 text-popover-foreground shadow-xl transition-none duration-100 fade-in-0 zoom-in-95"
          style={{ left: menu.x, top: menu.y, visibility: "hidden" }}
        >
          {menu.items.map((item) => (
            <button
              key={item.label}
              type="button"
              role="menuitem"
              disabled={item.disabled}
              onClick={() => {
                close()
                item.onSelect()
              }}
              className={cn(
                "flex w-full items-center gap-2.5 rounded-lg px-3 py-2 text-left text-[13px] font-medium outline-none transition-colors",
                "disabled:pointer-events-none disabled:opacity-40",
                item.destructive
                  ? "text-destructive hover:bg-destructive/10"
                  : "hover:bg-muted",
              )}
            >
              {item.icon && <span className="[&_svg]:size-4">{item.icon}</span>}
              {item.label}
            </button>
          ))}
        </div>,
        document.body,
      )}
    </ContextMenuContext.Provider>
  )
}

export function useContextMenu(): ContextMenuContextValue {
  const context = useContext(ContextMenuContext)
  if (!context) throw new Error("useContextMenu must be used within ContextMenuProvider")
  return context
}
