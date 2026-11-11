-- The game side of the career (career.lua is the pure part): keeps the profile in memory, reads and writes profile.json, follows the
-- running trip (driven line, stops stopped at) and tells the HUD about unlocked achievements. Every call is defensive: a failure here
-- must never touch a trip, so main.lua calls these without caring what they return except in finish().
local career = require('earthBusRoutes/career')
local world = require('earthBusRoutes/world')

local M = {}
M.PATH = '/settings/earthBusRoutes/profile.json'
M.OLD_PATH = '/settings/earthBusRoutes/stats.json'
M.MAP_POINTS = 1500            -- the most points of driven lines sent to the page

local st = { p = nil, run = nil, cache = nil }

-- the file functions of the game (the tests replace them)
M.io = {
  read = function(path) return jsonReadFile(path) end,
  write = function(path, t, pretty) return jsonWriteFile(path, t, pretty) end,
}

function M.profile()
  if not st.p then
    local p, migrated = career.load(M.io.read, M.PATH, M.OLD_PATH)
    st.p = p
    if migrated then
      career.save(M.io.write, M.PATH, p)
      if log then log('I', 'earthBusRoutes', 'stats.json moved into profile.json (' .. tostring(p.totals.trips) .. ' trips)') end
    end
  end
  return st.p
end

-- { trips, passengers, points } for the old stats card
function M.stats()
  local ok, p = pcall(M.profile)
  return ok and p and career.statsOf(p) or nil
end

function M.begin()
  st.run = career.runNew()
end

function M.sample(lat, lon)
  if st.run then pcall(career.runSample, st.run, lat, lon) end
end

-- The bus stopped at `stop` (a stop of the route): town and country come from Earth's reverse geocoding when it has them
function M.arrived(stop)
  if not st.run or type(stop) ~= 'table' then return end
  pcall(function()
    local pl = world.place() or {}
    career.runStop(st.run, { name = stop.name, lat = stop.lat, lon = stop.lon, station = stop.station, town = pl.place, country = pl.country })
  end)
end

local function announce(ids)
  for _, id in ipairs(ids or {}) do
    pcall(function()
      guihooks.trigger('EarthBusRoutesAchievement', { id = id, name = career.achievementName(id) })
    end)
  end
end

-- A trip finished (t = the trip, res = trip.result(t)); `full` false: the career part is off in the options, only the totals and records count.
-- Returns record, previous points, stats = { trips, passengers, points }, news = { earned, unlocked, rankUp } (news may be nil).
function M.finish(t, res, full)
  local p = M.profile()
  local rec
  if st.run then
    local ok, r = pcall(career.tripRecord, st.run, t, res)
    if ok then rec = r end
  end
  rec = rec or { key = tostring(t.route.ref) .. '|' .. tostring(t.route.network or ''), ref = t.route.ref, from = t.route.from, to = t.route.to,
    points = res.points, grade = res.grade, passengers = res.passengers }
  rec.at = os and os.time and os.time() or 0
  rec.inShift = M.inShift == true
  local out = career.recordTrip(p, rec, { light = full == false })
  st.run, st.cache = nil, nil
  career.save(M.io.write, M.PATH, p)
  if full ~= false then announce(out.unlocked) end
  local news = full ~= false and { earned = out.earned, unlocked = out.unlocked, rankUp = out.rankUp } or nil
  return out.record, out.previous, out.totals, news
end

-- Stage B's shift summary calls this (through earthBusRoutes_main.careerShiftDone) with
-- { hours, trips, passengers, punctuality, grade, revenue, smooth }. Returns { earned, unlocked, rankUp, rank } or nil.
function M.shiftDone(rec)
  local ok, out = pcall(function()
    local p = M.profile()
    rec = rec or {}
    rec.at = rec.at or (os and os.time and os.time() or 0)
    local r = career.recordShift(p, rec)
    st.cache = nil
    career.save(M.io.write, M.PATH, p)
    announce(r.unlocked)
    return r
  end)
  return ok and out or nil
end

-- the profile page's model and the map layer (kept until the next finished trip)
function M.model()
  if not st.cache then
    local ok, m = pcall(function()
      local p = M.profile()
      local model = career.model(p)
      model.layer = career.mapLayer(p, M.MAP_POINTS)
      return model
    end)
    st.cache = ok and m or false
  end
  return st.cache or nil
end

function M.rank()
  local ok, info = pcall(function() return career.rankInfo(M.profile()) end)
  return ok and info or nil
end

function M.reset() st.p, st.run, st.cache = nil, nil, nil end

return M
