-- Earth Bus Routes: entry point (extension "earthBusRoutes_main").
-- Works only on top of BeamNG.Earth's modding API v1 (beamngEarth_api). The menu pages (ui/ui-vue/mods/earthBusRoutes) and
-- the HUD app (ui/modules/apps/EarthBusHud) are thin: they show what this module publishes with guihooks
-- ('EarthBusRoutesState' for the menu, 'EarthBusRoutesHud' for the HUD) and call the M.ui* functions below.
-- Pure logic lives in osm / schedule / demand / scoring / trip / menu (tested under lupa); everything that touches the game is
-- in world.lua and datasvc.lua.

local M = {}
local TAG = 'earthBusRoutes'
M.VERSION = '0.3.0'
-- Features of beamngEarth_api this mod needs (docs/ADDONS.md "Modding API v1").
M.NEEDS = { 'pose', 'place', 'teleport', 'gpsRoute', 'events', 'options' }
M.PREFETCH_MOVE_M = 250
M.START_NEAR_M = 80          -- already this near the start stop: no teleport
M.REVERSE_GAP_S = 300        -- the reverse trip leaves this long after the arrival

local datasvc = require('earthBusRoutes/datasvc')
local osm = require('earthBusRoutes/osm')
local schedule = require('earthBusRoutes/schedule')
local trip = require('earthBusRoutes/trip')
local menu = require('earthBusRoutes/menu')
local builder = require('earthBusRoutes/builder')
local world = require('earthBusRoutes/world')
local geo = require('earthBusRoutes/geomath')

local S = {
  earth = false, reason = 'not checked', warned = false,
  screen = 'nearby', loading = nil, err = nil,
  cell = nil,                 -- { stations, routes, model } for the cell the player is in
  sel = {},                   -- station (index), lines, routeId, mode, timeSec, dep, reversed
  routes = {}, trips = {}, reverseOf = {},
  trip = nil, starting = nil, result = nil, hudTimer = 0,
  opts = {}, prefetchAt = nil, prefetchTimer = 0, hudAsked = false,
  build = nil,                -- manual mode: { b = builder state, busy = {..}, cands, ... }
  saved = {}, customSer = {}, nextCustomId = -1,
}

local function earthApi() return rawget(_G, 'beamngEarth_api') end

local function readStats()
  local ok, st = pcall(jsonReadFile, '/settings/earthBusRoutes/stats.json')
  S.stats = (ok and type(st) == 'table') and { trips = st.trips or 0, passengers = st.passengers or 0, points = st.points or 0 } or nil
end

local function readOptions()
  readStats()
  local o = world.options()
  if next(o) ~= nil then S.opts = o end        -- Earth answers {} until its add-on list is loaded: keep what we had
  if tonumber(S.opts.dataPort) then datasvc.PORT = tonumber(S.opts.dataPort) end
end

-- true, or false + why. Pure: no side effects, so the tests can call it with stub APIs.
function M.checkEarth()
  local api = earthApi()
  if not api then return false, 'BeamNG.Earth is not installed' end
  local ok, major = pcall(api.version)
  if not ok or major ~= 1 then return false, 'BeamNG.Earth modding API v1 is required' end
  for _, name in ipairs(M.NEEDS) do
    if not api.has(name) then return false, 'BeamNG.Earth is too old (API feature "' .. name .. '" missing)' end
  end
  return true
end

local function refreshEarth()
  local ok, why = M.checkEarth()
  S.earth, S.reason = ok, why or 'ok'
  if not ok and not S.warned then
    S.warned = true
    log('W', TAG, 'Earth Bus Routes is idle: ' .. S.reason)
    world.toast('Earth Bus Routes needs BeamNG.Earth: ' .. S.reason, 6)
  end
  return ok
end

function M.status() return { version = M.VERSION, earth = S.earth, reason = S.reason, trip = S.trip ~= nil, screen = S.screen } end

-- ---- the menu model ------------------------------------------------------------------------------------------------

local function stationRef(i) return S.cell and S.cell.model and S.cell.model[i] and S.cell.model[i].ref end

local function startIndexFor(route)
  if S.sel.custom then
    local p = S.sel.mode ~= 'first' and world.pose() or nil
    if not p then return 1 end
    return (menu.nearestStopIndex(route, p.lat, p.lon))
  end
  local st = S.sel.station and stationRef(S.sel.station)
  if S.sel.mode == 'first' or not st then return 1 end
  return (menu.nearestStopIndex(route, st.lat, st.lon))
end

local function currentRoute() return S.sel.routeId and S.routes[S.sel.routeId] or nil end

