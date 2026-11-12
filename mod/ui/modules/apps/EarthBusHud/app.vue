<template>
  <div class="ebr bngApp" :class="{ compact }" :style="{ '--line': lineColour, '--ink-on-line': lineInk }">
    <!-- no trip: one quiet line -->
    <div v-if="!d || d.idle" class="idle">
      <span class="idle-plate">{{ tr("hud.idle.plate") }}</span>
      <span class="idle-text">{{ tr("hud.idle.text") }}</span>
    </div>

    <!-- the trip waits for the bus at its first stop -->
    <div v-else-if="d.armed" class="armed">
      <header class="blind">
        <span class="plate">{{ d.armed.ref }}</span>
        <span class="led dest">{{ d.armed.to }}</span>
      </header>
      <div class="armed-body">
        <div class="armed-label">{{ tr("hud.armed") }}</div>
        <div class="armed-stop">{{ d.armed.stop }}</div>
        <div class="armed-dist">{{ armedDist }}</div>
        <div class="armed-hint">{{ tr("hud.armedHint") }}</div>
      </div>
    </div>

    <!-- a shift between two trips: the dispatcher's next trip, the wait and the delay -->
    <div v-else-if="d.layover" class="armed layover">
      <header class="blind">
        <span class="plate">{{ d.layover.ref }}</span>
        <span class="led dest">{{ d.layover.to }}</span>
        <span class="led clock">{{ timeLabel(d.layover.departs) }}</span>
      </header>
      <div class="armed-body">
        <div class="armed-label">{{ tr("hud.layover") }}</div>
        <div class="armed-stop">{{ d.layover.from }} → {{ d.layover.to }}</div>
        <div class="armed-dist" :class="layoverCls">{{ layoverText }}</div>
        <div class="armed-hint">{{ layoverHint }}</div>
      </div>
    </div>

    <!-- the empty run from the depot to the first stop -->
    <div v-else-if="d.service" class="armed service">
      <header class="blind">
        <span class="plate">{{ d.service.ref }}</span>
        <span class="led dest">{{ tr("hud.serviceSign") }}</span>
      </header>
      <div class="armed-body">
        <div class="armed-label">{{ tr("hud.service") }}</div>
        <div class="armed-stop">{{ d.service.stop }}</div>
        <div class="armed-dist">{{ serviceDist }}</div>
        <div class="armed-hint">
          {{ tr("hud.serviceDue", { time: timeLabel(d.service.due) }) }}
          <template v-if="d.service.late > 60"> · <span class="late">{{ tr("hud.lateBy", { min: Math.ceil(d.service.late / 60) }) }}</span></template>
        </div>
      </div>
    </div>

    <!-- trip finished: the menu shows the details -->
    <div v-else-if="d.finished" class="idle done">
      <span class="grade">{{ d.result.grade }}</span>
      <span class="idle-text">{{ d.shift ? tr("hud.shiftDone", { n: d.shift.count, points: d.result.points }) : tr("hud.done", { points: d.result.points }) }}</span>
    </div>

    <template v-else>
      <!-- the destination blind: line number and destination as on the front of the bus, the clock of the trip at the end -->
      <header class="blind" @click="compact = !compact" :title="tr('hud.toggle')">
        <span class="plate">{{ d.route.ref }}</span>
        <span class="led dest">{{ d.route.to || d.route.name }}</span>
        <span class="led clock">{{ clockText }}</span>
      </header>

      <!-- the LED board of the saloon: the next stop, "on request", the line and its terminus (a bell sounds when a stop is asked for) -->
      <section v-if="led" class="ledboard" :class="{ asked: led.requested }" :aria-label="tr('hud.led.next')">
        <div class="lb-top">
          <span class="lb-tag">{{ led.last ? tr("hud.led.last") : led.here ? tr("hud.led.now") : tr("hud.led.next") }}</span>
          <span v-if="led.requested" class="lb-flag asked" :key="'a' + led.bellSeq">{{ tr("hud.stopRequested") }}</span>
          <span v-else-if="led.waitSec" class="lb-flag wait">{{ tr("hud.led.leavesIn", { t: mmss(led.waitSec) }) }}</span>
          <span v-else-if="led.onRequest" class="lb-flag demand">{{ tr("hud.led.onRequest") }}</span>
        </div>
        <div class="lb-stop">{{ led.stop }}</div>
        <div class="lb-line">{{ led.line }} → {{ led.dest }}</div>
      </section>
      <!-- a shift: which trip it is, how late it began, how long the shift lasts -->
      <div v-if="d.shift" class="shiftbar">
        <b>{{ tr("hud.shiftTrip", { n: d.shift.number }) }}</b>
        <span v-if="d.shift.depot" class="muted">{{ tr("hud.shiftDepot") }}</span>
        <span v-if="d.shift.lateStart > 60" class="late">{{ tr("hud.lateStart", { min: Math.ceil(d.shift.lateStart / 60) }) }}</span>
        <span class="muted end">{{ tr("hud.shiftEnds", { time: hm(d.shift.endsIn) }) }}</span>
      </div>
      <!-- the dispatcher on the radio: a short message that goes by itself, else what the bus is waiting for -->
      <transition name="note">
        <div v-if="radio" class="radio" :class="radio.kind" :key="radio.key" role="status">
          <svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5" y="5" width="8" height="10" rx="1.5" /><path d="M7 5V1.5M11 8h-4M11 11h-4" /></svg>
          <span>{{ radio.text }}</span>
        </div>
      </transition>

      <!-- the line diagram: the next stop opened up at the top, the stops after it on the line's colour -->
      <section class="line" :key="d.index">
        <!-- the stop just behind the bus and what became of it: served, missed (people left behind), passed (nobody wanted it) -->
        <div v-if="d.past && !compact" class="stop past" :class="'o-' + d.past.outcome">
          <span class="dot">
            <svg v-if="d.past.outcome === 'served'" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6.2l2.3 2.3 4.7-5" /></svg>
            <svg v-else-if="d.past.outcome === 'missed'" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" /></svg>
          </span>
          <div class="body">
            <div class="row">
              <span class="name">{{ d.past.name }}</span>
              <span class="pstate">{{ tr("hud.past." + d.past.outcome) }}</span>
            </div>
          </div>
        </div>
        <div v-for="(s, i) in shown" :key="s.index" class="stop" :class="{ current: i === 0, far: i > 3, 'is-here': i === 0 && atStop, long: i === 0 && longName }">
          <span class="dot"></span>
          <div class="body">
            <div class="row">
              <span class="name">{{ s.name }}</span>
              <span v-if="i === 0 && delay" class="delay" :class="delay.cls">{{ delay.text }}</span>
              <span v-else-if="s.sched" class="time">{{ timeLabel(s.sched) }}</span>
            </div>
            <template v-if="i === 0 && d.next">
              <div class="sub">
                <template v-if="atStop">
                  <span v-if="d.atStop && d.atStop.doorsHint" class="hint">{{ tr("hud.openDoors") }}</span>
                  <span v-else class="flow">
                    <span v-if="d.atStop && d.atStop.alightLeft > 0">{{ tr("hud.gettingOff", { n: d.atStop.alightLeft }) }}</span>
                    <span v-if="d.atStop && d.atStop.boardLeft > 0">{{ tr("hud.boarding", { n: d.atStop.boardLeft }) }}</span>
                    <span v-if="d.atStop && d.atStop.alightLeft <= 0 && d.atStop.boardLeft <= 0 && !d.hold">{{ tr("hud.closeDoors") }}</span>
                    <span v-if="signalHint" class="hint">{{ signalHint }}</span>
                  </span>
                </template>
                <template v-else>
                  <span class="dist">{{ distText }}</span>
                  <span v-if="d.next.sched" class="due">{{ tr("hud.due", { time: timeLabel(d.next.sched) }) }}</span>
                  <span v-if="d.requested" class="request">{{ tr("hud.stopRequested") }}</span>
                  <span v-else-if="d.waitingNext > 0" class="waiting">{{ tr("hud.waiting", { n: d.waitingNext }) }}</span>
                </template>
              </div>
              <div v-if="!atStop" class="approach" role="progressbar" :aria-valuenow="Math.round(approach * 100)">
                <i :style="{ width: approach * 100 + '%' }"></i>
              </div>
            </template>
          </div>
        </div>
      </section>

      <!-- where on the line: the stop's number of all, the way to the end, the bar -->
      <div v-if="!compact" class="whereon" :title="tr('hud.progress')">
        <div class="wo-row">
          <span>{{ tr("hud.stopOf", { i: d.index, n: d.count }) }}</span>
          <span v-if="d.left != null" class="wo-left">{{ tr("hud.toEnd", { d: distLabel(d.left, d.units) }) }}</span>
        </div>
        <div class="route-progress"><i :style="{ width: d.progress * 100 + '%' }"></i></div>
      </div>

      <!-- the ghost of the best trip on this line: seconds behind (+) or ahead (-) at this place -->
      <div v-if="d.ghost" class="ghost" :class="ghostCls" :title="tr('hud.ghostTip', { points: d.ghost.points })">
        <span class="ghost-dot"></span>
        <span class="ghost-label">{{ tr("hud.ghost") }}</span>
        <b v-if="d.ghost.text" class="ghost-delta">{{ d.ghost.text }}</b>
        <span v-else class="ghost-wait">{{ tr("hud.ghostWait") }}</span>
      </div>

      <footer class="board">
        <div class="load" :title="tr('hud.onboardTip')">
          <div class="load-top">
            <span class="load-num"><b>{{ d.onboard }}</b><small>/{{ d.capacity }}</small></span>
            <span v-if="!(comfort && comfort.standing > 0)" class="load-label">{{ tr("hud.onboard") }}</span>
            <span v-else class="standing">{{ tr("hud.standing", { n: comfort.standing }) }}</span>
            <span v-if="d.lastBoard || d.lastAlight" class="flows">
              <span class="in">+{{ d.lastBoard }}</span><span class="out">−{{ d.lastAlight }}</span>
            </span>
          </div>
          <div class="seats" role="progressbar" :aria-valuenow="d.onboard" :aria-valuemax="d.capacity">
            <i v-for="n in 20" :key="n" :class="{ on: n <= filled, stand: n > seatSegs }"></i>
          </div>
        </div>
        <div v-if="comfort" class="cupbox" :class="{ spill: comfort.spill }" :title="tr('hud.cupTip')">
          <svg viewBox="0 0 28 28" class="cup" aria-hidden="true">
            <path class="cup-body" d="M5 8h15v9a6 6 0 0 1-6 6h-3a6 6 0 0 1-6-6z" />
            <path class="cup-handle" d="M20 10h2a3 3 0 0 1 0 6h-2" />
            <g class="cup-sway" :style="{ transform: 'rotate(' + comfort.cup + 'deg)', transformOrigin: '12.5px 14px' }"><path class="cup-coffee" d="M6.2 11h12.6v6a5.2 5.2 0 0 1-5.2 5.2h-2.2A5.2 5.2 0 0 1 6.2 17z" /></g>
          </svg>
        </div>
        <div v-if="limitText" class="limit" :class="{ over: d.rules.over }" :title="tr('hud.limitTip')">{{ limitText }}</div>
        <div class="score" :title="tr('hud.scoreTip')">
          <svg viewBox="0 0 44 44" class="ring" aria-hidden="true">
            <circle cx="22" cy="22" r="18" class="ring-bg" />
            <circle cx="22" cy="22" r="18" class="ring-fg" :stroke-dasharray="ringDash" />
          </svg>
          <span class="grade">{{ d.score.grade }}</span>
          <span class="points">{{ d.score.points }}</span>
        </div>
      </footer>

      <div v-if="d.rules && d.rules.doorsMoving" class="warn">{{ tr("hud.doorsMoving") }}</div>

      <transition name="note">
        <div v-if="lastNote" class="note" :key="d.noteSeq">
          <span>{{ noteText(lastNote.text) }}</span><b v-if="lastNote.points">{{ lastNote.points }}</b>
        </div>
      </transition>
    </template>

    <!-- an achievement was unlocked (career, plan 006 stage E): shown for a few seconds over whatever the HUD shows -->
    <transition name="note">
      <div v-if="ach" class="ach-toast" role="status" :key="ach.id">
        <span class="ach-star" aria-hidden="true">★</span>
        <span class="ach-body"><small>{{ tr("hud.ach") }}</small><b>{{ achName(ach) }}</b></span>
      </div>
    </transition>
  </div>
