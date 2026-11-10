local H = dofile('tests/harness.lua')
local geo = require('earthBusRoutes/geomath')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local B = require('earthBusRoutes/builder')
local T = {}

local NACHOD = { name = 'Náchod, autobusové nádraží', lat = 50.4157, lon = 16.1626, station = true }
local MID = { name = 'Hronov', lat = 50.584, lon = 16.33 }
local BROUMOV = { name = 'Broumov, autobusové nádraží', lat = 50.5855, lon = 16.332, station = true }

-- The data service's answer for these three stations, from a recorded OSRM response
local function pathAnswer()
  local raw = H.fixture('osrm_nachod_broumov').routes[1]
  local pts = {}
  for i, c in ipairs(raw.geometry.coordinates) do pts[i] = { c[2], c[1] } end
  local legs = {}
  for i, l in ipairs(raw.legs) do legs[i] = { dist = l.distance, dur = l.duration } end
  return { points = pts, legs = legs, source = 'osrm' }
end

local function built()
  local s = B.new(NACHOD)
  assert(B.add(s, MID) and B.add(s, BROUMOV))
  assert(B.applyPath(s, pathAnswer()))
  return s
end

-- Stop nodes put beside the road every `step` metres: on the right (even) or left (odd) side, `off` metres away
local function stopsBeside(s, from, to, step, off)
  local els, n = {}, 0
  local m = from
  while m < to do
    local lat, lon, brg = geo.pointAt(s.path, s.cum, m)
    n = n + 1
    local right = (n % 2 == 0)
    local b = math.rad((brg + (right and 90 or -90)) % 360)
    local dlat = off * math.cos(b) / 111195
    local dlon = off * math.sin(b) / (111195 * math.cos(math.rad(lat)))
    els[#els + 1] = { type = 'node', id = 9000 + n, lat = lat + dlat, lon = lon + dlon,
      tags = { highway = 'bus_stop', name = 'Zastávka ' .. n, public_transport = 'platform', bus = 'yes' } }
    m = m + step
  end
  return els
end

