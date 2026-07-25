import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./index.css"
import App from "./App"

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
