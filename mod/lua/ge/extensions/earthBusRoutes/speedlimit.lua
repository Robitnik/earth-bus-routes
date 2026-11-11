-- Speed limits along a route (pure logic). Three sources, best first:
--   1. the way's own tags (maxspeed, maxspeed:forward / :backward, zone:maxspeed, "CZ:urban", "30 mph", "walk");
--   2. the class of the road (motorway, living street);
--   3. the country's rule: built-up 50, outside 90 (table below), "built-up" = within a radius of a town centre.
--      The data service sends the towns near the road (GeoNames, radius 1-3 km by population) with the route as
--      rel.limits = { cc = 'CZ', towns = { {lat, lon, radiusM}, ... } }; without them only the tags speak.
-- The result is an array with one km/h number per segment of route.path (0 = no limit known), found by `M.at`.
local M = {}

-- country -> { urban, rural, motorway (nil: no general limit) }
M.COUNTRIES = {
  CZ = { 50, 90, 130 }, SK = { 50, 90, 130 }, DE = { 50, 100, nil }, AT = { 50, 100, 130 }, PL = { 50, 90, 140 },
  HU = { 50, 90, 130 }, UA = { 50, 90, 110 }, RO = { 50, 90, 130 }, FR = { 50, 80, 130 }, NL = { 50, 80, 100 },
  BE = { 50, 70, 120 }, CH = { 50, 80, 120 }, IT = { 50, 90, 130 }, GB = { 48, 96, 112 }, IE = { 50, 80, 120 },
}
M.DEFAULT = { 50, 90, 130 }
-- left-hand traffic: the indicator to use when pulling out is the right one
M.LEFT = { GB = true, IE = true, MT = true, CY = true, JP = true, AU = true, NZ = true, ZA = true, IN = true, TH = true }
M.LIVING_STREET = 20
M.WALK = 7
M.MPH = 1.609344

local function row(cc) return M.COUNTRIES[cc or ''] or M.DEFAULT end
function M.urban(cc) return row(cc)[1] end
function M.rural(cc) return row(cc)[2] end
function M.motorway(cc) return row(cc)[3] end
function M.leftHand(cc) return M.LEFT[cc or ''] == true end

local function lower(s) return type(s) == 'string' and s:lower() or '' end

-- One maxspeed value. Returns km/h (a number), false (explicitly no limit: "none", "signals") or nil (not understood).
function M.parse(value, cc)
  if type(value) == 'number' then value = tostring(value) end
  local v = lower(value):gsub('^%s+', ''):gsub('%s+$', '')
  if v == '' then return nil end
  if v == 'none' or v == 'signals' or v == 'variable' then return false end
  if v == 'walk' then return M.WALK end
  v = v:match('^([^;|]+)') or v                      -- "50;70": the first lane's
  local n, unit = v:match('^(%d+%.?%d*)%s*([%a/]*)$')
  if n then
    n = tonumber(n)
    if unit == 'mph' then n = n * M.MPH end
    n = math.floor(n + 0.5)
    if n >= 5 and n <= 140 then return n end
    return nil
  end
  -- "CZ:urban", "DE:zone30", "AT:living_street": a country's name for a limit
  local pre, name = v:match('^(%a%a):([%w_:]+)$')
  if not pre then return nil end
  pre = pre:upper()
  if name == 'urban' then return M.urban(pre) end
  if name == 'rural' or name == 'trunk' then return M.rural(pre) end
  if name == 'motorway' then return M.motorway(pre) or false end
  if name == 'living_street' then return M.LIVING_STREET end
  if name == 'bicycle_road' then return 30 end
  local z = name:match('^zone:?(%d+)$')
  if z then return tonumber(z) end
  return nil
end

