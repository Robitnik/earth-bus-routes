-- Where the markers of the stops go: a yellow zone on the road beside the stop, as in the game's own bus mode, but without a
-- stopping point (the whole zone counts, as for the trip) (pure: the tests run it; world.lua draws what this lays out).
local geo = require('earthBusRoutes/geomath')
local M = {}

M.LENGTH_M = 16          -- the zone along the road
M.WIDTH_M = 3.6          -- across it: a lane
M.LANE_OFFSET_M = 2.4    -- from the road's line to the middle of the zone: the lane on the right of the way of travel
M.SHOW_M = 700           -- a stop is marked from this far along the road
M.SOON_COUNT = 2         -- the stops after the next one, drawn lighter

local function offsetLatLon(lat, lon, east, north)
  return lat + north / 111195, lon + east / (111195 * math.cos(math.rad(lat)))
end

-- The zone of a stop: { corners = { {lat, lon} x4 in order }, centre = {lat, lon}, bearing } or nil. `along`: metres along the road.
function M.zone(route, along)
  if not (route and route.path and #route.path >= 2) then return nil end
  local lat, lon, bearing = geo.pointAt(route.path, route.cum, along)
  if not lat then return nil end
  local b = math.rad(bearing or 0)
  local fx, fy = math.sin(b), math.cos(b)          -- forward (east, north)
  local rx, ry = math.cos(b), -math.sin(b)         -- right of the way of travel
  local function at(f, r)
    local e = fx * f + rx * r
    local n = fy * f + ry * r
    local la, lo = offsetLatLon(lat, lon, e, n)
    return { la, lo }
  end
  local h, w, o = M.LENGTH_M / 2, M.WIDTH_M / 2, M.LANE_OFFSET_M
  local cl, cn = offsetLatLon(lat, lon, rx * o, ry * o)
  return { corners = { at(-h, o - w), at(h, o - w), at(h, o + w), at(-h, o + w) }, centre = { cl, cn }, bearing = bearing or 0 }
end

-- The markers to draw for a trip in progress (trip.lua state): the next stop (kind 'next') and the SOON_COUNT after it
-- (kind 'soon'), each within SHOW_M along the road. Items: { kind, index, name, zone, waiting, ref, to }.
function M.plan(t)
  local out = {}
  local r = t.route
  for k = 0, M.SOON_COUNT do
    local i = t.idx + k
    local s = r.stops[i]
    if not s then break end
    local ahead = (s.along or 0) - (t.along or 0)
    if ahead <= M.SHOW_M and ahead > -80 then
      local z = M.zone(r, s.along or 0)
      if z then
        out[#out + 1] = { kind = k == 0 and 'next' or 'soon', index = i, name = s.name, zone = z, ref = r.ref, to = r.to,
          waiting = k == 0 and t.waiting or nil, ahead = ahead }
      end
    end
  end
  return out
end

-- One stop: the start stop of a trip that waits for the bus
function M.planStart(route, stop)
  local z = M.zone(route, stop.along or 0)
  if not z then return {} end
  return { { kind = 'next', index = stop.index or 1, name = stop.name, zone = z, ref = route.ref, to = route.to } }
end

-- The text over the zone
function M.label(item)
  local lines = {}
  if item.kind == 'next' then
    lines[1] = tostring(item.ref or '') .. ' → ' .. tostring(item.to or '')
    lines[2] = tostring(item.name or '')
    if item.waiting and item.waiting > 0 then lines[3] = tostring(item.waiting) .. ' waiting' end
  else
    lines[1] = tostring(item.name or '')
  end
  return table.concat(lines, '\n')
end

return M
