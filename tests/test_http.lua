local H = dofile('tests/harness.lua')
local http = require('earthBusRoutes/http')
local T = {}

-- feed `raw` to a parser in pieces of `step` bytes
local function run(raw, step)
  local p = http.newParser()
  local i = 1
  while i <= #raw do
    http.feed(p, raw:sub(i, i + step - 1))
    i = i + step
  end
  return p
end

local BODY = ('{"elements":[%s]}'):format(('{"id":1234567,"x":"šá"},'):rep(300) .. '{}')

local function chunked(body, size)
  local out = {}
  local i = 1
  while i <= #body do
    local piece = body:sub(i, i + size - 1)
    out[#out + 1] = ('%x\r\n%s\r\n'):format(#piece, piece)
    i = i + size
  end
  return 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n' .. table.concat(out) .. '0\r\n\r\n'
end

function T.content_length_in_any_pieces()
  local raw = 'HTTP/1.1 200 OK\r\nContent-Length: ' .. #BODY .. '\r\nContent-Type: application/json\r\n\r\n' .. BODY
  for _, step in ipairs({ 1, 7, 100, 4096, #raw }) do
    local p = run(raw, step)
    assert(p.done and p.status == 200, 'step ' .. step)
    assert(http.body(p) == BODY, 'body differs at step ' .. step)
    assert(p.headers['content-type'] == 'application/json')
  end
end

function T.chunked_in_any_pieces()
  for _, chunk in ipairs({ 1, 13, 500, 5000 }) do
    local raw = chunked(BODY, chunk)
    for _, step in ipairs({ 1, 5, 64, 1000, #raw }) do
      if not (chunk == 1 and step == 1) or true then
        local p = run(raw, step)
        assert(p.done, 'not done: chunk ' .. chunk .. ' step ' .. step)
        assert(http.body(p) == BODY, 'body differs: chunk ' .. chunk .. ' step ' .. step)
      end
    end
  end
end

function T.until_close_body()
  local p = run('HTTP/1.0 200 OK\r\nServer: x\r\n\r\nhello world', 4)
  assert(not p.done)
  assert(http.closed(p) and http.body(p) == 'hello world')
end

function T.cut_short_is_an_error()
  local p = run('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort', 3)
  assert(not p.done)
  assert(http.closed(p) == false and p.err)
end

function T.status_errors_are_visible()
  local p = run('HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n', 10)
  assert(p.done and p.status == 429)
  local q = run('HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 4\r\n\r\nbusy', 3)
  assert(q.status == 504 and http.body(q) == 'busy')
end

function T.garbage_is_rejected()
  local p = run('not http at all\r\n\r\n', 5)
  assert(p.err and not p.done)
end

function T.too_large_is_rejected()
  local old = http.MAX_BYTES
  http.MAX_BYTES = 100
  local p = run('HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n' .. ('x'):rep(500), 50)
  http.MAX_BYTES = old
  assert(p.err == 'response too large')
end

function T.request_is_well_formed()
  local body = 'data=' .. http.urlencode('[out:json];node(1);out;')
  local r = http.buildRequest('overpass-api.de', 'POST', '/api/interpreter',
    { ['Content-Type'] = 'application/x-www-form-urlencoded', ['User-Agent'] = 'x/1' }, body)
  assert(r:find('^POST /api/interpreter HTTP/1.1\r\n'))
  assert(r:find('Host: overpass-api.de\r\n', 1, true))
  assert(r:find('Content-Length: ' .. #body .. '\r\n', 1, true))
  assert(r:sub(-#body) == body)
  assert(http.urlencode('a b&c=ü') == 'a%20b%26c%3D%C3%BC')
end

return T
