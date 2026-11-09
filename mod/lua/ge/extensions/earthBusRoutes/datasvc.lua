-- Client of the Earth Bus Routes data service (companion/bus_routes_data.py), the program that asks OpenStreetMap for us.
-- The game's Lua sandbox only allows connections to this computer, so every request goes to 127.0.0.1. One request runs at
-- a time, nothing waits: M.update(dt) is called every frame.
local http = require('earthBusRoutes/http')
local M = {}

M.HOST = '127.0.0.1'
M.PORT = 47630
M.RETRY_S = 6                -- after the service did not answer, ask again this much later
M.CONNECT_TRIES = 2          -- a refused connection is retried this often before the callbacks hear "service down"

local queue, active = {}, nil
local wait = 0
local memo = {}              -- path -> decoded data, for this game session
M.state = { up = nil, error = nil, version = nil, lastDown = nil }

local function finish(job, data, info)
  for _, cb in ipairs(job.cbs) do pcall(cb, data, info) end
end

-- GET `path`; cb(data, info) with info = { cached = bool } or cb(nil, { error = text, down = bool })
function M.get(path, cb, opts)
  if memo[path] and not (opts and opts.fresh) then cb(memo[path].data, { cached = true, memo = true }) return end
  for _, j in ipairs(queue) do
    if j.path == path then j.cbs[#j.cbs + 1] = cb return end
  end
  if active and active.job.path == path then active.job.cbs[#active.job.cbs + 1] = cb return end
  queue[#queue + 1] = { path = path, cbs = { cb }, tries = 0 }
end

function M.nearby(lat, lon, cb) M.get(('/v1/nearby?lat=%.5f&lon=%.5f'):format(lat, lon), cb) end
function M.route(id, cb) M.get(('/v1/route?id=%d'):format(id), cb) end
function M.ping(cb) M.get('/v1/info', cb, { fresh = true }) end

local function startNext()
  local job = table.remove(queue, 1)
  if not job then return end
  job.tries = job.tries + 1
  local ok, req = pcall(http.start, { host = M.HOST, port = M.PORT, method = 'GET', path = job.path, connectTimeout = 3 })
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

function M.update(dt)
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
    if data.version then M.state.version = data.version end
    local payload = data.data or data
    if job.path:find('/v1/info', 1, true) == nil then memo[job.path] = { data = payload } end
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
  queue, active, wait = {}, nil, 0
end

function M.forget() memo = {} end

return M
