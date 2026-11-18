-- The client of the data service: several requests at once, so a slow one (Overpass taking minutes) does not hold up the rest.
local H = dofile('tests/harness.lua')
local T = {}

-- a fake http module: each request waits until the test answers it
local function setup()
  H.reset()
  local reqs = {}
  local fake = {
    start = function(o) local r = { state = 'pending', path = o.path, parser = {}, o = o } reqs[#reqs + 1] = r return r end,
    step = function() end,
    body = function(p) return p.text end,
    cancel = function(r) r.state = 'cancelled' end,
    urlencode = function(s) return s end,
  }
  package.loaded['earthBusRoutes/http'] = fake
  local ds = H.load('mod/lua/ge/extensions/earthBusRoutes/datasvc.lua')
  local function answer(path, data)
    for _, r in ipairs(reqs) do
      if r.path == path and r.state == 'pending' then
        r.state, r.parser.text = 'done', '{"ok":true,"cached":true,"data":' .. data .. '}'
        return true
      end
    end
    error('no request for ' .. path)
  end
  local function running()
    local n = 0
    for _, r in ipairs(reqs) do if r.state == 'pending' then n = n + 1 end end
    return n
  end
  return ds, answer, running, reqs
end

local function cleanup() package.loaded['earthBusRoutes/http'] = nil end

function T.a_slow_request_does_not_hold_up_the_others()
  local ds, answer, running = setup()
  local got = {}
  ds.route(7185111, function(d) got.route = d end)                 -- Overpass: minutes
  ds.towns(50.5, 16.2, function(d) got.towns = d end)              -- from the disk: at once
  ds.update(0.1)
  assert(running() == 2, 'both run at once: ' .. running())
  answer('/v1/towns?lat=50.5000&lon=16.2000', '{"towns":[{"name":"Police"}]}')
  ds.update(0.1)
  assert(got.towns and got.towns.towns[1].name == 'Police', 'the towns came while the route still waits')
  assert(got.route == nil and running() == 1)
  answer('/v1/route?id=7185111', '{"elements":[]}')
  ds.update(0.1)
  assert(got.route and not ds.busy())
  cleanup()
end

function T.at_most_three_at_once_and_the_queue_moves_on()
  local ds, answer, running = setup()
  local n = 0
  for i = 1, 5 do ds.route(i, function() n = n + 1 end) end
  ds.update(0.1)
  assert(running() == ds.LANES and ds.LANES == 3)
  answer('/v1/route?id=2', '{}')
  ds.update(0.1)
  assert(n == 1 and running() == 3, 'the fourth started when one ended')
  -- the same path asked again while it runs: one request, two answers
  local twice = 0
  ds.route(1, function() twice = twice + 1 end)
  answer('/v1/route?id=1', '{}')
  ds.update(0.1)
  assert(twice == 1 and n == 2)
  cleanup()
end

function T.an_urgent_request_takes_the_lane_of_a_prefetch()
  local ds, _, running, reqs = setup()
  for i = 1, 3 do ds.nearby(50 + i / 100, 16, function() end, 'low') end
  ds.update(0.1)
  assert(running() == 3)
  ds.towns(50.5, 16.2, function() end)
  ds.update(0.1)
  local cancelled, towns = 0, false
  for _, r in ipairs(reqs) do
    if r.state == 'cancelled' then cancelled = cancelled + 1 end
    if r.path:find('/v1/towns', 1, true) and r.state == 'pending' then towns = true end
  end
  assert(cancelled == 1 and towns, 'one prefetch gave way to the request somebody waits for')
  cleanup()
end

function T.departures_ask_the_timetables_on_the_second_lane_and_a_background_route_is_low()
  local ds, answer, running, reqs = setup()
  local got
  ds.departures(50.01234, 16.0, 25200.7, 3, 30, function(d) got = d end)
  ds.update(0.1)
  assert(#reqs == 1 and reqs[1].path == '/v1/departures?lat=50.0123&lon=16.0000&r=3000&t=25200&day=3&mins=30', reqs[1].path)
  answer(reqs[1].path, '{"patterns":[],"trips":[{"pid":1,"start":25200}]}')
  ds.update(0.1)
  assert(got and got.trips[1].start == 25200)
  -- a background route gives way to an urgent request
  for i = 1, 3 do ds.route(100 + i, function() end, true) end
  ds.update(0.1)
  assert(running() == 3)
  ds.towns(50.5, 16.2, function() end)
  ds.update(0.1)
  local cancelled = 0
  for _, r in ipairs(reqs) do if r.state == 'cancelled' then cancelled = cancelled + 1 end end
  assert(cancelled == 1, 'one background route gave way')
  cleanup()
end

-- 0.10.3: the menu closed / a trip began: what the menu waited for is dropped (its connection closed, so the service stops
-- asking the public servers for it); a route, a shift and the road of a route being built are kept
function T.drop_cancels_what_the_menu_waited_for_and_keeps_routes()
  local ds, answer, running, reqs = setup()
  local heard = {}
  ds.nearby(50.5, 16.2, function(d, info) heard.nearby = info end, 'urgent')
  ds.towns(50.5, 16.2, function(d, info) heard.towns = info end)
  ds.route(7185111, function(d, info) heard.route = d end)
  ds.stations(50.5, 16.2, function(d, info) heard.stations = info end)
  ds.update(0.1)
  assert(running() == 3, 'three lanes: the urgent ones first, the route waits')
  local n = ds.drop()
  assert(n == 3, 'nearby, towns and stations: ' .. n)
  assert(heard.nearby.cancelled and heard.towns.cancelled and heard.stations.cancelled)
  assert(heard.route == nil, 'the route goes on')
  local cancelled = 0
  for _, r in ipairs(reqs) do if r.state == 'cancelled' then cancelled = cancelled + 1 end end
  assert(cancelled == 3 and running() == 0, 'their connections closed')
  ds.update(0.1)
  assert(running() == 1, 'the route takes a lane')
  answer('/v1/route?id=7185111', '{"elements":[]}')
  ds.update(0.1)
  assert(heard.route, 'the kept route arrives')
  assert(ds.drop() == 0)
  -- a background route of the bus net is not kept
  ds.route(42, function(d, info) heard.low = info end, true)
  ds.update(0.1)
  assert(ds.drop() == 1 and heard.low.cancelled)
  -- the stops round you from this computer only: the fast lane, never dropped (it answers at once)
  ds.nearbyKept(50.5, 16.2, function(d) heard.kept = d end)
  ds.update(0.1)
  answer('/v1/nearby?lat=50.50000&lon=16.20000&cached=1', '{"elements":[]}')
  ds.update(0.1)
  assert(heard.kept)
  assert(ds.TOTAL_S <= 120, 'the mod waits no longer than the service tries')
  cleanup()
end


-- 0.12: the source of the data is the player's choice: it goes to the service as ?src=, is kept in a file, and what was answered
-- under the old choice is forgotten
function T.the_source_choice_goes_to_the_service_and_is_kept()
  local ds, answer, running, reqs = setup()
  local files = {}
  jsonWriteFile = function(path, t) files[path] = t return true end
  jsonReadFile = function(path) return files[path] end
  assert(ds.source == 'auto')
  ds.nearby(50.5, 16.2, function() end, 'urgent')
  ds.update(0.1)
  assert(reqs[#reqs].path == '/v1/nearby?lat=50.50000&lon=16.20000', 'auto asks without src: ' .. reqs[#reqs].path)
  answer('/v1/nearby?lat=50.50000&lon=16.20000', '{"elements":[]}')
  ds.update(0.1)
  local memoHit
  ds.nearby(50.5, 16.2, function(d, info) memoHit = info and info.memo end, 'urgent')
  assert(memoHit, 'the second answer comes from memory')
  assert(ds.setSource('db') == true and ds.source == 'db')
  assert(ds.setSource('db') == false, 'no change')
  assert(ds.setSource('nonsense') == false and ds.source == 'db')
  assert(files[ds.PREFS_PATH].source == 'db', 'kept in a file')
  ds.nearby(50.5, 16.2, function() end, 'urgent')
  ds.update(0.1)
  assert(reqs[#reqs].path == '/v1/nearby?lat=50.50000&lon=16.20000&src=db', 'the choice is asked for, the old memo is gone: ' .. reqs[#reqs].path)
  ds.route(7, function() end)
  ds.update(0.1)
  assert(reqs[#reqs].path == '/v1/route?id=7&src=db')
  ds.setSource('live')
  ds.routeKept(7, function() end)
  ds.update(0.1)
  assert(reqs[#reqs].path == '/v1/route?id=7&cached=1&src=live')
  answer('/v1/route?id=7&cached=1&src=live', '{"elements":[]}')           -- (the fast lane runs one at a time)
  ds.update(0.1)
  ds.nearbyKept(50.5, 16.2, function() end)
  ds.update(0.1)
  assert(reqs[#reqs].path == '/v1/nearby?lat=50.50000&lon=16.20000&cached=1&src=live')
  -- the next session reads the file
  local ds2 = setup()
  jsonReadFile = function(path) return files[path] end         -- (setup resets the globals)
  ds2.loadPrefs()
  assert(ds2.source == 'live')
  jsonWriteFile, jsonReadFile = nil, nil
  cleanup()
end

function T.post_sends_a_json_body_and_the_answer_is_not_kept_in_memory()
  local ds, answer, running, reqs = setup()
  jsonEncode = function(t) return '{"n":' .. #t.points .. '}' end
  local got
  ds.post('/v1/export', { points = { {}, {} } }, function(d) got = d end)
  ds.update(0.1)
  local r = reqs[#reqs]
  assert(r.o.method == 'POST' and r.o.body == '{"n":2}', 'POST with the body')
  assert(r.o.headers and r.o.headers['Content-Type'] == 'application/json')
  answer('/v1/export', '{"cc":"CZ","files":[]}')
  ds.update(0.1)
  assert(got and got.cc == 'CZ')
  local again
  ds.post('/v1/export', { points = { {}, {} } }, function(d) again = d end)
  ds.update(0.1)
  assert(again == nil, 'it is asked again, not answered from memory')
  cleanup()
end


-- 0.12.1: the stops round you (somebody waits) never queue behind the roads of the lines: they have a lane of their own
function T.an_urgent_request_has_a_lane_when_the_others_are_busy()
  local ds, answer, running, reqs = setup()
  ds.route(1, function() end)
  ds.route(2, function() end)
  ds.route(3, function() end)
  ds.update(0.1)
  assert(running() == 3, 'three slow roads running')
  local got
  ds.nearby(50.5, 16.2, function(d) got = d end, 'urgent')
  ds.update(0.1)
  assert(running() == 4, 'the urgent request started at once')
  answer('/v1/nearby?lat=50.50000&lon=16.20000', '{"elements":[]}')
  ds.update(0.1)
  assert(got, 'and was answered')
  -- a fourth ordinary request still waits for a free lane
  ds.route(4, function() end)
  ds.update(0.1)
  assert(running() == 3, 'the road of the 4th line waits')
  cleanup()
end

-- 0.13.1: the announcer's clip comes as bytes (a WAV), not JSON
function T.a_raw_request_gives_the_bytes_and_the_headers()
  local ds, _, _, reqs = setup()
  local got, err
  ds.get('/v1/say?kind=next&name=A', function(d, info) got, err = d, info end, { fast = true, raw = true })
  ds.update(0.1)
  local r = reqs[#reqs]
  assert(r and r.path == '/v1/say?kind=next&name=A')
  r.state, r.parser.status, r.parser.headers, r.parser.text = 'done', 200, { ['x-clip'] = 'ab12' }, 'RIFF binary'
  ds.update(0.1)
  assert(got and got.body == 'RIFF binary' and got.headers['x-clip'] == 'ab12')
  ds.get('/v1/say?kind=next&name=B', function(d, info) got, err = d, info end, { fast = true, raw = true })
  ds.update(0.1)
  r = reqs[#reqs]
  r.state, r.parser.status, r.parser.text = 'done', 409, '{"ok":false,"error":"voice missing"}'
  ds.update(0.1)
  assert(got == nil and err.error == 'voice missing', tostring(err and err.error))
  cleanup()
end

return T
