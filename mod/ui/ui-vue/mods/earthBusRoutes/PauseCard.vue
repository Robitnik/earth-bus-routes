<template>
  <!-- The Mods tab's card of the pause menu: one button into the menu page -->
  <div class="ebr-card">
    <h3>{{ t("title") }}</h3>
    <p class="muted">{{ t("near.sub") }}</p>
    <BngButton :accent="ACCENTS.main" @click="open">{{ t("title") }}</BngButton>
    <p class="muted key">Ctrl+Shift+B</p>
  </div>
</template>

<script setup>
import { BngButton, ACCENTS } from "@/common/components/base"
import { call } from "./store.js"
import { t } from "./i18n.js"

function open() { call("uiOpen") }
</script>

<style scoped lang="scss">
.ebr-card { display: flex; flex-direction: column; align-items: flex-start; gap: 10px; padding: 12px; }
h3 { margin: 0; font-size: 18px; }
.muted { margin: 0; color: #93a9b4; }
.key { font-size: 13px; }
</style>
