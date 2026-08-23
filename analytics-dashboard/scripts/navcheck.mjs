// Drive the built app in headless Chrome over CDP and assert the nav/state behaviour.
// usage: node navcheck.mjs <app-origin> <devtools-http-port>
const [origin, port] = process.argv.slice(2)
const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json()
const page = list.find((t) => t.type === 'page')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((r) => (ws.onopen = r))
let id = 0
const pending = new Map()
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data)
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg)
    pending.delete(msg.id)
  }
}
const send = (method, params = {}) =>
  new Promise((resolve) => {
    const i = ++id
    pending.set(i, resolve)
    ws.send(JSON.stringify({ id: i, method, params }))
  })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const evaluate = async (expression) => {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails))
  return r.result?.result?.value
}
const goto = async (path) => {
  await send('Page.navigate', { url: origin + path })
  await sleep(1500)
}
const waitFor = async (selector, ms = 6000) => {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await evaluate(`!!document.querySelector(${JSON.stringify(selector)})`)) return
    await sleep(100)
  }
  throw new Error(`timeout waiting for ${selector}`)
}
const click = async (selector) => {
  await waitFor(selector)
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`)
  await sleep(900)
}
const url = () => evaluate('location.pathname + location.search')
const params = async () => {
  const u = await url()
  const p = new URLSearchParams(u.split('?')[1] ?? '')
  return { path: u.split('?')[0], get: (k) => p.get(k) }
}
const results = []
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail })
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? `: ${detail}` : ''}`)
}

await send('Page.enable')
await send('Runtime.enable')

// 1. pick a week on the board, open a game, Back to board returns to that week
await goto('/nfl/slate?season_type=Regular%20Season&week=2')
await waitFor('.game')
await evaluate(`document.querySelector('.board').scrollTop = 180`)
await sleep(300)
await click('.game')
check('game page opened', (await url()).startsWith('/nfl/games/'), await url())
await click('button.back')
{
  const p = await params()
  check('Back to board returns to week 2', p.path === '/nfl/slate' && p.get('week') === '2' && p.get('season_type') === 'Regular Season', await url())
}
await waitFor('.game')
await sleep(400)
const top = await evaluate(`document.querySelector('.board').scrollTop`)
check('board scroll restored', top > 100, `scrollTop ${top}`)

// 2. dock "Game day" from Home returns to the remembered week
await click('.dock a[href="/nfl"]')
check('home', (await url()) === '/nfl', await url())
await click('.dock a[href^="/nfl/slate"]')
check('dock Game day remembers week 2', (await url()).includes('week=2'), await url())

// 3. book picked on the game page carries back to the board
await click('.game')
await click('.chips[aria-label="Book"] button:nth-child(2)')
const bookUrl = await url()
const picked = (await params()).get('vendor')
await click('button.back')
await sleep(600)
check('book choice follows to the board', (await params()).get('vendor') === picked && (await params()).get('week') === '2', `${bookUrl} -> ${await url()}`)
// and choosing the default book again clears the memory
await click('.chips[aria-label="Book"] button:nth-child(1)')
check('default book clears the vendor param', (await params()).get('vendor') === null, await url())

// 4. dock stays on Game day inside a game
await click('.game')
const active = await evaluate(`document.querySelector('.dock a.active')?.textContent`)
check('dock highlights Game day on a game page', active === 'Game day', String(active))

// 5. deep link into a game: Back to board falls back to the game's week (fresh tab)
await send('Runtime.evaluate', { expression: 'sessionStorage.clear()' })
await send('Page.navigate', { url: origin + '/nfl/games/9d8f5c2f2bcbb264b89a51806e516c96' })
await sleep(1500)
await click('button.back')
check('deep link Back falls back to the board', (await url()).startsWith('/nfl/slate'), await url())

// 6. browser Back after chip clicks leaves the page in one step
await goto('/nfl')
await click('.dock a[href^="/nfl/slate"]')
await click('.chips[aria-label="Season type"] button:nth-child(2)')
await click('.chips[aria-label="Week"] button:nth-child(2)')
await click('.chips[aria-label="Week"] button:nth-child(1)')
check('chips landed on Regular Season W1', (await params()).get('week') === '1', await url())
await evaluate('history.back()')
await sleep(900)
check('browser Back skips chip history', (await url()) === '/nfl', await url())

ws.close()
process.exit(results.every((r) => r.ok) ? 0 : 1)
