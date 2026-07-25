import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./index.css"
import App from "./App"

// The media worker keeps immutable project covers and songs that have actually
// been played in browser storage. Register before rendering so returning visits
// are cache-controlled immediately.
if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register("/project-cover-cache-sw.js").catch(() => {})
}

// Follow the system appearance, matching the iOS app.
const darkMedia = window.matchMedia("(prefers-color-scheme: dark)")
const applyAppearance = () =>
  document.documentElement.classList.toggle("dark", darkMedia.matches)
applyAppearance()
darkMedia.addEventListener("change", applyAppearance)

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
