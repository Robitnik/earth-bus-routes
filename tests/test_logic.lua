local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local sched = require('earthBusRoutes/schedule')
local demand = require('earthBusRoutes/demand')
local scoring = require('earthBusRoutes/scoring')
local T = {}

local function route308() return assert(osm.parseRoute(H.fixture('route_6962840'))) end
local function route305() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

-- schedule -----------------------------------------------------------------------------------------------------
function T.schedule_is_deterministic_and_ordered()
  local r = route308()
  local a, b = sched.generate(r, 2), sched.generate(r, 2)
  assert(#a > 10 and #a == #b)
  for i = 1, #a do assert(a[i].start == b[i].start) end
  for i = 2, #a do assert(a[i].start > a[i - 1].start, 'not increasing at ' .. i) end
  assert(a[1].start >= 5 * 3600 and a[#a].start < 24 * 3600)
end

function T.regional_runs_less_often_than_city()
  local r = route308()
  local reg = sched.generate(r, 2)
  local city = sched.generate({ ref = 'x', id = 1, kind = 'city', stops = r.stops }, 2)
  assert(#city > #reg, #city .. ' vs ' .. #reg)
end

function T.weekend_is_sparser()
  local r = route305()
  local wk, we = sched.generate(r, 3), sched.generate(r, 6)
  assert(#we < #wk)
end

function T.tags_win_over_the_table()
  local r = { ref = 'x', id = 9, kind = 'city', stops = route305().stops, tags = { interval = '15', opening_hours = 'Mo-Fr 08:00-10:00' } }
  local t = sched.generate(r, 2)
  assert(#t == 8, #t)                      -- 2 h every 15 min
  assert(t[1].start >= 8 * 3600 and t[#t].start < 10 * 3600)
end

function T.night_line_runs_only_at_night()
  local r = { ref = 'N1', id = 5, kind = 'night', stops = route305().stops }
  local t = sched.generate(r, 2)
  assert(#t > 0)
  for _, tr in ipairs(t) do assert(tr.start >= 21 * 3600 or tr.start < 5 * 3600, tr.start) end
end

function T.run_times_grow_and_departures_are_found()
  local r = route305()
  local trips = sched.generate(r, 2)
  local tr = trips[3]
  for i = 2, #r.stops do assert(tr.arr[i] > tr.arr[i - 1] and tr.dep[i] >= tr.arr[i]) end
  local d = sched.departures(trips, 4, 8 * 3600, 3)
  assert(#d == 3 and d[1].at >= 8 * 3600 and d[2].at > d[1].at)
  local none = sched.nextTrip(trips, 1, 25 * 3600)
  assert(none == nil)
end

function T.duration_tag_scales_the_trip()
  local r = route305()
  r.tags.duration = '00:40'
  local trips = sched.generate(r, 2)
  local last = trips[1].arr[#r.stops]
  assert(math.abs(last - 2400) < 1, last)
end

-- demand -------------------------------------------------------------------------------------------------------
function T.profile_peaks_and_night()
  assert(demand.profile(7.5, false) > demand.profile(12, false))
  assert(demand.profile(12, false) > demand.profile(3, false))
  assert(demand.profile(7.5, true) < demand.profile(7.5, false))
end

function T.weights_are_normalised()
  local r = route305()
  local w = demand.stopWeights(r, { station = { [1] = true } })
  local sum = 0 for _, x in ipairs(w) do sum = sum + x end
  assert(math.abs(sum / #w - 1) < 1e-6)
end

function T.crowd_is_repeatable_and_follows_the_clock()
  local r = route305()
  local w, c = demand.stopWeights(r)
  local o = { tripId = 4, day = 2, density = 'normal' }
  local a = demand.waiting(r, w, c, 3, 7.5, false, 600, o)
  local b = demand.waiting(r, w, c, 3, 7.5, false, 600, o)
  assert(a == b)
  local peak, night = 0, 0
  for trip = 1, 200 do
    peak = peak + demand.waiting(r, w, c, 3, 7.5, false, 600, { tripId = trip, day = 2 })
    night = night + demand.waiting(r, w, c, 3, 2.5, false, 600, { tripId = trip, day = 2 })
  end
  assert(peak > night * 3, peak .. ' vs ' .. night)
  assert(demand.waiting(r, w, c, #r.stops, 7.5, false, 600, o) == 0)
end

function T.density_and_lateness_change_the_crowd()
  local r = route305()
  local w, c = demand.stopWeights(r)
  local function total(opts, since)
    local s = 0
    for t = 1, 100 do opts.tripId = t s = s + demand.waiting(r, w, c, 2, 12, false, since, opts) end
    return s
  end
  assert(total({ density = 'high' }, 600) > total({ density = 'low' }, 600))
  assert(total({ density = 'normal' }, 1800) > total({ density = 'normal' }, 600))
end

function T.passengers_get_off_downstream()
  local r = route305()
  local w, c = demand.stopWeights(r)
  local rand = demand.rng(7)
  for _ = 1, 50 do
    local d = demand.destination(r, w, c, 2, 12, false, rand)
    assert(d > 2 and d <= #r.stops)
  end
  assert(demand.destination(r, w, c, #r.stops - 1, 12, false, rand) == #r.stops)
end

function T.boarding_respects_room()
  local r = route305()
  local w, c = demand.stopWeights(r)
  local dests, left = demand.board(r, w, c, 2, 7.5, false, 3000, 2, { tripId = 1, day = 2, density = 'high' })
  assert(#dests <= 2)
  assert(left >= 0)
  assert(demand.dwellTime(2, 3, true) < demand.dwellTime(2, 3, false))
end

function T.poisson_mean()
  local rand = demand.rng(42)
  local sum, n = 0, 2000
  for _ = 1, n do sum = sum + demand.poisson(rand, 4) end
  assert(math.abs(sum / n - 4) < 0.3, sum / n)
  local big = 0
  for _ = 1, n do big = big + demand.poisson(rand, 60) end
  assert(math.abs(big / n - 60) < 2, big / n)
end

-- scoring ------------------------------------------------------------------------------------------------------
local function drive(s, seconds, aLong, aLat)
  for _ = 1, seconds do scoring.sample(s, 1, 10, aLong or 0.5, aLat or 0.5, false) end
end

function T.perfect_trip_scores_high()
  local s = scoring.new({ planned = 3 })
  for _ = 1, 3 do scoring.arrived(s, 10) scoring.departed(s, 0, 4, 2, 0) drive(s, 120) end
  local r = scoring.result(s)
  assert(r.points >= 950 and r.grade == 'S', r.points)
  assert(r.passengers == 12)
end

function T.late_early_rough_and_unsafe_cost_points()
  local function trip(delta, early, rough, doors)
    local s = scoring.new({ planned = 2 })
    for _ = 1, 2 do scoring.arrived(s, delta) scoring.departed(s, early, 1, 0, 0) drive(s, 100, rough and 4 or 0.5) end
    if doors then scoring.sample(s, 1, 8, 0, 0, true) end
    return scoring.result(s).points
  end
  local base = trip(0, 0, false, false)
  assert(trip(400, 0, false, false) < base)
  assert(trip(0, 180, false, false) < base)
  assert(trip(0, 0, true, false) < base)
  assert(trip(0, 0, false, true) < base)
end

function T.skipping_and_non_bus_penalised()
  local a = scoring.new({ planned = 3 })
  scoring.arrived(a, 0) scoring.departed(a, 0, 1, 0, 0) scoring.missed(a) scoring.missed(a)
  drive(a, 60)
  local b = scoring.new({ planned = 3, bus = false })
  for _ = 1, 3 do scoring.arrived(b, 0) scoring.departed(b, 0, 1, 0, 0) end
  drive(b, 60)
  assert(scoring.result(a).points < 800)
  assert(scoring.result(b).points <= 500)
end

function T.strictness_changes_the_score()
  local function pts(diff)
    local s = scoring.new({ planned = 2, difficulty = diff })
    for _ = 1, 2 do scoring.arrived(s, 200) scoring.departed(s, 0, 1, 0, 0) drive(s, 100, 3) end
    return scoring.result(s).points
  end
  assert(pts('relaxed') > pts('strict'))
end

return T
