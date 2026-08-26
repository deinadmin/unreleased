import { Bell, CheckCircle2, ChevronLeft, ChevronRight, Trash2 } from "lucide-react"
import { Link, useNavigate } from "react-router-dom"
import { AppHeader } from "@/components/app-header"
import { CloudProjectCover } from "@/components/project-cover"
import { useNotifications } from "@/hooks/use-notifications"
import { formatRelativeDate } from "@/lib/format"
import { notificationsProjectNavigationState } from "@/lib/project-navigation"
import type { AppNotification } from "@/lib/types"

export function NotificationsPage() {
  const { notifications, unreadCount, markRead, markAllRead, remove } = useNotifications()
  const navigate = useNavigate()

  const open = (notification: AppNotification) => {
    markRead(notification)
    if (notification.kind === "projectInvite") {
      navigate(`/shared/${notification.fromUID}/${notification.projectID.toLowerCase()}`, {
        state: notificationsProjectNavigationState,
      })
    }
  }

  return (
    <div className="min-h-dvh">
      <AppHeader />

      <main className="mx-auto w-full max-w-2xl px-4 pb-36 sm:px-6">
        <div className="flex h-12 items-center justify-between">
          <Link
            to="/"
            className="-ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
          >
            <ChevronLeft className="size-4.5" />
            Library
          </Link>

          {unreadCount > 0 && (
            <button
              type="button"
              onClick={markAllRead}
              className="flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm font-medium text-muted-foreground transition hover:text-foreground"
            >
              <CheckCircle2 className="size-4" />
              Mark all read
            </button>
          )}
        </div>

        <h1 className="pb-5 pt-2 text-[22px] font-bold">Notifications</h1>

        {notifications.length === 0 ? (
          <div className="rise-in flex flex-col items-center pt-[16vh] text-center">
            <Bell className="size-10 text-muted-foreground/40" />
            <p className="pt-4 text-[17px] font-semibold">No notifications</p>
            <p className="max-w-64 pt-1.5 text-sm text-muted-foreground">
              Invites and project activity will show up here.
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-2.5">
            {notifications.map((notification, i) => (
              <div
                key={notification.id}
                className="rise-in group relative"
                style={{ animationDelay: `${Math.min(i, 10) * 0.03}s` }}
              >
                <button
                  type="button"
                  onClick={() => open(notification)}
                  className="flex w-full items-center gap-3 rounded-2xl bg-secondary p-3.5 text-left transition hover:bg-secondary/70"
                >
                  {notification.kind === "projectInvite" ? (
                    <CloudProjectCover
                      name={notification.projectName}
                      gradient={
                        notification.projectGradient ?? {
                          colors: ["#667EEA", "#764BA2"],
                          startX: 0,
                          startY: 0,
                          endX: 1,
                          endY: 1,
                        }
                      }
                      coverStoragePath={notification.coverStoragePath}
                      className="size-10 shrink-0"
                    />
                  ) : (
                    <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-background">
                      <Bell className="size-4.5" />
                    </span>
                  )}

                  <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                    <span className="text-[15px] font-semibold leading-snug">
                      {notification.kind === "projectInvite" ? (
                        <>
                          @{notification.fromUsername} invited you to “{notification.projectName}”
                        </>
                      ) : (
                        notification.projectName
                      )}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {formatRelativeDate(notification.createdAt)}
                    </span>
                  </span>

                  {!notification.read && <span className="size-2 shrink-0 rounded-full bg-brand" />}
                  <ChevronRight className="size-3.5 shrink-0 text-muted-foreground/50" />
                </button>

                <button
                  type="button"
                  aria-label="Delete notification"
                  onClick={() => remove(notification)}
                  className="absolute -right-2 -top-2 hidden size-7 items-center justify-center rounded-full bg-background text-muted-foreground shadow-md transition hover:text-destructive group-hover:flex"
                >
                  <Trash2 className="size-3.5" />
                </button>
              </div>
            ))}
          </div>
        )}
      </main>
    </div>
  )
}
