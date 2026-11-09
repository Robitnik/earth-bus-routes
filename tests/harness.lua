-- Stubs for the game's globals, so pure mod logic runs under lupa. Each test file returns { name = function() ... end }.
local H = {}
H.logs = {}
function H.reset()
  H.logs = {}
  _G.beamngEarth_api = nil
  _G.log = function(level, tag, msg) H.logs[#H.logs + 1] = level .. ' ' .. tag .. ': ' .. tostring(msg) end
  _G.guihooks = { trigger = function() end }
  _G.setExtensionUnloadMode = function() end
end
-- A stub of beamngEarth_api; `features` = set of has() names, `major` the API major version.
function H.earth(features, major)
  features = features or { pose = true, place = true, teleport = true, gpsRoute = true, events = true, options = true }
  local toasts = {}
  _G.beamngEarth_api = {
    version = function() return major or 1, 3 end,
    has = function(n) return features[n] == true end,
    notify = function(t) toasts[#toasts + 1] = t end,
  }
  return toasts
end
-- A recorded Overpass answer from tests/fixtures as a Lua table
function H.fixture(name) return jsonDecode(readFileText('tests/fixtures/' .. name .. '.json')) end
function H.load(path)
  local f = assert(loadfile(path))
  return f()
end
return H
