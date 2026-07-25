import { ArrowUpRight, Link as LinkIcon, User } from "lucide-react"
import { AppHeader } from "@/components/app-header"
import { AppMark } from "@/components/app-mark"
import { SettingsDivider, SettingsPageHeader, SettingsRow, SettingsSection } from "@/components/settings"
import { APP_VERSION } from "@/lib/app-meta"

interface OpenSourceLibrary {
  name: string
  description: string
  license: string
  url: string
}

const OPEN_SOURCE_LIBRARIES: OpenSourceLibrary[] = [
  {
    name: "Firebase JS SDK",
    description: "Auth, Firestore & Cloud Storage",
    license: "Apache 2.0",
    url: "https://github.com/firebase/firebase-js-sdk",
  },
  {
    name: "React",
    description: "User interface library",
    license: "MIT",
    url: "https://github.com/facebook/react",
  },
  {
    name: "Tailwind CSS",
    description: "Utility-first styling",
    license: "MIT",
    url: "https://github.com/tailwindlabs/tailwindcss",
  },
  {
    name: "shadcn/ui",
    description: "Accessible UI components",
    license: "MIT",
    url: "https://github.com/shadcn-ui/ui",
  },
  {
    name: "Lucide",
    description: "Icon set",
    license: "ISC",
    url: "https://github.com/lucide-icons/lucide",
  },
]

/** Web port of the iOS `AboutView`. */
export function ProfileAboutPage() {
  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-lg px-5 pb-40">
        <SettingsPageHeader backTo="/profile" backLabel="Profile" title="About" />

        <div className="rise-in flex flex-col items-center pb-9 pt-2 text-center">
          <AppMark className="size-20" />
          <h2 className="pt-4 text-[22px] font-bold">unreleased</h2>
          <p className="pt-1 text-[15px] text-muted-foreground">Version {APP_VERSION}</p>
        </div>

        <SettingsSection title="Developer" className="rise-in">
          <SettingsRow
            icon={<User className="size-4" />}
            title="Carl Steen"
            subtitle="Design & Development"
          />
          <SettingsDivider />
          <SettingsRow
            icon={<LinkIcon className="size-4" />}
            title="@deinadmin on GitHub"
            trailing={<ArrowUpRight className="size-3.5 shrink-0 text-muted-foreground/50" />}
            href="https://github.com/deinadmin"
          />
        </SettingsSection>

        <SettingsSection title="Open Source Libraries" className="rise-in mt-6">
          {OPEN_SOURCE_LIBRARIES.map((library, index) => (
            <span key={library.name}>
              {index > 0 && <div className="ml-4 h-px bg-border/70" />}
              <a
                href={library.url}
                target="_blank"
                rel="noreferrer"
                className="flex items-start gap-3 px-4 py-3.5 transition-colors hover:bg-foreground/4"
              >
                <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                  <span className="text-[15px] font-semibold">{library.name}</span>
                  <span className="text-[13px] leading-snug text-muted-foreground">
                    {library.description}
                  </span>
                </span>
                <span className="flex shrink-0 flex-col items-end gap-1.5">
                  <span className="rounded-full bg-foreground/6 px-2 py-0.5 text-[11px] font-semibold tracking-[0.2px] text-muted-foreground">
                    {library.license}
                  </span>
                  <ArrowUpRight className="size-3 text-muted-foreground/50" />
                </span>
              </a>
            </span>
          ))}
        </SettingsSection>
      </main>
    </div>
  )
}
