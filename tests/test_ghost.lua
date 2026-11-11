-- ghost.lua (record, delta coding, place at a time, time difference at a place) and ghostrun.lua (wired to a trip, file I/O stubbed)
local H = dofile('tests/harness.lua')
local ghost = require('earthBusRoutes/ghost')
local T = {}

local function route(over)
  local r = {
    ref = '363', network = 'IDS', from = 'Praha', to = 'Hradec Králové', length = 20000,
    path = { { lat = 50.0, lon = 16.0 }, { lat = 50.0, lon = 16.3 } },
    stops = { { name = 'Praha, Florenc', along = 0 }, { name = 'Poděbrady', along = 10000 }, { name = 'Hradec', along = 20000 } },
  }
  r.cum = { 0, 20000 }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

-- a bus that stands for `wait` seconds, then drives `speed` m/s for `secs` seconds; fed every `step` seconds
local function drive(rec, o)
  local along, t = o.from or 0, o.t0 or 0
  local step = o.step or 0.1
  for _ = 1, math.floor((o.wait or 0) / step) do ghost.sample(rec, t, along) t = t + step end
  for _ = 1, math.floor(o.secs / step + 0.5) do
    along = along + o.speed * step
    t = t + step
    ghost.sample(rec, t, along)
  end
  return along, t
end

local function record(speed, secs, over)
  local rec = ghost.newRecorder(0)
  drive(rec, { speed = speed, secs = secs, wait = (over or {}).wait, t0 = (over or {}).t0 })
  local meta = { route = route(), startIndex = 1, points = (over or {}).points or 800, grade = 'B', finished = true }
  return ghost.finish(rec, meta), rec
end

function T.the_key_is_a_safe_file_name_that_tells_line_direction_and_first_stop_apart()
  local r = route()
  local k1 = ghost.key(r, 1)
  assert(k1:match('^[%w%-]+$'), 'file-name safe: ' .. k1)
  assert(k1 == ghost.key(route(), 1), 'stable')
  assert(k1 ~= ghost.key(r, 2), 'another first stop')
  assert(k1 ~= ghost.key(route({ from = 'Hradec Králové', to = 'Praha' }), 1), 'the other direction')
  assert(k1 ~= ghost.key(route({ ref = '364' }), 1), 'another line')
  assert(ghost.key(route({ ref = 'Ž 1/Á' }), 1):match('^[%w%-]+$'), 'odd characters')
  assert(ghost.key(route({ ref = '' }), 1):match('^line%-'), 'no number')
end

function T.time_counts_from_the_departure_not_from_the_start_of_the_trip()
  local a, ra = record(10, 100, { wait = 0 })
  local b, rb = record(10, 100, { wait = 45, t0 = 1000 })
  assert(a and b)
  assert(a.dur == b.dur, 'the wait at the first stop is not in the record: ' .. a.dur .. ' vs ' .. b.dur)
  assert(math.abs(a.dur - 100) <= 1)
  assert(ghost.elapsedOf(ghost.newRecorder(0), 5) == nil, 'before the departure there is no time')
  assert(math.abs(ghost.elapsedOf(rb, 1000 + 45 + 10) - 9.5) < 0.21, 'counted from the first metres: ' .. ghost.elapsedOf(rb, 1055))
end

