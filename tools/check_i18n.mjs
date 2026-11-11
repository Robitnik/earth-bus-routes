// Checks the translations of the menu (mod/ui/ui-vue/mods/earthBusRoutes/lang) and the HUD (mod/ui/modules/apps/EarthBusHud/lang)
// against the English base: every key present, none extra, the same {placeholders}, no empty text, no raw line breaks.
//   node tools/check_i18n.mjs            all languages (exit 1 when something is off)
//   node tools/check_i18n.mjs de ja      only these
//   node tools/check_i18n.mjs --allow-missing   a language may lack keys (English fills them); extras and bad placeholders still fail
import fs from "node:fs"
import path from "node:path"
import { pathToFileURL, fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const MENU = path.join(root, "mod/ui/ui-vue/mods/earthBusRoutes")
const HUD = path.join(root, "mod/ui/modules/apps/EarthBusHud")
const args = process.argv.slice(2)
const allowMissing = args.includes("--allow-missing")
const only = args.filter(a => !a.startsWith("--"))

const load = async f => (await import(pathToFileURL(f).href)).default
const ph = s => (String(s).match(/\{\w+\}/g) || []).sort().join(" ")
const problems = []
const complain = (lang, where, msg) => problems.push(`${lang} ${where}: ${msg}`)

function compare(lang, where, base, got) {
  const missing = Object.keys(base).filter(k => !(k in got))
  const extra = Object.keys(got).filter(k => !(k in base))
  if (missing.length && !allowMissing) complain(lang, where, `${missing.length} keys missing, e.g. ${missing.slice(0, 4).join(", ")}`)
  for (const k of extra) complain(lang, where, `extra key ${k}`)
  for (const k of Object.keys(got)) {
    if (!(k in base)) continue
    const v = got[k]
    if (typeof v !== "string" || !v.trim()) { complain(lang, where, `${k}: empty or not a text`); continue }
    if (ph(v) !== ph(base[k])) complain(lang, where, `${k}: placeholders ${ph(v) || "-"} instead of ${ph(base[k]) || "-"}`)
    if (/[\r\n]/.test(v)) complain(lang, where, `${k}: a line break`)
  }
  return { keys: Object.keys(got).length, of: Object.keys(base).length }
}

const { LANGS } = await import(pathToFileURL(path.join(MENU, "langs.js")).href)
const baseMenu = await load(path.join(MENU, "lang/en.js"))
const baseHud = await load(path.join(HUD, "lang/en.js"))
const rows = []
for (const { code } of LANGS) {
  if (code === "en" || (only.length && !only.includes(code))) continue
  const m = compare(code, "menu", baseMenu, await load(path.join(MENU, `lang/${code}.js`)))
  const h = await load(path.join(HUD, `lang/${code}.js`))
  const ht = compare(code, "hud.text", baseHud.text, h.text || {})
  const ha = compare(code, "hud.ach", baseHud.ach, h.ach || {})
  rows.push(`${code.padEnd(8)} menu ${m.keys}/${m.of}  hud ${ht.keys}/${ht.of}  achievements ${ha.keys}/${ha.of}`)
}
// the HUD and the menu name the same achievements the same way: the menu's ach.<id> and the HUD's ach table
for (const { code } of LANGS) {
  if (only.length && !only.includes(code)) continue
  const menu = await load(path.join(MENU, `lang/${code}.js`))
  const hud = await load(path.join(HUD, `lang/${code}.js`))
  for (const [id, name] of Object.entries(hud.ach || {})) {
    if (menu["ach." + id] && menu["ach." + id] !== name) complain(code, "hud.ach", `${id}: "${name}" but the menu says "${menu["ach." + id]}"`)
  }
}
// both copies of langs.js are the same file
if (fs.readFileSync(path.join(MENU, "langs.js"), "utf8") !== fs.readFileSync(path.join(HUD, "langs.js"), "utf8")) {
  problems.push("langs.js differs between the menu and the HUD folder")
}
console.log(rows.join("\n"))
if (problems.length) {
  console.log("\n" + problems.slice(0, 80).join("\n") + (problems.length > 80 ? `\n... and ${problems.length - 80} more` : ""))
  process.exit(1)
}
console.log("translations ok")
