/**
 * dsh-pet-chat — 桌宠「看屏幕」宿主半边。
 *
 * 职责只有三件事，且全部零第三方依赖：
 *   1. 开四条本机路由：`/state`（会话列表 + 最近答案）、`/ask`（注入提问）、
 *      `/workspaces`（工作区清单）、`/session`（新建会话，预设走默认）；
 *   2. 把悬浮窗抓来的屏幕帧落成 attachments 图片块，拼进一条 user 消息注入当前会话；
 *   3. 订阅 `session/event` / `agent/status`，把每个会话的「最近一条 assistant 文本 + 是否回合内」
 *      折叠成窗口轮询用的幂等状态。
 *
 * 刻意不依赖：不 import `@deepseek-ai/*`（工作区 bundle 里解析不到 dsh 安装树），
 * 不走 `dsh-h3` 的 defineWebServer / guard（那是浏览器连接信任边界，本地非浏览器客户端过不去）。
 */

import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-pet-chat'
/** 只依赖 webServer：agents / attachments 在调用时就地取，缺失时给出可读错误而不是激活失败。 */
export const inject = ['webServer']

/** 包根（lib/ 的上一级），卡片脚本与它同级。 */
const PACKAGE_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const CARD_SCRIPT = join(PACKAGE_DIR, 'pet-chat.ps1')

/** 自启这种"发生在宿主里、界面上看不见"的动作，留一行审计日志，出事时不用猜。 */
function auditAutostart(line) {
  try {
    mkdirSync(STATE_DIR, { recursive: true })
    const stamp = new Date().toISOString().slice(11, 19)
    appendFileSync(join(STATE_DIR, 'host.log'), `${stamp} ${line}
`, 'utf8')
  } catch {
    /* 审计失败不影响主流程 */
  }
}

const PREFIX = '/api/pet-chat'
const TOKEN = randomUUID()
const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), '.dsh')
const STATE_DIR = join(DSH_HOME, 'pet-chat')
const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1'])
const MAX_BODY_BYTES = 32 * 1024 * 1024
const MAX_QUESTION = 8_000
const MAX_ANSWER = 400_000
/** 只有附图没提问时的兜底追问（「再看一眼」按钮）。 */
const LOOK_AGAIN_TEXT = '这是我此刻的屏幕，接着说下去。'

/** sessionId → { text, running, at, title }。窗口轮询读的就是这份折叠态。 */
const live = new Map()

function entryOf(id) {
  let entry = live.get(id)
  if (entry === undefined) {
    entry = { text: '', running: false, at: 0, title: undefined }
    live.set(id, entry)
  }
  return entry
}

// ── HTTP 小工具 ──────────────────────────────────────────────────────────────

function send(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

/** 本机 + 预共享 token。自定义头让浏览器跨站请求必然预检被挡，CSRF 面为零。 */
function authorized(req) {
  if (!LOOPBACK.has(req.socket?.remoteAddress ?? '')) return false
  return req.headers['x-pet-token'] === TOKEN
}

async function readJson(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_BODY_BYTES) throw new Error('body-too-large')
    chunks.push(chunk)
  }
  if (size === 0) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

// ── 消息构造（等价于 createUserMessage，只是不 import dsh-llm） ──────────────

function deepFreeze(value) {
  if (value !== null && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value)
    for (const key of Object.keys(value)) deepFreeze(value[key])
  }
  return value
}

function userMessage(content) {
  return deepFreeze(structuredClone({ id: randomUUID(), role: 'user', content, source: { kind: 'user' } }))
}

// ── 会话面 ───────────────────────────────────────────────────────────────────

/** 会话 id 只认 `agent.session.id`（Agent 本身不暴露 id）。 */
function idOf(agent) {
  const id = agent?.session?.id ?? agent?.id
  return typeof id === 'string' ? id : ''
}

function titleOf(ctx, agent, id) {
  const session = agent?.session
  const candidates = [
    live.get(id)?.title,
    ctx.get('sessionTitle')?.get?.(session)?.title,
    session?.title,
    session?.summary?.title,
    session?.displayTitle,
    session?.header?.title,
  ]
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim() !== '') return candidate.trim()
  }
  // 兜底：`session-<uuid>` 掐掉前缀，取前 8 位（可读且大概率唯一）。
  const tail = id.replace(/^session-/, '')
  return (tail || id).slice(0, 8) || '未命名'
}

