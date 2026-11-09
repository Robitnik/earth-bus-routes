// A browser stand-in for the game's UI: the app's real .vue files with stubs for the game's modules (@/bridge, @/services/events).
import { defineConfig } from "vite"
import vue from "@vitejs/plugin-vue"
import path from "node:path"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const stub = name => path.resolve(here, "stubs", name)
const repo = path.resolve(here, "../..")

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: [
      { find: /^@\/bridge$/, replacement: stub("bridge.js") },
      { find: /^@\/services\/events$/, replacement: stub("events.js") },
      { find: /^@\/common\/components\/base$/, replacement: stub("base.js") },
      { find: /^@game\/hud$/, replacement: path.resolve(repo, "mod/ui/modules/apps/EarthBusHud/app.vue") },
      { find: /^@mod\/menu$/, replacement: path.resolve(repo, "mod/ui/ui-vue/mods/earthBusRoutes/BusMenu.vue") },
    ],
  },
  server: { fs: { allow: [repo] } },
})
