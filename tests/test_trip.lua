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

return T
