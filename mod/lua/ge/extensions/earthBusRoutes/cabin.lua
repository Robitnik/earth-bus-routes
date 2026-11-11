-- The inside of the bus (plan 006, ideas 10 and 9): the LED board (next stop, "on request", a bell when somebody asks) and the
-- live comfort (standing passengers, a cup of coffee that sways with the ride, a passenger who falls when the driver brakes
-- hard). Pure logic (tests/test_cabin.lua): trip.lua feeds it every frame, main.lua plays the bell and the HUD shows the numbers.
local scoring = require('earthBusRoutes/scoring')
local M = {}

M.BELL_M = 350            -- somebody who gets off at the next stop presses the button when the stop is this near
M.FALL_FACTOR = 1.5       -- braking harder than scoring.LIMITS.longitudinal * this (and the strictness) throws a standing passenger
M.FALL_GAP_S = 20         -- at most one fall in this many seconds
M.FALL_MIN_SPEED = 1.5    -- m/s: no falls at a standstill
M.CUP_MAX_DEG = 30        -- the cup's tilt at the end of its range
-- the cup: a damped spring (1 s period, a little sloshing) pushed by the ride; lean 1 = full tilt
local CUP_W, CUP_ZETA, CUP_GAIN = 6.5, 0.22, 0.12

local function state(t)
  local c = t.cabin
  if not c then
    c = { cup = 0, cupV = 0, falls = 0, fallSeq = 0, lastFall = -math.huge, bellIdx = nil, bellSeq = 0 }
    t.cabin = c
  end
  return c
end
M.state = state

-- The options (menu settings, default on): main.lua passes the player's choices when the trip begins
function M.configure(t, opts)
  t.opts = t.opts or {}
  opts = opts or {}
  t.opts.ledBoard = opts.ledBoard ~= 'off'
  t.opts.liveComfort = opts.liveComfort ~= 'off'
end

local function wants(t, name) return not (t.opts and t.opts[name] == false) end

-- People standing: those who do not fit the seats
function M.standing(t) return math.max(0, #t.onboard - (t.seats or 0)) end

local function emit(t, name, data) t.events[#t.events + 1] = { name = name, data = data } end

local function somebodyGetsOffAt(t, i)
  for _, d in ipairs(t.onboard) do if d == i then return true end end
  return false
end

local function stepCup(c, dt, s)
  local drive = (s.aLat or 0) + 0.6 * (s.aLong or 0)
  local n = math.max(1, math.ceil(dt / 0.02))
  local h = dt / n
  for _ = 1, n do
    local acc = -CUP_W * CUP_W * c.cup - 2 * CUP_ZETA * CUP_W * c.cupV + CUP_W * CUP_W * CUP_GAIN * drive
    c.cupV = c.cupV + acc * h
    c.cup = c.cup + c.cupV * h
    if c.cup > 1 then c.cup, c.cupV = 1, math.min(0, c.cupV) elseif c.cup < -1 then c.cup, c.cupV = -1, math.max(0, c.cupV) end
  end
end

-- Every frame, after the trip's own update (dt s, s = the bus sample)
function M.update(t, dt, s)
  if t.finished or not t.onboard then return end
  local c = state(t)
  -- the bell: a passenger for the next stop asks for it once the stop is near (never for the terminus: everybody gets off there)
  if wants(t, 'ledBoard') and t.phase == 'approach' and c.bellIdx ~= t.idx and t.idx < #t.route.stops
    and (t.dist or math.huge) <= M.BELL_M and somebodyGetsOffAt(t, t.idx) then
    c.bellIdx = t.idx
    c.bellSeq = c.bellSeq + 1
    emit(t, 'bell', { index = t.idx })
  end
  if not wants(t, 'liveComfort') then return end
  stepCup(c, math.min(dt, 0.25), s)
  -- a hard brake with people standing: somebody falls
  local limit = scoring.LIMITS.longitudinal * M.FALL_FACTOR * ((t.score and t.score.k) or 1)
  if M.standing(t) > 0 and (s.speed or 0) >= M.FALL_MIN_SPEED and (s.aLong or 0) < -limit and t.elapsed - c.lastFall >= M.FALL_GAP_S then
    c.lastFall = t.elapsed
    c.falls = c.falls + 1
    c.fallSeq = c.fallSeq + 1
    scoring.fall(t.score)
    emit(t, 'fell', { standing = M.standing(t) })
  end
end

-- The numbers the HUD shows (the HUD hides what it does not get: an option turned off leaves its part out)
function M.hud(t)
  local c = state(t)
  local out = {}
  if wants(t, 'liveComfort') then
    out.comfort = { standing = M.standing(t), seats = t.seats or 0, cup = math.floor(c.cup * M.CUP_MAX_DEG * 10 + 0.5) / 10,
      spill = math.abs(c.cup) > 0.85, falls = c.falls, fallSeq = c.fallSeq }
  end
  if wants(t, 'ledBoard') then
    local stop = t.route.stops[t.idx]
    if stop then
      local requested = c.bellIdx == t.idx
      -- waiting at the first stop for the scheduled departure (the trip began early on purpose): how long is left
      local wait
      if t.waitStart and t.entry and t.departedStops == 0 and (t.phase == 'atStop' or t.phase == 'start') then
        wait = t.entry.trip.start + (t.entry.trip.dep[t.idx] or 0) - t.clock
      end
      out.led = {
        stop = stop.name, line = t.route.ref, dest = t.route.to or t.route.name,
        onRequest = stop.onRequest == true and not requested, requested = requested, bellSeq = c.bellSeq,
        last = t.idx == #t.route.stops, here = t.phase == 'atStop' or t.phase == 'start',
        waitSec = (wait and wait > 0) and math.floor(wait + 0.5) or nil,
      }
    end
  end
  return out
end

return M
