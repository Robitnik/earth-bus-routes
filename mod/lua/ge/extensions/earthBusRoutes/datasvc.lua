-- Client of the Earth Bus Routes data service (companion/bus_routes_data.py), the program that asks OpenStreetMap for us.
-- The game's Lua sandbox only allows connections to this computer, so every request goes to 127.0.0.1. Up to M.LANES requests
-- run at once (the service asks the public servers one at a time itself, and answers what it has on disk meanwhile: a slow
-- Overpass request must not hold up the map of towns or the stops round you); nothing waits: M.update(dt) is called every frame.
local http = require('earthBusRoutes/http')
local M = {}

M.HOST = '127.0.0.1'
M.PORT = 47630
M.RETRY_S = 6                -- after the service did not answer, ask again this much later
M.TOTAL_S = 240              -- the service tries several public servers, each can take 45 s
M.CONNECT_TRIES = 2          -- a refused connection is retried this often before the callbacks hear "service down"
M.LANES = 3                  -- requests running at once

local queue, actives = {}, {}
local fastQueue, fastActive = {}, nil      -- the second lane: answers the service has at once (its index), never behind a slow request
local wait = 0
local memo = {}              -- path -> decoded data, for this game session
M.state = { up = nil, error = nil, version = nil, lastDown = nil, features = nil, progress = nil }
M.onProgress = nil           -- called when what the service is busy with changes (the menu shows it)
local pollTimer = 0
M.watching = false           -- the menu is open: ask what the service is busy with even when no request of ours is waiting
local idleTimer = 0

local function finish(job, data, info)
  for _, cb in ipairs(job.cbs) do pcall(cb, data, info) end
end

