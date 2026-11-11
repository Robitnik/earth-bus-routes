-- shift.lua: a chain of trips with layovers (pure), the summary, and the shift flow in main.lua with the game and the service stubbed.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local shift = require('earthBusRoutes/shift')
local T = {}

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

-- a generated plan: the line out and the same road back
local function generated(opts)
  opts = opts or {}
  local r = route()
  local back = osm.reversed(r)
  local ctx = {}
  local out, back_ = sched.generate(r, 2, ctx), sched.generate(back, 2, ctx)
  local start = opts.start or 8 * 3600
  local d = sched.departures(out, 1, start, 1)[1]
  return shift.new({ source = 'generated', startClock = d.trip.start, duration = opts.duration or 120,
    legs = { { route = r, trips = out }, { route = back, trips = back_ } } }), r, back, out, back_
end

local function chain(items)
  local list = {}
  for i, it in ipairs(items) do
    list[i] = { id = 1e12 + i, pid = i, start = it[1], ref = it[2] or '361', from = it[3] or 'A', to = it[4] or 'B', head = it[4] or 'B' }
  end
  return list
end

local function gtfsShift(items, duration)
  return shift.new({ source = 'gtfs', startClock = items[1][1], duration = duration or 120, chain = chain(items) })
end

local function rec(points, late)
  return { ref = '361', from = 'A', to = 'B', points = points or 800, grade = 'A', passengers = 20, revenue = 30, punctuality = 0.9,
    served = 9, planned = 10, missed = 1, minutes = 40, late = late or 0, notes = 0 }
end

function T.duration_is_one_of_the_three_choices()
  assert(shift.clampDuration(60) == 60 and shift.clampDuration(120) == 120 and shift.clampDuration(240) == 240)
  assert(shift.clampDuration(100) == 120 and shift.clampDuration(500) == 240 and shift.clampDuration(nil) == 120)
  assert(shift.clampDuration('abc') == 120)
end

function T.the_gtfs_chain_is_followed_in_order_with_its_layovers()
  local s = gtfsShift({ { 25200, '361', 'A', 'B' }, { 27600, '361', 'B', 'A' }, { 30000, '361', 'A', 'B' } }, 240)
  -- the first trip ended at 07:25
  local n = shift.arrive(s, rec(), 25200 + 1500)
  assert(n and n.kind == 'gtfs' and n.from == 'B' and n.to == 'A' and n.planned == 27600)
  assert(n.start == 27600 and n.late == 0 and n.layover == 27600 - 26700, 'the layover is the planned wait')
  assert(n.routeId == 1e12 + 2)
  local d = shift.depart(s, 27500)
  assert(d == n and s.cursor == 3 and s.begun == 2 and s.pending == nil)
  n = shift.arrive(s, rec(), 27600 + 1500)
  assert(n and n.planned == 30000)
  assert(shift.depart(s, 29900).planned == 30000)
  assert(shift.arrive(s, rec(), 31500) == nil and s.state == 'done', 'the chain is over')
end

function T.a_late_bus_eats_the_layover_and_the_next_trip_starts_late()
  local s = gtfsShift({ { 25200 }, { 27000 }, { 30000 } }, 240)
  -- arrives at 07:25, the next one leaves at 07:30: a 5 min wait is fine
  local n = shift.arrive(s, rec(), 26700)
  assert(n.late == 0 and n.start == 27000 and n.layover == 300)
  shift.depart(s, 27000)
  -- the next trip ended at 08:06 (the bus is late): the turn takes 2 minutes, the trip starts 4 min after 08:00... planned 08:20
  n = shift.arrive(s, rec(), 29700)
  assert(n.planned == 30000 and n.late == 0 and n.layover == 300)
  -- a bus that is 10 minutes late: planned 30000, arrival at 30300: the trip begins at arrival + the turn, late by 7 min
  local s2 = gtfsShift({ { 25200 }, { 30000 } }, 240)
  n = shift.arrive(s2, rec(), 30300)
  assert(n.planned == 30000 and n.start == 30300 + shift.MIN_TURN_S and n.late == 420, 'late by ' .. tostring(n.late))
  assert(n.layover == shift.MIN_TURN_S, 'no more wait than the turn')
