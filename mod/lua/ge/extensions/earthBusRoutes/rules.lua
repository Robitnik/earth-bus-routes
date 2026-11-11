-- The driving rules of a trip (pure logic; the game's values come in through trip.update's sample):
--   * the indicator when pulling out of a stop: the one on the side of the traffic you join (left; right in countries that
--     drive on the left), lit at least SIGNAL_MIN_S within SIGNAL_WINDOW_S before the bus moves. A bus whose indicator values
--     never reach us (the names are unverified in the game) is not judged: the rule switches itself off.
--   * the speed limit of the road (speedlimit.lua) plus a tolerance.
-- Doors open while moving are scored by scoring.sample already; the HUD only shows a hint (trip.hud).
local speedlimit = require('earthBusRoutes/speedlimit')
local M = {}

M.SIGNAL_MIN_S = 1        -- the indicator must have been lit this long ...
M.SIGNAL_WINDOW_S = 5     -- ... and still be lit, or have gone out, no more than this long before the bus moves
M.BLINK_HOLD_S = 0.9      -- a flashing indicator reads 0 half of the time: lit while it was seen on within this long
M.TOLERANCE_KMH = 10      -- speeding is this much over the limit

-- opts = { on = bool (default true), left = left-hand traffic }
function M.new(opts)
  opts = opts or {}
  return {
    on = opts.on ~= false, left = opts.left == true,
    seen = false,                                -- any value of the indicators ever reached us
    lastOn = { L = nil, R = nil },               -- time the indicator was last read lit
    since = { L = nil, R = nil },                -- time it began to be lit (continuously)
    okAt = { L = nil, R = nil },                 -- last time it had been lit for SIGNAL_MIN_S
    over = false, limit = nil,
  }
end

-- the side of the indicator the rule wants
function M.side(r) return r.left and 'R' or 'L' end

local function lit(v)
  if v == nil then return nil end
  if type(v) == 'number' then return v > 0.5 end
  return v == true
end

-- Every frame: `now` (s, any steady clock) and the two indicators' values (nil: unknown)
function M.signals(r, now, sigL, sigR)
  if not r.on then return end
  for side, v in pairs({ L = lit(sigL), R = lit(sigR) }) do
    r.seen = true
    if v then r.lastOn[side] = now end
    local active = r.lastOn[side] ~= nil and (now - r.lastOn[side]) <= M.BLINK_HOLD_S
    if active then
      r.since[side] = r.since[side] or now
      if r.lastOn[side] - r.since[side] >= M.SIGNAL_MIN_S then r.okAt[side] = r.lastOn[side] end     -- (seen lit that long, not held)
    else
      r.since[side] = nil
    end
  end
end

-- Is the wanted indicator lit now
function M.signalOn(r)
  local s = M.side(r)
  return r.lastOn[s] ~= nil and r.since[s] ~= nil
end

-- The bus is about to pull out of a stop: true when the indicator was not used as it should be
function M.noSignal(r, now)
  if not r.on or not r.seen then return false end
  local at = r.okAt[M.side(r)]
  return not (at and now - at <= M.SIGNAL_WINDOW_S)
end

-- Speed (m/s) against the limit at `along` of the route: returns over (bool), limit (km/h or nil)
function M.speeding(r, route, along, off, speed)
  r.over, r.limit = false, nil
  if not r.on or off == nil then return false, nil end
  local limit = speedlimit.at(route, along)
  if not limit then return false, nil end
  r.limit = limit
  r.over = (speed or 0) * 3.6 > limit + M.TOLERANCE_KMH
  return r.over, limit
end

return M
