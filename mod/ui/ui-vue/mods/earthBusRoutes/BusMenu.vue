<template>
  <div class="ebm" tabindex="-1" ref="rootEl" @keydown.esc.stop="close" :style="{ '--line': lineColour, '--ink-on-line': lineInk }">
    <div class="shell">
      <header class="top">
        <div class="titles">
          <h1>{{ t("title") }}</h1>
          <div v-if="whereText" class="where">{{ whereText }}</div>
        </div>
        <nav class="crumbs" aria-label="steps">
          <button v-if="['lines', 'route', 'build', 'buildStops'].includes(screen)" class="crumb" :disabled="busyTrip" @click="go('nearby')">{{ t("crumb.stops") }}</button>
          <template v-if="s && (screen === 'build' || screen === 'buildStops')">
            <span class="sep"></span>
            <button class="crumb" :class="{ on: screen === 'build' }" @click="screen === 'buildStops' && go('build')">{{ t("crumb.build") }}</button>
          </template>
          <template v-if="s && screen === 'buildStops'">
            <span class="sep"></span>
            <span class="crumb on">{{ t("crumb.stopsStep") }}</span>
          </template>
          <template v-if="s && s.station && ['lines', 'route'].includes(screen) && !(s.route && s.route.custom)">
            <span class="sep"></span>
            <button class="crumb" :class="{ on: screen === 'lines' }" @click="go('lines')">{{ s.station.name }}</button>
          </template>
          <template v-if="s && s.route && screen === 'route'">
            <span class="sep"></span>
            <button v-if="s.route.custom && s.build" class="crumb" @click="call('uiBuildBack')">{{ t("crumb.build") }}</button>
            <span v-if="s.route.custom && s.build" class="sep"></span>
            <span class="crumb on"><span class="mini-plate">{{ s.route.ref }}</span>{{ s.route.to }}</span>
          </template>
        </nav>
        <div class="tools">
          <div class="lang" role="group" :aria-label="t('lang')">
            <button :class="{ on: lang === 'en' }" @click="setLang('en')">EN</button>
            <button :class="{ on: lang === 'uk' }" @click="setLang('uk')">УК</button>
          </div>
          <button class="btn ghost" @click="close">{{ t("close") }}</button>
        </div>
      </header>

      <ProgressBar />
      <div v-if="s && s.armed" class="armed-bar" role="status">
        <span class="mini-plate">{{ s.armed.ref }}</span>
        <span class="armed-text">{{ t("armed.text", { stop: s.armed.stopName, dist: dist(s.armed.dist) }) }}</span>
        <button class="btn ghost slim" @click="call('uiCancelArmed')">{{ t("armed.cancel") }}</button>
      </div>

      <main class="body">
        <!-- the add-on cannot work without BeamNG.Earth -->
        <section v-if="s && !s.earth" class="notice bad">
          <h2>BeamNG.Earth</h2>
          <p>{{ s.reason }}</p>
        </section>

        <!-- a trip is running -->
        <section v-else-if="s && screen === 'trip'" class="card center">
          <h2>{{ t("trip.title") }}</h2>
          <p>{{ t("trip.text", { ref: hudRef, to: hudTo }) }}</p>
          <div class="row">
            <button class="btn" @click="close">{{ t("trip.back") }}</button>
            <button class="btn danger" @click="call('uiCancelTrip')">{{ t("trip.cancel") }}</button>
          </div>
        </section>

        <!-- 1. stops near you -->
        <section v-else-if="screen === 'nearby'" class="split">
          <div class="list">
            <div class="head">
              <div class="tabs" role="tablist">
                <button role="tab" :aria-selected="tab === 'near'" :class="{ on: tab === 'near' }" @click="tab = 'near'">{{ t("near.title") }}</button>
                <button role="tab" :aria-selected="tab === 'map'" :class="{ on: tab === 'map' }" @click="openMap">{{ t("map.tab") }}</button>
                <button role="tab" :aria-selected="tab === 'mine'" :class="{ on: tab === 'mine' }" @click="tab = 'mine'">{{ t("mine.title") }}<span v-if="saved.length" class="badge">{{ saved.length }}</span></button>
                <button role="tab" :aria-selected="tab === 'profile'" :class="{ on: tab === 'profile' }" @click="openProfile">{{ t("tab.profile") }}</button>
              </div>
              <div class="head-actions">
                <button v-if="tab === 'near'" class="btn ghost" :disabled="!!(s && s.loading)" @click="call('uiRefresh')">{{ t("refresh") }}</button>
                <button class="btn go slim" :disabled="!stations.length && !(s && s.pos)" @click="call('uiBuildStart')">＋ {{ t("build.start") }}</button>
              </div>
            </div>
            <p v-if="tab === 'near'" class="sub">{{ t("near.sub") }}</p>
            <NextTripCard v-if="tab === 'near' && s && s.nextTrip && !s.find" :trip="s.nextTrip" />

            <!-- search: a station by name, a line by number -->
            <form v-if="tab === 'near'" class="find" @submit.prevent="runFind">
              <input v-model="fq" type="text" maxlength="40" :placeholder="t('find.ph')" :aria-label="t('find.label')"
                     @keydown.stop @keyup.esc.stop="clearFind" @input="typedFind" @focus="typing(true)" @blur="typing(false)" />
              <button type="submit" class="btn" :disabled="!fq.trim()">{{ t("find.go") }}</button>
            </form>
            <template v-if="tab === 'near' && s && s.find">
              <div class="find-head">
                <b>{{ s.find.placeName ? t("find.inPlace", { place: s.find.placeName }) : t(s.find.kind === "lines" ? "find.linesFor" : "find.stationsFor", { q: s.find.q }) }}</b>
                <button class="btn ghost slim" @click="clearFind">{{ t("find.clear") }}</button>
              </div>
              <div v-if="s.find.kind === 'stations' && s.find.places && s.find.places.length" class="places" role="group" :aria-label="t('find.places')">
                <span class="muted small">{{ t("find.places") }}</span>
                <button v-for="pl in s.find.places" :key="pl.id" class="place-chip" :disabled="!!s.find.busy" @click="call('uiFindPlace', pl.id)">
                  {{ pl.name }}<small>{{ placeKind(pl) }}</small>
                </button>
              </div>
              <div v-if="s.find.busy" class="loading small"><span class="spin"></span><div><b>{{ t("find.searching") }}</b><div class="muted">{{ t("find.searchingHint") }}</div></div></div>
              <div v-if="s.find.err" class="notice bad"><p>{{ findErr(s.find.err) }}</p></div>
              <div v-else-if="!s.find.items.length && !s.find.busy" class="empty"><b>{{ t(s.find.kind === "lines" ? "find.noLines" : "find.noStations") }}</b><div class="muted">{{ t(s.find.kind === "lines" ? "find.noLinesHint" : "find.noStationsHint") }}</div></div>
              <div v-if="s.find.kind === 'lines'" class="lines found">
                <div v-for="ln in s.find.items" :key="ln.id" class="line-row">
                  <span class="plate big" :style="{ background: ln.colour, color: ink(ln.colour) }">{{ ln.ref }}</span>
                  <div class="line-body">
                    <div class="muted small">{{ [ln.network, ln.operator].filter(Boolean).join(" · ") }}</div>
                    <div class="variants">
                      <button v-for="v in ln.variants" :key="v.id" class="variant" :disabled="!!s.loading" @click="call('uiFindLine', v.id)">
                        {{ v.ambiguous ? v.label : (v.from && v.to ? v.from + " → " + v.to : v.label) }}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
              <div v-else class="stops found">
                <button v-for="it in s.find.items" :key="it.id" class="stop-card" :disabled="!!s.loading" @click="call('uiFindStation', it.id)">
                  <div class="stop-main">
                    <div class="stop-name">{{ it.name }}</div>
                    <div class="stop-meta">
                      <span class="dist">{{ dist(it.dist) }}</span><span class="dir">{{ it.dir }}</span>
                      <span v-if="it.station" class="tag">{{ t("near.station") }}</span>
                    </div>
                  </div>
                </button>
              </div>
            </template>

            <!-- the map of towns -->
            <template v-if="tab === 'map'">
              <div v-if="s && s.map && s.map.focus" class="map-head">
                <button class="btn ghost" @click="call('uiMapUnfocus')">‹ {{ t("map.all") }}</button>
                <b class="map-town">{{ s.map.focus.name }}</b>
                <button class="btn ghost" @click="townList">{{ t("map.asList") }}</button>
              </div>
              <p v-else class="sub">{{ t("map.hint") }}</p>
              <label v-if="driven" class="driven-toggle"><input v-model="showDriven" type="checkbox" /> {{ t("map.driven") }} <span class="muted small">{{ t("map.drivenHint") }}</span></label>
              <p v-if="busCount" class="bus-note muted small"><i class="bus-dot"></i>{{ t("bus.count", { n: busCount }) }}</p>
              <div v-if="s && s.map && s.map.busy" class="loading small"><span class="spin"></span><div><b>{{ t("map.loading") }}</b><div class="muted">{{ t("map.loadingHint") }}</div></div></div>
              <div v-else-if="s && s.map && s.map.err" class="notice bad"><p>{{ errText(s.map.err) }}</p><button class="btn" @click="openMap">{{ t("retry") }}</button></div>
              <div v-else-if="s && s.map && s.map.towns && !s.map.towns.length" class="empty"><b>{{ t("map.none") }}</b></div>
              <div v-if="s && s.map && s.map.towns && s.map.towns.length" class="map-big">
                <MiniMap :places="s.map.towns" :you="s.pos" :points="[]" :cands="[]" :show-names="false" :label="t('map.tab')"
                         :map-stops="(s.map.focus ? s.map.focusStops : s.map.stops) || []" :focus="s.map.focus || null"
                         :selected="s.map.sel ? s.map.sel.id : null" :tracks="showDriven && driven ? driven.lines : []" :visited="showDriven ? driven : null"
                         :buses="(s && s.buses) || []" :selected-bus="pickedBus"
                         @place="id => call('uiMapFocus', id)" @stop="id => call('uiMapPick', id)" @bus="pickBus" />
              </div>
              <div v-if="s && s.map && s.map.sel" class="map-sel">
                <div class="map-sel-body">
                  <div class="stop-name">{{ s.map.sel.name }}</div>
                  <div class="stop-meta">
                    <span class="tag">{{ t(s.map.sel.kind === "station" ? "map.station" : "map.stop") }}</span>
                    <span v-if="s.map.sel.dist != null" class="dist">{{ dist(s.map.sel.dist) }}</span>
                    <span v-for="c in s.map.sel.lines" :key="c.ref" class="plate" :style="{ background: c.colour, color: ink(c.colour) }">{{ c.ref }}</span>
                    <span v-if="!s.map.sel.lines.length" class="muted">{{ t("map.noLines") }}</span>
                  </div>
                  <p v-if="s.map.actErr" class="act-err">{{ s.map.actErr === "gps" ? t("map.gpsFail") : t("map.teleportFail") }}</p>
                </div>
                <div class="map-sel-actions">
                  <button class="btn go" @click="call('uiMapGo', 'gps')">{{ t("map.gps") }}</button>
                  <button class="btn" @click="call('uiMapGo', 'teleport')">{{ t("map.teleport") }}</button>
                  <button class="btn ghost" @click="mapLines">{{ t("map.linesHere") }}</button>
                </div>
              </div>
            </template>

            <!-- the career: rank, totals, records, achievements -->
            <ProfileTab v-if="tab === 'profile'" :s="s" @map="openMap" />

            <!-- my routes -->
            <template v-if="tab === 'mine'">
              <div v-if="s && s.error" class="notice bad"><p>{{ errText(s.error) }}</p></div>
              <div v-if="s && s.loading === 'route'" class="loading"><span class="spin"></span><div><b>{{ t("mine.opening") }}</b><div class="muted">{{ t("stops.loadingHint") }}</div></div></div>
              <div v-if="!saved.length" class="empty"><b>{{ t("mine.empty") }}</b><div class="muted">{{ t("mine.emptyHint") }}</div></div>
              <div v-else class="stops">
                <div v-for="m in saved" :key="m.id" class="mine-row">
                  <span class="plate big" :style="{ background: m.colour, color: ink(m.colour) }">{{ m.ref }}</span>
                  <div class="mine-body">
                    <div class="stop-name">{{ m.name }}</div>
                    <div class="muted small">{{ m.from }} → {{ m.to }} · {{ t("mine.stations", { n: m.n }) }}</div>
                  </div>
                  <div class="mine-actions">
                    <button class="btn" :disabled="!!(s && s.loading)" @click="call('uiOpenSaved', m.i)">{{ t("mine.open") }}</button>
                    <button class="btn ghost" @click="call('uiEditSaved', m.i)">{{ t("mine.edit") }}</button>
                    <button class="btn ghost" :class="{ danger: sure === m.id }" @click="remove(m)">{{ sure === m.id ? t("mine.sure") : "×" }}</button>
                  </div>
                </div>
              </div>
            </template>

            <div v-if="tab !== 'near' || (s && s.find)"></div>
            <div v-else-if="serviceDown" class="notice">
              <h3>{{ t("svc.downTitle") }}</h3>
              <p>{{ t("svc.downText") }}</p>
              <p class="steps">{{ t("svc.downSteps") }}</p>
              <button class="btn" @click="call('uiRefresh')">{{ t("retry") }}</button>
            </div>
            <div v-else-if="s && s.error" class="notice bad">
              <p>{{ t("err.generic", { e: s.error }) }}</p>
              <button class="btn" @click="call('uiRefresh')">{{ t("retry") }}</button>
            </div>
            <div v-else-if="!s || s.loading === 'nearby'" class="loading">
              <span class="spin"></span>
              <div><b>{{ t("near.loading") }}</b><div class="muted">{{ t("near.loadingHint") }}</div></div>
            </div>
            <div v-else-if="!stations.length" class="empty">
              <b>{{ t("near.empty") }}</b>
              <div class="muted">{{ t("near.emptyHint") }}</div>
            </div>
            <div v-else class="stops">
              <button v-for="(st, i) in stations" :key="st.id" class="stop-card" :class="{ nearest: i === 0 }" @click="call('uiSelectStation', st.id)">
                <div class="stop-main">
                  <div class="stop-name">{{ st.name }}</div>
                  <div class="stop-meta">
                    <span class="dist">{{ dist(st.dist) }}</span>
                    <span class="dir">{{ st.dir }}</span>
                    <span v-if="st.station" class="tag">{{ t("near.station") }}</span>
                    <span v-else-if="st.platforms > 1" class="muted">{{ t("near.platforms", { n: st.platforms }) }}</span>
                  </div>
                </div>
                <div class="chips">
                  <span v-for="c in st.lines" :key="c.ref" class="plate" :style="{ background: c.colour, color: ink(c.colour) }">{{ c.ref }}</span>
                  <span v-if="st.lineCount > st.lines.length" class="muted">+{{ st.lineCount - st.lines.length }}</span>
                  <span v-if="!st.lineCount" class="muted">—</span>
                </div>
              </button>
            </div>
          </div>
          <aside class="aside">
            <DepartureBoard v-if="s && s.board && tab === 'map'" :board="s.board" />
            <div class="card">
              <h3>{{ t("near.position") }}</h3>
              <div v-if="s && s.pos" class="coords">{{ s.pos.lat.toFixed(5) }}, {{ s.pos.lon.toFixed(5) }}</div>
              <div v-if="whereText" class="muted">{{ whereText }}</div>
            </div>
            <div v-if="s && s.stats && s.stats.trips" class="card">
              <h3>{{ t("stats.title") }}</h3>
              <div class="muted">{{ t("stats.line", { trips: s.stats.trips, pax: s.stats.passengers }) }}</div>
            </div>
          </aside>
        </section>

        <!-- 2. lines at the stop -->
        <section v-else-if="screen === 'lines'" class="list wide">
          <div class="head">
            <div>
              <h2>{{ t("lines.title", { name: s.station ? s.station.name : "" }) }}</h2>
              <p class="sub">{{ t("lines.sub") }}</p>
            </div>
            <div class="head-actions">
              <button class="btn ghost" @click="call('uiBuildStart', s.station ? s.station.id : 1)">＋ {{ t("build.fromHere") }}</button>
              <button class="btn ghost" @click="go('nearby')">{{ t("back") }}</button>
            </div>
          </div>
          <div v-if="s.loading === 'route'" class="loading"><span class="spin"></span><div><b>{{ t("lines.loading") }}</b><div class="muted">{{ t("lines.loadingHint") }}</div></div></div>
          <div v-if="s.error" class="notice bad"><p>{{ t("err.generic", { e: s.error }) }}</p></div>
          <DepartureBoard v-if="s.board" :board="s.board" class="station-board" />
          <div class="tabs station-tabs" role="tablist">
            <button v-for="k in TABS" :key="k" role="tab" :aria-selected="curTab === k" :class="{ on: curTab === k }" @click="call('uiSetTab', k)">
              {{ t("tabs." + k) }}<span class="badge" :class="{ zero: !tabCount(k) }">{{ tabCount(k) }}</span>
            </button>
          </div>
          <p class="sub tab-hint">{{ t("tabs." + curTab + "Hint") }}</p>
          <div v-if="!tabLines.length" class="empty"><b>{{ t("tabs.empty") }}</b><div class="muted">{{ t("tabs.emptyHint") }}</div></div>
          <div class="lines">
            <div v-for="ln in tabLines" :key="ln.id" class="line-row">
              <span class="plate big" :style="{ background: ln.colour, color: ink(ln.colour) }">{{ ln.ref }}</span>
              <div class="line-body">
                <div class="muted small">{{ [ln.network, ln.operator].filter(Boolean).join(" · ") }}</div>
                <div class="variants">
                  <button v-for="v in ln.variants" :key="v.id" class="variant" :disabled="s.loading === 'route'" @click="call('uiSelectRoute', v.id)">
                    {{ variantText(v) }}<i v-if="v.approx" class="approx" :title="t('tabs.approx')">~</i>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- manual mode -->
        <BuildPage v-else-if="screen === 'build' && s.build" :s="s" />
        <StopsPage v-else-if="screen === 'buildStops' && s.build" :s="s" />

        <!-- 3. the route and starting it -->
        <section v-else-if="screen === 'route' && s.route" class="route">
          <div class="card line-card">
            <div class="line-head">
              <span class="plate huge" :style="{ background: s.route.colour, color: ink(s.route.colour) }">{{ s.route.ref }}</span>
              <div>
                <div class="from-to">{{ s.route.from }}<span class="arrow"> → </span>{{ s.route.to }}</div>
                <div class="muted small"><span v-if="s.route.custom" class="own">{{ t("route.own") }}</span><span v-if="s.route.timetable === 'gtfs'" class="own real" :title="t('route.realHint')">{{ t("route.real") }}</span>{{ kindText }}<template v-if="s.route.loop"> · {{ t("route.loop") }}</template></div>
              </div>
            </div>
            <dl class="facts">
              <div v-if="s.route.operator"><dt>{{ t("route.operator") }}</dt><dd>{{ s.route.operator }}</dd></div>
              <div v-if="s.route.network && !s.route.custom"><dt>{{ t("route.network") }}</dt><dd>{{ s.route.network }}</dd></div>
              <div><dt>{{ t("route.length") }}</dt><dd>{{ lengthText }}</dd></div>
              <div><dt>{{ t("route.time") }}</dt><dd>{{ t("route.min", { n: s.route.minutes }) }}</dd></div>
              <div><dt>{{ t("route.stops") }}</dt><dd>{{ s.route.stopCount }}</dd></div>
              <div v-if="s.route.first"><dt>{{ t("route.first") }}</dt><dd>{{ s.route.first }}</dd></div>
              <div v-if="s.route.last"><dt>{{ t("route.last") }}</dt><dd>{{ s.route.last }}</dd></div>
            </dl>
            <div class="freq">
              <div class="freq-title">{{ t("route.interval") }} <span class="muted">· {{ t("day." + s.day) }}</span></div>
              <div class="bars">
                <div v-for="p in s.route.periods" :key="p.from" class="bar" :class="{ peak: p.peak, off: !p.minutes }" :title="p.minutes ? t('route.every', { n: p.minutes }) : t('route.none')">
                  <i :style="{ height: barHeight(p) + '%' }"></i>
                  <b>{{ p.minutes ? trim(p.minutes) : "–" }}</b>
                  <span>{{ p.from }}–{{ p.to }}</span>
                </div>
              </div>
            </div>
            <ShiftStart :s="s" />
            <p v-if="s.route.incomplete" class="warn">{{ t("route.incomplete") }}</p>
            <p v-if="s.route.straight" class="warn">{{ t("build.straight") }}</p>
            <div v-if="s.route.custom" class="own-actions">
              <button class="btn ghost" @click="call('uiSave')">{{ saveLabel }}</button>
              <button v-if="s.build" class="btn ghost" @click="call('uiBuildBack')">{{ t("route.editBuild") }}</button>
            </div>
            <button v-else class="btn ghost extend" @click="call('uiBuildFromRoute')">＋ {{ t("route.extend") }}<small>{{ t("route.extendHint") }}</small></button>
          </div>

          <div class="card diagram">
            <h3>{{ t("route.stopsTitle") }}</h3>
            <ol class="strip">
              <li v-for="st in s.route.stops" :key="st.i" :class="{ here: isHere(st.i), passed: isPassed(st.i) }">
                <span class="dot"></span>
                <span class="nm">{{ st.name }}</span>
                <span class="km">{{ units === 'mph' ? (st.km * 0.6214).toFixed(1) : st.km.toFixed(1) }}</span>
                <span v-if="isHere(st.i)" class="you">{{ t("route.youHere") }}</span>
              </li>
            </ol>
          </div>

          <div class="card start" v-if="s.start">
            <h3>{{ t("start.title") }}</h3>
            <div class="seg" role="group">
              <button v-if="s.start.place !== 'to'" :class="{ on: s.start.mode === 'here' }" @click="call('uiSetStartMode', 'here')">
                {{ t("start.here") }}<small>{{ stopAt(s.start.index) }}</small>
              </button>
              <button :class="{ on: s.start.mode === 'first' }" @click="call('uiSetStartMode', 'first')">
                {{ t("start.first") }}<small>{{ s.route.stops[0].name }}</small>
              </button>
            </div>

            <div class="time">
              <div class="label">{{ t("start.time") }}</div>
              <div class="led-time">
                <div class="unit">
                  <button class="step" aria-label="+1 h" @click="bump(3600)">▲</button>
                  <span class="digits">{{ hh }}</span>
                  <button class="step" aria-label="-1 h" @click="bump(-3600)">▼</button>
                </div>
                <span class="colon">:</span>
                <div class="unit">
                  <button class="step" aria-label="+5 min" @click="bump(300)">▲</button>
                  <span class="digits">{{ mm }}</span>
                  <button class="step" aria-label="-5 min" @click="bump(-300)">▼</button>
                </div>
                <button class="btn ghost now" @click="call('uiSetTime', s.nowSec)">{{ t("start.now") }}</button>
              </div>
            </div>

            <div class="deps">
              <div class="label">{{ t("start.next") }}</div>
              <div v-if="!s.start.deps.length" class="muted">{{ t("start.none") }}</div>
              <div class="chips">
                <button v-for="(d, i) in s.start.deps" :key="d.trip" class="dep" :class="{ on: s.start.dep === i + 1 }" @click="call('uiSelectDep', i + 1)">
                  {{ d.label }}<small v-if="d.tomorrow">{{ t("start.tomorrow") }}</small>
                </button>
              </div>
            </div>

            <button v-if="s.start.reverseId" class="btn ghost reverse" @click="call('uiToggleReverse')">
              ⇄ {{ t("start.reverse") }}<small>{{ t("start.reverseHint", { to: s.route.from }) }}<template v-if="s.start.reverseGuess"> · {{ t("start.reverseGuess") }}</template></small>
            </button>

            <p v-if="s.start.place === 'to'" class="muted small">{{ t("start.endsHere") }}</p>
            <div class="start-actions">
            <button class="btn go" :disabled="s.starting" @click="call('uiStart')">
              {{ s.starting ? t("start.teleporting") : (s.start.canDrive ? t("start.teleportGo") : t("start.go")) }}
              <small v-if="s.start.canDrive && !s.starting">{{ stopAt(s.start.index) }} · {{ dist(s.start.dist) }}</small>
            </button>
            <button v-if="s.start.canDrive && !s.starting" class="btn drive" :disabled="!!s.armed" @click="call('uiDriveToStart')">
              ➜ {{ t("start.drive") }}<small>{{ t("start.driveHint", { stop: stopAt(s.start.index) }) }}</small>
            </button>
            </div>
            <p v-if="s.error" class="warn">{{ s.error }}</p>
            <p class="muted small">{{ t("start.goHint") }}</p>
          </div>
        </section>

        <!-- the dispatcher between the trips, the summary of a shift -->
        <ShiftPage v-else-if="(screen === 'shiftLayover' || screen === 'shiftResult') && s.shift" :s="s" />

        <!-- 4. the end of the trip -->
        <section v-else-if="screen === 'result' && s.result" class="result card">
          <div class="res-head">
            <span class="plate big" :style="{ background: s.result.colour, color: ink(s.result.colour) }">{{ s.result.ref }}</span>
            <div>
              <h2>{{ t("res.title") }}</h2>
              <div class="muted">{{ s.result.from }} → {{ s.result.to }}</div>
            </div>
          </div>
          <div class="res-main">
            <div class="grade-ring">
              <svg viewBox="0 0 120 120" aria-hidden="true">
                <circle cx="60" cy="60" r="52" class="bg" />
                <circle cx="60" cy="60" r="52" class="fg" :stroke-dasharray="ring(s.result.points)" />
              </svg>
              <div class="g">{{ s.result.grade }}</div>
            </div>
            <div class="points"><b>{{ s.result.points }}</b><span>{{ t("res.points") }}</span>
              <div class="stars" :aria-label="s.result.stars + ' / 5'"><i v-for="n in 5" :key="n" :class="{ on: n <= s.result.stars }">★</i></div>
              <div v-if="s.result.record" class="record">{{ t("res.record") }}</div>
              <div v-else-if="s.result.previous" class="muted small">{{ t("res.best", { n: s.result.previous }) }}</div>
              <div v-if="s.result.ghostNew" class="muted small">{{ t("res.ghostNew") }}</div>
            </div>
            <div class="parts">
              <div v-for="k in PARTS" :key="k" class="part">
                <span>{{ t("res." + k) }}</span>
                <div class="meter"><i :style="{ width: Math.round(s.result.parts[k] * 100) + '%' }"></i></div>
                <b>{{ Math.round(s.result.parts[k] * 100) }}</b>
              </div>
              <p v-if="!s.result.scheduled" class="muted small">{{ t("res.noSchedule") }}</p>
            </div>
          </div>
          <dl class="facts row-facts">
            <div><dt>{{ t("res.passengers") }}</dt><dd>{{ s.result.passengers }}</dd></div>
            <div><dt>{{ t("res.stops") }}</dt><dd>{{ s.result.served }} / {{ s.result.planned }}</dd></div>
            <div><dt>{{ t("res.time") }}</dt><dd>{{ t("route.min", { n: s.result.minutes }) }}</dd></div>
            <div><dt>{{ t("res.income") }}</dt><dd>{{ s.result.revenue.toFixed(2) }}</dd></div>
            <div v-if="s.result.tickets > 0"><dt>{{ t("res.tickets") }}</dt><dd>{{ s.result.tickets }}</dd></div>
            <div v-if="s.result.counts && s.result.counts.connections > 0"><dt>{{ t("res.connections") }}</dt><dd>{{ s.result.counts.connections }}</dd></div>
          </dl>
          <ul v-if="s.result.notes && s.result.notes.length" class="notes">
            <li v-for="(n, i) in s.result.notes" :key="i"><span>{{ noteText(n.text) }}</span><b>{{ n.points }}</b></li>
          </ul>
          <div class="muted small">{{ t("res.totals", { trips: s.result.totals.trips, pax: s.result.totals.passengers }) }}</div>
          <div v-if="s.result.career" class="career-note">
            <span v-if="s.result.career.earned" class="earned">{{ t("res.credits", { n: s.result.career.earned }) }}</span>
            <span v-if="s.result.career.rankUp" class="earned">{{ t("res.rankUp", { rank: t("rank." + s.result.career.rankUp) }) }}</span>
            <span v-for="id in s.result.career.unlocked" :key="id" class="ach-new" :title="t('ach.' + id + '.d')">★ {{ t("res.unlocked") }}: {{ t("ach." + id) }}</span>
          </div>
          <div class="row">
            <button v-if="s.result.canReverse" class="btn go" @click="call('uiReverseTrip')">⇄ {{ t("res.back") }}</button>
            <button v-if="s.result.canContinue" class="btn" @click="call('uiBuildContinue')">＋ {{ t("res.next") }}</button>
            <button class="btn" @click="call('uiAnotherRoute')">{{ t("res.another") }}</button>
            <button class="btn ghost" @click="finish">{{ t("res.close") }}</button>
          </div>
        </section>
      </main>

      <footer class="foot">
        <span class="muted">{{ t("credit") }}</span>
        <span v-if="s && s.fleet" class="muted" :title="JSON.stringify(s.fleet)">{{ t("fleet.diag", s.fleet) }}</span>
        <span class="svc" :class="{ ok: s && s.service && s.service.up, bad: s && s.service && s.service.up === false }">
          <i></i>{{ svcText }}
        </span>
      </footer>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import ProgressBar from "./ProgressBar.vue"
