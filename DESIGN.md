# 桌宠「看屏幕」插件设计文档（dsh-pet-chat）

> 一句话：学习时遇到看不懂的东西，不用截图、不用切窗口——点一下桌面上的鲸鱼娘，
> 打字问一句，它自己抓你此刻的屏幕，后台 dsh 看懂后把答案吐回气泡里。

本文是 `dsh-pet-chat` 的设计依据。代码是入口，本文记录「为什么这样切」。

---

## 1. 场景与目标

**真实痛点**：学习过程中遇到陌生概念/报错/界面元素时，现有流程是
「截图 → 切到 dsh → 粘贴 → 描述 → 等回答 → 切回」。四次上下文切换，一次真实学习
被打断四段。

**目标链路**（一条，必须闭环）：

```
点桌宠 → 弹出小聊天框 → 打字提问 → 自动带上当前屏幕 → dsh 思考 → 答案回到气泡
```

**明确不做**（v1 边界，避免摊大）：

- 不做宠物形象（用户指定后续再做；v1 用绘制占位）。
- 不改 dsh 官方包、不改 Tauri 壳、不改社区插件（`dsh-tauri-pet` 只共存不侵入）。
- 不做语音输入、不做跨会话记忆、不做多显示器选择器。

---

## 2. 关键决策

| # | 分歧点 | 决策 | 理由 |
|---|---|---|---|
| D1 | 桌宠落地形态 | **挂在官方桌宠上**：形象沿用 `dsh-tauri-pet` 的鲸鱼娘窗口，本插件只提供一张按需弹出的置顶聊天卡 | 痛点发生在**别的软件里**（PDF/IDE/浏览器），页面内 overlay 一切换窗口就消失；而另起一只自绘鲸鱼等于让用户桌上出现两只宠物。壳侧 pet 窗口是 Tauri 内嵌页面，插件拿不到它的 DOM 与点击事件（`dsh-tauri` 只导出工具函数与 Service，无窗口 API），所以用「轮询光标 + 左键松开位移<8px + 命中宠物窗热点矩形」判定「点了桌宠」。 |
| D2 | 看屏节奏 | **提问即抓一帧** + 「再看一眼」再抓 | 单帧已覆盖 95% 提问；持续采样把隐私面和资源占用放大一个量级，收益却在边际递减。 |
| D3 | 会话落点 | **复用当前活跃会话**（可在窗口内切换） | 「后台 dsh 帮我思考」意味着它要能看到你正在学的东西的上下文、能调工具、能跑命令。独立小会话等于每次重新交代背景。 |
| D4 | 抓屏在哪一侧执行 | **窗口侧（PowerShell 进程内 .NET）** | 窗口本来就是 PS/.NET，抓屏零启动开销（<20ms）；宿主侧抓屏要 spawn 子进程，一次 300–700ms，还要处理临时文件。 |

### 被否掉的方案（记录原因，避免重走）

- **浏览器 `getDisplayMedia`**：需要每次用户手势授权，且 Tauri WebView 里行为不可靠。
- **dsh Web UI 插槽 overlay**：受 D2/D1 约束，人不在 dsh 页面时完全失效。
- **复用 `dsh-tauri-pet` 的透明窗口做输入框**：那个窗口由 Tauri 壳（Rust）创建与驱动，
  只消费宿主 SSE 展示态，**没有输入通道**；改造它等于改别人的插件 + 改壳二进制。否决。
- **交给 `@paicat1/dsh-screenshot`**：那是给「在 dsh 页面里截图提问」用的，不解决脱离页面的诉求。

---

## 3. 架构

```
┌────────────────────────────┐        ┌──────────────────────────────────────┐
│ 桌宠悬浮窗 (PowerShell)     │        │ dsh 宿主进程（profile: web）          │
│ pet-chat.ps1               │        │                                      │
│                            │  POST  │  dsh-pet-chat (host half, index.js)  │
│  · 平时隐藏/置顶/可拖动     │ ─────► │   /api/pet-chat/ask                  │
│  · 点官方桌宠 → 弹出卡      │        │     ├─ attachments.saveImage(png)    │
│  · .NET 抓当前屏幕          │        │     └─ agents.get(id).followup(msg)  │
│  · 800ms 轮询答案           │ ◄───── │   /api/pet-chat/state                │
│                            │  GET   │     ├─ agents.list() → 会话列表       │
└───────────┬────────────────┘        │     └─ session/event 折叠 → 最近答案  │
            │                          └───────────────┬──────────────────────┘
            │ 读取 token/端口                            │ 追加 user/message(+image)
            ▼                                           ▼
   ~/.dsh/pet-chat/endpoint.json             当前会话的 Agent Loop
   { base, token }                          （模型直接看到屏幕图，可调全部工具）
```

