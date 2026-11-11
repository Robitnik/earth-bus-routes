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
-- As in the game's own bus mode: the four corner markers of the stop's bay (the game's shape art/shapes/interface/
-- position_marker.dae, placed as its "Parking Markers" node does), red while you come, orange while the bus is in the bay,
-- green when the stop is done, then fading. Over them, with the debug drawer: a light fill of the same colour, the arrow of
-- the way to stand, the stop's name and how many wait. Needs BeamNG.Earth 1.6 (toGame) and the debug drawer; the corner
-- markers also need createObject (else the bay is drawn without them). A failure turns that part off, never the trip.
local markersOff, cornersOff = false, false
local CORNER_SHAPE = 'art/shapes/interface/position_marker.dae'
local slots = {}             -- 'next' | 'done' -> { objs = {4 TSStatic}, shown = bool }
local LABEL_M = 350          -- the name is written over a bay this near (along the road)

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

local function cornerObject(name)
  local m = createObject('TSStatic')
  m:setField('shapeName', 0, CORNER_SHAPE)
  m:setPosition(vec3(0, 0, 0))
  m.scale = vec3(1, 1, 1)
  m:setField('rotation', 0, '1 0 0 0')
  m.useInstanceRenderData = true
  m:setField('instanceColor', 0, '1 1 1 0')
  m:setField('collisionType', 0, 'None')            -- (the bus drives over them)
  m:setField('decalType', 0, 'None')
  m:setField('canSave', 0, '0')
  m:setField('meshCulling', 0, '0')
  m:setField('forceDetail', 0, '-1')
  m.canSave = false
  m:registerObject(name)
  local st = rawget(_G, 'scenetree')
  if st and st.MissionGroup then st.MissionGroup:addObject(m) end
  return m
end

local function slot(name)
  if cornersOff or rawget(_G, 'createObject') == nil then return nil end
  local sl = slots[name]
  if sl then return sl end
  local ok, objs = pcall(function()
    local t = {}
    for k = 1, 4 do t[k] = cornerObject(('earthBusRoutes_bay_%s_%d_%d'):format(name, k, os.time())) end
    return t
  end)
  if not ok then
    cornersOff = true
    log('W', TAG, 'world: corner markers off: ' .. tostring(objs))
    return nil
  end
  slots[name] = { objs = objs, shown = false }
  return slots[name]
end

local function colourText(c, a) return ('%.3f %.3f %.3f %.3f'):format(c[1], c[2], c[3], a) end

-- the corners of the bay (game x, y, z: back-left, front-left, front-right, back-right) -> the four markers, as the game's
-- Parking Markers node sets them (statically, on the ground)
local qOff
local function placeCorners(sl, pts, colour, alpha)
  qOff = qOff or (quatFromEuler(0, 0, math.pi / 2) * quatFromEuler(0, math.pi / 2, math.pi / 2))
  local fwd = (pts[2] + pts[3]) * 0.5 - (pts[1] + pts[4]) * 0.5
  fwd = vec3(fwd.x, fwd.y, 0)
  local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
  if len < 0.01 then return end
  fwd = fwd * (1 / len)
  local up = vec3(0, 0, 1)
  local base = qOff * quatFromDir(up, fwd)
  -- the node's corners: 1 top left (front-left), 2 top right, 3 bottom right, 4 bottom left; each turned 90 degrees more
  local order = { { pts[2], 90 }, { pts[3], 180 }, { pts[4], 270 }, { pts[1], 0 } }
  local text = colourText(colour, alpha)
  for k, obj in ipairs(sl.objs) do
    local pos, deg = order[k][1], order[k][2]
    local r = quatFromEuler(0, 0, math.rad(deg)) * base
    obj:setPosRot(pos.x, pos.y, pos.z + 0.05, r.x, r.y, r.z, r.w)
    obj:setField('instanceColor', 0, text)
  end
  sl.shown = true
end

local function hideSlot(sl)
  if not (sl and sl.shown) then return end
  for _, obj in ipairs(sl.objs) do pcall(function() obj:setField('instanceColor', 0, '1 1 1 0') end) end
  sl.shown = false
end

local function tri(dd, a, b, c, col)
  if dd.drawTriSolid then
    dd:drawTriSolid(a, b, c, col)
    dd:drawTriSolid(c, b, a, col)                    -- both faces: seen from either side
  elseif dd.drawTriangle then
    dd:drawTriangle(a, b, c, col)
  end
end

