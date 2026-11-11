-- The game side of the AI fleet (plan 007, T4/T5): builds the env of fleet.lua from world.lua and main.lua's state, runs it every
-- frame, forwards the events of the vehicle-side driver (main.lua defines onEarthBusDriverEvent, the hook the driver calls through
-- extensions.hook) and publishes `model.fleet` for the menu's small diagnostics line. Attached by main.lua (fleetrun.attach); every
-- hook runs under pcall and a failure switches the fleet off (the pool is emptied) for a minute, never the player's trip.
-- Everything is off when the game functions are missing (world.fleetAvailable), when the option `aiBuses` is off, when `busFleet`
-- is 0 or the virtual net (option busNet) is off. UNVERIFIED in the game: see the list at the top of world.lua's fleet section and
-- docs of stage T0 (spawn, hide, teleport, camera visibility, the graph accessor, the driver's loading and commands).
local fleet = require('earthBusRoutes/fleet')
local busnetrun = require('earthBusRoutes/busnetrun')
local connections = require('earthBusRoutes/connections')
local demand = require('earthBusRoutes/demand')
local speedlimit = require('earthBusRoutes/speedlimit')
local world = require('earthBusRoutes/world')
local M = {}
local TAG = 'earthBusRoutes'

M.RELOAD_MIN_S = 5            -- the paths are repaired for a moved graph at most this often
M.SIG_EVERY_S = 3             -- how often the graph is looked at for a change
M.RETRY_S = 60                -- after a failure the fleet stays off this long

local S, H
local st = { fl = nil, t = 0, sigT = 0, sig = nil, reloadAt = -1e9, offUntil = 0, warned = false }

-- 0 .. 6 buses; 0 when the option is off or there is no virtual net to take trips from
function M.wanted()
  if not S then return 0 end
  if (S.opts.aiBuses or 'off') ~= 'on' or (S.opts.busNet or 'on') == 'off' then return 0 end
  return fleet.limitOf(S.opts.busFleet == nil and 2 or S.opts.busFleet)
end

local function makeEnv()
  local env = {
    net = function() return busnetrun.net() end,
    clock = function() return busnetrun.clock() or world.nowSec() end,
    graph = world.navgraph, graphSig = world.navgraphSig, toGame = world.toGame,
    leftHand = function(route) return speedlimit.leftHand(route and route.limitInfo and route.limitInfo.cc) end,
    player = world.fleetPlayer, visible = world.fleetVisibleToPlayer,
    playerTrip = function()
      local t = S.trip
      if t and not t.finished and t.route then return { routeId = t.route.id, start = t.entry and t.entry.trip and t.entry.trip.start or nil } end
      return nil
    end,
    playerNext = function()
      local t = S.trip
      local stop = t and not t.finished and t.route and t.route.stops[t.idx]
      if stop then return { lat = stop.lat, lon = stop.lon, name = stop.name } end
      return nil
    end,
    spawn = world.fleetSpawn, place = world.fleetPlace, hide = world.fleetHide, remove = world.fleetRemove,
    alive = world.fleetAlive, pos = world.fleetPos, load = world.fleetLoad, send = world.fleetSend,
    density = function() return S.opts.density or 'normal' end,
    night = function() local s = world.nowSec() return s < 6 * 3600 or s >= 20 * 3600 end,
    log = function(level, text) log(level, TAG, text) end,
  }
  return env
end

-- the live transfers of connections.lua are answered by the fleet while it runs
local function liveProvider()
  return {
    request = function(req)
      if not st.fl then return nil end
      return fleet.requestTransfer(st.fl, { ref = req.ref, at = req.at, stop = req.stop })
    end,
    status = function(token) return st.fl and fleet.transferStatus(st.fl, token) or 'gone' end,
    cancel = function(token) if st.fl then fleet.cancelTransfer(st.fl, token) end end,
  }
end

local function teardown()
  if st.fl then pcall(fleet.shutdown, st.fl) end
  st.fl, st.sig = nil, nil
  demand.book.active = false
  connections.live = nil
end

function M.shutdown() teardown() end

local function ensure(n)
  if st.fl then return true end
  if not world.fleetAvailable() then
    if not st.warned then
      st.warned = true
      log('I', TAG, 'fleet: the game functions the AI buses need are missing: the fleet stays off')
    end
    return false
  end
  st.fl = fleet.new(makeEnv(), { n = n })
  demand.book.active = true
  connections.live = liveProvider()
  log('I', TAG, ('fleet: on, %d buses'):format(n))
  return true
end

function M.frame(dt)
  dt = dt or 0
  st.t = st.t + dt
  if st.t < st.offUntil then return end
  local n = M.wanted()
  if n == 0 and not st.fl then return end
  if not ensure(n) then return end
  fleet.setLimit(st.fl, n)
  fleet.frame(st.fl, dt)
  if n == 0 and #st.fl.slots == 0 then teardown() return end
  -- the graph moved: the paths of the buses follow it
  st.sigT = st.sigT + dt
  if st.sigT >= M.SIG_EVERY_S then
    st.sigT = 0
    local sig = world.navgraphSig()
    if sig ~= st.sig then
      st.sig = sig
      if sig and st.t - st.reloadAt >= M.RELOAD_MIN_S then
        st.reloadAt = st.t
        fleet.onGraphReload(st.fl)
      end
    end
  end
end

-- the driver of vehicle `id` reports (called from main.lua's onEarthBusDriverEvent)
function M.onBusDriverEvent(id, name, data)
  if st.fl then fleet.onEvent(st.fl, id, name, data) end
end

function M.onTeleport() if st.fl then fleet.onTeleport(st.fl) end end

function M.onGraphReload() if st.fl then fleet.onGraphReload(st.fl) end end

-- for the menu's diagnostics line (nil when the fleet is off)
function M.info()
  if not st.fl then return nil end
  local s = fleet.stats(st.fl)
  return { n = s.n, pool = s.pool, physical = s.physical, stuck = s.stuck, relocated = s.relocated, removed = s.removed, spawned = s.spawned,
    transfers = s.transfers }
end

-- the numbers of the stage T0 measurements (stuck causes, events, hand-backs)
function M.stats() return st.fl and fleet.stats(st.fl) or nil end

local function guard(name, fn, default)
  return function(...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    log('E', TAG, 'fleet: ' .. name .. ' failed: ' .. tostring(a))
    st.offUntil = st.t + M.RETRY_S
    pcall(teardown)
    return default
  end
end

function M.attach(mainModule, state, host)
  S, H = state, host
  M.frame = guard('frame', M.frame, nil)
  M.onBusDriverEvent = guard('event', M.onBusDriverEvent, nil)
  M.onTeleport = guard('onTeleport', M.onTeleport, nil)
  M.onGraphReload = guard('onGraphReload', M.onGraphReload, nil)
  M.info = guard('info', M.info, nil)
end

M._state = st

return M
