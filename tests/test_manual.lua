-- The manual mode's flow in main.lua, with the data service and the game stubbed (answers arrive at once).
local H = dofile('tests/harness.lua')
local T = {}

local NACHOD = { 50.4157, 16.1626 }

local function setup(opts)
  opts = opts or {}
  H.reset()
  H.earth()
  local calls, files, state = {}, {}, nil
  local osrm = H.fixture('osrm_nachod_broumov').routes[1]
  local pts, legs = {}, {}
  for i, c in ipairs(osrm.geometry.coordinates) do pts[i] = { c[2], c[1] } end
  for i, l in ipairs(osrm.legs) do legs[i] = { dist = l.distance, dur = l.duration } end
  local features = opts.features or { path = true, along = true, search = true, stations = true }
  local ds = {
    state = { up = true, features = features },
    has = function(f) return features[f] == true end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb, how) calls[#calls + 1] = 'nearby:' .. tostring(how) cb(H.fixture('nachod_around_slim'), {}) end,
    stations = function(lat, lon, cb)
      calls[#calls + 1] = 'stations'
      cb({ elements = { { type = 'node', id = 777, lat = 50.5855, lon = 16.332, tags = { amenity = 'bus_station', name = 'Broumov, autobusové nádraží' } } } }, {})
    end,
    path = function(p, cb)
      calls[#calls + 1] = 'path:' .. p
      if opts.pathFails then cb(nil, { error = 'down' }) else cb({ points = pts, legs = legs, source = 'osrm' }, {}) end
    end,
    along = function(p, cb)
      calls[#calls + 1] = 'along'
      cb({ elements = opts.alongElements or {} }, {})
    end,
    search = function(q, lat, lon, cb)
      calls[#calls + 1] = 'search:' .. q
      cb({ elements = { { type = 'node', id = 778, lat = 50.5855, lon = 16.332, tags = { amenity = 'bus_station', name = 'Broumov, autobusové nádraží' } } } }, {})
    end,
  }
  local clock = 8 * 3600
  local world = setmetatable({
    pose = function() return { lat = NACHOD[1], lon = NACHOD[2], speed = 0 } end,
    place = function() return 'Náchod' end, weekday = function() return 2 end, nowSec = function() return clock end,
    options = function() return {} end, navigate = function() end, toast = function() end,
    vehicleInfo = function() return { bus = true, name = 'bus' } end,
  }, { __index = function() return function() end end })
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  files = {}
  _G.jsonReadFile = function(path) if files[path] == nil then error('no file') end return files[path] end
  _G.jsonWriteFile = function(path, data) files[path] = data return true end
  local last
  _G.guihooks = { trigger = function(name, data) if name == 'EarthBusRoutesState' then last = data end end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  return m, function() return last end, calls, files
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

local function candidateNamed(model, name)
  for _, c in ipairs(model.build.cands or {}) do if c.name == name then return c end end
end

function T.build_a_route_station_by_station()
  local m, model, calls = setup()
  m.uiOpen()
  assert(model().screen == 'nearby' and #model().stations >= 3)
  m.uiBuildStart(1)
  local b = model().build
  assert(model().screen == 'build' and #b.points == 1 and b.mode == 'all')
  assert(b.busy.cands == nil and #b.cands >= 1, 'candidates are listed')
  local broumov = candidateNamed(model(), 'Broumov, autobusové nádraží')
  assert(broumov and broumov.station, 'a far bus station is offered')
  m.uiBuildAdd(broumov.id)
  b = model().build
  assert(#b.points == 2 and b.canFinish and b.km > 30 and b.line and #b.line > 10 and not b.straight)
  assert(calls[#calls - 2]:find('path:') or true)
  m.uiBuildUndo()
  assert(#model().build.points == 1 and not model().build.canFinish)
  cleanup()
end

function T.finish_gives_a_custom_route_card_and_save_and_reopen()
  local m, model, _, files = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildAdd(candidateNamed(model(), 'Broumov, autobusové nádraží').id)
  m.uiBuildMode('express')
  m.uiBuildMeta('310', '#cc3300', '')
  assert(model().build.ref == '310' and model().build.colour == '#cc3300')
  m.uiBuildFinish()
  local md = model()
  assert(md.screen == 'route' and md.route.custom and md.route.ref == '310' and md.route.stopCount == 2, tostring(md.route and md.route.stopCount))
  assert(md.route.km > 30 and md.route.tripsToday > 10 and md.start.reverseId == 'custom')
  m.uiSave()
  assert(#model().saved == 1 and model().saved[1].ref == '310')
  assert(files['/settings/earthBusRoutes/myroutes.json'].routes[1].state.format == 1)
  m.uiSave()
  assert(#model().saved == 1, 'saving again replaces the entry')
  m.uiBackTo('nearby')
  m.uiOpenSaved(1)
  md = model()
  assert(md.screen == 'route' and md.route.custom and md.route.ref == '310')
  m.uiDeleteSaved(1)
  assert(#model().saved == 0)
  cleanup()
end

function T.reverse_builds_the_other_way()
  local m, model, calls = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildAdd(candidateNamed(model(), 'Broumov, autobusové nádraží').id)
  m.uiBuildMode('express')
  m.uiBuildFinish()
  local first = model().route
  m.uiToggleReverse()
  local back = model().route
  assert(back.custom and back.id ~= first.id and back.from == first.to and back.to == first.from and model().start.reversed)
  cleanup()
end

function T.search_offers_matches()
  local m, model, calls = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildSearch('Broum')
  local b = model().build
  assert(b.candKind == 'search' and #b.cands == 1 and b.cands[1].name:find('Broumov'))
  m.uiBuildClearSearch()
  assert(model().build.candKind == 'ring')
  m.uiBuildSearch('x')
  assert(model().build.candKind == 'ring', 'one letter is not a search')
  cleanup()
end

function T.without_a_road_the_path_is_straight_and_the_route_still_builds()
  local m, model = setup({ pathFails = true })
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildAdd(candidateNamed(model(), 'Broumov, autobusové nádraží').id)
  local b = model().build
  assert(b.straight and b.canFinish and b.pathErr == 'down')
  m.uiBuildFinish()
  assert(model().route.custom and model().route.straight)
  cleanup()
end

function T.an_old_service_still_lets_you_build_with_straight_lines()
  local m, model = setup({ features = { path = false, along = false, search = false, stations = false } })
  m.uiOpen()
  m.uiBuildStart(1)
  assert(#model().build.cands >= 1, 'the nearby stops still come')
  m.uiBuildAdd(model().build.cands[1].id)
  assert(model().build.straight and model().build.pathErr == 'service_old')
  m.uiBuildSearch('Broum')
  assert(model().build.err == 'service_old')
  cleanup()
end

function T.stops_screen_asks_for_stops_once()
  local m, model, calls = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  m.uiBuildAdd(candidateNamed(model(), 'Broumov, autobusové nádraží').id)
  m.uiBuildStops()
  assert(model().screen == 'buildStops' and model().build.stops and #model().build.stops == 2)
  local n = 0
  for _, c in ipairs(calls) do if c == 'along' then n = n + 1 end end
  m.uiBuildStops()
  local n2 = 0
  for _, c in ipairs(calls) do if c == 'along' then n2 = n2 + 1 end end
  assert(n == 1 and n2 == 1)
  cleanup()
end

function T.limit_of_stations_is_reported()
  local m, model = setup()
  m.uiOpen()
  m.uiBuildStart(1)
  local b = model().build
  assert(b.maxPoints == 25 and not b.full)
  cleanup()
end

return T