关键点：**屏幕帧不是"上下文提示"，而是真正的 user 消息内容块（text + image）**。
模型不需要"请求看屏幕"这个工具调用，第一跳就已经看见了。

---

## 4. 数据流

**提问（一次往返）**

1. 用户回车 → 窗口 `CopyFromScreen` 抓虚拟屏幕 → PNG → base64。
2. `POST /api/pet-chat/ask`：`{ question, sessionId?, shot }`。
3. 宿主：`ctx.attachments.saveImage({ data, mediaType:'image/png' })` → 持久化引用。
4. 组装 user 消息：`[text(问题), image(屏幕), text(「上图是我此刻的屏幕」)]`，
   `deepFreeze` 后 `agent.followup(msg)` 唤醒该会话。
5. 模型当步即可读到图，正常走思考/工具/回答。

**回答（轮询，不上 SSE）**

- 宿主订阅 `session/event`，把 `assistant/message` 的 text 块折叠进 per-session 缓存，
  `turn/start` / `turn/end` / `agent/status` 维护 running 位。
- 窗口每 800ms `GET /api/pet-chat/state?sessionId=`：拿会话列表 + 当前答案 + running。
- **为什么轮询而不是 SSE**：答案是「最近一条完整 assistant 消息」这种幂等状态，不是增量流；
  轮询 800ms 的实现量是 SSE 的 1/5，且窗口崩了宿主侧零残留。

**再看一眼**：同一会话再发一条 `[image]` 消息（问题留空 → 走默认追问文案）。

**观察模式**（后续开关，v1 预留）：窗口侧每 3s 抓帧刷新缩略图，仅本地展示，
不推给宿主——「看得见它在看什么」比「让它一直看」更重要。

---

## 5. 接口契约

宿主侧两条精确路由（`ctx.webServer.register`，纯 Node `req/res`，**零第三方依赖**）：

| 路由 | 方法 | 入参 | 出参 |
|---|---|---|---|
| `/api/pet-chat/state` | GET | `?sessionId=` 可选 | `{ ok, sessions:[{id,title,running,active}], sessionId, title, text, running, at }` |
| `/api/pet-chat/ask` | POST | `{ question, sessionId?, shot? }`（`shot` 为 PNG base64） | `{ ok, sessionId, withShot }`；失败 `{ ok:false, error }` + 4xx |

**鉴权**：每次进程启动生成随机 token，写入 `$DSH_HOME/pet-chat/endpoint.json`
（含 `base` 与 `token`）。窗口带 `x-pet-token` 头访问；宿主校验
「远端地址必须是 127.0.0.1/::1 且 token 相等」。

**为什么不用 `guard`**：官方 guard 依赖 `ctx.connection.requestRejection`，那是浏览器连接的
信任边界（cookie/同源），本地非浏览器客户端天然过不去。我们自建「本机 + 预共享 token」边界：
token 只在用户自己的 `~/.dsh` 下，且自定义头让浏览器跨站请求必然触发预检被挡，
CSRF 面为零。

---

## 6. 隐私与安全边界

- 抓屏**只在用户按回车或点「再看一眼」时发生**；不按键不抓帧、不落盘。
- 帧进入会话日志后与普通贴图同权（`attachments` 内容寻址存储），随会话记录留存——
  这是「复用当前会话」的必然代价，用户可自行清理。
- 路由只监听 dsh 已监听的 loopback 端口，不新开端口、不写系统注册表。

---

## 7. 已知边界（诚实清单）

1. **窗口是独立 PowerShell 进程，不是 Tauri 窗口**：因此不参与壳的窗口管理
   （不会进任务栏分组、不吃壳的快捷键）。要变成原生桌宠窗口需要壳侧支持（见 §8）。
