--tks https://github.com/azurewang/lua-resty-postgres

local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local strpack = string.pack
local strunpack = string.unpack

local PGSession = {
}

local STATE_NONE = 0
local STATE_CONNECTED = 1

local AUTH_REQ_OK = "\00\00\00\00"

local function PGSessionNew(p)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.tcpsession = nil
    o.env = {}
    o.state = STATE_NONE
    o.compact = false
    o.pendingQueryCo = {}
    o.queryControl = nil

    return o
end

local function _set_byte2(n)
    return strpack(">I2", n)
end

local function _set_byte4(n)
    return strpack(">I4", n)
end

local function _get_byte2(data, i)
    return strunpack(">I2", data, i)
end

local function _get_byte4(data, i)
    return strunpack(">I4", data, i)
end

local function _send_req(session, req, len, typ)
    if typ then
        session:send(typ)
    end

    session:send(_set_byte4(len))

    for i,v in ipairs(req) do
        session:send(v)
    end
end

local function _recv_packet(session)
    local typ = session:receive(1)
    if not typ then
        return nil, nil, "receive timeout"
    end

    local data = session:receive(4)
    local len = _get_byte4(data, 1)
    if len <= 4 then
        return nil, typ, "len is error"
    end

    data = session:receive(len - 4)
    if not data then
        return nil, nil, "receive timeout"
    end

    return data, typ
end

local function _from_cstring(data, i)
    local last = string.find(data, "\0", i, true)
    if not last then
        return nil, nil
    end
    return string.sub(data, i, last - 1), last + 1
end

local function _parse_error_packet(packet)
    local pos = 1
    local flg, value, msg
    msg = {}
    while true do
       flg = string.sub(packet, pos, pos)
       if not flg then
           return nil, "parse error packet fail"
       end
       pos = pos + 1
       if flg == '\0' then
          break
       end
       -- all flg S/C/M/P/F/L/R
       value, pos = _from_cstring(packet, pos)
       if not value then
           return nil, "parse error packet fail"
       end
       msg[flg] = value
   end
   return msg
end

function PGSession:connect(tcpservice, ip, port, timeout, database, user, password)
    if self.tcpsession ~= nil then
        return true, nil
    end

    local isOK, err = self:_connect(tcpservice, ip, port, timeout, database, user, password)
    self.tcpsession:releaseControl()
    if not isOK and self.tcpsession ~= nil then
        self.tcpsession:postClose()
        self.tcpsession = nil
    end

    return isOK, err
end

function PGSession:_connect(tcpservice, ip, port, timeout, database, user, password)
    self.tcpsession = tcpservice:connect(ip, port, timeout)
    if self.tcpsession == nil then
        return false, "connect failed"
    end

    local req = {}
    local req_len = 0

    table.insert(req, "\00\03")
    table.insert(req, "\00\00")

    table.insert(req, "user")
    table.insert(req, "\0")
    table.insert(req, user)
    table.insert(req, "\0")

    table.insert(req, "database")
    table.insert(req, "\0")
    table.insert(req, database)
    table.insert(req, "\0")
    
    table.insert(req, "\00")

    req_len = string.len(user) + string.len(database) + 25
    _send_req(self.tcpsession, req, req_len)

    local packet, typ, err = _recv_packet(self.tcpsession)
    if not packet then
        return false, "handshake error:"..err
    end

    if typ == 'E' and packet ~= nil then
        local msg = _parse_error_packet(packet)
        return false,  "handshake failed, error:" .. msg.M
    elseif typ ~= 'R' then
        return false, "handshake error, got packet type:" .. typ
    end

    local auth_type = string.sub(packet, 1, 4)
    local salt = string.sub(packet, 5, 8)
    req = {}

    local token1 = UtilsMd5(password..user)
    local token2 = UtilsMd5(token1 .. salt)
    local token = "md5" .. token2
    table.insert(req, token)
    table.insert(req, "\0")
    req_len = 40
    _send_req(self.tcpsession, req, req_len, 'p')
    packet, typ, err = _recv_packet(self.tcpsession)

    if typ == 'E' and packet ~= nil then
        local msg = _parse_error_packet(packet)
        return false,  "authentication failed, error:" .. msg.M
    elseif typ ~= 'R' then
        return false,  "auth return type not support, type is :"..tostring(typ)
    end

    if packet ~= AUTH_REQ_OK then
        return false,  "authentication failed"
    end

    while true do
        packet, typ, err = _recv_packet(self.tcpsession)
        if not packet then
            return false,  "read packet error:"..err
        end

        if typ == 'S' then
            local pos = 1
            local k, pos = _from_cstring(packet, pos)
            local v, pos = _from_cstring(packet, pos)
            self.env[k] = v
        end

        -- secret key
        if typ == 'K' then
            local pid = _get_byte4(packet, 1)
            local secret_key = string.sub(packet, 5, 8)
            self.env.secret_key = secret_key
            self.env.pid = pid
        end
        -- error
        if typ == 'E' then
            local msg = _parse_error_packet(packet)
            return false,  "Get error packet:" .. msg.M
        end
        -- ready for new query
        if typ == 'Z' then
            self.state = STATE_CONNECTED
            break
        end
    end

    return true, nil
