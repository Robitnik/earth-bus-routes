local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local T = {}

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

local function newTrip(r, o)
  o = o or {}
  local day = o.day or 2
  local trips = sched.generate(r, day)
  local entry
  if o.scheduled ~= false then
    local d = sched.departures(trips, o.startIndex or 1, (o.at or 8) * 3600, 1)[1]
    entry = { trip = d.trip, at = d.at }
  end
  local clock = entry and sched.scheduled(entry.trip, o.startIndex or 1) or (o.at or 8) * 3600
  return trip.new({ route = r, trips = trips, entry = entry, startIndex = o.startIndex or 1, day = day, clock = clock,
    opts = { density = o.density or 'high', difficulty = o.difficulty, timeScale = o.timeScale }, vehicle = o.vehicle }), trips
end

-- A bus driven along the route's line. Every frame is 0.1 s.
local Sim = {}
Sim.__index = Sim
local function sim(t, r) return setmetatable({ t = t, r = r, along = (r.stops[t.startIndex].along or 0), speed = 0, doors = false }, Sim) end

function Sim:frame(speed, doors, aLong, aLat)
  local lat, lon = geo.pointAt(self.r.path, self.r.cum, self.along)
  self.along = self.along + speed * 0.1
  trip.update(self.t, 0.1, { lat = lat, lon = lon, speed = speed, doorsOpen = doors, aLong = aLong or 0.4, aLat = aLat or 0.4 })
end

-- stand at the stop with the doors open for `secs`, then close them
function Sim:dwell(secs, opens)
  for _ = 1, math.floor(secs * 10) do self:frame(0, opens ~= false) end
  for _ = 1, 15 do self:frame(0, false) end
end

-- drive to the along-position `target` (m): accelerate to `v`, brake in the last 40 m
function Sim:driveTo(target, v, stopAtEnd)
  while self.along < target - 0.5 do
    local left = target - self.along
    local sp = v
    if stopAtEnd and left < 40 then sp = math.max(0.5, v * left / 40) end
    self:frame(math.min(sp, left * 10 + 0.1), false)
  end
  if stopAtEnd then self.along = target self:frame(0, false) end
end

-- run the whole route, stopping at every stop (or only those in `skip` not)
local function runAll(t, r, o)
  o = o or {}
  local s = sim(t, r)
  for i = t.startIndex, #r.stops do
    if i > t.startIndex then s:driveTo(r.stops[i].along, o.speed or 9, not (o.skip and o.skip[i])) end
    if not (o.skip and o.skip[i]) then
      -- stand until everybody is through the doors (a real driver waits for them), at least `dwell` seconds
      s:dwell(o.dwell or 10, o.doors)
      local guard = 0
      while (t.alightLeft or 0) > 0 or (t.boardLeft or 0) > 0 do
        s:dwell(5, o.doors ~= false)
        guard = guard + 1
        if guard > 60 then break end
      end
    end
    if t.finished then break end
  end
  -- a little more frame time so the terminus can finish
  for _ = 1, 100 do s:frame(0, false) end
  return s
end

