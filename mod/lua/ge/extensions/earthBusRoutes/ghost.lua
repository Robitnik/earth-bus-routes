-- The ghost of the best trip (pure: no game calls, the tests run it). While a trip is driven, the place of the bus along the
-- route (`along`, metres) is recorded once a second. The record of the best finished trip of "line + direction + first stop" is
-- kept, and the next trip of that line from that stop is raced against it: a translucent bus moves along the route as the
-- record did, and the time difference at the place the bus is at is shown ("+0:12" slower, "-0:07" faster).
-- Time is counted from the departure (the moment the bus has moved away from where the trip began), never from the clock of
-- the day, so a trip at 7:15 can be compared with one at 14:22 and the time spent boarding at the first stop does not count.
--
-- A record is a plain table for JSON (delta coded, about 3 bytes a second, so ~10 KB an hour):
--   { v = 1, key, ref, from, to, stop, points, grade, finished, dur, len, dt = 1, a0 = metres at the departure, d = { deltas } }
-- sample k (k = 0 ...) was taken k * dt seconds after the departure; its place is a0 + d[1] + ... + d[k] (d[1] is 0).
local M = {}

M.DT = 1                 -- seconds between two samples
M.MOVE_M = 5             -- the trip counts as departed when the bus has moved this far along the route
M.MAX_S = 6 * 3600       -- a longer trip is not recorded further (the file stays small)
M.MIN_S = 60             -- shorter or ...
M.MIN_M = 200            -- ... nearer records are not worth keeping
M.MAX_SAMPLES = M.MAX_S + 10

local function round(x) return math.floor(x + 0.5) end

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return ('%08x'):format(h)
end

-- The name of the record's file (without folder and extension): "line + direction + first stop", safe on any file system
function M.key(route, startIndex)
  local stop = route.stops and route.stops[startIndex or 1] or {}
  local raw = table.concat({ tostring(route.ref or ''), tostring(route.network or ''), tostring(route.from or ''),
    tostring(route.to or ''), tostring(startIndex or 1), tostring(stop.name or '') }, '|')
  local ascii = tostring(route.ref or 'line'):lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
  if ascii == '' then ascii = 'line' end
  return ascii:sub(1, 16) .. '-' .. hash(raw)
end

-- ---- recording -------------------------------------------------------------------------------------------------------

-- A recorder for a trip that begins at `along0` metres (the departure is found by the bus moving away from there)
function M.newRecorder(along0)
  return { start = along0 or 0, a0 = nil, t0 = nil, a = {}, last = nil, full = false }
end

