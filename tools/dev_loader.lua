-- Run in the game's GE Lua over MCP (see dev_push.py): puts the pushed files into package.preload, so
-- require('earthBusRoutes/<name>') gives the working copy instead of the installed zip's version.
local dir = '/settings/earthBusRoutes/dev/'
local loaded = {}
for _, path in ipairs(FS:findFiles(dir, '*.lua', 0, true, false)) do
  local n = path:match('([^/]+)%.lua$')
  local src = readFile(path)
  if src then
    package.loaded['earthBusRoutes/' .. n] = nil
    package.preload['earthBusRoutes/' .. n] = assert(loadstring(src, '@dev/' .. n .. '.lua'))
    loaded[#loaded + 1] = n
  end
end
table.sort(loaded)
return 'preloaded: ' .. table.concat(loaded, ',')
