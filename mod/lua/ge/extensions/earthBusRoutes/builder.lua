-- Manual mode: a route the player builds from stations (pure logic, tested under lupa). The state is a list of chosen
-- stations ("points"); the data service turns them into a road path (/v1/path), and the stops along that path come from
-- /v1/along. toRoute() gives the same table osm.parseRoute gives, so the timetable, passengers, HUD and score work on it
-- unchanged.
local geo = require('earthBusRoutes/geomath')
local osm = require('earthBusRoutes/osm')
local menu = require('earthBusRoutes/menu')
local M = {}

M.MAX_POINTS = 25
M.SAME_M = 150           -- a station this close to a chosen one is the same place
M.RING_MIN_M = 250       -- "where next" lists stations at least this far from the last one ...
M.RING_MAX_M = 9000      -- ... and at most this far (a search has no limit)
M.MAX_CANDIDATES = 40
M.STOP_OFF_M = 30        -- a stop this near the road is on the route
M.WRONG_SIDE_PENALTY_M = 12
M.WAYPOINT_SNAP_M = 20   -- a chosen station farther than this from the road is moved onto the road for the trip
M.CLOSE_ALONG_M = 120    -- an automatic stop this close (along the road) to a chosen one is the same stop
M.TWIN_ALONG_M = 60      -- two automatic stops of one name this close are one stop
M.FORMAT = 1

local function lower(s) return type(s) == 'string' and s:lower() or '' end

local function copyPoint(p)
  return { name = p.name ~= '' and p.name or nil, lat = p.lat, lon = p.lon, station = p.station or nil }
end

-- A new route state starting at `first` ({ name, lat, lon })
function M.new(first)
  return { points = { copyPoint(first) }, legs = {}, mode = 'all', off = {}, ref = '', serial = 0 }
end

