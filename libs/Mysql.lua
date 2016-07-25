local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local strpack = string.pack
local strunpack = string.unpack
local sub = string.sub
local strbyte = string.byte
local strchar = string.char
local format = string.format
local strrep = string.rep
local concat = table.concat
local band = bit32.band
local bxor = bit32.bxor
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local tohex = bit32.tohex

local MysqlSession = {
}

-- constants

local STATE_NONE = 0
local STATE_CONNECTED = 1
local STATE_COMMAND_SENT = 2

local COM_QUIT = 0x01
local COM_QUERY = 0x03
local CLIENT_SSL = 0x0800

local SERVER_MORE_RESULTS_EXISTS = 8

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215

-- mysql field value type converters
local converters = {}

for i = 0x01, 0x05 do
    -- tiny, short, long, float, double
    converters[i] = tonumber
end
-- converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal

local function _get_byte2(data, i)
    local a, b = strbyte(data, i, i + 1)
    return bor(a, lshift(b, 8)), i + 2
end

local function _get_byte3(data, i)
    local a, b, c = strbyte(data, i, i + 2)
    return bor(a, lshift(b, 8), lshift(c, 16)), i + 3
end

local function _get_byte4(data, i)
    local a, b, c, d = strbyte(data, i, i + 3)
    return bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24)), i + 4
end

local function _get_byte8(data, i)
    local a, b, c, d, e, f, g, h = strbyte(data, i, i + 7)

    -- XXX workaround for the lack of 64-bit support in bitop:
    local lo = bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
    local hi = bor(e, lshift(f, 8), lshift(g, 16), lshift(h, 24))
    return lo + hi * 4294967296, i + 8
end

local function _set_byte2(n)
    return strchar(band(n, 0xff), band(rshift(n, 8), 0xff))
end

local function _set_byte3(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff))
end

local function _set_byte4(n)
    return strchar(band(n, 0xff),
                   band(rshift(n, 8), 0xff),
                   band(rshift(n, 16), 0xff),
                   band(rshift(n, 24), 0xff))
end

local function _from_cstring(data, i)
    local last = string.find(data, "\0", i, true)
    if not last then
        return nil, nil
    end
    return string.sub(data, i, last - 1), last + 1
end

local function _to_cstring(data)
    return data .. "\0"
end

