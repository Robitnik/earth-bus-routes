-- The voice of the stop announcer: takes informer.lua's 'say' events, asks the data service for the clip (the service speaks it
-- on this computer with an offline voice of the country's language, voice downloads included), plays the clips one after the
-- other through the game's intercom channel. Never an error for the trip: no service, no voice, no file = silence.
local M = {}
local TAG = 'earthBusRoutes'

M.PREFS_PATH = '/settings/earthBusRoutes/voice.json'
M.TTL_S = 12               -- a sentence not spoken this long after it was due is dropped (the bus has moved on)
M.GAP_S = 0.25             -- between two clips
M.QUEUE_MAX = 3
M.ASK_AGAIN_S = 6          -- while the voice downloads: ask how far it is this often (the service stops when we stop asking)

M.on = true
local S = { trip = nil, queue = {}, busyUntil = 0, clock = 0, ask = 0, state = nil, told = {}, lang = nil }

-- the pieces the tests replace
M.deps = {
  get = function(path, cb, opts) return require('earthBusRoutes/datasvc').get(path, cb, opts) end,
  has = function(f) return require('earthBusRoutes/datasvc').has(f) end,
  play = function(path) return require('earthBusRoutes/world').playClip(path) end,
  toast = function(key) local w, t = require('earthBusRoutes/world'), require('earthBusRoutes/texts') w.toast(t.t(key), 5) end,
  uiLang = function() return require('earthBusRoutes/texts').lang() end,
  read = function(path) local r = rawget(_G, 'jsonReadFile') return r and r(path) or nil end,
  write = function(path, t) local w = rawget(_G, 'jsonWriteFile') if w then w(path, t, true) end end,
}

local function enc(s) return require('earthBusRoutes/http').urlencode(tostring(s)) end

function M.load()
  local ok, d = pcall(M.deps.read, M.PREFS_PATH)
  if ok and type(d) == 'table' and type(d.on) == 'boolean' then M.on = d.on end
end

function M.setOn(on)
  on = on == true
  if on == M.on then return false end
  M.on = on
  pcall(M.deps.write, M.PREFS_PATH, { format = 1, on = on })
  if not on then M.clear() end
  return true
end

function M.supported() return M.deps.has('voice') == true end
function M.ready() return S.state == 'ready' end
function M.status() return S.state end

local function where(stop)
  local t = S.trip
  local info = t and t.route and t.route.limitInfo
  local q = ('&lat=%.5f&lon=%.5f&ui=%s'):format(stop.lat or 0, stop.lon or 0, enc(M.deps.uiLang() or 'en'))
  if info and info.cc then q = q .. '&cc=' .. enc(info.cc) end
  return q
end

-- Asks how the language's voice is doing (and, at the first ask, starts its download). Once ready, never again in this trip.
local function prepare()
  local t = S.trip
  if not t or S.state == 'ready' or S.asking then return end
  local stop = t.route.stops[math.max(1, t.idx or 1)] or t.route.stops[1]
  if not stop then return end
  S.asking = true
  M.deps.get('/v1/voice?x=1' .. where(stop), function(data)
    S.asking = false
    if S.trip ~= t then return end
    S.state = data and data.state or 'failed'
    S.lang = data and data.lang or S.lang
    if S.state == 'downloading' and not S.told.loading then S.told.loading = true pcall(M.deps.toast, 'voiceLoading') end
    if S.state == 'failed' and not S.told.failed then S.told.failed = true pcall(M.deps.toast, 'voiceFailed') end
  end, { fast = true, total = 10 })
end

-- A trip begins: forget the last one, ask for the voice
function M.begin(t)
  S = { trip = t, queue = {}, busyUntil = 0, clock = 0, ask = 0, state = nil, told = {}, lang = nil }
  if not M.on or not M.supported() then return end
  prepare()
end

function M.clear() S.queue = {} end

function M.stop()
  S.trip, S.queue = nil, {}
end

-- A 'say' event of the informer: { kind, index, stop, request }
function M.say(data)
  local t = S.trip
  if not t or not M.on or not M.supported() or S.state == 'none' or S.state == 'unsupported' then return end
  if S.state ~= 'ready' then return end              -- nothing to say it with yet (the sentence would be stale when the voice comes)
  local e = { kind = data.kind, index = data.index, at = S.clock, clip = nil, failed = false }
  S.queue[#S.queue + 1] = e
  while #S.queue > M.QUEUE_MAX do table.remove(S.queue, 1) end
  local stop = data.stop
  local path = ('/v1/say?file=1&kind=%s&name=%s&req=%d'):format(enc(data.kind), enc(stop.name or ''), data.request and 1 or 0) .. where(stop)
  M.deps.get(path, function(clip, info)
    if clip and clip.path then e.clip = clip else e.failed = true end
  end, { fast = true, total = 10 })
end

function M.frame(dt)
  local t = S.trip
  if not t then return end
  S.clock = S.clock + dt
  if S.state ~= 'ready' and M.on and M.supported() and S.state ~= 'none' and S.state ~= 'unsupported' then
    S.ask = S.ask - dt
    if S.ask <= 0 then S.ask = M.ASK_AGAIN_S prepare() end
  end
  local q = S.queue
  while q[1] and (q[1].failed or S.clock - q[1].at > M.TTL_S) do table.remove(q, 1) end
  local head = q[1]
  if head and head.clip and S.clock >= S.busyUntil then
    table.remove(q, 1)
    local ok = pcall(M.deps.play, head.clip.path)
    if not ok then log('W', TAG, 'voice: the clip could not be played') end
    S.busyUntil = S.clock + (tonumber(head.clip.seconds) or 3) + M.GAP_S
  end
end

return M
