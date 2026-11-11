-- Everything that touches the running game or BeamNG.Earth, in one place and behind pcall: if the game or Earth
-- changes, the feature that needs it stops, not the whole mod. The pure logic never calls any of this.
local M = {}
local TAG = 'earthBusRoutes'

local function api() return rawget(_G, 'beamngEarth_api') end
local function try(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  log('W', TAG, 'world: ' .. tostring(a))
  return nil
end

-- ---- BeamNG.Earth ------------------------------------------------------------------------------------------------

function M.pose()
  local a = api()
  if not (a and a.ready and a.ready()) then return nil end
  return try(a.pose)
end

function M.place()
  local a = api()
  return a and a.place and try(a.place) or nil
end

function M.weather()
  local a = api()
  return a and a.has and a.has('weather') and try(a.weather) or nil
end

-- The player's own add-on options (the add-on's registry id depends on how it was added)
function M.options()
  local a = api()
  if not (a and a.addonOptions) then return {} end
  for _, id in ipairs({ 'earth-bus-routes', 'bus-routes', 'earth_bus_routes' }) do
    local o = try(a.addonOptions, id)
    if type(o) == 'table' and next(o) ~= nil then return o end
  end
  return {}
end

function M.teleport(lat, lon, name)
  local a = api()
  if not (a and a.teleport) then return false, 'BeamNG.Earth is not loaded' end
  local ok, err = a.teleport(lat, lon, name)
  return ok, err
end

