-- Shifts in the game (plan 006, stage B): the dispatcher between the trips, the layover, the empty run from the depot and the
-- summary. The pure rules are in shift.lua; this module only joins them to main.lua's state (S), the data service and the world.
-- It is attached by main.lua (shiftrun.attach) and called from a few hooks there; every hook runs under pcall, and a failure
-- ends the shift (never the trip): "if something breaks, this part is switched off, not the trip".
-- Unverified in the game (no game was at hand): the clock winding during a layover, leaving the bus during a layover, the
-- depot teleport and the empty run, the bus sign between the trips.
local shift = require('earthBusRoutes/shift')
local schedule = require('earthBusRoutes/schedule')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local datasvc = require('earthBusRoutes/datasvc')
local world = require('earthBusRoutes/world')
local M = {}
local TAG = 'earthBusRoutes'

M.NEAR_DEPOT_M = 300         -- a depot this near the first stop is no run: the shift starts as any trip does
M.TELEPORT_GRACE_S = 4       -- a teleport event this soon after our own teleport is ours

local S, H, main             -- main.lua's state, the functions it lends, and its module table (set by attach)

local function enabled() return (S.opts.shifts or 'on') ~= 'off' end
local function depotOn() return (S.opts.depotStart or 'on') ~= 'off' end
local function scale() return tonumber(S.opts.timeScale) or 1 end

