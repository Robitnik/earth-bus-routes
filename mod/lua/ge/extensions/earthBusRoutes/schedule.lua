-- Timetable generator. OSM almost never says how often a line runs (Náchod: 0 of 11 routes), so the timetable is
-- generated from the line's kind and length; `interval`, `duration` and a simple `opening_hours` window in the tags win.
-- Deterministic: the same route and day always give the same timetable. Pure logic.
-- All times are seconds from midnight, "day" is 1 (Monday) .. 7 (Sunday).
local geo = require('earthBusRoutes/geomath')
local M = {}

-- Day periods (hours): 1 05-06, 2 06-09 peak, 3 09-15, 4 15-18 peak, 5 18-21, 6 21-24, 7 00-05
M.PERIODS = { { 5, 6 }, { 6, 9 }, { 9, 15 }, { 15, 18 }, { 18, 21 }, { 21, 24 }, { 0, 5 } }
M.PEAK = { [2] = true, [4] = true }
-- Minutes between buses; false = no service in that period
M.INTERVALS = {
  main     = { 15, 7.5, 10, 7.5, 15, 20, false },
  city     = { 20, 12, 20, 12, 30, 40, false },
  regional = { 60, 30, 60, 30, 60, 120, false },
  night    = { false, false, false, false, false, 30, 60 },
}
-- Average moving speed (km/h, traffic lights and queues included) and dwell at a stop (s)
M.SPEED = { main = 20, city = 21, regional = 36, night = 27 }
M.DWELL, M.DWELL_STATION = 20, 40
M.STOP_LOSS_S = 15           -- slowing down for a stop and getting going again, on top of the standing

-- Average speed (km/h) between two stops d metres apart: short legs are town streets, long ones are open road.
function M.legSpeed(kind, d)
  if kind == 'regional' then
    if d < 500 then return 20 elseif d < 1200 then return 30 elseif d < 2500 then return 42 elseif d < 5000 then return 52 end
    return 60
  end
  local v
  if d < 300 then v = 16 elseif d < 700 then v = 19 else v = 24 end
  if kind == 'main' then v = v * 0.95 elseif kind == 'night' then v = v * 1.25 end
  return v
end
M.WEEKEND_STRETCH = 1.5

local function hash(s)
  local h = 5381
  for i = 1, #(s or '') do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end

function M.isWeekend(day) return day >= 6 end

function M.periodAt(sec)
  local h = (sec / 3600) % 24
  for i, p in ipairs(M.PERIODS) do
    if h >= p[1] and h < p[2] then return i end
  end
  return 7
end

-- "10", "00:30", "01:00:00" -> seconds; nil when not understood
local function parseClock(v)
  if type(v) ~= 'string' then return type(v) == 'number' and v * 60 or nil end
  local h, m, s = v:match('^(%d+):(%d+):?(%d*)$')
  if h then return tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(s) or 0) end
  local n = tonumber(v)
  if n then return n * 60 end
end
M.parseClock = parseClock

-- First "HH:MM-HH:MM" of an opening_hours value as seconds (from, to); nil when there is none.
function M.parseWindow(v)
  if type(v) ~= 'string' then return nil end
  local a, b, c, d = v:match('(%d%d?):(%d%d)%s*%-%s*(%d%d?):(%d%d)')
  if not a then return nil end
  local from, to = tonumber(a) * 3600 + tonumber(b) * 60, tonumber(c) * 3600 + tonumber(d) * 60
  if to <= from then to = 24 * 3600 end
  return from, to
end

-- The kind used for the interval table: a busy city line is "main". ctx.busy = the line's stops are shared with many others.
function M.kindOf(route, ctx)
  local k = route.kind or 'city'
  if k == 'city' and ctx and ctx.busy then return 'main' end
  return k
end

-- Seconds between buses for the period (nil = none), after the tags and the weekend rule
function M.intervalFor(route, kind, period, weekend, ctx)
  local tags = route.tags or {}
  local row = M.INTERVALS[kind] or M.INTERVALS.city
  local iv = row[period]
  if weekend and M.PEAK[period] then iv = row[3] end         -- no rush hour at the weekend
  local tagged = parseClock(tags.interval)
  if tagged and tagged > 0 then
    if iv == false and kind ~= 'night' then return nil end
    return tagged
  end
  if not iv then return nil end
  iv = iv * 60
  if weekend then iv = iv * M.WEEKEND_STRETCH end
  return iv
end

