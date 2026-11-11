<template>
  <section class="build">
    <!-- the chain of chosen stations -->
    <div class="card chain">
      <div class="chain-head">
        <h3>{{ t("build.chain") }}</h3>
        <span class="muted small">{{ t("build.count", { n: b.points.length, max: b.maxPoints }) }}</span>
      </div>
      <ol class="strip">
        <template v-for="(p, i) in b.points" :key="i">
          <li class="st" :class="{ last: i === b.points.length - 1 }">
            <span class="dot"><b>{{ i + 1 }}</b></span>
            <span class="nm">{{ p.name }}</span>
            <span v-if="p.station" class="tag">{{ t("near.station") }}</span>
            <button v-if="i === b.points.length - 1 && b.points.length > 1" class="x" :title="t('build.undo')" :aria-label="t('build.undo')" @click="call('uiBuildUndo')">×</button>
          </li>
          <li v-if="i < b.legs.length" class="leg">
            <span v-if="b.legs[i].ready">{{ legText(b.legs[i]) }}</span>
            <span v-else class="muted"><span class="spin small"></span>{{ t("build.road") }}</span>
          </li>
        </template>
      </ol>
      <div class="sum">
        <div v-if="b.km"><b>{{ distKm(b.km) }}</b><span>{{ t("route.length") }}</span></div>
        <div v-if="b.minutes"><b>{{ t("route.min", { n: b.minutes }) }}</b><span>{{ t("route.time") }}</span></div>
      </div>
      <p v-if="b.straight" class="warn">{{ b.pathErr === 'service_old' ? t("build.oldService") : t("build.straight") }}</p>
    </div>

    <!-- where next -->
    <div class="card next">
      <div class="next-head">
        <h3>{{ b.full ? t("build.full") : t("build.next") }}</h3>
        <button v-if="b.points.length > 1" class="btn ghost small-btn" @click="call('uiBuildUndo')">↶ {{ t("build.undo") }}</button>
      </div>
      <form class="search" @submit.prevent="runSearch">
        <input v-model="q" type="text" maxlength="40" :placeholder="t('build.searchPh')" :aria-label="t('build.search')" @keydown.stop @keyup.esc.stop="clearSearch" @input="typed" @focus="typing(true)" @blur="typing(false)" />
        <button type="submit" class="btn" :disabled="q.trim().length < 1 || !!b.busy.search">{{ t("build.searchGo") }}</button>
        <button v-if="b.candKind === 'search'" type="button" class="btn ghost" @click="clearSearch">{{ t("build.nearAgain") }}</button>
      </form>
      <p class="muted small">{{ b.lineName ? t("build.lineStops", { q: b.lineName }) : b.candKind === "lines" ? t("build.linesFor", { q: b.query }) : b.candKind === "search" ? t("build.resultsFor", { q: b.query }) : t("build.ringHint") }}</p>

      <div v-if="b.places && b.places.length" class="places" role="group" :aria-label="t('build.places')">
        <button v-for="pl in b.places" :key="pl.id" class="place-chip" :disabled="!!b.busy.search" @click="call('uiBuildPlace', pl.id)">
          ＋ {{ pl.name }}<small>{{ placeKind(pl) }}</small>
        </button>
      </div>
      <div v-if="b.err" class="notice bad"><p>{{ errText(b.err) }}</p></div>
      <div v-if="b.busy.cands || b.busy.search" class="loading small">
        <span class="spin"></span><div><b>{{ b.busy.search ? t("build.searching") : t("build.loadingCands") }}</b><div class="muted">{{ t("build.loadingHint") }}</div></div>
      </div>
      <div v-else-if="b.candKind === 'lines' && !(b.lineHits || []).length && !b.err" class="empty"><b>{{ t("find.noLines") }}</b><div class="muted">{{ t("find.noLinesHint") }}</div></div>
      <div v-else-if="b.candKind !== 'lines' && !b.cands.length && !b.err" class="empty"><b>{{ b.candKind === "search" ? t("build.noMatch") : t("build.noCands") }}</b>
        <div class="muted">{{ b.candKind === "search" ? t("build.noMatchHint") : t("build.noCandsHint") }}</div></div>
      <div v-if="b.candKind === 'lines'" class="cands" role="list">
        <div v-for="ln in (b.lineHits || [])" :key="ln.id" class="line-hit" role="listitem">
          <span class="plate" :style="{ background: ln.colour, color: ink(ln.colour) }">{{ ln.ref }}</span>
          <div class="variants">
            <button v-for="v in ln.variants" :key="v.id" class="variant" :disabled="!!b.busy.search" @click="call('uiBuildLine', v.id)">
              {{ v.ambiguous ? v.label : (v.from && v.to ? v.from + " → " + v.to : v.label) }}
            </button>
          </div>
        </div>
      </div>
      <div v-else class="cands" role="list">
        <button v-for="c in b.cands" :key="c.id" class="cand-row" :class="{ behind: c.ahead === false, hot: hover === c.id }" role="listitem" :disabled="b.full"
                @click="pick(c.id)" @mouseenter="hover = c.id" @mouseleave="hover = null" @focus="hover = c.id" @blur="hover = null">
          <span class="ic" :class="{ station: c.station }" aria-hidden="true">{{ c.station ? "■" : "●" }}</span>
          <span class="body">
            <span class="cn">{{ c.name }}</span>
            <span class="cm"><b>{{ dist(c.dist) }}</b> <span class="dir">{{ c.dir }}</span><span v-if="c.station" class="tag">{{ t("near.station") }}</span></span>
          </span>
          <span class="plus" aria-hidden="true">＋</span>
        </button>
      </div>
    </div>

    <!-- the map and the next step -->
    <div class="side">
      <div class="map">
        <MiniMap :points="b.points" :line="b.line" :cands="b.showCities ? [] : b.cands" :hover="hover" :places="b.cities || []" :label="t('build.map')"
                 @pick="pick" @hover="hover = $event" @place="id => call('uiBuildCity', id)" />
        <button class="btn cities-btn" :class="{ on: b.showCities }" :disabled="!!b.busy.cities" @click="call('uiBuildCities', !b.showCities)">
          {{ b.busy.cities ? t("build.citiesLoading") : (b.showCities ? t("build.citiesOff") : t("build.cities")) }}
        </button>
      </div>
      <div class="card actions">
        <div class="seg" role="group" :aria-label="t('build.stopsMode')">
          <button :class="{ on: b.mode === 'all' }" @click="call('uiBuildMode', 'all')">{{ t("build.modeAll") }}<small>{{ t("build.modeAllHint") }}</small></button>
          <button :class="{ on: b.mode === 'express' }" @click="call('uiBuildMode', 'express')">{{ t("build.modeExpress") }}<small>{{ t("build.modeExpressHint") }}</small></button>
        </div>
        <button class="btn go" :disabled="!b.canFinish || !!b.busy.path" @click="call('uiBuildStops')">
          {{ b.busy.path ? t("build.road") : t("build.toStops") }}
        </button>
        <button class="btn ghost" :disabled="b.points.length < 2" @click="call('uiSave')">{{ b.justSaved ? "✓ " + t("build.saved") : t("build.save") }}</button>
      </div>
    </div>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, ref } from "vue"
