local byte = string.byte
local char = string.char

local WebSocketSession = {
}

local types = {
    [0x0] = "continuation",
    [0x1] = "text",
    [0x2] = "binary",
    [0x8] = "close",
    [0x9] = "ping",
    [0xa] = "pong",
}

function WebSocketSession:setSession(session)
    self.session = session
end

function WebSocketSession:setMasking()
    self.masking = true
end

local function _acceptHandshake(self)
    local session = self.session
    if session ~= nil then
        -- 开始读取(解析)http response
        local packet, err = session:receiveUntil("\r\n", 10000)
        local secKey = nil
        --读取多行头部
        while true do
            packet = session:receiveUntil("\r\n", 10000)
            if packet ~= nil then
                if #packet == 0 then
                    break
                end
                
                if secKey == nil  then
                    local s, e = string.find(packet, "Sec%-WebSocket%-Key: ")
                    if s ~= nil and e ~= nil then
                        secKey = string.sub(packet, e+1, string.len(packet))
                    end
                end
            else
                break
            end
        end
        
        if secKey ~= nil then
            local resp = UtilsWsHandshakeResponse(secKey)
            session:send(resp)
            return true
        end
    end
    
    return false
end

local function _checkDisconnectAndReleaseRecvLock(self)
    if self.tcpsession ~= nil then
        self.tcpsession:releaseRecvLock()
        if self.tcpsession:isClose() then
            self.tcpsession = nil
        end
    end
end

function WebSocketSession:acceptHandshake()
    local isAccept = _acceptHandshake(self)
    _checkDisconnectAndReleaseRecvLock(self)
    
    return isAccept
end

local function _connectHandshake(self, url)
    local session = self.session
    local isAccept = false
    
    if session ~= nil then
        local request_str = "GET "..url.." HTTP/1.1\r\n"
                            .."Upgrade: websocket\r\n"
                            .."Host: 127.0.0.1\r\n"
                            .."Connection: Upgrade\r\n"
                            .."Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                            .."Sec-WebSocket-Version: 13\r\n"
                            .."\r\n"
        session:send(request_str)
        -- 开始读取(解析)http response
        local packet, err = session:receiveUntil("\r\n", 10000)
        --读取多行头部
        while true do
            packet = session:receiveUntil("\r\n", 10000)
            if packet ~= nil then
                if #packet == 0 then
                    break
                end
                
                if not isAccept  then
                    local s, e = string.find(packet, "Sec%-WebSocket%-Accept")
                    isAccept = s ~= nil
                end
            else
                break
            end
        end
    end
    
    return isAccept
end

function WebSocketSession:connectHandshake(url)
    local isAccept = _connectHandshake(self, url)
    _checkDisconnectAndReleaseRecvLock(self)
    
    return isAccept
end

local function build_frame(fin, opcode, payload_len, payload, masking)
    local fst
    if fin then
        fst = (0x80 | opcode)
    else
        fst = opcode
    end

    local snd, extra_len_bytes
    if payload_len <= 125 then
        snd = payload_len
        extra_len_bytes = ""

    elseif payload_len <= 65535 then
        snd = 126
        extra_len_bytes = char((payload_len >> 8)&0xff,
                                        (payload_len&0xff))

    else
        if (payload_len&0x7fffffff) < payload_len then
            return nil, "payload too big"
        end

        snd = 127
        -- XXX we only support 31-bit length here
        extra_len_bytes = char(0, 0, 0, 0, (payload_len>>24)& 0xff,
                                                    (payload_len>> 16)&0xff,
                                                    (payload_len>> 8)&0xff,
                                                    payload_len&0xff)
    end

    local masking_key
    if masking then
        -- set the mask bit
        snd = (snd|0x80)
        local key = math.random(0xffffffff)
        masking_key = char((key>>24)&0xff,
                                    (key>>16)&0xff,
                                    (key>>8)&0xff,
                                    key&0xff)

        -- TODO string.buffer optimizations
        local bytes = {}
        for i = 1, payload_len do
            bytes[i] = char((byte(payload, i) ~ byte(masking_key, (i - 1) % 4 + 1)))
        end
        payload = table.concat(bytes)

    else
        masking_key = ""
    end
    
    return char(fst, snd) .. extra_len_bytes .. masking_key .. payload
end

