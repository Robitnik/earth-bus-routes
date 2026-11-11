local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local menu = require('earthBusRoutes/menu')
local T = {}

local NACHOD = { 50.4157, 16.1626 }

local function around()
  local a = osm.parseAround(H.fixture('nachod_around_slim'))
  return osm.groupStops(a.stops), a.routes
end

function T.clock_label_and_compass()
  assert(menu.clockLabel(7 * 3600 + 5 * 60) == '07:05')
  assert(menu.clockLabel(25 * 3600) == '01:00')
  assert(menu.compass(0) == 'N' and menu.compass(95) == 'E' and menu.compass(181) == 'S' and menu.compass(359) == 'N')
end

function T.nearby_model_is_sorted_and_complete()
  local stations, routes = around()
  local m = menu.nearbyModel(stations, routes, NACHOD[1], NACHOD[2])
  assert(#m >= 3 and #m <= menu.MAX_STATIONS)
  for i = 2, #m do assert(m[i].dist >= m[i - 1].dist) end
  for _, s in ipairs(m) do
    assert(s.name ~= '' and s.dir and s.lat and s.lines)
    for _, c in ipairs(s.lines) do assert(c.ref and c.colour:match('^#%x%x%x%x%x%x$')) end
  end
end

function T.lines_model_lists_variants_with_ids()
  local stations, routes = around()
  local m = menu.nearbyModel(stations, routes, NACHOD[1], NACHOD[2])
  local busy
  for _, s in ipairs(m) do if s.lineCount >= 2 then busy = s break end end
  assert(busy, 'no station with two lines')
  local lines = menu.linesModel(busy.ref, routes)
  assert(#lines == busy.lineCount)
  for _, l in ipairs(lines) do
    assert(#l.variants >= 1)
    for _, v in ipairs(l.variants) do assert(type(v.id) == 'number' and v.label ~= nil) end
  end
end

function T.variants_with_the_same_destination_are_told_apart()
  local function head(id, to, name) return { id = id, ref = '309', network = 'N', from = 'Rychnov', to = to, name = name, colour = '#112233', nodes = { [1] = true } } end
  local routes = {
    head(1, 'Nachod', '309: Rychnov => Provodov => Nachod'),
    head(2, 'Nachod', '309: Rychnov => Nachod'),
    head(3, 'Nachod', '309: Rychnov => Nachod'),          -- even the names can be equal
    head(4, 'Rychnov', nil),
  }
  local lines = menu.linesModel({ nodeIds = { [1] = true } }, routes)
  assert(#lines == 1 and #lines[1].variants == 4)
  local labels, n = {}, 0
  for _, v in ipairs(lines[1].variants) do
    if v.to == 'Nachod' then
      assert(v.ambiguous and not labels[v.label], 'duplicate label ' .. tostring(v.label))
      labels[v.label] = true
      n = n + 1
    else
      assert(not v.ambiguous)
    end
  end
  assert(n == 3)
end

function T.route_model_and_departures()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  local trips = sched.generate(r, 2)
  local m = menu.routeModel(r, trips, 2)
  assert(m.ref == '305' and m.stopCount == #r.stops and #m.stops == #r.stops)
  assert(m.km > 30 and m.minutes > 20 and #m.periods == 7)
  assert(m.first and m.last and m.tripsToday == #trips)
  local idx = menu.nearestStopIndex(r, r.stops[4].lat, r.stops[4].lon)
  assert(idx == 4)
  local deps = menu.departuresModel(trips, 2, 8 * 3600, 5)
  assert(#deps == 5 and deps[1].sec >= 8 * 3600 and not deps[1].tomorrow)
  local late, tomorrow = menu.departuresModel(trips, 2, 25 * 3600, 3)
  assert(tomorrow and #late == 3)
end

local function route(over)
  local r = { id = 1, ref = '9', network = 'N', from = 'A', to = 'B', ordered = true, n = 5, colour = '#112233',
    nodes = { [10] = true, [11] = true }, places = { [10] = { i = 1, j = 1 } } }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end
local function station(name, ids)
  local nodeIds = {}
  for _, id in ipairs(ids) do nodeIds[id] = true end
  return { name = name, nodeIds = nodeIds, platforms = {} }
end

function T.place_of_a_station_follows_the_stop_order()
  local st = station('Stop', { 10 })
  local at = function(i, j, n) local r = route({ n = n or 5, places = { [10] = { i = i, j = j or i } } }) return (osm.placeAt(st, r)) end
  assert(at(1) == 'from' and at(5) == 'to' and at(3) == 'through')
  assert(at(1, 5) == 'loop', 'a circular line starts and ends at its first stop')
  -- a station with several platforms: the earliest and the latest of the route's stops there count
  local two = station('Station', { 10, 11 })
  local r = route({ places = { [10] = { i = 1, j = 1 }, [11] = { i = 5, j = 5 } } })
  assert((osm.placeAt(two, r)) == 'loop')
end

function T.place_is_guessed_by_name_without_an_order()
  local st = station('Náchod, autobusové nádraží', { 10 })
  local r = route({ ordered = false, n = nil, places = {}, from = 'Náchod, autobusové nádraží', to = 'Broumov' })
  local place, approx = osm.placeAt(st, r)
  assert(place == 'from' and approx == true)
  assert((osm.placeAt(st, route({ ordered = false, places = {}, from = 'Broumov', to = 'Náchod' }))) == 'to')
  local place2, approx2 = osm.placeAt(station('Elsewhere', { 10 }), route({ ordered = false, places = {}, from = 'A', to = 'B' }))
  assert(place2 == 'through' and approx2 == true)
  -- an old data service (no places at all): the same guess
  local old = route({ ordered = nil, n = nil, places = {}, from = 'Stop', to = 'Z' })
  assert((osm.placeAt(station('Stop', { 10 }), old)) == 'from')
end

function T.tabs_split_lines_and_a_loop_is_in_two()
  local st = station('Stop', { 10 })
  local routes = {
    route({ id = 1, ref = '1', places = { [10] = { i = 1, j = 1 } } }),
    route({ id = 2, ref = '2', places = { [10] = { i = 5, j = 5 } } }),
    route({ id = 3, ref = '3', places = { [10] = { i = 3, j = 3 } } }),
    route({ id = 4, ref = '4', places = { [10] = { i = 1, j = 5 } } }),
  }
  local lines = menu.linesModel(st, routes)
  local c = menu.tabCounts(lines)
  assert(c.from == 2 and c.to == 2 and c.through == 1, c.from .. c.to .. c.through)
  assert(menu.firstTab(c) == 'from')
  assert(menu.firstTab({ from = 0, to = 0, through = 3 }) == 'through')
  assert(menu.firstTab({ from = 0, to = 2, through = 3 }) == 'to')
  for _, ln in ipairs(lines) do
    for _, v in ipairs(ln.variants) do
      assert(menu.inTab(v, 'through') == (v.place == 'through'))
    end
  end
end

function T.real_data_nachod_splits_lines()
  local a = osm.parseAround(H.fixture('nachod_around_slim3'))
  local stations = osm.groupStops(a.stops)
  local seen = { from = 0, to = 0, through = 0 }
  for _, s in ipairs(stations) do
    local c = menu.tabCounts(menu.linesModel(s, a.routes))
    for k, v in pairs(c) do seen[k] = seen[k] + v end
  end
  assert(seen.from > 0 and seen.through > 0, 'the recorded answer has lines that start and lines that pass')
  -- the bus station of Náchod: lines 302 and 306 start there
  for _, s in ipairs(stations) do
    if s.name:find('autobusov') then
      local lines = menu.linesModel(s, a.routes)
      assert(menu.tabCounts(lines).from >= 1)
    end
  end
end

function T.ends_of_a_route_name()
  local a, b = osm.nameEnds({ ref = '360', name = '360: Police nad Metují, autobusové stanoviště - Teplice n. Met., skály' })
  assert(a == 'Police nad Metují, autobusové stanoviště' and b == 'Teplice n. Met., skály', tostring(a) .. ' / ' .. tostring(b))
  a, b = osm.nameEnds({ ref = '363', name = '363 Police n. Metují - Suchý Důl - Police n. Metují' })
  assert(a == 'Police n. Metují' and b == 'Police n. Metují')
  a, b = osm.nameEnds({ ref = '7', name = 'Bus 7: A – B' })
  assert(a == 'Bus 7: A' and b == 'B')
  assert(osm.nameEnds({ ref = '361', name = '361 Police n.Met.-Machov' }) == nil, 'a dash without spaces is part of a name')
  assert(osm.nameEnds({ ref = '1' }) == nil)
end

-- Police nad Metují, the bus station (recorded answer of 2026-11-11): OSM lists 360 Police → Teplice with its stops shuffled
-- (the station 8th of 16), 363 from the school (the station 13th of 14), and the other 360 with swapped from/to tags.
function T.lines_at_police_follow_their_names_when_the_list_is_out_of_order()
  local a = osm.parseAround(H.fixture('police_around_slim3'))
  local st
  for _, s in ipairs(osm.groupStops(a.stops)) do
    if s.name == 'Police nad Metují, aut.st.' then st = s end
  end
  assert(st, 'the bus station is in the answer')
  local at = {}
  for _, r in ipairs(osm.routesAt(st, a.routes)) do at[r.id] = { osm.placeAt(st, r) } end
  assert(at[6978584][1] == 'from', '360 Police → Teplice starts here: ' .. tostring(at[6978584][1]))
  assert(at[6978584][2] == true, 'a guess from the words')
  assert(at[7185111][1] == 'loop', '363 starts and ends here: ' .. tostring(at[7185111][1]))
  assert(at[11795188][1] == 'to', '360 Teplice → Police ends here (the order wins over swapped tags)')
  local c = menu.tabCounts(menu.linesModel(st, a.routes))
  assert(c.from == 2 and c.to == 2, ('from %d, to %d'):format(c.from, c.to))
  -- a stop in the middle stays in the middle when the words say nothing about it
  local school
  for _, s in ipairs(osm.groupStops(a.stops)) do
    if s.name == 'Police nad Metují, škola' then school = s end
  end
  assert(osm.placeAt(school, a.routes[1]) == 'through')
end

-- Tags and name disagree (swapped tags): no guess from the words.
function T.words_that_disagree_say_nothing()
  local st = station('Police nad Metují, aut.st.', { 10 })
  local r = route({ ordered = true, n = 16, places = { [10] = { i = 8, j = 8 } }, ref = '360',
    name = '360: Teplice n. Met., skály - Police nad Metují, autobusové stanoviště',
    from = 'Police nad Metují, autobusové stanoviště', to = 'Teplice n. Met., skály' })
  assert(osm.placeAt(st, r) == 'through')
end

-- Police nad Metují with the timetables only (the map server was down; recorded answer of service 0.8.0): the bus station
-- has the lines the map lacks (361, 375) and each in the right tab.
function T.timetable_lines_fill_the_tabs_of_the_bus_station()
  local a = osm.parseAround(H.fixture('police_gtfs_nearby'))
  local st
  for _, g in ipairs(osm.groupStops(a.stops)) do
    if g.name == 'Police n.Met.,aut.st.' then st = g end
  end
  assert(st, 'the bus station is in the answer')
  local lines = menu.linesModel(st, a.routes)
  local seen = {}
  for _, ln in ipairs(lines) do
    for _, v in ipairs(ln.variants) do
      seen[ln.ref] = seen[ln.ref] or {}
      seen[ln.ref][v.place] = true
    end
  end
  for _, ref in ipairs({ '360', '361', '363', '375' }) do assert(seen[ref], 'line ' .. ref .. ' is missing') end
  assert(seen['363'].loop, '363 starts and ends at the station')
  assert(seen['360'].from and seen['360'].to, '360 both ways')
  assert(seen['375'].from and seen['375'].to and seen['375'].through, '375 starts, ends and passes')
  local c = menu.tabCounts(lines)
  assert(c.from >= 4 and c.to >= 3, ('from %d to %d'):format(c.from, c.to))
end

return T