local function _to_binary_coded_string(data)
    return strchar(#data) .. data
end


local function _dump(data)
    local len = #data
    local bytes = {}
    for i = 1, len do
        bytes[i] = format("%x", strbyte(data, i))
    end
    return concat(bytes, " ")
end

local function _dumphex(data)
    local len = #data
    local bytes = {}
    for i = 1, len do
        bytes[i] = tohex(strbyte(data, i), 2)
    end
    return concat(bytes, " ")
end

local function _compute_token(password, scramble)
    if password == "" then
        return ""
    end

    local stage1 = UtilsSha1(password)
    local stage2 = UtilsSha1(stage1)
    local stage3 = UtilsSha1(scramble .. stage2)
    local n = #stage1
    local bytes = {}
    for i = 1, n do
         bytes[i] = strchar(bxor(strbyte(stage3, i), strbyte(stage1, i)))
    end

    return concat(bytes)
end

local function _send_packet(self, req, size)
    local tcpsession = self.tcpsession

    self.packet_no = self.packet_no + 1

    local packet = _set_byte3(size) .. strchar(self.packet_no) .. req

    return tcpsession:send(packet)
end

local function _recv_packet(self)
    local data, err = self.tcpsession:receive(4)
    if not data then
        return nil, nil, "failed to receive packet header: " .. err
    end
	
    local len, pos = _get_byte3(data, 1)

    if len == 0 then
        return nil, nil, "empty packet"
    end

    if len > self._max_packet_size then
        return nil, nil, "packet size too big: " .. len .. "max len:" .. self._max_packet_size
    end
    local num = strbyte(data, pos)
	
    self.packet_no = num

    data, err = self.tcpsession:receive(len)

    if not data then
        return nil, nil, "failed to read packet content: " .. err
    end

    local field_count = strbyte(data, 1)

    local typ
    if field_count == 0x00 then
        typ = "OK"
    elseif field_count == 0xff then
        typ = "ERR"
    elseif field_count == 0xfe then
        typ = "EOF"
    elseif field_count <= 250 then
        typ = "DATA"
    end

    return data, typ
end

local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    if not first then
        return nil, pos
    end

    if first >= 0 and first <= 250 then
        return first, pos + 1
    end

    if first == 251 then
        return null, pos + 1
    end

    if first == 252 then
        pos = pos + 1
        return _get_byte2(data, pos)
    end

    if first == 253 then
        pos = pos + 1
        return _get_byte3(data, pos)
    end

    if first == 254 then
        pos = pos + 1
        return _get_byte8(data, pos)
    end

    return false, pos + 1
end

local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == nil or len == null then
        return null, pos
    end

    return sub(data, pos, pos + len - 1), pos + len
end


local function _parse_ok_packet(packet)
    local res = {}
    local pos

    res.affected_rows, pos = _from_length_coded_bin(packet, 2)
    res.insert_id, pos = _from_length_coded_bin(packet, pos)
    res.server_status, pos = _get_byte2(packet, pos)
    res.warning_count, pos = _get_byte2(packet, pos)

    local message = sub(packet, pos)
    if message and message ~= "" then
        res.message = message
    end

    return res
end

local function _parse_eof_packet(packet)
    local pos = 2

    local warning_count, pos = _get_byte2(packet, pos)
    local status_flags = _get_byte2(packet, pos)

    return warning_count, status_flags
end


local function _parse_err_packet(packet)
    local errno, pos = _get_byte2(packet, 2)
    local marker = sub(packet, pos, pos)
    local sqlstate
    if marker == '#' then
        pos = pos + 1
        sqlstate = sub(packet, pos, pos + 5 - 1)
        pos = pos + 5
    end

    local message = sub(packet, pos)
    return errno, message, sqlstate
end

local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)
    local extra = _from_length_coded_bin(packet, pos)
    return field_count, extra
end

local function _parse_field_packet(data)
    local col = {}
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)

    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)

    pos = pos + 1 -- ignore the filler

    charsetnr, pos = _get_byte2(data, pos)

    length, pos = _get_byte4(data, pos)

    col.type = strbyte(data, pos)
	print("col.type is"..col.type..", col.name is:".. col.name)
    return col
end


local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row = {}
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type
        local name = col.name

        if value ~= null then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end

        if compact then
            row[i] = value
        else
            row[name] = value
        end
    end

    return row
end

local function _recv_field_packet(self)
    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, err
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ ~= 'DATA' then
        return nil, "bad field packet type: " .. typ
    end

    return _parse_field_packet(packet)
end