/** 活的会话列表，最近活动在前。窗口用它渲染切换下拉。 */
function sessionRows(ctx) {
  const agents = ctx.get('agents')?.list?.() ?? []
  const rows = agents.map((agent) => {
    const id = idOf(agent)
    const entry = live.get(id)
    return {
      id,
      title: titleOf(ctx, agent, id),
      running: agent?.status === 'running' || entry?.running === true,
      at: entry?.at ?? 0,
    }
  })
  rows.sort((a, b) => b.at - a.at)
  return rows
}

/**
 * 工作区清单。`workspaceRegistry` 是可选服务：宿主没装工作区能力时返回空表，
 * 窗口只能建"默认位置"的会话，而不是整块功能报错。
 */
function workspaceRows(ctx) {
  const registry = ctx.get('workspaceRegistry')
  if (registry === undefined || registry === null || typeof registry.list !== 'function') return []
  let list
  try {
    list = registry.list()
  } catch {
    return []
  }
  return list.map((workspace) => ({
    id: String(workspace.id),
    title: String(workspace.title ?? workspace.path ?? ''),
    path: String(workspace.path ?? ''),
    sessions: Array.isArray(workspace.sessionIds) ? workspace.sessionIds.length : 0,
  }))
}

/** 会话属于哪个工作区（工作区列表按 registry 顺序，取第一个命中的）。 */
function workspaceOf(ctx, sessionId) {
  if (typeof sessionId !== 'string' || sessionId === '') return ''
  const registry = ctx.get('workspaceRegistry')
  if (registry === undefined || registry === null || typeof registry.list !== 'function') return ''
  try {
    for (const workspace of registry.list()) {
      const ids = Array.isArray(workspace.sessionIds) ? workspace.sessionIds : []
      if (ids.includes(sessionId)) return String(workspace.id)
    }
  } catch {
    /* 读不到就是没有 */
  }
  return ''
}

/** 只认点名的会话，绝不退到"别的活会话"——新建会话还没活起来时，退让会把问题投错会话。 */
function exactAgent(ctx, sessionId) {
  if (typeof sessionId !== 'string' || sessionId === '') return undefined
  const agents = ctx.get('agents')
  if (agents === undefined || agents === null) return undefined
  return agents.get(sessionId)
}

/** 目标会话：显式 id 优先，其次最近活动的活体会话。 */
function pickAgent(ctx, sessionId) {
  const agents = ctx.get('agents')
  if (agents === undefined || agents === null) return undefined
  if (typeof sessionId === 'string' && sessionId !== '') {
    const wanted = agents.get(sessionId)
    if (wanted !== undefined) return wanted
  }
  for (const row of sessionRows(ctx)) {
    const agent = agents.get(row.id)
    if (agent !== undefined) return agent
  }
  return undefined
}

// ── 路由 ─────────────────────────────────────────────────────────────────────

function handleWorkspaces(ctx) {
  return async (req, res) => {
    if (req.method !== 'GET') return send(res, 405, { ok: false, error: 'method-not-allowed' })
    if (!authorized(req)) return send(res, 401, { ok: false, error: 'unauthorized' })
    try {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const sessionId = url.searchParams.get('sessionId') ?? ''
      send(res, 200, {
        ok: true,
        workspaces: workspaceRows(ctx),
        sessionId,
        workspaceId: workspaceOf(ctx, sessionId),
      })
    } catch (error) {
      send(res, 500, { ok: false, error: String(error?.message ?? error) })
    }
  }
}

/** 新建会话。预设故意不传 = 走部署默认（用户明确要求"预设采用默认"）。 */
function handleCreate(ctx) {
  return async (req, res) => {
    if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'method-not-allowed' })
    if (!authorized(req)) return send(res, 401, { ok: false, error: 'unauthorized' })
    let body
    try {
      body = await readJson(req)
    } catch (error) {
      return send(res, 400, { ok: false, error: `bad-body:${error?.message ?? error}` })
    }
    const controller = ctx.get('sessionController')
    if (controller === undefined || controller === null || typeof controller.create !== 'function') {
      return send(res, 503, { ok: false, error: 'session-controller-unavailable' })
    }
    const workspaceId = typeof body.workspaceId === 'string' && body.workspaceId !== '' ? body.workspaceId : undefined
    try {
      const created = await controller.create(workspaceId === undefined ? {} : { workspaceId })
      send(res, 200, {
        ok: true,
        sessionId: String(created?.sessionId ?? ''),
        agentPreset: String(created?.agentPreset ?? ''),
        workspaceId: workspaceId ?? '',
      })
    } catch (error) {
      send(res, 500, { ok: false, error: String(error?.message ?? error) })
    }
  }
}

