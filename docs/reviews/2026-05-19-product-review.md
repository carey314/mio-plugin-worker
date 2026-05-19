# 摸鱼侠 — 产品 Review

**日期**: 2026-05-19
**审视版本**: v0.2.0 main HEAD `0cff83fc`（"sleep-aware timers + auto-loop pomodoro"）
**Tabs**: 番茄 / 久坐 / 喝水 / 下班 / 周末
**面板**: 380×620

---

## 一、核心价值主张

| 维度 | 评分 | 说明 |
|---|---|---|
| 差异化 | 9/10 | 聚合 5 个上班场景，刘海常驻，"周末倒数 + 打工语录" 玩具感 |
| 价值密度 | 8/10 | 单一 plugin 覆盖 4 个独立细分（番茄 / 久坐 / 喝水 / 倒计时）|
| 上手摩擦 | 9/10 | 0 登录 0 网络 0 配置就能用 |

### 强项

1. **聚合"上班一天会做的微动作"** — 番茄钟 + 久坐 + 喝水 + 下班倒计时已经覆盖职场版"健康助手"大头。市面上要么单功能 menubar (Be Focused / Drink Water Reminder)，要么大 app (Forest / Notion)。集中在刘海是新形态。
2. **"周末倒数 + 打工语录"是 personality 担当** — 这一 tab 跟其它四个分开看是娱乐性的，但它是产品个性的来源。没这个 tab 就是健康提醒 app，有了它就是"打工人玩具"。
3. **100% 本地** — 没网络、没账号、没 telemetry。比 Forest 联网+social pressure 更适合"我自己用"的人。

### 弱项

1. **"摸鱼侠"名字 vs 5 个 tab 全在认真工作 = 反差**
   名字暗示"摸鱼"，实际：番茄（专注）、久坐（健康）、喝水（健康）、下班（期待）、周末（期待）。**整个工具是"老老实实打工 toolkit"**。要么改名（"打工侠"更准），要么真加一个摸鱼 tab（藏老板模式 / 桌面伪装 / 假装写代码的 dummy editor）。
2. **5 tab 在 380pt 太挤** — `ExpandedView.swift:97` spacing 6 + 5 个 emoji tab，单 tab ~64pt。看是看见，但触摸/点击 hit zone 比看盘侠 3-tab 明显窄。
3. **README 与 footer/Info.plist 版本号不一致** — `ExpandedView.swift:151` footer 硬编码 "v0.1 · 本地运行"，但 Info.plist + WorkerPlugin.swift 是 v0.2.0。每次发版都得手改文案。

---

## 二、UX 流程完整度（按 tab 拆）

### 番茄 tab — 9/10 (最完善)

✅ 25/5 + 长休息 cycle 完整
✅ pause/resume 跨重启正确（`WorkerStore.swift:594-600` paused 持久化）
✅ **sleep-aware**：`WorkerStore.swift:198-200` 用 tick 间隔检测 wallclock gap，Mac 睡眠后倒计时不错乱
✅ 4-tomato dot 周期可视化（`PomodoroView.swift:64`）
✅ autoLoop toggle — 经典 Pomodoro 节奏，一启动跑一上午

**短板**：
- ⚠️ stepperPill 单位 +5/+1/+5 min，专注分钟想要 +1 step（27 分钟用例）
- ⚠️ 没"中断当前番茄"button — 重置可以替代但语义不同
- ⚠️ "专注时长 = todayCount × focusMin" 算法 simplistic — partial focus 丢失。无所谓，不算精确没事

### 久坐 tab — 9/10 (算法亮点)

✅ **input-idle 算法是核心亮点** — `SystemIdle.swift` 用 `CGEventSource.secondsSinceLastEventType` 判定真在打字 vs 离开。避免天真版"start timestamp - now"把午休/会议都算成坐着的 trap。
✅ 5min idle 阈值 reset；wallclock gap >30s 也 reset（sleep/wake）— 双保险
✅ threshold 之后 dock bounce + 红色 status pill + 通知（30s 持久化 cadence，崩溃最多丢 30s data）
✅ tip 文案诚实："只统计你真正在键盘前的时间。离开 5 分钟以上自动归零，午休/会议不会被算进去。"

**短板**：
- ⚠️ 没"今日累计坐了 X 小时"统计 — 只显示当前 streak，无历史 retention。"健康报告"路线钩子缺
- ⚠️ trigger 配置 +5 min step、下限 5 min — 想要 60min trigger 要点 3 次。可以加 +15 min step

### 喝水 tab — 7/10 (placeholder 级)

✅ Hero 大杯子 + 水位渐变填充动画细心（`WaterView.swift` CupOutline + LinearGradient mask）
✅ 进度 dot 可视化今日 x/N 杯
✅ 加 / 撤销 manual log，撤销 -∞ 守住（`WorkerStore.swift:455`）

**短板**：
- 🔴 **没提醒** — 跟番茄/久坐对比最大短板。设了"目标 8 杯"但不提醒。一整天忘了喝就没了。**P0**：加 X 小时一杯水的 cadence + 通知（autoLoop pomodoro-style）
- ⚠️ 历史不可见 — `waterHistory` dict 里其实存了过往天数据，没 UI
- ⚠️ 没编辑"今早 8 点喝了 1 杯但忘了点"功能 — 只能 + / 撤销 当前

### 下班 tab — 7/10 (倒计时到 0 没事件)

✅ "X 时 Y 分 Z 秒" + 渐变进度条（红→深红）— 视觉感染力强
✅ 9 小时 anchor 算 progress fraction —合理
✅ 时间 hh:mm 可调（5 min step）

