local H = dofile('tests/harness.lua')
local career = require('earthBusRoutes/career')
local careersvc = require('earthBusRoutes/careersvc')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local T = {}

local function has(list, id) for _, v in ipairs(list) do if v == id then return true end end return false end

-- a trip record with sane defaults
local function rec(o)
  local r = { key = '305|IREDO', ref = '305', from = 'A', to = 'B', kind = 'city', points = 700, grade = 'B', passengers = 20, revenue = 30,
    hours = 1, km = 10, punctuality = 0.9, scheduled = true, stops = {}, inShift = false }
  for k, v in pairs(o or {}) do r[k] = v end
  return r
end

function T.old_stats_move_into_the_profile_with_their_records()
  local stats = { trips = 7, passengers = 214, points = 5120,
    best = { ['305|IREDO'] = { points = 874, grade = 'A', ref = '305', from = 'Náchod', to = 'Hradec Králové' } } }
  local files = { ['/s/stats.json'] = stats }
  local read = function(path) if files[path] == nil then error('no file') end return files[path] end
  local p, migrated = career.load(read, '/s/profile.json', '/s/stats.json')
  assert(migrated == true and p.format == 2)
  assert(p.totals.trips == 7 and p.totals.passengers == 214 and p.totals.points == 5120)
  assert(p.best['305|IREDO'].points == 874 and p.best['305|IREDO'].grade == 'A' and p.best['305|IREDO'].to == 'Hradec Králové')
  -- the migrated profile is a whole one: the later code finds every table
  assert(p.shifts.count == 0 and type(p.tracks) == 'table' and p.rank == 'trainee')
  -- a profile.json that exists wins over stats.json
  files['/s/profile.json'] = { format = 2, totals = { trips = 9 } }
  local p2, again = career.load(read, '/s/profile.json', '/s/stats.json')
  assert(again == false and p2.totals.trips == 9 and p2.totals.km == 0, 'a half-written profile is filled in')
  -- nothing at all: a new profile, no error
  local p3, m3 = career.load(function() error('no file') end, '/s/profile.json', '/s/stats.json')
  assert(m3 == false and p3.totals.trips == 0)
end

function T.the_service_migrates_once_and_keeps_stats_json()
  H.reset()
  local files = { ['/settings/earthBusRoutes/stats.json'] = { trips = 3, passengers = 50, points = 1800, best = {} } }
  careersvc.reset()
  careersvc.io = {
    read = function(path) if files[path] == nil then error('no file') end return files[path] end,
    write = function(path, t) files[path] = t return true end,
  }
  assert(careersvc.stats().trips == 3)
  assert(files['/settings/earthBusRoutes/profile.json'] and files['/settings/earthBusRoutes/profile.json'].format == 2, 'profile.json written')
  assert(files['/settings/earthBusRoutes/stats.json'].trips == 3, 'the old file is left alone')
  careersvc.reset()
end

function T.earnings_hourly_rate_plus_revenue_times_the_grade()
  local base = 2 * career.HOURLY_RATE + 50
  assert(career.earnings(2, 50, 'S') == math.floor(base * 1.5 + 0.5))
  assert(career.earnings(2, 50, 'B') == base)
  assert(career.earnings(2, 50, 'D') == math.floor(base * 0.6 + 0.5))
  assert(career.GRADE_BONUS.S == 1.5 and career.GRADE_BONUS.D == 0.6)
  assert(career.earnings(0, 0, 'S') == 0)
  local last
  for _, g in ipairs({ 'D', 'C', 'B', 'A', 'S' }) do
    local e = career.earnings(1, 10, g)
    assert(not last or e > last, 'a better grade pays more')
    last = e
  end
end

