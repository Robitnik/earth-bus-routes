-- Search by name and by line number: the instant answer from the service's index, then the public servers' answer.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local T = {}

local function setup(opts)
  opts = opts or {}
  H.reset()
  H.earth()
  local env = { pose = { lat = 50.4157, lon = 16.1626, speed = 0 }, later = {}, calls = {}, toasts = {} }
  local around = H.fixture('nachod_around_slim3')
  local nodes, heads = {}, {}
  for _, e in ipairs(around.elements) do
    if e.type == 'relation' then
      if e.tags.ref == '309' then heads[#heads + 1] = { type = 'relation', id = e.id, tags = e.tags, members = {} } end
    else
      nodes[#nodes + 1] = e
    end
  end
  env.heads = heads
  local features = opts.features or { path = true, along = true, search = true, stations = true, ['local'] = true, lines = true, towns = true, progress = true }
  local function answer(kind, q, cb, fast)
    env.calls[#env.calls + 1] = kind .. ':' .. q .. (fast and ':fast' or ':full')
    local data
    if kind == 'lines' then data = { elements = heads } else data = { elements = nodes, places = { { name = 'Náchod', lat = 50.4157, lon = 16.1626, kind = 'town', state = 'KHK' }, { name = 'Broumov', lat = 50.5855, lon = 16.332, kind = 'town' } } } end
    if fast then
      if opts.fastEmpty then data = { elements = {} } end
      cb(data, { cached = true, fast = true })
    elseif opts.fullFails then
      env.later[#env.later + 1] = function() cb(nil, { error = 'all mirrors down' }) end
    else
      env.later[#env.later + 1] = function() cb(data, { cached = false }) end
    end
  end
  local route = H.fixture('route_6964117')
  local ds = {
    state = { up = true, features = features },
    has = function(f) if opts.unknownFeatures then return nil end return features[f] == true end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb)
      if lat > 50.5 then
        -- a town 20 km away: the same stops moved there
        local moved = { elements = {} }
        for _, e in ipairs(around.elements) do
          if e.type == 'node' then
            local c = {}
            for k, v in pairs(e) do c[k] = v end
            c.id, c.lat, c.lon = e.id + 5000000, e.lat + 0.17, e.lon + 0.17
            moved.elements[#moved.elements + 1] = c
          end
        end
        cb(moved, {})
        return
      end
      cb(around, {})
    end,
    stations = function(lat, lon, cb) cb({ elements = {} }, {}) end,
    route = function(id, cb) cb(route, {}) end,
    towns = function(lat, lon, cb) env.calls[#env.calls + 1] = 'towns' cb({ towns = { { name = 'Hradec Králové', lat = 50.21, lon = 15.83, kind = 'city' }, { name = 'Broumov', lat = 50.5855, lon = 16.332, kind = 'town' }, { name = 'Náchod', lat = 50.4157, lon = 16.1626, kind = 'town' } } }, {}) end,
    path = function(p, cb) cb({ points = { { 50.4, 16.1 }, { 50.5, 16.2 } }, legs = { { dist = 14000, dur = 1200 } }, source = 'osrm' }, {}) end,
    along = function(p, cb) cb({ elements = {} }, {}) end,
    search = function(q, lat, lon, cb, fast) answer('stations', q, cb, fast) end,
    lines = function(ref, lat, lon, cb, fast) answer('lines', ref, cb, fast) end,
  }
  local world = setmetatable({
    pose = function() return { lat = env.pose.lat, lon = env.pose.lon, speed = 0 } end,
    place = function() return 'Náchod' end, weekday = function() return 2 end, nowSec = function() return 8 * 3600 end,
    options = function() return {} end, navigate = function() end,
    toast = function(text) env.toasts[#env.toasts + 1] = text end,
    vehicleInfo = function() return { bus = true, name = 'bus' } end,
  }, { __index = function() return function() end end })
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  _G.jsonReadFile = function() error('no file') end
  _G.jsonWriteFile = function() return true end
  local last
  _G.guihooks = { trigger = function(name, data) if name == 'EarthBusRoutesState' then last = data end end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  env.flush = function() local l = env.later env.later = {} for _, f in ipairs(l) do f() end end
  return m, function() return last end, env
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

function T.line_number_is_told_from_a_name()
  for _, ok in ipairs({ '305', 'N1', 'X12', '6/7', '22-3', ' 363 ', '305A' }) do assert(osm.isLineRef(ok), ok) end
  for _, no in ipairs({ '', 'Broumov', 'Náchod', 'a b 1', '123456789', 'Police 2', '(1)' }) do assert(not osm.isLineRef(no), no) end
end

function T.name_search_shows_the_instant_answer_then_the_full_one()
  local m, model, env = setup()
  m.uiOpen()
  m.uiFind('nachod')
  local f = model().find
  assert(f.kind == 'stations' and #f.items >= 3 and f.busy == true, 'the index answer is shown while the servers are still asked')
  for i = 2, #f.items do assert(f.items[i].dist >= f.items[i - 1].dist) end
  assert(env.calls[1] == 'stations:nachod:fast' and env.calls[2] == 'stations:nachod:full')
  env.flush()
  f = model().find
  assert(f.busy == false and #f.items >= 3 and f.err == nil)
  cleanup()
end

function T.typing_asks_only_the_index()
  local m, model, env = setup()
  m.uiOpen()
  m.uiFind('nach', true)
  assert(#env.calls == 1 and env.calls[1] == 'stations:nach:fast')
  assert(model().find.busy == false and #model().find.items >= 3)
  cleanup()
end

function T.a_failed_full_search_keeps_what_the_index_gave()
  local m, model, env = setup({ fullFails = true })
  m.uiOpen()
  m.uiFind('nachod')
  env.flush()
  local f = model().find
  assert(#f.items >= 3 and f.err == nil and not f.busy)
  cleanup()
  local m2, model2, env2 = setup({ fullFails = true, fastEmpty = true })
  m2.uiOpen()
  m2.uiFind('nachod')
  env2.flush()
  assert(#model2().find.items == 0 and model2().find.err == 'all mirrors down')
  cleanup()
end

function T.a_number_searches_lines_and_opens_a_line()
  local m, model, env = setup()
  m.uiOpen()
  m.uiFind('309')
  local f = model().find
  assert(f.kind == 'lines' and #f.items == 1 and f.items[1].ref == '309' and #f.items[1].variants >= 2)
  env.flush()
  local v = model().find.items[1].variants[1]
  m.uiFindLine(v.id)
  local md = model()
  assert(md.screen == 'route' and md.route and md.start.mode == 'first', 'the line card, to start from its first stop')
  m.uiBackTo('nearby')
  assert(model().screen == 'nearby' and model().find and model().find.kind == 'lines', 'the results are still there')
  m.uiFindClear()
  assert(model().find == nil)
  cleanup()
end

function T.a_found_station_opens_its_lines_and_back_returns_to_you()
  local m, model, env = setup()
  m.uiOpen()
  m.uiFind('nachod')
  env.flush()
  local f = model().find
  m.uiFindStation(f.items[1].id)
  local md = model()
  assert(md.screen == 'lines' and md.station and md.tabCounts, 'the station screen with its tabs')
  m.uiBackTo('nearby')
  assert(model().screen == 'nearby' and model().stations and #model().stations >= 3)
  cleanup()
end

function T.too_short_a_name_clears_the_search()
  local m, model = setup()
  m.uiOpen()
  m.uiFind('nachod')
  m.uiFind('n')
  assert(model().find == nil)
  cleanup()
end

function T.old_service_says_so_and_unknown_features_skip_the_instant_step()
  local m, model, env = setup({ features = { path = true, search = false, lines = false } })
  m.uiOpen()
  m.uiFind('nachod')
  assert(model().find.err == 'service_old' and #env.calls == 0)
  m.uiFind('309')
  assert(model().find.err == 'service_old')
  cleanup()
  local m2, model2, env2 = setup({ unknownFeatures = true })
  m2.uiOpen()
  m2.uiFind('nachod')
  assert(#env2.calls == 1 and env2.calls[1] == 'stations:nachod:full', 'no instant step until the service has said it has one')
  cleanup()
end

function T.builder_search_by_number_lists_the_lines_then_their_stations()
  local m, model, env = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildSearch('309')
  local b = model().build
  assert(b.candKind == 'lines' and b.lineHits and #b.lineHits == 1, 'lines found by the number')
  env.flush()
  m.uiBuildLine(model().build.lineHits[1].variants[1].id)
  b = model().build
  assert(b.candKind == 'search' and #b.cands >= 5, 'the stations of the line to pick from')
  -- in the order of the line, not by distance
  local H2 = osm.parseRoute(H.fixture('route_6964117'))
  assert(b.cands[1].name == H2.stops[1].name and b.cands[2].name == H2.stops[2].name)
  m.uiBuildAdd(b.cands[3].id)
  assert(#model().build.points == 2 and model().build.candKind == 'ring')
  cleanup()
end

function T.builder_name_search_still_works_and_typing_is_instant()
  local m, model, env = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildSearch('nach', true)
  assert(model().build.candKind == 'search' and #model().build.cands >= 1)
  assert(not model().build.busy.search)
  m.uiBuildSearch('nachod')
  assert(model().build.busy.search == true)
  env.flush()
  assert(not model().build.busy.search)
  m.uiBuildSearch('x')
  assert(model().build.candKind == 'ring')
  cleanup()
end

function T.the_search_finds_towns_and_a_town_opens_its_stations()
  local m, model, env = setup()
  m.uiOpen()
  m.uiFind('nachod')
  env.flush()
  local f = model().find
  assert(#f.places == 2 and f.places[1].name == 'Náchod' and f.places[1].kind == 'town')
  m.uiFindPlace(1)
  f = model().find
  assert(f.kind == 'stations' and #f.items >= 3 and f.placeName == 'Náchod' and not f.busy)
  for i = 2, #f.items do
    if f.items[i].station == f.items[i - 1].station then assert(f.items[i].dist >= f.items[i - 1].dist) else assert(f.items[i - 1].station) end
  end
  -- the stations of a town far away are not the ones here
  m.uiFindPlace(1)
  cleanup()
end

function T.a_town_picked_in_the_builder_adds_its_main_station()
  local m, model, env = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildSearch('broumov')
  env.flush()
  local b = model().build
  assert(b.places and #b.places == 2 and b.places[2].name == 'Broumov')
  m.uiBuildPlace(2)
  b = model().build
  assert(#b.points == 2, 'the next station is the main station of the town: ' .. #b.points)
  assert(b.points[2].name:find('Náchod'), 'a stop of the (moved) data: ' .. tostring(b.points[2].name))
  assert(b.canFinish and b.candKind == 'ring' and not b.places)
  cleanup()
end

function T.what_the_service_is_doing_reaches_the_menu()
  local m, model = setup()
  m.uiOpen()
  assert(model().progress == nil)
  local ds = package.loaded['earthBusRoutes/datasvc']
  ds.state.progress = { busy = { { what = 'overpass', label = 'route', state = 'running', mirror = 2, of = 4, elapsed = 18.5 } }, waiting = 0 }
  m.publish()
  local p = model().progress
  assert(p and p.busy[1].what == 'overpass' and p.busy[1].mirror == 2 and p.busy[1].of == 4)
  assert(type(ds.onProgress) == 'function' or ds.onProgress == nil)
  cleanup()
end

function T.the_map_lists_the_towns_and_a_chip_opens_the_stations()
  local m, model, env = setup()
  m.uiOpen()
  m.uiMapOpen()
  local mp = model().map
  assert(mp and mp.towns and #mp.towns == 3 and mp.towns[1].kind == 'city' and mp.towns[2].id == 2)
  m.uiMapOpen()
  local n = 0
  for _, c in ipairs(env.calls) do if c == 'towns' then n = n + 1 end end
  assert(n == 1, 'the same area is not asked twice')
  m.uiMapPlace(3)                                   -- Náchod
  local f = model().find
  assert(f and f.kind == 'stations' and f.placeName == 'Náchod' and #f.items >= 3 and not f.busy)
  cleanup()
end

function T.towns_on_the_builder_map_and_a_chip_adds_the_main_station()
  local m, model, env = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildCities(true)
  local b = model().build
  assert(b.showCities and b.cities and #b.cities == 3)
  m.uiBuildCity(2)                                  -- Broumov (the stub moves the stops there)
  b = model().build
  assert(#b.points == 2 and b.canFinish, 'the chip added the main station of the town: ' .. #b.points)
  assert(b.showCities and b.cities, 'the map stays on towns, now round the new last station')
  m.uiBuildCities(false)
  assert(not model().build.showCities and model().build.cities == nil)
  cleanup()
end

function T.an_old_service_cannot_show_the_map()
  local m, model = setup({ features = { path = true, search = true } })
  m.uiOpen()
  m.uiMapOpen()
  assert(model().map.err == 'service_old')
  cleanup()
end

return T