import MiniMap from "./MiniMap.vue"
import { call, distance, typing, plateInk } from "./store.js"
import { t } from "./i18n.js"

const props = defineProps({ s: { type: Object, required: true } })
const b = computed(() => props.s.build)
const units = computed(() => props.s.units)
const hover = ref(null)
const q = ref("")
let timer = null

const ink = plateInk
const dist = m => distance(m, units.value, t)
const distKm = km => (units.value === "mph" ? t("route.mi", { n: (km * 0.6214).toFixed(1) }) : t("route.km", { n: km.toFixed(1) }))
const legText = l => (l.km == null ? "" : distKm(l.km) + " · " + t("route.min", { n: l.min }))
const clean = v => String(v).replace(/[\\"\u0000-\u001f]/g, " ").trim()

function pick(id) { hover.value = null; call("uiBuildAdd", id) }
// as you type: only what the data service already knows (instant); Enter or the button asks the public servers too
function runSearch() { clearTimeout(timer); const v = clean(q.value); if (v.length >= 1) call("uiBuildSearch", v) }
function typed() {
  clearTimeout(timer)
  const v = clean(q.value)
  if (v.length < 1) { call("uiBuildClearSearch"); return }
  timer = setTimeout(() => call("uiBuildSearch", v, true), 250)
}
function clearSearch() { clearTimeout(timer); q.value = ""; call("uiBuildClearSearch") }
onBeforeUnmount(() => { clearTimeout(timer); typing(false) })

function placeKind(pl) {
  const k = "find.kind." + pl.kind
  const v = t(k)
  return v === k ? t("build.mainStation") : t("build.mainStationOf", { kind: v })
}

function errText(e) {
  const key = "build.err." + e
  const s = t(key)
  return s === key ? t("err.generic", { e }) : s
}
</script>

<style scoped lang="scss">
.build { display: grid; grid-template-columns: 310px minmax(0, 1fr) 440px; gap: 16px; min-height: 0; }
.build > .card, .build > .side { min-height: 0; }
.card { display: flex; flex-direction: column; gap: 10px; overflow: hidden; }
.chain-head, .next-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; h3 { margin: 0; } }
.small-btn { padding: 5px 10px; font-size: 13px; }

// the chain: a line diagram, as in the route card
.strip { list-style: none; margin: 0; padding: 0 6px 0 0; flex: 1; min-height: 0; overflow-y: auto; }
.st { position: relative; display: flex; align-items: center; gap: 10px; padding: 2px 0 2px 38px; min-height: 30px;
  .dot { position: absolute; left: 0; top: 1px; width: 28px; height: 28px; border-radius: 50%; background: var(--line); display: grid; place-items: center;
    b { color: var(--ink-on-line); font-size: 14px; font-weight: 800; } }
  .nm { flex: 1; min-width: 0; font-size: 16px; font-weight: 700; line-height: 1.2; }
  .x { flex: none; width: 28px; height: 28px; border: 0; border-radius: 6px; background: var(--panel-3); color: var(--ink); font-size: 18px; line-height: 1; cursor: pointer;
    &:hover { background: #5a2a26; } &:focus-visible { outline: 2px solid var(--line); } } }
.leg { position: relative; margin: 0 0 0 13px; padding: 4px 0 4px 25px; border-left: 4px solid var(--line); font-size: 13px; color: var(--muted); }
.tag { padding: 0 8px; border-radius: 4px; background: var(--panel-3); color: var(--ink); font-size: 12px; white-space: nowrap; }
.sum { display: flex; gap: 10px; div { flex: 1; padding: 8px 10px; border-radius: 8px; background: var(--panel-3); display: flex; flex-direction: column; b { font-size: 20px; } span { font-size: 12px; color: var(--muted); } } }
.warn { margin: 0; color: var(--late); font-size: 13px; line-height: 1.4; }

// where next
.search { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 2px;
  input { flex: 1; min-width: 180px; padding: 10px 12px; border: 0; border-radius: 8px; background: #0f1a20; color: var(--ink); font: inherit; box-shadow: inset 0 0 0 1px var(--hair);
    &::placeholder { color: var(--muted); } &:focus { outline: 2px solid var(--line); outline-offset: 0; } } }
.cands { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 6px; padding-right: 6px; }
.cand-row { display: flex; align-items: center; gap: 12px; width: 100%; padding: 10px 12px; border: 0; border-radius: 10px; background: var(--panel-3); color: var(--ink); font: inherit; text-align: left; cursor: pointer;
  &:hover:not(:disabled), &.hot { background: #36525f; }
  &:focus-visible { outline: 2px solid var(--line); }
  &:disabled { opacity: 0.5; cursor: default; }
  &.behind .cn { opacity: 0.82; }
  .ic { flex: none; width: 18px; text-align: center; font-size: 12px; color: var(--muted); &.station { color: var(--led); font-size: 14px; } }
  .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .cn { font-size: 16px; font-weight: 700; line-height: 1.2; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .cm { display: flex; gap: 8px; align-items: center; color: var(--muted); font-size: 13px; b { color: var(--ink); } }
  .plus { flex: none; width: 28px; height: 28px; display: grid; place-items: center; border-radius: 50%; background: var(--line); color: var(--ink-on-line); font-weight: 800; } }
.loading { display: flex; align-items: center; gap: 12px; padding: 8px 2px; &.small { font-size: 14px; } }
.spin { flex: none; width: 22px; height: 22px; border: 3px solid var(--hair); border-top-color: var(--line); border-radius: 50%; animation: spin 0.9s linear infinite;
  &.small { display: inline-block; width: 12px; height: 12px; border-width: 2px; margin-right: 6px; vertical-align: -1px; } }
@keyframes spin { to { transform: rotate(360deg); } }
.places { display: flex; flex-wrap: wrap; gap: 6px; }
.place-chip { display: inline-flex; flex-direction: column; align-items: flex-start; padding: 5px 12px; border: 0; border-radius: 99px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 800; font-size: 15px; line-height: 1.15; cursor: pointer;
  small { font-weight: 400; font-size: 11px; color: var(--muted); }
  &:hover:not(:disabled) { background: var(--line); color: var(--ink-on-line); small { color: inherit; } }
  &:disabled { opacity: 0.5; cursor: default; } &:focus-visible { outline: 2px solid var(--line); } }
.empty { padding: 14px 2px; line-height: 1.5; }
.line-hit { display: flex; gap: 12px; align-items: flex-start; padding: 10px 12px; border-radius: 10px; background: var(--panel-3);
  .plate { flex: none; min-width: 44px; padding: 2px 10px; display: grid; place-items: center; border-radius: 6px; font-weight: 800; font-size: 18px; }
  .variants { display: flex; flex-wrap: wrap; gap: 6px; }
  .variant { padding: 6px 12px; border: 0; border-radius: 8px; background: var(--panel-2); color: var(--ink); font: inherit; font-weight: 700; cursor: pointer;
    &:hover:not(:disabled) { background: #36525f; } &:disabled { opacity: 0.5; cursor: default; } &:focus-visible { outline: 2px solid var(--line); } } }
.notice { padding: 10px 12px; border-radius: 10px; background: var(--panel-3); box-shadow: inset 4px 0 0 var(--late); line-height: 1.4; }

// map + actions
.side { display: flex; flex-direction: column; gap: 12px; }
.map { position: relative; flex: 1; min-height: 0; border-radius: 10px; overflow: hidden; }
.cities-btn.cities-btn.btn { position: absolute; right: 10px; top: 10px; padding: 6px 12px; font-size: 13px; background: rgba(18, 31, 38, 0.92); box-shadow: inset 0 0 0 1px var(--hair); &.on { background: var(--line); color: var(--ink-on-line); } }
.actions { flex: none; }
.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 6px;
  button { display: flex; flex-direction: column; gap: 2px; min-width: 0; padding: 8px 10px; border: 0; border-radius: 8px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 700; text-align: left; cursor: pointer;
    small { font-weight: 400; color: var(--muted); font-size: 12px; line-height: 1.25; }
    &.on { background: var(--line); color: var(--ink-on-line); small { color: inherit; opacity: 0.85; } }
    &:focus-visible { outline: 2px solid var(--ink); } } }
@media (max-width: 1100px) { .build { grid-template-columns: 280px minmax(0, 1fr); .side { grid-column: 1 / -1; flex-direction: row; .map { flex: 1; } .actions { width: 340px; } } } }
@media (prefers-reduced-motion: reduce) { .spin { animation-duration: 3s; } }
</style>