function T.ranks_by_shift_hours_and_the_average_of_the_last_ten()
  local p = career.new()
  assert(p.rank == 'trainee' and career.unlocks('trainee').shiftHours == 1)
  -- 3 hours with grade C: Driver
  career.recordShift(p, { hours = 3, grade = 'C' })
  assert(p.rank == 'driver', p.rank)
  -- enough hours but the average is C: no Experienced
  career.recordShift(p, { hours = 8, grade = 'C' })
  assert(p.rank == 'driver', p.rank)
  -- good shifts push the average of the last 10 up
  local up
  for _ = 1, 10 do
    local r = career.recordShift(p, { hours = 2, grade = "A" })
    up = up or r.rankUp
  end
  assert(p.rank == 'experienced' or p.rank == 'mentor', p.rank)
  assert(#p.shifts.recent == 10, 'only the last ten count')
  assert(career.averageGrade(p) == 3)
  -- 25 hours and an average of A: Mentor
  assert(p.shifts.hours >= 25 and p.rank == 'mentor', p.rank .. ' ' .. p.shifts.hours)
  assert(career.unlocks('mentor').night == true and career.unlocks('experienced').depot == true and career.unlocks('driver').depot == false)
  assert(career.unlocks('trainee').night == false and career.unlocks('mentor').shiftHours == 4)
end

function T.the_rank_is_kept_when_the_average_drops()
  local p = career.new()
  for _ = 1, 4 do career.recordShift(p, { hours = 3, grade = 'A' }) end
  assert(p.rank == 'experienced', p.rank)
  for _ = 1, 10 do career.recordShift(p, { hours = 0.1, grade = 'D' }) end
  assert(career.averageGrade(p) == 0)
  assert(p.rank == 'experienced', 'a rank once reached is not taken away')
end

function T.rank_info_shows_the_way_to_the_next_rank()
  local p = career.new()
  local i0 = career.rankInfo(p)
  assert(i0.id == 'trainee' and i0.next == 'driver' and i0.hoursNeed == 3 and i0.gradeNeed == 'C' and i0.progress == 0 and i0.gradeOk == false)
  career.recordShift(p, { hours = 1.5, grade = 'B' })
  local i1 = career.rankInfo(p)
  assert(math.abs(i1.hoursPct - 0.5) < 1e-9 and i1.gradeOk == true and i1.avgLetter == 'B', i1.hoursPct)
  assert(i1.progress > 0.4 and i1.progress < 0.6)
  p.rank = 'mentor'
  local top = career.rankInfo(p)
  assert(top.next == nil and top.progress == 1)
end

function T.a_trip_counts_totals_records_and_pays()
  local p = career.new()
  local a = career.recordTrip(p, rec({ points = 700, grade = 'B' }))
  assert(a.record == true and a.previous == nil and p.totals.trips == 1 and p.totals.passengers == 20 and p.totals.points == 700)
  assert(a.earned == career.earnings(1, 30, 'B') and p.credits == a.earned)
  local b = career.recordTrip(p, rec({ points = 650 }))
  assert(b.record == false and b.previous == 700 and p.best['305|IREDO'].points == 700)
  local c = career.recordTrip(p, rec({ points = 880, grade = 'A' }))
  assert(c.record == true and c.previous == 700 and p.best['305|IREDO'].grade == 'A')
  assert(p.totals.trips == 3 and c.totals.trips == 3 and c.totals.points == 700 + 650 + 880)
  assert(p.totals.km == 30 and p.totals.hours == 3)
  assert(career.onTimePct(p) == 90)
  -- a trip inside a shift is paid with the shift
  local before = p.credits
  local d = career.recordTrip(p, rec({ inShift = true }))
  assert(d.earned == 0 and p.credits == before)
  -- the shift's own record: trips and passengers were counted by the trips
  local s = career.recordShift(p, { hours = 2, trips = 4, passengers = 80, punctuality = 0.95, grade = 'A', revenue = 120 })
  assert(s.earned == career.earnings(2, 120, 'A') and p.credits == before + s.earned)
  assert(p.totals.trips == 4 and p.totals.passengers == 80, 'the shift adds no trips twice')
  assert(p.shifts.count == 1 and p.shifts.hours == 2)
  local m = career.model(p)
  assert(m.totals.shifts == 1 and m.totals.km == 40 and m.rank.id == 'trainee' and #m.records == 1)
end

function T.light_mode_keeps_only_totals_and_records()
  local p = career.new()
  local r = career.recordTrip(p, rec({ stops = { { name = 'Náchod, aut. nádraží', lat = 50.41, lon = 16.16, station = true } }, track = { 504100, 161600, 504200, 161700 } }), { light = true })
  assert(r.record and p.totals.trips == 1 and p.totals.km == 0 and #p.tracks == 0 and next(p.towns) == nil and p.credits == 0 and #r.unlocked == 0)
end

function T.achievements_unlock_from_trip_events_and_once()
  local p = career.new()
  local r = career.recordTrip(p, rec({ allOnTime = true, kind = 'night', km = 120, grade = 'S', smooth = true }))
  for _, id in ipairs({ 'first_trip', 'on_time_all', 'night_line', 'km_100_trip', 'first_s', 'smooth_trip' }) do assert(has(r.unlocked, id), id) end
  assert(not has(r.unlocked, 'trips_10') and not has(r.unlocked, 'ghost_beat'))
  local again = career.recordTrip(p, rec({ allOnTime = true, kind = 'night', km = 120, grade = 'S' }))
  assert(not has(again.unlocked, 'first_trip') and not has(again.unlocked, 'night_line'), 'each achievement once')
  -- counters fed by other stages
  local g = career.recordTrip(p, rec({ ghostDeltaSec = 75, transfersWaited = 10 }))
  assert(has(g.unlocked, 'ghost_beat') and has(g.unlocked, 'transfers_10'))
  -- the 10th trip
  for _ = 1, 7 do career.recordTrip(p, rec()) end
  assert(p.ach.trips_10 ~= nil and p.ach.trips_100 == nil)
  -- shifts: a smooth one, and ranks
  local s = career.recordShift(p, { hours = 3, grade = 'B', smooth = true })
  assert(has(s.unlocked, 'smooth_shift') and has(s.unlocked, 'first_shift') and has(s.unlocked, 'rank_driver') and s.rankUp == 'driver')
  assert(#career.ACHIEVEMENTS >= 20)
  local seen = {}
  for _, a in ipairs(career.ACHIEVEMENTS) do assert(a.id and a.name and a.check and not seen[a.id], 'duplicate or incomplete ' .. tostring(a.id)) seen[a.id] = true end
end

function T.towns_stations_and_countries_are_collected()
  local p = career.new()
  local stops = {}
  for i = 1, 10 do
    stops[#stops + 1] = { name = 'Town' .. i .. ', centre', lat = 50 + i * 0.1, lon = 16, station = i % 2 == 0, country = i <= 3 and 'Czechia' or i <= 6 and 'Poland' or 'Germany' }
  end
  stops[#stops + 1] = { name = 'Elsewhere', town = 'Named By Earth', lat = 51.5, lon = 16, station = false }
  local r = career.recordTrip(p, rec({ stops = stops }))
  assert(next(p.towns) and p.towns['Town3'] and p.towns['Named By Earth'], 'the town is the name before the comma, or what Earth says')
  assert(p.towns['Town3'].la == 503000 and p.towns['Town3'].lo == 160000)
  assert(p.stations['Town2, centre'] and not p.stations['Town1, centre'])
  assert(p.countries.Czechia == 3 and p.countries.Poland == 3 and p.countries.Germany == 4)
  assert(has(r.unlocked, 'towns_10') and has(r.unlocked, 'countries_3'), table.concat(r.unlocked, ','))
  local layer = career.mapLayer(p)
  assert(#layer.towns == 11 and #layer.stations == 5)
end

-- ---- the driven line --------------------------------------------------------------------------------------------------------

local function straight(km)             -- a line going north every 10 m
  local run = career.runNew()
  local n = km * 100
  for i = 0, n do career.runSample(run, 50 + i * 10 / 111195, 16) end
  return run
end

function T.the_driven_line_has_a_point_per_200_m_and_counts_distance()
  local run = straight(10)
  assert(math.abs(run.meters - 10000) < 20, run.meters)
  local pts = #run.p / 2
  assert(pts >= 49 and pts <= 52, pts)
  -- a jump (teleport) is not driven
  local before = run.meters
  career.runSample(run, 51, 17)
  assert(run.meters == before, 'a jump is not counted')
  -- junk is ignored
  career.runSample(run, nil, nil)
  career.runStop(run, { name = 'X', lat = 50, lon = 16 })
  career.runStop(run, { name = 'X', lat = 50, lon = 16 })
  assert(#run.stops == 1)
end

function T.simplify_keeps_corners_and_drops_straight_points()
  local p = {}
  for i = 0, 20 do p[#p + 1], p[#p + 2] = 500000 + i * 18, 160000 end                       -- north 200 m steps (E4 degrees: 18 = ~200 m)
  for i = 1, 20 do p[#p + 1], p[#p + 2] = 500000 + 20 * 18, 160000 + i * 28 end              -- then east
  local s = career.simplify(p, 100)
  assert(#s == 6, #s)                                                                        -- start, corner, end
  assert(s[1] == p[1] and s[2] == p[2] and s[5] == p[#p - 1] and s[6] == p[#p], 'the ends stay')
  assert(s[3] == 500000 + 20 * 18 and s[4] == 160000, 'the corner stays')
  assert(#career.simplify({ 1, 2, 3, 4 }, 100) == 4)
end

function T.tracks_stay_inside_the_budget_and_the_oldest_go_coarser()
  local p = career.new()
  local function wiggle(seed, n)
    local f = {}
    for i = 0, n - 1 do f[#f + 1], f[#f + 2] = 500000 + seed * 1000 + i * 18, 160000 + math.floor(math.sin(i / 3) * 40) + seed end
    return f
  end
  local budget = 6000
  for k = 1, 12 do
    p.tracks[#p.tracks + 1] = { k = 'r' .. k, ref = tostring(k), p = wiggle(k, 150) }
    career.compact(p, budget)
    assert(career.trackBytes(p) <= budget, 'over budget at ' .. k .. ': ' .. career.trackBytes(p))
  end
  assert(#p.tracks >= 2)
  -- the oldest ones were simplified harder than the newest
  local newest = p.tracks[#p.tracks]
  assert(#p.tracks[1].p <= #newest.p, #p.tracks[1].p .. ' vs ' .. #newest.p)
  -- with the default budget a few long drives fit untouched
  local q = career.new()
  career.recordTrip(q, rec({ track = straight(100).p }))
  assert(#q.tracks == 1 and #q.tracks[1].p >= 400)
  assert(career.trackBytes(q) < career.TRACK_BUDGET)
end

function T.one_line_per_route_a_longer_drive_replaces_the_old_one()
  local p = career.new()
  career.recordTrip(p, rec({ track = straight(5).p }))
  career.recordTrip(p, rec({ track = straight(1).p }))
  assert(#p.tracks == 1 and #p.tracks[1].p / 2 > 20, 'a short run does not replace the whole line')
  career.recordTrip(p, rec({ track = straight(8).p }))
  assert(#p.tracks == 1 and #p.tracks[1].p / 2 > 35)
  career.recordTrip(p, rec({ key = 'other|', ref = '9', track = straight(2).p }))
  assert(#p.tracks == 2)
end

function T.map_layer_is_capped_for_the_page()
  local p = career.new()
  for k = 1, 5 do career.recordTrip(p, rec({ key = 'l' .. k, ref = tostring(k), track = straight(40).p })) end
  local layer = career.mapLayer(p, 40)
  local n = 0
  for _, l in ipairs(layer.lines) do for _ in ipairs(l.pts) do n = n + 1 end assert(#l.pts >= 2) end
  assert(n <= 40 and #layer.lines == 5, n)
  local full = career.mapLayer(p, 100000)
  assert(#full.lines[1].pts > 100)
  assert(math.abs(full.lines[1].pts[1][1] - 50) < 1e-3 and math.abs(full.lines[1].pts[1][2] - 16) < 1e-3)
end

-- ---- through a real trip ------------------------------------------------------------------------------------------------------

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

function T.a_trip_through_the_service_ends_in_the_profile_and_the_hud_toast()
  H.reset()
  local files = {}
  careersvc.reset()
  careersvc.io = {
    read = function(path) if files[path] == nil then error('no file') end return files[path] end,
    write = function(path, t) files[path] = t return true end,
  }
  local toasts = {}
  _G.guihooks = { trigger = function(name, data) if name == 'EarthBusRoutesAchievement' then toasts[#toasts + 1] = data end end }

  local r = route()
  local trips = sched.generate(r, 2)
  local d = sched.departures(trips, 1, 8 * 3600, 1)[1]
  local t = trip.new({ route = r, trips = trips, entry = { trip = d.trip, at = d.at }, startIndex = 1, day = 2, clock = sched.scheduled(d.trip, 1),
    opts = { density = 'high' } })
  careersvc.begin()
  -- drive it: every frame samples the bus; the stops are noted when the bus arrives
  local along, speed = r.stops[1].along or 0, 0
  local function frame(sp, doors)
    local lat, lon = geo.pointAt(r.path, r.cum, along)
    along = along + sp * 0.1
    trip.update(t, 0.1, { lat = lat, lon = lon, speed = sp, doorsOpen = doors, aLong = 0.4, aLat = 0.4 })
    careersvc.sample(lat, lon)
    for _, e in ipairs(trip.takeEvents(t)) do if e.name == 'arrived' then careersvc.arrived(e.data.stop) end end
  end
  for i = 1, #r.stops do
    if i > 1 then
      local target = r.stops[i].along
      while along < target - 0.5 do
        local left = target - along
        frame(math.min(left < 40 and math.max(0.5, 9 * left / 40) or 9, left * 10 + 0.1), false)
      end
      along = target frame(0, false)
    end
    for _ = 1, 100 do frame(0, true) end
    local guard = 0
    while ((t.alightLeft or 0) > 0 or (t.boardLeft or 0) > 0) and guard < 600 do for _ = 1, 50 do frame(0, true) end guard = guard + 1 end
    for _ = 1, 15 do frame(0, false) end
    if t.finished then break end
  end
  for _ = 1, 100 do frame(0, false) end
  assert(t.finished, 'the trip did not finish')
  local res = trip.result(t)
  local record, previous, totals, news = careersvc.finish(t, res, true)
  assert(record == true and previous == nil and totals.trips == 1)
  local prof = files['/settings/earthBusRoutes/profile.json']
  assert(prof and prof.format == 2 and prof.totals.trips == 1, 'profile.json written')
  assert(prof.totals.km > 40 and prof.totals.km < 80, prof.totals.km)           -- the route is about 54 km
  assert(#prof.tracks == 1 and #prof.tracks[1].p > 100, 'the driven line was stored')
  assert(prof.credits > 0 and news.earned == prof.credits)
  assert(has(news.unlocked, 'first_trip') and #toasts >= 1 and toasts[1].id and toasts[1].name, 'the HUD was told')
  assert(news.unlocked and prof.ach.first_trip ~= nil)
  local model = careersvc.model()
  assert(model.totals.trips == 1 and #model.layer.lines == 1 and model.achievements[1].id)
  -- the next trip of the same line: the record logic of old
  careersvc.begin()
  local rec2 = careersvc.finish(t, { points = res.points - 10, grade = res.grade, passengers = 1, parts = res.parts }, false)
  assert(rec2 == false, 'no new record')
  assert(files['/settings/earthBusRoutes/profile.json'].totals.trips == 2)
  careersvc.reset()
end

function T.shift_summary_entry_point_for_stage_b()
  H.reset()
  careersvc.reset()
  local files = {}
  careersvc.io = { read = function(path) if files[path] == nil then error('no file') end return files[path] end, write = function(path, t) files[path] = t return true end }
  local out = careersvc.shiftDone({ hours = 3, trips = 5, passengers = 120, punctuality = 0.92, grade = 'B', revenue = 150, smooth = true })
  assert(out and out.earned == career.earnings(3, 150, 'B') and out.rankUp == 'driver' and out.rank.id == 'driver')
  assert(careersvc.rank().id == 'driver')
  assert(files['/settings/earthBusRoutes/profile.json'].shifts.count == 1)
  careersvc.reset()
end

function T.main_publishes_the_profile_only_once_the_tab_was_opened()
  H.reset()
  careersvc.reset()
  local files = { ['/settings/earthBusRoutes/stats.json'] = { trips = 2, passengers = 10, points = 1200, best = {} } }
  careersvc.io = { read = function(path) if files[path] == nil then error('no file') end return files[path] end, write = function(path, t) files[path] = t return true end }
  local m = H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua')
  local before = m.model()
  assert(before.profile == nil and before.career.on == true)
  m.uiProfileOpen()
  local after = m.model()
  assert(after.profile and after.profile.totals.trips == 2 and #after.profile.achievements >= 20 and after.profile.layer, 'the profile is in the model')
  assert(m.careerRank().id == 'trainee')
  local sh = m.careerShiftDone({ hours = 3, grade = 'A', trips = 3 })
  assert(sh and sh.rankUp == 'driver' and m.model().profile.rank.id == 'driver')
  careersvc.reset()
end

return T
