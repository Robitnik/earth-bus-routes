<template>
  <svg class="mini" :viewBox="`0 0 ${W} ${H}`" role="img" :aria-label="label" preserveAspectRatio="xMidYMid meet">
    <defs>
      <pattern id="ebm-grid" width="40" height="40" patternUnits="userSpaceOnUse">
        <path d="M40 0H0V40" fill="none" stroke="rgba(255,255,255,0.05)" stroke-width="1" />
      </pattern>
    </defs>
    <rect :width="W" :height="H" fill="url(#ebm-grid)" />

    <!-- the road path of the route -->
    <polyline v-if="linePoints" :points="linePoints" class="road-casing" />
    <polyline v-if="linePoints" :points="linePoints" class="road" />

    <!-- stops on the way (stops screen) -->
    <g v-for="(st, i) in stopDots" :key="'s' + i">
      <circle :cx="st.x" :cy="st.y" :r="st.chosen ? 0 : 3.2" class="way-stop" :class="{ off: !st.on }" />
    </g>

    <!-- stations to pick from -->
    <g v-for="c in candDots" :key="'c' + c.id" class="cand" :class="{ hot: hover === c.id, behind: c.ahead === false, station: c.station }"
       @click="emit('pick', c.id)" @mouseenter="emit('hover', c.id)" @mouseleave="emit('hover', null)">
      <circle :cx="c.x" :cy="c.y" r="14" class="hit" />
      <rect v-if="c.station" :x="c.x - 5.5" :y="c.y - 5.5" width="11" height="11" rx="2" class="dot" />
      <circle v-else :cx="c.x" :cy="c.y" r="4.5" class="dot" />
      <text v-if="hover === c.id" :x="c.x > W - 190 ? c.x - 10 : c.x + 10" :y="c.y - 8" class="tip" :text-anchor="c.x > W - 190 ? 'end' : 'start'">{{ short(c.name) }}</text>
    </g>

    <!-- you -->
    <g v-if="youDot" class="you"><circle :cx="youDot.x" :cy="youDot.y" r="15" class="halo" /><circle :cx="youDot.x" :cy="youDot.y" r="5" class="core" /></g>

    <!-- towns: chips, the bigger first; one that would cover another is left out -->
    <g v-for="pl in placeChips" :key="'t' + pl.id" class="place" :class="pl.kind" @click="emit('place', pl.id)">
      <rect :x="pl.x - pl.w / 2" :y="pl.y - pl.h / 2" :width="pl.w" :height="pl.h" :rx="pl.h / 2" class="chip" />
      <text :x="pl.x" :y="pl.y + pl.fs * 0.35" class="pl-name" :style="{ fontSize: pl.fs + 'px' }">{{ pl.name }}</text>
    </g>

    <!-- stations already chosen -->
    <g v-for="(p, i) in pointDots" :key="'p' + i" class="chosen">
      <circle :cx="p.x" :cy="p.y" r="11" class="ring" />
      <text :x="p.x" :y="p.y + 4.5" class="num">{{ i + 1 }}</text>
      <text v-if="showNames" :x="p.x > W - 190 ? p.x - 16 : p.x + 16" :y="p.y + 4" class="nm" :text-anchor="p.x > W - 190 ? 'end' : 'start'">{{ short(p.name) }}</text>
    </g>
  </svg>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  points: { type: Array, default: () => [] },     // chosen stations: { lat, lon, name }
  line: { type: Array, default: null },           // the road: [[lat, lon], ...]
  cands: { type: Array, default: () => [] },      // { id, lat, lon, name, station, ahead }
  stops: { type: Array, default: () => [] },      // stops along the road: { lat, lon, chosen, on }
  hover: { type: [Number, String], default: null },
  showNames: { type: Boolean, default: true },
  label: { type: String, default: "map" },
  places: { type: Array, default: () => [] },     // towns: { id, name, lat, lon, kind }
  you: { type: Object, default: null },           // where the player is: { lat, lon }
})
const emit = defineEmits(["pick", "hover", "place"])

const W = 460
const H = 380
const PAD = 34

const NEAR_M = 6000
// what the map is fitted to: the route; while there is no road yet, the stations within a few km as well
const all = computed(() => {
  const out = []
  for (const p of props.points) out.push([p.lat, p.lon])
  if (props.line) for (const p of props.line) out.push(p)
  if (props.you) out.push([props.you.lat, props.you.lon])
  if (props.places.length) {
    // a map of towns: all of them (the biggest 40) in the frame
    for (const p of props.places.slice(0, 40)) out.push([p.lat, p.lon])
  } else if (!props.line || props.line.length < 2) {
    for (const c of props.cands) if (c.dist == null || c.dist <= NEAR_M) out.push([c.lat, c.lon])
  }
  return out
})