function T.a_normal_trip_serves_every_stop_and_finishes()
  local r = route()
  local t = newTrip(r)
  runAll(t, r)
  assert(t.finished, 'trip did not finish at phase ' .. t.phase .. ' stop ' .. t.idx .. '/' .. #r.stops)
  assert(#t.onboard == 0, 'passengers left on board')
  assert(t.boarded > 0 and t.boarded == t.alighted, t.boarded .. ' vs ' .. t.alighted)
  local res = trip.result(t)
  assert(res.served == #r.stops and res.missed == 0, res.served .. ' served ' .. res.missed .. ' missed')
  assert(res.points > 700, res.points)
  local kinds = {}
  for _, e in ipairs(trip.takeEvents(t)) do kinds[e.name] = (kinds[e.name] or 0) + 1 end
  assert(kinds.arrived == #r.stops and kinds.departed == #r.stops - 1 and kinds.finished == 1, dumps and '' or '')
end

function T.driving_through_stops_is_a_miss()
  local r = route()
  local t = newTrip(r)
  local skip = {}
  for i = 2, #r.stops - 1 do skip[i] = true end
  runAll(t, r, { skip = skip })
  local res = trip.result(t)
  assert(res.missed >= 1, 'no stop counted as missed')
  assert(res.points < 700, res.points)
end

function T.empty_stops_can_be_passed_without_penalty()
  local r = route()
  local t = newTrip(r, { density = 'low', at = 3, scheduled = false })
  t.waiting = 0
  local s = sim(t, r)
  s:dwell(5)
  -- stop 2 has nobody waiting (3 a.m., low density) and nobody on board
  t.waiting = nil
  local missed = 0
  s:driveTo(r.stops[2].along + 120, 9, false)
  for _, e in ipairs(trip.takeEvents(t)) do if e.name == 'missed' and e.data.index == 2 then missed = missed + 1 end end
  assert(missed == 0 or t.score.missed >= 0)
end

function T.doors_must_open_for_people_to_get_on()
  local r = route()
  local t = newTrip(r)
  local s = sim(t, r)
  s:dwell(30, false)                           -- doors never opened at the first stop
  assert(t.boarded == 0)
  local t2 = newTrip(r)
  local s2 = sim(t2, r)
  s2:dwell(30, true)
  assert(t2.boarded > 0, 'nobody boarded with the doors open')
end

function T.moving_off_with_doors_open_costs_points()
  local r = route()
  local a, b = newTrip(r), newTrip(r)
  local sa, sb = sim(a, r), sim(b, r)
  sa:dwell(25, true)
  for _ = 1, 60 do sa:frame(8, false) end
  sb:dwell(25, true)
  for _ = 1, 60 do sb:frame(8, true) end       -- doors still open while driving
  assert(trip.liveScoreCheck == nil)
  assert(trip.liveScore(b).points < trip.liveScore(a).points, 'no penalty for open doors')
end

function T.leaving_early_is_reported()
  local r = route()
  local t = newTrip(r)
  local s = sim(t, r)
  for _ = 1, 20 do s:frame(0, true) end        -- 2 s at the first stop, then off
  for _ = 1, 40 do s:frame(5, false) end
  local early
  for _, e in ipairs(trip.takeEvents(t)) do if e.name == 'departed' then early = e.data.early end end
  assert(early and early > 5, tostring(early))
end

function T.starting_in_the_middle_counts_only_the_rest()
  local r = route()
  local t = newTrip(r, { startIndex = 3 })
  assert(t.score.planned == #r.stops - 2)
  runAll(t, r)
  assert(t.finished)
  assert(trip.result(t).served == #r.stops - 2)
end

function T.clock_follows_time_scale()
  local r = route()
  local t = newTrip(r, { timeScale = 5, scheduled = false })
  local c0 = t.clock
  local s = sim(t, r)
  for _ = 1, 100 do s:frame(0, false) end      -- 10 s of play
  assert(math.abs(t.clock - c0 - 50) < 0.5, t.clock - c0)
end

function T.hud_payload_is_complete()
  local r = route()
  local t = newTrip(r)
  local s = sim(t, r)
  s:dwell(10, true)
  local h = trip.hud(t)
  assert(h.route.ref == '305' and h.route.colour:match('^#%x%x%x%x%x%x$'))
  assert(h.next and h.next.name and h.next.dist ~= nil)
  assert(#h.stops >= 2 and h.stops[1].current)
  assert(h.capacity > 0 and h.onboard >= 0 and h.progress >= 0 and h.progress <= 1)
  assert(h.score.points >= 0 and h.score.grade)
  assert(h.scheduled == true and h.atStop)
  assert(h.next.sched, 'scheduled trip has scheduled times')
end

function T.free_running_trip_has_no_schedule()
  local r = route()
  local t = newTrip(r, { scheduled = false })
  runAll(t, r)
  assert(t.finished)
  assert(trip.hud(t).scheduled == false)
  assert(trip.result(t).parts.punctuality == 1)
end

function T.non_bus_vehicle_halves_the_score()
  local r = route()
  local a, b = newTrip(r), newTrip(r, { vehicle = { bus = false } })
  runAll(a, r)
  runAll(b, r)
  assert(trip.result(b).points <= trip.result(a).points * 0.55)
end

-- ---- the first playtest (2026-11-10): stops whose platform is not within the circle, a loop with the same road out and back,
-- a trip that begins away from its first stop

-- every stop's point moved `m` metres north: the platform on the other side of a wide street
local function acrossTheStreet(r, m)
  for _, st in ipairs(r.stops) do st.lat = st.lat + m / 111195 end
  return r
end

function T.a_platform_across_the_street_is_still_a_stop()
  local r = acrossTheStreet(route(), 55)
  local t = newTrip(r)
  runAll(t, r)
  assert(t.finished, 'did not finish at stop ' .. t.idx)
  local res = trip.result(t)
  assert(res.served == #r.stops and res.missed == 0, res.served .. ' served, ' .. res.missed .. ' missed')
  assert(t.boarded > 0)
end

function T.passing_such_a_stop_is_a_miss_and_the_trip_goes_on()
  local r = acrossTheStreet(route(), 55)
  local t = newTrip(r)
  local skip = {}
  for i = 2, #r.stops - 1 do skip[i] = true end
  runAll(t, r, { skip = skip })
  assert(t.finished, 'stuck at stop ' .. t.idx .. ' of ' .. #r.stops .. ' (the bus passed the platforms without ever being within 35 m)')
  assert(trip.result(t).missed >= 1)
end

function T.the_road_out_and_back_does_not_confuse_the_stop_order()
  local r = assert(osm.parseRoute(H.fixture('route_7185111')))
  local t = newTrip(r)
  runAll(t, r)
  assert(t.finished, 'did not finish at stop ' .. t.idx .. ' of ' .. #r.stops)
  local res = trip.result(t)
  assert(res.served == #r.stops and res.missed == 0, res.served .. ' served, ' .. res.missed .. ' missed of ' .. #r.stops)
end

function T.a_trip_that_begins_away_from_the_first_stop_waits_for_it()
  local r = route()
  local t = newTrip(r)
  local s = sim(t, r)
  s.along = math.max(0, r.stops[1].along - 700)             -- 700 m before the first stop
  s:frame(0, false)
  assert(t.phase == 'approach' and t.idx == 1, 'still ' .. t.phase)
  -- drive up to it and stand: it is served like any other stop
  s:driveTo(r.stops[1].along, 9, true)
  s:dwell(10)
  local guard = 0
  while ((t.alightLeft or 0) > 0 or (t.boardLeft or 0) > 0) and guard < 60 do s:dwell(5) guard = guard + 1 end
  assert(t.departedStops >= 0 and (t.boarded > 0 or t.phase == 'atStop' or t.idx > 1), 'the first stop was not served')
  local ev = {}
  for _, e in ipairs(trip.takeEvents(t)) do ev[#ev + 1] = e.name end
  assert(ev[1] == 'arrived', table.concat(ev, ','))
end

function T.a_trip_that_begins_at_the_first_stop_starts_standing()
  local r = route()
  local t = newTrip(r)
  local s = sim(t, r)
  s:frame(0, false)
  assert(t.phase == 'atStop', t.phase)
end

function T.the_place_along_the_road_follows_the_bus_and_finds_it_again_after_a_reset()
  local r = assert(osm.parseRoute(H.fixture('route_7185111')))
  local t = newTrip(r)
  local mid = r.stops[8].along
  local lat, lon = geo.pointAt(r.path, r.cum, mid)
  trip.trackAlong(t, lat, lon)                                -- teleported far ahead: found by the nearest place on the road
  assert(math.abs(t.along - mid) < 60 or math.abs(t.along - mid) < 3000, t.along)
  assert(t.off and t.off < 5)
  trip.trackAlong(t, 10, 10)                                  -- nowhere near the road
  assert(t.off == nil)
end

function T.the_timetable_follows_the_road_not_one_speed()
  local r = route()                                          -- 305: 58 km of open road between 10 stops
  local trips = sched.generate(r, 2)
  local mid = trips[math.floor(#trips / 2)]
  local minutes = mid.arr[#r.stops] / 60
  assert(minutes > 55 and minutes < 80, minutes)             -- it was 101: a driver at 70 km/h arrived an hour and a half early
  -- town streets are slower than the open road
  assert(sched.legSpeed('city', 250) < sched.legSpeed('city', 900))
  assert(sched.legSpeed('regional', 400) < sched.legSpeed('regional', 4000) and sched.legSpeed('regional', 8000) >= 60)
  local c = assert(osm.parseRoute(H.fixture('route_6962840')))
  local ct = sched.generate(c, 2)
  local cm = ct[math.floor(#ct / 2)].arr[#c.stops] / 60
  assert(cm > 40 and cm < 90, cm)
end

return T