import MiniMap from "./MiniMap.vue"
import BuildPage from "./BuildPage.vue"
import StopsPage from "./StopsPage.vue"
import NextTripCard from "./NextTripCard.vue"
import ShiftStart from "./ShiftStart.vue"
import ShiftPage from "./ShiftPage.vue"
import ProfileTab from "./ProfileTab.vue"
import DepartureBoard from "./DepartureBoard.vue"
import { useEvents } from "@/services/events"
import { state, call, onState, distance, plateInk, pad, typing } from "./store.js"
import { lang, setLang, t, noteText } from "./i18n.js"

const events = useEvents()
events.on("EarthBusRoutesState", onState)

const PARTS = ["punctuality", "service", "comfort", "safety"]
const rootEl = ref(null)
const s = state
onBeforeUnmount(() => typing(false))
onMounted(() => {
  if (rootEl.value) rootEl.value.focus()
  call("uiState")
})

const screen = computed(() => (s.value ? s.value.screen : "nearby"))
const TABS = ["from", "to", "through"]
const curTab = computed(() => (s.value && s.value.tab) || "from")
const tabCount = k => (s.value && s.value.tabCounts && s.value.tabCounts[k]) || 0
// a circular line is in "from" and in "to"
const inTab = (v, k) => (k === "from" ? v.place === "from" || v.place === "loop" : k === "to" ? v.place === "to" || v.place === "loop" : v.place === "through")
const tabLines = computed(() => {
  const k = curTab.value
  return ((s.value && s.value.lines) || [])
    .map(ln => ({ ...ln, variants: ln.variants.filter(v => inTab(v, k)) }))
    .filter(ln => ln.variants.length)
})
function variantText(v) {
  if (v.ambiguous) return v.label
  if (curTab.value === "to" && v.from) return t("lines.variantFrom", { from: v.from })
  if (curTab.value === "through" && v.from && v.to) return t("lines.variantThrough", { from: v.from, to: v.to })
  return v.to ? t("lines.variant", { to: v.to }) : v.label
}
const fq = ref("")
let findTimer = null
const clean = v => String(v).replace(/[\\"\u0000-\u001f]/g, " ").trim()
// as you type: only what the data service already knows (instant); Enter or the button asks the public servers too
function typedFind() {
  clearTimeout(findTimer)
  const v = clean(fq.value)
  if (v.length < 1) { if (s.value && s.value.find) call("uiFindClear"); return }
  findTimer = setTimeout(() => call("uiFind", v, true), 250)
}
function runFind() { clearTimeout(findTimer); const v = clean(fq.value); if (v) call("uiFind", v) }
function clearFind() { clearTimeout(findTimer); fq.value = ""; call("uiFindClear") }
function findErr(e) {
  const key = "build.err." + e
  const v = t(key)
  return v === key ? t("err.generic", { e }) : v
}
const tab = ref("near")
watch(() => s.value && s.value.tab, v => { if (v) tab.value = v }, { immediate: true })
const sure = ref(null)
const saved = computed(() => (s.value && s.value.saved) || [])
const saveLabel = computed(() => {
  const own = s.value && s.value.route && s.value.route.custom
  return own && s.value.start && s.value.start.saved ? "✓ " + t("build.saved") : t("build.save")
})
let sureTimer = null
function remove(m) {
  if (sure.value === m.id) { sure.value = null; call("uiDeleteSaved", m.i); return }
  sure.value = m.id
  clearTimeout(sureTimer)
  sureTimer = setTimeout(() => { sure.value = null }, 3000)
}
function openMap() { tab.value = "map"; call("uiMapOpen"); call("uiProfileOpen") }
function openProfile() { tab.value = "profile"; call("uiProfileOpen") }
// the career's layer of the map: the lines driven, the towns and stations stopped at (only once the profile is in the model)
const showDriven = ref(true)
// the buses of the lines (plan 007): the chosen one gets a chip on the map
const pickedBus = ref(null)
const busCount = computed(() => (s.value && s.value.buses ? s.value.buses.length : 0))
function pickBus(key) { pickedBus.value = key == null || pickedBus.value === key ? null : key }
const driven = computed(() => (s.value && s.value.profile && s.value.profile.layer && s.value.profile.layer.lines.length ? s.value.profile.layer : null))
function townList() { const f = s.value && s.value.map && s.value.map.focus; if (f) { tab.value = "near"; call("uiMapPlace", f.id) } }
function mapLines() { tab.value = "near"; call("uiMapGo", "lines") }
function placeKind(pl) {
  const k = "find.kind." + pl.kind
  const v = t(k)
  return v === k ? "" : v
}
function errText(e) {
  const key = "build.err." + e
  const v = t(key)
  return v === key ? t("err.generic", { e }) : v
}
const units = computed(() => (s.value ? s.value.units : "km/h"))
const stations = computed(() => (s.value && s.value.stations) || [])
const serviceDown = computed(() => !!(s.value && (s.value.error === "service_down" || (s.value.service && s.value.service.up === false && !stations.value.length))))
const busyTrip = computed(() => !!(s.value && s.value.tripActive))
const svcText = computed(() => {
  const v = s.value && s.value.service
  if (!v) return ""
  if (v.up) return t("svc.ok", { v: v.version || "" })
  return v.up === false ? t("svc.off") : ""
})

const whereText = computed(() => {
  const p = s.value && s.value.place
  if (!p) return ""
  return [p.street, p.place, p.country].filter(Boolean).join(", ")
})
const lineColour = computed(() => (s.value && s.value.route && s.value.route.colour) || (s.value && s.value.result && s.value.result.colour) || "#4aa3df")
const lineInk = computed(() => plateInk(lineColour.value))
const ink = plateInk
const dist = m => distance(m, units.value, t)
const hudRef = computed(() => (s.value && s.value.route ? s.value.route.ref : ""))
const hudTo = computed(() => (s.value && s.value.route ? s.value.route.to : ""))

const kindText = computed(() => (s.value && s.value.route ? t("route.kind." + s.value.route.kind) : ""))
const lengthText = computed(() => {
  const km = s.value.route.km
  return units.value === "mph" ? t("route.mi", { n: (km * 0.6214).toFixed(1) }) : t("route.km", { n: km.toFixed(1) })
})
const stopAt = i => (s.value && s.value.route && s.value.route.stops[i - 1] ? s.value.route.stops[i - 1].name : "")
const isHere = i => !!(s.value && s.value.start && s.value.start.mode === "here" && i === s.value.start.index)
const isPassed = i => !!(s.value && s.value.start && s.value.start.mode === "here" && i < s.value.start.index)

// the trip clock picker
const hh = computed(() => pad(Math.floor((s.value.start.timeSec % 86400) / 3600)))
const mm = computed(() => pad(Math.floor((s.value.start.timeSec % 3600) / 60)))
function bump(delta) { call("uiSetTime", Math.round((s.value.start.timeSec + delta + 86400) % 86400)) }

// frequency bars: buses an hour, 8 or more (a bus every 7.5 minutes) fills the bar
const barHeight = p => (p.minutes ? Math.min(100, Math.max(12, (60 / p.minutes) * (100 / 8))) : 0)
const trim = n => (Number.isInteger(n) ? String(n) : n.toFixed(1))
const ring = pts => { const c = 2 * Math.PI * 52; return `${(c * Math.max(0, Math.min(1, pts / 1000))).toFixed(1)} ${c.toFixed(1)}` }

function go(where) { call("uiBackTo", where) }
function close() { call("uiClose") }
function finish() { call("uiDismissResult"); close() }
</script>

<style scoped lang="scss">
// One panel colour family; the line's own colour (--line) is the accent; amber only on the LED time, as on the HUD.
.ebm {
  --panel: #1a2830;
  --panel-2: #22343e;
  --panel-3: #2b414d;
  --ink: #eef3f4;
  --muted: #93a9b4;
  --hair: rgba(255, 255, 255, 0.1);
  --led: #ffc233;
  --ok: #52d394;
  --late: #ff875a;
  position: fixed;
  inset: 0;
  display: grid;
  place-items: center;
  padding: 24px;
  box-sizing: border-box;
  color: var(--ink);
  font-family: "Overpass", "Segoe UI", system-ui, sans-serif;
  font-variant-numeric: tabular-nums;
  background: rgba(8, 15, 19, 0.82);
  backdrop-filter: blur(6px);
  outline: none;
}
.shell {
  width: min(1240px, 100%);
  height: min(780px, 100%);
  display: flex;
  flex-direction: column;
  background: var(--panel);
  border-radius: 14px;
  border-left: 8px solid var(--line);
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.55);
  overflow: hidden;
}
h1, h2, h3, p { margin: 0; }
h1 { font-size: 24px; font-weight: 800; letter-spacing: -0.2px; }
h2 { font-size: 22px; font-weight: 700; }
h3 { font-size: 16px; font-weight: 700; margin-bottom: 8px; }
.muted { color: var(--muted); }
.small { font-size: 13px; }
.sub { color: var(--muted); margin-top: 2px; }

// ---- top bar
.top {
  display: flex;
  align-items: center;
  gap: 24px;
  padding: 14px 20px;
  border-bottom: 1px solid var(--hair);
}
.titles { flex: none; }
.where { color: var(--muted); font-size: 14px; margin-top: 1px; }
.crumbs { flex: 1; min-width: 0; display: flex; align-items: center; gap: 8px; overflow: hidden; }
.crumb {
  max-width: 280px;
  padding: 6px 12px;
  border: 0;
  border-radius: 99px;
  background: transparent;
  color: var(--muted);
  font: inherit;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
  cursor: pointer;
  &.on { background: var(--panel-2); color: var(--ink); font-weight: 700; cursor: default; }
  &:hover:not(.on):not(:disabled) { color: var(--ink); }
  &:disabled { opacity: 0.5; cursor: default; }
}
.sep { flex: none; width: 14px; height: 2px; background: var(--hair); }
.mini-plate { display: inline-block; margin-right: 8px; padding: 0 7px; border-radius: 4px; background: var(--line); color: var(--ink-on-line); font-weight: 800; }
.tools { flex: none; display: flex; align-items: center; gap: 12px; }
.lang { display: flex; border: 1px solid var(--hair); border-radius: 8px; overflow: hidden;
  button { border: 0; padding: 6px 10px; background: transparent; color: var(--muted); font: inherit; font-weight: 700; cursor: pointer; &.on { background: var(--panel-3); color: var(--ink); } } }

// ---- body
.body { flex: 1; min-height: 0; padding: 18px 20px 6px; overflow: hidden; display: flex; }
.body > section { flex: 1; min-width: 0; min-height: 0; }
.card { background: var(--panel-2); border-radius: 12px; padding: 16px; }
.card.center { margin: auto; text-align: center; max-width: 480px; display: flex; flex-direction: column; gap: 12px; flex: none; }
.row { display: flex; gap: 10px; flex-wrap: wrap; justify-content: center; margin-top: 6px; }

.split { display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 20px; }
.list { display: flex; flex-direction: column; gap: 12px; min-height: 0; &.wide { max-width: 900px; margin: 0 auto; width: 100%; } }
.head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.stops, .lines { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; padding-right: 6px; }
.aside { display: flex; flex-direction: column; gap: 12px; }
.coords { font-size: 15px; font-weight: 600; margin-bottom: 2px; }

.stop-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  width: 100%;
  padding: 14px 16px;
  border: 0;
  border-radius: 12px;
  background: var(--panel-2);
  color: var(--ink);
  font: inherit;
  text-align: left;
  cursor: pointer;
  &:hover { background: var(--panel-3); }
  &:focus-visible { outline: 2px solid var(--line); }
  &.nearest { box-shadow: inset 4px 0 0 var(--line); }
}
.stop-name { font-size: 20px; font-weight: 700; line-height: 1.2; }
.stop-meta { display: flex; gap: 10px; align-items: center; margin-top: 3px; color: var(--muted); .dist { color: var(--ink); font-weight: 700; } }
.tag { padding: 0 8px; border-radius: 4px; background: var(--panel-3); color: var(--ink); font-size: 13px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; max-width: 46%; align-items: center; }
.plate {
  display: inline-grid;
  place-items: center;
  min-width: 34px;
  padding: 2px 8px;
  border-radius: 6px;
  font-weight: 800;
  font-size: 16px;
  &.big { min-width: 64px; padding: 6px 12px; font-size: 28px; border-radius: 8px; }
  &.huge { min-width: 84px; padding: 8px 14px; font-size: 38px; border-radius: 10px; }
}

