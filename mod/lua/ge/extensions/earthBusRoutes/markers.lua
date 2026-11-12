-- Where the markers of the stops go, as in the game's own bus mode: the four corner markers of the stop's bay on the road
-- (red while you come, orange while the bus is in it, green when the stop is done, then they fade), with a light fill of the
-- same colour, an arrow of the way to stand and the stop's name over it. The whole bay counts (as for the trip).
-- Pure: the tests run it; world.lua draws what this lays out.
local geo = require('earthBusRoutes/geomath')
local M = {}

M.LENGTH_M = 16          -- the zone along the road
M.WIDTH_M = 3.6          -- across it: a lane
M.LANE_OFFSET_M = 2.4    -- from the road's line to the middle of the zone: the lane on the right of the way of travel
M.SHOW_M = 700           -- a stop is marked from this far along the road
M.SOON_COUNT = 2         -- the stops after the next one, drawn lighter
M.DONE_FADE_S = 2.5      -- a stop just served stays green this long, fading

-- the colours of a bay (r, g, b in 0..1), as the game's bus mode: coming, in it, done
M.COLOURS = { approach = { 1, 0.08, 0.05 }, inside = { 1, 0.5, 0 }, done = { 0.1, 0.9, 0.2 }, soon = { 1, 0.8, 0.1 },
  closed = { 0.55, 0.55, 0.58 } }       -- a stop out of service (a dispatcher event): grey

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

-- The markers to draw for a trip in progress (trip.lua state): the next stop (kind 'next', state 'approach' or 'inside') and
-- the SOON_COUNT after it (kind 'soon'), each within SHOW_M along the road; `done` = { index, at } of the stop just served
-- (kind 'done', fading for DONE_FADE_S after `now`). Items: { kind, state, alpha, index, name, zone, waiting, ref, to, ahead }.
function M.plan(t, done, now)
  local out = {}
  if done and now and done.at and now - done.at < M.DONE_FADE_S then
    local s = t.route.stops[done.index]
    local z = s and M.zone(t.route, s.along or 0)
    if z then
      out[#out + 1] = { kind = 'done', state = 'done', alpha = 1 - (now - done.at) / M.DONE_FADE_S, index = done.index,
        name = s.name, zone = z, ref = t.route.ref, to = t.route.to, ahead = (s.along or 0) - (t.along or 0) }
    end
  end
  local r = t.route
  for k = 0, M.SOON_COUNT do
    local i = t.idx + k
    local s = r.stops[i]
    if not s then break end
    local ahead = (s.along or 0) - (t.along or 0)
    if ahead <= M.SHOW_M and ahead > -80 then
      local z = M.zone(r, s.along or 0)
      if z then
        local state = 'soon'
        if k == 0 then
          state = (t.inZone or t.phase == 'atStop' or t.phase == 'start') and 'inside' or 'approach'
        end
        if t.extra and t.extra[i] and t.extra[i].closed then state = 'closed' end
        out[#out + 1] = { kind = k == 0 and 'next' or 'soon', state = state, alpha = 1, index = i, name = s.name, zone = z,
          ref = r.ref, to = r.to, waiting = k == 0 and t.waiting or nil, ahead = ahead }
      end
    end
  end
  return out
end

-- The stops on the game's minimap for a trip in progress: the next one (the colour of its bay: coming, in it, out of
-- service) and the MINIMAP_COUNT after it (yellow, smaller), wherever they are (the minimap shows the ones round the bus
-- and points to the next one from its edge). { { lat, lon, kind = 'next' | 'soon', colour, index, name } }, the next first.
M.MINIMAP_COUNT = 8
function M.minimap(t)
  local out = {}
  local r = t and t.route
  if not (r and r.stops) then return out end
  for k = 0, M.MINIMAP_COUNT do
    local i = (t.idx or 1) + k
    local s = r.stops[i]
    if not s then break end
    if s.lat and s.lon then
      local state = 'soon'
      if k == 0 then state = (t.inZone or t.phase == 'atStop' or t.phase == 'start') and 'inside' or 'approach' end
      if t.extra and t.extra[i] and t.extra[i].closed then state = 'closed' end
      out[#out + 1] = { lat = s.lat, lon = s.lon, kind = k == 0 and 'next' or 'soon', colour = M.COLOURS[state], index = i,
        name = s.name }
    end
  end
  return out
end

-- One stop: the start stop of a trip that waits for the bus
function M.planStart(route, stop)
  local z = M.zone(route, stop.along or 0)
  if not z then return {} end
  return { { kind = 'next', state = 'approach', alpha = 1, index = stop.index or 1, name = stop.name, zone = z, ref = route.ref,
    to = route.to } }
end

-- The text over the bay, one string per line (the game's text drawer has no line breaks): the stop's name first, then how
-- many wait (the next stop only), then the line; nothing for the stops after it.
function M.labelLines(item)
  if item.kind == 'soon' then return {} end
  local lines = { tostring(item.name or '') }
  if item.kind == 'done' then return lines end
  if item.waiting and item.waiting > 0 then lines[#lines + 1] = tostring(item.waiting) .. ' waiting' end
  lines[#lines + 1] = tostring(item.ref or '') .. ' > ' .. tostring(item.to or '')
  return lines
end

-- the one line drawn over the bay: the name and how many wait (the line and its end are on the HUD)
function M.label(item)
  local l = M.labelLines(item)
  if #l == 0 then return '' end
  if item.kind == 'next' and item.waiting and item.waiting > 0 then return l[1] .. '  -  ' .. l[2] end
  return l[1]
end

-- The arrow on the bay's floor, the way the bus stands (lat, lon): its tip near the front, its base across the back third.
function M.arrow(zone)
  local c = zone.corners                         -- back-left, front-left, front-right, back-right (left = the road's side)
  local function mix(a, b, k) return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k } end
  local backMid, frontMid = mix(c[1], c[4], 0.5), mix(c[2], c[3], 0.5)
  local tip = mix(backMid, frontMid, 0.82)
  local baseMid = mix(backMid, frontMid, 0.38)
  local half = { (c[4][1] - c[1][1]) * 0.28, (c[4][2] - c[1][2]) * 0.28 }
  return { tip, { baseMid[1] - half[1], baseMid[2] - half[2] }, { baseMid[1] + half[1], baseMid[2] + half[2] } }
end

return M
