-- The inside of the bus (plan 006 A / ideas 10 and 9): the LED board with its bell, standing passengers, the cup, falls.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local scoring = require('earthBusRoutes/scoring')
local cabin = require('earthBusRoutes/cabin')
local T = {}

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

-- a trip on the route's own timetable, `seats` seats (and room for 40 standing), people for the given stops on board
local function newTrip(r, o)
  o = o or {}
  local trips = sched.generate(r, 2)
  local d = sched.departures(trips, 1, 8 * 3600, 1)[1]
  local t = trip.new({ route = r, trips = trips, entry = { trip = d.trip, at = d.at }, startIndex = 1, day = 2,
    clock = sched.scheduled(d.trip, 1), opts = { density = 'high', difficulty = o.difficulty }, vehicle = { seats = o.seats or 5, standing = 40 } })
  if o.options then cabin.configure(t, o.options) end
  return t
end

-- the bus on its way to stop 2, `m` metres before it, with the given people on board (destinations)
local function approaching(r, t, m, onboard)
  t.idx, t.phase, t.waiting, t.along = 2, 'approach', 0, (r.stops[2].along or 0) - m - 30
  t.onboard = onboard or {}
  local lat, lon = geo.pointAt(r.path, r.cum, (r.stops[2].along or 0) - m)
  return lat, lon
end

local function frame(t, lat, lon, speed, aLong, aLat, dt)
  trip.update(t, dt or 0.1, { lat = lat, lon = lon, speed = speed, aLong = aLong or 0, aLat = aLat or 0, doorsOpen = false })
end

local function noteCount(t, text)
  local n = 0
  for _, x in ipairs(t.score.notes) do if x.text == text then n = n + 1 end end
  return n
end

local function crowd(n, dest) local o = {} for i = 1, n do o[i] = dest or 5 end return o end

function T.standing_passengers_are_those_without_a_seat()
  local r = route()
  local t = newTrip(r)
  approaching(r, t, 500, crowd(3))
  assert(cabin.standing(t) == 0)
  t.onboard = crowd(12)
  assert(cabin.standing(t) == 7)
  local lat, lon = geo.pointAt(r.path, r.cum, 100)
  frame(t, lat, lon, 8)
  local c = trip.hud(t).cabin.comfort
  assert(c.standing == 7 and c.seats == 5)
end

function T.a_hard_brake_with_nobody_standing_throws_nobody()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(5))                 -- exactly the seats
  for _ = 1, 30 do frame(t, lat, lon, 10, -6) end
  assert(noteCount(t, 'Passenger fell') == 0 and t.cabin.falls == 0)
  assert(scoring.result(t.score).parts.comfort < 1, 'the hard brake still costs comfort the old way')
end

