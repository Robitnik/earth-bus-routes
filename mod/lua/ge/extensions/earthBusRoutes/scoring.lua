-- Trip score: 0..1000 from punctuality, service, comfort and safety. Pure logic: the trip feeds it events.
local M = {}

M.WEIGHTS = { punctuality = 350, service = 250, comfort = 200, safety = 200 }
-- strictness: scales every tolerance (relaxed forgives more)
M.STRICT = { relaxed = 1.4, normal = 1.0, strict = 0.7 }
M.LIMITS = { longitudinal = 2.5, lateral = 3.0 }   -- m/s^2 above which the ride is rough
M.SPEEDING_NOTE_S = 3                         -- speeding this long gets a note
M.NO_SIGNAL_POINTS = 15                       -- points lost for pulling out without the indicator
M.GRADES = { { 900, 'S' }, { 800, 'A' }, { 650, 'B' }, { 500, 'C' }, { 0, 'D' } }

function M.new(opts)
  opts = opts or {}
  return {
    k = M.STRICT[opts.difficulty or 'normal'] or 1,
    bus = opts.bus ~= false,                 -- driving something that is not a bus halves the score
    stops = {},                              -- per stop { delta = s late(+)/early(-) at arrival, early = s left too early }
    planned = opts.planned or 0,             -- stops the trip has to serve
    served = 0, passengers = 0, missed = 0, leftWaiting = 0,
    harshSec = 0, drivenSec = 0, harshLong = 0, harshLat = 0,
    doorEvents = 0, doorSec = 0, collisions = 0, speedingSec = 0,
    fare = opts.fare or 1.5, revenue = 0, notes = {},
  }
end