-- The limit of one way from its tags, for a way driven `forward` (the way of the road's nodes) or not.
-- Returns km/h, false (no limit) or nil (the tags say nothing: the country's rule decides).
function M.wayKmh(tags, cc, forward)
  if type(tags) ~= 'table' then return nil end
  local dir = forward and 'maxspeed:forward' or 'maxspeed:backward'
  for _, k in ipairs({ 'maxspeed', dir, 'zone:maxspeed', 'maxspeed:type' }) do
    if tags[k] ~= nil then
      local v = M.parse(tags[k], cc)
      if v ~= nil then return v end
    end
  end
  if tags.highway == 'motorway' then return M.motorway(cc) or false end
  if tags.highway == 'living_street' then return M.LIVING_STREET end
  return nil
end

-- ---- what a parsed route carries -------------------------------------------------------------------------------------

local function key(lat, lon) return ('%.6f,%.6f'):format(lat, lon) end
local function segKey(a, b)
  local ka, kb = key(a.lat, a.lon), key(b.lat, b.lon)
  if ka > kb then ka, kb = kb, ka end
  return ka .. '|' .. kb
end

-- spans = { { geometry = { {lat, lon}... }, kmh = number | false } ... } of the ways whose tags said something;
-- limits = rel.limits of the service or nil. Returns route.limitInfo, or nil when there is nothing to know.
function M.info(spans, limits)
  local segs, verts, any = {}, {}, false
  for _, sp in ipairs(spans or {}) do
    local g, v = sp.geometry, sp.kmh
    if v == false then v = 0 end
    for j = 1, #g do
      verts[key(g[j].lat, g[j].lon)] = v
      if j > 1 then segs[segKey(g[j - 1], g[j])] = v end
      any = true
    end
  end
  local towns, cc
  if type(limits) == 'table' then
    cc = type(limits.cc) == 'string' and limits.cc:upper() or nil
    if type(limits.towns) == 'table' then
      towns = {}
      for _, t in ipairs(limits.towns) do
        if type(t) == 'table' and tonumber(t[1]) and tonumber(t[2]) and tonumber(t[3]) then
          towns[#towns + 1] = { tonumber(t[1]), tonumber(t[2]), tonumber(t[3]) }
        end
      end
    end
  end
  if not any and not towns and not cc then return nil end
  return { segs = segs, verts = verts, towns = towns, cc = cc }
end

-- is the point within the radius of one of the towns
local function inTown(towns, lat, lon)
  local k = math.cos(lat * math.pi / 180) * 111320
  for _, t in ipairs(towns) do
    local dy = (t[1] - lat) * 110574
    if dy <= t[3] and dy >= -t[3] then
      local dx = (t[2] - lon) * k
      if dx * dx + dy * dy <= t[3] * t[3] then return true end
    end
  end
  return false
end

-- Array of km/h per segment of route.path (0 = none known); nil when the route has no limit information at all
function M.build(route)
  local info = route.limitInfo
  local path = route.path
  if not info or not path or #path < 2 then return nil end
  local out = {}
  for i = 1, #path - 1 do
    local a, b = path[i], path[i + 1]
    local v = info.segs[segKey(a, b)]
    if v == nil then
      -- a point the road was cut at (a loop turned round, a reversed route): the way of either end
      v = info.verts[key(b.lat, b.lon)]
      if v == nil then v = info.verts[key(a.lat, a.lon)] end
    end
    if v == nil and info.towns then
      v = inTown(info.towns, (a.lat + b.lat) * 0.5, (a.lon + b.lon) * 0.5) and M.urban(info.cc) or M.rural(info.cc)
    end
    out[i] = v or 0
  end
  return out
end

-- The array of the route, made once per path (a reversed route has its own path)
function M.limits(route)
  if route._limFor ~= route.path then
    route._limFor = route.path
    local ok, lim = pcall(M.build, route)
    route._lim = ok and lim or nil
  end
  return route._lim
end

-- The limit (km/h) at `along` metres of the route, nil when none is known
function M.at(route, along)
  local lim = M.limits(route)
  if not lim then return nil end
  local cum = route.cum
  local lo, hi = 1, #lim
  if hi < 1 then return nil end
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if cum[mid] <= (along or 0) then lo = mid else hi = mid - 1 end
  end
  local v = lim[lo]
  return (v and v > 0) and v or nil
end

return M
