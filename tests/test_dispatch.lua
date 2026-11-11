-- Plan 006 stage C: the dispatcher's events, transfers and tickets sold by the driver (dispatch.lua, connections.lua and their
-- hooks in trip.lua / scoring.lua / markers.lua).
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local dispatch = require('earthBusRoutes/dispatch')
local connections = require('earthBusRoutes/connections')
local markers = require('earthBusRoutes/markers')
local T = {}

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

-- a trip on the fixture route (a bus on a timetable); o.opts are merged into the trip's options
local function newTrip(r, o)
  o = o or {}
  local day = o.day or 2
  local trips = sched.generate(r, day)
  local start = o.startIndex or 1
  local d = sched.departures(trips, start, (o.at or 8) * 3600, 1)[1]
  local entry = { trip = d.trip, at = d.at }
  local opts = { density = o.density or 'high' }
  for k, v in pairs(o.opts or {}) do opts[k] = v end
  return trip.new({ route = r, trips = trips, entry = entry, startIndex = start, day = day, clock = sched.scheduled(entry.trip, start),
    opts = opts })
end

local Sim = {}
Sim.__index = Sim
local function sim(t, r) return setmetatable({ t = t, r = r, along = (r.stops[t.startIndex].along or 0) }, Sim) end
function Sim:frame(speed, doors)
  local lat, lon = geo.pointAt(self.r.path, self.r.cum, self.along)
  self.along = self.along + speed * 0.1
  trip.update(self.t, 0.1, { lat = lat, lon = lon, speed = speed, doorsOpen = doors, aLong = 0.4, aLat = 0.4 })
end
function Sim:stand(secs, doors) for _ = 1, math.floor(secs * 10) do self:frame(0, doors ~= false) end end
function Sim:driveTo(target, v, stopAtEnd)
  while self.along < target - 0.5 do
    local left = target - self.along
    local sp = v
    if stopAtEnd and left < 40 then sp = math.max(0.5, v * left / 40) end
    self:frame(math.min(sp, left * 10 + 0.1), false)
  end
  if stopAtEnd then self.along = target self:frame(0, false) end
end

