<template>
  <!-- A drop-down of our own: the game's browser does not open the list of a native <select> (seen in 0.13.0: the language and
       announcer choices did nothing). A button, and under it the list; a click outside or Esc closes it. -->
  <div class="pick" :class="{ open, disabled }" ref="root" :title="title">
    <button type="button" class="pick-btn" :disabled="disabled" :aria-label="ariaLabel" aria-haspopup="listbox" :aria-expanded="open"
      @click="toggle" @keydown.esc.stop="open = false">
      <span v-if="icon" class="pick-icon" aria-hidden="true">{{ icon }}</span>
      <span class="pick-text">{{ currentLabel }}</span>
      <span class="pick-caret" aria-hidden="true">▾</span>
    </button>
    <ul v-if="open" class="pick-list" role="listbox" :class="{ up }">
      <li v-for="o in options" :key="String(o.value)" role="option" :aria-selected="o.value === value" :class="{ on: o.value === value }"
        @click.stop="choose(o.value)">{{ o.label }}</li>
    </ul>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, ref } from "vue"

const props = defineProps({
  value: { type: [String, Number, Boolean], default: null },
  options: { type: Array, default: () => [] },          // [{ value, label }]
  icon: { type: String, default: "" },
  title: { type: String, default: "" },
  ariaLabel: { type: String, default: "" },
  disabled: { type: Boolean, default: false },
  up: { type: Boolean, default: false },                 // open upwards (at the bottom of a card)
})
const emit = defineEmits(["pick"])
const open = ref(false)
const root = ref(null)
const currentLabel = computed(() => {
  const o = props.options.find(x => x.value === props.value)
  return o ? o.label : (props.options[0] ? props.options[0].label : "")
})

function outside(e) { if (root.value && !root.value.contains(e.target)) close() }
function close() {
  open.value = false
  document.removeEventListener("mousedown", outside, true)
}
function toggle() {
  if (props.disabled) return
  if (open.value) return close()
  open.value = true
  document.addEventListener("mousedown", outside, true)
}
function choose(v) {
  close()
  if (v !== props.value) emit("pick", v)
}
onBeforeUnmount(close)
</script>

<style scoped lang="scss">
.pick { position: relative; display: inline-flex; }
.pick-btn {
  display: flex; align-items: center; gap: 6px; border: 1px solid var(--hair); border-radius: 8px; padding: 6px 8px;
  background: transparent; color: var(--ink); font: inherit; font-weight: 700; cursor: pointer; max-width: 280px;
  &:hover:not(:disabled) { border-color: var(--muted); }
  &:disabled { opacity: 0.5; cursor: default; }
}
.pick-icon { font-size: 14px; color: var(--muted); }
.pick-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pick-caret { color: var(--muted); font-size: 11px; }
.pick-list {
  position: absolute; top: calc(100% + 4px); right: 0; z-index: 50; min-width: 100%; max-height: 360px; overflow-y: auto;
  margin: 0; padding: 4px; list-style: none; background: #1b2a32; border: 1px solid var(--hair); border-radius: 8px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
  &.up { top: auto; bottom: calc(100% + 4px); left: 0; right: auto; }
  li {
    padding: 7px 10px; border-radius: 6px; color: #e8f0f2; white-space: nowrap; cursor: pointer;
    &:hover { background: rgba(255, 255, 255, 0.08); }
    &.on { background: rgba(255, 255, 255, 0.14); font-weight: 700; }
  }
}
</style>