-- items from markers.lua; refZ: the height of the player's vehicle (the ground is looked for from above it)
function M.drawMarkers(items, refZ)
  local used = {}
  if M.markersAvailable() and #items > 0 then
    local mk = require('earthBusRoutes/markers')
    local ok, err = pcall(function()
      local dd = debugDrawer
      for _, it in ipairs(items) do
        local pts = {}
        for k, c in ipairs(it.zone.corners) do
          local x, y, z = toGround(c[1], c[2], refZ)
          if not x then return end
          pts[k] = vec3(x, y, z + 0.06)
        end
        local colour = mk.COLOURS[it.state or 'approach'] or mk.COLOURS.approach
        local a = it.alpha or 1
        local function ci(alpha) return ColorI(math.floor(colour[1] * 255), math.floor(colour[2] * 255), math.floor(colour[3] * 255), math.floor(alpha * a)) end
        if it.kind == 'soon' then
          local edge = ColorF(colour[1], colour[2], colour[3], 0.45)
          for k = 1, 4 do dd:drawLine(pts[k], pts[k % 4 + 1], edge) end
        else
          -- the bay: a light fill, its edge, the arrow of the way to stand
          tri(dd, pts[1], pts[2], pts[3], ci(48))
          tri(dd, pts[1], pts[3], pts[4], ci(48))
          local edge = ColorF(colour[1], colour[2], colour[3], 0.9 * a)
          for k = 1, 4 do dd:drawLine(pts[k], pts[k % 4 + 1], edge) end
          local ar = {}
          for k, c in ipairs(mk.arrow(it.zone)) do
            local x, y, z = toGround(c[1], c[2], refZ)
            if not x then return end
            ar[k] = vec3(x, y, z + 0.08)
          end
          tri(dd, ar[1], ar[2], ar[3], ci(110))
          -- the corner markers of the game
          local sl = slot(it.kind)
          if sl then
            local okc, e2 = pcall(placeCorners, sl, pts, colour, a)
            if okc then used[it.kind] = true
            else cornersOff = true log('W', TAG, 'world: corner markers off: ' .. tostring(e2)) end
          end
          -- the name and who waits, over the middle of the bay
          local text = mk.label(it)
          if text ~= '' and (it.ahead or 0) <= LABEL_M and dd.drawTextAdvanced then
            local mid = (pts[1] + pts[2] + pts[3] + pts[4]) * 0.25
            local S = rawget(_G, 'String')
            dd:drawTextAdvanced(vec3(mid.x, mid.y, mid.z + 2.6), S and S(text) or text, ColorF(1, 1, 1, a), true, false,
              ColorI(0, 0, 0, math.floor(150 * a)))
          end
        end
      end
    end)
    if not ok then
      markersOff = true
      log('W', TAG, 'world: markers off: ' .. tostring(err))
    end
  end
  for name, sl in pairs(slots) do
    if not used[name] then hideSlot(sl) end
  end
end

-- The corner markers removed from the world (a trip ended, the mod unloads)
function M.clearMarkers()
  for name, sl in pairs(slots) do
    for _, obj in ipairs(sl.objs) do pcall(function() obj:delete() end) end
    slots[name] = nil
  end
end

-- ---- the ghost of the best trip --------------------------------------------------------------------------------------------
-- A translucent bus-sized rectangle lying on the road, drawn with the debug drawer as the bay fill of the markers is, with the
-- same ground lookup (toGround). spec = { back = {lat, lon}, front = {lat, lon}, width }: the middle of its back and of its
-- front edge (taken from the route, so it follows a bend); refZ as for drawMarkers. A failure turns the ghost off, never the trip.
local ghostOff = false
local GHOST_FILL, GHOST_EDGE = { 70, 150, 255, 80 }, { 0.45, 0.7, 1, 0.95 }
local GHOST_LIFT = 0.15                -- metres over the ground (over the road paint, under the bus)

function M.ghostAvailable()
  local a = api()
  return not ghostOff and a ~= nil and a.has ~= nil and a.has('transform') == true and rawget(_G, 'debugDrawer') ~= nil
end

-- the ground under a game x, y, looked for from above refZ; `fallback` when the game cannot tell
local function groundXY(x, y, refZ, fallback)
  local be = rawget(_G, 'be')
  if be and be.getSurfaceHeightBelow then
    local h = be:getSurfaceHeightBelow(vec3(x, y, (refZ or fallback or 0) + 40))
    if type(h) == 'number' and h > -1e5 then return h end
  end
  return fallback or 0
end

