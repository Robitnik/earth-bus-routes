# Ресерч: аддон «Автобусні маршрути» для BeamNG.Earth

Дата: 2026-11-09. Гра 0.40 (Steam, `D:\programs\steam\steamapps\common\BeamNG.drive`), BeamNG.Earth `origin/dev` 80441137 (1.9.x).

## 1. Аддони BeamNG.Earth: як вони влаштовані

Джерело: `docs/ADDONS.md` в `D:\Projects\BeamNG.Earth-dev` (гілка `origin/dev`), код `server/addons.py`, `mod/.../beamngEarth/addons.lua`, `api.lua`.

- **Реєстр**: сторінка Add-ons у грі показує курований список (`server/data/addons.json`, з 1.9.0 онлайн-копія в репо
  BeamNG.Earth-data). Ставити можна лише репо зі списку. Види: `beamng-mod` (zip у mods), `companion` (програма поруч із грою,
  Python, запускається Python-ом Earth), `link`.
- **Наш вид — `beamng-mod`**: публічний GitHub-репо з релізами; zip зі стабільною назвою, у корені zip — теки гри (`lua/`, `ui/`,
  `scripts/`), без вкладеної теки. Earth сам качає реліз, перевіряє SHA-256 від GitHub, ставить через `core_modmanager`,
  а при оновленні вивантажує наші GE-розширення й перезавантажує UI (без рестарту гри).
- **Локальна спроба до релізу**: `%LOCALAPPDATA%\beamng-earth\addons\local.json` (формат реєстру + `local: {file, tag}`) —
  аддон з'являється з позначкою **Local**. Так тестуємо до того, як просимо внести нас у реєстр.
- **Опції аддона**: `beamngEarth_addon.json` у корені zip (`options`: int/bool/text/choice); мод читає їх
  `beamngEarth_api.addonOptions(id)` і чує зміни через `onBeamNGEarthAddonOptions`.
- Наявні аддони: Worldwide Trucking Career (мод з UI-апом `TruckingCareerDC`), Live GPS (companion).

### Modding API v1 (`beamngEarth_api`, зараз 1.3)

`version()`, `has(name)`, `ready()`, `inWorld()`, `pose()` (`lat, lon, alt, heading, speed, x, y, z, anchorLat, anchorLon`),
`place()` (вулиця/місто/країна), `teleport(lat, lon, name)`, `gpsSet`, `gpsSetRoute(points ≤ 11)` (маршрут GPS через точки, по
порядку, «пройдено» в межах 40 м), `gps()` (залишок, ETA, `legs`), `notify(text, s)`, `inTunnel()`, `weather()` (дощ/сніг 0..1,
температура), події `worldReady`, `teleported`, `routeArrived`, `waypointReached`.

**Чого бракує для нас** (пропозиції в апстрім, див. план, етап J):
1. Перетворення `lat, lon → x, y, z` гри і назад. Внутрішньо є `anchor:worldToGeodetic` / `geodeticToWorld` у
   `beamngEarth_core._state().anchor`, але це внутрішнє API, що міняється. Потрібне `api.toGame(lat, lon)` / `api.toGeo(x, y, z)`.
2. Керування годинником: небо Earth (`beamngEarth/sky.lua`) у режимі `real` тримає реальний час; будь-яка зміна часу іншим
   модом перемикає його в `manual` **з тостом і зберігає це в налаштуваннях гравця**. Потрібне `api.setClock(hours, speed)` /
   `api.releaseClock()`, як у місій (вони ставлять і відновлюють свій час).
3. (бажано) Обмеження швидкості й клас дороги в позиції гравця — вже в списку «Next for v1.x» в ADDONS.md.

## 2. Що вже є в самій грі (0.40)

- **Штатний режим Bus Routes**: `lua/ge/extensions/core/busRouteManager.lua`, `scenario/busdriver.lua`, рівні з
  `levels/<level>/buslines/*.buslines.json` і тригерами `busstop`. На Earth їх нема (рівень генерується), тому режим не підходить,
  але **корисний контракт з автобусом**:
  - контролер `vehicles/citybus/lua/controller/bus.lua`: двері (`electrics.values.dooropen`), кнеелінг (`kneel`), підйом;
  - подія `controller.onGameplayEvent('bus_onRouteChange', {direction, routeID, tasklist, routeColor, ...})` оновлює
    **табло маршруту на автобусі** (htmlTexture) і табло «наступна зупинка»; `bus_onRequestState`, `SetStopRequest`
    (кнопка «зупинка на вимогу»);
  - гук `onBusUpdate(state)` у GE (стан автобуса).
  Тобто штатні автобуси (і моди, що повторюють цей контролер) покажуть номер і напрямок нашого маршруту.
