<template>
  <!-- The next departures of a station, live: the buses of the lines run to their timetables (plan 007) -->
  <section class="board" :aria-label="t('board.title')">
    <div class="board-head">
      <h3>{{ t("board.title") }}</h3>
      <span class="live" :title="t('board.liveTip')"><i></i>{{ t("board.live") }}</span>
    </div>
    <ul v-if="board.rows && board.rows.length" class="rows">
      <li v-for="r in board.rows" :key="r.key" :class="r.state">
        <span class="plate" :style="{ background: r.colour, color: ink(r.colour) }">{{ r.ref }}</span>
        <div class="what">
          <div class="head">{{ r.head }}</div>
          <div class="sub"><span class="in">{{ inText(r) }}</span><span v-if="r.late >= 1" class="late" :title="t('board.lateTip')">+{{ r.late }} {{ t("board.min") }}</span></div>
        </div>
        <span class="time">{{ r.time }}</span>
      </li>
    </ul>
    <p v-else-if="board.loading" class="muted empty"><span class="spin"></span>{{ t("board.loading") }}</p>
    <p v-else class="muted empty">{{ board.lines ? t("board.none") : t("board.noLines") }}</p>
  </section>
</template>

<script setup>
import { plateInk } from "./store.js"
import { t } from "./i18n.js"

defineProps({ board: { type: Object, required: true } })
const ink = plateInk
function inText(r) {
  if (r.state === "stop") return t("board.atStop")
  return r.inMin <= 0 ? t("board.now") : t("board.in", { n: r.inMin })
}
</script>

<style scoped lang="scss">
.board { background: var(--panel-2); border-radius: 12px; padding: 14px 16px; }
.board-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 6px; h3 { margin: 0; } }
.live { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em;
  i { width: 8px; height: 8px; border-radius: 50%; background: #2f9e6a; animation: pulse 2s ease-in-out infinite; } }
.rows { list-style: none; margin: 0; padding: 0; }
li { display: grid; grid-template-columns: 46px minmax(0, 1fr) auto; align-items: center; gap: 10px; padding: 6px 0; border-top: 1px solid var(--hair);
  &:first-child { border-top: 0; } }
.plate { text-align: center; padding: 1px 4px; border-radius: 5px; font-weight: 800; }
.head { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sub { display: flex; gap: 8px; font-size: 13px; color: var(--muted); }
.late { font-weight: 800; color: #e0735a; }
.time { color: var(--led); font-weight: 800; font-size: 17px; font-variant-numeric: tabular-nums; }
li.stop .in { color: #2f9e6a; font-weight: 800; }
li.run .in { color: var(--ink); }
.empty { display: flex; align-items: center; gap: 10px; margin: 6px 0 0; }
.spin { flex: none; width: 16px; height: 16px; border: 2px solid var(--hair); border-top-color: var(--line); border-radius: 50%; animation: spin 0.9s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes pulse { 50% { opacity: 0.35; } }
@media (prefers-reduced-motion: reduce) { .live i, .spin { animation: none; } }
</style>
