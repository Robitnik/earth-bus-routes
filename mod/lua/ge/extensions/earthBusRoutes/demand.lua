-- Passenger flow. Who waits where and when, who gets off where. Deterministic for a (route, trip, stop): driving the same
-- trip twice meets the same crowd. Pure logic.
local geo = require('earthBusRoutes/geomath')
local M = {}

M.DENSITY = { low = 0.6, normal = 1.0, high = 1.6 }
-- How many people a stop has (docs/research/passenger-demand.md): the people living round it (the town it is in, shared out among the
-- line's stops there, at most those within 400 m), times the trips a person makes a day, times the share of them made by bus.
-- A bus takes the demand of the time since the bus before (the headway), weighted by the hour.
M.TRIPS_PER_DAY = 2.7        -- trips a person makes a day (EU average of the national travel surveys)
M.CATCH_KM2 = 0.5            -- a stop's catchment: 400 m round it
M.FIELD_PEOPLE = 40          -- a stop outside any town: a few houses, a farm, a junction
M.STATION_K = 2.5            -- a bus or rail station: transfers and people from all over town
M.CENTRE_K = 2.0             -- the centre of a town draws people (shops, work, schools) on top of those who live there
M.WINDOW_MAX_MIN = 180       -- a bus after a long gap takes the demand of at most this long
M.SEATS, M.STANDING = 25, 55 -- when the vehicle does not say
M.BOARD_S, M.ALIGHT_S = 1.2, 0.8    -- s per person: on through the front door, off through the others (at the same time)

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

-- the population a town of the gazetteer has, when the service did not say (older answers): from its built-up radius
local function popFromRadius(r)
  if r >= 3000 then return 150000 elseif r >= 2400 then return 50000 elseif r >= 2000 then return 15000
  elseif r >= 1600 then return 5000 elseif r >= 1200 then return 1200 end
  return 300
end
-- people per km2 in the built-up area of a town of that size
local function density(pop)
  if pop < 2000 then return 1200 elseif pop < 20000 then return 2500 elseif pop < 200000 then return 4000 end
  return 6000
end
-- the share of trips made by public transport
local function busShare(pop)
  if pop < 1000 then return 0.05 elseif pop < 10000 then return 0.07 elseif pop < 50000 then return 0.10
  elseif pop < 300000 then return 0.15 end
  return 0.22
end
M.busShare = busShare

-- the people of each stop and how central it is: { pop, share, centre (0..1), town (pop of the town or nil) } per stop
function M.catchments(route)
  local stops = route.stops
  local towns = route.limitInfo and route.limitInfo.towns
  local out = {}
  -- which town each stop is in (the nearest centre whose built-up radius reaches it)
  local inTown, perTown = {}, {}
  for i, s in ipairs(stops) do
    local best, bd
    for k, t in ipairs(towns or {}) do
      local d = geo.dist(s.lat, s.lon, t[1], t[2])
      if d <= t[3] and (not bd or d / t[3] < bd) then best, bd = k, d / t[3] end
    end
    if best then inTown[i] = { k = best, pos = bd } perTown[best] = (perTown[best] or 0) + 1 end
  end
  for i, s in ipairs(stops) do
    local c
    if inTown[i] then
      local t = towns[inTown[i].k]
      local pop = (t[4] and t[4] > 0) and t[4] or popFromRadius(t[3])
      local centre = 1 - inTown[i].pos
      local people = math.min(pop / perTown[inTown[i].k], density(pop) * M.CATCH_KM2 * (0.7 + 0.6 * centre))
      -- a town's centre draws people from the rest of it; the more lines a big town has, the fewer of them take this one
      local draw = 1 + (M.CENTRE_K - 1) * centre * math.min(1, pop / 5000)
      local lines = 1 + math.min(5, pop / 8000)                     -- a town of 20 000 has 3-4 lines, a city 6+ at a stop
      c = { pop = people * draw / lines, share = busShare(pop), centre = centre, town = pop }
    elseif towns then
      c = { pop = M.FIELD_PEOPLE, share = busShare(0), centre = 0 }
    else
      -- no towns known (an old service, no gazetteer): the spacing of the stops tells town from country
      local a, b = stops[i - 1], stops[i + 1]
      local gaps, n = 0, 0
      if a and a.along and s.along then gaps, n = gaps + (s.along - a.along), n + 1 end
      if b and b.along and s.along then gaps, n = gaps + (b.along - s.along), n + 1 end
      local gap = n > 0 and gaps / n or 1000
      if gap <= 450 then c = { pop = 1800, share = 0.12, centre = 0.6 }
      elseif gap <= 900 then c = { pop = 700, share = 0.09, centre = 0.3 }
      elseif gap <= 2000 then c = { pop = 180, share = 0.06, centre = 0 }
      else c = { pop = M.FIELD_PEOPLE, share = 0.05, centre = 0 } end
    end
    if s.station then c.pop = c.pop * M.STATION_K end
    out[i] = c
  end
  return out
end

-- Weight of every stop of the route (mean 1): how many people it draws, from its catchment (M.catchments). ctx.station[i] = a bus
-- or rail station. w.daily[i] = the people who board there a day, in one direction. central[i] = 0..1 (the town centre).
function M.stopWeights(route, ctx)
  local stops, w, central = route.stops, {}, {}
  local n = #stops
  local daily = {}
  local cs = M.catchments(route)
  for i = 1, n do
    local c = cs[i]
    if ctx and ctx.station and ctx.station[i] and not stops[i].station then c.pop = c.pop * M.STATION_K end
    daily[i] = c.pop * M.TRIPS_PER_DAY * c.share * 0.5            -- half of a stop's people go this way
    central[i] = c.centre
    w[i] = daily[i]
  end
  local sum = 0
  for i = 1, n do sum = sum + w[i] end
  local mean = sum / math.max(1, n)
  for i = 1, n do w[i] = mean > 0 and w[i] / mean or 1 end
  w.daily = daily
  return w, central
end

-- the share of a day's people that come in `minutes` before `hour` (the profile summed over the day)
local DAY_PROFILE
local function dayProfile()
  if not DAY_PROFILE then
    DAY_PROFILE = {}
    for _, we in ipairs({ false, true }) do
      local sum = 0
      for m = 0, 24 * 60 - 1, 10 do sum = sum + M.profile(m / 60, we) * 10 end
      DAY_PROFILE[we] = sum
    end
  end
  return DAY_PROFILE
end
function M.windowShare(hour, weekend, minutes)
  minutes = math.max(0, math.min(minutes, M.WINDOW_MAX_MIN))
  local sum, step = 0, 5
  local m = 0
  while m < minutes do
    local d = math.min(step, minutes - m)
    sum = sum + M.profile(((hour - (m + d / 2) / 60) % 24), weekend) * d
    m = m + d
  end
  return sum / dayProfile()[weekend == true]
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
  local daily = (w.daily and w.daily[i]) or (w[i] * 20)
  local board = daily * (1 + 0.5 * tilt * (1 - 2 * central[i]))
  local lambda = dens * board * M.windowShare(hour, weekend, sinceSec / 60) * weatherFactor(opts.weather)
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

-- Seconds the doors stay useful for: people off and on at the same time (the slower stream); kneeling is quicker
function M.dwellTime(alighting, boarding, kneeling)
  local s = math.max(alighting * M.ALIGHT_S, boarding * M.BOARD_S)
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
