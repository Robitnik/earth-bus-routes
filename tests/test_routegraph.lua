local H = dofile('tests/harness.lua')
local R = require('earthBusRoutes/routegraph')
local geo = require('earthBusRoutes/geomath')
local T = {}

-- ---------------------------------------------------------------------------------------------------- scaffolding
local O = { 50.0, 16.0 }
local RE = 6371008.8
local function ll(x, y)
  return O[1] + math.deg(y / RE), O[2] + math.deg(x / (RE * math.cos(math.rad(O[1]))))
end
local function toGame(lat, lon)
  local x, y = geo.toXY(O[1], O[2], lat, lon)
  return x, y
end
local function opts(extra)
  local o = { toGame = toGame }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local function node(g, name, x, y, z, radius)
  g[name] = { pos = { x = x, y = y, z = z or 0 }, radius = radius or 4, links = {} }
end
local function link(g, a, b, oneWay)
  local e = { oneWay = oneWay or false, inNode = a, outNode = b, drivability = 1 }
  g[a].links[b] = e
  g[b].links[a] = e
  return e
end
-- nodes prefix1.. along a list of {x, y[, z]}, linked in order
local function chain(g, prefix, pts, oneWay, radius)
  local names = {}
  for i, p in ipairs(pts) do
    node(g, prefix .. i, p[1], p[2], p[3], radius)
    names[i] = prefix .. i
    if i > 1 then link(g, names[i - 1], names[i], oneWay) end
  end
  return names
