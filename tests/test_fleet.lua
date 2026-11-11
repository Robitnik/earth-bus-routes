-- Plan 007 T4/T5: the AI fleet (fleet.lua) with a fake world and a fake driver, the live transfers of connections.lua, the shared
-- stops of demand.lua and the fleet's wiring in main.lua (fleetrun.lua).
local H = dofile('tests/harness.lua')
local busnet = require('earthBusRoutes/busnet')
local fleet = require('earthBusRoutes/fleet')
local demand = require('earthBusRoutes/demand')
local geo = require('earthBusRoutes/geomath')
local T = {}

-- ---- a straight road along x (game metres), 25 m between nodes, and lines driving it ----------------------------------------------
local O = { 50.0, 16.0 }
local RE = 6371008.8
local function ll(x, y) return O[1] + math.deg(y / RE), O[2] + math.deg(x / (RE * math.cos(math.rad(O[1])))) end
local function toGame(lat, lon) local x, y = geo.toXY(O[1], O[2], lat, lon) return x, y, 0 end

local function roadGraph(x0, x1, extra)
  local g = {}
  local names = {}
  local k = 0
  for x = x0, x1, 25 do
    k = k + 1
    local nm = 'N' .. math.floor(x / 25)
    g[nm] = { pos = { x = x, y = 0, z = 0 }, radius = 4, links = {} }
    names[#names + 1] = nm
  end
  for i = 2, #names do
    local e = { oneWay = false, inNode = names[i - 1], outNode = names[i], drivability = 1 }
    g[names[i - 1]].links[names[i]] = e
    g[names[i]].links[names[i - 1]] = e
  end
  return g
end

-- a line along the road: stops at the given x's (platform 6 m right of the road)
local function line(id, ref, xs, len)
  local path, cum = {}, { 0 }
  local lenM = len or 3000
  for x = 0, lenM, 25 do
    local lat, lon = ll(x, 0)
    path[#path + 1] = { lat = lat, lon = lon }
  end
  cum = geo.cumulative(path)
  local stops = {}
  for i, x in ipairs(xs) do
    local lat, lon = ll(x, -6)
    stops[i] = { id = id * 100 + i, name = ref .. '-S' .. i, lat = lat, lon = lon, along = x }
  end
  return { id = id, ref = ref, colour = '#336699', path = path, cum = cum, stops = stops, from = stops[1].name, to = stops[#stops].name,
    length = lenM }
end

-- the timetable of a bus at 10 m/s with 20 s at each stop: arr, dep (s after the start)
local function timetable(r)
  local arr, dep = {}, {}
  for i, s in ipairs(r.stops) do
    arr[i] = i == 1 and 0 or dep[i - 1] + (s.along - r.stops[i - 1].along) / 10
    dep[i] = arr[i] + 20
  end
  return arr, dep
end

-- the start time that has the bus `x` metres along at clock `clock`
local function startFor(r, arr, dep, x, clock)
  for i = 1, #r.stops - 1 do
    local a, b = r.stops[i].along, r.stops[i + 1].along
    if x >= a and x <= b then return clock - (dep[i] + (x - a) / (b - a) * (arr[i + 1] - dep[i])) end
  end
  return clock
end

local LINE_A = { 1, '305', { 200, 800, 1400, 2000, 2600 } }
local LINE_B = { 2, '360', { 300, 900, 1700, 2300 } }

-- the fake world. o.trips = { { line = LINE_A, x = 500 } ... } (where each bus is at the start), o.n = pool size, o.gx = {x0, x1} graph
local function world(o)
  o = o or {}
  H.reset()
  demand.book = demand.newBook()
  local W = { clock = 8 * 3600 + 30, veh = {}, nextId = 100, sent = {}, placed = {}, hidden = {}, removed = {}, loaded = {}, logs = {},
    vis = function() return false end, answer = true, drvState = 'drive', routes = {}, spawnFail = false, graphSigN = 1 }
  local plat, plon = ll(o.px or 1500, 0)
  W.player = { x = o.px or 1500, y = 0, z = 0, lat = plat, lon = plon, speed = 0 }
  W.graph = roadGraph(o.gx and o.gx[1] or 0, o.gx and o.gx[2] or 3000)
  W.net = busnet.new({ day = 2 })
  local lines = {}
  for _, spec in ipairs(o.lines or { LINE_A, LINE_B }) do
    lines[spec[2]] = line(spec[1], spec[2], spec[3], o.len)
    W.routes[spec[2]] = lines[spec[2]]
  end
  W.lines = lines
  for _, tt in ipairs(o.trips or { { line = LINE_A, x = 500 } }) do
    local r = lines[tt.line[2]]
    local arr, dep = timetable(r)
    local start = startFor(r, arr, dep, tt.x, W.clock)
    if tt.start then start = tt.start end
    busnet.addLine(W.net, r, { clock = W.clock, day = 2, trips = { { start = start, arr = arr, dep = dep } } })
  end
  busnet.update(W.net, W.clock)
  local env = {
    net = function() return W.net end, clock = function() return W.clock end,
    graph = function() return W.graph end, graphSig = function() return W.graphSigN end, toGame = toGame,
    player = function() return W.player end, visible = function(x, y, z) return W.vis(x, y, z) end,
    playerTrip = function() return W.playerTrip end, playerNext = function() return W.playerNext end,
    spawn = function()
      if W.spawnFail then return nil end
      local id = W.nextId
      W.nextId = id + 1
      W.veh[id] = { alive = true, x = 0, y = 0, z = 400, active = false }
      W.created = (W.created or 0) + 1
      return id
    end,
    place = function(id, pose, fresh)
      local v = W.veh[id]
      if not v then return false end
      v.x, v.y, v.z, v.active = pose.x, pose.y, pose.z, true
      W.placed[#W.placed + 1] = { id = id, pose = pose, clock = W.clock, vis = W.vis(pose.x, pose.y, pose.z) }
      return true
    end,
    hide = function(id) local v = W.veh[id] if v then v.active = false end W.hidden[#W.hidden + 1] = id end,
    remove = function(id) local v = W.veh[id] if v then v.alive = false end W.removed[#W.removed + 1] = id end,
    alive = function(id) return W.veh[id] ~= nil and W.veh[id].alive end,
    pos = function(id) local v = W.veh[id] if v and v.alive then return v.x, v.y, v.z end end,
    load = function(id) W.loaded[#W.loaded + 1] = id end,
    send = function(id, cmd)
      W.sent[#W.sent + 1] = { id = id, cmd = cmd, clock = W.clock }
      local fl = W.fl
      if W.answer and fl then
        if cmd.c == 'status' then fleet.onEvent(fl, id, 'status', { state = W.drvState, rung = 0, late = W.late }) end
        if cmd.c == 'start' then fleet.onEvent(fl, id, 'ready', { n = #cmd.path, stops = #cmd.stops }) end
      end
      return true
    end,
    density = function() return 'normal' end, night = function() return false end,
    log = function(level, text) W.logs[#W.logs + 1] = level .. ' ' .. text end,
  }
  W.env = env
  W.fl = fleet.new(env, { n = o.n or 2 })
  return W
end

-- seconds of game: the net moves with the clock (as busnetrun does), the fleet runs a frame per second
local function step(W, secs, each)
  for _ = 1, secs do
    W.clock = W.clock + 1
    busnet.update(W.net, W.clock)
    fleet.frame(W.fl, 1)
    if each then each(W) end
  end
end

local function busySlots(W)
  local out = {}
  for _, b in ipairs(W.fl.slots) do if b.state == 'busy' then out[#out + 1] = b end end
  return out
end

local function sentOf(W, name, id)
  local out = {}
  for _, s in ipairs(W.sent) do if s.cmd.c == name and (not id or s.id == id) then out[#out + 1] = s end end
  return out
end

local function trip(W, ref) return W.net.lines[ref == '305' and 1 or 2].trips[1] end

-- the one bus: spawn it (the trip of line 305 comes to the player), return its slot
local function spawned(W)
  step(W, 140)
  local list = busySlots(W)
  assert(#list >= 1, 'a bus was made physical')
  return list[1]
end

local function moveTo(W, b, x, y) local v = W.veh[b.id] v.x, v.y = x, y or 0 end

-- ---- selection and spawning -------------------------------------------------------------------------------------------------------------

function T.a_trip_that_comes_near_becomes_a_physical_bus_with_a_driver_command()
  local W = world()
  step(W, 60)
  assert(#busySlots(W) == 0, 'the bus is still far: nothing physical')
  local b = spawned(W)
  local tr = trip(W, '305')
  assert(tr.physical == true, 'the net does not draw it twice')
  local starts = sentOf(W, 'start', b.id)
  assert(#starts == 1, 'one start command')
  local c = starts[1].cmd
  assert(#c.path >= 2 and #c.pts == #c.path and c.pts[1][1] and c.clock and c.delaySec == 0)
  assert(#c.stops >= 2, 'the stops ahead are in the command')
  local last = c.stops[#c.stops]
  assert(last.id == 5 and last.terminus == true and last.side == 'r' and last.sched == tr.start + tr.dep[5], 'terminus stop with its time')
  for i = 2, #c.stops do assert(c.stops[i].along > c.stops[i - 1].along) end
  assert(c.stops[1].id >= 3, 'the stops behind it are not sent')
  assert(W.loaded[1] == b.id, 'the driver extension is loaded')
  assert(W.placed[1].vis == false, 'put down out of sight')
  local pl = W.placed[1].pose
  assert(math.abs(pl.x - W.player.x) >= fleet.NEAR_PLAYER_M, 'not on the player')
  assert(fleet.stats(W.fl).physical == 1 and fleet.stats(W.fl).started == 1)
  local buses = busnet.buses(W.net, {})
  for _, x in ipairs(buses) do assert(x.key ~= tr.key, 'the map does not draw the physical bus') end
end

function T.a_bus_is_never_put_down_where_the_player_looks_or_stands()
  local W = world()
  W.vis = function() return true end
  step(W, 100)
  assert(#busySlots(W) == 0 and #W.placed == 0, 'everything is in sight: nothing is placed')
  assert((fleet.stats(W.fl).byCause.spawn_visible or 0) > 0, 'counted')
  -- only the part of the road behind the player's back is out of sight
  W.vis = function(x) return x > 1250 end
  step(W, 6)
  local b = busySlots(W)[1]
  assert(b, 'now it can be placed')
  assert(W.placed[1].pose.x <= 1250, 'at a spot out of sight: ' .. W.placed[1].pose.x)
  -- not on top of the player either
  local W2 = world({ px = 1100 })
  step(W2, 150)
  for _, p in ipairs(W2.placed) do assert(math.abs(p.pose.x - 1100) >= fleet.NEAR_PLAYER_M, 'near player: ' .. p.pose.x) end
end

function T.the_player_own_trip_is_never_served_by_the_ai()
  local W = world()
  local tr = trip(W, '305')
  W.playerTrip = { routeId = 1, start = tr.start }
  step(W, 160)
  assert(#busySlots(W) == 0, 'the player drives that trip himself')
  -- another trip of the same line (an hour later) is not his: it is served
  local W2 = world()
  W2.playerTrip = { routeId = 1, start = trip(W2, '305').start + 3600 }
  step(W2, 140)
  assert(#busySlots(W2) == 1, 'a different trip of the line is served')
  -- a trip of another line is not his either
  local W3 = world()
  W3.playerTrip = { routeId = 2, start = trip(W3, '305').start }
  step(W3, 140)
  assert(#busySlots(W3) == 1)
end

function T.the_pool_never_has_more_than_n_buses_and_n_physical()
  local W = world({ n = 2, trips = { { line = LINE_A, x = 900 }, { line = LINE_B, x = 1000 }, { line = LINE_A, x = 700, start = nil } } })
  -- two more trips of line A, behind the first ones
  local r = W.lines['305']
  local arr, dep = timetable(r)
  busnet.addLine(W.net, r, { clock = W.clock, day = 2, trips = { { start = startFor(r, arr, dep, 900, W.clock) , arr = arr, dep = dep },
    { start = startFor(r, arr, dep, 900, W.clock) - 15, arr = arr, dep = dep }, { start = startFor(r, arr, dep, 900, W.clock) - 30, arr = arr, dep = dep } } })
  busnet.update(W.net, W.clock)
  local maxBusy = 0
  step(W, 200, function()
    local n = #busySlots(W)
    if n > maxBusy then maxBusy = n end
    assert(#W.fl.slots <= 2, 'the pool never grows past n')
  end)
  assert(maxBusy >= 1 and maxBusy <= 2, 'at most n buses are physical: ' .. maxBusy)
  assert(W.created == 2, 'two vehicles were made, no more: ' .. tostring(W.created))
  -- the option goes down: the pool shrinks, a busy bus goes when nobody sees it
  fleet.setLimit(W.fl, 1)
  step(W, 5)
  assert(#W.fl.slots <= 1, 'the pool shrank')
  fleet.setLimit(W.fl, 0)
  step(W, 3)
  assert(#W.fl.slots == 0 and #busySlots(W) == 0, 'off: everything put away')
  for _, tr in ipairs(W.net.lines[1].trips) do assert(not tr.physical, 'no trip stays physical when the fleet is off') end
end

function T.priority_transfer_then_the_buses_to_the_players_next_stop_then_the_rest()
  local function run(setup)
    local W = world({ n = 1, trips = { { line = LINE_A, x = 1300 }, { line = LINE_B, x = 1560 } } })
    -- (line B's bus is nearer to the player than line A's)
    setup(W)
    step(W, 6)
    local b = busySlots(W)[1]
    assert(b, 'one bus')
    return W, b.trip.line.ref
  end
  local _, plain = run(function() end)
  assert(plain == '360', 'the nearer bus first without any wish: ' .. plain)
  local W2, next2 = run(function(W)
    local s = W.lines['305'].stops[3]
    W.playerNext = { lat = s.lat, lon = s.lon, name = s.name }
  end)
  assert(next2 == '305', 'the bus that calls at the stop the player goes to next comes first: ' .. next2)
  local W3, tr3 = run(function(W)
    local s = W.lines['305'].stops[3]
    W.playerNext = { lat = s.lat, lon = s.lon, name = s.name }
    local hub = W.lines['360'].stops[3]
    local trB = W.net.lines[2].trips[1]
    local token = fleet.requestTransfer(W.fl, { ref = '360', at = trB.start + trB.arr[3], stop = { lat = hub.lat, lon = hub.lon, name = hub.name } })
    assert(token, 'the transfer is known to the fleet')
  end)
  assert(tr3 == '360', 'a live transfer beats the rest: ' .. tr3)
end

function T.a_slot_is_kept_for_a_higher_priority_trip_that_is_about_to_come()
  -- one free slot; line B's bus (priority 2: the player goes to its stop) is still 700 m away and comes within 90 s; line A's bus is here now
  local W = world({ n = 1, trips = { { line = LINE_A, x = 1400 }, { line = LINE_B, x = 1000 } } })
  local s = W.lines['360'].stops[3]
  W.playerNext = { lat = s.lat, lon = s.lon, name = s.name }
  step(W, 3)
  assert(#busySlots(W) == 0, 'the slot waits for the bus the player is going to meet')
  step(W, 40)
  local b = busySlots(W)[1]
  assert(b and b.trip.line.ref == '360', 'it took the slot when it came')
end

-- ---- handing back ---------------------------------------------------------------------------------------------------------------------------

function T.a_bus_that_leaves_the_window_goes_back_to_the_net_with_its_measured_delay()
  local W = world()
  local b = spawned(W)
  local tr = trip(W, '305')
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 1, id = 3, late = 75, fault = false })
  fleet.onEvent(W.fl, b.id, 'departed', { i = 1, id = 3, late = 80 })
  assert(tr.delay == 80 and tr.physical, 'the delay follows the bus while it is physical')
  moveTo(W, b, 2400)                                          -- 900 m from the player
  step(W, 2)
  assert(#busySlots(W) == 0, 'given back')
  assert(tr.physical == false and tr.delay == 80, 'the net has the trip again, 80 s late')
  assert(W.veh[b.id].active == false and #sentOf(W, 'abort') >= 1, 'hidden, driver told to stop')
  assert(#W.fl.slots == 2, 'the vehicle stays in the pool')
  step(W, 20)
  assert(#busySlots(W) == 0, 'not made physical again at once (the cool-down)')
end

function T.a_bus_in_sight_stays_until_the_player_looks_away_or_it_is_far_beyond_the_window()
  local W = world()
  local b = spawned(W)
  W.vis = function() return true end
  moveTo(W, b, 2000)                                          -- 500 m: out of the window, but seen
  step(W, 5)
  assert(#busySlots(W) == 1, 'seen: it stays')
  W.vis = function() return false end
  step(W, 2)
  assert(#busySlots(W) == 0, 'out of sight: given back')
  local W2 = world()
  local b2 = spawned(W2)
  W2.vis = function() return true end
  moveTo(W2, b2, 2300)                                        -- 800 m: no ground out there
  step(W2, 2)
  assert(#busySlots(W2) == 0 and (fleet.stats(W2.fl).byCause.left_window_hard or 0) == 1)
end

function T.a_finished_trip_goes_back_when_nobody_sees_the_bus()
  local W = world()
  local b = spawned(W)
  fleet.onEvent(W.fl, b.id, 'done', { late = 20 })
  W.vis = function() return true end
  step(W, 12)
  assert(#busySlots(W) == 1, 'in sight at the terminus: it waits')
  W.vis = function() return false end
  step(W, 2)
  assert(#busySlots(W) == 0)
  assert((fleet.stats(W.fl).byCause.finished or 0) == 1)
  assert(trip(W, '305').delay == 20)
end

function T.the_events_of_the_driver_update_stops_served_and_the_shared_crowd()
  local W = world()
  demand.book.active = true
  local b = spawned(W)
  local before = W.fl.counters.events.atStop
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 1, id = 3, late = 0 })
  assert(b.served[3] == true and b.dwell == true and b.dwellIdx == 3)
  assert(W.fl.counters.events.atStop == (before or 0) + 1)
  fleet.onEvent(W.fl, b.id, 'skipped', { i = 2, id = 4, cause = 'blocked' })
  assert(b.served[4] == true)
  fleet.onEvent(W.fl, 9999, 'atStop', { id = 1 })              -- a stranger: ignored
  fleet.onEvent(W.fl, b.id, 'nonsense', {})
  fleet.onEvent(W.fl, b.id, 'signal_timeout', { what = 'red' })
  assert((fleet.stats(W.fl).byCause.signal_timeout_red or 0) == 1)
end

-- ---- the guarantee: every report of the driver is answered ------------------------------------------------------------------

local function placedCount(W) return #W.placed end

function T.stuck_out_of_sight_teleports_the_bus_onto_the_path_ahead_and_restarts_the_driver()
  local W = world()
  local b = spawned(W)
  local n0, a0 = placedCount(W), b.along
  fleet.onEvent(W.fl, b.id, 'stuck', { cause = 'deadlock', rung = 6, count = 1 })
  assert(placedCount(W) == n0 + 1, 'teleported at once: the player does not see it')
  assert(b.along > a0 + 20, 'ahead on the path')
  assert(W.placed[#W.placed].vis == false, 'to a spot out of sight')
  local st = sentOf(W, 'start', b.id)
  assert(#st == 2, 'the driver is started again from there')
  assert(fleet.stats(W.fl).stuck == 1 and fleet.stats(W.fl).relocated == 1 and (fleet.stats(W.fl).byCause.cause_deadlock or 0) == 1)
  assert(b.trouble == nil)
end

function T.stuck_in_sight_waits_for_the_player_to_look_away_then_moves_or_is_forced_after_three_times_the_wait()
  local W = world()
  local b = spawned(W)
  W.vis = function(x, y, z) return math.abs(x - W.veh[b.id].x) < 5 end      -- he sees the bus where it stands, not the road ahead
  local n0 = placedCount(W)
  fleet.onEvent(W.fl, b.id, 'stuck', { cause = 'obstacle', rung = 6, count = 1 })
  step(W, 100)
  assert(placedCount(W) == n0, 'seen: not touched for 100 s')
  W.vis = function() return false end
  step(W, 2)
  assert(placedCount(W) == n0 + 1, 'he looked away: it moved')
  -- in sight for good (everything is visible): after 3 x 60 s the bus is put away (never teleported where he can see it)
  local W2 = world()
  local b2 = spawned(W2)
  W2.vis = function() return true end
  fleet.onEvent(W2.fl, b2.id, 'stuck', { cause = 'obstacle', rung = 6, count = 1 })
  step(W2, 170)
  assert(#busySlots(W2) == 1, 'still there before 180 s')
  step(W2, 15)
  assert(#busySlots(W2) == 0 and (fleet.stats(W2.fl).byCause.no_spot or 0) == 1, 'forced after 3 x the wait')
  assert(trip(W2, '305').physical == false, 'the trip goes on virtually')
  for _, p in ipairs(W2.placed) do assert(p.vis == false or p.clock <= W2.clock, 'never placed in sight') end
end

function T.a_bus_that_keeps_getting_stuck_is_taken_out_of_the_pool_for_the_trip()
  local W = world()
  local b = spawned(W)
  for i = 1, fleet.MAX_RELOCATES do
    fleet.onEvent(W.fl, b.id, 'stuck', { cause = 'obstacle' })
    assert(#busySlots(W) == 1, 'relocated ' .. i)
    b.trouble = nil
  end
  fleet.onEvent(W.fl, b.id, 'stuck', { cause = 'obstacle' })
  assert(#busySlots(W) == 0 and (fleet.stats(W.fl).byCause.gave_up or 0) == 1, 'given up')
  local tr = trip(W, '305')
  assert(tr.physical == false)
  step(W, 60)
  assert(#busySlots(W) == 0, 'cool-down: not made physical again at once')
end

function T.flipped_offgraph_and_failed_buses_are_put_back_on_the_road()
  for _, ev in ipairs({ { 'flipped', {} }, { 'offgraph', { cause = 'noground' } }, { 'failed', { cause = 'obstacle' } } }) do
    local W = world()
    local b = spawned(W)
    local n0 = placedCount(W)
    fleet.onEvent(W.fl, b.id, ev[1], ev[2])
    assert(placedCount(W) == n0 + 1, ev[1] .. ': respawned on a safe spot')
    assert(W.placed[#W.placed].vis == false)
    assert((fleet.stats(W.fl).byCause['trouble_' .. ev[1]] or 0) == 1, ev[1] .. ' counted')
    -- seen: waits only HARD_WAIT_S x 3
    local W2 = world()
    local b2 = spawned(W2)
    W2.vis = function() return true end
    local m0 = placedCount(W2)
    fleet.onEvent(W2.fl, b2.id, ev[1], ev[2])
    step(W2, 40)
    assert(placedCount(W2) == m0 and #busySlots(W2) == 1, ev[1] .. ' in sight: waits')
    step(W2, 10)
    assert(#busySlots(W2) == 0, ev[1] .. ' in sight for 45 s: put away')
  end
end

-- a detour round the 100 m of road at x = 1000 .. 1100 (the nodes N40 .. N44)
local function withBypass(W)
  local g = W.graph
  local function node(n, x, y) g[n] = { pos = { x = x, y = y, z = 0 }, radius = 4, links = {} } end
  local function link(a, b) local e = { oneWay = false, inNode = a, outNode = b, drivability = 1 } g[a].links[b] = e g[b].links[a] = e end
  node('D1', 1000, 14) node('D2', 1050, 22) node('D3', 1100, 14)
  link('N39', 'D1') link('D1', 'D2') link('D2', 'D3') link('D3', 'N45')
  g.N39 = g.N39 and g.N39 or nil
end

function T.a_reroute_report_gets_a_new_path_round_the_blocked_edge()
  local W = world({ trips = { { line = LINE_A, x = 500 } } })
  withBypass(W)
  W.graphSigN = 2
  W.fl.ix = nil
  step(W, 140)
  local b = busySlots(W)[1]
  assert(b, 'bus')
  -- the bus stands before the blocked edge N41-N42 (it is spawned at x >= 1100 on this road; put it back for the test)
  moveTo(W, b, 950)
  b.along = 950
  local n0 = #sentOf(W, 'setPath')
  fleet.onEvent(W.fl, b.id, 'reroute', { cause = 'blocked', from = 'N40', blocked = { 'N41', 'N42' }, along = 950 })
  local sp = sentOf(W, 'setPath', b.id)
  assert(#sp == n0 + 1, 'the new path is sent (rerouted ' .. tostring(fleet.stats(W.fl).byCause.rerouted) .. ', trouble ' .. tostring(b.trouble and b.trouble.cause) .. ')')
  local used = {}
  for _, nm in ipairs(sp[#sp].cmd.path) do used[nm] = true end
  assert(used.D1 and used.D2 and used.D3, 'through the bypass')
  assert(not (used.N41 and used.N42), 'not over the blocked edge')
end

function T.a_detour_that_has_to_turn_round_is_not_sent_the_bus_is_teleported_instead()
  local W = world({ trips = { { line = LINE_A, x = 500 } } })
  withBypass(W)
  W.graphSigN = 2
  W.fl.ix = nil
  step(W, 140)
  local b = busySlots(W)[1]
  moveTo(W, b, 1030)                                           -- already past the bypass's entry (N39): it would have to turn round
  b.along = 1030
  local n0 = placedCount(W)
  fleet.onEvent(W.fl, b.id, 'reroute', { cause = 'blocked', blocked = { 'N41', 'N42' }, along = 1030 })
  assert(#sentOf(W, 'setPath', b.id) == 0, 'no path that turns round')
  assert(placedCount(W) == n0 + 1 and (fleet.stats(W.fl).byCause.reroute_failed or 0) == 1, 'put on the road ahead instead')
end

function T.a_reroute_that_cannot_be_made_is_a_stuck_bus_and_is_handled_as_one()
  local W = world()
  local b = spawned(W)
  local n0 = placedCount(W)
  fleet.onEvent(W.fl, b.id, 'reroute', { cause = 'blocked', blocked = { 'N60', 'N61' }, along = 0 })   -- no way round: the road has no bypass
  assert((fleet.stats(W.fl).byCause.reroute_failed or 0) + (fleet.stats(W.fl).byCause.rerouted or 0) >= 1)
  assert(placedCount(W) == n0 + 1 or #busySlots(W) == 0, 'teleported ahead or put away')
end

function T.the_edge_of_the_graph_is_answered_with_a_longer_path()
  -- the graph window ends at x = 1800; the line goes on to 3000
  local W = world({ gx = { 800, 1800 } })
  step(W, 140)
  local b = busySlots(W)[1]
  assert(b, 'a bus')
  local c0 = sentOf(W, 'start', b.id)[1].cmd
  local lastNode = c0.path[#c0.path]
  -- the window moves with the player: the graph now reaches to x = 2600
  W.graph = roadGraph(1000, 2600)
  W.graphSigN = 2
  fleet.onEvent(W.fl, b.id, 'edge', { remaining = 80 })
  local sp = sentOf(W, 'setPath', b.id)
  assert(#sp == 1, 'a longer path is sent')
  assert(#sp[1].cmd.path > #c0.path - 5 and sp[1].cmd.path[#sp[1].cmd.path] ~= lastNode, 'it reaches further')
  assert((fleet.stats(W.fl).byCause.edge_extended or 0) == 1)
  -- nothing more to grow: the bus is marked as leaving and goes back at the end of the path when unseen
  fleet.onEvent(W.fl, b.id, 'edge', { remaining = 50 })        -- (rate limited)
  step(W, fleet.EDGE_RETRY_S + 1)
  fleet.onEvent(W.fl, b.id, 'edge', { remaining = 50 })
  assert((fleet.stats(W.fl).byCause.edge_same or 0) == 1 and b.leaving == true)
end

-- ---- the watchdog of the pool (it does not trust the driver) ---------------------------------------------------------------------

function T.a_silent_driver_is_restarted_once_then_the_bus_is_removed_and_replaced()
  local W = world()
  local b = spawned(W)
  local id = b.id
  W.answer = false                                             -- the driver's extension has crashed: no events, no status
  local x = W.veh[id].x
  local function roll() x = x + 2 W.veh[id].x = x end         -- (the bus is rolling: only the silence is wrong)
  step(W, fleet.SILENT_S + 2, roll)
  assert(#sentOf(W, 'start', id) == 2 and fleet.stats(W.fl).restarted == 1, 'restarted once')
  step(W, fleet.SILENT_S + 2, roll)
  assert(#busySlots(W) == 0 and W.veh[id].alive == false, 'then the bus is removed from the world')
  assert((fleet.stats(W.fl).byCause.removed_silent_driver or 0) == 1)
  assert(trip(W, '305').physical == false)
  step(W, 10)
  assert(#W.fl.slots == 2, 'the pool made a new vehicle: ' .. #W.fl.slots)
end

function T.a_driver_that_answers_status_is_never_silent()
  local W = world()
  local b = spawned(W)
  step(W, 200)
  assert(fleet.stats(W.fl).restarted == 0 and b.restarts == 0, 'a healthy driver is left alone')
  assert(#sentOf(W, 'status', b.id) >= 30, 'the fleet asks every few seconds')
end

function T.a_bus_that_does_not_advance_for_a_minute_is_moved_but_a_dwell_is_not_a_stall()
  local W = world()
  local b = spawned(W)
  W.drvState = 'dwell'
  local n0 = placedCount(W)
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 1, id = 3, late = 0 })
  step(W, 300)
  assert(placedCount(W) == n0, 'standing at a stop with the doors open for 5 minutes is a dwell: ' .. placedCount(W))
  fleet.onEvent(W.fl, b.id, 'departed', { i = 1, id = 3, late = 0 })
  W.drvState = 'drive'
  -- a healthy driver on the road waits at a red light up to RED_CAP_S
  step(W, 100)
  assert(placedCount(W) == n0, 'a healthy driver may wait 100 s at a red light')
  step(W, 40)
  assert(placedCount(W) == n0 + 1, 'but not for ever: moved after RED_CAP_S')
  assert((fleet.stats(W.fl).byCause.trouble_stall or 0) == 1)
  -- a bus whose driver is already on a rung of the ladder (or does not say) is stalled after FLEET_STALL_S
  local W2 = world()
  local b2 = spawned(W2)
  W2.drvState = 'drive'
  W2.answer = true
  W2.env.send = (function(orig) return function(id, cmd)
    if cmd.c == 'status' then fleet.onEvent(W2.fl, id, 'status', { state = 'drive', rung = 2 }) return true end
    return orig(id, cmd)
  end end)(W2.env.send)
  fleet.onEvent(W2.fl, b2.id, 'status', { state = 'drive', rung = 2 })
  b2.anchorT = W2.fl.t
  local m0 = placedCount(W2)
  step(W2, fleet.FLEET_STALL_S - 5)
  assert(placedCount(W2) == m0)
  step(W2, 12)
  assert(placedCount(W2) == m0 + 1, 'the pool-level watchdog fires after FLEET_STALL_S')
  -- a moving bus is not a stall
  local W3 = world()
  local b3 = spawned(W3)
  W3.drvState = 'drive'
  local k0 = placedCount(W3)
  local x = W3.veh[b3.id].x
  step(W3, 200, function() x = x + 5 W3.veh[b3.id].x = x end)
  assert(placedCount(W3) == k0, 'a bus that moves is not stalled')
end

function T.a_stalled_bus_in_sight_waits_for_the_player_to_look_away()
  local W = world()
  local b = spawned(W)
  W.vis = function() return true end
  W.drvState = 'drive'
  W.env.send = (function(orig) return function(id, cmd)
    if cmd.c == 'status' then fleet.onEvent(W.fl, id, 'status', { state = 'drive', rung = 3 }) return true end
    return orig(id, cmd)
  end end)(W.env.send)
  local n0 = placedCount(W)
  step(W, 150)
  assert(placedCount(W) == n0, 'in sight: not touched')
  W.vis = function() return false end
  step(W, 2)
  assert(placedCount(W) == n0 + 1, 'moved when he looked away')
end

function T.a_vanished_vehicle_gives_its_trip_back_and_is_replaced()
  local W = world()
  local b = spawned(W)
  local id = b.id
  W.veh[id].alive = false                                      -- deleted by something else
  step(W, 2)
  assert(#busySlots(W) == 0 and trip(W, '305').physical == false)
  step(W, 8)
  assert(#W.fl.slots == 2, 'a new vehicle for the pool')
end

function T.a_player_teleport_puts_every_bus_away_and_the_graph_reload_repairs_or_gives_back()
  local W = world()
  local b = spawned(W)
  fleet.onEvent(W.fl, b.id, 'departed', { i = 1, id = 3, late = 33 })
  fleet.onTeleport(W.fl)
  assert(#busySlots(W) == 0 and trip(W, '305').physical == false and trip(W, '305').delay == 33, 'all away, delay kept')
  assert(#W.fl.slots == 2)
  -- graph reload: the road is still there -> the path is kept
  local W2 = world()
  local b2 = spawned(W2)
  W2.graphSigN = 5
  fleet.onGraphReload(W2.fl)
  assert(#busySlots(W2) == 1, 'a repairable path keeps the bus')
  -- the graph is replaced by one without this road -> the bus goes back when it is not seen
  W2.graph = roadGraph(5000, 5400)
  W2.graphSigN = 6
  fleet.onGraphReload(W2.fl)
  step(W2, 2)
  assert(#busySlots(W2) == 0 and (fleet.stats(W2.fl).byCause.graph_lost or 0) == 1, 'path lost: given back')
  assert(trip(W2, '305').physical == false)
end

function T.a_graph_that_moves_makes_the_trip_unfit_nothing_stays_when_there_is_no_graph()
  local W = world()
  local b = spawned(W)
  W.graph = nil
  fleet.onGraphReload(W.fl)
  step(W, 2)
  assert(#busySlots(W) == 0, 'no graph: no physical bus')
  step(W, 30)
  assert(#busySlots(W) == 0, 'and none is made without a graph')
end

function T.a_net_that_is_built_again_keeps_the_physical_flag_and_the_delay()
  local W = world()
  local b = spawned(W)
  fleet.onEvent(W.fl, b.id, 'delay', { late = 45 })
  -- the net is replaced by a fresh one (busnetrun does it every few minutes)
  local old = W.net
  W.net = busnet.new({ day = 2 })
  local r = W.lines['305']
  local arr, dep = timetable(r)
  busnet.addLine(W.net, r, { clock = W.clock, day = 2, trips = { { start = old.lines[1].trips[1].start, arr = arr, dep = dep } } })
  busnet.update(W.net, W.clock)
  assert(W.net.lines[1].trips[1].physical == false)
  step(W, 2)
  assert(W.net.lines[1].trips[1].physical == true, 'the fleet says again which trips are physical')
  -- a given back trip gets its delay in a new net as well
  fleet.onEvent(W.fl, b.id, 'done', { late = 45 })
  W.vis = function() return false end
  step(W, 12)
  W.net = busnet.new({ day = 2 })
  busnet.addLine(W.net, r, { clock = W.clock, day = 2, trips = { { start = old.lines[1].trips[1].start, arr = arr, dep = dep } } })
  busnet.update(W.net, W.clock)
  step(W, 2)
  assert(W.net.lines[1].trips[1].delay == 45 and W.net.lines[1].trips[1].physical == false)
end

function T.a_pool_that_cannot_spawn_backs_off_and_everything_stays_virtual()
  local W = world()
  W.spawnFail = true
  step(W, 100)
  assert(#W.fl.slots == 0 and #busySlots(W) == 0)
  local by = fleet.stats(W.fl).byCause
  assert((by.pool_spawn_failed or 0) >= 3 and (by.pool_spawn_failed or 0) < 12, 'it tries now and then, not every second: ' .. tostring(by.pool_spawn_failed))
  W.spawnFail = false
  step(W, 80)
  assert(#W.fl.slots >= 1, 'and recovers')
end

-- ---- live transfers -----------------------------------------------------------------------------------------------------------------------------

local function hubRequest(W, tr)
  local hub = W.lines['360'].stops[3]
  return fleet.requestTransfer(W.fl, { ref = '360', at = tr.start + tr.arr[3], stop = { lat = hub.lat, lon = hub.lon, name = hub.name } })
end

function T.a_live_transfer_is_credited_when_the_bus_stands_at_the_hub_with_its_doors_open()
  local W = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  local tr = trip(W, '360')
  local token = hubRequest(W, tr)
  assert(token and fleet.transferStatus(W.fl, token) == 'pending')
  step(W, 60)
  local b = busySlots(W)[1]
  assert(b and b.key == tr.key and b.prio == 1, 'the bus of the transfer is physical, with priority 1')
  assert(fleet.transferStatus(W.fl, token) == 'live')
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 1, id = 2, late = 0 })        -- another stop: not the hub
  assert(fleet.transferStatus(W.fl, token) == 'live')
  fleet.onEvent(W.fl, b.id, 'departed', { i = 1, id = 2, late = 0 })
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 2, id = 3, late = 10 })       -- the hub (stop 3), doors open
  step(W, 1)
  assert(fleet.transferStatus(W.fl, token) == 'ready', 'standing at the hub')
  assert(fleet.transferStatus(W.fl, 99) == 'gone')
  fleet.cancelTransfer(W.fl, token)
  assert(fleet.transferStatus(W.fl, token) == 'gone')
end

function T.a_door_fault_or_a_passed_hub_means_no_credit_from_the_bus()
  local W = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  local tr = trip(W, '360')
  local token = hubRequest(W, tr)
  step(W, 60)
  local b = busySlots(W)[1]
  fleet.onEvent(W.fl, b.id, 'doorfault', { what = 'open' })
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 2, id = 3, late = 0, fault = true })
  step(W, 1)
  assert(fleet.transferStatus(W.fl, token) == 'live', 'doors that do not open: not ready')
  local W2 = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  local token2 = hubRequest(W2, trip(W2, '360'))
  step(W2, 60)
  local b2 = busySlots(W2)[1]
  fleet.onEvent(W2.fl, b2.id, 'skipped', { i = 2, id = 3, cause = 'blocked' })
  step(W2, 1)
  assert(fleet.transferStatus(W2.fl, token2) == 'fallback', 'the bus passed the hub without standing there')
end

function T.a_transfer_that_cannot_be_made_physical_falls_back_to_the_timer()
  -- no graph
  local W = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  W.graph = nil
  assert(hubRequest(W, trip(W, '360')) == nil, 'no graph: the timer decides from the start')
  -- no such trip near that time
  local W2 = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  local hub = W2.lines['360'].stops[3]
  assert(fleet.requestTransfer(W2.fl, { ref = '360', at = W2.clock + 3000, stop = { lat = hub.lat, lon = hub.lon, name = hub.name } }) == nil)
  assert(fleet.requestTransfer(W2.fl, { ref = '999', at = W2.clock, stop = { lat = hub.lat, lon = hub.lon, name = hub.name } }) == nil)
  -- the fleet is off
  fleet.setLimit(W2.fl, 0)
  assert(hubRequest(W2, trip(W2, '360')) == nil)
  -- the bus cannot be made physical (every spot in sight): the time passes and the status becomes 'fallback'
  local W3 = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  W3.vis = function() return true end
  local tr = trip(W3, '360')
  local token = hubRequest(W3, tr)
  step(W3, 60)
  assert(fleet.transferStatus(W3.fl, token) == 'pending')
  step(W3, 200)
  assert(fleet.transferStatus(W3.fl, token) == 'fallback', 'late: ' .. fleet.transferStatus(W3.fl, token))
  -- the bus of the transfer is taken out for trouble: fallback too
  local W4 = world({ trips = { { line = LINE_B, x = 1000 } }, px = 1700 })
  local token4 = hubRequest(W4, trip(W4, '360'))
  step(W4, 60)
  local b4 = busySlots(W4)[1]
  for _ = 1, fleet.MAX_RELOCATES + 1 do fleet.onEvent(W4.fl, b4.id, 'stuck', { cause = 'obstacle' }) b4.trouble = nil end
  assert(fleet.transferStatus(W4.fl, token4) == 'fallback' and #busySlots(W4) == 0)
end

function T.a_transfer_takes_the_slot_of_a_lower_priority_bus_out_of_sight()
  -- the only slot is taken by line A's bus; line B's bus (the transfer) is still on its way in
  local W = world({ n = 1, px = 1700, trips = { { line = LINE_A, x = 1500 }, { line = LINE_B, x = 1100 } } })
  step(W, 3)
  local b = busySlots(W)[1]
  assert(b and b.trip.line.ref == '305' and b.prio == 3, 'one bus is on the road: line A')
  local token = hubRequest(W, trip(W, '360'))
  assert(token)
  step(W, 40)
  local nb = busySlots(W)[1]
  assert(nb and nb.trip.line.ref == '360' and nb.prio == 1, 'the transfer bus got the slot')
  assert((fleet.stats(W.fl).byCause.preempted or 0) == 1)
  assert(trip(W, '305').physical == false, 'line A goes on virtually')
  -- a bus standing at a stop is not taken away
  local W2 = world({ n = 1, px = 1700, trips = { { line = LINE_A, x = 1500 }, { line = LINE_B, x = 1100 } } })
  step(W2, 3)
  local a2 = busySlots(W2)[1]
  fleet.onEvent(W2.fl, a2.id, 'atStop', { i = 1, id = 3, late = 0 })
  hubRequest(W2, trip(W2, '360'))
  step(W2, 40)
  assert(busySlots(W2)[1].trip.line.ref == '305', 'the bus at the stop keeps its slot')
end

-- the connections.lua side: the transfer is credited by the bus, with a fallback to the timer
local trip_ = require('earthBusRoutes/trip')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local connections = require('earthBusRoutes/connections')

local function atHub(live)
  H.reset()
  demand.book = demand.newBook()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  r.stops[3].station = true
  local trips = sched.generate(r, 2)
  local d = sched.departures(trips, 3, 8 * 3600, 1)[1]
  local t = trip_.new({ route = r, trips = trips, entry = { trip = d.trip, at = d.at }, startIndex = 3, day = 2, clock = sched.scheduled(d.trip, 3),
    opts = { density = 'high' } })
  t.dispatch.events = {}
  connections.store(t, 3, t.clock0, 0, { arrivals = { { ref = '360', to = 'Hradec', rel = 120 } }, lines = 4 })
  connections.live = live
  return t, r
end

local function standStill(t, secs) for _ = 1, secs * 10 do trip_.update(t, 0.1, { lat = t.route.stops[3].lat, lon = t.route.stops[3].lon, speed = 0, doorsOpen = true, aLong = 0, aLat = 0 }) end end

function T.connections_credit_the_transfer_when_the_bus_is_ready_not_when_the_clock_says()
  local state, asked, cancelled = 'live', {}, {}
  local t = atHub({ request = function(req) asked[#asked + 1] = req return 7 end, status = function(tok) assert(tok == 7) return state end,
    cancel = function(tok) cancelled[#cancelled + 1] = tok end })
  standStill(t, 1)
  assert(#asked == 1 and asked[1].ref == '360' and asked[1].stop.name == t.route.stops[3].name and asked[1].idx == 3 and asked[1].at > t.clock0)
  assert(t.hold and t.hold.live == 7, 'the hold waits for the bus')
  standStill(t, 135)
  assert(t.hold ~= nil and t.connCount == 0, 'the clock passed its time but the bus is not there: still waiting')
  state = 'ready'
  standStill(t, 1)
  assert(t.hold == nil and t.connCount == 1 and t.score.counts.connections == 1, 'credited by the bus')
  assert(t.waived > 100, 'the longer wait is not held against the driver: ' .. t.waived)
  connections.live = nil
end

function T.connections_fall_back_to_the_timer_when_the_fleet_gives_up()
  local state = 'live'
  local t = atHub({ request = function() return 3 end, status = function() return state end, cancel = function() end })
  standStill(t, 1)
  assert(t.hold and t.hold.live == 3)
  state = 'fallback'
  standStill(t, 1)
  assert(t.hold ~= nil and t.hold.live == nil, 'the timer is back in charge')
  standStill(t, 135)
  assert(t.hold == nil and t.connCount == 1, 'credited by the clock as before')
  -- no token, no provider, a broken provider: the timer
  for _, live in ipairs({ { request = function() return nil end, status = function() return 'ready' end, cancel = function() end },
    { request = function() error('boom') end, status = function() error('boom') end, cancel = function() end } }) do
    local t2 = atHub(live)
    standStill(t2, 1)
    assert(t2.hold and t2.hold.live == nil)
    standStill(t2, 135)
    assert(t2.hold == nil and t2.connCount == 1)
  end
  local t3 = atHub(nil)
  standStill(t3, 140)
  assert(t3.connCount == 1)
  -- a bus that is physical but never arrives: the timer takes over LIVE_EXTRA_S after the time
  local t4 = atHub({ request = function() return 5 end, status = function() return 'live' end, cancel = function() end })
  standStill(t4, 1)
  standStill(t4, 120 + connections.LIVE_EXTRA_S + 5)
  assert(t4.hold == nil and t4.connCount == 1, 'not stuck waiting for ever')
  connections.live = nil
end

function T.leaving_cancels_the_live_transfer_and_costs_a_missed_connection()
  local cancelled = {}
  local t = atHub({ request = function() return 11 end, status = function() return 'live' end, cancel = function(tok) cancelled[#cancelled + 1] = tok end })
  local s = t.route.stops[3]
  standStill(t, 1)
  -- the bus drives off with the doors closed
  for _ = 1, 40 do trip_.update(t, 0.1, { lat = s.lat, lon = s.lon, speed = 5, doorsOpen = false, aLong = 0, aLat = 0 }) end
  assert(t.hold == nil and #cancelled == 1 and cancelled[1] == 11, 'the fleet is told')
  assert(t.score.counts.missedConnections == 1)
  connections.live = nil
end

-- ---- shared passengers ----------------------------------------------------------------------------------------------------------------------------

function T.the_ai_that_served_a_stop_leaves_fewer_people_for_the_player_and_other_lines_are_not_touched()
  local book = demand.newBook()
  book.active = true
  local r = line(1, '305', { 200, 800, 1400 })
  local key = demand.lineKey(r)
  assert(key == '305>305-S3')
  local s = r.stops[2]
  assert(demand.sharedSince(book, s.lat, s.lon, key, 1000, 600) == 600, 'nobody served it')
  demand.markServed(book, s.lat, s.lon, key, 940, 4)
  assert(demand.sharedSince(book, s.lat, s.lon, key, 1000, 600) == 60, 'a bus took them 60 s ago')
  assert(demand.sharedSince(book, s.lat, s.lon, '360>X', 1000, 600) == 600, 'people of another line are not in the crowd')
  assert(demand.sharedSince(book, s.lat, s.lon, key, 900, 600) == 600, 'in the future: no effect')
  assert(demand.sharedSince(book, s.lat + 0.0003, s.lon, key, 1000, 600) == 60, 'the platform across the street is the same stop')
  assert(demand.sharedSince(book, s.lat + 0.01, s.lon, key, 1000, 600) == 600, 'a stop far away is another one')
  assert(demand.sharedSince(book, s.lat, s.lon, key, 1000, 30) == 30, 'never more than the caller counts')
  book.active = false
  assert(demand.sharedSince(book, s.lat, s.lon, key, 1000, 600) == 600, 'off: nothing changes')
  demand.pruneBook(book, 1000 + 4000)
  assert(next(book.cells) == nil, 'old entries are forgotten')
  -- fewer people in numbers
  local w, central = demand.stopWeights(r, nil)
  local many = demand.waiting(r, w, central, 2, 8, false, 600, { density = 'high', tripId = 1, day = 2 })
  local few = demand.waiting(r, w, central, 2, 8, false, 60, { density = 'high', tripId = 1, day = 2 })
  assert(few < many, few .. ' < ' .. many)
end

function T.a_player_trip_meets_fewer_people_where_an_ai_bus_of_the_line_just_stopped()
  local function waitingAt(served)
    H.reset()
    demand.book = demand.newBook()
    demand.book.active = true
    local r = assert(osm.parseRoute(H.fixture('route_6964117')))
    local trips = sched.generate(r, 2)
    local d = sched.departures(trips, 1, 8 * 3600, 1)[1]
    local t = trip_.new({ route = r, trips = trips, entry = { trip = d.trip, at = d.at }, startIndex = 1, day = 2, clock = sched.scheduled(d.trip, 1),
      opts = { density = 'high' } })
    -- drive to the second stop
    local marked = false
    local along = r.stops[1].along
    local target = r.stops[2].along
    for _ = 1, 20000 do
      if t.waiting ~= nil and t.idx == 2 then break end
      if served and not marked and target - along < 250 then
        marked = true
        local s2 = r.stops[2]
        demand.markServed(demand.book, s2.lat, s2.lon, demand.lineKey(r), t.clock - 30, 5)         -- an AI bus took them 30 s ago
      end
      along = math.min(target, along + 0.9)
      local lat, lon = geo.pointAt(r.path, r.cum, along)
      trip_.update(t, 0.1, { lat = lat, lon = lon, speed = along >= target and 0 or 9, doorsOpen = false, aLong = 0, aLat = 0 })
      if t.phase == 'atStop' and t.idx == 1 and t.boardLeft <= 0 and t.alightLeft <= 0 then along = along + 3 end
    end
    return t.waiting or 0, t
  end
  local many = waitingAt(false)
  local few = waitingAt(true)
  assert(many > 0 and few < many, ('with the AI bus 30 s before: %d, without: %d'):format(few, many))
end

function T.the_ai_buses_crowd_comes_from_the_same_model_and_shares_the_stops()
  local W = world()
  demand.book.active = true
  local b = spawned(W)
  local c = b.crowd
  assert(c and #c == 5 and c[5].board == 0, 'nobody boards at the terminus')
  local total = 0
  for i = 1, 5 do total = total + c[i].alight end
  local boarding = 0
  for i = 1, 5 do boarding = boarding + c[i].board end
  assert(total <= boarding, 'nobody gets off who did not get on')
  fleet.onEvent(W.fl, b.id, 'atStop', { i = 1, id = 3, late = 0 })
  local s = W.lines['305'].stops[3]
  assert(demand.sharedSince(demand.book, s.lat, s.lon, demand.lineKey(W.lines['305']), W.clock, 900) < 5, 'the AI marked the stop as served')
end

-- ---- the wiring in main.lua ------------------------------------------------------------------------------------------------------------------------

function T.the_option_values_and_the_off_switches()
  local fleetrun = require('earthBusRoutes/fleetrun')
  local S = { opts = {} }
  fleetrun.attach({}, S, {})
  assert(fleetrun.wanted() == 0, 'experimental: off until the player turns it on')
  S.opts.aiBuses = 'on'
  assert(fleetrun.wanted() == 2, 'default two buses')
  S.opts.busFleet = 4
  assert(fleetrun.wanted() == 4)
  S.opts.busFleet = '9'
  assert(fleetrun.wanted() == 6, 'at most six')
  S.opts.busFleet = -3
  assert(fleetrun.wanted() == 0)
  S.opts.busFleet = 3
  S.opts.aiBuses = 'off'
  assert(fleetrun.wanted() == 0, 'switched off')
  S.opts.aiBuses = 'on'
  S.opts.busNet = 'off'
  assert(fleetrun.wanted() == 0, 'no net, no fleet')
  assert(fleet.limitOf(nil) == 2 and fleet.limitOf('x') == 2 and fleet.limitOf(2.6) == 3)
  local json = jsonDecode(readFileText('mod/beamngEarth_addon.json'))
  local have = {}
  local order = {}
  for _, o in ipairs(json.options) do have[o.key] = o order[#order + 1] = o.key end
  assert(have.busFleet and have.busFleet.default == 2 and have.busFleet.min == 0 and have.busFleet.max == 6 and have.aiBuses.default == 'off')
  local iu, ib
  for i, k in ipairs(order) do if k == 'units' then iu = i end if k == 'busFleet' then ib = i end end
  assert(ib < iu, 'before units')
end

function T.without_the_game_functions_the_fleet_stays_off_and_the_main_module_works()
  H.reset()
  H.earth()
  package.loaded['earthBusRoutes/fleetrun'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  local fleetrun = require('earthBusRoutes/fleetrun')
  local S = { opts = {} }
  fleetrun.attach({}, S, {})
  for _ = 1, 5 do fleetrun.frame(1) end
  assert(fleetrun.info() == nil and fleetrun.stats() == nil, 'nothing without the game')
  fleetrun.onBusDriverEvent(5, 'stuck', {})
  fleetrun.onTeleport()
  fleetrun.onGraphReload()
  local main = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  assert(type(main.onEarthBusDriverEvent) == 'function' and type(main.onNavgraphReloaded) == 'function')
  main.onEarthBusDriverEvent(5, 'stuck', {})
  main.onNavgraphReloaded()
  assert(main.model().fleet == nil, 'the menu model has no fleet line')
  package.loaded['earthBusRoutes/fleetrun'] = nil
end

function T.fleetrun_runs_the_fleet_with_the_game_functions_and_publishes_a_line_for_the_menu()
  H.reset()
  H.earth()
  package.loaded['earthBusRoutes/fleetrun'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  package.loaded['earthBusRoutes/busnetrun'] = nil
  local W = world()
  -- the fake game: world.lua's fleet functions are the fake env's
  local world_ = require('earthBusRoutes/world')
  local busnetrun = require('earthBusRoutes/busnetrun')
  world_.fleetAvailable = function() return true end
  world_.navgraph = W.env.graph
  world_.navgraphSig = W.env.graphSig
  world_.toGame = toGame
  world_.fleetPlayer = W.env.player
  world_.fleetVisibleToPlayer = W.env.visible
  world_.fleetSpawn, world_.fleetPlace, world_.fleetHide, world_.fleetRemove = W.env.spawn, W.env.place, W.env.hide, W.env.remove
  world_.fleetAlive, world_.fleetPos, world_.fleetLoad = W.env.alive, W.env.pos, W.env.load
  world_.nowSec = function() return W.clock end
  local fleetrun = require('earthBusRoutes/fleetrun')
  world_.fleetSend = function(id, cmd)
    W.sent[#W.sent + 1] = { id = id, cmd = cmd }
    -- the driver answers through main.lua's hook
    if cmd.c == 'status' then fleetrun.onBusDriverEvent(id, 'status', { state = 'drive', rung = 0 }) end
    if cmd.c == 'start' then fleetrun.onBusDriverEvent(id, 'ready', { n = #cmd.path }) end
    return true
  end
  busnetrun._state.net, busnetrun._state.clock = W.net, W.clock
  local S = { opts = { aiBuses = 'on' }, screen = 'nearby' }
  fleetrun.attach({}, S, {})
  busnetrun.attach({}, S, { publish = function() end })
  for i = 1, 150 do
    W.clock = W.clock + 1
    busnet.update(W.net, W.clock)
    busnetrun._state.clock = W.clock
    fleetrun.frame(1)
  end
  local info = fleetrun.info()
  assert(info and info.n == 2 and info.pool == 2 and info.physical >= 1 and info.stuck == 0, 'the fleet runs: ' .. tostring(info and info.physical))
  assert(connections.live and demand.book.active, 'the live transfers and the shared stops are on')
  local stats = fleetrun.stats()
  assert(stats.spawned >= 1)
  -- the driver's events reach the fleet through the same function main.lua forwards to
  assert(#W.sent > 0 and W.sent[1].cmd.c == 'start', 'the start command went through world.fleetSend')
  S.opts.busFleet = 0
  for _ = 1, 4 do fleetrun.frame(1) end
  assert(fleetrun.info() == nil and connections.live == nil and demand.book.active == false, 'off cleanly')
  package.loaded['earthBusRoutes/fleetrun'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  package.loaded['earthBusRoutes/busnetrun'] = nil
end

return T
