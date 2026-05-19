# 摸鱼侠 — 代码质量 Review

**日期**: 2026-05-19
**审视分支**: main @ `0cff83fc` ("feat: v0.2.0 — sleep-aware timers + auto-loop pomodoro")
**源码规模**: 13 Swift 文件，~1500 行；WorkerStore 700 行最大
**测试**: 0（无 XCTest target，无测试文件）

---

## 一、架构 — 8/10

```
engine/
  WorkerStore.swift          700-行单体 state + tick + 5 feature 逻辑
  NotificationCenter.swift   UN wrapper + dock fallback
  SystemIdle.swift           CGEvent input-idle 探测
  WorkerDebugLog.swift       /tmp/worker-plugin.log
ui/
  ExpandedView.swift         5-tab shell
  PomodoroView/SitView/WaterView/ClockoutView/WeekendView.swift
  Theme.swift                色彩 token + WorkerFormat helpers
WorkerPlugin.swift           主类
```

比看盘侠少一层 `data/` — 因为 100% 本地无网络，不需要 actor client。

### 问题 1：WorkerStore 是 god object

700 行包含 pomodoro state machine + sit accumulator + water counter + clockout time + weekend countdown + 全部持久化。每 feature 逻辑都在 store 里。当前 OK 因为单体跑得通，长期 `tickFire()` 会膨胀。

**重构方向 P2**（不阻塞 ship）：
```
PomodoroStore : ObservableObject
SitStore      : ObservableObject
WaterStore    : ObservableObject
ClockoutStore : ObservableObject
WeekendCalculator
WorkerStore   只负责 orchestrate 1Hz tick 分发 + persistence routing
```

---

## 二、状态管理 — 9/10（最大亮点）

### 🌟 亮点 1：pomodoro 用 wallclock endsAt 而非 counter

`WorkerStore.swift:108 private var pomodoroPhaseEndsAt: Date?`。tick 每次算 `remaining = endsAt - now`。

**含义**：Mac 睡了 / quit / 关 panel / 重启 都不影响倒计时正确性（按现实流逝）。比天真版"每秒减 1"强多了。

```swift
// WorkerStore.swift:203-207
if let endsAt = pomodoroPhaseEndsAt,
   pomodoroPhase == .focus || pomodoroPhase == .rest {
    let remaining = max(0, Int(endsAt.timeIntervalSinceNow))
    pomodoroRemaining = remaining
    ...
}
```

### 🌟 亮点 2：paused 持久化

`WorkerStore.swift:584-624` — paused phase 在 launch 时检测到 `savedPhase == .paused` 跳过 endsAt 计算，直接 resume 到上次 pause 时的 remaining。**正确**。

### 🌟 亮点 3：sit accumulator 用 input-idle，不用 timestamp

`WorkerStore.swift:225-244` sit 增长依赖 `SystemIdle.seconds < 60`，> 5 min idle reset。配合 `didSleepWake` (wallclock gap > 30s) 检测 → 三层保护。

```swift
// 三层 reset:
if didSleepWake { ... }                              // 1. Mac 睡了
else if idle >= sitBreakResetThresholdSec { ... }    // 2. 离开 ≥ 5min
else if idle < 60 { sitAccumActiveSec += 1 }         // 3. 真在打字
// idle 1-5 min：hold steady（开会/打电话不归零也不+）
```

**比市面上"久坐提醒"app 都准**。

### 🔴 问题 1：PomodoroView 进度环 fraction 在 paused-in-break 算错

`PomodoroView.swift:118-128`：
```swift
private var progressFraction: CGFloat {
    let total: Int
    switch store.pomodoroPhase {
    case .focus:           total = store.pomodoroFocusMin * 60
    case .rest:            total = store.pomodoroBreakMin * 60
    case .paused, .idle:   total = store.pomodoroFocusMin * 60  // ← BUG
    }
    ...
}
```

paused 状态下 `total` 永远当 focus 时长。但用户可能在 **break 中按了暂停**（`pomodoroPause()` 在 focus/rest 都允许）。这时 `pausedRemaining` 是 break 的剩余，total 是 focusMin × 60 — fraction 算错（分母不对）。

**修法**：暴露 store.pausedPhase 给 view 或在 store 提供 `pomodoroPhaseTotalSec` computed：
```swift
var pomodoroPhaseTotalSec: Int {
    switch pomodoroPhase {
    case .focus: return pomodoroFocusMin * 60
    case .rest:  return pomodoroBreakMin * 60  // 或长休
    case .paused: return pausedPhase == .rest ? pomodoroBreakMin * 60 : pomodoroFocusMin * 60
    case .idle:  return pomodoroFocusMin * 60
    }
}
```

