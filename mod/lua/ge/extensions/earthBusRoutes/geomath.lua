-- Pure geodesy helpers on lat/lon degrees (equirectangular: good to well under 1 % over the few km a stop or a route
-- segment spans). No game calls, so the tests run it under lupa.
local M = {}
local R = 6371008.8
local rad = math.pi / 180
-- LuaJIT (the game) has math.atan2; Lua 5.4 (the tests under lupa) only the two-argument math.atan
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- metres between two points
function M.dist(lat1, lon1, lat2, lon2)
  local dlat = (lat2 - lat1) * rad
  local dlon = (lon2 - lon1) * rad * math.cos((lat1 + lat2) * 0.5 * rad)
  return R * math.sqrt(dlat * dlat + dlon * dlon)
end

-- local metres (east, north) of p relative to the origin point
function M.toXY(oLat, oLon, lat, lon)
  return (lon - oLon) * rad * R * math.cos(oLat * rad), (lat - oLat) * rad * R
end

-- compass bearing 0..360 from point 1 to point 2
function M.bearing(lat1, lon1, lat2, lon2)
  local x, y = M.toXY(lat1, lon1, lat2, lon2)
  return (math.deg(atan2(x, y)) + 360) % 360
end

-- Nearest point of segment a-b to p: returns distance (m), t (0..1 along the segment), and the segment length (m).
function M.pointSegment(plat, plon, alat, alon, blat, blon)
  local bx, by = M.toXY(alat, alon, blat, blon)
  local px, py = M.toXY(alat, alon, plat, plon)
  local len2 = bx * bx + by * by
  local t = 0
  if len2 > 1e-9 then t = math.max(0, math.min(1, (px * bx + py * by) / len2)) end
  local dx, dy = px - bx * t, py - by * t
  return math.sqrt(dx * dx + dy * dy), t, math.sqrt(len2)
end

-- A polyline { {lat=, lon=}, ... }: cumulative metres at every vertex (cum[1] = 0) and the total length.
function M.cumulative(path)
  local cum, total = { 0 }, 0
  for i = 2, #path do
    total = total + M.dist(path[i - 1].lat, path[i - 1].lon, path[i].lat, path[i].lon)
    cum[i] = total
  end
  return cum, total
end

-- Project a point onto a polyline: returns metres along it, distance off it (m). `cum` from M.cumulative(path);
-- `from` / `to` (metres) limit the search to that part of the line (a route that doubles back on itself).
function M.along(path, cum, lat, lon, from, to)
  local bestAlong, bestOff = nil, math.huge
  for i = 2, #path do
    if (not from or cum[i] >= from) and (not to or cum[i - 1] <= to) then
      local off, t, len = M.pointSegment(lat, lon, path[i - 1].lat, path[i - 1].lon, path[i].lat, path[i].lon)
      local a = cum[i - 1] + t * len
      if (not from or a >= from) and off < bestOff then bestAlong, bestOff = a, off end
    end
  end
  return bestAlong, bestOff
end

-- Every place along a polyline a point is close to (the nearest spots of each pass: a loop or an out-and-back road goes by the
-- same stop twice): { {along, off} ... } in road order, each at most `maxOff` m off, at least `sepM` m apart; the nearest one only
-- when none is that close.
function M.alongCandidates(path, cum, lat, lon, maxOff, sepM)
  sepM = sepM or 80
  local n = #path - 1
  local offs, alongs = {}, {}
  for i = 1, n do
    local off, t, len = M.pointSegment(lat, lon, path[i].lat, path[i].lon, path[i + 1].lat, path[i + 1].lon)
    offs[i], alongs[i] = off, cum[i] + t * len
  end
  local out = {}
  for i = 1, n do
    if offs[i] <= maxOff and (i == 1 or offs[i] <= offs[i - 1]) and (i == n or offs[i] < offs[i + 1]) then
      local last = out[#out]
      if last and alongs[i] - last.along < sepM then
        if offs[i] < last.off then out[#out] = { along = alongs[i], off = offs[i] } end
      else
        out[#out + 1] = { along = alongs[i], off = offs[i] }
      end
    end
  end
  if #out == 0 and n >= 1 then
    local best = 1
    for i = 2, n do if offs[i] < offs[best] then best = i end end
    out[1] = { along = alongs[best], off = offs[best] }
  end
  return out
end

-- The point `m` metres along a polyline (clamped): lat, lon, bearing
function M.pointAt(path, cum, m)
  if #path == 0 then return nil end
  if #path == 1 or m <= 0 then return path[1].lat, path[1].lon, 0 end
  local total = cum[#path]
  if m >= total then
    local a, b = path[#path - 1], path[#path]
    return b.lat, b.lon, M.bearing(a.lat, a.lon, b.lat, b.lon)
  end
  for i = 2, #path do
    if cum[i] >= m then
      local a, b = path[i - 1], path[i]
      local seg = cum[i] - cum[i - 1]
      local t = seg > 0 and (m - cum[i - 1]) / seg or 0
      return a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t, M.bearing(a.lat, a.lon, b.lat, b.lon)
    end
  end
end

return M
