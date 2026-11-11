-- Career and collection: the player's profile (profile.json, format 2), earnings, ranks, the driven-lines layer of the map and the
-- achievements. Pure logic: no game calls, so the tests run it under lupa. The game side (files, HUD toast) is careersvc.lua.
--
-- The career never takes anything away: every line stays open in free play. It only counts what was driven and opens its own
-- shifts (rank -> M.unlocks(rank)).
--
-- Records fed to the career (all fields optional):
--   trip  (M.recordTrip):  { key, ref, from, to, kind ('city'|'regional'|'night'), points, grade, passengers, revenue, hours, km,
--                            punctuality (0..1, nil off the timetable), scheduled, allOnTime, smooth, stops = { {name, town, country, lat, lon,
--                            station} }, track = flat E4 ints, inShift (the shift pays, not the trip), transfersWaited, ghostDeltaSec, at }
--   shift (M.recordShift): { hours, trips, passengers, punctuality, grade, revenue, smooth, at }   <- what stage B's summary calls
local M = {}

M.FORMAT = 2
M.HOURLY_RATE = 12                                    -- credits per hour of a shift (in-game credits, no real currency)
M.GRADE_BONUS = { S = 1.5, A = 1.25, B = 1.0, C = 0.8, D = 0.6 }
M.GRADE_VALUE = { S = 4, A = 3, B = 2, C = 1, D = 0 }
M.GRADE_LETTER = { 'D', 'C', 'B', 'A', 'S' }          -- by value + 1
M.RECENT = 10                                         -- the grade average looks at this many last shifts

-- Ranks: shift-hours and the average grade of the last RECENT shifts. `unlocks` is what the career opens (for the shifts of stage B).
M.RANKS = {
  { id = 'trainee', hours = 0, grade = nil, unlocks = { lines = { 'city' }, shiftHours = 1, depot = false, night = false, heavyEvents = false } },
  { id = 'driver', hours = 3, grade = 'C', unlocks = { lines = { 'city', 'suburban' }, shiftHours = 2, depot = false, night = false, heavyEvents = false } },
  { id = 'experienced', hours = 10, grade = 'B', unlocks = { lines = { 'city', 'suburban', 'intercity' }, shiftHours = 4, depot = true, night = false, heavyEvents = false } },
  { id = 'mentor', hours = 25, grade = 'A', unlocks = { lines = { 'city', 'suburban', 'intercity', 'night' }, shiftHours = 4, depot = true, night = true, heavyEvents = true } },
}

M.SPACING_M = 200                                     -- a point of a driven line per this many metres
M.TRACK_BUDGET = 1800000                              -- bytes of tracks in profile.json (the whole file stays about 2 MB)
M.BYTES_PER_INT = 7
M.JUMP_M = 500                                        -- a step between two samples longer than this is a jump (teleport): not driven

local floor, max, min, abs, sqrt, cos = math.floor, math.max, math.min, math.abs, math.sqrt, math.cos
local rad = math.pi / 180
local function round(x, d) local m = 10 ^ (d or 0) return floor(x * m + 0.5) / m end
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
local function e4(x) return floor(x * 1e4 + 0.5) end

-- ---- the profile ---------------------------------------------------------------------------------------------------

function M.new()
  return {
    format = M.FORMAT,
    totals = { trips = 0, passengers = 0, points = 0, km = 0, hours = 0, revenue = 0, punctSum = 0, punctN = 0 },
    shifts = { count = 0, hours = 0, recent = {}, trips = 0 },
    credits = 0, rank = 'trainee',
    best = {}, counters = {}, ach = {},
    towns = {}, stations = {}, countries = {},
    tracks = {},
  }
end

-- stats.json (what versions before 0.14 wrote: { trips, passengers, points, best }) -> a profile; the records are kept
function M.migrate(stats)
  local p = M.new()
  if type(stats) ~= 'table' then return p end
  p.totals.trips = tonumber(stats.trips) or 0
  p.totals.passengers = tonumber(stats.passengers) or 0
  p.totals.points = tonumber(stats.points) or 0
  if type(stats.best) == 'table' then
    for k, v in pairs(stats.best) do
      if type(v) == 'table' then p.best[k] = { points = v.points, grade = v.grade, ref = v.ref, from = v.from, to = v.to } end
    end
  end
  p.migrated = true
  return p
end