end

function T.a_trip_that_would_be_too_late_is_lost_and_the_next_one_taken()
  local s = gtfsShift({ { 25200 }, { 26000 }, { 30000 } }, 240)
  local n = shift.arrive(s, rec(), 26000 + shift.MAX_LATE_S + 600)          -- the second one cannot be reached any more
  assert(n and n.planned == 30000 and n.skipped == 1, 'the second trip was lost')
  shift.depart(s, n.start)
  assert(s.skipped == 1 and s.cursor == 4)
  assert(shift.result(s).skipped == 1)
end

function T.the_shift_ends_by_time_not_by_trips()
  local s = gtfsShift({ { 25200 }, { 29000 }, { 30000 } }, 60)                    -- 07:00 + 1 h = 08:00
  local n = shift.arrive(s, rec(), 26700)
  assert(n == nil and s.state == 'done', 'the 08:03 departure is after the end of the shift: none begins')
  local s2 = gtfsShift({ { 25200 }, { 29000 }, { 30000 } }, 120)
  assert(shift.arrive(s2, rec(), 26700) ~= nil, 'the same trips fit a two hour shift')
  assert(s2.endClock == 25200 + 7200)
  local _, why = shift.nextTrip(shift.new({ source = 'gtfs', startClock = 0, duration = 60, chain = chain({ { 0 }, { 99999 } }) }), 100)
  assert(why == 'time')
end

function T.nothing_to_chain_ends_the_shift()
  local s = gtfsShift({ { 25200 } }, 120)
  local n, why = shift.nextTrip(s, 26000)
  assert(n == nil and why == 'none')
  assert(shift.arrive(s, rec(), 26000) == nil and s.state == 'done' and s.endedAt == 26000)
  assert(select(2, shift.nextTrip(s, 26000)) == 'time', 'a finished shift offers nothing')
end

function T.generated_shift_goes_there_and_back_on_the_same_road()
  local s, r, back = generated({ duration = 240 })
  assert(s.source == 'generated' and s.dir == 1)
  local n = shift.arrive(s, rec(), s.startClock + 3000)
  assert(n and n.kind == 'generated' and n.dir == 2 and n.route == back, 'the way back first')
  assert(n.from == r.to and n.to == r.from)
  assert(n.start >= s.startClock + 3000 + shift.MIN_TURN_S and n.late == 0 and n.layover == n.start - (s.startClock + 3000))
  assert(n.entryTrip and n.entryTrip.start == n.planned)
  shift.depart(s, n.start)
  assert(s.dir == 2)
  local n2 = shift.arrive(s, rec(), n.start + 3000)
  assert(n2 and n2.dir == 1 and n2.route == r, 'and out again')
end

function T.generated_departures_come_from_the_generator()
  local s, _, back, _, backTrips = generated()
  local n = shift.nextTrip(s, s.startClock + 3000)
  local found = false
  for _, tr in ipairs(backTrips) do if tr.start == n.planned then found = true end end
  assert(found, 'the departure is one of schedule.generate for the way back')
  -- and it is the earliest one that leaves after the turn
  for _, tr in ipairs(backTrips) do
    if tr.start >= s.startClock + 3000 + shift.MIN_TURN_S then assert(tr.start >= n.planned) end
  end
  assert(back.ref == '305')
end

