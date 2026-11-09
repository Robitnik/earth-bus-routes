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

return T