-- Fills what a profile written by another version may lack
function M.normalize(p)
  if type(p) ~= 'table' then return M.new() end
  local base = M.new()
  for k, v in pairs(base) do if type(p[k]) ~= type(v) then p[k] = v end end
  for k, v in pairs(base.totals) do if type(p.totals[k]) ~= 'number' then p.totals[k] = v end end
  for k, v in pairs(base.shifts) do if type(p.shifts[k]) ~= type(v) then p.shifts[k] = v end end
  p.format = M.FORMAT
  if not M.rankIndex(p.rank) then p.rank = 'trainee' end
  return p
end

-- readFn(path) -> table or nil. profile.json first, else the old stats.json (migrated), else a new profile. Second result: migrated.
function M.load(readFn, profilePath, statsPath)
  local ok, p = pcall(readFn, profilePath)
  if ok and type(p) == 'table' and p.format == M.FORMAT then return M.normalize(p), false end
  local ok2, st = pcall(readFn, statsPath)
  if ok2 and type(st) == 'table' then return M.normalize(M.migrate(st)), true end
  return M.new(), false
end

function M.save(writeFn, path, p)
  p.migrated = nil
  return pcall(writeFn, path, p, false)        -- compact: the tracks are long lists
end

-- what the older code showed: { trips, passengers, points }
function M.statsOf(p) return { trips = p.totals.trips, passengers = p.totals.passengers, points = p.totals.points } end

-- ---- earnings and ranks --------------------------------------------------------------------------------------------

-- (hours of the shift * hourly rate + revenue) * the grade's bonus, whole credits
function M.earnings(hours, revenue, grade)
  local mult = M.GRADE_BONUS[grade or 'C'] or 1
  return floor(((hours or 0) * M.HOURLY_RATE + (revenue or 0)) * mult + 0.5)
end

function M.rankIndex(id)
  for i, r in ipairs(M.RANKS) do if r.id == id then return i end end
end

function M.unlocks(id) local i = M.rankIndex(id) return i and M.RANKS[i].unlocks or M.RANKS[1].unlocks end

-- average grade value (0..4) of the last RECENT shifts; nil without shifts
function M.averageGrade(p)
  local r = p.shifts.recent
  if #r == 0 then return nil end
  local s = 0
  for _, g in ipairs(r) do s = s + (M.GRADE_VALUE[g] or 0) end
  return s / #r
end

function M.gradeLetter(avg) return avg and M.GRADE_LETTER[max(0, min(4, floor(avg + 0.5))) + 1] or nil end

-- the highest rank the numbers allow
local function rankFor(hours, avg)
  local best = 1
  for i, r in ipairs(M.RANKS) do
    if hours >= r.hours and (r.grade == nil or (avg ~= nil and avg >= M.GRADE_VALUE[r.grade])) then best = i end
  end
  return best
end

-- A rank once reached is kept (the average moves up and down). Returns the new rank's id when it went up.
function M.updateRank(p)
  local i = rankFor(p.shifts.hours, M.averageGrade(p))
  local cur = M.rankIndex(p.rank) or 1
  if i > cur then p.rank = M.RANKS[i].id return p.rank end
end

-- the rank, and the way to the next one
function M.rankInfo(p)
  local i = M.rankIndex(p.rank) or 1
  local avg = M.averageGrade(p)
  local info = { id = p.rank, index = i, hours = round(p.shifts.hours, 1), avg = avg and round(avg, 2) or nil, avgLetter = M.gradeLetter(avg),
    unlocks = M.RANKS[i].unlocks }
  local nxt = M.RANKS[i + 1]
  if nxt then
    info.next = nxt.id
    info.hoursNeed = nxt.hours
    info.gradeNeed = nxt.grade
    info.hoursPct = min(1, p.shifts.hours / nxt.hours)
    info.gradeOk = avg ~= nil and avg >= (M.GRADE_VALUE[nxt.grade] or 0)
    info.progress = info.hoursPct * (info.gradeOk and 1 or 0.9)       -- the bar stops short of full while the grade is not there
  else
    info.progress = 1
  end
  return info
end

-- ---- a trip's driven line and visits (kept by the host while the trip runs) --------------------------------------------

local geo = require('earthBusRoutes/geomath')

function M.runNew() return { p = {}, meters = 0, stops = {}, seen = {} } end

