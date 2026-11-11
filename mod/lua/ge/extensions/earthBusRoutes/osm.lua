-- Parsing of Overpass answers into stops, stations, lines and routes. Pure logic (no game calls): the tests run it under
-- lupa on recorded answers (tests/fixtures). Overpass queries live in overpass.lua.
local geo = require('earthBusRoutes/geomath')
local M = {}

M.MERGE_M = 150        -- same-named platforms closer than this are one stop (one platform per direction)
M.POSITION_M = 60      -- a stop_position this close to a platform belongs to the same stop
M.STATION_M = 150      -- platforms and stop positions this close to a bus station (amenity=bus_station) belong to it
M.GAP_M = 40           -- a hole in a route's way chain bigger than this makes the route "incomplete"

local function lower(s) return type(s) == 'string' and s:lower() or '' end

-- Names compare without case, spaces, punctuation ("Náchod, nám." and "nachod nam" are not equal, but "Náchod  nám" and
-- "náchod nám" are): good enough to join a stop's two platforms, which OSM names alike.
function M.normName(s)
  s = lower(s or '')
  -- explicit ASCII separators: %p / %s change with the machine's locale (cp1251 treats UTF-8 bytes as punctuation)
  s = s:gsub("[ \t\r\n,%.;:!%?%-_%(%)%[%]/\'\"]+", " ")
  s = s:gsub('^ ', ''):gsub(' $', '')
  return s
end

-- A "#rrggbb" colour from a route's tag, else a stable one from its ref (so a line keeps its colour everywhere).
function M.colorFor(ref, tag)
  if type(tag) == 'string' then
    if tag:match('^#%x%x%x%x%x%x$') then return tag:lower() end
    local r, g, b = tag:match('^#(%x)(%x)(%x)$')
    if r then return ('#%s%s%s%s%s%s'):format(r, r, g, g, b, b):lower() end
  end
  local h = 7
  for i = 1, #(ref or '?') do h = (h * 31 + (ref or '?'):byte(i)) % 360000 end
  local hue = (h % 360) / 60
  local s, v = 0.62, 0.86
  local c = v * s
  local x = c * (1 - math.abs(hue % 2 - 1))
  local m = v - c
  local r1, g1, b1 = 0, 0, 0
  local k = math.floor(hue)
  if k == 0 then r1, g1, b1 = c, x, 0 elseif k == 1 then r1, g1, b1 = x, c, 0 elseif k == 2 then r1, g1, b1 = 0, c, x
  elseif k == 3 then r1, g1, b1 = 0, x, c elseif k == 4 then r1, g1, b1 = x, 0, c else r1, g1, b1 = c, 0, x end
  return ('#%02x%02x%02x'):format(math.floor((r1 + m) * 255 + 0.5), math.floor((g1 + m) * 255 + 0.5), math.floor((b1 + m) * 255 + 0.5))
end

local function nodeKind(tags, role)
  tags = tags or {}
  if tags.amenity == 'bus_station' or (tags.public_transport == 'station' and tags.bus == 'yes') then return 'station' end
  if tags.public_transport == 'stop_position' then return 'stop' end
  if tags.public_transport == 'platform' or tags.highway == 'bus_stop' then return 'platform' end
  role = role or ''
  if role:sub(1, 8) == 'platform' then return 'platform' end
  if role:sub(1, 4) == 'stop' then return 'stop' end
  return nil
end

local function elemPoint(e)
  if e.lat and e.lon then return e.lat, e.lon end
  if e.center then return e.center.lat, e.center.lon end
end

