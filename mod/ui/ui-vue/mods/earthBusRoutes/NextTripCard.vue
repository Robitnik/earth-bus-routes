<template>
  <!-- "Next trip from here": the earliest departure from the stop you stand at; one press starts it -->
  <section class="nt" :style="{ '--line': trip.colour, '--ink-on-line': ink(trip.colour) }" :aria-label="t('next.title')">
    <span class="plate" :style="{ background: trip.colour, color: ink(trip.colour) }">{{ trip.ref }}</span>
    <div class="what">
      <div class="kicker">{{ t("next.title") }}</div>
      <div class="to">{{ trip.to }}</div>
      <div class="from muted">{{ t("next.from", { stop: trip.stopName }) }}<span v-if="trip.source === 'generated'" class="est" :title="t('next.estimatedTip')">{{ t("next.estimated") }}</span></div>
    </div>
    <div class="when">
      <div class="time">{{ trip.label }}</div>
      <div class="in">{{ inText }}</div>
    </div>
    <button class="btn go" @click="call('uiStartNext')">
      {{ t("next.go") }}
      <small>{{ trip.wait ? t("next.goWait") : t("next.goJump") }}</small>
    </button>
  </section>
</template>

<script setup>
import { computed } from "vue"
import { call, plateInk } from "./store.js"
import { t } from "./i18n.js"

const props = defineProps({ trip: { type: Object, required: true } })
const ink = plateInk
const inText = computed(() => {
  const x = props.trip
  if (x.tomorrow) return t("next.tomorrow")
  return x.inMin <= 0 ? t("next.now") : t("next.in", { n: x.inMin })
})
</script>

<style scoped lang="scss">
.nt {
  flex: none;
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 12px 16px;
  border-radius: 12px;
  background: var(--panel-2);
  box-shadow: inset 5px 0 0 var(--line);
}
.plate {
  flex: none;
  display: inline-grid;
  place-items: center;
  min-width: 64px;
  padding: 6px 12px;
  border-radius: 8px;
  font-size: 28px;
  font-weight: 800;
}
.what { flex: 1; min-width: 0; }
.kicker { color: var(--muted); font-size: 12px; font-weight: 700; letter-spacing: 0.8px; text-transform: uppercase; }
.to { font-size: 21px; font-weight: 800; line-height: 1.2; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
.from { font-size: 14px; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
.muted { color: var(--muted); }
.est { margin-left: 8px; padding: 0 6px; border-radius: 4px; background: var(--panel-3); color: var(--muted); font-size: 11px; }
.when { flex: none; text-align: right; }
// the time as on the LED blind of the HUD
.time { font-size: 28px; font-weight: 800; color: var(--led); letter-spacing: 1px; line-height: 1.1; text-shadow: 0 0 8px rgba(255, 170, 0, 0.35); }
.in { color: var(--muted); font-size: 14px; }
.btn { flex: none; text-align: center; small { display: block; font-weight: 400; font-size: 12px; opacity: 0.85; margin-top: 1px; } }
@media (max-width: 900px) { .nt { flex-wrap: wrap; } .when { text-align: left; } }
</style>
