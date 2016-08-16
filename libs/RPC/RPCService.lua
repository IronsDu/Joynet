local LinkQue = require "linkque"
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

if true then
    local addr = io.open("ServiceRPC.pb","rb")
    if addr ~= nil then
        local buffer = addr:read "*a"
        addr:close()
        protobuf.register(buffer)
    else
        print("failed open ServiceRPC.pb")
    end
end

local nextServiceIncID = 0
local serviceTableOfName = {}
local serviceTableOfID = {}

local service = {}

function service:new()
    local o = {}
    self.__index = self      
    setmetatable(o,self)
    
    nextServiceIncID = nextServiceIncID + 1
    
    o.serviceID = (os.time() << 32) | nextServiceIncID
    o.name = nil
    --使用两种channel:request(包括postmsg类型) 和 response
    --为了避免(使用一个channel时)在A协程调用rpcCall(等待response)时，另外的协程B调用recvRequest。而另外的服务发送了response到了B的问题。
    o.requestChan = LinkQue.New()
    o.requestBlock = LinkQue.New()
    o.responseChan = LinkQue.New()
    o.responseBlock = LinkQue.New()
    o.nextRequestID = 0
    o.rpcCallGuard = Lock.New()
    
    RPCServiceMgr.AddServiceByID(o, o.serviceID)
  
  return o
end

function service:pushRequest(...)
    self.requestChan:Push({...})
    local coObject = self.requestBlock:Pop()  
    if coObject then
        coroutine_wakeup(coObject)
    end
end

--err, req id, data
function service:pushResponse(...)
    self.responseChan:Push({...})
    local coObject = self.responseBlock:Pop()  
    if coObject then
        coroutine_wakeup(coObject)
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
        local coObject = coroutine_running()
        self.requestBlock:Push(coObject)
        coroutine_sleep(coObject, timeout)
        msg = self.requestChan:Pop()
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
        local coObject = coroutine_running()
        self.responseBlock:Push(coObject)
        coroutine_sleep(coObject, timeout)
        msg = self.responseChan:Pop()
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
function service:SyncCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, data)
    self.rpcCallGuard:Lock()
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
    New = function () return service:new() end,
}