end

local converters = {}
-- INT8OID
converters[20] = tonumber
-- INT2OID
converters[21] = tonumber
-- INT2VECTOROID
converters[22] = tonumber
-- INT4OID
converters[23] = tonumber
-- FLOAT4OID
converters[700] = tonumber
-- FLOAT8OID
converters[701] = tonumber
-- NUMERICOID
converters[1700] = tonumber

local function _get_data_n(data, len, i)
    local d = string.sub(data, i, i+len-1)
    return d, i+len
end

local function _read_result(self)
    local res = {}
    local fields = {}
    local field_ok = false
    local packet, typ, recvError
    local queryError

    while true do
        packet, typ, recvError = _recv_packet(self.tcpsession)
        if not packet then
            return nil, "read result packet error:"..recvError
        end

        if typ == 'T' then
            local field_num, pos = _get_byte2(packet, 1)
            for i=1, field_num do
                local field = {}
                field.name, pos = _from_cstring(packet, pos)
                field.table_id, pos = _get_byte4(packet, pos)
                field.field_id, pos = _get_byte2(packet, pos)
                field.type_id, pos  = _get_byte4(packet, pos)
                field.type_len, pos = _get_byte2(packet, pos)
                -- pass atttypmod, format
                pos = pos + 6
                table.insert(fields, field)
            end
            field_ok = true
        end

        -- packet of data row
        if typ == 'D' then
            if not field_ok then
                return nil, "not receive fields packet"
            end
            local row = {}
            local row_num, pos = _get_byte2(packet, 1)
            -- get row
            for i=1, row_num do
                local data, len
                len, pos = _get_byte4(packet, pos)
                if len == -1 then
                    data = ""
                else
                    data, pos = _get_data_n(packet, len, pos)
                end
                local field = fields[i]
                local conv = converters[field.type_id]
                if conv and data ~= "" then
                    data = conv(data)
                end
                if self.compact then
                    table.insert(row, data)
                else
                    local name = field.name
                    row[name] = data
                end
            end 
            table.insert(res, row)
        end

        if typ == 'E' then
            -- error packet
            local msg = _parse_error_packet(packet)
            queryError = msg.M
            res = nil
        end

        if typ == 'C' then
            -- read complete
            local sql_type = _from_cstring(packet, 1)
            self.env.sql_type = sql_type
            queryError = nil
        end
        if typ == 'Z' then
            self.state = STATE_CONNECTED
            break
        end
    end

    return res, queryError
end

function PGSession:query(query)
    if self.state == STATE_NONE then
        return nil, "not connect"
    end

    local current = coroutine_running()
    if self.queryControl ~= nil and self.queryControl ~= current then

        --同时只允许一个协程进行query,存在进行中的query时，其他协程需要等待
        table.insert(self.pendingQueryCo, current)

        while true do   
            coroutine_sleep(current, 1000)
            if self.queryControl == current then
                break
            end
        end
    else
        self.queryControl = current
    end

    local req = {}
    table.insert(req, query)
    table.insert(req, "\0")
    local req_len = string.len(query) + 5
    _send_req(self.tcpsession, req, req_len, 'Q')

    local res, err = _read_result(self)
    self.tcpsession:releaseControl()

    if self.tcpsession:isClose() then
        self.state = STATE_NONE
        self.tcpsession = nil
    end

    if self.queryControl == coroutine_running() then
        self.queryControl = nil
        if next(self.pendingQueryCo) ~= nil then
            --激活队列首部的协程
            self.queryControl = self.pendingQueryCo[1]
            table.remove(self.pendingQueryCo, 1)
            coroutine_wakeup(self.queryControl)
        end
    end

    return res, err
end

return {
    New = function () return PGSessionNew(PGSession) end
}