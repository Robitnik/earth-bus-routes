-- The dispatcher: short radio messages to the driver and the random things that happen on a trip (a school group at a stop, a
-- wheelchair user, a crowd after a match, a stop out of service, "stop please!", a forgotten bag). Pure logic: trip.lua calls
-- plan / step / leave, and nothing here touches the game. Events are drawn once, when the trip begins, from a seed
-- (clock0 + the line), so a trip run twice meets the same events; at most one per EVENT_GAP_S of trip time.
-- The state lives on the trip: t.dispatch (messages, events) and t.extra[stopIndex] (what an event did to a stop).
local demand = require('earthBusRoutes/demand')
local scoring = require('earthBusRoutes/scoring')
local M = {}

M.EVENT_GAP_S = 600        -- at most one event per this much trip time
M.TTL_S = 8                -- a message stays on the HUD this long
M.QUEUE_MAX = 3
M.WHEEL_S = 15             -- a wheelchair user needs the doors open this long
M.BAG_S = 4                -- handing a bag in at the terminus: the doors open this long
M.BAG_WAIT_S = 20          -- the trip waits this long at the terminus for it
M.SPEED_M_S = 6.5          -- when there is no timetable: the pace the arrival times are guessed at
M.NEAR_M = 700             -- an event is announced when the bus is this near the stop (along the road, else as the crow flies)
M.CHANCE = { school = 0.85, crowd = 0.8, wheelchair = 0.10, closed = 0.05, request = 0.07, bag = 0.12 }

-- ---- the stop's surroundings, from its name (the data service gives no school / stadium tags yet) ----------------------------
-- Lua's lower() leaves non-ASCII letters alone, so the capitals of those are listed too.
local SCHOOL = { 'škol', 'Škol', 'zš', 'zŠ', 'ZŠ', 'Zš', 'gymn', 'Gymn', 'střední', 'Střední', 'učiliš', 'Učiliš', 'school', 'gimnaz', 'школ', 'Школ', 'гімназ', 'Гімназ', 'ліце', 'Ліце' }
local STADIUM = { 'stadion', 'Stadion', 'stadium', 'stadión', 'Stadión', 'arena', 'aréna', 'Aréna', 'sportovní hala', 'Sportovní hala', 'стадіон', 'Стадіон', 'арена', 'Арена' }

local function has(name, list)
  if type(name) ~= 'string' then return false end
  local low = name:lower()
  for _, k in ipairs(list) do
    if name:find(k, 1, true) or low:find(k, 1, true) then return true end
  end
  return false
end
function M.isSchool(stop, ctx, i) return (stop and (stop.school or has(stop.name, SCHOOL))) or (ctx and ctx.school and ctx.school[i]) or false end
function M.isStadium(stop, ctx, i) return (stop and (stop.stadium or has(stop.name, STADIUM))) or (ctx and ctx.stadium and ctx.stadium[i]) or false end

-- ---- messages ------------------------------------------------------------------------------------------------------------------

function M.new()
  return { events = {}, queue = {}, cur = nil, seq = 0, elapsed = 0 }
end

