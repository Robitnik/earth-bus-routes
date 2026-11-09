-- Minimal non-blocking HTTP/1.1 client over LuaSocket (the game's LuaSocket has no TLS: http:// only).
-- Nothing here ever waits: M.step(req) is called every frame and does whatever the socket allows right now.
-- The parser is pure and tested under lupa; the socket part follows beamngEarth/net.lua (settimeout(0), a connect
-- in progress is finished by getpeername()).
-- One blocking spot remains: the name lookup inside connect() the first time a host is used (the result is cached).
local M = {}

M.CONNECT_TIMEOUT_S = 10
M.TOTAL_TIMEOUT_S = 90
M.MAX_BYTES = 8 * 1024 * 1024
M.RECV_CHUNK = 32768

-- ---- response parser (pure) --------------------------------------------------------------------------------------

function M.newParser()
  return { buf = '', headEnd = nil, status = nil, headers = nil, mode = nil, need = nil, parts = {}, size = 0,
    done = false, err = nil, chunkLeft = nil, chunkWait = nil }
end

local function parseHead(p)
  local head = p.buf:sub(1, p.headEnd - 1)
  local status = head:match('^HTTP/%d%.%d (%d%d%d)')
  if not status then p.err = 'bad status line' return end
  p.status = tonumber(status)
  p.headers = {}
  for k, v in head:gmatch('\r\n([^:\r\n]+):%s*([^\r\n]*)') do p.headers[k:lower()] = v end
  local te = (p.headers['transfer-encoding'] or ''):lower()
  if te:find('chunked', 1, true) then p.mode = 'chunked'
  elseif p.headers['content-length'] then p.mode, p.need = 'length', tonumber(p.headers['content-length'])
  else p.mode = 'close' end
  if p.status == 204 or p.status == 304 or (p.status >= 100 and p.status < 200) then p.mode, p.need = 'length', 0 end
  p.buf = p.buf:sub(p.headEnd + 4)
end

local function take(p, s)
  if #s > 0 then
    p.parts[#p.parts + 1] = s
    p.size = p.size + #s
    if p.size > M.MAX_BYTES then p.err = 'response too large' end
  end
end

-- Feed bytes; returns true once the whole response is in (p.status, p.headers, M.body(p))
function M.feed(p, data)
  if p.done or p.err then return p.done end
  p.buf = p.buf .. data
  if not p.headEnd then
    local s = p.buf:find('\r\n\r\n', 1, true)
    if not s then
      if #p.buf > 65536 then p.err = 'header too large' end
      return false
    end
    p.headEnd = s
    parseHead(p)
    if p.err then return false end
  end
  if p.mode == 'length' then
    take(p, p.buf)
    p.buf = ''
    if p.size >= (p.need or 0) then p.done = true end
  elseif p.mode == 'close' then
    take(p, p.buf)
    p.buf = ''
  else  -- chunked
    while true do
      if p.chunkLeft == nil then
        local eol = p.buf:find('\r\n', 1, true)
        if not eol then break end
        local len = tonumber(p.buf:sub(1, eol - 1):match('^%s*(%x+)'), 16)
        if not len then p.err = 'bad chunk size' break end
        p.buf = p.buf:sub(eol + 2)
        if len == 0 then p.done = true break end
        p.chunkLeft = len
      end
      if #p.buf < p.chunkLeft + 2 then
        -- take what is there of the chunk's data now (keeps the buffer small), the CRLF after it later
        if #p.buf > 0 and #p.buf <= p.chunkLeft then take(p, p.buf) p.chunkLeft = p.chunkLeft - #p.buf p.buf = '' end
        break
      end
      take(p, p.buf:sub(1, p.chunkLeft))
      p.buf = p.buf:sub(p.chunkLeft + 3)
      p.chunkLeft = nil
    end
    if p.chunkLeft == 0 and #p.buf >= 2 then p.buf = p.buf:sub(3) p.chunkLeft = nil end
  end
  return p.done
end

-- The connection closed: a length-less body is complete then; anything else cut short is an error
function M.closed(p)
  if p.done then return true end
  if p.mode == 'close' and p.status then p.done = true return true end
  p.err = p.err or 'connection closed early'
  return false
end

function M.body(p) return table.concat(p.parts) end

-- ---- request building (pure) -------------------------------------------------------------------------------------

function M.urlencode(s)
  return (s:gsub('[^A-Za-z0-9%-_%.~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

function M.buildRequest(host, method, path, headers, body)
  local h = { ('%s %s HTTP/1.1'):format(method, path), 'Host: ' .. host, 'Connection: close', 'Accept: application/json' }
  for k, v in pairs(headers or {}) do h[#h + 1] = k .. ': ' .. v end
  if body then h[#h + 1] = 'Content-Length: ' .. #body end
  return table.concat(h, '\r\n') .. '\r\n\r\n' .. (body or '')
end

-- ---- the socket driver -------------------------------------------------------------------------------------------

local socket
local ipCache = {}

-- req = M.start{ host=, port=80, method='POST', path=, headers={}, body= }; call M.step(req, dt) each frame until
-- req.state is 'done' or 'error'. req.status / req.err / M.body(req.parser) afterwards.
function M.start(o)
  local req = { host = o.host, port = o.port or 80, state = 'connecting', t = 0, parser = M.newParser(), ctimeout = o.connectTimeout or M.CONNECT_TIMEOUT_S, ttimeout = o.totalTimeout or M.TOTAL_TIMEOUT_S,
    out = M.buildRequest(o.host, o.method or 'GET', o.path or '/', o.headers, o.body), sent = 1 }
  socket = socket or require('socket')
  local ip = ipCache[o.host]
  if not ip then
    ip = socket.dns.toip(o.host)           -- blocking, once per host
    if not ip then req.state, req.err = 'error', 'cannot resolve ' .. o.host return req end
    ipCache[o.host] = ip
  end
  local s = socket.tcp()
  s:settimeout(0)
  req.sock = s
  local ok, err = s:connect(ip, req.port)
  if ok then req.state = 'sending'
  elseif err ~= 'timeout' and err ~= 'Operation already in progress' then
    req.state, req.err = 'error', 'connect: ' .. tostring(err)
    s:close()
  end
  return req
end

local function fail(req, err)
  req.state, req.err = 'error', err
  if req.sock then pcall(req.sock.close, req.sock) req.sock = nil end
end

function M.step(req, dt)
  if req.state == 'done' or req.state == 'error' then return end
  req.t = req.t + dt
  if req.t > req.ttimeout then return fail(req, 'timeout') end
  local s = req.sock
  if req.state == 'connecting' then
    if s:getpeername() then req.state = 'sending'
    elseif req.t > req.ctimeout then return fail(req, 'connect timeout') end
  end
  if req.state == 'sending' then
    local last, err, partial = s:send(req.out, req.sent)
    local upto = last or partial
    if upto then req.sent = upto + 1 end
    if last then req.state = 'receiving'
    elseif err ~= 'timeout' then return fail(req, 'send: ' .. tostring(err)) end
  end
  if req.state == 'receiving' then
    for _ = 1, 8 do                               -- a few chunks a frame at most
      local data, err, partial = s:receive(M.RECV_CHUNK)
      local got = data or partial
      if got and #got > 0 then
        if M.feed(req.parser, got) then break end
        if req.parser.err then return fail(req, req.parser.err) end
      end
      if err == 'closed' then
        pcall(s.close, s)
        req.sock = nil
        if M.closed(req.parser) then req.state, req.status = 'done', req.parser.status
        else req.state, req.err = 'error', req.parser.err end
        return
      end
      if not data then break end                  -- timeout: nothing more right now
    end
    if req.parser.done then
      pcall(s.close, s)
      req.sock = nil
      req.state, req.status = 'done', req.parser.status
    end
  end
end

function M.cancel(req)
  if req and req.sock then pcall(req.sock.close, req.sock) req.sock = nil end
  if req then req.state = 'error' req.err = req.err or 'cancelled' end
end

return M
