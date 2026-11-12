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
  _G.ColorF = function(...) return { kind = 'ColorF', ... } end
  _G.ColorI = function(...) return { kind = 'ColorI', ... } end
  _G.color = nil                  -- (packed by hand, as the game's color() does; one test sets it)
  _G.quatFromEuler = function() return setmetatable({ x = 0, y = 0, z = 0, w = 1 }, Q) end
  _G.quatFromDir = function() return setmetatable({ x = 0, y = 0, z = 0, w = 1 }, Q) end
  local calls, objects = {}, {}
  local dd = {}
  -- what the game's drawer takes (BeamNG 0.40, its own calls in lua/ge): a triangle's colour is ONE number (color(r, g, b,
  -- a)), a line's a ColorF, a text's a ColorF and a ColorI behind it. Anything else throws, as the game does.
  local function want(cond, msg) if not cond then error(msg, 3) end end
  local function isVec(p) return type(p) == 'table' and type(p.x) == 'number' end
  local check = {
    drawTriSolid = function(a, b, c, col)
      want(isVec(a) and isVec(b) and isVec(c), 'bad argument: a point expected')
      want(type(col) == 'number', "bad argument #4 to 'drawTriSolid' (number expected, got " .. type(col) .. ')')
      calls.triColours = calls.triColours or {}
      calls.triColours[#calls.triColours + 1] = col
    end,
    drawLine = function(a, b, col)
      want(isVec(a) and isVec(b) and type(col) == 'table' and col.kind == 'ColorF', "bad argument to 'drawLine'")
    end,
    drawTextAdvanced = function(p, text, col, adv, twod, bg)
      want(isVec(p) and type(col) == 'table' and col.kind == 'ColorF' and type(bg) == 'table' and bg.kind == 'ColorI',
        "bad argument to 'drawTextAdvanced'")
      calls.text = text
    end,
  }
  for name, chk in pairs(check) do
    dd[name] = function(self, ...)
      if opts.failOn == name then error('boom') end
      chk(...)
      calls[name] = (calls[name] or 0) + 1
    end
  end
  _G.debugDrawer = dd
  -- the game's minimap utils (ui/apps/minimap/utils.lua): a dot at a game position, a dot or an edge pointer
  if opts.minimap ~= false then
    local dots = {}
    calls.dots = dots
    local function dot(kind) return function(pos, fill, stroke, radius)
      if opts.failOn == 'minimap' then error('boom') end
      want(isVec(pos) and type(fill) == 'number' and type(stroke) == 'number', 'bad minimap dot')
      dots[#dots + 1] = { kind = kind, x = pos.x, y = pos.y, fill = fill, radius = radius }
    end end
    _G.ui_apps_minimap_utils = { simpleCircle = dot('circle'), simpleCircleWithEdgePointer = dot('pointer') }
  else
    _G.ui_apps_minimap_utils = nil
  end
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
  assert(not (calls.drawTriSolid or calls.drawLine or calls.drawTextAdvanced) and #objects == 0)
end

function T.a_failing_drawer_turns_the_markers_off_without_an_error()
  local world, calls = stubs({ failOn = 'drawLine' })
  world.drawMarkers({ item() }, 300)
  assert(not world.markersAvailable(), 'off after the first failure')
  local n = calls.drawTriSolid
  world.drawMarkers({ item() }, 300)
  assert(calls.drawTriSolid == n, 'nothing drawn any more')
  assert(#H.logs >= 1 and H.logs[#H.logs]:find('markers off'))
end

-- 0.9.2-0.10.2: the fill got a ColorI, the game's drawTriSolid threw on the first frame of every trip and all the markers
-- of the session went off (beamng.log: "bad argument #4 to 'drawTriSolid' (number expected, got userdata)")
function T.the_fill_colour_is_one_packed_number_as_the_game_takes_it()
  local world, calls = stubs()
  world.drawMarkers({ item() }, 300)
  assert(world.markersAvailable() and calls.drawTriSolid == 6, 'drawn, not turned off')
  -- red 255, 20, 12 at alpha 48 for the bay; 110 for the arrow
  local bay = 255 * 16777216 + 20 * 65536 + 12 * 256 + 48
  assert(calls.triColours[1] == bay, 'packed r, g, b, a: ' .. tostring(calls.triColours[1]))
  assert(calls.triColours[5] % 256 == 110, 'the arrow stronger')
  -- the game's own color() is used when it is there
  _G.color = function(r, g, b, a) return 7 end
  world.drawMarkers({ item() }, 300)
  _G.color = nil
  assert(calls.triColours[#calls.triColours] == 7)
  assert(world.packed(300, -5, 128.9, nil) == 255 * 16777216 + 0 + 128 * 256 + 255, 'clamped, floored, alpha 255 by default')
end

function T.a_failing_fill_or_name_leaves_the_rest_of_the_markers()
  local world, calls, objects = stubs({ failOn = 'drawTriSolid' })
  world.drawMarkers({ item() }, 300)
  assert(world.markersAvailable(), 'only the fills go')
  assert(#objects == 4 and calls.drawLine == 4 and calls.drawTextAdvanced == 1, 'corners, edges and the name stay')
  assert(H.logs[#H.logs]:find('fills off'))
  local w2, c2, o2 = stubs({ failOn = 'drawTextAdvanced' })
  w2.drawMarkers({ item() }, 300)
  w2.drawMarkers({ item() }, 300)
  assert(w2.markersAvailable() and #o2 == 4 and c2.drawTriSolid == 12, 'the bay is drawn on without its name')
end

-- ---- the minimap ----
local function mini(over)
  local s = { lat = 50.001, lon = 16.002, kind = 'next', colour = markers.COLOURS.approach }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

function T.the_next_stops_go_on_the_games_minimap()
  local world, calls = stubs()
  world.drawMinimap({ mini(), mini({ kind = 'soon', colour = markers.COLOURS.soon, lat = 50.002 }) })
  local d = calls.dots
  assert(#d == 2, 'two dots: ' .. #d)
  assert(d[2].kind == 'pointer' and d[2].radius == 8, 'the next one last (on top), with a pointer from the edge')
  assert(d[1].kind == 'circle' and d[1].radius == 5, 'the one after it: a small dot')
  assert(math.abs(d[2].x - 140) < 1e-6 and math.abs(d[2].y - 111) < 1e-6, 'at the game position of the stop (toGame)')
  assert(d[2].fill == 255 * 16777216 + 20 * 65536 + 12 * 256 + 255, 'red, as the bay: ' .. tostring(d[2].fill))
end

function T.the_minimap_needs_its_app_and_earths_coordinates_and_a_failure_turns_only_it_off()
  local world, calls = stubs({ minimap = false })
  world.drawMinimap({ mini() })                          -- no minimap app: nothing, no error
  local w2, c2 = stubs({ transform = false })
  w2.drawMinimap({ mini() })
  assert(#c2.dots == 0)
  local w3, c3 = stubs({ failOn = 'minimap' })
  w3.drawMinimap({ mini() })
  assert(H.logs[#H.logs]:find('minimap off'))
  w3.drawMarkers({ item() }, 300)
  assert(w3.markersAvailable() and c3.drawTriSolid == 6, 'the markers on the road go on')
end

local function ghostSpec() return { back = { lat = 50.0, lon = 16.0 }, front = { lat = 50.0, lon = 16.00017 }, width = 2.55 } end

function T.the_ghost_is_a_filled_rectangle_with_an_edge_and_an_arrow()
  local world, calls = stubs()
  assert(world.ghostAvailable())
  world.drawGhost(ghostSpec(), 300)
  assert(calls.drawTriSolid == 6, 'two triangles of the body and one of the arrow, both faces: ' .. tostring(calls.drawTriSolid))
  assert(calls.drawLine == 4 and calls.drawTextAdvanced == nil)
end

function T.the_ghost_follows_the_ground_of_the_game()
  local world, calls = stubs()
  local seen = {}
  _G.be = { getSurfaceHeightBelow = function(_, p) seen[#seen + 1] = p.z return 310 end }
  world.drawGhost(ghostSpec(), 300)
  _G.be = nil
  assert(#seen >= 5 and seen[1] == 340, 'looked for from above the bus: ' .. tostring(seen[1]))
  assert(calls.drawTriSolid == 6)
end

function T.the_ghost_needs_earths_coordinates_and_a_failure_turns_only_it_off()
  local world, calls = stubs({ transform = false })
  assert(not world.ghostAvailable())
  world.drawGhost(ghostSpec(), 300)
  assert(not (calls.drawTriSolid or calls.drawLine or calls.drawTextAdvanced))
  local w2, c2 = stubs({ failOn = 'drawLine' })
  w2.drawGhost(ghostSpec(), 300)                          -- no error
  assert(not w2.ghostAvailable() and w2.markersAvailable(), 'the stop markers go on')
  local n = c2.drawTriSolid
  w2.drawGhost(ghostSpec(), 300)
  assert(c2.drawTriSolid == n and H.logs[#H.logs]:find('ghost off'))
  -- a rectangle of no length (the same point twice) is not drawn
  local w3, c3 = stubs()
  w3.drawGhost({ back = { lat = 50, lon = 16 }, front = { lat = 50, lon = 16 }, width = 2.5 }, 300)
  assert(not (c3.drawTriSolid or c3.drawLine or c3.drawTextAdvanced))
end

function T.the_size_of_the_vehicle_is_asked_in_a_safe_way()
  local world = stubs()
  assert(world.vehicleSize(nil) == nil)
  assert(world.vehicleSize({}) == nil, 'no such method')
  local l, w = world.vehicleSize({ getInitialLength = function() return 12.1 end, getInitialWidth = function() return 2.55 end })
  assert(l == 12.1 and w == 2.55)
  assert(world.vehicleSize({ getInitialLength = function() return 0.1 end, getInitialWidth = function() return 2.5 end }) == nil, 'nonsense')
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
