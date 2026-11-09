import { createApp, h } from "vue"
import Hud from "@game/hud"
import { HUD_STATES } from "./mocks.js"

const q = new URLSearchParams(location.search)
const view = q.get("view") || "hud"
const app = document.getElementById("app")

if (view === "hud") {
  const w = Number(q.get("w") || 380), hh = Number(q.get("h") || 470)
  Object.assign(app.style, { right: "20px", top: "110px", width: w + "px", height: hh + "px" })
  createApp(Hud).mount(app)
  const state = HUD_STATES[q.get("state") || "approach"]
  setTimeout(() => window.__emit("EarthBusRoutesHud", JSON.parse(JSON.stringify(state))), 30)
} else {
  import("@mod/menu").then(async m => {
    const { MENU_STATES } = await import("./mocks.js")
    Object.assign(app.style, { inset: "0" })
    createApp(m.default).mount(app)
    setTimeout(() => window.__emit("EarthBusRoutesState", JSON.parse(JSON.stringify(MENU_STATES[q.get("screen") || "nearby"]))), 30)
  })
}
