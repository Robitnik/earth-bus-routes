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

return T