2. **抓帧是「提问那一刻」**：用户提问后若继续拖动画面，模型看到的是旧帧。
3. **Windows only**：抓屏走 `System.Drawing` + `CopyFromScreen`。
4. **多显示器**：抓整个虚拟屏幕（`VirtualScreen`），不是"当前显示器"。
5. 与 `dsh-tauri-pet` 并存：那个插件负责动画与状态气泡，本插件负责聊天与看屏，
   两者不共享窗口、互不感知。

---

## 8. 后续（按价值排序）

1. **让触发更可靠**：现用的「光标轮询 + 热点矩形」是外部观测（50ms 一次，CPU 可忽略），
   宠物被拖到透明留白处或半透明区域时会漏判；根治要在壳侧给 pet 页面加一次
   `invoke('pet_clicked')`，或在 `dsh-tauri-pet` 的 client 里挂同一个唤起逻辑。
2. **真正的 Tauri 卡片窗口**：在 `dsh-tauri` 壳里加一个 `petChat` webview 窗口 +
   两条 invoke（`show_pet_chat` / `submit_pet_chat`），把本插件的 HTTP 面变成壳内直连；
   好处是进程数从 2 降到 1、可复用壳的置顶/穿透能力。
3. **观察模式落地**：3s 采样 + 帧差检测，画面剧变时才提示"要不要我看看"。
4. **多显示器选择器** + 窗口级截图（`PrintWindow`，只抓目标窗口）。
5. **语音提问**：复用 `dsh-experimental-speech-to-text` 的 SenseVoice 本地转写。

---

## 9. 文件清单

| 文件 | 作用 |
|---|---|
| `package.json` | bundle 清单：`dsh.bundle.patch` 指向 patch，零依赖；`exports` 指向 `./lib/index.js` |
| `cordis.patch.yml` | 在 profile 里插入一行 `dsh-pet-chat` |
| `lib/index.js` | 宿主半边：两条路由 + 会话折叠 + 消息注入（放 `lib/` 是注入器热重载的硬要求，见 §10） |
| `pet-chat.ps1` | 聊天卡（平时隐藏、点官方桌宠唤出、置顶可拖动、抓屏、轮询、托盘）；**必须带 UTF-8 BOM** |
| `pet-chat.cmd` | 双击启动器（隐藏控制台窗口） |
| `verify/selfcheck.mjs` | 桩 ctx（真 http + 假服务）跑 25 条断言的离线自检 |
| `verify/shoot.ps1` | 旧版自绘鲸鱼的渲染验证（折叠/展开两态，保留作历史回归） |
| `verify/shoot-summon.ps1` | 现役验证：重启卡片 → 把官方桌宠挪到 (160,160) → 拍空闲态 → 点宠物中心 → 拍弹出态并裁图 → 复原桌宠位置 |
| `verify/shots/` | 上面两个脚本产出的截图（`summon-1-idle.png` 空闲、`summon-card-crop.png` 卡片特写等） |
| `README.md` | 安装与使用 |
| `DESIGN.md` | 本文 |

---

## 10. 实现勘误与验证记录（真机实测，不是推演）

### 10.1 落到实现时才暴露的三件事

1. **`inject` 只声明 `webServer` 时，直接 `ctx.agents` 会抛**
   （`cannot get property "agents" without inject`）。改走 `ctx.get('agents')` /
   `ctx.get('attachments')`——cordis 的 `get()` 对未注入服务返回 `undefined` 而不抛，
   于是不必把 `agents`/`attachments` 写进依赖面。
2. **热重载只认 `<pkg>/lib/index.js`**：注入器磁盘降级的匹配条件是入口路径以
   `/lib/index.js` 结尾。入口留在根目录 `index.js` 时热重载必失败，故迁到 `lib/`。
3. **`session.title` 拿不到 → 标题退化成 `session-`**。正解是读 `sessionTitle` 服务：
   `ctx.get('sessionTitle')?.get?.(session)?.title`；兜底才掐前缀取 uuid 前 8 位。

### 10.2 真机验证证据

- **离线自检** `node verify/selfcheck.mjs` → `SELFCHECK PASS`，25 断言：token 鉴权
  （无/错 token 401）、三处 effect 装配、`saveImage` 收到 `image/png`、
  注入消息 `role=user` 且**内容块顺序 text → image → text**、`session/event` 折叠出
  running 与答案、`turn/end` 后 running=false、400/405/404 的边角。