</template>

<script setup>
import { computed, onMounted, ref, watch } from "vue"
import { useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { isLang, autoLang } from "./langs.js"

const { api } = useBridge()
const events = useEvents()
const d = ref(null)
const compact = ref(false)

// ---- languages (langs.js; the texts are in lang/<code>.js): the menu's choice (the same localStorage key), else the game's interface
// language, else English; a key a language lacks shows in English
import en from "./lang/en.js"
import uk from "./lang/uk.js"
import de from "./lang/de.js"
import es from "./lang/es.js"
import fr from "./lang/fr.js"
import ja from "./lang/ja.js"
import ko from "./lang/ko.js"
import pl from "./lang/pl.js"
import pt_BR from "./lang/pt_BR.js"
import pt_PT from "./lang/pt_PT.js"
import ru from "./lang/ru.js"
import zh_Hans from "./lang/zh_Hans.js"
import zh_Hant from "./lang/zh_Hant.js"
const PACKS = { en, uk, de, es, fr, ja, ko, pl, pt_BR, pt_PT, ru, zh_Hans, zh_Hant }
const lang = ref("en")
function syncLang() {
  let chosen = null
  try { chosen = localStorage.getItem("earthBusRoutes.lang") } catch (e) { /* private window */ }
  const l = isLang(chosen) ? chosen : autoLang(useBridge())
  if (l !== lang.value) lang.value = l
}
syncLang()
const TEXT = {}
for (const c of Object.keys(PACKS)) TEXT[c] = (PACKS[c] && PACKS[c].text) || {}
function tr(key, p) {
  let s = (TEXT[lang.value] && TEXT[lang.value][key]) || TEXT.en[key] || key
  if (p) for (const k in p) s = s.replace("{" + k + "}", p[k])
  return s
}
// the radio band: the dispatcher's message, else the connection the bus waits for, else the ticket selling
const radio = computed(() => {
  const v = d.value
  if (!v || v.idle || v.armed || v.finished) return null
  if (v.dispatch) return { key: "m" + v.dispatch.seq, kind: v.dispatch.kind, text: tr("msg." + v.dispatch.key, v.dispatch.params) }
  if (v.hold) {
    const s = Math.ceil(v.hold.left)
    return { key: "hold", kind: "transfer", text: tr("hud.holding", { ref: v.hold.ref, time: Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0") }) }
  }
  if (v.selling) return { key: "sell", kind: "info", text: tr("hud.selling") }
  return null
})
const noteText = t => (TEXT[lang.value] && TEXT[lang.value]["note." + t]) || TEXT.en["note." + t] || t

// ---- achievements (the same titles as the menu's ach.<id>; a title the lists do not know falls back to the English one Lua sends)
const achName = a => (PACKS[lang.value] && PACKS[lang.value].ach && PACKS[lang.value].ach[a.id]) || (PACKS.en.ach[a.id]) || a.name || a.id
const ach = ref(null)
let achQueue = []
let achTimer = null
function nextAch() {
  clearTimeout(achTimer)
  ach.value = achQueue.shift() || null
  if (ach.value) achTimer = setTimeout(nextAch, 6000)
}
events.on("EarthBusRoutesAchievement", a => {
  if (!a || !a.id) return
  achQueue.push(a)
  if (!ach.value) nextAch()
})

// ---- the numbers
const lineColour = computed(() => (d.value && ((d.value.route && d.value.route.colour) || (d.value.armed && d.value.armed.colour)
  || (d.value.layover && d.value.layover.colour) || (d.value.service && d.value.service.colour))) || "#4aa3df")
const armedDist = computed(() => {
  const a = d.value && d.value.armed
  if (!a) return ""
  const m = a.dist
  if (a.units === "mph") {
    const ft = m * 3.28084
    return ft < 1000 ? Math.round(ft / 10) * 10 + " " + tr("ft") : (m / 1609.344).toFixed(1) + " " + tr("mi")
  }
  return m < 1000 ? Math.round(m / 10) * 10 + " " + tr("m") : (m / 1000).toFixed(1) + " " + tr("km")
})
function distLabel(m, units) {
  if (units === "mph") {
    const ft = m * 3.28084
    return ft < 1000 ? Math.round(ft / 10) * 10 + " " + tr("ft") : (m / 1609.344).toFixed(1) + " " + tr("mi")
  }
  return m < 1000 ? Math.round(m / 10) * 10 + " " + tr("m") : (m / 1000).toFixed(1) + " " + tr("km")
}
const serviceDist = computed(() => (d.value && d.value.service && d.value.service.dist != null ? distLabel(d.value.service.dist, d.value.service.units) : ""))
// the layover board: the wait (or the delay) is the big number
const layoverText = computed(() => {
  const l = d.value && d.value.layover
  if (!l) return ""
  if (l.late > 60) return tr("hud.lateBy", { min: Math.ceil(l.late / 60) })
  if (l.remaining > 90) return tr("hud.layoverIn", { min: Math.ceil(l.remaining / 60) })
  return tr("hud.layoverNow")
})
const layoverCls = computed(() => (d.value && d.value.layover && d.value.layover.late > 60 ? "late" : ""))
const layoverHint = computed(() => {
  const l = d.value && d.value.layover
  if (!l) return ""
  if (l.away) return tr("hud.layoverAway")
  if (l.loading) return tr("hud.layoverLoading")
  return tr("hud.layoverWait", { n: l.number, time: timeLabel(l.departs), end: hm(l.endsIn) })
})
// hours:minutes of a length of time in seconds
const hm = sec => Math.floor(sec / 3600) + ":" + pad(Math.floor((sec % 3600) / 60))
// dark text on a light line colour, white on a dark one
const lineInk = computed(() => {
  const m = /^#([0-9a-f]{6})$/i.exec(lineColour.value)
  if (!m) return "#0b1a22"
  const n = parseInt(m[1], 16)
  return (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255 > 0.55 ? "#0b1a22" : "#ffffff"
})
const shown = computed(() => (d.value ? (compact.value ? d.value.stops.slice(0, 1) : d.value.stops) : []))
const atStop = computed(() => d.value && (d.value.phase === "atStop" || d.value.phase === "start"))
// a long name of the next stop gets a smaller font (two lines of it, not one and a half cut off)
const longName = computed(() => !!(d.value && d.value.stops && d.value.stops[0] && String(d.value.stops[0].name || "").length > 28))
const pad = n => String(n).padStart(2, "0")
function timeLabel(sec) {
  const s = Math.floor(((sec % 86400) + 86400) % 86400)
  return pad(Math.floor(s / 3600)) + ":" + pad(Math.floor((s % 3600) / 60))
}
const clockText = computed(() => (d.value ? timeLabel(d.value.clock) : "--:--"))
const mmss = sec => Math.floor(sec / 60) + ":" + pad(Math.floor(sec % 60))
// the saloon: the LED board and the live comfort (each is left out of the data when its menu setting is off)
const led = computed(() => (d.value && d.value.cabin && d.value.cabin.led) || null)
const comfort = computed(() => (d.value && d.value.cabin && d.value.cabin.comfort) || null)

const delay = computed(() => {
  const n = d.value && d.value.next
  if (!n || n.delta === undefined || n.delta === null) return null
  if (led.value && led.value.waitSec) return null                    // waiting for the departure: the LED board counts it down
  const s = Math.round(n.delta)
  if (Math.abs(s) <= 60) return { cls: "ok", text: tr("hud.onTime") }
  const a = Math.abs(s)
  const txt = (s > 0 ? "+" : "−") + Math.floor(a / 60) + ":" + pad(a % 60)
  return { cls: s > 0 ? "late" : "early", text: txt }
})

const ghostCls = computed(() => {
  const g = d.value && d.value.ghost
  if (!g || g.delta === undefined || g.delta === null) return ""
  return g.delta > 0.5 ? "behind" : "ahead"
})

const distText = computed(() => {
  const n = d.value && d.value.next
  if (!n || n.dist === undefined || n.dist === null) return ""
  const m = n.remaining > 0 ? n.remaining : n.dist
  const imperial = d.value.units === "mph"
  if (imperial) {
    const ft = m * 3.28084
    return ft < 1000 ? Math.round(ft / 10) * 10 + " " + tr("ft") : (m / 1609.344).toFixed(1) + " " + tr("mi")
  }
  return m < 1000 ? Math.round(m / 10) * 10 + " " + tr("m") : (m / 1000).toFixed(1) + " " + tr("km")
})
const approach = computed(() => {
  const n = d.value && d.value.next
  if (!n) return 0
  const m = n.remaining > 0 ? n.remaining : n.dist
  return Math.max(0, Math.min(1, 1 - m / 600))
})

// the sign of the road's speed limit (in the player's units) and the indicator hint at a stop
const limitText = computed(() => {
  const l = d.value && d.value.rules && d.value.rules.limit
  if (!l) return ""
  return d.value.units === "mph" ? String(Math.round(l / 1.609344 / 5) * 5) : String(l)
})
const signalHint = computed(() => {
  const s = d.value && d.value.rules && d.value.rules.signal
  if (!s || s.on) return ""
  return tr(s.side === "R" ? "hud.signalRight" : "hud.signalLeft")
})

const seatSegs = computed(() => (d.value && d.value.capacity ? Math.round((d.value.seats / d.value.capacity) * 20) : 10))
const filled = computed(() => (d.value && d.value.capacity ? Math.ceil((d.value.onboard / d.value.capacity) * 20) : 0))
const ringDash = computed(() => {
  const c = 2 * Math.PI * 18
  const f = d.value ? Math.max(0, Math.min(1, d.value.score.points / 1000)) : 0
  return `${(c * f).toFixed(1)} ${c.toFixed(1)}`
})
// a penalty is shown for four seconds after it happened (noteSeq counts every one)
const lastNote = ref(null)
let noteTimer = null
watch(() => d.value && d.value.noteSeq, (seq, was) => {
  const n = d.value && d.value.notes
  if (!seq || seq === was || !n || !n.length) return
  lastNote.value = n[n.length - 1]
  clearTimeout(noteTimer)
  noteTimer = setTimeout(() => { lastNote.value = null }, 4000)
})

events.on("EarthBusRoutesHud", data => { syncLang(); d.value = data })

onMounted(() => {
  api.engineLua("if earthBusRoutes_main and earthBusRoutes_main.sendHud then earthBusRoutes_main.sendHud() end")
})
</script>

<style scoped lang="scss">
// Tokens: one panel colour family, the line colour (--line) as the only accent, amber only on the destination blind.
.ebr {
  --panel: #1a2830;
  --panel-2: #22343e;
  --ink: #eef3f4;
  --muted: #93a9b4;
  --hair: rgba(255, 255, 255, 0.09);
  --led: #ffc233;
  --ok: #52d394;
  --late: #ff875a;
  --early: #6db8ff;
  position: relative;
  box-sizing: border-box;
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 8px;
  color: var(--ink);
  font-family: "Overpass", "Segoe UI", system-ui, sans-serif;
  font-variant-numeric: tabular-nums;
  background: var(--panel);
  border-radius: 10px;
  border-left: 6px solid var(--line);
  box-shadow: 0 6px 22px rgba(0, 0, 0, 0.45);
  user-select: none;
  overflow: hidden;
}

.ach-toast {
  position: absolute; left: 8px; right: 8px; bottom: 8px; display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 8px;
  background: #26394a; box-shadow: inset 0 0 0 1.5px var(--led), 0 4px 14px rgba(0, 0, 0, 0.5); z-index: 5;
  .ach-star { font-size: 22px; color: var(--led); }
  .ach-body { display: flex; flex-direction: column; min-width: 0; small { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; } b { font-size: 15px; line-height: 1.2; } }
}

.idle {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: auto 0;
  color: var(--muted);
  font-size: 14px;
  line-height: 1.3;
}
.idle-plate {
  flex: none;
  padding: 3px 9px;
  border-radius: 5px;
  background: var(--line);
  color: var(--ink-on-line);
  font-weight: 800;
}
.armed { display: flex; flex-direction: column; gap: 8px; margin: auto 0; }
.armed .blind { cursor: default; }
.armed-body { display: flex; flex-direction: column; gap: 2px; padding: 2px 4px; }
.armed-label { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: 0.6px; }
.armed-stop { font-size: 20px; font-weight: 800; line-height: 1.2; }
.armed-dist { font-size: 34px; font-weight: 800; color: var(--line); line-height: 1.1; }
.armed-hint { color: var(--muted); font-size: 13px; line-height: 1.3; }
.armed-dist.late, .shiftbar .late, .armed-hint .late { color: var(--late); }
.shiftbar { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; padding: 0 4px; font-size: 13px; color: var(--ink);
  b { font-weight: 800; } .muted { color: var(--muted); } .end { margin-left: auto; } }
.idle.done .grade { flex: none; font-size: 30px; font-weight: 800; color: var(--line); }

// ---- destination blind
.blind {
  display: flex;
  align-items: stretch;
  gap: 8px;
  cursor: pointer;
}
.plate {
  flex: none;
  min-width: 58px;
  padding: 0 10px;
  display: grid;
  place-items: center;
  border-radius: 6px;
  background: var(--line);
  color: var(--ink-on-line);
  font-size: 30px;
  font-weight: 800;
  letter-spacing: -0.5px;
  line-height: 44px;
}
.led {
  position: relative;
  display: flex;
  align-items: center;
  height: 44px;
  padding: 0 10px;
  background: #07090a;
  border-radius: 6px;
  color: var(--led);
  font-weight: 700;
  text-shadow: 0 0 7px rgba(255, 170, 0, 0.55);
  overflow: hidden;
  // the dot grid of a real LED sign
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    background:
      linear-gradient(rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 100% 3px,
      linear-gradient(90deg, rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 3px 100%;
    pointer-events: none;
  }
}
.dest {
  flex: 1;
  min-width: 0;
  font-size: 20px;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
  display: block;
  line-height: 44px;
}
.clock { flex: none; font-size: 22px; letter-spacing: 1px; }

// ---- the line diagram: as many stops as the window has room for, the last ones fading out
.line {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  padding: 2px 4px 0 6px;
  overflow: hidden;
  -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 34px), transparent);
  mask-image: linear-gradient(to bottom, #000 calc(100% - 34px), transparent);
}
// the stop behind: small, muted, its dot says what became of it
.stop.past {
  padding-bottom: 6px;
  font-size: 13px;
  color: var(--muted);
  &::before { background: var(--muted); opacity: 0.45; }
  .dot { display: grid; place-items: center; left: 2px; top: 3px; width: 14px; height: 14px; border: 2px solid var(--past); background: var(--past); }
  .dot svg { width: 10px; height: 10px; fill: none; stroke: #0b1114; stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; }
  .name { text-decoration: none; }
  .pstate { flex: none; font-size: 11px; font-weight: 700; letter-spacing: 0.5px; text-transform: uppercase; color: var(--past); }
  &.o-served { --past: var(--ok); }
  &.o-missed { --past: #b84dff; .name { color: #cfb0e6; } }
  &.o-passed { --past: #73ade6; .dot { background: var(--panel); } }
}
.whereon {
  flex: none;
  padding: 0 4px 0 30px;
  .wo-row { display: flex; justify-content: space-between; gap: 8px; font-size: 12px; color: var(--muted); }
  .wo-left { color: var(--ink); font-weight: 600; }
  .route-progress { margin: 4px 0 2px; }
}
.stop {
  position: relative;
  padding: 0 0 7px 24px;
  font-size: 14px;
  color: var(--ink);
  // the line from this stop's dot to the next one's
  &::before {
    content: "";
    position: absolute;
    left: 7px;
    top: 14px;
    bottom: -4px;
    width: 4px;
    border-radius: 2px;
    background: var(--line);
    opacity: 0.9;
  }
  &:last-of-type::before { display: none; }
  .dot {
    position: absolute;
    left: 3px;
    top: 5px;
    z-index: 1;
    width: 12px;
    height: 12px;
    box-sizing: border-box;
    border-radius: 50%;
    background: var(--panel);
    border: 3px solid var(--line);
  }
  .row { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
  .name { flex: 1; min-width: 0; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
  .time { flex: none; color: var(--muted); }
  &.far { color: var(--muted); }
  &.current {
    padding-bottom: 10px;
    &::before { top: 20px; }
    .dot { left: 0; top: 3px; width: 18px; height: 18px; border-width: 4px; background: var(--line); animation: arrive 0.9s ease-out 1; }
    .row { align-items: center; }
    .name { font-size: 23px; font-weight: 700; line-height: 1.2; white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    &.long .name { font-size: 18px; }
    &.is-here .name { color: var(--line); }
  }
}
.delay {
  flex: none;
  padding: 1px 9px;
  border-radius: 99px;
  font-size: 14px;
  font-weight: 700;
  &.ok { background: rgba(82, 211, 148, 0.16); color: var(--ok); }
  &.late { background: rgba(255, 135, 90, 0.18); color: var(--late); }
  &.early { background: rgba(109, 184, 255, 0.18); color: var(--early); }
}
.sub {
  display: flex;
  flex-wrap: wrap;
  gap: 2px 12px;
  margin-top: 2px;
  color: var(--muted);
  font-size: 14px;
  .dist { color: var(--ink); font-weight: 600; }
  .hint { color: var(--led); font-weight: 600; }
  .flow { display: flex; gap: 12px; color: var(--ink); }
  .request { color: var(--led); font-weight: 600; }
  .waiting { color: var(--ink); }
}
.ghost {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 10px;
  border-radius: 99px;
  font-size: 14px;
  color: var(--muted);
  background: rgba(109, 184, 255, 0.1);
  .ghost-dot { width: 10px; height: 10px; border-radius: 3px; background: rgba(109, 184, 255, 0.55); border: 1px solid #6db8ff; }
  .ghost-delta { margin-left: auto; font-size: 16px; }
  .ghost-wait { margin-left: auto; font-size: 13px; }
  &.behind .ghost-delta { color: var(--late); }
  &.ahead .ghost-delta { color: var(--ok); }
}
.approach, .route-progress {
  height: 4px;
  margin-top: 6px;
  border-radius: 2px;
  background: var(--hair);
  overflow: hidden;
  i { display: block; height: 100%; background: var(--line); border-radius: 2px; transition: width 0.25s linear; }
}
@keyframes arrive {
  0% { box-shadow: 0 0 0 0 var(--line); }
  100% { box-shadow: 0 0 0 12px transparent; }
}

// ---- the LED board of the saloon
.ledboard {
  position: relative;
  flex: none;
  padding: 5px 10px 6px;
  border-radius: 6px;
  background: #07090a;
  color: var(--led);
  text-shadow: 0 0 7px rgba(255, 170, 0, 0.55);
  overflow: hidden;
  &::after {
    content: "";
    position: absolute;
    inset: 0;
    background:
      linear-gradient(rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 100% 3px,
      linear-gradient(90deg, rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 3px 100%;
    pointer-events: none;
  }
  .lb-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-height: 17px; }
  .lb-tag { font-size: 12px; font-weight: 700; letter-spacing: 1.2px; text-transform: uppercase; opacity: 0.75; }
  .lb-flag {
    padding: 0 7px;
    border-radius: 3px;
    background: var(--led);
    color: #07090a;
    text-shadow: none;
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.8px;
    text-transform: uppercase;
    &.demand { animation: blink 1.6s steps(1) infinite; }
    &.wait { background: transparent; color: var(--led); outline: 1px solid var(--led); text-transform: none; letter-spacing: 0.2px; }
    &.asked { background: #ff5a3c; color: #fff; animation: ring 0.5s steps(1) 6; }
  }
  .lb-stop { margin-top: 1px; font-size: 20px; font-weight: 700; line-height: 1.2; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
  .lb-line { font-size: 13px; opacity: 0.7; white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
  &.asked .lb-stop { color: #ff8a6b; text-shadow: 0 0 7px rgba(255, 90, 60, 0.6); }
}
@keyframes blink { 0%, 55% { opacity: 1; } 56%, 100% { opacity: 0.25; } }
@keyframes ring { 0% { opacity: 1; } 50% { opacity: 0.2; } }

// ---- load and score
.board {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 6px 4px 2px;
  border-top: 1px solid var(--hair);
}
.load { flex: 1; min-width: 0; }
.load-top { display: flex; align-items: baseline; gap: 8px; }
.load-num { font-size: 22px; b { font-weight: 800; } small { font-size: 14px; color: var(--muted); } }
.load-label { color: var(--muted); font-size: 13px; }
.flows { margin-left: auto; display: flex; gap: 8px; font-weight: 700; font-size: 14px; .in { color: var(--ok); } .out { color: var(--early); } }
.standing { white-space: nowrap; padding: 0 7px; border-radius: 99px; background: rgba(255, 135, 90, 0.18); color: var(--late); font-size: 13px; font-weight: 700; }
.cupbox {
  flex: none;
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  .cup { width: 28px; height: 28px; }
  .cup-body { fill: none; stroke: var(--muted); stroke-width: 1.8; stroke-linejoin: round; }
  .cup-handle { fill: none; stroke: var(--muted); stroke-width: 1.8; stroke-linecap: round; }
  .cup-coffee { fill: #8b5a3a; }
  .cup-sway { transition: transform 0.08s linear; }
  &.spill .cup-body, &.spill .cup-handle { stroke: var(--late); }
  &.spill .cup-coffee { fill: var(--late); }
}
.seats {
  display: grid;
  grid-template-columns: repeat(20, 1fr);
  gap: 2px;
  margin-top: 4px;
  i {
    height: 8px;
    border-radius: 2px;
    background: var(--hair);
    &.on { background: var(--ink); }
    &.on.stand { background: var(--late); }
  }
}
.limit {
  flex: none;
  width: 40px;
  height: 40px;
  box-sizing: border-box;
  display: grid;
  place-items: center;
  border-radius: 50%;
  border: 4px solid #d8382f;
  background: #ffffff;
  color: #111;
  font-size: 17px;
  font-weight: 800;
  line-height: 1;
  letter-spacing: -0.5px;
  transition: box-shadow 0.2s;
  &.over { animation: over-limit 0.7s ease-in-out infinite; }
}
@keyframes over-limit {
  0%, 100% { box-shadow: 0 0 0 0 rgba(216, 56, 47, 0); }
  50% { box-shadow: 0 0 0 7px rgba(216, 56, 47, 0.45); }
}
.warn {
  position: absolute;
  left: 14px;
  right: 14px;
  bottom: 104px;
  padding: 6px 10px;
  border-radius: 6px;
  background: #4a2b1c;
  color: #ffc233;
  font-size: 14px;
  font-weight: 700;
  text-align: center;
}
.score {
  position: relative;
  flex: none;
  width: 64px;
  height: 52px;
  display: grid;
  place-items: center;
  .ring { position: absolute; left: 10px; top: 0; width: 44px; height: 44px; transform: rotate(-90deg); }
  .ring-bg { fill: none; stroke: var(--hair); stroke-width: 4; }
  .ring-fg { fill: none; stroke: var(--line); stroke-width: 4; stroke-linecap: round; transition: stroke-dasharray 0.4s; }
  .grade { position: absolute; top: 9px; font-size: 20px; font-weight: 800; }
  .points { position: absolute; bottom: -2px; font-size: 12px; color: var(--muted); }
}

.note {
  position: absolute;
  left: 14px;
  right: 14px;
  bottom: 62px;
  display: flex;
  justify-content: space-between;
  padding: 6px 10px;
  border-radius: 6px;
  background: #3a2320;
  color: #ffb199;
  font-size: 14px;
  font-weight: 600;
  b { margin-left: 10px; }
}
.radio {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 6px 10px 0;
  padding: 6px 10px;
  border-radius: 6px;
  background: #1d3442;
  color: #bfe3f7;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.25;
  svg { flex: none; width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.4; stroke-linecap: round; stroke-linejoin: round; }
  &.event { background: #3a3220; color: #ffd98a; }
  &.good { background: #1f3a2a; color: #9be3b2; }
  &.bad { background: #3a2320; color: #ffb199; }
}
.note-enter-active { transition: opacity 0.2s, transform 0.2s; }
.note-enter-from { opacity: 0; transform: translateY(6px); }
.note-leave-active { transition: opacity 2.5s; }
.note-leave-to { opacity: 0; }

@media (prefers-reduced-motion: reduce) {
  .stop.current .dot { animation: none; }
  .ledboard .lb-flag { animation: none !important; }
  .limit.over { animation: none; box-shadow: 0 0 0 4px rgba(216, 56, 47, 0.6); }
}
</style>
