-- What the menu shows, as plain tables for the Vue pages (pure: the tests run it). main.lua keeps the state and calls
-- these to turn parsed data into the page's model.
local geo = require('earthBusRoutes/geomath')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local M = {}

M.MAX_STATIONS = 12
M.NEAR_M = 600

function M.clockLabel(sec)
  sec = math.floor(sec % 86400)
  return ('%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

local COMPASS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
function M.compass(bearing) return COMPASS[math.floor(((bearing % 360) + 22.5) / 45) % 8 + 1] end

-- The lines (refs with colours) calling at a station, unique, in number order
function M.linesAt(station, routes)
  return osm.groupLines(osm.routesAt(station, routes))
end

-- The nearest stations as the first screen shows them
function M.nearbyModel(stations, routes, lat, lon)
  local near = osm.nearest(stations, lat, lon, M.NEAR_M)
  local out = {}
  for i = 1, math.min(#near, M.MAX_STATIONS) do
    local st = near[i]
    local lines = M.linesAt(st, routes)
    local chips = {}
    for k = 1, math.min(#lines, 10) do chips[k] = { ref = lines[k].ref, colour = lines[k].colour } end
    out[i] = { id = i, name = st.name ~= '' and st.name or 'Bus stop', dist = math.floor(st.dist + 0.5),
      dir = M.compass(geo.bearing(lat, lon, st.lat, st.lon)), station = st.station, platforms = #st.platforms,
      lat = st.lat, lon = st.lon, lines = chips, lineCount = #lines, ref = st }
  end
  return out
end

-- Lines of one station with every variant (direction / branch) the data lists
function M.linesModel(station, routes)
  local lines = M.linesAt(station, routes)
  local out = {}
  for i, ln in ipairs(lines) do
    local variants = {}
    local seen = {}
    for _, r in ipairs(ln.variants) do seen[r.to or ''] = (seen[r.to or ''] or 0) + 1 end
    local used = {}
    for k, r in ipairs(ln.variants) do
      local v = { id = r.id, label = osm.label(r), from = r.from, to = r.to, ref = r.ref }
      -- several variants of one line with the same destination (a way via a village, a short run): tell them apart by the
      -- relation's own name ("309: Rychnov => Provodov => Náchod"), else by a counter
      if r.to and seen[r.to] > 1 then
        v.ambiguous = true
        v.label = r.name and osm.label({ ref = r.ref, name = r.name }) or v.label
        used[v.label] = (used[v.label] or 0) + 1
        if used[v.label] > 1 then v.label = v.label .. ' (' .. used[v.label] .. ')' end
      end
      variants[k] = v
    end
    out[i] = { id = i, ref = ln.ref, colour = ln.colour, network = ln.network, operator = ln.operator, variants = variants }
  end
  return out
end

-- Index of the route's stop nearest to a point (the station the player is at)
function M.nearestStopIndex(route, lat, lon)
  local best, bestD = 1, math.huge
  for i, s in ipairs(route.stops) do
    local d = geo.dist(lat, lon, s.lat, s.lon)
    if d < bestD then best, bestD = i, d end
  end
  return best, bestD
end

-- Info card of a route
function M.routeModel(route, trips, day, ctx)
  local stops = {}
  for i, s in ipairs(route.stops) do
    stops[i] = { i = i, name = s.name, km = math.floor(s.along / 100 + 0.5) / 10, lat = s.lat, lon = s.lon }
  end
  local mid = trips[math.max(1, math.floor(#trips / 2))]
  local minutes = mid and math.floor((mid.arr[#route.stops] or 0) / 60 + 0.5) or nil
  local periods = {}
  for i, p in ipairs(sched.summary(route, day, ctx)) do
    periods[i] = { from = p.from, to = p.to, minutes = p.minutes and math.floor(p.minutes * 10 + 0.5) / 10 or nil, peak = p.peak }
  end
  return {
    id = route.id, ref = route.ref, colour = route.colour, name = route.name, from = route.from, to = route.to,
    network = route.network, operator = route.operator, kind = route.kind, loop = route.loop,
    km = math.floor(route.length / 100 + 0.5) / 10, stopCount = #route.stops, minutes = minutes,
    incomplete = route.incomplete or false, gaps = route.gaps, stops = stops, periods = periods,
    custom = route.custom or false, straight = route.straight or false,
    tripsToday = #trips, first = trips[1] and M.clockLabel(trips[1].start) or nil,
    last = trips[#trips] and M.clockLabel(trips[#trips].start) or nil,
  }
end

-- Departure choices from stop `index` at or after `sec` (a day's trips); wraps to tomorrow's first ones.
function M.departuresModel(trips, index, sec, count)
  count = count or 8
  local deps = sched.departures(trips, index, sec, count)
  local out, tomorrow = {}, false
  if #deps == 0 and #trips > 0 then
    deps = sched.departures(trips, index, 0, count)
    tomorrow = true
  end
  for i, d in ipairs(deps) do
    out[i] = { trip = d.trip.id, sec = d.at, label = M.clockLabel(d.at), arrive = d.arrive, tomorrow = tomorrow }
  end
  return out, tomorrow
end

return M