-- Seconds to ride between consecutive stops and stand at each, for a trip leaving at `startSec`.
-- Returns arr[i], dep[i] (seconds after the trip's start; arr[1] = 0, dep[1] = the dwell at the terminus).
function M.runTimes(route, kind, startSec, ctx)
  local stops = route.stops
  local h = (startSec / 3600) % 24
  local factor = 1
  if (h >= 7 and h < 9) or (h >= 15 and h < 18) then factor = 1.15 elseif h >= 22 or h < 5 then factor = 0.9 end
  local arr, dep = { 0 }, { M.DWELL }           -- the bus is at the terminus at `start` and leaves after its dwell
  local t = M.DWELL
  for i = 2, #stops do
    local d = math.max(0, stops[i].along - stops[i - 1].along)
    t = t + d / (M.legSpeed(kind, d) / 3.6) * factor + M.STOP_LOSS_S
    arr[i] = t
    local dwell = (i == #stops) and 0 or ((ctx and ctx.station and ctx.station[i]) and M.DWELL_STATION or M.DWELL)
    t = t + dwell
    dep[i] = t
  end
  local want = parseClock((route.tags or {}).duration)
  if want and want > 0 and arr[#arr] > 0 then
    local k = want / arr[#arr]
    for i = 1, #arr do arr[i], dep[i] = arr[i] * k, dep[i] * k end
  end
  return arr, dep
end

-- All trips of the day: { { id, start (s), arr = {..}, dep = {..} } ... } leaving the first stop.
-- `reverse` shifts the phase so the two directions do not leave their ends at the same minute.
function M.generate(route, day, ctx)
  local kind = M.kindOf(route, ctx)
  -- the real timetable (a line of the national feed): its departures of this weekday, each stop at its own time
  local real = route.gtfsOffs and route.gtfsStarts and route.gtfsStarts[tostring(day)]
  if real and #real > 0 and #route.gtfsOffs == #route.stops then
    local trips = {}
    for _, st in ipairs(real) do
      local arr, dep = {}, {}
      for i, o in ipairs(route.gtfsOffs) do arr[i], dep[i] = o, o end
      trips[#trips + 1] = { id = #trips + 1, start = st, arr = arr, dep = dep }
    end
    return trips, kind
  end
  local weekend = M.isWeekend(day)
  local seed = hash((route.ref or '') .. '|' .. tostring(route.id or '') .. '|' .. (route.network or ''))
  local winFrom, winTo = 0, 24 * 3600
  local ow = (route.tags or {}).opening_hours
  local f, t = M.parseWindow(ow)
  if f then winFrom, winTo = f, t end
  local trips = {}
  for pi, p in ipairs(M.PERIODS) do
    local iv = M.intervalFor(route, kind, pi, weekend, ctx)
    if iv then
      local from, to = math.max(p[1] * 3600, winFrom), math.min(p[2] * 3600, winTo)
      local step = (iv >= 600) and 300 or 60                      -- real timetables use round minutes
      local offset = (seed % math.max(1, math.floor(iv / step))) * step
      local k = 0
      while true do
        local dep = from + offset + k * iv
        if dep >= to then break end
        if iv >= 600 then dep = math.floor(dep / 300 + 0.5) * 300 else dep = math.floor(dep / 30 + 0.5) * 30 end
        if dep >= from and (#trips == 0 or dep > trips[#trips].start) then
          local arr, dp = M.runTimes(route, kind, dep, ctx)
          trips[#trips + 1] = { id = #trips + 1, start = dep, arr = arr, dep = dp }
        end
        k = k + 1
      end
    end
  end
  return trips, kind
end

-- Departures from stop `index` at or after `fromSec`: the next `n` as { trip, at (departure s), arrive (s) }.
function M.departures(trips, index, fromSec, n)
  local out = {}
  for _, tr in ipairs(trips) do
    local at = tr.start + (tr.dep[index] or 0)
    if at >= fromSec then
      out[#out + 1] = { trip = tr, at = at, arrive = tr.start + (tr.arr[index] or 0) }
      if #out >= (n or 5) then break end
    end
  end
  return out
end

-- Next trip when none is left today: the first one tomorrow (day + 1) => caller handles; returns nil, why here.
function M.nextTrip(trips, index, fromSec)
  local d = M.departures(trips, index, fromSec, 1)[1]
  if d then return d end
  return nil, 'no more trips today'
end

-- Scheduled time (s from midnight) a trip reaches stop `index`
function M.scheduled(trip, index) return trip.start + (trip.arr[index] or 0) end

-- Interval (s) around the time, for the line's info card: { {from,to,minutes} ... } for the day
function M.summary(route, day, ctx)
  local kind = M.kindOf(route, ctx)
  local out = {}
  for pi, p in ipairs(M.PERIODS) do
    local iv = M.intervalFor(route, kind, pi, M.isWeekend(day), ctx)
    out[#out + 1] = { from = p[1], to = p[2], minutes = iv and iv / 60 or nil, peak = M.PEAK[pi] or false }
  end
  return out
end

return M
