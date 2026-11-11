-- The ghost of the best trip, wired to a running trip (see ghost.lua for the record and the maths). This module keeps the state of
-- the trip's ghost and reads/writes the record file (/settings/earthBusRoutes/ghosts/<key>.json); drawing is world.drawGhost.
-- Everything here is safe to call from main.lua: a failure turns the ghost off for the trip, never the trip itself.
local ghost = require('earthBusRoutes/ghost')
local geo = require('earthBusRoutes/geomath')
local world = require('earthBusRoutes/world')
local M = {}

M.DIR = '/settings/earthBusRoutes/ghosts/'
M.LEN_TOLERANCE = 0.02      -- a record of a route whose length differs more than this is of another road: not used
M.DEFAULT_LEN_M, M.DEFAULT_WIDTH_M = 12, 2.55
M.LINGER_S = 8              -- the ghost stays drawn this long after it has got to the end

local st = nil              -- the ghost of the running trip

local function path(key) return M.DIR .. key .. '.json' end

local function log(level, msg)
  local f = rawget(_G, 'log')
  if f then pcall(f, level, 'earthBusRoutes', 'ghost: ' .. msg) end
end

-- the switch in the add-on's options: "off" turns the ghost off (default on)
function M.enabled(opts) return not (opts and opts.ghost == 'off') end

-- A trip begins (t = trip.new's state): read the record of this line + direction + first stop, start a new recording
function M.begin(t, opts)
  st = nil
  if not M.enabled(opts) then return end
  local key = ghost.key(t.route, t.startIndex)
  st = { key = key, rec = ghost.newRecorder(t.along or 0), startIndex = t.startIndex, size = nil }
  local reader = rawget(_G, 'jsonReadFile')
  if reader then
    local ok, data = pcall(reader, path(key))
    if ok and type(data) == 'table' then
      local g, why = ghost.decode(data)
      if g and g.len and t.route.length and t.route.length > 0 and math.abs(g.len - t.route.length) > M.LEN_TOLERANCE * t.route.length then
        g, why = nil, 'another road (length differs)'
      end
      if g then st.g = g else log('W', 'record ' .. key .. ' not used: ' .. tostring(why)) end
    end
  end
  local ok, l, w = pcall(world.vehicleSize, world.vehicle())
  st.len = (ok and l) or M.DEFAULT_LEN_M
  st.width = (ok and w) or M.DEFAULT_WIDTH_M
end

-- Every frame of the trip, after trip.update
function M.update(t)
  if not st then return end
  local ok, err = pcall(function()
    if t.off ~= nil then ghost.sample(st.rec, t.elapsed, t.along) end
    local et = ghost.elapsedOf(st.rec, t.elapsed)
    st.t = et
    if st.g and et then
      st.gAlong = ghost.alongAt(st.g, et)
      st.delta = ghost.delta(st.g, et, t.along)
    end
  end)
  if not ok then
    log('W', 'off: ' .. tostring(err))
    st = nil
  end
end

-- For the HUD: nil without a ghost; { points, delta = seconds behind (+) or ahead (-) | nil, text } otherwise
function M.hud(opts)
  if not (st and st.g and M.enabled(opts)) then return nil end
  return { points = st.g.points, grade = st.g.grade, delta = st.delta, text = st.delta and ghost.deltaText(st.delta) or nil }
end

-- Every frame (the debug drawer shows what is drawn in the frame): the ghost's bus on the road
function M.draw(t, opts)
  if not (st and st.g and t and t.route and st.gAlong and st.t and M.enabled(opts)) then return end
  if st.t > st.g.dur + M.LINGER_S then return end
  local route = t.route
  local half = (st.len or M.DEFAULT_LEN_M) / 2
  local alat, alon = geo.pointAt(route.path, route.cum, math.max(0, st.gAlong - half))
  local flat, flon = geo.pointAt(route.path, route.cum, math.min(route.length or st.gAlong + half, st.gAlong + half))
  if not (alat and flat) then return end
  local z
  local veh = world.vehicle()
  if veh and veh.getPosition then
    local ok, p = pcall(function() return veh:getPosition() end)
    if ok and p then z = p.z end
  end
  world.drawGhost({ back = { lat = alat, lon = alon }, front = { lat = flat, lon = flon }, width = st.width or M.DEFAULT_WIDTH_M }, z)
end

local function ensureDir()
  local fs = rawget(_G, 'FS')
  if fs and fs.directoryCreate then pcall(function() fs:directoryCreate(M.DIR, true) end) end
end

-- The trip finished with `res` (trip.result): the record replaces the ghost when it scored more. true when a record was saved.
function M.finish(t, res)
  if not st then return false end
  local s = st
  st = nil
  local enc = ghost.finish(s.rec, { route = t.route, startIndex = s.startIndex, points = res and res.points, grade = res and res.grade,
    finished = true })
  if not enc or not ghost.better(s.g, enc) then return false end
  local writer = rawget(_G, 'jsonWriteFile')
  if not writer then return false end
  ensureDir()
  local ok, saved = pcall(writer, path(enc.key), enc, false)
  if not ok or saved == false then
    log('W', 'could not save ' .. enc.key)
    return false
  end
  return true
end

-- The trip ended without a record (cancelled, vehicle changed) or the mod unloads
function M.cancel() st = nil end

function M.state() return st end       -- for the tests

return M
