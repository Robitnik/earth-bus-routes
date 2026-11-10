// The menu's state and calls into Lua (lua/ge/extensions/earthBusRoutes/main.lua). The game's UI browser cannot fetch anything
// itself: Lua publishes the whole model with guihooks.trigger('EarthBusRoutesState', model) after every change, and the page
// asks for actions through bngApi.engineLua.
import { ref } from "vue"

export const state = ref(null)

export function engineLua(script) {
  if (window.bngApi && window.bngApi.engineLua) window.bngApi.engineLua(script)
}

// call("uiSelectStation", 3) -> earthBusRoutes_main.uiSelectStation(3)
export function call(fn, ...args) {
  const a = args.map(v => (typeof v === "string" ? JSON.stringify(v) : String(v))).join(", ")
  engineLua(`if earthBusRoutes_main then earthBusRoutes_main.${fn}(${a}) end`)
}

// While a text field has the focus the game must not treat the keys as controls (it would drive the car, open menus...)
export function typing(on) { engineLua(`if setCEFTyping then setCEFTyping(${on ? "true" : "false"}) end`) }

export function onState(model) { state.value = model }

// ---- small formatting helpers shared by the pages
export const pad = n => String(n).padStart(2, "0")
export function clock(sec) {
  const s = Math.floor(((sec % 86400) + 86400) % 86400)
  return pad(Math.floor(s / 3600)) + ":" + pad(Math.floor((s % 3600) / 60))
}
export function distance(m, units, t) {
  if (units === "mph") {
    const ft = m * 3.28084
    return ft < 1000 ? Math.round(ft / 10) * 10 + " ft" : (m / 1609.344).toFixed(1) + " mi"
  }
  return m < 1000 ? Math.round(m) + " " + t("units.m") : (m / 1000).toFixed(1) + " " + t("units.km")
}
// A plate's text colour: dark on light line colours, white on dark ones
export function plateInk(hex) {
  const m = /^#([0-9a-f]{6})$/i.exec(hex || "")
  if (!m) return "#0b1a22"
  const n = parseInt(m[1], 16)
  const lum = (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255
  return lum > 0.55 ? "#0b1a22" : "#ffffff"
}
