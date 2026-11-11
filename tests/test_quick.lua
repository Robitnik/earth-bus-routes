-- "Next trip from here" (plan 006 A / idea 11): which departure the card shows and how the one-press start sets the trip up.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local quick = require('earthBusRoutes/quick')
local T = {}

local function gtfs360() return assert(osm.parseRoute(H.fixture('route_gtfs_360'))) end
local function cand360(day)
  local r = gtfs360()
  local c = assert(quick.candidate(r, { lat = r.stops[1].lat, lon = r.stops[1].lon }, {}))
  return c, r
end

-- a candidate with hand-made trips: departures at `deps` (s) from stop 1
local function fake(id, place, deps, day)
  local trips = {}
  for i, d in ipairs(deps) do trips[i] = { id = i, start = d, arr = { 0, 600 }, dep = { 0, 600 } } end
  return { route = { id = id, ref = 'L' .. id, colour = '#123456', to = 'Z', stops = { { name = 'Here' }, { name = 'There' } } },
    idx = 1, place = place, trips = { [day or 3] = trips, [(day or 3) % 7 + 1] = trips } }
end

function T.variants_put_the_lines_that_start_here_first_and_leave_out_the_ones_that_end_here()
  local lines = {
    { ref = '1', variants = { { id = 11, place = 'through' }, { id = 12, place = 'from' }, { id = 13, place = 'to' } } },
    { ref = '2', variants = { { id = 21, place = 'to' }, { id = 22, place = 'through' } } },
    { ref = '3', variants = { { id = 31, place = 'loop' }, { id = 32, place = 'to', approx = true } } },
  }
  local v = quick.variants(lines, 10)
  local ids = {}
  for _, x in ipairs(v) do ids[#ids + 1] = x.id end
  -- round robin: the best variant of every line first, then the next ones; 13 and 21 (it ends here) are never loaded
  assert(table.concat(ids, ',') == '12,22,31,11,32', table.concat(ids, ','))
  assert(#quick.variants(lines, 2) == 2)
  assert(#quick.variants({}, 5) == 0 and #quick.variants(nil, 5) == 0)
end

function T.a_route_that_ends_at_the_station_or_misses_it_is_no_candidate()
  local r = gtfs360()
  local last = r.stops[#r.stops]
  assert(quick.candidate(r, { lat = last.lat, lon = last.lon }, {}) == nil, 'it only ends there')
  assert(quick.candidate(r, { lat = 51.5, lon = 16.2 }, {}) == nil, 'far from every stop')
  local mid = r.stops[5]
  local c = assert(quick.candidate(r, { lat = mid.lat, lon = mid.lon }, {}))
  assert(c.place == 'through' and c.idx == 5)
  local first = quick.candidate(r, { lat = r.stops[1].lat, lon = r.stops[1].lon }, {})
  assert(first.place == 'from' and first.idx == 1)
end

function T.a_circular_line_leaves_from_where_it_begins()
  local r = assert(osm.parseRoute(H.fixture('route_gtfs_363')))
  local c = assert(quick.candidate(r, { lat = r.stops[#r.stops].lat, lon = r.stops[#r.stops].lon }, {}))
  assert(r.loop and c.place == 'loop' and c.idx == 1)
end

function T.the_nearest_departure_is_shown_with_the_real_timetable()
  local c = cand360()
  -- a Wednesday at 05:10: the 05:25 is the next one (15 minutes: it is waited for)
  local q = assert(quick.pick({ c }, 5 * 3600 + 600, 3))
  assert(q.sec == 19500 and q.label == '05:25' and not q.tomorrow and q.source == 'gtfs', q.label)
  local m = quick.model(q, 5 * 3600 + 600)
  assert(m.inMin == 15 and m.wait == true and m.ref == q.ref and m.stopName == c.route.stops[1].name)
  -- at 05:26 the first one has gone: the next is 06:25, 59 minutes away: the clock would move
  q = assert(quick.pick({ c }, 5 * 3600 + 26 * 60, 3))
  assert(q.label == '06:25')
  m = quick.model(q, 5 * 3600 + 26 * 60)
  assert(m.inMin == 59 and m.wait == false)
end

function T.the_exact_twenty_minutes_are_still_waited_for()
  local c = cand360()
  local q = assert(quick.pick({ c }, 19500 - 20 * 60, 3))
  assert(quick.model(q, 19500 - 20 * 60).wait == true)
  q = assert(quick.pick({ c }, 19500 - 20 * 60 - 31, 3))
  assert(quick.model(q, 19500 - 20 * 60 - 31).wait == false)
end

function T.after_the_last_departure_of_the_day_it_is_the_first_of_tomorrow()
  local c = cand360()
  -- Wednesday 23:50: the last real one left at 13:20; Thursday has the same list
  local now = 23 * 3600 + 50 * 60
  local q = assert(quick.pick({ c }, now, 3))
  assert(q.tomorrow == true and q.abs == 86400 + 19500 and q.sec == 19500 and q.label == '05:25', q.label)
  local m = quick.model(q, now)
  assert(m.tomorrow and m.inMin == math.floor((86400 + 19500 - now) / 60 + 0.5))
  -- Friday night: tomorrow is a Saturday with its own list (a wrap of the week too: Sunday -> Monday)
  q = assert(quick.pick({ c }, now, 5))
  assert(q.tomorrow and q.sec == 27660, q.sec)
  assert(quick.pick({ c }, now, 7).tomorrow == true)
end

function T.a_departure_just_after_midnight_counts_from_the_evening()
  local c = fake(1, 'from', { 600 })                      -- a night bus at 00:10 (every day)
  local now = 23 * 3600 + 55 * 60
  local q = assert(quick.pick({ c }, now, 3))
  assert(q.tomorrow and q.abs == 86400 + 600 and q.secLeft == 15 * 60)
  assert(quick.model(q, now).wait == true, 'a quarter of an hour is waited for')
end

function T.a_stop_where_the_line_starts_wins_over_one_it_only_passes()
  local through = fake(1, 'through', { 8 * 3600 })
  local from = fake(2, 'from', { 8 * 3600 + 90 })        -- 90 s later: still preferred
  local q = assert(quick.pick({ through, from }, 7 * 3600 + 3000, 3))
  assert(q.routeId == 2 and q.place == 'from', tostring(q.routeId))
  -- much later: the nearest departure wins
  from = fake(2, 'from', { 8 * 3600 + 600 })
  q = assert(quick.pick({ through, from }, 7 * 3600 + 3000, 3))
  assert(q.routeId == 1)
  -- the same minute: the one that starts here
  from = fake(2, 'loop', { 8 * 3600 })
  q = assert(quick.pick({ through, from }, 7 * 3600 + 3000, 3))
  assert(q.routeId == 2)
  -- an earlier one that starts here stays the earliest
  q = assert(quick.pick({ fake(3, 'from', { 7 * 3600 + 3300 }), through }, 7 * 3600 + 3000, 3))
  assert(q.routeId == 3)
end

function T.without_candidates_there_is_no_card()
  assert(quick.pick({}, 3600, 3) == nil and quick.pick(nil, 3600, 3) == nil and quick.model(nil, 0) == nil)
  assert(quick.pick({ fake(1, 'from', {}) }, 3600, 3) == nil)
end

function T.a_generated_timetable_is_marked_as_such()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  local c = assert(quick.candidate(r, { lat = r.stops[1].lat, lon = r.stops[1].lon }, {}))
  local q = assert(quick.pick({ c }, 8 * 3600, 2))
  assert(q.source == 'generated' and q.sec >= 8 * 3600 and q.sec < 9 * 3600)
  assert(sched.departures(sched.generate(r, 2, {}), 1, 8 * 3600, 1)[1].at == q.abs, 'the same timetable the menu builds')
end

local function planFor(r, c)
  local trips = sched.generate(r, 3, {})
  return { route = r, trips = trips, startIndex = 1, day = 3, clock = 0, opts = { density = 'high' }, vehicle = {} }
end

function T.a_near_departure_is_waited_for_at_the_stop_with_the_clock_left_alone()
  local c, r = cand360()
  local now = 5 * 3600 + 600
  local q = quick.pick({ c }, now, 3)
  local plan = quick.adjustPlan(planFor(r, c), q, now)
  assert(plan.waitStart == true and plan.clock == now and plan.entry.trip.start == 19500 and plan.startIndex == 1)
end

function T.a_far_departure_moves_the_clock_to_it()
  local c, r = cand360()
  local now = 3 * 3600
  local q = quick.pick({ c }, now, 3)
  local plan = quick.adjustPlan(planFor(r, c), q, now)
  assert(not plan.waitStart and plan.clock == sched.scheduled(q.trip, 1) and plan.entry.trip.start == 19500)
end

function T.waiting_over_midnight_shifts_tomorrows_trip_to_the_clock_of_the_evening()
  local c = fake(1, 'from', { 600 })
  c.route.stops[1].lat, c.route.stops[1].lon = 50, 16
  local now = 23 * 3600 + 55 * 60
  local q = quick.pick({ c }, now, 3)
  local plan = quick.adjustPlan({ startIndex = 1, clock = 0 }, q, now)
  assert(plan.waitStart and plan.clock == now and plan.entry.trip.start == 86400 + 600)
  assert(q.trip.start == 600, 'the timetable itself is not changed')
end

-- the trip that waits: the arrival at the first stop is on time, the HUD counts down to the departure, leaving early costs
local function waitingTrip(r, c, now)
  local q = quick.pick({ c }, now, 3)
  local plan = quick.adjustPlan(planFor(r, c), q, now)
  plan.waitStart = true
  local t = trip.new(plan)
  return t, q
end

function T.the_waiting_trip_starts_on_time_and_counts_down_to_the_departure()
  local c, r = cand360()
  local now = 5 * 3600 + 600
  local t = waitingTrip(r, c, now)
  local s = { lat = r.stops[1].lat, lon = r.stops[1].lon, speed = 0, doorsOpen = true, aLong = 0, aLat = 0 }
  for _ = 1, 20 do trip.update(t, 0.1, s) end
  assert(t.phase == 'atStop' and t.arrivalDelta == 0, tostring(t.arrivalDelta))
  local w1 = trip.hud(t).cabin.led.waitSec
  assert(w1 and w1 > 800 and w1 <= 900, tostring(w1))        -- about 15 minutes
  for _ = 1, 100 do trip.update(t, 0.1, s) end
  local w2 = trip.hud(t).cabin.led.waitSec
  assert(w2 < w1, 'the countdown goes down')
end

function T.a_trip_that_does_not_wait_keeps_its_old_arrival_rule()
  local c, r = cand360()
  local q = quick.pick({ c }, 3 * 3600, 3)
  local plan = quick.adjustPlan(planFor(r, c), q, 3 * 3600)
  local t = trip.new(plan)
  local s = { lat = r.stops[1].lat, lon = r.stops[1].lon, speed = 0, doorsOpen = true, aLong = 0, aLat = 0 }
  for _ = 1, 20 do trip.update(t, 0.1, s) end
  assert(t.arrivalDelta ~= nil and math.abs(t.arrivalDelta) < 5, 'arrives at the scheduled time')
  assert(trip.hud(t).cabin.led.waitSec == nil)
end

-- ---- main.lua with the service and the game stubbed: the card on the Stops tab and the one-press start ----------------------------

local function setup(clock, opts)
  H.reset()
  H.earth()
  local route = H.fixture('route_6964117')
  local first = osm.parseRoute(route).stops[1]
  local env = { pose = { lat = first.lat, lon = first.lon, speed = 0 }, clock = clock, hud = {}, teleports = 0, loads = 0, opts = opts or {} }
  local ds = {
    state = { up = true, features = { path = true, along = true, search = true, stations = true } },
    has = function() return true end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb) cb(H.fixture('nachod_around_slim3'), {}) end,
    stations = function(lat, lon, cb) cb({ elements = {} }, {}) end,
    route = function(id, cb) env.loads = env.loads + 1 cb(route, {}) end,
  }
  local world = setmetatable({
    pose = function() return { lat = env.pose.lat, lon = env.pose.lon, speed = env.pose.speed } end,
    place = function() return 'Nachod' end, weekday = function() return 2 end, nowSec = function() return env.clock end,
    options = function() return env.opts end, navigate = function() end,
    teleport = function() env.teleports = env.teleports + 1 return true end,
    vehicleInfo = function() return { bus = true, name = 'bus' } end,
  }, { __index = function() return function() end end })
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  _G.jsonReadFile = function() error('no file') end
  _G.jsonWriteFile = function() return true end
  local last
  _G.guihooks = { trigger = function(name, data)
    if name == 'EarthBusRoutesState' then last = data elseif name == 'EarthBusRoutesHud' then env.hud[#env.hud + 1] = data end
  end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  return m, function() return last end, env
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

local function seconds(label) local h, m = label:match('^(%d+):(%d+)$') return tonumber(h) * 3600 + tonumber(m) * 60 end

function T.the_menu_gets_the_card_for_the_stop_you_stand_at()
  local m, model = setup(8 * 3600)
  m.uiOpen()
  local nt = model().nextTrip
  assert(nt, 'no card')
  assert(nt.ref == '305' and nt.stopName == 'Náchod, Okresní soud' and nt.label:match('^%d%d:%d%d$') and nt.place == 'from', nt.stopName .. ' ' .. tostring(nt.place))
  assert(nt.source == 'generated' and nt.inMin >= 0 and seconds(nt.label) >= 8 * 3600)
  cleanup()
end

function T.no_card_away_from_a_stop_or_with_the_option_off()
  local m, model, env = setup(8 * 3600)
  env.pose.lat, env.pose.lon = 50.45, 16.05                -- far from every stop of the fixture
  m.uiOpen()
  assert(model().nextTrip == nil)
  cleanup()
  m, model = setup(8 * 3600, { quickStart = 'off' })
  m.uiOpen()
  assert(model().nextTrip == nil, 'switched off in the menu settings')
  assert(model().stations and #model().stations > 0, 'the rest of the page is unaffected')
  cleanup()
end

function T.one_press_starts_a_trip_that_waits_for_a_near_departure()
  local m, model, env = setup(8 * 3600)
  m.uiOpen()
  local at = seconds(model().nextTrip.label)
  cleanup()
  -- five minutes before it leaves: the clock is left alone
  m, model, env = setup(at - 300)
  m.uiOpen()
  local nt = model().nextTrip
  assert(nt.wait == true and nt.inMin == 5, tostring(nt.inMin))
  m.uiStartNext()
  assert(m.status().trip == true and model().tripActive == true)
  local h = env.hud[#env.hud]
  assert(h.route.ref == '305' and h.index == 1)
  assert(math.abs(h.clock - (at - 300)) < 1, 'the clock stays at ' .. tostring(h.clock))
  assert(env.teleports == 0, 'standing at the stop: no teleport')
  cleanup()
end

function T.one_press_moves_the_clock_to_a_far_departure()
  local m, model, env = setup(3 * 3600)                    -- the night: the first bus of the day is hours away
  m.uiOpen()
  local nt = model().nextTrip
  assert(nt and nt.wait == false and nt.inMin > 20, tostring(nt and nt.inMin))
  m.uiStartNext()
  local h = env.hud[#env.hud]
  assert(m.status().trip and math.abs(h.clock - seconds(nt.label)) < 61, 'the clock is at the departure: ' .. tostring(h.clock))
  cleanup()
end

function T.pressing_while_a_trip_runs_does_nothing()
  local m, model, env = setup(8 * 3600)
  m.uiOpen()
  m.uiStartNext()
  assert(m.status().trip)
  local before = #env.hud
  m.uiStartNext()
  assert(m.status().trip and model().nextTrip == nil, 'no card while driving')
  cleanup()
end

return T
