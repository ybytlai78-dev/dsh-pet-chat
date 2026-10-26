/**
 * 宿主半边自检：用一个桩 ctx 起真 HTTP 服务，跑通
 * 鉴权 → 会话列表 → 带图提问 → 消息装配 → 事件折叠 → 状态回读。
 *
 *   node verify/selfcheck.mjs      # 全绿退出码 0，任一断言失败退出码 1
 *
 * 桩只提供被用到的五个服务（agents / attachments / sessionTitle / workspaceRegistry / sessionController），
 * 走 `ctx.get()` 与真实宿主同一取用方式。
 */
import { createServer } from 'node:http'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const home = mkdtempSync(join(tmpdir(), 'pet-chat-check-'))
process.env.DSH_HOME = home

const PNG_1PX =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

const calls = { followup: [], saved: [], effects: [], errors: [], created: [] }
const routes = new Map()
const bus = new Map()

const agent = {
  session: { id: 'session-abc12345' },
  status: 'idle',
  followup(message) {
    calls.followup.push(message)
  },
}

const services = {
  agents: {
    list: () => [agent],
    get: (id) => (id === 'session-abc12345' ? agent : undefined),
  },
  attachments: {
    async saveImage(input) {
      calls.saved.push(input)
      return { id: 'img-1', mediaType: input.mediaType, bytes: input.data.length }
    },
  },
  sessionTitle: { get: () => ({ title: '自检会话' }) },
  workspaceRegistry: {
    list: () => [
      { id: 'ws-alpha', title: '阿尔法', path: 'C:/alpha', sessionIds: ['session-abc12345'] },
      { id: 'ws-beta', title: '贝塔', path: 'C:/beta', sessionIds: [] },
    ],
  },
  sessionController: {
    async create(request) {
      calls.created.push(request)
      // 认领已知会话 → 让它变成活体；否则造一个新的。
      if (request?.sessionId) {
        services.agents.get = (id) => (id === request.sessionId ? agent : undefined)
        return { sessionId: request.sessionId }
      }
      return { sessionId: 'session-new00001', agentPreset: 'router-standard' }
    },
  },
}

const server = createServer((req, res) => {
  const handler = routes.get(new URL(req.url, 'http://127.0.0.1').pathname)
  if (handler === undefined) {
    res.writeHead(404).end('not found')
    return
  }
  Promise.resolve(handler(req, res)).catch((error) => {
    res.writeHead(500).end(String(error))
  })
})
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const port = server.address().port

const ctx = {
  webServer: {
    port,
    register(route) {
      routes.set(route.path, route.handler)
      return () => routes.delete(route.path)
    },
  },
  get: (name) => services[name],
  effect(execute, label) {
    calls.effects.push(label)
    return execute()
  },
  on(name, listener) {
    if (!bus.has(name)) bus.set(name, [])
    bus.get(name).push(listener)
    return () => {}
  },
  logger: { error: (message) => calls.errors.push(message) },
}

const fail = []
function check(name, condition, detail = '') {
  if (condition) {
    console.log(`  ok   ${name}`)
  } else {
    fail.push(`${name}${detail === '' ? '' : ` — ${detail}`}`)
    console.log(`  FAIL ${name} ${detail}`)
  }
}

const mod = await import('../lib/index.js')
mod.apply(ctx)

const endpoint = JSON.parse(readFileSync(join(home, 'pet-chat', 'endpoint.json'), 'utf8'))
const base = `http://127.0.0.1:${port}`
const auth = { 'x-pet-token': endpoint.token }

console.log('endpoint / 鉴权')
check('endpoint.json 写对了端口', endpoint.base === base, endpoint.base)
check('endpoint.json 带 token', /^[0-9a-f-]{36}$/.test(endpoint.token ?? ''))
const wantedEffects = ['dsh-pet-chat: endpoint', 'dsh-pet-chat: routes', 'dsh-pet-chat: session bus', 'dsh-pet-chat: card autostart']
check('四条 effect 都装了（含自启卡片）', wantedEffects.every((n) => calls.effects.includes(n)), JSON.stringify(calls.effects))

check('无 token → 401', (await fetch(`${base}/api/pet-chat/state`)).status === 401)
check('错 token → 401', (await fetch(`${base}/api/pet-chat/state`, { headers: { 'x-pet-token': 'nope' } })).status === 401)

console.log('GET /state')
const state1 = await (await fetch(`${base}/api/pet-chat/state`, { headers: auth })).json()
check('ok=true', state1.ok === true)
check('会话 id 取自 session.id', state1.sessions?.[0]?.id === 'session-abc12345', JSON.stringify(state1.sessions))
check('标题走 sessionTitle 服务', state1.sessions?.[0]?.title === '自检会话', state1.sessions?.[0]?.title)
check('默认空闲', state1.running === false)