-- The GPS through the given stops (at most 10 are used): { {lat, lon, name} ... }
function M.gpsRoute(points)
  local a = api()
  if not (a and a.gpsSetRoute) then return false end
  local list = {}
  for i = 1, math.min(#points, 10) do list[i] = { lat = points[i].lat, lon = points[i].lon, name = points[i].name } end
  if #list == 0 then return false end
  local ok, err = a.gpsSetRoute(list)
  return ok, err
end

function M.gpsClear()
  local a = api()
  if a and a.gpsClear then try(a.gpsClear) end
end

-- ---- markers in the world ----------------------------------------------------------------------------------------------
-- A yellow zone on the road at the next stops, a pole and a text over it. Needs BeamNG.Earth 1.6 (toGame: lat/lon to the
-- game's coordinates) and the game's debug drawer; without them, or when the first draw fails, no markers (the GPS line stays).
local markersOff = false

function M.markersAvailable()
  local a = api()
  return not markersOff and a ~= nil and a.has ~= nil and a.has('transform') == true and rawget(_G, 'debugDrawer') ~= nil
end

local function xyz(a, b, c)
  if type(a) == 'number' then return a, b, c end
  if a ~= nil then return a.x, a.y, a.z end
end

-- lat, lon to the game's x, y and the ground under it (z)
local function toGround(lat, lon, refZ)
  local x, y, z = xyz(api().toGame(lat, lon, 0))
  if not x then return nil end
  local gz = z
  local be = rawget(_G, 'be')
  if be and be.getSurfaceHeightBelow then
    local h = be:getSurfaceHeightBelow(vec3(x, y, (refZ or z or 0) + 40))
    if type(h) == 'number' and h > -1e5 then gz = h end
  end
  return x, y, gz or 0
end

-- items from markers.lua; refZ: the height of the player's vehicle (the ground is looked for from above it)
function M.drawMarkers(items, refZ)
  if not M.markersAvailable() or #items == 0 then return end
  local ok, err = pcall(function()
    local dd = debugDrawer
    for _, it in ipairs(items) do
      local pts = {}
      for k, c in ipairs(it.zone.corners) do
        local x, y, z = toGround(c[1], c[2], refZ)
        if not x then return end
        pts[k] = vec3(x, y, z + 0.08)
      end
      local near = it.kind == 'next'
      local fill = near and ColorI(255, 200, 0, 120) or ColorI(255, 200, 0, 45)
      local edge = near and ColorF(1, 0.8, 0, 1) or ColorF(1, 0.8, 0, 0.5)
      if dd.drawTriangle then
        dd:drawTriangle(pts[1], pts[2], pts[3], fill)
        dd:drawTriangle(pts[1], pts[3], pts[4], fill)
      end
      for k = 1, 4 do dd:drawLine(pts[k], pts[k % 4 + 1], edge) end
      -- the pole and the text over the middle of the zone
      local mid = (pts[1] + pts[2] + pts[3] + pts[4]) * 0.25
      local top = vec3(mid.x, mid.y, mid.z + (near and 7 or 4))
      dd:drawLine(mid, top, edge)
      dd:drawSphere(top, near and 0.4 or 0.25, edge)
      local text = require('earthBusRoutes/markers').label(it)
      if dd.drawTextAdvanced then
        dd:drawTextAdvanced(top + vec3(0, 0, 0.8), text, ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, near and 170 or 110))
      elseif dd.drawText then
        dd:drawText(top + vec3(0, 0, 0.8), String(text), ColorF(1, 1, 1, 1))
      end
    end
  end)
  if not ok then
    markersOff = true
    log('W', TAG, 'world: markers off: ' .. tostring(err))
  end
end

function M.toast(text, seconds)
  local a = api()
  if a and a.notify then try(a.notify, text, seconds or 5) return end
  try(function() guihooks.trigger('Message', { ttl = seconds or 5, msg = text, icon = 'directions_bus' }) end)
end

-- ---- the player's vehicle ----------------------------------------------------------------------------------------

function M.vehicle()
  return getPlayerVehicle and getPlayerVehicle(0) or nil
end

-- { bus = bool, name = text, id = number } : a bus when the model says Body Style "Bus" or Commercial Class "Transit Bus"
function M.vehicleInfo(veh)
  veh = veh or M.vehicle()
  if not veh then return nil end
  local info = { bus = false, name = tostring(veh.jbeam), id = veh:getID() }
  local m = rawget(_G, 'core_vehicles') and try(core_vehicles.getModel, veh.jbeam)
  local model = m and m.model
  if model then
    info.name = model.Name or info.name
    info.bus = model['Body Style'] == 'Bus' or model['Commercial Class'] == 'Transit Bus'
  end
  return info
end

-- electrics.values.dooropen of the bus controller (citybus and the mods built on it): 1 while a door is open
function M.watchDoors(veh)
  local b = rawget(_G, 'core_vehicleBridge')
  if veh and b and b.registerValueChangeNotification then try(b.registerValueChangeNotification, veh, 'dooropen') end
end

-- true / false, or nil when the vehicle never reported the value (no doors the game knows of)
function M.doorsOpen(veh)
  local b = rawget(_G, 'core_vehicleBridge')
  if not (veh and b) then return nil end
  local v = try(b.getCachedVehicleData, veh:getID(), 'dooropen')
  if v == nil then return nil end
  if type(v) == 'number' then return v > 0.5 end
  return v == true
end

local acc = { prev = nil, aLong = 0, aLat = 0, id = nil }
function M.resetAccel() acc.prev = nil acc.aLong, acc.aLat = 0, 0 end

-- Smoothed longitudinal and lateral acceleration (m/s^2) of the vehicle from its velocity
function M.accel(veh, dt)
  if not veh or dt <= 0 then return 0, 0 end
  if acc.id ~= veh:getID() then acc.id = veh:getID() acc.prev = nil end
  local v = veh:getVelocity()
  local fwd, up = veh:getDirectionVector(), veh:getDirectionVectorUp()
  local right = fwd:cross(up)
  if acc.prev then
    local a = (v - acc.prev) / dt
    local aL, aR = a:dot(fwd), a:dot(right)
    -- a jump (a teleport, a reset) is no acceleration
    if math.abs(aL) < 40 and math.abs(aR) < 40 then
      acc.aLong = acc.aLong + (aL - acc.aLong) * 0.25
      acc.aLat = acc.aLat + (aR - acc.aLat) * 0.25
    end
  end
  acc.prev = vec3(v.x, v.y, v.z)
  return acc.aLong, acc.aLat
end

-- The bus's destination sign / next-stop screen (the stock bus controller's own event)
function M.busDisplay(veh, route, stopsAhead)
  if not veh then return end
  local tasklist = {}
  for i, s in ipairs(stopsAhead or {}) do tasklist[i] = { 'earthstop' .. i, s.name } end
  local data = { direction = route.to or route.name or '', routeID = route.ref, routeId = route.ref,
    routeColor = route.colour, tasklist = tasklist }
  try(function()
    veh:queueLuaCommand("if controller and controller.onGameplayEvent then controller.onGameplayEvent('bus_onRouteChange'," ..
      serialize(data) .. ") end")
  end)