function T.a_hard_brake_with_people_standing_throws_one_of_them()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(9))
  local base = newTrip(r)
  approaching(r, base, 500, crowd(5))
  for _ = 1, 10 do frame(t, lat, lon, 10, -5) frame(base, lat, lon, 10, -5) end
  assert(t.cabin.falls == 1 and noteCount(t, 'Passenger fell') == 1, 'one fall')
  local note = t.score.notes[#t.score.notes]
  assert(note.text == 'Passenger fell' and note.points == -30)
  local fell
  for _, e in ipairs(trip.takeEvents(t)) do if e.name == 'fell' then fell = e end end
  assert(fell and fell.data.standing == 4)
  -- minus 30 comfort points, nothing else
  local a, b = scoring.result(t.score), scoring.result(base.score)
  assert(math.abs((b.points - a.points) - 30) <= 1, (b.points - a.points) .. ' points lost')
  assert(math.abs(a.parts.comfort - (b.parts.comfort - 30 / scoring.WEIGHTS.comfort)) < 1e-6)
  assert(trip.hud(t).noteSeq > 0 and trip.hud(t).notes[#trip.hud(t).notes].text == 'Passenger fell', 'the HUD gets the note')
  assert(trip.hud(t).cabin.comfort.falls == 1 and trip.hud(t).cabin.comfort.fallSeq == 1)
end

function T.falls_have_a_pause_between_them()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(9))
  for _ = 1, 100 do frame(t, lat, lon, 10, -5) end                -- 10 s of hard braking
  assert(t.cabin.falls == 1, t.cabin.falls .. ' falls in 10 s')
  for _ = 1, 105 do frame(t, lat, lon, 10, -5) end                -- 20 s since the first
  assert(t.cabin.falls == 2, t.cabin.falls .. ' falls in 20 s')
  for _ = 1, 205 do frame(t, lat, lon, 10, -5) end
  assert(t.cabin.falls == 3, t.cabin.falls .. ' falls in 40 s')
  assert(noteCount(t, 'Passenger fell') == 3)
end

function T.the_limit_is_one_and_a_half_times_the_roughness_limit_and_follows_the_strictness()
  local r = route()
  local limit = scoring.LIMITS.longitudinal * 1.5
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(9))
  for _ = 1, 20 do frame(t, lat, lon, 10, -(limit - 0.1)) end      -- harsh for the score, not for the passengers
  assert(t.cabin.falls == 0)
  assert(t.score.harshSec > 0)
  for _ = 1, 5 do frame(t, lat, lon, 10, -(limit + 0.1)) end
  assert(t.cabin.falls == 1)
  -- the same brake with a relaxed score (k = 1.4) is forgiven, a strict one (k = 0.7) is not
  local relaxed = newTrip(r, { difficulty = 'relaxed' })
  lat, lon = approaching(r, relaxed, 500, crowd(9))
  for _ = 1, 5 do frame(relaxed, lat, lon, 10, -(limit + 0.1)) end
  assert(relaxed.cabin.falls == 0)
  local strict = newTrip(r, { difficulty = 'strict' })
  lat, lon = approaching(r, strict, 500, crowd(9))
  for _ = 1, 5 do frame(strict, lat, lon, 10, -(limit * 0.8)) end
  assert(strict.cabin.falls == 1)
end

function T.accelerating_or_standing_still_does_not_throw_anybody()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(9))
  for _ = 1, 30 do frame(t, lat, lon, 5, 6) end                    -- a hard start
  for _ = 1, 30 do frame(t, lat, lon, 0.2, -6) end                 -- a jolt at a standstill
  assert(t.cabin.falls == 0)
end

function T.the_option_switches_the_live_comfort_off()
  local r = route()
  local t = newTrip(r, { options = { liveComfort = 'off' } })
  local lat, lon = approaching(r, t, 500, crowd(9))
  for _ = 1, 30 do frame(t, lat, lon, 10, -6) end
  assert(t.cabin.falls == 0 and noteCount(t, 'Passenger fell') == 0)
  assert(trip.hud(t).cabin.comfort == nil, 'the HUD gets no comfort block')
  assert(trip.hud(t).cabin.led ~= nil, 'the LED board is a separate switch')
end

function T.the_cup_sways_with_the_ride_and_settles()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, crowd(2))
  for _ = 1, 100 do frame(t, lat, lon, 10, 0, 3) end               -- a steady 3 m/s^2 in a bend
  local lean = trip.hud(t).cabin.comfort.cup
  assert(lean > 6 and lean < 20, 'tilted into the bend: ' .. lean)
  local peak = 0
  for _ = 1, 30 do frame(t, lat, lon, 10, 0, 0) peak = math.min(peak, trip.hud(t).cabin.comfort.cup) end
  assert(peak < -0.5, 'the coffee overshoots the other way when the bend ends: ' .. peak)
  for _ = 1, 100 do frame(t, lat, lon, 10, 0, 0) end
  assert(math.abs(trip.hud(t).cabin.comfort.cup) < 0.5, 'settled')
  -- a violent ride spills it
  for _ = 1, 30 do frame(t, lat, lon, 10, 0, 12) end
  assert(trip.hud(t).cabin.comfort.spill == true)
end

function T.the_led_board_names_the_next_stop_and_the_line()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, {})
  frame(t, lat, lon, 8)
  local led = trip.hud(t).cabin.led
  assert(led.stop == r.stops[2].name and led.line == '305' and led.dest == r.to and not led.last, led.stop)
  assert(led.onRequest == false and led.requested == false)
  t.idx = #r.stops
  assert(trip.hud(t).cabin.led.last == true)
end