function T.the_record_goes_to_json_and_back_with_the_same_places()
  local enc = record(12, 300)
  assert(enc.v == 1 and enc.dt == 1 and enc.finished == true and enc.points == 800 and enc.ref == '363')
  assert(#enc.d == 301 or #enc.d == 300, 'one sample a second: ' .. #enc.d)
  assert(enc.d[1] == 0)
  for i = 2, #enc.d do assert(enc.d[i] == 12 or enc.d[i] == 11 or enc.d[i] == 13, 'a delta, not a place: ' .. enc.d[i]) end
  local g = assert(ghost.decode(enc))
  assert(#g.a == #enc.d and g.points == 800 and g.grade == 'B' and g.finished and g.ref == '363' and g.key == enc.key)
  local again = assert(ghost.decode(ghost.encode(g)))
  assert(#again.a == #g.a)
  for i = 1, #g.a do assert(again.a[i] == g.a[i]) end
  -- the place after 100 s of 12 m/s, give or take the whole-metre rounding
  assert(math.abs(g.a[101] - g.a[1] - 1200) <= 2, 'place at 100 s: ' .. g.a[101])
  assert(math.abs(g.a[#g.a] - g.a[1] - 3588) <= 15)
end

function T.an_hour_of_trip_is_about_ten_kilobytes()
  local rec = ghost.newRecorder(0)
  -- a city bus: stops often, moves 6..15 m/s
  local along, t = 0, 0
  for s = 1, 3600 * 10 do
    local v = (s % 600 < 40) and 0 or (6 + (s % 90) / 10)
    along = along + v * 0.1
    t = t + 0.1
    ghost.sample(rec, t, along)
  end
  local enc = ghost.finish(rec, { route = route({ length = 99999 }), startIndex = 1, points = 500, finished = true })
  assert(#enc.d >= 3590)
  local bytes = #table.concat(enc.d, ',') + 2
  assert(bytes < 14000, 'bytes of the deltas: ' .. bytes)
  -- the delta list is the whole size: no absolute places
  assert(enc.d[2] < 100)
end

function T.a_trip_is_not_recorded_beyond_the_limit_and_slow_frames_leave_no_holes()
  local rec = ghost.newRecorder(0)
  -- 3 s frames: the places still come once a second, on the straight line between the feeds
  drive(rec, { speed = 10, secs = 300, step = 3 })
  local enc = ghost.finish(rec, { route = route(), startIndex = 1, points = 1, finished = true })
  assert(#enc.d >= 296 and #enc.d <= 301, #enc.d)
  local g = assert(ghost.decode(enc))
  for i = 2, #g.a do assert(math.abs(g.a[i] - g.a[i - 1] - 10) <= 1.01, 'no hole at ' .. i) end
  -- the cap
  local small = ghost.newRecorder(0)
  local saved = ghost.MAX_SAMPLES
  ghost.MAX_SAMPLES = 50
  drive(small, { speed = 10, secs = 200, step = 1 })
  ghost.MAX_SAMPLES = saved
  assert(#small.a == 50 and small.full)
end

function T.a_trip_too_short_to_race_is_not_kept()
  local rec = ghost.newRecorder(0)
  drive(rec, { speed = 10, secs = 20 })
  assert(ghost.finish(rec, { route = route(), startIndex = 1, finished = true }) == nil, 'under a minute')
  local still = ghost.newRecorder(0)
  for t = 1, 200 do ghost.sample(still, t, 0) end
  assert(ghost.finish(still, { route = route(), startIndex = 1, finished = true }) == nil, 'never left')
  local slow = ghost.newRecorder(0)
  drive(slow, { speed = 1, secs = 100 })
  assert(ghost.finish(slow, { route = route(), startIndex = 1, finished = true }) == nil, 'under 200 m')
end

function T.the_ghost_is_at_the_place_the_record_says_at_time_t()
  local g = assert(ghost.decode((record(10, 200))))
  assert(math.abs(ghost.alongAt(g, 0) - g.a[1]) < 1e-9)
  assert(math.abs(ghost.alongAt(g, 50) - (g.a[1] + 500)) <= 2)
  assert(math.abs(ghost.alongAt(g, 50.5) - (g.a[1] + 505)) <= 2.5, 'between two samples: a straight line')
  assert(ghost.alongAt(g, -5) == g.a[1], 'before the departure it stands')
  assert(ghost.alongAt(g, 9999) == g.a[#g.a], 'after the end it stands at the end')
  assert(ghost.alongAt(g, 100) > ghost.alongAt(g, 99))
end

function T.the_time_difference_at_the_same_place()
  local g = assert(ghost.decode((record(10, 200))))     -- 10 m/s
  -- the player is at 800 m after 100 s (8 m/s): the ghost was there after 80 s: 20 s behind
  local d = ghost.delta(g, 100, g.a[1] + 800)
  assert(math.abs(d - 20) < 0.7, 'behind: ' .. tostring(d))
  -- 500 m after 40 s (12.5 m/s): the ghost needed 50 s: 10 s ahead
  d = ghost.delta(g, 40, g.a[1] + 500)
  assert(math.abs(d + 10) < 0.7, 'ahead: ' .. tostring(d))
  assert(ghost.delta(g, 5, g.a[1] - 3) == nil, 'not yet at the ghost start')
  assert(ghost.delta(g, 500, g.a[#g.a] + 100) == nil, 'farther than the ghost went')
  assert(ghost.timeAt(g, g.a[1] + 1000) > ghost.timeAt(g, g.a[1] + 100))
  assert(ghost.deltaText(12) == '+0:12' and ghost.deltaText(-7) == '\226\136\146' .. '0:07', 'a real minus sign')
  assert(ghost.deltaText(75) == '+1:15' and ghost.deltaText(nil) == '')
end

function T.a_ghost_that_stood_still_or_went_back_gives_the_first_time_at_a_place()
  local enc = { v = 1, dt = 1, a0 = 0, d = { 0, 10, 10, 0, 0, -5, 10, 10, 10 }, finished = true, points = 1 }
  local g = assert(ghost.decode(enc))
  -- places 0 10 20 20 20 15 25 35 45
  assert(math.abs(ghost.timeAt(g, 20) - 2) < 1e-9, 'the first time it was at 20 m: ' .. ghost.timeAt(g, 20))
  assert(math.abs(ghost.timeAt(g, 22.5) - 5.5) < 1e-9, tostring(ghost.timeAt(g, 22.5)))
  assert(ghost.timeAt(g, 46) == nil)
end

function T.only_a_finished_trip_with_more_points_replaces_the_ghost()
  local old = { finished = true, points = 800, dur = 500 }
  assert(ghost.better(nil, { finished = true, points = 10 }), 'the first record always stays')
  assert(not ghost.better(old, { finished = false, points = 999 }), 'not finished')
  assert(not ghost.better(old, { finished = true, points = 800, dur = 600 }), 'the same points, slower')
  assert(ghost.better(old, { finished = true, points = 800, dur = 450 }), 'the same points, faster')
  assert(ghost.better(old, { finished = true, points = 801, dur = 900 }))
  assert(not ghost.better(old, { finished = true, points = 700, dur = 100 }))
  assert(ghost.better({ finished = false, points = 900 }, { finished = true, points = 1 }), 'an unfinished record yields')
  assert(not ghost.better(old, nil))
end

function T.a_damaged_record_is_refused_not_a_crash()
  assert(ghost.decode(nil) == nil)
  assert(ghost.decode('x') == nil)
  assert(ghost.decode({ v = 2 }) == nil)
  assert(ghost.decode({ v = 1, dt = 1, a0 = 0, d = { 0, 'x' } }) == nil)
  assert(ghost.decode({ v = 1, dt = 0, a0 = 0, d = { 0, 1 } }) == nil)
  assert(ghost.decode({ v = 1, dt = 1, a0 = 0, d = { 0 } }) == nil, 'one sample is no record')
  assert(ghost.decode({ v = 1, dt = 1, a0 = 0 }) == nil)
end

-- ---- ghostrun: the ghost of the running trip --------------------------------------------------------------------------

local function stubFiles(initial)
  H.reset()
  local files, writes = initial or {}, {}
  _G.jsonReadFile = function(p) local f = files[p] if f == nil then error('no file') end return f end
  _G.jsonWriteFile = function(p, data, pretty) files[p] = data writes[#writes + 1] = { p = p, data = data, pretty = pretty } return true end
  _G.FS = nil
  package.loaded['earthBusRoutes/ghostrun'] = nil
  package.loaded['earthBusRoutes/world'] = nil
  return files, writes, require('earthBusRoutes/ghostrun')
end

-- a trip state as trip.lua keeps it (only what ghostrun reads)
local function fakeTrip(r) return { route = r or route(), startIndex = 1, along = 0, off = 0, elapsed = 0 } end

local function runTrip(gr, t, speed, secs, wait)
  for _ = 1, math.floor((wait or 0) * 10) do t.elapsed = t.elapsed + 0.1 gr.update(t) end
  for _ = 1, math.floor(secs * 10 + 0.5) do
    t.elapsed = t.elapsed + 0.1
    t.along = t.along + speed * 0.1
    gr.update(t)
  end
end

local function pathOf(gr, t) return gr.DIR .. ghost.key(t.route, t.startIndex) .. '.json' end

function T.the_first_trip_leaves_a_record_and_the_second_races_it()
  local files, writes, gr = stubFiles()
  local t1 = fakeTrip()
  gr.begin(t1, {})
  assert(gr.hud({}) == nil, 'no ghost yet')
  runTrip(gr, t1, 10, 200, 30)
  assert(gr.finish(t1, { points = 700, grade = 'C' }) == true)
  assert(#writes == 1 and writes[1].p == pathOf(gr, t1) and writes[1].p:find('^/settings/earthBusRoutes/ghosts/') and writes[1].pretty == false)
  assert(writes[1].data.points == 700 and writes[1].data.finished)
  -- the second trip, slower
  local t2 = fakeTrip()
  gr.begin(t2, {})
  local h = gr.hud({})
  assert(h and h.points == 700 and h.delta == nil, 'a ghost, waiting for the departure')
  runTrip(gr, t2, 8, 100, 50)
  h = gr.hud({})
  assert(h and h.delta and h.delta > 15 and h.delta < 25, 'behind: ' .. tostring(h and h.delta))
  assert(h.text:sub(1, 1) == '+', h.text)
  assert(gr.state().gAlong and gr.state().gAlong > 900, 'the ghost is drawn ahead of the bus')
end

function T.a_worse_trip_keeps_the_old_ghost_and_a_better_one_replaces_it()
  local files, writes, gr = stubFiles()
  local function trip(points, speed, secs)
    local t = fakeTrip()
    gr.begin(t, {})
    runTrip(gr, t, speed, secs or 200, 10)
    return gr.finish(t, { points = points, grade = 'B' })
  end
  assert(trip(700, 10) == true)
  assert(trip(600, 12) == false, 'fewer points')
  assert(#writes == 1)
  assert(trip(900, 9) == true, 'more points')
  assert(#writes == 2 and writes[2].data.points == 900)
  assert(trip(900, 15, 100) == true and #writes == 3, 'the same points, but faster')
  assert(trip(900, 8, 300) == false and #writes == 3, 'the same points, slower')
end

function T.a_cancelled_trip_leaves_nothing()
  local _, writes, gr = stubFiles()
  local t = fakeTrip()
  gr.begin(t, {})
  runTrip(gr, t, 10, 200)
  gr.cancel()
  assert(gr.finish(t, { points = 1000 }) == false and #writes == 0)
  assert(gr.state() == nil)
end

function T.the_switch_turns_the_ghost_off_without_any_file_access()
  local files, writes, gr = stubFiles()
  local t = fakeTrip()
  gr.begin(t, { ghost = 'off' })
  assert(gr.state() == nil)
  runTrip(gr, t, 10, 200)
  assert(gr.hud({ ghost = 'off' }) == nil and gr.finish(t, { points = 500 }) == false and #writes == 0)
  assert(gr.enabled({}) and gr.enabled(nil) and gr.enabled({ ghost = 'on' }) and not gr.enabled({ ghost = 'off' }))
  -- switched off in the middle of a trip: nothing shown
  local f2, w2, gr2 = stubFiles()
  local t1 = fakeTrip()
  gr2.begin(t1, {})
  runTrip(gr2, t1, 10, 200)
  gr2.finish(t1, { points = 500 })
  local t2 = fakeTrip()
  gr2.begin(t2, {})
  runTrip(gr2, t2, 10, 50, 1)
  assert(gr2.hud({}) ~= nil and gr2.hud({ ghost = 'off' }) == nil)
end

function T.a_record_of_another_road_or_a_broken_file_is_not_used()
  local _, w0, g0 = stubFiles()
  local t0 = fakeTrip()
  g0.begin(t0, {})
  runTrip(g0, t0, 10, 200)
  g0.finish(t0, { points = 5 })
  local enc = w0[1].data
  -- the route was changed in the data: another length, the same file name
  local files, _, gr = stubFiles()
  local longer = fakeTrip(route({ length = 26000 }))
  files[pathOf(gr, longer)] = enc
  gr.begin(longer, {})
  assert(gr.hud({}) == nil, 'another length: not the same road')
  -- a broken file
  local f3, _, gr3 = stubFiles()
  f3[pathOf(gr3, fakeTrip())] = { v = 1, d = 'garbage' }
  local t3 = fakeTrip()
  gr3.begin(t3, {})
  assert(gr3.hud({}) == nil and gr3.state() ~= nil, 'still recording')
  H.logs = {}
end

function T.a_failing_update_turns_the_ghost_off_not_the_trip()
  local _, _, gr = stubFiles()
  local t = fakeTrip()
  gr.begin(t, {})
  runTrip(gr, t, 10, 20)
  t.elapsed = 'boom'
  gr.update(t)                            -- must not raise
  assert(gr.state() == nil)
  assert(gr.finish(t, { points = 1 }) == false)
  assert(gr.hud({}) == nil)
  assert(#H.logs >= 1 and H.logs[#H.logs]:find('ghost: off'))
end

function T.drawing_asks_the_world_for_a_bus_sized_rectangle_around_the_ghost()
  local files, _, gr = stubFiles()
  local t1 = fakeTrip()
  gr.begin(t1, {})
  runTrip(gr, t1, 10, 200, 5)
  gr.finish(t1, { points = 700 })
  local drawn
  package.loaded['earthBusRoutes/world'].drawGhost = function(spec, z) drawn = { spec = spec, z = z } end
  local t2 = fakeTrip()
  gr.begin(t2, {})
  gr.draw(t2, {})
  assert(drawn == nil, 'nothing before the bus has left')
  runTrip(gr, t2, 5, 40)
  gr.draw(t2, {})
  assert(drawn and drawn.spec.width and drawn.spec.width > 2)
  assert(drawn.spec.front.lon > drawn.spec.back.lon, 'the route runs east: the front is east of the back')
  drawn = nil
  gr.draw(t2, { ghost = 'off' })
  assert(drawn == nil)
  -- long after the ghost has finished it is not drawn any more
  runTrip(gr, t2, 5, 400)
  gr.draw(t2, {})
  assert(drawn == nil)
end

return T
