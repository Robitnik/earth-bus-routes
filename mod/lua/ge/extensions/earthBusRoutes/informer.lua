-- The stop announcer (informator): when the bus should say what. Pure logic, fed by trip.update every frame; it never touches
-- the game. It emits trip events { name = 'say', data = { kind, index, stop, request } } that main.lua hands to voice.lua.
--   kind 'at'      - the bus is AT_M before a stop (along the road; as the crow flies off it)
--   kind 'end'     - the same for the terminus
--   kind 'next'    - the doors closed at a stop: the stop after it
--   kind 'nextEnd' - the same when that stop is the terminus
-- Each is said once per stop. A stop the bus is told about on leaving the one before is not told again a moment later
-- when it is so near that AT_M is reached at once (stops a few dozen metres apart).
local M = {}

M.AT_M = 100              -- the stop is told this far before it
M.AFTER_NEXT_S = 15       -- ... unless 'next' told it less than this ago
M.enabled = true          -- the player's switch (voice.lua keeps it)

local function emit(t, data) t.events[#t.events + 1] = { name = 'say', data = data } end

local function state(t)
  if not t.inf then t.inf = { said = {}, openAt = nil, wasOpen = false, nextAt = {} } end
  return t.inf
end

-- metres to the stop ahead: along the road while the bus is on the route's line, else as the crow flies; nil once it is behind
local function ahead(t, stop)
  if t.off ~= nil and t.off <= 45 and stop.along and t.along then
    local d = stop.along - t.along
    if d < -10 then return nil end
    return math.max(0, d)
  end
  return t.dist
end

function M.step(t, dt, doorsOpen)
  if not M.enabled or t.finished then return end
  local s = state(t)
  local stops = t.route.stops
  local n = #stops
  -- the doors closed after they were open at a stop: the next one
  if doorsOpen and (t.phase == 'atStop' or t.phase == 'start') then s.openAt = t.idx end
  if s.wasOpen and not doorsOpen and s.openAt then
    local i = s.openAt + 1
    s.openAt = nil
    local stop = stops[i]
    if stop and not s.said[i] then
      s.said[i] = 'next'
      s.nextAt[i] = t.elapsed
      emit(t, { kind = i == n and 'nextEnd' or 'next', index = i, stop = stop, request = stop.onRequest == true })
    end
  end
  s.wasOpen = doorsOpen == true
  -- nearing the stop ahead
  if t.phase == 'approach' then
    local i = t.idx
    local stop = stops[i]
    if stop and s.said[i] ~= 'at' and t.dist then
      local d = ahead(t, stop)
      if d and d <= M.AT_M then
        local told = s.nextAt[i]
        s.said[i] = 'at'
        if not told or t.elapsed - told >= M.AFTER_NEXT_S then
          emit(t, { kind = i == n and 'end' or 'at', index = i, stop = stop, request = stop.onRequest == true })
        end
      end
    end
  end
end

return M
