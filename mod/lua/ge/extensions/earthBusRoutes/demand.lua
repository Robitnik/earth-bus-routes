-- Passenger flow. Who waits where and when, who gets off where. Deterministic for a (route, trip, stop): driving the same
-- trip twice meets the same crowd. Pure logic.
local geo = require('earthBusRoutes/geomath')
local M = {}

M.DENSITY = { low = 0.6, normal = 1.0, high = 1.6 }
M.BASE_PER_MIN = 0.30        -- people per minute appearing at an average stop at profile 1.0
M.SEATS, M.STANDING = 25, 55 -- when the vehicle does not say
M.BOARD_S, M.ALIGHT_S = 1.8, 1.2

local function gauss(h, mu, sigma) local d = (h - mu) / sigma return math.exp(-0.5 * d * d) end

-- How busy the hour is (1 = the morning peak of a weekday), from the clock hour 0..24
function M.profile(hour, weekend)
  local plateau = (hour >= 6 and hour < 21) and 0.45 or 0
  -- soften the plateau's edges
  if hour >= 5 and hour < 6 then plateau = 0.45 * (hour - 5) elseif hour >= 21 and hour < 22 then plateau = 0.45 * (22 - hour) end
  local peak = gauss(hour, 7.5, 1.0) + gauss(hour, 16.5, 1.2) * 0.95
  if weekend then return 0.05 + plateau * 0.8 + peak * 0.4 * 0.55 end
  return 0.05 + plateau + peak * 0.55
end

-- +1 around the morning peak (people go towards the centre), -1 around the evening one (home again), 0 between.
function M.tilt(hour, weekend)
  if weekend then return 0 end
  return gauss(hour, 7.5, 1.2) - gauss(hour, 16.5, 1.4)
end

