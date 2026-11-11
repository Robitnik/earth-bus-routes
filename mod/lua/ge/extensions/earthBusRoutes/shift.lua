-- A shift: a chain of trips with layovers at the termini, and what the dispatcher says between them. Pure logic (no game, no
-- network): main.lua / shiftrun.lua feed it what happened and ask what comes next, the tests drive it with plain tables.
-- All times are seconds on one continuous clock (the trip clock): a shift may run past midnight, so times above 86400 are normal.
--
-- Two sources of the chain (plan 006, stage B):
--   'gtfs'      the real timetable: the data service chained real departures at the termini (/v1/shift) -> plan.chain
--   'generated' the same line there and back, departures from schedule.generate -> plan.legs[1] (the way out) and plan.legs[2]
--               (the way back), each { route, trips }
local M = {}

M.DURATIONS = { 60, 120, 240 }     -- minutes of game time a shift lasts (no trip begins after that; the last one is finished)
M.MIN_TURN_S = 120                 -- the bus needs at least this long to turn round at the terminus
M.MAX_LATE_S = 1200                -- a chained trip that would leave more than this late is lost: the dispatcher gives it to somebody else
M.BOARD_LEAD_S = 90                -- the next trip begins this long before its departure, so the people can board
M.WIND_FROM_S = 900                -- a layover longer than this: the clock is wound forward (the wait is not played)
M.WIND_TO_S = 150                  -- ... to this long before the next departure
M.RUN_SPEED = 8                    -- m/s the empty run from the depot is expected to take (a town's streets)

local function clampDuration(mins)
  mins = tonumber(mins) or 120
  local best = M.DURATIONS[1]
  for _, d in ipairs(M.DURATIONS) do if math.abs(d - mins) < math.abs(best - mins) then best = d end end
  return best
end
M.clampDuration = clampDuration

-- plan = { source, startClock (planned time the first trip is at its first stop), duration (min), chain | legs, startIndex,
--          depot (the depot or station the shift starts from, or nil), vehId }
function M.new(plan)
  local s = {
    source = plan.source or 'generated', startClock = plan.startClock, duration = clampDuration(plan.duration),
    chain = plan.chain, legs = plan.legs, dir = 1, cursor = 2,             -- chain[1] is the trip the player starts with
    trips = {}, begun = 1, skipped = 0, state = 'running',                 -- 'running' | 'done'
    startIndex = plan.startIndex or 1, depot = plan.depot, vehId = plan.vehId,
    pending = nil, arrivedAt = nil, endedAt = nil,
  }
  s.endClock = s.startClock + s.duration * 60
  return s
end

-- The trips of the day of a route as of a continuous clock `base` (the midnight the clock is on)
local function firstAtOrAfter(trips, from)
  local base = math.floor(from / 86400) * 86400
  for _, add in ipairs({ base, base + 86400 }) do
    for _, tr in ipairs(trips or {}) do
      local at = tr.start + add
      if at >= from then return tr, at end
    end
  end
end

-- What follows a trip that ended at `arrivedAt`: a descriptor, or nil (+ why: 'time' the shift is over, 'none' nothing runs).
-- Descriptor: { kind, routeId (gtfs) | route (generated), dir, ref, from, to, planned (departure the timetable says), start (when it
-- really begins: later than planned when the bus is late), late (s), layover (s from the arrival to the start), index (gtfs) | entryTrip }
-- Does not change the shift: M.depart does when the trip begins.
function M.nextTrip(s, arrivedAt)
  if s.state == 'done' then return nil, 'time' end
  local earliest = arrivedAt + M.MIN_TURN_S
  if s.source == 'gtfs' then
    local skipped = 0
    for idx = s.cursor, #(s.chain or {}) do
      local it = s.chain[idx]
      if it.start > s.endClock then return nil, 'time' end
      if it.start + M.MAX_LATE_S >= earliest then
        local start = math.max(it.start, earliest)
        return { kind = 'gtfs', index = idx, routeId = it.id, pid = it.pid, ref = it.ref, from = it.from, to = it.to, head = it.head,
          planned = it.start, start = start, late = start - it.start, layover = start - arrivedAt, skipped = skipped, dir = 1 }
      end
      skipped = skipped + 1
    end
    return nil, 'none'
  end
  local dir = 3 - s.dir
  local leg = s.legs and s.legs[dir]
  if not leg then return nil, 'none' end
  local tr, at = firstAtOrAfter(leg.trips, earliest)
  if not tr then return nil, 'none' end
  if at > s.endClock then return nil, 'time' end
  local shifted = tr
  if at ~= tr.start then
    shifted = {}
    for k, v in pairs(tr) do shifted[k] = v end
    shifted.start = at
  end
  return { kind = 'generated', dir = dir, route = leg.route, ref = leg.route.ref, from = leg.route.from, to = leg.route.to,
    entryTrip = shifted, planned = at, start = at, late = 0, layover = at - arrivedAt, skipped = 0 }
end

-- The trip that ended: its numbers (M.record) and the clock. Works out what comes next and keeps it as s.pending.
-- Returns the next descriptor, or nil (the shift is over: M.result).
function M.arrive(s, record, arrivedAt)
  s.trips[#s.trips + 1] = record
  s.arrivedAt = arrivedAt
  local nxt = M.nextTrip(s, arrivedAt)
  s.pending = nxt
  if not nxt then s.state, s.endedAt = 'done', arrivedAt end
  return nxt
end

-- The pending trip begins now (`now` on the trip clock): the shift moves on to it. Returns the descriptor.
function M.depart(s, now)
  local nxt = s.pending
  if not nxt then return nil end
  s.pending = nil
  s.skipped = s.skipped + (nxt.skipped or 0)
  if nxt.kind == 'gtfs' then s.cursor = nxt.index + 1 else s.dir = nxt.dir end
  s.begun = s.begun + 1
  nxt.began = now
  return nxt
end

-- The shift ends now whatever is pending (the driver gave up, or the vehicle was lost)
function M.finish(s, now)
  s.state, s.pending, s.endedAt = 'done', nil, s.endedAt or now
end

-- What the dispatcher shows while the bus stands at the terminus at `now`: the pending trip, the wait, the delay
function M.layover(s, now)
  local p = s.pending
  if not p then return nil end
  local remaining = p.start - now
  return { ref = p.ref, from = p.from, to = p.to, planned = p.planned, departs = p.start, remaining = remaining,
    late = math.max(0, now - p.planned),            -- how late the next trip is (the planned time has passed: a late start)
    boardAt = p.start - M.BOARD_LEAD_S, go = now >= p.start - M.BOARD_LEAD_S, source = s.source, number = s.begun + 1 }
end

-- How long a layover is wound forward: the clock to set (nil: the wait is short, it is played)
function M.windTo(s, now)
  local p = s.pending
  if not p then return nil end
  if p.start - now > M.WIND_FROM_S then return p.start - M.WIND_TO_S end
end

-- The numbers the trip HUD shows about the shift
function M.hud(s, now)
  return { number = s.begun, source = s.source, endsIn = math.max(0, s.endClock - now), endClock = s.endClock,
    depot = s.depot ~= nil and s.depot.kind or nil, done = #s.trips }
end

-- Lead time (s) the empty run from the depot to the first stop begins before the planned departure: the drive plus a margin
function M.depotLead(distM)
  local d = tonumber(distM) or 0
  return math.max(300, math.min(1800, math.floor(d / M.RUN_SPEED + 240)))
end

-- A finished trip as the shift keeps it. `res` is trip.result / scoring.result; `info` = { minutes, late (s the trip began late) }
function M.record(route, res, info)
  info = info or {}
  return {
    ref = route.ref, from = route.from, to = route.to, colour = route.colour,
    points = res.points or 0, grade = res.grade or 'D', passengers = res.passengers or 0, revenue = res.revenue or 0,
    punctuality = (res.parts and res.parts.punctuality) or 1, served = res.served or 0, planned = res.planned or 0, missed = res.missed or 0,
    minutes = info.minutes or 0, late = info.late or 0, notes = #(res.notes or {}),
    smooth = (res.parts and res.parts.comfort or 0) >= 0.999,
  }
end

local GRADES = { { 900, 'S' }, { 800, 'A' }, { 650, 'B' }, { 500, 'C' }, { 0, 'D' } }
local function gradeOf(points)
  for _, g in ipairs(GRADES) do if points >= g[1] then return g[2] end end
  return 'D'
end

-- The summary of the shift (also the hook for the career, stage E: it can add earnings from this table).
-- { trips = { record ... }, count, passengers, points (mean per trip), grade, punctuality (0..1, mean over the trips),
--   served, planned, missed (stops skipped), skipped (chained trips lost to lateness), revenue, minutes, durationMin, source, depot }
function M.result(s)
  local n = #s.trips
  local pax, pts, punct, served, planned, missed, revenue, lateTrips = 0, 0, 0, 0, 0, 0, 0, 0
  for _, t in ipairs(s.trips) do
    pax, pts, punct = pax + t.passengers, pts + t.points, punct + t.punctuality
    served, planned, missed, revenue = served + t.served, planned + t.planned, missed + t.missed, revenue + t.revenue
    if (t.late or 0) > 60 then lateTrips = lateTrips + 1 end
  end
  local mean = n > 0 and math.floor(pts / n + 0.5) or 0
  local ended = s.endedAt or s.arrivedAt or s.startClock
  return {
    trips = s.trips, count = n, passengers = pax, points = mean, grade = n > 0 and gradeOf(mean) or '-',
    punctuality = n > 0 and punct / n or 1, served = served, planned = planned, missed = missed, skipped = s.skipped, lateTrips = lateTrips,
    revenue = revenue, minutes = math.max(0, math.floor((ended - s.startClock) / 60 + 0.5)), durationMin = s.duration,
    source = s.source, depot = s.depot and s.depot.kind or nil,
  }
end

-- The entry (the chosen scheduled trip, as trip.lua takes it) of a chained trip, for a loaded route and its timetable of the day:
-- the timetable's own trip with that departure when there is one, else one made of the route's times.
function M.entryFor(desc, route, trips)
  if desc.kind == 'generated' then return { trip = desc.entryTrip, at = desc.planned } end
  for _, tr in ipairs(trips or {}) do
    if tr.start == desc.planned then return { trip = tr, at = desc.planned + (tr.dep[1] or 0) } end
  end
  local offs = route.gtfsOffs
  if not offs then return nil end
  local arr, dep = {}, {}
  for i, o in ipairs(offs) do arr[i], dep[i] = o, o end
  return { trip = { id = 0, start = desc.planned, arr = arr, dep = dep }, at = desc.planned + (dep[1] or 0) }
end

return M