end
local function line(x0, y0, x1, y1, step)
  local out, len = {}, math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
  local n = math.max(1, math.floor(len / step + 0.5))
  for i = 0, n do out[#out + 1] = { x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n } end
  return out
end
local function concat(...)
  local out = {}
  for _, l in ipairs({ ... }) do
    for i, p in ipairs(l) do
      local last = out[#out]
      if not (i == 1 and last and math.abs(last[1] - p[1]) < 1e-6 and math.abs(last[2] - p[2]) < 1e-6) then out[#out + 1] = p end
    end
  end
  return out
end
-- a route over game points; stops = { {along =, off = (m to the right of travel; negative: left)} }
local function route(pts, stops)
  local path, xy = {}, { 0 }
  for i, p in ipairs(pts) do
    local lat, lon = ll(p[1], p[2])
    path[i] = { lat = lat, lon = lon }
    if i > 1 then xy[i] = xy[i - 1] + math.sqrt((p[1] - pts[i - 1][1]) ^ 2 + (p[2] - pts[i - 1][2]) ^ 2) end
  end
  local r = { path = path, cum = geo.cumulative(path), stops = {} }
  for si, s in ipairs(stops or {}) do
    local k = 2
    while k < #pts and xy[k] < s.along do k = k + 1 end
    local a, b = pts[k - 1], pts[k]
    local seg = xy[k] - xy[k - 1]
    local f = seg > 0 and (s.along - xy[k - 1]) / seg or 0
    local x, y = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
    local dx, dy = (b[1] - a[1]) / seg, (b[2] - a[2]) / seg
    local lat, lon = ll(x + dy * s.off, y - dx * s.off)
    r.stops[si] = { id = si, name = 'S' .. si, lat = lat, lon = lon, along = s.along }
  end
  return r
end
local function near(a, b, tol, msg) assert(math.abs(a - b) <= tol, (msg or 'value') .. ': ' .. a .. ' vs ' .. b) end
local function names(prefix, from, to)
  local out = {}
  for i = from, to do out[#out + 1] = prefix .. i end
  return out
end
local function same(got, want, msg)
  assert(#got == #want, (msg or 'path') .. ': ' .. table.concat(got, ',') .. ' vs ' .. table.concat(want, ','))
  for i = 1, #want do assert(got[i] == want[i], (msg or 'path') .. ' at ' .. i .. ': ' .. table.concat(got, ',')) end
end
local function indexOf(list, v)
  for i, x in ipairs(list) do if x == v then return i end end
end
local function has(list, v) return indexOf(list, v) ~= nil end
local function straight(n, y)
  local pts = {}
  for i = 1, n do pts[i] = { (i - 1) * 50, y or 0 } end
  return pts
end
local function wobble(pts, amp)
  local out = {}
  for i, p in ipairs(pts) do out[i] = { p[1], p[2] + amp * math.sin(i * 1.7) } end
  return out
end

-- ------------------------------------------------------------------------------------------------------ basic matching
function T.straight_road_with_wobble_and_stops_on_both_sides()
  local g = {}
  chain(g, 'N', straight(11))
  local r = route(wobble(line(0, 0, 500, 0, 25), 2), { { along = 100, off = 6 }, { along = 250, off = -7 }, { along = 400, off = 6 } })
  local res = assert(R.build(r, g, opts()))
  same(res.path, names('N', 1, 11))
  near(res.length, 500, 1, 'length')
  assert(res.ok and res.complete, table.concat(res.warnings, ','))
  assert(#res.stops == 3 and #res.droppedStops == 0)
  near(res.stops[1].along, 100, 3)
  near(res.stops[2].along, 250, 3)
  near(res.stops[3].along, 400, 3)
  assert(res.stops[1].side == 1 and res.stops[2].side == -1 and res.stops[3].side == 1)
  near(res.stops[1].offset, 6, 3)
  assert(res.stops[1].sideOk and not res.stops[2].sideOk)
  near(res.stops[1].dirX, 1, 0.01)
  assert(#res.junctions == 0 and res.nodes[1].degree == 1 and res.nodes[2].degree == 2)
  -- the same on left-hand traffic: the right-hand platform is on the wrong side
  local rl = assert(R.build(r, g, opts({ leftHand = true })))
  assert(not rl.stops[1].sideOk and rl.stops[2].sideOk)
end

function T.long_edge_without_shape_nodes_still_matches()
  local g = {}
  node(g, 'L1', 0, 0) node(g, 'L2', 400, 0) link(g, 'L1', 'L2')
  local r = route(wobble(line(0, 0, 400, 0, 25), 8), { { along = 200, off = 5 } })
  local res = assert(R.build(r, g, opts()))
  same(res.path, { 'L1', 'L2' })
  near(res.stops[1].along, 200, 14)
end

function T.t_junction_turn_junction_info_and_both_directions()
  local g = {}
  chain(g, 'M', straight(9))
  chain(g, 'S', { { 200, 50 }, { 200, 100 }, { 200, 150 }, { 200, 200 } })
  link(g, 'M5', 'S1')
  local r = route(concat(line(0, 0, 200, 0, 25), line(200, 0, 200, 200, 25)), { { along = 100, off = 6 }, { along = 300, off = 6 } })
  local res = assert(R.build(r, g, opts()))
  same(res.path, { 'M1', 'M2', 'M3', 'M4', 'M5', 'S1', 'S2', 'S3', 'S4' })
  assert(res.ok)
  assert(#res.junctions == 1 and res.junctions[1].name == 'M5' and res.junctions[1].degree == 3)
  near(res.junctions[1].along, 200, 0.5)
  near(res.nodes[5].turn, 90, 5, 'left turn at the junction')
  assert(res.nodes[5].junction and not res.nodes[4].junction)
  near(res.stops[1].junctionAhead, 100, 4)
  near(res.stops[2].junctionBehind, 100, 4)
  local ahead = R.junctionsAhead(res, 50, 200)
  assert(#ahead == 1 and ahead[1].name == 'M5')
  near(ahead[1].dist, 150, 0.5)
  assert(#R.junctionsAhead(res, 250, 200) == 0)
  -- a right turn from the side road
  local back = route(concat(line(200, 200, 200, 0, 25), line(200, 0, 400, 0, 25)))
  local rb = assert(R.build(back, g, opts()))
  same(rb.path, { 'S4', 'S3', 'S2', 'S1', 'M5', 'M6', 'M7', 'M8', 'M9' })
  near(rb.nodes[5].turn, 90, 5)
end

local function roundabout()
  local g = {}
  local ring = {}
  for k = 0, 7 do
    node(g, 'R' .. k, 200 + 20 * math.cos(math.rad(45 * k)), 20 * math.sin(math.rad(45 * k)))
    ring[k] = 'R' .. k
  end
  for k = 0, 7 do link(g, 'R' .. k, 'R' .. ((k + 1) % 8), true) end    -- counter-clockwise: right-hand traffic
  chain(g, 'W', { { 0, 0 }, { 50, 0 }, { 100, 0 }, { 150, 0 } })
  link(g, 'W4', 'R4')
  chain(g, 'E', { { 250, 0 }, { 300, 0 }, { 350, 0 } })
  link(g, 'R0', 'E1')
  return g
end
local function arc(from, to, step)
  local out = {}
  local n = math.max(1, math.floor(math.abs(to - from) / step + 0.5))
  for i = 0, n do
    local a = math.rad(from + (to - from) * i / n)
    out[#out + 1] = { 200 + 20 * math.cos(a), 20 * math.sin(a) }
  end
  return out
end

function T.roundabout_goes_round_the_right_way()
  local g = roundabout()
  local r = route(concat(line(0, 0, 180, 0, 25), arc(180, 360, 15), line(220, 0, 350, 0, 25)))
  local res = assert(R.build(r, g, opts()))
  assert(res.ok, table.concat(res.warnings, ','))
  local p = res.path
  local i4 = indexOf(p, 'R4')
  assert(i4 and p[i4 + 1] == 'R5' and p[i4 + 2] == 'R6' and p[i4 + 3] == 'R7' and p[i4 + 4] == 'R0' and p[i4 + 5] == 'E1', table.concat(p, ','))
  assert(p[1] == 'W1' and p[#p] == 'E3')
  local okV, rep = R.validate(p, g, {})
  assert(okV and #rep.wrongWay == 0)
  assert(#res.junctions == 2)        -- R4 and R0 (an arm each)
end

function T.wrong_way_around_a_one_way_ring_is_never_used()
  local g = roundabout()
  -- the route goes clockwise through the north half: against every ring edge
  local r = route(concat(line(0, 0, 180, 0, 25), arc(180, 0, 15), line(220, 0, 350, 0, 25)))
  local res, why = R.buildAll(r, g, opts())
  assert(res or why)
  for _, s in ipairs(res or {}) do
    local okV, rep = R.validate(s.path, g, {})
    assert(okV and #rep.wrongWay == 0, 'wrong-way edge in the path')
    for k = 2, #s.path do
      local a, b = s.path[k - 1], s.path[k]
      if a:sub(1, 1) == 'R' and b:sub(1, 1) == 'R' then
        assert((tonumber(a:sub(2)) + 1) % 8 == tonumber(b:sub(2)), 'clockwise step ' .. a .. '>' .. b)
      end
    end
  end
end

function T.dual_carriageway_picks_the_carriageway_by_direction()
  local g = {}
  local E, W = {}, {}
  for i = 1, 11 do E[i] = { (i - 1) * 50, -6 } W[i] = { 500 - (i - 1) * 50, 6 } end
  chain(g, 'E', E, true)
  chain(g, 'W', W, true)
  local east = assert(R.build(route(line(0, 0, 500, 0, 25)), g, opts()))
  same(east.path, names('E', 1, 11))
  local west = assert(R.build(route(line(500, 0, 0, 0, 25)), g, opts()))
  same(west.path, names('W', 1, 11))
  -- on a one-way carriageway the bay is not shifted to a lane
  local sp = east.safeSpawn(250)
  assert(sp and sp.lateral == 0)
  near(sp.y, -6, 0.01)
end

function T.close_parallel_road_and_a_noisy_sample_do_not_derail_the_match()
  local g = {}
  chain(g, 'M', straight(11, 0))
  chain(g, 'P', straight(11, -8))
  local pts = line(0, 0, 500, 0, 25)
  pts[11] = { 250, -5.5 }           -- one fix is nearer the parallel road
  local res = assert(R.build(route(pts), g, opts()))
  same(res.path, names('M', 1, 11))
end

function T.bridge_over_a_road_follows_heights_and_connectivity()
  local g = {}
  chain(g, 'A', straight(9))
  chain(g, 'B', { { 200, -150, 0 }, { 200, -100, 0 }, { 200, -30, 8 }, { 200, 30, 8 }, { 200, 100, 0 }, { 200, 150, 0 } })
  local function zAt(y)
    local a = math.abs(y)
    if a >= 100 then return 0 elseif a <= 30 then return 8 end
    return 8 * (100 - a) / 70
  end
  local up = route(line(200, -150, 200, 150, 20))
  local withZ = function(lat, lon)
    local x, y = toGame(lat, lon)
    return x, y, zAt(y)
  end
  local res = assert(R.build(up, g, { toGame = withZ }))
  same(res.path, names('B', 1, 6))
  local res2 = assert(R.build(up, g, opts()))              -- no heights: connectivity alone
  same(res2.path, names('B', 1, 6))
  -- and the road under the bridge stays the road when the route is on it (z = 0 there)
  local under = route(line(0, 0, 400, 0, 20))
  local flat = function(lat, lon)
    local x, y = toGame(lat, lon)
    return x, y, 0
  end
  local res3 = assert(R.build(under, g, { toGame = flat }))
  same(res3.path, names('A', 1, 9))
  -- heights come from heightAt too
  local res4 = assert(R.build(under, g, opts({ heightAt = function() return 0 end })))
  same(res4.path, names('A', 1, 9))
end

-- --------------------------------------------------------------------------------------------------- holes and windows
local function holeGraph(h)
  local g = {}
  chain(g, 'A', { { 0, 0 }, { 50, 0 }, { 100, 0 }, { 150, 0 } })
  chain(g, 'D', { { 150, h }, { 200, h }, { 250, h } })
  local b = {}
  for i = 1, 12 do b[i] = { 250 + (i - 1) * 50, 0 } end
  chain(g, 'B', b)
  link(g, 'A4', 'D1') link(g, 'D3', 'B1')
  return g
end

function T.hole_in_the_graph_is_filled_with_the_shortest_path()
  local g = holeGraph(40)
  local res = assert(R.build(route(line(0, 0, 800, 0, 25)), g, opts()))
  same(res.path, { 'A1', 'A2', 'A3', 'A4', 'D1', 'D2', 'D3', 'B1', 'B2', 'B3', 'B4', 'B5', 'B6', 'B7', 'B8', 'B9', 'B10', 'B11', 'B12' })
  near(res.lengthRatio, 880 / 800, 0.02)
  assert(res.ok and has(res.warnings, 'detour') and res.complete)
end

function T.hole_too_long_to_fill_splits_the_route_into_segments()
  local g = holeGraph(150)
  local list = assert(R.buildAll(route(line(0, 0, 800, 0, 25)), g, opts()))
  assert(#list == 2, #list)
  local head = assert(R.build(route(line(0, 0, 800, 0, 25)), g, opts({ nearAlong = 50 })))
  local tail = assert(R.build(route(line(0, 0, 800, 0, 25)), g, opts({ nearAlong = 700 })))
  assert(head.path[1] == 'A1' and head.path[#head.path] ~= 'B12')
  assert(tail.path[#tail.path] == 'B12' and not has(tail.path, 'A1'))
  assert(#head.segments == 2)
  assert(not has(head.path, 'D2') and not has(tail.path, 'D2'))
  assert(tail.head.clipped and not tail.tail.clipped)
end

function T.route_leaving_the_window_reports_where_the_usable_path_ends()
  local g = {}
  chain(g, 'N', straight(7))
  local r = route(line(0, 0, 600, 0, 25), { { along = 100, off = 6 }, { along = 250, off = 6 }, { along = 450, off = 6 } })
  local res = assert(R.build(r, g, opts()))
  same(res.path, names('N', 1, 7))
  near(res.coverage, 0.5, 0.03)
  assert(not res.complete and res.tail.clipped and res.tail.deadEnd and not res.head.clipped)
  assert(has(res.warnings, 'clippedTail') and has(res.warnings, 'deadEnd') and has(res.warnings, 'partial'))
  assert(#res.stops == 2 and res.droppedStops[1] == 3)
  near(res.usableTo, 240, 1)
  local sp = res.safeSpawn(290)
  assert(sp and sp.along <= 240.01 and sp.along >= 238, sp and sp.along)
  near(sp.x, 240, 3)
  near(sp.y, -2, 0.01)             -- the right-hand lane of a two-way road
  near(sp.dirX, 1, 0.001)
  local first = res.safeSpawn(5)
  assert(first and first.along >= 4.9 and first.along <= 5.1, 'the start is the real start of the route: no margin')
end

function T.safe_spawn_keeps_off_junctions_and_clipped_ends()
  local g = {}
  chain(g, 'M', straight(9))
  chain(g, 'S', { { 200, 50 }, { 200, 100 }, { 200, 150 }, { 200, 200 } })
  link(g, 'M5', 'S1')
  local r = route(concat(line(0, 0, 200, 0, 25), line(200, 0, 200, 200, 25)))
  local res = assert(R.build(r, g, opts()))
  local sp = res.safeSpawn(200)
  assert(sp and math.abs(sp.along - 200) >= 19.99, sp and sp.along)
  assert(res.safeSpawn(190).along <= 180.01 or res.safeSpawn(190).along >= 219.99)
  -- a short path with no room: nil
  local g2 = {}
  chain(g2, 'N', straight(4))
  local r2 = route(line(0, 0, 400, 0, 25))
  local res2 = assert(R.build(r2, g2, opts()))
  assert(res2.tail.clipped and res2.safeSpawn(100) ~= nil)
  local g3 = {}
  chain(g3, 'N', straight(2))
  local res3 = assert(R.build(route(line(0, 0, 400, 0, 25)), g3, opts()))
  assert(res3.safeSpawn(10) == nil, 'a 50 m graph has no spot 60 m inside')
end

function T.graph_shift_trims_and_extends_with_stable_names()
  local g0 = {}
  chain(g0, 'N', straight(9))                                   -- x 0..400
  local g1 = {}
  for i = 4, 12 do node(g1, 'N' .. i, (i - 1) * 50, 0) end      -- x 150..550
  for i = 5, 12 do link(g1, 'N' .. (i - 1), 'N' .. i) end
  local r = route(line(0, 0, 600, 0, 25), { { along = 100, off = 6 }, { along = 300, off = 6 }, { along = 500, off = 6 } })
  local res0 = assert(R.build(r, g0, opts()))
  assert(#res0.stops == 2 and res0.tail.clipped)
  local t = assert(R.trimResult(res0, g1))
  same(t.path, names('N', 4, 9))
  assert(#t.stops == 1 and t.stops[1].index == 2)
  near(t.stops[1].along, 150, 3)
  near(t.length, 250, 0.5)
  local e = assert(R.extend(res0, g1))
  assert(e.extended)
  same(e.path, names('N', 4, 12))
  assert(#e.stops == 2 and e.stops[1].index == 2 and e.stops[2].index == 3)
  near(e.stops[1].along, 150, 3)
  near(e.stops[2].along, 350, 3)
  assert(e.head.clipped and e.tail.clipped)
  -- the graph jumps elsewhere along the route: the old path is gone, the new one replaces it
  local g2 = {}
  for i = 9, 13 do node(g2, 'N' .. i, (i - 1) * 50, 0) end
  for i = 10, 13 do link(g2, 'N' .. (i - 1), 'N' .. i) end
  local far = assert(R.extend(res0, g2))
  assert(far.replaced)
  same(far.path, names('N', 9, 13))
  -- nothing of the route left in the new graph: nil
  local g3 = {}
  node(g3, 'Z1', 5000, 5000) node(g3, 'Z2', 5050, 5000) link(g3, 'Z1', 'Z2')
  assert(R.trimResult(res0, g3) == nil)
  assert(R.extend(res0, g3) == nil)
end

function T.wrong_way_trap_detours_through_the_legal_road_or_gives_up()
  local g = {}
  chain(g, 'WS', { { -100, 0 }, { -50, 0 } })
  node(g, 'A', 0, 0) link(g, 'WS2', 'A')
  node(g, 'B', 200, 0)
  node(g, 'm3', 150, 0) node(g, 'm2', 100, 0) node(g, 'm1', 50, 0)
  link(g, 'B', 'm3', true) link(g, 'm3', 'm2', true) link(g, 'm2', 'm1', true) link(g, 'm1', 'A', true)   -- one way WEST
  chain(g, 'E', { { 250, 0 }, { 300, 0 } })
  link(g, 'B', 'E1')
  local r = route(line(-100, 0, 300, 0, 25))
  -- no other road: the two ends cannot be joined, and the wrong-way edges are in no segment
  local list = assert(R.buildAll(r, g, opts()))
  assert(#list == 2)
  for _, s in ipairs(list) do
    assert(not has(s.path, 'm2') and not has(s.path, 'm1') and not has(s.path, 'm3'))
    assert(R.validate(s.path, g, {}))
  end
  -- a parallel two-way road lets the match go round
  chain(g, 'P', { { 0, 60 }, { 50, 60 }, { 100, 60 }, { 150, 60 }, { 200, 60 } })
  link(g, 'A', 'P1') link(g, 'B', 'P5')
  local res = assert(R.build(r, g, opts()))
  same(res.path, { 'WS1', 'WS2', 'A', 'P1', 'P2', 'P3', 'P4', 'P5', 'B', 'E1', 'E2' })
  assert(has(res.warnings, 'detour') and has(res.warnings, 'length') and not res.ok)
  local okV = R.validate(res.path, g, {})
  assert(okV)
end

function T.loop_route_passes_the_same_roads_twice()
  local g = {}
  local sq = {}
  local perim = {}
  for i = 0, 3 do
    for k = 0, 3 do
      local x, y
      if i == 0 then x, y = 50 * k, 0 elseif i == 1 then x, y = 200, 50 * k elseif i == 2 then x, y = 200 - 50 * k, 200 else x, y = 0, 200 - 50 * k end
      perim[#perim + 1] = { x, y }
    end
  end
  chain(g, 'Q', perim)
  link(g, 'Q16', 'Q1')
  local lap = concat(line(0, 0, 200, 0, 25), line(200, 0, 200, 200, 25), line(200, 200, 0, 200, 25), line(0, 200, 0, 0, 25))
  local pts = concat(lap, lap)
  local r = route(pts, { { along = 100, off = 6 }, { along = 900, off = 6 } })
  local res = assert(R.build(r, g, opts()))
  assert(#res.path == 33, #res.path)
  assert(res.path[1] == 'Q1' and res.path[17] == 'Q1' and res.path[33] == 'Q1')
  near(res.length, 1600, 2)
  assert(res.ok)
  assert(#res.stops == 2)
  near(res.stops[1].along, 100, 4)
  near(res.stops[2].along, 900, 4)
  assert(res.stops[1].side == 1 and res.stops[2].side == 1)
end

function T.out_and_back_route_is_flagged_as_a_u_turn()
  local g = {}
  chain(g, 'N', straight(5))
  local r = route(concat(line(0, 0, 200, 0, 25), line(200, 0, 0, 0, 25)))
  local res = assert(R.build(r, g, opts()))
  same(res.path, { 'N1', 'N2', 'N3', 'N4', 'N5', 'N4', 'N3', 'N2', 'N1' })
  assert(#res.problems.uturn == 1 and res.problems.uturn[1] == 5 and not res.ok and has(res.warnings, 'uturn'))
  local okV, rep = R.validate(res.path, g, {})
  assert(okV and #rep.uturns >= 1)
end

-- -------------------------------------------------------------------------------------------- validation, trim, avoid
function T.validate_reports_missing_jumps_wrong_way_and_length()
  local g = {}
  chain(g, 'N', straight(6))
  node(g, 'O1', 0, 100) node(g, 'O2', 50, 100) link(g, 'O1', 'O2', true)
  local okV, rep = R.validate(names('N', 1, 6), g, { routeLength = 250 })
  assert(okV and math.abs(rep.length - 250) < 0.01 and math.abs(rep.ratio - 1) < 0.01)
  okV, rep = R.validate({ 'N1', 'N2', 'X', 'N4' }, g, {})
  assert(not okV and rep.missing[1] == 3)
  okV, rep = R.validate({ 'N1', 'N2', 'N4' }, g, {})
  assert(not okV and rep.jumps[1] == 3)
  okV, rep = R.validate({ 'O2', 'O1' }, g, {})
  assert(not okV and rep.wrongWay[1] == 2)
  okV = R.validate(names('N', 1, 6), g, { routeLength = 400 })
  assert(not okV, 'length off by more than 15 %')
end

function T.trim_keeps_the_longest_run_or_the_one_with_the_bus()
  local g = {}
  chain(g, 'N', straight(6))
  local path = { 'X1', 'N1', 'N2', 'N3', 'Y', 'N5', 'N6' }
  local p, info = R.trim(path, g, {})
  same(p, { 'N1', 'N2', 'N3' })
  assert(info.first == 2 and info.last == 4 and info.droppedFront == 1 and info.droppedBack == 3 and info.holes == 1)
  local p2 = R.trim(path, g, { at = 7 })
  same(p2, { 'N5', 'N6' })
  assert(R.trim({ 'X1', 'X2' }, g, {}) == nil)
  -- an unlinked pair is a hole too
  local p3 = R.trim({ 'N1', 'N2', 'N4', 'N5' }, g, {})
  same(p3, { 'N1', 'N2' })
end

local function narrowGraph()
  local g = {}
  chain(g, 'N', straight(11))
  g.N5.radius, g.N6.radius = 1.5, 1.5               -- the edge N5-N6 is 3 m wide: no room for a bus
  node(g, 'C1', 200, -20) node(g, 'C2', 250, -20)
  link(g, 'N5', 'C1') link(g, 'C1', 'C2') link(g, 'C2', 'N6')
  return g
end

function T.narrow_edge_is_flagged_and_repaired_by_going_round()
  local g = narrowGraph()
  local r = route(line(0, 0, 500, 0, 25))
  local flagged = assert(R.build(r, g, opts({ repair = false })))
  same(flagged.path, names('N', 1, 11))
  assert(not flagged.ok and has(flagged.warnings, 'narrow'))
  assert(#flagged.problems.narrow == 1 and flagged.problems.narrow[1].a == 'N5' and flagged.problems.narrow[1].b == 'N6')
  near(flagged.problems.narrow[1].from, 200, 0.5)
  near(flagged.problems.narrow[1].to, 250, 0.5)
  -- no spawn on the narrow stretch
  local sp = flagged.safeSpawn(225)
  assert(sp and (sp.along <= 200.01 or sp.along >= 249.99))
  local fixed = assert(R.build(r, g, opts()))
  assert(fixed.repaired and fixed.ok, table.concat(fixed.warnings, ','))
  same(fixed.path, { 'N1', 'N2', 'N3', 'N4', 'N5', 'C1', 'C2', 'N6', 'N7', 'N8', 'N9', 'N10', 'N11' })
  assert(#fixed.problems.narrow == 0)
  -- where there is no other way the narrow edge is kept and flagged
  local g2 = {}
  chain(g2, 'N', straight(11))
  g2.N5.radius, g2.N6.radius = 1.5, 1.5
  local kept = assert(R.build(r, g2, opts()))
  same(kept.path, names('N', 1, 11))
  assert(not kept.ok and #kept.problems.narrow == 1)
  -- narrow checking can be switched off
  assert(assert(R.build(r, g2, opts({ minRadius = 0 }))).ok)
  local set = R.narrowEdges(g, 2.4)
  assert(set[R.edgeKey('N5', 'N6')] and not set[R.edgeKey('N4', 'N5')])
end

function T.avoid_edges_make_the_match_go_round()
  local g = narrowGraph()
  local r = route(line(0, 0, 500, 0, 25))
  local viaList = assert(R.build(r, g, opts({ avoidEdges = { { 'N7', 'N8' }, 'N9|N10' }, minRadius = 0 })))
  assert(#viaList.path >= 2)
  for k = 2, #viaList.path do
    local key = R.edgeKey(viaList.path[k - 1], viaList.path[k])
    assert(key ~= 'N7|N8' and key ~= 'N9|N10', 'avoided edge used')
  end
  -- a blocked edge with a bypass
  local g2 = narrowGraph()
  local set = R.avoidSet({ { 'N5', 'N6' } })
  local res = assert(R.build(r, g2, opts({ avoidEdges = set, minRadius = 0 })))
  assert(has(res.path, 'C1') and has(res.path, 'C2') and res.ok)
end

function T.reroute_around_a_blocked_edge_on_a_path_and_on_a_result()
  local g = narrowGraph()
  local path = names('N', 1, 11)
  local np, info = R.reroute(path, { 'N5', 'N6' }, g)
  same(np, { 'N1', 'N2', 'N3', 'N4', 'N5', 'C1', 'C2', 'N6', 'N7', 'N8', 'N9', 'N10', 'N11' })
  assert(info.from == 5 and info.to == 6)
  -- the edge table of the game's graph works as the blocked edge
  local np2 = R.reroute(path, g.N5.links.N6, g)
  assert(np2 and has(np2, 'C1'))
  assert(R.validate(np2, g, {}))
  -- no way round: nil
  assert(R.reroute(path, 'N2|N3', g) == nil)
  -- not on the path: nil
  assert(R.reroute(path, 'C1|C2', g) == nil)
  -- the bypass is one-way the wrong way: nil
  local g3 = narrowGraph()
  g3.C1.links.N5.oneWay, g3.C1.links.N5.inNode = true, 'C1'
  g3.C1.links.C2.oneWay, g3.C1.links.C2.inNode = true, 'C1'
  g3.C2.links.N6.oneWay, g3.C2.links.N6.inNode = true, 'N6'
  assert(R.reroute(path, 'N5|N6', g3) == nil)
  -- a build result is matched again with the edge avoided
  local r = route(line(0, 0, 500, 0, 25), { { along = 100, off = 6 }, { along = 400, off = 6 } })
  local res = assert(R.build(r, g, opts({ minRadius = 0 })))
  same(res.path, path)
  local re = assert(R.reroute(res, 'N5|N6', g))
  assert(re.rerouted and has(re.path, 'C1') and has(re.path, 'N6'))
  assert(#re.stops == 2)
  near(re.stops[2].along, 400 + (90 - 50), 6, 'the stop after the detour moved by the detour')
  assert(R.reroute(res, 'N2|N3', g) == nil or #R.reroute(res, 'N2|N3', g).path < #path)
end

function T.find_closest_road_is_only_a_fallback()
  local g = {}
  chain(g, 'N', straight(5))
  local calls = 0
  local far = route(line(0, 500, 200, 500, 25))
  local res, why = R.build(far, g, opts({ findClosestRoad = function() calls = calls + 1 return nil end }))
  assert(res == nil and why == 'no match' and calls > 0)
  calls = 0
  local ok = assert(R.build(route(line(0, 0, 200, 0, 25)), g, opts({ findClosestRoad = function() calls = calls + 1 return nil end })))
  assert(calls == 0 and #ok.path == 5)
  assert(R.build({ path = {} }, g, opts()) == nil)
  assert(R.build(route(line(0, 0, 200, 0, 25)), g, {}) == nil)
end

function T.index_can_be_reused_and_shortest_paths_respect_drivability()
  local g = {}
  chain(g, 'N', straight(5))
  local ix = R.index(g)
  assert(R.index(ix) == ix)
  local res = assert(R.build(route(line(0, 0, 200, 0, 25)), ix, opts()))
  same(res.path, names('N', 1, 5))
  assert(R.pointAt(res, 125) ~= nil)
  local x, y, z, dx, dy = R.pointAt(res, 125)
  near(x, 125, 0.01) near(y, 0, 0.01) near(dx, 1, 1e-6)
end

return T