-- Chosen stations of an OSM route (all its stops when they fit, else evenly chosen ones) to go on from.
function M.fromRoute(route)
  local stops = route.stops or {}
  local pts = {}
  local n = #stops
  local mode = 'express'
  if n <= M.MAX_POINTS - 1 then
    for i, s in ipairs(stops) do pts[i] = copyPoint(s) end
  else
    mode = 'all'
    local want = M.MAX_POINTS - 1
    for k = 0, want - 1 do
      local i = 1 + math.floor(k * (n - 1) / (want - 1) + 0.5)
      pts[#pts + 1] = copyPoint(stops[i])
    end
  end
  return { points = pts, legs = {}, mode = mode, off = {}, ref = route.ref or '', colour = route.colour, serial = 0,
    name = nil, basedOn = route.id }
end

local function invalidate(s)
  s.path, s.cum, s.length, s.legs, s.auto, s.straight, s.source, s.starts = nil, nil, nil, {}, nil, nil, nil, nil
  s.serial = (s.serial or 0) + 1
end

-- Add a station; false + why when refused
function M.add(s, p)
  if #s.points >= M.MAX_POINTS then return false, 'full' end
  local last = s.points[#s.points]
  if last and geo.dist(last.lat, last.lon, p.lat, p.lon) < M.SAME_M and lower(last.name) == lower(p.name) then return false, 'same' end
  s.points[#s.points + 1] = copyPoint(p)
  invalidate(s)
  return true
end

function M.undo(s)
  if #s.points <= 1 then return false end
  s.points[#s.points] = nil
  invalidate(s)
  return true
end

-- The query string for /v1/path (and /v1/along)
function M.pts(s)
  local t = {}
  for i, p in ipairs(s.points) do t[i] = ('%.6f,%.6f'):format(p.lat, p.lon) end
  return table.concat(t, ';')
end

-- Take the data service's answer for the road path ({ points = { {lat, lon} ...}, legs = { {dist, dur} ...}, source }).
function M.applyPath(s, ans)
  local path = {}
  for i, p in ipairs(ans.points or {}) do path[i] = { lat = p[1], lon = p[2] } end
  if #path < 2 then return false end
  s.path = path
  s.cum, s.length = geo.cumulative(path)
  s.legs = {}
  for i, l in ipairs(ans.legs or {}) do s.legs[i] = { dist = l.dist or 0, dur = l.dur or 0 } end
  s.source = ans.source
  s.straight = ans.source ~= 'osrm'
  s.auto = nil
  s.starts = nil
  return true
end

-- Per-leg summary for the chain on screen: { from, to, km, min }
function M.legInfo(s)
  local out = {}
  for i = 2, #s.points do
    local l = s.legs and s.legs[i - 1]
    out[#out + 1] = { from = s.points[i - 1].name, to = s.points[i].name, km = l and math.floor(l.dist / 100 + 0.5) / 10 or nil,
      min = l and math.floor(l.dur / 60 * 1.25 + 0.5) or nil, ready = l ~= nil }
  end
  return out
end

-- ---- "where next?" ---------------------------------------------------------------------------------------------------

-- Stations (osm.groupStops) to go to from the last chosen one: not the chosen ones, bus stations first, then by distance.
-- opts: { min, max, byName = true (a search: every match, nearest first) }
function M.candidates(stations, s, opts)
  opts = opts or {}
  local from = s.points[#s.points]
  local prev = s.points[#s.points - 1]
  local heading = prev and geo.bearing(prev.lat, prev.lon, from.lat, from.lon) or nil
  local out = {}
  for _, st in ipairs(stations) do
    local d = geo.dist(from.lat, from.lon, st.lat, st.lon)
    local taken = false
    for _, p in ipairs(s.points) do
      if geo.dist(p.lat, p.lon, st.lat, st.lon) < M.SAME_M and (lower(p.name) == lower(st.name) or geo.dist(p.lat, p.lon, st.lat, st.lon) < 60) then taken = true break end
    end
    local inRing = d >= (opts.min or M.RING_MIN_M) and d <= (opts.max or M.RING_MAX_M)
    if not taken and st.name and st.name ~= '' and (opts.byName or inRing) then
      local b = geo.bearing(from.lat, from.lon, st.lat, st.lon)
      local ahead = true
      if heading then
        local diff = math.abs((b - heading + 540) % 360 - 180)
        ahead = diff <= 100
      end
      out[#out + 1] = { name = st.name, lat = st.lat, lon = st.lon, station = st.station and true or false, dist = math.floor(d + 0.5),
        dir = menu.compass(b), ahead = ahead, platforms = #st.platforms, ref = st }
    end
  end
  table.sort(out, function(a, b)
    if a.station ~= b.station then return a.station end
    return a.dist < b.dist
  end)
  if not opts.byName then
    -- a bus station first only when it is not far behind a nearer stop
    local keep = {}
    for i = 1, math.min(#out, M.MAX_CANDIDATES) do keep[i] = out[i] end
    out = keep
  else
    local keep = {}
    table.sort(out, function(a, b) return a.dist < b.dist end)
    for i = 1, math.min(#out, M.MAX_CANDIDATES) do keep[i] = out[i] end
    out = keep
  end
  for i, c in ipairs(out) do c.id = i end
  return out
end

-- ---- stops along the road --------------------------------------------------------------------------------------------

local function sideOf(path, cum, along, lat, lon)
  local plat, plon, bearing = geo.pointAt(path, cum, along)
  if not plat then return 0 end
  local x, y = geo.toXY(plat, plon, lat, lon)
  local b = math.rad(bearing or 0)
  return x * math.cos(b) - y * math.sin(b)         -- > 0: on the right of the way of travel
end

-- Bus stops near the road as { id, name, lat, lon, along, off, side } in road order. `elements` = Overpass elements.
function M.stopsAlong(s, elements)
  if not s.path then return {} end
  local a = osm.parseAround({ elements = elements })
  local stations = osm.groupStops(a.stops)
  local found = {}
  for _, st in ipairs(stations) do
    local best, bestScore
    local cands = {}
    for _, p in ipairs(st.platforms) do cands[#cands + 1] = p end
    if st.station then cands[#cands + 1] = { id = 'st' .. tostring(st.lat), lat = st.lat, lon = st.lon } end
    if #cands == 0 then cands[1] = { id = 'c' .. tostring(st.lat), lat = st.lat, lon = st.lon } end
    for _, p in ipairs(cands) do
      local al, off = geo.along(s.path, s.cum, p.lat, p.lon)
      if al and off <= M.STOP_OFF_M then
        local side = sideOf(s.path, s.cum, al, p.lat, p.lon)
        local score = off + (side < 0 and M.WRONG_SIDE_PENALTY_M or 0)
        if not bestScore or score < bestScore then
          bestScore = score
          best = { id = p.id, name = st.name ~= '' and st.name or p.name, lat = p.lat, lon = p.lon, along = al, off = off, side = side }
        end
      end
    end
    if best and best.name and best.name ~= '' then found[#found + 1] = best end
  end
  table.sort(found, function(x, y) return x.along < y.along end)
  local out = {}
  for _, f in ipairs(found) do
    local prev = out[#out]
    if prev and osm.normName(prev.name) == osm.normName(f.name) and f.along - prev.along < M.TWIN_ALONG_M then
      if f.off < prev.off then out[#out] = f end
    else
      out[#out + 1] = f
    end
  end
  return out
end

function M.setAuto(s, stops)
  s.auto = stops
  s.starts = nil
end

-- The chosen stations on the path: { name, lat, lon, along, off, chosen = true }, the first at 0 and the last at its end.
function M.waypointStops(s)
  local out = {}
  if not s.path then return out end
  local prev = 0
  for i, p in ipairs(s.points) do
    local al, off
    if i == 1 then al, off = 0, 0
    elseif i == #s.points then al, off = s.length, 0
    else al, off = geo.along(s.path, s.cum, p.lat, p.lon, math.max(0, prev - 30)) end
    if not al then al, off = geo.along(s.path, s.cum, p.lat, p.lon) end
    al = math.max(al or prev, prev)
    local lat, lon = p.lat, p.lon
    local plat, plon = geo.pointAt(s.path, s.cum, al)
    local dist = plat and geo.dist(plat, plon, lat, lon) or 0
    if plat and (i == 1 or i == #s.points or dist > M.WAYPOINT_SNAP_M) then lat, lon = plat, plon end
    out[i] = { id = 'w' .. i, name = p.name or ('Stop ' .. i), lat = lat, lon = lon, along = al, off = math.min(dist, 999), chosen = true }
    prev = al
  end
  return out
end

-- The stops of the route as it would run: the chosen stations and, in "all" mode, the stops on the way (the ones not
-- switched off). Each: { id, name, lat, lon, along, off, chosen, on }. Switched-off ones are listed with on = false.
function M.stopList(s)
  local list = M.waypointStops(s)
  if #list < 2 then return {} end
  if s.mode ~= 'all' then return list end
  for _, a in ipairs(s.auto or {}) do
    local near = false
    for _, w in ipairs(list) do
      if w.chosen and math.abs(w.along - a.along) < M.CLOSE_ALONG_M then near = true break end
    end
    if not near then
      list[#list + 1] = { id = a.id, name = a.name, lat = a.lat, lon = a.lon, along = a.along, off = a.off, chosen = false,
        on = not s.off[tostring(a.id)] }
    end
  end
  table.sort(list, function(x, y) return x.along < y.along end)
  for _, st in ipairs(list) do if st.on == nil then st.on = true end end
  return list
end

function M.toggleStop(s, id)
  if tostring(id):sub(1, 1) == 'w' then return false end      -- a chosen station stays
  id = tostring(id)
  if s.off[id] then s.off[id] = nil else s.off[id] = true end
  s.starts = nil
  return true
end

function M.setMode(s, mode)
  s.mode = (mode == 'express') and 'express' or 'all'
end

-- ---- the finished route ----------------------------------------------------------------------------------------------

-- A route table like osm.parseRoute's. `id` must be unique among the routes of the session (a negative number).
function M.toRoute(s, id)
  if not s.path or #s.points < 2 then return nil, 'no path yet' end
  local list = M.stopList(s)
  local stops = {}
  for _, st in ipairs(list) do
    if st.on ~= false then
      stops[#stops + 1] = { id = st.id, name = st.name, lat = st.lat, lon = st.lon, along = st.along, off = st.off, role = '' }
    end
  end
  if #stops < 2 then return nil, 'fewer than two stops' end
  for i, st in ipairs(stops) do st.index = i end
  local first, last = stops[1], stops[#stops]
  local ref = (s.ref and s.ref ~= '') and s.ref or 'My'
  local p1, pn = s.points[1], s.points[#s.points]
  local loop = osm.normName(first.name) == osm.normName(last.name) and geo.dist(p1.lat, p1.lon, pn.lat, pn.lon) < 150
  local r = {
    id = id, ref = ref, name = s.name or (ref .. ': ' .. first.name .. ' => ' .. last.name), from = first.name, to = last.name,
    network = 'Custom', colour = osm.colorFor(ref, s.colour), mode = 'bus', tags = {}, stops = stops, path = s.path,
    cum = s.cum, length = s.length, gaps = 0, loop = loop, incomplete = false, custom = true, straight = s.straight or false,
    waypoints = #s.points,
  }
  r.kind = osm.kind(r)
  return r
end

-- The same route the other way: the stations in reverse order (the path has to be asked for again).
function M.reverse(s)
  local pts = {}
  for i = #s.points, 1, -1 do pts[#pts + 1] = copyPoint(s.points[i]) end
  local r = { points = pts, legs = {}, mode = s.mode, off = {}, ref = s.ref, colour = s.colour, serial = 0, name = nil }
  for id in pairs(s.off or {}) do r.off[id] = true end
  return r
end

-- ---- saving ------------------------------------------------------------------------------------------------------------

function M.serialize(s)
  local pts, off = {}, {}
  for i, p in ipairs(s.points) do pts[i] = { name = p.name, lat = p.lat, lon = p.lon, station = p.station } end
  for id in pairs(s.off or {}) do off[#off + 1] = tostring(id) end
  table.sort(off)
  return { format = M.FORMAT, points = pts, mode = s.mode, off = off, ref = s.ref, colour = s.colour, name = s.name }
end

function M.deserialize(d)
  if type(d) ~= 'table' or d.format ~= M.FORMAT or type(d.points) ~= 'table' or #d.points < 2 or #d.points > M.MAX_POINTS then return nil end
  local s = { points = {}, legs = {}, mode = d.mode == 'express' and 'express' or 'all', off = {}, ref = type(d.ref) == 'string' and d.ref or '',
    colour = type(d.colour) == 'string' and d.colour or nil, name = type(d.name) == 'string' and d.name or nil, serial = 0 }
  for _, p in ipairs(d.points) do
    local lat, lon = tonumber(p.lat), tonumber(p.lon)
    if not lat or not lon or lat < -85 or lat > 85 or lon < -180 or lon > 180 then return nil end
    s.points[#s.points + 1] = { name = type(p.name) == 'string' and p.name or nil, lat = lat, lon = lon, station = p.station or nil }
  end
  for _, id in ipairs(d.off or {}) do s.off[tostring(id)] = true end
  return s
end

return M