local function note(s, text, points)
  s.notes[#s.notes + 1] = { text = text, points = points or 0 }
  s.noteSeq = (s.noteSeq or 0) + 1
  if #s.notes > 40 then table.remove(s.notes, 1) end
end

-- The bus stopped at a stop: `deltaSec` against the timetable (late positive). Free-running trips pass nil.
function M.arrived(s, deltaSec)
  s.stops[#s.stops + 1] = { delta = deltaSec }
  s.served = s.served + 1
end

-- It left; `earlySec` > 0 when it left before its scheduled time
function M.departed(s, earlySec, boarded, alighted, leftWaiting)
  local last = s.stops[#s.stops]
  if last then last.early = earlySec or 0 end
  s.passengers = s.passengers + (boarded or 0)
  s.revenue = s.revenue + (boarded or 0) * s.fare
  s.leftWaiting = s.leftWaiting + (leftWaiting or 0)
  if (earlySec or 0) > 30 * s.k then note(s, 'Left early', -math.floor((earlySec / 60) * 25)) end
end

function M.missed(s, people)
  s.missed = s.missed + 1
  note(s, 'Stop skipped', -50)
end

-- Every frame (dt s): speed m/s, acceleration along and across (m/s^2), whether a door is open
function M.sample(s, dt, speed, aLong, aLat, doorOpen, overLimit)
  s.drivenSec = s.drivenSec + dt
  local rough = false
  if math.abs(aLong or 0) > M.LIMITS.longitudinal * s.k then s.harshLong = s.harshLong + dt rough = true end
  if math.abs(aLat or 0) > M.LIMITS.lateral * s.k then s.harshLat = s.harshLat + dt rough = true end
  if rough then s.harshSec = s.harshSec + dt end
  if doorOpen and (speed or 0) > 2 then
    if s.doorSec == 0 or s._doorWas ~= true then s.doorEvents = s.doorEvents + 1 note(s, 'Moving with doors open', -50) end
    s.doorSec = s.doorSec + dt
    s._doorWas = true
  else
    s._doorWas = false
  end
  if overLimit then
    s.speedingSec = s.speedingSec + dt
    s._overRun = (s._overRun or 0) + dt
    -- one note per stretch of speeding, once it has lasted a few seconds (the points go through the safety part)
    if s._overRun >= M.SPEEDING_NOTE_S and not s._overNoted then s._overNoted = true note(s, 'Speeding', 0) end
  else
    s._overRun, s._overNoted = 0, false
  end
end

-- Pulled out of a stop without the indicator (trip.lua decides): the safety part loses M.NO_SIGNAL_POINTS of its weight
function M.noSignal(s)
  s.signalMisses = (s.signalMisses or 0) + 1
  note(s, 'No signal', -M.NO_SIGNAL_POINTS)
end

-- Dispatcher events, transfers (plan 006 stage C): a note and a nudge to the service / comfort part (fractions of 1, can be
-- negative). The note's points are what the nudge is worth in the 1000-point score.
function M.adjust(s, text, parts)
  s.adj = s.adj or { service = 0, comfort = 0 }
  s.adj.service = s.adj.service + (parts.service or 0)
  s.adj.comfort = s.adj.comfort + (parts.comfort or 0)
  note(s, text, math.floor((parts.service or 0) * M.WEIGHTS.service + (parts.comfort or 0) * M.WEIGHTS.comfort + 0.5))
end

-- A ticket sold by the driver (suburban and intercity lines): its price goes into the revenue
function M.ticket(s, price)
  s.tickets = (s.tickets or 0) + 1
  s.revenue = s.revenue + (price or 0)
end

function M.count(s, key) s.counts = s.counts or {} s.counts[key] = (s.counts[key] or 0) + 1 end

function M.collision(s) s.collisions = s.collisions + 1 note(s, 'Collision', -40) end

-- A standing passenger fell when the bus braked hard (cabin.lua): the comfort of the ride loses FALL_POINTS
M.FALL_POINTS = 30
function M.fall(s) s.falls = (s.falls or 0) + 1 note(s, 'Passenger fell', -M.FALL_POINTS) end

local function clamp01(x) return math.max(0, math.min(1, x)) end

-- Final numbers: parts 0..1, points, grade, stars
function M.result(s)
  local sum, n = 0, 0
  for _, st in ipairs(s.stops) do
    if st.delta ~= nil then
      local pct = 1
      local late = st.delta - 60 * s.k
      if late > 0 then pct = 1 - 0.10 * (late / 60) / s.k end
      local early = (st.early or 0)
      if early > 0 then pct = pct - 0.25 * (early / 60) / s.k end
      if st.delta < -60 * s.k then pct = pct - 0.15 * ((-st.delta - 60 * s.k) / 60) end
      sum, n = sum + clamp01(pct), n + 1
    end
  end
  local punctuality = (n + s.missed) > 0 and sum / (n + s.missed) or 1   -- a skipped stop is a stop missed on time; off the timetable: nothing to be late for
  local planned = math.max(s.planned, s.served + s.missed, 1)
  local service = clamp01(s.served / planned) * (1 - clamp01(s.leftWaiting / math.max(1, s.passengers + s.leftWaiting)) * 0.3)
  local comfort = 1 - clamp01(s.harshSec / math.max(60, 0.08 * s.drivenSec))
  comfort = clamp01(comfort - (s.falls or 0) * M.FALL_POINTS / M.WEIGHTS.comfort)
  if s.adj then service, comfort = clamp01(service + s.adj.service), clamp01(comfort + s.adj.comfort) end
  local safety = clamp01(1 - 0.2 * s.doorEvents - 0.15 * s.collisions - 0.01 * s.speedingSec - (s.signalMisses or 0) * M.NO_SIGNAL_POINTS / M.WEIGHTS.safety)
  local parts = { punctuality = punctuality, service = service, comfort = comfort, safety = safety }
  local points = 0
  for k, w in pairs(M.WEIGHTS) do points = points + w * parts[k] end
  if not s.bus then points = points * 0.5 end
  points = math.floor(points + 0.5)
  local grade = 'D'
  for _, g in ipairs(M.GRADES) do if points >= g[1] then grade = g[2] break end end
  local stars = points >= 900 and 5 or points >= 750 and 4 or points >= 600 and 3 or points >= 450 and 2 or 1
  return { parts = parts, points = points, grade = grade, stars = stars, passengers = s.passengers,
    revenue = s.revenue, served = s.served, planned = planned, missed = s.missed, notes = s.notes,
    tickets = s.tickets or 0, counts = s.counts or {} }
end

return M