- **真宿主**（本机 dsh，profile=web，200% 缩放）：
  - `GET /state` 返回真实会话，标题为 `DSH鲸鱼娘桌宠插件设计`（走 `sessionTitle`）。
  - `POST /ask`（带 1280×720 屏帧）→ 会话存储 `inbox.next-turn` 里出现
    `role=user` + `content=[{type:text},{type:image,attachmentId:sha256:8f02779a…,width:1280,height:720}]`
    —— 屏幕帧与问题一起进入了**当前会话**的待处理队列。
  - 窗口：折叠 118×118（200% 下物理 236×236）、点击后展开 400×540（物理 800×1080），
    截图为 `verify/shots/crop-collapsed-2x.png`、`verify/shots/crop-expanded.png`。

### 10.3 踩过的坑（给后来者）

| 症状 | 根因 | 处置 |
|---|---|---|
| `[Parser]::ParseFile` 满屏 `Unexpected token`，中文变`椴搁奔濑` | .ps1 存成**无 BOM UTF-8**，5.1 按 GBK 解码吃掉引号 | 落盘后补 BOM（`UTF8Encoding($true)`）；脚本里写中文就别省这步 |
| `FindWindow($null,'鲸鱼娘 · 看屏幕')` 返回 0 | 标题含 `·` 时精确匹配不可靠 | 改 `EnumWindows` + `GetWindowTextW` + `Contains` |
| 截图截到浏览器而不是桌宠 | 截图进程未 DPI 感知：`GetWindowRect` 给虚拟化坐标、`CopyFromScreen` 按物理像素取 | 截图脚本开头 `SetProcessDPIAware()` |
| 点"展开"没反应 | 窗口右下角被 `dsh-tauri-pet` 的置顶窗盖住，点击落到它身上 | 验证脚本先把窗口 `SetWindowPos` 挪到 (80,80) 再点 |
| 按钮文字被裁（`发送 (Ent`） | 同时声明 DPI 感知 + 按 96dpi 像素写死字号 → 9pt 在 200% 上渲染成 2 倍高 | **不声明 DPI 感知**，交给系统整体缩放；要锐利得按 `k=DPI/96` 缩放全部坐标 |
| 一次 `Stop-Process` 把工具进程自己杀了（空输出、exit -1） | 清理命令 `Where CommandLine -like '*pet-chat*'` 命中了自己 | 过滤加 `$_.ProcessId -ne $PID`，模式串带 `.ps1` |

### 10.4 改挂官方桌宠（2026-10-25，取代自绘折叠鲸鱼）

用户裁决：`dsh-tauri-pet` 的鲸鱼娘已经是完整桌宠，本插件不再自绘第二只，
只提供**按需弹出的聊天卡**，由「点官方桌宠」唤出。

壳侧约束（实测，决定了实现方式）：

| 事实 | 证据 |
|---|---|
| pet 窗口是 Tauri 内嵌页面 | 同进程 `deepseek-harness-desktop` 的可见窗 `420×225 / class=Tauri Window / title="Deepseek Harness Pet"`；安装根只有 `deepseek-harness-desktop.exe`(35MB)+`resources/`，无独立 html |
| 通道是 host → Rust → pet 单向 | `dsh-tauri-pet/dist/index.js:16` `SESSION_STREAM_PATH`、`:780` `app.get(...)` + `:790-792` 注释「方案 1（host → rust → pet webview）」、Rust 侧 `emit_to('pet')` |
| 插件层没有窗口 API | `dsh-tauri/dist/index.d.ts` 只导出 `openUrl/openDirectory/readJsonBody/respond/routeHandler/withConnectionAuth/...` 与 `WebServerService / HostLifecycle` 等 Service |
| client UI 只在 iframe 内注册 | `dsh-tauri-pet/dist/client.cjs` 的 `Z()`：`if (window.parent === window) return` |

于是触发做成**外部观测**（不改壳、不碰他人插件）：

- `PetWin.FindPet()`：`EnumWindows` → `class=="Tauri Window"` → 标题含 `Pet` → 进程名
  `deepseek-harness-desktop`；`GetWindowRect` 取矩形。
- 热点矩形 = 宽度 62% 居中、高度 82% 贴底（宠物窗有透明留白，点留白不该触发）。
- 50ms `Timer` 轮询：`GetAsyncKeyState(0x01)` 见到按下就记点，松开时
  **位移 > 8px 判为拖动**、否则判为点击；命中热点 → 卡片在宠物右侧弹出
  （右侧放不下则左侧，`y` 夹在工作区内），再点一次收起。