function handleState(ctx) {
  return async (req, res) => {
    if (req.method !== 'GET') return send(res, 405, { ok: false, error: 'method-not-allowed' })
    if (!authorized(req)) return send(res, 401, { ok: false, error: 'unauthorized' })
    try {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const wanted = url.searchParams.get('sessionId') ?? ''
      const rows = sessionRows(ctx)
      const matched = wanted === '' ? undefined : rows.find((row) => row.id === wanted)
      const active = matched ?? (wanted === '' ? rows[0] : undefined)
      const entry = active === undefined ? undefined : live.get(active.id)
      // 显式点名但还没活起来（刚新建、还没发第一句）：照样把 id 回给窗口，别把它顶掉。
      const sessionId = wanted !== '' ? wanted : (active?.id ?? '')
      send(res, 200, {
        ok: true,
        sessions: rows,
        sessionId,
        title: active?.title ?? '',
        workspaceId: workspaceOf(ctx, sessionId),
        text: entry?.text ?? '',
        running: active?.running ?? false,
        at: entry?.at ?? 0,
      })
    } catch (error) {
      send(res, 500, { ok: false, error: String(error?.message ?? error) })
    }
  }
}

function handleAsk(ctx) {
  return async (req, res) => {
    if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'method-not-allowed' })
    if (!authorized(req)) return send(res, 401, { ok: false, error: 'unauthorized' })

    let body
    try {
      body = await readJson(req)
    } catch (error) {
      return send(res, 400, { ok: false, error: `bad-body:${error?.message ?? error}` })
    }

    const question = String(body.question ?? '').trim().slice(0, MAX_QUESTION)
    const shot = typeof body.shot === 'string' ? body.shot : ''
    if (question === '' && shot === '') return send(res, 400, { ok: false, error: 'empty-question' })

    const wantedSession = typeof body.sessionId === 'string' ? body.sessionId : ''
    // 点名了会话就必须是它：拿不到就认领，认领不了就报错，别把问题送进别的会话。
    let agent = wantedSession === '' ? pickAgent(ctx, '') : exactAgent(ctx, wantedSession)
    if (agent === undefined && wantedSession !== '') {
      // 刚建的会话还没有活体：`create({sessionId})` 是"新建或认领"，认领后就有 Agent 了。
      const controller = ctx.get('sessionController')
      if (controller !== undefined && controller !== null && typeof controller.create === 'function') {
        try {
          await controller.create({ sessionId: wantedSession })
        } catch (error) {
          report(`认领会话失败：${error?.message ?? error}`)
        }
        agent = exactAgent(ctx, wantedSession)
      }
    }
    if (agent === undefined) return send(res, 409, { ok: false, error: 'no-live-session' })

    const attachments = ctx.get('attachments')
    if (shot !== '' && (attachments === undefined || attachments === null)) {
      return send(res, 503, { ok: false, error: 'attachments-unavailable' })
    }

    const content = []
    if (question !== '') content.push({ type: 'text', text: question })
    let withShot = false
    if (shot !== '') {
      try {
        const ref = await attachments.saveImage({
          data: Buffer.from(shot, 'base64'),
          mediaType: 'image/png',
          name: 'pet-screen.png',
        })
        content.push({ type: 'image', attachment: ref })
        content.push({ type: 'text', text: question === '' ? LOOK_AGAIN_TEXT : '（上图是我此刻的屏幕）' })
        withShot = true
      } catch (error) {
        // 附图失败不该吞掉用户的问题：带上原因继续走纯文本。
        content.push({ type: 'text', text: `（屏幕截图失败：${String(error?.message ?? error)}）` })
      }
    }
    if (content.length === 0) content.push({ type: 'text', text: LOOK_AGAIN_TEXT })

    const id = idOf(agent)
    try {
      agent.followup(userMessage(content))
    } catch (error) {
      return send(res, 500, { ok: false, error: `followup-failed:${error?.message ?? error}` })
    }
    const entry = entryOf(id)
    entry.at = Date.now()
    entry.running = true
    return send(res, 200, { ok: true, sessionId: id, withShot })
  }
}

// ── 会话事件折叠 ─────────────────────────────────────────────────────────────

function onSessionEvent(session, event) {
  const id = typeof session?.id === 'string' ? session.id : ''
  if (id === '') return
  const entry = entryOf(id)
  entry.at = Date.now()
  const type = event?.type
  if (type === 'turn/start') {
    entry.running = true
    return
  }
  if (type === 'turn/end') {
    entry.running = false
    return
  }
  if (type === 'session/title') {
    const title = event?.data?.title
    if (typeof title === 'string' && title.trim() !== '') entry.title = title.trim()
    return
  }
  if (type === 'assistant/message') {
    const blocks = event?.data?.message?.content
    if (!Array.isArray(blocks)) return
    const text = blocks
      .filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text)
      .join('')
      .trim()
    if (text !== '') entry.text = text.slice(-MAX_ANSWER)
  }
}