-- Feed the elapsed time of the trip (s, any origin that only grows) and the place along the route (m). Samples are laid on
-- the second grid by straight lines between the feeds, so a slow frame leaves no holes.
function M.sample(rec, elapsed, along)
  if rec.full or type(along) ~= 'number' or type(elapsed) ~= 'number' then return end
  if not rec.t0 then
    if along - rec.start < M.MOVE_M then return end
    rec.t0, rec.a0 = elapsed, along          -- the first moment of the record: the bus has just moved off
    rec.a[1] = along
    rec.last = { t = elapsed, a = along }
  end
  local last = rec.last
  local t = elapsed - rec.t0
  if t <= last.t - rec.t0 then
    rec.last = { t = last.t, a = along }
    return
  end
  local nextK = #rec.a                         -- the sample to make next is at time nextK * DT
  while nextK * M.DT <= t do
    local tk = rec.t0 + nextK * M.DT
    local f = (tk - last.t) / (elapsed - last.t)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    rec.a[#rec.a + 1] = last.a + (along - last.a) * f
    nextK = #rec.a
    if nextK >= M.MAX_SAMPLES then rec.full = true break end
  end
  rec.last = { t = elapsed, a = along }
end

-- Seconds since the departure of the recorded trip (nil before it)
function M.elapsedOf(rec, elapsed)
  if not rec.t0 then return nil end
  return math.max(0, elapsed - rec.t0)
end

-- The record to keep, or nil when the trip was too short to be worth it. meta = { route, startIndex, points, grade, finished }
function M.finish(rec, meta)
  if not rec.t0 or #rec.a < 2 then return nil end
  local n = #rec.a
  local dur = (n - 1) * M.DT
  local dist = math.abs(rec.a[n] - rec.a[1])
  if dur < M.MIN_S or dist < M.MIN_M then return nil end
  local route = meta.route
  local d, prev = { 0 }, round(rec.a[1])
  for i = 2, n do
    local v = round(rec.a[i])
    d[i] = v - prev
    prev = v
  end
  local stop = route.stops and route.stops[meta.startIndex or 1] or {}
  return {
    v = 1, key = M.key(route, meta.startIndex), ref = route.ref, from = route.from, to = route.to, stop = stop.name,
    points = meta.points or 0, grade = meta.grade, finished = meta.finished == true, dur = dur, len = route.length,
    dt = M.DT, a0 = round(rec.a[1]), d = d,
  }
end

-- ---- reading ---------------------------------------------------------------------------------------------------------

-- A record from JSON back to the ghost: { a = absolute places, mx = running maximum, dt, points, ... } or nil, why
function M.decode(tbl)
  if type(tbl) ~= 'table' then return nil, 'not a table' end
  if tbl.v ~= 1 then return nil, 'unknown format' end
  local dt, a0, d = tbl.dt, tbl.a0, tbl.d
  if type(dt) ~= 'number' or dt <= 0 or type(a0) ~= 'number' or type(d) ~= 'table' then return nil, 'bad fields' end
  if #d < 2 or #d > M.MAX_SAMPLES then return nil, 'bad length' end
  local a, mx, cur = {}, {}, a0
  for i = 1, #d do
    local x = d[i]
    if type(x) ~= 'number' then return nil, 'bad sample' end
    cur = cur + x
    a[i] = cur
    mx[i] = (i > 1 and mx[i - 1] > cur) and mx[i - 1] or cur
  end
  return { a = a, mx = mx, dt = dt, dur = (#a - 1) * dt, points = tbl.points or 0, grade = tbl.grade, finished = tbl.finished == true,
    key = tbl.key, ref = tbl.ref, from = tbl.from, to = tbl.to, stop = tbl.stop, len = tbl.len }
end

-- JSON of a decoded ghost back (for tests and a re-save)
function M.encode(g)
  local d, prev = {}, g.a[1]
  for i = 1, #g.a do
    d[i] = i == 1 and 0 or (g.a[i] - prev)
    prev = g.a[i]
  end
  return { v = 1, key = g.key, ref = g.ref, from = g.from, to = g.to, stop = g.stop, points = g.points, grade = g.grade,
    finished = g.finished, dur = g.dur, len = g.len, dt = g.dt, a0 = g.a[1], d = d }
end

-- Where the ghost is `t` seconds after its departure (metres along the route); stands at the start before and at the end after
function M.alongAt(g, t)
  local x = (t or 0) / g.dt
  if x <= 0 then return g.a[1] end
  local n = #g.a
  if x >= n - 1 then return g.a[n] end
  local i = math.floor(x)
  local f = x - i
  return g.a[i + 1] + (g.a[i + 2] - g.a[i + 1]) * f
end

-- When the ghost first got to `along` (seconds after its departure), or nil when it never got there (it stood nearer the start,
-- or did not reach so far)
function M.timeAt(g, along)
  local mx = g.mx
  local n = #mx
  if along <= mx[1] or along > mx[n] then return nil end
  local lo, hi = 1, n                           -- the first index whose running maximum has reached `along`
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if mx[mid] >= along then hi = mid else lo = mid + 1 end
  end
  local b = mx[lo]
  local a = mx[lo - 1]
  local f = b > a and (along - a) / (b - a) or 1
  return (lo - 2 + f) * g.dt
end

-- Seconds the player is behind (+) or ahead (-) of the ghost at the place `along` after `t` seconds from the departure; nil
-- while there is nothing to compare
function M.delta(g, t, along)
  local at = M.timeAt(g, along)
  if at == nil then return nil end
  return t - at
end

-- "+0:12" / "-0:07" (the sign is a real minus sign for the HUD)
function M.deltaText(sec)
  if sec == nil then return '' end
  local s = round(sec)
  local a = math.abs(s)
  return (s < 0 and '\226\136\146' or '+') .. ('%d:%02d'):format(math.floor(a / 60), a % 60)
end

-- Does the new record replace the old one? Only a finished trip can, and only with more points (the same points: the faster)
function M.better(old, new)
  if not new or not new.finished then return false end
  if not old or old.finished ~= true then return true end
  local po, pn = old.points or 0, new.points or 0
  if pn ~= po then return pn > po end
  return (new.dur or math.huge) < (old.dur or math.huge)
end

return M
