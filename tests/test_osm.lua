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

function T.bus_station_takes_its_numbered_platforms()
  local base = { 50.0, 16.0 }
  local function node(id, kind, name, dlat, dlon, extra)
    local t = { id = id, kind = kind, name = name, lat = base[1] + dlat, lon = base[2] + dlon, tags = {} }
    return t
  end
  local stops = {
    node(1, 'station', 'Autobusove nadrazi', 0, 0),
    node(2, 'platform', '1', 0.0003, 0.0002), node(3, 'platform', '2', 0.0004, 0.0003), node(4, 'platform', 'V3', -0.0003, 0.0004),
    node(5, 'stop', nil, 0.0003, 0.0002),
    node(6, 'platform', 'Skolni', 0.01, 0.01),                 -- an ordinary stop far from the station
    node(7, 'station', 'Empty station', 0.05, 0.05),           -- a station nobody calls at
  }
  local st = osm.groupStops(stops)
  assert(#st == 2, #st)                                           -- the station and the far stop
  local station
  for _, s in ipairs(st) do if s.station then station = s end end
  assert(station and station.name == 'Autobusove nadrazi' and #station.platforms == 3)
  assert(station.nodeIds[2] and station.nodeIds[3] and station.nodeIds[4] and station.nodeIds[5] and not station.nodeIds[6])
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

-- Line 363 at Police nad Metují: a loop that passes its first stop twice and goes to Suchý Důl and back along the same road
function T.loop_with_an_out_and_back_keeps_its_stops_in_order()
  local r = assert(osm.parseRoute(H.fixture('route_7185111')))
  assert(r.loop and #r.stops == 14, #r.stops)
  assert(r.length > 13500 and r.length < 15000)
  assert(r.stops[1].along < 100, 'the first stop is at the start, not at the end of the loop: ' .. r.stops[1].along)
  assert(r.stops[#r.stops].along > r.length - 400, r.stops[#r.stops].along)
  for i, s in ipairs(r.stops) do
    assert(s.off <= 40, ('stop %d %s is %.0f m off the road'):format(i, s.name, s.off))
    if i > 1 then assert(s.along >= r.stops[i - 1].along - 30, ('stop %d goes backwards'):format(i)) end
  end
  -- Suchý Důl is passed on the way out and on the way back: both visits keep their own place
  local first, second
  for i, s in ipairs(r.stops) do
    if s.name == 'Suchý Důl, MŠ' then if first then second = s else first = s end end
  end
  assert(first and second and second.along - first.along > 500)
  -- the ride is spread over the line (the timetable depends on it)
  local sched = require('earthBusRoutes/schedule')
  local trips = sched.generate(r, 2)
  assert(#trips > 0 and trips[1].arr[#r.stops] > 15 * 60)
end

function T.short_branch_pair_still_found()
  local a = assert(osm.parseRoute(H.fixture('route_11872572')))
  local b = assert(osm.parseRoute(H.fixture('route_11872574')))
  assert(#a.stops == 2 and #b.stops == 2)
  assert(a.stops[2].along > a.stops[1].along and b.stops[2].along > b.stops[1].along)
  local back = osm.reverseOf(a, { a, b })
  assert(back and back.id == b.id)
end

function T.reversed_route_runs_the_same_road_the_other_way()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  local b = osm.reversed(r)
  assert(b.id == -r.id and b.from == r.to and b.to == r.from and b.synthetic and b.reversedOf == r.id)
  assert(#b.stops == #r.stops and b.stops[1].name == r.stops[#r.stops].name and b.stops[#b.stops].name == r.stops[1].name)
  assert(math.abs(b.length - (r.stops[#r.stops].along - r.stops[1].along)) < 5, 'only the road between the first and the last stop')
  assert(b.stops[1].along < 5 and b.length - b.stops[#b.stops].along < 5)
  for i, s in ipairs(b.stops) do
    assert(s.index == i)
    if i > 1 then assert(s.along >= b.stops[i - 1].along) end
  end
  local geo = require('earthBusRoutes/geomath')
  assert(geo.dist(b.path[1].lat, b.path[1].lon, r.stops[#r.stops].lat, r.stops[#r.stops].lon) < 60, 'it starts at the last stop of the original')
  assert(b.ref == r.ref and b.colour == r.colour and b.kind == r.kind)
  local again = osm.reversed(b)
  assert(again.id == r.id and again.from == r.from and again.stops[1].name == r.stops[1].name)
  assert(math.abs(again.length - b.length) < 5)
  -- it has a timetable like any route
  local sched = require('earthBusRoutes/schedule')
  assert(#sched.generate(b, 2) > 5)
end

function T.a_circular_line_starts_where_the_map_says()
  local r = assert(osm.parseRoute(H.fixture('route_7185111')))
  assert(r.rotated and r.loop and #r.stops == 14)
  assert(r.stops[1].name == 'Police nad Metují, aut.st.' and r.stops[#r.stops].name == r.stops[1].name,
    'a trip starts and ends at the bus station, not at the school: ' .. r.stops[1].name .. ' / ' .. r.stops[#r.stops].name)
  assert(r.stops[1].along < 5 and math.abs(r.stops[#r.stops].along - r.length) < 5)
  for i, s in ipairs(r.stops) do
    assert(s.off <= 40, ('stop %d %s is %.0f m off the road'):format(i, s.name, s.off))
    if i > 1 then assert(s.along >= r.stops[i - 1].along - 30, ('stop %d goes backwards'):format(i)) end
  end
  -- the school, the old first stop, is the second now
  assert(r.stops[2].name == 'Police nad Metují, škola')
end

-- 360 Police → Teplice: a PTv2 relation whose platforms are listed shuffled (the road is in order, from the bus station):
-- the stops go by the road then, and the trip starts at the bus station.
function T.shuffled_stops_go_by_the_road()
  local r = assert(osm.parseRoute(H.fixture('route_6978584')))
  assert(r.shuffled, 'the list is seen to be out of order')
  assert(r.stops[1].name == 'Police nad Metují, aut.st.', 'first: ' .. r.stops[1].name)
  assert(r.stops[2].name == 'Police nad Metují, škola')
  for i = 2, #r.stops do
    assert(r.stops[i].along >= r.stops[i - 1].along, ('stop %d %s goes backwards'):format(i, r.stops[i].name))
  end
  -- a list in order is left alone
  local loop = assert(osm.parseRoute(H.fixture('route_7185111')))
  assert(not loop.shuffled)
end

-- A line of the national timetables (service 0.8.0 asks the routing server for the road through the stops): the mod reads it
-- like a relation, and the stops carry their real times.
function T.a_line_of_the_timetables_is_a_route_with_real_times()
  local r = assert(osm.parseRoute(H.fixture('route_gtfs_360')))
  assert(#r.stops == 12 and r.stops[1].name == 'Police n.Met.,aut.st.', 'first: ' .. tostring(r.stops[1].name))
  assert(r.timetable == 'gtfs' and #r.gtfsOffs == 12 and r.gtfsOffs[1] == 0 and r.gtfsOffs[12] == 1320)
  for i = 2, #r.stops do
    assert(r.stops[i].along >= r.stops[i - 1].along - 30, ('stop %d goes backwards'):format(i))
    assert(r.gtfsOffs[i] >= r.gtfsOffs[i - 1])
  end
  local sched = require('earthBusRoutes/schedule')
  local trips = sched.generate(r, 3)                                  -- a Wednesday
  assert(#trips >= 3 and trips[1].start == 19500 and trips[2].start == 23100 and trips[3].start == 26520, 'the real departures: ' .. #trips)
  assert(sched.scheduled(trips[1], 12) == 19500 + 1320, 'the last stop 22 minutes after the start')
  -- a Saturday has its own list
  local sat = sched.generate(r, 6)
  assert(#sat >= 2 and sat[1].start == 27660)
  -- the made-up opposite direction has no real times (they would be the wrong way round)
  local back = osm.reversed(r)
  assert(back.timetable == nil and back.gtfsOffs == nil)
  assert(#sched.generate(back, 3) > 5, 'generated instead')
end

function T.a_loop_of_the_timetables_keeps_its_first_stop()
  local r = assert(osm.parseRoute(H.fixture('route_gtfs_363')))
  assert(r.stops[1].name == 'Police n.Met.,aut.st.' and r.stops[#r.stops].name == r.stops[1].name)
  assert(not r.rotated, 'the timetable says where it starts')
  assert(r.timetable == 'gtfs' and r.gtfsOffs[#r.stops] > 1500)
end

function T.same_stop_name_reads_abbreviations()
  assert(osm.sameStopName('Police nad Metují, aut.st.', 'Police nad Metují, autobusové stanoviště'))
  assert(osm.sameStopName('Náchod, aut. nádraží', 'Náchod, autobusové nádraží'))
  assert(not osm.sameStopName('Police nad Metují, škola', 'Police nad Metují, autobusové stanoviště'))
  assert(not osm.sameStopName('Police', 'Police nad Metují'))
  assert(not osm.sameStopName('', 'x'))
end

-- A straight road going east at latitude 50, three stops; each platform 10 m south (the right of the way of travel) unless
-- `north` says it is on the north side. `twins`: the stops that also have the platform of the other side, not listed in the relation.
local function eastRoad(north, twins)
  local d = 10 / 111195
  local pts, members, nodes = {}, {}, {}
  for i = 0, 8 do pts[#pts + 1] = { lat = 50.0, lon = 16.0 + i * 0.005 } end
  members[1] = { type = 'way', ref = 10, role = '', geometry = pts }
  local names = { 'Alpha', 'Bravo', 'Charlie' }
  local lons = { 16.004, 16.02, 16.036 }
  for i, nm in ipairs(names) do
    local lat = (north and north[i]) and (50.0 + d) or (50.0 - d)
    members[#members + 1] = { type = 'node', ref = 100 + i, role = 'platform', lat = lat, lon = lons[i] }
    nodes[#nodes + 1] = { type = 'node', id = 100 + i, lat = lat, lon = lons[i], tags = { name = nm, highway = 'bus_stop', public_transport = 'platform' } }
    if twins and twins[i] then
      local tl = (north and north[i]) and (50.0 - d) or (50.0 + d)
      nodes[#nodes + 1] = { type = 'node', id = 200 + i, lat = tl, lon = lons[i], tags = { name = nm, highway = 'bus_stop', public_transport = 'platform' } }
    end
  end
  local els = { { type = 'relation', id = 1, tags = { type = 'route', route = 'bus', ref = 'X', ['public_transport:version'] = '2', from = 'Alpha', to = 'Charlie' }, members = members } }
  for _, n in ipairs(nodes) do els[#els + 1] = n end
  return { elements = els }
end

function T.the_platform_on_the_right_of_the_way_of_travel_is_taken()
  local geo = require('earthBusRoutes/geomath')
  -- Bravo's listed platform is on the north (the left going east); its twin on the south is not listed
  local r = assert(osm.parseRoute(eastRoad({ [2] = true }, { [2] = true })))
  assert(#r.stops == 3)
  assert(r.stops[1].id == 101 and r.stops[3].id == 103, 'platforms already on the right stay')
  assert(r.stops[2].id == 202, 'the twin on the right is taken: ' .. tostring(r.stops[2].id))
  assert(geo.sideOf(r.path, r.cum, r.stops[2].along, r.stops[2].lat, r.stops[2].lon) > 0)
  assert(r.stops[2].off < 15)
  -- the other direction: the platform that was on the left is on the right
  local b = osm.reversed(r)
  assert(b.stops[1].name == 'Charlie' and b.stops[2].name == 'Bravo')
  assert(b.stops[2].id == 102, 'going back the north platform is the right one: ' .. tostring(b.stops[2].id))
  assert(geo.sideOf(b.path, b.cum, b.stops[2].along, b.stops[2].lat, b.stops[2].lon) > 0)
  -- the others had no twin: they stay (the nearest there is)
  assert(b.stops[1].id == 103 and b.stops[3].id == 101)
end

function T.a_platform_already_on_the_right_is_kept()
  local r = assert(osm.parseRoute(eastRoad(nil, { true, true, true })))
  for i, id in ipairs({ 101, 102, 103 }) do assert(r.stops[i].id == id, 'stop ' .. i .. ' ' .. r.stops[i].id) end
end

function T.without_twins_nothing_changes()
  local r = assert(osm.parseRoute(eastRoad({ true, true, true }, nil)))
  for i, id in ipairs({ 101, 102, 103 }) do assert(r.stops[i].id == id) end
  local b = osm.reversed(r)
  assert(b.stops[1].id == 103)
end

-- ---- speed limits (speedlimit.lua, osm.parseRoute) ----------------------------------------------------------------------

function T.maxspeed_values_are_understood()
  local sl = require('earthBusRoutes/speedlimit')
  assert(sl.parse('50') == 50 and sl.parse(' 70 ') == 70 and sl.parse('50 km/h') == 50)
  assert(sl.parse('30 mph') == 48 and sl.parse('60 mph') == 97)
  assert(sl.parse('CZ:urban') == 50 and sl.parse('CZ:rural') == 90 and sl.parse('CZ:motorway') == 130)
  assert(sl.parse('DE:urban') == 50 and sl.parse('DE:rural') == 100 and sl.parse('DE:motorway') == false)
  assert(sl.parse('GB:nsl_single') == nil)                   -- a name we do not know: the country's rule decides
  assert(sl.parse('walk') == 7 and sl.parse('CZ:living_street') == 20 and sl.parse('DE:zone30') == 30)
  assert(sl.parse('none') == false and sl.parse('signals') == false)
  assert(sl.parse('50;70') == 50 and sl.parse('') == nil and sl.parse('fast') == nil and sl.parse('3') == nil)
  assert(sl.wayKmh({ maxspeed = '70' }, 'CZ', true) == 70)
  assert(sl.wayKmh({ ['maxspeed:forward'] = '60', ['maxspeed:backward'] = '40' }, 'CZ', true) == 60)
  assert(sl.wayKmh({ ['maxspeed:forward'] = '60', ['maxspeed:backward'] = '40' }, 'CZ', false) == 40)
  assert(sl.wayKmh({ maxspeed = 'CZ:urban' }, 'CZ', true) == 50)
  assert(sl.wayKmh({ ['maxspeed:type'] = 'CZ:rural' }, nil, true) == 90)
  assert(sl.wayKmh({ highway = 'motorway' }, 'CZ', true) == 130 and sl.wayKmh({ highway = 'motorway' }, 'DE', true) == false)
  assert(sl.wayKmh({ highway = 'residential' }, 'CZ', true) == nil and sl.wayKmh(nil, 'CZ', true) == nil)
  assert(sl.leftHand('GB') and sl.leftHand('IE') and not sl.leftHand('CZ') and not sl.leftHand(nil))
end

-- the route 308 of the fixtures with `way` elements (as the data service's Overpass answer has) tagged in thirds
local function tagged(limits)
  local data = H.fixture('route_6962840')
  local rel = data.elements[1]
  local refs = {}
  for _, m in ipairs(rel.members) do if m.type == 'way' then refs[#refs + 1] = m end end
  local third = math.floor(#refs / 3)
  for i, m in ipairs(refs) do
    local tags = nil
    if i <= third then tags = { highway = 'secondary', maxspeed = '70' }
    elseif i <= 2 * third then tags = { highway = 'residential', maxspeed = 'CZ:urban' } end
    data.elements[#data.elements + 1] = { type = 'way', id = m.ref, tags = tags or { highway = 'tertiary' } }
  end
  rel.limits = limits
  return data, refs, third
end

local function limitAtMiddleOf(r, member)
  local g = member.geometry
  local k = math.max(1, math.floor(#g / 2))
  local a = geo.along(r.path, r.cum, (g[k].lat + g[k + 1].lat) / 2, (g[k].lon + g[k + 1].lon) / 2)
  return require('earthBusRoutes/speedlimit').at(r, a)
end

function T.a_route_gets_the_limits_of_its_ways()
  local sl = require('earthBusRoutes/speedlimit')
  local data, refs, third = tagged({ cc = 'CZ', towns = {} })
  local r = assert(osm.parseRoute(data))
  assert(r.limitInfo and r.limitInfo.cc == 'CZ')
  assert(limitAtMiddleOf(r, refs[2]) == 70, tostring(limitAtMiddleOf(r, refs[2])))
  assert(limitAtMiddleOf(r, refs[third + 2]) == 50)             -- "CZ:urban"
  assert(limitAtMiddleOf(r, refs[#refs - 1]) == 90)             -- untagged, no town near: outside a town
  local rev = osm.reversed(r)                                    -- the same road the other way: the same limits at the same places
  assert(sl.at(rev, 5) ~= nil)
  local g = refs[2].geometry
  local mid = { (g[1].lat + g[2].lat) / 2, (g[1].lon + g[2].lon) / 2 }
  assert(sl.at(rev, (geo.along(rev.path, rev.cum, mid[1], mid[2]))) == 70)
end

function T.untagged_roads_are_built_up_near_a_town()
  local sl = require('earthBusRoutes/speedlimit')
  local data, refs = tagged(nil)
  local last = refs[#refs - 1].geometry
  local c = last[math.floor(#last / 2)]
  data.elements[1].limits = { cc = 'CZ', towns = { { c.lat, c.lon, 1500 } } }
  local r = assert(osm.parseRoute(data))
  assert(limitAtMiddleOf(r, refs[#refs - 1]) == 50, 'in the town')
  assert(limitAtMiddleOf(r, refs[95]) == 90, 'outside it')
  -- a long way outside: the road a town's radius away
  assert(sl.urban('CZ') == 50 and sl.rural('CZ') == 90 and sl.urban('XX') == 50)
  assert(sl.rural('DE') == 100)
end

function T.without_limits_or_tags_nothing_is_known()
  local sl = require('earthBusRoutes/speedlimit')
  local r = assert(osm.parseRoute(H.fixture('route_6962840')))          -- no way tags in this answer, no rel.limits
  assert(r.limitInfo == nil and sl.at(r, 100) == nil)
  local data, refs = tagged(nil)                                         -- tags only: where they are silent, nothing
  local r2 = assert(osm.parseRoute(data))
  assert(limitAtMiddleOf(r2, refs[2]) == 70)
  assert(limitAtMiddleOf(r2, refs[#refs - 1]) == nil)
end

function T.a_gtfs_line_has_towns_only()
  local sl = require('earthBusRoutes/speedlimit')
  local data = H.fixture('route_gtfs_363')
  local rel = data.elements[1]
  local g = rel.members[1].geometry
  rel.limits = { cc = 'CZ', towns = { { g[1].lat, g[1].lon, 1500 } } }
  local r = assert(osm.parseRoute(data))
  assert(sl.at(r, 10) == 50, 'in the first town')
  local far                                                      -- a place of the road 3 km and more from that town
  for i = 1, #r.path do if geo.dist(g[1].lat, g[1].lon, r.path[i].lat, r.path[i].lon) > 3000 then far = r.cum[i] break end end
  assert(far and sl.at(r, far) == 90, 'outside it')
end

return T