function MysqlSession:connect(tcpservice, ip, port, timeout, database, user, password)
    local tcpsession = self.tcpsession
    if tcpsession then
        return nil, "already initialized"
    end

    self._max_packet_size = 1024 * 1024 * 10

    self.compact = false

	self.tcpsession = tcpservice:connect(ip, port, timeout)

    if self.tcpsession == nil then
        return nil, 'failed to connect: '
    end

    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, err
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    self.protocol_ver = strbyte(packet)

    local server_ver, pos = _from_cstring(packet, 2)
    if not server_ver then
        return nil, "bad handshake initialization packet: bad server version"
    end

    self._server_ver = server_ver

    local thread_id, pos = _get_byte4(packet, pos)

    local scramble = sub(packet, pos, pos + 8 - 1)
    if not scramble then
        return nil, "1st part of scramble not found"
    end

    pos = pos + 9 -- skip filler

    local capabilities  -- server capabilities
    capabilities, pos = _get_byte2(packet, pos)

    self._server_lang = strbyte(packet, pos)
    pos = pos + 1

    self._server_status, pos = _get_byte2(packet, pos)

    local more_capabilities
    more_capabilities, pos = _get_byte2(packet, pos)

    capabilities = bor(capabilities, lshift(more_capabilities, 16))

    local len = 21 - 8 - 1

    pos = pos + 1 + 10

    local scramble_part2 = sub(packet, pos, pos + len - 1)
    if not scramble_part2 then
        return nil, "2nd part of scramble not found"
    end

    scramble = scramble .. scramble_part2

    local client_flags = 0x3f7cf

    local token = _compute_token(password, scramble)

    local req = _set_byte4(client_flags)
                .. _set_byte4(self._max_packet_size)
                .. "\0" -- TODO: add support for charset encoding
                .. strrep("\0", 23)
                .. _to_cstring(user)
                .. _to_binary_coded_string(token)
                .. _to_cstring(database)

    local packet_len = 4 + 4 + 1 + 23 + #user + 1
        + #token + 1 + #database + 1

	_send_packet(self, req, packet_len)

    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, "failed to receive the result packet: " .. err
    end

    if typ == 'ERR' then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ == 'EOF' then
        return nil, "old pre-4.1 authentication protocol not supported"
    end

    if typ ~= 'OK' then
        return nil, "bad packet type: " .. typ
    end

    self.state = STATE_CONNECTED
	
    return 1
end

local function send_query(self, query)
    if self.state ~= STATE_CONNECTED then
        return nil, "cannot send query in the current context: "
                    .. (self.state or "nil")
    end
	
    local tcpsession = self.tcpsession
    if not tcpsession then
        return nil, "not initialized"
    end

    self.packet_no = -1

    local cmd_packet = strchar(COM_QUERY) .. query
    local packet_len = 1 + #query

	_send_packet(self, cmd_packet, packet_len)

    self.state = STATE_COMMAND_SENT
end

local function read_result(self)
    if self.state ~= STATE_COMMAND_SENT then
        return nil, "cannot read result in the current context: "
                    .. (self.state or "nil")
    end

    local tcpsession = self.tcpsession
    if not tcpsession then
        return nil, "not initialized"
    end

    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, err
    end
	
    if typ == "ERR" then
        self.state = STATE_CONNECTED

        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ == 'OK' then
        local res = _parse_ok_packet(packet)
        if res and band(res.server_status, SERVER_MORE_RESULTS_EXISTS) ~= 0 then
            return res, "again"
        end

        self.state = STATE_CONNECTED
        return res
    end

    if typ ~= 'DATA' then
        self.state = STATE_CONNECTED
        return nil, "packet type " .. typ .. " not supported"
    end

    local field_count, extra = _parse_result_set_header_packet(packet)
    local cols = {}
    for i = 1, field_count do
        local col, err, errno, sqlstate = _recv_field_packet(self)
        if not col then
            return nil, err, errno, sqlstate
        end

        cols[i] = col
    end

    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, err
    end

    if typ ~= 'EOF' then
        return nil, "unexpected packet type " .. typ .. " while eof packet is "
            .. "expected"
    end

    local compact = self.compact

    local rows = {}
    local i = 0
    while true do
        packet, typ, err = _recv_packet(self)
        if not packet then
            return nil, err
        end

        if typ == 'EOF' then
            local warning_count, status_flags = _parse_eof_packet(packet)

            if band(status_flags, SERVER_MORE_RESULTS_EXISTS) ~= 0 then
                return rows, "again"
            end

            break
        end

        local row = _parse_row_data_packet(packet, cols, compact)
        i = i + 1
        rows[i] = row
    end

    self.state = STATE_CONNECTED

    return rows
end

function MysqlSession:query(query)
	send_query(self, query)
    return read_result(self)
end

local function MysqlSessionNew(p)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.tcpsession = nil
    o.state = STATE_NONE
    o.compact = false
    o.pendingQueryCo = {}
    o.queryControl = nil

    return o
end

return {
    New = function () return MysqlSessionNew(MysqlSession) end
}