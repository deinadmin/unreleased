export const notificationsProjectNavigationState = {
  projectEntryPoint: "notifications",
} as const

export function projectBackLink(state: unknown): { to: string; label: string } {
  if (
    typeof state === "object" &&
    state !== null &&
    "projectEntryPoint" in state &&
    state.projectEntryPoint === "notifications"
  ) {
    return { to: "/notifications", label: "Notifications" }
  }

  return { to: "/", label: "Library" }
}
