-- One bus trip: stops, doors, passengers, timetable and score. A state machine fed with samples of the bus
-- ({lat, lon, speed, aLong, aLat, doorsOpen}) every frame; it never touches the game, so the tests drive it with a
-- simulated bus. Times are seconds; `clock` is the time of day (s from midnight) the trip runs on.
local geo = require('earthBusRoutes/geomath')
local demand = require('earthBusRoutes/demand')
local scoring = require('earthBusRoutes/scoring')
local M = {}

M.ZONE_M = 35            -- the bus is "at" a stop this near its platform
M.APPROACH_M = 200       -- the crowd of a stop is made when the bus gets this near
M.PASSED_M = 60          -- farther than this after the zone without having stopped: the stop was passed
M.STOP_SPEED = 1.0       -- m/s: slower than this the bus stands
M.GO_SPEED = 2.0         -- m/s: faster than this after standing it has left
M.NO_DOORS_DWELL_S = 3   -- a vehicle without doors: standing this long counts as doors open
M.END_DWELL_S = 3        -- at the terminus the trip ends this long after the last passenger is out

-- plan = { route, trips (timetable) or nil, entry (the chosen scheduled trip) or nil, startIndex, day, clock (s),
--          opts = { density, difficulty, timeScale, weather }, vehicle = { bus, seats, standing } }
function M.new(plan)
  local route = plan.route
  local w, central = demand.stopWeights(route, plan.ctx)
  local capacity, seats = demand.capacity(plan.vehicle)
  local t = {
    route = route, entry = plan.entry, trips = plan.trips, day = plan.day or 2, opts = plan.opts or {},
    w = w, central = central, capacity = capacity, seats = seats,
    clock = plan.clock, clock0 = plan.clock, elapsed = 0,
    idx = plan.startIndex or 1, startIndex = plan.startIndex or 1,
    phase = 'approach', onboard = {}, requested = false,
    waiting = nil, boarded = 0, alighted = 0, lastBoard = 0, lastAlight = 0, leftBehind = 0,
    timer = 0, standing = 0, doorWasOpen = false, doorOpenedHere = false, minDist = math.huge, inZone = false,
    arrivedAt = nil, finished = false, along = 0, alongTimer = 0, dist = nil, lastDeparture = nil,
    events = {}, departedStops = 0, notes = {},
  }
  t.score = scoring.new({ difficulty = t.opts.difficulty, bus = not plan.vehicle or plan.vehicle.bus ~= false,
    planned = #route.stops - t.startIndex + 1 })
  t.phase = 'start'                                     -- begins standing at the chosen first stop
  return t
end

local function emit(t, name, data) t.events[#t.events + 1] = { name = name, data = data } end
function M.takeEvents(t) local e = t.events t.events = {} return e end

local function hour(t) return (t.clock / 3600) % 24 end
local function weekend(t) return t.day >= 6 end

function M.stop(t, i) return t.route.stops[i or t.idx] end

-- Scheduled arrival / departure (s from midnight) at stop i for the chosen trip, nil when driving free
function M.scheduledArrival(t, i)
  if not t.entry then return nil end
  return t.entry.trip.start + (t.entry.trip.arr[i or t.idx] or 0)
end

function M.scheduledDeparture(t, i)
  if not t.entry then return nil end
  return t.entry.trip.start + (t.entry.trip.dep[i or t.idx] or 0)
end

-- seconds since the previous bus left here: the headway, longer when we are late (people pile up)
local function sinceLast(t, i)
  local headway = 600
  if t.trips and t.entry then
    local id = t.entry.trip.id
    local prev = t.trips[id - 1]
    if prev then headway = math.max(60, (t.entry.trip.start + (t.entry.trip.dep[i] or 0)) - (prev.start + (prev.dep[i] or 0))) end
  end
  local late = 0
  local sched = M.scheduledArrival(t, i)
  if sched then late = math.max(0, t.clock - sched) end
  return headway + late
end

local function makeWaiting(t)
  local i = t.idx
  local n = demand.waiting(t.route, t.w, t.central, i, hour(t), weekend(t), sinceLast(t, i),
    { tripId = t.entry and t.entry.trip.id or 0, day = t.day, density = t.opts.density, weather = t.opts.weather })
  t.waiting = n
end

local function onboardFor(t, i)
  local n = 0
  for _, d in ipairs(t.onboard) do if d == i then n = n + 1 end end
  return n
end

-- Does the next stop need the bus? (somebody gets off, or people wait)
local function needed(t)
  return onboardFor(t, t.idx) > 0 or (t.waiting or 0) > 0 or t.idx == #t.route.stops
end

local function startStopping(t, sample)
  t.phase = 'atStop'
  t.arrivedAt = t.clock
  t.timer, t.standing, t.doorOpenedHere = 0, 0, false
  t.alightLeft = onboardFor(t, t.idx)
  if t.idx == #t.route.stops then t.alightLeft = #t.onboard end
  if t.waiting == nil then makeWaiting(t) end
  t.boardLeft = t.waiting or 0
  t.lastBoard, t.lastAlight = 0, 0
  local sched = M.scheduledArrival(t, t.idx)
  local delta = sched and (t.clock - sched) or nil
  t.arrivalDelta = delta
  scoring.arrived(t.score, delta)
  t.requested = false
  emit(t, 'arrived', { index = t.idx, stop = M.stop(t), delta = delta })
end

local function finish(t)
  t.finished, t.phase = true, 'finished'
  t.result = scoring.result(t.score)
  emit(t, 'finished', t.result)
end

local function depart(t)
  local i = t.idx
  local sched = M.scheduledDeparture(t, i)
  local early = sched and math.max(0, sched - t.clock) or 0
  scoring.departed(t.score, early, t.lastBoard, t.lastAlight, math.max(0, t.boardLeft or 0))
  emit(t, 'departed', { index = i, stop = M.stop(t, i), early = early, boarded = t.lastBoard, alighted = t.lastAlight })
  t.lastDeparture = t.clock
  t.departedStops = t.departedStops + 1
  t.idx = i + 1
  t.waiting, t.phase, t.inZone, t.minDist = nil, 'approach', false, math.huge
  t.doorOpenedHere = false
end

-- One person boards or gets off at a time while the doors are open
local function serve(t, dt, doorsOpen)
  if not doorsOpen then return end
  t.doorOpenedHere = true
  t.timer = t.timer + dt
  while true do
    if t.alightLeft > 0 then
      if t.timer < demand.ALIGHT_S then return end
      t.timer = t.timer - demand.ALIGHT_S
      -- the person nearest to getting off here leaves (any with this destination; at the terminus everybody)
      local removed = false
      for k = #t.onboard, 1, -1 do
        if t.onboard[k] == t.idx or t.idx == #t.route.stops then table.remove(t.onboard, k) removed = true break end
      end
      t.alightLeft = t.alightLeft - 1
      if removed then t.alighted = t.alighted + 1 t.lastAlight = t.lastAlight + 1 end
    elseif t.boardLeft > 0 and t.idx < #t.route.stops then
      if t.timer < demand.BOARD_S then return end
      if #t.onboard >= t.capacity then t.leftBehind = t.leftBehind + t.boardLeft t.boardLeft = 0 return end
      t.timer = t.timer - demand.BOARD_S
      local rand = demand.rng(demand.hashSeed(t.route.id or t.route.ref, t.entry and t.entry.trip.id or 0, t.idx, 'p', t.boarded, t.day))
      t.onboard[#t.onboard + 1] = demand.destination(t.route, t.w, t.central, t.idx, hour(t), weekend(t), rand)
      t.boardLeft = t.boardLeft - 1
      t.boarded = t.boarded + 1
      t.lastBoard = t.lastBoard + 1
    else
      return
    end
  end
end

-- Advance by dt with the bus sample. Returns nothing; read t.phase, events (M.takeEvents) and M.hud(t).
function M.update(t, dt, s)
  if t.finished then return end
  t.elapsed = t.elapsed + dt
  t.clock = t.clock0 + t.elapsed * (t.opts.timeScale or 1)
  local stop = M.stop(t)
  if not stop then return finish(t) end
  local speed = s.speed or 0
  local doorsOpen = s.doorsOpen
  t.standing = (speed < M.STOP_SPEED) and (t.standing + dt) or 0
  if doorsOpen == nil then doorsOpen = (t.phase == 'atStop' or t.phase == 'start') and t.standing >= M.NO_DOORS_DWELL_S end
  scoring.sample(t.score, dt, speed, s.aLong, s.aLat, doorsOpen, s.overLimit)

  t.dist = geo.dist(s.lat, s.lon, stop.lat, stop.lon)
  t.alongTimer = t.alongTimer - dt
  if t.alongTimer <= 0 then
    t.alongTimer = 0.5
    local a = geo.along(t.route.path, t.route.cum, s.lat, s.lon, math.max(0, t.along - 150))
    if a then t.along = a end
  end

  if t.phase == 'start' then
    -- standing at the chosen first stop (the player was set down there): boarding opens as for any arrival
    startStopping(t, s)
  elseif t.phase == 'approach' then
    if t.dist <= M.APPROACH_M and t.waiting == nil then makeWaiting(t) end
    if t.dist <= M.ZONE_M then
      t.inZone = true
      t.minDist = math.min(t.minDist, t.dist)
      if speed < M.STOP_SPEED then startStopping(t, s) end
    elseif t.inZone and t.dist > M.PASSED_M and t.dist > t.minDist + 20 then
      -- drove through the stop's zone without standing
      if needed(t) then
        scoring.missed(t.score, t.waiting)
        emit(t, 'missed', { index = t.idx, stop = stop, waiting = t.waiting or 0 })
        t.leftBehind = t.leftBehind + (t.waiting or 0)
      end
      t.idx = t.idx + 1
      t.waiting, t.inZone, t.minDist = nil, false, math.huge
      if t.idx > #t.route.stops then finish(t) end
    end
    t.requested = onboardFor(t, t.idx) > 0
  elseif t.phase == 'atStop' then
    serve(t, dt, doorsOpen)
    local done = t.alightLeft <= 0 and t.boardLeft <= 0
    if t.idx == #t.route.stops then
      if done and (t.doorOpenedHere or #t.onboard == 0) then
        t.endTimer = (t.endTimer or 0) + dt
        if t.endTimer >= M.END_DWELL_S then finish(t) end
      end
    elseif speed > M.GO_SPEED then
      depart(t)
    end
  end
end

-- The numbers the HUD shows
function M.hud(t)
  local stops = t.route.stops
  local nextStop = stops[t.idx]
  local list = {}
  for i = t.idx, math.min(#stops, t.idx + 6) do
    local sched = M.scheduledArrival(t, i)
    list[#list + 1] = { name = stops[i].name, sched = sched, current = (i == t.idx), index = i, station = stops[i].station or false }
  end
  local delta = nil
  if nextStop and t.entry then
    local sched = M.scheduledArrival(t, t.idx)
    if sched then delta = t.clock - sched end
  end
  local remaining = nextStop and math.max(0, (nextStop.along or 0) - t.along) or 0
  local total = t.route.length > 0 and t.route.length or 1
  return {
    route = { ref = t.route.ref, colour = t.route.colour, from = t.route.from, to = t.route.to, name = t.route.name,
      network = t.route.network, operator = t.route.operator, kind = t.route.kind },
    clock = t.clock, phase = t.phase, index = t.idx, count = #stops,
    next = nextStop and { name = nextStop.name, dist = t.dist, remaining = remaining, sched = M.scheduledArrival(t, t.idx),
      delta = delta } or nil,
    stops = list,
    onboard = #t.onboard, capacity = t.capacity, seats = t.seats,
    waitingNext = t.waiting, requested = t.requested,
    boarded = t.boarded, alighted = t.alighted, lastBoard = t.lastBoard, lastAlight = t.lastAlight,
    leftBehind = t.leftBehind,
    progress = math.max(0, math.min(1, t.along / total)),
    scheduled = t.entry ~= nil,
    score = M.liveScore(t),
    notes = M.recentNotes(t), noteSeq = t.score.noteSeq or 0,
    atStop = t.phase == 'atStop' and { alightLeft = t.alightLeft, boardLeft = t.boardLeft, doorsHint = not t.doorOpenedHere } or nil,
    finished = t.finished,
  }
end

function M.liveScore(t)
  local r = scoring.result(t.score)
  return { points = r.points, grade = r.grade, parts = r.parts }
end

function M.recentNotes(t)
  local n = t.score.notes
  local out = {}
  for i = math.max(1, #n - 2), #n do out[#out + 1] = n[i] end
  return out
end

function M.result(t) return t.result or scoring.result(t.score) end

return M
