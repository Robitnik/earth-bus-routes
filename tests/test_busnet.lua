-- The virtual bus network (plan 007, T1): positions along the route at any clock time, dwell, delays, physical buses, boards.
local H = dofile('tests/harness.lua')
local T = {}

local function lib()
  H.reset()
  for _, n in ipairs({ 'geomath', 'schedule', 'busnet' }) do package.loaded['earthBusRoutes/' .. n] = nil end
  return require('earthBusRoutes/busnet'), require('earthBusRoutes/geomath'), require('earthBusRoutes/schedule')
end

-- A straight road north from (50, 16); stops at the given metres. Lat degree = 111195 m (the module's earth radius).
local function route(geo, id, ref, alongs, extra)
  local path = {}
  local M_PER_DEG = geo.dist(50, 16, 51, 16)
  local total = alongs[#alongs] + 500
  for k = 0, 20 do path[#path + 1] = { lat = 50 + (total * k / 20) / M_PER_DEG, lon = 16 } end
  local cum, length = geo.cumulative(path)
  local stops = {}
  for i, a in ipairs(alongs) do
    stops[i] = { id = i, name = 'Stop ' .. i, lat = 50 + a / M_PER_DEG, lon = 16, along = a, index = i }
  end
  local r = { id = id, ref = ref, colour = '#336699', from = stops[1].name, to = stops[#stops].name, stops = stops, path = path, cum = cum,
    length = length, kind = 'city', tags = {} }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

-- one trip by hand: leaves at 1000 s, stands 20 s at the first stop, 100 s between stops, 30 s at the middle ones
local function simple(busnet, geo)
  local net = busnet.new({ day = 1 })
  local r = route(geo, 11, '360', { 0, 1000, 2000, 3000 })
  local trip = { start = 1000, arr = { 0, 120, 250, 380 }, dep = { 20, 150, 280, 380 } }
  assert(busnet.addLine(net, r, { trips = { trip }, clock = 900 }) == 1)
  return net, r
end

function T.states_along_one_trip()
  local busnet, geo = lib()
  local net, r = simple(busnet, geo)
  local trip = net.lines[11].trips[1]
  local p = busnet.posOf(trip, 990)
  assert(p.state == 'wait' and p.along == 0 and p.nextIndex == 1 and math.abs(p.leaveIn - 30) < 1e-9, 'not started')
  p = busnet.posOf(trip, 1010)
  assert(p.state == 'stop' and p.index == 1 and math.abs(p.leaveIn - 10) < 1e-9 and p.nextIndex == 2, 'standing at the first stop')
  p = busnet.posOf(trip, 1020 + 65)                            -- half of the 130 s leg 1 -> 2 (dep 20, arr 120 => 100 s)
  assert(p.state == 'run' and p.index == 1 and p.nextIndex == 2, p.state)
  assert(math.abs(p.along - 650) < 1, 'leg 1: 85 of 100 s = 850 m? ' .. p.along)
  p = busnet.posOf(trip, 1000 + 135)
  assert(p.state == 'stop' and p.index == 2 and p.along == 1000, 'standing at the middle stop')
  p = busnet.posOf(trip, 1000 + 380)
  assert(p.state == 'done' and p.along == 3000 and p.nextIndex == nil, 'ended')
  local lat, lon = busnet.pointAt(r, 1000)
  assert(math.abs(geo.dist(lat, lon, r.stops[2].lat, r.stops[2].lon)) < 1, 'pointAt matches the stop')
end

function T.position_is_monotone_and_on_the_road()
  local busnet, geo = lib()
  local net, r = simple(busnet, geo)
  local trip = net.lines[11].trips[1]
  local last = -1
  for c = 1000, 1400, 5 do
    local p = busnet.posOf(trip, c)
    assert(p.along >= last - 1e-9, 'went back at ' .. c)
    last = p.along
    assert(math.abs(p.lon - 16) < 1e-9 and p.lat >= 50, 'on the road')
    assert(p.heading < 1 or p.heading > 359, 'heading north ' .. p.heading)
  end
  assert(last == 3000)
end

function T.timetable_times_get_a_dwell_before_the_departure()
  local busnet, geo = lib()
  local net = busnet.new()
  local r = route(geo, 12, 'X1', { 0, 1000, 2000, 3000 })
  -- a feed gives one time per stop: offs
  assert(busnet.addLine(net, r, { trips = { { start = 5000, offs = { 0, 120, 240, 360 } } }, clock = 4900 }) == 1)
  local t = net.lines[12].trips[1]
  assert(t.arr[2] == 100 and t.dep[2] == 120, 'stands 20 s before the departure time')
  assert(t.arr[1] == 0 and t.arr[4] == 360 and t.dep[4] == 360, 'ends are untouched')
  local p = busnet.posOf(t, 5000 + 110)
  assert(p.state == 'stop' and p.index == 2)
end

function T.offs_of_another_pattern_are_fitted_to_the_stops()
  local busnet, geo = lib()
  local r = route(geo, 13, 'X2', { 0, 1000, 3000 })
  local o = busnet.fitOffs(r, { 100, 150, 180, 220, 300 })            -- five stops of the feed, three of our road
  assert(#o == 3 and o[1] == 0 and o[3] == 200 and math.abs(o[2] - 200 / 3) < 1e-6, 'shared by distance')
  local same = busnet.fitOffs(r, { 60, 90, 120 })
  assert(same[1] == 0 and same[2] == 30 and same[3] == 60, 'same count: rebased')
end

function T.generated_lines_have_trips_and_a_live_set()
  local busnet, geo = lib()
  local net = busnet.new({ day = 2 })
  local r = route(geo, 21, '5', { 0, 800, 1600, 2400, 3200 })
  local n = busnet.addLine(net, r, { clock = 8 * 3600 })
  assert(n > 5, 'trips of the window: ' .. n)
  local live = busnet.update(net, 8 * 3600)
  assert(#live > 0)
  for _, b in ipairs(live) do
    assert(b.start <= 8 * 3600 + 1800 and b.start + 3600 >= 8 * 3600 - 60, 'live trips only: ' .. b.start)
    assert(b.ref == '5' and b.head == 'Stop 5' and b.colour == '#336699')
  end
  for i = 2, #live do assert(live[i].start >= live[i - 1].start, 'by start') end
  -- the same input, the same output
  local net2 = busnet.new({ day = 2 })
  busnet.addLine(net2, r, { clock = 8 * 3600 })
  local live2 = busnet.update(net2, 8 * 3600)
  assert(#live2 == #live)
  for i = 1, #live do assert(live[i].key == live2[i].key and live[i].lat == live2[i].lat and live[i].state == live2[i].state) end
end

function T.the_live_window_is_thirty_minutes_ahead()
  local busnet, geo = lib()
  local net = busnet.new()
  local r = route(geo, 22, '7', { 0, 1000, 2000 })
  local trips = {
    { start = 1000, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } },       -- ended long ago at clock 5000
    { start = 4900, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } },
    { start = 6000, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } },       -- 1000 s ahead: live (waiting)
    { start = 7000, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } },       -- 2000 s ahead: not yet
  }
  busnet.addLine(net, r, { trips = trips, clock = 5000 })
  local live = busnet.update(net, 5000)
  assert(#live == 2 and live[1].start == 4900 and live[2].start == 6000 and live[2].state == 'wait', #live)
  -- a trip that has just ended stays for the grace time
  live = busnet.update(net, 4900 + 200 + 30)
  assert(live[1].start == 4900 and live[1].state == 'done')
  live = busnet.update(net, 4900 + 200 + 61)
  assert(live[1].start ~= 4900, 'gone after the grace time')
end

function T.trips_run_past_midnight()
  local busnet, geo = lib()
  local r = route(geo, 23, 'N1', { 0, 2000, 4000 })
  -- a real timetable: Monday (1) has a trip at 23:50 and one at 00:10 (= 24:10 of Sunday's service day is not in Monday's list)
  r.gtfsOffs = { 0, 600, 1200 }
  r.gtfsStarts = { ['1'] = { 600, 85800 }, ['2'] = { 600 }, ['7'] = { 86400 + 300 } }     -- Sunday's 00:05 next day
  local net = busnet.new({ day = 1 })
  busnet.addLine(net, r, { clock = 120, day = 1 })                            -- Monday 00:02: Sunday's 24:05 run is on
  local live = busnet.update(net, 360)
  local found
  for _, b in ipairs(live) do if b.start == 300 then found = b end end
  assert(found and (found.state == 'run' or found.state == 'stop' or found.state == 'wait'), 'yesterday\'s late trip runs after midnight')
  -- Monday 23:55: tomorrow's 00:10 (start 600 + 86400) is not live yet, today's 23:50 is
  local net2 = busnet.new({ day = 1 })
  busnet.addLine(net2, r, { clock = 86100, day = 1 })
  live = busnet.update(net2, 86100)
  local starts = {}
  for _, b in ipairs(live) do starts[#starts + 1] = b.start end
  assert(starts[1] == 85800, 'the 23:50 trip is on')
  local function sees(clock)
    for _, b in ipairs(busnet.update(net2, clock)) do if b.start == 86400 + 600 then return b end end
  end
  assert(not sees(86400 - 1500), 'tomorrow 00:10 is 2100 s away: not live')
  local b = sees(86400 - 100)
  assert(b and b.state == 'wait', 'the early trip of tomorrow waits at its first stop, 700 s ahead')
end

function T.a_measured_delay_moves_the_bus()
  local busnet, geo = lib()
  local net, r = simple(busnet, geo)
  local key = net.lines[11].trips[1].key
  busnet.update(net, 1085)
  local before = net.live[1]
  assert(before.state == 'run')
  assert(busnet.setDelay(net, key, 60))
  busnet.update(net, 1085)
  local after = net.live[1]
  assert(after.delay == 60 and after.along < before.along, 'late = further back')
  -- an arrival measured at stop 2: 130 s after the start, the timetable said 120 => 10 s late
  assert(busnet.reportArrival(net, key, 2, 1000 + 130) == 10)
  assert(net.byKey[key].delay == 10)
  assert(busnet.reportArrival(net, 'nope', 2, 1) == nil and busnet.setDelay(net, 'nope', 1) == false)
  -- early (negative delay)
  busnet.reportArrival(net, key, 2, 1000 + 100)
  assert(net.byKey[key].delay == -20)
end

function T.a_physical_bus_is_not_drawn_twice()
  local busnet, geo = lib()
  local net, r = simple(busnet, geo)
  local key = net.lines[11].trips[1].key
  busnet.update(net, 1085)
  assert(#busnet.buses(net) == 1)
  assert(busnet.setPhysical(net, key, true))
  assert(#busnet.buses(net) == 0, 'taken over')
  assert(#busnet.buses(net, { includePhysical = true }) == 1)
  assert(net.live[1].physical == true)
  busnet.update(net, 1090)
  assert(net.live[1].physical == true, 'the flag stays')
  busnet.setPhysical(net, key, false)
  assert(#busnet.buses(net) == 1, 'given back')
end

function T.buses_to_draw_are_filtered_by_distance_and_state()
  local busnet, geo = lib()
  local net = busnet.new()
  local near = route(geo, 31, 'A', { 0, 1000, 2000 })
  local far = route(geo, 32, 'B', { 0, 1000, 2000 })
  for _, p in ipairs(far.path) do p.lon = 16.5 end
  for _, s in ipairs(far.stops) do s.lon = 16.5 end
  local trips = { { start = 100, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } }, { start = 1500, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } } }
  busnet.addLine(net, near, { trips = trips, clock = 150 })
  busnet.addLine(net, far, { trips = trips, clock = 150 })
  busnet.update(net, 150)
  assert(#net.live == 4)
  local all = busnet.buses(net)
  assert(#all == 2, 'the two that run; the ones 1350 s away are not drawn: ' .. #all)
  local here = busnet.buses(net, { center = { lat = 50.005, lon = 16 }, r = 3000 })
  assert(#here == 1 and here[1].ref == 'A')
  busnet.update(net, 1450)                                   -- 50 s before the second trip leaves
  assert(#busnet.buses(net, { center = { lat = 50.005, lon = 16 }, r = 3000 }) == 1 and busnet.buses(net, { center = { lat = 50.005, lon = 16 }, r = 3000 })[1].state == 'wait')
  assert(#busnet.buses(net, { waitS = 10, center = { lat = 50.005, lon = 16 }, r = 3000 }) == 0)
end

function T.a_board_lists_the_next_departures_of_a_station()
  local busnet, geo = lib()
  local net = busnet.new()
  local a = route(geo, 41, '10', { 0, 1000, 2000, 3000 })
  local b = route(geo, 42, '20', { 500, 1000, 1500 })             -- also calls at the stop 1000 m up the road
  local ta, tb = {}, {}
  for k = 0, 5 do
    ta[#ta + 1] = { start = 1000 + k * 600, arr = { 0, 120, 250, 380 }, dep = { 20, 150, 280, 380 } }
    tb[#tb + 1] = { start = 1300 + k * 900, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } }
  end
  busnet.addLine(net, a, { trips = ta, clock = 1000 })
  busnet.addLine(net, b, { trips = tb, clock = 1000 })
  busnet.update(net, 1000)
  local spec = { lat = a.stops[2].lat, lon = 16, name = 'Stop 2' }
  local rows = busnet.board(net, spec, 1000, 4)
  assert(#rows == 4)
  assert(rows[1].ref == '10' and rows[1].at == 1150 and rows[1].inS == 150, 'first: ' .. rows[1].ref .. ' ' .. rows[1].at)
  assert(rows[2].ref == '20' and rows[2].at == 1410, 'second: ' .. rows[2].ref .. ' ' .. rows[2].at)
  for i = 2, #rows do assert(rows[i].eta >= rows[i - 1].eta, 'by time') end
  assert(rows[1].state == 'sched' or rows[1].state == 'run')
  -- a delay shows in the expected time, not in the scheduled one
  busnet.setDelay(net, rows[1].key, 90)
  rows = busnet.board(net, spec, 1000, 4)
  assert(rows[1].ref == '10' and rows[1].eta == 1240 and rows[1].at == 1150 and rows[1].delay == 90)
  -- the bus is standing at the stop
  rows = busnet.board(net, spec, 1000 + 140 + 90, 3)
  assert(rows[1].ref == '10' and rows[1].state == 'stop', rows[1].state)
  -- the terminus has no departures
  local last = { lat = a.stops[4].lat, lon = 16, name = 'Stop 4' }
  local rowsLast = busnet.board(net, last, 1000, 5)
  for _, row in ipairs(rowsLast) do assert(row.ref ~= '10', 'line 10 ends there') end
  -- another station name nowhere near
  assert(#busnet.board(net, { lat = 52, lon = 16, name = 'Nowhere' }, 1000, 5) == 0)
end

function T.a_station_with_platforms_matches_by_any_platform()
  local busnet, geo = lib()
  local net = busnet.new()
  local a = route(geo, 51, '30', { 0, 1000, 2000 })
  busnet.addLine(net, a, { trips = { { start = 100, arr = { 0, 100, 200 }, dep = { 10, 110, 200 } } }, clock = 0 })
  local second = geo.pointAt and a.stops[2]
  local spec = { lat = 50.5, lon = 16.5, name = 'Elsewhere', pts = { { lat = 50.5, lon = 16.5 }, { lat = second.lat, lon = second.lon + 0.0003 } } }
  assert(#busnet.board(net, spec, 0, 3) == 1, 'a platform 21 m off')
  spec.pts = { { lat = 50.5, lon = 16.5 } }
  assert(#busnet.board(net, spec, 0, 3) == 0)
  -- same name within 350 m counts, 120 m rule otherwise
  local byName = { lat = second.lat + 0.002, lon = 16, name = 'Stop 2' }      -- 222 m up the road
  assert(#busnet.board(net, byName, 0, 3) == 1)
  assert(#busnet.board(net, { lat = second.lat + 0.002, lon = 16, name = 'Other' }, 0, 3) == 0)
end

function T.lines_can_be_replaced_and_removed()
  local busnet, geo = lib()
  local net, r = simple(busnet, geo)
  assert(busnet.hasLine(net, 11))
  assert(busnet.stats(net).trips == 1)
  busnet.addLine(net, r, { trips = { { start = 2000, arr = { 0, 120, 250, 380 }, dep = { 20, 150, 280, 380 } } }, clock = 1900 })
  assert(busnet.stats(net).trips == 1 and net.byKey['11@2000'] and not net.byKey['11@1000'], 'replaced, not doubled')
  busnet.removeLine(net, 11)
  assert(not busnet.hasLine(net, 11) and #busnet.update(net, 2000) == 0)
  assert(busnet.addLine(net, { id = 1, stops = {}, path = {} }, {}) == 0, 'a route without a road is not placed')
  busnet.clear(net)
  assert(busnet.stats(net).lines == 0)
end

function T.a_big_net_updates_quickly()
  local busnet, geo = lib()
  local net = busnet.new({ day = 3 })
  for i = 1, 40 do
    local r = route(geo, 100 + i, tostring(i), { 0, 500, 1000, 2000, 3000, 4000, 5000, 6000 })
    busnet.addLine(net, r, { clock = 9 * 3600, ctx = { busy = i % 2 == 0 } })
  end
  local t0 = os.clock()
  for c = 9 * 3600, 9 * 3600 + 600, 5 do busnet.update(net, c) end
  local dt = os.clock() - t0
  assert(#net.live > 40, 'live: ' .. #net.live)
  assert(dt < 3, 'update too slow: ' .. dt)
end

return T