function T.generated_shift_runs_into_the_next_day_and_stops_at_its_end()
  local s, _, _, out, back = generated({ start = 21 * 3600, duration = 240 })
  local late = s.startClock + 1800
  local n = shift.nextTrip(s, 23 * 3600 + 50 * 60)
  if n then assert(n.start >= 23 * 3600 + 50 * 60 + shift.MIN_TURN_S) assert(n.start <= s.endClock) end
  -- far after the end: nothing begins
  local x, why = shift.nextTrip(s, s.endClock + 10)
  assert(x == nil and why == 'time')
  -- without a way back the shift is one trip
  local one = shift.new({ source = 'generated', startClock = 28800, duration = 60, legs = { { route = route(), trips = out } } })
  local y, why2 = shift.nextTrip(one, 30000)
  assert(y == nil and why2 == 'none')
  assert(#back > 0 and late > 0)
end

function T.the_layover_shows_the_wait_and_the_delay()
  local s = gtfsShift({ { 25200 }, { 27600, '363', 'B', 'C' } }, 240)
  shift.arrive(s, rec(), 26700)
  local l = shift.layover(s, 26800)
  assert(l.ref == '363' and l.to == 'C' and l.remaining == 800 and l.late == 0 and l.go == false and l.number == 2)
  assert(shift.layover(s, 27600 - shift.BOARD_LEAD_S).go == true, 'the trip begins a little before the departure')
  local late = shift.layover(s, 27700)
  assert(late.late == 100 and late.remaining == -100, 'the planned time has passed: the next trip is late')
  assert(shift.layover(gtfsShift({ { 1 } }), 5) == nil, 'no pending trip, no layover')
end

function T.a_long_layover_is_wound_forward()
  local s = gtfsShift({ { 25200 }, { 31000 } }, 240)
  shift.arrive(s, rec(), 26700)
  local to = shift.windTo(s, 26700)
  assert(to == 31000 - shift.WIND_TO_S, 'wound to ' .. tostring(to))
  shift.depart(s, 31000)
  local s2 = gtfsShift({ { 25200 }, { 27300 } }, 240)
  shift.arrive(s2, rec(), 26700)
  assert(shift.windTo(s2, 26700) == nil, 'ten minutes are waited')
end

function T.summary_adds_the_trips_up()
  local s = gtfsShift({ { 25200 }, { 27600 }, { 30000 } }, 240)
  shift.arrive(s, rec(900, 0), 26700)
  shift.depart(s, 27600)
  shift.arrive(s, rec(700, 200), 29000)
  shift.depart(s, 30000)
  shift.finish(s, 31000)
  local r = shift.result(s)
  assert(r.count == 2 and r.passengers == 40 and r.points == 800 and r.grade == 'A')
  assert(math.abs(r.punctuality - 0.9) < 1e-9 and r.served == 18 and r.planned == 20 and r.missed == 2)
  assert(r.revenue == 60 and r.lateTrips == 1 and r.minutes == 97)
  assert(r.source == 'gtfs' and r.durationMin == 240 and #r.trips == 2)
  assert(s.state == 'done')
  local e = shift.result(gtfsShift({ { 1 } }))
  assert(e.count == 0 and e.grade == '-' and e.punctuality == 1)
end

function T.the_record_takes_a_trips_result()
  local r = route()
  local res = { points = 777, grade = 'B', passengers = 12, revenue = 18, parts = { punctuality = 0.8 }, served = 9, planned = 10, missed = 1, notes = { {}, {} } }
  local x = shift.record(r, res, { minutes = 41, late = 130 })
  assert(x.ref == '305' and x.points == 777 and x.punctuality == 0.8 and x.minutes == 41 and x.late == 130 and x.notes == 2)
  assert(x.from == r.from and x.to == r.to)
end

function T.the_depot_run_starts_earlier_for_a_longer_way()
  assert(shift.depotLead(0) == 300 and shift.depotLead(800) == 340)
  assert(shift.depotLead(4000) == 740 and shift.depotLead(99999) == 1800)
  assert(shift.depotLead(nil) == 300)
end

function T.the_hud_numbers()
  local s = gtfsShift({ { 25200 }, { 27600 } }, 60)
  s.depot = { kind = 'depot' }
  local h = shift.hud(s, 26000)
  assert(h.number == 1 and h.source == 'gtfs' and h.endsIn == 25200 + 3600 - 26000 and h.depot == 'depot' and h.done == 0)
  assert(shift.hud(s, 99999).endsIn == 0)
end

function T.entry_of_a_chained_trip_is_the_timetables_trip_or_made_of_the_route()
  local r = route()
  local trips = sched.generate(r, 2)
  local tr = trips[3]
  local e = shift.entryFor({ kind = 'gtfs', planned = tr.start }, r, trips)
  assert(e.trip == tr and e.at == tr.start + tr.dep[1])
  r.gtfsOffs = {}
  for i = 1, #r.stops do r.gtfsOffs[i] = (i - 1) * 100 end
  local e2 = shift.entryFor({ kind = 'gtfs', planned = 12345 }, r, trips)
  assert(e2.trip.start == 12345 and e2.trip.arr[#r.stops] == (#r.stops - 1) * 100 and e2.trip.dep[2] == 100)
  r.gtfsOffs = nil
  assert(shift.entryFor({ kind = 'gtfs', planned = 12345 }, r, trips) == nil, 'nothing to build a timetable from')
  local g = shift.entryFor({ kind = 'generated', planned = 5, entryTrip = tr }, r, trips)
  assert(g.trip == tr and g.at == 5)
end

-- ---- the shift in main.lua, with the game and the data service stubbed ----------------------------------------------------

local function setup(o)
  o = o or {}
  H.reset()
  H.earth()
  local env = { pose = { lat = 50.4157, lon = 16.1626, speed = 0 }, gps = {}, toasts = {}, clock = 8 * 3600, hud = {}, ready = true,
    inBus = true, teleports = {}, opts = o.opts or {}, features = { shift = true, depot = true } }
  local relation = H.fixture(o.fixture or 'route_6964117')
  local ds = {
    state = { up = true, features = { path = true, along = true, search = true, stations = true, shift = true, depot = true } },
    has = function(f) return env.features[f] ~= false end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb) cb(H.fixture('nachod_around_slim3'), {}) end,
    stations = function(lat, lon, cb) cb({ elements = {} }, {}) end,
    route = function(id, cb) cb(relation, {}) end,
    shift = function(pid, start, day, mins, cb)
      env.shiftAsked = { pid = pid, start = start, day = day, mins = mins }
      cb(env.chain and env.chain(pid, start) or { trips = {} }, {})
    end,
    depot = function(lat, lon, cb) env.depotAsked = { lat = lat, lon = lon } cb(env.depotAnswer or { depot = nil }, {}) end,
  }
  local veh = { getID = function() return 7 end }
  local world = setmetatable({
    pose = function() return { lat = env.pose.lat, lon = env.pose.lon, speed = env.pose.speed } end,
    place = function() return 'Náchod' end, weekday = function() return 2 end, nowSec = function() return env.clock end,
    options = function() return env.opts end, navigate = function() end,
    toast = function(text) env.toasts[#env.toasts + 1] = text end,
    gpsRoute = function(points) env.gps[#env.gps + 1] = points return true end,
    teleport = function(lat, lon, name) env.teleports[#env.teleports + 1] = { lat = lat, lon = lon, name = name } return true end,
    vehicleInfo = function() return { bus = true, name = 'bus', id = 7 } end,
    vehicle = function() return env.inBus and veh or nil end,
    clockSet = function(sec) env.clockSet = sec end,
    clearMarkers = function() if env.breakClear then env.breakClear = false error('boom') end end,
  }, { __index = function() return function() end end })
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  package.loaded['earthBusRoutes/shiftrun'] = nil
  _G.jsonReadFile = function() error('no file') end
  _G.jsonWriteFile = function() return true end
  _G.guihooks = { trigger = function(name, data) if name == 'EarthBusRoutesHud' then env.hud[#env.hud + 1] = data end end }
  _G.beamngEarth_api.ready = function() return env.ready end
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  return m, env, osm.parseRoute(relation)
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  package.loaded['earthBusRoutes/shiftrun'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

-- opens the route card of the first line of the first station, standing at the route's first stop
local function openRoute(m, env, r)
  env.pose.lat, env.pose.lon, env.pose.speed = 50.4157, 16.1626, 0
  m.uiOpen()
  for _, st in ipairs(m.model().stations) do
    if st.lineCount > 0 then m.uiSelectStation(st.id) break end
  end
  m.uiSelectRoute(m.model().lines[1].variants[1].id)
  env.pose.lat, env.pose.lon = r.stops[1].lat, r.stops[1].lon          -- (the bus stands at the first stop)
  m.uiSetStartMode('first')
  assert(m.model().screen == 'route', 'the route card is open')
end

local function lastHud(env, key)
  for i = #env.hud, 1, -1 do if env.hud[i][key] then return env.hud[i][key] end end
end

-- drives the running trip stop by stop (the bus is put on each stop, stands until the doors are done, leaves) until it ends
local function driveTrip(m, env, stops, from)
  for i = from or 1, #stops do
    env.pose.lat, env.pose.lon, env.pose.speed = stops[i].lat, stops[i].lon, 0
    for _ = 1, 600 do
      m.onUpdate(0.5, 0.5)
      if not m.model().tripActive then return true end
      local h = env.hud[#env.hud]
      if h and h.phase == 'atStop' and h.atStop and h.atStop.alightLeft <= 0 and h.atStop.boardLeft <= 0 and not h.atStop.doorsHint and i < #stops then break end
    end
    if i < #stops then env.pose.speed = 6 m.onUpdate(0.5, 0.5) end
  end
  return not m.model().tripActive
end

local function waitFor(m, cond, frames)
  for _ = 1, frames or 4000 do
    if cond() then return true end
    m.onUpdate(0.5, 0.5)
  end
  return cond()
end

function T.a_shift_begins_with_its_first_trip_and_shows_the_source()
  local m, env, r = setup()
  openRoute(m, env, r)
  local md = m.model()
  assert(md.shift and md.shift.enabled and md.shift.depotOn and #md.shift.durations == 3, 'the page may offer a shift')
  m.uiStartShift(240, false)
  md = m.model()
  assert(md.tripActive and md.shift.active and md.shift.state == 'trip' and md.shift.source == 'generated' and md.shift.trips == 0)
  assert(env.shiftAsked == nil, 'a map line is not chained by the service')
  local h = lastHud(env, 'shift')
  assert(h and h.number == 1 and h.source == 'generated' and h.endsIn > 0, 'the trip HUD carries the shift')
  cleanup()
end

function T.a_layover_follows_a_trip_and_the_next_trip_goes_the_other_way()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(driveTrip(m, env, r.stops), 'the first trip ended')
  local md = m.model()
  assert(not md.tripActive and md.shift.active and md.shift.state == 'layover', 'state ' .. tostring(md.shift and md.shift.state))
  local lo = md.shift.layover
  assert(lo and lo.from == r.to and lo.to == r.from and lo.number == 2, 'the way back is next')
  assert(md.shift.trips == 1)
  local hud = lastHud(env, 'layover')
  assert(hud and hud.to == r.from and hud.departsLabel and hud.units == 'km/h', 'the HUD shows the layover')
  -- the menu opens on the dispatcher's page while the bus waits
  m.uiOpen()
  assert(m.model().screen == 'shiftLayover')
  -- time passes (a long wait is wound forward), the second trip begins by itself
  assert(waitFor(m, function() return m.model().tripActive end), 'the next trip began')
  md = m.model()
  assert(md.shift.state == 'trip' and md.shift.number == 2)
  assert(env.clockSet ~= nil)
  cleanup()
end

function T.leaving_the_bus_during_a_layover_makes_the_shift_wait()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(driveTrip(m, env, r.stops))
  env.inBus = false
  for _ = 1, 3000 do m.onUpdate(0.5, 0.5) end
  local md = m.model()
  assert(not md.tripActive and md.shift.active and md.shift.layover.away == true, 'the shift waits for the driver')
  assert(md.shift.layover.late > 0 or md.shift.layover.remaining <= 0, 'the time goes on: the next trip is late')
  env.inBus = true
  assert(waitFor(m, function() return m.model().tripActive end, 40), 'back in the bus the trip begins')
  assert(m.model().shift.state == 'trip')
  local h = lastHud(env, 'shift')
  assert(h and h.lateStart > 0, 'it began late')
  cleanup()
end

function T.a_short_shift_ends_when_no_trip_fits_and_shows_the_summary()
  local m, env, r = setup({ opts = { timeScale = 30 } })          -- (the clock runs fast: the trip takes hours of it)
  openRoute(m, env, r)
  m.uiStartShift(60, false)                       -- the line takes longer than the hour: nothing else begins
  assert(driveTrip(m, env, r.stops))
  local md = m.model()
  assert(md.screen == 'shiftResult' and not md.shift.active, 'the shift is over: ' .. tostring(md.screen))
  local res = md.shift.result
  assert(res and res.count == 1 and res.passengers >= 0 and res.source == 'generated' and res.punctuality > 0)
  assert(res.grade ~= '-' and res.trips[1].ref == r.ref and res.durationMin == 60)
  m.uiShiftClose()
  assert(m.model().screen == 'nearby' and m.model().shift.result == nil)
  cleanup()
end

function T.cancelling_a_trip_ends_the_shift_and_keeps_the_trips_done()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(driveTrip(m, env, r.stops))
  assert(waitFor(m, function() return m.model().tripActive end))
  m.uiCancelTrip()                                -- the second trip is given up: the first one still counts
  local md = m.model()
  assert(not md.tripActive and not md.shift.active and md.screen == 'shiftResult' and md.shift.result.count == 1)
  m.uiShiftClose()
  -- a shift with no trip done shows nothing
  openRoute(m, env, r)
  m.uiStartShift(120, false)
  m.uiCancelTrip()
  md = m.model()
  assert(not md.shift.active and md.screen == 'nearby' and md.shift.result == nil)
  cleanup()
end

function T.ending_the_shift_in_a_layover()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(driveTrip(m, env, r.stops))
  assert(m.model().shift.state == 'layover')
  m.uiShiftEnd()
  local md = m.model()
  assert(md.screen == 'shiftResult' and md.shift.result.count == 1 and not md.shift.active)
  cleanup()
end

function T.a_second_shift_cannot_start_while_one_runs_and_the_option_switches_it_off()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(120, false)
  m.uiStartShift(120, false)
  assert(m.model().error and m.model().error:find('already'))
  cleanup()
  local m2, env2, r2 = setup({ opts = { shifts = 'off' } })
  openRoute(m2, env2, r2)
  assert(m2.model().shift.enabled == false)
  m2.uiStartShift(120, false)
  assert(not m2.model().tripActive and m2.model().error == 'shift_off')
  cleanup()
end

function T.a_real_timetable_line_is_chained_by_the_service()
  local m, env, r = setup({ fixture = 'route_gtfs_363' })
  assert(r.timetable == 'gtfs')
  openRoute(m, env, r)
  local trips = sched.generate(r, 2)
  local dep = sched.departures(trips, 1, env.clock, 1)[1]
  local first = dep.trip.start
  env.chain = function()
    return { trips = {
      { pid = 1, id = r.id, start = first, ref = '363', from = r.from, to = r.to, head = r.to },
      { pid = 2, id = r.id, start = first + 6000, ref = '363', from = r.to, to = r.from, head = r.from, layover = 900 } } }
  end
  m.uiStartShift(240, false)
  assert(env.shiftAsked and env.shiftAsked.pid == r.id and env.shiftAsked.start == first and env.shiftAsked.mins == 240 and env.shiftAsked.day == 2)
  local md = m.model()
  assert(md.tripActive and md.shift.source == 'gtfs' and md.shift.realChain == true, 'the chain is the real one')
  assert(driveTrip(m, env, r.stops))
  md = m.model()
  assert(md.shift.state == 'layover' and md.shift.layover.planned == first + 6000, 'the next trip is the service one')
  assert(md.shift.layover.plannedLabel and md.shift.layover.departsLabel)
  assert(waitFor(m, function() return m.model().tripActive end), 'the chained trip began')
  cleanup()
end

function T.a_line_the_service_cannot_chain_is_driven_there_and_back()
  local m, env, r = setup({ fixture = 'route_gtfs_363' })
  openRoute(m, env, r)
  env.chain = function() return { trips = {} } end
  m.uiStartShift(120, false)
  assert(m.model().tripActive and m.model().shift.source == 'generated', 'the service had nothing')
  cleanup()
  -- an old service without /v1/shift
  local m2, env2, r2 = setup({ fixture = 'route_gtfs_363' })
  env2.features.shift = false
  openRoute(m2, env2, r2)
  m2.uiStartShift(120, false)
  assert(env2.shiftAsked == nil and m2.model().shift.source == 'generated' and m2.model().shift.realChain == false)
  cleanup()
end

function T.a_shift_may_begin_with_a_run_from_the_depot()
  local m, env, r = setup()
  env.depotAnswer = { depot = { name = 'Vozovna Náchod', lat = r.stops[1].lat + 0.03, lon = r.stops[1].lon, kind = 'depot', dist = 3300 } }
  openRoute(m, env, r)
  m.uiStartShift(240, true)
  assert(env.depotAsked and math.abs(env.depotAsked.lat - r.stops[1].lat) < 1e-6, 'the depot near the first stop was asked for')
  assert(#env.teleports == 1 and env.teleports[1].name == 'Vozovna Náchod', 'the player is taken to the depot')
  assert(not m.model().tripActive and m.model().shift.active)
  env.pose.lat, env.pose.lon = env.teleports[1].lat, env.teleports[1].lon
  env.ready = false
  m.onUpdate(0.5, 0.5)
  env.ready = true
  m.onUpdate(0.5, 0.5)
  local md = m.model()
  assert(md.shift.state == 'run' and md.shift.depot == 'depot' and md.shift.run.depot == 'Vozovna Náchod', 'the empty run began: ' .. tostring(md.shift.state))
  assert(env.gps[#env.gps][1].name == r.stops[1].name, 'the GPS leads to the first stop')
  local svc = lastHud(env, 'service')
  assert(svc and svc.stop == r.stops[1].name and svc.dist > 2000, 'the HUD says it is a service run')
  -- the event of our own teleport, just after the begin, is not the player's
  m.onBeamNGEarthTeleported()
  assert(m.model().shift.active)
  -- the bus gets to the first stop and stands: the trip begins
  env.pose.lat, env.pose.lon, env.pose.speed = r.stops[1].lat, r.stops[1].lon, 8
  m.onUpdate(0.5, 0.5)
  assert(m.model().shift.state == 'run', 'still rolling')
  env.pose.speed = 0
  m.onUpdate(0.5, 0.5)
  md = m.model()
  assert(md.tripActive and md.shift.state == 'trip' and md.shift.depot == 'depot')
  cleanup()
end

function T.no_depot_found_is_a_plain_start_and_a_depot_next_door_is_no_run()
  local m, env, r = setup()
  env.depotAnswer = { depot = nil }
  openRoute(m, env, r)
  m.uiStartShift(120, true)
  assert(m.model().tripActive and #env.teleports == 0 and m.model().shift.depot == nil)
  cleanup()
  local m2, env2, r2 = setup()
  env2.depotAnswer = { depot = { name = 'Depo', lat = r2.stops[1].lat + 0.0005, lon = r2.stops[1].lon, kind = 'station', dist = 50 } }
  openRoute(m2, env2, r2)
  m2.uiStartShift(120, true)
  assert(m2.model().tripActive and #env2.teleports == 0, 'a depot 50 m away is no run')
  cleanup()
  -- the depot switched off in the settings: not even asked
  local m3, env3, r3 = setup({ opts = { depotStart = 'off' } })
  openRoute(m3, env3, r3)
  m3.uiStartShift(120, true)
  assert(env3.depotAsked == nil and m3.model().shift.depotOn == false)
  cleanup()
end

function T.a_teleport_in_a_layover_ends_the_shift()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(driveTrip(m, env, r.stops))
  assert(m.model().shift.state == 'layover')
  for _ = 1, 20 do m.onUpdate(1, 1) end            -- (past the grace of our own teleports)
  m.onBeamNGEarthTeleported()
  local md = m.model()
  assert(not md.shift.active and md.screen == 'shiftResult', 'the player went away: the shift is over')
  cleanup()
end

function T.a_broken_shift_hook_ends_the_shift_and_the_trip_finishes_as_a_trip()
  local m, env, r = setup()
  openRoute(m, env, r)
  m.uiStartShift(240, false)
  assert(m.model().tripActive)
  env.breakClear = true                           -- the world fails when the shift takes the finished trip over
  assert(driveTrip(m, env, r.stops))
  env.breakClear = false
  local md = m.model()
  assert(not md.shift.active, 'the shift was dropped')
  assert(md.screen == 'result' and md.result and md.result.ref == r.ref, 'the trip shows its own result page: ' .. tostring(md.screen))
  cleanup()
end

return T