console.log('POST /ask（带屏）')
const ask = await fetch(`${base}/api/pet-chat/ask`, {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ question: '这是啥', shot: PNG_1PX }),
})
const askBody = await ask.json()
check('ok=true', askBody.ok === true, JSON.stringify(askBody))
check('withShot=true', askBody.withShot === true)
check('saveImage 收到 png', calls.saved[0]?.mediaType === 'image/png' && calls.saved[0]?.data?.length > 40)
check('saveImage 收到文件名', calls.saved[0]?.name === 'pet-screen.png')

const message = calls.followup[0]
check('注入了一条 user 消息', message?.role === 'user')
check('消息有 uuid', /^[0-9a-f-]{36}$/.test(message?.id ?? ''))
check('消息被冻结', Object.isFrozen(message) && Object.isFrozen(message.content))
const blocks = message?.content ?? []
check('内容块顺序 = 文本 / 图 / 文本', blocks.length === 3 && blocks[0].type === 'text' && blocks[1].type === 'image' && blocks[2].type === 'text', JSON.stringify(blocks.map((b) => b.type)))
check('图块挂 attachment ref', blocks[1]?.attachment?.id === 'img-1')

console.log('工作区与新建会话')
check('端点数是四条', routes.size === 4, String(routes.size))
const ws = await (await fetch(`${base}/api/pet-chat/workspaces?sessionId=session-abc12345`, { headers: auth })).json()
check('/workspaces ok', ws.ok === true)
check('/workspaces 列出两个工作区', ws.workspaces?.length === 2, JSON.stringify(ws.workspaces?.map((w) => w.id)))
check('/workspaces 认出所属工作区', ws.workspaceId === 'ws-alpha', ws.workspaceId)
check('/workspaces 带会话数', ws.workspaces?.[0]?.sessions === 1, String(ws.workspaces?.[0]?.sessions))
check('/workspaces 无 token → 401', (await fetch(`${base}/api/pet-chat/workspaces`)).status === 401)

const created = await (await fetch(`${base}/api/pet-chat/session`, {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ workspaceId: 'ws-beta' }),
})).json()
check('/session 建出会话', created.ok === true && created.sessionId === 'session-new00001', JSON.stringify(created))
check('/session 预设走默认（未指定 → controller 自己决定）', created.agentPreset === 'router-standard', created.agentPreset)
check('/session 透传 workspaceId', calls.created.at(-1)?.workspaceId === 'ws-beta', JSON.stringify(calls.created.at(-1)))
check('/session 空 body 也受理', (await (await fetch(`${base}/api/pet-chat/session`, {
  method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: '{}',
})).status) === 200)
check('/session GET → 405', (await fetch(`${base}/api/pet-chat/session`, { headers: auth })).status === 405)

const pending = await (await fetch(`${base}/api/pet-chat/state?sessionId=session-new00001`, { headers: auth })).json()
check('/state 保留还没活起来的新会话 id', pending.sessionId === 'session-new00001', pending.sessionId)

const adopted = await (await fetch(`${base}/api/pet-chat/ask`, {
  method: 'POST',
  headers: { ...auth, 'content-type': 'application/json' },
  body: JSON.stringify({ sessionId: 'session-ghost0001', question: '认领我' }),
})).json()
check('/ask 认领未活会话后仍投递', adopted.ok === true, JSON.stringify(adopted))
check('认领时调了 controller.create({sessionId})', calls.created.some((r) => r.sessionId === 'session-ghost0001'), JSON.stringify(calls.created))

console.log('事件折叠')
for (const listener of bus.get('session/event') ?? []) {
  listener(agent.session, { type: 'turn/start', data: { turn: 1 } })
  listener(agent.session, { type: 'assistant/message', data: { message: { content: [{ type: 'text', text: '这是答案' }] } } })
}
const running = await (await fetch(`${base}/api/pet-chat/state?sessionId=session-abc12345`, { headers: auth })).json()
check('回合中 running=true', running.running === true)
check('回读到答案正文', running.text === '这是答案', JSON.stringify(running.text))

for (const listener of bus.get('session/event') ?? []) {
  listener(agent.session, { type: 'turn/end', data: { turn: 1, reason: 'success' } })
}
const idle = await (await fetch(`${base}/api/pet-chat/state`, { headers: auth })).json()
check('回合结束 running=false', idle.running === false)

console.log('边界')
check('空问题 + 无图 → 400', (await fetch(`${base}/api/pet-chat/ask`, { method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: '{}' })).status === 400)
check('GET /ask → 405', (await fetch(`${base}/api/pet-chat/ask`, { headers: auth })).status === 405)
check('未知路径 → 404', (await fetch(`${base}/api/pet-chat/nope`, { headers: auth })).status === 404)
check('无内部错误日志', calls.errors.length === 0, JSON.stringify(calls.errors))

server.close()
if (fail.length > 0) {
  console.log(`\nSELFCHECK FAIL ${fail.length} 项`)
  process.exitCode = 1
} else {
  console.log('\nSELFCHECK PASS')
}