function T.a_request_stop_says_on_request_until_somebody_presses_the_button()
  local r = route()
  r.stops[2].onRequest = true
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 500, {})                       -- nobody for this stop
  frame(t, lat, lon, 8)
  local led = trip.hud(t).cabin.led
  assert(led.onRequest == true and led.requested == false)
  t.onboard = { 2 }                                                 -- somebody wants out there, 500 m ahead: not yet
  frame(t, lat, lon, 8)
  assert(trip.hud(t).cabin.led.onRequest == true)
  local lat2, lon2 = geo.pointAt(r.path, r.cum, (r.stops[2].along or 0) - 300)
  frame(t, lat2, lon2, 8)                                           -- 300 m: the button is pressed
  led = trip.hud(t).cabin.led
  assert(led.requested == true and led.onRequest == false and led.bellSeq == 1)
end

function T.the_bell_rings_once_when_a_stop_is_asked_for()
  local r = route()
  local t = newTrip(r)
  local lat, lon = approaching(r, t, 300, { 2, 4 })
  local bells = 0
  for _ = 1, 20 do
    frame(t, lat, lon, 8)
    for _, e in ipairs(trip.takeEvents(t)) do if e.name == 'bell' then bells = bells + 1 assert(e.data.index == 2) end end
  end
  assert(bells == 1, bells .. ' bells')
  -- nobody gets off at the next stop: no bell
  local t2 = newTrip(r)
  lat, lon = approaching(r, t2, 300, { 4, 5 })
  for _ = 1, 20 do frame(t2, lat, lon, 8) end
  for _, e in ipairs(trip.takeEvents(t2)) do assert(e.name ~= 'bell') end
  assert(t2.cabin.bellSeq == 0)
end

function T.no_bell_for_the_terminus_and_none_with_the_led_board_off()
  local r = route()
  local t = newTrip(r)
  t.idx, t.phase, t.waiting, t.onboard = #r.stops, 'approach', 0, crowd(3, #r.stops)
  local lat, lon = geo.pointAt(r.path, r.cum, (r.stops[#r.stops].along or 0) - 200)
  t.along = (r.stops[#r.stops].along or 0) - 230
  for _ = 1, 10 do frame(t, lat, lon, 8) end
  for _, e in ipairs(trip.takeEvents(t)) do assert(e.name ~= 'bell') end
  local off = newTrip(r, { options = { ledBoard = 'off' } })
  lat, lon = approaching(r, off, 300, { 2 })
  for _ = 1, 10 do frame(off, lat, lon, 8) end
  for _, e in ipairs(trip.takeEvents(off)) do assert(e.name ~= 'bell') end
  assert(trip.hud(off).cabin.led == nil and trip.hud(off).cabin.comfort ~= nil)
end

function T.configure_reads_the_menu_options_default_on()
  local t = {}
  cabin.configure(t, {})
  assert(t.opts.ledBoard == true and t.opts.liveComfort == true)
  cabin.configure(t, { ledBoard = 'off', liveComfort = 'on' })
  assert(t.opts.ledBoard == false and t.opts.liveComfort == true)
  cabin.configure(t, nil)
  assert(t.opts.ledBoard == true)
end

-- the request_stop tag of a stop (OSM) reaches the route, also the one driven the other way
function T.the_request_stop_tag_of_openstreetmap_marks_the_stop()
  local data = H.fixture('route_6964117')
  local plain = assert(osm.parseRoute(data))
  assert(plain.stops[2].onRequest == nil)
  local target = plain.stops[2]
  local marked = 0
  for i = 2, #data.elements do
    local e = data.elements[i]
    if e.id == target.id and e.tags then e.tags.request_stop = 'yes' marked = marked + 1 end
  end
  assert(marked >= 1)
  local r = assert(osm.parseRoute(data))
  local hit = 0
  for _, s in ipairs(r.stops) do if s.onRequest then hit = hit + 1 assert(s.id == target.id) end end
  assert(hit == 1, hit .. ' request stops')
  local back = osm.reversed(r)
  hit = 0
  for _, s in ipairs(back.stops) do if s.onRequest then hit = hit + 1 end end
  assert(hit == 1, 'the reversed route keeps it')
end

return T