function T.new_state_add_undo_and_limits()
  local s = B.new(NACHOD)
  assert(#s.points == 1)
  assert(not B.add(s, NACHOD), 'the same place twice in a row')
  assert(B.add(s, MID))
  assert(B.pts(s) == '50.415700,16.162600;50.584000,16.330000')
  assert(B.undo(s) and #s.points == 1)
  assert(not B.undo(s), 'the first station stays')
  for i = 1, B.MAX_POINTS - 1 do assert(B.add(s, { name = 'S' .. i, lat = 50.4 + i * 0.01, lon = 16.2 })) end
  local ok, why = B.add(s, { name = 'one more', lat = 51, lon = 17 })
  assert(not ok and why == 'full')
end

function T.path_answer_gives_length_and_legs()
  local s = built()
  assert(s.length > 31000 and s.length < 34000, s.length)
  local info = B.legInfo(s)
  assert(#info == 2 and info[1].km > 30 and info[1].min > 30 and info[1].from == NACHOD.name and info[2].to == BROUMOV.name)
  assert(not s.straight)
  B.add(s, { name = 'Police', lat = 50.52, lon = 16.24 })
  assert(s.path == nil and #s.legs == 0, 'a new station invalidates the path')
  local straight = B.new(NACHOD)
  B.add(straight, BROUMOV)
  B.applyPath(straight, { points = { { 50.4157, 16.1626 }, { 50.5855, 16.332 } }, legs = { { dist = 20000, dur = 1800 } }, source = 'straight' })
  assert(straight.straight)
end

function T.candidates_are_a_ring_with_bus_stations_first()
  local a = osm.parseAround(H.fixture('nachod_around_slim'))
  local stations = osm.groupStops(a.stops)
  local s = B.new({ name = 'x', lat = 50.4157, lon = 16.1626 })
  local c = B.candidates(stations, s, { min = 100, max = 700 })
  assert(#c >= 3, #c)
  local seenPlain = false
  for _, x in ipairs(c) do
    assert(x.dist >= 100 and x.dist <= 700 and x.dir and x.name ~= '')
    if not x.station then seenPlain = true elseif seenPlain then error('a bus station after a plain stop') end
  end
  for i = 2, #c do if c[i].station == c[i - 1].station then assert(c[i].dist >= c[i - 1].dist) end end
  -- chosen stations are not offered again
  local first = c[1]
  B.add(s, first)
  for _, x in ipairs(B.candidates(stations, s, { min = 0, max = 700 })) do assert(x.name ~= first.name or x.dist > 150) end
end

function T.search_lists_every_match_nearest_first()
  local a = osm.parseAround(H.fixture('nachod_around_slim'))
  local stations = osm.groupStops(a.stops)
  local s = B.new({ name = 'x', lat = 50.4157, lon = 16.1626 })
  local c = B.candidates(stations, s, { byName = true })
  assert(#c >= 3)
  for i = 2, #c do assert(c[i].dist >= c[i - 1].dist) end
end

function T.ahead_flag_follows_the_leg_direction()
  local s = B.new({ name = 'A', lat = 50.0, lon = 16.0 })
  B.add(s, { name = 'B', lat = 50.05, lon = 16.0 })            -- we drive north
  local st = function(name, lat, lon) return { name = name, lat = lat, lon = lon, platforms = {}, station = false, nodeIds = {} } end
  local c = B.candidates({ st('north', 50.10, 16.0), st('south', 49.95, 16.0) }, s, { min = 100, max = 20000 })
  local by = {}
  for _, x in ipairs(c) do by[x.name] = x end
  assert(by.north.ahead and not by.south.ahead)
end

function T.stops_along_take_the_right_side_and_skip_far_ones()
  local s = built()
  local els = stopsBeside(s, 2000, 30000, 1500, 12)
  els[#els + 1] = { type = 'node', id = 1, lat = 50.5, lon = 16.0, tags = { highway = 'bus_stop', name = 'Far away' } }   -- not near the road
  local stops = B.stopsAlong(s, els)
  assert(#stops >= 15, #stops)
  for i, st in ipairs(stops) do
    assert(st.name ~= 'Far away' and st.off <= 30)
    if i > 1 then assert(st.along >= stops[i - 1].along) end
  end
end

function T.both_sides_of_a_stop_become_one_right_hand_stop()
  local s = built()
  local lat, lon, brg = geo.pointAt(s.path, s.cum, 5000)
  local function beside(side, id)
    local b = math.rad((brg + side) % 360)
    return { type = 'node', id = id, lat = lat + 10 * math.cos(b) / 111195, lon = lon + 10 * math.sin(b) / (111195 * math.cos(math.rad(lat))),
      tags = { highway = 'bus_stop', name = 'U kostela', public_transport = 'platform' } }
  end
  local stops = B.stopsAlong(s, { beside(-90, 1), beside(90, 2) })
  assert(#stops == 1)
  assert(stops[1].id == 2 and stops[1].side > 0, 'the right-hand platform of the way of travel')
end

function T.stop_list_modes_and_switching_off()
  local s = built()
  B.setAuto(s, B.stopsAlong(s, stopsBeside(s, 2000, 30000, 1500, 8)))
  local all = B.stopList(s)
  assert(#all >= 17)
  assert(all[1].chosen and all[1].along == 0 and all[#all].chosen and math.abs(all[#all].along - s.length) < 1)
  local mid = 0
  for _, st in ipairs(all) do if st.chosen then mid = mid + 1 end end
  assert(mid == 3)
  -- switch an automatic one off
  local victim
  for _, st in ipairs(all) do if not st.chosen then victim = st break end end
  assert(B.toggleStop(s, victim.id))
  assert(not B.toggleStop(s, 'w1'), 'a chosen station cannot be switched off')
  local r = assert(B.toRoute(s, -1))
  assert(#r.stops == #all - 1)
  for i, st in ipairs(r.stops) do assert(st.index == i and st.id ~= victim.id) end
  assert(B.toggleStop(s, victim.id))
  assert(#assert(B.toRoute(s, -1)).stops == #all)
  -- express: only the chosen ones
  B.setMode(s, 'express')
  local e = assert(B.toRoute(s, -2))
  assert(#e.stops == 3 and e.stops[1].name == NACHOD.name and e.stops[3].name == BROUMOV.name)
end

function T.automatic_stops_near_a_chosen_one_are_dropped()
  local s = built()
  local lat, lon = geo.pointAt(s.path, s.cum, 0)
  local els = { { type = 'node', id = 5, lat = lat + 0.0002, lon = lon + 0.0002, tags = { highway = 'bus_stop', name = 'Next to the start' } } }
  B.setAuto(s, B.stopsAlong(s, els))
  for _, st in ipairs(B.stopList(s)) do assert(st.name ~= 'Next to the start' or st.chosen) end
end

function T.route_works_with_the_timetable()
  local s = built()
  B.setAuto(s, B.stopsAlong(s, stopsBeside(s, 2000, 30000, 2500, 8)))
  s.ref = '310'
  local r = assert(B.toRoute(s, -7))
  assert(r.custom and r.id == -7 and r.ref == '310' and r.from == NACHOD.name and r.to == BROUMOV.name)
  assert(r.length == s.length and #r.path == #s.path and r.kind == 'regional' and not r.loop)
  assert(r.colour:match('^#%x%x%x%x%x%x$'))
  local trips = sched.generate(r, 2)
  assert(#trips > 10)
  assert(trips[1].arr[#r.stops] > 1500, 'a 33 km run takes a while')
  for i = 2, #r.stops do assert(r.stops[i].along >= r.stops[i - 1].along) end
end

function T.no_path_no_route()
  local s = B.new(NACHOD)
  B.add(s, BROUMOV)
  local r, why = B.toRoute(s, -1)
  assert(r == nil and why)
end

function T.a_loop_is_recognised()
  local s = B.new(NACHOD)
  B.add(s, MID)
  B.add(s, { name = NACHOD.name, lat = 50.41575, lon = 16.16265 })
  local path = pathAnswer()
  s.points[3].lat, s.points[3].lon = NACHOD.lat + 0.0001, NACHOD.lon
  B.applyPath(s, path)
  local r = assert(B.toRoute(s, -3))
  assert(r.loop)
end

function T.reverse_swaps_the_stations()
  local s = built()
  s.ref = '310'
  s.off['123'] = true
  local back = B.reverse(s)
  assert(back.points[1].name == BROUMOV.name and back.points[3].name == NACHOD.name and back.points[2].name == MID.name)
  assert(back.path == nil and back.ref == '310' and back.off['123'])
  assert(B.pts(back) == '50.585500,16.332000;50.584000,16.330000;50.415700,16.162600')
end

function T.save_and_load_round_trip()
  local s = built()
  s.ref, s.name, s.colour = '310', 'Náchod — Broumov', '#cc3300'
  s.mode = 'express'
  s.off['77'] = true
  local d = B.serialize(s)
  local text = jsonEncode and jsonEncode(d) or nil
  local back = assert(B.deserialize(d))
  assert(#back.points == 3 and back.points[3].name == BROUMOV.name and back.mode == 'express' and back.ref == '310')
  assert(back.name == 'Náchod — Broumov' and back.colour == '#cc3300' and back.off['77'] and back.path == nil)
  assert(B.deserialize({ format = 99, points = d.points }) == nil)
  assert(B.deserialize({ format = 1, points = { { lat = 1, lon = 2 } } }) == nil, 'one station is no route')
  assert(B.deserialize({ format = 1, points = { { lat = 1, lon = 2 }, { lat = 'x', lon = 3 } } }) == nil)
  assert(B.deserialize({ format = 1, points = { { lat = 1, lon = 2 }, { lat = 99, lon = 3 } } }) == nil)
  assert(B.deserialize('nonsense') == nil)
end

function T.continue_an_osm_route()
  local r = assert(osm.parseRoute(H.fixture('route_6964117')))
  local s = B.fromRoute(r)
  assert(#s.points == #r.stops and s.mode == 'express' and s.ref == '305')
  assert(s.points[1].name == r.stops[1].name)
  assert(B.add(s, { name = 'Broumov', lat = 50.5855, lon = 16.332 }))
  -- more stops than the limit: evenly chosen, first and last kept, room left for the new ones
  local big = { stops = {}, ref = 'X' }
  for i = 1, 60 do big.stops[i] = { name = 'S' .. i, lat = 50 + i * 0.001, lon = 16 } end
  local b = B.fromRoute(big)
  assert(#b.points == B.MAX_POINTS - 1 and b.mode == 'all' and b.points[1].name == 'S1' and b.points[#b.points].name == 'S60')
end

return T
