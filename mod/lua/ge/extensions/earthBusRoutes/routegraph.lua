-- Bus route -> road-graph path for the AI driver (plan 007, stage T2). Pure Lua, no game calls: the graph, the lat/lon ->
-- game conversion and (optionally) the game's closest-road search are handed in, so the tests run it under lupa.
--
-- WHAT IT DOES
--   A route (route.path = {{lat=, lon=}..}, route.cum = metres at each vertex (made when missing), route.stops = {{lat=, lon=
--   (the platform), along = metres along the route, id=, name=}..}, as osm.parseRoute / the gtfs routes give) is map-matched onto
--   the road graph BeamNG.Earth hands to the game with map.reset(customNodes) (navgraph.lua toNodes):
--       graph[name] = { pos = {x=,y=,z=} (a vec3 is fine), radius = half road width, links = { [neighbour] = edge } }
--       edge = { oneWay = bool, inNode = name, outNode = name, drivability, lanes, speedLimit }  (one table shared by both ends;
--       a oneWay edge is driven inNode -> outNode only). Node names are stable (s<osm id>_<k>), so a path of names stays valid when
--       the graph moves with the player; only its ends are cut (trim) and grown (extend).
--   The result is what `ai.driveUsingPath{path = names}` needs plus what the bus driver (T3) and the fleet (T4) need to stay out
--   of trouble. Matching: samples of the route every SAMPLE_M, candidate edges within MAX_OFF_M (distance weighted like the game's
--   closest-road search: sqrt(dxy^2 + (WZ*dz)^2), WZ = 1.85, when the route has heights), direction-consistent (a one-way edge
--   against the route is never a candidate; a two-way edge only the way the route goes), then a Viterbi pass over the samples whose
--   transitions need a real way through the graph (so a bridge above a road, a parallel carriageway or a crossing road that is not
--   connected cannot be hopped to). Holes (no edge near, or no way through) are filled with a shortest path over `links`
--   (one-way respected) when it is not much longer than the route there; otherwise the route is cut into separate segments.
--
-- API (R = require('earthBusRoutes/routegraph'))
--   R.index(graph)                       -> ix     spatial index + adjacency of a graph; rebuild it when the graph changes
--                                                  (the game keeps one node table object across resets, so no caching by identity)
--   R.build(route, graph|ix, opts)       -> res | nil, why     the best segment (see opts.nearAlong); res.segments = all of them
--   R.buildAll(route, graph|ix, opts)    -> { res.. } | nil, why   every matched segment, longest coverage first
--   opts: toGame(lat, lon) -> x, y [, z]   REQUIRED (the game position; z optional)
--         heightAt(x, y) -> z              optional ground height when toGame gives none
--         findClosestRoad(x, y, z) -> name1, name2, dist   optional; the game's own search, used only for a sample with no
--                                          candidate of ours (fallback)
--         nearAlong = route metres         which segment to prefer (default: the longest)
--         avoidEdges = set                 edges never used (R.avoidSet / R.edgeKey): blocked or unfit; matching and fills go round
--         minRadius = 2.4                  edges narrower (mean node radius = half width) are flagged `narrow`; 0 switches it off
--         repair = true                    when the matched path uses narrow edges it is matched again with them avoided
--         leftHand = false                 driving side (the bay offset and lane offset of safeSpawn)
--         sampleM, maxOffM, wz             override the constants below
--   res = {
--     path = {names}, cum = {metres at each node, cum[1] = 0}, length, pts = {{x,y,z}..}, radius = {..},
--     fromAlong, toAlong        the part of the route (metres) this path covers; routeLength; coverage = covered / routeLength
--     complete                  coverage >= 0.98
--     lengthRatio               path length over covered route length (valid when within 1 +- LEN_TOL = 15 %)
--     ok                        lengthRatio in range, nothing in `problems` except `sharp`
--     warnings = {'length','detour','partial','narrow','sharp','uturn','clippedHead','clippedTail','deadEnd'..}
--     problems = { missing={}, jumps={}, wrongWay={}, narrow={ {from=, to=, a=, b=} (path metres) }, sharp={ {index, along, angle} },
--                  uturn={index..} }
--     head = { clipped = bool }, tail = { clipped = bool, deadEnd = bool }
--         clipped: the route goes on beyond the graph there (the usable path ends where the graph window ends);
--         deadEnd: the last node has no way on except back (a bus that gets there is stuck: never spawn/hold it near)
--     usableFrom, usableTo      path metres where a bus is safe to be (a clipped end keeps SAFE_END_M = 60 m clear)
--     stops = { {index (in route.stops), id, name, along (path metres), routeAlong, side (+1 right of travel, -1 left),
--                offset (m from the path's centre line to the platform), halfWidth (node radius there), sideOk (false: platform on the
--                wrong side for the driving side), far (platform > 45 m from the path), x, y, z, dirX, dirY (the path there),
--                nodeIndex, nodeName (last path node at or before), junctionAhead, junctionBehind (m to the nearest junction node
--                of the path ahead / behind, nil when none)} }   in route order; droppedStops = {route stop indexes outside the path}
--     junctions = { {index, name, along, degree} }      path nodes with more than two neighbours in the graph
--     nodes = { [i] = {name, along, degree, junction, radius, turn (deg, + left, - right; nil at the ends), narrowAfter} }
--     anchors = {ar = route metres, ap = path metres}   monotone map route -> path
--     safeSpawn(distAlong) -> pose | nil   pose = {x, y, z, dirX, dirY, along, nodeIndex, lateral}: the nearest spot to distAlong
--         that is inside [usableFrom, usableTo] (60 m clear of a clipped end), >= SAFE_JUNCTION_M = 20 m from any junction or sharp
--         turn node, on an edge that is not narrow or avoided; shifted `lateral` m to the driving side on a two-way edge (the lane),
--         centred on a one-way edge
--   }
--   R.pointAt(res, along)                 -> x, y, z, dirX, dirY      position/direction on the path
--   R.junctionsAhead(res, along, maxM)    -> { {along, dist, name, degree, index}.. } junction nodes within maxM ahead
--   R.validate(path, graph|ix, opts)      -> ok, report   report = {missing, jumps, wrongWay, uturns (index lists), length, ratio};
--                                            opts.routeLength compares the length (+- LEN_TOL)
--   R.trim(path, graph|ix, opts)          -> path | nil, info   longest run of names that exists in the graph, is linked and
--                                            drivable in that direction; opts.at = node index the bus is at (prefer the run that
--                                            holds/follows it); info = {first, last, droppedFront, droppedBack, holes}
--   R.trimResult(res, graph|ix, opts)     -> res | nil   res on the new graph without the nodes it lost (stops/anchors shifted)
--   R.extend(res, graph|ix, opts)         -> res | nil   after the graph moved: trims what was lost, matches the route again and
--                                            grows the path ahead from the node where it overlaps (res.extended = true; with no
--                                            overlap the new best segment replaces it, res.replaced = true). Needs the build result
--                                            (it carries the route and options in res._ctx), not a bare name list.
--   R.reroute(pathOrRes, blocked, graph|ix, opts) -> path | res | nil, info
--         blocked = {a, b} / 'a|b' / an edge with inNode, outNode. A bare name list gets a local detour around the blocked edge
--         that rejoins the old path at the cheapest later node (info = {from, to, extra}); nil when there is none. A build result
--         is matched again with the edge avoided (nil when that fails).
--   R.edgeKey(a, b) / R.avoidSet(list) / R.narrowEdges(graph|ix, minRadius) -> avoid sets
--
-- ASSUMPTIONS ABOUT THE GAME'S GRAPH (verify in game): nodes[name].pos has .x .y .z; links are symmetric and share one edge table;
-- oneWay edges carry inNode (travel allowed inNode -> outNode); node.radius is half the road width; the graph around the player
-- is clipped to the terrain block (a clipped end is a dead end to the AI); node names stay the same across map.reset.
-- Shortest paths weigh an edge by its length times (1 + 0.5 * (1 - drivability)) (drivability 0..1; 1 when unknown).
local geo = require('earthBusRoutes/geomath')
local M = {}

