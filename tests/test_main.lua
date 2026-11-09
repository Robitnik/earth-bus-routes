local H = dofile('tests/harness.lua')
local T = {}

local function main() return H.load('mod/lua/ge/extensions/earthBusRoutes/main.lua') end

function T.idle_without_earth()
  H.reset()
  local m = main()
  local ok, why = m.checkEarth()
  assert(ok == false and why:find('not installed'), why)
  m.onExtensionLoaded()
  assert(m.status().earth == false)
  assert(#H.logs == 1 and H.logs[1]:find('idle'))
end

function T.warns_only_once()
  H.reset()
  local m = main()
  m.onExtensionLoaded(); m.onBeamNGEarthWorldReady(); m.onBeamNGEarthWorldReady()
  assert(#H.logs == 1, #H.logs)
end

function T.rejects_old_api()
  H.reset()
  H.earth({ pose = true })
  local ok, why = main().checkEarth()
  assert(ok == false and why:find('too old'), why)
end

function T.rejects_other_major()
  H.reset()
  H.earth(nil, 2)
  local ok = main().checkEarth()
  assert(ok == false)
end

function T.ready_with_earth_and_recovers()
  H.reset()
  local m = main()
  m.onExtensionLoaded()
  assert(m.status().earth == false)
  local toasts = H.earth()
  m.onBeamNGEarthWorldReady()
  assert(m.status().earth == true and m.status().reason == 'ok')
  assert(#toasts == 0)
end

return T
