-- world.drawMarkers with a stubbed debug drawer, the game's objects and BeamNG.Earth's toGame.
local H = dofile('tests/harness.lua')
local markers = require('earthBusRoutes/markers')
local T = {}

local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V) end
V.__mul = function(a, k) return setmetatable({ x = a.x * k, y = a.y * k, z = a.z * k }, V) end
local Q = {}
Q.__index = Q
Q.__mul = function(a, b) return setmetatable({ x = 0, y = 0, z = 0, w = 1, parts = (a.parts or 1) + (b.parts or 1) }, Q) end

local function stubs(opts)
  opts = opts or {}
  H.reset()
  _G.vec3 = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
  _G.ColorF = function(...) return { ... } end
  _G.ColorI = function(...) return { ... } end
  _G.quatFromEuler = function() return setmetatable({ x = 0, y = 0, z = 0, w = 1 }, Q) end
  _G.quatFromDir = function() return setmetatable({ x = 0, y = 0, z = 0, w = 1 }, Q) end
  local calls, objects = {}, {}
  local dd = {}
  for _, name in ipairs({ 'drawTriSolid', 'drawLine', 'drawTextAdvanced' }) do
    dd[name] = function(self, ...)
      if opts.failOn == name then error('boom') end
      calls[name] = (calls[name] or 0) + 1
      if name == 'drawTextAdvanced' then calls.text = select(2, ...) end
    end
  end
  _G.debugDrawer = dd
  if opts.objects ~= false then
    _G.createObject = function(kind)
      if opts.failObjects then error('no objects') end
      local o = { kind = kind, fields = {}, deleted = false }
      function o:setField(k, _, v) self.fields[k] = v end
      function o:setPosition() end
      function o:setPosRot(x, y, z) self.pos = { x, y, z } end
      function o:registerObject(n) self.name = n end
      function o:delete() self.deleted = true end
      objects[#objects + 1] = o
      return o
    end
  else
    _G.createObject = nil
  end
  _G.beamngEarth_api = {
    version = function() return 1, 6 end,
    has = function(n) return n == 'transform' and opts.transform ~= false end,
    toGame = function(lat, lon, h) return (lon - 16) * 70000, (lat - 50) * 111000, 300 end,
  }
  package.loaded['earthBusRoutes/world'] = nil
  return H.load('mod/lua/ge/extensions/earthBusRoutes/world.lua'), calls, objects
end

local function item(over)
  local r = { path = { { lat = 50.0, lon = 16.0 }, { lat = 50.0, lon = 16.01 } }, ref = '305', to = 'X' }
  r.cum = { 0, 715 }
  local it = { kind = 'next', state = 'approach', alpha = 1, index = 1, name = 'Stop', zone = markers.zone(r, 300), ref = '305',
    to = 'X', waiting = 2, ahead = 100 }
  for k, v in pairs(over or {}) do it[k] = v end
  return it
end

local function colourOf(o) return o.fields.instanceColor end

function T.a_next_stop_gets_the_games_corner_markers_a_fill_an_arrow_and_its_name()
  local world, calls, objects = stubs()
  assert(world.markersAvailable())
  world.drawMarkers({ item() }, 300)
  assert(#objects == 4 and objects[1].fields.shapeName == 'art/shapes/interface/position_marker.dae', 'the game bus mode shape')
  assert(objects[1].fields.collisionType == 'None', 'the bus drives over them')
  for _, o in ipairs(objects) do assert(o.pos and colourOf(o):find('^1%.000 0%.080'), 'red while coming: ' .. colourOf(o)) end
  assert(calls.drawTriSolid == 6, 'two triangles of the bay and the arrow, both faces: ' .. tostring(calls.drawTriSolid))
  assert(calls.drawLine == 4 and calls.drawTextAdvanced == 1)
  assert(calls.text == 'Stop  -  2 waiting', 'one line, no line breaks: ' .. tostring(calls.text))
  -- in the bay: orange; the same four objects
  world.drawMarkers({ item({ state = 'inside' }) }, 300)
  assert(#objects == 4 and colourOf(objects[1]):find('^1%.000 0%.500'))
  -- nothing to show: hidden (alpha 0), not deleted
  world.drawMarkers({}, 300)
  assert(colourOf(objects[1]):find(' 0$') and not objects[1].deleted)
  -- a stop just served fades green on its own four markers while the next one is red
  world.drawMarkers({ item({ kind = 'done', state = 'done', alpha = 0.5 }), item({ index = 2 }) }, 300)
  assert(#objects == 8)
  assert(colourOf(objects[5]):find('0%.100 0%.900 0%.200 0%.500'), 'green, half faded: ' .. colourOf(objects[5]))
  world.clearMarkers()
  for _, o in ipairs(objects) do assert(o.deleted) end
end

function T.the_stops_after_it_are_only_outlined()
  local world, calls, objects = stubs()
  world.drawMarkers({ item({ kind = 'soon', state = 'soon' }) }, 300)
  assert(#objects == 0 and calls.drawLine == 4 and calls.drawTriSolid == nil and calls.drawTextAdvanced == nil)
end

function T.a_far_bay_has_no_text()
  local world, calls = stubs()
  world.drawMarkers({ item({ ahead = 600 }) }, 300)
  assert(calls.drawTextAdvanced == nil and calls.drawTriSolid == 6)
end

function T.without_the_games_objects_the_bay_is_still_drawn()
  local world, calls, objects = stubs({ failObjects = true })
  world.drawMarkers({ item() }, 300)
  assert(#objects == 0 and calls.drawTriSolid == 6 and world.markersAvailable())
  assert(H.logs[#H.logs]:find('corner markers off'))
end

function T.without_earths_coordinates_there_are_no_markers()
  local world, calls, objects = stubs({ transform = false })
  assert(not world.markersAvailable())
  world.drawMarkers({ item() }, 300)
  assert(next(calls) == nil and #objects == 0)
end

function T.a_failing_drawer_turns_the_markers_off_without_an_error()
  local world, calls = stubs({ failOn = 'drawTextAdvanced' })
  world.drawMarkers({ item() }, 300)
  assert(not world.markersAvailable(), 'off after the first failure')
  local n = calls.drawLine
  world.drawMarkers({ item() }, 300)
  assert(calls.drawLine == n, 'nothing drawn any more')
  assert(#H.logs >= 1 and H.logs[#H.logs]:find('markers off'))
end

function T.the_indicators_are_read_defensively()
  H.reset()
  local world = H.load('mod/lua/ge/extensions/earthBusRoutes/world.lua')
  local veh = { getID = function() return 7 end }
  assert(world.signal(veh, 'L') == nil, 'no bridge: unknown')
  local values, watched = {}, {}
  _G.core_vehicleBridge = {
    registerValueChangeNotification = function(v, k) watched[#watched + 1] = k end,
    getCachedVehicleData = function(id, k) assert(id == 7) if k == 'boom' then error('x') end return values[k] end,
  }
  world.watchSignals(veh)
  assert(#watched == 4)
  assert(world.signal(veh, 'L') == nil and world.signal(veh, 'R') == nil, 'never reported: unknown, not off')
  values.signal_L = 0
  assert(world.signal(veh, 'L') == false and world.signal(veh, 'R') == nil)
  values.signal_left_input = 1                                 -- the lever, while the lamp is in its dark half
  assert(world.signal(veh, 'L') == true)
  values.signal_R = 1
  assert(world.signal(veh, 'R') == true)
  _G.core_vehicleBridge.getCachedVehicleData = function() error('gone') end
  assert(world.signal(veh, 'L') == nil, 'a failing bridge is silent')
  _G.core_vehicleBridge = nil
end

return T
