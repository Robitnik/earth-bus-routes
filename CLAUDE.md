# earth-bus-routes — правила для агентів

Аддон для BeamNG.Earth: водіння автобуса реальними маршрутами OSM з розкладом, пасажирами, HUD і балами.
Ресерч — `docs/research.md`, плани — `docs/new/` (чекають «+» або в роботі), `docs/done/` (виконані, з розділом «Результат»).

## Перш ніж писати код
- Прочитай `NOTE_FOR_MODDERS.md` у теці гри (`D:\programs\steam\steamapps\common\BeamNG.drive`) і дотримуйся його:
  теку гри не змінювати, лише функції, що є в `lua/` гри, LuaJIT 5.1, унікальні імена (`earthBusRoutes`, `EarthBusHud`).
- API Earth — лише `beamngEarth_api` (`docs/ADDONS.md` у `D:\Projects\BeamNG.Earth-dev`). Внутрішнє Earth — тільки через pcall
  і в одному модулі-обгортці (`geo.lua`, `clock.lua`).
- UI: Vue 3 SFC, як `ui/modules/apps/busLine/app.vue` і `ui/ui-vue/mods/README.md` гри. Дизайн — скіл `frontend-design`,
  перевірка поза грою — скіл `webapp-testing` (`.claude/skills/`).
- Нічого не блокує кадр: мережа неблокуюча, важкі розбори — частинами по кадрах.

## Тести і гра
- Чиста логіка (osm, schedule, demand, scoring) — Lua-тести в `tests/` (lupa, Python з `D:\Projects\BeamNG.Earth-dev\.venv`).
- Перед запуском гри перевір, чи вона вже запущена (інші сесії Claude теж користуються грою). Консоль гри має бути чиста.

## Git
- Гілка `main`; задачі — `feature/<name>`, після закритої задачі — злиття в `main`.
- Push / реліз / запис у реєстр Earth / пропозиції в апстрім Earth — лише з дозволу користувача.
- Дані OSM — ODbL: атрибуція в UI.
