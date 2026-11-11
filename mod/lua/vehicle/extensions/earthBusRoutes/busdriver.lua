-- Earth Bus Routes: the bus driver (plan 007, stage T3). A VEHICLE-side Lua extension that runs inside every physical AI bus.
-- It drives the game's own AI (ai.lua) through its public API and adds what the game's `manual` mode lacks: traffic lights,
-- STOP signs, give-way at junctions, bus bays (indicator, kerb, kneel, doors, dwell, timetable), queueing, catch-up and, above
-- all, a finite ladder of recoveries so that a bus can NEVER stay stuck.
--
-- Lua 5.1 (LuaJIT) syntax only. The file has two layers:
--   core    : pure state machine and decision functions. No game globals: every access to the game goes through the `env`
--             table handed to core.new(env), so tests/test_busdriver.lua drives it with a fake world.
--   adapter : at the bottom; builds `env` from the game's globals (obj, ai, electrics, mapmgr, controller), every call in pcall.
--
-- LOADING (GE side, stage T4 fleet.lua):
--   be:queueObjectLua(vehId, "extensions.load('earthBusRoutes_busdriver')")           -- file lua/vehicle/extensions/earthBusRoutes/busdriver.lua
--   be:queueObjectLua(vehId, "earthBusRoutes_busdriver.cmd(" .. serialize(command) .. ")")   -- or .cmdJson('<json>')
--
-- PROTOCOL  GE -> bus, a Lua table with field `c` (the command):
--   {c='start', path={'s1_1','s1_2',...}, pts={{x,y},...}, stops={...}, delaySec=0, clock=nil, night=false, cfg={...}}
--        path   node names of the navgraph, in driving order (the first one is behind or at the bus)
--        pts    optional x,y of every path node (same order). Without it the driver reads them from the graph and guesses 25 m
--               for nodes it cannot see yet. `along` of a stop is the distance in metres along the polyline of these points.
--        stops  list of {id=, along=, side='r'|'l', sched=, dwellS=, alight=, board=, kneel=true|false, terminus=true|false}
--               along = where the FRONT DOOR must stand (the stop anchor). side = kerb side relative to the travel direction.
--               sched = scheduled DEPARTURE, in the same clock as `clock` (seconds of day or any); without `clock` it is
--               seconds after the start command. dwellS = fixed dwell, else alight*ALIGHT_S + board*BOARD_S (demand.lua).
--               terminus (or the last stop within 30 m of the path end): let everybody out, then event `done`.
--        delaySec  lateness at the start (s), > 0 makes the driver catch up.
--        cfg    overrides of core.DEFAULTS (kerbShift, doorOffset, strategy, yieldFallback, allowReverse, ...)
--   {c='abort'}                 stop where it is, close doors, indicators off, forget the route (state idle)
--   {c='setLate', sec=N}        the dispatcher's idea of the lateness (changes the aggression only)
--   {c='sync', clock=N}         re-synchronise the schedule clock
--   {c='hold', sec=N}           keep the doors open N more seconds at the current stop (transfer; capped by LIMITS.HOLD_MAX_S)
--   {c='skipStop', id=ID}       do not serve this stop (id or index)
--   {c='setPath', path=, pts=, stops=}   answer to event `reroute` (a new path; stops matched by id keep their served state)
--   {c='relocate'}              the GE teleported the bus: forget the stall, re-issue the path from the nearest node
--   {c='lights', on=bool}       headlights (night)
--   {c='status'}                answers with event `status`
-- bus -> GE: extensions.hook('onEarthBusDriverEvent', vehId, name, data)   data is a table; always has t (vehicle sim time)
--   ready{n,stops}  atStop{i,id,late,short,dist}  departed{i,id,late}  skipped{i,id,cause}  delay{late}  done{late,counters}
--   escalate{rung,name,cause}   one per ladder rung entered
--   stuck{cause,x,y,z,along,node,rung,count,stalled}  the final guarantee: the GE must act (teleport ahead out of sight,
--                                                     or put the bus back in the pool and continue the trip virtually)
--   reroute{cause,from,blocked={a,b},along}  ask routegraph for a path avoiding the edge; answer with setPath
--   edge{remaining}  the route continues beyond the known graph and the bus is nearing the end of it
--   flipped{x,y,z}  rolled over: respawn.   offgraph{cause,x,y,z}  no ground / the path ran out: remove or teleport
--   recovered{rung,cause,stalled}  moving again after a ladder   doorfault{what}   signal_timeout{what,key}
--   failed{cause}  the driver gave up after LIMITS.MAX_REPORTS reports   rejected{reason}   status{...}
--
-- STUCK CAUSES (string in escalate/stuck/reroute/recovered): path_end (the graph ends), deadlock (facing vehicle),
--   wrong_way, signal, stopsign, giveway, bay (bay blocked), door, obstacle (standing vehicle ahead), no_response (throttle
--   without motion: damage), off_route, blocked. Counters (status/done events and drv.counters): stuck, recovered, reports,
--   reissues, skipped, flips, doorfaults, starts, rungs[1..7], byCause[cause]. T0 reads them for the stuck rate.
-- LADDER (each rung bounded by LIMITS.RUNG_S, the whole ladder by core.worstCaseToReportS()): 1 horn+creep, 2 re-plan
--   (driveUsingPath from the node behind the bus), 3 lane nudge (alternating sides; deadlock: both to their kerb), 4 reverse a
--   few metres (needs env.reverseStart: UNVERIFIED in game; skipped when something is behind), 5 skip the blocked stop or event
--   `reroute` (GE answers `setPath`), 6 event `stuck` (GE must teleport ahead out of sight or pool the bus), 7 wait
--   REPORT_COOLDOWN_S for the GE, then start again; after MAX_REPORTS reports state `failed` + event `failed`.
--   GE side needed for: reroute (setPath), stuck, flipped, offgraph, failed, edge (a longer path / a larger graph), doorfault.
local M = {}
local core = {}
M.core = core

local floor, min, max, abs, sqrt, huge = math.floor, math.min, math.max, math.abs, math.sqrt, math.huge

---------------------------------------------------------------------------------------------------------------------------
-- Named maxima (seconds unless said otherwise). The tests assert that no scenario keeps the bus standing longer than the
-- documented bound built from these.
---------------------------------------------------------------------------------------------------------------------------
local L = {
  MAX_STUCK_S = 40,           -- plain road, nothing legitimate to wait for: longer without progress starts the ladder
  RED_WAIT_MAX_S = 100,       -- longest wait at one red light (a cycle is ~90 s); then the stale signal is overridden
  STOPSIGN_HOLD_S = 2,        -- full stop at a STOP sign
  STOPSIGN_CLEAR_MAX_S = 15,  -- longest wait for the crossing to clear at a STOP sign
  GIVEWAY_MAX_S = 10,         -- longest wait for cross traffic at a give-way junction, then creep
  QUEUE_MAX_S = 60,           -- standing behind a stopped car (not at a signal) before it counts as stuck
  BAY_QUEUE_MAX_S = 40,       -- waiting for an occupied bay, then serve the stop short
  DEADLOCK_WAIT_S = 12,       -- two vehicles facing each other
  EDGE_STALL_S = 6,           -- the path ran out at the edge of the known graph
  DOOR_TIMEOUT_S = 6, DOOR_RETRIES = 2, KNEEL_TIMEOUT_S = 5,
  EARLY_WAIT_MAX_S = 240,     -- longest wait for the timetable at a stop
  DWELL_MAX_S = 90,           -- longest alight/board time
  HOLD_MAX_S = 60,            -- longest extension by the `hold` command
  PULLOUT_WAIT_S = 6,         -- longest wait for a gap when leaving the bay
  RUNG_S = { 6, 8, 8, 8, 12 },-- time spent on rungs 1..5 of the ladder
  REPORT_COOLDOWN_S = 30,     -- rung 7: after the report, wait for the GE this long
  MAX_REPORTS = 3,            -- then the driver gives up for good (state failed)
  FLIP_S = 2, NOGROUND_S = 1.5, OFFROUTE_M = 25, OFFROUTE_S = 5,
  REISSUE_MIN_S = 3, RECOVER_M = 6, PROG_M = 1.0,
}
L.INTERNAL_MAX_S = L.EARLY_WAIT_MAX_S + L.DWELL_MAX_S + L.HOLD_MAX_S + 30   -- safety net for the door/dwell states
M.LIMITS = L

-- time to the final guarantee (report) from the start of a stall on a plain road
function core.worstCaseToReportS()
  local s = L.MAX_STUCK_S
  for i = 1, #L.RUNG_S do s = s + L.RUNG_S[i] end
  return s
end