const frame = computed(() => {
  const pts = all.value
  if (!pts.length) return null
  let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180
  for (const [la, lo] of pts) {
    if (la < minLat) minLat = la
    if (la > maxLat) maxLat = la
    if (lo < minLon) minLon = lo
    if (lo > maxLon) maxLon = lo
  }
  const k = Math.cos(((minLat + maxLat) / 2) * Math.PI / 180)
  const dx = Math.max((maxLon - minLon) * k, 1e-4)
  const dy = Math.max(maxLat - minLat, 1e-4)
  const scale = Math.min((W - 2 * PAD) / dx, (H - 2 * PAD) / dy)
  const ox = (W - dx * scale) / 2
  const oy = (H - dy * scale) / 2
  return { minLat, maxLat, minLon, k, scale, ox, oy, dy }
})

function project(lat, lon) {
  const f = frame.value
  if (!f) return { x: W / 2, y: H / 2 }
  return { x: f.ox + (lon - f.minLon) * f.k * f.scale, y: f.oy + (f.maxLat - lat) * f.scale }
}

const linePoints = computed(() => {
  if (!props.line || props.line.length < 2) return ""
  return props.line.map(([la, lo]) => { const p = project(la, lo); return p.x.toFixed(1) + "," + p.y.toFixed(1) }).join(" ")
})
const pointDots = computed(() => props.points.map(p => ({ ...project(p.lat, p.lon), name: p.name })))
// stations outside the frame are only in the list
const candDots = computed(() => props.cands
  .map(c => ({ ...project(c.lat, c.lon), id: c.id, name: c.name, station: c.station, ahead: c.ahead }))
  .filter(c => c.x > 8 && c.x < W - 8 && c.y > 8 && c.y < H - 8))
const stopDots = computed(() => props.stops.map(s => ({ ...project(s.lat, s.lon), chosen: s.chosen, on: s.on })))

const youDot = computed(() => (props.you ? project(props.you.lat, props.you.lon) : null))
const FS = { city: 17, town: 14, village: 11.5 }
const placeChips = computed(() => {
  const out = []
  // the stations already chosen stand for their towns: their numbered markers and names, not a second label
  const boxes = pointDots.value.map(d => ({ x: d.x + 60, y: d.y, w: 150, h: 26 }))
  for (const p of props.places) {
    const { x, y } = project(p.lat, p.lon)
    const fs = FS[p.kind] || 12
    const w = String(p.name).length * fs * 0.6 + 16
    const h = fs + 9
    if (x < w / 2 || x > W - w / 2 || y < h / 2 || y > H - h / 2) continue
    if (boxes.some(b => Math.abs(b.x - x) < (b.w + w) / 2 + 2 && Math.abs(b.y - y) < (b.h + h) / 2 + 2)) continue
    boxes.push({ x, y, w, h })
    out.push({ id: p.id, name: p.name, kind: p.kind, x, y, w, h, fs })
  }
  return out
})

function short(n) {
  n = String(n || "")
  return n.length > 26 ? n.slice(0, 25) + "…" : n
}
</script>

<style scoped lang="scss">
.mini { width: 100%; height: 100%; display: block; background: #121f26; border-radius: 10px; }
.road-casing { fill: none; stroke: #0b1519; stroke-width: 9; stroke-linejoin: round; stroke-linecap: round; }
.road { fill: none; stroke: var(--line); stroke-width: 5; stroke-linejoin: round; stroke-linecap: round; }
.way-stop { fill: var(--ink); stroke: #0b1519; stroke-width: 1.5; &.off { fill: none; stroke: var(--muted); } }
.cand {
  cursor: pointer;
  .hit { fill: transparent; }
  .dot { fill: #1a2830; stroke: var(--ink); stroke-width: 2; transition: transform 0.12s; transform-box: fill-box; transform-origin: center; }
  &.station .dot { stroke: var(--led); }
  &.behind .dot { stroke: var(--muted); }
  &.hot .dot { fill: var(--line); transform: scale(1.35); }
  &:focus-visible .dot { stroke-width: 3; }
}
.tip { fill: var(--ink); font-size: 13px; font-weight: 700; paint-order: stroke; stroke: #0b1519; stroke-width: 4px; pointer-events: none; }
.place { cursor: pointer;
  .chip { fill: #223743; fill-opacity: 0.93; stroke: rgba(255, 255, 255, 0.18); stroke-width: 1; transition: fill 0.12s; }
  .pl-name { fill: var(--ink); text-anchor: middle; font-weight: 700; pointer-events: none; }
  &.city .chip { fill: #2b4a5c; stroke: var(--line); } &.city .pl-name { font-weight: 800; }
  &.village .chip { fill: #1c2d36; } &.village .pl-name { fill: var(--muted); font-weight: 600; }
  &:hover .chip { fill: var(--line); } &:hover .pl-name { fill: var(--ink-on-line); } }
.you { .halo { fill: rgba(255, 255, 255, 0.3); stroke: #fff; stroke-width: 1.5; } .core { fill: #fff; stroke: #0b1519; stroke-width: 2; } }
.chosen {
  .ring { fill: var(--line); stroke: #0b1519; stroke-width: 2.5; }
  .num { fill: var(--ink-on-line); font-size: 12px; font-weight: 800; text-anchor: middle; }
  .nm { fill: var(--ink); font-size: 12.5px; font-weight: 700; paint-order: stroke; stroke: #0b1519; stroke-width: 4px; }
}
@media (prefers-reduced-motion: reduce) { .cand .dot { transition: none; } }
</style>
