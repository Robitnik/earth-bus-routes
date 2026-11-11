<template>
  <div v-if="sh && sh.enabled && !sh.active" class="shift-start">
    <div class="head" :title="t('shift.hint')">
      <b>{{ t("shift.title") }}</b>
      <span class="src" :class="real ? 'real' : 'gen'" :title="t(real ? 'shift.srcRealHint' : 'shift.srcGenHint')">{{ t(real ? "shift.srcReal" : "shift.srcGen") }}</span>
    </div>
    <div class="len" role="group" :aria-label="t('shift.length')" :title="t('shift.hint')">
      <button v-for="m in sh.durations" :key="m" :class="{ on: mins === m }" @click="mins = m">{{ t("shift.hours", { n: m / 60 }) }}</button>
    </div>
    <label v-if="sh.depotOn && sh.hasDepot" class="chk" :title="t('shift.depotHint')">
      <input type="checkbox" v-model="depot" />
      <span>{{ t("shift.depot") }}</span>
    </label>
    <button class="btn go-shift" :disabled="busy || !s.start.deps.length" :title="t('shift.hint')" @click="start">
      {{ busy ? t("shift.starting") : t("shift.start") }}<small>{{ t("shift.chosen", { time: chosen }) }}</small>
    </button>
    <p v-if="err" class="warn">{{ err }}</p>
  </div>
</template>

<script setup>
import { computed, ref } from "vue"
import { call } from "./store.js"
import { t } from "./i18n.js"

const props = defineProps({ s: { type: Object, required: true } })
const mins = ref(120)
const depot = ref(true)

const sh = computed(() => props.s.shift)
const chosen = computed(() => {
  const st = props.s.start
  const d = st && st.deps && st.deps[(st.dep || 1) - 1]
  return d ? d.label : ""
})
// the real chain needs a line of the national timetables and a service that can chain it
const real = computed(() => !!(props.s.route && props.s.route.timetable === "gtfs" && sh.value && sh.value.realChain))
const busy = computed(() => !!props.s.starting || props.s.loading === "shift")
const err = computed(() => {
  const e = props.s.error
  if (!e) return ""
  const key = "shift.err." + e
  const text = t(key)
  return text === key ? "" : text
})
function start() { call("uiStartShift", mins.value, !!(depot.value && sh.value.depotOn && sh.value.hasDepot)) }
</script>

<style scoped lang="scss">
.shift-start { flex: none; display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; margin: 4px 0; border-radius: 10px; background: var(--panel-3); box-shadow: inset 4px 0 0 var(--line); }
.head { display: flex; align-items: center; justify-content: space-between; gap: 8px; b { font-size: 16px; } }
.src { padding: 2px 9px; border-radius: 99px; font-size: 12px; font-weight: 700; background: var(--panel); color: var(--muted);
  &.real { color: var(--ok); box-shadow: inset 0 0 0 1px var(--ok); } }
.len { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px;
  button { padding: 8px 10px; border: 0; border-radius: 8px; background: var(--panel); color: var(--ink); font: inherit; font-weight: 700; cursor: pointer;
    &.on { background: var(--line); color: var(--ink-on-line); } &:focus-visible { outline: 2px solid var(--ink); } } }
.chk { display: flex; align-items: flex-start; gap: 10px; cursor: pointer;
  input { margin-top: 4px; width: 18px; height: 18px; accent-color: var(--line); }
  span { font-size: 14px; } }
p { margin: 0; line-height: 1.35; }
.go-shift { display: flex; flex-direction: column; align-items: flex-start; text-align: left; background: transparent; box-shadow: inset 0 0 0 2px var(--line);
  small { display: block; font-weight: 400; font-size: 12px; opacity: 0.85; margin-top: 1px; } }
.warn { color: var(--late); font-size: 13px; }
</style>
