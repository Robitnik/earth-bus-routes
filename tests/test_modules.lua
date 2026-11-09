local H = dofile('tests/harness.lua')
local T = {}

-- every module of the mod loads (a syntax error or a missing global at load time shows here, not in the game)
function T.all_modules_load()
  H.reset()
  for _, n in ipairs({ 'geomath', 'osm', 'schedule', 'demand', 'scoring', 'http', 'datasvc', 'trip', 'menu', 'world', 'main' }) do
    package.loaded['earthBusRoutes/' .. n] = nil
    local ok, m = pcall(require, 'earthBusRoutes/' .. n)
    assert(ok, n .. ': ' .. tostring(m))
    assert(type(m) == 'table', n .. ' did not return a table')
  end
end

-- the game's LuaJIT is Lua 5.1: no goto-free integer division, bit operators or integer literals of 5.3
function T.no_lua53_only_syntax()
  local dir = 'mod/lua/ge/extensions/earthBusRoutes/'
  for _, n in ipairs({ 'geomath', 'osm', 'schedule', 'demand', 'scoring', 'http', 'datasvc', 'trip', 'menu', 'world', 'main' }) do
    local src = readFileText(dir .. n .. '.lua')
    src = src:gsub('%-%-[^\n]*', ''):gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")   -- comments and strings out
    assert(not src:find('//'), n .. ': integer division //')
    assert(not src:find('<<') and not src:find('>>'), n .. ': shift operators')
    assert(not src:find('%f[%w_]goto%f[^%w_]'), n .. ': goto')
    assert(not src:find('%f[%w_]utf8%.'), n .. ': utf8 library')
    assert(not src:find('table%.unpack') and not src:find('math%.tointeger'), n .. ': 5.3 library function')
  end
end

return T
