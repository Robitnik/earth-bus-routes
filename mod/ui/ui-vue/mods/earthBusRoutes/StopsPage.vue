<template>
  <section class="stops-page">
    <!-- stops of the route -->
    <div class="card list">
      <div class="head">
        <div>
          <h3>{{ t("stops.title") }}</h3>
          <p class="muted small">{{ b.mode === "all" ? t("stops.hintAll") : t("stops.hintExpress") }}</p>
        </div>
        <span class="count">{{ onCount }}</span>
      </div>
      <div class="seg" role="group" :aria-label="t('build.stopsMode')">
        <button :class="{ on: b.mode === 'all' }" @click="setMode('all')">{{ t("build.modeAll") }}</button>
        <button :class="{ on: b.mode === 'express' }" @click="setMode('express')">{{ t("build.modeExpress") }}</button>
      </div>
      <div v-if="b.busy.along" class="loading"><span class="spin"></span><div><b>{{ t("stops.loading") }}</b><div class="muted">{{ t("stops.loadingHint") }}</div></div></div>
      <div v-else-if="b.alongErr && b.mode === 'all'" class="notice">
        <p>{{ alongText }}</p>
        <button class="btn" @click="call('uiBuildRetryAlong')">{{ t("retry") }}</button>
      </div>
      <ol class="strip">
        <li v-for="st in (b.stops || [])" :key="st.id" :class="{ chosen: st.chosen, off: !st.on }">
          <span class="dot"></span>
          <span class="nm">{{ st.name }}</span>
          <span class="km">{{ km(st.km) }}</span>
          <span v-if="st.chosen" class="tag">{{ t("stops.chosen") }}</span>
          <button v-else class="sw" role="switch" :aria-checked="st.on" :aria-label="st.name" :class="{ on: st.on }" @click="call('uiBuildToggleStop', st.id)"><i></i></button>
        </li>
      </ol>
    </div>

    <!-- the map, the plate and the end -->
    <div class="right">
      <div class="map"><MiniMap :points="b.points" :line="b.line" :stops="mapStops" :show-names="false" :label="t('build.map')" /></div>
      <div class="card meta">
        <div class="plate-row">
          <span class="plate huge" :style="{ background: b.colour, color: ink(b.colour) }">{{ b.ref || "My" }}</span>
          <div class="fields">
            <label>{{ t("meta.ref") }}
              <input v-model="refText" type="text" maxlength="6" :placeholder="t('meta.refPh')" @keydown.stop @input="send" @focus="typing(true)" @blur="typing(false)" />
            </label>
            <label>{{ t("meta.name") }}
              <input v-model="nameText" type="text" maxlength="60" :placeholder="autoName" @keydown.stop @input="send" @focus="typing(true)" @blur="typing(false)" />
            </label>
          </div>
        </div>
        <div class="swatches" role="group" :aria-label="t('meta.colour')">
          <button class="sw-auto" :class="{ on: !b.customColour }" @click="setColour('')">{{ t("meta.auto") }}</button>
          <button v-for="c in COLOURS" :key="c" class="swatch" :class="{ on: b.customColour === c }" :style="{ background: c }" :aria-label="c" @click="setColour(c)"></button>
        </div>
        <p v-if="b.straight" class="warn">{{ b.pathErr === 'service_old' ? t("build.oldService") : t("build.straight") }}</p>
        <p v-if="s.error" class="warn">{{ s.error }}</p>
        <div class="row">
          <button class="btn ghost" @click="call('uiBackTo', 'build')">{{ t("back") }}</button>
          <button class="btn ghost" @click="call('uiSave')">{{ b.justSaved ? "✓ " + t("build.saved") : t("build.save") }}</button>
          <button class="btn go" :disabled="!!s.loading || !!b.busy.along" @click="call('uiBuildFinish')">{{ s.loading === "route" ? t("stops.building") : t("stops.create") }}</button>
        </div>
      </div>
    </div>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, ref, watch } from "vue"
import MiniMap from "./MiniMap.vue"
import { call, plateInk, typing } from "./store.js"
import { t } from "./i18n.js"

const props = defineProps({ s: { type: Object, required: true } })
const b = computed(() => props.s.build)
const units = computed(() => props.s.units)

const COLOURS = ["#2f9e8f", "#c0572b", "#4a6fc7", "#c9a227", "#8a4fb0", "#2d8f4e", "#c23b5a", "#4a4f57"]
const ink = plateInk
const refText = ref(b.value.ref || "")
const nameText = ref(b.value.name || "")

const autoName = computed(() => {
  const p = b.value.points
  return (b.value.ref || "My") + ": " + (p[0] ? p[0].name : "") + " ⇒ " + (p[p.length - 1] ? p[p.length - 1].name : "")
})
const onCount = computed(() => (b.value.stops || []).filter(x => x.on).length)
const mapStops = computed(() => (b.value.stops || []).filter(x => !x.chosen))
const km = v => (units.value === "mph" ? (v * 0.6214).toFixed(1) : v.toFixed(1))
const alongText = computed(() => {
  const e = b.value.alongErr
  const key = "stops.err." + e
  const s = t(key)
  return s === key ? t("stops.err.other", { e }) : s
})

