local RPCCall = require "RPCCall"

local RPCDefine = require "RPCDefine"
local REQUEST = RPCDefine.REQUEST
local RESPONSE = RPCDefine.RESPONSE
local POSTMSG = RPCDefine.POSTMSG

--定义RPC服务收到的RPC请求结构

local RpcRequest = {}

function RpcRequest:new(remoteAddr, remotePort, _callerServiceID, _callerReqID, _type, _data)
    local o = {}
    self.__index = self
    setmetatable(o,self)
  
    o._remoteAddr = remoteAddr
    o._remotePort = remotePort
    o._type = _type
    o._callerServiceID = _callerServiceID
    o._callerReqID = _callerReqID
    o._data = _data
    return o
end

function RpcRequest:isSync()
    return self._type == REQUEST
end

function RpcRequest:getData()
    return self._data
end

function RpcRequest:reply(data)
    if self:isSync() then
        --TODO::err用nil代替"",目前在table.unpack(nil, ...)会出现问题
        RPCCall.RPCReply(self._remoteAddr, self._remotePort, self._callerServiceID, data, "", self._callerReqID)
    end
end

return {
    New =   function (remoteAddr, remotePort, _callerServiceID, _callerReqID, _type, _data)
                return RpcRequest:new(remoteAddr, remotePort, _callerServiceID, _callerReqID, _type, _data) 
            end,
}