M.SAMPLE_M = 12           -- route sampling step
M.MAX_OFF_M = 12          -- an edge farther than this from a sample is not a candidate (wide roads: node radius + 4)
M.WZ = 1.85               -- weight of the height difference, as the game's closest-road search
M.ANGLE_K = 10            -- metres of cost for a right angle off the road's direction
M.TRANS_W = 0.6           -- cost of each metre the way through the graph differs from the way along the route
M.NEAR_CUT_M = 160        -- how far a hop between two samples may go through the graph
M.BACK_TOL_M = 1.5        -- jitter allowed going backwards on one edge
M.MIN_RUN_M = 25          -- a matched piece shorter than this (route metres) is noise
M.JOIN_DETOUR = 2.0       -- a hole is filled when the way through the graph is at most this times the route there ...
M.JOIN_SLACK_M = 60       -- ... plus this
M.LEN_TOL = 0.15          -- path length vs route length
M.GRID_M = 40
M.MAX_CANDS = 8
M.MIN_RADIUS = 2.4        -- a 12 m bus does not fit a road narrower than this (node radius = half width)
M.NARROW_COST = 30        -- a narrow edge costs this much more as a candidate (it is used only when nothing else fits)
M.SHARP_DEG = 140         -- a turn at a path node beyond this is flagged `sharp`
M.UTURN_DEG = 165         -- ... and beyond this it is a U-turn (not ok)
M.SAFE_END_M = 60         -- safeSpawn: clear of a clipped end of the path
M.SAFE_JUNCTION_M = 20    -- safeSpawn: clear of a junction
M.LANE_SHIFT_M = 2.2      -- safeSpawn: at most this far from the centre line on a two-way edge
M.FAR_PLATFORM_M = 45
M.CLIP_M = 25             -- the route goes on this much beyond the matched part: the graph clipped it
M.COMPLETE = 0.98

local sqrt, abs, min, max, floor = math.sqrt, math.abs, math.min, math.max, math.floor

-- ---------------------------------------------------------------------------------------------------------------- helpers
local function hpush(h, pri, item)
  local n = #h + 1
  h[n] = { pri, item }
  while n > 1 do
    local p = floor(n / 2)
    if h[p][1] <= h[n][1] then break end
    h[p], h[n] = h[n], h[p]
    n = p
  end
end

local function hpop(h)
  local n = #h
  if n == 0 then return nil end
  local top = h[1]
  h[1] = h[n]
  h[n] = nil
  n = n - 1
  local i = 1
  while true do
    local l, r, s = i * 2, i * 2 + 1, i
    if l <= n and h[l][1] < h[s][1] then s = l end
    if r <= n and h[r][1] < h[s][1] then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]
    i = s
  end
  return top[2], top[1]
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- linear interpolation of ys over increasing xs; clamped at the ends
local function interp(xs, ys, v)
  local n = #xs
  if n == 0 then return nil end
  if v <= xs[1] then return ys[1] end
  if v >= xs[n] then return ys[n] end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if xs[mid] <= v then lo = mid else hi = mid end
  end
  local dx = xs[hi] - xs[lo]
  if dx <= 1e-9 then return ys[lo] end
  return ys[lo] + (ys[hi] - ys[lo]) * (v - xs[lo]) / dx
end

function M.edgeKey(a, b)
  if a > b then a, b = b, a end
  return a .. '|' .. b
end

-- a set of edges to avoid from a list of {a, b} pairs / 'a|b' keys / edge tables with inNode, outNode
function M.avoidSet(list)
  local s = {}
  for _, e in ipairs(list or {}) do
    if type(e) == 'string' then
      local a, b = e:match('^(.-)|(.*)$')
      if a then s[M.edgeKey(a, b)] = true end
    elseif type(e) == 'table' then
      local a, b = e[1] or e.a or e.inNode, e[2] or e.b or e.outNode
      if a and b then s[M.edgeKey(a, b)] = true end
    end
  end
  return s
end

local function asAvoid(v)
  if v == nil then return {} end
  if type(v) == 'table' and v[1] ~= nil then return M.avoidSet(v) end
  return v
end

-- ------------------------------------------------------------------------------------------------------------------ index
local function cellKey(cx, cy) return cx * 2097152 + cy end