---

## 三、并发 — 9/10

### 强项

- `@MainActor` 在 WorkerStore / WorkerNotificationCenter
- `Timer.scheduledTimer` 在 main RunLoop，cb 内 `Task { @MainActor in }` 隔离正确
- `@preconcurrency import UserNotifications` (`NotificationCenter.swift:13`) — 处理 UN API 非全 Sendable

### 🔴 问题 1：notifAuthorized 没 wire 到 store，状态 dot 永 dim

`NotificationCenter.swift:32-46` callback 内 `WorkerNotificationCenter.shared.isAuthorized = true` —— 但 `WorkerStore.shared.notificationsAuthorized` (`WorkerStore.swift:149`) **没人 wire**。`ExpandedView.swift:84` 读 `store.notificationsAuthorized` 永远是初始值 `false`。

**结果**：top bar 通知状态 dot 永远是 dim grey，即使用户实际授权了通知。

**修法**：`NotificationCenter.swift:34`
```swift
Task { @MainActor in
    WorkerNotificationCenter.shared.isAuthorized = true
    WorkerStore.shared.notificationsAuthorized = true  // ← 加这行
}
```

---

## 四、通知 — 7/10

### 强项

- UN authorization 三态正确处理（authorized/denied/notDetermined）
- 0.1s threshold trigger 处理 macOS 即时通知 flakiness 是 known workaround
- 通知 denied → fallback `NSApp.requestUserAttention(.criticalRequest)` (dock bounce)

### 问题 1：notify() 即便授权也每次都 dock bounce

`NotificationCenter.swift:74` `NSApp.requestUserAttention(.criticalRequest)` 在 schedule 之后**无条件**调用，注释说"always bounce as backup"。但用户授权通知后 dock 还在 bounce 会 spammy。

**修法**：
```swift
if !isAuthorized {
    NSApp.requestUserAttention(.criticalRequest)
}
```

### 问题 2：没 snooze 机制

番茄结束通知 / 久坐警告 fire-and-forget。用户在开会，一次注意不到就丢。**建议**：5 min 后 retry 一次。

---

## 五、持久化 — 7/10

用 `UserDefaults(suiteName: "com.mioisland.plugin.worker")`。5 个 feature 数据全塞同一 suite。简单 key-value，OK。

### 问题 1：历史 dict 增长无 cap

`WorkerStore.swift:403-406` `pomodoroHistory` 每日 key 累积。一年 365 keys，五年 1825。**建议**：保留最近 90 天，rolloverIfNeeded 时 prune。

### 问题 2：lastSeenDay 不持久

`WorkerStore.swift:539 private var lastSeenDay: String = ""`. 重启后 init 时被设成 today (`loadPersisted` 末尾)。day rollover 检测靠这个。跨日运行（不重启）能 catch；新一天才启动则 `lastSeenDay = today` 直接，rolloverIfNeeded 永不 fire（OK，data 也确实新一天 0）。**逻辑 work 但脆**。

---

## 六、错误处理 — 6/10

### 问题 1：SystemIdle 失败返回 0 → silent 误 grow

`SystemIdle.swift:34`：
```swift
return minVal == .greatestFiniteMagnitude ? 0 : minVal
```

若 `CGEventSource` 全部失败（理论上可能 sandbox 拒绝），返回 0 = "用户刚刚操作了" = sit counter 每秒 +1。**结果**：sit counter 误 grow，假警报触发。

**修法**：返回 `nil` 或 sentinel，store 里检测无效 idle 数据时 skip tick。

### 问题 2：UNUserNotificationCenter.add 错误只日志

`NotificationCenter.swift:67-69` — 错误只写 `WorkerDebugLog`，无 UI 信号。

---

## 七、UI — 7/10

### 强项

- 5 个 view 风格高度一致（statusBadge + hero + controls + divider + settings + tipText）
- `WorkerTheme` 集中色彩 token，`WorkerFormat` 集中时间格式
- 各 view emoji + 中文，跟产品 personality 匹配

### 🔴 问题 1：PomodoroView 进度环 paused-in-break 错

（见状态管理问题 1）

### 🔴 问题 2：ExpandedView 通知状态 dot 永 dim

（见并发问题 1）

### 问题 3：WaterView cup mask 不跟 trapezoid 收边