- 卡片平时 `Hide()`，`ShowInTaskbar=false`，改用托盘兜底（右键「显示聊天卡/退出」）。
- 抓屏前先 `Hide()` 自己 180ms 再 `CopyFromScreen`，避免把自己拍进去（宠物照常留在画面里）。
- 调试线索落 `$DSH_HOME\pet-chat\watcher.log`（每次点击一行：down/up/热点/结果）。

真机证据（`verify/shoot-summon.ps1`，200% 缩放，4K 屏）：

```
pet-orig  = 2134,1098,2974,1547      # 官方桌宠原位（物理）
pet-moved = 160,160,1000,609         # 挪到固定点便于确定性点击
clicked   = 580,474                  # 点宠物中心（物理）
card      = 1020,16,1820,1096  size=800x1080   # 卡片弹在宠物右侧（逻辑 400×540）
watcher.log: down 290,237 → up 290,237 moved=0 → hot 160,121-420,305 → shown
```

- `verify/shots/summon-1-idle.png`：空闲态——桌面上只有官方鲸鱼娘，没有第二只宠物、没有卡片。
- `verify/shots/summon-card-crop.png`：点一下之后，卡片贴在宠物右侧弹出，
  标题是真实会话名、答案区显示上一条真实回答、按钮无裁字。

### 10.5 卡片改版（2026-10-25 第二版：浅蓝白 + 可拖可缩）

用户两条要求：① 点鲸鱼娘后聊天框**固定出现在屏幕右侧**，且能拖边框移动/缩放；
② 现有 UI 糊、内容堆成一团。

| 处理 | 做法 |
|---|---|
| 糊 | 反向修正 10.3 的结论：**重新声明 `SetProcessDPIAware()`**，几何一律乘 `$k = DpiX/96`（`function S`），字号仍用 pt 让系统换算 —— 这样既不糊也不裁字 |
| 堆成一团 | 答案区从 `TextBox` 换成 `RichTextBox` 消息流：`Format-Text` 扁平化 markdown（去围栏、标题变 `▍`、列表变 `·`、压空行、超 4000 字截尾），我的提问右对齐 + `#DBE8FF` 底 + `#183E8C` 字，回答左对齐正文色，段间 6pt 小字号空行 |
| 固定位置 | `Default-Geometry`：主屏工作区右缘内缩 24px、垂直居中、420×620；几何写 `$DSH_HOME\pet-chat\card.json`，下次开在原位 |
| 拖边缩放 | C# `ResizeHook : NativeWindow` 拦 `WM_NCHITTEST`，8px 边带返回 10/11/12/13/14/15/16/17 交给系统做 sizing loop（光标/吸附/DPI 全归系统）；`AssignHandle` 在 `Add_Shown` 里做。命中码实测：10/11/12/15/17/1 全对 |
| 原生滚动条太亮 | uxtheme 深色（`SetPreferredAppMode`）在 PS 宿主里不生效 → `ScrollBars=None`，右侧自绘 3px 进度轨（`EM_GETLINECOUNT`/`EM_GETFIRSTVISIBLELINE`），滚轮照常滚；**轨不可拖**（ponytail 标注，要拖再上 `EM_GETSCROLLPOS`） |
| 配色 | 浅蓝 + 白：画布 `#FFFFFF`、顶栏/输入区 `#EEF5FF`、描边 `#B8CFEE`、正文 `#1C283A`、次要 `#6B7C93`、强调 `#2F6BFF`；白卡压在白窗口上会"飘"，`Form.Paint` 里描一圈圆角淡蓝边 |
| 输入框 | `TextBox` 画不了边框 → 套 1px 浅蓝 `Panel`（`$inputFrame`）当描边，白底内嵌；空输入时状态行兼作占位提示「写点问题，我边看屏幕边答」 |

真机证据（`verify/shoot-card-ui.ps1`，200% 缩放）：

```
card-default = 1992,142 840x1240     # 逻辑 420×620，贴右缘 24px、垂直居中
card-resized = 1698,102 1134x1463    # SetWindowPos 后 Layout 重排：文字按新宽换行、按钮仍贴底右
card-reopen  size=890x1240 persisted=True   # 收起再开，尺寸被 card.json 记住
```