-- GET `path`; cb(data, info) with info = { cached = bool } or cb(nil, { error = text, down = bool })
-- opts: fresh (skip the memo), low (a background prefetch: an urgent request may cancel it), urgent (goes first),
-- total (seconds to wait for the answer)
function M.get(path, cb, opts)
  opts = opts or {}
  if opts.fast then
    for _, j in ipairs(fastQueue) do if j.path == path then j.cbs[#j.cbs + 1] = cb return end end
    fastQueue[#fastQueue + 1] = { path = path, cbs = { cb }, tries = 1, total = opts.total or 15 }
    return
  end
  if memo[path] and not opts.fresh then cb(memo[path].data, { cached = true, memo = true }) return end
  for _, j in ipairs(queue) do
    if j.path == path then
      j.cbs[#j.cbs + 1] = cb
      if opts.urgent then j.low = false end
      return
    end
  end
  for _, a in ipairs(actives) do
    if a.job.path == path then a.job.cbs[#a.job.cbs + 1] = cb return end
  end
  local job = { path = path, cbs = { cb }, tries = 0, low = opts.low or false, total = opts.total }
  if opts.urgent then
    table.insert(queue, 1, job)
    -- every lane busy: a prefetch nobody waits for gives way
    if #actives >= M.LANES then
      for i, a in ipairs(actives) do
        if a.job.low and #a.job.cbs <= 1 then
          http.cancel(a.req)
          table.remove(actives, i)
          a.job.tries = 0
          queue[#queue + 1] = a.job
          break
        end
      end
    end
  else
    queue[#queue + 1] = job
  end
end

-- Does the running service know this feature ('path', 'along', 'search', 'stations')? nil = not known yet.
function M.has(feature)
  local f = M.state.features
  if not f then return nil end
  return f[feature] == true
end

-- how: 'low' (background prefetch) | 'urgent' (somebody waits) | nil
function M.nearby(lat, lon, cb, how)
  M.get(('/v1/nearby?lat=%.5f&lon=%.5f'):format(lat, lon), cb, { low = how == 'low', urgent = how == 'urgent' })
end
function M.path(pts, cb) M.get('/v1/path?pts=' .. pts, cb, { urgent = true, total = 60 }) end
function M.along(pts, cb) M.get('/v1/along?pts=' .. pts, cb, { urgent = true }) end
function M.stations(lat, lon, cb) M.get(('/v1/stations?lat=%.4f&lon=%.4f'):format(lat, lon), cb, { urgent = true, total = 120 }) end
-- fast: only what the service already knows, answered at once (on the second lane); else it asks the public servers
function M.search(q, lat, lon, cb, fast)
  local path = ('/v1/search?q=%s&lat=%.4f&lon=%.4f'):format(http.urlencode(q), lat, lon)
  if fast then M.get(path .. '&local=1', cb, { fast = true }) else M.get(path, cb, { urgent = true, total = 120 }) end
end
-- the bus lines with this number near a point
function M.lines(ref, lat, lon, cb, fast)
  local path = ('/v1/lines?ref=%s&lat=%.4f&lon=%.4f'):format(http.urlencode(ref), lat, lon)
  if fast then M.get(path .. '&local=1', cb, { fast = true }) else M.get(path, cb, { urgent = true, total = 120 }) end
end
-- the cities, towns and villages round a point (the map of towns)
function M.towns(lat, lon, cb) M.get(('/v1/towns?lat=%.4f&lon=%.4f'):format(lat, lon), cb, { urgent = true, total = 120 }) end
-- low: a background load (the virtual bus network): an urgent request of the player may cancel it
function M.route(id, cb, low) M.get(('/v1/route?id=%d'):format(id), cb, low and { low = true } or nil) end
-- a route only if the service has it on this computer (never a request to a public server; service 0.10.1+): for the
-- background loads, which must not queue in front of what the player asked for
function M.routeKept(id, cb) M.get(('/v1/route?id=%d&cached=1'):format(id), cb, { fast = true, total = 10 }) end
-- the stations and stops within r metres for the map (from the service's own data: at once, on the second lane)
function M.mapStops(lat, lon, r, cb) M.get(('/v1/mapstops?lat=%.4f&lon=%.4f&r=%d'):format(lat, lon, r), cb, { fast = true, total = 10 }) end
function M.ping(cb) M.get('/v1/info', cb, { fast = true }) end
-- shifts (plan 006 B): the real trips that follow a timetable trip at its terminus; the depot (or a bus station) near a point
function M.shift(pid, start, day, mins, cb)
  M.get(('/v1/shift?pid=%d&start=%d&day=%d&mins=%d'):format(math.floor(pid), math.floor(start), math.floor(day), math.floor(mins)), cb, { urgent = true, total = 30 })
end
function M.depot(lat, lon, cb) M.get(('/v1/depot?lat=%.4f&lon=%.4f'):format(lat, lon), cb, { urgent = true, total = 120 }) end
-- the lines arriving at the stop at (lat, lon) within a few minutes of `t` (s from midnight) on weekday `day`, `ref` left out
-- (transfers: from the service's timetables, answered at once)
function M.connections(lat, lon, t, day, ref, cb)
  local path = ('/v1/connections?lat=%.5f&lon=%.5f&t=%d&day=%d&win=8'):format(lat, lon, t, day)
  if ref and ref ~= '' then path = path .. '&ref=' .. http.urlencode(tostring(ref)) end
  M.get(path, cb, { fast = true, total = 10 })
end

-- the trips of the timetables that call within r metres of a point between t - 5 min and t + mins (t: s from midnight, day: 1 Monday
-- .. 7 Sunday): { patterns = { {pid, id, ref, head, from, to, offs} }, trips = { {pid, start} } } (plan 007: the virtual buses)
function M.departures(lat, lon, t, day, mins, cb)
  local path = ('/v1/departures?lat=%.4f&lon=%.4f&r=3000&t=%d&day=%d&mins=%d'):format(lat, lon, math.floor(t), math.floor(day), math.floor(mins or 30))
  M.get(path, cb, { fast = true, total = 10 })
end

local function startNext()
  local job = table.remove(queue, 1)
  if not job then return end
  job.tries = job.tries + 1
  local ok, req = pcall(http.start, { host = M.HOST, port = M.PORT, method = 'GET', path = job.path, connectTimeout = 3, totalTimeout = job.total or M.TOTAL_S })
  if not ok then req = { state = 'error', err = tostring(req) } end
  actives[#actives + 1] = { job = job, req = req }
end

local function failed(job, err, down)
  M.state.up, M.state.error = false, err
  if down then
    M.state.lastDown = os.time()
    if job.tries < M.CONNECT_TRIES then wait = M.RETRY_S table.insert(queue, 1, job) return end
  end
  finish(job, nil, { error = err, down = down or false })
end

-- the second lane: no retries, no memo (the service's index grows)
-- what a service answer says about the service (version, features)
local function learn(data)
  if data.version then M.state.version = data.version end
  if type(data.features) == 'table' then
    M.state.features = {}
    for _, f in ipairs(data.features) do M.state.features[f] = true end
  end
end

local function updateFast(dt)
  if not fastActive then
    local job = table.remove(fastQueue, 1)
    if not job then return end
    local ok, req = pcall(http.start, { host = M.HOST, port = M.PORT, method = 'GET', path = job.path, connectTimeout = 2, totalTimeout = job.total })
    if not ok then req = { state = 'error', err = tostring(req) } end
    fastActive = { job = job, req = req }
  end
  local req = fastActive.req
  http.step(req, dt)
  if req.state == 'done' then
    local job = fastActive.job
    fastActive = nil
    local ok, data = pcall(jsonDecode, http.body(req.parser))
    if not ok or type(data) ~= 'table' or data.ok == false then
      finish(job, nil, { error = (type(data) == 'table' and data.error) or 'bad answer from the data service', down = false })
    else
      M.state.up = true
      learn(data)
      finish(job, data.data or data, { cached = true, fast = true })
    end
  elseif req.state == 'error' then
    local job = fastActive.job
    fastActive = nil
    local err = tostring(req.err)
    finish(job, nil, { error = err, down = err:find('connect', 1, true) ~= nil })
  end
end

-- while a slow request runs: what the service is doing, once a second, for the progress line
local function pollProgress(dt)
  pollTimer = pollTimer + dt
  if pollTimer < 1 then return end
  pollTimer = 0
  if #actives == 0 then
    -- nothing of ours is waiting; the service may still be downloading the timetables (a minute, once): look every 3 s
    -- while the menu is open
    idleTimer = idleTimer + 1
    if not M.watching or idleTimer < 3 then
      if not M.watching and M.state.progress ~= nil then
        M.state.progress = nil
        if M.onProgress then pcall(M.onProgress) end
      end
      return
    end
    idleTimer = 0
  end
  if M.has('progress') ~= true then return end
  M.get('/v1/progress', function(data)
    if not data then return end
    local before = M.state.progress
    M.state.progress = (data.busy and #data.busy > 0) and data or nil
    if M.onProgress and (before ~= nil or M.state.progress ~= nil) then pcall(M.onProgress) end
  end, { fast = true, total = 3 })
end

local function settle(a)
  local req, job = a.req, a.job
  if req.state == 'done' then
    local text = http.body(req.parser)
    local ok, data = pcall(jsonDecode, text)
    if not ok or type(data) ~= 'table' then return failed(job, 'bad answer from the data service', false) end
    if data.ok == false then
      M.state.up = true
      return failed(job, tostring(data.error or ('HTTP ' .. tostring(req.status))), false)
    end
    M.state.up, M.state.error = true, nil
    learn(data)
    local payload = data.data or data
    -- (an answer marked partial has the timetables only, the map's part is still coming: not kept for the session)
    if job.path:find('/v1/info', 1, true) == nil and not (type(payload) == 'table' and payload.partial) then memo[job.path] = { data = payload } end
    finish(job, payload, { cached = data.cached == true })
  else
    local err = tostring(req.err)
    -- refused / unreachable: the service is not running; anything else is a broken answer or a timeout
    failed(job, err, err:find('connect', 1, true) ~= nil)
  end
end

function M.update(dt)
  updateFast(dt)
  pollProgress(dt)
  local i = 1
  while i <= #actives do
    local a = actives[i]
    http.step(a.req, dt)
    if a.req.state == 'done' or a.req.state == 'error' then
      table.remove(actives, i)
      settle(a)
    else
      i = i + 1
    end
  end
  if wait > 0 then wait = wait - dt return end
  while #actives < M.LANES and #queue > 0 do startNext() end
end

function M.busy() return #actives > 0 or #queue > 0 end

function M.reset()
  for _, a in ipairs(actives) do if a.req then http.cancel(a.req) end end
  if fastActive and fastActive.req then http.cancel(fastActive.req) end
  queue, actives, wait, fastQueue, fastActive = {}, {}, 0, {}, nil
  M.state.progress = nil
end

function M.forget() memo = {} end

return M
