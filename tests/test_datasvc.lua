-- The client of the data service: several requests at once, so a slow one (Overpass taking minutes) does not hold up the rest.
local H = dofile('tests/harness.lua')
local T = {}

-- a fake http module: each request waits until the test answers it
local function setup()
  H.reset()
  local reqs = {}
  local fake = {
    start = function(o) local r = { state = 'pending', path = o.path, parser = {} } reqs[#reqs + 1] = r return r end,
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

return T
