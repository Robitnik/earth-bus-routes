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

    <!-- trip finished: the menu shows the details -->
    <div v-else-if="d.finished" class="idle done">
      <span class="grade">{{ d.result.grade }}</span>
      <span class="idle-text">{{ tr("hud.done", { points: d.result.points }) }}</span>
    </div>

    <template v-else>
      <!-- the destination blind: line number and destination as on the front of the bus, the clock of the trip at the end -->
      <header class="blind" @click="compact = !compact" :title="tr('hud.toggle')">
        <span class="plate">{{ d.route.ref }}</span>
        <span class="led dest">{{ d.route.to || d.route.name }}</span>
        <span class="led clock">{{ clockText }}</span>
      </header>

      <!-- the line diagram: the next stop opened up at the top, the stops after it on the line's colour -->
      <section class="line" :key="d.index">
        <div v-for="(s, i) in shown" :key="s.index" class="stop" :class="{ current: i === 0, far: i > 3, 'is-here': i === 0 && atStop }">
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
                    <span v-if="d.atStop && d.atStop.alightLeft <= 0 && d.atStop.boardLeft <= 0">{{ tr("hud.closeDoors") }}</span>
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
        <div class="route-progress" :title="tr('hud.progress')"><i :style="{ width: d.progress * 100 + '%' }"></i></div>
      </section>

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
            <span class="load-label">{{ tr("hud.onboard") }}</span>
            <span v-if="d.lastBoard || d.lastAlight" class="flows">
              <span class="in">+{{ d.lastBoard }}</span><span class="out">−{{ d.lastAlight }}</span>
            </span>
          </div>
          <div class="seats" role="progressbar" :aria-valuenow="d.onboard" :aria-valuemax="d.capacity">
            <i v-for="n in 20" :key="n" :class="{ on: n <= filled, stand: n > seatSegs }"></i>
          </div>
        </div>
        <div class="score" :title="tr('hud.scoreTip')">
          <svg viewBox="0 0 44 44" class="ring" aria-hidden="true">
            <circle cx="22" cy="22" r="18" class="ring-bg" />
            <circle cx="22" cy="22" r="18" class="ring-fg" :stroke-dasharray="ringDash" />
          </svg>
          <span class="grade">{{ d.score.grade }}</span>
          <span class="points">{{ d.score.points }}</span>
        </div>
      </footer>

      <transition name="note">
        <div v-if="lastNote" class="note" :key="d.noteSeq">
          <span>{{ noteText(lastNote.text) }}</span><b v-if="lastNote.points">{{ lastNote.points }}</b>
        </div>
      </transition>
    </template>
  </div>
</template>

<script setup>
import { computed, onMounted, ref, watch } from "vue"
import { useBridge } from "@/bridge"
import { useEvents } from "@/services/events"

const { api } = useBridge()
const events = useEvents()
const d = ref(null)
const compact = ref(false)

