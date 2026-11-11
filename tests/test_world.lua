-- world.drawMarkers with a stubbed debug drawer and BeamNG.Earth's toGame.
local H = dofile('tests/harness.lua')
local markers = require('earthBusRoutes/markers')
local T = {}

local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__mul = function(a, k) return setmetatable({ x = a.x * k, y = a.y * k, z = a.z * k }, V) end

local function stubs(opts)
  opts = opts or {}
  H.reset()
  _G.vec3 = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
  _G.ColorF = function(...) return { ... } end
  _G.ColorI = function(...) return { ... } end
  local calls = {}
  local dd = {}
  for _, name in ipairs({ 'drawTriangle', 'drawLine', 'drawSphere', 'drawTextAdvanced' }) do
    dd[name] = function(self, ...)
      if opts.failOn == name then error('boom') end
      calls[name] = (calls[name] or 0) + 1
    end
  end
  _G.debugDrawer = dd
  _G.beamngEarth_api = {
    version = function() return 1, 6 end,
    has = function(n) return n == 'transform' and opts.transform ~= false end,
    toGame = function(lat, lon, h) return (lon - 16) * 70000, (lat - 50) * 111000, 300 end,
  }
  package.loaded['earthBusRoutes/world'] = nil
  return H.load('mod/lua/ge/extensions/earthBusRoutes/world.lua'), calls
end

local function item()
  local r = { path = { { lat = 50.0, lon = 16.0 }, { lat = 50.0, lon = 16.01 } }, ref = '305', to = 'X' }
  r.cum = { 0, 715 }
  return { kind = 'next', index = 1, name = 'Stop', zone = markers.zone(r, 300), ref = '305', to = 'X', waiting = 2 }
end

function T.a_next_stop_is_drawn_as_a_zone_a_pole_and_a_text()
  local world, calls = stubs()
  assert(world.markersAvailable())
  world.drawMarkers({ item() }, 300)
  assert(calls.drawTriangle == 2 and calls.drawLine == 5 and calls.drawSphere == 1 and calls.drawTextAdvanced == 1, 'drew ' .. tostring(calls.drawTriangle))
  world.drawMarkers({}, 300)
  assert(calls.drawTriangle == 2, 'nothing for an empty list')
end

function T.without_earths_coordinates_there_are_no_markers()
  local world, calls = stubs({ transform = false })
  assert(not world.markersAvailable())
  world.drawMarkers({ item() }, 300)
  assert(next(calls) == nil)
end

function T.a_failing_drawer_turns_the_markers_off_without_an_error()
  local world, calls = stubs({ failOn = 'drawSphere' })
  world.drawMarkers({ item() }, 300)
  assert(not world.markersAvailable(), 'off after the first failure')
  local n = calls.drawLine
  world.drawMarkers({ item() }, 300)
  assert(calls.drawLine == n, 'nothing drawn any more')
  assert(#H.logs >= 1 and H.logs[#H.logs]:find('markers off'))
end

return T