function M.drawGhost(spec, refZ)
  if not (spec and M.ghostAvailable()) then return end
  local ok, err = pcall(function()
    local dd = debugDrawer
    local fx, fy, fz = toGround(spec.front.lat, spec.front.lon, refZ)
    local bx, by, bz = toGround(spec.back.lat, spec.back.lon, refZ)
    if not (fx and bx) then return end
    local dx, dy = fx - bx, fy - by
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then return end
    dx, dy = dx / len, dy / len
    local rx, ry = dy * (spec.width or 2.55) / 2, -dx * (spec.width or 2.55) / 2       -- half a width to the right
    local function corner(x, y, z) return vec3(x, y, groundXY(x, y, refZ, z) + GHOST_LIFT) end
    local p = { corner(bx - rx, by - ry, bz), corner(fx - rx, fy - ry, fz), corner(fx + rx, fy + ry, fz), corner(bx + rx, by + ry, bz) }
    local fill = ColorI(GHOST_FILL[1], GHOST_FILL[2], GHOST_FILL[3], GHOST_FILL[4])
    tri(dd, p[1], p[2], p[3], fill)
    tri(dd, p[1], p[3], p[4], fill)
    local edge = ColorF(GHOST_EDGE[1], GHOST_EDGE[2], GHOST_EDGE[3], GHOST_EDGE[4])
    for k = 1, 4 do dd:drawLine(p[k], p[k % 4 + 1], edge) end
    -- an arrow in the front half: which way it goes
    local mx, my, mz = (fx + bx) / 2, (fy + by) / 2, (fz + bz) / 2
    local function at(a, w)                    -- a metres along (from the middle), w metres to the right
      local x, y = mx + dx * a + (dy * w), my + dy * a - (dx * w)
      return vec3(x, y, groundXY(x, y, refZ, mz) + GHOST_LIFT + 0.02)
    end
    local half = len / 2
    tri(dd, at(half - 0.6, 0), at(half - 3.2, 0.7), at(half - 3.2, -0.7), ColorI(GHOST_FILL[1], GHOST_FILL[2], GHOST_FILL[3], 150))
  end)
  if not ok then
    ghostOff = true
    log('W', TAG, 'world: ghost off: ' .. tostring(err))
  end
end

-- length, width of the vehicle in metres, or nil when the game does not say
function M.vehicleSize(veh)
  if not veh then return nil end
  local okL, l = pcall(function() return veh:getInitialLength() end)
  local okW, w = pcall(function() return veh:getInitialWidth() end)
  if okL and type(l) == 'number' and l >= 4 and l <= 30 and okW and type(w) == 'number' and w >= 1.6 and w <= 3.5 then return l, w end
  return nil
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

-- The indicators: electrics.values.signal_L / signal_R (the lamp, flashing) and signal_left_input / signal_right_input (the
-- lever). Which of them the citybus and the mods built on it report is NOT verified in the game: every name is asked for, and
-- a vehicle that reports none leaves the indicator rule off (rules.lua).
M.SIGNAL_KEYS = { L = { 'signal_L', 'signal_left_input' }, R = { 'signal_R', 'signal_right_input' } }

function M.watchSignals(veh)
  local b = rawget(_G, 'core_vehicleBridge')
  if not (veh and b and b.registerValueChangeNotification) then return end
  for _, keys in pairs(M.SIGNAL_KEYS) do
    for _, k in ipairs(keys) do try(b.registerValueChangeNotification, veh, k) end
  end
end

-- true / false for 'L' or 'R', nil when the vehicle never reported the value
function M.signal(veh, side)
  local b = rawget(_G, 'core_vehicleBridge')
  if not (veh and b and b.getCachedVehicleData) then return nil end
  local lit
  for _, k in ipairs(M.SIGNAL_KEYS[side] or {}) do
    local ok, v = pcall(b.getCachedVehicleData, veh:getID(), k)       -- (silent: it runs every frame)
    if ok and v ~= nil then
      local on = (type(v) == 'number' and v > 0.5) or v == true
      if on then return true end
      lit = false
    end
  end
  return lit
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

-- The stop-request bell: the sound the game's own bus mode plays when somebody asks for the stop (bus.flow.json of busMode).
-- Not heard in a game session yet; a missing event or engine call turns the bell off for the session, never the trip.
M.BELL_EVENT = 'event:>UI>Missions>Bus_Stop_Bell'
local bellOff = false
function M.stopBell()
  if bellOff then return false end
  local ok, err = pcall(function() return Engine.Audio.playOnce('AudioGui', M.BELL_EVENT) end)
  if not ok then
    bellOff = true
    log('W', TAG, 'world: the stop bell is off: ' .. tostring(err))
  end
  return ok
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
  local ok = try(L.addApp, cur.filename, M.HUD_APP, { right = '20px', top = '110px', width = '380px', height = '480px' })
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