-- A message for the HUD: `key` names the text (the HUD translates it), `params` fill it in.
function M.say(t, key, params, kind)
  local d = t.dispatch
  if not d then return end
  d.seq = d.seq + 1
  local m = { key = key, params = params or {}, kind = kind or 'info', seq = d.seq }
  if not d.cur then m.at = d.elapsed d.cur = m return end
  d.queue[#d.queue + 1] = m
  if #d.queue > M.QUEUE_MAX then table.remove(d.queue, 1) end
end

-- What the HUD shows now: { key, params, kind, seq } or nil
function M.current(t)
  local c = t.dispatch and t.dispatch.cur
  if not c then return nil end
  return { key = c.key, params = c.params, kind = c.kind, seq = c.seq }
end

local function tick(t, dt)
  local d = t.dispatch
  d.elapsed = d.elapsed + dt
  if d.cur and d.elapsed - d.cur.at >= M.TTL_S then d.cur = nil end
  if not d.cur and #d.queue > 0 then
    d.cur = table.remove(d.queue, 1)
    d.cur.at = d.elapsed
  end
end

local function extraOf(t, i)
  t.extra[i] = t.extra[i] or {}
  return t.extra[i]
end

-- ---- planning ------------------------------------------------------------------------------------------------------------------

-- The events of a trip: o = { route, startIndex, day, clock0, eta = function(i) -> clock (s) at stop i, ctx, hard = bool }.
-- Returns { { kind, stop, eta, people, ... } } in the order of the stops.
function M.plan(o)
  local route = o.route
  local n = #route.stops
  local rand = demand.rng(demand.hashSeed(o.clock0 or 0, route.ref or route.id or '', 'dispatch'))
  local events, lastEta = {}, -math.huge
  local weekend = (o.day or 2) >= 6
  for i = (o.startIndex or 1) + 1, n do
    local stop = route.stops[i]
    local eta = o.eta(i)
    local hour = (eta / 3600) % 24
    local roll, pick = rand(), rand()
    if eta - lastEta >= M.EVENT_GAP_S then
      local kind
      if i < n and not weekend and M.isSchool(stop, o.ctx, i) and ((hour >= 7 and hour < 8.25) or (hour >= 13 and hour < 15)) then
        if roll < M.CHANCE.school then kind = 'school' end
      elseif i < n and M.isStadium(stop, o.ctx, i) and hour >= 17 and hour < 23 then
        if roll < M.CHANCE.crowd then kind = 'crowd' end
      end
      if not kind then
        if i == n then
          if roll < M.CHANCE.bag then kind = 'bag' end
        elseif i > (o.startIndex or 1) + 1 then
          -- the rare ones, one roll shared between them
          if roll < M.CHANCE.wheelchair then kind = 'wheelchair'
          elseif roll < M.CHANCE.wheelchair + M.CHANCE.closed then kind = 'closed'
          elseif roll < M.CHANCE.wheelchair + M.CHANCE.closed + M.CHANCE.request then kind = 'request' end
        end
      end
      if kind then
        local people
        if kind == 'school' then people = 8 + math.floor(pick * 8) elseif kind == 'crowd' then people = 20 + math.floor(pick * 36) end
        events[#events + 1] = { kind = kind, stop = i, eta = eta, people = people }
        lastEta = eta
      end
    end
  end
  return events
end

-- Called when the trip begins: draws the events (unless they are switched off)
function M.start(t, ctx, scheduled)
  t.dispatch = M.new()
  t.extra = {}
  if t.opts.events == false then return end
  local route = t.route
  local eta = function(i)
    local s = scheduled and scheduled(i)
    if s then return s end
    local from = (route.stops[t.startIndex] or {}).along or 0
    return t.clock0 + math.max(0, ((route.stops[i] or {}).along or 0) - from) / M.SPEED_M_S
  end
  t.dispatch.events = M.plan({ route = route, startIndex = t.startIndex, day = t.day, clock0 = t.clock0, eta = eta, ctx = ctx })
end

-- ---- what the events do to the trip (trip.lua asks) ----------------------------------------------------------------------------------

-- the crowd the stop gets when it is made (`n` is the normal one)
function M.adjustWaiting(t, i, n)
  local ex = t.extra and t.extra[i]
  if not ex then return n end
  if ex.closed then return 0 end
  if ex.double then n = n * 2 end
  return n + (ex.people or 0)
end

function M.closed(t, i) return (t.extra and t.extra[i] and t.extra[i].closed) or false end
function M.requested(t, i) return (t.extra and t.extra[i] and t.extra[i].request) or false end

-- may the trip end at the terminus now? (a forgotten bag waits there to be handed in)
function M.canFinish(t)
  local ex = t.extra and t.extra[#t.route.stops]
  return not (ex and ex.bag and not ex.bagDone)
end

-- how far the stop is: along the road while the bus is on it (a road driven out and back passes near stops it reaches much later),
-- else as the crow flies
function M.distTo(t, stop)
  if t.off ~= nil and stop.along then return math.abs(stop.along - t.along) end
  return t.dist
end
local near = M.distTo

local TEXT = { -- notes (English; the HUD and the menu translate them)
  helped = 'Wheelchair passenger helped', left = 'Wheelchair passenger left behind', bag = 'Bag handed in', served = 'Group served',
}

-- Every frame, after the trip has been updated
function M.step(t, dt, doorsOpen)
  if not t.dispatch then return end
  tick(t, dt)
  local n = #t.route.stops
  for _, e in ipairs(t.dispatch.events) do
    local i = e.stop
    local stop = t.route.stops[i]
    if not e.fired and t.idx == i and stop and t.phase == 'approach' then
      local d = near(t, stop)
      if d and d <= M.NEAR_M then
        local ex = extraOf(t, i)
        local name = stop.name or ''
        if e.kind == 'school' then
          ex.people = e.people ex.group = 'school'
          if t.waiting then t.waiting = t.waiting + e.people end
          M.say(t, 'school', { stop = name, n = e.people }, 'event')
          e.fired = true
        elseif e.kind == 'crowd' then
          ex.people, ex.double, ex.group = e.people, true, 'crowd'
          if t.waiting then t.waiting = t.waiting * 2 + e.people end
          M.say(t, 'crowd', { stop = name }, 'event')
          e.fired = true
        elseif e.kind == 'wheelchair' then
          ex.wheelchair, ex.wheelT = true, 0
          M.say(t, 'wheelchair', { stop = name, s = M.WHEEL_S }, 'event')
          e.fired = true
        elseif e.kind == 'closed' then
          ex.closed = true
          if t.waiting then t.waiting = 0 end
          M.say(t, 'closed', { stop = name }, 'event')
          e.fired = true
        elseif e.kind == 'request' then
          if d > 100 then
            ex.request = true
            M.say(t, 'request', { stop = name }, 'event')
          end
          e.fired = true                     -- too near to be a surprise: no event
        elseif e.kind == 'bag' then
          ex.bag = true
          M.say(t, 'bag', {}, 'event')
          e.fired = true
        end
        if e.fired then t.eventsDone = (t.eventsDone or 0) + 1 end
      end
    end
  end
  -- the things that need the bus standing at the stop with the doors open
  if t.phase == 'atStop' then
    local ex = t.extra[t.idx]
    if ex and ex.wheelchair and not ex.wheelDone and doorsOpen then
      ex.wheelT = ex.wheelT + dt
      if ex.wheelT >= M.WHEEL_S then
        ex.wheelDone = true
        scoring.adjust(t.score, TEXT.helped, { service = 0.03, comfort = 0.02 })
        M.say(t, 'wheelchairDone', {}, 'good')
      end
    end
    if ex and ex.bag and not ex.bagDone and t.idx == n then
      ex.bagWait = (ex.bagWait or 0) + dt
      if doorsOpen then ex.bagOpen = (ex.bagOpen or 0) + dt end
      if (ex.bagOpen or 0) >= M.BAG_S then
        ex.bagDone = true
        scoring.adjust(t.score, TEXT.bag, { service = 0.03 })
        M.say(t, 'bagDone', {}, 'good')
      elseif ex.bagWait >= M.BAG_WAIT_S then
        ex.bagDone = true                    -- the trip is not held any longer; no bonus
        M.say(t, 'bagLeft', {}, 'info')
      end
    end
  end
end

-- The bus leaves stop i (trip.lua calls it before the stop index moves on)
function M.leave(t, i)
  local ex = t.extra and t.extra[i]
  if not ex then return end
  if ex.wheelchair and not ex.wheelDone then
    ex.wheelDone = true
    scoring.adjust(t.score, TEXT.left, { service = -0.05, comfort = -0.03 })
  end
  if ex.group and not ex.paid then
    ex.paid = true
    -- the group got on (nobody was left behind): the extra people count for the service
    if (t.lastBoard or 0) >= (ex.people or 0) and (ex.people or 0) > 0 and (t.boardLeft or 0) <= 0 then
      scoring.adjust(t.score, TEXT.served, { service = 0.02 })
    end
  end
end

return M
