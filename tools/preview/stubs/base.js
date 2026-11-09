import { h } from "vue"
export const ACCENTS = { main: "main", outlined: "outlined", attention: "attention" }
export const BngButton = { props: ["accent"], setup(p, { slots }) { return () => h("button", { class: "bng-btn " + (p.accent || "") }, slots.default && slots.default()) } }
export const BngSelect = { props: ["value", "options"], setup() { return () => h("select") } }