local function currentTrips(route)
  local c = S.trips[route.id]
  local day = world.weekday()
  if not c or c.day ~= day then
    local ctx = { busy = (S.sel.lines and #S.sel.lines >= 4) or false }
    c = { day = day, trips = schedule.generate(route, day, ctx), ctx = ctx }
    S.trips[route.id] = c
  end
  return c
end

local function buildModel()
  local pose = world.pose()
  local model = {
    version = M.VERSION, earth = S.earth, reason = S.reason, screen = S.screen, loading = S.loading, error = S.err,
    service = { up = datasvc.state.up, error = datasvc.state.error, version = datasvc.state.version, port = datasvc.PORT },
    pos = pose and { lat = pose.lat, lon = pose.lon } or nil, place = world.place(),
    units = S.opts.units or 'km/h', day = world.weekday(), nowSec = world.nowSec(),
    tripActive = S.trip ~= nil, starting = S.starting ~= nil,
    mapCredit = '© OpenStreetMap contributors',
  }
  if S.cell and S.cell.model then
    local list = {}
    for i, st in ipairs(S.cell.model) do
      list[i] = { id = st.id, name = st.name, dist = st.dist, dir = st.dir, station = st.station, platforms = st.platforms,
        lines = st.lines, lineCount = st.lineCount }
    end
    model.stations = list
  end
  model.station = S.sel.station and model.stations and model.stations[S.sel.station] or nil
  model.lines = S.sel.lines
  local route = currentRoute()
  if route then
    local c = currentTrips(route)
    model.route = menu.routeModel(route, c.trips, c.day, c.ctx)
    local idx = startIndexFor(route)
    local sec = S.sel.timeSec or world.nowSec()
    local deps, tomorrow = menu.departuresModel(c.trips, idx, sec, 8)
    model.start = { mode = S.sel.mode or 'here', index = idx, stopName = route.stops[idx].name, timeSec = sec,
      timeLabel = menu.clockLabel(sec), deps = deps, tomorrow = tomorrow, dep = S.sel.dep or 1,
      reverseId = S.reverseOf[route.id] or nil, reversed = S.sel.reversed or false }
  end
  if S.result then model.result = S.result end
  model.stats = S.stats
  model.saved = M.savedModel()
  model.features = datasvc.state.features
  if S.build then model.build = M.buildModelOf() end
  return model
end
M.model = buildModel

local function publish()
  guihooks.trigger('EarthBusRoutesState', buildModel())
end
M.publish = publish

-- ---- data ----------------------------------------------------------------------------------------------------------

local function onNearby(data, lat, lon)
  local a = osm.parseAround(data)
  local stations = osm.groupStops(a.stops)
  local model = menu.nearbyModel(stations, a.routes, lat, lon)
  S.cell = { stations = stations, routes = a.routes, model = model, lat = lat, lon = lon }
end

local function loadNearby(silent)
  local pose = world.pose()
  if not pose then
    if not silent then S.err = 'The BeamNG.Earth world is not ready yet' publish() end
    return
  end
  local lat, lon = pose.lat, pose.lon
  S.prefetchAt = { lat = lat, lon = lon }
  if not silent then S.loading, S.err = 'nearby', nil publish() end
  datasvc.nearby(lat, lon, function(data, info)
    if not data then
      S.loading = nil
      if not silent then S.err = info and info.down and 'service_down' or (info and info.error) or 'unknown error' end
      publish()
      return
    end
    local ok, err = pcall(onNearby, data, lat, lon)
    if not ok then log('E', TAG, 'parse failed: ' .. tostring(err)) S.err = 'Could not read the map data' end
    S.loading = nil
    if not silent then S.screen = 'nearby' end
    publish()
  end, (not silent) and 'urgent' or nil)
end

-- Load (or take from memory) one route relation: cb(route) or cb(nil, why)
local function loadRoute(id, cb)
  if S.routes[id] then cb(S.routes[id]) return end
  datasvc.route(id, function(data, info)
    if not data then cb(nil, info and info.error or 'unknown error') return end
    local ok, route, why = pcall(osm.parseRoute, data)
    if not ok then cb(nil, tostring(route)) return end
    if not route then cb(nil, why) return end
    S.routes[id] = route
    cb(route)
  end)
end

-- After a route is chosen: load its sibling variants (same line) in the background to find its opposite direction
local function findReverse(route)
  if S.reverseOf[route.id] ~= nil then return end
  local siblings = {}
  for _, ln in ipairs(S.sel.lines or {}) do
    if ln.ref == route.ref then for _, v in ipairs(ln.variants) do if v.id ~= route.id then siblings[#siblings + 1] = v.id end end end
  end
  S.reverseOf[route.id] = false
  for i = 1, math.min(#siblings, 6) do
    loadRoute(siblings[i], function(r)
      if r and S.reverseOf[route.id] == false then
        local back = osm.reverseOf(route, { r })
        if back then S.reverseOf[route.id] = r.id S.reverseOf[r.id] = route.id publish() end
      end
    end)
  end
end

-- ---- manual mode: a route built from stations ----------------------------------------------------------------------------

local SAVED_PATH = '/settings/earthBusRoutes/myroutes.json'
M.MAX_SAVED = 50
local MAX_LINE_POINTS = 300

local function readSaved()
  local ok, d = pcall(jsonReadFile, SAVED_PATH)
  local out = {}
  if ok and type(d) == 'table' and type(d.routes) == 'table' then
    for _, r in ipairs(d.routes) do
      if type(r) == 'table' and type(r.id) == 'string' and builder.deserialize(r.state) then out[#out + 1] = r end
    end
  end
  S.saved = out
end

local function writeSaved() pcall(jsonWriteFile, SAVED_PATH, { format = 1, routes = S.saved }, true) end

local function defaultName(ser)
  local a, b = ser.points[1], ser.points[#ser.points]
  local ref = (ser.ref and ser.ref ~= '') and ser.ref or 'My'
  return ref .. ': ' .. (a.name or '?') .. ' => ' .. (b.name or '?')
end

function M.savedModel()
  local out = {}
  for i, e in ipairs(S.saved) do
    out[i] = { i = i, id = e.id, name = e.name, ref = e.ref, colour = e.colour, from = e.from, to = e.to, n = e.n, mode = e.mode }
  end
  return out
end

-- road path of the chosen stations (the straight line when the data service cannot give one); cb(ok, err)
local function fetchPath(b, cb)
  if datasvc.has('path') == false then builder.applyPath(b, builder.straightAnswer(b)) cb(false, 'service_old') return end
  local serial = b.serial
  datasvc.path(builder.pts(b), function(ans, info)
    if b.serial ~= serial then return end
    if ans and ans.points and builder.applyPath(b, ans) then cb(true) return end
    builder.applyPath(b, builder.straightAnswer(b))
    cb(false, info and info.error or 'no path')
  end)
end

-- the stops along the path, in "all stops" mode; cb(ok, err)
local function fetchAlong(b, cb)
  if b.mode ~= 'all' or b.auto then cb(true) return end
  if b.straight then builder.setAuto(b, {}) cb(true) return end
  if datasvc.has('along') == false then builder.setAuto(b, {}) b.alongErr = 'service_old' cb(false, 'service_old') return end
  local serial = b.serial
  datasvc.along(builder.pts(b), function(ans, info)
    if b.serial ~= serial then return end
    if ans and ans.elements then
      local ok, stops = pcall(builder.stopsAlong, b, ans.elements)
      builder.setAuto(b, ok and stops or {})
      b.alongErr = (not ok) and 'parse' or (ans.fallback and 'fallback' or nil)
      cb(ok, b.alongErr)
      return
    end
    builder.setAuto(b, {})
    b.alongErr = info and info.error or 'no stops'
    cb(false, b.alongErr)
  end)
end

-- A finished route table of a builder state (asks the service for what is missing); cb(route) or cb(nil, why)
local function makeRoute(state, cb)
  local function done()
    local id = S.nextCustomId
    S.nextCustomId = id - 1
    local r, why = builder.toRoute(state, id)
    if not r then cb(nil, why) return end
    S.routes[id] = r
    S.customSer[id] = builder.serialize(state)
    S.reverseOf[id] = 'custom'
    cb(r)
  end
  local function along() fetchAlong(state, function() done() end) end
  if state.path then along() else fetchPath(state, function() along() end) end
end

local function openCustomRoute(route, keepTime)
  local prevTime = S.sel and S.sel.timeSec
  S.sel = { routeId = route.id, custom = true, dep = 1, reversed = S.sel and S.sel.reversed or false }
  local pose = world.pose()
  local _, d = menu.nearestStopIndex(route, pose and pose.lat or route.stops[1].lat, pose and pose.lon or route.stops[1].lon)
  S.sel.mode = (pose and d <= 250) and 'here' or 'first'
  S.sel.timeSec = (keepTime and prevTime) or world.nowSec()
  S.loading, S.err = nil, nil
  S.screen = 'route'
  publish()
end

local function busy(key, on) if S.build then S.build.busy[key] = on or nil end end

-- the list the player picks the next station from
local function activeCands()
  local B = S.build
  if not B then return nil end
  return (B.candKind == 'search' and B.searchCands) or B.cands
end

local function loadCandidates()
  local B = S.build
  if not B then return end
  local b = B.b
  local last = b.points[#b.points]
  local token = (B.candToken or 0) + 1
  B.candToken = token
  B.cands, B.err = nil, nil
  busy('cands', true)
  local pending, stops, failed, got = 2, {}, nil, false
  local function fin()
    pending = pending - 1
    if pending > 0 then return end
    if S.build ~= B or B.candToken ~= token then return end
    busy('cands', false)
    local ok, list = pcall(function() return builder.candidates(builder.fromStops(stops), b, {}) end)
    B.cands = ok and list or {}
    if not got and failed then B.err = failed end
    publish()
  end
  local function take(data, info)
    if data then
      got = true
      local ok, a = pcall(osm.parseAround, data)
      if ok then for _, st in ipairs(a.stops) do stops[#stops + 1] = st end end
    elseif not failed then
      failed = info and info.down and 'service_down' or (info and info.error) or 'unknown error'
    end
    fin()
  end
  -- (the last asked goes first: the stations list is what the player waits for, the nearby stops are the extra)
  datasvc.nearby(last.lat, last.lon, take, 'urgent')
  if datasvc.has('stations') == false then fin() else datasvc.stations(last.lat, last.lon, take) end
end

local function requestPath()
  local B = S.build
  if not B then return end
  local b = B.b
  B.pathErr = nil
  if #b.points < 2 then publish() return end
  busy('path', true)
  fetchPath(b, function(ok, err)
    if S.build ~= B or B.b ~= b then return end
    busy('path', false)
    B.pathErr = (not ok) and err or nil
    publish()
  end)
end

function M.uiBuildStart(i)
  readOptions()
  readSaved()
  local st, name
  local idx = tonumber(i)
  if idx and S.cell and S.cell.model and S.cell.model[idx] then
    st, name = S.cell.model[idx].ref, S.cell.model[idx].name
  elseif S.cell and S.cell.model and S.cell.model[1] then
    st, name = S.cell.model[1].ref, S.cell.model[1].name
  end
  local pose = world.pose()
  local first = st and { name = name, lat = st.lat, lon = st.lon, station = st.station }
    or (pose and { name = 'Start', lat = pose.lat, lon = pose.lon })
  if not first then S.err = 'The BeamNG.Earth world is not ready yet' publish() return end
  S.build = { b = builder.new(first), busy = {}, candKind = 'ring' }
  S.screen = 'build'
  S.err = nil
  loadCandidates()
  publish()
end

function M.uiBuildAdd(id)
  local B = S.build
  local list = activeCands()
  local c = list and list[tonumber(id)]
  if not c then return end
  local ok, why = builder.add(B.b, c)
  if not ok then B.err = (why == 'full') and 'build_full' or nil publish() return end
  B.query, B.candKind, B.searchCands, B.justSaved = nil, 'ring', nil, false
  loadCandidates()
  requestPath()
  publish()
end

function M.uiBuildUndo()
  local B = S.build
  if not B or not builder.undo(B.b) then return end
  B.query, B.candKind, B.searchCands, B.justSaved = nil, 'ring', nil, false
  loadCandidates()
  requestPath()
  publish()
end

function M.uiBuildSearch(q)
  local B = S.build
  if not B then return end
  q = tostring(q or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if #q < 2 then B.query, B.candKind, B.searchCands = nil, 'ring', nil publish() return end
  if datasvc.has('search') == false then B.err = 'service_old' publish() return end
  B.query = q
  B.searchToken = (B.searchToken or 0) + 1
  local token = B.searchToken
  local last = B.b.points[#B.b.points]
  busy('search', true)
  B.err = nil
  publish()
  datasvc.search(q, last.lat, last.lon, function(data, info)
    if S.build ~= B or B.searchToken ~= token then return end
    busy('search', false)
    if not data then
      B.err = info and info.down and 'service_down' or (info and info.error) or 'unknown error'
    else
      local ok, a = pcall(osm.parseAround, data)
      local list = {}
      if ok then
        local ok2, l = pcall(function() return builder.candidates(builder.fromStops(a.stops), B.b, { byName = true }) end)
        if ok2 then list = l end
      end
      B.searchCands, B.candKind = list, 'search'
    end
    publish()
  end)
end

function M.uiBuildClearSearch()
  local B = S.build
  if not B then return end
  B.query, B.candKind, B.searchCands = nil, 'ring', nil
  publish()
end

function M.uiBuildMode(mode)
  local B = S.build
  if not B then return end
  builder.setMode(B.b, mode)
  publish()
end

function M.uiBuildToggleStop(id)
  local B = S.build
  if B and builder.toggleStop(B.b, id) then publish() end
end

-- the stops screen: the stops on the way come from the service the first time it is opened
function M.uiBuildStops()
  local B = S.build
  if not B then return end
  if #B.b.points < 2 or not B.b.path then B.err = 'build_few' publish() return end
  S.screen = 'buildStops'
  if B.b.mode == 'all' and not B.b.auto then
    busy('along', true)
    publish()
    fetchAlong(B.b, function()
      if S.build ~= B then return end
      busy('along', false)
      publish()
    end)
  else
    publish()
  end
end

function M.uiBuildRetryAlong()
  local B = S.build
  if not B then return end
  B.b.auto, B.b.alongErr = nil, nil
  datasvc.forget()
  M.uiBuildStops()
end

function M.uiBuildMeta(ref, colour, name)
  local B = S.build
  if not B then return end
  local b = B.b
  if type(ref) == 'string' then b.ref = ref:gsub('[^%w%-/ ]', ''):sub(1, 6) end
  if type(colour) == 'string' then b.colour = colour:match('^#%x%x%x%x%x%x$') and colour:lower() or nil end
  if type(name) == 'string' then b.name = (#name > 0) and name:sub(1, 80) or nil end
  B.justSaved = false
  publish()
end

-- "Done": the route card (timetable, start) of what was built
function M.uiBuildFinish()
  local B = S.build
  if not B then return end
  local b = B.b
  if #b.points < 2 or not b.path then B.err = 'build_few' publish() return end
  S.loading, S.err = 'route', nil
  publish()
  makeRoute(b, function(route, why)
    S.loading = nil
    if not route then S.err = why or 'could not build the route' publish() return end
    S.sel = {}
    openCustomRoute(route)
    S.sel.savedId = B.savedId
  end)
end

-- Back from a built route's card to the builder
function M.uiBuildBack()
  if S.build then S.screen = 'build' S.sel = {} publish() end
end

local function saveSer(ser, savedId)
  readSaved()
  local first, last = ser.points[1], ser.points[#ser.points]
  local ref = (ser.ref and ser.ref ~= '') and ser.ref or 'My'
  local entry = {
    id = savedId or ('r' .. tostring(os.time()) .. tostring(#S.saved + 1)), name = ser.name or defaultName(ser),
    ref = ref, colour = osm.colorFor(ref, ser.colour), from = first.name, to = last.name, n = #ser.points, mode = ser.mode,
    state = ser, savedAt = os.time(),
  }
  for i, e in ipairs(S.saved) do
    if e.id == entry.id then S.saved[i] = entry writeSaved() return entry.id end
  end
  if #S.saved >= M.MAX_SAVED then return nil, 'full' end
  S.saved[#S.saved + 1] = entry
  writeSaved()
  return entry.id
end

-- Save what is on screen (the builder, or the built route's card)
function M.uiSave()
  if S.screen == 'build' or S.screen == 'buildStops' then
    local B = S.build
    if not B or #B.b.points < 2 then return end
    local id = saveSer(builder.serialize(B.b), B.savedId)
    if not id then S.err = 'save_full' else B.savedId, B.justSaved = id, true end
    publish()
  elseif S.sel and S.sel.custom and S.sel.routeId then
    local ser = S.customSer[S.sel.routeId]
    if not ser then return end
    local id = saveSer(ser, S.sel.savedId)
    if not id then S.err = 'save_full' else S.sel.savedId, S.sel.justSaved = id, true end
    publish()
  end
end

function M.uiOpenSaved(i)
  local e = S.saved[tonumber(i)]
  local state = e and builder.deserialize(e.state)
  if not state then return end
  S.loading, S.err = 'route', nil
  S.sel = {}
  publish()
  makeRoute(state, function(route, why)
    S.loading = nil
    if not route then S.err = why or 'could not build the route' S.screen = 'nearby' publish() return end
    S.sel = {}
    openCustomRoute(route)
    S.sel.savedId = e.id
  end)
end

function M.uiEditSaved(i)
  local e = S.saved[tonumber(i)]
  local state = e and builder.deserialize(e.state)
  if not state then return end
  S.build = { b = state, busy = {}, candKind = 'ring', savedId = e.id }
  S.screen = 'build'
  S.err = nil
  loadCandidates()
  requestPath()
  publish()
end

function M.uiDeleteSaved(i)
  i = tonumber(i)
  if not i or not S.saved[i] then return end
  table.remove(S.saved, i)
  writeSaved()
  publish()
end

-- Opposite direction of a built route: the stations the other way round
function M.uiCustomReverse()
  local route = currentRoute()
  local ser = route and S.customSer[route.id]
  local state = ser and builder.deserialize(ser)
  if not state then return end
  S.loading = 'route'
  publish()
  local reversed = not S.sel.reversed
  local savedId = S.sel.savedId
  makeRoute(builder.reverse(state), function(r, why)
    S.loading = nil
    if not r then S.err = why publish() return end
    openCustomRoute(r, true)
    S.sel.reversed, S.sel.savedId = reversed, savedId
    publish()
  end)
end

function M.uiCustomReverseTrip()
  local cur = S.finishedRouteId and S.routes[S.finishedRouteId]
  local ser = cur and S.customSer[cur.id]
  local state = ser and builder.deserialize(ser)
  if not state then return end
  S.result = nil
  S.loading = 'route'
  S.screen = 'route'
  publish()
  makeRoute(builder.reverse(state), function(r, why)
    S.loading = nil
    if not r then S.err = why S.screen = 'nearby' publish() return end
    S.sel = { routeId = r.id, custom = true, mode = 'first', dep = 1, reversed = true, timeSec = world.nowSec() + M.REVERSE_GAP_S }
    M.uiStart()
  end)
end

-- "Continue this line": an OSM route (even an incomplete one) as the first stations of a route of your own
function M.uiBuildFromRoute()
  local route = currentRoute()
  if not route or route.custom then return end
  readOptions()
  readSaved()
  S.build = { b = builder.fromRoute(route), busy = {}, candKind = 'ring' }
  S.screen = 'build'
  S.err = nil
  loadCandidates()
  requestPath()
  publish()
end

-- What the builder screens show
function M.buildModelOf()
  local B = S.build
  local b = B.b
  local pts = {}
  for i, p in ipairs(b.points) do pts[i] = { name = p.name or ('Stop ' .. i), lat = p.lat, lon = p.lon, station = p.station or false } end
  local km, min = 0, 0
  for _, l in ipairs(b.legs or {}) do km = km + l.dist min = min + l.dur / 60 * 1.25 end
  local line
  if b.path then
    line = {}
    local step = math.max(1, math.ceil(#b.path / MAX_LINE_POINTS))
    for i = 1, #b.path, step do line[#line + 1] = { b.path[i].lat, b.path[i].lon } end
    local lastp = b.path[#b.path]
    if line[#line][1] ~= lastp.lat or line[#line][2] ~= lastp.lon then line[#line + 1] = { lastp.lat, lastp.lon } end
  end
  local cands = {}
  for i, c in ipairs(activeCands() or {}) do
    cands[i] = { id = c.id, name = c.name, dist = c.dist, dir = c.dir, station = c.station, ahead = c.ahead, lat = c.lat, lon = c.lon }
  end
  local stops
  if b.path then
    stops = {}
    for i, st in ipairs(builder.stopList(b)) do
      stops[i] = { id = tostring(st.id), name = st.name, km = math.floor(st.along / 100 + 0.5) / 10, chosen = st.chosen or false,
        on = st.on ~= false, lat = st.lat, lon = st.lon }
    end
  end
  return {
    points = pts, legs = builder.legInfo(b), km = math.floor(km / 100 + 0.5) / 10, minutes = math.floor(min + 0.5),
    mode = b.mode, straight = b.straight or false, line = line, cands = cands, candKind = B.candKind, query = B.query,
    busy = B.busy, err = B.err, pathErr = B.pathErr, alongErr = b.alongErr, stops = stops,
    ref = b.ref, colour = osm.colorFor((b.ref ~= '' and b.ref) or 'My', b.colour), customColour = b.colour, name = b.name,
    canFinish = b.path ~= nil and #b.points >= 2, full = #b.points >= builder.MAX_POINTS, maxPoints = builder.MAX_POINTS,
    saved = B.savedId ~= nil, justSaved = B.justSaved or false,
  }
end

-- ---- menu actions (called by the Vue pages through bngApi.engineLua) --------------------------------------------------

function M.uiOpen()
  readOptions()
  readSaved()
  if datasvc.state.features == nil then datasvc.ping(function() publish() end) end
  S.screen = S.trip and 'trip' or ((S.result and S.result.show) and 'result') or 'nearby'
  if S.screen == 'nearby' then loadNearby(false) else publish() end
  world.navigate('earthBusRoutes')
end

function M.toggleMenu() M.uiOpen() end

function M.uiClose() world.navigate('play') end

function M.uiState() publish() end

function M.uiRefresh() datasvc.forget() S.cell = nil loadNearby(false) end

function M.uiBackTo(screen)
  S.screen = screen
  if screen == 'nearby' then S.sel = {} S.result = nil S.build = nil end
  if screen == 'build' then S.sel = {} end
  if screen == 'lines' then S.sel.routeId, S.sel.dep, S.sel.reversed = nil, nil, false end
  if screen == 'buildStops' then M.uiBuildStops() return end
  publish()
end

function M.uiSelectStation(i)
  local st = stationRef(i)
  if not st then return end
  S.sel = { station = i, mode = 'here' }
  S.sel.lines = menu.linesModel(st, S.cell.routes)
  S.screen = 'lines'
  publish()
end

function M.uiSelectRoute(id)
  id = tonumber(id)
  if not id then return end
  S.loading, S.err = 'route', nil
  S.sel.routeId, S.sel.dep = id, 1
  publish()
  loadRoute(id, function(route, why)
    S.loading = nil
    if not route then S.err = why or 'could not load the route' S.sel.routeId = nil publish() return end
    -- the player starts at the stop they are at when it is near enough, else at the route's first stop
    local st = S.sel.station and stationRef(S.sel.station)
    local _, d = menu.nearestStopIndex(route, st and st.lat or route.stops[1].lat, st and st.lon or route.stops[1].lon)
    S.sel.mode = (st and d <= 250) and 'here' or 'first'
    S.sel.timeSec = S.sel.timeSec or world.nowSec()
    S.screen = 'route'
    findReverse(route)
    publish()
  end)
end

function M.uiSetStartMode(mode)
  S.sel.mode = (mode == 'first') and 'first' or 'here'
  S.sel.dep = 1
  publish()
end

function M.uiSetTime(sec)
  sec = tonumber(sec)
  if not sec then return end
  S.sel.timeSec = sec % 86400
  S.sel.dep = 1
  publish()
end

function M.uiSelectDep(i) S.sel.dep = tonumber(i) or 1 publish() end

-- The opposite direction of the chosen route, when the data has it
function M.uiToggleReverse()
  local route = currentRoute()
  local back = route and S.reverseOf[route.id]
  if not back then return end
  if back == 'custom' then return M.uiCustomReverse() end
  S.sel.reversed = not S.sel.reversed
  M.uiSelectRoute(back)
end

-- ---- starting a trip -----------------------------------------------------------------------------------------------

local function buildPlan()
  readOptions()
  local route = currentRoute()
  if not route then return nil, 'no route chosen' end
  local c = currentTrips(route)
  local idx = startIndexFor(route)
  local sec = S.sel.timeSec or world.nowSec()
  local deps = menu.departuresModel(c.trips, idx, sec, 8)
  local dep = deps[S.sel.dep or 1]
  local entry
  if dep then
    for _, tr in ipairs(c.trips) do if tr.id == dep.trip then entry = { trip = tr, at = dep.sec } break end end
  end
  local veh = world.vehicleInfo()
  if not veh then return nil, 'Sit in a bus first' end
  local clock = entry and schedule.scheduled(entry.trip, idx) or sec
  return {
    route = route, trips = c.trips, entry = entry, startIndex = idx, day = c.day, clock = clock, ctx = c.ctx,
    opts = { density = S.opts.density or 'normal', difficulty = S.opts.difficulty or 'normal', timeScale = S.opts.timeScale or 1,
      weather = world.weather() },
    vehicle = { bus = veh.bus }, vehicleName = veh.name,
  }
end

local function gpsAhead(t)
  local pts = {}
  for i = t.idx, #t.route.stops do
    local s = t.route.stops[i]
    pts[#pts + 1] = { lat = s.lat, lon = s.lon, name = s.name }
    if #pts >= 10 then break end
  end
  world.gpsRoute(pts)
end

local function stopsAhead(t, n)
  local out = {}
  for i = t.idx, math.min(#t.route.stops, t.idx + (n or 8) - 1) do out[#out + 1] = t.route.stops[i] end
  return out
end

local function beginTrip(plan)
  local veh = world.vehicle()
  S.result = nil
  S.trip = trip.new(plan)
  S.trip.veh = veh
  S.hudTimer = 0
  world.resetAccel()
  world.watchDoors(veh)
  world.clockBegin()
  world.clockSet(plan.clock)
  local stop = plan.route.stops[plan.startIndex]
  local _, _, bearing = geo.pointAt(plan.route.path, plan.route.cum, stop.along)
  if bearing then world.faceHeading(veh, bearing) end
  if world.ensureHud() and not S.hudAsked then
    S.hudAsked = true
    world.toast('Bus HUD added to your UI layout. Move or remove it in Esc > UI Apps.', 7)
  end
  world.busDisplay(veh, plan.route, stopsAhead(S.trip))
  gpsAhead(S.trip)
  S.screen = 'trip'
  world.navigate('play')
  publish()
  M.sendHud()
  log('I', TAG, ('trip started: %s %s -> %s from stop %d, clock %s'):format(plan.route.ref, tostring(plan.route.from), tostring(plan.route.to),
    plan.startIndex, menu.clockLabel(plan.clock)))
end

function M.uiStart()
  local plan, why = buildPlan()
  if not plan then S.err = why publish() return end
  S.err = nil
  local stop = plan.route.stops[plan.startIndex]
  local pose = world.pose()
  local near = pose and geo.dist(pose.lat, pose.lon, stop.lat, stop.lon) <= M.START_NEAR_M
  if near then beginTrip(plan) return end
  local ok, err = world.teleport(stop.lat, stop.lon, stop.name)
  if not ok then S.err = 'Could not take you to the stop: ' .. tostring(err) publish() return end
  S.starting = { plan = plan, t = 0, seenTeleport = false }
  publish()
  world.navigate('play')
  world.toast('Taking you to ' .. tostring(stop.name) .. '…', 5)
end

-- ---- finishing -----------------------------------------------------------------------------------------------------

local function statsPath() return '/settings/earthBusRoutes/stats.json' end

local function saveStats(t, res)
  local ok, stats = pcall(jsonReadFile, statsPath())
  if not ok or type(stats) ~= 'table' then stats = {} end
  stats.trips = (stats.trips or 0) + 1
  stats.passengers = (stats.passengers or 0) + (res.passengers or 0)
  stats.points = (stats.points or 0) + (res.points or 0)
  stats.best = stats.best or {}
  local key = tostring(t.route.ref) .. '|' .. tostring(t.route.network or '')
  local prev = stats.best[key]
  local record = (not prev) or res.points > (prev.points or 0)
  if record then stats.best[key] = { points = res.points, grade = res.grade, ref = t.route.ref, from = t.route.from, to = t.route.to } end
  pcall(jsonWriteFile, statsPath(), stats, true)
  return record, prev and prev.points or nil, stats
end

local function endClockAndGps()
  world.clockEnd()
  world.gpsClear()
end

local function finishTrip(t)
  local res = trip.result(t)
  local record, previous, stats = saveStats(t, res)
  local back = S.reverseOf[t.route.id]
  S.result = {
    show = true, points = res.points, grade = res.grade, stars = res.stars, parts = res.parts, passengers = res.passengers,
    revenue = res.revenue, served = res.served, planned = res.planned, missed = res.missed, notes = res.notes,
    ref = t.route.ref, colour = t.route.colour, from = t.route.from, to = t.route.to, record = record, previous = previous,
    minutes = math.floor((t.clock - t.clock0) / 60 + 0.5), canReverse = back ~= nil and back ~= false,
    totals = { trips = stats.trips, passengers = stats.passengers, points = stats.points },
    scheduled = t.entry ~= nil,
  }
  S.stats = { trips = stats.trips, passengers = stats.passengers, points = stats.points }
  S.finishedRouteId = t.route.id
  S.finishedStation = S.sel.station
  S.trip = nil
  endClockAndGps()
  S.screen = 'result'
  publish()
  world.navigate('earthBusRoutes')
  guihooks.trigger('EarthBusRoutesHud', { finished = true, result = S.result })
end

function M.uiCancelTrip()
  if not S.trip then return end
  S.trip = nil
  endClockAndGps()
  S.screen = 'nearby'
  S.result = nil
  publish()
  guihooks.trigger('EarthBusRoutesHud', { idle = true })
  world.toast('Trip cancelled', 3)
end

-- After a trip: the way back (opposite direction, from here), when the data has it
function M.uiReverseTrip()
  local id = S.finishedRouteId and S.reverseOf[S.finishedRouteId]
  if not id then return end
  if id == 'custom' then return M.uiCustomReverseTrip() end
  S.sel = { station = S.finishedStation, mode = 'first', routeId = id, reversed = true, lines = S.sel.lines }
  S.result = nil
  loadRoute(id, function(route, why)
    if not route then S.err = why S.screen = 'nearby' publish() return end
    S.sel.timeSec = world.nowSec() + M.REVERSE_GAP_S
    S.sel.dep = 1
    M.uiStart()
  end)
end

-- After a trip: another route from this place
function M.uiAnotherRoute()
  S.result = nil
  S.sel = {}
  S.cell = nil
  S.screen = 'nearby'
  loadNearby(false)
end

function M.uiDismissResult()
  if S.result then S.result.show = false end
  S.screen = 'nearby'
  guihooks.trigger('EarthBusRoutesHud', { idle = true })
  publish()
end

-- ---- every frame -----------------------------------------------------------------------------------------------------

-- The HUD's payload (units come from the player's option)
local function hudOf(t)
  local h = trip.hud(t)
  h.units = S.opts.units or 'km/h'
  return h
end

-- The HUD app asks when it mounts (it may have been added after the trip started)
function M.sendHud()
  if S.trip then guihooks.trigger('EarthBusRoutesHud', hudOf(S.trip))
  elseif S.result and S.result.show then guihooks.trigger('EarthBusRoutesHud', { finished = true, result = S.result })
  else guihooks.trigger('EarthBusRoutesHud', { idle = true }) end
end

local function handleEvents(t)
  for _, e in ipairs(trip.takeEvents(t)) do
    if e.name == 'arrived' then
      world.busDisplay(t.veh, t.route, stopsAhead(t))
    elseif e.name == 'departed' then
      world.busDisplay(t.veh, t.route, stopsAhead(t))
      gpsAhead(t)
    elseif e.name == 'missed' then
      world.toast('Missed stop: ' .. tostring(e.data.stop.name), 4)
      gpsAhead(t)
    elseif e.name == 'finished' then
      finishTrip(t)
      return true
    end
  end
end

local function tripFrame(dt)
  local t = S.trip
  local pose = world.pose()
  if not pose then return end
  local veh = world.vehicle()
  if not veh then return end
  if t.veh and veh:getID() ~= t.veh:getID() then
    M.uiCancelTrip()
    world.toast('Trip cancelled: you changed vehicle', 4)
    return
  end
  local aL, aR = world.accel(veh, dt)
  trip.update(t, dt, { lat = pose.lat, lon = pose.lon, speed = pose.speed or 0, aLong = aL, aLat = aR, doorsOpen = world.doorsOpen(veh) })
  if handleEvents(t) then return end
  world.clockSet(t.clock)
  S.hudTimer = S.hudTimer - dt
  if S.hudTimer <= 0 then
    S.hudTimer = 0.25
    guihooks.trigger('EarthBusRoutesHud', hudOf(t))
  end
end

local function startingFrame(dt)
  local st = S.starting
  st.t = st.t + dt
  local api = earthApi()
  -- the teleport shows as "not ready" for a while, then the world is there again
  if api and not api.ready() then st.seenTeleport = true end
  if (st.seenTeleport and api and api.ready()) or st.t > 45 then
    S.starting = nil
    if api and api.ready() then
      beginTrip(st.plan)
    else
      S.err = 'The world did not load in time'
      publish()
    end
  end
end

function M.onUpdate(dtReal, dtSim)
  if not S.earth then return end
  datasvc.update(dtReal or 0)
  if S.starting then startingFrame(dtReal or 0) end
  if S.trip then tripFrame(dtSim or 0) end
  -- keep the cell around the player ready, so the menu opens at once
  S.prefetchTimer = S.prefetchTimer - (dtReal or 0)
  if S.prefetchTimer <= 0 and not S.trip and not S.starting then
    S.prefetchTimer = 5
    local pose = world.pose()
    if pose and datasvc.state.up ~= false then
      local p = S.prefetchAt
      if not p or geo.dist(p.lat, p.lon, pose.lat, pose.lon) > M.PREFETCH_MOVE_M then
        S.prefetchAt = { lat = pose.lat, lon = pose.lon }
        local lat, lon = pose.lat, pose.lon
        datasvc.nearby(lat, lon, function(data)
          if data and not S.cell then pcall(onNearby, data, lat, lon) end
        end, 'low')
      end
    end
  end
end

-- ---- game hooks ------------------------------------------------------------------------------------------------------

function M.onExtensionLoaded()
  refreshEarth()
  readOptions()
end

-- BeamNG.Earth's world loads after the level: check again then (the API may not have been there at mount time).
function M.onBeamNGEarthWorldReady()
  refreshEarth()
  readOptions()
end

function M.onBeamNGEarthAddonOptions(info)
  if info and info.values then
    S.opts = info.values
    if tonumber(S.opts.dataPort) then datasvc.PORT = tonumber(S.opts.dataPort) end
    publish()
  end
end

-- A teleport the player asked for during a trip ends it (the bus is no longer where the trip is)
function M.onBeamNGEarthTeleported()
  if S.trip then M.uiCancelTrip() world.toast('Trip cancelled: you were teleported', 4) end
end

function M.onVehicleSwitched()
  if S.trip then M.uiCancelTrip() world.toast('Trip cancelled: you changed vehicle', 4) end
end

function M.onExtensionUnloaded()
  endClockAndGps()
  datasvc.reset()
  S.trip, S.starting = nil, nil
end

return M
