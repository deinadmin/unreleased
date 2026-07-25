import { ChevronRight } from "lucide-react"
import type { ReactNode } from "react"
import { Link } from "react-router-dom"
import { cn } from "@/lib/utils"

/** Grouped settings card with an uppercase-ish caption, like iOS inset sections. */
export function SettingsSection({
  title,
  trailing,
  children,
  className,
}: {
  title: string
  /** Optional caption-level accessory on the right of the section title. */
  trailing?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className={cn("min-w-0", className)}>
      <div className="flex items-baseline justify-between gap-3 pb-2.5 pl-1 pr-1">
        <h3 className="text-[13px] font-semibold text-muted-foreground">{title}</h3>
        {trailing}
      </div>
      <div className="overflow-hidden rounded-[14px] bg-secondary">{children}</div>
    </section>
  )
}

export function SettingsDivider() {
  return <div className="ml-14 h-px bg-border/70" />
}

/** iOS-style settings row: icon column, title/subtitle, trailing accessory. */
export function SettingsRow({
  icon,
  iconClassName,
  title,
  titleClassName,
  subtitle,
  value,
  trailing,
  chevron = false,
  to,
  href,
  onClick,
  disabled = false,
}: {
  icon: ReactNode
  iconClassName?: string
  title: string
  titleClassName?: string
  subtitle?: string
  value?: string
  trailing?: ReactNode
  chevron?: boolean
  to?: string
  href?: string
  onClick?: () => void
  disabled?: boolean
}) {
  const content = (
    <>
      <span
        className={cn("flex w-7 shrink-0 items-center justify-center text-muted-foreground", iconClassName)}
      >
        {icon}
      </span>
      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className={cn("text-left text-[15px]", titleClassName)}>{title}</span>
        {subtitle && (
          <span className="text-left text-[13px] leading-snug text-muted-foreground">
            {subtitle}
          </span>
        )}
      </span>
      {value && <span className="shrink-0 text-[14px] text-muted-foreground">{value}</span>}
      {trailing}
      {chevron && <ChevronRight className="size-3.5 shrink-0 text-muted-foreground/50" />}
    </>
  )
  const rowClass = cn(
    "flex w-full items-center gap-3 px-4 py-3.5 transition-colors",
    (to || href || onClick) && !disabled && "hover:bg-foreground/4",
    disabled && "opacity-60",
  )

  if (to && !disabled) {
    return (
      <Link to={to} className={rowClass}>
        {content}
      </Link>
    )
  }
  if (href && !disabled) {
    return (
      <a href={href} target={href.startsWith("mailto:") ? undefined : "_blank"} rel="noreferrer" className={rowClass}>
        {content}
      </a>
    )
  }
  if (onClick && !disabled) {
    return (
      <button type="button" onClick={onClick} className={rowClass}>
        {content}
      </button>
    )
  }
  return <div className={rowClass}>{content}</div>
}

/** Back chevron + page title, shared by the profile subpages. */
export function SettingsPageHeader({ backTo, backLabel, title }: { backTo: string; backLabel: string; title: string }) {
  return (
    <>
      <div className="flex h-12 items-center">
        <Link
          to={backTo}
          className="-ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
        >
          <ChevronRight className="size-4.5 rotate-180" />
          {backLabel}
        </Link>
      </div>
      <h1 className="pb-6 pt-2 text-[22px] font-bold">{title}</h1>
    </>
  )
}
