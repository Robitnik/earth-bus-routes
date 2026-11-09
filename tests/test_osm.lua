local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local T = {}

local NACHOD = { 50.4157, 16.1626 }

function T.around_parses_stops_and_routes()
  local a = osm.parseAround(H.fixture('nachod_around'))
  assert(#a.stops >= 8, #a.stops)
  assert(#a.routes == 11, #a.routes)
  for _, s in ipairs(a.stops) do assert(s.lat and s.lon and (s.kind == 'platform' or s.kind == 'stop')) end
end

function T.stations_group_platforms_and_find_routes()
  local a = osm.parseAround(H.fixture('nachod_around'))
  local sts = osm.groupStops(a.stops)
  assert(#sts >= 3 and #sts < #a.stops, #sts)
  local near = osm.nearest(sts, NACHOD[1], NACHOD[2], 600)
  assert(#near >= 3)
  assert(near[1].dist <= near[2].dist)
  local any = 0
  for _, st in ipairs(near) do any = any + #osm.routesAt(st, a.routes) end
  assert(any > 0, 'no station has a route')
end

function T.slim_answer_gives_the_same_stations_and_routes()
  local full = osm.parseAround(H.fixture('nachod_around'))
  local slim = osm.parseAround(H.fixture('nachod_around_slim'))
  assert(#slim.routes == #full.routes and #slim.stops == #full.stops)
  local near = osm.nearest(osm.groupStops(slim.stops), NACHOD[1], NACHOD[2], 600)
  local nearFull = osm.nearest(osm.groupStops(full.stops), NACHOD[1], NACHOD[2], 600)
  for i = 1, math.min(#near, 5) do
    assert(#osm.routesAt(near[i], slim.routes) == #osm.routesAt(nearFull[i], full.routes), 'station ' .. i)
  end
end

function T.lines_group_variants_by_ref()
  local a = osm.parseAround(H.fixture('nachod_around'))
  local lines = osm.groupLines(a.routes)
  assert(#lines < #a.routes)
  local n309
  for _, l in ipairs(lines) do if l.ref == '309' then n309 = #l.variants end end
  assert(n309 == 4, n309)
  assert(lines[1].ref == '302', lines[1].ref)   -- numeric order
  assert(lines[1].colour:match('^#%x%x%x%x%x%x$'))
end

function T.colour_is_stable_and_tag_wins()
  assert(osm.colorFor('308') == osm.colorFor('308'))
  assert(osm.colorFor('308') ~= osm.colorFor('309'))
  assert(osm.colorFor('1', '#FF0000') == '#ff0000')
  assert(osm.colorFor('1', '#f00') == '#ff0000')
  assert(osm.colorFor('1', 'red'):match('^#'))
end

function T.ptv2_route_308()
  local r = assert(osm.parseRoute(H.fixture('route_6962840')))
  assert(r.ref == '308' and r.network == 'IREDO')
  assert(#r.stops == 28, #r.stops)
  assert(r.stops[1].name and r.stops[#r.stops].name)
  assert(r.length > 5000 and r.length < 40000, r.length)
  -- member order kept for PTv2 and consistent with the line: stops go forward along it
  local back = 0
  for i = 2, #r.stops do if r.stops[i].along < r.stops[i - 1].along - 50 then back = back + 1 end end
  assert(back <= 2, 'stops jump back ' .. back .. ' times')
  assert(r.kind == 'regional', r.kind)
end

function T.ptv1_route_305_is_sorted_along_the_line()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  assert(#r.stops >= 8, #r.stops)
  for i = 2, #r.stops do assert(r.stops[i].along >= r.stops[i - 1].along, 'unsorted at ' .. i) end
  assert(r.from and r.to)               -- filled from the first / last stop when the tags lack them
end

function T.way_chain_is_connected()
  local r = assert(osm.parseRoute(H.fixture('route_6962840')))
  local worst = 0
  for i = 2, #r.path do
    worst = math.max(worst, geo.dist(r.path[i - 1].lat, r.path[i - 1].lon, r.path[i].lat, r.path[i].lon))
  end
  assert(r.gaps == 0 or r.incomplete)
  assert(worst < 2000, worst)
end

function T.broken_input_is_refused()
  local r, why = osm.parseRoute({ elements = {} })
  assert(r == nil and why)
  local r2 = osm.parseRoute({ elements = { { type = 'relation', id = 1, tags = { ref = '1' }, members = {} } } })
  assert(r2 == nil)
end

function T.reverse_pairing()
  local a = { id = 1, ref = '9', network = 'N', from = 'Alpha', to = 'Beta' }
  local b = { id = 2, ref = '9', network = 'N', from = 'Beta', to = 'Alpha' }
  local c = { id = 3, ref = '9', network = 'N', from = 'Alpha', to = 'Gamma' }
  assert(osm.reverseOf(a, { a, c, b }) == b)
  assert(osm.reverseOf(a, { a, c }) == nil)
  assert(osm.reverseOf({ id = 4, ref = '9', network = 'N', loop = true }, { b }) == nil)
end

function T.geo_basics()
  assert(math.abs(geo.dist(50, 16, 50, 16.001) - 71.5) < 1)
  local path = { { lat = 50, lon = 16 }, { lat = 50.001, lon = 16 }, { lat = 50.001, lon = 16.001 } }
  local cum, total = geo.cumulative(path)
  assert(math.abs(total - (111.2 + 71.5)) < 1.5, total)
  local a, off = geo.along(path, cum, 50.0005, 16.0001)
  assert(math.abs(a - 55.6) < 2 and off < 10, a .. ' ' .. off)
  local lat, lon = geo.pointAt(path, cum, total + 100)
  assert(lat == 50.001 and lon == 16.001)
end

return T