core.DEFAULTS = {
  cruiseAggression = 0.3, maxAggression = 0.45, lateFullS = 150,
  indicatorDist = 130, shiftDist = 120, shiftRamp = 60, kerbShift = 1.0, doorOffset = 2.0, stopTol = 2.0, shortMaxM = 45,
  approachDecel = 1.2, approachCreep = 0.9, approachZone = 90, stopMargin = 0.3,
  comfDecel = 2.5, hardDecel = 5.5, passedM = 2.0, yellowMargin = 2.0,
  signalHorizon = 160, junctionHorizon = 70, yieldZone = 30, junctionKmh = 15, junctionBackoff = 6, creepMs = 2.0,
  crossRadius = 40, crossHorizonS = 5, yieldFallback = true,
  occSpeed = 1.5, occLat = 1.8, queueGap = 3.0, busLen = 12, laneHalf = 2.4, aheadRange = 40,
  kneel = true, kneelS = 1.4, departIndicateS = 2.0, minDwellS = 6, boardS = 1.8, alightS = 1.2,
  strategy = 'speed',          -- 'speed' (speed curve + backstop), 'stoppoint' (setStopPoint only), 'routespeed0'
  allowReverse = true, reverseM = 4, nudgeM = 1.8, laneSign = 1,
  tickS = 0.1, closeLeadS = 5, groundCheck = true, maxIssueNodes = 80, extendNodes = 3,
}

local function merge(base, over)
  local r = {}
  for k, v in pairs(base) do r[k] = v end
  if type(over) == 'table' then for k, v in pairs(over) do r[k] = v end end
  return r
end

---------------------------------------------------------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------------------------------------------------------
function core.brakeDist(v, a) return v * v / (2 * (a > 0 and a or 1)) end

-- speed cap that lets the AI roll to a stop `dist` m ahead (dist = front bumper to the stop target)
function core.approachSpeed(dist, cfg)
  cfg = cfg or core.DEFAULTS
  if dist <= cfg.stopMargin then return 0 end
  local v = sqrt(2 * cfg.approachDecel * (dist - cfg.stopMargin))
  if dist > 0.6 and v < cfg.approachCreep then v = cfg.approachCreep end
  return v
end