const clean = v => String(v).replace(/[\\"\u0000-\u001f]/g, " ")
let timer = null
function send() {
  clearTimeout(timer)
  timer = setTimeout(() => call("uiBuildMeta", clean(refText.value).trim(), b.value.customColour || "", clean(nameText.value).trim()), 250)
}
onBeforeUnmount(() => { clearTimeout(timer); typing(false) })
function setColour(c) { call("uiBuildMeta", clean(refText.value).trim(), c, clean(nameText.value).trim()) }
function setMode(m) {
  call("uiBuildMode", m)
  if (m === "all") call("uiBuildStops")
}
watch(() => b.value.ref, v => { if (v !== refText.value.trim()) refText.value = v })
</script>

<style scoped lang="scss">
.stops-page { display: grid; grid-template-columns: minmax(0, 1fr) 460px; gap: 16px; min-height: 0; }
.card { display: flex; flex-direction: column; gap: 10px; min-height: 0; }
.head { display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; h3 { margin: 0 0 2px; } }
.count { flex: none; min-width: 44px; padding: 4px 10px; border-radius: 99px; background: var(--panel-3); text-align: center; font-weight: 800; font-size: 18px; }
.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 6px;
  button { padding: 8px 10px; border: 0; border-radius: 8px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 700; cursor: pointer;
    &.on { background: var(--line); color: var(--ink-on-line); } &:focus-visible { outline: 2px solid var(--ink); } } }
.strip { list-style: none; margin: 0; padding: 0 6px 0 0; flex: 1; min-height: 0; overflow-y: auto; }
.strip li { position: relative; display: flex; align-items: center; gap: 10px; padding: 0 0 8px 26px; min-height: 30px; font-size: 15px;
  &::before { content: ""; position: absolute; left: 7px; top: 14px; bottom: -8px; width: 4px; border-radius: 2px; background: var(--line); opacity: 0.9; }
  &:last-child::before { display: none; }
  .dot { position: absolute; left: 3px; top: 5px; width: 12px; height: 12px; box-sizing: border-box; border-radius: 50%; border: 3px solid var(--line); background: var(--panel-2); z-index: 1; }
  .nm { flex: 1; min-width: 0; line-height: 1.2; }
  .km { color: var(--muted); font-size: 13px; }
  &.chosen .nm { font-weight: 800; font-size: 17px; }
  &.chosen .dot { background: var(--line); width: 16px; height: 16px; left: 1px; top: 3px; }
  &.off { .nm, .km { opacity: 0.45; text-decoration: line-through; } &::before { opacity: 0.3; } } }
.tag { padding: 0 8px; border-radius: 4px; background: var(--panel-3); font-size: 12px; white-space: nowrap; }
.sw { flex: none; position: relative; width: 40px; height: 22px; border: 0; border-radius: 99px; background: var(--panel-3); cursor: pointer;
  i { position: absolute; left: 3px; top: 3px; width: 16px; height: 16px; border-radius: 50%; background: var(--muted); transition: transform 0.12s, background 0.12s; }
  &.on { background: var(--line); i { transform: translateX(18px); background: var(--ink-on-line); } }
  &:focus-visible { outline: 2px solid var(--ink); } }
.loading { display: flex; align-items: center; gap: 12px; padding: 8px 2px; }
.spin { flex: none; width: 22px; height: 22px; border: 3px solid var(--hair); border-top-color: var(--line); border-radius: 50%; animation: spin 0.9s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.notice { padding: 10px 12px; border-radius: 10px; background: var(--panel-3); box-shadow: inset 4px 0 0 var(--late); display: flex; flex-direction: column; gap: 8px; align-items: flex-start; line-height: 1.4; }

.right { display: flex; flex-direction: column; gap: 12px; min-height: 0; }
.map { flex: 1; min-height: 0; border-radius: 10px; overflow: hidden; }
.meta { flex: none; }
.plate-row { display: flex; gap: 14px; align-items: center; }
.plate { display: inline-grid; place-items: center; font-weight: 800; border-radius: 10px; &.huge { min-width: 84px; padding: 8px 14px; font-size: 34px; } }
.fields { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6px;
  label { display: flex; flex-direction: column; gap: 3px; color: var(--muted); font-size: 12px; }
  input { padding: 8px 10px; border: 0; border-radius: 8px; background: #0f1a20; color: var(--ink); font: inherit; font-size: 15px; box-shadow: inset 0 0 0 1px var(--hair);
    &::placeholder { color: var(--muted); } &:focus { outline: 2px solid var(--line); } } }
.swatches { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.swatch { width: 28px; height: 28px; border: 0; border-radius: 50%; cursor: pointer; box-shadow: inset 0 0 0 2px rgba(0, 0, 0, 0.35);
  &.on { outline: 3px solid var(--ink); outline-offset: 2px; } &:focus-visible { outline: 3px solid var(--ink); outline-offset: 2px; } }
.sw-auto { padding: 4px 12px; border: 0; border-radius: 99px; background: var(--panel-3); color: var(--ink); font: inherit; font-size: 13px; font-weight: 700; cursor: pointer;
  &.on { background: var(--ink); color: #0b1a22; } &:focus-visible { outline: 2px solid var(--line); } }
.warn { margin: 0; color: var(--late); font-size: 13px; line-height: 1.4; }
.row { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.row .go { flex: 1; min-width: 150px; }
@media (max-width: 1100px) { .stops-page { grid-template-columns: 1fr; .right { flex-direction: row; } } }
@media (prefers-reduced-motion: reduce) { .spin { animation-duration: 3s; } .sw i { transition: none; } }
</style>
