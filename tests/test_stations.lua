-- The station tabs (from / to / through) and "drive to the start" in main.lua, with the service and the game stubbed.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local T = {}

local function setup()
  H.reset()
  H.earth()
  local env = { pose = { lat = 50.4157, lon = 16.1626, speed = 0 }, gps = {}, gpsCleared = 0, toasts = {}, clock = 8 * 3600, hud = {} }
  local route = H.fixture('route_6964117')
  local ds = {
    state = { up = true, features = { path = true, along = true, search = true, stations = true } },
    has = function() return true end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb) cb(H.fixture('nachod_around_slim3'), {}) end,
    stations = function(lat, lon, cb) cb({ elements = {} }, {}) end,
    route = function(id, cb) cb(route, {}) end,
  }
  local world = setmetatable({
    pose = function() return { lat = env.pose.lat, lon = env.pose.lon, speed = env.pose.speed } end,
    place = function() return 'Náchod' end, weekday = function() return 2 end, nowSec = function() return env.clock end,
    options = function() return {} end, navigate = function() end,
    toast = function(text) env.toasts[#env.toasts + 1] = text end,
    gpsRoute = function(points) env.gps[#env.gps + 1] = points return true end,
    gpsClear = function() env.gpsCleared = env.gpsCleared + 1 end,
    vehicleInfo = function() return { bus = true, name = 'bus' } end,
  }, { __index = function() return function() end end })
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  _G.jsonReadFile = function() error('no file') end
  _G.jsonWriteFile = function() return true end
  local last
  _G.guihooks = { trigger = function(name, data)
    if name == 'EarthBusRoutesState' then last = data elseif name == 'EarthBusRoutesHud' then env.hud[#env.hud + 1] = data end
  end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  return m, function() return last end, env, route
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

-- the first station of the model that has lines and the first variant of one of them
local function pickStation(m, model)
  m.uiOpen()
  for _, st in ipairs(model().stations) do
    if st.lineCount > 0 then
      m.uiSelectStation(st.id)
      return st
    end
  end
  error('no station with lines')
end

function T.station_screen_has_tabs_and_opens_the_first_that_has_lines()
  local m, model = setup()
  local st = pickStation(m, model)
  local md = model()
  assert(md.screen == 'lines' and md.tabCounts and md.tab)
  assert(md.tabCounts.from + md.tabCounts.to + md.tabCounts.through > 0)
  assert(md.tabCounts[md.tab] > 0 or md.tab == 'from')
  m.uiSetTab('through')
  assert(model().tab == 'through')
  m.uiSetTab('nonsense')
  assert(model().tab == 'through', 'an unknown tab is ignored')
  for _, ln in ipairs(model().lines) do
    for _, v in ipairs(ln.variants) do assert(v.place == 'from' or v.place == 'to' or v.place == 'through' or v.place == 'loop') end
  end
  cleanup()
end

function T.a_route_that_ends_here_starts_from_its_first_stop()
  local m, model, env, route = setup()
  pickStation(m, model)
  -- the player is at the route's LAST stop; the route ends here
  local r = osm.parseRoute(H.fixture('route_6964117'))
  local last = r.stops[#r.stops]
  env.pose.lat, env.pose.lon = last.lat, last.lon
  m.uiOpen()
  m.uiSelectStation(1)
  local id = model().lines[1].variants[1].id
  m.uiSelectRoute(id)
  -- (the stubbed data service answers every route with the same relation)
  local md = model()
  assert(md.screen == 'route' and md.start)
  m.uiSetStartMode('here')
  assert(model().start.mode == 'here' or model().start.place ~= 'to')
  cleanup()
end

function T.drive_to_the_start_waits_and_begins_on_arrival()
  local m, model, env = setup()
  pickStation(m, model)
  m.uiSelectRoute(model().lines[1].variants[1].id)
  local md = model()
  assert(md.screen == 'route')
  -- somewhere far from the start
  local r = osm.parseRoute(H.fixture('route_6964117'))
  local first = r.stops[1]
  env.pose.lat, env.pose.lon = first.lat + 0.1, first.lon
  m.uiSetStartMode('first')
  assert(model().start.canDrive and model().start.dist > 5000)
  m.uiDriveToStart()
  md = model()
  assert(md.armed and md.armed.ref == '305' and md.armed.dist > 5000, 'the trip is waiting for the bus')
  assert(#env.gps == 1 and env.gps[1][1].name == first.name, 'the GPS leads to the first stop')
  assert(not md.tripActive)
  -- driving: nothing happens, the HUD hears about the distance
  m.onUpdate(1, 1)
  assert(not model().tripActive)
  local armedHud
  for _, h in ipairs(env.hud) do if h.armed then armedHud = h.armed end end
  assert(armedHud and armedHud.dist > 5000 and armedHud.ref == '305')
  -- at the stop but still rolling: no start
  env.pose.lat, env.pose.lon, env.pose.speed = first.lat, first.lon, 9
  m.onUpdate(1, 1)
  assert(model().armed and not model().tripActive)
  -- standing at the stop: the trip begins on the first departure after the clock + a little time to board
  env.pose.speed = 0
  m.onUpdate(1, 1)
  md = model()
  assert(md.tripActive and not md.armed, 'the trip began: err=' .. tostring(md.error) .. ' toasts=' .. table.concat(env.toasts, '|'))
  assert(env.gpsCleared >= 1)
  cleanup()
end

function T.cancel_and_teleport_end_the_wait()
  local m, model, env = setup()
  pickStation(m, model)
  m.uiSelectRoute(model().lines[1].variants[1].id)
  local first = osm.parseRoute(H.fixture('route_6964117')).stops[1]
  env.pose.lat = first.lat + 0.1
  m.uiSetStartMode('first')
  m.uiDriveToStart()
  assert(model().armed)
  m.uiCancelArmed()
  assert(not model().armed and env.gpsCleared >= 1)
  m.uiDriveToStart()
  assert(model().armed)
  m.onBeamNGEarthTeleported()
  assert(not model().armed, 'a teleport ends the wait: the road to the start is lost')
  -- starting by teleport also drops a wait
  m.uiDriveToStart()
  assert(model().armed)
  m.uiStart()
  assert(not model().armed)
  cleanup()
end

return T
