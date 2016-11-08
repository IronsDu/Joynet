require "Scheduler"
local AsyncConnect = require "Connect"
local TcpSession = require "TcpSession"

local __TcpServiceList = {}

function __on_enter__(serviceID, socketID)
    __TcpServiceList[serviceID].entercallback(serviceID, socketID)
end

function __on_close__(serviceID, socketID)
    __TcpServiceList[serviceID].closecallback(serviceID, socketID)
end

function __on_data__(serviceID, socketID, data, len)
    return __TcpServiceList[serviceID].datacallback(serviceID, socketID, data, len)
end

function __on_connected__(serviceID, socketID, uid)
    __TcpServiceList[serviceID].connected(serviceID, socketID, uid)
end

local TcpService = {
}

local function TcpServiceNew(p)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.serviceID = -1
    o.acceptSessions = {}
    o.sessions = {}
    o.connectedCo = {}
    o.connectedSessions = {}
    
    o.entercallback = nil
    o.closecallback = nil
    o.datacallback = nil
    o.connected = nil

    return o
end

function TcpService:findSession(socketID)
    return self.sessions[socketID]
end

function TcpService:createService()
    if self.serviceID ~= -1 then
        return
    end

    local serviceID = CoreDD:createTCPService()
    self.serviceID = serviceID
    __TcpServiceList[serviceID] = self

    self.closecallback = function (serviceID, socketID)
        local session = self.sessions[socketID]
        if session ~= nil then
            session:setClose(true)
            session:wakeupRecv()
        end

        self.sessions[socketID] = nil
    end

    self.datacallback = function (serviceID, socketID, data, len)
        local session = self.sessions[socketID]
        return session:parseData(data, len)
    end

    self.connected = function (serviceID, socketID, uid)
        local waitCo = self.connectedCo[uid]
        if waitCo ~= nil then
            local session = TcpSession:New()
            session:init(serviceID, socketID)

            self.connectedSessions[uid] = session
            self.sessions[socketID] = session
            self.connectedCo[uid] = nil
            coroutine_wakeup(waitCo)
        else
            CoreDD:closeTcpSession(serviceID, socketID)
        end
    end
end

function TcpService:listen(ip, port)
    self:createService()
    if self.entercallback  == nil then
        CoreDD:listen(self.serviceID, ip, port)    --开启监听服务

        self.entercallback = function (serviceID, socketID)
            local session = TcpSession:New()
            session:init(serviceID, socketID)

            table.insert(self.acceptSessions, session)
            self.sessions[socketID] = session
            self:wakeupAccept()
        end
    end
end

function TcpService:connect(ip, port, timeout, useOpenSSL)
    if useOpenSSL == nil then
        useOpenSSL = false
    end
    
    local uid = AsyncConnect.AsyncConnect(ip, port, timeout, function (fd, uid)
        local isFailed = fd == -1
        if not isFailed then
            isFailed = not CoreDD:addSessionToService(self.serviceID, fd, uid, useOpenSSL)
        end

        if isFailed then
            local waitCo = self.connectedCo[uid]
            if waitCo ~= nil then
                self.connectedCo[uid] = nil
                coroutine_wakeup(waitCo)
            end
        end
    end)

    self.connectedCo[uid] = coroutine_running()
    coroutine_sleep(coroutine_running(), timeout)
    --寻找uid对应的session
    local session = self.connectedSessions[uid]
    self.connectedSessions[uid] = nil
    self.connectedCo[uid] = nil

    return session
end

function TcpService:accept(timeout)
    if timeout == nil then
        timeout = 1000
    end

    local newClient = nil
    local hasData = false

    self.acceptCo = coroutine_running()
    if next(self.acceptSessions) == nil then
        coroutine_sleep(self.acceptCo, timeout)
        hasData = next(self.acceptSessions) ~= nil
    else
        hasData = true
    end

    self.acceptCo = nil
    
    if hasData then
        newClient = self.acceptSessions[1]
        table.remove(self.acceptSessions, 1)
    end

    return newClient
end

function TcpService:wakeupAccept()
    if self.acceptCo ~= nil then
        coroutine_wakeup(self.acceptCo)
        self.acceptCo = nil
    end
end

return {
    New = function () return TcpServiceNew(TcpService) end
}