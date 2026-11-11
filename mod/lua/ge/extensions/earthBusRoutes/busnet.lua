-- The virtual bus network (plan 007, stage T1): every trip of the lines round a point, and where each bus is at any clock time.
-- Pure logic, no game calls: deterministic, so the tests run it under lupa. The game side (busnetrun.lua) feeds it the lines it has
-- loaded and publishes what it computes (moving dots on the map, the board of a station); a physical bus (plan 007 T3/T4) later
-- reports its delay back and takes a trip over, so the map does not draw it twice.
--
-- Times are seconds from midnight of the net's day; a trip of yesterday or tomorrow has a start below 0 or above 86400.
-- A trip: { key, line, start, arr[i], dep[i] (seconds after the start), delay (s, late > 0), physical }.
-- The bus of a trip, at clock time `c`, is where  t = c - start - delay  puts it in its arr/dep lists:
--   t < arr[1]            'wait'  at the first stop (not started)
--   arr[i] <= t < dep[i]  'stop'  standing at stop i
--   dep[i] <= t < arr[i+1] 'run'  between stop i and i + 1, a straight share of the time along the road
--   t >= arr[n]           'done'  at the last stop
local geo = require('earthBusRoutes/geomath')
local schedule = require('earthBusRoutes/schedule')
local M = {}

M.HORIZON_S = 1800           -- trips that start within this much are live (the next 30 minutes)
M.GRACE_S = 60               -- a trip that has ended stays live this long
M.DWELL_S = 20               -- a real timetable gives one time per stop: the bus stands this long before it
M.SPAN_BACK_S, M.SPAN_AHEAD_S = 3600, 3 * 3600      -- the trips kept when a line is added: from clock - back to clock + ahead
M.MATCH_M = 120              -- a stop this near a station's platform is the station
M.MATCH_NAME_M = 350         -- ... or this near with the same name
M.WAIT_SHOWN_S = 120         -- a bus about to leave its first stop is drawn this long before

-- ---- the net ---------------------------------------------------------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  return { lines = {}, order = {}, trips = {}, byKey = {}, live = {}, clock = nil, day = opts.day or 1,
    horizon = opts.horizon or M.HORIZON_S, sorted = true, maxDelay = 0 }
end

local function foldName(s)
  return (tostring(s or ''):lower():gsub('[^%w]', ''))
end

local function hasAlong(route)
  if type(route) ~= 'table' or type(route.stops) ~= 'table' or #route.stops < 2 or type(route.path) ~= 'table' or #route.path < 2 then return false end
  for _, s in ipairs(route.stops) do if type(s.along) ~= 'number' then return false end end
  return true
end