**短板**：
- 🔴 **"下班到了"那一刻没事件** — `clockoutRemainingSec` 到 0 后 roll 到明天的同一时间（`WorkerStore.swift:491-495 if target <= now { target += 1 day }`）。所以下班到了下一秒变成"距明天下班 23:59:59"。**漏的体验**：应该有"已下班！" celebration overlay 或 panel 颜色变。**P0**
- ⚠️ tipText 说"下班时间到不会响铃" — 这是文案 disclaimer 但产品上反而是缺陷。**应该响**
- ⚠️ 没"周末忽略" — 周六也倒计时下班，应该周末显示"今天不上班"
- ⚠️ 默认 18:00；9-9-6 / 灵活 OT 党需改。OK 可调，但没"工时模式"预设

### 周末 tab — 8/10 (personality 担当)

✅ "天/时/分 + 下个周六 00:00" + 旋转打工语录 — 形态独特
✅ 周末打开倒计时 +7 天 — 决策合理（`WorkerStore.swift:518-519`）
✅ day-of-year mod 7 的 quote rotation 一天一条稳定

**短板**：
- ⚠️ **打工语录池只有 7 条** — 52 周看 52 次每条。重复感会重。**P1 扩到 30+**
- ⚠️ **没"假期校准"** — 国庆/春节怎么办？周末倒计时还在算下周六。逻辑对但用户期待"放长假倒计时"。**P1 接入国务院 ICS feed**

---

## 三、信息架构

| 强项 | 弱项 |
|---|---|
| 每个 tab 一致 layout：statusBadge + hero + controls + divider + settings + tipText | 没"全局 dashboard" — 5 tab 间不互通 |
| LiveDot 在 footer 闪 — plugin 在 active 计时 | 没"今日 X 番茄 + Y 杯水 + Z 分钟久坐" 一行 summary |
| notif status dot 在 top bar — 通知未授权时的隐性提醒 | tab 之间数据点孤岛 |

---

## 四、与竞品对比

| | 摸鱼侠 | Be Focused | Drink Water | Forest |
|---|---|---|---|---|
| 桌面常驻 | ✅ 刘海 | ✅ menubar | ✅ menubar | ❌ App |
| 番茄钟 | ✅ + auto-loop | ✅ | ❌ | ✅ |
| 久坐提醒 | ✅ input-idle | ❌ | ❌ | ❌ |
| 喝水追踪 | ✅（无提醒）| ❌ | ✅ | ❌ |
| 下班倒计时 | ✅ | ❌ | ❌ | ❌ |
| 周末倒数 | ✅ | ❌ | ❌ | ❌ |
| 通知 | UN + dock | ✅ | ✅ | ✅ |
| 价格 | 免费 | $1.99 | 免费 | $1.99 |
| Social pressure | ❌ | ❌ | ❌ | ✅（种树）|
| 中文体验 | ✅✅ | ❌ | ❌ | ⚠️ |

**差异化**：聚合 + 桌面常驻 + 中文文案 + 周末打工语录。"打工人玩具"比 Western productivity tool 中文用户更亲切。

---

## 五、上架前必修（P0）

| # | 项 | 文件 / 位置 |
|---|---|---|
| 1 | "下班到了"瞬间要有通知 + panel celebration overlay | `WorkerStore.swift:491-495` clockoutRemainingSec roll 逻辑 |
| 2 | 喝水加可选定时提醒（每 X 小时） | 新增 water reminder timer |
| 3 | footer 版本号去硬编码 | `ExpandedView.swift:151` 改读 `WorkerPlugin.version` |
| 4 | tipText "不会响铃" 删掉或改写 — 跟未来要加的通知冲突 | `ClockoutView.swift:239` |

---

## 六、建议加（P1）

1. **真的"摸鱼" tab** — 跟名字呼应：藏老板模式 / 桌面伪装 / dummy editor。是 product personality 的兑现
2. **打工语录池扩到 30+** — 现在 7 条一周一轮太短，季节性条目（春节前 / 国庆前 / 周一专属 / 周五专属）
3. **假期/节假日校准** — 国务院假期 ICS pull 一次，下班 + 周末倒计时知道明天是法定休
4. **今日历史 chart** — 7 天番茄 / 喝水 / 久坐 trend，鼓励 streak
5. **快捷键** — `cmd-shift-1/2/3/4/5` 切 tab，`space` 番茄 start/pause
6. **WaterView 历史可见** — `waterHistory` 数据已经在存，画个 7 天 bar chart

---

## 七、建议砍（P-1）

- README 提到 macOS 15.0+ / MioIsland v2.2.0+ 是 OK，但应在产品文案显式说"需要 Apple Silicon"（bundle arm64-only）— 这是 ecosystem 级问题，跟主程序 + 其它插件统一改

---

## 八、总评

| 问 | 答 |
|---|---|
| v0.2.0 上架免费版？ | **是** |
| 功能完成度？ | 番茄 9/10 + 久坐 9/10 是亮点；喝水 7/10 + 下班 7/10 是 placeholder 级；周末 8/10 是 personality 担当 |
| 上架前必修项数？ | 4 个（见上）|
| 最大产品风险 | "摸鱼侠"名字 vs 实际功能反差。要么改名要么真做摸鱼 tab |
| 最大产品亮点 | input-idle 久坐算法 + sleep-aware 番茄 wallclock — 工程支撑产品体验，比同类强一档 |

**优先级 sequence**：修 P0 四项 → 上架免费 → 做"真摸鱼 tab"兑现名字 → 加节假日校准 + 历史 chart 增 retention。