function WebSocketSession:sendText(content)
    self.session:send(build_frame(true, 0x1, #content, content, self.masking))
end

function WebSocketSession:sendBinary(content)
    self.session:send(build_frame(true, 0x2, #content, content, self.masking))
end

function WebSocketSession:sendClose(code, msg)
    local payload
    if code then
        if type(code) ~= "number" or code > 0x7fff then
        end
        payload = char(((code<<8)&0xff), (code&0xff))
                        .. (msg or "")
    end
    self.session:send(build_frame(true, 0x8, #payload, payload, self.masking))
end

function WebSocketSession:sendPing(content)
    self.session:send(build_frame(true, 0x9, #content, content, self.masking))
end

function WebSocketSession:sendPong(content)
    self.session:send(build_frame(true, 0xa, #content, content, self.masking))
end

local function _readFrame(self, force_masking)
    local session = self.session
    if session == nil then
        return nil, nil, "not connected"
    end
    
    local data, err = session:receive(2, 10000)
    
    if not data then
        return nil, nil, "failed to receive the first 2 bytes: " .. err
    end

    local fst, snd = byte(data, 1, 2)

    local fin = (fst&0x80) ~= 0

    if (fst&0x70) ~= 0 then
        return nil, nil, "bad RSV1, RSV2, or RSV3 bits"
    end

    local opcode = (fst&0x0f)

    if opcode >= 0x3 and opcode <= 0x7 then
        return nil, nil, "reserved non-control frames"
    end

    if opcode >= 0xb and opcode <= 0xf then
        return nil, nil, "reserved control frames"
    end

    local mask = (snd&0x80) ~= 0

    if force_masking and not mask then
        return nil, nil, "frame unmasked"
    end

    local payload_len = (snd&0x7f)

    if payload_len == 126 then
        local data, err = session:receive(2, 10000)
        if not data then
            return nil, nil, "failed to receive the 2 byte payload length: "
                             .. (err or "unknown")
        end

        payload_len = (byte(data, 1)<<8) | byte(data, 2)

    elseif payload_len == 127 then
        local data, err = session:receive(8, 10000)
        if not data then
            return nil, nil, "failed to receive the 8 byte payload length: "
                             .. (err or "unknown")
        end

        if byte(data, 1) ~= 0
           or byte(data, 2) ~= 0
           or byte(data, 3) ~= 0
           or byte(data, 4) ~= 0
        then
            return nil, nil, "payload len too large"
        end

        local fifth = byte(data, 5)
        if (fifth&0x80) ~= 0 then
            return nil, nil, "payload len too large"
        end

        payload_len = ((fifth<<24) |
                          (byte(data, 6)<<16) |
                          (byte(data, 7)<< 8) |
                            byte(data, 8))
    end

    if (opcode&0x8) ~= 0 then
        -- being a control frame
        if payload_len > 125 then
            return nil, nil, "too long payload for control frame"
        end

        if not fin then
            return nil, nil, "fragmented control frame"
        end
    end

    local rest
    if mask then
        rest = payload_len + 4

    else
        rest = payload_len
    end

    local data
    if rest > 0 then
        data, err = session:receive(rest, 10000)
        if not data then
            return nil, nil, "failed to read masking-len and payload: "
                             .. (err or "unknown")
        end
    else
        data = ""
    end

    if opcode == 0x8 then
        -- being a close frame
        if payload_len > 0 then
            if payload_len < 2 then
                return nil, nil, "close frame with a body must carry a 2-byte"
                                 .. " status code"
            end

            local msg, code
            if mask then
                local fst = (byte(data, 4 + 1) ~ byte(data, 1))
                local snd = (byte(data, 4 + 2) ~ byte(data, 2))
                code = ((fst<<8) | snd)

                if payload_len > 2 then
                    -- TODO string.buffer optimizations
                    local bytes = {}
                    for i = 3, payload_len do
                        bytes[i - 2] = char((byte(data, 4 + i) ~
                                                            byte(data, (i - 1) % 4 + 1)))
                    end
                    msg = table.concat(bytes)

                else
                    msg = ""
                end

            else
                local fst = byte(data, 1)
                local snd = byte(data, 2)
                code = ((fst<< 8)|snd)

                if payload_len > 2 then
                    msg = string.sub(data, 3)
                else
                    msg = ""
                end
            end

            return msg, "close", code
        end

        return "", "close", nil
    end

    local msg
    if mask then
        -- TODO string.buffer optimizations
        local bytes = {}
        for i = 1, payload_len do
            bytes[i] = char((byte(data, 4 + i) ~
                                     byte(data, (i - 1) % 4 + 1)))
        end
        msg = table.concat(bytes)

    else
        msg = data
    end
    return msg, types[opcode], not fin and "again" or nil
end

function WebSocketSession:readFrame(force_masking)
    local msg, t, err = _readFrame(self, force_masking)
    _checkDisconnectAndReleaseRecvLock(self)
    
    return msg, t, err
end

local function WebSocketSessionNew(p)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.session = nil
    o.masking = true
    
    return o
end

return {
    New = function () return WebSocketSessionNew(WebSocketSession) end
}