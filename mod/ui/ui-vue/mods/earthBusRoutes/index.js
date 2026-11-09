// Earth Bus Routes: the menu page as a standalone route ("earthBusRoutes", opened by earthBusRoutes_main.uiOpen through
// ui_router.navigate) and a button in the pause menu's shared Mods tab. Follows ui/ui-vue/mods/README.md of the game
// ("Standalone routes", "Pause menu"); any failure is logged and leaves the game's own UI alone.
import { lua } from "@/bridge"

const MOD_ROOT = "/ui/ui-vue/mods/earthBusRoutes"
const SOURCE = "earthBusRoutes.routes"
const BUTTON_ID = "earthBusRoutes-open"

function toLuaRoutes(records) {
  return records.map(record => ({ name: record.name, path: record.path, meta: record.meta }))
}

async function registerRoute() {
  try {
    if (!window.bngRoutes || !lua.extensions.ui_router_routeManager) return
    const BusMenu = (await import("./BusMenu.vue")).default
    const routes = [
      {
        path: "/earth-bus-routes",
        name: "earthBusRoutes",
        component: BusMenu,
        meta: { luaRoute: { title: "Bus routes", backTarget: "play" } },
      },
    ]
    window.bngRoutes.add([{ path: SOURCE, routes }])
    const result = await lua.extensions.ui_router_routeManager.registerModRoutes(SOURCE, toLuaRoutes(routes))
    if (!result?.success) {
      window.bngRoutes.remove([SOURCE])
      console.error("Earth Bus Routes: route not registered", result?.errors)
    }
  } catch (e) {
    console.error("Earth Bus Routes: route failed", e)
  }
}

async function registerButton() {
  try {
    await lua.extensions.ui_pause_actions.registerModButton({
      id: BUTTON_ID,
      tabId: "mods",
      label: "Bus routes",
      icon: "bus",
      componentName: `${MOD_ROOT}/PauseCard.vue`,
    })
  } catch (e) {
    console.error("Earth Bus Routes: pause menu button failed", e)
  }
}

export async function onLoad() {
  await registerRoute()
  await registerButton()
}

export async function onUnload() {
  try { await lua.extensions.ui_pause_actions.unregisterModButton(BUTTON_ID) } catch (e) { /* none */ }
  try {
    if (window.bngRoutes) window.bngRoutes.remove([SOURCE])
    if (lua.extensions.ui_router_routeManager) {
      await lua.extensions.ui_router_routeManager.unregisterModRoutes(SOURCE, { fallbackRoute: "play" })
    }
  } catch (e) {
    console.error("Earth Bus Routes: unload failed", e)
  }
}