-- One sample of the bus. Adds a point to the line every SPACING_M metres and counts the distance driven.
function M.runSample(run, lat, lon)
  if type(lat) ~= 'number' or type(lon) ~= 'number' then return end
  local last = run.last
  if last then
    local d = geo.dist(last[1], last[2], lat, lon)
    if d <= M.JUMP_M then run.meters = run.meters + d end
  end
  run.last = { lat, lon }
  local n = #run.p
  if n == 0 or geo.dist(run.p[n - 1] * 1e-4, run.p[n] * 1e-4, lat, lon) >= M.SPACING_M then
    run.p[n + 1], run.p[n + 2] = e4(lat), e4(lon)
  end
end

-- The end of the line (so it reaches the last stop)
function M.runFinish(run)
  local last = run.last
  if not last then return end
  local n = #run.p
  if n == 0 or run.p[n - 1] ~= e4(last[1]) or run.p[n] ~= e4(last[2]) then run.p[n + 1], run.p[n + 2] = e4(last[1]), e4(last[2]) end
end

-- The bus stopped at a stop: { name, town, country, lat, lon, station }
function M.runStop(run, s)
  if type(s) ~= 'table' or not s.name or run.seen[s.name] then return end
  run.seen[s.name] = true
  run.stops[#run.stops + 1] = { name = s.name, town = s.town, country = s.country, lat = s.lat, lon = s.lon, station = s.station and true or false }
end

-- The record of a finished trip from the trip object (route, clock) and its result (scoring.result)
function M.tripRecord(run, t, res)
  local route = t.route or {}
  local parts = res.parts or {}
  local scheduled = t.entry ~= nil
  local punct = scheduled and parts.punctuality or nil
  M.runFinish(run)
  return {
    key = tostring(route.ref) .. '|' .. tostring(route.network or ''),
    ref = route.ref, from = route.from, to = route.to, kind = route.kind,
    points = res.points, grade = res.grade, passengers = res.passengers, revenue = res.revenue,
    hours = max(0, (t.clock or 0) - (t.clock0 or 0)) / 3600, km = run.meters / 1000,
    scheduled = scheduled, punctuality = punct,
    allOnTime = scheduled and (parts.punctuality or 0) >= 0.999 and (res.served or 0) >= 3 and (res.missed or 0) == 0 or false,
    smooth = (parts.comfort or 0) >= 0.999 and run.meters >= 5000,
    stops = run.stops, track = run.p,
  }
end

-- ---- simplifying the driven lines ----------------------------------------------------------------------------------------

-- Douglas-Peucker on a flat list of E4 ints { lat, lon, lat, lon, ... }; tolM metres. Keeps the ends.
function M.simplify(p, tolM)
  local n = floor(#p / 2)
  if n <= 2 then local c = {} for i = 1, #p do c[i] = p[i] end return c end
  local kx = 111320 * cos(p[1] * 1e-4 * rad) * 1e-4
  local ky = 110574 * 1e-4
  local xs, ys = {}, {}
  for i = 1, n do xs[i], ys[i] = p[2 * i] * kx, p[2 * i - 1] * ky end
  local keep = { [1] = true, [n] = true }
  local stack = { { 1, n } }
  while #stack > 0 do
    local seg = table.remove(stack)
    local a, b = seg[1], seg[2]
    if b - a > 1 then
      local ax, ay, dx, dy = xs[a], ys[a], xs[b] - xs[a], ys[b] - ys[a]
      local len2 = dx * dx + dy * dy
      local far, farD = nil, tolM
      for i = a + 1, b - 1 do
        local d
        if len2 < 1e-9 then
          d = sqrt((xs[i] - ax) ^ 2 + (ys[i] - ay) ^ 2)
        else
          local u = max(0, min(1, ((xs[i] - ax) * dx + (ys[i] - ay) * dy) / len2))
          d = sqrt((xs[i] - ax - u * dx) ^ 2 + (ys[i] - ay - u * dy) ^ 2)
        end
        if d > farD then far, farD = i, d end
      end
      if far then
        keep[far] = true
        stack[#stack + 1] = { a, far }
        stack[#stack + 1] = { far, b }
      end
    end
  end
  local out = {}
  for i = 1, n do if keep[i] then out[#out + 1], out[#out + 2] = p[2 * i - 1], p[2 * i] end end
  return out
end

function M.trackBytes(p)
  local b = 0
  for _, tr in ipairs(p.tracks) do b = b + #tr.p * M.BYTES_PER_INT + 30 end
  return b
end

-- Over the budget: the oldest lines are simplified harder (a coarser tolerance each round), and when even that does not do it the
-- oldest ones go.
function M.compact(p, budget)
  budget = budget or M.TRACK_BUDGET
  if M.trackBytes(p) <= budget then return false end
  for _, tol in ipairs({ 300, 600, 1200, 2500, 5000 }) do
    for _, tr in ipairs(p.tracks) do                            -- oldest first
      if (tr.tol or 0) < tol then tr.p, tr.tol = M.simplify(tr.p, tol), tol end
      if M.trackBytes(p) <= budget then return true end
    end
  end
  while #p.tracks > 0 and M.trackBytes(p) > budget do table.remove(p.tracks, 1) end
  return true
end

-- length in metres of a flat E4 line
function M.length(flat)
  local d = 0
  for i = 3, #flat - 1, 2 do d = d + geo.dist(flat[i - 2] * 1e-4, flat[i - 1] * 1e-4, flat[i] * 1e-4, flat[i + 1] * 1e-4) end
  return d
end

-- One line per route: a new drive replaces the old one when it covers at least 80 % of it (and moves to the newest end)
local function storeTrack(p, key, ref, flat)
  if type(flat) ~= 'table' or #flat < 4 then return end
  for i, tr in ipairs(p.tracks) do
    if tr.k == key then
      if M.length(flat) >= 0.8 * M.length(tr.p) then table.remove(p.tracks, i) break end
      return
    end
  end
  p.tracks[#p.tracks + 1] = { k = key, ref = ref, p = flat }
  M.compact(p)
end

-- ---- achievements --------------------------------------------------------------------------------------------------------

-- check(c): c = { p = profile (already updated), rec = the trip's record or nil, shift = the shift's record or nil }.
-- `name` is the English title (the UI has both languages in i18n.js under "ach.<id>" / "ach.<id>.d").
local function rankAtLeast(p, id) return (M.rankIndex(p.rank) or 1) >= M.rankIndex(id) end
M.ACHIEVEMENTS = {
  { id = 'first_trip', name = 'First trip', check = function(c) return c.p.totals.trips >= 1 end },
  { id = 'trips_10', name = '10 trips', check = function(c) return c.p.totals.trips >= 10 end },
  { id = 'trips_100', name = '100 trips', check = function(c) return c.p.totals.trips >= 100 end },
  { id = 'on_time_all', name = 'Every stop on time', check = function(c) return c.rec ~= nil and c.rec.allOnTime == true end },
  { id = 'night_line', name = 'Night line', check = function(c) return c.rec ~= nil and (c.rec.kind == 'night') end },
  { id = 'km_100_trip', name = '100 km in one trip', check = function(c) return c.rec ~= nil and (c.rec.km or 0) >= 100 end },
  { id = 'km_1000', name = '1000 km driven', check = function(c) return c.p.totals.km >= 1000 end },
  { id = 'towns_10', name = '10 towns', check = function(c) return count(c.p.towns) >= 10 end },
  { id = 'towns_50', name = '50 towns', check = function(c) return count(c.p.towns) >= 50 end },
  { id = 'countries_3', name = '3 countries', check = function(c) return count(c.p.countries) >= 3 end },
  { id = 'transfers_10', name = 'Waited for a connection 10 times', check = function(c) return (c.p.counters.transfersWaited or 0) >= 10 end },
  { id = 'smooth_trip', name = 'A smooth ride', check = function(c) return c.rec ~= nil and c.rec.smooth == true end },
  { id = 'smooth_shift', name = 'A shift without a jolt', check = function(c) return c.shift ~= nil and c.shift.smooth == true end },
  { id = 'first_s', name = 'First S', check = function(c) return (c.rec ~= nil and c.rec.grade == 'S') or (c.shift ~= nil and c.shift.grade == 'S') end },
  { id = 'ghost_beat', name = 'Beat your ghost by a minute', check = function(c) return c.rec ~= nil and (c.rec.ghostDeltaSec or 0) >= 60 end },
  { id = 'pax_1000', name = '1000 passengers', check = function(c) return c.p.totals.passengers >= 1000 end },
  { id = 'records_5', name = 'Records on 5 lines', check = function(c) return count(c.p.best) >= 5 end },
  { id = 'regional_10', name = '10 regional trips', check = function(c) return (c.p.counters.regional or 0) >= 10 end },
  { id = 'city_20', name = '20 city trips', check = function(c) return (c.p.counters.city or 0) >= 20 end },
  { id = 'first_shift', name = 'First shift', check = function(c) return c.p.shifts.count >= 1 end },
  { id = 'shifts_10', name = '10 shifts', check = function(c) return c.p.shifts.count >= 10 end },
  { id = 'rank_driver', name = 'Driver', check = function(c) return rankAtLeast(c.p, 'driver') end },
  { id = 'rank_experienced', name = 'Experienced', check = function(c) return rankAtLeast(c.p, 'experienced') end },
  { id = 'rank_mentor', name = 'Mentor', check = function(c) return rankAtLeast(c.p, 'mentor') end },
  { id = 'credits_5000', name = '5000 credits earned', check = function(c) return c.p.credits >= 5000 end },
}

-- Unlocks what the numbers now allow; returns the ids newly unlocked (a failing check is skipped, never fatal)
function M.evaluate(p, rec, shift)
  local out = {}
  local c = { p = p, rec = rec, shift = shift }
  for _, a in ipairs(M.ACHIEVEMENTS) do
    if not p.ach[a.id] then
      local ok, yes = pcall(a.check, c)
      if ok and yes then
        p.ach[a.id] = (rec and rec.at) or (shift and shift.at) or 0
        out[#out + 1] = a.id
      end
    end
  end
  return out
end

function M.achievementName(id)
  for _, a in ipairs(M.ACHIEVEMENTS) do if a.id == id then return a.name end end
end

-- ---- recording -------------------------------------------------------------------------------------------------------------

local function townOf(s)
  if s.town and s.town ~= '' then return s.town end
  local head = tostring(s.name or ''):match('^%s*([^,]+),')
  return head and (head:gsub('%s+$', '')) or nil
end

local function noteVisits(p, rec)
  for _, s in ipairs(rec.stops or {}) do
    local town = townOf(s)
    if town and type(s.lat) == 'number' then
      local t = p.towns[town] or { la = e4(s.lat), lo = e4(s.lon), n = 0 }
      t.n = t.n + 1
      p.towns[town] = t
    end
    if s.station and s.name and type(s.lat) == 'number' then
      local t = p.stations[s.name] or { la = e4(s.lat), lo = e4(s.lon), n = 0 }
      t.n = t.n + 1
      p.stations[s.name] = t
    end
    if s.country and s.country ~= '' then p.countries[s.country] = (p.countries[s.country] or 0) + 1 end
  end
end

-- A finished trip. opts.light: only the totals and the records (the career feature is off in the options).
-- Returns { record, previous, earned, unlocked = { ids }, rankUp = id or nil, totals }.
function M.recordTrip(p, rec, opts)
  rec = rec or {}
  opts = opts or {}
  local tot = p.totals
  tot.trips = tot.trips + 1
  tot.passengers = tot.passengers + (rec.passengers or 0)
  tot.points = tot.points + (rec.points or 0)
  local key = rec.key or (tostring(rec.ref) .. '|')
  local prev = p.best[key]
  local points = rec.points or 0
  local record = (not prev) or points > (prev.points or 0)
  if record then p.best[key] = { points = points, grade = rec.grade, ref = rec.ref, from = rec.from, to = rec.to } end
  local res = { record = record, previous = prev and prev.points or nil, earned = 0, unlocked = {}, totals = M.statsOf(p) }
  if opts.light then return res end

  tot.km = round(tot.km + (rec.km or 0), 2)
  tot.hours = round(tot.hours + (rec.hours or 0), 3)
  tot.revenue = round(tot.revenue + (rec.revenue or 0), 2)
  if rec.punctuality then tot.punctSum, tot.punctN = tot.punctSum + rec.punctuality, tot.punctN + 1 end
  local kind = rec.kind == 'night' and 'night' or rec.kind == 'regional' and 'regional' or 'city'
  p.counters[kind] = (p.counters[kind] or 0) + 1
  p.counters.transfersWaited = (p.counters.transfersWaited or 0) + (rec.transfersWaited or 0)
  noteVisits(p, rec)
  if rec.track then storeTrack(p, key, rec.ref, rec.track) end
  if not rec.inShift then                       -- a trip inside a shift is paid with the shift
    res.earned = M.earnings(rec.hours, rec.revenue, rec.grade)
    p.credits = p.credits + res.earned
  end
  res.rankUp = M.updateRank(p)
  res.unlocked = M.evaluate(p, rec, nil)
  return res
end

-- A finished shift (stage B calls this from its summary). Its trips were counted one by one when they finished, so only what is
-- a shift's own is added: the count, the hours, the grade for the rank and the pay. Returns { earned, unlocked, rankUp, rank }.
function M.recordShift(p, rec)
  rec = rec or {}
  p.shifts.count = p.shifts.count + 1
  p.shifts.hours = round(p.shifts.hours + (rec.hours or 0), 3)
  p.shifts.trips = p.shifts.trips + (rec.trips or 0)
  if rec.grade then
    p.shifts.recent[#p.shifts.recent + 1] = rec.grade
    while #p.shifts.recent > M.RECENT do table.remove(p.shifts.recent, 1) end
  end
  local earned = M.earnings(rec.hours, rec.revenue, rec.grade)
  p.credits = p.credits + earned
  local rankUp = M.updateRank(p)
  local unlocked = M.evaluate(p, nil, rec)
  return { earned = earned, unlocked = unlocked, rankUp = rankUp, rank = M.rankInfo(p) }
end

-- ---- what the UI gets -------------------------------------------------------------------------------------------------------

-- Share of the stops on time over all trips that had a timetable, in %; nil before one
function M.onTimePct(p)
  local t = p.totals
  return t.punctN > 0 and round(t.punctSum / t.punctN * 100, 0) or nil
end

function M.model(p)
  local t = p.totals
  local records = {}
  for key, b in pairs(p.best) do
    records[#records + 1] = { key = key, ref = b.ref, from = b.from, to = b.to, points = b.points, grade = b.grade }
  end
  table.sort(records, function(a, b) if a.points ~= b.points then return (a.points or 0) > (b.points or 0) end return tostring(a.key) < tostring(b.key) end)
  while #records > 60 do table.remove(records) end
  local list, unlocked = {}, 0
  for _, a in ipairs(M.ACHIEVEMENTS) do
    local at = p.ach[a.id]
    if at then unlocked = unlocked + 1 end
    list[#list + 1] = { id = a.id, name = a.name, unlocked = at ~= nil, at = at or nil }
  end
  return {
    totals = { trips = t.trips, passengers = t.passengers, points = t.points, km = round(t.km, 1), hours = round(t.hours, 1), onTimePct = M.onTimePct(p),
      shifts = p.shifts.count, shiftHours = round(p.shifts.hours, 1), credits = p.credits, revenue = round(t.revenue, 0) },
    rank = M.rankInfo(p),
    records = records,
    achievements = list, unlockedCount = unlocked,
    visited = { towns = count(p.towns), stations = count(p.stations), countries = count(p.countries) },
  }
end

-- The layer of the minimap: the driven lines as [[lat, lon], ...] (at most maxPts points in all) and the places stopped at.
function M.mapLayer(p, maxPts)
  maxPts = maxPts or 1500
  local flats, total = {}, 0
  for i, tr in ipairs(p.tracks) do flats[i] = tr.p total = total + floor(#tr.p / 2) end
  local tol = 100
  while total > maxPts and tol <= 20000 do
    total = 0
    for i, tr in ipairs(p.tracks) do
      flats[i] = M.simplify(tr.p, tol)
      total = total + floor(#flats[i] / 2)
    end
    tol = tol * 2
  end
  local lines = {}
  for i, tr in ipairs(p.tracks) do
    local pts = {}
    for j = 1, floor(#flats[i] / 2) do pts[j] = { flats[i][2 * j - 1] * 1e-4, flats[i][2 * j] * 1e-4 } end
    lines[#lines + 1] = { ref = tr.ref, pts = pts }
  end
  local towns, stations = {}, {}
  for name, v in pairs(p.towns) do towns[#towns + 1] = { name = name, lat = v.la * 1e-4, lon = v.lo * 1e-4, n = v.n } end
  for name, v in pairs(p.stations) do stations[#stations + 1] = { name = name, lat = v.la * 1e-4, lon = v.lo * 1e-4, n = v.n } end
  table.sort(towns, function(a, b) return a.name < b.name end)
  table.sort(stations, function(a, b) return a.name < b.name end)
  return { lines = lines, towns = towns, stations = stations }
end

return M