end

-- Put the vehicle where it stands but turned to a true heading (degrees clockwise from north)
function M.faceHeading(veh, wantHeading)
  local a = api()
  local pose = a and a.pose and a.pose()
  if not (veh and pose and pose.heading and wantHeading) then return false end
  local delta = ((wantHeading - pose.heading + 540) % 360) - 180          -- -180..180, clockwise positive
  if math.abs(delta) < 8 then return true end
  return try(function()
    local pos = veh:getPosition()
    local rot = quat(veh:getRotation())
    local turn = quatFromAxisAngle(vec3(0, 0, 1), -math.rad(delta))        -- clockwise seen from above = about -z
    local nr = turn * rot
    spawn.safeTeleport(veh, pos, nr, nil, nil, false)
    return true
  end) == true
end

-- ---- the clock ---------------------------------------------------------------------------------------------------

local clock = { savedMode = nil, savedTime = nil, active = false, lastSet = -1 }

function M.clockBegin()
  if clock.active then return end
  local sky = rawget(_G, 'beamngEarth_sky')
  clock.savedMode = sky and sky.getMode and try(sky.getMode) or nil
  if sky and clock.savedMode and clock.savedMode ~= 'manual' and sky.setMode then try(sky.setMode, 'manual') end
  local env = rawget(_G, 'core_environment')
  local tod = env and env.getTimeOfDay and try(env.getTimeOfDay)
  clock.savedTime = tod and tod.time or nil
  clock.active, clock.lastSet = true, -1
end

-- Time of day as the game wants it: a day fraction with noon = 0
function M.todFraction(sec) return (sec / 86400 + 0.5) % 1 end

function M.clockSet(sec)
  if not clock.active then return end
  if math.abs(sec - clock.lastSet) < 0.9 then return end
  clock.lastSet = sec
  local env = rawget(_G, 'core_environment')
  if env and env.setTimeOfDay then try(env.setTimeOfDay, { time = M.todFraction(sec) }) end
end

-- Back to what it was: Earth's real clock if that was running, else the time the player had
function M.clockEnd()
  if not clock.active then return end
  clock.active = false
  local sky = rawget(_G, 'beamngEarth_sky')
  if clock.savedMode == 'real' and sky and sky.setMode then
    try(sky.setMode, 'real')
  elseif clock.savedTime then
    local env = rawget(_G, 'core_environment')
    if env and env.setTimeOfDay then try(env.setTimeOfDay, { time = clock.savedTime }) end
  end
end

-- The current time of day in seconds from midnight, from the game's clock
function M.nowSec()
  local env = rawget(_G, 'core_environment')
  local tod = env and env.getTimeOfDay and try(env.getTimeOfDay)
  if tod and tod.time then return ((tod.time * 24 + 12) % 24) * 3600 end
  return 12 * 3600
end

function M.weekday()
  local w = os.date('*t').wday           -- 1 = Sunday
  return (w + 5) % 7 + 1                 -- 1 = Monday .. 7 = Sunday
end

-- ---- the HUD app and the menu page --------------------------------------------------------------------------------

M.HUD_APP = 'EarthBusHud'

-- Makes sure the HUD app is in the player's current UI layout (asked once, with a toast): returns true if it added it
function M.ensureHud()
  local L = rawget(_G, 'ui_appLayouts')
  if not (L and L.getCurrentLayout and L.addApp) then return false end
  local cur = try(L.getCurrentLayout)
  if type(cur) ~= 'table' or not cur.filename then return false end
  for _, a in ipairs(cur.apps or {}) do
    if a.appName == M.HUD_APP then return false end
  end
  local ok = try(L.addApp, cur.filename, M.HUD_APP, { right = '20px', top = '110px', width = '380px', height = '410px' })
  if ok then
    try(function() guihooks.trigger('UiAppLayoutsChanged') end)
    try(L.setCurrentLayout, cur.filename)
  end
  return ok == true
end

function M.navigate(route)
  local r = rawget(_G, 'ui_router')
  if r and r.navigate then return try(r.navigate, route) ~= nil end
  try(function() guihooks.trigger('ChangeState', { state = route }) end)
  return true
end

return M
