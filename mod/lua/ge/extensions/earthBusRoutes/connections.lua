-- Transfers (plan 006 stage C): at a hub (a bus station, or a stop with 3 or more lines) the dispatcher asks the driver to wait for
-- the passengers of another line that arrives a few minutes after the bus. Waiting at the stop with the doors open until then
-- takes them on board and earns a bonus; leaving before they come costs a "missed connection". The arrivals of the other lines
-- come from the data service (/v1/connections: the real timetables) or, where it has none, are generated from the lines that
-- call at the stop (`approx`: marked as a rough guess). Pure logic: trip.lua calls offer / arrive / step / leave.
local demand = require('earthBusRoutes/demand')
local schedule = require('earthBusRoutes/schedule')
local scoring = require('earthBusRoutes/scoring')
local dispatch = require('earthBusRoutes/dispatch')
local M = {}

M.MAX_PER_TRIP = 2         -- at most this many transfers asked of the driver on one trip
M.MAX_AFTER_S = 300        -- only a line arriving 0..5 min after the bus
M.MAX_WAIT_S = 360         -- the bus does not wait longer than this at the stop
M.HUB_LINES = 3            -- lines calling near the stop for it to be a hub (a bus station is one anyway)
M.WIN_MIN = 8              -- the window of arrivals asked of the service, +- minutes
M.NEAR_M = 150             -- stops this near count as the same hub
M.ANNOUNCE_M = 700         -- the message comes when the bus is this near the stop
M.SPEED_M_S = 6.5
M.LIVE_EXTRA_S = 180       -- a transfer bus that is physical but still not at the hub this long after its time: the timer decides

-- Live transfers (plan 007 T5): fleetrun.lua sets M.live = { request(req) -> token|nil, status(token) -> 'pending' | 'live' | 'ready' |
-- 'fallback' | 'gone', cancel(token) }. With a token the transfer is credited when the bus of the other line is physically standing
-- at the hub with the doors open ('ready'), not when the clock says so; 'fallback' (or no provider, or no token) leaves the timer
-- logic below exactly as it was.
M.live = nil

function M.enabled(t) return t.opts.transfers ~= false end

