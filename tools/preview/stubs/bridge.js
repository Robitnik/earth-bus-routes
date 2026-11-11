// The game's Lua bridge: calls are recorded in window.__calls so a test can see what a click asked for.
const calls = []
if (typeof window !== "undefined") window.__calls = calls
export function useBridge() {
  const engineLua = (script, cb) => { calls.push(script); if (typeof cb === "function") cb(null) }
  // the game's interface language (?uilang=de-DE in the preview's address), as the real bridge's units.userSettings
  const uiLanguage = (typeof location !== "undefined" && new URLSearchParams(location.search).get("uilang")) || "en-US"
  return { units: { userSettings: { uiLanguage } }, api: { engineLua, activeObjectLua() {} }, lua: new Proxy({}, { get: () => new Proxy(() => {}, { get: () => async () => ({}) }) }), events: {} }
}
export const lua = new Proxy({}, { get: () => new Proxy(() => {}, { get: () => async () => ({}) }) })
