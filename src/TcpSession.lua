require "Scheduler"

local TcpSession = {
}

local function TcpSessionNew(p, joynet, scheduler)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.joynet = joynet
    o.scheduler = scheduler
    o.serviceID = -1
    o.socketID = -1
    o.isClosed = false
    o.recvCo = nil
    o.pendingWaitCo = {}
    o.cacheRecv = ""
    o.controlRecvCo = nil
    o.isWaitLen = true
    o.waitLen = 0
    o.waitStr = ""

    return o
end

function TcpSession:init(serviceID, socketID)
    self.serviceID = serviceID
    self.socketID = socketID
end

function TcpSession:setClose()
    self.isClosed = true
end

function TcpSession:isClose()
    return self.isClosed
end

function TcpSession:postClose()
    self.joynet:closeTcpSession(self.serviceID, self.socketID)
end

function TcpSession:postShutdown()
    self.joynet:shutdownTcpSession(self.serviceID, self.socketID)
end

function TcpSession:parseData(data, len)
    self.cacheRecv = self.cacheRecv..data
    if self.recvCo ~= nil then
        local mustWakeup = false
        if self.isWaitLen then
            mustWakeup = string.len(self.cacheRecv) >= self.waitLen
        else
            local s, e = string.find(self.cacheRecv, self.waitStr)
            mustWakeup = s ~= nil
        end

        if mustWakeup then
            self:wakeupRecv()
        end
    end
    
    return len
end

function TcpSession:releaseRecvLock()
    if self.controlRecvCo == self.scheduler:Running() then
        self.controlRecvCo = nil
        if next(self.pendingWaitCo) ~= nil then
            --激活队列首部的协程
            self.controlRecvCo = self.pendingWaitCo[1]
            table.remove(self.pendingWaitCo, 1)
            self.scheduler:ForceWakeup(self.controlRecvCo)
        end
    end
end

function TcpSession:recvLock()
    local current = self.scheduler:Running()

    if self.controlRecvCo ~= nil and self.controlRecvCo ~= current then
        --等待获取控制权
        table.insert(self.pendingWaitCo, current)

        while true do    
            self.scheduler:Sleep(current, timeout)
            if self.controlRecvCo == current then
                break
            end
        end
    else
        self.controlRecvCo = current
    end
end

function TcpSession:receive(len, timeout)
    if timeout == nil or timeout < 0 then 
        timeout = 1000
    end

    if len <= 0 then
        return nil, "len <= 0"
    end

    self:recvLock()
	
	if self:isClose() then
		return nil, "socket is closed"
	end

    if string.len(self.cacheRecv) < len then
        self.recvCo = self.scheduler:Running()
        self.isWaitLen = true
        self.waitLen = len
        self.scheduler:Sleep(self.recvCo, timeout)
        self.recvCo = nil
    end

    local ret = nil
	local err = nil
    if string.len(self.cacheRecv) >= len then
        ret = string.sub(self.cacheRecv, 1, len)
        self.cacheRecv = string.sub(self.cacheRecv, len+1, string.len(self.cacheRecv))
	else
		err = "timeout"
    end

    return ret, err
end

function TcpSession:receiveUntil(str, timeout)
    if timeout == nil or timeout < 0 then 
        timeout = 1000
    end

    if str == "" then
        return nil, "str is empty"
    end

    self:recvLock()
	
	if self:isClose() then
		return nil, "socket is closed"
	end
	
    local s, e = string.find(self.cacheRecv, str)
    if s == nil then
        self.recvCo = self.scheduler:Running()
        self.isWaitLen = false
        self.waitStr = str
        self.scheduler:Sleep(self.recvCo, timeout)
        self.recvCo = nil
        s, e = string.find(self.cacheRecv, str)
    end

    local ret = nil
	local err = nil
	
    if s ~= nil then
        ret = string.sub(self.cacheRecv, 1, s-1)
        self.cacheRecv = string.sub(self.cacheRecv, e+1, string.len(self.cacheRecv))
	else
		err = "timeout"
    end

    return ret
end

function TcpSession:wakeupRecv()
    if self.recvCo ~= nil then
        self.scheduler:ForceWakeup(self.recvCo)
        self.recvCo = nil
    end
end

function TcpSession:send(data)
    self.joynet:sendToTcpSession(self.serviceID, self.socketID, data, string.len(data))
end

return {
    New = function (joynet, scheduler) return TcpSessionNew(TcpSession, joynet, scheduler) end
}