.loading { display: flex; align-items: center; gap: 14px; padding: 22px 4px; }
.spin { flex: none; width: 26px; height: 26px; border: 3px solid var(--hair); border-top-color: var(--line); border-radius: 50%; animation: spin 0.9s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.empty { padding: 28px 4px; line-height: 1.5; }
.notice { padding: 16px; border-radius: 12px; background: var(--panel-2); display: flex; flex-direction: column; gap: 10px; align-items: flex-start; line-height: 1.45;
  &.bad { box-shadow: inset 4px 0 0 var(--late); }
  .steps { color: var(--led); } }

// ---- station tabs, armed bar
.find { display: flex; gap: 8px;
  input { flex: 1; min-width: 0; padding: 10px 14px; border: 0; border-radius: 10px; background: #0f1a20; color: var(--ink); font: inherit; font-size: 16px; box-shadow: inset 0 0 0 1px var(--hair);
    &::placeholder { color: var(--muted); } &:focus { outline: 2px solid var(--line); } } }
.driven-toggle { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; cursor: pointer; font-size: 14px; }
.career-note { display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 14px; .earned { font-weight: 700; color: var(--led); } .ach-new { font-weight: 700; } }
.bus-note { display: flex; align-items: center; gap: 8px; margin: 0; }
.bus-dot { width: 9px; height: 9px; border-radius: 50%; background: var(--led); box-shadow: 0 0 0 2px #0b1519; flex: none; }
.station-board { margin: 4px 0 10px; }
.map-big { flex: 1; min-height: 0; border-radius: 12px; overflow: hidden; }
.map-head { display: flex; align-items: center; gap: 12px; .map-town { flex: 1; font-size: 18px; } .btn { padding: 6px 12px; } }
.map-sel { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 12px; background: var(--panel-2);
  .map-sel-body { flex: 1; min-width: 220px; } .stop-name { font-size: 18px; } .stop-meta { flex-wrap: wrap; }
  .map-sel-actions { display: flex; flex-wrap: wrap; gap: 8px; } .btn.go { font-size: 15px; padding: 10px 16px; }
  .act-err { margin: 6px 0 0; color: var(--late); } }
.places { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.place-chip { display: inline-flex; flex-direction: column; align-items: flex-start; padding: 6px 14px; border: 0; border-radius: 99px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 800; font-size: 16px; line-height: 1.15; cursor: pointer;
  small { font-weight: 400; font-size: 11px; color: var(--muted); }
  &:hover:not(:disabled) { background: var(--line); color: var(--ink-on-line); small { color: inherit; } }
  &:disabled { opacity: 0.5; cursor: default; } &:focus-visible { outline: 2px solid var(--line); } }
.find-head { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
.found { min-height: 0; }
.stop-card:disabled { opacity: 0.6; cursor: default; }
.station-tabs { align-self: flex-start; button { font-size: 16px; padding: 7px 14px; } }
.badge.zero { background: var(--panel-3); color: var(--muted); }
.tab-hint { margin: -2px 0 2px; }
.approx { margin-left: 6px; font-style: normal; color: var(--muted); font-weight: 400; }
.armed-bar { display: flex; align-items: center; gap: 12px; padding: 8px 20px; background: var(--panel-3); border-bottom: 1px solid var(--hair); }
.armed-text { flex: 1; min-width: 0; font-weight: 700; }
.btn small { display: block; font-weight: 400; font-size: 12px; opacity: 0.85; margin-top: 1px; }
.start-actions { position: sticky; bottom: -16px; display: flex; flex-direction: column; gap: 8px; padding: 10px 0 16px; margin-bottom: -16px; background: var(--panel-2); }
.btn.drive { display: flex; flex-direction: column; align-items: flex-start; text-align: left; background: transparent; box-shadow: inset 0 0 0 2px var(--line); }

// ---- tabs, my routes
.tabs { display: flex; gap: 4px; padding: 4px; border-radius: 12px; background: var(--panel-2);
  button { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border: 0; border-radius: 9px; background: transparent; color: var(--muted); font: inherit; font-size: 18px; font-weight: 700; cursor: pointer;
    &.on { background: var(--panel-3); color: var(--ink); } &:hover:not(.on) { color: var(--ink); } &:focus-visible { outline: 2px solid var(--line); } } }
.badge { padding: 0 8px; border-radius: 99px; background: var(--line); color: var(--ink-on-line); font-size: 13px; }
.head-actions { display: flex; gap: 8px; align-items: center; }
.btn.slim { padding: 9px 16px; font-size: 15px; }
.mine-row { display: flex; align-items: center; gap: 16px; padding: 12px 16px; border-radius: 12px; background: var(--panel-2); }
.mine-body { flex: 1; min-width: 0; .stop-name { font-size: 18px; } }
.mine-actions { display: flex; gap: 8px; flex: none; }
.own-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
.extend { margin-top: 14px; display: flex; flex-direction: column; align-items: flex-start; gap: 2px; text-align: left; small { font-weight: 400; color: var(--muted); } }
.own { display: inline-block; white-space: nowrap; margin-right: 8px; padding: 1px 8px; border-radius: 4px; background: var(--panel-3); color: var(--ink); font-weight: 700; font-size: 12px; }
.own.real { background: var(--line); color: var(--ink-on-line); }

// ---- lines
.line-row { display: flex; gap: 16px; align-items: flex-start; padding: 14px 16px; border-radius: 12px; background: var(--panel-2); }
.line-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }
.variants { display: flex; flex-wrap: wrap; gap: 8px; }
.variant { padding: 8px 14px; border: 0; border-radius: 8px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 700; cursor: pointer;
  &:hover:not(:disabled) { background: #36525f; } &:disabled { opacity: 0.5; cursor: default; } &:focus-visible { outline: 2px solid var(--line); } }

// ---- route
.route { display: grid; grid-template-columns: 330px minmax(0, 1fr) 340px; gap: 16px; }
.route > .card { min-height: 0; overflow-y: auto; }
.line-head { display: flex; gap: 14px; align-items: center; margin-bottom: 12px; }
.from-to { font-size: 18px; font-weight: 700; line-height: 1.25; .arrow { color: var(--muted); font-weight: 400; } }
.facts { margin: 0; display: grid; gap: 7px; div { display: flex; justify-content: space-between; gap: 12px; } dt { color: var(--muted); } dd { margin: 0; font-weight: 600; text-align: right; } }
.freq { margin-top: 16px; }
.freq-title { font-weight: 700; margin-bottom: 8px; }
.bars { display: grid; grid-template-columns: repeat(7, 1fr); gap: 6px; height: 92px; }
.bar { position: relative; display: flex; flex-direction: column; justify-content: flex-end; align-items: center; text-align: center;
  i { display: block; width: 100%; background: var(--panel-3); border-radius: 3px 3px 0 0; }
  b { font-size: 12px; margin-top: 3px; }
  span { font-size: 10px; color: var(--muted); }
  &.peak i { background: var(--line); }
  &.off b { color: var(--muted); font-weight: 400; } }
.warn { margin-top: 12px; color: var(--late); font-size: 13px; line-height: 1.4; }

.diagram { display: flex; flex-direction: column; }
.strip { list-style: none; margin: 0; padding: 0 6px 0 0; flex: 1; min-height: 0; overflow-y: auto; }
.strip li { position: relative; display: flex; align-items: baseline; gap: 10px; padding: 0 0 9px 26px; font-size: 15px;
  &::before { content: ""; position: absolute; left: 7px; top: 14px; bottom: -5px; width: 4px; border-radius: 2px; background: var(--line); opacity: 0.9; }
  &:last-child::before { display: none; }
  .dot { position: absolute; left: 3px; top: 5px; width: 12px; height: 12px; box-sizing: border-box; border-radius: 50%; border: 3px solid var(--line); background: var(--panel-2); z-index: 1; }
  .nm { flex: 1; min-width: 0; }
  .km { color: var(--muted); font-size: 13px; }
  .you { padding: 0 8px; border-radius: 99px; background: var(--line); color: var(--ink-on-line); font-size: 12px; font-weight: 700; }
  &.here .nm { font-weight: 700; font-size: 17px; }
  &.here .dot { background: var(--line); width: 16px; height: 16px; left: 1px; top: 3px; }
  &.passed { opacity: 0.45; } }

.start { display: flex; flex-direction: column; gap: 14px; overflow-y: auto; }
.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 6px;
  button { display: flex; flex-direction: column; gap: 2px; min-width: 0; overflow: hidden; padding: 9px 10px; border: 0; border-radius: 8px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 700; text-align: left; cursor: pointer;
    small { font-weight: 400; color: var(--muted); white-space: nowrap; text-overflow: ellipsis; overflow: hidden; }
    &.on { background: var(--line); color: var(--ink-on-line); small { color: inherit; opacity: 0.8; } }
    &:focus-visible { outline: 2px solid var(--ink); } } }
.label { color: var(--muted); font-size: 13px; margin-bottom: 6px; }
.led-time { display: flex; align-items: center; gap: 8px; }
.led-time .unit { display: flex; flex-direction: column; align-items: center; }
.led-time .digits {
  position: relative; min-width: 72px; padding: 2px 10px; text-align: center; background: #07090a; border-radius: 6px; color: var(--led);
  font-size: 40px; font-weight: 800; line-height: 54px; text-shadow: 0 0 8px rgba(255, 170, 0, 0.55); overflow: hidden;
  &::after { content: ""; position: absolute; inset: 0; pointer-events: none;
    background: linear-gradient(rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 100% 3px, linear-gradient(90deg, rgba(0, 0, 0, 0.42) 1px, transparent 1px) 0 0 / 3px 100%; } }
.led-time .colon { font-size: 36px; font-weight: 800; color: var(--led); margin-bottom: 4px; }
.step { width: 72px; height: 22px; border: 0; border-radius: 5px; background: transparent; color: var(--muted); font-size: 12px; cursor: pointer; &:hover { background: var(--panel-3); color: var(--ink); } &:focus-visible { outline: 2px solid var(--line); } }
.now { margin-left: auto; padding: 8px 12px; }
.deps .chips { justify-content: flex-start; max-width: none; gap: 6px; }
.dep { padding: 8px 12px; border: 0; border-radius: 8px; background: var(--panel-3); color: var(--ink); font: inherit; font-weight: 700; cursor: pointer; display: flex; flex-direction: column; align-items: center; line-height: 1.1;
  small { font-weight: 400; font-size: 10px; color: var(--muted); }
  &.on { background: var(--line); color: var(--ink-on-line); small { color: inherit; } } &:focus-visible { outline: 2px solid var(--ink); } }
.reverse { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; text-align: left; small { font-weight: 400; color: var(--muted); } }

// ---- result
.result { max-width: 920px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; overflow-y: auto; }
.res-head { display: flex; gap: 16px; align-items: center; }
.res-main { display: grid; grid-template-columns: 150px 250px minmax(0, 1fr); gap: 24px; align-items: center; }
.grade-ring { position: relative; width: 140px; height: 140px;
  svg { width: 100%; height: 100%; transform: rotate(-90deg); }
  .bg { fill: none; stroke: var(--hair); stroke-width: 9; }
  .fg { fill: none; stroke: var(--line); stroke-width: 9; stroke-linecap: round; transition: stroke-dasharray 0.8s ease-out; }
  .g { position: absolute; inset: 0; display: grid; place-items: center; font-size: 64px; font-weight: 800; } }
.points { display: flex; flex-direction: column; gap: 4px; b { font-size: 54px; line-height: 1; font-weight: 800; } span { color: var(--muted); }
  .stars i { font-style: normal; color: var(--hair); font-size: 22px; &.on { color: var(--led); } }
  .record { margin-top: 4px; padding: 3px 10px; white-space: nowrap; font-size: 13px; border-radius: 99px; background: rgba(82, 211, 148, 0.16); color: var(--ok); font-weight: 700; align-self: flex-start; } }
.parts { display: flex; flex-direction: column; gap: 9px; }
.part { display: grid; grid-template-columns: 130px minmax(0, 1fr) 36px; align-items: center; gap: 10px; b { text-align: right; }
  .meter { height: 8px; border-radius: 4px; background: var(--hair); overflow: hidden; i { display: block; height: 100%; background: var(--line); border-radius: 4px; } } }
.row-facts { grid-template-columns: repeat(4, 1fr); display: grid; gap: 12px; div { flex-direction: column; gap: 2px; padding: 10px 12px; border-radius: 8px; background: var(--panel-3); } dd { text-align: left; font-size: 20px; } }
.notes { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 4px; li { display: flex; justify-content: space-between; padding: 6px 10px; border-radius: 6px; background: rgba(255, 135, 90, 0.12); color: #ffb199; } }

.foot { display: flex; justify-content: space-between; align-items: center; padding: 8px 20px 12px; font-size: 13px; }
.svc { display: flex; align-items: center; gap: 6px; color: var(--muted); i { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
  &.ok i { background: var(--ok); } &.bad { color: var(--late); i { background: var(--late); } } }

@media (max-width: 1100px) {
  .route { grid-template-columns: 1fr 1fr; .start { grid-column: 1 / -1; } }
  .split { grid-template-columns: 1fr; .aside { display: none; } }
}
@media (prefers-reduced-motion: reduce) { .spin { animation-duration: 3s; } .grade-ring .fg { transition: none; } }
</style>

<style lang="scss">
// shared by the pages inside the menu (BuildPage, StopsPage): not scoped
.ebm .btn {
  padding: 10px 18px;
  border: 0;
  border-radius: 8px;
  background: var(--panel-3);
  color: var(--ink);
  font: inherit;
  font-weight: 700;
  cursor: pointer;
  &:hover:not(:disabled) { background: #36525f; }
  &:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
  &:disabled { opacity: 0.5; cursor: default; }
  &.ghost { background: transparent; box-shadow: inset 0 0 0 1px var(--hair); &:hover:not(:disabled) { background: var(--panel-2); } }
  &.danger { background: #5a2a26; &:hover:not(:disabled) { background: #74352f; } }
  &.go { background: var(--line); color: var(--ink-on-line); font-size: 17px; padding: 14px 18px; &:hover:not(:disabled) { filter: brightness(1.1); background: var(--line); } }
}
.ebm h3 { margin: 0 0 8px; font-size: 16px; font-weight: 700; }
.ebm .card { background: var(--panel-2); border-radius: 12px; padding: 16px; }
.ebm .muted { color: var(--muted); }
.ebm .small { font-size: 13px; }
</style>
