-- "Next trip from here" (plan 006, idea 11): the earliest departure from the stop the player stands at, over every line that
-- starts there or calls there, as one card at the top of the Stops tab. Pure logic (tests/test_quick.lua): main.lua loads the
-- routes (the data service), this module picks the departure and adjusts the trip plan for the one-press start.
local schedule = require('earthBusRoutes/schedule')
local menu = require('earthBusRoutes/menu')
local M = {}

M.NEAR_M = 150          -- the card is for the stop the player stands at: the nearest station within this many metres
M.STOP_M = 250          -- a route calls "here" when one of its stops is this near the station (as the menu's own "from here")
M.MAX_LOAD = 8          -- routes loaded for the card (round robin over the lines; one request each, cached by the service)
M.WAIT_MAX_MIN = 20     -- a departure up to this many minutes away is waited for at the stop; a later one moves the clock to it
M.PREFER_S = 120        -- a departure that starts here beats one that only passes through unless it is this much later

local DAY = 86400

-- The variants of the lines at a station worth loading, as menu.linesModel lists them: the ones that start here first, then the
-- ones that pass, round robin over the lines so a busy station shows its different lines early. Variants that certainly end
-- here are left out. -> { { id, place, ref } ... }
function M.variants(lines, max)
  max = max or M.MAX_LOAD
  local rank = { from = 1, loop = 1, through = 2 }
  local per = {}
  for li, ln in ipairs(lines or {}) do
    local list = {}
    for _, v in ipairs(ln.variants or {}) do
      if v.place ~= 'to' or v.approx then list[#list + 1] = { id = v.id, place = v.place, ref = ln.ref, r = (v.place == 'to') and 3 or rank[v.place] or 2, o = #list } end
    end
    table.sort(list, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.o < b.o end)
    per[li] = list
  end
  local out = {}
  local k = 1
  while #out < max do
    local took = false
    for li = 1, #per do
      local v = per[li][k]
      if v and #out < max then out[#out + 1] = v took = true end
    end
    if not took then break end
    k = k + 1
  end
  return out
end

-- A loaded route as a candidate for the card, or nil when it does not call at the station (or only ends there).
-- station = { lat, lon }; ctx = the timetable context the menu uses for the line (busy lines run more often).
function M.candidate(route, station, ctx)
  if not (route and route.stops and #route.stops >= 2 and station) then return nil end
  local idx, d = menu.nearestStopIndex(route, station.lat, station.lon)
  if d > M.STOP_M then return nil end
  local n = #route.stops
  if route.loop and idx == n then idx = 1 end                     -- a circular line leaves from where it begins
  local place = route.loop and 'loop' or (idx == 1 and 'from') or (idx == n and 'to') or 'through'
  if place == 'to' then return nil end
  return { route = route, idx = idx, place = place, ctx = ctx, trips = {} }
end

local function tripsOf(c, day)
  local t = c.trips[day]
  if not t then t = schedule.generate(c.route, day, c.ctx) or {} c.trips[day] = t end
  return t
end

local function nextDay(day) return day % 7 + 1 end

-- The earliest departure from the station among the candidates, now = time of day (s), day = 1 (Monday) .. 7.
-- After the last departure of the day the first one of tomorrow is taken. nil when no candidate has any.
function M.pick(cands, now, day)
  local rows = {}
  for _, c in ipairs(cands or {}) do
    local row
    local d = schedule.departures(tripsOf(c, day), c.idx, now, 1)[1]
    if d then
      row = { c = c, d = d, abs = d.at, tomorrow = false }
    else
      local d2 = schedule.departures(tripsOf(c, nextDay(day)), c.idx, 0, 1)[1]
      if d2 then row = { c = c, d = d2, abs = d2.at + DAY, tomorrow = true } end
    end
    if row then rows[#rows + 1] = row end
  end
  if #rows == 0 then return nil end
  table.sort(rows, function(a, b)
    if a.abs ~= b.abs then return a.abs < b.abs end
    local ra, rb = a.c.place == 'through' and 2 or 1, b.c.place == 'through' and 2 or 1
    if ra ~= rb then return ra < rb end
    return (a.c.route.id or 0) < (b.c.route.id or 0)
  end)
  local best = rows[1]
  if best.c.place == 'through' then
    for _, r in ipairs(rows) do
      if r.c.place ~= 'through' and r.abs <= best.abs + M.PREFER_S then best = r break end
    end
  end
  local route = best.c.route
  return {
    routeId = route.id, ref = route.ref, colour = route.colour, to = route.to or route.name, from = route.from,
    stopName = route.stops[best.c.idx].name, idx = best.c.idx, place = best.c.place,
    tripId = best.d.trip.id, trip = best.d.trip, abs = best.abs, sec = best.abs % DAY, label = menu.clockLabel(best.abs),
    tomorrow = best.tomorrow, secLeft = best.abs - now,
    source = route.timetable == 'gtfs' and 'gtfs' or 'generated',
  }
end

-- What the menu card shows (no tables of the route): the minutes are counted from `now`
function M.model(q, now)
  if not q then return nil end
  local left = math.max(0, q.abs - now)
  return {
    routeId = q.routeId, ref = q.ref, colour = q.colour, to = q.to, from = q.from, stopName = q.stopName,
    label = q.label, inMin = math.floor(left / 60 + 0.5), wait = left / 60 <= M.WAIT_MAX_MIN, tomorrow = q.tomorrow,
    place = q.place, source = q.source,
  }
end

local function shifted(trip, by)
  return { id = trip.id, start = trip.start + by, arr = trip.arr, dep = trip.dep }
end

-- The trip plan (main.lua's buildPlan) set up for the chosen departure. A departure within WAIT_MAX_MIN is waited for: the
-- clock stays where it is, the trip starts standing at the stop and the first arrival counts as on time (plan.waitStart); a
-- later one moves the clock to the departure, as picking a time in the menu does.
function M.adjustPlan(plan, q, now)
  plan.startIndex = q.idx
  if (q.abs - now) / 60 <= M.WAIT_MAX_MIN then
    plan.waitStart = true
    plan.entry = { trip = q.tomorrow and shifted(q.trip, DAY) or q.trip, at = q.abs }
    plan.clock = now
  else
    plan.entry = { trip = q.trip, at = q.sec }
    plan.clock = schedule.scheduled(q.trip, q.idx)
  end
  return plan
end

return M
