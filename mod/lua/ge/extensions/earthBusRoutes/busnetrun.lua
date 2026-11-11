-- The game side of the virtual bus network (plan 007, T1): keeps a busnet.lua net for the area round the player, fed by the data
-- service (the trips of the real timetables, /v1/departures; elsewhere the lines of OpenStreetMap with generated timetables) and
-- publishes two things in the menu model: `buses` (the moving dots of the map) and `board` (the next departures of the station
-- on screen). It is attached by main.lua (busnetrun.attach); every hook runs under pcall, a failure only switches the net off.
-- Nothing here touches a vehicle; the physical buses (T3/T4) later take trips over through busnet.setPhysical.
-- Unverified in the game: the clock (world.nowSec follows the game's time of day), the cost of the background route loads.
local busnet = require('earthBusRoutes/busnet')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local datasvc = require('earthBusRoutes/datasvc')
local world = require('earthBusRoutes/world')
local M = {}
local TAG = 'earthBusRoutes'

M.GTFS_ROUTE = 10 ^ 12          -- relation ids of the lines made from the timetables: GTFS_ROUTE + pattern (as in the service)
M.MOVE_M = 1000                 -- the net is built again when the player is this far from where it was built
M.REFRESH_S = 300               -- ... or this old (real seconds)
M.RETRY_S = 20                  -- after a refresh that found nothing
M.TICK_S = 1                    -- positions are computed this often
M.PUBLISH_S = 3                 -- the open menu gets fresh positions this often (a small event, not the whole model)
M.RADIUS_M = 3000               -- the buses published are those this near the player
M.MAX_LINES = 30                -- routes loaded for the net (each one of the timetables is a road the service asks the routing servers for)
M.MAX_BUSES = 80
M.PARALLEL = 2                  -- routes loaded at once
M.SWAP_S = 8                    -- a half built net replaces the old one after this long

local S, H, main                -- main.lua's state, the functions it lends (publish) and its module
local st = { net = nil, job = nil, t = 0, tick = 0, publishT = 0, builtAt = nil, center = nil, buses = nil, clock = nil, failedAt = nil }

local function enabled() return (S.opts.busNet or 'on') ~= 'off' end

local function clockLabel(sec)
  sec = math.floor(sec % 86400)
  return ('%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

function M.reset()
  if st.job then st.job.dead = true end
  st.net, st.job, st.buses, st.builtAt, st.center, st.asking = nil, nil, nil, nil, nil, false
  st.token = (st.token or 0) + 1                 -- an answer still on its way is dropped
end

-- ---- building the net ----------------------------------------------------------------------------------------------------------

local function isGtfs(route)
  return route.timetable == 'gtfs' or (route.tags and route.tags['bus_routes:source'] == 'gtfs') or (route.id or 0) >= M.GTFS_ROUTE
end

-- A loaded route into the net of the job
local function addRoute(job, route)
  local ctx = { busy = job.busy }
  local opts = { clock = job.clock, day = job.day, ctx = ctx }
  if isGtfs(route) and not route.gtfsOffs then
    -- a pattern of the feed whose stops we could not all place: its trips from the answer of /v1/departures, their times fitted
    local pat = job.pattern[route.id]
    if not pat then return end
    local trips = {}
    for _, tr in ipairs(job.trips[route.id] or {}) do trips[#trips + 1] = { start = tr, offs = pat.offs } end
    opts.trips = trips
  end
  busnet.addLine(job.net, route, opts)
end

-- the job's net replaces the old one (when it is finished, or half built after SWAP_S: more lines join it as they load)
local function adopt(job)
  st.net, st.builtAt, st.center, st.builtClock = job.net, job.real, job.center, job.clock
  job.adopted = true
end

local function finishJob(job)
  if st.job ~= job then return end
  if not job.adopted then adopt(job) end
  st.job = nil
  if #job.net.order == 0 then st.failedAt = st.t end
  M.tick(true)
end

-- load the routes of the job a few at a time, in the background
local function pump(job)
  while job.inflight < M.PARALLEL and job.next <= #job.ids do
    local id = job.ids[job.next]
    job.next = job.next + 1
    local route = S.routes[id]
    if route then
      pcall(addRoute, job, route)
    elseif datasvc.has('routecached') == true then
      -- only what the service keeps on this computer: a background load never waits for a public server, so it never queues
      -- in front of the route the player asked for (0.10.0 queued 30 of them: five minutes). The road may be rough (straight
      -- between stops whose road was never asked for): kept for the dots only, never in S.routes the trips use.
      job.inflight = job.inflight + 1
      datasvc.routeKept(id, function(data)
        job.inflight = job.inflight - 1
        if job.dead then return end
        if data then
          local ok, r = pcall(osm.parseRoute, data)
          if ok and r then pcall(addRoute, job, r) end
        end
      end)
    end                                    -- (an older service: only the routes already loaded)
  end
end

local function startJob(pose, clock, day, heads, deps)
  if st.job then st.job.dead = true end
  local job = { net = busnet.new({ day = day }), center = { lat = pose.lat, lon = pose.lon }, clock = clock, day = day, real = st.t,
    ids = {}, next = 1, inflight = 0, pattern = {}, trips = {}, busy = false, startedAt = st.t }
  -- the lines to place: those the timetables run in the next minutes, else the lines of the map round here
  local seen = {}
  if deps and deps.patterns and #deps.patterns > 0 then
    for _, p in ipairs(deps.patterns) do
      job.pattern[p.id] = p
      if not seen[p.id] and #job.ids < M.MAX_LINES then seen[p.id] = true job.ids[#job.ids + 1] = p.id end
    end
    local byPid = {}
    for _, p in ipairs(deps.patterns) do byPid[p.pid] = p.id end
    for _, tr in ipairs(deps.trips or {}) do
      local rid = byPid[tr.pid]
      if rid then
        job.trips[rid] = job.trips[rid] or {}
        job.trips[rid][#job.trips[rid] + 1] = tr.start
      end
    end
  else
    for _, h in ipairs(heads or {}) do
      if not seen[h.id] and #job.ids < M.MAX_LINES then seen[h.id] = true job.ids[#job.ids + 1] = h.id end
    end
  end
  job.busy = #job.ids >= 10
  st.job = job
  pump(job)
end

-- Asks the service what runs round the player; the job starts when both answers are in
local function refresh(pose, clock, day)
  local token = (st.token or 0) + 1
  st.token = token
  st.askedAt, st.asking = st.t, true
  local heads, deps
  local waiting = 2
  local function done()
    waiting = waiting - 1
    if waiting > 0 or st.token ~= token then return end
    st.asking = false
    startJob(pose, clock, day, heads, deps)
  end
  datasvc.nearby(pose.lat, pose.lon, function(data)
    if data then
      local ok, a = pcall(osm.parseAround, data)
      if ok then heads = a.routes end
    end
    done()
  end, 'low')
  if datasvc.has('departures') == true then
    datasvc.departures(pose.lat, pose.lon, clock, day, 30, function(data)
      if type(data) == 'table' and type(data.patterns) == 'table' then deps = data end
      done()
    end)
  else
    done()
  end
end

-- ---- the model -----------------------------------------------------------------------------------------------------------------

local function round(x, n) local k = 10 ^ (n or 0) return math.floor(x * k + 0.5) / k end

local function modelOf(pose)
  local list = busnet.buses(st.net, { center = pose and { lat = pose.lat, lon = pose.lon } or nil, r = pose and M.RADIUS_M or nil })
  local out = {}
  for i, b in ipairs(list) do
    if i > M.MAX_BUSES then break end
    out[i] = { key = b.key, ref = b.ref, colour = b.colour, head = b.head, lat = round(b.lat, 6), lon = round(b.lon, 6),
      heading = round(b.heading, 0), state = b.state, next = b.next, nextIn = b.nextEta and round(b.nextEta, 0) or nil,
      late = round((b.delay or 0) / 60, 0) }
  end
  return out
end

-- The positions of the buses at `clock`, now. Called from the frame (every TICK_S) and after a build.
function M.tick(force)
  if not st.net then return end
  local clock = world.nowSec()
  st.clock = clock
  busnet.update(st.net, clock)
  st.buses = modelOf(world.pose())
  if force then st.publishT = M.PUBLISH_S end
end

function M.buses()
  if not enabled() then return nil end
  return st.buses
end

-- The state of the net for the menu: nil when it is off
function M.info()
  if not enabled() then return nil end
  local lines = st.net and #st.net.order or 0
  return { lines = lines, loading = st.job ~= nil, buses = st.buses and #st.buses or 0 }
end

-- The next departures of the station on screen: spec = { name, lat, lon, pts = platforms }; the rows for the board
function M.boardModel(spec, n)
  if not enabled() or not st.net or not spec then return nil end
  local clock = st.clock or world.nowSec()
  local rows = busnet.board(st.net, spec, clock, n or 6)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = { key = r.key, ref = r.ref, colour = r.colour, head = r.head, time = clockLabel(r.eta), inMin = math.max(0, math.floor(r.inS / 60)),
      late = round(r.delay / 60, 0), state = r.state, live = r.physical or nil }
  end
  return { name = spec.name, rows = out, lines = #st.net.order, loading = st.job ~= nil }
end

-- ---- the frame -----------------------------------------------------------------------------------------------------------------

function M.frame(dt)
  if not enabled() then
    if st.net or st.job then M.reset() end
    return
  end
  st.t = st.t + (dt or 0)
  local job = st.job
  if job then
    pump(job)
    if job.next > #job.ids and job.inflight == 0 then finishJob(job)
    elseif not job.adopted and st.t - job.startedAt > M.SWAP_S and #job.net.order > 0 then adopt(job) end
  end
  st.tick = st.tick + (dt or 0)
  if st.tick < M.TICK_S then return end
  st.tick = 0
  local pose = world.pose()
  if not pose then return end
  local clock, day = world.nowSec(), world.weekday()
  local stale = not st.net
  if st.net then
    stale = (st.builtAt and st.t - st.builtAt > M.REFRESH_S) or (st.center and geo.dist(st.center.lat, st.center.lon, pose.lat, pose.lon) > M.MOVE_M)
      or st.net.day ~= day or math.abs(clock - (st.builtClock or clock)) > 1800
  end
  if stale and not st.job then
    local waited = st.askedAt and st.t - st.askedAt or math.huge
    if (not st.asking or waited > 60) and waited > (st.net and 5 or 3) and not (st.failedAt and st.t - st.failedAt < M.RETRY_S)
      and datasvc.state.up ~= false then
      refresh(pose, clock, day)
    end
  end
  M.tick()
  -- the open menu shows moving dots and a live board
  st.publishT = st.publishT + M.TICK_S
  if datasvc.watching and st.publishT >= M.PUBLISH_S and st.net and (S.screen == 'nearby' or S.screen == 'lines') then
    st.publishT = 0
    M.sendLive()
  end
end

-- The net the fleet (plan 007 T4) takes its trips from, and the clock it was last computed for: nil while there is none
function M.net() if enabled() then return st.net end end
function M.clock() return st.clock end

function M.onTeleport() st.builtAt = -1e9 end

-- The moving dots and the board go to the open menu as a small event of their own: sending the whole model (hundreds of map
-- stops) every few seconds made the menu stutter (0.10.0)
function M.sendLive()
  local spec = main and main.boardSpec and main.boardSpec() or nil
  guihooks.trigger('EarthBusRoutesBuses', { buses = M.buses(), busNet = M.info(), board = M.boardModel(spec) })
end

-- ---- attach ----------------------------------------------------------------------------------------------------------------------

local function guard(name, fn, default)
  return function(...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    log('E', TAG, 'busnet: ' .. name .. ' failed: ' .. tostring(a))
    if name == 'frame' then pcall(M.reset) end
    return default
  end
end

function M.attach(mainModule, state, host)
  S, H, main = state, host, mainModule
  M.frame = guard('frame', M.frame, nil)
  M.buses = guard('buses', M.buses, nil)
  M.info = guard('info', M.info, nil)
  M.boardModel = guard('boardModel', M.boardModel, nil)
  M.onTeleport = guard('onTeleport', M.onTeleport, nil)
end

-- for the tests
M._state = st

return M
