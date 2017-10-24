package.cpath = './libs/RPC/?.so;./libs/RPC/?.dll;'

local Queue = require "queue"
local protobuf = require "protobuf"
local Lock = require "lock"
local RpcRequest = require "RPCRequest"
local RPCCall = require "RPCCall"
local RPCServiceMgr = require "RPCServiceMgr"
local RPCDefine = require "RPCDefine"
local REQUEST = RPCDefine.REQUEST
local RESPONSE = RPCDefine.RESPONSE
local POSTMSG = RPCDefine.POSTMSG

--RPC服务对象

protobuf.register_file "ServiceRPC.pb"

local nextServiceIncID = 0
local serviceTableOfName = {}
local serviceTableOfID = {}

local service = {}

local function serviceNew(p, scheduler)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    nextServiceIncID = nextServiceIncID + 1
    
    o.serviceID = (os.time() << 32) | nextServiceIncID
    o.name = nil
    --使用两个Queue:request(包括postmsg类型) 和 response
    --为了避免(使用一个queue时)在A协程调用rpcCall(等待response)时，另外的协程B调用recvRequest。而另外的服务发送了response到了B的问题。
    o.requestChan = Queue.New()
    o.requestBlock = Queue.New()
    
    o.responseChan = Queue.New()
    o.responseBlock = Queue.New()
    
    o.nextRequestID = 0
    o.rpcCallGuard = Lock.New(scheduler)
    o.scheduler = scheduler
    
    RPCServiceMgr.AddServiceByID(o, o.serviceID)
  
    return o
end

function service:pushRequest(...)
    self.requestChan:Push({...})
    local coObject = self.requestBlock:Pop()  
    if coObject then
        self.scheduler:ForceWakeup(coObject)
    end
end

--err, req id, data
function service:pushResponse(...)
    self.responseChan:Push({...})
    local coObject = self.responseBlock:Pop()  
    if coObject then
        self.scheduler:ForceWakeup(coObject)
    end
end

function service:getName()
    return self.name
end

function service:getID()
    return self.serviceID
end

local function serviceRecvRequest(self, timeout)
    if timeout == nil then
        timeout = 10000
    end
    
    local msg = self.requestChan:Pop()
    if not msg then
        local coObject = self.scheduler:Running()
        self.requestBlock:Push(coObject)
        self.scheduler:Sleep(coObject, timeout)
        msg = self.requestChan:Pop()
        if msg == nil and self.requestBlock:Front() == coObject then
            self.requestBlock:Pop()
        end
    end
    
    if msg ~= nil then
        return nil, table.unpack(msg)
    else
        return "timeout", nil
    end
end

local function serviceRecvResponse(self, timeout)
    if timeout == nil then
        timeout = 10000
    end
    
    local msg = self.responseChan:Pop()
    if not msg then
        local coObject = self.scheduler:Running()
        self.responseBlock:Push(coObject)
        self.scheduler:Sleep(coObject, timeout)
        msg = self.responseChan:Pop()
        if msg == nil and self.responseBlock:Front() == coObject then
            self.responseBlock:Pop()
        end
    end
    
    if msg ~= nil then
        return table.unpack(msg)
    else
        return "timeout", nil
    end
end

function service:recvRequest(timeout)
    local err, _remoteAddr, _remotePort, _callerServiceID, _callerReqID, _type, _data =  serviceRecvRequest(self)
    if err ~= nil then
        return err, nil
    else
        return nil, RpcRequest.New(_remoteAddr, _remotePort, _callerServiceID, _callerReqID, _type, _data)
    end
end

function service:recvResponse(timeout)
    return serviceRecvResponse(self, timeout)
end

--同步RPC调用(需要传递调用者service参数,且对他加锁,避免多个协程同时使用一个RPCService对象调用其它服务可能造成response乱序问题)
function service:SyncCall(remoteIP, remotePort, remoteService, data)
    self.rpcCallGuard:Lock()
    local remoteServiceID = nil
    local remoteServiceName = nil
    if type(remoteService) == "string" then
        remoteServiceName = remoteService
    else
        remoteServiceID = remoteService
    end
    
    local err, _response = RPCCall.RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, REQUEST, data, 0, self)
    self.rpcCallGuard:Unlock()
    return err, _response
end

--TODO::加锁(并返回是否成功)(避免多个协程同时注册重复的本地服务名称)
function service:setName(name)
    self.name = name
    RPCServiceMgr.AddServiceByName(self, name)
    return true
end

return {
    New = function(scheduler) return serviceNew(service, scheduler) end,
}