- `verify/shots/card-v2-default.png`：默认尺寸下的浅蓝白卡片（空态文案 + 最近回答 + 输入框 + 两个按钮）。
- `verify/shots/card-v2-wide.png`：放大后的同一张卡，排版跟着变宽、无裁字、无溢出。


### 10.6 卡片改为"可自由拖放、位置自适应"（2026-10-25 第三版）

用户反馈两条：① 位置别固定，下次沿用上次关掉时的位置与大小；② 实际只能左右拉宽、
拖不动，要求长宽位置都能随手调。

**根因（②的一半是架构问题，不是手感问题）**：上一版把缩放交给系统的
`WM_NCHITTEST` + sizing loop，而 `WM_NCHITTEST` 只发给光标正下方的那个窗口 ——
标题栏 Panel、消息区 `RichTextBox`、输入区 Panel、按钮全盖住了窗体四边，系统
hit-test 根本到不了窗体边框。只有左右两侧留了 14px 的 padding 空档属于窗体本体，
于是"只有宽度能拉"。移动则是因为标题栏上的 `Label` 铺满整条、吞掉了 `Panel` 的
`MouseDown`，而且即便拖到标题栏空白处也没有 `Save-Geometry`。

**改法：移动和缩放全部自己实现，不再依赖系统 sizing loop。**

| 项 | 做法 |
|---|---|
| 挂载 | `Attach-Drag <控件> <是否可移动>` 给每个子控件挂一套 `MouseDown/MouseMove/MouseUp`；可移动 = 标题栏 Panel、标题 Label、状态点、消息区、进度轨、状态行；只缩放 = 窗体、输入区、输入框壳、四个按钮 |
| 分区 | `Get-Zone <屏幕坐标>` 用 12px 边带算出 `l/r/t/b/tl/tr/bl/br`；12px 而非 8px 是因为窗口有 14px 圆角，**圆角外的像素不属于窗口、点击会直接穿过去**，抓角得落在圆角内侧一点 |
| 缩放 | `Update-Drag` 按 zone 改 `Left/Top/Width/Height`，最小 360×420，然后**夹进虚拟桌面**（拖出屏幕边会让右下角永远够不着） |
| 移动 | 同一套逻辑，`SetBounds(base + delta)`，同样夹进虚拟桌面 |
| 光标 | 悬停时按 zone 换 `SizeWE/SizeNS/SizeNWSE/SizeNESW`，空白区 `SizeAll` |
| 落盘 | `End-Drag` 只要真动过就 `Save-Geometry` → `$DSH_HOME\pet-chat\card.json`；`Show-Card` 读回并夹进虚拟桌面（用 `SystemInformation.VirtualScreen` 而不是主屏，卡在副屏也不会被拉回来） |
| 退出 | `ApplicationExit` 也存一次，托盘退出不丢几何 |

`ResizeHook`（`NativeWindow` + `WM_NCHITTEST`）保留在文件里但**不再挂载**，只作为
踩坑记录。

**真机验证（`verify/shoot-drag.ps1`，200% 缩放，真实鼠标事件注入）**：

```
r0 summon   = 1992,142 840x1240          # 首次默认位：右缘 24px、垂直居中
r1 moved    = 1292,222 840x1240  d=-700,+80     # 拖标题栏：位移与手势完全一致
r2 size BR  = 1292,222 1000x1360 d=+160,+120    # 拖右下角：宽高同改
r3 size L   = 1212,222 1080x1360 dW=+80         # 拖左缘：只改宽
r4 size B   = 1212,222 1080x1260 dH=-100        # 拖下缘：只改高
r5 reopened = 1212,222 1080x1260 persisted=True # 收起再开：位置与大小沿用
card.json   = {"x":1212,"y":222,"w":1080,"h":1260}
```

截图 `verify/shots/card-v3-moved.png`：缩放到 1080×1260 后文字按新宽重排、
按钮仍贴底右、无裁字。
## 10.7 卡片 UI 重做（第四版：Raycast 浮层语言，2026-10-25）

设计走的是「先出视觉稿再落地」：三版 HTML 纸面稿在 `design-demos/`
（`d1-bento.html` 轮盘 20 号 Bento 分区 / `d2-overlay.html` Raycast 浮层 / `d3-ma.html` 原研哉留白），
用户选 **d2** 后按稿复刻。