-- The answer of overpass.nearbyQuery: { stops = { {id, name, lat, lon, kind} }, routes = { {id, ref, ... , nodes = set} } }
function M.parseAround(data)
  local out = { stops = {}, routes = {} }
  for _, e in ipairs(data and data.elements or {}) do
    local tags = e.tags or {}
    if e.type == 'relation' then
      if tags.type == 'route' then
        local nodes, places = {}, {}
        for _, m in ipairs(e.members or {}) do
          if m.type == 'node' then
            nodes[m.ref] = true
            if m.i then places[m.ref] = { i = m.i, j = m.j or m.i } end     -- from the data service: the stop's place in the route
          end
        end
        local head = M.routeHead(e, tags, nodes)
        head.places, head.n, head.ordered = places, e.n, e.ordered == true
        out.routes[#out.routes + 1] = head
      end
    else
      local kind = nodeKind(tags)
      local lat, lon = elemPoint(e)
      if kind and lat and not (tags.bus == 'no' and tags.trolleybus ~= 'yes') then
        out.stops[#out.stops + 1] = { id = e.id, name = tags.name, lat = lat, lon = lon, kind = kind, tags = tags }
      end
    end
  end
  return out
end

-- What the list of lines shows about a relation before its geometry is loaded.
function M.routeHead(e, tags, nodes)
  return {
    id = e.id, ref = tags.ref or tags.name or tostring(e.id), name = tags.name, from = tags.from, to = tags.to,
    network = tags.network, operator = tags.operator, colour = M.colorFor(tags.ref or tags.name, tags.colour),
    mode = tags.route, version = tags['public_transport:version'], nodes = nodes or {}, tags = tags,
  }
end

-- Platforms of one name close together become one "stop" with several platforms (one per direction); a stop_position
-- near a platform joins it, because routes list those as members, not the platform.
-- Returns stations { {name, lat, lon, platforms = {..}, nodeIds = set, station = bool} } (unsorted). Bus stations of the map
-- come first and take the platforms around them.
function M.groupStops(stops)
  local buses, platforms, positions = {}, {}, {}
  for _, s in ipairs(stops) do
    if s.kind == 'station' then buses[#buses + 1] = s
    elseif s.kind == 'platform' then platforms[#platforms + 1] = s
    else positions[#positions + 1] = s end
  end
  -- A bus station (amenity=bus_station) takes every platform and stop position near it: its platforms are often named
  -- "4" or "V2" only, the station's own name is what the player knows.
  local out = {}
  for _, b in ipairs(buses) do
    out[#out + 1] = { name = b.name or '', platforms = {}, nodeIds = {}, lat = b.lat, lon = b.lon, station = true, fixed = true }
  end
  local function stationFor(s)
    local best, bd = nil, M.STATION_M
    for _, st in ipairs(out) do
      if st.fixed then
        local d = geo.dist(st.lat, st.lon, s.lat, s.lon)
        if d <= bd then best, bd = st, d end
      end
    end
    return best
  end
  local restPlatforms, restPositions = {}, {}
  for _, p in ipairs(platforms) do
    local st = stationFor(p)
    if st then st.platforms[#st.platforms + 1] = p st.nodeIds[p.id] = true else restPlatforms[#restPlatforms + 1] = p end
  end
  for _, sp in ipairs(positions) do
    local st = stationFor(sp)
    if st then st.nodeIds[sp.id] = true else restPositions[#restPositions + 1] = sp end
  end
  platforms, positions = restPlatforms, restPositions

  -- positions without any platform around are stops of their own (OSM often maps only stop positions)
  local units = {}
  for _, p in ipairs(platforms) do units[#units + 1] = p end
  for _, sp in ipairs(positions) do
    local near = false
    for _, p in ipairs(platforms) do
      if geo.dist(p.lat, p.lon, sp.lat, sp.lon) <= M.POSITION_M * 2 then near = true break end
    end
    if not near then units[#units + 1] = sp end
  end
  local stations = {}
  for _, u in ipairs(units) do
    local key = M.normName(u.name)
    local home
    for _, st in ipairs(stations) do
      if key ~= '' and st.key == key and geo.dist(st.lat, st.lon, u.lat, u.lon) <= M.MERGE_M then home = st break end
    end
    if not home then
      home = { key = key, name = u.name or '', platforms = {}, nodeIds = {}, lat = u.lat, lon = u.lon }
      stations[#stations + 1] = home
    end
    home.platforms[#home.platforms + 1] = u
    home.nodeIds[u.id] = true
    local n = #home.platforms
    home.lat, home.lon = home.lat + (u.lat - home.lat) / n, home.lon + (u.lon - home.lon) / n
  end
  for _, st in ipairs(stations) do
    for _, sp in ipairs(positions) do
      for _, p in ipairs(st.platforms) do
        if geo.dist(p.lat, p.lon, sp.lat, sp.lon) <= M.POSITION_M then st.nodeIds[sp.id] = true break end
      end
    end
    st.station = #st.platforms >= 3
    st.key = nil
    out[#out + 1] = st
  end
  -- a bus station nobody calls at (no stop of it is mapped) is no place to start from
  local kept = {}
  for _, st in ipairs(out) do
    if not st.fixed or next(st.nodeIds) ~= nil then kept[#kept + 1] = st end
  end
  return kept
end

-- Stations by distance from a point (at most maxM away), each with .dist
function M.nearest(stations, lat, lon, maxM)
  local out = {}
  for _, st in ipairs(stations) do
    local d = geo.dist(lat, lon, st.lat, st.lon)
    if d <= (maxM or 1e9) then st.dist = d out[#out + 1] = st end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  return out
end

-- The routes (relations from parseAround) that call at a station
function M.routesAt(station, routes)
  local out = {}
  for _, r in ipairs(routes) do
    for id in pairs(station.nodeIds) do
      if r.nodes[id] then out[#out + 1] = r break end
    end
  end
  return out
end

-- Is what the player typed a line number ("305", "N1", "X12", "6/7") rather than a name? Letters, digits, - and / only, a digit in it.
function M.isLineRef(q)
  q = tostring(q or ''):gsub('^%s+', ''):gsub('%s+$', '')
  return #q >= 1 and #q <= 8 and q:match('^[%w/%-]+$') ~= nil and q:find('%d') ~= nil
end

-- Where a station is on a route: 'from' (the route starts here), 'to' (it ends here), 'loop' (both: a circular line), 'through'.
-- Second result: true when it is only a guess (the data has no order of stops, so the ends are compared by name).
local function sameName(a, b)
  if M.sameStopName(a, b) then return true end    -- "aut.st." = "autobusové stanoviště"
  a, b = M.normName(a), M.normName(b)
  if a == '' or b == '' then return false end
  return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- The ends of "360: A - B" / "363 A - X - B" (the ref and the stops between dropped); nil without a spaced dash.
function M.nameEnds(route)
  local n = route.name
  if type(n) ~= 'string' then return nil end
  if route.ref then n = n:gsub('^' .. tostring(route.ref):gsub('%p', '%%%0') .. '%s*:?%s*', '') end
  n = n:gsub('\226\128\147', '-'):gsub('\226\134\146', '-'):gsub('=>', '-')     -- "–" and "→"
  local parts = {}
  for p in (n .. ' - '):gmatch('(.-)%s+%-+%s+') do parts[#parts + 1] = p end
  if #parts < 2 then return nil end
  return parts[1], parts[#parts]
end

local function endOf(station, from, to)
  if not from or not to then return nil end
  local first, last = sameName(station.name, from), sameName(station.name, to)
  if first and last then return 'loop' end
  if first then return 'from' end
  if last then return 'to' end
  return nil
end

-- What the route's words (its from/to tags and its name) say: the end they agree on; nil when they say nothing or disagree
-- (tags are sometimes swapped: the name says "Teplice - Police", from/to say the other way).
local function endByWords(station, route)
  local byTags = endOf(station, route.from, route.to)
  local byName = endOf(station, M.nameEnds(route))
  if byTags and byName and byTags ~= byName then return nil end
  return byTags or byName
end

function M.placeAt(station, route)
  if route.ordered and route.n and route.n >= 2 then
    local lo, hi
    for id in pairs(station.nodeIds) do
      local p = route.places and route.places[id]
      if p then
        lo = math.min(lo or p.i, p.i)
        hi = math.max(hi or p.j, p.j)
      end
    end
    if lo then
      local first, last = lo == 1, hi == route.n
      if first and last then return 'loop', false end
      if first then return 'from', false end
      if last then return 'to', false end
      -- in the middle of the list, yet the tags and the name call it an end: the list is shuffled (360 at Police lists its
      -- stops out of order) or misses the station at its start (363 starts at the school 150 m away); the words win
      local said = endByWords(station, route)
      if said then return said, true end
      return 'through', false
    end
  end
  return endByWords(station, route) or 'through', true
end

-- Routes with the same ref (and network) are one line: { ref, colour, network, operator, variants = { route... } }.
function M.groupLines(routes)
  local lines, byKey = {}, {}
  for _, r in ipairs(routes) do
    local key = (r.ref or '') .. '|' .. lower(r.network)
    local ln = byKey[key]
    if not ln then
      ln = { ref = r.ref, colour = r.colour, network = r.network, operator = r.operator, variants = {} }
      byKey[key] = ln
      lines[#lines + 1] = ln
    end
    ln.variants[#ln.variants + 1] = r
  end
  table.sort(lines, function(a, b)
    local na, nb = tonumber(a.ref and a.ref:match('^%d+')), tonumber(b.ref and b.ref:match('^%d+'))
    if na and nb and na ~= nb then return na < nb end
    if (na ~= nil) ~= (nb ~= nil) then return na ~= nil end
    return tostring(a.ref) < tostring(b.ref)
  end)
  return lines
end

-- "from > to" of a route for lists: tags first, else the name ("308: A - B" without the ref).
function M.label(r)
  if r.from and r.to then return r.from .. ' → ' .. r.to end
  if r.name then
    local n = r.name:gsub('^' .. (r.ref or ''):gsub('%p', '%%%0') .. '%s*[:%-]?%s*', '')
    return n
  end
  return r.ref
end

M.CAND_OFF_M = 60      -- a stop is looked for at every place this near the road (a loop passes the same stop twice)
M.BACK_M = 30          -- the next stop may lie this much behind the previous one (platforms of one stop on both sides)
M.BACKWARDS_COST = 1e5

-- Stops in the order the relation lists them (public_transport:version 2) get their place along the road: a road that passes
-- the same stop twice (a loop, or the same road out and back) offers several, so the choice is the one that keeps the order
-- and stays nearest the road in total (dynamic programming over the candidates).
-- Returns the total cost and { {along, off} ... } (one per stop); the stops are not touched.
function M.fitStops(path, cum, stops)
  local cands = {}
  for i, s in ipairs(stops) do
    local _, nearest = geo.along(path, cum, s.lat, s.lon)
    cands[i] = geo.alongCandidates(path, cum, s.lat, s.lon, math.max(M.CAND_OFF_M, (nearest or 0) + 30))
  end
  local cost, from = {}, {}
  for i = 1, #stops do
    cost[i], from[i] = {}, {}
    for k, c in ipairs(cands[i]) do
      if i == 1 then
        cost[i][k] = c.off
      else
        local best, bestJ = math.huge, 1
        for j, p in ipairs(cands[i - 1]) do
          local v = cost[i - 1][j] + ((c.along >= p.along - M.BACK_M) and 0 or M.BACKWARDS_COST)
          if v < best then best, bestJ = v, j end
        end
        cost[i][k], from[i][k] = best + c.off, bestJ
      end
    end
  end
  local k, best = 1, math.huge
  for j = 1, #cands[#stops] do
    if cost[#stops][j] < best then best, k = cost[#stops][j], j end
  end
  local res = {}
  for i = #stops, 1, -1 do
    res[i] = cands[i][k]
    k = from[i][k] or 1
  end
  return best, res, cands
end

-- A closed road (a loop) started `at` metres further on: { points }; the start point is also the end.
function M.rotatePath(path, cum, at)
  local lat0, lon0 = geo.pointAt(path, cum, at)
  local out = { { lat = lat0, lon = lon0 } }
  for i = 2, #path do if cum[i] > at then out[#out + 1] = { lat = path[i].lat, lon = path[i].lon } end end
  for i = 2, #path do if cum[i] <= at then out[#out + 1] = { lat = path[i].lat, lon = path[i].lon } end end
  out[#out + 1] = { lat = lat0, lon = lon0 }
  return out
end

M.LOOP_CLOSED_M = 60

-- Places the stops along the road, turning a closed road to start where the first stop is when that fits the order better
-- (OSM lists the ways of a loop from anywhere). Returns path, cum, length (maybe rotated); sets s.along and s.off.
function M.orderedAlong(path, cum, length, stops)
  local cost, res, cands = M.fitStops(path, cum, stops)
  local closed = geo.dist(path[1].lat, path[1].lon, path[#path].lat, path[#path].lon) < M.LOOP_CLOSED_M
  if closed and cost >= M.BACKWARDS_COST * 0.5 or (closed and #cands[1] > 1) then
    local bestCost, bestPath, bestCum, bestLen, bestRes = cost, nil, nil, nil, nil
    for _, c in ipairs(cands[1]) do
      local p2 = M.rotatePath(path, cum, c.along)
      local cum2, len2 = geo.cumulative(p2)
      local cost2, res2 = M.fitStops(p2, cum2, stops)
      if cost2 < bestCost then bestCost, bestPath, bestCum, bestLen, bestRes = cost2, p2, cum2, len2, res2 end
    end
    if bestPath then path, cum, length, res = bestPath, bestCum, bestLen, bestRes end
  end
  for i, s in ipairs(stops) do s.along, s.off = res[i].along, res[i].off end
  return path, cum, length
end

-- Do two names mean one stop? "Police nad Metují, aut.st." and "Police nad Metují, autobusové stanoviště": the same words, each
-- the start of the other's.
function M.sameStopName(a, b)
  local function words(s)
    local out = {}
    for w in M.normName(s):gmatch('%S+') do out[#out + 1] = w end
    return out
  end
  local x, y = words(a), words(b)
  if #x == 0 or #x ~= #y then return false end
  for i = 1, #x do
    local p, q = x[i], y[i]
    if #p > #q then p, q = q, p end
    if q:sub(1, #p) ~= p then return false end
  end
  return true
end

M.TWIN_M = 100         -- a platform of the same name this near a stop is its twin on the other side of the road
M.SIDE_OFF_M = 40      -- a platform this near the line is on the road

-- Of a stop's platform and its twins (s.alts), the one on the right of the way of travel and nearest the road; the stop is moved
-- there. Does nothing without a twin on the right, or when the stop is on the right already.
function M.pickRight(path, cum, s)
  if not s.alts or #s.alts == 0 then return false end
  local function measure(c)
    local a, off = geo.along(path, cum, c.lat, c.lon, (s.along or 0) - 300, (s.along or 0) + 300)
    if not a then return nil end
    return { along = a, off = off, side = geo.sideOf(path, cum, a, c.lat, c.lon) }
  end
  local mine = measure(s)
  if mine and mine.side > 0 and mine.off <= M.SIDE_OFF_M then return false end
  local best, bestM
  for _, c in ipairs(s.alts) do
    local m = measure(c)
    if m and m.side > 0 and m.off <= M.SIDE_OFF_M and (not bestM or m.off < bestM.off) then best, bestM = c, m end
  end
  if not best then return false end
  local old = { id = s.id, lat = s.lat, lon = s.lon }
  for i, c in ipairs(s.alts) do if c == best then table.remove(s.alts, i) break end end
  s.alts[#s.alts + 1] = old
  s.id, s.lat, s.lon, s.along, s.off = best.id, best.lat, best.lon, bestM.along, bestM.off
  return true
end

-- A closed road (a loop) turned to start at the stop `pick`: the stops after it first, the ones before it after, and the stop it
-- started at again at the end. Returns path, cum, length, stops.
local function rotateLoop(path, cum, length, stops, pick)
  local a0 = stops[pick].along
  local p2 = M.rotatePath(path, cum, a0)
  local cum2, len2 = geo.cumulative(p2)
  local out = {}
  local n = #stops - 1                       -- the last stop is the first one again
  for k = 0, n - 1 do
    local s = stops[(pick - 1 + k) % n + 1]
    s.along = (s.along - a0) % length
    out[#out + 1] = s
  end
  local back = {}
  for key, v in pairs(stops[pick]) do back[key] = v end
  back.along = len2
  out[#out + 1] = back
  for i, s in ipairs(out) do s.index = i end
  return p2, cum2, len2, out
end

-- The full route: data = the answer of overpass.routeQuery (relation with geometry first, then its member nodes / ways
-- with tags). Returns route table (see fields below) or nil, why.
function M.parseRoute(data)
  local elems = data and data.elements or {}
  local rel = elems[1]
  if not rel or rel.type ~= 'relation' then return nil, 'no relation in the answer' end
  local tags = rel.tags or {}
  local byId = {}
  for i = 2, #elems do byId[elems[i].type .. elems[i].id] = elems[i] end

  -- 1. the way chain ----------------------------------------------------------------------------------------------
  local path, gaps = {}, 0
  local function add(p)
    local last = path[#path]
    if not (last and last.lat == p.lat and last.lon == p.lon) then path[#path + 1] = { lat = p.lat, lon = p.lon } end
  end
  for _, m in ipairs(rel.members or {}) do
    local role = m.role or ''
    if m.type == 'way' and m.geometry and #m.geometry >= 2 and (role == '' or role == 'forward' or role == 'backward' or role == 'hail_and_ride') then
      local g = m.geometry
      if #path == 0 then
        for _, p in ipairs(g) do add(p) end
      else
        local e = path[#path]
        local dStart = geo.dist(e.lat, e.lon, g[1].lat, g[1].lon)
        local dEnd = geo.dist(e.lat, e.lon, g[#g].lat, g[#g].lon)
        local forward = dStart <= dEnd
        if math.min(dStart, dEnd) > M.GAP_M then gaps = gaps + 1 end
        if forward then for i = 1, #g do add(g[i]) end else for i = #g, 1, -1 do add(g[i]) end end
      end
    end
  end

  -- 2. the stops --------------------------------------------------------------------------------------------------
  local plats, poss = {}, {}
  for _, m in ipairs(rel.members or {}) do
    if m.type == 'node' or (m.type == 'way' and (m.role or ''):sub(1, 8) == 'platform') then
      local el = byId[m.type .. m.ref]
      local etags = el and el.tags or {}
      local lat, lon = m.lat, m.lon
      if not lat and el then lat, lon = elemPoint(el) end
      if not lat and m.geometry and m.geometry[1] then lat, lon = m.geometry[1].lat, m.geometry[1].lon end
      local kind = nodeKind(etags, m.role)
      if lat and kind then
        local s = { id = m.ref, name = etags.name, lat = lat, lon = lon, role = m.role or '' }
        if kind == 'platform' then plats[#plats + 1] = s else poss[#poss + 1] = s end
      end
    end
  end
  local stops = #plats >= 2 and plats or poss
  if #stops < 2 then stops = #plats >= #poss and plats or poss end
  -- a stop_position often has no name: borrow the nearest platform's, else number it
  for i, s in ipairs(stops) do
    if not s.name or s.name == '' then
      for _, o in ipairs(stops == plats and poss or plats) do
        if o.name and geo.dist(o.lat, o.lon, s.lat, s.lon) <= M.POSITION_M * 2 then s.name = o.name break end
      end
      s.name = s.name or ('Stop ' .. i)
    end
  end
  if #stops < 2 then return nil, 'fewer than two stops in the relation' end

  -- 3. positions along the line -----------------------------------------------------------------------------------
  local cum, length = geo.cumulative(path)
  local sorted = tags['public_transport:version'] ~= '2'
  local shuffled = false
  if #path >= 2 and sorted then
    for _, s in ipairs(stops) do
      local a, off = geo.along(path, cum, s.lat, s.lon)
      s.along, s.off = a or 0, off or 0
    end
    table.sort(stops, function(x, y) return x.along < y.along end)
  elseif #path >= 2 then
    path, cum, length = M.orderedAlong(path, cum, length, stops)
    -- a list that the road cannot follow (stops shuffled in the relation, 360 at Police) is no order: by the road then, as
    -- for an old relation; one stray stop is not enough (a road passed twice needs the list's order)
    local back = 0
    for i = 2, #stops do if stops[i].along < stops[i - 1].along - M.BACK_M then back = back + 1 end end
    if back >= math.max(2, #stops * 0.2) then
      for _, s in ipairs(stops) do
        local a, off = geo.along(path, cum, s.lat, s.lon)
        s.along, s.off = a or 0, off or 0
      end
      table.sort(stops, function(x, y) return x.along < y.along end)
      shuffled = true
    end
  else
    -- no road geometry at all: a straight line through the stops
    local acc = 0
    for i, s in ipairs(stops) do
      if i > 1 then acc = acc + geo.dist(stops[i - 1].lat, stops[i - 1].lon, s.lat, s.lon) end
      s.along, s.off = acc, 0
    end
    for _, s in ipairs(stops) do path[#path + 1] = { lat = s.lat, lon = s.lon } end
    cum, length = geo.cumulative(path)
    gaps = gaps + 1
  end
  -- OSM often lists both sides' platforms of one stop (one per direction): in order, a stop with the same name close to
  -- the previous one is the same stop; the platform nearer the line is kept
  local merged = {}
  for _, s in ipairs(stops) do
    local prev = merged[#merged]
    if prev and M.normName(prev.name) == M.normName(s.name) and geo.dist(prev.lat, prev.lon, s.lat, s.lon) < M.MERGE_M then
      if (s.off or 0) < (prev.off or 0) then merged[#merged] = s end
    else
      merged[#merged + 1] = s
    end
  end
  stops = merged
  if #stops < 2 then return nil, 'fewer than two distinct stops in the relation' end
  for i, s in ipairs(stops) do s.index = i end

  -- the platform on the right of the way of travel, when the map has one on each side (the answer holds the bus stops near the
  -- road too, not only the ones the relation lists)
  if #path >= 2 then
    local listed = {}
    for _, m in ipairs(rel.members or {}) do if m.type == 'node' then listed[m.ref] = true end end
    local extras = {}
    for i = 2, #elems do
      local e = elems[i]
      local tg = e.tags or {}
      if e.type == 'node' and not listed[e.id] and e.lat and tg.name and (tg.highway == 'bus_stop' or tg.public_transport == 'platform') then
        extras[#extras + 1] = { id = e.id, lat = e.lat, lon = e.lon, name = tg.name }
      end
    end
    if #extras > 0 then
      for _, s in ipairs(stops) do
        s.alts = {}
        for _, x in ipairs(extras) do
          if x.id ~= s.id and M.normName(x.name) == M.normName(s.name) and geo.dist(x.lat, x.lon, s.lat, s.lon) <= M.TWIN_M then
            s.alts[#s.alts + 1] = { id = x.id, lat = x.lat, lon = x.lon }
          end
        end
        M.pickRight(path, cum, s)
      end
    end
  end

  local first, last = stops[1], stops[#stops]
  local loop = M.normName(first.name) == M.normName(last.name) and geo.dist(first.lat, first.lon, last.lat, last.lon) < 150
  local rotated = false
  -- a circular line starts where the map says it does ("from" names the bus station, the relation lists the school first)
  if loop and #stops >= 4 and tags.from and geo.dist(path[1].lat, path[1].lon, path[#path].lat, path[#path].lon) < M.LOOP_CLOSED_M then
    for i = 2, #stops - 1 do
      if M.sameStopName(stops[i].name, tags.from) then
        path, cum, length, stops = rotateLoop(path, cum, length, stops, i)
        first, last = stops[1], stops[#stops]
        rotated = true
        break
      end
    end
  end
  local head = M.routeHead(rel, tags)
  head.nodes = nil
  head.stops, head.path, head.cum, head.length = stops, path, cum, length
  head.gaps, head.loop = gaps, loop
  head.rotated = rotated or nil
  head.shuffled = shuffled or nil
  head.incomplete = gaps > 0 or #stops < 2 or (tags.complete == 'no')
  head.kind = M.kind(head)
  head.from = head.from or first.name
  head.to = head.to or last.name
  if loop then head.from, head.to = first.name, last.name end
  return head
end

-- 'night' | 'regional' | 'city'
function M.kind(r)
  local tags = r.tags or {}
  if tags.night_service == 'yes' or lower(tags.bus) == 'night' or (r.ref or ''):match('^[Nn]%d') or lower(r.name):find('night') or lower(r.name):find('noční') then
    return 'night'
  end
  local n = r.stops and #r.stops or 0
  local avg = n > 1 and (r.length or 0) / (n - 1) or 0
  if (r.length or 0) > 12000 or avg > 1300 then return 'regional' end
  return 'city'
end

-- The same route driven the other way, for lines whose opposite direction is not in the map data: the same road and the same stops
-- in reverse order. id = -(the route's id) (OSM ids are big, ids of routes built by hand are small negative numbers).
function M.reversed(route)
  local n = #route.stops
  -- only the stretch of road between the first and the last stop (a relation may list ways beyond them)
  local a0, a1 = route.stops[1].along or 0, route.stops[n].along or route.length or 0
  if a1 - a0 < 100 then a0, a1 = 0, route.length or 0 end
  local stops = {}
  for i = n, 1, -1 do
    local s = route.stops[i]
    stops[#stops + 1] = { id = s.id, name = s.name, lat = s.lat, lon = s.lon, role = s.role, off = s.off, station = s.station,
      along = math.min(a1 - a0, math.max(0, a1 - (s.along or 0))), alts = s.alts }
    stops[#stops].index = #stops
  end
  local inside = { }
  local lat0, lon0 = geo.pointAt(route.path, route.cum, a0)
  local lat1, lon1 = geo.pointAt(route.path, route.cum, a1)
  inside[1] = { lat = lat0, lon = lon0 }
  for i = 1, #route.path do
    if route.cum[i] > a0 and route.cum[i] < a1 then inside[#inside + 1] = { lat = route.path[i].lat, lon = route.path[i].lon } end
  end
  inside[#inside + 1] = { lat = lat1, lon = lon1 }
  local path = {}
  for i = #inside, 1, -1 do path[#path + 1] = inside[i] end
  local cum, length = geo.cumulative(path)
  for _, s in ipairs(stops) do
    if s.alts then
      local alts = {}
      for k, v in ipairs(s.alts) do alts[k] = v end
      s.alts = alts
      M.pickRight(path, cum, s)               -- going the other way the platform on the right is the one across the road
    end
  end
  local name = route.name
  if route.from and route.to then name = (route.ref or '') .. ': ' .. route.to .. ' => ' .. route.from end
  local r = {}
  for k, v in pairs(route) do r[k] = v end
  r.id, r.name, r.from, r.to = -route.id, name, route.to, route.from
  r.stops, r.path, r.cum, r.length = stops, path, cum, length
  r.reversedOf, r.synthetic = route.id, true
  return r
end

-- The opposite direction of `route` among `candidates` (other parsed routes or heads): same ref, swapped ends.
-- Loops have none. Returns the candidate or nil.
function M.reverseOf(route, candidates)
  if route.loop then return nil end
  local a, b = M.normName(route.from), M.normName(route.to)
  local first = route.stops and route.stops[1] and M.normName(route.stops[1].name) or a
  local last = route.stops and route.stops[#route.stops] and M.normName(route.stops[#route.stops].name) or b
  for _, c in ipairs(candidates) do
    if c.id ~= route.id and c.ref == route.ref and lower(c.network) == lower(route.network) then
      local cf, ct = M.normName(c.from), M.normName(c.to)
      if c.stops and c.stops[1] then
        cf, ct = M.normName(c.stops[1].name), M.normName(c.stops[#c.stops].name)
      end
      if (cf == last and ct == first) or (cf == b and ct == a and a ~= '' and b ~= '') then return c end
    end
  end
  return nil
end

return M
