// Screenshots of the preview pages with the browser Playwright already has on this machine.
//   node shoot.mjs hud approach late atstop ...      (HUD states from mocks.js)
//   node shoot.mjs menu nearby lines route result    (menu screens)
// Starts the Vite dev server itself when nothing listens on 5199. Output: ../../docs/shots/*.png
import { chromium } from "playwright-core"
import { spawn } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import os from "node:os"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const out = path.resolve(here, "../../docs/shots")
fs.mkdirSync(out, { recursive: true })
const [view, ...names] = process.argv.slice(2)
const base = "http://127.0.0.1:5199"

async function up() { try { return (await fetch(base)).ok } catch { return false } }
let server = null
if (!(await up())) {
  server = spawn(process.execPath, [path.join(here, "node_modules/vite/bin/vite.js"), "--port", "5199", "--host", "127.0.0.1"], { cwd: here, stdio: "ignore" })
  for (let i = 0; i < 60 && !(await up()); i++) await new Promise(r => setTimeout(r, 500))
}

const chromeDir = path.join(process.env.LOCALAPPDATA || os.homedir(), "ms-playwright")
const exe = fs.readdirSync(chromeDir).filter(d => d.startsWith("chromium-")).map(d => path.join(chromeDir, d, "chrome-win64", "chrome.exe")).find(fs.existsSync)
const browser = await chromium.launch({ executablePath: exe })
const size = view === "hud" ? { width: 460, height: 640 } : { width: 1600, height: 900 }
const logs = []
for (const name of names) {
  const page = await browser.newPage({ viewport: size, deviceScaleFactor: view === "hud" ? 2 : 1 })
  page.on("console", m => { if (m.type() === "error" || m.type() === "warning") logs.push(`[${name}] ${m.type()}: ${m.text()}`) })
  page.on("pageerror", e => logs.push(`[${name}] pageerror: ${e.message}`))
  const [nm, ...rest] = name.split(":")
  const extra = rest.join(":")
  const url = view === "hud" ? `${base}/?view=hud&state=${nm}${extra ? "&" + extra : ""}` : `${base}/?view=menu&screen=${nm}${extra ? "&" + extra : ""}`
  await page.goto(url)
  await page.waitForTimeout(700)
  // name:click=<css selector> clicks that element before the shot (e.g. a bus dot on the map)
  const click = new URLSearchParams(extra).get("click")
  if (click) { await page.click(click); await page.waitForTimeout(300) }
  const file = path.join(out, `${view}-${nm}.png`)
  await page.screenshot({ path: file })
  console.log("saved", file)
  await page.close()
}
await browser.close()
if (server) server.kill()
if (logs.length) { console.log("--- browser console ---"); console.log(logs.join("\n")) }
