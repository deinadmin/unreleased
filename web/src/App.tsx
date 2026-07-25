import { useLayoutEffect } from "react"
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom"
import { Toaster } from "sonner"
import { AppMark } from "@/components/app-mark"
import { ContextMenuProvider } from "@/components/context-menu"
import { PlayerDock } from "@/components/player-dock"
import { TooltipProvider } from "@/components/ui/tooltip"
import { AuthProvider, useAuth } from "@/hooks/use-auth"
import { NotificationsProvider } from "@/hooks/use-notifications"
import { ProjectsProvider } from "@/hooks/use-projects"
import { ChooseUsernamePage } from "@/pages/choose-username"
import { EmailAuthPage } from "@/pages/email-auth"
import { LibraryPage } from "@/pages/library"
import { NotificationsPage } from "@/pages/notifications"
import { ProfilePage } from "@/pages/profile"
import { ProfileAboutPage } from "@/pages/profile-about"
import { ProfileNotificationsPage } from "@/pages/profile-notifications"
import { ProfileStoragePage } from "@/pages/profile-storage"
import { ProjectPage } from "@/pages/project"
import { SharedProjectPage } from "@/pages/shared"
import { TrackNotesPage } from "@/pages/track-notes"
import { WelcomePage } from "@/pages/welcome"
import { PlayerProvider } from "@/player/player-provider"
import { UploadsCard } from "@/uploads/uploads-card"
import { UploadsProvider } from "@/uploads/uploads-provider"

function RequireAuth({ children }: { children: React.ReactNode }) {
  const { isSignedIn, initializing, username, usernameLoaded } = useAuth()
  if (initializing) return <Splash />
  if (!isSignedIn) return <Navigate to="/welcome" replace />
  if (!usernameLoaded) return <Splash />
  // First sign-in: claim a username before entering the app.
  if (!username) return <ChooseUsernamePage />
  return <>{children}</>
}

/** Starts every route at the top instead of inheriting the previous scroll. */
function ScrollToTop() {
  const { pathname } = useLocation()
  useLayoutEffect(() => {
    window.scrollTo(0, 0)
  }, [pathname])
  return null
}

function Splash() {
  return (
    <div className="flex min-h-dvh items-center justify-center">
      <AppMark className="size-24 animate-pulse" />
    </div>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <ProjectsProvider>
        <NotificationsProvider>
          <PlayerProvider>
            <UploadsProvider>
              <TooltipProvider>
                <BrowserRouter>
                <ContextMenuProvider>
                <ScrollToTop />
                <Routes>
                  <Route path="/welcome" element={<WelcomePage />} />
                  <Route path="/welcome/email" element={<EmailAuthPage />} />
                  <Route path="/shared/:ownerId/:projectId" element={<SharedProjectPage />} />
                  <Route
                    path="/"
                    element={
                      <RequireAuth>
                        <LibraryPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/project/:projectId"
                    element={
                      <RequireAuth>
                        <ProjectPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/project/:projectId/notes/:trackId"
                    element={
                      <RequireAuth>
                        <TrackNotesPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/notifications"
                    element={
                      <RequireAuth>
                        <NotificationsPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/profile"
                    element={
                      <RequireAuth>
                        <ProfilePage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/profile/notifications"
                    element={
                      <RequireAuth>
                        <ProfileNotificationsPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/profile/storage"
                    element={
                      <RequireAuth>
                        <ProfileStoragePage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/profile/about"
                    element={
                      <RequireAuth>
                        <ProfileAboutPage />
                      </RequireAuth>
                    }
                  />
                  <Route path="*" element={<Navigate to="/" replace />} />
                </Routes>
                <PlayerDock />
                <UploadsCard />
                </ContextMenuProvider>
              </BrowserRouter>
              <Toaster position="top-center" />
              </TooltipProvider>
            </UploadsProvider>
          </PlayerProvider>
        </NotificationsProvider>
      </ProjectsProvider>
    </AuthProvider>
  )
}