| 改动 | 做法 | 为什么 |
| --- | --- | --- |
| 消息区换自绘控件 | 新增 `msgview.cs`（`PetMsgView : Control`），GDI+ 自己折行、自己画气泡 | RichTextBox 行距由字体度量决定（≈1.35 倍），设计稿要 1.6 倍；14px 正文跑 14 行就累积 98px 偏差，底栏会被顶出卡片 |
| 字号反解 | `Fit-Font` 量一个汉字的前进宽度再回推字号（本机实测 GDI 给 CJK 的前进 ≈ 请求像素的 1.53 倍） | 直接按 pt 建字体，420 宽的卡一行只剩 13 个字，和稿子差一倍 |
| 分区只靠线 | 顶栏底线 + 底栏顶线两条 1px（`$cLine`），底色 `#ffffff / #f5f9ff / #f8fbff` | 稿子的分区语言是"表面只差一档"，不靠块面 |
| 提问气泡 | 右对齐、`#e8f0fe` 底、`#17356f` 字、圆角 10、最大 82% 宽 | 一眼分出"我说的/它说的"，且不抢正文 |
| 输入框 | 外框 `#c3d4ea` 1px + 内层 `#fbfdff`，占位「写点问题，我边看屏幕边答」用叠一层 Label 实现 | 单行 TextBox 没有占位符属性，cue banner 对多行不生效 |
| 状态 | 圆点色表状态（绿/琥珀/红）+ 状态文字挪到按钮同排左端 | 不额外占高度，信息仍在 |
| 出错 | 不再弹一句就消失，`Add-Notice` 落成 `#fdf1ee` 描边块留在流里 | 可回看，且和稿子的错误态一致 |

**验证入口（这两个开关只给验证脚本用，日常不用）**

- `pet-chat.ps1 -Show`：启动即展开卡片（`Add_Shown` 在"平时不显示窗体"的场景下根本不会触发，
  展开必须显式做，这条踩过）。
- `pet-chat.ps1 -Show -Demo`：灌一段样例问答且**不启轮询**（轮询会用真实会话内容覆盖样例）。
- `verify/shoot-card-ui.ps1` → `card-v2-default.png`（右缘停靠）/ `card-v2-top.png`（滚到顶）/
  `card-v2-clean.png`（挪到空白区，排除别的窗口压屏）/ `card-v2-wide.png`（放大验重排）。

真机结果：`card-default = 1992,142 840x1240`、`card-resized = 1698,102 1134x1463`，
字体反解后一行 ≈27 字（与稿子一致），按钮贴底右、无裁字。

## 10.8 第五版：16px 字号 + 主操作变图标（2026-10-25）

按实际使用反馈改的三处，都属于"用起来才知道"的层级：

| 改动 | 做法 | 为什么 |
| --- | --- | --- |
| 正文 14 → 16px | `Fit-Font (16*K)`；辅助 12 → 13；按钮 15/600 | 420 宽的卡上 14px 读着费劲，用户实际观感偏小 |
| 主操作改成圆形图标按钮 | `$btnAsk`（Panel + `Set-EllipseRegion` 圆形 Region），`Add_Paint` 里画白箭头（`Pen` 圆头、杆 6k、头 5k），hover 变 `#3366F2` | 发送这类动作图标比文字快；同时把"发问"和"看屏"拆成两个语义 |
| 语义调换 | 图标按钮与 Enter = **只发问题、不抓屏**；「看屏幕并提问」= 连屏幕一起发 | 大多数问题是"接着上一轮问"，不需要重新截图；要画面时再显式按 |

**关于抓屏参数**：宿主 `/api/pet-chat/ask` 的 `shot` 本来就是可选的
（`lib/index.js:188-205`：`const shot = typeof body.shot === 'string' ? body.shot : ''`，
空串就只发文本块），所以"不抓屏"不需要改宿主协议。

**进度轨**：仍然是**指示器，不可拖**。滚轮、PageUp/PageDown、Home/End 都能滚
（`PetMsgView` 覆写 `OnMouseWheel` + `IsInputKey`/`OnKeyDown`）。曾经实现过拖轨
（命中区放宽 4px、按下即滚、`Invalidate()+Update()`），真机拖拽时出现"气泡与文字错位、
内容不滚"的刷新异常，且该功能本来就不在需求里，遂回退，只留键盘与滚轮。

## 10.9 第六版：工作区选择 + 新建会话（2026-10-25）

