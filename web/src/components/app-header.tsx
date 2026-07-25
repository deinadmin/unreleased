import { Bell } from "lucide-react"
import { Link, useLocation } from "react-router-dom"
import { AppMark } from "@/components/app-mark"
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar"
import { useAuth } from "@/hooks/use-auth"
import { useNotifications } from "@/hooks/use-notifications"

export function AppHeader() {
  const { user, isSignedIn, username } = useAuth()
  const location = useLocation()
  const displayName = username ?? user?.displayName ?? user?.email ?? ""
  const initial = (displayName || "u").charAt(0).toUpperCase()

  return (
    <header className="sticky top-0 z-30 border-b border-border/60 bg-background">
      <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link to="/" className="flex items-center gap-2.5">
          <AppMark className="size-7" />
          <span className="text-[17px] font-bold tracking-tight">unreleased</span>
        </Link>

        {!isSignedIn && (
          <Link
            to={`/welcome?next=${encodeURIComponent(location.pathname)}`}
            className="flex h-9 items-center rounded-full bg-foreground px-4.5 text-[13px] font-bold text-background transition hover:opacity-90 active:scale-[0.98]"
          >
            Sign in
          </Link>
        )}

        {isSignedIn && user && (
          <div className="flex items-center gap-2">
            <NotificationBell />
            <Link
              to="/profile"
              aria-label="Profile"
              className="cursor-default rounded-full outline-none transition hover:opacity-85 focus-visible:ring-2 focus-visible:ring-ring"
            >
              <Avatar className="size-8.5">
                {user.photoURL && <AvatarImage src={user.photoURL} alt={displayName} />}
                <AvatarFallback className="bg-brand/15 text-[13px] font-semibold text-brand">
                  {initial}
                </AvatarFallback>
              </Avatar>
            </Link>
          </div>
        )}
      </div>
    </header>
  )
}

function NotificationBell() {
  const { unreadCount } = useNotifications()
  return (
    <Link
      to="/notifications"
      aria-label={unreadCount > 0 ? `Notifications (${unreadCount} unread)` : "Notifications"}
      className="relative flex size-9 items-center justify-center rounded-full text-foreground/80 transition hover:bg-secondary hover:text-foreground"
    >
      <Bell className="size-4.5" />
      {unreadCount > 0 && (
        <span className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-brand px-1 text-[10px] font-bold text-white">
          {unreadCount > 9 ? "9+" : unreadCount}
        </span>
      )}
    </Link>
  )
}