// ---- the two languages of the add-on (the menu follows the same rule: Ukrainian / Russian game language -> uk)
const lang = (typeof navigator !== "undefined" && /^(uk|ru|be)/i.test(navigator.language || "")) ? "uk" : "en"
const TEXT = {
  en: {
    "hud.idle.plate": "Bus", "hud.idle.text": "No trip. Press Ctrl+Shift+B to pick a route.",
    "hud.armed": "Drive to the start", "hud.armedHint": "The trip begins when you get there and stop.",
    "hud.done": "Trip finished: {points} points. Open the menu for details.", "hud.toggle": "Click to fold",
    "hud.openDoors": "Open the doors", "hud.closeDoors": "Close the doors and go", "hud.gettingOff": "{n} getting off", "hud.boarding": "{n} boarding",
    "hud.due": "due {time}", "hud.waiting": "{n} waiting", "hud.stopRequested": "Stop requested",
    "hud.onboard": "on board", "hud.onboardTip": "Passengers on board / capacity", "hud.scoreTip": "Score of this trip", "hud.progress": "Progress along the line",
    "hud.onTime": "On time", "hud.ghost": "Ghost", "hud.ghostWait": "starts when you leave", "hud.ghostTip": "Your best trip on this line ({points} points): + slower than it was here, − faster", "m": "m", "km": "km", "ft": "ft", "mi": "mi",
    "note.Left early": "Left early", "note.Stop skipped": "Stop skipped", "note.Moving with doors open": "Moving with doors open", "note.Collision": "Collision",
  },
  uk: {
    "hud.idle.plate": "Автобус", "hud.idle.text": "Рейсу немає. Ctrl+Shift+B: обрати маршрут.",
    "hud.armed": "Їдьте до початку", "hud.armedHint": "Рейс почнеться, коли ви доїдете й зупинитесь.",
    "hud.done": "Рейс завершено: {points} балів. Подробиці в меню.", "hud.toggle": "Клік: згорнути",
    "hud.openDoors": "Відчиніть двері", "hud.closeDoors": "Зачиніть двері й рушайте", "hud.gettingOff": "виходить {n}", "hud.boarding": "заходить {n}",
    "hud.due": "за розкладом {time}", "hud.waiting": "чекає {n}", "hud.stopRequested": "Зупинку замовлено",
    "hud.onboard": "у салоні", "hud.onboardTip": "Пасажирів у салоні / місткість", "hud.scoreTip": "Бали за рейс", "hud.progress": "Пройдено по маршруту",
    "hud.onTime": "Вчасно", "hud.ghost": "Привид", "hud.ghostWait": "рушає, коли ви рушите", "hud.ghostTip": "Ваш найкращий рейс на цьому маршруті ({points} балів): + повільніше, ніж тут їхали тоді, − швидше", "m": "м", "km": "км", "ft": "фт", "mi": "миль",
    "note.Left early": "Поїхали раніше часу", "note.Stop skipped": "Зупинку пропущено", "note.Moving with doors open": "Рух з відчиненими дверима", "note.Collision": "Зіткнення",
  },
}
function tr(key, p) {
  let s = (TEXT[lang] && TEXT[lang][key]) || TEXT.en[key] || key
  if (p) for (const k in p) s = s.replace("{" + k + "}", p[k])
  return s
}
const noteText = t => (TEXT[lang] && TEXT[lang]["note." + t]) || t

// ---- the numbers
const lineColour = computed(() => (d.value && ((d.value.route && d.value.route.colour) || (d.value.armed && d.value.armed.colour))) || "#4aa3df")
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
// dark text on a light line colour, white on a dark one
const lineInk = computed(() => {
  const m = /^#([0-9a-f]{6})$/i.exec(lineColour.value)
  if (!m) return "#0b1a22"
  const n = parseInt(m[1], 16)
  return (0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255 > 0.55 ? "#0b1a22" : "#ffffff"
})
const shown = computed(() => (d.value ? (compact.value ? d.value.stops.slice(0, 1) : d.value.stops) : []))
const atStop = computed(() => d.value && (d.value.phase === "atStop" || d.value.phase === "start"))
const pad = n => String(n).padStart(2, "0")
function timeLabel(sec) {
  const s = Math.floor(((sec % 86400) + 86400) % 86400)
  return pad(Math.floor(s / 3600)) + ":" + pad(Math.floor((s % 3600) / 60))
}
const clockText = computed(() => (d.value ? timeLabel(d.value.clock) : "--:--"))

const delay = computed(() => {
  const n = d.value && d.value.next
  if (!n || n.delta === undefined || n.delta === null) return null
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

events.on("EarthBusRoutesHud", data => { d.value = data })

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

// ---- the line diagram
.line {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  padding: 2px 4px 0 6px;
  overflow: hidden;
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
.route-progress { margin: 8px 0 6px 24px; }
@keyframes arrive {
  0% { box-shadow: 0 0 0 0 var(--line); }
  100% { box-shadow: 0 0 0 12px transparent; }
}

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
.note-enter-active { transition: opacity 0.2s, transform 0.2s; }
.note-enter-from { opacity: 0; transform: translateY(6px); }
.note-leave-active { transition: opacity 2.5s; }
.note-leave-to { opacity: 0; }

@media (prefers-reduced-motion: reduce) {
  .stop.current .dot { animation: none; }
}
</style>
