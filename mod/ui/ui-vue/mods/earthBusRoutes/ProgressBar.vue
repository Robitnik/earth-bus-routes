<template>
  <div v-if="p" class="progress" role="status" aria-live="polite">
    <span class="bar" aria-hidden="true"><i></i></span>
    <span class="txt">{{ text }}</span>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { state } from "./store.js"
import { t } from "./i18n.js"

// What the data service is busy with (it says it about once a second while a slow request runs): the server it asks, how long it
// has been waiting, what else is in the queue.
const p = computed(() => {
  const pr = state.value && state.value.progress
  return pr && pr.busy && pr.busy.length ? pr : null
})
const text = computed(() => {
  if (!p.value) return ""
  const b = p.value.busy[0]
  const what = t("prog.label." + b.label)
  const label = what === "prog.label." + b.label ? b.label : what
  const parts = []
  if (b.what === "overpass") {
    parts.push(b.state === "waiting" ? t("prog.waiting", { label }) : t("prog.overpass", { label, mirror: b.mirror, of: b.of }))
  } else if (b.what === "osrm") {
    parts.push(t("prog.osrm"))
  } else if (b.what === "photon") {
    parts.push(t("prog.photon"))
  } else if (b.what === "gtfs") {
    parts.push(b.stage === "index" ? t("prog.gtfs.index", { pct: b.pct || 0 }) : t("prog.gtfs.download", { done: b.done || 0, total: b.total || 0 }))
  } else if (b.what === "geonames") {
    parts.push(t("prog.geonames"))
  } else {
    parts.push(label)
  }
  if (b.what !== "gtfs") parts.push(t("prog.seconds", { n: Math.floor(b.elapsed || 0) }))
  const more = p.value.busy.length - 1
  if (more > 0) parts.push(t("prog.more", { n: more }))
  return parts.join(" · ")
})
</script>

<style scoped lang="scss">
.progress { display: flex; align-items: center; gap: 12px; padding: 6px 20px; background: var(--panel-3); border-bottom: 1px solid var(--hair); font-size: 14px; }
.bar { flex: none; position: relative; width: 120px; height: 6px; border-radius: 3px; background: var(--hair); overflow: hidden;
  i { position: absolute; top: 0; bottom: 0; width: 40%; border-radius: 3px; background: var(--line); animation: slide 1.2s ease-in-out infinite; } }
@keyframes slide { 0% { left: -40%; } 100% { left: 100%; } }
.txt { color: var(--ink); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
@media (prefers-reduced-motion: reduce) { .bar i { animation: none; left: 30%; } }
</style>
