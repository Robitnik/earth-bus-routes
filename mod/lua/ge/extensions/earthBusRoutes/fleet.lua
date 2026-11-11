-- The physical buses of the AI fleet (plan 007, stage T4/T5): a small pool of real buses that take over the trips of the virtual
-- network (busnet.lua) when those come near the player, drive them with the vehicle-side driver (busdriver.lua) and give them back
-- to the network, with the delay they measured, when they leave. Pure logic, no game calls: everything the game gives is
-- injected through `env`, so the tests run it under lupa with a fake world and a fake driver. fleetrun.lua builds the real env
-- from world.lua. Lua 5.1 syntax.
--
-- THE GUARANTEE (the player's requirement: a bus can never stay stuck). Three levels, this is the last one:
--   1. routegraph never builds a path the bus cannot drive, and spawns only on a safe spot out of the player's sight;
--   2. busdriver.lua has a bounded ladder of recoveries and reports `stuck`, `reroute`, `edge`, `flipped`, `offgraph`, `failed`;
--   3. THIS FILE answers every report, and has a watchdog of its own that does not trust the driver (a driver can crash):
--        - a bus that has not moved 3 m for FLEET_STALL_S outside a legitimate wait (a dwell at a stop, a red light of a
--          healthy driver) is in trouble; so is a bus that has been silent for SILENT_S (the fleet asks for `status` every
--          STATUS_EVERY_S, any event counts as a sign of life);
--        - trouble is solved by teleporting the bus onto the path ahead (a spot out of sight), or, when that is not possible
--          or has happened MAX_RELOCATES times, by taking the bus out of the pool: the trip goes on virtually with its delay;
--        - a bus the player can see is never moved or removed while he looks, unless the trouble has lasted
--          VISIBLE_MULT times the base wait (a bus that cannot move must not stand in the street for ever).
--
-- env (all functions; the ones marked ? may be missing):
--   env.net()            -> the busnet net (busnet.new) or nil          env.clock() -> game clock, s from midnight (the net's clock)
--   env.graph()          -> navgraph nodes { name = { pos, radius, links } } or nil     env.graphSig()? -> a value that changes when the graph does
--   env.toGame(lat, lon) -> x, y [, z]                                   env.leftHand(route)? -> bool
--   env.player()         -> { x, y, z, lat, lon, speed } or nil          env.visible(x, y, z) -> bool (true when in doubt)
--   env.playerTrip()?    -> { routeId, start } the player's own trip (never served by the AI) or nil
--   env.playerNext()?    -> { lat, lon, name } the stop the player calls at next, or nil
--   env.spawn()          -> vehicle id (hidden) or nil     env.place(id, pose, fresh) -> bool     env.hide(id)     env.remove(id)
--   env.alive(id)        -> bool          env.pos(id) -> x, y, z | nil     env.load(id)     env.send(id, cmd) -> bool (the driver's protocol)
--   env.density()? -> 'low'|'normal'|'high'     env.night()? -> bool     env.log(level, text)?
--
-- A pool slot: { id, state = 'free' | 'busy', key (the busnet trip), trip, res (routegraph result), along (path m), ... }.
local busnet = require('earthBusRoutes/busnet')
local routegraph = require('earthBusRoutes/routegraph')
local demand = require('earthBusRoutes/demand')
local geo = require('earthBusRoutes/geomath')
local M = {}

M.MAX_N = 6
M.WINDOW_M = 350            -- a trip is a candidate when it will be this near the player (the graph window) ...
M.LOOKAHEAD_S = 90          -- ... within this time
M.LOOK_STEP_S = 15
M.SPAWN_M = 320             -- it becomes a physical bus when its virtual place is this near
M.REMOVE_M = 420            -- a bus farther than this goes back to the net as soon as the player cannot see it
M.HARD_M = 650              -- ... farther than this always (there is no ground and no graph out there)
M.NEAR_PLAYER_M = 40        -- never spawn / teleport nearer than this to the player
M.SELECT_EVERY_S = 1
M.WATCH_EVERY_S = 1
M.STATUS_EVERY_S = 5
M.POOL_EVERY_S = 1
M.SPAWN_GAP_S = 3           -- pool vehicles are spawned one per this many seconds (a spawn costs a frame)
M.FLEET_STALL_S = 60        -- a moving bus that has not advanced for this long outside a legitimate wait is stalled
M.MOVE_M = 3                -- ... advancing is moving this far
M.DWELL_CAP_S = 420         -- the longest legitimate stand at a stop (the driver's own bound is 240 + 90 + 60 + 30)
M.RED_CAP_S = 120           -- the longest legitimate stand of a healthy driver on the road (a red light: the driver's own bound is 100)
M.SILENT_S = 20             -- no event and no status for this long: the driver is dead
M.HARD_WAIT_S = 15          -- base wait for flipped / failed / offgraph before a bus in sight is moved
M.VISIBLE_MULT = 3          -- a bus in sight is moved after this many times the base wait
M.MAX_RELOCATES = 3         -- teleports of one bus in one trip; the next trouble takes it out of the pool
M.MAX_REROUTES = 3
M.AHEAD_M = { 60, 100, 150, 220, 300, 400 }     -- where a relocated bus is put, ahead of where it was
M.BEHIND_M = { 0, -60, -120, -200, -300 }       -- where a new bus is put round its virtual place (behind it: early, never late)
M.BEHIND_STOP_M = { -60, -100, -160, -240, -320 }
M.AHEAD_TOL_M = 40
M.AFTER_S = 30
M.COOLDOWN_S = 180          -- a trip taken out for trouble is not made physical again for this long ...
M.MAX_ATTEMPTS = 3          -- ... and not more than this many times
M.NO_RES_S = 20             -- a line the graph could not be matched for is not tried again for this long
M.INDEX_MAX_AGE_S = 20
M.TERMINUS_HOLD_S = 8       -- a finished bus stays this long (its passengers get out) before it goes back
M.HUB_MATCH_M = 120
M.TRANSFER_TOL_S = 240      -- the line's trip is the one due at the hub within this of the announced time
M.TRANSFER_GRACE_S = 90     -- a transfer bus that is not physical this long after its time is given up (the timer decides)
M.TRANSFER_KEEP_S = 900
M.DELAY_KEEP_S = 7200
M.EDGE_RETRY_S = 10

local clamp = function(v, a, b) return math.max(a, math.min(b, v)) end

function M.limitOf(v)
  v = tonumber(v)
  if not v then return 2 end
  return clamp(math.floor(v + 0.5), 0, M.MAX_N)
end

function M.new(env, opts)
  opts = opts or {}
  return { env = env, t = 0, n = M.limitOf(opts.n == nil and 2 or opts.n), slots = {}, byId = {}, transfers = {}, nextToken = 1,
    delays = {}, cooldown = {}, attempts = {}, noRes = {}, nextSelect = 0, nextWatch = 0, nextStatus = 0, nextPool = 0, nextSpawn = 0,
    spawnFails = 0, spawnBlocked = 0, ix = nil, ixSig = nil, ixT = -1e9, active = false,
    counters = { spawned = 0, started = 0, handBack = 0, removed = 0, relocated = 0, stuck = 0, restarted = 0, byCause = {}, events = {} } }
end

local function count(fl, cause, k)
  fl.counters.byCause[cause] = (fl.counters.byCause[cause] or 0) + (k or 1)
end

local function say(fl, level, text)
  if fl.env.log then fl.env.log(level, 'fleet: ' .. text) end
end

-- ---- geometry on a routegraph result -------------------------------------------------------------------------------------------

-- the last node whose cumulative metres are <= along, within 1..n-1
local function nodeAt(res, along)
  local cum = res.cum
  local lo, hi = 1, #cum
  if along <= 0 then return 1 end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if cum[mid] <= along then lo = mid else hi = mid end
  end
  return math.min(lo, math.max(1, #cum - 1))
end

-- route metres -> path metres through the anchors (outside them 1:1 from the nearest anchor)
local function pathAlongOf(res, routeAlong)
  local ar, ap = res.anchors.ar, res.anchors.ap
  local n = #ar
  if n == 0 then return nil end
  if routeAlong <= ar[1] then return ap[1] - (ar[1] - routeAlong) end
  if routeAlong >= ar[n] then return ap[n] + (routeAlong - ar[n]) end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if ar[mid] <= routeAlong then lo = mid else hi = mid end
  end
  local span = ar[hi] - ar[lo]
  local f = span > 1e-9 and (routeAlong - ar[lo]) / span or 0
  return ap[lo] + (ap[hi] - ap[lo]) * f
end

-- where (x, y) is along the path: path metres, distance off it. hint + win limit the search to that part of the path.
local function project(res, x, y, hint, win)
  local pts, cum = res.pts, res.cum
  local n = #pts
  if n < 2 then return nil end
  local from, to = 1, n - 1
  if hint then
    from = nodeAt(res, hint - win)
    to = nodeAt(res, hint + win)
  end
  local bestA, bestD
  for i = from, to do
    local a, b = pts[i], pts[i + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local l2 = ex * ex + ey * ey
    local t = 0
    if l2 > 1e-9 then t = clamp(((x - a.x) * ex + (y - a.y) * ey) / l2, 0, 1) end
    local qx, qy = a.x + ex * t, a.y + ey * t
    local d = math.sqrt((x - qx) ^ 2 + (y - qy) ^ 2)
    if not bestD or d < bestD then bestD, bestA = d, cum[i] + t * (cum[i + 1] - cum[i]) end
  end
  return bestA, bestD
end

local function dist2(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- ---- the graph --------------------------------------------------------------------------------------------------------------------

local function index(fl)
  local g = fl.env.graph and fl.env.graph()
  if not g then return nil end
  local sig = fl.env.graphSig and fl.env.graphSig() or nil
  if not fl.ix or sig ~= fl.ixSig or fl.t - fl.ixT > M.INDEX_MAX_AGE_S then
    local ok, ix = pcall(routegraph.index, g)
    if not ok then count(fl, 'indexFailed') say(fl, 'W', 'graph index failed: ' .. tostring(ix)) return nil end
    fl.ix, fl.ixSig, fl.ixT = ix, sig, fl.t
  end
  return fl.ix
end

local function leftHand(fl, route)
  return fl.env.leftHand and fl.env.leftHand(route) or false
end

local function buildOpts(fl, route, extra)
  local o = { toGame = fl.env.toGame, leftHand = leftHand(fl, route) }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- ---- the crowd of a trip -----------------------------------------------------------------------------------------------------------

-- Who boards and who gets off at every stop of a trip (the people model of demand.lua; the same crowd every time for a trip). The
-- people of a stop that a bus of the line took a moment ago are fewer (demand.book, shared with the player's trips).
local function crowdFor(fl, trip, firstIdx)
  local route = trip.line.route
  local w, central = demand.stopWeights(route, nil)
  local net = fl.env.net()
  local day = net and net.day or 1
  local weekend = day >= 6
  local dens = fl.env.density and fl.env.density() or 'normal'
  local key = demand.lineKey(route)
  local prev
  for k, t in ipairs(trip.line.trips) do if t == trip then prev = trip.line.trips[k - 1] break end end
  local n = #route.stops
  local board, dest = {}, {}
  local seed = demand.hashSeed(trip.key)
  for i = 1, n do
    local at = trip.start + (trip.dep[i] or 0)
    local headway = 600
    if prev and prev.dep[i] then headway = math.max(60, at - (prev.start + prev.dep[i])) end
    local stop = route.stops[i]
    local since = headway
    if i >= firstIdx then since = demand.sharedSince(demand.book, stop.lat, stop.lon, key, at, headway) end
    local hour = (at / 3600) % 24
    board[i] = demand.waiting(route, w, central, i, hour, weekend, since, { tripId = seed, day = day, density = dens })
    local rand = demand.rng(demand.hashSeed(route.id or route.ref, trip.key, i, 'ai'))
    dest[i] = {}
    for _ = 1, board[i] do
      local d = demand.destination(route, w, central, i, hour, weekend, rand)
      dest[i][d] = (dest[i][d] or 0) + 1
    end
  end
  local crowd = {}
  for i = 1, n do
    local alight = 0
    for j = 1, i - 1 do alight = alight + (dest[j][i] or 0) end
    crowd[i] = { board = i == n and 0 or board[i], alight = alight }
  end
  return crowd
end

-- ---- commands to the driver ---------------------------------------------------------------------------------------------------------

local function stopsFor(fl, b, base)
  local res, trip = b.res, b.trip
  local route = trip.line.route
  local n = #route.stops
  local out = {}
  for _, st in ipairs(res.stops) do
    local i = st.index
    if trip.arr[i] and not b.served[i] and st.along - base > -25 then
      local c = b.crowd and b.crowd[i] or { board = 0, alight = 0 }
      local side = st.side
      if not side or side == 0 then side = leftHand(fl, route) and -1 or 1 end
      out[#out + 1] = { id = i, along = st.along - base, side = side > 0 and 'r' or 'l', sched = trip.start + (trip.dep[i] or 0),
        alight = c.alight, board = c.board, kneel = true, terminus = (i == n) }
    end
  end
  return out
end

-- path / pts / stops of the result from the node at or before `fromAlong` (path m); the driver counts along from that node
local function pathCommand(fl, b, c, fromAlong)
  local res = b.res
  local i = nodeAt(res, fromAlong)
  local base = res.cum[i]
  local path, pts = {}, {}
  for k = i, #res.path do
    path[#path + 1] = res.path[k]
    pts[#pts + 1] = { res.pts[k].x, res.pts[k].y }
  end
  c.path, c.pts, c.stops = path, pts, stopsFor(fl, b, base)
  b.base, b.nodeIndex = base, i
  return c
end

local function startCommand(fl, b, fromAlong)
  local c = { c = 'start', delaySec = b.trip.delay or 0, clock = fl.env.clock(), night = fl.env.night and fl.env.night() or false }
  return pathCommand(fl, b, c, fromAlong)
end

local function send(fl, b, cmd)
  local ok, r = pcall(fl.env.send, b.id, cmd)
  if not ok or r == false then count(fl, 'sendFailed') return false end
  return true
end

-- ---- slots ------------------------------------------------------------------------------------------------------------------------

local function resetSlot(b)
  local id = b.id
  for k in pairs(b) do b[k] = nil end
  b.id, b.state = id, 'free'
end

local function busyList(fl)
  local out = {}
  for _, b in ipairs(fl.slots) do if b.state == 'busy' then out[#out + 1] = b end end
  return out
end

local function freeSlot(fl)
  for _, b in ipairs(fl.slots) do if b.state == 'free' then return b end end
end

local function busyByKey(fl, key)
  for _, b in ipairs(fl.slots) do if b.state == 'busy' and b.key == key then return b end end
end

local function dropSlot(fl, b)
  for i, s in ipairs(fl.slots) do if s == b then table.remove(fl.slots, i) break end end
  fl.byId[b.id] = nil
end

local function seen(fl, x, y, z)
  local ok, v = pcall(fl.env.visible, x, y, z)
  if not ok then return true end
  return v ~= false
end

local function busPos(fl, b)
  local x, y, z = fl.env.pos(b.id)
  if x then b.x, b.y, b.z = x, y, z end
  return x, y, z
end

local function playerDist(fl, x, y)
  local p = fl.env.player()
  if not p or not x then return math.huge end
  return dist2(x, y, p.x, p.y)
end

-- Gives a physical bus back: the trip goes on virtually with the delay the bus had; the vehicle is hidden (or removed from the
-- pool for good when `remove`). `trouble` keeps the trip from being made physical again at once.
local function release(fl, b, cause, remove, trouble)
  if b.state ~= 'busy' then return end
  local net = fl.env.net()
  local key = b.key
  if key then
    if b.late then fl.delays[key] = { late = b.late, at = fl.t } end
    local tr = net and busnet.find(net, key)
    if tr then
      busnet.setPhysical(net, key, false)
      if b.late then busnet.setDelay(net, key, b.late) end
    end
    if trouble then
      fl.attempts[key] = (fl.attempts[key] or 0) + 1
      fl.cooldown[key] = fl.attempts[key] >= M.MAX_ATTEMPTS and math.huge or fl.t + M.COOLDOWN_S
    elseif cause ~= 'shutdown' and cause ~= 'teleport' then
      fl.cooldown[key] = fl.t + M.AFTER_S              -- (its virtual place may still be near: not at once again)
    end
    for _, e in pairs(fl.transfers) do
      if e.key == key and (e.state == 'live' or e.state == 'pending') then e.state = 'fallback' end
    end
  end
  pcall(fl.env.send, b.id, { c = 'abort' })
  pcall(fl.env.hide, b.id)
  count(fl, cause)
  fl.counters.handBack = fl.counters.handBack + 1
  say(fl, 'I', ('bus %s given back (%s) trip %s late %s'):format(tostring(b.id), cause, tostring(key), tostring(b.late)))
  if remove then
    pcall(fl.env.remove, b.id)
    fl.counters.removed = fl.counters.removed + 1
    dropSlot(fl, b)
  else
    resetSlot(b)
  end
end

-- ---- making a trip physical ---------------------------------------------------------------------------------------------------------

local function isPlayersTrip(fl, tr)
  local pt = fl.env.playerTrip and fl.env.playerTrip()
  if not pt then return false end
  return tr.line.id == pt.routeId and (pt.start == nil or math.abs(tr.start - pt.start) <= 150)
end

-- A place for a new bus: the safe spot nearest to the trip's virtual place, a little behind it, out of sight and not on the player
local function planSpawn(fl, cand)
  local env = fl.env
  local tr = cand.trip
  local route = tr.line.route
  local ix = index(fl)
  if not ix then return nil, 'noGraph' end
  local until_ = fl.noRes[tr.line.id]
  if until_ and until_ > fl.t then return nil, 'noRes' end
  local okB, res, why = pcall(routegraph.build, route, ix, buildOpts(fl, route, { nearAlong = cand.along }))
  if not okB or not res then
    fl.noRes[tr.line.id] = fl.t + M.NO_RES_S
    say(fl, 'W', 'no path for line ' .. tostring(tr.line.ref) .. ': ' .. tostring(okB and why or res))
    return nil, 'noRes'
  end
  if not res.ok then
    fl.noRes[tr.line.id] = fl.t + M.NO_RES_S
    return nil, 'resNotOk'
  end
  local a0 = pathAlongOf(res, cand.along)
  if not a0 then return nil, 'noRes' end
  local offs = cand.state == 'run' and M.BEHIND_M or M.BEHIND_STOP_M
  local sawSpot = false
  for _, off in ipairs(offs) do
    local sp = res.safeSpawn(a0 + off)
    if sp and sp.along >= a0 - 340 and sp.along <= a0 + M.AHEAD_TOL_M and sp.along <= res.usableTo - 30 then
      sawSpot = true
      if playerDist(fl, sp.x, sp.y) >= M.NEAR_PLAYER_M and not seen(fl, sp.x, sp.y, sp.z) then
        return { res = res, pose = sp }
      end
    end
  end
  return nil, sawSpot and 'visible' or 'noSpot'
end

local function spawnTrip(fl, cand, slot)
  local env = fl.env
  local plan, why = planSpawn(fl, cand)
  if not plan then
    count(fl, 'spawn_' .. why)
    return false, why
  end
  local tr = cand.trip
  local b = slot
  b.state, b.key, b.trip, b.res, b.prio = 'busy', tr.key, tr, plan.res, cand.prio
  b.served, b.relocates, b.reroutes, b.restarts = {}, 0, 0, 0
  b.startT, b.heardT, b.progressT, b.along = fl.t, fl.t, fl.t, plan.pose.along
  b.late = tr.delay
  b.crowd = crowdFor(fl, tr, cand.nextIndex or 1)
  if not env.place(b.id, plan.pose, true) then
    count(fl, 'placeFailed')
    resetSlot(b)
    return false, 'placeFailed'
  end
  b.x, b.y, b.z = plan.pose.x, plan.pose.y, plan.pose.z
  b.anchorX, b.anchorY, b.anchorT = b.x, b.y, fl.t
  env.load(b.id)
  send(fl, b, startCommand(fl, b, plan.pose.along))
  local net = env.net()
  busnet.setPhysical(net, tr.key, true)
  fl.counters.spawned = fl.counters.spawned + 1
  fl.counters.started = fl.counters.started + 1
  count(fl, 'spawn_ok')
  say(fl, 'I', ('trip %s (line %s) is physical on bus %s at %.0f m of %.0f'):format(tr.key, tostring(tr.line.ref), tostring(b.id), plan.pose.along, plan.res.length))
  return true
end

-- candidates: trips of the net that will be near the player soon, by priority
local function candidates(fl, net, player, clock)
  local out = {}
  local transferKeys = {}
  for _, e in pairs(fl.transfers) do
    if e.state == 'pending' or e.state == 'live' then transferKeys[e.key] = true end
  end
  local nextStop = fl.env.playerNext and fl.env.playerNext() or nil
  for _, e in ipairs(net.live) do
    local tr = net.byKey[e.key]
    local cd = fl.cooldown[e.key]
    if tr and not tr.physical and e.state ~= 'done' and not (cd and cd > fl.t) and not busyByKey(fl, e.key) and not isPlayersTrip(fl, tr)
      and not (e.state == 'wait' and (e.leaveIn or 0) > M.LOOKAHEAD_S) then
      local d0 = geo.dist(player.lat, player.lon, e.lat, e.lon)
      local minD = d0
      if d0 > M.WINDOW_M and d0 < M.WINDOW_M + 90 * 30 then
        for ts = M.LOOK_STEP_S, M.LOOKAHEAD_S, M.LOOK_STEP_S do
          local p = busnet.posOf(tr, net.clock + ts)
          local d = geo.dist(player.lat, player.lon, p.lat, p.lon)
          if d < minD then minD = d end
        end
      end
      if minD <= M.WINDOW_M then
        local prio = 3
        if transferKeys[e.key] then prio = 1
        elseif nextStop then
          local idx = busnet.matchStops(tr.line, nextStop)
          local from = e.nextIndex or e.index or 1
          for _, i in ipairs(idx) do if i >= from then prio = 2 break end end
        end
        out[#out + 1] = { trip = tr, key = e.key, state = e.state, along = e.along, nextIndex = e.nextIndex or e.index, prio = prio,
          d0 = d0, now = d0 <= M.SPAWN_M }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    if a.now ~= b.now then return a.now end
    if a.d0 ~= b.d0 then return a.d0 < b.d0 end
    return a.key < b.key
  end)
  return out
end

-- a lower priority bus that may go back to make room for a transfer: out of sight, not standing at a stop
local function preempt(fl, prio)
  local pick
  for _, b in ipairs(fl.slots) do
    if b.state == 'busy' and (b.prio or 3) > prio and not b.dwell and not b.finished then
      local x, y, z = busPos(fl, b)
      if x and not seen(fl, x, y, z) and (not pick or (b.prio or 3) > (pick.prio or 3)) then pick = b end
    end
  end
  if pick then
    release(fl, pick, 'preempted', false, false)
    return freeSlot(fl)
  end
end

local function selectTick(fl)
  local env = fl.env
  local net = env.net()
  local player = env.player()
  if not net or not net.clock or not player or not player.lat then return end
  -- a net that was built again knows nothing of the buses: say which trips are physical and what delay they had
  for _, b in ipairs(fl.slots) do
    if b.state == 'busy' and b.key then
      local tr = net.byKey[b.key]
      if tr and not tr.physical then busnet.setPhysical(net, b.key, true) end
    end
  end
  for key, d in pairs(fl.delays) do
    local tr = net.byKey[key]
    if tr and not tr.physical and tr.delay ~= d.late then busnet.setDelay(net, key, d.late) end
    if fl.t - d.at > M.DELAY_KEEP_S then fl.delays[key] = nil end
  end
  local cands = candidates(fl, net, player, net.clock)
  if #cands == 0 then return end
  local free = 0
  for _, b in ipairs(fl.slots) do if b.state == 'free' then free = free + 1 end end
  for ci, cand in ipairs(cands) do
    if cand.now then
      -- slots kept for the trips of a higher priority that are about to come in
      local reserve = 0
      for _, c2 in ipairs(cands) do if c2.prio < cand.prio and not c2.now then reserve = reserve + 1 end end
      local slot = freeSlot(fl)
      if slot and (cand.prio == 1 or free > reserve) then
        local ok = spawnTrip(fl, cand, slot)
        if ok then return end                                       -- one spawn per tick: a spawn costs a frame
      elseif not slot and cand.prio == 1 then
        local freed = preempt(fl, 1)
        if freed then
          local ok = spawnTrip(fl, cand, freed)
          if ok then return end
        end
      end
    end
  end
end

-- ---- trouble: teleport ahead, or give the bus back -----------------------------------------------------------------------------------

-- Puts the bus on the path ahead of where it is, on a safe spot out of sight. Returns true when it did.
local function relocateAhead(fl, b)
  local res = b.res
  if not res then return false end
  local from = b.along or 0
  for _, ahead in ipairs(M.AHEAD_M) do
    local sp = res.safeSpawn(from + ahead)
    if sp and sp.along > from + 20 and sp.along <= res.usableTo - 30
      and playerDist(fl, sp.x, sp.y) >= M.NEAR_PLAYER_M and not seen(fl, sp.x, sp.y, sp.z) then
      if fl.env.place(b.id, sp, true) then
        b.along, b.x, b.y, b.z = sp.along, sp.x, sp.y, sp.z
        b.anchorX, b.anchorY, b.anchorT = sp.x, sp.y, fl.t
        b.relocates = b.relocates + 1
        b.dwell, b.dwellIdx, b.offSince, b.rung = false, nil, nil, 0
        -- a bus put past the stops in between does not serve them
        for _, st in ipairs(res.stops) do if st.along < sp.along - 20 then b.served[st.index] = true end end
        send(fl, b, startCommand(fl, b, sp.along))                 -- a fresh start from here: the safest way to make a driver right again
        b.heardT = fl.t
        fl.counters.relocated = fl.counters.relocated + 1
        count(fl, 'relocated')
        say(fl, 'I', ('bus %s relocated to %.0f m (%s)'):format(tostring(b.id), sp.along, tostring(b.trouble and b.trouble.cause)))
        return true
      end
    end
  end
  return false
end

local function setTrouble(fl, b, kind, cause, hard, kill)
  local old = b.trouble
  if old then
    -- the first trouble keeps its clock; only a removal or a harder fault takes the place of a milder one
    if (kind == 'remove' and old.kind ~= 'remove') or (hard and not old.hard) then
      b.trouble = { kind = kind, cause = cause, hard = hard or false, since = old.since, kill = kill or false }
    end
    return
  end
  b.trouble = { kind = kind, cause = cause, hard = hard or false, since = fl.t, kill = kill or false }
  count(fl, 'trouble_' .. kind)
  if cause then count(fl, 'cause_' .. cause) end
  say(fl, 'W', ('bus %s trouble %s (%s) along %s'):format(tostring(b.id), kind, tostring(cause), tostring(b.along)))
end

local function troubleAction(fl, b)
  local tr = b.trouble
  local x, y, z = busPos(fl, b)
  local unseen = x ~= nil and not seen(fl, x, y, z)
  local wait = tr.hard and M.HARD_WAIT_S or M.FLEET_STALL_S
  local forced = fl.t - tr.since >= M.VISIBLE_MULT * wait
  if not x then unseen = true end                                    -- no position: nothing to look at
  if not unseen and not forced then return end
  if tr.kind == 'remove' then
    release(fl, b, 'removed_' .. tostring(tr.cause), tr.kill, true)
    return
  end
  if b.relocates >= M.MAX_RELOCATES then
    release(fl, b, 'gave_up', false, true)
    return
  end
  if relocateAhead(fl, b) then
    b.trouble = nil
    return
  end
  -- no spot out of sight ahead: the bus goes back to the net (a bus in sight that cannot be moved is hidden after the extra wait)
  release(fl, b, 'no_spot', false, true)
end

-- ---- the path after the graph moved / near its end ---------------------------------------------------------------------------------

-- The path grown / cut for the graph as it is now. Returns 'same', 'changed' (and tells the driver) or nil when it cannot be kept.
local function repath(fl, b)
  local ix = index(fl)
  if not ix or not b.res then return nil end
  local x, y = busPos(fl, b)
  local old = b.res
  local okE, res = pcall(routegraph.extend, old, ix, { at = nodeAt(old, b.along or 0) })
  if not okE or not res then return nil end
  local grew = res.length > old.length + 10 or #res.path ~= #old.path or res.path[#res.path] ~= old.path[#old.path] or res.path[1] ~= old.path[1]
  if not grew then return 'same' end
  local a, off = nil, nil
  if x then a, off = project(res, x, y, nil, 0) end
  if not a or off > 25 then return nil end                           -- the bus is not on the new path any more
  b.res = res
  b.along = a
  send(fl, b, pathCommand(fl, b, { c = 'setPath' }, a))
  return 'changed'
end

-- ---- events from the driver ---------------------------------------------------------------------------------------------------------------

local H = {}

local function noteLate(fl, b, late)
  if type(late) ~= 'number' then return end
  b.late = late
  local net = fl.env.net()
  if net and b.key then busnet.setDelay(net, b.key, late) end
end

function H.ready(fl, b, d) b.ready = true end

function H.atStop(fl, b, d)
  b.dwell, b.dwellIdx, b.dwellT = true, tonumber(d.id) or d.i, fl.t
  b.doorfault = d.fault == true
  b.progressT, b.anchorX, b.anchorY, b.anchorT = fl.t, b.x, b.y, fl.t
  local i = b.dwellIdx
  if i then
    b.served[i] = true
    local route = b.trip.line.route
    local stop = route.stops[i]
    local c = b.crowd and b.crowd[i]
    if stop then demand.markServed(demand.book, stop.lat, stop.lon, demand.lineKey(route), fl.env.clock(), c and c.board or 0) end
  end
  noteLate(fl, b, d.late)
end

function H.departed(fl, b, d)
  b.dwell, b.dwellIdx = false, nil
  b.progressT, b.anchorX, b.anchorY, b.anchorT = fl.t, b.x, b.y, fl.t
  noteLate(fl, b, d.late)
end

function H.skipped(fl, b, d)
  local i = tonumber(d.id) or d.i
  if i then b.served[i] = true end
  count(fl, 'skipped_' .. tostring(d.cause))
end

function H.delay(fl, b, d) noteLate(fl, b, d.late) end

function H.done(fl, b, d)
  b.finished, b.doneT, b.dwell = true, fl.t, false
  noteLate(fl, b, d.late)
end

function H.escalate(fl, b, d)
  b.rung = d.rung
  count(fl, 'escalate')
end

function H.recovered(fl, b, d)
  count(fl, 'recovered_by_driver')
  if b.trouble and b.trouble.kind == 'stuck' then b.trouble = nil end
  b.anchorX, b.anchorY, b.anchorT = b.x, b.y, fl.t
end

function H.stuck(fl, b, d)
  fl.counters.stuck = fl.counters.stuck + 1
  setTrouble(fl, b, 'stuck', tostring(d.cause or 'unknown'), false)
  troubleAction(fl, b)
end

function H.reroute(fl, b, d)
  b.reroutes = b.reroutes + 1
  local ix = index(fl)
  if b.reroutes > M.MAX_REROUTES or not ix or not d.blocked then
    setTrouble(fl, b, 'stuck', 'reroute_' .. tostring(d.cause), false)
    return troubleAction(fl, b)
  end
  local okR, res = pcall(routegraph.detour, b.res, d.blocked, ix, { at = nodeAt(b.res, b.along or 0) })
  if okR and res and (#res.problems.uturn > 0 or #res.problems.jumps > 0 or #res.problems.wrongWay > 0 or #res.problems.missing > 0) then
    res = nil                                                        -- a detour that turns round or leaves the graph is no detour
  end
  if not okR or not res then
    count(fl, 'reroute_failed')
    setTrouble(fl, b, 'stuck', 'reroute_' .. tostring(d.cause), false)
    return troubleAction(fl, b)
  end
  local x, y = busPos(fl, b)
  local a, off = nil, nil
  if x then a, off = project(res, x, y, nil, 0) end
  b.res = res
  count(fl, 'rerouted')
  if a and off <= 25 then
    b.along = a
    send(fl, b, pathCommand(fl, b, { c = 'setPath' }, a))
  else
    -- the new path does not pass where the bus stands: put the bus on it, out of sight
    b.along = a or 0
    setTrouble(fl, b, 'stuck', 'reroute_offpath', false)
    troubleAction(fl, b)
  end
end

function H.edge(fl, b, d)
  if b.edgeAt and fl.t - b.edgeAt < M.EDGE_RETRY_S then return end
  b.edgeAt = fl.t
  local r = repath(fl, b)
  if r == 'same' then b.leaving = true count(fl, 'edge_same')
  elseif r == 'changed' then b.leaving = false count(fl, 'edge_extended')
  else b.leaving = true count(fl, 'edge_lost') end
end

function H.flipped(fl, b, d)
  setTrouble(fl, b, 'flipped', 'flipped', true)
  troubleAction(fl, b)
end

function H.offgraph(fl, b, d)
  setTrouble(fl, b, 'offgraph', tostring(d.cause or 'offgraph'), true)
  troubleAction(fl, b)
end

function H.failed(fl, b, d)
  setTrouble(fl, b, 'failed', tostring(d.cause or 'failed'), true)
  troubleAction(fl, b)
end

function H.doorfault(fl, b, d)
  b.doorfault = true
  count(fl, 'doorfault')
  say(fl, 'W', ('bus %s door fault (%s)'):format(tostring(b.id), tostring(d.what)))
end

function H.signal_timeout(fl, b, d) count(fl, 'signal_timeout_' .. tostring(d.what)) end

function H.rejected(fl, b, d)
  count(fl, 'rejected_' .. tostring(d.reason))
  setTrouble(fl, b, 'remove', 'rejected', true)
  troubleAction(fl, b)
end

function H.status(fl, b, d)
  b.drvState, b.rung, b.statusT = d.state, d.rung, fl.t
  if type(d.late) == 'number' then noteLate(fl, b, d.late) end
end

-- An event of the driver of vehicle `id` (extensions.hook('onEarthBusDriverEvent', id, name, data)). Never throws.
function M.onEvent(fl, id, name, data)
  local b = fl.byId[id]
  if not b then return false end
  data = type(data) == 'table' and data or {}
  fl.counters.events[name] = (fl.counters.events[name] or 0) + 1
  if b.state ~= 'busy' then return false end
  b.heardT = fl.t
  local h = H[name]
  if not h then return true end
  local ok, err = pcall(h, fl, b, data)
  if not ok then
    count(fl, 'handler_error')
    say(fl, 'E', ('handler %s failed: %s'):format(tostring(name), tostring(err)))
    pcall(release, fl, b, 'handler_error', false, true)
  end
  return true
end

-- ---- the watchdog of the pool ------------------------------------------------------------------------------------------------------------

local function legitCap(fl, b)
  if b.dwell then return M.DWELL_CAP_S end
  if b.drvState == 'drive' and (b.rung or 0) == 0 and b.statusT and fl.t - b.statusT < M.STATUS_EVERY_S * 2 then return M.RED_CAP_S end
  return M.FLEET_STALL_S
end

local function watch(fl, b)
  local env = fl.env
  if not env.alive(b.id) then
    count(fl, 'vanished')
    release(fl, b, 'vanished', true, true)
    return
  end
  local x, y, z = busPos(fl, b)
  local pd = x and playerDist(fl, x, y) or math.huge
  -- where on its path the bus is
  if x and b.res then
    local a, off = project(b.res, x, y, b.along, 150)
    if a then
      b.along = a
      if off > 60 then
        b.offSince = b.offSince or fl.t
        if fl.t - b.offSince >= 15 then setTrouble(fl, b, 'stuck', 'off_path', false) end
      else b.offSince = nil end
    end
  end
  -- progress (independent of the driver)
  if x then
    if not b.anchorX or dist2(x, y, b.anchorX, b.anchorY) >= M.MOVE_M then
      b.anchorX, b.anchorY, b.anchorT = x, y, fl.t
      if b.trouble and b.trouble.kind == 'stall' then b.trouble = nil end
    elseif not b.finished and fl.t - b.anchorT > legitCap(fl, b) then
      setTrouble(fl, b, 'stall', 'pool_stall', false)
    end
  end
  -- silence
  if not b.finished and fl.t - b.heardT >= M.SILENT_S then
    if b.restarts < 1 and b.res then
      b.restarts = b.restarts + 1
      fl.counters.restarted = fl.counters.restarted + 1
      count(fl, 'driver_restarted')
      say(fl, 'W', ('bus %s driver silent for %.0f s: restarted'):format(tostring(b.id), fl.t - b.heardT))
      env.load(b.id)
      send(fl, b, startCommand(fl, b, b.along or 0))
      b.heardT = fl.t
    else
      setTrouble(fl, b, 'remove', 'silent_driver', true, true)
    end
  end
  -- leaving the window, finishing
  if b.trouble then
    troubleAction(fl, b)
    if b.state ~= 'busy' then return end
  end
  local unseen = not x or not seen(fl, x, y, z)
  if b.finished and fl.t - b.doneT >= M.TERMINUS_HOLD_S then
    if unseen or fl.t - b.doneT >= M.TERMINUS_HOLD_S + M.VISIBLE_MULT * M.FLEET_STALL_S then release(fl, b, 'finished', false, false) return end
  end
  if pd > M.HARD_M then release(fl, b, 'left_window_hard', false, false) return end
  if pd > M.REMOVE_M and unseen then release(fl, b, 'left_window', false, false) return end
  if b.leaving and unseen and b.res and (b.along or 0) >= b.res.length - 150 then release(fl, b, 'graph_end', false, false) return end
  if b.retire and unseen then release(fl, b, 'retired', true, false) return end
end

-- ---- live transfers ------------------------------------------------------------------------------------------------------------------

-- A transfer the player's dispatcher asks for: line `req.ref` arriving at the stop `req.stop` at about `req.at` (game clock).
-- Returns a token, or nil when this trip cannot become a physical bus (the timer decides then).
function M.requestTransfer(fl, req)
  local env = fl.env
  local net = env.net()
  if fl.n < 1 or not net or not req or not req.stop or not req.stop.lat then return nil end
  if not (env.graph and env.graph()) then count(fl, 'transfer_noGraph') return nil end
  local spec = { lat = req.stop.lat, lon = req.stop.lon, name = req.stop.name, radius = M.HUB_MATCH_M }
  local tr, idx, eta = busnet.findArrival(net, spec, req.ref, req.at, M.TRANSFER_TOL_S)
  if not tr then count(fl, 'transfer_noTrip') return nil end
  if isPlayersTrip(fl, tr) then return nil end
  local token = fl.nextToken
  fl.nextToken = token + 1
  fl.transfers[token] = { key = tr.key, idx = idx, ref = req.ref, at = eta, state = 'pending', since = fl.t }
  local mine = busyByKey(fl, tr.key)
  if mine then mine.prio = 1 end
  count(fl, 'transfer_asked')
  fl.cooldown[tr.key] = nil
  return token
end

-- 'pending' (not physical yet) | 'live' (a bus is driving it) | 'ready' (standing at the hub with the doors open) | 'fallback' | 'gone'
function M.transferStatus(fl, token)
  local e = fl.transfers[token]
  if not e then return 'gone' end
  return e.state
end

function M.cancelTransfer(fl, token)
  if fl.transfers[token] then count(fl, 'transfer_cancelled') end
  fl.transfers[token] = nil
end

local function updateTransfers(fl)
  local env = fl.env
  local net = env.net()
  local clock = net and net.clock or env.clock()
  for token, e in pairs(fl.transfers) do
    if clock > e.at + M.TRANSFER_KEEP_S then
      fl.transfers[token] = nil
    elseif e.state ~= 'ready' and e.state ~= 'fallback' then
      local b = busyByKey(fl, e.key)
      local tr = net and net.byKey[e.key]
      if b then
        if b.dwell and b.dwellIdx == e.idx and not b.doorfault then
          e.state = 'ready'
          count(fl, 'transfer_ready')
        elseif b.served[e.idx] and not b.dwell then
          e.state = 'fallback'                                       -- it passed the hub without standing there
          count(fl, 'transfer_missed')
        else
          e.state = 'live'
        end
      elseif not tr or fl.n < 1 or not (env.graph and env.graph()) or clock > e.at + M.TRANSFER_GRACE_S then
        e.state = 'fallback'
        count(fl, 'transfer_fallback')
      else
        e.state = 'pending'
      end
    end
  end
end

-- ---- the pool --------------------------------------------------------------------------------------------------------------------------------

local function maintain(fl)
  local env = fl.env
  for i = #fl.slots, 1, -1 do
    local s = fl.slots[i]
    if s.state == 'free' and not env.alive(s.id) then
      count(fl, 'vanished_free')
      fl.byId[s.id] = nil
      table.remove(fl.slots, i)
    end
  end
  if #fl.slots > fl.n then
    for i = #fl.slots, 1, -1 do
      if #fl.slots <= fl.n then break end
      local s = fl.slots[i]
      if s.state == 'free' then
        pcall(env.remove, s.id)
        fl.byId[s.id] = nil
        table.remove(fl.slots, i)
        count(fl, 'pool_shrunk')
      end
    end
    for _, s in ipairs(fl.slots) do if s.state == 'busy' and #fl.slots > fl.n then s.retire = true end end
  end
  if #fl.slots < fl.n and fl.t >= fl.nextSpawn and fl.t >= fl.spawnBlocked then
    fl.nextSpawn = fl.t + M.SPAWN_GAP_S
    local ok, id = pcall(env.spawn)
    if ok and id then
      local slot = { id = id, state = 'free' }
      fl.slots[#fl.slots + 1] = slot
      fl.byId[id] = slot
      fl.spawnFails = 0
      count(fl, 'pool_spawned')
    else
      fl.spawnFails = fl.spawnFails + 1
      count(fl, 'pool_spawn_failed')
      if fl.spawnFails >= 3 then
        fl.spawnBlocked = fl.t + 60
        fl.spawnFails = 0
        say(fl, 'W', 'the pool could not spawn a bus 3 times: trying again in a minute')
      end
    end
  end
end

-- Every bus back to the net and the pool emptied (the option switched off, or the game functions are gone)
function M.shutdown(fl)
  for _, b in ipairs(busyList(fl)) do release(fl, b, 'shutdown', false, false) end
  for i = #fl.slots, 1, -1 do
    pcall(fl.env.remove, fl.slots[i].id)
    fl.byId[fl.slots[i].id] = nil
    table.remove(fl.slots, i)
  end
  fl.transfers = {}
  fl.active = false
end

function M.setLimit(fl, n)
  fl.n = M.limitOf(n)
end

-- The player was teleported: nothing of what the buses drove on is there any more
function M.onTeleport(fl)
  for _, b in ipairs(busyList(fl)) do release(fl, b, 'teleport', false, false) end
  fl.ix, fl.ixSig = nil, nil
  fl.noRes, fl.cooldown = {}, {}
  for _, e in pairs(fl.transfers) do if e.state ~= 'ready' then e.state = 'fallback' end end
end

-- The graph was loaded again (the player moved): every path is cut and grown for it, or the bus goes back
function M.onGraphReload(fl)
  fl.ix, fl.ixSig = nil, nil
  for _, b in ipairs(busyList(fl)) do
    local r = repath(fl, b)
    if r == nil then
      count(fl, 'graph_lost')
      setTrouble(fl, b, 'remove', 'graph_lost', false)
    end
  end
end

-- One frame: dt real seconds
function M.frame(fl, dt)
  fl.t = fl.t + (dt or 0)
  if fl.n < 1 then
    if fl.active or #fl.slots > 0 then M.shutdown(fl) end
    return
  end
  fl.active = true
  if fl.t >= fl.nextPool then
    fl.nextPool = fl.t + M.POOL_EVERY_S
    maintain(fl)
  end
  if fl.t >= fl.nextWatch then
    fl.nextWatch = fl.t + M.WATCH_EVERY_S
    for _, b in ipairs(busyList(fl)) do
      local ok, err = pcall(watch, fl, b)
      if not ok then
        count(fl, 'watch_error')
        say(fl, 'E', 'watchdog failed: ' .. tostring(err))
        pcall(release, fl, b, 'watch_error', true, true)
      end
    end
    updateTransfers(fl)
  end
  if fl.t >= fl.nextStatus then
    fl.nextStatus = fl.t + M.STATUS_EVERY_S
    for _, b in ipairs(busyList(fl)) do send(fl, b, { c = 'status' }) end
    local net = fl.env.net()
    if net and net.clock then demand.pruneBook(demand.book, net.clock) end
  end
  if fl.t >= fl.nextSelect then
    fl.nextSelect = fl.t + M.SELECT_EVERY_S
    local ok, err = pcall(selectTick, fl)
    if not ok then
      count(fl, 'select_error')
      say(fl, 'E', 'selection failed: ' .. tostring(err))
    end
  end
end

-- ---- numbers -------------------------------------------------------------------------------------------------------------------------------

function M.stats(fl)
  local busy, keys = 0, {}
  for _, b in ipairs(fl.slots) do
    if b.state == 'busy' then busy = busy + 1 keys[#keys + 1] = b.key end
  end
  local by = {}
  for k, v in pairs(fl.counters.byCause) do by[k] = v end
  local ev = {}
  for k, v in pairs(fl.counters.events) do ev[k] = v end
  local tr = 0
  for _ in pairs(fl.transfers) do tr = tr + 1 end
  return { n = fl.n, pool = #fl.slots, physical = busy, keys = keys, spawned = fl.counters.spawned, started = fl.counters.started,
    handBack = fl.counters.handBack, removed = fl.counters.removed, relocated = fl.counters.relocated, stuck = fl.counters.stuck,
    restarted = fl.counters.restarted, transfers = tr, byCause = by, events = ev, t = fl.t }
end

M._index = index                       -- for the tests

return M
