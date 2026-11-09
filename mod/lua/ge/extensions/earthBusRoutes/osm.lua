-- Parsing of Overpass answers into stops, stations, lines and routes. Pure logic (no game calls): the tests run it under
-- lupa on recorded answers (tests/fixtures). Overpass queries live in overpass.lua.
local geo = require('earthBusRoutes/geomath')
local M = {}

M.MERGE_M = 150        -- same-named platforms closer than this are one stop (one platform per direction)
M.POSITION_M = 60      -- a stop_position this close to a platform belongs to the same stop
M.GAP_M = 40           -- a hole in a route's way chain bigger than this makes the route "incomplete"

local function lower(s) return type(s) == 'string' and s:lower() or '' end

-- Names compare without case, spaces, punctuation ("Náchod, nám." and "nachod nam" are not equal, but "Náchod  nám" and
-- "náchod nám" are): good enough to join a stop's two platforms, which OSM names alike.
function M.normName(s)
  s = lower(s or '')
  s = s:gsub('[%s%p]+', ' '):gsub('^ ', ''):gsub(' $', '')
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
        local nodes = {}
        for _, m in ipairs(e.members or {}) do
          if m.type == 'node' then nodes[m.ref] = true end
        end
        out.routes[#out.routes + 1] = M.routeHead(e, tags, nodes)
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
-- Returns stations { {name, lat, lon, platforms = {..}, nodeIds = set, station = bool} } (unsorted).
function M.groupStops(stops)
  local platforms, positions = {}, {}
  for _, s in ipairs(stops) do
    if s.kind == 'platform' then platforms[#platforms + 1] = s else positions[#positions + 1] = s end
  end
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
  end
  return stations
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
  if #path >= 2 then
    local prev = 0
    for _, s in ipairs(stops) do
      local a, off = geo.along(path, cum, s.lat, s.lon, (not sorted) and math.max(0, prev - 30) or nil)
      if not a then a, off = geo.along(path, cum, s.lat, s.lon) end
      s.along, s.off = a or prev, off or 0
      prev = s.along
    end
    if sorted then table.sort(stops, function(x, y) return x.along < y.along end) end
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
  for i, s in ipairs(stops) do s.index = i end

  local first, last = stops[1], stops[#stops]
  local loop = M.normName(first.name) == M.normName(last.name) and geo.dist(first.lat, first.lon, last.lat, last.lon) < 150
  local head = M.routeHead(rel, tags)
  head.nodes = nil
  head.stops, head.path, head.cum, head.length = stops, path, cum, length
  head.gaps, head.loop = gaps, loop
  head.incomplete = gaps > 0 or #stops < 2 or (tags.complete == 'no')
  head.kind = M.kind(head)
  head.from = head.from or first.name
  head.to = head.to or last.name
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