-- Seeded random numbers (LCG): math.random is global state the game and other mods share.
function M.rng(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

function M.hashSeed(...)
  local h = 5381
  for _, v in ipairs({ ... }) do
    local str = tostring(v)
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
  end
  return h
end

-- Poisson sample (Knuth for small means, a normal approximation for large ones)
function M.poisson(rand, lambda)
  if lambda <= 0 then return 0 end
  if lambda > 30 then
    local u1, u2 = math.max(rand(), 1e-9), rand()
    local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    return math.max(0, math.floor(lambda + math.sqrt(lambda) * z + 0.5))
  end
  local limit, k, p = math.exp(-lambda), 0, 1
  repeat k = k + 1 p = p * rand() until p <= limit
  return k - 1
end

-- Weight of every stop of the route (mean 1): how many people it draws. ctx.routesAt[i] = lines calling there,
-- ctx.station[i] = a bus or rail station. Stops with many neighbours within 400 m count as central.
function M.stopWeights(route, ctx)
  local stops, w, central = route.stops, {}, {}
  local n = #stops
  for i, s in ipairs(stops) do
    local nb = 0
    for j, o in ipairs(stops) do
      if i ~= j and geo.dist(s.lat, s.lon, o.lat, o.lon) <= 400 then nb = nb + 1 end
    end
    central[i] = math.min(1, nb / 4)
    local x = 1 + 0.6 * math.max(0, ((ctx and ctx.routesAt and ctx.routesAt[i]) or 1) - 1)
    if ctx and ctx.station and ctx.station[i] then x = x + 2 end
    w[i] = x + central[i]
  end
  local sum = 0
  for i = 1, n do sum = sum + w[i] end
  local mean = sum / math.max(1, n)
  for i = 1, n do w[i] = w[i] / mean end
  return w, central
end

local function weatherFactor(weather)
  if weather and ((weather.rain or 0) > 0.3 or (weather.snow or 0) > 0.3) then return 1.2 end
  return 1
end
M.weatherFactor = weatherFactor

-- People waiting when the bus arrives at stop `i`. `sinceSec` = time since the previous bus left (the headway, or
-- longer when the player is late). hour = clock hour at the arrival.
function M.waiting(route, w, central, i, hour, weekend, sinceSec, opts)
  opts = opts or {}
  local dens = M.DENSITY[opts.density or 'normal'] or 1
  local tilt = M.tilt(hour, weekend)
  local board = w[i] * (1 + 0.5 * tilt * (1 - 2 * central[i]))
  local lambda = M.BASE_PER_MIN * dens * board * M.profile(hour, weekend) * (math.min(sinceSec, 3600) / 60) * weatherFactor(opts.weather)
  local rand = M.rng(M.hashSeed(route.id or route.ref, opts.tripId or 0, i, opts.day or 0))
  -- the last stop has nobody to carry anywhere
  if i >= #route.stops then return 0 end
  return M.poisson(rand, lambda)
end

-- Where a passenger boarding at stop i gets off: index j > i, gravity-weighted (heavier stops and nearer ones)
function M.destination(route, w, central, i, hour, weekend, rand)
  local n = #route.stops
  if i >= n - 1 then return n end
  local tilt = M.tilt(hour, weekend)
  local total, cands = 0, {}
  for j = i + 1, n do
    local alight = w[j] * (1 - 0.5 * tilt * (1 - 2 * central[j]))
    local d = route.stops[j].along - route.stops[i].along
    local f = alight / (1 + d / 3000)
    if j == n then f = f * 1.5 end                             -- the terminus is a common destination
    total = total + f
    cands[#cands + 1] = { j, total }
  end
  local r = rand() * total
  for _, c in ipairs(cands) do if r <= c[2] then return c[1] end end
  return n
end

-- ---- shared stops (plan 007 T5) ----------------------------------------------------------------------------------------------
-- The people of a stop belong to a LINE (a direction of it): each stop keeps, per line, when a bus of that line last took people
-- and how many. A bus of the AI that has just served a stop leaves fewer waiting for the player of the same line, and the player
-- leaves fewer for it; the people of another line are never in either's crowd. `book` is off (a no-op) until the fleet switches
-- it on, so a trip without AI buses is exactly what it was.
M.CELL_DEG = 0.0004                     -- ~ 44 m: the stops of a platform pair (both sides of a street) share a cell, neighbours are looked at too

function M.newBook() return { active = false, cells = {} } end
M.book = M.newBook()

local function cellOf(lat, lon) return math.floor(lat / M.CELL_DEG + 0.5), math.floor(lon / M.CELL_DEG + 0.5) end

-- one key per line and direction: a bus of 305 towards A takes no one of 305 towards B
function M.lineKey(route)
  local stops = route.stops or {}
  local to = route.to or (stops[#stops] and stops[#stops].name) or ''
  return tostring(route.ref or route.id or '?') .. '>' .. tostring(to)
end

-- a bus of `line` took `taken` people at the stop at (lat, lon) at `clock` (s)
function M.markServed(book, lat, lon, line, clock, taken)
  if not book or not book.active or not lat or not lon then return end
  local cx, cy = cellOf(lat, lon)
  local key = cx .. ',' .. cy
  local cell = book.cells[key]
  if not cell then cell = {} book.cells[key] = cell end
  cell[line] = { at = clock, taken = taken or 0 }
end

-- The time (s) that people of `line` have been collecting at the stop at (lat, lon) when a bus comes at `clock`: `since` (the
-- headway the caller counts) unless another bus of the line took them more recently (within the cell and its neighbours).
function M.sharedSince(book, lat, lon, line, clock, since)
  if not book or not book.active or not lat or not lon then return since end
  local cx, cy = cellOf(lat, lon)
  local best = since
  for dx = -1, 1 do
    for dy = -1, 1 do
      local cell = book.cells[(cx + dx) .. ',' .. (cy + dy)]
      local s = cell and cell[line]
      if s and s.at <= clock and clock - s.at < best then best = math.max(0, clock - s.at) end
    end
  end
  return best
end

-- keep the book small: what is older than an hour is forgotten
function M.pruneBook(book, clock)
  for k, cell in pairs(book.cells) do
    for line, s in pairs(cell) do if s.at < clock - 3600 then cell[line] = nil end end
    if next(cell) == nil then book.cells[k] = nil end
  end
end

function M.capacity(info)
  local seats = (info and info.seats) or M.SEATS
  local standing = (info and info.standing) or M.STANDING
  return seats + standing, seats
end

-- Seconds the doors stay useful for: people off, then on; kneeling is quicker
function M.dwellTime(alighting, boarding, kneeling)
  local s = alighting * M.ALIGHT_S + boarding * M.BOARD_S
  if kneeling then s = s * 0.8 end
  return s
end

-- Make the crowd that boards at stop i: returns a list of destination indices (at most `room` of them) and how many
-- were left on the pavement.
function M.board(route, w, central, i, hour, weekend, sinceSec, room, opts)
  local n = M.waiting(route, w, central, i, hour, weekend, sinceSec, opts)
  local take = math.min(n, math.max(0, room))
  local rand = M.rng(M.hashSeed(route.id or route.ref, (opts and opts.tripId) or 0, i, 'dest', (opts and opts.day) or 0))
  local dests = {}
  for _ = 1, take do dests[#dests + 1] = M.destination(route, w, central, i, hour, weekend, rand) end
  return dests, n - take
end

return M
