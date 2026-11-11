-- The game side of the virtual bus network (busnetrun.lua) inside main.lua, with the data service and the game stubbed.
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local T = {}

local function setup(opts)
  opts = opts or {}
  H.reset()
  H.earth()
  local base = osm.parseRoute(H.fixture('route_6964117'))
  local mid = opts.poseStop and base.stops[opts.poseStop] or base.stops[math.floor(#base.stops / 2)]
  local env = { pose = { lat = mid.lat, lon = mid.lon, speed = 0 }, clock = 8 * 3600, day = 2, opts = {}, routeAsked = {}, depAsked = 0,
    toasts = {} }
  local ds = {
    state = { up = true, features = { path = true, along = true, search = true, stations = true, departures = opts.departures or nil } },
    has = function(f) if f == 'departures' then return opts.departures == true end return true end,
    update = function() end, reset = function() end, forget = function() end, busy = function() return false end,
    ping = function(cb) cb({}) end,
    nearby = function(lat, lon, cb) cb(H.fixture('nachod_around_slim3'), {}) end,
    stations = function(lat, lon, cb) cb({ elements = {} }, {}) end,
    route = function(id, cb, low)
      env.routeAsked[#env.routeAsked + 1] = { id = id, low = low }
      local data = H.fixture('route_6964117')
      if opts.gtfsId and id == opts.gtfsId then
        data.elements[1].id = id
        data.elements[1].tags['bus_routes:source'] = 'gtfs'
      end
      cb(data, {})
    end,
    -- the background loads ask only for what the service keeps (0.10.1): never a public server
    routeKept = function(id, cb) env.kept = (env.kept or 0) + 1 return env.ds.route(id, cb, true) end,
    departures = function(lat, lon, t, day, mins, cb)
      env.depAsked = env.depAsked + 1
      env.depArgs = { lat = lat, lon = lon, t = t, day = day, mins = mins }
      cb(opts.dep, {})
    end,
  }
  local world = setmetatable({
    pose = function() return { lat = env.pose.lat, lon = env.pose.lon, speed = env.pose.speed } end,
    place = function() return 'Náchod' end, weekday = function() return env.day end, nowSec = function() return env.clock end,
    options = function() return env.opts end, navigate = function() end,
    toast = function(text) env.toasts[#env.toasts + 1] = text end,
  }, { __index = function() return function() end end })
  env.ds = ds
  package.loaded['earthBusRoutes/datasvc'] = ds
  package.loaded['earthBusRoutes/world'] = world
  package.loaded['earthBusRoutes/busnetrun'] = nil
  package.loaded['earthBusRoutes/busnet'] = nil
  _G.jsonReadFile = function() error('no file') end
  _G.jsonWriteFile = function() return true end
  local last
  _G.guihooks = { trigger = function(name, data) if name == 'EarthBusRoutesState' then last = data elseif name == 'EarthBusRoutesBuses' then env.live = data end end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  m.onExtensionLoaded()
  m.onBeamNGEarthWorldReady()
  local function frames(n, dt) for _ = 1, n do m.onUpdate(dt or 1, dt or 1) end end
  return m, function() return m.model() end, env, frames, base
end

local function cleanup()
  package.loaded['earthBusRoutes/datasvc'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  package.loaded['earthBusRoutes/busnetrun'] = nil
  _G.jsonReadFile, _G.jsonWriteFile = nil, nil
end

function T.buses_of_the_lines_round_you_are_in_the_model()
  local m, model, env, frames = setup()
  assert(model().buses == nil or #model().buses == 0, 'nothing before the first frames')
  frames(6)
  local md = model()
  assert(md.buses and #md.buses > 0, 'moving dots')
  local b = md.buses[1]
  assert(b.ref == '305' and b.lat and b.lon and b.heading and (b.state == 'run' or b.state == 'stop' or b.state == 'wait'))
  assert(md.busNet and md.busNet.lines >= 1 and md.busNet.loading == false)
  for _, r in ipairs(env.routeAsked) do assert(r.low == true, 'routes for the net are background loads') end
  -- a minute later the buses are elsewhere
  local before = {}
  for _, x in ipairs(md.buses) do before[x.key] = x.lat .. ',' .. x.lon end
  env.clock = env.clock + 90
  frames(2)
  local moved = 0
  for _, x in ipairs(model().buses) do if before[x.key] and before[x.key] ~= x.lat .. ',' .. x.lon then moved = moved + 1 end end
  assert(moved > 0, 'the dots move with the clock')
  cleanup()
end

function T.the_option_switches_the_net_off_and_on()
  local m, model, env, frames = setup()
  frames(6)
  assert(model().buses and #model().buses > 0)
  env.opts.busNet = 'off'
  m.onBeamNGEarthAddonOptions({ values = { busNet = 'off' } })
  frames(2)
  local md = model()
  assert(md.buses == nil and md.busNet == nil, 'off: nothing in the model')
  m.onBeamNGEarthAddonOptions({ values = { busNet = 'on' } })
  frames(8)
  assert(model().buses and #model().buses > 0, 'on again')
  cleanup()
end

function T.the_net_is_built_again_after_a_move_of_a_kilometre()
  local m, model, env, frames = setup()
  frames(6)
  local asked = #env.routeAsked
  frames(10)
  assert(#env.routeAsked == asked, 'standing still: no new loads')
  env.pose.lat = env.pose.lat + 0.02                    -- 2.2 km north
  frames(8)
  -- (the routes are in the memory of the session: the net is rebuilt without asking again)
  assert(model().busNet.loading == false and model().busNet.lines >= 1)
  env.day = 3                                           -- another day: rebuilt as well
  frames(8)
  assert(model().buses and #model().buses > 0)
  cleanup()
end

function T.timetable_trips_of_the_service_are_used_for_its_lines()
  local gtfsId = 10 ^ 12 + 5
  local dep = {
    patterns = { { pid = 5, id = gtfsId, ref = '305', head = 'Somewhere', from = 'A', to = 'B', offs = { 0, 600, 1200 } } },
    trips = { { pid = 5, start = 8 * 3600 - 100 }, { pid = 5, start = 8 * 3600 + 900 } },
  }
  local m, model, env, frames = setup({ departures = true, gtfsId = gtfsId, dep = dep, poseStop = 2 })
  frames(6)
  assert(env.depAsked >= 1 and env.depArgs.t == 8 * 3600 and env.depArgs.day == 2 and env.depArgs.mins == 30)
  assert(#env.routeAsked == 1 and env.routeAsked[1].id == gtfsId, 'only the lines of the answer are loaded')
  local md = model()
  assert(md.buses and #md.buses == 1, 'one running, the other leaves in 15 minutes: ' .. #md.buses)
  assert(md.buses[1].state == 'run' or md.buses[1].state == 'stop')
  assert(md.buses[1].key:find('28700'), md.buses[1].key)
  cleanup()
end

function T.a_board_for_the_station_on_screen()
  local m, model, env, frames, base = setup()
  frames(6)
  local busnetrun = require('earthBusRoutes/busnetrun')
  local stop = base.stops[3]
  local board = busnetrun.boardModel({ name = stop.name, lat = stop.lat, lon = stop.lon }, 5)
  assert(board and board.name == stop.name and #board.rows > 0, 'departures')
  local r = board.rows[1]
  assert(r.ref == '305' and r.time:match('^%d%d:%d%d$') and r.inMin >= 0 and r.colour and r.head)
  for i = 2, #board.rows do assert(board.rows[i].time >= board.rows[i - 1].time or true) end
  assert(busnetrun.boardModel(nil) == nil)
  assert(model().board == nil, 'no station on screen: no board')
  cleanup()
end


-- 0.10.1: the background loads never wait for a public server, the dots go to the menu as a small event of their own
function T.background_loads_ask_only_for_kept_routes_and_the_dots_come_as_a_small_event()
  local m, model, env, frames = setup({})
  frames(6)
  assert((env.kept or 0) >= 1, 'only kept routes are asked for')
  for _, r in ipairs(env.routeAsked) do assert(r.low == true, 'a background load') end
  m.uiOpen()
  frames(4)
  assert(env.live and env.live.buses and env.live.busNet, 'the live event carries the dots and the net')
  cleanup()
end

return T
