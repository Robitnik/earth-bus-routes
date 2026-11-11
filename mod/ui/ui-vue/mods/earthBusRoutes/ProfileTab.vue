<template>
  <div class="profile">
    <div v-if="off" class="card"><b>{{ t("profile.off") }}</b><div class="muted">{{ t("profile.offHint") }}</div></div>
    <div v-else-if="!p" class="card muted">{{ t("profile.loading") }}</div>
    <template v-else>
      <!-- rank and the way to the next one -->
      <section class="card rank">
        <div class="rank-head">
          <div>
            <div class="muted small">{{ t("profile.rank") }}</div>
            <h3 class="rank-name">{{ t("rank." + p.rank.id) }}</h3>
          </div>
          <div class="credits"><b>{{ p.totals.credits }}</b><span>{{ t("profile.credits") }}</span></div>
        </div>
        <template v-if="p.rank.next">
          <div class="meter" role="progressbar" :aria-valuenow="Math.round(p.rank.progress * 100)" aria-valuemin="0" aria-valuemax="100"><i :style="{ width: Math.round(p.rank.progress * 100) + '%' }"></i></div>
          <div class="rank-way">
            <span>{{ t("profile.next", { rank: t("rank." + p.rank.next) }) }}</span>
            <span>{{ t("profile.hours", { have: p.rank.hours, need: p.rank.hoursNeed }) }}</span>
            <span :class="{ ok: p.rank.gradeOk }">{{ t("profile.avgGrade", { grade: p.rank.gradeNeed, have: p.rank.avgLetter || "–" }) }}<template v-if="p.rank.gradeOk"> ✓</template></span>
          </div>
        </template>
        <div v-else class="muted small">{{ t("profile.topRank") }}</div>
        <div class="muted small unlocks">{{ t("profile.opens") }}: {{ opens }}</div>
        <div class="muted small">{{ t("profile.free") }}</div>
      </section>

      <!-- totals -->
      <section class="tiles" :aria-label="t('profile.totals')">
        <div class="tile"><b>{{ km }}</b><span>{{ unitKm }}</span></div>
        <div class="tile"><b>{{ p.totals.passengers }}</b><span>{{ t("profile.passengers") }}</span></div>
        <div class="tile"><b>{{ p.totals.onTimePct == null ? "–" : p.totals.onTimePct + " %" }}</b><span>{{ t("profile.onTime") }}</span></div>
        <div class="tile"><b>{{ p.totals.trips }}</b><span>{{ t("profile.trips") }}</span></div>
        <div class="tile"><b>{{ p.totals.shifts }}</b><span>{{ t("profile.shifts") }}</span></div>
        <div class="tile"><b>{{ p.visited.towns }} / {{ p.visited.stations }}</b><span>{{ t("profile.visited") }}</span></div>
      </section>

      <div class="cols">
        <!-- records per line -->
        <section class="card">
          <h3>{{ t("profile.records") }}</h3>
          <div v-if="!p.records.length" class="muted small">{{ t("profile.noRecords") }}</div>
          <ul v-else class="records">
            <li v-for="r in p.records" :key="r.key">
              <span class="plate">{{ r.ref }}</span>
              <span class="rt">{{ r.from }} → {{ r.to }}</span>
              <b class="pts">{{ r.points }}</b>
              <span class="g" :class="'g' + r.grade">{{ r.grade }}</span>
            </li>
          </ul>
        </section>

        <!-- achievements -->
        <section class="card">
          <div class="ach-head">
            <h3>{{ t("profile.achievements") }}</h3>
            <span class="muted small">{{ p.unlockedCount }} / {{ p.achievements.length }}</span>
          </div>
          <ul class="ach-grid">
            <li v-for="a in p.achievements" :key="a.id" class="ach" :class="{ on: a.unlocked }" :title="t('ach.' + a.id + '.d')">
              <span class="ico" aria-hidden="true">{{ a.unlocked ? "★" : "☆" }}</span>
              <span class="nm">{{ t("ach." + a.id) }}</span>
              <span class="ds">{{ t("ach." + a.id + ".d") }}</span>
            </li>
          </ul>
        </section>
      </div>
      <div class="row"><button class="btn" @click="emit('map')">{{ t("profile.showMap") }}</button></div>
    </template>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { t } from "./i18n.js"

