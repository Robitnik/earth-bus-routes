-- The stop announcer: informer.lua (when to speak) and voice.lua (how the clips are fetched and played in turn).
local H = dofile('tests/harness.lua')
local osm = require('earthBusRoutes/osm')
local geo = require('earthBusRoutes/geomath')
local sched = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local informer = require('earthBusRoutes/informer')
local voice = require('earthBusRoutes/voice')
local T = {}

local function route() return assert(osm.parseRoute(H.fixture('route_6964117'))) end

local function newTrip(r)
  local trips = sched.generate(r, 2)
  local d = sched.departures(trips, 1, 8 * 3600, 1)[1]
  local entry = { trip = d.trip, at = d.at }
  return trip.new({ route = r, trips = trips, entry = entry, startIndex = 1, day = 2, clock = sched.scheduled(entry.trip, 1),
    opts = { density = 'high' } })
end

local Sim = {}
Sim.__index = Sim
local function sim(t, r) return setmetatable({ t = t, r = r, along = r.stops[t.startIndex].along or 0, say = {} }, Sim) end
function Sim:frame(speed, doors)
  local lat, lon = geo.pointAt(self.r.path, self.r.cum, self.along)
  self.along = self.along + speed * 0.1
  trip.update(self.t, 0.1, { lat = lat, lon = lon, speed = speed, doorsOpen = doors, aLong = 0.4, aLat = 0.4 })
  for _, e in ipairs(trip.takeEvents(self.t)) do
    if e.name == 'say' then self.say[#self.say + 1] = { kind = e.data.kind, index = e.data.index, along = self.along, name = e.data.stop.name } end
  end
end
function Sim:dwell(secs)
  for _ = 1, math.floor(secs * 10) do self:frame(0, true) end
  for _ = 1, 15 do self:frame(0, false) end
end
function Sim:driveTo(target, v)
  while self.along < target - 0.5 do
    local left = target - self.along
    local sp = math.min(v, math.max(0.5, v * left / 40), left * 10 + 0.1)
    if left > 40 then sp = math.min(v, left * 10 + 0.1) end
    self:frame(sp, false)
  end
  self.along = target
  self:frame(0, false)
end

local function drive(r, t, upTo)
  local s = sim(t, r)
  for i = t.startIndex, upTo or #r.stops do
    if i > t.startIndex then s:driveTo(r.stops[i].along, 9) end
    local guard = 0
    s:dwell(10)
    while ((t.alightLeft or 0) > 0 or (t.boardLeft or 0) > 0) and guard < 60 do s:dwell(5) guard = guard + 1 end
  end
  return s
end

function T.the_next_stop_is_told_when_the_doors_close_and_the_stop_when_it_is_near()
  informer.enabled = true
  local r = route()
  local t = newTrip(r)
  local s = drive(r, t, 4)
  local byIndex = {}
  for _, e in ipairs(s.say) do byIndex[e.index] = byIndex[e.index] or {} table.insert(byIndex[e.index], e) end
  for i = 2, 4 do
    local list = byIndex[i]
    assert(list and #list >= 1, 'nothing said for stop ' .. i)
    assert(list[1].kind == 'next', 'stop ' .. i .. ' is told as the next one first: ' .. list[1].kind)
    assert(#list <= 2, 'stop ' .. i .. ' told ' .. #list .. ' times')
  end
  -- the 'next' of stop 2 comes while the bus still stands at stop 1
  assert(byIndex[2][1].along <= r.stops[1].along + 5, 'told at ' .. byIndex[2][1].along)
end

function T.a_stop_is_told_100_m_before_it_unless_it_was_just_told_as_the_next_one()
  informer.enabled = true
  local r = route()
  local t = newTrip(r)
  local s = drive(r, t, #r.stops)
  local at = {}
  for _, e in ipairs(s.say) do if e.kind == 'at' or e.kind == 'end' then at[e.index] = e end end
  local count = 0
  for i = 2, #r.stops do
    local e = at[i]
    if e then
      count = count + 1
      local d = r.stops[i].along - e.along
      assert(d <= informer.AT_M + 12 and d >= 0, 'stop ' .. i .. ' told ' .. d .. ' m before it')
    end
  end
  assert(count >= 1, 'no stop was told when near')
  local last = at[#r.stops]
  assert(last == nil or last.kind == 'end', 'the terminus is told as "end"')
  local lastNext
  for _, e in ipairs(s.say) do if e.index == #r.stops and e.kind ~= 'at' and e.kind ~= 'end' then lastNext = e.kind end end
  assert(lastNext == 'nextEnd', 'the terminus as the next one: ' .. tostring(lastNext))
end

function T.the_players_switch_silences_it()
  informer.enabled = false
  local r = route()
  local t = newTrip(r)
  local s = drive(r, t, 3)
  informer.enabled = true
  assert(#s.say == 0, 'said ' .. #s.say)
end

-- ---- voice.lua --------------------------------------------------------------------------------------------------------

local function voiceSetup()
  H.reset()
  local d = { calls = {}, played = {}, toasts = {}, saved = nil }
  voice.on = true
  voice.deps.has = function() return true end
  voice.deps.uiLang = function() return 'uk' end
  voice.deps.toast = function(k) d.toasts[#d.toasts + 1] = k end
  voice.deps.play = function(p) d.played[#d.played + 1] = p return true end
  voice.deps.write = function(_, v) d.saved = v end
  d.files = {}
  voice.deps.exists = function(p) return d.files[p] ~= nil end
  voice.deps.save = function(p, b) d.files[p] = b return true end
  d.state = 'ready'
  voice.deps.get = function(path, cb)
    d.calls[#d.calls + 1] = { path = path, cb = cb }
    if path:find('/v1/voice', 1, true) then cb({ state = d.state, lang = 'uk' }) end
  end
  local r = route()
  d.trip = newTrip(r)
  d.stop = r.stops[2]
  return d
end

local function wav(id, secs) return { body = string.rep('x', 100), headers = { ['x-clip'] = id, ['x-seconds'] = tostring(secs) } } end

local function ev(d, kind, i) return { kind = kind, index = i or 2, stop = d.stop, request = false } end

function T.a_clip_is_asked_for_and_played_when_the_voice_is_ready()
  local d = voiceSetup()
  voice.begin(d.trip)
  assert(voice.ready())
  voice.say(ev(d, 'next'))
  local c = d.calls[#d.calls]
  assert(c.path:find('/v1/say?kind=next', 1, true), c.path)
  assert(c.path:find('&ui=uk', 1, true) and c.path:find('&lat=', 1, true), c.path)
  voice.frame(0.1)
  assert(#d.played == 0, 'nothing to play before the clip is there')
  c.cb(wav('a1', 3))
  voice.frame(0.1)
  assert(d.played[1] == '/temp/earthBusRoutes/voice/a1.wav', tostring(d.played[1]))
  assert(d.files['/temp/earthBusRoutes/voice/a1.wav'], 'the clip is written into the game folder')
  voice.stop()
end

function T.clips_play_one_after_the_other_not_over_each_other()
  local d = voiceSetup()
  voice.begin(d.trip)
  voice.say(ev(d, 'next'))
  voice.say(ev(d, 'at'))
  d.calls[#d.calls - 1].cb(wav('one', 2))
  d.calls[#d.calls].cb(wav('two', 2))
  voice.frame(0.1)
  assert(#d.played == 1 and d.played[1]:find('one.wav', 1, true))
  for _ = 1, 10 do voice.frame(0.1) end
  assert(#d.played == 1, 'the first still speaks')
  for _ = 1, 15 do voice.frame(0.1) end
  assert(#d.played == 2 and d.played[2]:find('two.wav', 1, true), #d.played)
  voice.stop()
end

function T.a_sentence_that_came_too_late_is_dropped()
  local d = voiceSetup()
  voice.begin(d.trip)
  voice.say(ev(d, 'next'))
  for _ = 1, 130 do voice.frame(0.1) end
  d.calls[#d.calls].cb(wav('late', 2))
  voice.frame(0.1)
  assert(#d.played == 0, 'a stale sentence was spoken')
  voice.stop()
end

function T.no_voice_no_sound_and_the_download_is_asked_about_until_ready()
  local d = voiceSetup()
  d.state = 'downloading'
  voice.begin(d.trip)
  assert(not voice.ready() and d.toasts[1] == 'voiceLoading')
  voice.say(ev(d, 'next'))
  for _, c in ipairs(d.calls) do assert(not c.path:find('/v1/say', 1, true), 'nothing is said without a voice') end
  local n = #d.calls
  for _ = 1, 70 do voice.frame(0.1) end
  assert(#d.calls > n, 'asked how far the voice is')
  d.state = 'ready'
  for _ = 1, 70 do voice.frame(0.1) end
  assert(voice.ready())
  local m = #d.calls
  for _ = 1, 100 do voice.frame(0.1) end
  assert(#d.calls == m, 'no more asking once ready')
  assert(#d.toasts == 1, 'one toast')
  voice.stop()
end

function T.an_old_service_or_the_switch_off_asks_for_nothing()
  local d = voiceSetup()
  voice.deps.has = function() return false end
  voice.begin(d.trip)
  voice.say(ev(d, 'next'))
  assert(#d.calls == 0)
  voice.deps.has = function() return true end
  voice.on = true
  assert(voice.setOn(false) and d.saved.on == false)
  voice.begin(d.trip)
  voice.say(ev(d, 'next'))
  assert(#d.calls == 0)
  voice.on = true
  voice.stop()
end

-- 2026-11-18, seen in the game: the game reads no file outside its folders; the clip comes as bytes and is written into /temp
function T.a_clip_already_in_the_game_folder_is_not_written_again_and_a_failed_answer_is_silence()
  local d = voiceSetup()
  voice.begin(d.trip)
  d.files['/temp/earthBusRoutes/voice/same.wav'] = 'old'
  voice.say(ev(d, 'next'))
  d.calls[#d.calls].cb(wav('same', 2))
  assert(d.files['/temp/earthBusRoutes/voice/same.wav'] == 'old')
  voice.frame(0.1)
  assert(#d.played == 1)
  voice.say(ev(d, 'at'))
  d.calls[#d.calls].cb(nil, { error = 'voice missing' })
  for _ = 1, 40 do voice.frame(0.1) end
  assert(#d.played == 1, 'nothing played for a failed clip')
  voice.stop()
end

return T
