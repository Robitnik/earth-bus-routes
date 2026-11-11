// The menu's languages (langs.js): the game's interface language picks one, a switch on the page overrides it (kept in
// localStorage when the browser lets us). A key a language lacks shows in English.
import { ref } from "vue"
import { useBridge } from "@/bridge"
import { LANGS, isLang, autoLang } from "./langs.js"
import en from "./lang/en.js"
import uk from "./lang/uk.js"
import de from "./lang/de.js"
import es from "./lang/es.js"
import fr from "./lang/fr.js"
import ja from "./lang/ja.js"
import ko from "./lang/ko.js"
import pl from "./lang/pl.js"
import pt_BR from "./lang/pt_BR.js"
import pt_PT from "./lang/pt_PT.js"
import ru from "./lang/ru.js"
import zh_Hans from "./lang/zh_Hans.js"
import zh_Hant from "./lang/zh_Hant.js"

export { LANGS }
export const DICT = { en, uk, de, es, fr, ja, ko, pl, pt_BR, pt_PT, ru, zh_Hans, zh_Hant }

function stored() {
  try { return localStorage.getItem("earthBusRoutes.lang") } catch (e) { return null }
}
const bridge = () => { try { return useBridge() } catch (e) { return null } }
let chosen = stored()
if (!isLang(chosen)) chosen = null
export const lang = ref(chosen || autoLang(bridge()))

// The game's language may arrive after the page opened (the bridge fills it from the settings): looked at again on every update
export function syncLang() {
  if (chosen) return
  const a = autoLang(bridge())
  if (a !== lang.value) lang.value = a
}

export function setLang(l) {
  if (!isLang(l)) return
  chosen = l
  lang.value = l
  try { localStorage.setItem("earthBusRoutes.lang", l) } catch (e) { /* private window: the choice lasts this session */ }
}

// "auto": follow the game again
export function resetLang() {
  chosen = null
  try { localStorage.removeItem("earthBusRoutes.lang") } catch (e) { /* ignore */ }
  lang.value = autoLang(bridge())
}
export const isAuto = () => chosen === null

export function t(key, params) {
  let s = (DICT[lang.value] && DICT[lang.value][key]) || DICT.en[key] || key
  if (params) for (const k of Object.keys(params)) s = s.split("{" + k + "}").join(String(params[k]))
  return s
}

export function noteText(text) { return (DICT[lang.value] && DICT[lang.value]["note." + text]) || DICT.en["note." + text] || text }
