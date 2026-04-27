# 摸鱼侠 — Worker Toolkit for MioIsland

Office-survival toolkit in your notch. Five tabs cover the everyday
rhythm of a desk job: pomodoro focus, sit-up reminder, water
hydration tracker, clock-out countdown, and weekend countdown.

100% local. No network, no API keys, no telemetry.

## Features

- **🍅 番茄钟** — 25/5 minute focus/break cycles, big circular ring
  timer, pause/resume/reset, today's pomodoro tally + focus minutes,
  ±5min and ±1min steppers.
- **🪑 久坐提醒** — count-up "已坐 X 分钟" since you last broke,
  configurable trigger interval (default 45 min), red status pill
  + dock bounce when you cross the threshold.
- **💧 喝水追踪** — animated water-level cup glyph, today's tally
  with progress dots, 加一杯 / 撤销 buttons, configurable goal
  (default 8 cups).
- **🏃 下班倒计时** — live H:M:S countdown to your clock-out hour,
  gradient bar fills 0→1 across a 9-hour anchor, in-panel hour and
  minute steppers.
- **🎉 周末倒数** — 天/时/分 to next Saturday 00:00 with a rotating
  打工语录 that's stable per day.

## Notifications

Uses `UNUserNotificationCenter` for sit-up and pomodoro alerts. If
notification authorization is denied, falls back to
`NSApp.requestUserAttention(.criticalRequest)` — your dock icon
bounces and the menu bar status dot flips red, so the reminder
never silently misses.

## Persistence

All preferences stored in `UserDefaults(suiteName: "com.mioisland.plugin.worker")`:
- Pomodoro count history (per-date dict)
- Focus / break minute settings
- Sit-up start timestamp + trigger interval
- Water cups today + daily goal
- Clock-out time (HH:mm)

## Requirements

- macOS 15.0+
- MioIsland v2.2.0+

## Building from source

```bash
./build.sh           # produce build/worker.bundle + build/worker.zip
./build.sh install   # build + copy to ~/.config/codeisland/plugins/
```

Restart MioIsland (Cmd+Q + reopen) to load the new build.

## Structure

```
Sources/
├── MioPlugin.swift             # protocol (verbatim from host)
├── WorkerPlugin.swift          # principal class
├── ui/
│   ├── ExpandedView.swift      # 380×620 panel + 5-tab pill strip
│   ├── PomodoroView.swift      # circular ring timer
│   ├── SitView.swift           # count-up + threshold alert
│   ├── WaterView.swift         # animated cup with water fill
│   ├── ClockoutView.swift      # gradient countdown bar
│   ├── WeekendView.swift       # purple hero countdown
│   └── Theme.swift             # design tokens
└── engine/
    ├── WorkerStore.swift       # @MainActor state surface, 1Hz tick
    ├── NotificationCenter.swift # UN wrapper + dock bounce fallback
    └── WorkerDebugLog.swift    # /tmp/worker-plugin.log
```

## License

MIT — see [LICENSE](LICENSE).
