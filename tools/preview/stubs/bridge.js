// The game's Lua bridge: calls are recorded in window.__calls so a test can see what a click asked for.
const calls = []
if (typeof window !== "undefined") window.__calls = calls
export function useBridge() {
  const engineLua = (script, cb) => { calls.push(script); if (typeof cb === "function") cb(null) }
  return { api: { engineLua, activeObjectLua() {} }, lua: new Proxy({}, { get: () => new Proxy(() => {}, { get: () => async () => ({}) }) }), events: {} }
}
export const lua = new Proxy({}, { get: () => new Proxy(() => {}, { get: () => async () => ({}) }) })