const props = defineProps({ s: { type: Object, default: null } })
const emit = defineEmits(["map"])
const p = computed(() => (props.s && props.s.profile) || null)
const off = computed(() => !!(props.s && props.s.career && props.s.career.on === false))
const mph = computed(() => !!(props.s && props.s.units === "mph"))
const km = computed(() => (p.value ? (mph.value ? p.value.totals.km * 0.6214 : p.value.totals.km).toFixed(1) : ""))
const unitKm = computed(() => t(mph.value ? "profile.unitMi" : "profile.unitKm"))
// what the rank opens: the kinds of lines of its shifts and the shift length
const opens = computed(() => {
  const u = p.value && p.value.rank.unlocks
  if (!u) return ""
  const parts = u.lines.map(k => t("profile.lines." + k))
  parts.push(t("profile.shiftLen", { n: u.shiftHours }))
  if (u.depot) parts.push(t("profile.depot"))
  if (u.heavyEvents) parts.push(t("profile.heavy"))
  return parts.join(", ")
})
</script>

<style scoped lang="scss">
.profile { flex: 1; display: flex; flex-direction: column; gap: 12px; min-height: 0; overflow-y: auto; padding-right: 6px; > * { flex: none; } }
.card { background: var(--panel-2); border-radius: 12px; padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; min-width: 0; h3 { margin: 0; font-size: 17px; } }
.rank-head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; }
.rank-name { font-size: 26px !important; font-weight: 800; color: var(--line); }
.credits { text-align: right; b { display: block; font-size: 26px; font-weight: 800; } span { color: var(--muted); font-size: 13px; } }
.meter { height: 10px; border-radius: 5px; background: var(--hair); overflow: hidden; i { display: block; height: 100%; background: var(--line); border-radius: 5px; } }
.rank-way { display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: 14px; .ok { color: var(--ok, #52d394); font-weight: 700; } }
.unlocks { line-height: 1.35; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 10px; }
.tile { background: var(--panel-2); border-radius: 12px; padding: 12px 14px; display: flex; flex-direction: column; gap: 2px;
  b { font-size: 24px; font-weight: 800; } span { color: var(--muted); font-size: 13px; } }
.cols { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.3fr); gap: 12px; align-items: start; }
@media (max-width: 1000px) { .cols { grid-template-columns: 1fr; } }
.records { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; max-height: 320px; overflow: auto;
  li { display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto; gap: 10px; align-items: center; }
  .plate { min-width: 42px; text-align: center; padding: 2px 8px; border-radius: 6px; background: var(--line); color: var(--ink-on-line); font-weight: 800; }
  .rt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pts { font-variant-numeric: tabular-nums; }
  .g { width: 24px; text-align: center; font-weight: 800; color: var(--led, #ffc233); } }
.ach-head { display: flex; justify-content: space-between; align-items: baseline; }
.ach-grid { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 8px; }
.ach { display: grid; grid-template-columns: auto 1fr; column-gap: 8px; padding: 8px 10px; border-radius: 10px; background: var(--panel-3, rgba(0, 0, 0, 0.2)); opacity: 0.55;
  .ico { grid-row: span 2; font-size: 20px; align-self: center; color: var(--muted); }
  .nm { font-weight: 700; font-size: 14px; line-height: 1.2; }
  .ds { color: var(--muted); font-size: 12px; line-height: 1.25; }
  &.on { opacity: 1; box-shadow: inset 0 0 0 1.5px var(--led, #ffc233); .ico { color: var(--led, #ffc233); } } }
.row { display: flex; gap: 8px; }
</style>