-- 'go' | 'stop' | 'sign'. action: 0 go, 1 yellow, 2 red, 3 STOP sign (the game's signalsData). dist = metres to the line.
function core.signalDecision(action, dist, v, cfg, committed)
  cfg = cfg or core.DEFAULTS
  action = action or 0
  if action == 3 then return 'sign' end
  if action == 2 then
    if dist < -cfg.passedM then return 'go' end
    if dist < 0.5 and v > 2.0 then return 'go' end                              -- already crossing
    if v > 2.0 and core.brakeDist(v, cfg.hardDecel) > dist + 0.5 then return 'go' end -- cannot stop any more
    return 'stop'
  end
  if action == 1 then
    if committed or dist < 0 then return 'go' end
    if core.brakeDist(v, cfg.comfDecel) + cfg.yellowMargin <= dist then return 'stop' end
    return 'go'
  end
  return 'go'
end

-- the game's give-way test (ai.lua trafficStates): a turn of 45..135 degrees, or the road we come from is less important
function core.isGiveWay(inDx, inDy, outDx, outDy, drivIn, drivMax)
  local dot = inDx * outDx + inDy * outDy
  if abs(dot) < 0.707 then return true end
  return (drivIn or 1) < (drivMax or 1)
end

function core.aggressionFor(late, cfg)
  cfg = cfg or core.DEFAULTS
  if not late or late <= 30 then return cfg.cruiseAggression end
  local k = min(1, (late - 30) / cfg.lateFullS)
  return cfg.cruiseAggression + (cfg.maxAggression - cfg.cruiseAggression) * k
end

-- people model of demand.lua: alight*1.2 s + board*1.8 s, at least minDwell, at most DWELL_MAX_S
function core.dwellSeconds(stop, cfg)
  cfg = cfg or core.DEFAULTS
  local s = stop.dwellS
  if not s then s = (stop.alight or 0) * cfg.alightS + (stop.board or 0) * cfg.boardS end
  return max(cfg.minDwellS, min(L.DWELL_MAX_S, s))
end

-- when the doors may close: dwell over AND (timetable reached, if the stop has one), within EARLY_WAIT_MAX_S of opening
function core.departAt(openT, dwell, schedLocal, terminus, extraHold)
  local t = openT + dwell
  if schedLocal and not terminus then t = max(t, min(schedLocal, openT + L.EARLY_WAIT_MAX_S)) end
  if extraHold then t = max(t, extraHold) end
  return min(t, openT + L.EARLY_WAIT_MAX_S + L.DWELL_MAX_S + L.HOLD_MAX_S)
end

-- Is there cross traffic that would hit the junction at (jx,jy) within a few seconds? vehicles: {id,x,y,vx,vy}
function core.crossTrafficBlocked(jx, jy, vehicles, myDx, myDy, myId, cfg)
  cfg = cfg or core.DEFAULTS
  for _, u in ipairs(vehicles or {}) do
    if u.id ~= myId then
      local uvx, uvy = u.vx or 0, u.vy or 0
      local spd = sqrt(uvx * uvx + uvy * uvy)
      if spd > 1.5 then
        local rx, ry = jx - u.x, jy - u.y
        local dist = sqrt(rx * rx + ry * ry)
        if dist > 1 and dist < cfg.crossRadius and dist / spd < cfg.crossHorizonS then
          local approaching = (rx * uvx + ry * uvy) / (dist * spd) > 0.6
          local sameDir = (uvx * myDx + uvy * myDy) / spd > 0.7
          if approaching and not sameDir then return true, u end
        end
      end
    end
  end
  return false
end

-- Where the front door has to stop. pv = {{id, along, lat, len, speed}} in route coordinates. A standing vehicle in our lane
-- whose body reaches the bay moves the target behind its rear. Returns effective target, occupant (or nil).
function core.bayTarget(pv, tgt, F, cfg)
  cfg = cfg or core.DEFAULTS
  local eff, occ = tgt, nil
  for _, u in ipairs(pv or {}) do
    if u.speed < cfg.occSpeed and abs(u.lat) < cfg.occLat then
      local rear, front = u.along - u.len * 0.5, u.along + u.len * 0.5
      if front > F and rear < tgt + 1 then
        local cand = rear - cfg.queueGap
        if cand < eff then eff, occ = cand, u end
      end
    end
  end
  return eff, occ
end

-- A table as Lua source (for obj:queueGameEngineLua). nil values are dropped.
function core.ser(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == 'number' then
    if v ~= v or v == huge or v == -huge then return 'nil' end
    return string.format('%.6g', v)
  elseif t == 'boolean' then return tostring(v)
  elseif t == 'string' then return string.format('%q', v)
  elseif t == 'table' and depth < 6 then
    local parts, n = {}, #v
    for i = 1, n do parts[#parts + 1] = core.ser(v[i], depth + 1) end
    for k, x in pairs(v) do
      if not (type(k) == 'number' and k >= 1 and k <= n and k == floor(k)) and type(x) ~= 'function' then
        parts[#parts + 1] = '[' .. core.ser(k, depth + 1) .. ']=' .. core.ser(x, depth + 1)
      end
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'nil'
end

-- node positions in route coordinates ------------------------------------------------------------------------------------
local function ptXY(p)
  if not p then return nil end
  local x, y = p.x or p[1], p.y or p[2]
  if x and y then return { x, y } end
end

function core.buildRoute(names, pts)
  local r = { names = names, n = #names, pts = {}, cum = { 0 }, len = {} }
  for i = 1, r.n do r.pts[i] = ptXY(pts[i]) or r.pts[i - 1] end
  for i = 1, r.n - 1 do
    local a, b = r.pts[i], r.pts[i + 1]
    local l = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    r.len[i] = l
    r.cum[i + 1] = r.cum[i] + l
  end
  r.total = r.cum[r.n]
  return r
end

local function segProject(ax, ay, bx, by, px, py)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 1e-9 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local ex, ey = px - (ax + t * dx), py - (ay + t * dy)
  local dist = sqrt(ex * ex + ey * ey)
  local cross = dx * (py - ay) - dy * (px - ax)           -- > 0: the point is on the left of the travel direction
  return t * sqrt(l2), dist, (cross > 0 and -dist or dist)  -- offset along the segment, distance, lateral (right positive)
end
core.segProject = segProject

-- project a point onto the route polyline. Returns along, lateral (right +), segment, distance. lo/hi limit the segments.
function core.project(r, x, y, lo, hi)
  lo = max(1, lo or 1)
  hi = min(r.n - 1, hi or (r.n - 1))
  local bestD, bA, bL, bS = huge, 0, 0, lo
  for i = lo, hi do
    local a, b = r.pts[i], r.pts[i + 1]
    local off, d, lat = segProject(a[1], a[2], b[1], b[2], x, y)
    if d < bestD then bestD, bA, bL, bS = d, r.cum[i] + off, lat, i end
  end
  return bA, bL, bS, bestD
end

-- segments reachable from segment `seg` within [-back, +ahead] metres, to keep per-vehicle projections cheap
function core.segWindow(r, seg, F, back, ahead)
  local lo, hi = seg, seg
  while lo > 1 and r.cum[lo] > F - back do lo = lo - 1 end
  while hi < r.n - 1 and r.cum[hi + 1] < F + ahead do hi = hi + 1 end
  return lo, hi
end

-- first available node >= from, then the contiguous run of nodes joined by edges. Returns first,last (or nil).
function core.availablePrefix(names, hasNode, hasEdge, from, maxN)
  local s = from
  while s <= #names and not hasNode(names[s]) do s = s + 1 end
  if s > #names then return nil end
  local e = s
  while e < #names and (e - s + 1) < (maxN or huge) and hasNode(names[e + 1]) and hasEdge(names[e], names[e + 1]) do e = e + 1 end
  return s, e
end

---------------------------------------------------------------------------------------------------------------------------
-- The driver
---------------------------------------------------------------------------------------------------------------------------
local D = {}
D.__index = D

local RUNG_NAME = { 'horn_creep', 'replan', 'nudge', 'reverse', 'skip_or_reroute', 'report', 'cooldown' }

function core.new(env, cfgOver)
  local d = setmetatable({}, D)
  d.env = env
  d.cfg = merge(core.DEFAULTS, cfgOver)
  d.st = 'idle'
  d.acc = 0
  d.counters = { stuck = 0, recovered = 0, reports = 0, reissues = 0, skipped = 0, rungs = { 0, 0, 0, 0, 0, 0, 0 }, flips = 0, doorfaults = 0, starts = 0, byCause = {} }
  d.t = 0
  d.lastEmit = {}
  d.lad = { rung = 0 }
  d.applied = {}
  d.prog = { best = 0, t = 0 }
  return d
end

function D:emit(name, data)
  data = data or {}
  data.t = self.t
  self.env.emit(name, data)
end

-- rate-limited event: at most once per `every` seconds per key
function D:emitLimited(key, every, name, data)
  local last = self.lastEmit[key]
  if last and self.t - last < every then return false end
  self.lastEmit[key] = self.t
  self:emit(name, data)
  return true
end

function D:setState(st)
  self.st = st
  self.stT = self.t
  self.prog.t = self.t
  self.sub = nil
end

---- commands -----------------------------------------------------------------------------------------------------------
function D:command(c)
  if type(c) ~= 'table' then return end
  local k = c.c
  self.t = self.env.time()
  if k == 'start' then self:start(c)
  elseif k == 'abort' then self:abort()
  elseif k == 'setLate' then self.lateBase = tonumber(c.sec) or 0
  elseif k == 'sync' then
    if c.clock then self.clockOff = c.clock - self.t end
  elseif k == 'hold' then
    if self.st == 'dwell' and self.openT then
      local until_ = min(self.t + min(tonumber(c.sec) or 0, L.HOLD_MAX_S), self.openT + L.EARLY_WAIT_MAX_S + L.DWELL_MAX_S + L.HOLD_MAX_S)
      self.holdUntil = max(self.holdUntil or 0, until_)
      self.depAt = max(self.depAt, self.holdUntil)
    end
  elseif k == 'skipStop' then self:skipStopById(c.id, 'command')
  elseif k == 'setPath' then self:setPath(c)
  elseif k == 'relocate' then self:relocate()
  elseif k == 'lights' then self.lights = c.on and true or false; self.env.lights(self.lights)
  elseif k == 'status' then self:emit('status', self:status())
  end
end

function D:status()
  return { state = self.st, along = self.F, v = self.v, nextStop = self.nextIdx, late = self:late(), rung = self.lad.rung,
    counters = self.counters, issued = self.issued and { self.issued.from, self.issued.to } or nil }
end

function D:prepareRoute(c)
  local env = self.env
  local names, pts = {}, {}
  for i, n in ipairs(c.path) do
    names[i] = n
    local p = c.pts and ptXY(c.pts[i])
    if not p then
      local x, y = env.node(n)
      if x then p = { x, y } end
    end
    pts[i] = p
  end
  -- unknown points: guess 25 m further along the last known direction
  for i = 1, #names do
    if not pts[i] then
      local a, b = pts[i - 1], pts[i - 2]
      if a then
        local dx, dy = 25, 0
        if b then
          local l = sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
          if l > 0.1 then dx, dy = (a[1] - b[1]) / l * 25, (a[2] - b[2]) / l * 25 end
        end
        pts[i] = { a[1] + dx, a[2] + dy }
      end
    end
  end
  for i = #names, 1, -1 do if not pts[i] and pts[i + 1] then pts[i] = pts[i + 1] end end
  if not pts[1] then return nil end
  return core.buildRoute(names, pts)
end

function D:prepareStops(list, route, old)
  local stops = {}
  for i, s in ipairs(list or {}) do
    if type(s.along) == 'number' then
      local st = { id = s.id or i, along = s.along, side = (s.side == 'l') and 'l' or 'r', sched = s.sched, kneel = s.kneel,
        terminus = s.terminus, state = 'pending' }
      st.dwell = core.dwellSeconds(s, self.cfg)
      stops[#stops + 1] = st
    end
  end
  table.sort(stops, function(a, b) return a.along < b.along end)
  local last = stops[#stops]
  if last and last.terminus == nil and route.total - last.along <= 30 then last.terminus = true end
  if old then
    for _, s in ipairs(stops) do
      for _, o in ipairs(old) do if o.id == s.id and o.state ~= 'pending' then s.state = o.state end end
    end
  end
  return stops
end

function D:start(c)
  local env = self.env
  if type(c.path) ~= 'table' or #c.path < 2 then self:emit('rejected', { reason = 'path' }); return end
  self.cfg = merge(core.DEFAULTS, c.cfg)
  self.counters.starts = self.counters.starts + 1
  local route = self:prepareRoute(c)
  if not route then self:emit('rejected', { reason = 'points' }); return end
  self.route = route
  self.stops = self:prepareStops(c.stops, route)
  self.t0 = self.t
  self.clockOff = (c.clock or 0) - self.t
  self.lateBase = tonumber(c.delaySec) or 0
  self.committed, self.signs, self.redWait, self.redOver, self.yieldWait, self.yieldOver, self.junc = {}, {}, {}, {}, {}, {}, {}
  self.lad = { rung = 0, nudges = 0, cycle = 0 }
  self.applied = { stop = false, cap = false, aggr = false, ind = false }
  self.shift, self.shiftSent = 0, 0
  self.seg, self.F, self.v, self.hintLat = 1, 0, 0, 0
  self.flipT, self.groundT, self.offT, self.edgeSent, self.noRoute = nil, nil, nil, false, false
  self.reports, self.issued, self.reload, self.creep = 0, nil, nil, nil
  self.bayWait, self.bayStallT, self.holdUntil = 0, nil, nil
  self.cur, self.doorFault, self.rev, self.indOffAt, self.lastLate, self.pendingReturn, self.availEnd, self.availT = nil, false, nil, nil, nil, nil, nil, nil
  self.graphId = env.graphId()
  self.id = env.id and env.id() or 0
  if c.night ~= nil then self.lights = c.night and true or false; env.lights(self.lights) end
  self:sense(true)
  for _, st in ipairs(self.stops) do
    if st.along + self.cfg.doorOffset - self.F < -20 then st.state = 'passed' end   -- the bus joins the route after it
  end
  self.prog = { best = self.F, t = self.t }
  self:setState('drive')
  self:issue('start')
  self:emit('ready', { n = route.n, stops = #self.stops })
end

function D:abort()
  local env = self.env
  if self.st ~= 'idle' then
    pcall(env.setDoors, false)
    pcall(env.indicator, nil)
    pcall(env.ai.setStopPoint, 0)
    if self.rev then pcall(env.reverseStop); self.rev = nil end
  end
  self.st = 'idle'
  self.route, self.stops = nil, nil
  self.lad = { rung = 0 }
end

function D:setPath(c)
  if not self.route or type(c.path) ~= 'table' or #c.path < 2 then self:emit('rejected', { reason = 'setPath' }); return end
  local route = self:prepareRoute(c)
  if not route then self:emit('rejected', { reason = 'points' }); return end
  local oldStops = self.stops
  self.route = route
  self.stops = self:prepareStops(c.stops or {}, route, oldStops)
  if not c.stops then self.stops = oldStops end
  self.junc, self.issued = {}, nil
  self.seg = 1
  self:sense(true)
  self.lad = { rung = 0, nudges = 0, cycle = 0 }
  self.creep = nil
  self.prog = { best = self.F, t = self.t }
  self:issue('setPath')
end

function D:relocate()
  if not self.route then return end
  self.seg = 1
  self:sense(true)
  self.lad = { rung = 0, nudges = 0, cycle = 0 }
  self.creep = nil
  self.prog = { best = self.F, t = self.t }
  self.shift, self.shiftSent = 0, 0
  self.reports = 0
  if self.st == 'failed' or self.st == 'drive' or self.st == 'approach' then self:setState('drive') end
  self:issue('relocate')
end

---- sensing ------------------------------------------------------------------------------------------------------------
function D:sense(first)
  local env, r = self.env, self.route
  self.t = env.time()
  local x, y, z = env.pos()
  self.x, self.y, self.z = x, y, z
  self.v = env.speed()
  self.dx, self.dy = env.dir()
  if r and x then
    local lo, hi = 1, r.n - 1
    if not first and self.seg then lo, hi = max(1, self.seg - 2), min(r.n - 1, self.seg + 10) end
    local a, lat, s, dist = core.project(r, x, y, lo, hi)
    if not first and dist > 30 then a, lat, s, dist = core.project(r, x, y) end
    self.F, self.hintLat, self.seg, self.routeDist = a, lat, s, dist
  end
  self.vehicles = env.vehicles() or {}
end

---- the AI: issuing a path ---------------------------------------------------------------------------------------------
function D:junctionAt(k)
  local jc = self.junc[k]
  if jc ~= nil then return jc or nil end
  local r, env = self.route, self.env
  if k <= 1 or k >= r.n then self.junc[k] = false; return nil end
  local deg, drivIn, drivMax = env.junction(r.names[k], r.names[k - 1])
  if not deg then return nil end            -- graph does not know the node yet: try again later
  if deg <= 2 then self.junc[k] = false; return nil end
  local a, b, c = r.pts[k - 1], r.pts[k], r.pts[k + 1]
  local l1 = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2) + 1e-9
  local l2 = sqrt((c[1] - b[1]) ^ 2 + (c[2] - b[2]) ^ 2) + 1e-9
  local give = core.isGiveWay((b[1] - a[1]) / l1, (b[2] - a[2]) / l1, (c[1] - b[1]) / l2, (c[2] - b[2]) / l2, drivIn, drivMax)
  local jc2 = { giveWay = give, x = b[1], y = b[2], k = k }
  self.junc[k] = jc2
  return jc2
end

function D:wpSpeeds(s, e)
  local ws, v = {}, self.cfg.junctionKmh / 3.6
  for k = s + 1, e - 1 do
    local jc = self:junctionAt(k)
    if jc and jc.giveWay and not self:hasSignalOnEdge(k - 1) then ws[self.route.names[k]] = v end
  end
  return ws
end

function D:hasSignalOnEdge(i)
  local r = self.route
  local l = r.names[i + 1] and self.env.signal(r.names[i], r.names[i + 1])
  return l ~= nil and #l > 0
end

function D:available(from)
  local env, r = self.env, self.route
  return core.availablePrefix(r.names, function(n) return env.node(n) ~= nil end,
    function(a, b) return env.edge(a, b) end, from, self.cfg.maxIssueNodes)
end

-- (re)issue ai.driveUsingPath from the node behind the bus over the part of the path the graph knows
function D:issue(reason)
  local env, r = self.env, self.route
  if not r then return false end
  local s, e = self:available(max(1, self.seg or 1))
  if not s or e - s < 1 then
    self.noRoute = true
    self.issued = { from = 1, to = 0, t = self.t, graph = self.graphId, reason = reason, none = true }
    return false
  end
  self.noRoute = false
  local slice = {}
  for i = s, e do slice[#slice + 1] = r.names[i] end
  local late = self:late()
  self.aggr = core.aggressionFor(late, self.cfg)
  env.ai.driveUsingPath({ path = slice, wpSpeeds = self:wpSpeeds(s, e), driveInLane = 'on', avoidCars = 'on',
    routeSpeedMode = 'legal', aggression = self.aggr })
  self.issued = { from = s, to = e, t = self.t, graph = self.graphId, reason = reason }
  self.counters.reissues = self.counters.reissues + 1
  -- the plan is rebuilt: everything we told the AI is gone
  self.applied = { stop = false, cap = false, aggr = self.aggr, ind = self.applied.ind }
  self.shiftSent = 0
  self.pendingReturn = nil
  self.lad.nudgeTotal = 0
  self.planReadyT = self.t + 0.4
  return true
end

function D:graphMaintenance()
  local env, r, t = self.env, self.route, self.t
  local gid = env.graphId()
  if gid ~= self.graphId then
    self.graphId = gid
    self.reload = { t = t }
    self.junc = {}
  end
  local iss = self.issued
  local mode = env.ai.mode and env.ai.mode()
  local needs, why = false, nil
  if (self.reload and t - self.reload.t >= 0.4) or t - (self.availT or -9) >= 2 then
    self.reload, self.availT = nil, t
    local hasNode = function(n) return env.node(n) ~= nil end
    local s, e = core.availablePrefix(r.names, hasNode, function(a, b) return env.edge(a, b) end, max(1, self.seg or 1))
    self.availEnd = e
    if not s or e - s < 1 then
      if not iss or not iss.none then needs, why = true, 'graph' end
    elseif not iss or iss.none then
      needs, why = true, 'graph'
    elseif e < iss.to then
      needs, why = true, 'graph'            -- nodes of the issued run vanished
    elseif e > iss.to and (e >= iss.to + self.cfg.extendNodes or r.cum[iss.to] - self.F < 120) and r.cum[iss.to] - self.F < 300 then
      needs, why = true, 'extend'
    else
      for i = max(iss.from, self.seg or 1), iss.to do
        if not env.node(r.names[i]) then needs, why = true, 'graph'; break end
      end
    end
  elseif iss and mode and mode ~= 'manual' then
    needs, why = true, 'mode'
  elseif iss and iss.none and t - iss.t > 1.5 then
    needs, why = true, 'retry'
  end
  if needs and (not iss or t - iss.t >= L.REISSUE_MIN_S) then self:issue(why) end
  -- the route continues beyond what the graph knows: tell the GE when we get near the end of it
  local e = self.availEnd
  if e and e < r.n then
    local rest = r.cum[e] - self.F
    self.edgeRest = rest
    if rest < 120 and not self.edgeSent then
      self.edgeSent = true
      self:emit('edge', { remaining = rest })
    elseif rest > 200 then self.edgeSent = false end
  else
    self.edgeRest = nil
  end
end

---- holds: signals, STOP signs, give-way ------------------------------------------------------------------------------------
function D:late()
  local over = 0
  if self.clockOff and self.stops then
    for _, s in ipairs(self.stops) do
      if s.state == 'pending' and s.sched then
        local arrive = (s.sched - self.clockOff) - s.dwell
        over = max(0, self.t - arrive)
        break
      end
    end
  end
  return max(over, self.lateBase or 0)
end

function D:schedLocal(stop)
  if stop.sched and self.clockOff then return stop.sched - self.clockOff end
end

function D:scanSignals()
  local r, env, cfg = self.route, self.env, self.cfg
  local out = {}
  for i = max(1, self.seg or 1), r.n - 1 do
    if r.cum[i] - self.F > cfg.signalHorizon then break end
    local list = env.signal(r.names[i], r.names[i + 1])
    if list and #list > 0 then
      local best, bl = nil, huge
      for _, s in ipairs(list) do
        local px, py = s.x or (s.pos and (s.pos.x or s.pos[1])), s.y or (s.pos and (s.pos.y or s.pos[2]))
        if px then
          local a, b = r.pts[i], r.pts[i + 1]
          local off, d = segProject(a[1], a[2], b[1], b[2], px, py)
          if d < bl then best, bl = { off = off, action = s.action or 0, x = px, y = py }, d end
        end
      end
      if best then out[#out + 1] = { key = r.names[i] .. '>' .. r.names[i + 1], along = r.cum[i] + best.off, action = best.action,
        x = best.x, y = best.y, i = i } end
    end
  end
  return out
end

function D:findAhead()
  local r, cfg = self.route, self.cfg
  local lo, hi = core.segWindow(r, self.seg, self.F, 15, cfg.aheadRange + 20)
  local best
  for _, u in ipairs(self.vehicles) do
    if u.id ~= self.id then
      local a, lat = core.project(r, u.x, u.y, lo, hi)
      local gap = a - (u.len or 4) * 0.5 - self.F
      if gap > -2 and gap < cfg.aheadRange and abs(lat) < cfg.laneHalf and (not best or gap < best.gap) then
        local speed = sqrt((u.vx or 0) ^ 2 + (u.vy or 0) ^ 2)
        local oncoming = u.dx and (u.dx * self.dx + u.dy * self.dy) < -0.5 or false
        best = { id = u.id, gap = gap, speed = speed, oncoming = oncoming, along = a, lat = lat, len = u.len or 4 }
      end
    end
  end
  return best
end

function D:holds()
  local cfg, r, F, v, t = self.cfg, self.route, self.F, self.v, self.t
  self.cands = {}
  self.cap = nil
  self.ahead = self:findAhead()
  local seen, sigEdge = {}, {}
  local dt = self.tickDt or cfg.tickS
  for _, s in ipairs(self:scanSignals()) do
    local dist = s.along - F
    seen[s.key] = true
    sigEdge[s.i] = true
    if s.action == 3 then
      local sg = self.signs[s.key]
      if not sg then sg = { ph = 'approach' }; self.signs[s.key] = sg end
      if sg.ph ~= 'served' then
        if dist < -cfg.passedM then sg.ph = 'served'
        elseif sg.ph == 'approach' then
          if v < 0.3 and dist < 10.0 and dist > -cfg.passedM then sg.ph = 'stopped'; sg.t0 = t end
          self.cands[#self.cands + 1] = { along = s.along - 0.3, kind = 'sign', key = s.key, stopAdd = self:stopAddFor(s.along - 0.3) }
        end
        if sg.ph == 'stopped' then
          local waited = t - sg.t0
          local blocked = core.crossTrafficBlocked(s.x, s.y, self.vehicles, self.dx, self.dy, self.id, cfg)
          if waited >= L.STOPSIGN_CLEAR_MAX_S then
            sg.ph = 'served'
            self:emit('signal_timeout', { what = 'stopsign', key = s.key })
            self.prog.t = t
          elseif waited >= L.STOPSIGN_HOLD_S and not blocked then sg.ph = 'served'
          else self.cands[#self.cands + 1] = { along = s.along - 0.3, kind = 'sign', key = s.key, stopAdd = self:stopAddFor(s.along - 0.3) } end
        end
      end
    else
      local dec = core.signalDecision(s.action, dist, v, cfg, self.committed[s.key])
      if s.action == 1 and dec == 'go' then self.committed[s.key] = true end
      if dec == 'stop' and not self.redOver[s.key] then
        if v < 0.3 and dist < 15 then
          self.redWait[s.key] = (self.redWait[s.key] or 0) + dt
          if self.redWait[s.key] > L.RED_WAIT_MAX_S then
            self.redOver[s.key] = true
            self:emit('signal_timeout', { what = 'red', key = s.key })
            self.prog.t = t
          end
        end
        if not self.redOver[s.key] then
          self.cands[#self.cands + 1] = { along = s.along - 0.3, kind = 'red', key = s.key, hard = true, stopAdd = self:stopAddFor(s.along - 0.3) }
        end
      elseif dec == 'go' and not self.redOver[s.key] then self.redWait[s.key] = nil end
      if self.redOver[s.key] and dist > -cfg.passedM then self.cap = min(self.cap or huge, cfg.creepMs) end
    end
  end
  for k in pairs(self.signs) do if not seen[k] then self.signs[k] = nil end end
  for k in pairs(self.redWait) do if not seen[k] then self.redWait[k] = nil end end
  for k in pairs(self.redOver) do if not seen[k] then self.redOver[k] = nil end end
  for k in pairs(self.committed) do if not seen[k] then self.committed[k] = nil end end
  -- give-way junctions without a signal
  for k = max(2, (self.seg or 1) + 1), r.n - 1 do
    local dist = r.cum[k] - F
    if dist > cfg.junctionHorizon then break end
    if not sigEdge[k - 1] then
      local jc = self:junctionAt(k)
      if jc and jc.giveWay and dist > -2 then
        if dist < cfg.yieldZone then self.cap = min(self.cap or huge, cfg.junctionKmh / 3.6) end
        if cfg.yieldFallback and not self.yieldOver[k] then
          local line = r.cum[k] - cfg.junctionBackoff
          local blocked = core.crossTrafficBlocked(jc.x, jc.y, self.vehicles, self.dx, self.dy, self.id, cfg)
          if blocked and line - F > -1 then
            if v < 0.5 and line - F < 12 then
              self.yieldWait[k] = (self.yieldWait[k] or 0) + dt
              if self.yieldWait[k] > L.GIVEWAY_MAX_S then
                self.yieldOver[k] = true
                self:emit('signal_timeout', { what = 'giveway', key = k })
                self.prog.t = t
              end
            end
            if not self.yieldOver[k] then self.cands[#self.cands + 1] = { along = line, kind = 'junction', key = k, stopAdd = self:stopAddFor(line) } end
          elseif not blocked then self.yieldWait[k] = nil end
        elseif self.yieldOver[k] and dist > -2 then self.cap = min(self.cap or huge, cfg.creepMs) end
      end
    end
  end
  for k in pairs(self.yieldWait) do if k <= (self.seg or 1) then self.yieldWait[k] = nil end end
  -- a red/yellow/stop ahead explains a queue of standing cars
  self.signalAhead = #self.cands > 0
end

---- bays ---------------------------------------------------------------------------------------------------------------
function D:nextStop()
  for i, s in ipairs(self.stops or {}) do
    if s.state == 'pending' then return s, i end
  end
end

function D:skipStop(s, i, cause)
  s.state = 'skipped'
  self.counters.skipped = self.counters.skipped + 1
  self:emit('skipped', { i = i, id = s.id, cause = cause })
  if self.st == 'approach' then self:endApproach() end
end

function D:skipStopById(id, cause)
  for i, s in ipairs(self.stops or {}) do
    if (s.id == id or i == id) and s.state == 'pending' then self:skipStop(s, i, cause); return true end
  end
end

function D:kerbSign(stop) return ((stop.side == 'l') and -1 or 1) * self.cfg.laneSign end

function D:endApproach()
  if self.shiftSent ~= 0 then self.env.ai.laneChange(40, -self.shiftSent) end
  self.shift, self.shiftSent = 0, 0
  self.env.indicator(nil)
  self.bayWait, self.bayStallT = 0, nil
  if self.st == 'approach' then self:setState('drive') end
end

function D:stRoute()
  local cfg, F, v, t, env = self.cfg, self.F, self.v, self.t, self.env
  local ns, ni = self:nextStop()
  self.nextIdx = ni
  if self.pendingReturn and F >= self.pendingReturn.at and (not self.planReadyT or t >= self.planReadyT) then
    env.ai.laneChange(40, self.pendingReturn.disp)
    self.pendingReturn = nil
  end
  if not ns then
    if self.st == 'approach' then self:endApproach() end
    if F >= self.route.total - 6 and v < 0.5 then self:finish() end
    return
  end
  local tgt = ns.along + cfg.doorOffset
  local dist = tgt - F
  if dist < -20 then self:skipStop(ns, ni, 'missed'); return end
  if dist <= cfg.indicatorDist and self.st ~= 'approach' then
    self:setState('approach')
    env.indicator(ns.side == 'l' and 'left' or 'right')
    self.approachT = t
  end
  if self.st ~= 'approach' then return end
  -- one lateral shift to the kerb, after the plan exists
  if self.shift == 0 and dist <= cfg.shiftDist and (not self.planReadyT or t >= self.planReadyT) then
    self.shift = self:kerbSign(ns) * cfg.kerbShift
  end
  if self.shift ~= 0 and self.shiftSent ~= self.shift and (not self.planReadyT or t >= self.planReadyT) then
    env.ai.laneChange(cfg.shiftRamp, self.shift - self.shiftSent)
    self.shiftSent = self.shift
  end
  -- the target, moved behind a vehicle standing in the bay
  local pv = {}
  local lo, hi = core.segWindow(self.route, self.seg, F, 10, dist + 40)
  for _, u in ipairs(self.vehicles) do
    if u.id ~= self.id then
      local a, lat = core.project(self.route, u.x, u.y, lo, hi)
      pv[#pv + 1] = { id = u.id, along = a, lat = lat, len = u.len or 4, speed = sqrt((u.vx or 0) ^ 2 + (u.vy or 0) ^ 2) }
    end
  end
  local eff, occ = core.bayTarget(pv, tgt, F, cfg)
  local displaced = occ ~= nil and eff < tgt - cfg.stopTol
  local d2 = eff - F
  self.bayEff, self.bayDisplaced = eff, displaced
  if displaced and v < 0.5 and d2 < 25 then self.bayWait = self.bayWait + (self.tickDt or cfg.tickS)
  elseif not displaced then self.bayWait = 0 end
  local short = displaced and self.bayWait >= L.BAY_QUEUE_MAX_S and (tgt - F) < cfg.shortMaxM
  -- creeping on when the AI stalled short of the target without a reason
  if v < 0.15 and d2 > cfg.stopTol and not displaced and #self.cands == 0 then
    self.bayStallT = self.bayStallT or t
  else
    self.bayStallT = nil
  end
  local stalled = self.bayStallT and (t - self.bayStallT) > 5
  local cand = { along = eff, kind = displaced and 'bayqueue' or 'bay', creep = stalled, stopAdd = stalled and false or self:maxGap() }
  self.cands[#self.cands + 1] = cand
  -- arrival
  local nearest = true
  for _, c in ipairs(self.cands) do if c.along < eff - 0.01 then nearest = false end end
  if v < 0.25 and nearest then
    local ok
    if not displaced then ok = F >= tgt - cfg.stopTol else ok = short and F >= eff - cfg.stopTol end
    if ok then self:enterOpening(ns, ni, displaced or abs(F - tgt) > cfg.stopTol) end
  end
end

function D:enterOpening(ns, ni, short)
  self.cur, self.curIdx, self.curShort = ns, ni, short
  self:setState('opening')
  self.doorTries = 0
  self.sub = 'kneel'
  self.subT = self.t
  if self.cfg.kneel and ns.kneel ~= false then self.env.setKneel(true) else self:openDoors() end
end

function D:openDoors()
  self.env.setDoors(true)
  self.sub, self.subT = 'doors', self.t
end

function D:stOpening()
  local env, t = self.env, self.t
  self.cands = { { along = self.F, kind = 'hold' } }
  if self.sub == 'kneel' then
    if t - self.subT >= self.cfg.kneelS then self:openDoors() end
  elseif self.sub == 'doors' then
    if env.doorsOpen() then self:enterDwell(false)
    elseif t - self.subT > L.DOOR_TIMEOUT_S then
      self.doorTries = self.doorTries + 1
      if self.doorTries > L.DOOR_RETRIES then
        self.counters.doorfaults = self.counters.doorfaults + 1
        self:emit('doorfault', { what = 'open' })
        self:enterDwell(true)
      else
        env.setDoors(false)
        self.sub, self.subT = 'doorsRetry', t
      end
    end
  elseif self.sub == 'doorsRetry' then
    if t - self.subT >= 1.0 then self:openDoors() end
  else
    self:openDoors()
  end
end

function D:enterDwell(fault)
  local s = self.cur
  self:setState('dwell')
  self.openT = self.t
  self.doorFault = fault
  self.holdUntil = nil
  local sl = self:schedLocal(s)
  self.depAt = core.departAt(self.t, s.dwell, sl and sl - self.cfg.closeLeadS, s.terminus)
  s.state = 'served'
  local late = max(0, self.t - ((self:schedLocal(s) or self.t) - s.dwell))
  self:emit('atStop', { i = self.curIdx, id = s.id, late = late, short = self.curShort, dist = self.F - (s.along + self.cfg.doorOffset),
    fault = fault, early = self:schedLocal(s) and max(0, self:schedLocal(s) - self.t - s.dwell) or 0 })
  if self.lastLate == nil or abs(late - self.lastLate) >= 15 then self.lastLate = late; self:emit('delay', { late = late }) end
end

function D:stDwell()
  self.cands = { { along = self.F, kind = 'hold' } }
  if self.t >= self.depAt then
    self:setState('closing')
    self.sub, self.subT, self.doorTries = 'close', self.t, 0
    self.env.setDoors(false)
  end
end

function D:stClosing()
  local env, t = self.env, self.t
  self.cands = { { along = self.F, kind = 'hold' } }
  if self.sub == 'close' then
    if not env.doorsOpen() then
      self.sub, self.subT = 'unkneel', t
      env.setKneel(false)
    elseif t - self.subT > L.DOOR_TIMEOUT_S then
      self.doorTries = self.doorTries + 1
      if self.doorTries > L.DOOR_RETRIES then
        self.counters.doorfaults = self.counters.doorfaults + 1
        self:emit('doorfault', { what = 'close' })
        self.sub, self.subT = 'unkneel', t
        env.setKneel(false)
      else
        env.setDoors(true)               -- toggle back and forth: the adapter re-sends the request
        self.sub, self.subT = 'closeRetry', t
      end
    end
  elseif self.sub == 'closeRetry' then
    if t - self.subT >= 1.0 then env.setDoors(false); self.sub, self.subT = 'close', t end
  elseif self.sub == 'unkneel' then
    if not env.kneeling() or t - self.subT > L.KNEEL_TIMEOUT_S then
      if self.cur.terminus then self:finish() else self:enterDepart() end
    end
  end
end

function D:enterDepart()
  local s = self.cur
  self:setState('depart')
  self.depStart = self.t
  self.env.indicator(s.side == 'l' and 'right' or 'left')
end

function D:pulloutClear()
  local gapN = 25
  for _, u in ipairs(self.vehicles) do
    if u.id ~= self.id then
      local rx, ry = u.x - self.x, u.y - self.y
      local behind = rx * self.dx + ry * self.dy
      local side = abs(rx * self.dy - ry * self.dx)
      local spd = sqrt((u.vx or 0) ^ 2 + (u.vy or 0) ^ 2)
      if behind < 0 and behind > -gapN and side < 3.5 and spd > 3 then return false end
    end
  end
  return true
end

function D:stDepart()
  local env, t, s = self.env, self.t, self.cur
  self.cands = { { along = self.F, kind = 'hold' } }
  local e = t - self.depStart
  if e >= self.cfg.departIndicateS and (self:pulloutClear() or e >= self.cfg.departIndicateS + L.PULLOUT_WAIT_S) then
    if self.shiftSent ~= 0 then env.ai.laneChange(40, -self.shiftSent) end
    self.shift, self.shiftSent = 0, 0
    self.cands = {}
    self.lastDeparted = { i = self.curIdx, F = self.F }
    self.indOffAt = t + 4
    local depLate = self:schedLocal(s) and max(0, t - self:schedLocal(s)) or 0
    self.lateBase = depLate
    self:emit('departed', { i = self.curIdx, id = s.id, late = depLate })
    self.bayWait, self.bayStallT = 0, nil
    self:setState('drive')
  end
end

function D:finish()
  self:setState('done')
  self.env.setDoors(false)
  self.env.indicator(nil)
  self:emit('done', { late = self:late(), counters = self.counters })
end

---- the watchdog and the ladder of recoveries ----------------------------------------------------------------------------------
-- facing against the direction of the route (spawned or thrown round)?
function D:wrongWay()
  local r = self.route
  local i = min(max(1, self.seg or 1), r.n - 1)
  local a, b = r.pts[i], r.pts[i + 1]
  local l = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
  if l < 0.5 then return false end
  return ((b[1] - a[1]) * self.dx + (b[2] - a[2]) * self.dy) / l < -0.5
end

function D:cause()
  local a = self.ahead
  if self.noRoute or (self.edgeRest and self.edgeRest < 25) then return 'path_end' end
  if a and a.oncoming and a.speed < 0.5 and a.gap < 20 then return 'deadlock' end
  if self:wrongWay() then return 'wrong_way' end
  local k = self.holdKind
  if k == 'red' then return 'signal' elseif k == 'sign' then return 'stopsign' elseif k == 'junction' then return 'giveway'
  elseif k == 'bayqueue' then return 'bay' end
  if self.doorFault and self.env.doorsOpen() then return 'door' end
  if a and a.speed < 0.5 then return 'obstacle' end
  if (self.env.throttle() or 0) > 0.5 and self.v < 0.2 then return 'no_response' end
  return 'blocked'
end

function D:allowance()
  local s = self.st
  if s == 'opening' or s == 'dwell' or s == 'closing' or s == 'depart' then return L.INTERNAL_MAX_S end
  local a = self.ahead
  if self.noRoute or (self.edgeRest and self.edgeRest < 25 and self.v < 0.5) then return L.EDGE_STALL_S end
  if a and a.oncoming and a.speed < 0.5 and a.gap < 20 then return L.DEADLOCK_WAIT_S end
  local k = self.holdKind
  if k == 'red' then return L.RED_WAIT_MAX_S + 15 end
  if k == 'sign' then return L.STOPSIGN_CLEAR_MAX_S + 15 end
  if k == 'junction' then return L.GIVEWAY_MAX_S + 15 end
  if k == 'bayqueue' then return L.BAY_QUEUE_MAX_S + 15 end
  if a and a.speed < 0.5 then
    if self.signalAhead then return L.RED_WAIT_MAX_S + 15 end
    return L.QUEUE_MAX_S
  end
  return L.MAX_STUCK_S
end

function D:watchdog()
  local t, F, lad, p = self.t, self.F, self.lad, self.prog
  if F > p.best + L.PROG_M then p.best = F; p.t = t end
  if lad.rung > 0 then
    if F > lad.F0 + L.RECOVER_M and self.v > 0.5 and not (lad.cause == 'wrong_way' and self:wrongWay()) then self:recovered(); return end
    if self.st ~= 'drive' and self.st ~= 'approach' then self:recovered(); return end
    self:runLadder()
    return
  end
  -- off the route for good
  if self.routeDist and self.routeDist > L.OFFROUTE_M then
    self.offT = self.offT or t
    if t - self.offT > L.OFFROUTE_S and self.st ~= 'done' then
      self:startLadder('off_route', 2)
      return
    end
  else
    self.offT = nil
  end
  if t - p.t > self:allowance() then
    if self.st == 'drive' or self.st == 'approach' then
      self:startLadder(self:cause())
    else
      self:forceDepart()
    end
  end
end

-- the door/dwell states have their own timers; if one ever overstays, push the bus on
function D:forceDepart()
  self:emit('escalate', { rung = 0, name = 'force_depart', cause = 'internal_timeout', state = self.st })
  self.env.setDoors(false)
  self.env.setKneel(false)
  self.shift, self.shiftSent = 0, 0
  self.env.indicator(nil)
  if self.cur then self.cur.state = 'served' end
  self:setState('drive')
end

function D:startLadder(cause, rung)
  local lad = self.lad
  self.counters.stuck = self.counters.stuck + 1
  self.counters.byCause[cause] = (self.counters.byCause[cause] or 0) + 1
  lad.cause, lad.F0, lad.t0, lad.cycle = cause, self.F, self.t, lad.cycle or 0
  local first = rung or 1
  if cause == 'deadlock' then
    -- two vehicles facing each other: both pull over to their own kerb at once (a nudge to the right each)
    first = 3
  elseif cause == 'path_end' then first = 6
  elseif cause == 'wrong_way' then first = 2 end
  self:enterRung(first)
end

function D:recovered()
  local lad = self.lad
  self.counters.recovered = self.counters.recovered + 1
  self:emit('recovered', { rung = lad.rung, cause = lad.cause, stalled = self.t - (lad.t0 or self.t) })
  if self.rev then self.env.reverseStop(); self.rev = nil; self:issue('afterReverse') end
  if (lad.nudgeTotal or 0) ~= 0 then self.pendingReturn = { at = self.F + 30, disp = -lad.nudgeTotal } end
  self.lad = { rung = 0, nudges = lad.nudges or 0, cycle = 0, nudgeTotal = 0 }
  self.creep = nil
  self.prog = { best = max(self.prog.best, self.F), t = self.t }
end

function D:enterRung(r)
  local env, lad = self.env, self.lad
  lad.rung, lad.rungT = r, self.t
  self.counters.rungs[r] = self.counters.rungs[r] + 1
  if r <= 5 then self:emitLimited('esc' .. r, 1.0, 'escalate', { rung = r, name = RUNG_NAME[r], cause = lad.cause, count = self.counters.stuck }) end
  if r == 1 then
    env.horn(0.5)
    lad.hornAgain = self.t + 3
    if env.doorsOpen() then env.setDoors(false) end
    self.creep = self.cfg.creepMs
  elseif r == 2 then
    self:issue('ladder')
    self.creep = self.cfg.creepMs
  elseif r == 3 then
    lad.nudges = (lad.nudges or 0) + 1
    local kerb = self.cur and self:kerbSign(self.cur) or self.cfg.laneSign
    local dir
    if lad.cause == 'deadlock' then dir = kerb else dir = (lad.nudges % 2 == 1) and -kerb or kerb end
    env.ai.laneChange(25, dir * self.cfg.nudgeM)
    lad.nudgeTotal = (lad.nudgeTotal or 0) + dir * self.cfg.nudgeM
    env.horn(0.3)
    self.creep = 3.0
  elseif r == 4 then
    local behindClear = true
    for _, u in ipairs(self.vehicles) do
      if u.id ~= self.id then
        local rx, ry = u.x - self.x, u.y - self.y
        local behind = rx * self.dx + ry * self.dy
        if behind < 0 and behind > -10 and abs(rx * self.dy - ry * self.dx) < 3 then behindClear = false end
      end
    end
    if self.cfg.allowReverse and env.reverseStart and behindClear and self.v < 1 and lad.cause ~= 'wrong_way' then
      self.rev = true
      lad.revF = self.F
      env.reverseStart()
    else
      self:enterRung(5)
    end
  elseif r == 5 then
    if self.rev then env.reverseStop(); self.rev = nil; self:issue('afterReverse') end
    local ns, ni = self:nextStop()
    local near = ns and (ns.along + self.cfg.doorOffset - self.F) < 80 and (ns.along + self.cfg.doorOffset - self.F) > -5
    if (lad.cause == 'bay' or near) and ns then
      self:skipStop(ns, ni, lad.cause)
      self.creep = 3.0
    else
      local r_ = self.route
      local seg = min(self.seg, r_.n - 1)
      self:emit('reroute', { cause = lad.cause, from = r_.names[seg], blocked = { r_.names[seg], r_.names[seg + 1] }, along = self.F })
      lad.rerouteAsked = true
    end
  elseif r == 6 then
    self.reports = self.reports + 1
    self.counters.reports = self.reports
    local r_ = self.route
    self:emitLimited('stuck', 5, 'stuck', { cause = lad.cause, x = self.x, y = self.y, z = self.z, along = self.F, node = r_.names[min(self.seg, r_.n)],
      rung = 6, count = self.reports, stalled = self.t - (lad.t0 or self.t) })
    self.creep = nil
    lad.rung = 7
    lad.rungT = self.t
    self.counters.rungs[7] = self.counters.rungs[7] + 1
  end
end

function D:runLadder()
  local lad, t, env = self.lad, self.t, self.env
  local r = lad.rung
  if r == 1 and lad.hornAgain and t >= lad.hornAgain then env.horn(0.5); lad.hornAgain = nil end
  if r == 4 and self.rev then
    if self.F <= (lad.revF or self.F) - self.cfg.reverseM then
      env.reverseStop(); self.rev = nil
      self:issue('afterReverse')
      lad.rungT = t - L.RUNG_S[4]
    end
  end
  if r <= 5 then
    if t - lad.rungT >= L.RUNG_S[r] then
      if r == 4 and self.rev then env.reverseStop(); self.rev = nil; self:issue('afterReverse') end
      self:enterRung(r + 1)
    end
  elseif r == 7 then
    if t - lad.rungT >= L.REPORT_COOLDOWN_S then
      if self.reports >= L.MAX_REPORTS then
        self:setState('failed')
        self.creep = nil
        self:emit('failed', { cause = lad.cause })
      else
        lad.cycle = (lad.cycle or 0) + 1
        lad.t0, lad.F0 = t, self.F
        self:enterRung(1)
      end
    end
  end
end

---- safety checks ------------------------------------------------------------------------------------------------------
function D:safety()
  local env, t = self.env, self.t
  local up = env.upZ()
  if up and up < 0.35 then
    self.flipT = self.flipT or t
    if t - self.flipT >= L.FLIP_S then
      self.counters.flips = self.counters.flips + 1
      self:emit('flipped', { x = self.x, y = self.y, z = self.z })
      self:setState('failed')
      return true
    end
  else self.flipT = nil end
  if self.cfg.groundCheck and env.ground() == false then
    self.groundT = self.groundT or t
    if t - self.groundT >= L.NOGROUND_S then
      self:emit('offgraph', { cause = 'noground', x = self.x, y = self.y, z = self.z })
      self:setState('failed')
      return true
    end
  else self.groundT = nil end
  return false
end

---- applying the wishes to the AI ----------------------------------------------------------------------------------------
-- How far BEYOND the target the stop point (a plan node of the AI) may be put. The AI stops at the last plan node before the
-- distance, so with nodes 25 m apart a plain stop point would leave the bus up to a segment short of the line. When a node lies
-- within 8 m behind the line, or 4 m beyond it, the stop point alone is precise enough; otherwise the speed curve does the
-- precise stop and the stop point is only a backstop further on.
function D:stopAddFor(along)
  local r = self.route
  local i = max(1, self.seg or 1)
  while i < r.n - 1 and r.cum[i + 1] <= along do i = i + 1 end
  local back = along - r.cum[i]
  local fwd = r.cum[i + 1] and (r.cum[i + 1] - along)
  if back <= 8 then return 0 end
  if fwd and fwd <= 4 then return fwd + 0.1 end
  return self:maxGap()
end

function D:maxGap()
  local r, g = self.route, 10
  for i = max(1, self.seg or 1), min(r.n - 1, (self.seg or 1) + 3) do g = max(g, r.len[i]) end
  return min(g, 40)
end

function D:actuate()
  local env, cfg, ai, ap, t = self.env, self.cfg, self.env.ai, self.applied, self.t
  local ready = not self.planReadyT or t >= self.planReadyT
  -- resolve the nearest stop target
  local stop
  for _, c in ipairs(self.cands) do
    if self.lad.rung >= 1 and self.lad.rung <= 5 and not c.hard and c.kind ~= 'hold' then
      -- during recoveries the soft holds (queues, bays, give-way, signs) are suspended
    elseif not stop or c.along < stop.along then stop = c end
  end
  local cap = self.cap
  if self.creep then cap = min(cap or huge, self.creep) end
  local wantStop, stopDist
  if stop and not self.rev then
    local dist = stop.kind == 'hold' and 0 or (stop.along - self.F)
    if dist < 0 then dist = 0 end
    stopDist = dist
    if stop.kind ~= 'hold' and cfg.strategy ~= 'stoppoint' and dist < cfg.approachZone then
      local a = core.approachSpeed(dist, cfg)
      if stop.creep then a = max(a, 1.3) end
      cap = min(cap or huge, a)
      if cfg.strategy == 'routespeed0' and dist < 1 then cap = 0 end
    end
    wantStop = dist
    if cfg.strategy == 'speed' and stop.stopAdd ~= nil then
      wantStop = stop.stopAdd == false and false or dist + stop.stopAdd
    end
  end
  if ready then
    if wantStop ~= nil and wantStop ~= false then
      if not ap.stop or t - ap.stopT >= 0.25 then
        ai.setStopPoint(wantStop)
        ap.stop, ap.stopT = true, t
      end
    elseif ap.stop then
      ai.setStopPoint(nil)
      ap.stop = false
    end
  end
  -- speed cap
  if not self.rev then
    if cap then
      if ap.cap ~= cap and (not ap.cap or abs(ap.cap - cap) > 0.05) then
        ai.setSpeedMode('limit')
        ai.setSpeed(cap)
        ap.cap = cap
      end
    elseif ap.cap then
      ai.setSpeedMode('legal')
      ai.setSpeed(nil)
      ap.cap = false
    end
  end
  -- aggression
  if t - (ap.aggrT or -9) > 2 then
    ap.aggrT = t
    local a = core.aggressionFor(self:late(), cfg)
    if ap.aggr ~= a then ai.setAggression(a); ap.aggr = a end
  end
  -- indicator that must go off after leaving the bay
  if self.indOffAt and t >= self.indOffAt and self.st == 'drive' then env.indicator(nil); self.indOffAt = nil end
end

function D:idleKeep()
  local env, t = self.env, self.t
  if self.st == 'done' or self.st == 'failed' then
    if t - (self.keepT or -9) > 1 then
      self.keepT = t
      env.ai.setStopPoint(0)
    end
  end
end

---- the step --------------------------------------------------------------------------------------------------------------
function D:step(dt)
  self.acc = self.acc + dt
  if self.acc < self.cfg.tickS then return end
  self.tickDt = self.acc
  self.acc = 0
  if self.st == 'idle' then return end
  self:sense(false)
  if self.st == 'done' or self.st == 'failed' then self:idleKeep(); return end
  if self:safety() then return end
  self:graphMaintenance()
  self:holds()
  local s = self.st
  if s == 'drive' or s == 'approach' then self:stRoute()
  elseif s == 'opening' then self:stOpening()
  elseif s == 'dwell' then self:stDwell()
  elseif s == 'closing' then self:stClosing()
  elseif s == 'depart' then self:stDepart() end
  if self.st == 'drive' or self.st == 'approach' then
    -- remember the kind of the nearest hold for the watchdog before actuate resolves it
    local nearest
    for _, c in ipairs(self.cands) do if not nearest or c.along < nearest.along then nearest = c end end
    self.holdKind = nearest and nearest.kind or nil
  end
  self:watchdog()
  if self.st == 'idle' then return end
  self:actuate()
end

core.Driver = D

---------------------------------------------------------------------------------------------------------------------------
-- Game adapter. Everything below touches the game, every call is protected; it is not loaded by the unit tests except through
-- core.buildEnv(globals) which receives a fake `globals` table.
---------------------------------------------------------------------------------------------------------------------------
function core.buildEnv(g)
  local env = {}
  local function try(f, ...) local ok, a, b, c = pcall(f, ...); if ok then return a, b, c end end
  local objc, ai, el = g.obj, g.ai, g.electrics
  local doorReq, kneelReq, kneelT, resyncT = false, false, -99, -99
  local indWant, indT = nil, -99
  env.id = function() return objc:getId() end
  env.time = function() return objc:getSimTime() end
  env.pos = function() return objc:getFrontPositionXYZ() end
  env.speed = function()
    local vx, vy, vz = objc:getSmoothRefVelocityXYZ()
    return sqrt(vx * vx + vy * vy + vz * vz)
  end
  env.dir = function() local x, y = objc:getDirectionVectorXYZ(); return x, y end
  env.upZ = function() local _, _, z = objc:getDirectionVectorUpXYZ(); return z end
  env.ground = function()
    local x, y, z = objc:getFrontPositionXYZ()
    local h = objc.getSurfaceHeightBelow and objc:getSurfaceHeightBelow(g.vec3(x, y, z + 1))
    if h == nil then return nil end
    return h > z - 50       -- no terrain within 50 m below the bus
  end
  env.throttle = function() return el.values.throttle_input or el.values.throttle or 0 end
  env.doorsOpen = function() return (el.values.dooropen or 0) > 0.5 end
  env.kneeling = function() return (el.values.kneel or 0) > 0.5 end
  local function busCtl() return g.controller.getController('bus') or g.controller.getControllerSafe('bus') end
  -- toggleDoors/toggleKneel are toggles. The controller's getState() tells whether the doors are REQUESTED open (its doorLever),
  -- so a request is sent only when it differs; env.resync() repeats it (the controller refuses while the bus drives > 2 m/s).
  local function busRequestsOpen(bus)
    local ok, st = pcall(bus.getState)
    if ok and type(st) == 'table' then
      for k, v in pairs(st) do
        if type(k) == 'string' and k:find('doorsRequestedOpen', 1, true) and type(v) == 'boolean' then return v end
      end
    end
    return nil
  end
  local function syncDoors()
    local bus = busCtl()
    if not bus or not bus.toggleDoors then return end
    local req = busRequestsOpen(bus)
    if req == nil then req = env.doorsOpen() end
    if req ~= doorReq then bus.toggleDoors() end
  end
  local function syncKneel()
    local bus = busCtl()
    if not bus or not bus.toggleKneel then return end
    local t = env.time()
    if t - kneelT < 0.6 then return end                 -- the controller needs a frame to notice its own change
    local is = bus.isKneeling
    if is == nil then is = env.kneeling() end
    if is ~= kneelReq then bus.toggleKneel(); kneelT = t end
  end
  env.setDoors = function(open)
    doorReq = open and true or false
    try(syncDoors)
  end
  env.setKneel = function(on)
    kneelReq = on and true or false
    try(syncKneel)
  end
  env.resync = function()          -- called every frame: repair a request that was refused, keep the indicator on
    local t = env.time()
    if t - resyncT >= 0.5 then
      resyncT = t
      try(syncDoors)
      try(syncKneel)
    end
    if indWant and t - indT > 1.5 then
      indT = t
      local cur = el.values.turnsignal or 0
      cur = (cur > 0.5 and 1) or (cur < -0.5 and -1) or 0
      if cur ~= (indWant == 'left' and -1 or 1) then env.indicator(indWant) end
    end
  end
  env.indicator = function(side)
    indWant = side
    local want = (side == 'left' and -1) or (side == 'right' and 1) or 0
    local cur = el.values.turnsignal or 0
    cur = (cur > 0.5 and 1) or (cur < -0.5 and -1) or 0
    if cur ~= want then
      if cur ~= 0 then el.stop_turn_signal() end
      if want < 0 then el.toggle_left_signal() elseif want > 0 then el.toggle_right_signal() end
    end
  end
  env.horn = function(sec)
    if el.horn then el.horn(true) end
    env.hornOffAt = env.time() + (sec or 0.4)
  end
  env.lights = function(on) if el.setLightsState then el.setLightsState(on and 1 or 0) end end
  env.emit = function(name, data)
    local id = objc:getId()
    data = data or {}
    objc:queueGameEngineLua(string.format("extensions.hook('onEarthBusDriverEvent', %d, %q, %s)", id, name, core.ser(data)))
  end
  env.graphId = function() return g.mapmgr.mapData end
  env.node = function(n)
    local md = g.mapmgr.mapData
    local p = md and md.positions and md.positions[n]
    if p and md.graph and md.graph[n] then return p.x, p.y end
  end
  env.edge = function(a, b)
    local md = g.mapmgr.mapData
    return md and md.graph and md.graph[a] and md.graph[a][b] ~= nil or false
  end
  env.junction = function(n, prev)
    local md = g.mapmgr.mapData
    local nb = md and md.graph and md.graph[n]
    if not nb then return nil end
    local deg, best = 0, 0
    for k, e in pairs(nb) do deg = deg + 1; best = max(best, e.drivability or 1) end
    local ein = nb[prev]
    return deg, ein and ein.drivability or 1, best
  end
  env.signal = function(a, b)
    local sd = g.mapmgr.signalsData
    local l = sd and sd[a] and sd[a][b]
    if not l then return nil end
    local out = {}
    for i, s in ipairs(l) do out[i] = { x = s.pos.x, y = s.pos.y, action = s.action } end
    return out
  end
  env.vehicles = function()
    local out = {}
    local me = objc:getId()
    local px, py = objc:getPositionXYZ()
    for id, o in pairs(g.mapmgr.getObjects()) do
      if id ~= me and o.pos then
        local dx, dy = o.pos.x - px, o.pos.y - py
        if dx * dx + dy * dy < 150 * 150 then
          out[#out + 1] = { id = id, x = o.pos.x, y = o.pos.y, vx = o.vel and o.vel.x or 0, vy = o.vel and o.vel.y or 0,
            dx = o.dirVec and o.dirVec.x, dy = o.dirVec and o.dirVec.y, len = try(function() return objc:getObjectInitialLength(id) end) or 4 }
        end
      end
    end
    return out
  end
  env.ai = {
    driveUsingPath = function(t) ai.driveUsingPath(t) end,
    setStopPoint = function(d) ai.setStopPoint(nil, d) end,
    laneChange = function(dist, disp) ai.laneChange(nil, dist, disp) end,
    setSpeed = function(v) ai.setSpeed(v) end,
    setSpeedMode = function(m) ai.setSpeedMode(m) end,
    setAggression = function(a) ai.setAggression(a) end,
    mode = function() local s = ai.getState and ai.getState(); return s and s.mode end,
  }
  -- Reverse is a last resort; the game's AI only reverses in traffic mode. UNVERIFIED in the game.
  env.reverseStart = function()
    ai.setMode('disabled')
    if g.input then
      g.input.event('parkingbrake', 0, 1)
      g.input.event('throttle', 0, 1)
      g.input.event('brake', 0.55, 1)      -- arcade gearbox: brake from standstill selects reverse
    end
  end
  env.reverseStop = function()
    if g.input then g.input.event('brake', 0, 1); g.input.event('throttle', 0, 1) end
  end
  return env
end

-- the extension --------------------------------------------------------------------------------------------------------------
local drv

local function gameGlobals()
  return { obj = obj, ai = ai, electrics = electrics, mapmgr = mapmgr, controller = controller, input = input, vec3 = vec3 }
end

local function ensure()
  if drv then return drv end
  local env = core.buildEnv(gameGlobals())
  drv = core.new(env)
  drv.env = env
  return drv
end

function M.onExtensionLoaded() ensure() end

function M.cmd(c)
  local ok, err = pcall(function() ensure():command(c) end)
  if not ok and log then log('E', 'busdriver', 'cmd failed: ' .. tostring(err)) end
end

function M.cmdJson(s)
  local c = jsonDecode and jsonDecode(s)
  if c then M.cmd(c) end
end

function M.updateGFX(dt)
  if not drv then return end
  local ok, err = pcall(function()
    drv:step(dt)
    local env = drv.env
    if env.hornOffAt and env.time() >= env.hornOffAt then
      env.hornOffAt = nil
      if electrics and electrics.horn then electrics.horn(false) end
    end
    if env.resync and drv.st ~= 'idle' then env.resync() end
  end)
  if not ok and log then log('E', 'busdriver', 'step failed: ' .. tostring(err)) end
end

function M.onReset()
  -- the vehicle was reset or teleported: the GE sends `relocate` after it moved the bus; here only forget transient requests
  if drv and drv.st ~= 'idle' then
    pcall(function() drv:command({ c = 'relocate' }) end)
  end
end

function M.onExtensionUnloaded()
  if drv then pcall(function() drv:abort() end) end
  drv = nil
end

M.getDriver = function() return drv end

return M
