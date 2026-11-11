<template>
  <!-- the dispatcher between the trips (screen "shiftLayover") and the summary of a finished shift (screen "shiftResult") -->
  <section v-if="s.screen === 'shiftLayover' && sh && (sh.layover || sh.run)" class="shift card">
    <div class="res-head">
      <span class="plate big" :style="{ background: lineColour, color: ink(lineColour) }">{{ (sh.layover || sh.run).ref }}</span>
      <div>
        <h2>{{ sh.run ? t("layover.run") : t("layover.title") }}</h2>
        <div class="muted">{{ sh.run ? t("layover.runTo", { depot: sh.run.depot, stop: sh.run.stop }) : t("layover.next") }}</div>
      </div>
    </div>

    <template v-if="sh.layover">
      <div class="next">
        <div class="route">{{ sh.layover.from }}<span class="arrow"> → </span>{{ sh.layover.to }}</div>
        <div class="when">
          <span class="led">{{ sh.layover.departsLabel }}</span>
          <span v-if="sh.layover.late > 60" class="late">{{ t("layover.late", { min: Math.ceil(sh.layover.late / 60) }) }}</span>
          <span v-else-if="sh.layover.remaining > 0" class="muted">{{ t("layover.in", { min: Math.ceil(sh.layover.remaining / 60) }) }}</span>
          <span v-else class="ok">{{ t("layover.now") }}</span>
        </div>
        <div class="muted small">{{ t("layover.planned", { time: sh.layover.plannedLabel }) }} · {{ t("layover.clock", { time: sh.layover.nowLabel }) }}</div>
      </div>
      <p v-if="sh.layover.loading" class="muted">{{ t("layover.loading") }}</p>
      <p v-if="sh.layover.away" class="warn">{{ t("layover.away") }}</p>
      <p v-if="sh.layover.clockWound" class="muted small">{{ t("layover.wound") }}</p>
    </template>
    <template v-else>
      <div class="next">
        <div class="when"><span class="led">{{ sh.run.dueLabel }}</span><span class="muted">{{ t("layover.runDue", { time: sh.run.dueLabel }) }}</span>
          <span v-if="sh.run.late > 60" class="late">{{ t("layover.late", { min: Math.ceil(sh.run.late / 60) }) }}</span></div>
        <div v-if="sh.run.dist != null" class="muted">{{ dist(sh.run.dist) }}</div>
      </div>
    </template>

    <p class="muted small">{{ t("layover.endsAt", { time: sh.endsLabel }) }} · {{ t("shiftres.trips") }}: {{ sh.trips }}</p>
    <div class="row">
      <button class="btn go" @click="call('uiClose')">{{ t("layover.back") }}</button>
      <button class="btn danger" :title="t('layover.endSure')" @click="call('uiShiftEnd')">{{ t("layover.end") }}</button>
    </div>
  </section>

  <section v-else-if="s.screen === 'shiftResult' && res" class="shift card">
    <div class="res-head">
      <div>
        <h2>{{ t("shiftres.title") }}</h2>
        <div class="muted">
          {{ t("shiftres.source." + res.source) }}<template v-if="res.depot"> · {{ t(res.depot === "station" ? "shiftres.station" : "shiftres.depot") }}</template>
        </div>
      </div>
      <div class="grade"><b>{{ res.grade }}</b><span>{{ res.points }} {{ t("shiftres.points") }}</span></div>
    </div>
    <dl class="facts row-facts">
      <div><dt>{{ t("shiftres.trips") }}</dt><dd>{{ res.count }}</dd></div>
      <div><dt>{{ t("shiftres.passengers") }}</dt><dd>{{ res.passengers }}</dd></div>
      <div><dt>{{ t("shiftres.punctuality") }}</dt><dd>{{ Math.round(res.punctuality * 100) }} %</dd></div>
      <div><dt>{{ t("shiftres.time") }}</dt><dd>{{ t("shiftres.min", { n: res.minutes }) }}</dd></div>
    </dl>
    <p class="muted small">
      {{ t("shiftres.stops") }}: {{ res.served }} / {{ res.planned }}
      <template v-if="res.skipped"> · {{ t("shiftres.lost") }}: {{ res.skipped }}</template>
      <template v-if="res.lateTrips"> · {{ t("shiftres.late") }}: {{ res.lateTrips }}</template>
      · {{ t("shiftres.revenue") }}: {{ res.revenue.toFixed(2) }}
    </p>
    <ol class="trips">
      <li v-for="(tr, i) in res.trips" :key="i">
        <span class="plate" :style="{ background: tr.colour || '#4aa3df', color: ink(tr.colour) }">{{ tr.ref }}</span>
        <span class="nm">{{ tr.from }} → {{ tr.to }}</span>
        <span v-if="tr.late > 60" class="late small">{{ t("shiftres.minLate", { n: Math.ceil(tr.late / 60) }) }}</span>
        <span class="muted small">{{ tr.passengers }} · {{ Math.round(tr.punctuality * 100) }} %</span>
        <b class="g">{{ tr.grade }}</b>
      </li>
    </ol>
    <div class="row">
      <button class="btn go" @click="call('uiShiftClose')">{{ t("shiftres.new") }}</button>
      <button class="btn ghost" @click="finish">{{ t("shiftres.close") }}</button>
    </div>
  </section>