function onAgentStatus(payload) {
  const id = payload?.agent?.session?.id
  if (typeof id !== 'string' || id === '') return
  entryOf(id).running = payload?.status === 'running'
}

// ── 装配 ─────────────────────────────────────────────────────────────────────

export function apply(ctx, config) {
  const report = (message) => {
    try {
      ctx.logger?.error?.(`[dsh-pet-chat] ${message}`)
    } catch {
      /* 日志失败不影响主流程 */
    }
  }

  // 1. 落地 endpoint.json，供悬浮窗读取 base + token。
  ctx.effect(() => {
    try {
      const port = ctx.webServer?.port
      if (typeof port === 'number' && port > 0) {
        mkdirSync(STATE_DIR, { recursive: true })
        writeFileSync(
          join(STATE_DIR, 'endpoint.json'),
          JSON.stringify({ base: `http://127.0.0.1:${port}`, token: TOKEN, pid: process.pid }, null, 2),
          'utf8',
        )
      }
    } catch (error) {
      report(`写入 endpoint.json 失败：${error?.message ?? error}`)
    }
    return () => {}
  }, 'dsh-pet-chat: endpoint')

  // 2. 两条本机路由。
  ctx.effect(() => {
    const disposers = [
      ctx.webServer.register({ kind: 'exact', path: `${PREFIX}/state`, handler: handleState(ctx) }),
      ctx.webServer.register({ kind: 'exact', path: `${PREFIX}/ask`, handler: handleAsk(ctx) }),
      ctx.webServer.register({ kind: 'exact', path: `${PREFIX}/workspaces`, handler: handleWorkspaces(ctx) }),
      ctx.webServer.register({ kind: 'exact', path: `${PREFIX}/session`, handler: handleCreate(ctx) }),
    ]
    return () => {
      for (const dispose of disposers) {
        try {
          dispose()
        } catch {
          /* 卸载期重复释放忽略 */
        }
      }
    }
  }, 'dsh-pet-chat: routes')

  // 3. 会话增量 → 展示态。
  ctx.effect(() => {
    const offEvent = ctx.on('session/event', onSessionEvent)
    const offStatus = ctx.on('agent/status', onAgentStatus)
    return () => {
      offEvent()
      offStatus()
      live.clear()
    }
  }, 'dsh-pet-chat: session bus')

  // 4. 自动拉起悬浮窗：开机后 dsh 一起来，点鲸鱼娘就有卡片，不用记着双击 cmd。
  //    Launch via `cmd /c start` —— 直接 spawn powershell 在这台机器上会静默秒退（无控制台），
  //    而 `start` 起的进程是独立一条，和 pet-chat.cmd 走的是同一条被验证过的路。
  //    卡片自带单实例互斥锁，重复拉起会立刻自退，所以不必先探测进程。
  if (config?.autoStartCard !== false) {
    ctx.effect(() => {
      if (process.platform !== 'win32' || !existsSync(CARD_SCRIPT)) {
        if (process.platform === 'win32') report(`找不到卡片脚本：${CARD_SCRIPT}`)
        return () => {}
      }
      auditAutostart(`spawn: script=${CARD_SCRIPT} platform=${process.platform}`)
      try {
        const child = spawn(
          'cmd.exe',
          // `/b` + windowsHide：拿得到独立进程、又不闪黑框（不加 /b 时 windowsHide 会连子进程一起掐掉）。
          ['/c', 'start', '', '/b', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', CARD_SCRIPT],
          { cwd: PACKAGE_DIR, stdio: 'ignore', windowsHide: true },
        )
        auditAutostart(`spawn ok pid=${child.pid}`)
        child.on('error', (error) => {
          auditAutostart(`spawn error: ${error?.message ?? error}`)
          report(`拉起悬浮窗失败：${error?.message ?? error}`)
        })
        child.on('exit', (code) => auditAutostart(`spawn exit code=${code}`))
      } catch (error) {
        report(`拉起悬浮窗失败：${error?.message ?? error}`)
      }
      return () => {
        // start 起的进程拿不到 pid，按命令行精确收尸（互斥锁保证只有一个）。
        try {
          spawn(
            'powershell.exe',
            ['-NoProfile', '-Command',
              "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'pet-chat\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"],
            { stdio: 'ignore', windowsHide: true },
          )
        } catch {
          /* 宿主退出阶段，收不掉就算了 */
        }
      }
    }, 'dsh-pet-chat: card autostart')
  }
}