-- Times for a route's stops out of a list of offsets that does not have the same stops (a line of the national feed has a time
-- at every stop of its pattern, the route we drew merged some of them): the stops share the trip's time by their distance.
function M.fitOffs(route, offs)
  local n = #route.stops
  if #offs == n then
    local base, out = offs[1], {}
    for i = 1, n do out[i] = offs[i] - base end
    return out
  end
  local total = offs[#offs] - offs[1]
  local a0, a1 = route.stops[1].along, route.stops[n].along
  local span = a1 - a0
  local out = {}
  for i = 1, n do
    local f = span > 0 and (route.stops[i].along - a0) / span or (i - 1) / (n - 1)
    out[i] = total * math.max(0, math.min(1, f))
  end
  return out
end

-- A timetable gives one time per stop (the departure): the bus stands DWELL_S before it at the stops between the ends
local function withDwell(arr, dep)
  local same = true
  for i = 1, #arr do if arr[i] ~= dep[i] then same = false break end end
  if not same then return arr, dep end
  local a = {}
  for i = 1, #arr do a[i] = arr[i] end
  for i = 2, #arr - 1 do a[i] = math.max(dep[i - 1], dep[i] - M.DWELL_S) end
  return a, dep
end

local function tripKey(line, start) return ('%s@%d'):format(tostring(line.id), math.floor(start + 0.5)) end

-- Trips of a route for a window round `clock`, from the generator (the real timetable of a national feed, else the generated
-- one): yesterday's late runs, today's and tomorrow's early ones, all on today's clock. { {start, arr, dep} ... } by start.
function M.tripsAround(route, day, clock, ctx, span)
  span = span or {}
  local back, ahead = span.back or M.SPAN_BACK_S, span.ahead or M.SPAN_AHEAD_S
  local out = {}
  for _, off in ipairs({ -1, 0, 1 }) do
    local d = (day - 1 + off) % 7 + 1
    local trips = schedule.generate(route, d, ctx)
    local shift = off * 86400
    for _, tr in ipairs(trips) do
      local s = tr.start + shift
      local last = tr.arr[#tr.arr] or 0
      if s + last >= clock - back and s <= clock + ahead then out[#out + 1] = { start = s, arr = tr.arr, dep = tr.dep } end
    end
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

-- Adds (or replaces) a line: a parsed route (osm.parseRoute: stops with `along`, path, cum, ref, colour) and its trips.
-- opts: trips = a list of { start, arr, dep } or { start, offs } (offs: a time per stop of the pattern, fitted to the route's stops);
-- else the trips come from schedule.generate for `opts.day` (default the net's), window round `opts.clock`; opts.ctx = the
-- generator's context ({ busy = true } for a busy line). Returns the number of trips, 0 when the route cannot be placed.
function M.addLine(net, route, opts)
  opts = opts or {}
  if not hasAlong(route) then return 0 end
  M.removeLine(net, route.id)
  local clock = opts.clock or net.clock or 0
  local day = opts.day or net.day or 1
  net.day = day
  local list = opts.trips or M.tripsAround(route, day, clock, opts.ctx, opts.span)
  local stops = route.stops
  local line = { id = route.id, ref = route.ref or '?', colour = route.colour or '#888888', route = route,
    head = route.to or stops[#stops].name or '', from = route.from or stops[1].name or '', trips = {} }
  local n = #stops
  for _, tr in ipairs(list) do
    local arr, dep = tr.arr, tr.dep
    if tr.offs then
      local o = M.fitOffs(route, tr.offs)
      arr, dep = {}, {}
      for i = 1, n do arr[i], dep[i] = o[i], o[i] end
      arr, dep = withDwell(arr, dep)
    elseif arr and dep and #arr == n and #dep == n then
      arr, dep = withDwell(arr, dep)
    else
      arr = nil
    end
    if arr and type(tr.start) == 'number' then
      local t = { key = tripKey(line, tr.start), line = line, start = tr.start, arr = arr, dep = dep, delay = 0, physical = false,
        last = arr[n] }
      if not net.byKey[t.key] then
        line.trips[#line.trips + 1] = t
        net.byKey[t.key] = t
      end
    end
  end
  table.sort(line.trips, function(a, b) return a.start < b.start end)
  net.lines[line.id] = line
  net.order[#net.order + 1] = line.id
  net.sorted = false
  return #line.trips
end

function M.removeLine(net, id)
  local line = net.lines[id]
  if not line then return end
  for _, t in ipairs(line.trips) do net.byKey[t.key] = nil end
  net.lines[id] = nil
  for i, v in ipairs(net.order) do if v == id then table.remove(net.order, i) break end end
  net.sorted = false
end

function M.hasLine(net, id) return net.lines[id] ~= nil end

function M.clear(net)
  net.lines, net.order, net.trips, net.byKey, net.live, net.sorted = {}, {}, {}, {}, {}, true
end

function M.stats(net)
  local lines, trips = 0, 0
  for _, id in ipairs(net.order) do lines = lines + 1 trips = trips + #net.lines[id].trips end
  return { lines = lines, trips = trips, live = #net.live, clock = net.clock }
end

local function flat(net)
  if net.sorted then return net.trips end
  local all = {}
  for _, id in ipairs(net.order) do
    for _, t in ipairs(net.lines[id].trips) do all[#all + 1] = t end
  end
  table.sort(all, function(a, b) if a.start ~= b.start then return a.start < b.start end return a.key < b.key end)
  net.trips, net.sorted = all, true
  return all
end

-- ---- where a bus is ----------------------------------------------------------------------------------------------------------

-- point `m` metres along the route's path, by bisection over the cumulative lengths: lat, lon, heading
local function pointAt(route, m)
  local path, cum = route.path, route.cum
  local n = #path
  if m <= 0 then
    local a, b = path[1], path[2]
    return a.lat, a.lon, geo.bearing(a.lat, a.lon, b.lat, b.lon)
  end
  if m >= cum[n] then
    local a, b = path[n - 1], path[n]
    return b.lat, b.lon, geo.bearing(a.lat, a.lon, b.lat, b.lon)
  end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if cum[mid] >= m then hi = mid else lo = mid end
  end
  local a, b = path[hi - 1], path[hi]
  local seg = cum[hi] - cum[hi - 1]
  local f = seg > 0 and (m - cum[hi - 1]) / seg or 0
  return a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f, geo.bearing(a.lat, a.lon, b.lat, b.lon)
end
M.pointAt = pointAt

-- The state of a trip at `clock`: { state, index (the stop it stands at, or the last it left), nextIndex, nextEta (s until it is
-- there; for 'stop' and 'wait' the stop it leaves is index / 1 and leaveIn says when), along (m), lat, lon, heading }.
function M.posOf(trip, clock)
  local route = trip.line.route
  local stops = route.stops
  local arr, dep = trip.arr, trip.dep
  local n = #arr
  local t = clock - trip.start - trip.delay
  local r = { t = t }
  if t < arr[1] then
    r.state, r.index, r.nextIndex, r.nextEta, r.leaveIn, r.along = 'wait', 1, 1, arr[1] - t, dep[1] - t, stops[1].along
  elseif t >= arr[n] then
    r.state, r.index, r.along = 'done', n, stops[n].along
  else
    local i = 1
    while i < n and t >= arr[i + 1] do i = i + 1 end            -- the last stop with arr[i] <= t (i < n here)
    if t < dep[i] then
      r.state, r.index, r.along = 'stop', i, stops[i].along
      r.leaveIn, r.nextIndex, r.nextEta = dep[i] - t, i + 1, arr[i + 1] - t
    else
      local span = arr[i + 1] - dep[i]
      local f = span > 0 and (t - dep[i]) / span or 1
      local a0, a1 = stops[i].along, math.max(stops[i].along, stops[i + 1].along)
      r.state, r.index, r.nextIndex, r.nextEta, r.along = 'run', i, i + 1, arr[i + 1] - t, a0 + (a1 - a0) * f
    end
  end
  r.lat, r.lon, r.heading = pointAt(route, r.along)
  return r
end

local function describe(trip, p)
  local line = trip.line
  local nx = p.nextIndex and line.route.stops[p.nextIndex]
  return { key = trip.key, ref = line.ref, colour = line.colour, head = line.head, routeId = line.id, start = trip.start,
    state = p.state, index = p.index, nextIndex = p.nextIndex, next = nx and nx.name or nil, nextEta = p.nextEta, leaveIn = p.leaveIn,
    along = p.along, lat = p.lat, lon = p.lon, heading = p.heading, delay = trip.delay, physical = trip.physical }
end

-- The live trips at `clock` (s from midnight), by start: the buses that run now and those that leave within the horizon (the
-- ones that ended within the grace time too). Each is { key, ref, colour, head, routeId, start, state ('wait' | 'stop' | 'run' |
-- 'done'), index, nextIndex, next (the name), nextEta, leaveIn, along, lat, lon, heading, delay, physical }.
function M.update(net, clock)
  net.clock = clock
  local live = {}
  local horizon = net.horizon
  for _, t in ipairs(flat(net)) do
    if t.start - net.maxDelay > clock + horizon then break end             -- by start: no later trip is live either
    local s = t.start + t.delay
    if s <= clock + horizon and s + t.last >= clock - M.GRACE_S then live[#live + 1] = describe(t, M.posOf(t, clock)) end
  end
  net.live = live
  return live
end

-- The buses to draw: not the ones a physical bus has taken over, not the ones that have ended, those about to leave only shortly
-- before. opts: center { lat, lon } + r (m) keep the buses within that distance; includePhysical; waitS.
function M.buses(net, opts)
  opts = opts or {}
  local out = {}
  local waitS = opts.waitS or M.WAIT_SHOWN_S
  for _, b in ipairs(net.live) do
    local show = b.state == 'run' or b.state == 'stop' or (b.state == 'wait' and (b.leaveIn or 0) <= waitS)
    if show and (opts.includePhysical or not b.physical) then
      if not (opts.center and opts.r) or geo.dist(opts.center.lat, opts.center.lon, b.lat, b.lon) <= opts.r then out[#out + 1] = b end
    end
  end
  return out
end

-- ---- delay and physical buses --------------------------------------------------------------------------------------------

function M.find(net, key) return net.byKey[key] end

-- A measured delay (s, late > 0): the whole rest of the trip moves by it
function M.setDelay(net, key, seconds)
  local t = net.byKey[key]
  if not t then return false end
  t.delay = tonumber(seconds) or 0
  net.maxDelay = math.max(net.maxDelay, math.abs(t.delay))
  return true
end

-- A physical bus stood at stop `index` at `clock`: the trip's delay is the difference to its timetable. Returns the delay.
function M.reportArrival(net, key, index, clock)
  local t = net.byKey[key]
  if not t or not t.arr[index] then return nil end
  t.delay = clock - (t.start + t.arr[index])
  net.maxDelay = math.max(net.maxDelay, math.abs(t.delay))
  return t.delay
end

-- A real bus drives the trip (or has given it back): the map does not draw the virtual one meanwhile
function M.setPhysical(net, key, on)
  local t = net.byKey[key]
  if not t then return false end
  t.physical = on and true or false
  for _, b in ipairs(net.live) do if b.key == key then b.physical = t.physical end end
  return true
end

-- ---- boards --------------------------------------------------------------------------------------------------------------------

-- The indexes of a line's stops that belong to a station: spec = { lat, lon, name, pts = { {lat, lon} ... } (its platforms), radius }
local function matchStops(line, spec)
  local pts = spec.pts
  if not pts or #pts == 0 then pts = { { lat = spec.lat, lon = spec.lon } } end
  local radius = spec.radius or M.MATCH_M
  local want = spec.name and foldName(spec.name) or nil
  local out = {}
  for i, s in ipairs(line.route.stops) do
    local best = math.huge
    for _, p in ipairs(pts) do
      if p.lat and p.lon then best = math.min(best, geo.dist(p.lat, p.lon, s.lat, s.lon)) end
    end
    if best <= radius or (want and want ~= '' and foldName(s.name) == want and best <= M.MATCH_NAME_M) then out[#out + 1] = i end
  end
  return out
end

M.matchStops = matchStops

-- The trip of line `ref` that is due at a station (spec as above) near `at` (s, the expected arrival with its delay): the best
-- within `tol` seconds. Returns trip, stopIndex, eta or nil. (The fleet's live transfers: "line 360 arrives at the hub at 8:12".)
function M.findArrival(net, spec, ref, at, tol)
  tol = tol or 240
  local best, bestI, bestEta, bestD
  for _, id in ipairs(net.order) do
    local line = net.lines[id]
    if tostring(line.ref) == tostring(ref) then
      local idx = matchStops(line, spec)
      for _, t in ipairs(line.trips) do
        if t.start - net.maxDelay > at + tol + 3600 then break end
        for _, i in ipairs(idx) do
          if i > 1 then                                           -- (a trip that begins here is not an arrival of a bus coming in)
            local eta = t.start + t.arr[i] + t.delay
            local d = math.abs(eta - at)
            if d <= tol and (not bestD or d < bestD) then best, bestI, bestEta, bestD = t, i, eta, d end
          end
        end
      end
    end
  end
  return best, bestI, bestEta
end

-- The next departures of a station at `clock`: { { key, ref, colour, head, at (scheduled s), eta (expected s, with the delay),
-- inS (s until eta), delay, state ('sched' not started | 'run' on its way | 'stop' standing here), next (the stop it is at or
-- heading for, by name), physical } ... } by expected time, at most n. A trip that ends at the station has no departure.
-- opts.within (s, default 7200) how far ahead to look, opts.back (s, default 15) how long after leaving a trip stays.
function M.board(net, spec, clock, n, opts)
  opts = opts or {}
  local within, back = opts.within or 7200, opts.back or 15
  local rows = {}
  for _, id in ipairs(net.order) do
    local line = net.lines[id]
    local idx = matchStops(line, spec)
    if #idx > 0 then
      for _, t in ipairs(line.trips) do
        if t.start - net.maxDelay > clock + within then break end
        for _, i in ipairs(idx) do
          if i < #line.route.stops then
            local at = t.start + t.dep[i]
            local eta = at + t.delay
            if eta >= clock - back and eta <= clock + within then
              local p = M.posOf(t, clock)
              local state = 'sched'
              if p.state == 'stop' and p.index == i then state = 'stop'
              elseif p.state == 'run' or p.state == 'stop' or (p.state == 'wait' and t.delay ~= 0) then state = 'run' end
              rows[#rows + 1] = { key = t.key, ref = line.ref, colour = line.colour, head = line.head, at = at, eta = eta, inS = eta - clock,
                delay = t.delay, state = state, physical = t.physical, stopIndex = i,
                next = line.route.stops[p.nextIndex or i] and line.route.stops[p.nextIndex or i].name or nil }
              break                                         -- (a loop passes the station twice: the first call is the next)
            end
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.eta ~= b.eta then return a.eta < b.eta end
    if a.ref ~= b.ref then return a.ref < b.ref end
    return a.key < b.key
  end)
  local out = {}
  for i = 1, math.min(n or 6, #rows) do out[i] = rows[i] end
  return out
end

return M
