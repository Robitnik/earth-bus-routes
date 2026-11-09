-- Earth Bus Routes: entry point (extension "earthBusRoutes_main").
-- Works only on top of BeamNG.Earth's modding API v1 (beamngEarth_api); without it the mod does nothing but say so once.
-- Everything BeamNG.Earth-internal goes through pcall in its own wrapper module (geo.lua, clock.lua), never from here.

local M = {}
local TAG = 'earthBusRoutes'
M.VERSION = '0.1.0'
-- Features of beamngEarth_api this mod needs (docs/ADDONS.md "Modding API v1").
M.NEEDS = { 'pose', 'place', 'teleport', 'gpsRoute', 'events', 'options' }

local state = { earth = false, reason = 'not checked', warned = false }

local function earthApi() return rawget(_G, 'beamngEarth_api') end

-- true, or false + why. Pure: no side effects, so the tests can call it with stub APIs.
function M.checkEarth()
  local api = earthApi()
  if not api then return false, 'BeamNG.Earth is not installed' end
  local ok, major, minor = pcall(api.version)
  if not ok or major ~= 1 then return false, 'BeamNG.Earth modding API v1 is required' end
  for _, name in ipairs(M.NEEDS) do
    if not api.has(name) then return false, 'BeamNG.Earth is too old (API feature "' .. name .. '" missing)' end
  end
  return true
end

local function toast(text)
  local api = earthApi()
  if api and api.notify then pcall(api.notify, text, 6) return end
  pcall(function() guihooks.trigger('Message', { ttl = 6, msg = text, icon = 'directions_bus' }) end)
end

local function refresh()
  local ok, why = M.checkEarth()
  state.earth, state.reason = ok, why or 'ok'
  if not ok and not state.warned then
    state.warned = true
    log('W', TAG, 'Earth Bus Routes is idle: ' .. state.reason)
    toast('Earth Bus Routes needs BeamNG.Earth: ' .. state.reason)
  end
  return ok
end

function M.status() return { version = M.VERSION, earth = state.earth, reason = state.reason } end

function M.onExtensionLoaded() refresh() end
-- BeamNG.Earth's world loads after the level: check again then (the API may not have been there at mount time).
function M.onBeamNGEarthWorldReady() refresh() end

return M