以前的卡只会"跟着最近活动的会话"，想开新话题必须先切回 dsh 网页。这一版把这两步搬进卡里。

| 需求 | 做法 | 为什么这么做 |
| --- | --- | --- |
| 选工作区 | 头栏下面加 34px 的条：左边 `ComboBox` 列 `workspaceRegistry.list()`，右边「新建会话」 | 工作区是"这件事属于哪个项目"的唯一标识，建会话前必须先定它 |
| 新建会话 | `sessionController.create({ workspaceId })` | 这是宿主自己的创建入口，语义是"新建或认领"，比在窗口里拼 requestId 稳 |
| 预设采用默认 | 请求体**不传** `agentPreset` | 传死值（如 `router-standard`）会在用户改过默认预设后变味；不传=部署默认 |
| 新会话立刻可用 | `/ask` 遇到"点名的会话还没有活体"时先 `create({ sessionId })` 认领，再 `followup` | 刚建的会话在下一条消息前没有 Agent，不认领就会 409 |
| 绝不投错会话 | `/ask` 点名了 sessionId 就只用它（`exactAgent`），拿不到就认领，认领不了就 409 | 早先 `pickAgent` 会退到"最近活动的活会话"——新建会话还没活起来时，问题会被悄悄送进**别的**会话 |

**新增路由**（都在 `lib/index.js`，同一套 token 边界）：

- `GET /api/pet-chat/workspaces?sessionId=` → `{ ok, workspaces:[{id,title,path,sessions}], sessionId, workspaceId }`
- `POST /api/pet-chat/session` body `{ workspaceId? }` → `{ ok, sessionId, agentPreset, workspaceId }`；
  宿主没装 `sessionController` 时 503 `session-controller-unavailable`

**两个小坑**：

1. 新会话在 dsh 侧会先拿到一个 8 位短 id 当标题（`802ca19e`），用户看不懂 → 卡的 `Refresh-State`
   把 `^[0-9a-f]{8}$` 的标题折成「新会话」。
2. `/state?sessionId=` 以前找不到会话就退回最近活动的那个，窗口的选择会被顶掉 → 改成"点名的 id 原样回"，
   只把 title/text 留空。

## 10.10 发送发不出去的两个真 bug（2026-10-25 修复）

| 现象 | 根因 | 修法 |
| --- | --- | --- |
| 点圆形图标、按 Enter 都毫无反应（输入框里的字还在，状态不变成「已送达」） | `function Send-Question { param([bool]$WithShot, [string]$Override = $null) ... }`：**PowerShell 会把带类型的 `[string]` 参数的 `$null` 默认值强制转成空串**，于是 `if ($null -ne $Override)` 永远为真，`$question` 被自己的空 override 覆盖成 `''`，函数在"空问题"分支直接 `return`。抓屏按钮没事，因为它允许空问题，所以一直显示正常，把 bug 藏住了 | 判断改成 `if (-not [string]::IsNullOrWhiteSpace($Override))`；`card.log` 里现在能直接看到 `send: withShot=False q=[...]` |
| 提问气泡是空的（有框没字），一滚就更明显 | `msgview.cs` 的 `OnPaint` 用 `g.TranslateTransform(0, -scrollY)` 做滚动，但 `TextRenderer.DrawText` 走 GDI、**不认 GDI+ 的世界变换**：气泡（GDI+ 路径）被平移了，文字留在原位，滚动越大错得越远 | 去掉变换，改每个块自己算 `y - scrollY`；顺带加上"块完全在视口外就跳过"的早退 |

两个入口的验证（`tools/probe-enter` / `tools/probe-icon.ps1`）都会写 `%USERPROFILE%\.dsh\pet-chat\card.log`：

```
23:12:17  send: withShot=False q=[sendprobe-enter] session=[session-cf10a84b-...]
23:12:17  view: k=2 W=720 blocks=3 | meta:1行/12字/648x34 | theirs:34行/934字/648x1496 | mine:1行/15字/217x72
```

`view:` 那行是排版自述（每块的种类、行数、字数、尺寸），气泡"有框没字"这类问题一眼定位在折行还是绘制。

事件处理器一律包 `try/catch → Write-CardLog`：WinForms 的 `Add_Click`/`Add_KeyDown` 里抛出的异常在隐藏窗口里是**看不见**的，不落日志就等于随机失灵。