function M.index(graph)
  if graph.isIndex then return graph end
  local ix = { isIndex = true, nodes = graph, adj = {}, pair = {}, grid = {}, deg = {}, edges = 0 }
  local cell = M.GRID_M
  for a, na in pairs(graph) do
    ix.adj[a] = ix.adj[a] or {}
    ix.pair[a] = ix.pair[a] or {}
    local nbrs = 0
    if type(na) == 'table' and na.pos and na.links then
      for b, e in pairs(na.links) do
        local nb = graph[b]
        if nb and nb.pos and a ~= b then
          nbrs = nbrs + 1
          if not ix.pair[a][b] then
            local ab, ba = true, true
            if e.oneWay then
              if e.inNode == a then ba = false elseif e.inNode == b then ab = false end
            end
            local pa, pb = na.pos, nb.pos
            local az, bz = pa.z or 0, pb.z or 0
            local ex, ey = pb.x - pa.x, pb.y - pa.y
            local len2 = ex * ex + ey * ey
            local ra, rb = na.radius, nb.radius
            local rad = (ra and rb) and (ra + rb) / 2 or ra or rb
            local drv = clamp(tonumber(e.drivability) or 1, 0, 1)
            local len = sqrt(len2 + (bz - az) ^ 2)
            local E = { a = a, b = b, ax = pa.x, ay = pa.y, az = az, bx = pb.x, by = pb.y, bz = bz, ex = ex, ey = ey,
              len2 = len2, len = max(len, 0.01), ux = len2 > 1e-9 and ex / sqrt(len2) or 0, uy = len2 > 1e-9 and ey / sqrt(len2) or 0,
              ab = ab, ba = ba, oneWay = not (ab and ba), radius = rad, key = M.edgeKey(a, b),
              w = max(len, 0.01) * (1 + 0.5 * (1 - drv)) }
            ix.pair[b] = ix.pair[b] or {}
            ix.pair[a][b] = E
            ix.pair[b][a] = E
            ix.edges = ix.edges + 1
            if ab then ix.adj[a][#ix.adj[a] + 1] = { to = b, e = E } end
            if ba then
              ix.adj[b] = ix.adj[b] or {}
              ix.adj[b][#ix.adj[b] + 1] = { to = a, e = E }
            end
            local x0, x1 = floor(min(pa.x, pb.x) / cell), floor(max(pa.x, pb.x) / cell)
            local y0, y1 = floor(min(pa.y, pb.y) / cell), floor(max(pa.y, pb.y) / cell)
            for cx = x0, x1 do
              for cy = y0, y1 do
                local k = cellKey(cx, cy)
                local g = ix.grid[k]
                if not g then g = {} ix.grid[k] = g end
                g[#g + 1] = E
              end
            end
          end
        end
      end
    end
    ix.deg[a] = nbrs
  end
  return ix
end

local function query(ix, x, y, r)
  local cell = M.GRID_M
  local out, seen = {}, {}
  for cx = floor((x - r) / cell), floor((x + r) / cell) do
    for cy = floor((y - r) / cell), floor((y + r) / cell) do
      local g = ix.grid[cellKey(cx, cy)]
      if g then
        for i = 1, #g do
          local E = g[i]
          if not seen[E] then seen[E] = true out[#out + 1] = E end
        end
      end
    end
  end
  return out
end

function M.narrowEdges(graph, minRadius)
  local ix = M.index(graph)
  minRadius = minRadius or M.MIN_RADIUS
  local s = {}
  for _, row in pairs(ix.pair) do
    for _, E in pairs(row) do
      if E.radius and E.radius < minRadius then s[E.key] = true end
    end
  end
  return s
end

-- ---------------------------------------------------------------------------------------------------------- shortest paths
-- Dijkstra from src over the directed adjacency; weighted: edge.w, else length. Stops at dst when given. avoid: edge keys.
local function search(ix, src, dst, cutoff, weighted, avoid)
  local dist, prev, done, heap = { [src] = 0 }, {}, {}, {}
  hpush(heap, 0, src)
  while true do
    local u, d = hpop(heap)
    if not u then break end
    if not done[u] then
      done[u] = true
      if u == dst then break end
      local list = ix.adj[u]
      if list then
        for i = 1, #list do
          local a = list[i]
          if not (avoid and avoid[a.e.key]) then
            local nd = d + (weighted and a.e.w or a.e.len)
            if nd <= cutoff and (dist[a.to] == nil or nd < dist[a.to]) then
              dist[a.to] = nd
              prev[a.to] = { u, a }
              hpush(heap, nd, a.to)
            end
          end
        end
      end
    end
  end
  return dist, prev
end

local function unwind(prev, src, dst)
  local names, n = { dst }, dst
  while n ~= src do
    local p = prev[n]
    if not p then return nil end
    n = p[1]
    names[#names + 1] = n
  end
  local out = {}
  for i = #names, 1, -1 do out[#out + 1] = names[i] end
  return out
end

-- node names src .. dst, real length; nil when no way within cutoff
local function shortest(ix, src, dst, cutoff, weighted, avoid)
  if src == dst then return { src }, 0 end
  if not ix.adj[src] then return nil end
  local dist, prev = search(ix, src, dst, cutoff, weighted, avoid)
  if dist[dst] == nil then return nil end
  local names = unwind(prev, src, dst)
  if not names then return nil end
  local real = 0
  for i = 2, #names do real = real + ix.pair[names[i - 1]][names[i]].len end
  return names, real
end

-- --------------------------------------------------------------------------------------------------------------- sampling
local function sampleRoute(route, ctx)
  local P = route.path
  if type(P) ~= 'table' or #P < 2 then return nil end
  local cum = route.cum
  if type(cum) ~= 'table' or #cum ~= #P then cum = geo.cumulative(P) end
  local V = {}
  for i, p in ipairs(P) do
    local x, y, z = ctx.toGame(p.lat, p.lon)
    if z == nil and ctx.heightAt then z = ctx.heightAt(x, y) end
    V[i] = { x = x, y = y, z = z }
  end
  local total = cum[#P]
  if total <= 0 then return nil end
  local step = ctx.sampleM
  local S, j, m = {}, 1, 0
  while true do
    while j < #P - 1 and cum[j + 1] < m do j = j + 1 end
    local seg = cum[j + 1] - cum[j]
    local f = seg > 0 and clamp((m - cum[j]) / seg, 0, 1) or 0
    local a, b = V[j], V[j + 1]
    S[#S + 1] = { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f,
      z = (a.z and b.z) and (a.z + (b.z - a.z) * f) or nil, m = m }
    if m >= total then break end
    m = min(m + step, total)
  end
  local hx, hy = 1, 0
  for k = 1, #S do
    local a, b = S[max(k - 1, 1)], S[min(k + 1, #S)]
    local dx, dy = b.x - a.x, b.y - a.y
    local l = sqrt(dx * dx + dy * dy)
    if l > 1e-6 then hx, hy = dx / l, dy / l end
    S[k].hx, S[k].hy = hx, hy
  end
  ctx.step = {}
  for k = 2, #S do
    local a, b = S[k - 1], S[k]
    ctx.step[k] = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (((a.z and b.z) and (b.z - a.z) or 0) ^ 2))
  end
  return S, total
end

-- ------------------------------------------------------------------------------------------------------------- candidates
local function project(E, x, y)
  local t = 0
  if E.len2 > 1e-9 then t = clamp(((x - E.ax) * E.ex + (y - E.ay) * E.ey) / E.len2, 0, 1) end
  local qx, qy = E.ax + E.ex * t, E.ay + E.ey * t
  return t, sqrt((x - qx) ^ 2 + (y - qy) ^ 2), E.az + (E.bz - E.az) * t
end

local function mkState(ctx, E, dir, t, d, cosv)
  local c = d + M.ANGLE_K * (1 - cosv)
  if E.radius and E.radius < ctx.minRadius then c = c + M.NARROW_COST end
  return { E = E, dir = dir, t = t, d = d, cos = cosv, from = dir > 0 and E.a or E.b, to = dir > 0 and E.b or E.a,
    u = (dir > 0 and t or 1 - t) * E.len, cost = c }
end

local function candidates(ix, ctx, s)
  local out = {}
  local r = ctx.maxOffM + 6
  for _, E in ipairs(query(ix, s.x, s.y, r)) do
    if not ctx.avoid[E.key] then
      local t, dxy, qz = project(E, s.x, s.y)
      local d = dxy
      if s.z then d = sqrt(dxy * dxy + (ctx.wz * (s.z - qz)) ^ 2) end
      if d <= min(max(ctx.maxOffM, (E.radius or 0) + 4), r) then
        local cosF = s.hx * E.ux + s.hy * E.uy
        if E.ab and E.ba then
          if cosF >= 0 then
            out[#out + 1] = mkState(ctx, E, 1, t, d, cosF)
            if cosF < 0.2 then out[#out + 1] = mkState(ctx, E, -1, t, d, -cosF) end
          else
            out[#out + 1] = mkState(ctx, E, -1, t, d, -cosF)
            if cosF > -0.2 then out[#out + 1] = mkState(ctx, E, 1, t, d, cosF) end
          end
        elseif E.ab then
          if cosF > -0.35 then out[#out + 1] = mkState(ctx, E, 1, t, d, cosF) end
        else
          if -cosF > -0.35 then out[#out + 1] = mkState(ctx, E, -1, t, d, -cosF) end
        end
      end
    end
  end
  table.sort(out, function(p, q) return p.cost < q.cost end)
  for i = #out, M.MAX_CANDS + 1, -1 do out[i] = nil end
  if #out == 0 and ctx.findClosestRoad then
    local ok, n1, n2, dist = pcall(ctx.findClosestRoad, s.x, s.y, s.z)
    local E = ok and n1 and n2 and ix.pair[n1] and ix.pair[n1][n2]
    if E and not ctx.avoid[E.key] and (dist or 0) <= ctx.maxOffM then
      local t, dxy = project(E, s.x, s.y)
      local cosF = s.hx * E.ux + s.hy * E.uy
      local dir = (E.ab and E.ba) and (cosF >= 0 and 1 or -1) or (E.ab and 1 or -1)
      if dir * cosF > -0.35 then out[1] = mkState(ctx, E, dir, t, dxy, dir * cosF) end
    end
  end
  return out
end

-- ------------------------------------------------------------------------------------------------------------- transitions
local function near(ctx, node)
  local t = ctx.nearCache[node]
  if not t then
    t = ctx.ix.adj[node] and search(ctx.ix, node, nil, M.NEAR_CUT_M, false, ctx.avoid) or { [node] = 0 }
    ctx.nearCache[node] = t
  end
  return t
end

-- metres through the graph from state s1's spot to s2's spot; nil when there is no way
local function netDist(ctx, s1, s2)
  if s1.E == s2.E and s1.dir == s2.dir then
    local d = s2.u - s1.u
    if d >= -M.BACK_TOL_M then return max(d, 0) end
    return nil
  end
  local rem = s1.E.len - s1.u
  if s1.to == s2.from then return rem + s2.u end
  local dd = near(ctx, s1.to)[s2.from]
  if dd then return rem + dd + s2.u end
  return nil
end

local function viterbi(ctx, S, cands)
  local runs, layer, start = {}, nil, nil
  local function close(k)
    if not layer then return end
    local best
    for _, s in ipairs(layer) do if not best or s.acc < best.acc then best = s end end
    local rev, s = {}, best
    while s do rev[#rev + 1] = s s = s.prev end
    local seq = {}
    for i = #rev, 1, -1 do seq[#seq + 1] = rev[i] end
    runs[#runs + 1] = { k0 = start, k1 = k, states = seq }
    layer, start = nil, nil
  end
  for k = 1, #S do
    local cs = cands[k]
    if #cs == 0 then
      close(k - 1)
    elseif not layer then
      for _, s in ipairs(cs) do s.acc = s.cost end
      layer, start = cs, k
    else
      local ds = ctx.step[k]
      local nl = {}
      for _, s2 in ipairs(cs) do
        local best, bp
        for _, s1 in ipairs(layer) do
          local nd = netDist(ctx, s1, s2)
          if nd then
            local c = s1.acc + abs(nd - ds) * M.TRANS_W
            if not best or c < best then best, bp = c, s1 end
          end
        end
        if bp then
          s2.acc, s2.prev = best + s2.cost, bp
          nl[#nl + 1] = s2
        end
      end
      if #nl == 0 then
        close(k - 1)
        for _, s in ipairs(cs) do s.acc, s.prev = s.cost, nil end
        layer, start = cs, k
      else
        layer = nl
      end
    end
  end
  close(#S)
  return runs
end

-- ------------------------------------------------------------------------------------------------------------ assembling
local function runToPiece(S, run)
  local visits, anchors = {}, {}
  for idx, st in ipairs(run.states) do
    local k = run.k0 + idx - 1
    local last = visits[#visits]
    if not last or last.E ~= st.E or last.dir ~= st.dir then
      last = { E = st.E, dir = st.dir, from = st.from, to = st.to, u0 = st.u, u1 = st.u, via = M.NEAR_CUT_M * 2 }
      visits[#visits + 1] = last
    else
      last.u1 = st.u
    end
    anchors[#anchors + 1] = { m = S[k].m, vi = #visits, u = st.u }
  end
  return { visits = visits, anchors = anchors, m0 = S[run.k0].m, m1 = S[run.k1].m }
end

-- Can the chain's end be joined to piece B (a hole of the route between them)? Returns the extra path length and the weight
-- limit the assembly may search with, or nil.
local function tryJoin(ctx, lastV, firstV, gap)
  if lastV.E == firstV.E and lastV.dir == firstV.dir and firstV.u0 >= lastV.u1 - M.BACK_TOL_M then
    return max(firstV.u0 - lastV.u1, 0), nil
  end
  local rem = lastV.E.len - lastV.u1
  local limit = max(gap, 0) * M.JOIN_DETOUR + M.JOIN_SLACK_M
  if lastV.to == firstV.from then
    local extra = rem + firstV.u0
    if extra <= limit then return extra, M.NEAR_CUT_M end
    return nil
  end
  local names, real = shortest(ctx.ix, lastV.to, firstV.from, limit * 2, true, ctx.avoid)
  if not names then return nil end
  local extra = rem + real + firstV.u0
  if extra <= limit then return extra, limit * 2 end
  return nil
end

local function joinPieces(ctx, pieces)
  local chains = {}
  local cur
  for _, p in ipairs(pieces) do
    if cur then
      local lastV = cur.visits[#cur.visits]
      local gap = p.m0 - cur.m1
      local extra, via = tryJoin(ctx, lastV, p.visits[1], gap)
      if extra then
        local off = #cur.visits
        local first = p.visits[1]
        local merged = lastV.E == first.E and lastV.dir == first.dir and via == nil
        for i, v in ipairs(p.visits) do
          if i == 1 and merged then
            lastV.u1 = v.u1
          else
            if i == 1 then v.via = via; v.joined = true end
            cur.visits[#cur.visits + 1] = v
          end
        end
        for _, a in ipairs(p.anchors) do
          local vi
          if merged then vi = a.vi == 1 and off or (a.vi + off - 1) else vi = a.vi + off end
          cur.anchors[#cur.anchors + 1] = { m = a.m, vi = vi, u = a.u }
        end
        cur.m1 = p.m1
      else
        chains[#chains + 1] = cur
        cur = p
      end
    else
      cur = p
    end
  end
  if cur then chains[#chains + 1] = cur end
  return chains
end

-- A chain of visits -> segments {names, anchors {ar, ap}, detours}; it splits where two visits cannot be connected any more.
local function assemble(ctx, chain)
  local ix = ctx.ix
  local segs, cur = {}, nil
  local where = {}      -- visit index -> {seg, node index of its from node}
  for vi, v in ipairs(chain.visits) do
    local ok = true
    if cur then
      local last = cur.names[#cur.names]
      if v.from ~= last then
        local nodes = shortest(ix, last, v.from, v.via or (M.NEAR_CUT_M * 2), true, ctx.avoid)
        if nodes then
          for i = 2, #nodes do cur.names[#cur.names + 1] = nodes[i] end
          if v.joined then cur.detours = cur.detours + 1 end
        else
          ok = false
        end
      end
    end
    if not cur or not ok then
      cur = { names = { v.from }, detours = 0, anchors = { ar = {}, ap = {} }, visits = {} }
      segs[#segs + 1] = cur
    end
    where[vi] = { seg = cur, idx = #cur.names }
    cur.names[#cur.names + 1] = v.to
  end
  for _, s in ipairs(segs) do
    s.cum = { 0 }
    for i = 2, #s.names do s.cum[i] = s.cum[i - 1] + ix.pair[s.names[i - 1]][s.names[i]].len end
  end
  for _, a in ipairs(chain.anchors) do
    local w = where[a.vi]
    local s = w.seg
    local ap = s.cum[w.idx] + a.u
    local n = #s.anchors.ar
    if n == 0 or (a.m > s.anchors.ar[n] and ap >= s.anchors.ap[n]) then
      s.anchors.ar[n + 1], s.anchors.ap[n + 1] = a.m, ap
    elseif a.m > s.anchors.ar[n] then
      s.anchors.ar[n + 1], s.anchors.ap[n + 1] = a.m, s.anchors.ap[n]
    end
  end
  return segs
end

-- ------------------------------------------------------------------------------------------------------------ finalizing
local function dist3(a, b) return sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end

local function edgeDir(res, i)
  local a, b = res.pts[i], res.pts[i + 1]
  local dx, dy = b.x - a.x, b.y - a.y
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-9 then return 0, 0 end
  return dx / l, dy / l
end

local function locate(res, along)
  local cum, n = res.cum, #res.cum
  if n < 2 then return nil end
  along = clamp(along, 0, cum[n])
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if cum[mid] <= along then lo = mid else hi = mid end
  end
  local len = cum[hi] - cum[lo]
  return lo, len > 1e-9 and (along - cum[lo]) / len or 0
end

function M.pointAt(res, along)
  local i, f = locate(res, along)
  if not i then return nil end
  local a, b = res.pts[i], res.pts[i + 1]
  local dx, dy = edgeDir(res, i)
  return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, (a.z or 0) + ((b.z or 0) - (a.z or 0)) * f, dx, dy
end

function M.junctionsAhead(res, along, maxM)
  local out = {}
  for _, j in ipairs(res.junctions) do
    local d = j.along - along
    if d >= -0.01 and d <= (maxM or math.huge) then
      out[#out + 1] = { along = j.along, dist = max(d, 0), name = j.name, degree = j.degree, index = j.index }
    end
  end
  return out
end

local function turnAt(res, i)
  local ax, ay, bx, by
  local k = i - 1
  while k >= 1 do
    ax, ay = res.pts[i].x - res.pts[k].x, res.pts[i].y - res.pts[k].y
    if ax * ax + ay * ay > 0.25 then break end
    k = k - 1
  end
  k = i + 1
  while k <= #res.pts do
    bx, by = res.pts[k].x - res.pts[i].x, res.pts[k].y - res.pts[i].y
    if bx * bx + by * by > 0.25 then break end
    k = k + 1
  end
  if not (ax and bx) or k > #res.pts or (ax * ax + ay * ay) <= 0.25 then return nil end
  local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
  local c = clamp((ax * bx + ay * by) / (la * lb), -1, 1)
  local deg = math.deg(math.acos(c))
  if ax * by - ay * bx < 0 then deg = -deg end
  return deg
end

local function platformXY(ctx, i)
  local s = ctx.route.stops[i]
  if s.lat and s.lon then
    local x, y = ctx.toGame(s.lat, s.lon)
    return x, y
  end
  return nil
end

-- The path with everything the driver wants. anchors = {ar, ap} (route metres -> path metres).
local function finalize(ix, ctx, names, anchors)
  local res = { path = names, cum = { 0 }, pts = {}, radius = {}, _ctx = ctx, anchors = anchors, warnings = {},
    problems = { missing = {}, jumps = {}, wrongWay = {}, narrow = {}, sharp = {}, uturn = {} } }
  for i, nm in ipairs(names) do
    local n = ix.nodes[nm]
    res.pts[i] = { x = n.pos.x, y = n.pos.y, z = n.pos.z or 0 }
    res.radius[i] = n.radius
  end
  res.edges = {}
  for i = 2, #names do
    local E = ix.pair[names[i - 1]] and ix.pair[names[i - 1]][names[i]]
    res.edges[i - 1] = E
    res.cum[i] = res.cum[i - 1] + (E and E.len or dist3(res.pts[i - 1], res.pts[i]))
  end
  res.length = res.cum[#res.cum]
  res.routeLength = ctx.routeLength
  local ar, ap = anchors.ar, anchors.ap
  local n = #ar
  res.fromAlong, res.toAlong = ar[1] or 0, ar[n] or 0
  local covered = res.toAlong - res.fromAlong
  res.coverage = ctx.routeLength > 0 and covered / ctx.routeLength or 0
  res.complete = res.coverage >= M.COMPLETE
  res.lengthRatio = covered > 1 and ((ap[n] - ap[1]) / covered) or 1
  local W = res.warnings
  if abs(res.lengthRatio - 1) > M.LEN_TOL then W[#W + 1] = 'length' end
  if not res.complete then W[#W + 1] = 'partial' end

  -- structural problems against the graph
  local okV, rep = M.validate(names, ix, {})
  res.problems.missing, res.problems.jumps, res.problems.wrongWay = rep.missing, rep.jumps, rep.wrongWay

  -- nodes, junctions, turns
  res.nodes, res.junctions = {}, {}
  for i, nm in ipairs(names) do
    local deg = ix.deg[nm] or 0
    local turn = (i > 1 and i < #names) and turnAt(res, i) or nil
    local info = { name = nm, along = res.cum[i], degree = deg, junction = deg > 2, radius = res.radius[i], turn = turn }
    res.nodes[i] = info
    if deg > 2 then res.junctions[#res.junctions + 1] = { index = i, name = nm, along = res.cum[i], degree = deg } end
    if turn and abs(turn) > M.SHARP_DEG then
      res.problems.sharp[#res.problems.sharp + 1] = { index = i, along = res.cum[i], angle = turn }
      if abs(turn) > M.UTURN_DEG then res.problems.uturn[#res.problems.uturn + 1] = i end
    end
  end
  -- narrow edges (a stretch of consecutive ones is one entry)
  local minR = ctx.minRadius
  for i, E in ipairs(res.edges) do
    if E and E.radius and E.radius < minR then
      res.nodes[i].narrowAfter = true
      local last = res.problems.narrow[#res.problems.narrow]
      if last and abs(last.to - res.cum[i]) < 0.01 then
        last.to, last.b = res.cum[i + 1], names[i + 1]
      else
        res.problems.narrow[#res.problems.narrow + 1] = { from = res.cum[i], to = res.cum[i + 1], a = names[i], b = names[i + 1] }
      end
    end
  end
  if #res.problems.narrow > 0 then W[#W + 1] = 'narrow' end
  if #res.problems.sharp > 0 then W[#W + 1] = 'sharp' end
  if #res.problems.uturn > 0 then W[#W + 1] = 'uturn' end

  -- ends: clipped by the graph window / dead end
  res.head = { clipped = res.fromAlong > M.CLIP_M }
  res.tail = { clipped = ctx.routeLength - res.toAlong > M.CLIP_M, deadEnd = false }
  if res.tail.clipped and #names >= 2 then
    local outs = 0
    for _, a in ipairs(ix.adj[names[#names]] or {}) do if a.to ~= names[#names - 1] then outs = outs + 1 end end
    res.tail.deadEnd = outs == 0
  end
  if res.head.clipped then W[#W + 1] = 'clippedHead' end
  if res.tail.clipped then W[#W + 1] = 'clippedTail' end
  if res.tail.deadEnd then W[#W + 1] = 'deadEnd' end
  res.usableFrom = res.head.clipped and M.SAFE_END_M or 0
  res.usableTo = res.length - (res.tail.clipped and M.SAFE_END_M or 0)

  -- stops
  res.stops, res.droppedStops = {}, {}
  local stops = ctx.route.stops or {}
  local WIN = 35
  for si, s in ipairs(stops) do
    local sa = s.along
    local placed = false
    if sa and n >= 1 and sa >= ar[1] - ctx.sampleM and sa <= ar[n] + ctx.sampleM and #names >= 2 then
      local p0 = interp(ar, ap, sa)
      local px, py = platformXY(ctx, si)
      local bestAlong, bestD, bestEdge, bestT, bestV
      if px then
        for i = 1, #names - 1 do
          if res.cum[i + 1] >= p0 - WIN and res.cum[i] <= p0 + WIN then
            local a, b = res.pts[i], res.pts[i + 1]
            local ex, ey = b.x - a.x, b.y - a.y
            local l2 = ex * ex + ey * ey
            local t = l2 > 1e-9 and clamp(((px - a.x) * ex + (py - a.y) * ey) / l2, 0, 1) or 0
            local qx, qy = a.x + ex * t, a.y + ey * t
            local d = sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
            if not bestD or d < bestD then
              bestD, bestEdge, bestT = d, i, t
              bestAlong = res.cum[i] + t * (res.cum[i + 1] - res.cum[i])
              bestV = { px - qx, py - qy }
            end
          end
        end
      end
      local far = (not bestD) or bestD > M.FAR_PLATFORM_M
      local along, side, offset
      if far then
        along = p0
        local i, f = locate(res, along)
        bestEdge, bestT = i, f
        side = (s.side and s.side ~= 0) and (s.side > 0 and 1 or -1) or 0
        offset = s.off or bestD or 0
      else
        along = bestAlong
        local ux, uy = edgeDir(res, bestEdge)
        side = (ux * bestV[2] - uy * bestV[1]) < 0 and 1 or -1
        offset = bestD
      end
      local x, y, z, dx, dy = M.pointAt(res, along)
      local ni = locate(res, along)
      local ra, rb = res.radius[bestEdge], res.radius[bestEdge + 1]
      local jA, jB
      for _, j in ipairs(res.junctions) do
        if j.along >= along then
          if not jA then jA = j.along - along end
        else
          jB = along - j.along
        end
      end
      res.stops[#res.stops + 1] = { index = si, id = s.id, name = s.name, along = along, routeAlong = sa, side = side,
        offset = offset, halfWidth = (ra and rb) and (ra + (rb - ra) * bestT) or ra or rb,
        sideOk = side == 0 or side == (ctx.leftHand and -1 or 1), far = far, x = x, y = y, z = z, dirX = dx, dirY = dy,
        nodeIndex = ni, nodeName = names[ni], junctionAhead = jA, junctionBehind = jB }
      placed = true
    end
    if not placed then res.droppedStops[#res.droppedStops + 1] = si end
  end

  -- safe places for a bus to appear / be teleported to
  local bad = {}
  for _, j in ipairs(res.junctions) do bad[#bad + 1] = { j.along - M.SAFE_JUNCTION_M, j.along + M.SAFE_JUNCTION_M } end
  for _, sp in ipairs(res.problems.sharp) do bad[#bad + 1] = { sp.along - M.SAFE_JUNCTION_M, sp.along + M.SAFE_JUNCTION_M } end
  for _, nr in ipairs(res.problems.narrow) do bad[#bad + 1] = { nr.from, nr.to } end
  local function valid(d)
    if d < res.usableFrom or d > res.usableTo then return false end
    for _, iv in ipairs(bad) do if d > iv[1] and d < iv[2] then return false end end
    return true
  end
  res.safeSpawn = function(distAlong)
    if res.usableTo <= res.usableFrom then return nil end
    local d0 = clamp(distAlong or 0, res.usableFrom, res.usableTo)
    local found
    local stepM = 2
    for k = 0, floor(res.length / stepM) + 1 do
      for _, sgn in ipairs({ 1, -1 }) do
        local d = d0 + sgn * k * stepM
        if not found and valid(d) then found = d end
      end
      if found then break end
    end
    if not found then return nil end
    local i, f = locate(res, found)
    local x, y, z, dx, dy = M.pointAt(res, found)
    local E = res.edges[i]
    local lateral = 0
    if E and not E.oneWay then
      lateral = min((E.radius or 2 * M.LANE_SHIFT_M) * 0.5, M.LANE_SHIFT_M)
      if ctx.leftHand then lateral = -lateral end
      x, y = x + dy * lateral, y - dx * lateral       -- the right-hand normal of (dx, dy) is (dy, -dx)
    end
    return { x = x, y = y, z = z, dirX = dx, dirY = dy, along = found, nodeIndex = i, lateral = lateral }
  end

  res.ok = abs(res.lengthRatio - 1) <= M.LEN_TOL and #res.problems.missing == 0 and #res.problems.jumps == 0
    and #res.problems.wrongWay == 0 and #res.problems.narrow == 0 and #res.problems.uturn == 0
  return res
end

-- ----------------------------------------------------------------------------------------------------------------- validate
local function rawOf(graph) return graph.isIndex and graph.nodes or graph end

function M.validate(path, graph, opts)
  opts = opts or {}
  local g = rawOf(graph)
  local rep = { missing = {}, jumps = {}, wrongWay = {}, uturns = {}, length = 0 }
  local prev
  for i, name in ipairs(path) do
    local n = g[name]
    if not n then
      rep.missing[#rep.missing + 1] = i
    elseif prev and path[i - 1] then
      local e = prev.links and prev.links[name]
      if not e then
        rep.jumps[#rep.jumps + 1] = i
      else
        if e.oneWay and e.inNode ~= nil and e.inNode ~= path[i - 1] then rep.wrongWay[#rep.wrongWay + 1] = i end
        local a, b = prev.pos, n.pos
        rep.length = rep.length + dist3({ x = a.x, y = a.y, z = a.z }, { x = b.x, y = b.y, z = b.z })
      end
    end
    if i > 2 and path[i] == path[i - 2] then rep.uturns[#rep.uturns + 1] = i end
    prev = n
  end
  local ok = #rep.missing == 0 and #rep.jumps == 0 and #rep.wrongWay == 0
  if opts.routeLength and opts.routeLength > 0 then
    rep.ratio = rep.length / opts.routeLength
    if abs(rep.ratio - 1) > M.LEN_TOL then ok = false end
  end
  return ok, rep
end

local function edgeOk(g, a, b)
  local na, nb = g[a], g[b]
  if not (na and nb and na.links) then return false end
  local e = na.links[b]
  if not e then return false end
  if e.oneWay and e.inNode ~= nil and e.inNode ~= a then return false end
  return true
end

function M.trim(path, graph, opts)
  opts = opts or {}
  local g = rawOf(graph)
  local runs, cur, holes = {}, nil, 0
  for i, name in ipairs(path) do
    if g[name] then
      if cur and edgeOk(g, path[i - 1], name) then
        cur.last = i
      else
        if cur then holes = holes + 1 end
        cur = { first = i, last = i }
        runs[#runs + 1] = cur
      end
    else
      if cur then holes = holes + 1 end
      cur = nil
    end
  end
  local best
  local at = opts.at
  for _, r in ipairs(runs) do
    if r.last > r.first then
      if at then
        -- the run holding the bus, else the first one ahead of it, else the last behind
        if r.first <= at and at <= r.last then best = r break end
        if r.first > at and (not best or best.first <= at) then best = r
        elseif not best then best = r end
      elseif not best or (r.last - r.first) > (best.last - best.first) then
        best = r
      end
    end
  end
  if not best then return nil, { holes = holes } end
  local out = {}
  for i = best.first, best.last do out[#out + 1] = path[i] end
  return out, { first = best.first, last = best.last, droppedFront = best.first - 1, droppedBack = #path - best.last,
    holes = holes }
end

-- the path of res on the graph without what it lost; stops and anchors follow
function M.trimResult(res, graph, opts)
  local ix = M.index(graph)
  local ctx = res._ctx
  local path, info = M.trim(res.path, ix, opts)
  if not path then return nil end
  -- a node of the old path may exist but sit elsewhere: the result is built from the graph's own positions
  local c0, c1 = res.cum[info.first], res.cum[info.last]
  local ar, ap = {}, {}
  for i = 1, #res.anchors.ar do
    local p = res.anchors.ap[i]
    if p >= c0 - 1e-6 and p <= c1 + 1e-6 then
      ar[#ar + 1], ap[#ap + 1] = res.anchors.ar[i], p - c0
    end
  end
  if #ar == 0 then return nil end
  -- the route metres at the cut ends, from the map path -> route
  local out = finalize(ix, ctx, path, { ar = ar, ap = ap })
  M.setDetours(out, res.detours)
  out.segments = nil
  out.trimmed = info
  return out
end

-- ------------------------------------------------------------------------------------------------------------------- build
local function newCtx(route, ix, opts)
  local ctx = { route = route, ix = ix, toGame = opts.toGame, heightAt = opts.heightAt, findClosestRoad = opts.findClosestRoad,
    sampleM = opts.sampleM or M.SAMPLE_M, maxOffM = opts.maxOffM or M.MAX_OFF_M, wz = opts.wz or M.WZ,
    minRadius = opts.minRadius == nil and M.MIN_RADIUS or opts.minRadius, avoid = asAvoid(opts.avoidEdges),
    leftHand = opts.leftHand and true or false, nearCache = {}, opts = opts }
  return ctx
end

local function buildCtx(ctx)
  local S, total = sampleRoute(ctx.route, ctx)
  if not S then return nil, 'route' end
  ctx.routeLength = total
  local cands, any = {}, false
  for k, s in ipairs(S) do
    cands[k] = candidates(ctx.ix, ctx, s)
    if #cands[k] > 0 then any = true end
  end
  if not any then return nil, 'no match' end
  local runs = viterbi(ctx, S, cands)
  local pieces = {}
  for _, run in ipairs(runs) do
    local p = runToPiece(S, run)
    if p.m1 - p.m0 >= M.MIN_RUN_M then pieces[#pieces + 1] = p end
  end
  if #pieces == 0 then return nil, 'no match' end
  local out = {}
  for _, chain in ipairs(joinPieces(ctx, pieces)) do
    for _, seg in ipairs(assemble(ctx, chain)) do
      if #seg.anchors.ar >= 2 and #seg.names >= 2 then
        local res = finalize(ctx.ix, ctx, seg.names, seg.anchors)
        M.setDetours(res, seg.detours)
        -- a safety net: whatever the graph does not allow is cut off
        if #res.problems.missing + #res.problems.jumps + #res.problems.wrongWay > 0 then
          local t = M.trimResult(res, ctx.ix)
          if t then M.setDetours(t, seg.detours) res = t else res = nil end
        end
        if res then out[#out + 1] = res end
      end
    end
  end
  if #out == 0 then return nil, 'no match' end
  table.sort(out, function(p, q) return (p.toAlong - p.fromAlong) > (q.toAlong - q.fromAlong) end)
  return out
end

function M.setDetours(res, n)
  res.detours = n or 0
  if res.detours > 0 then
    for _, w in ipairs(res.warnings) do if w == 'detour' then return end end
    res.warnings[#res.warnings + 1] = 'detour'
  end
end

local function pick(list, nearAlong)
  if not nearAlong then return list[1] end
  local best, bd
  for _, r in ipairs(list) do
    local d = 0
    if nearAlong < r.fromAlong then d = r.fromAlong - nearAlong elseif nearAlong > r.toAlong then d = nearAlong - r.toAlong end
    if not bd or d < bd - 1e-6 then best, bd = r, d end
  end
  return best
end

local function usedNarrow(res)
  local out = {}
  for i = 1, #res.edges do
    local E = res.edges[i]
    if E and E.radius and E.radius < res._ctx.minRadius then out[E.key] = true end
  end
  return out
end

function M.buildAll(route, graph, opts)
  if type(opts) ~= 'table' or not opts.toGame then return nil, 'toGame' end
  if type(route) ~= 'table' or type(route.path) ~= 'table' then return nil, 'route' end
  local ix = M.index(graph)
  local ctx = newCtx(route, ix, opts)
  local list, why = buildCtx(ctx)
  if not list then return nil, why end
  if opts.repair ~= false then
    local anyNarrow = false
    for _, r in ipairs(list) do if #r.problems.narrow > 0 then anyNarrow = true end end
    if anyNarrow then
      local avoid = {}
      for k in pairs(ctx.avoid) do avoid[k] = true end
      for _, r in ipairs(list) do for k in pairs(usedNarrow(r)) do avoid[k] = true end end
      local o2 = {}
      for k, v in pairs(opts) do o2[k] = v end
      o2.avoidEdges, o2.repair = avoid, false
      local list2 = buildCtx(newCtx(route, ix, o2))
      if list2 then
        local c1, c2 = 0, 0
        local n1, n2 = 0, 0
        for _, r in ipairs(list) do c1 = max(c1, r.coverage) n1 = n1 + #r.problems.narrow end
        for _, r in ipairs(list2) do c2 = max(c2, r.coverage) n2 = n2 + #r.problems.narrow end
        if n2 < n1 and c2 >= c1 - 0.02 then
          for _, r in ipairs(list2) do r.repaired = true end
          list = list2
        end
      end
    end
  end
  return list
end

function M.build(route, graph, opts)
  local list, why = M.buildAll(route, graph, opts)
  if not list then return nil, why end
  local res = pick(list, opts.nearAlong)
  res.segments = list
  return res
end

-- ------------------------------------------------------------------------------------------------------------------ extend
function M.extend(res, graph, opts)
  opts = opts or {}
  local ix = M.index(graph)
  local ctx = res._ctx
  local t = M.trimResult(res, ix, { at = opts.at })
  local o = {}
  for k, v in pairs(ctx.opts) do o[k] = v end
  for k, v in pairs(opts) do if k ~= 'at' then o[k] = v end end
  local list = M.buildAll(ctx.route, ix, o)
  if not list then return t end
  if not t then
    local r = pick(list, o.nearAlong or res.toAlong)
    r.segments, r.replaced = list, true
    return r
  end
  -- the fresh segment that shares the most nodes with what is left
  local have = {}
  for _, nm in ipairs(t.path) do have[nm] = true end
  local best, bestShared
  for _, r in ipairs(list) do
    local shared = 0
    for _, nm in ipairs(r.path) do if have[nm] then shared = shared + 1 end end
    if shared > 0 and (not bestShared or shared > bestShared) then best, bestShared = r, shared end
  end
  if not best then
    local r = pick(list, o.nearAlong or res.toAlong)
    r.segments, r.replaced = list, true
    return r
  end
  local tp, fp = t.path, best.path
  local last = tp[#tp]
  local j
  for k = #fp, 1, -1 do
    if fp[k] == last and (#tp == 1 or k == 1 or fp[k - 1] == tp[#tp - 1]) then j = k break end
  end
  if not j or j == #fp then
    if not j then
      best.segments, best.replaced = list, true
      return best
    end
    t.segments = list
    return t
  end
  local names, tcum = {}, t.cum[#t.path]
  for _, nm in ipairs(tp) do names[#names + 1] = nm end
  for k = j + 1, #fp do names[#names + 1] = fp[k] end
  local shift = tcum - best.cum[j]
  local ar, ap = {}, {}
  for i = 1, #t.anchors.ar do ar[i], ap[i] = t.anchors.ar[i], t.anchors.ap[i] end
  for i = 1, #best.anchors.ar do
    local p = best.anchors.ap[i] + shift
    if p > (ap[#ap] or -1) + 1e-6 and best.anchors.ar[i] > (ar[#ar] or -1) then
      ar[#ar + 1], ap[#ap + 1] = best.anchors.ar[i], p
    end
  end
  local out = finalize(ix, ctx, names, { ar = ar, ap = ap })
  M.setDetours(out, (t.detours or 0) + (best.detours or 0))
  out.extended = true
  out.segments = list
  return out
end

-- --------------------------------------------------------------------------------------------------------------- reroute
local function blockedKey(blocked)
  if type(blocked) == 'string' then
    local a, b = blocked:match('^(.-)|(.*)$')
    return a and M.edgeKey(a, b)
  end
  if type(blocked) == 'table' then
    local a, b = blocked[1] or blocked.a or blocked.inNode, blocked[2] or blocked.b or blocked.outNode
    return a and b and M.edgeKey(a, b)
  end
end

function M.reroute(arg, blocked, graph, opts)
  opts = opts or {}
  local key = blockedKey(blocked)
  if not key then return nil, 'blocked' end
  local ix = M.index(graph)
  if type(arg) == 'table' and arg._ctx then
    local o = {}
    for k, v in pairs(arg._ctx.opts) do o[k] = v end
    local avoid = {}
    for k in pairs(arg._ctx.avoid) do avoid[k] = true end
    avoid[key] = true
    for k in pairs(asAvoid(opts.avoidEdges)) do avoid[k] = true end
    o.avoidEdges, o.nearAlong = avoid, o.nearAlong or arg.fromAlong
    local r, why = M.build(arg._ctx.route, ix, o)
    if not r then return nil, why end
    r.rerouted = true
    return r
  end
  local path = arg
  local avoid = asAvoid(opts.avoidEdges)
  local blockedSet = {}
  for k in pairs(avoid) do blockedSet[k] = true end
  blockedSet[key] = true
  local at = opts.at or 1
  local i
  for k = max(at, 1), #path - 1 do
    if M.edgeKey(path[k], path[k + 1]) == key then i = k break end
  end
  if not i then return nil, 'not on the path' end
  if not ix.adj[path[i]] then return nil, 'missing' end
  local cum = { 0 }
  for k = 2, #path do
    local E = ix.pair[path[k - 1]] and ix.pair[path[k - 1]][path[k]]
    cum[k] = cum[k - 1] + (E and E.len or 0)
  end
  local limit = opts.maxDetourM or (3 * (cum[#path] - cum[i]) + 250)
  limit = min(limit, opts.maxDetourM or 1500)
  local dist, prev = search(ix, path[i], nil, limit, true, blockedSet)
  -- the detour rejoins the old path at the first node that costs (nearly) the least extra: not at the farthest one, which
  -- would drop the stretch between (its stops) from the path
  local extras, minExtra = {}, nil
  for j = i + 1, #path do
    local d = dist[path[j]]
    if d then
      extras[j] = d - (cum[j] - cum[i])
      if not minExtra or extras[j] < minExtra then minExtra = extras[j] end
    end
  end
  if not minExtra then return nil, 'no detour' end
  local bestJ, bestExtra
  for j = i + 1, #path do
    if extras[j] and extras[j] <= minExtra + 30 then bestJ, bestExtra = j, extras[j] break end
  end
  local mid = unwind(prev, path[i], path[bestJ])
  if not mid then return nil, 'no detour' end
  local out = {}
  for k = 1, i do out[#out + 1] = path[k] end
  for k = 2, #mid do out[#out + 1] = mid[k] end
  for k = bestJ + 1, #path do out[#out + 1] = path[k] end
  return out, { from = i, to = bestJ, extra = bestExtra }
end

return M