- **Фільтр автобусів** (з пам'яті попередньої роботи): `Body Style == "Bus"` і `Commercial Class == "Transit Bus"` в info.
- **UI-апи на Vue**: штатний `ui/modules/apps/busLine/` — це `app.json` + `app.vue` (Vue 3 Composition API,
  `useBridge()`, `useEvents()`, `api.activeObjectLua(...)`), моки в `mockdata/`. Тобто HUD-ап мода можна писати на Vue.
- **Vue-моди**: `ui/ui-vue/mods/README.md` — SFC у `/ui/ui-vue/mods/<mod>/`, слоти (`modInfo.uiSlots`), вкладка в меню паузи
  (`ui_pause_actions.registerModTab`, так робить Earth), окремі сторінки-маршрути (Standalone routes), компоненти гри
  `@/common/components/base` (`BngButton` ...). Приклад у грі — «Anna's Toolbox». Earth так робить свою карту й налаштування.
- **Мережа з Lua**: LuaSocket є (`lua/common/libs/luasocket`, `socket.http`), **TLS нема** — лише `http://`. Неблокуючий
  патерн: `socket.tcp()` + `settimeout(0)` щокадру, як `beamngEarth/net.lua`. `copas` теж у грі.
- **Офіційна інструкція для моддерів і AI-інструментів**: `NOTE_FOR_MODDERS.md` у теці гри (не редагувати теку гри, усе
  в `mods/unpacked/<mod>/`, унікальні імена `name_username`, лише функції, що є в `lua/` гри, LuaJIT 5.1, чиста консоль).
- **Офіційний MCP-сервер у грі**: `lua/ge/extensions/mcp/server.lua` (`extensions.load('mcp_server')`,
  `http://127.0.0.1:29292/mcp`, інструменти camera/scene/sim/spawn/ui/vehicle/world ...). Earth має обгортку `tools/mcp.py`.
- **Час доби**: `core_environment.setTimeOfDay({time = t})`, `time` — частка доби, **полудень = 0** (`core/celestial.lua`).

## 3. Дані про автобусні маршрути: API

| джерело | що дає | ключ | світ | вердикт |
|---|---|---|---|---|
| **OSM через Overpass API** | зупинки (`highway=bus_stop`, `public_transport=platform/stop_position`), маршрути — relation `type=route route=bus/trolleybus` з **упорядкованими** членами (ролі `stop`, `platform`, шляхи), теги `ref, name, from, to, network, operator, colour, interval, duration, opening_hours`, `route_master` об'єднує напрямки | ні (потрібен User-Agent, інакше 406) | весь | **основне джерело** |
| Transitland REST v2 (`transit.land/api/v2/rest`) | GTFS: зупинки в радіусі (≤ 10 км), маршрути, **реальний розклад** `/stops/{key}/departures`, real-time де є | так, безкоштовний некомерційний з низьким лімітом | ~2500 операторів | опціонально, пізніше (опція з ключем гравця) |
| Mobility Database (`/v1/gtfs_feeds`, bbox) | каталог GTFS-фідів (zip) | токен | весь | ні: цілі zip-и, важко в Lua |
| Earth (Overture `transit/bus_stop`) | точки зупинок з тегами shelter/bench/name | — | весь | лише зупинки, без маршрутів; зупинки Earth уже малює (наші задачі 020-034) |

### Перевірка Overpass (2026-11-09)

- `http://overpass-api.de/api/interpreter` відповідає по **http** (200 з User-Agent) — отже, можна просто з Lua гри.
- Náchod (50.4157, 16.1626), 400 м: **11 маршрутів**, `ref` 11/11, `from/to` 7/11, `public_transport:version=2` 8/11,
  **`interval`/`duration`/`opening_hours` — 0/11**, `colour` 0/11. Висновок: розклад треба **генерувати** (теги інтервалу —
  рідкість), PTv1-маршрути (без порядку зупинок) треба впорядковувати проєкцією на ланцюжок шляхів.
- Головний сервер і дзеркало `overpass.private.coffee` у той же вечір віддавали **502 / «at capacity»** і таймаути.
  Висновок: кеш на диску, кілька дзеркал, експоненційні повтори, малі запити, ніколи не блокувати кадр.
- Порядок членів relation в Overpass `out body` зберігається (масив `members` — у порядку relation), це і є порядок зупинок PTv2.
  Overpass не розкриває relation у relation рекурсивно: `route_master` — окремим кроком (`rel(br)`).

Приклади запитів:

```
// маршрути через зупинки поруч
[out:json][timeout:25];
( node[highway=bus_stop](around:600,LAT,LON);
  node[public_transport=platform][bus=yes](around:600,LAT,LON); )->.s;
rel(bn.s)[type=route][route~"^(bus|trolleybus|minibus|share_taxi)$"];
out tags;
// один маршрут повністю: члени по порядку + геометрія
[out:json][timeout:25];
rel(ID); out body geom;
```

Використання: ODbL, атрибуція «© OpenStreetMap contributors» в UI; політика Overpass — помірні запити (≤ 10 тис./добу, ≤ 1 ГБ).

## 4. Існуючі HUD/автобусні моди (BeamNG)

- **WayLine Bus Controller** (наступник Bus Display Controller), 0.39: маршрути з поточної карти, табло, ETA, голосові
  оголошення зупинок і номерів маршрутів. Працює на штатних buslines — на Earth нема.
- **Bus Display Controller**: ручне керування табло автобусів (Wentward, Capsule).
- **Enhanced Dashboard**: загальний HUD (GPS-підказки, ETA).
- Не знайдено жодного мода з пасажиропотоком, розкладом і балами — ніша вільна.

## 5. Офіційні скіли (Anthropic, `github.com/anthropics/skills`, Apache-2.0)

Покладено в репо, `.claude/skills/`:
- **frontend-design** — напрям дизайну, типографіка, нешаблонні рішення: для HUD і меню.
- **webapp-testing** — Playwright: відкрити HUD/меню в браузері з моками, скриншоти, логи консолі.

Ще можуть знадобитися (не покладено): `theme-factory` (палітри), `skill-creator` (свій скіл «BeamNG Vue UI-ап»), `canvas-design`.
Від BeamNG офіційних скілів немає; є їхній `NOTE_FOR_MODDERS.md` і вбудований MCP (вище) — це і є «офіційне» для агентів.

## Джерела

- BeamNG.Earth `docs/ADDONS.md`, `api.lua`, `sky.lua`, `net.lua` (локальний checkout).
- Гра: `NOTE_FOR_MODDERS.md`, `ui/ui-vue/mods/README.md`, `ui/modules/apps/busLine/app.vue`, `content/vehicles/citybus.zip:…/bus.lua`.
- [BeamNG docs: Creating an app](https://documentation.beamng.com/modding/ui/app_creation), [BeamMP docs: UI apps](https://docs.beammp.com/beamng/dev/modding/ui-apps/)
- [Overpass blog: PT tagging](https://dev.overpass-api.de/blog/some_tagging_in_pt.html), [roataway/infrastructure-data](https://github.com/roataway/infrastructure-data), [OSM help: stops of a route](https://help.openstreetmap.org/questions/68040/how-to-get-coordinates-and-names-of-public-transport-stations-of-a-specific-route/?sort=votes)
- [Transitland REST API](https://transit.land/documentation/rest-api/), [Stops](https://www.transit.land/documentation/rest-api/stops), [Departures](https://www.transit.land/documentation/rest-api/departures)
- [Mobility Database catalogs](https://github.com/MobilityData/mobility-database-catalogs)
- [WayLine Bus Controller](https://www.modland.net/beamng.drive-mods/wayline-bus-controller.html), [Bus Display Controller](https://www.beamng.com/resources/bus-display-controller.21292/), [Enhanced Dashboard](https://www.beamng.com/resources/enhanced-dashboard.39626/)
- [anthropics/skills](https://github.com/anthropics/skills)
