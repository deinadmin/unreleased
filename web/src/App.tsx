import { lazy, Suspense, useLayoutEffect } from "react"
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom"
import { AppMark } from "@/components/app-mark"
import { ContextMenuProvider } from "@/components/context-menu"
import { PlayerDock } from "@/components/player-dock"
import { Toaster } from "@/components/toaster"
import { TooltipProvider } from "@/components/ui/tooltip"
import { AuthProvider, useAuth } from "@/hooks/use-auth"
import { NotificationsProvider } from "@/hooks/use-notifications"
import { ProjectsProvider } from "@/hooks/use-projects"
import { ChooseUsernamePage } from "@/pages/choose-username"
import { EqualizerProvider } from "@/player/equalizer-provider"
import { PlayerProvider } from "@/player/player-provider"
import { UploadsCard } from "@/uploads/uploads-card"
import { UploadsProvider } from "@/uploads/uploads-provider"

const DeleteTracksPage = lazy(() =>
  import("@/pages/delete-tracks").then((module) => ({ default: module.DeleteTracksPage })),
)
const EmailAuthPage = lazy(() =>
  import("@/pages/email-auth").then((module) => ({ default: module.EmailAuthPage })),
)
const LibraryPage = lazy(() =>
  import("@/pages/library").then((module) => ({ default: module.LibraryPage })),
)
const NotificationsPage = lazy(() =>
  import("@/pages/notifications").then((module) => ({ default: module.NotificationsPage })),
)
const ProfilePage = lazy(() =>
  import("@/pages/profile").then((module) => ({ default: module.ProfilePage })),
)
const ProfileAboutPage = lazy(() =>
  import("@/pages/profile-about").then((module) => ({ default: module.ProfileAboutPage })),
)
const ProfileEqPage = lazy(() =>
  import("@/pages/profile-eq").then((module) => ({ default: module.ProfileEqPage })),
)
const ProfileNotificationsPage = lazy(() =>
  import("@/pages/profile-notifications").then((module) => ({
    default: module.ProfileNotificationsPage,
  })),
)
const ProfilePlaybackPage = lazy(() =>
  import("@/pages/profile-playback").then((module) => ({
    default: module.ProfilePlaybackPage,
  })),
)
const ProfileStoragePage = lazy(() =>
  import("@/pages/profile-storage").then((module) => ({ default: module.ProfileStoragePage })),
)
const ProjectPage = lazy(() =>
  import("@/pages/project").then((module) => ({ default: module.ProjectPage })),
)
const SharedProjectPage = lazy(() =>
  import("@/pages/shared").then((module) => ({ default: module.SharedProjectPage })),
)
const TrackNotesPage = lazy(() =>
  import("@/pages/track-notes").then((module) => ({ default: module.TrackNotesPage })),
)
const WelcomePage = lazy(() =>
  import("@/pages/welcome").then((module) => ({ default: module.WelcomePage })),
)

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
            <EqualizerProvider>
            <UploadsProvider>
              <TooltipProvider>
                <BrowserRouter>
                <ContextMenuProvider>
                <ScrollToTop />
                <Suspense fallback={<Splash />}>
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
                    path="/profile/playback"
                    element={
                      <RequireAuth>
                        <ProfilePlaybackPage />
                      </RequireAuth>
                    }
                  />
                  <Route
                    path="/profile/eq"
                    element={
                      <RequireAuth>
                        <ProfileEqPage />
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
                    path="/profile/storage/delete-tracks"
                    element={
                      <RequireAuth>
                        <DeleteTracksPage />
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
                </Suspense>
                <PlayerDock />
                </ContextMenuProvider>
              </BrowserRouter>
              {/* The upload card is pinned to the bottom of the toast stack. */}
              <Toaster>
                <UploadsCard />
              </Toaster>
              </TooltipProvider>
            </UploadsProvider>
            </EqualizerProvider>
          </PlayerProvider>
        </NotificationsProvider>
      </ProjectsProvider>
    </AuthProvider>
  )
}