local function clockLabel(sec)
  sec = math.floor(sec % 86400)
  return ('%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end
M.clockLabel = clockLabel

-- Arrivals of other lines made up from the lines that call at the stop: lines = { { ref, to, kind } }, tq = time of day (s) the
-- answer is for. Each line gets a fixed phase (from its name) in its interval of that time of day.
function M.approx(lines, tq, day, win)
  local out = {}
  local weekend = schedule.isWeekend(day or 2)
  local iv0 = schedule.periodAt(tq)
  for _, ln in ipairs(lines) do
    local iv = schedule.intervalFor({ tags = {} }, ln.kind or 'city', iv0, weekend, nil)
    if iv and iv > 0 then
      local off = math.floor((demand.hashSeed(ln.ref, ln.to or '') % iv) / 60) * 60
      local at = off + math.ceil((tq - win - off) / iv) * iv
      while at <= tq + win do
        out[#out + 1] = { ref = ln.ref, to = ln.to, rel = at - tq, approx = true }
        at = at + iv
      end
    end
  end
  table.sort(out, function(a, b) return a.rel < b.rel end)
  return out
end

-- Keep the answer for stop `idx`. `eta` = our expected arrival (trip clock, s), `tq` = the time of day the service was asked for,
-- answer = { arrivals = { { ref, to, at | rel, approx } }, lines = n }. An arrival's `at` is a time of day (s), `rel` seconds after tq.
function M.store(t, idx, eta, tq, answer)
  local list = {}
  for _, a in ipairs(answer.arrivals or {}) do
    local rel = a.rel or ((a.at or 0) - tq)
    list[#list + 1] = { ref = a.ref, to = a.to, at = eta + rel, approx = a.approx or answer.approx or false }
  end
  table.sort(list, function(a, b) return a.at < b.at end)
  t.conn[idx] = { list = list, lines = answer.lines or 0 }
end

function M.isHub(t, idx)
  local stop = t.route.stops[idx]
  local c = t.conn[idx]
  return (stop and stop.station == true) or (c ~= nil and (c.lines or 0) >= M.HUB_LINES)
end

-- The line to wait for at stop `idx` when the bus gets there at `eta`: the first to arrive 0..MAX_AFTER_S after it, or nil. The
-- answer is kept (one offer per stop), and an offer counts against MAX_PER_TRIP.
function M.offer(t, idx, eta)
  if not M.enabled(t) then return nil end
  if t.offered[idx] ~= nil then return t.offered[idx] or nil end
  local c = t.conn[idx]
  if not c or not M.isHub(t, idx) or t.connOffers >= M.MAX_PER_TRIP then return nil end
  for _, a in ipairs(c.list) do
    local after = a.at - eta
    if after >= 0 and after <= M.MAX_AFTER_S then
      t.connOffers = t.connOffers + 1
      t.offered[idx] = { ref = a.ref, to = a.to, at = a.at, approx = a.approx, after = after }
      M.requestLive(t, idx)
      return t.offered[idx]
    end
  end
  t.offered[idx] = false
  return nil
end

function M.requestLive(t, idx)
  local live, item = M.live, t.offered[idx]
  if not (live and item) then return end
  local ok, tok = pcall(live.request, { ref = item.ref, to = item.to, at = item.at, idx = idx, stop = t.route.stops[idx], approx = item.approx })
  if ok and tok then item.live = tok end
end

local function people(t, idx, item)
  local rand = demand.rng(demand.hashSeed(t.clock0, item.ref, idx, 'conn'))
  local hour = (item.at / 3600) % 24
  local k = 0.6 + demand.profile(hour, t.day >= 6)
  local dens = demand.DENSITY[t.opts.density or 'normal'] or 1
  return math.max(2, math.floor((2 + rand() * 6) * k * dens + 0.5))
end

local function scheduled(t, idx, which)
  if not t.entry then return nil end
  return t.entry.trip.start + (t.entry.trip[which][idx] or 0)
end

local function etaOf(t, idx)
  local sched = scheduled(t, idx, 'arr')
  if sched then return sched end
  local stop = t.route.stops[idx]
  return t.clock + math.max(0, ((stop.along or 0) - (t.along or 0)) / M.SPEED_M_S)
end

-- Approaching a hub with a connection to wait for: the dispatcher says so (once per stop)
function M.announce(t)
  if not M.enabled(t) or t.phase ~= 'approach' then return end
  local idx = t.idx
  if t.announced[idx] or idx >= #t.route.stops then return end
  local stop = t.route.stops[idx]
  local d = dispatch.distTo(t, stop)
  if not d or d > M.ANNOUNCE_M or not t.conn[idx] then return end
  t.announced[idx] = true
  local item = M.offer(t, idx, etaOf(t, idx))
  if item then
    dispatch.say(t, item.approx and 'connectionApprox' or 'connection',
      { stop = stop.name or '', ref = item.ref, time = clockLabel(item.at), mins = math.max(1, math.floor(item.after / 60 + 0.5)) }, 'transfer')
  end
end

-- The bus stands at the stop: wait for the offered line when it is still to come
function M.arrive(t)
  local idx = t.idx
  if not M.enabled(t) or idx >= #t.route.stops then return end
  local item = t.offered[idx]
  if item == nil then item = M.offer(t, idx, t.clock) end
  if not item then return end
  local wait = item.at - t.clock
  if wait <= 0 or wait > M.MAX_WAIT_S then return end          -- it came before us, or too far off to wait for
  t.hold = { ref = item.ref, at = item.at, approx = item.approx, people = people(t, idx, item), idx = idx, from = t.clock, live = item.live }
  dispatch.say(t, 'connectionWait', { ref = item.ref, time = clockLabel(item.at) }, 'transfer')
end

-- seconds of waiting past the scheduled departure that the transfer asked for (not held against the driver)
local function waive(t, untilClock)
  local h = t.hold
  local sched = scheduled(t, h.idx, 'dep')
  local from = math.max(h.from, sched or h.from)
  if untilClock > from then t.waived = t.waived + (untilClock - from) end
end

-- Every frame: the other line's passengers arrive and board when the doors are open
function M.step(t, dt, doorsOpen)
  M.announce(t)
  local h = t.hold
  if not h or t.phase ~= 'atStop' then return end
  local viaBus = false
  if h.live and M.live then
    local ok, state = pcall(M.live.status, h.live)
    if not ok or state == 'fallback' or state == 'gone' or t.clock > h.at + M.LIVE_EXTRA_S then h.live = nil
    elseif state == 'ready' then viaBus = true end
  else
    h.live = nil
  end
  if (h.live and viaBus or (not h.live and t.clock >= h.at)) and doorsOpen then
    waive(t, h.live and t.clock or h.at)
    t.hold = nil
    t.connCount = t.connCount + 1
    t.boardLeft = (t.boardLeft or 0) + h.people
    scoring.adjust(t.score, 'Connection made', { service = 0.03 })
    scoring.count(t.score, 'connections')
    dispatch.say(t, 'connectionBoard', { ref = h.ref, n = h.people }, 'good')
  end
end

-- The bus leaves: with the connection still to come, its passengers stay behind
function M.leave(t)
  local h = t.hold
  if not h then return end
  if h.live and M.live then pcall(M.live.cancel, h.live) end
  waive(t, math.min(t.clock, h.at))
  t.hold = nil
  t.connCount = t.connCount + 1
  t.leftBehind = t.leftBehind + h.people
  scoring.adjust(t.score, 'Missed connection', { service = -0.04 })
  scoring.count(t.score, 'missedConnections')
  dispatch.say(t, 'connectionMissed', { ref = h.ref }, 'bad')
end

return M