local function noteTexts(t)
  local out = {}
  for _, n in ipairs(t.score.notes) do out[#out + 1] = n.text end
  return table.concat(out, '|')
end

-- ---- the radio ---------------------------------------------------------------------------------------------------------------------

function T.a_message_stays_eight_seconds_and_the_next_one_waits_its_turn()
  local t = newTrip(route())
  dispatch.say(t, 'closed', { stop = 'A' }, 'event')
  dispatch.say(t, 'request', { stop = 'B' }, 'event')
  assert(dispatch.current(t).key == 'closed')
  local s = sim(t, t.route)
  s:stand(7.5)
  assert(dispatch.current(t).key == 'closed', 'still on after 7.5 s')
  s:stand(1)
  assert(dispatch.current(t).key == 'request', 'the next one after 8 s')
  s:stand(9)
  assert(dispatch.current(t) == nil, 'gone after its time')
  assert(trip.hud(t).dispatch == nil)
end

-- ---- planning ------------------------------------------------------------------------------------------------------------------------

-- a long line of 30 stops a minute apart, every one a school: only the rule of the gap limits the events
local function schoolLine()
  local r = { ref = '7', stops = {} }
  for i = 1, 30 do r.stops[i] = { name = 'Brno, ZŠ ' .. i, along = i * 400, lat = 50, lon = 16 } end
  return r
end

function T.at_most_one_event_every_ten_minutes_and_the_same_seed_gives_the_same_events()
  local r = schoolLine()
  local o = { route = r, startIndex = 1, day = 2, clock0 = 7.5 * 3600, eta = function(i) return 7.5 * 3600 + (i - 1) * 60 end }
  local a, b = dispatch.plan(o), dispatch.plan(o)
  assert(#a > 0, 'a school at the morning rush brings a group')
  assert(#a == #b)
  for i, e in ipairs(a) do
    assert(e.stop == b[i].stop and e.kind == b[i].kind and e.people == b[i].people, 'the same seed, the same events')
    if i > 1 then assert(e.eta - a[i - 1].eta >= dispatch.EVENT_GAP_S, 'events are ten minutes apart') end
    assert(e.kind == 'school' and e.people >= 8 and e.people <= 15, 'a group of 8..15')
  end
  assert(#a <= 3, 'a half-hour trip has at most 3 events, got ' .. #a)
  o.clock0 = o.clock0 + 1
  local c = dispatch.plan(o)
  assert(#c == #a, 'another seed, still within the rule')
end

function T.a_school_group_comes_on_school_days_in_school_hours_only()
  local r = schoolLine()
  local function count(day, hour)
    local n = 0
    for seed = 1, 20 do
      n = n + #dispatch.plan({ route = r, startIndex = 1, day = day, clock0 = seed * 100, eta = function(i) return hour * 3600 + (i - 1) * 60 end })
    end
    return n
  end
  assert(count(2, 7.5) > 0 and count(2, 14) > 0)
  for seed = 1, 20 do
    for _, e in ipairs(dispatch.plan({ route = r, startIndex = 1, day = 6, clock0 = seed, eta = function(i) return 7.5 * 3600 + (i - 1) * 60 end })) do
      assert(e.kind ~= 'school', 'no school group at the weekend')
    end
    for _, e in ipairs(dispatch.plan({ route = r, startIndex = 1, day = 2, clock0 = seed, eta = function(i) return 11 * 3600 + (i - 1) * 60 end })) do
      assert(e.kind ~= 'school', 'no school group at eleven')
    end
  end
end

function T.a_stadium_in_the_evening_brings_a_crowd()
  local r = { ref = '9', stops = {} }
  for i = 1, 6 do r.stops[i] = { name = i == 4 and 'Hradec, stadion' or ('Stop ' .. i), along = i * 400, lat = 50, lon = 16 } end
  local seen = 0
  for seed = 1, 20 do
    for _, e in ipairs(dispatch.plan({ route = r, startIndex = 1, day = 5, clock0 = seed, eta = function(i) return 19 * 3600 + (i - 1) * 60 end })) do
      if e.kind == 'crowd' then seen = seen + 1 assert(e.stop == 4 and e.people >= 20) end
    end
  end
  assert(seen > 0, 'a crowd now and then')
end

function T.with_events_off_nothing_is_planned()
  local t = newTrip(route(), { opts = { events = false } })
  assert(#t.dispatch.events == 0)
  local r = route()
  local on = newTrip(r)
  assert(on.dispatch.events ~= nil)
end

-- ---- what the events do ------------------------------------------------------------------------------------------------------------

local function withEvent(ev, o)
  local r = route()
  local t = newTrip(r, o)
  t.dispatch.events = { ev }
  return t, r
end

function T.a_school_group_adds_people_to_the_stop_and_the_dispatcher_says_so()
  local t, r = withEvent({ kind = 'school', stop = 3, eta = 0, people = 12 }, { density = 'low' })
  local base = newTrip(route(), { density = 'low' })
  local s, sb = sim(t, r), sim(base, base.route)
  for _, x in ipairs({ { s, t }, { sb, base } }) do
    x[1]:driveTo(r.stops[2].along, 9, true) x[1]:stand(6)
    x[1]:driveTo(r.stops[3].along, 9, true)
  end
  assert(t.dispatch.cur or #t.dispatch.queue > 0 or t.eventsDone == 1, 'the message was sent')
  s:stand(2) sb:stand(2)
  assert(t.waiting == base.waiting + 12, ('12 more people at the stop: %s vs %s'):format(tostring(t.waiting), tostring(base.waiting)))
  assert(t.eventsDone == 1)
end

function T.a_stop_out_of_service_is_passed_without_a_penalty_and_marked_grey()
  local t, r = withEvent({ kind = 'closed', stop = 3, eta = 0 }, { density = 'high' })
  local s = sim(t, r)
  s:driveTo(r.stops[2].along, 9, true) s:stand(6)
  s:driveTo(r.stops[3].along - 150, 9, false)
  assert(t.extra[3] and t.extra[3].closed, 'the event fired on the approach')
  local items = markers.plan(t, nil, 0)
  local grey
  for _, it in ipairs(items) do if it.index == 3 then grey = it.state end end
  assert(grey == 'closed', 'the bay is grey: ' .. tostring(grey))
  assert(markers.COLOURS.closed)
  s:driveTo(r.stops[3].along + 120, 9, false)
  s:driveTo(r.stops[4].along - 150, 9, false)
  assert(t.idx == 4, 'the trip went on')
  assert(t.score.missed == 0 and not noteTexts(t):find('Stop skipped'), 'no penalty for driving past')
end

function T.driving_past_a_stop_that_was_just_requested_is_a_miss()
  local t, r = withEvent({ kind = 'request', stop = 3, eta = 0 }, { density = 'low' })
  local s = sim(t, r)
  s:driveTo(r.stops[2].along, 9, true) s:stand(6)
  s:driveTo(r.stops[3].along - 300, 9, false)
  assert(t.extra[3] and t.extra[3].request, ('the request came: idx %s phase %s dist %s along %s stop %s dists %s'):format(t.idx, t.phase, tostring(t.dist), t.along, r.stops[3].along, tostring(t.dispatch.events[1].fired) .. ' extra=' .. tostring(t.extra[3]) .. ' req=' .. tostring(t.extra[3] and t.extra[3].request) .. ' d2=' .. r.stops[2].along))
  assert(trip.hud(t).requested, 'the HUD shows the stop as requested')
  s:driveTo(r.stops[3].along + 120, 9, false)
  assert(t.score.missed == 1, 'driving past it costs')
end

function T.a_wheelchair_user_needs_the_doors_open_for_fifteen_seconds()
  local t, r = withEvent({ kind = 'wheelchair', stop = 3, eta = 0 }, { density = 'low' })
  local s = sim(t, r)
  s:driveTo(r.stops[2].along, 9, true) s:stand(6)
  s:driveTo(r.stops[3].along, 9, true)
  s:stand(10)
  assert(not noteTexts(t):find('Wheelchair'), 'not yet at 10 s')
  s:stand(9)
  assert(noteTexts(t):find('Wheelchair passenger helped'), noteTexts(t))
  -- and the one who is left behind
  local t2, r2 = withEvent({ kind = 'wheelchair', stop = 3, eta = 0 }, { density = 'low' })
  local s2 = sim(t2, r2)
  s2:driveTo(r2.stops[2].along, 9, true) s2:stand(6)
  s2:driveTo(r2.stops[3].along, 9, true)
  s2:stand(3)
  for _ = 1, 40 do s2:frame(6, false) end
  assert(noteTexts(t2):find('Wheelchair passenger left behind'), noteTexts(t2))
  assert(trip.result(t).parts.service > trip.result(t2).parts.service or trip.result(t).parts.service == 1)
end

function T.a_forgotten_bag_holds_the_terminus_until_it_is_handed_in()
  local r = route()
  local t = newTrip(r, { startIndex = #r.stops - 1, density = 'low' })
  t.dispatch.events = { { kind = 'bag', stop = #r.stops, eta = 0 } }
  local s = sim(t, r)
  s:driveTo(r.stops[#r.stops].along - 100, 8, false)
  assert(t.extra[#r.stops] and t.extra[#r.stops].bag, 'the dispatcher asks for the bag')
  s:driveTo(r.stops[#r.stops].along, 8, true)
  s:stand(2.5, true)
  assert(not t.finished, 'the trip waits for the bag')
  s:stand(5, true)
  assert(noteTexts(t):find('Bag handed in'), noteTexts(t))
  for _ = 1, 100 do s:frame(0, false) end
  assert(t.finished, 'then it ends')
  -- nobody opens the doors: the trip is not held for ever
  local t2 = newTrip(r, { startIndex = #r.stops - 1, density = 'low' })
  t2.dispatch.events = { { kind = 'bag', stop = #r.stops, eta = 0 } }
  local s2 = sim(t2, r)
  s2:driveTo(r.stops[#r.stops].along, 8, true)
  s2:stand(1, true)
  for _ = 1, 400 do s2:frame(0, false) end
  assert(t2.finished and not noteTexts(t2):find('Bag handed in'))
end

-- ---- tickets --------------------------------------------------------------------------------------------------------------------------

local function boardMany(kind, opts)
  local r = route()
  r.kind = kind
  local t = newTrip(r, { opts = opts })
  t.dispatch.events = {}
  local s = sim(t, r)
  s:stand(1)                                        -- begins standing at the first stop: boarding opens
  t.boardLeft = 60                                  -- a big queue
  local frames = 0
  while t.boardLeft > 0 and frames < 5000 do s:frame(0, true) frames = frames + 1 end
  return t, frames / 10
end

function T.on_a_suburban_line_some_passengers_buy_a_ticket_and_the_dwell_grows_by_at_most_twelve_seconds()
  local t, secs = boardMany('regional')
  assert(t.tickets == true)
  local sold = t.score.tickets or 0
  assert(sold >= 1 and sold <= 8, 'tickets sold: ' .. sold)
  assert(t.ticketExtra <= trip.TICKET_MAX_S + 1e-9 and t.ticketExtra == sold * trip.TICKET_S, 'cap of 12 s: ' .. t.ticketExtra)
  assert(math.abs(t.score.revenue - sold * t.score.fare * trip.TICKET_FARE_K) < 1e-9, 'the tickets are in the revenue')
  local c, csecs = boardMany('city')
  assert(c.tickets == false and (c.score.tickets or 0) == 0 and c.ticketExtra == 0, 'a city line sells none')
  assert(math.abs((secs - csecs) - t.ticketExtra) < 1.0, ('the dwell is longer by the tickets: %.1f vs %.1f + %.1f'):format(secs, csecs, t.ticketExtra))
  assert(trip.result(t).tickets == sold)
end

function T.a_busy_city_line_has_no_tickets_either_and_the_option_switches_them_off()
  local r = route()
  r.kind = 'city'
  local trips = sched.generate(r, 2)
  local d = sched.departures(trips, 1, 8 * 3600, 1)[1]
  local t = trip.new({ route = r, trips = trips, entry = { trip = d.trip, at = d.at }, startIndex = 1, day = 2, clock = d.at,
    opts = {}, ctx = { busy = true } })
  assert(t.tickets == false, 'a busy city line is a main line')
  local off = boardMany('regional', { tickets = false })
  assert(off.tickets == false and (off.score.tickets or 0) == 0)
end

-- ---- transfers ------------------------------------------------------------------------------------------------------------------------

function T.the_offer_needs_a_hub_a_line_arriving_within_five_minutes_after_us_and_is_limited_to_two()
  local t = newTrip(route(), { startIndex = 3 })
  local eta = t.clock0
  connections.store(t, 3, eta, 0, { arrivals = { { ref = '360', to = 'X', rel = -60 }, { ref = '361', to = 'X', rel = 400 }, { ref = '362', to = 'Y', rel = 180 } }, lines = 2 })
  assert(connections.offer(t, 3, eta) == nil, 'two lines is not a hub')
  t.offered = {}
  t.route.stops[3].station = true
  local o = connections.offer(t, 3, eta)
  assert(o and o.ref == '362' and o.after == 180, 'the one 3 min after us, not before and not 6 min after')
  assert(connections.offer(t, 3, eta) == o, 'one offer per stop')
  t.conn[4], t.conn[5], t.conn[6] = t.conn[3], t.conn[3], t.conn[3]
  for _, i in ipairs({ 4, 5, 6 }) do t.route.stops[i].station = true end
  assert(connections.offer(t, 4, eta), 'the second')
  assert(connections.offer(t, 5, eta) == nil, 'not a third')
  -- a hub by its lines
  local t2 = newTrip(route(), { startIndex = 3 })
  connections.store(t2, 3, eta, 0, { arrivals = { { ref = '360', rel = 60 } }, lines = 3 })
  assert(connections.offer(t2, 3, eta))
  -- off
  local t3 = newTrip(route(), { startIndex = 3, opts = { transfers = false } })
  t3.route.stops[3].station = true
  connections.store(t3, 3, eta, 0, { arrivals = { { ref = '360', rel = 60 } }, lines = 5 })
  assert(connections.offer(t3, 3, eta) == nil)
end

function T.approximate_arrivals_are_made_up_from_the_lines_and_marked_so()
  local lines = { { ref = '360', to = 'A', kind = 'city' }, { ref = '12', to = 'B', kind = 'regional' } }
  local a = connections.approx(lines, 9 * 3600, 2, 8 * 60)
  local b = connections.approx(lines, 9 * 3600, 2, 8 * 60)
  assert(#a == #b)
  for i, x in ipairs(a) do
    assert(x.approx == true and math.abs(x.rel) <= 8 * 60 and x.rel == b[i].rel)
  end
  local night = connections.approx(lines, 3 * 3600, 2, 8 * 60)
  assert(#night == 0, 'no service at three in the night')
end

local function atHub(o)
  local r = route()
  r.stops[3].station = true
  local t = newTrip(r, { startIndex = 3, opts = o })
  t.dispatch.events = {}
  connections.store(t, 3, t.clock0, 0, { arrivals = { { ref = '360', to = 'Hradec', rel = 120 } }, lines = 4 })
  return t, r, sim(t, r)
end

function T.waiting_at_the_hub_until_the_other_line_comes_takes_its_passengers_aboard()
  local t, r, s = atHub()
  s:stand(1)
  assert(t.hold and t.hold.ref == '360', 'the bus waits for line 360')
  local h = trip.hud(t)
  assert(h.hold and h.hold.ref == '360' and h.hold.left > 0 and h.dispatch.key == 'connectionWait')
  local before = t.boarded + t.boardLeft
  s:stand(135)
  assert(t.hold == nil and t.connCount == 1, 'they came')
  assert(t.score.counts.connections == 1 and noteTexts(t):find('Connection made'))
  assert(t.boarded + t.boardLeft >= before + 2, 'more people got on')
  assert(t.waived > 60, 'the wait past the timetable is not held against the driver: ' .. t.waived)
  -- the next stop is not late because of it: the arrival delta is forgiven by the wait
  s:stand(20)
  s:driveTo(r.stops[4].along, 9, true)
  assert(t.arrivalDelta == nil or t.arrivalDelta < 120, 'the wait is not counted as lateness at the next stop: ' .. tostring(t.arrivalDelta))
end

function T.the_wait_for_a_connection_is_not_lateness_at_the_next_stop()
  local function arrival(o)
    local t, r, s = atHub(o)
    s:stand(135)
    s:driveTo(r.stops[4].along, 12, true)
    assert(t.idx == 4 and t.phase == 'atStop', 'reached the next stop')
    return t.arrivalDelta, t
  end
  local forgiven, t1 = arrival()
  local plain, t2 = arrival({ transfers = false })
  assert(t1.waived > 60 and t2.waived == 0)
  assert(plain > 20 and forgiven < plain - 20, ('late by %.0f s with the connection, %.0f s without'):format(forgiven, plain))
end

function T.leaving_before_the_other_line_comes_is_a_missed_connection()
  local t, r, s = atHub()
  s:stand(20)
  assert(t.hold)
  for _ = 1, 40 do s:frame(6, false) end
  assert(t.hold == nil and t.score.counts.missedConnections == 1, noteTexts(t))
  assert(noteTexts(t):find('Missed connection'))
  assert(t.leftBehind >= 2, 'the passengers stayed behind')
  assert(trip.result(t).parts.service < 1)
end

function T.with_transfers_off_the_bus_does_not_wait()
  local t, r, s = atHub({ transfers = false })
  s:stand(5)
  assert(t.hold == nil and (t.score.counts or {}).connections == nil)
end

function T.a_line_that_came_before_us_is_not_waited_for_and_one_far_off_neither()
  local r = route()
  r.stops[3].station = true
  local t = newTrip(r, { startIndex = 3 })
  connections.store(t, 3, t.clock0, 0, { arrivals = { { ref = '360', rel = 280 } }, lines = 4 })
  -- we arrive 10 minutes later than expected: the line has been and gone
  t.clock0 = t.clock0 + 600
  t.clock = t.clock0
  local s = sim(t, r)
  s:stand(2)
  assert(t.hold == nil, 'it was here already')
  local t2 = newTrip(r, { startIndex = 3 })
  connections.store(t2, 3, t2.clock0, 0, { arrivals = { { ref = '360', rel = 280 } }, lines = 4 })
  t2.clock0 = t2.clock0 - 600                                -- early by 10 minutes: too long a wait
  t2.clock = t2.clock0
  local s2 = sim(t2, r)
  s2:stand(2)
  assert(t2.hold == nil, 'more than six minutes is too long')
end

function T.the_dispatcher_announces_the_connection_on_the_approach()
  local r = route()
  r.stops[4].station = true
  local t = newTrip(r, { startIndex = 3 })
  t.dispatch.events = {}
  local s = sim(t, r)
  s:stand(1) s:stand(10, false)
  connections.store(t, 4, trip.scheduledArrival(t, 4), 0, { arrivals = { { ref = '360', to = 'Hradec', rel = 120 } }, lines = 4 })
  local said
  while s.along < r.stops[4].along - 100 and not said do
    s:frame(9, false)
    if t.dispatch.cur and t.dispatch.cur.key == 'connection' then said = t.dispatch.cur end
  end
  assert(said, 'announced on the approach')
  assert(said.params.ref == '360' and said.params.mins == 2 and said.params.stop == r.stops[4].name and said.params.time:match('^%d%d:%d%d$'))
  assert(t.offered[4] and t.offered[4].ref == '360')
  local approx = newTrip(r, { startIndex = 3 })
  connections.store(approx, 4, trip.scheduledArrival(approx, 4), 0, { arrivals = { { ref = '360', rel = 120 } }, lines = 4, approx = true })
  assert(connections.offer(approx, 4, trip.scheduledArrival(approx, 4)).approx == true)
end

-- ---- the modules are plain Lua 5.1 ---------------------------------------------------------------------------------------------------

function T.the_new_modules_load_and_use_no_lua53_syntax()
  for _, n in ipairs({ 'dispatch', 'connections' }) do
    local src = readFileText('mod/lua/ge/extensions/earthBusRoutes/' .. n .. '.lua')
    src = src:gsub('%-%-[^\n]*', ''):gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
    assert(not src:find('//') and not src:find('<<') and not src:find('>>'), n)
    assert(not src:find('%f[%w_]goto%f[^%w_]') and not src:find('%f[%w_]utf8%.') and not src:find('math%.tointeger'), n)
  end
end

return T