local function clockLabel(sec)
  sec = math.floor(sec % 86400)
  return ('%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

-- A hook that never breaks the caller: an error ends the shift and returns `default`
local function guard(name, fn, default)
  return function(...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    log('E', TAG, 'shift: ' .. name .. ' failed: ' .. tostring(a))
    pcall(function() M.abandon() end)
    return default
  end
end

-- ---- what the pages show --------------------------------------------------------------------------------------------------

local function layoverModel(sh)
  local L = sh.layover
  if not L then return nil end
  local info = shift.layover(sh, L.clock)
  if not info then return nil end
  local r = L.route or L.desc.route
  return { ref = info.ref, from = info.from, to = info.to, colour = r and r.colour or nil, planned = info.planned, departs = info.departs,
    plannedLabel = clockLabel(info.planned), departsLabel = clockLabel(info.departs), nowLabel = clockLabel(L.clock),
    remaining = math.floor(info.remaining), late = math.floor(info.late), number = info.number, away = L.away or false, loading = L.route == nil,
    clockWound = L.wound or false, endsIn = math.max(0, math.floor(sh.endClock - L.clock)) }
end

local function runModel(sh)
  local R = sh.run
  if not R then return nil end
  local pose = world.pose()
  local d = pose and geo.dist(pose.lat, pose.lon, R.stop.lat, R.stop.lon) or nil
  local route = R.plan.route
  return { ref = route.ref, colour = route.colour, to = route.to, stop = R.stop.name, dist = d and math.floor(d + 0.5) or nil,
    due = R.plan.clock, dueLabel = clockLabel(R.plan.clock), late = math.max(0, math.floor(R.clock - R.plan.clock)), depot = R.depot.name,
    depotKind = R.depot.kind }
end

function M.model()
  local sh = S.shift
  local m = { enabled = enabled(), depotOn = depotOn(), durations = shift.DURATIONS, realChain = datasvc.has('shift') == true,
    hasDepot = datasvc.has('depot') == true, active = sh ~= nil, result = S.shiftResult }
  if sh then
    m.source, m.trips, m.number, m.depot = sh.source, #sh.trips, sh.begun, sh.depot and sh.depot.kind or nil
    m.state = sh.run and 'run' or sh.layover and 'layover' or S.trip and 'trip' or 'starting'
    m.layover, m.run = layoverModel(sh), runModel(sh)
    m.endsLabel = clockLabel(sh.endClock)
  end
  return m
end

local function layoverHud(sh)
  local m = layoverModel(sh)
  if not m then return nil end
  m.units = S.opts.units or 'km/h'
  return m
end

-- What the trip HUD adds while a shift runs
function M.hud(t)
  local sh = S.shift
  if not sh then return nil end
  local h = shift.hud(sh, t.clock)
  h.lateStart = t.shiftLate or sh.nextLate or 0
  return h
end

-- true when it sent something the HUD can show (the HUD asks when it mounts)
function M.sendHud()
  local sh = S.shift
  if not sh or S.trip then return false end
  local payload
  if sh.layover then payload = { layover = layoverHud(sh) }
  elseif sh.run then
    local m = runModel(sh)
    if m then m.units = S.opts.units or 'km/h' end
    payload = { service = m }
  end
  if not payload or not (payload.layover or payload.service) then return false end
  guihooks.trigger('EarthBusRoutesHud', payload)
  return true
end

-- ---- starting ---------------------------------------------------------------------------------------------------------------

-- The way back of a route (the map's, when it is loaded, else the same road the other way); cb(route)
local function syntheticBack(route)
  local ok, rev = pcall(osm.reversed, route)
  if not ok or not rev then return nil end
  S.routes[rev.id] = S.routes[rev.id] or rev
  return S.routes[rev.id]
end

local function backOf(route, cb)
  local back = S.reverseOf[route.id]
  if type(back) == 'number' and S.routes[back] then cb(S.routes[back]) return end
  if type(back) == 'number' then
    H.loadRoute(back, function(r) cb(r or syntheticBack(route)) end)
    return
  end
  cb(syntheticBack(route))
end

local function generatedPlan(plan, cb)
  backOf(plan.route, function(back)
    local legs = { { route = plan.route, trips = plan.trips } }
    if back then legs[2] = { route = back, trips = H.currentTrips(back).trips } end
    cb({ source = 'generated', legs = legs })
  end)
end

-- The chain of the shift: the real one from the service for a line of the timetables, else there and back; cb(partial plan)
local function chainStep(plan, mins, cb)
  local route, entry = plan.route, plan.entry
  if route.timetable == 'gtfs' and datasvc.has('shift') == true then
    datasvc.shift(route.id, entry.trip.start, plan.day, mins, function(data)
      local list = data and data.trips
      if type(list) == 'table' and #list >= 2 and tonumber(list[1].start) == entry.trip.start then
        for _, it in ipairs(list) do it.start, it.id = tonumber(it.start), tonumber(it.id) end
        cb({ source = 'gtfs', chain = list })
      else
        generatedPlan(plan, cb)             -- nothing leaves the terminus (or the service did not know the line): there and back
      end
    end)
  else
    generatedPlan(plan, cb)
  end
end

-- The depot the shift starts from (the service looks it up once for the area); cb(depot or nil)
local function depotStep(plan, want, cb)
  if not want or datasvc.has('depot') ~= true then cb(nil) return end
  local stop = plan.route.stops[plan.startIndex]
  datasvc.depot(stop.lat, stop.lon, function(data)
    local d = data and data.depot
    if type(d) ~= 'table' or not d.lat or not d.lon then cb(nil) return end
    if geo.dist(d.lat, d.lon, stop.lat, stop.lon) < M.NEAR_DEPOT_M then cb(nil) return end         -- already there
    cb({ name = d.name or 'Depot', lat = d.lat, lon = d.lon, kind = d.kind == 'station' and 'station' or 'depot' })
  end)
end

-- The first trip as a plain start: where the bus is, or taken to the stop (as uiStart does)
local function startFirst(plan)
  local stop = plan.route.stops[plan.startIndex]
  local pose = world.pose()
  if pose and geo.dist(pose.lat, pose.lon, stop.lat, stop.lon) <= main.START_NEAR_M then H.beginTrip(plan) return end
  local ok, err = world.teleport(stop.lat, stop.lon, stop.name)
  if not ok then
    S.shift = nil
    S.err = 'Could not take you to the stop: ' .. tostring(err)
    H.publish()
    return
  end
  S.starting = { plan = plan, t = 0, seenTeleport = false }
  H.publish()
  H.goPlay()
  world.toast('Taking you to ' .. tostring(stop.name) .. '…', 5)
end

-- The empty run: the bus begins at the depot, the GPS leads to the first stop, the trip begins there
local function beginRun(plan, depot)
  local sh = S.shift
  if not sh then return end
  local stop = plan.route.stops[plan.startIndex]
  local pose = world.pose()
  local d = pose and geo.dist(pose.lat, pose.lon, stop.lat, stop.lon) or depot.dist or 2000
  local lead = shift.depotLead(d)
  sh.run = { plan = plan, depot = depot, stop = { name = stop.name, lat = stop.lat, lon = stop.lon }, clock0 = plan.clock - lead,
    elapsed = 0, clock = plan.clock - lead, hudTimer = 0 }
  sh.beganAt = S.markerClock or 0
  world.clockBegin()
  world.clockSet(sh.run.clock)
  world.watchDoors(world.vehicle())
  world.busDisplay(world.vehicle(), { to = 'Služební jízda', ref = '', colour = plan.route.colour }, {})    -- the sign of an empty run
  world.gpsRoute({ { lat = stop.lat, lon = stop.lon, name = stop.name } })
  world.toast(('Service run from %s to %s: the trip begins there.'):format(tostring(depot.name), tostring(stop.name)), 7)
  H.goPlay()
  H.publish()
  M.sendHud()
end

local function launch(plan, sp, depot)
  S.loading = nil
  local veh = world.vehicleInfo()
  local sh = shift.new({ source = sp.source, startClock = plan.clock, duration = plan.shiftMinutes, chain = sp.chain, legs = sp.legs,
    startIndex = plan.startIndex, depot = depot, vehId = veh and veh.id })
  sh.base = { day = plan.day, ctx = plan.ctx, opts = plan.opts, vehicle = plan.vehicle, vehicleName = plan.vehicleName }
  sh.beganAt = S.markerClock or 0
  S.shift, S.shiftResult = sh, nil
  pcall(main.careerSetShift, true)          -- the career (stage E): the shift pays at its end, not each trip
  if depot then
    local ok, err = world.teleport(depot.lat, depot.lon, depot.name)
    if not ok then
      S.shift = nil
      S.err = 'Could not take you to the depot: ' .. tostring(err)
      H.publish()
      return
    end
    S.starting = { plan = plan, t = 0, seenTeleport = false, after = function() M.beginRun(plan, depot) end }
    H.publish()
    H.goPlay()
    world.toast('Taking you to ' .. tostring(depot.name) .. '…', 5)
  else
    startFirst(plan)
  end
end

-- "Start a shift": the chosen departure of the open route card begins it; minutes = 60 | 120 | 240 of game time
function M.uiStartShift(minutes, withDepot)
  if not enabled() then S.err = 'shift_off' H.publish() return end
  if S.trip or S.shift or S.starting then S.err = 'A trip is already running' H.publish() return end
  if S.armed then main.uiCancelArmed(true) end
  local plan, why = H.buildPlan()
  if not plan then S.err = why H.publish() return end
  if not plan.entry then S.err = 'shift_noentry' H.publish() return end
  S.err = nil
  S.loading = 'shift'
  plan.shiftMinutes = shift.clampDuration(minutes)
  H.publish()
  local want = (withDepot == true or withDepot == 'true') and depotOn()
  local got, left = {}, 2
  local function join()
    left = left - 1
    if left > 0 then return end
    local ok, err = pcall(launch, plan, got.sp, got.depot)
    if not ok then
      log('E', TAG, 'shift: start failed: ' .. tostring(err))
      S.shift, S.loading, S.err = nil, nil, 'Could not start the shift'
      H.publish()
    end
  end
  chainStep(plan, plan.shiftMinutes, function(sp) got.sp = sp join() end)
  depotStep(plan, want, function(depot) got.depot = depot join() end)
end

-- ---- between the trips -------------------------------------------------------------------------------------------------------

local function stopsOf(route, n)
  local out = {}
  for i = 1, math.min(#route.stops, n or 8) do out[i] = route.stops[i] end
  return out
end

-- The next trip's route is here: the bus's sign shows it and the GPS leads to its first stop
local function routeReady(sh, L, route)
  L.route = route
  world.busDisplay(sh.veh, route, stopsOf(route, 8))
  local first = route.stops[1]
  if first then world.gpsRoute({ { lat = first.lat, lon = first.lon, name = first.name } }) end
  H.publish()
  M.sendHud()
end

local function startLayover(sh, t, nxt)
  local L = { clock0 = t.clock, elapsed = 0, clock = t.clock, hudTimer = 0, pubTimer = 0, desc = nxt }
  sh.layover, sh.veh = L, t.veh or sh.veh
  local wind = shift.windTo(sh, L.clock)
  if wind then
    L.clock0, L.clock, L.wound = wind, wind, true
    world.clockSet(wind)
  end
  if nxt.kind == 'gtfs' then
    H.loadRoute(nxt.routeId, function(route, why)
      if S.shift ~= sh or sh.layover ~= L then return end
      if not route then
        log('W', TAG, 'shift: the next trip could not be loaded: ' .. tostring(why))
        world.toast('The dispatcher could not give you the next trip: the shift ends.', 6)
        M.uiShiftEnd()
        return
      end
      routeReady(sh, L, route)
    end)
  else
    routeReady(sh, L, nxt.route)
  end
  local label = clockLabel(nxt.start)
  world.toast(('Shift: trip %d done. Next: %s to %s at %s%s'):format(#sh.trips, tostring(nxt.ref), tostring(nxt.to), label,
    L.wound and (' (the clock moved on to ' .. clockLabel(L.clock) .. ')') or ''), 8)
  H.publish()
  M.sendHud()
end

local function beginNext(sh, L)
  local desc = shift.depart(sh, L.clock)
  local route = L.route
  local day = sh.base.day
  local trips = H.currentTrips(route).trips
  local entry = shift.entryFor(desc, route, trips)
  local veh = world.vehicleInfo()
  local opts = {}
  for k, v in pairs(sh.base.opts or {}) do opts[k] = v end
  opts.weather = world.weather()
  local late = math.max(0, math.floor(L.clock - desc.planned))
  local plan = { route = route, trips = trips, entry = entry, startIndex = 1, day = day, clock = L.clock, ctx = sh.base.ctx, opts = opts,
    vehicle = { bus = veh and veh.bus ~= false }, vehicleName = veh and veh.name or sh.base.vehicleName }
  sh.layover, sh.nextLate = nil, late          -- (the HUD sent as the trip begins already knows how late it begins)
  H.beginTrip(plan)
  if S.trip then S.trip.shiftLate = late end
  sh.nextLate = nil
end

-- A trip of the shift is over (called by main's finishTrip). true = the shift took it over (the menu's result page is not shown)
function M.onTripFinished(t, res)
  local sh = S.shift
  if not sh or sh.state == 'done' then return false end
  local rec = shift.record(t.route, res, { minutes = math.floor((t.clock - t.clock0) / 60 + 0.5), late = t.shiftLate or 0 })
  rec.number = #sh.trips + 1
  local nxt = shift.arrive(sh, rec, t.clock)
  S.trip = nil
  world.clearMarkers()
  S.doneStop = nil
  world.gpsClear()
  if not nxt then M.finish(t.clock) return true end
  startLayover(sh, t, nxt)
  return true
end

-- The shift is over (the summary shows) or was given up before a trip was done (nothing to show)
function M.finish(now)
  local sh = S.shift
  if not sh then return end
  shift.finish(sh, now)
  local res = shift.result(sh)
  sh.layover, sh.run = nil, nil
  pcall(main.careerSetShift, false)
  if res.count > 0 then
    local smooth = true
    for _, tr in ipairs(res.trips) do if not tr.smooth then smooth = false end end
    local okC, news = pcall(main.careerShiftDone, { hours = res.minutes / 60, trips = res.count, passengers = res.passengers,
      punctuality = res.punctuality, grade = res.grade, revenue = res.revenue, smooth = smooth })
    if okC then res.career = news end      -- { earned, unlocked, rankUp, rank } for the summary page
  end
  S.shift, S.trip, S.starting = nil, nil, nil
  H.endClockAndGps()
  if res.count == 0 then
    S.screen = 'nearby'
    H.publish()
    guihooks.trigger('EarthBusRoutesHud', { idle = true })
    return
  end
  S.shiftResult, S.result = res, nil
  S.screen = 'shiftResult'
  H.publish()
  datasvc.watching = true
  world.navigate('earthBusRoutes')
  guihooks.trigger('EarthBusRoutesHud', { finished = true, result = { grade = res.grade, points = res.points }, shift = { count = res.count } })
end

-- "End the shift" (the layover page, the cancel of a trip): an unfinished trip is not counted
function M.uiShiftEnd()
  local sh = S.shift
  if not sh then return end
  local now = (sh.layover and sh.layover.clock) or (sh.run and sh.run.clock) or sh.arrivedAt or sh.startClock
  if S.trip then now = S.trip.clock end
  M.finish(now)
end

function M.uiShiftClose()
  S.shiftResult = nil
  S.screen = 'nearby'
  S.sel, S.result = {}, nil
  H.publish()
  guihooks.trigger('EarthBusRoutesHud', { idle = true })
end

-- Something went wrong in a hook: the shift is dropped, the trip (if one runs) goes on as a trip of its own
function M.abandon()
  local sh = S.shift
  S.shift = nil
  pcall(main.careerSetShift, false)
  if sh then
    sh.layover, sh.run = nil, nil
    if not S.trip and not S.starting then H.endClockAndGps() guihooks.trigger('EarthBusRoutesHud', { idle = true }) end
    world.toast('The shift was dropped because of an error.', 5)
  end
  if S.starting and S.starting.after then S.starting = nil end
end

-- ---- every frame ---------------------------------------------------------------------------------------------------------

local function inShiftBus(sh)
  local veh = world.vehicle()
  if not veh then return false end
  if not sh.vehId then return true end
  return veh:getID() == sh.vehId
end

local function runFrame(sh, dtReal, dtSim)
  local R = sh.run
  R.elapsed = R.elapsed + (dtSim or 0)
  R.clock = R.clock0 + R.elapsed * scale()
  world.clockSet(R.clock)
  local pose = world.pose()
  if not pose then return end
  local d = geo.dist(pose.lat, pose.lon, R.stop.lat, R.stop.lon)
  R.hudTimer = R.hudTimer - (dtReal or 0)
  if R.hudTimer <= 0 then R.hudTimer = 0.5 M.sendHud() end
  if d <= main.ARRIVE_M and (pose.speed or 0) <= main.ARRIVE_SPEED then
    local plan = R.plan
    sh.run = nil
    world.gpsClear()
    plan.clock = R.clock                       -- early: the people board and the bus waits for its time; late: the late start counts
    local late = math.max(0, math.floor(R.clock - (plan.entry and schedule.scheduled(plan.entry.trip, plan.startIndex) or plan.clock)))
    sh.nextLate = late
    H.beginTrip(plan)
    if S.trip then S.trip.shiftLate = late end
    sh.nextLate = nil
  end
end

local function layoverFrame(sh, dtReal, dtSim)
  local L = sh.layover
  L.elapsed = L.elapsed + (dtSim or 0)
  L.clock = L.clock0 + L.elapsed * scale()
  world.clockSet(L.clock)
  L.away = not inShiftBus(sh)
  L.hudTimer = L.hudTimer - (dtReal or 0)
  if L.hudTimer <= 0 then L.hudTimer = 0.5 M.sendHud() end
  L.pubTimer = L.pubTimer - (dtReal or 0)
  if L.pubTimer <= 0 then
    L.pubTimer = 5
    if S.screen == 'shiftLayover' then H.publish() end
  end
  local info = shift.layover(sh, L.clock)
  if info and info.go and L.route and not L.away then beginNext(sh, L) end
end

function M.frame(dtReal, dtSim)
  local sh = S.shift
  if not sh or S.trip or S.starting then return end
  if not sh.run and not sh.layover then
    -- nothing runs and nothing waits (the world did not load after the teleport): the shift is lost, quietly
    if (S.markerClock or 0) - (sh.beganAt or 0) > 60 then M.abandon() end
    return
  end
  if sh.run then runFrame(sh, dtReal, dtSim) elseif sh.layover then layoverFrame(sh, dtReal, dtSim) end
end

-- ---- hooks of main.lua ----------------------------------------------------------------------------------------------------

-- The menu opens: during a layover or an empty run it shows the dispatcher's page
function M.screenFor(screen)
  local sh = S.shift
  if sh and not S.trip and (sh.layover or sh.run) then return 'shiftLayover' end
  return screen
end

-- The player cancelled the trip: with a shift that ends the shift. true = handled
function M.onCancel()
  if not S.shift then return false end
  M.uiShiftEnd()
  world.toast('Shift ended', 3)
  return true
end

-- A teleport the player asked for (not ours: the depot and the first stop are ours) ends a shift that waits or runs
function M.onTeleport()
  local sh = S.shift
  if not sh or S.trip or S.starting then return end
  if (S.markerClock or 0) - (sh.beganAt or 0) < M.TELEPORT_GRACE_S then return end
  if sh.layover or sh.run then
    M.uiShiftEnd()
    world.toast('Shift ended: you were teleported', 4)
  end
end

-- ---- wiring ---------------------------------------------------------------------------------------------------------------

-- host = { publish, loadRoute, beginTrip, buildPlan, currentTrips, goPlay, endClockAndGps }
function M.attach(mainModule, state, host)
  main, S, H = mainModule, state, host
  mainModule.uiStartShift = guard('start', M.uiStartShift, nil)
  mainModule.uiShiftEnd = M.uiShiftEnd
  mainModule.uiShiftClose = M.uiShiftClose
  -- the hooks main.lua calls
  M.onTripFinished = guard('onTripFinished', M.onTripFinished, false)
  M.frame = guard('frame', M.frame, nil)
  M.onCancel = guard('onCancel', M.onCancel, false)
  M.onTeleport = guard('onTeleport', M.onTeleport, nil)
  M.hud = guard('hud', M.hud, nil)
  M.model = guard('model', M.model, nil)
  M.sendHud = guard('sendHud', M.sendHud, false)
  M.screenFor = guard('screenFor', M.screenFor, nil)
  M.beginRun = guard('beginRun', beginRun, nil)
end

return M
