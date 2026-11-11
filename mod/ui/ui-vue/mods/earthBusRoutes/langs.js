// The languages of the add-on: the ones BeamNG.drive itself offers (its locales folder: de_DE, en-US, es_419, es_ES, fr_FR, ja_JP,
// ko_KR, pl_PL, pt_BR, pt_PT, ru_RU, zh_Hans, zh_Hant) and Ukrainian. Spanish is one text for Spain and Latin America.
// The same file sits in the menu's and the HUD's folders (the two are loaded apart).
export const LANGS = [
  { code: "en", name: "English" },
  { code: "uk", name: "Українська" },
  { code: "de", name: "Deutsch" },
  { code: "es", name: "Español" },
  { code: "fr", name: "Français" },
  { code: "ja", name: "日本語" },
  { code: "ko", name: "한국어" },
  { code: "pl", name: "Polski" },
  { code: "pt_BR", name: "Português (Brasil)" },
  { code: "pt_PT", name: "Português (Portugal)" },
  { code: "ru", name: "Русский" },
  { code: "zh_Hans", name: "简体中文" },
  { code: "zh_Hant", name: "繁體中文" },
]

const CODES = new Set(LANGS.map(l => l.code))
export const isLang = c => CODES.has(c)

// A language tag of the game ("de-DE", "de_DE", "zh-Hans", "es-419", "pt-BR") or of the browser -> one of the codes above, or null
export function fromTag(tag) {
  const s = String(tag || "").replace(/_/g, "-").toLowerCase()
  if (!s) return null
  if (s.startsWith("zh")) return /hant|-tw|-hk|-mo/.test(s) ? "zh_Hant" : "zh_Hans"
  if (s.startsWith("pt")) return /^pt-pt/.test(s) ? "pt_PT" : "pt_BR"
  const two = s.slice(0, 2)
  if (two === "be") return "uk"                     // Belarusian readers: the nearest we have
  return CODES.has(two) ? two : null
}

// The game's own interface language (settings.uiLanguage, which the UI bridge keeps), else the browser's, else English
export function autoLang(bridge) {
  let tag = null
  try { tag = bridge && bridge.units && bridge.units.userSettings && bridge.units.userSettings.uiLanguage } catch (e) { /* no bridge */ }
  return fromTag(tag) || fromTag(typeof navigator !== "undefined" ? navigator.language : "") || "en"
}