</template>

<script setup>
import { computed } from "vue"
import { call, distance, plateInk } from "./store.js"
import { t } from "./i18n.js"

const props = defineProps({ s: { type: Object, required: true } })
const sh = computed(() => props.s.shift)
const res = computed(() => props.s.shift && props.s.shift.result)
const lineColour = computed(() => {
  const x = sh.value && (sh.value.layover || sh.value.run)
  return (x && x.colour) || "#4aa3df"
})
const ink = c => plateInk(c)
const dist = m => distance(m, props.s.units, t)
function finish() { call("uiShiftClose"); call("uiClose") }
</script>

<style scoped lang="scss">
.shift { max-width: 820px; margin: 0 auto; display: flex; flex-direction: column; gap: 14px; overflow-y: auto; }
h2 { margin: 0; }
.res-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.plate { display: inline-grid; place-items: center; font-weight: 800; border-radius: 8px; padding: 2px 10px;
  &.big { min-width: 70px; padding: 6px 14px; font-size: 28px; border-radius: 10px; } }
.next { display: flex; flex-direction: column; gap: 6px; padding: 12px 14px; border-radius: 10px; background: var(--panel-3); box-shadow: inset 4px 0 0 var(--line); }
.route { font-size: 20px; font-weight: 800; .arrow { color: var(--muted); } }
.when { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
.led { font-size: 34px; font-weight: 800; color: var(--led); letter-spacing: 1px; }
.late { color: var(--late); font-weight: 700; }
.ok { color: var(--ok); font-weight: 700; }
.warn { margin: 0; color: var(--late); }
p { margin: 0; line-height: 1.4; }
.row { display: flex; gap: 10px; flex-wrap: wrap; }
.grade { display: flex; flex-direction: column; align-items: flex-end; b { font-size: 46px; line-height: 1; color: var(--line); } span { color: var(--muted); font-size: 13px; } }
.facts { margin: 0; display: grid; gap: 12px; grid-template-columns: repeat(4, 1fr);
  div { display: flex; flex-direction: column; gap: 2px; padding: 10px 12px; border-radius: 8px; background: var(--panel-3); }
  dt { color: var(--muted); } dd { margin: 0; font-weight: 700; font-size: 20px; } }
.trips { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px;
  li { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border-radius: 8px; background: var(--panel-3); }
  .nm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .g { font-size: 20px; min-width: 24px; text-align: center; color: var(--line); } }
.small { font-size: 13px; }
</style>
