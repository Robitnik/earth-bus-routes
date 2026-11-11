-- busdriver.lua (vehicle-side AI bus driver, plan 007 stage T3): the pure decision functions, then whole scenarios against a fake
-- world: a straight road of nodes every 25 m, a toy AI that obeys setStopPoint / speed caps / laneChange / driveUsingPath the way
-- ai.lua does (stop at the last plan node within the distance, speed limit mode), doors and kneel with delays and a safety
-- interlock like the citybus, signals that change with time, other vehicles. No game needed.
local H = dofile('tests/harness.lua')
local BD = H.load('mod/lua/vehicle/extensions/earthBusRoutes/busdriver.lua')
local core, L = BD.core, BD.LIMITS
local T = {}

local function near(a, b, tol, msg) assert(math.abs(a - b) <= tol, (msg or 'near') .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end

---------------------------------------------------------------------------------------------------------------------------
-- the fake world
---------------------------------------------------------------------------------------------------------------------------
local W = {}
W.__index = W

local CRUISE = 13.9

function W.new(o)
  o = o or {}
  local w = setmetatable({ t = 0, events = {}, nodesN = o.nodes or 41, gap = o.gap or 25, buses = {}, others = {}, sigs = {},
    junctions = {}, gid = 1, hidden = {}, dt = 0.1, clipFrom = nil }, W)
  return w
end

function W:nodeName(i) return 'n' .. i end
function W:nodeX(i) return (i - 1) * self.gap end
function W:nodeIdx(name) return tonumber(name:sub(2)) end
function W:hasNode(name)
  local i = self:nodeIdx(name)
  return i and i >= 1 and i <= self.nodesN and not self.hidden[i] and (not self.clipFrom or i <= self.clipFrom)
end
function W:setClip(i) self.clipFrom = i; self.gid = self.gid + 1 end
function W:hide(i, on) self.hidden[i] = on or nil; self.gid = self.gid + 1 end

-- route over nodes from..to (either direction)
function W:route(from, to)
  local names, pts = {}, {}
  local step = from <= to and 1 or -1
  for i = from, to, step do names[#names + 1] = self:nodeName(i); pts[#pts + 1] = { self:nodeX(i), 0 } end
  return names, pts
end

function W:addOther(o)
  o.len = o.len or 4.5
  o.vx, o.vy = o.vx or 0, o.vy or 0
  o.id = o.id or (100 + #self.others)
  self.others[#self.others + 1] = o
  return o
end

-- an endless stream of cars driving across the road at x (north, 8 m/s), `n` of them so that one is always approaching
function W:crossFlow(x, n)
  for i = 1, n do
    self:addOther({ x = x, y = -60 + (i - 1) * (80 / n), vx = 0, vy = 8, update = function(o, t, dt)
      o.y = o.y + o.vy * dt
      if o.y > 20 then o.y = -60 end
    end })
  end
end

function W:addSignal(a, b, x, fn) self.sigs[self:nodeName(a) .. '>' .. self:nodeName(b)] = { x = x, y = 0, fn = fn } end

function W:addBus(o)
  local w = self
  local B = { id = o.id or (#w.buses + 1), dir = o.dir or 1, x = o.x or 5, v = 0, lat = 0, latTarget = 0, len = 12,
    doorsReq = false, doorsPhys = false, kneelReq = false, kneelPhys = false, doorT = -9, kneelT = -9, up = 1, ground = true,
    horn = 0, calls = {}, ai = { active = false, cap = nil, capMode = 'legal', stopS = nil, path = nil }, rev = false,
    stand = 0, standNS = 0, maxStandNS = 0, doorDelay = 1.5, jamOpen = false, jamClose = false, dead = false, throttle = 0,
    reissues = 0, ind = nil, laneChanges = {}, stopCalls = 0, maxX = o.x or 5 }
  local function s(x) return B.dir * x end
  B.s = s
  local env = {}
  env.id = function() return B.id end
  env.time = function() return w.t end
  env.pos = function() return B.x, -B.dir * B.lat, 0 end
  env.speed = function() return math.abs(B.v) end
  env.dir = function() return B.dir, 0 end
  env.upZ = function() return B.up end
  env.ground = function() return B.ground end
  env.throttle = function() return B.throttle end
  env.doorsOpen = function() return B.doorsPhys end
  env.kneeling = function() return B.kneelPhys end
  env.setDoors = function(open)
    if open ~= B.doorsReq then B.doorsReq = open; B.doorT = w.t end
    B.calls[#B.calls + 1] = open and 'doorsOpen' or 'doorsClose'
  end
  env.setKneel = function(on)
    if on ~= B.kneelReq then B.kneelReq = on; B.kneelT = w.t end
    B.calls[#B.calls + 1] = on and 'kneel' or 'unkneel'
  end
  env.indicator = function(side) B.ind = side; B.calls[#B.calls + 1] = 'ind:' .. tostring(side) end
  env.horn = function() B.horn = B.horn + 1 end
  env.lights = function(on) B.lights = on end
  env.emit = function(name, data) w.events[#w.events + 1] = { bus = B.id, name = name, data = data, t = w.t } end
  env.graphId = function() return w.gid end
  env.node = function(n)
    if w:hasNode(n) then return w:nodeX(w:nodeIdx(n)), 0 end
  end
  env.edge = function(a, b) return w:hasNode(a) and w:hasNode(b) and math.abs(w:nodeIdx(a) - w:nodeIdx(b)) == 1 end
  env.junction = function(n)
    local j = w.junctions[w:nodeIdx(n)]
    if j then return j.deg or 3, j.drivIn or 1, j.drivMax or 1 end
    return 2, 1, 1
  end
  env.signal = function(a, b)
    local sg = w.sigs[a .. '>' .. b]
    if not sg then return nil end
    return { { x = sg.x, y = sg.y, action = sg.fn(w.t) } }
  end
  env.vehicles = function()
    local out = {}
    for _, o in ipairs(w.others) do out[#out + 1] = { id = o.id, x = o.x, y = o.y or 0, vx = o.vx, vy = o.vy, dx = o.dx or (o.vx >= 0 and 1 or -1), dy = 0, len = o.len } end
    for _, b in ipairs(w.buses) do
      if b ~= B then out[#out + 1] = { id = b.id, x = b.x - b.dir * b.len * 0.5, y = -b.dir * b.lat, vx = b.v * b.dir, vy = 0, dx = b.dir, dy = 0, len = b.len } end
    end
    return out
  end
  env.ai = {
    driveUsingPath = function(a)
      local ai = B.ai
      ai.active, ai.path, ai.stopS, ai.cap, ai.capMode = true, a.path, nil, nil, 'legal'
      ai.wp = a.wpSpeeds
      ai.aggr = a.aggression
      ai.nodes = {}
      for i, n in ipairs(a.path) do ai.nodes[i] = s(w:nodeX(w:nodeIdx(n))) end
      B.latTarget = 0
      B.reissues = B.reissues + 1
      B.calls[#B.calls + 1] = 'drive'
      B.lastIssue = a
    end,
    setStopPoint = function(d)
      local ai = B.ai
      if not ai.active then return end
      B.stopCalls = B.stopCalls + 1
      if d == nil then ai.stopS = nil; B.calls[#B.calls + 1] = 'stopClear'; return end
      local sf = s(B.x)
      local best = sf
      for _, ns in ipairs(ai.nodes) do
        if ns >= sf - 1e-6 and ns <= sf + d then best = math.max(best == sf and ns or best, ns) end
      end
      ai.stopS = best
    end,
    laneChange = function(dist, disp)
      B.latTarget = B.latTarget + disp
      B.laneChanges[#B.laneChanges + 1] = { t = w.t, dist = dist, disp = disp, x = B.x }
      B.calls[#B.calls + 1] = 'lane'
    end,
    setSpeed = function(v) B.ai.cap = v end,
    setSpeedMode = function(m) B.ai.capMode = m end,
    setAggression = function(a) B.ai.aggr = a end,
    mode = function() return B.ai.active and 'manual' or 'disabled' end,
  }
  env.reverseStart = function() B.rev = true; B.ai.active = false end
  env.reverseStop = function() B.rev = false end
  B.env = env
  B.driver = core.new(env)
  w.buses[#w.buses + 1] = B
  return B
end

function W:cmd(B, c) B.env.time = B.env.time; B.driver:command(c) end

local function physics(w, B, dt)
  local ai = B.ai
  -- doors/kneel follow the request after a delay
  if B.doorsReq ~= B.doorsPhys and w.t - B.doorT >= B.doorDelay then
    if not ((B.doorsReq and B.jamOpen) or ((not B.doorsReq) and B.jamClose)) then B.doorsPhys = B.doorsReq end
  end
  if B.kneelReq ~= B.kneelPhys and w.t - B.kneelT >= B.doorDelay then B.kneelPhys = B.kneelReq end
  -- the lane shift is slow
  if B.lat ~= B.latTarget then
    local d = B.latTarget - B.lat
    B.lat = B.lat + math.max(-0.7 * dt, math.min(0.7 * dt, d))
  end
  if B.rev then
    B.v = -1.5
    B.x = B.x + B.dir * B.v * dt
    return
  end
  local target = 0
  if ai.active and not B.dead then
    target = CRUISE
    if ai.cap and ai.capMode == 'limit' then target = math.min(target, ai.cap) end
    local sf = B.s(B.x)
    local limitS = ai.nodes[#ai.nodes]
    if ai.stopS and ai.stopS < limitS then limitS = ai.stopS end
    target = math.min(target, math.sqrt(2 * 2.0 * math.max(limitS - sf, 0)))
    -- obstacles ahead in our lane (avoidCars)
    local function obstacle(x, y, len, vx)
      local sx = B.s(x)
      local gap = sx - len * 0.5 - sf
      local lat = math.abs(y - (-B.dir * B.lat))
      if gap > -1 and gap < 90 and lat < 2.6 then
        if vx * B.dir < -0.5 then gap = gap / 2 end            -- oncoming: both brake
        target = math.min(target, math.sqrt(2 * 3.0 * math.max(gap - 4, 0)))
      end
    end
    for _, o in ipairs(w.others) do obstacle(o.x, o.y or 0, o.len, o.vx) end
    for _, b in ipairs(w.buses) do
      if b ~= B then obstacle(b.x - b.dir * b.len * 0.5, -b.dir * b.lat, b.len, b.v * b.dir) end
    end
    if B.doorsPhys or B.kneelPhys or B.doorsReq then target = 0 end   -- the citybus' interlock holds the brake
  end
  B.throttle = (target > 0.5 or (ai.active and not ai.stopS)) and 0.9 or 0
  if B.dead then B.throttle = 0.9 end
  local dv = target - B.v
  B.v = B.v + math.max(-3 * dt, math.min(1.5 * dt, dv))
  B.x = B.x + B.dir * B.v * dt
end

function W:run(sec, untilFn)
  local n = math.floor(sec / self.dt + 0.5)
  for _ = 1, n do
    for _, B in ipairs(self.buses) do B.driver:step(self.dt) end
    self.t = self.t + self.dt
    for _, o in ipairs(self.others) do
      if o.update then o.update(o, self.t, self.dt) else o.x = o.x + o.vx * self.dt end
    end
    for _, B in ipairs(self.buses) do
      physics(self, B, self.dt)
      if math.abs(B.v) < 0.3 then B.stand = B.stand + self.dt else B.stand = 0 end
      local st = B.driver.st
      local service = st == 'opening' or st == 'dwell' or st == 'closing' or st == 'depart' or st == 'done' or st == 'idle'
      if math.abs(B.v) < 0.3 and not service then B.standNS = B.standNS + self.dt else B.standNS = 0 end
      if B.standNS > B.maxStandNS then B.maxStandNS = B.standNS end
      if B.dir * B.x > B.dir * B.maxX then B.maxX = B.x end
    end
    if untilFn and untilFn(self) then return true end
  end
  return false
end

function W:ev(name, bus)
  local out = {}
  for _, e in ipairs(self.events) do if e.name == name and (not bus or e.bus == bus) then out[#out + 1] = e end end
  return out
end
function W:first(name) return self:ev(name)[1] end

-- a bus on the straight road from node `from` to node `to`
local function scene(o)
  o = o or {}
  local w = W.new(o)
  local B = w:addBus({ x = o.x or 5, dir = (o.from or 1) <= (o.to or w.nodesN) and 1 or -1 })
  local names, pts = w:route(o.from or 1, o.to or w.nodesN)
  local c = { c = 'start', path = names, pts = pts, stops = o.stops, delaySec = o.delay, clock = o.clock or 0, cfg = o.cfg, night = o.night }
  return w, B, c
end

---------------------------------------------------------------------------------------------------------------------------
-- pure functions
---------------------------------------------------------------------------------------------------------------------------
function T.approach_speed_curve()
  local c = core.DEFAULTS
  assert(core.approachSpeed(0, c) == 0 and core.approachSpeed(0.3, c) == 0)
  assert(core.approachSpeed(100, c) > core.approachSpeed(30, c) and core.approachSpeed(30, c) > core.approachSpeed(5, c))
  near(core.approachSpeed(30, c), math.sqrt(2 * c.approachDecel * 29.7), 1e-9)
  assert(core.approachSpeed(1, c) >= c.approachCreep, 'a creep floor so the AI does not stall short of the target')
  near(core.brakeDist(10, 2.5), 20, 1e-9)
end

function T.signal_decisions()
  local c = core.DEFAULTS
  assert(core.signalDecision(0, 5, 10, c) == 'go')
  assert(core.signalDecision(2, 50, 10, c) == 'stop', 'red far ahead')
  assert(core.signalDecision(2, 5, 12, c) == 'go', 'red but it cannot stop any more: no emergency stop in the junction')
  assert(core.signalDecision(2, -5, 0, c) == 'go', 'line already behind')
  assert(core.signalDecision(2, 3, 0.1, c) == 'stop', 'standing before the line')
  assert(core.signalDecision(1, 60, 10, c) == 'stop', 'yellow with room: stop')
  assert(core.signalDecision(1, 15, 10, c) == 'go', 'yellow without room: go on')
  assert(core.signalDecision(1, 60, 10, c, true) == 'go', 'a committed yellow stays go')
  assert(core.signalDecision(3, 40, 10, c) == 'sign')
end

function T.give_way_rule()
  assert(core.isGiveWay(1, 0, 0, 1, 1, 1), '90 degrees')
  assert(not core.isGiveWay(1, 0, 1, 0, 1, 1), 'straight on a main road')
  assert(not core.isGiveWay(1, 0, math.cos(0.5), math.sin(0.5), 1, 1), '29 degrees is not a turn')
  assert(core.isGiveWay(1, 0, 1, 0, 0.5, 1), 'a minor road entering a major one')
  assert(core.isGiveWay(1, 0, math.cos(2.2), math.sin(2.2), 1, 1), '126 degrees is still a turn')
end

function T.route_projection_and_sides()
  local r = core.buildRoute({ 'a', 'b', 'c' }, { { 0, 0 }, { 100, 0 }, { 100, 100 } })
  near(r.total, 200, 1e-9)
  local a, lat = core.project(r, 40, -3)       -- heading +x: y negative is on the right
  near(a, 40, 1e-9); assert(lat > 0, 'right is positive'); near(lat, 3, 1e-9)
  local a2, lat2 = core.project(r, 40, 3)
  assert(lat2 < 0)
  local a3, _, seg = core.project(r, 103, 60)
  near(a3, 160, 1e-9); assert(seg == 2)
  local lo, hi = core.segWindow(r, 1, 10, 5, 50)
  assert(lo == 1 and hi == 1)
  -- unknown points are filled from their neighbours
  local r2 = core.buildRoute({ 'a', 'b' }, { { 1, 2 }, nil })
  assert(r2.n == 2 and r2.total == 0)
end

function T.bay_target_moves_behind_occupant()
  local c = core.DEFAULTS
  local eff, occ = core.bayTarget({ { id = 7, along = 300, lat = 0.2, len = 12, speed = 0 } }, 300, 200, c)
  near(eff, 300 - 6 - c.queueGap, 1e-9); assert(occ.id == 7)
  eff = core.bayTarget({ { id = 7, along = 300, lat = 0.2, len = 12, speed = 6 } }, 300, 200, c)
  assert(eff == 300, 'a moving vehicle does not occupy the bay')
  eff = core.bayTarget({ { id = 7, along = 300, lat = 3.0, len = 4, speed = 0 } }, 300, 200, c)
  assert(eff == 300, 'a car parked at the kerb beside the lane is not in our way')
  eff = core.bayTarget({ { id = 7, along = 330, lat = 0, len = 4, speed = 0 } }, 300, 200, c)
  assert(eff == 300, 'standing beyond the bay does not matter')
  eff = core.bayTarget({ { id = 7, along = 150, lat = 0, len = 4, speed = 0 } }, 300, 200, c)
  assert(eff == 300, 'behind us does not matter')
end

function T.cross_traffic()
  local c = core.DEFAULTS
  local me = { id = 1 }
  -- a car 30 m west of the junction, driving east: 10 m/s -> 3 s
  assert(core.crossTrafficBlocked(0, 0, { { id = 5, x = -30, y = 0, vx = 10, vy = 0 } }, 0, 1, 1, c), 'approaching from the side')
  assert(not core.crossTrafficBlocked(0, 0, { { id = 5, x = 30, y = 0, vx = 10, vy = 0 } }, 0, 1, 1, c), 'driving away')
  assert(not core.crossTrafficBlocked(0, 0, { { id = 5, x = -30, y = 0, vx = 0.5, vy = 0 } }, 0, 1, 1, c), 'standing')
  assert(not core.crossTrafficBlocked(0, 0, { { id = 5, x = 0, y = -30, vx = 0, vy = 10 } }, 0, 1, 1, c), 'same direction as we drive')
  assert(not core.crossTrafficBlocked(0, 0, { { id = 1, x = -30, y = 0, vx = 10, vy = 0 } }, 0, 1, 1, c), 'ourselves')
  assert(not core.crossTrafficBlocked(0, 0, { { id = 5, x = -39, y = 0, vx = 3, vy = 0 } }, 0, 1, 1, c), 'too slow to arrive in 5 s')
end

function T.catch_up_aggression_dwell_and_departure()
  local c = core.DEFAULTS
  near(core.aggressionFor(0, c), 0.3, 1e-9)
  near(core.aggressionFor(30, c), 0.3, 1e-9)
  near(core.aggressionFor(1000, c), 0.45, 1e-9)
  assert(core.aggressionFor(90, c) > 0.3 and core.aggressionFor(90, c) < 0.45)
  near(core.dwellSeconds({ alight = 5, board = 10 }, c), 5 * 1.2 + 10 * 1.8, 1e-9)
  near(core.dwellSeconds({}, c), c.minDwellS, 1e-9)
  near(core.dwellSeconds({ dwellS = 1000 }, c), L.DWELL_MAX_S, 1e-9)
  near(core.departAt(100, 20, nil, false), 120, 1e-9)
  near(core.departAt(100, 20, 160, false), 160, 1e-9, 'early: wait for the timetable')
  near(core.departAt(100, 20, 100 + 10000, false), 100 + L.EARLY_WAIT_MAX_S, 1e-9, 'the early wait is capped')
  near(core.departAt(100, 20, 160, true), 120, 1e-9, 'the terminus does not wait')
  near(core.departAt(100, 20, 110, false, 170), 170, 1e-9, 'extra hold')
end

function T.serializer_round_trip()
  local t = { a = 1, b = 'x"y', c = { 1, 2, { d = true } }, e = false, f = 1.5e-3 }
  local back = load('return ' .. core.ser(t))()
  assert(back.a == 1 and back.b == 'x"y' and back.c[3].d == true and back.e == false and math.abs(back.f - 0.0015) < 1e-9)
  assert(core.ser(0 / 0) == 'nil' and core.ser(function() end) == 'nil')
end

function T.available_prefix()
  local names = { 'a', 'b', 'c', 'd', 'e' }
  local has = { b = true, c = true, d = true, e = true }
  local s, e = core.availablePrefix(names, function(n) return has[n] end, function(a, b) return not (a == 'c' and b == 'd') end, 1)
  assert(s == 2 and e == 3, 'starts at the first known node, ends at the first missing edge')
  assert(core.availablePrefix(names, function() return false end, function() return true end, 1) == nil)
  local _, e2 = core.availablePrefix(names, function() return true end, function() return true end, 1, 3)
  assert(e2 == 3, 'maxN')
end

function T.file_is_lua51_and_shipped()
  local src = readFileText('mod/lua/vehicle/extensions/earthBusRoutes/busdriver.lua')
  local s = src:gsub('%-%-[^\n]*', ''):gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
  assert(not s:find('//'), 'integer division')
  assert(not s:find('<<') and not s:find('>>'), 'shift operators')
  assert(not s:find('%f[%w_]goto%f[^%w_]'), 'goto')
  assert(not s:find('%f[%w_]utf8%.') and not s:find('table%.unpack') and not s:find('math%.tointeger'), '5.3 library')
  assert(not s:find('%f[%w_]unpack%('), 'unpack differs between 5.1 and 5.4')
  assert(not s:find('%f[%w_]loadstring'), 'loadstring does not exist in 5.4')
  assert(not s:find('%f[%w_]global%f[^%w_]'), 'global is a keyword in Lua 5.5')
  assert(src:find('onEarthBusDriverEvent', 1, true) and src:find('extensions.load', 1, true), 'the protocol is documented in the header')
end

function T.game_adapter_builds_with_fake_globals()
  -- the adapter touches only what it is given; every game call is a method of obj/ai/electrics/mapmgr/controller
  local calls = {}
  local g = {
    obj = { getId = function() return 7 end, getSimTime = function() return 12.5 end,
      getFrontPositionXYZ = function() return 1, 2, 3 end, getSmoothRefVelocityXYZ = function() return 3, 4, 0 end,
      getDirectionVectorXYZ = function() return 1, 0, 0 end, getDirectionVectorUpXYZ = function() return 0, 0, 1 end,
      getPositionXYZ = function() return 1, 2, 3 end,
      queueGameEngineLua = function(_, s) calls[#calls + 1] = s end },
    ai = { driveUsingPath = function(t) calls[#calls + 1] = 'drive' .. #t.path end,
      setStopPoint = function(p, d) calls[#calls + 1] = 'stop' .. tostring(p) .. tostring(d) end,
      laneChange = function(p, d, x) calls[#calls + 1] = 'lane' .. tostring(p) .. d .. x end,
      getState = function() return { mode = 'manual' } end },
    electrics = { values = { turnsignal = 0, dooropen = 0, kneel = 0 }, toggle_left_signal = function() calls[#calls + 1] = 'left' end,
      toggle_right_signal = function() calls[#calls + 1] = 'right' end, stop_turn_signal = function() end, horn = function() end,
      setLightsState = function() end },
    mapmgr = { mapData = { positions = { a = { x = 0, y = 0 }, b = { x = 10, y = 0 } }, graph = { a = { b = { drivability = 1 } }, b = { a = { drivability = 1 } } } },
      signalsData = { a = { b = { { pos = { x = 5, y = 0 }, action = 2 } } } },
      getObjects = function() return { [7] = { pos = { x = 1, y = 2 } }, [9] = { pos = { x = 30, y = 2 }, vel = { x = 1, y = 0 }, dirVec = { x = 1, y = 0 } } } end },
    controller = { getController = function() return nil end, getControllerSafe = function() return nil end },
  }
  local env = core.buildEnv(g)
  assert(env.id() == 7 and env.time() == 12.5)
  near(env.speed(), 5, 1e-9)
  local x = env.node('a'); assert(x == 0 and env.node('zz') == nil)
  assert(env.edge('a', 'b') == true and env.edge('a', 'c') == false)
  assert(env.signal('a', 'b')[1].action == 2 and env.signal('b', 'a') == nil)
  local vs = env.vehicles(); assert(#vs == 1 and vs[1].id == 9)
  env.ai.setStopPoint(12); env.ai.laneChange(60, 1.2)
  assert(calls[1] == 'stopnil12' and calls[2]:find('lanenil60', 1, true))
  env.indicator('right'); assert(calls[3] == 'right')
  env.emit('atStop', { i = 2 })
  assert(calls[4]:find("onEarthBusDriverEvent', 7, \"atStop\"", 1, true), calls[4])
  env.setDoors(true); env.setKneel(true)    -- no bus controller: silently nothing
end

---------------------------------------------------------------------------------------------------------------------------
-- scenarios
---------------------------------------------------------------------------------------------------------------------------
function T.drives_the_route_and_reports_done()
  local w, B, c = scene({ from = 1, to = 21 })
  w:cmd(B, c)
  assert(w:first('ready') and w:first('ready').data.n == 21)
  local a = B.lastIssue
  assert(a.driveInLane == 'on' and a.avoidCars == 'on' and a.routeSpeedMode == 'legal' and #a.path == 21 and a.path[1] == 'n1')
  near(a.aggression, 0.3, 1e-9)
  assert(w:run(120, function() return w:first('done') end), 'reaches the end')
  assert(B.x > 480, 'drove to the end of the path: ' .. B.x)
  assert(B.maxStandNS < 15, 'no long standstill on the way')
  assert(B.driver.counters.stuck == 0)
end

function T.red_light_stops_before_the_line_then_goes()
  -- signal on edge n11>n12, the line at x=262: red until t=35
  local w, B, c = scene({ from = 1, to = 31 })
  w:addSignal(11, 12, 262, function(t) return t < 35 and 2 or 0 end)
  w:cmd(B, c)
  local crossedWhileRed = false
  w:run(34, function() if B.x > 262.5 then crossedWhileRed = true end end)
  assert(not crossedWhileRed, 'never crosses the line on red: ' .. B.x)
  assert(B.x > 150 and math.abs(B.v) < 0.5, 'waiting at the line: x=' .. B.x .. ' v=' .. B.v)
  assert(w:run(40, function() return B.x > 300 end), 'goes after green')
  assert(B.driver.counters.stuck == 0, 'a red light is not a stall')
end

function T.yellow_it_cannot_stop_for_is_run_but_far_yellow_stops()
  -- bus at 13.9 m/s: yellow showing when the line is 25 m away: cannot stop comfortably, goes on
  local w, B, c = scene({ from = 1, to = 31 })
  w:addSignal(11, 12, 262, function(t) return t < 21.5 and 0 or (t < 24.5 and 1 or (t < 80 and 2 or 0)) end)
  -- cruising from rest the bus is 28 m before the line at t=21.5: yellow starts there, red 3 s later
  w:cmd(B, c)
  w:run(40)
  assert(B.x > 262, 'went through (or the test timing needs an adjustment): ' .. B.x)
  local w2, B2, c2 = scene({ from = 1, to = 31 })
  w2:addSignal(11, 12, 262, function(t) return t < 5 and 1 or (t < 40 and 2 or 0) end)
  w2:cmd(B2, c2)
  w2:run(35)
  assert(B2.x < 262 and math.abs(B2.v) < 0.5, 'yellow far from the line at 5 s: stops. x=' .. B2.x)
end

function T.stop_sign_full_stop_then_go()
  local w, B, c = scene({ from = 1, to = 31 })
  w:addSignal(11, 12, 262, function() return 3 end)
  w:cmd(B, c)
  local minV, atLine = 99, nil
  local t0
  w:run(60, function()
    if B.x > 235 and B.x < 263 then
      if math.abs(B.v) < 0.3 then t0 = t0 or w.t; atLine = B.x end
    end
    return B.x > 300
  end)
  assert(t0, 'it stopped at the sign')
  assert(w.t - t0 >= L.STOPSIGN_HOLD_S, 'full stop of at least 2 s')
  assert(atLine <= 262.2, 'stopped before the line: ' .. atLine)
  assert(B.x > 300)
end

function T.stop_sign_waits_for_cross_traffic_then_times_out()
  -- a car sits across the junction forever moving at 5 m/s back and forth would block; a car that keeps coming
  local w, B, c = scene({ from = 1, to = 31 })
  w:addSignal(11, 12, 262, function() return 3 end)
  -- cross traffic: a vehicle approaching the junction at x=275 from the south, resets every 5 s
  w:crossFlow(275, 6)
  w:cmd(B, c)
  assert(w:run(80, function() return B.x > 290 end), 'goes on in the end')
  assert(w:first('signal_timeout') and w:first('signal_timeout').data.what == 'stopsign', 'a permanent flow does not hold it for ever')
  assert(w.t < 40 + L.STOPSIGN_CLEAR_MAX_S + 5, 'bounded: ' .. w.t)
end

function T.stale_red_light_is_overridden_after_the_cap()
  local w, B, c = scene({ from = 1, to = 31 })
  w:addSignal(11, 12, 262, function() return 2 end)       -- never turns
  w:cmd(B, c)
  assert(w:run(40 + L.RED_WAIT_MAX_S + 40, function() return B.x > 275 end), 'creeps on after the cap')
  assert(w:first('signal_timeout') and w:first('signal_timeout').data.what == 'red')
  assert(w.t < 30 + L.RED_WAIT_MAX_S + 25, 'bounded wait: ' .. w.t)
  assert(B.driver.counters.stuck == 0, 'the override is not a ladder')
end

function T.give_way_junction_slows_and_waits_for_cross_traffic()
  local w, B, c = scene({ from = 1, to = 31 })
  w.junctions[13] = { deg = 4, drivIn = 1, drivMax = 1 }
  -- 90 degree turn at n13 would be a give-way; our straight road makes dot=1, so make the road minor instead
  w.junctions[13].drivIn = 0.4
  w:cmd(B, c)
  assert(B.lastIssue.wpSpeeds.n13 and math.abs(B.lastIssue.wpSpeeds.n13 - 15 / 3.6) < 1e-6, 'wpSpeeds at the give-way node')
  assert(B.lastIssue.wpSpeeds.n12 == nil)
  -- cross traffic keeps coming for a while: the bus waits before the node (x=300), 6 m back
  local until_ = 25
  w:addOther({ x = 300, y = -40, vx = 0, vy = 10, update = function(o, t, dt)
    if t < until_ then o.y = o.y + o.vy * dt; if o.y > 5 then o.y = -40 end else o.y = 400 end
  end })
  local crossedEarly = false
  w:run(60, function() if B.x > 296 and w.t < until_ - 6 then crossedEarly = true end return B.x > 320 end)
  assert(not crossedEarly, 'waited for the cross traffic')
  assert(B.x > 300 or w.t < 60, 'and went afterwards')
  assert(w.t < 45, 'in time: ' .. w.t)
end

function T.give_way_wait_is_capped()
  local w, B, c = scene({ from = 1, to = 31 })
  w.junctions[13] = { deg = 3, drivIn = 0.4, drivMax = 1 }
  w:crossFlow(300, 6)
  w:cmd(B, c)
  assert(w:run(120, function() return B.x > 320 end), 'cross traffic that never ends does not hold the bus for ever')
  local ev = w:ev('signal_timeout')
  assert(#ev >= 1 and ev[1].data.what == 'giveway')
end

function T.bay_stop_full_sequence()
  -- stop anchor at 400 m, kerb on the right; scheduled departure 60 s after the start
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 400, side = 'r', sched = 100, alight = 4, board = 6 } } })
  w:cmd(B, c)
  assert(w:run(120, function() return w:first('atStop') end), 'arrives at the stop')
  local at = w:first('atStop')
  local tgt = 400 + core.DEFAULTS.doorOffset
  near(B.x, tgt, 2.0, 'front door within 2 m of the anchor')
  -- indicator right, lane change towards the kerb ~120 m before
  local sawRight = false
  for _, cl in ipairs(B.calls) do if cl == 'ind:right' then sawRight = true end end
  assert(sawRight, 'right indicator on the approach')
  assert(#B.laneChanges >= 1 and B.laneChanges[1].disp > 0, 'shift to the right kerb')
  assert(B.laneChanges[1].x < tgt - 100 and B.laneChanges[1].x > tgt - 135, 'about 120 m before: ' .. B.laneChanges[1].x)
  -- doors: kneel first, then open; the bus has stopped
  assert(B.kneelReq and B.doorsReq and B.doorsPhys, 'kneeled and doors open')
  assert(math.abs(B.v) < 0.3)
  assert(not at.data.short and at.data.dist and math.abs(at.data.dist) <= 2)
  -- dwell until the timetable: scheduled departure t=100 (clock 0 at the start)
  assert(w:run(150, function() return w:first('departed') end), 'departs')
  assert(w.t >= 100 - 0.2, 'waited for the timetable: left at ' .. w.t)
  assert(not B.doorsReq and not B.kneelReq, 'doors closed and bus raised before leaving')
  local depE = w:first('departed')
  assert(depE.data.i == 1 and depE.data.late < 2)
  local sawLeft, laneBack = false, false
  for _, cl in ipairs(B.calls) do if cl == 'ind:left' then sawLeft = true end end
  assert(sawLeft, 'left indicator when leaving')
  assert(B.laneChanges[#B.laneChanges].disp < 0, 'back into the lane')
  -- the indicator went off and the bus goes on to the end
  assert(w:run(80, function() return w:first('done') end), 'finishes the route')
  assert(B.ind == nil, 'indicator off')
  assert(B.driver.counters.stuck == 0)
end

function T.bay_early_wait_and_dwell_model()
  -- no schedule: dwell = 4*1.2 + 6*1.8 = 15.6 s
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', alight = 4, board = 6 } } })
  w:cmd(B, c)
  w:run(100, function() return w:first('atStop') end)
  local t0 = w:first('atStop').t
  w:run(60, function() return w:first('departed') end)
  local dep = w:first('departed').t
  assert(dep - t0 >= 15.6 and dep - t0 < 15.6 + 12, 'dwell ' .. (dep - t0))
end

function T.left_side_stop_uses_left_indicator_and_shift()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'l', dwellS = 8 } } })
  w:cmd(B, c)
  w:run(100, function() return w:first('departed') end)
  local sawL = false
  for _, cl in ipairs(B.calls) do if cl == 'ind:left' then sawL = true; break end end
  assert(sawL and B.laneChanges[1].disp < 0)
  local leftAfter = false
  for i = #B.calls, 1, -1 do if B.calls[i] == 'ind:right' then leftAfter = true; break end end
  assert(leftAfter, 'leaving a left kerb: right indicator')
end

function T.terminus_lets_everybody_out_then_done()
  local w, B, c = scene({ from = 1, to = 21, stops = { { id = 'END', along = 495, side = 'r', alight = 10 } } })
  w:cmd(B, c)
  assert(w:run(150, function() return w:first('done') end), 'done is reported')
  assert(w:first('atStop'), 'doors opened at the terminus')
  assert(not w:first('departed'), 'no departure from the terminus')
  assert(not B.doorsReq, 'doors closed again')
  assert(w:first('done').t - w:first('atStop').t >= 12, 'alight time respected')
end

function T.queue_behind_a_bus_that_leaves()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 400, side = 'r', dwellS = 6 } } })
  -- another bus stands in the bay for 25 s, then drives off
  local o = w:addOther({ x = 402, vx = 0, len = 12, update = function(o, t, dt)
    if t > 45 then o.vx = math.min(8, (o.vx or 0) + 2 * dt) end
    o.x = o.x + o.vx * dt
  end })
  w:cmd(B, c)
  assert(w:run(200, function() return w:first('atStop') end), 'serves the stop once the bay is free')
  assert(not w:first('atStop').data.short, 'not short: the bay was free in the end')
  near(B.x, 402, 3.5)
  assert(w:first('atStop').t > 45, 'it queued while the bay was occupied: ' .. w:first('atStop').t)
end

function T.bay_blocked_for_good_stops_short_after_the_queue_limit()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 8 }, { id = 'B', along = 600, side = 'r', dwellS = 6 } } })
  w:addOther({ x = 302, vx = 0, len = 4.5 })                 -- a car parked in the bay and the lane, for ever
  w:cmd(B, c)
  assert(w:run(200, function() return w:first('atStop') end), 'serves the stop short')
  local at = w:first('atStop')
  assert(at.data.short, 'short')
  assert(at.t < 300 / 10 + 20 + L.BAY_QUEUE_MAX_S + 25, 'bounded by the queue limit: ' .. at.t)
  assert(B.x < 302 - 2, 'stopped behind the car: ' .. B.x)
end

function T.bay_blocked_car_that_cannot_be_passed_is_skipped_or_reported()
  -- the parked car in the lane stays; after stopping short and departing the bus is still behind it and must get past or report
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
  w:addOther({ x = 302, vx = 0, len = 4.5 })
  w:cmd(B, c)
  local ok = w:run(400, function() return B.x > 330 or w:first('stuck') end)
  assert(ok, 'resolved within bounds')
  assert(B.x > 330 or w:first('stuck'), 'moving again or reported')
  assert(B.maxStandNS <= L.BAY_QUEUE_MAX_S + 15 + core.worstCaseToReportS(), 'longest standstill ' .. B.maxStandNS)
end

function T.late_bus_catches_up_with_more_aggression()
  local w, B, c = scene({ from = 1, to = 41, delay = 200, stops = { { id = 'A', along = 300, side = 'r', sched = 5, dwellS = 6 } } })
  w:cmd(B, c)
  near(B.lastIssue.aggression, 0.45, 1e-9, 'catching up')
  w:run(200, function() return w:first('departed') end)
  assert(w:first('atStop').data.late > 10, 'late reported')
  local dep = w:first('departed')
  assert(dep.data.late > 10)
  w:cmd(B, { c = 'setLate', sec = 0 })
  w:run(10)
  near(B.ai.aggr, 0.3, 0.2)
end

function T.night_lights_and_status_commands()
  local w, B, c = scene({ from = 1, to = 21, night = true })
  w:cmd(B, c)
  assert(B.lights == true)
  w:cmd(B, { c = 'lights', on = false }); assert(B.lights == false)
  w:cmd(B, { c = 'status' })
  local st = w:first('status')
  assert(st and st.data.state == 'drive' and st.data.counters)
  w:cmd(B, { c = 'start', path = { 'n1' } })
  assert(w:first('rejected') and w:first('rejected').data.reason == 'path')
end

function T.abort_releases_everything()
  local w, B, c = scene({ from = 1, to = 21 })
  w:cmd(B, c)
  w:run(5)
  w:cmd(B, { c = 'abort' })
  assert(B.driver.st == 'idle' and not B.doorsReq and B.ind == nil)
  local n = #B.calls
  w:run(5)
  assert(#B.calls == n, 'an idle driver does nothing')
end

function T.hold_command_extends_the_dwell_with_a_cap()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
  w:cmd(B, c)
  w:run(100, function() return w:first('atStop') end)
  local t0 = w.t
  w:cmd(B, { c = 'hold', sec = 30 })
  w:run(20)
  assert(not w:first('departed'), 'held')
  w:cmd(B, { c = 'hold', sec = 10000 })
  w:run(200, function() return w:first('departed') end)
  assert(w:first('departed'), 'a 10000 s hold is capped to HOLD_MAX_S')
  assert(w:first('departed').t - t0 <= 20 + L.HOLD_MAX_S + 30, 'capped: ' .. (w:first('departed').t - t0))
end

function T.skip_stop_command()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
  w:cmd(B, c)
  w:cmd(B, { c = 'skipStop', id = 'A' })
  assert(w:first('skipped'))
  w:run(120, function() return w:first('done') end)
  assert(not w:first('atStop') and w:first('done'))
end

---------------------------------------------------------------------------------------------------------------------------
-- graph reloads
---------------------------------------------------------------------------------------------------------------------------
function T.graph_window_extends_and_the_path_is_reissued()
  local w, B, c = scene({ from = 1, to = 41 })
  w:setClip(15)                                           -- the graph knows only the first 15 nodes
  w:cmd(B, c)
  assert(#B.lastIssue.path == 15, 'only the known part is given to the AI')
  assert(w:run(40, function() return w:first('edge') end), 'announces that the route runs on beyond the graph')
  w:run(3)
  w:setClip(30)
  w:run(6)
  assert(B.lastIssue.path[#B.lastIssue.path] == 'n30', 'extended to the new graph: ' .. B.lastIssue.path[#B.lastIssue.path])
  assert(B.reissues >= 2)
  w:setClip(nil)
  w:run(30, function() return B.reissues >= 3 end)
  assert(B.lastIssue.path[#B.lastIssue.path] == 'n41')
end

function T.vanished_nodes_are_dropped_from_the_reissued_path()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(15)
  local before = B.reissues
  w:hide(30, true)                                        -- a node ahead vanished with the reload
  w:run(8)
  assert(B.reissues > before, 're-issued')
  local p = B.lastIssue.path
  assert(p[#p] == 'n29', 'cut before the hole: ' .. p[#p])
  assert(p[1] ~= 'n1', 'started at the node behind the bus')
  -- and comes back when the node does
  w:hide(30, false)
  w:run(35)
  assert(B.lastIssue.path[#B.lastIssue.path] == 'n41', 'extended again once near: ' .. B.lastIssue.path[#B.lastIssue.path])
  assert(B.driver.counters.stuck == 0)
end

function T.passed_nodes_that_vanish_are_ignored()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(20)
  local n = B.reissues
  w:hide(2, true); w:hide(3, true)                        -- behind us
  w:run(8)
  assert(B.reissues == n, 'no need to re-issue')
  assert(B.driver.st == 'drive')
end

function T.ai_that_left_manual_mode_is_given_its_path_again()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(10)
  local n = B.reissues
  B.ai.active = false
  w:run(8)
  assert(B.reissues > n, 'got the route again')
end

function T.graph_clip_at_the_edge_reports_offgraph_in_bounded_time()
  local w, B, c = scene({ from = 1, to = 41 })
  w:setClip(12)
  w:cmd(B, c)
  assert(w:run(120, function() return w:first('stuck') end), 'reports')
  local s = w:first('stuck')
  assert(s.data.cause == 'path_end', s.data.cause)
  assert(s.t < 60, 'quickly: ' .. s.t)
  assert(B.x < 12 * 25, 'did not leave the graph')
end

---------------------------------------------------------------------------------------------------------------------------
-- never stuck: the ladder and the traps
---------------------------------------------------------------------------------------------------------------------------
local function kinds(w, name)
  local out = {}
  for _, e in ipairs(w:ev(name)) do out[#out + 1] = e.data.name or e.data.what or e.data.cause end
  return out
end

function T.obstacle_that_can_be_passed_the_ladder_nudges_around_it()
  local w, B, c = scene({ from = 1, to = 41 })
  -- a stopped car 3 m right of the lane centre blocks the bus's own lane unless the bus moves 1.8 m left
  w:addOther({ x = 200, y = -1.5, vx = 0, len = 4.5 })
  w:cmd(B, c)
  assert(w:run(200, function() return B.x > 240 end), 'gets past')
  assert(B.maxStandNS <= L.QUEUE_MAX_S + L.RUNG_S[1] + L.RUNG_S[2] + L.RUNG_S[3] + 5, 'standstill ' .. B.maxStandNS)
  local esc = kinds(w, 'escalate')
  assert(esc[1] == 'horn_creep' and esc[2] == 'replan' and esc[3] == 'nudge', table.concat(esc, ','))
  assert(w:first('recovered'), 'recovery event')
  assert(B.driver.counters.recovered == 1 and B.horn >= 1)
  assert(not w:first('stuck'))
  -- the lateral offset is given back later
  w:run(40)
  assert(math.abs(B.latTarget) < 0.01, 'back in the lane: ' .. B.latTarget)
end

function T.road_fully_blocked_climbs_the_whole_ladder_and_reports()
  local w, B, c = scene({ from = 1, to = 41 })
  w:addOther({ x = 200, y = 0, vx = 0, len = 4.5, id = 500 })
  w:addOther({ x = 200, y = 2.2, vx = 0, len = 4.5, id = 501 })
  w:addOther({ x = 200, y = -2.2, vx = 0, len = 4.5, id = 502 })
  w:addOther({ x = 200, y = 4.4, vx = 0, len = 4.5, id = 503 })
  w:addOther({ x = 200, y = -4.4, vx = 0, len = 4.5, id = 504 })
  w:cmd(B, c)
  assert(w:run(300, function() return w:first('stuck') end), 'reports in bounded time')
  local s = w:first('stuck')
  assert(s.data.cause == 'obstacle', s.data.cause)
  assert(s.t <= L.QUEUE_MAX_S + 25 + core.worstCaseToReportS(), 'report time ' .. s.t)
  local esc = kinds(w, 'escalate')
  assert(esc[1] == 'horn_creep' and esc[2] == 'replan' and esc[3] == 'nudge' and esc[4] == 'reverse' and esc[5] == 'skip_or_reroute', table.concat(esc, ','))
  assert(w:first('reroute') and w:first('reroute').data.blocked[1], 'asked the GE for another path')
  assert(s.data.x and s.data.along and s.data.node and s.data.count == 1)
  assert(B.driver.counters.stuck >= 1 and B.driver.counters.reports == 1)
end

function T.reroute_answer_gets_the_bus_going()
  local w, B, c = scene({ from = 1, to = 41 })
  local blocker = w:addOther({ x = 200, y = 0, vx = 0, len = 4.5 })
  w:addOther({ x = 200, y = 2.2, vx = 0, len = 4.5 }); w:addOther({ x = 200, y = -2.2, vx = 0, len = 4.5 })
  w:addOther({ x = 200, y = 4.4, vx = 0, len = 4.5 }); w:addOther({ x = 200, y = -4.4, vx = 0, len = 4.5 })
  w:cmd(B, c)
  assert(w:run(300, function() return w:first('reroute') end))
  -- the GE answers with a path whose blocker was removed (here: the blockers vanish)
  w.others = {}
  local names, pts = w:route(1, 41)
  w:cmd(B, { c = 'setPath', path = names, pts = pts })
  assert(w:run(100, function() return B.x > 260 end), 'moving again')
  assert(B.maxStandNS < 120)
end

function T.final_guarantee_is_finite_after_max_reports_the_driver_gives_up()
  local w, B, c = scene({ from = 1, to = 41 })
  for i = -3, 3 do w:addOther({ x = 200, y = i * 2.2, vx = 0, len = 4.5, id = 600 + i }) end
  w:cmd(B, c)
  local total = L.MAX_STUCK_S + core.worstCaseToReportS() + L.MAX_REPORTS * (core.worstCaseToReportS() + L.REPORT_COOLDOWN_S) + 100
  assert(w:run(total + 400, function() return w:first('failed') end), 'gives up in bounded time')
  assert(#w:ev('stuck') == L.MAX_REPORTS, 'one report per cycle: ' .. #w:ev('stuck'))
  assert(B.driver.st == 'failed')
  -- reports are at least REPORT_COOLDOWN apart
  local ts = w:ev('stuck')
  for i = 2, #ts do assert(ts[i].t - ts[i - 1].t >= L.REPORT_COOLDOWN_S, 'rate limit') end
end

function T.relocate_after_the_ge_teleported_the_bus_resets_the_stall()
  local w, B, c = scene({ from = 1, to = 41 })
  for i = -3, 3 do w:addOther({ x = 200, y = i * 2.2, vx = 0, len = 4.5, id = 600 + i }) end
  w:cmd(B, c)
  w:run(300, function() return w:first('stuck') end)
  assert(w:first('stuck'))
  B.x = 260; B.v = 0                                      -- fleet teleported the bus past the blockade
  w:cmd(B, { c = 'relocate' })
  assert(w:run(60, function() return B.x > 300 end), 'drives on')
  assert(B.driver.lad.rung == 0)
end

function T.deadlock_two_buses_facing_each_other_on_a_single_lane()
  local w = W.new({ nodes = 41 })
  local A = w:addBus({ id = 1, dir = 1, x = 400 })
  local B = w:addBus({ id = 2, dir = -1, x = 560 })
  local na, pa = w:route(17, 41)
  local nb, pb = w:route(41, 17)
  w:cmd(A, { c = 'start', path = na, pts = pa })
  w:cmd(B, { c = 'start', path = nb, pts = pb })
  local passed = w:run(300, function() return A.x > 990 and B.x < 405 end)
  assert(passed, 'both get through: A=' .. A.x .. ' B=' .. B.x)
  assert(not w:first('stuck'), 'no report needed')
  local limit = L.DEADLOCK_WAIT_S + L.RUNG_S[1] + L.RUNG_S[2] + L.RUNG_S[3] + 5
  assert(A.maxStandNS <= limit + 10 and B.maxStandNS <= limit + 10, 'standstills ' .. A.maxStandNS .. ' / ' .. B.maxStandNS)
  assert(A.driver.counters.stuck + B.driver.counters.stuck >= 1)
end

function T.doors_that_never_open_are_retried_then_the_trip_goes_on()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
  B.jamOpen = true
  w:cmd(B, c)
  assert(w:run(200, function() return w:first('departed') end), 'departs although the doors would not open')
  local f = w:first('doorfault')
  assert(f and f.data.what == 'open')
  local at = w:first('atStop')
  assert(at and at.data.fault == true)
  local openCalls = 0
  for _, cl in ipairs(B.calls) do if cl == 'doorsOpen' then openCalls = openCalls + 1 end end
  assert(openCalls == L.DOOR_RETRIES + 1, 'retried: ' .. openCalls)
  assert(w:first('departed').t - at.t < L.DWELL_MAX_S)
end

function T.doors_that_never_close_do_not_hold_the_bus_for_ever()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
  B.jamClose = true
  w:cmd(B, c)
  w:run(400, function() return w:first('departed') or w:first('stuck') end)
  local f = w:ev('doorfault')
  assert(#f >= 1 and f[1].data.what == 'close')
  assert(w:first('departed') or w:first('stuck'), 'decided one way or the other')
  assert(w.t < 100 + 3 * L.DOOR_TIMEOUT_S + 60 + core.worstCaseToReportS(), 'bounded ' .. w.t)
end

function T.flipped_bus_is_reported_quickly()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(10)
  B.up = 0.05
  assert(w:run(10, function() return w:first('flipped') end))
  assert(w:first('flipped').t - 10 <= L.FLIP_S + 1)
  assert(B.driver.st == 'failed')
  -- a start command revives the driver (respawned bus)
  B.up = 1
  w:cmd(B, c)
  assert(B.driver.st == 'drive')
end

function T.missing_ground_reports_offgraph()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(5)
  B.ground = false
  assert(w:run(10, function() return w:first('offgraph') end))
  assert(w:first('offgraph').data.cause == 'noground')
end

function T.damaged_bus_that_does_not_respond_reports_no_response()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(10)
  B.dead = true                                            -- throttle commanded, nothing happens
  assert(w:run(400, function() return w:first('stuck') end), 'reports')
  local s = w:first('stuck')
  assert(s.data.cause == 'no_response', s.data.cause)
  assert(s.t - 10 <= L.MAX_STUCK_S + core.worstCaseToReportS() + 20, 'bounded: ' .. s.t)
end

function T.queue_behind_a_car_at_a_red_light_is_not_a_stall()
  local w, B, c = scene({ from = 1, to = 41 })
  w:addSignal(15, 16, 362, function(t) return t < 70 and 2 or 0 end)
  -- a car waits at the line; it leaves on green
  w:addOther({ x = 360, vx = 0, len = 4.5, update = function(o, t, dt)
    if t > 70 then o.vx = math.min(10, o.vx + 2 * dt) end
    o.x = o.x + o.vx * dt
  end })
  w:cmd(B, c)
  assert(w:run(150, function() return B.x > 400 end), 'goes with the queue')
  assert(B.driver.counters.stuck == 0, 'waiting in the queue at a red light is legitimate')
  assert(not w:first('escalate'))
end

function T.slow_car_ahead_is_not_a_stall()
  local w, B, c = scene({ from = 1, to = 41 })
  w:addOther({ x = 60, vx = 3, len = 4.5 })               -- a tractor
  w:cmd(B, c)
  assert(w:run(600, function() return w:first('done') end), 'follows to the end of the road')
  assert(B.driver.counters.stuck == 0)
end

function T.off_the_route_far_triggers_a_replan()
  local w, B, c = scene({ from = 1, to = 41 })
  w:cmd(B, c)
  w:run(10)
  B.lat = 40; B.latTarget = 40                            -- thrown aside by a crash
  local n = B.reissues
  w:run(L.OFFROUTE_S + 3)
  assert(B.reissues > n, 'replanned')
  assert(w:ev('escalate')[1].data.cause == 'off_route')
end

function T.bus_facing_the_wrong_way_replans_then_reports_wrong_way()
  local w = W.new({})
  local B = w:addBus({ x = 300, dir = -1 })              -- faces west, the route runs east
  local names, pts = w:route(1, 41)
  w:cmd(B, { c = 'start', path = names, pts = pts })
  assert(w:run(300, function() return w:first('stuck') end), 'reports')
  assert(w:first('stuck').data.cause == 'wrong_way', w:first('stuck').data.cause)
  assert(w:ev('escalate')[1].data.name == 'replan', 'a re-plan is the first attempt')
  assert(w:first('stuck').t <= L.MAX_STUCK_S + core.worstCaseToReportS() + 5)
end

function T.joining_the_route_mid_way_drops_the_stops_behind()
  local w, B, c = scene({ from = 1, to = 41, x = 305, stops = { { id = 'A', along = 100, side = 'r', dwellS = 6 }, { id = 'B', along = 600, side = 'r', dwellS = 6 } } })
  w:cmd(B, c)
  assert(#w:ev('skipped') == 0, 'silently')
  assert(w:run(100, function() return w:first('atStop') end))
  assert(w:first('atStop').data.id == 'B')
end

function T.ground_check_can_be_switched_off()
  local w, B, c = scene({ from = 1, to = 41, cfg = { groundCheck = false } })
  w:cmd(B, c)
  B.ground = false
  w:run(10)
  assert(not w:first('offgraph'))
end

function T.stuck_counters_by_cause()
  local w, B, c = scene({ from = 1, to = 41 })
  w:addOther({ x = 200, y = -1.5, vx = 0, len = 4.5 })
  w:cmd(B, c)
  w:run(200, function() return B.x > 240 end)
  local cn = B.driver.counters
  assert(cn.stuck == 1 and cn.byCause.obstacle == 1 and cn.recovered == 1, 'counted per cause')
  assert(cn.rungs[1] == 1 and cn.rungs[3] == 1, 'per rung')
end

function T.fallback_strategies_still_stop_at_a_red_light_and_a_bay()
  for _, strat in ipairs({ 'stoppoint', 'routespeed0' }) do
    local w, B, c = scene({ from = 1, to = 41, cfg = { strategy = strat },
      stops = { { id = 'A', along = 300, side = 'r', dwellS = 6 } } })
    w:addSignal(7, 8, 162, function(t) return t < 35 and 2 or 0 end)
    w:cmd(B, c)
    local crossed = false
    w:run(34, function() if B.x > 162.5 then crossed = true end end)
    assert(not crossed, strat .. ': red respected')
    assert(w:run(150, function() return w:first('atStop') end), strat .. ': serves the stop')
    assert(math.abs(B.x - 302) < 27, strat .. ': stop within a segment: ' .. B.x)
  end
end

function T.set_path_keeps_served_stops()
  local w, B, c = scene({ from = 1, to = 41, stops = { { id = 'A', along = 150, side = 'r', dwellS = 6 }, { id = 'B', along = 600, side = 'r', dwellS = 6 } } })
  w:cmd(B, c)
  w:run(100, function() return w:first('departed') end)
  local names, pts = w:route(1, 41)
  w:cmd(B, { c = 'setPath', path = names, pts = pts, stops = { { id = 'A', along = 150, side = 'r', dwellS = 6 }, { id = 'B', along = 600, side = 'r', dwellS = 6 } } })
  w:run(200, function() return #w:ev('atStop') >= 2 end)
  assert(#w:ev('atStop') == 2, 'A is not served twice: ' .. #w:ev('atStop'))
end

function T.every_scenario_with_a_blocked_road_ends_in_a_known_outcome()
  -- the matrix of the user's requirement: whatever blocks the bus, it ends 'moving again', 'skipped' or 'reported'
  local cases = {
    { name = 'parked car in the lane', setup = function(w) w:addOther({ x = 200, y = -1.0, vx = 0 }) end },
    { name = 'oncoming car stopped', setup = function(w) w:addOther({ x = 200, y = 0, vx = 0, dx = -1 }) end },
    { name = 'bay car', stops = { { id = 'A', along = 200, side = 'r', dwellS = 5 } }, setup = function(w) w:addOther({ x = 202, y = 0, vx = 0 }) end },
  }
  for _, cs in ipairs(cases) do
    local w, B, c = scene({ from = 1, to = 41, stops = cs.stops })
    cs.setup(w)
    w:cmd(B, c)
    local ok = w:run(500, function() return B.x > 260 or w:first('stuck') end)
    assert(ok, cs.name .. ': no outcome')
    assert(B.x > 260 or w:first('stuck') or w:first('skipped'), cs.name .. ' outcome')
    assert(B.maxStandNS <= L.BAY_QUEUE_MAX_S + 15 + L.QUEUE_MAX_S + core.worstCaseToReportS(), cs.name .. ' standstill ' .. B.maxStandNS)
  end
end

return T
