-- Client of the Earth Bus Routes data service (companion/bus_routes_data.py), the program that asks OpenStreetMap for us.
-- The game's Lua sandbox only allows connections to this computer, so every request goes to 127.0.0.1. One request runs at
-- a time, nothing waits: M.update(dt) is called every frame.
local http = require('earthBusRoutes/http')
local M = {}

M.HOST = '127.0.0.1'
M.PORT = 47630
M.RETRY_S = 6                -- after the service did not answer, ask again this much later
M.TOTAL_S = 240              -- the service tries several public servers, each can take 45 s
M.CONNECT_TRIES = 2          -- a refused connection is retried this often before the callbacks hear "service down"

local queue, active = {}, nil
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
  if active and active.job.path == path then active.job.cbs[#active.job.cbs + 1] = cb return end
  local job = { path = path, cbs = { cb }, tries = 0, low = opts.low or false, total = opts.total }
  if opts.urgent then
    table.insert(queue, 1, job)
    -- a prefetch nobody waits for gives way
    if active and active.job.low and #active.job.cbs <= 1 then
      http.cancel(active.req)
      local old = active.job
      active = nil
      old.tries = 0
      queue[#queue + 1] = old
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
function M.route(id, cb) M.get(('/v1/route?id=%d'):format(id), cb) end
function M.ping(cb) M.get('/v1/info', cb, { fast = true }) end

local function startNext()
  local job = table.remove(queue, 1)
  if not job then return end
  job.tries = job.tries + 1
  local ok, req = pcall(http.start, { host = M.HOST, port = M.PORT, method = 'GET', path = job.path, connectTimeout = 3, totalTimeout = job.total or M.TOTAL_S })
  if not ok then req = { state = 'error', err = tostring(req) } end
  active = { job = job, req = req }
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
  if active == nil then
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

function M.update(dt)
  updateFast(dt)
  pollProgress(dt)
  if wait > 0 then wait = wait - dt return end
  if not active then startNext() if not active then return end end
  local req = active.req
  http.step(req, dt)
  if req.state == 'done' then
    local job = active.job
    active = nil
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
  elseif req.state == 'error' then
    local job = active.job
    active = nil
    local err = tostring(req.err)
    -- refused / unreachable: the service is not running; anything else is a broken answer or a timeout
    failed(job, err, err:find('connect', 1, true) ~= nil)
  end
end

function M.busy() return active ~= nil or #queue > 0 end

function M.reset()
  if active and active.req then http.cancel(active.req) end
  if fastActive and fastActive.req then http.cancel(fastActive.req) end
  queue, active, wait, fastQueue, fastActive = {}, nil, 0, {}, nil
  M.state.progress = nil
end

function M.forget() memo = {} end

return M