`WaterView.swift:99-108` 水位 mask 用 `Rectangle`，但 cupShape (`CupOutline`) 是 trapezoid (bottomInset 8%)。`Rectangle` mask 不跟着杯子底部收边收缩。

**视觉效果**：低水位时基本看不出来；满水位接近 outline 那里水位 fill 会越过杯壁 — 渲染上可见的 leak。

**修法**：mask 用 `CupOutline` 自己 clip（不是 Rectangle）：
```swift
.mask(CupOutline().scale(y: fraction, anchor: .bottom))
```

### 问题 4：没"今日总览"footer

5 个 tab 各管各的，没"今日 3 番茄 + 6 杯水 + 监控中" 一行 summary。footer 左侧 (`ExpandedView.swift:169-177 footerLeftText`) 每 tab 显示自己的，无跨 tab 整合。

---

## 八、安全 — 9/10

- 100% 本地，无网络
- UserDefaults suite name 跟其它 plugin 隔离
- `NSApp.requestUserAttention` 是 standard API
- 无 entitlement 需求
- 无用户输入直接 eval / shell

唯一关注：`SystemIdle` 用 `CGEventSource` 的 `.combinedSessionState` source 不需要 Accessibility 权限。Apple 列为 sandbox 友好 API。**OK**。

---

## 九、测试 — 0/10

**No tests at all**。

**v1 必须有的**：

| 测试场景 | 难度 |
|---|---|
| Pomodoro state machine：focus → rest → focus × 4 → long rest → focus（autoLoop）| 易（注入 mock Date）|
| Pomodoro paused → resume 跨时间正确 | 易 |
| Pomodoro phase end while away（`loadPersisted` 路径）| 中 |
| Sit accumulator：idle <60 += 1; 60..300 hold; ≥300 reset | 易 |
| Sit wakeup gap：tickGap > 30s reset | 易 |
| Day rollover：跨 midnight 各 counter 归零 | 中 |
| Weekend countdown 跨 Saturday 边界 | 易 |
| ClockoutRemainingSec 跨 midnight roll | 易 |
| WaterCupsToday 持久化 + restore | 易 |

---

## 十、Code smell 汇总

| 文件:行 | 问题 | 优先级 | 修复行数 |
|---|---|---|---|
| `PomodoroView.swift:118` | paused-in-break fraction 用 focusMin 当分母 | 🔴 P0 | 5 |
| `ExpandedView.swift:84` + `NotificationCenter.swift:34` | notifAuthorized 未 wire 到 store，dot 永 dim | 🔴 P0 | 3 |
| `NotificationCenter.swift:74` | 授权后还 dock bounce 体验吵 | 🟡 P1 | 3 |
| `SystemIdle.swift:34` | 失败 fallback 0 → 误 grow sit counter | 🟡 P1 | 改 nil |
| `WaterView.swift:99-108` | mask 不跟 trapezoid 收边 | 🟡 P1 | 改 mask |
| `WorkerStore.swift:403` | pomodoroHistory / waterHistory 无 cleanup | 🟢 P2 | 90 天 prune |
| `WorkerStore.swift` | 700 行 god object | 🟢 P2 | 拆 store |
| 全 repo | 0 tests | 🟡 P1 | 加 XCTest |
| `ExpandedView.swift:151` | footer 版本号硬编码"v0.1" | 🟢 P2 | 读 Plugin.version |

---

## 十一、总评

代码质量 **8/10** — 实际上比看盘侠更扎实。

### 亮点（值得保留 + 文档化）

1. **pomodoro wallclock-based timing** — Mac 睡/quit/手动改时钟都不影响
2. **sit input-idle algorithm** — 比天真 startTimestamp 模型强一档
3. **sleep-aware tick gap detection** — 三层保护
4. **paused state 持久化** — 跨重启恢复正确
5. **统一 view 结构** — 5 个 tab 风格高度一致

### 主要短板

1. **notifAuthorized 没 wire** — UI 上 notif 状态 dot 永远说谎
2. **PomodoroView 进度环算错**（pause 在 break 中）
3. **WorkerStore 700 行 god object** — 长期维护痛
4. **0 tests** — 上架后崩了不知道哪坏

修完 P0 两项 + 加最小测试集（5 个 fixture），code quality 能上 9.5/10。

**整体判断**：v0.2.0 的代码扎实度足以支撑上架。两个 P0 bug（notif dot + paused fraction）一晚上能修完。比看盘侠 v0.3.0 的 Toast bug 更轻 — 后者是 typo 级 ship-blocker。
