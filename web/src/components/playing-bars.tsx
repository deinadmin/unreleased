/** Three animated equalizer bars, matching the iOS `PlayingBarsIndicator`. */
export function PlayingBars({ color, paused = false }: { color: string; paused?: boolean }) {
  return (
    <div className="flex h-4 items-center gap-[2px]">
      {[
        { height: 0.6, duration: 0.52, delay: 0.09 },
        { height: 1.0, duration: 0.6, delay: 0.15 },
        { height: 0.75, duration: 0.55, delay: 0.11 },
      ].map((bar, i) => (
        <span
          key={i}
          className="playing-bar w-[3px] rounded-[1.5px]"
          style={{
            height: `${bar.height * 16}px`,
            background: color,
            animationDuration: `${bar.duration}s`,
            animationDelay: `${bar.delay}s`,
            animationPlayState: paused ? "paused" : "running",
          }}
        />
      ))}
    </div>
  )
}
