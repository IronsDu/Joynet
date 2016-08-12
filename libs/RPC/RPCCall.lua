local protobuf = require "protobuf"
local TcpService = require "TcpService"
local RPCServiceMgr = require "RPCServiceMgr"
local RPCDefine = require "RPCDefine"
local HarborAddress = require "harborAddress"

local REQUEST = RPCDefine.REQUEST
local RESPONSE = RPCDefine.RESPONSE
local POSTMSG = RPCDefine.POSTMSG

local harborOutTcpService = nil
local harborOutMgr = {}

local function sendPB(session, op, message)
	local packet = string.pack(">I4", 8+#message) .. string.pack(">I4", op) .. message
	session:send(packet)
end

local function _RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, _type, data, _callerWaitReqID, callerService)
	if _type ~= REQUEST and _type ~= RESPONSE and _type ~= POSTMSG then
		return nil, "type is error"
	end
	
	local harborIP = HarborAddress.GetHarborIP()
	local harborPort = HarborAddress.GetHarborPort()
	
	if remoteIP == harborIP and remotePort == harborPort then	--如果对方处于自己同一个节点
		local destService = RPCServiceMgr.FindServiceByID(remoteServiceID)
		if destService == nil then
			destService = RPCServiceMgr.FindServiceByName(remoteServiceName)
		end
		if destService ~= nil then
			if _type == REQUEST then
				callerService.nextRequestID = callerService.nextRequestID + 1
				destService:pushRequest(harborIP, harborPort, callerService:getID(), callerService.nextRequestID, _type, data)
				local _replyReqID, _data =  callerService:recvResponse()
				assert(_replyReqID == callerService.nextRequestID)
				return _data
				
			elseif _type == POSTMSG then
				destService:pushRequest(harborIP, harborPort, 0, 0, _type, data)
			elseif _type == RESPONSE then
				if _callerWaitReqID == destService.nextRequestID then
					destService:pushResponse(_callerWaitReqID, data)
				end
			end
		else
			return nil, "not find service"
		end
	else
		if harborOutTcpService == nil then
			harborOutTcpService = TcpService:New()
			harborOutTcpService:createService()
		end
		local remoteAddr = remoteIP..remotePort
		local session = harborOutMgr[remoteAddr]
		if session == nil then
			session = harborOutTcpService:connect(remoteIP, remotePort, 5000)
			print("connect success, remoteAddr is:"..remoteAddr)
			harborOutMgr[remoteAddr] = session
			--TODO::处理session断开时取消关联
		end
		
		if session ~= nil then
			if _type == REQUEST then
				callerService.nextRequestID = callerService.nextRequestID + 1
				local request = {
					callerHarborIP = harborIP,
					callerHarborPort = harborPort,
					callerServiceID = callerService:getID(),
					callerReqID = callerService.nextRequestID,
					remoteServiceName = remoteServiceName,
					remoteServiceID = remoteServiceID,
					body = data,
				}

				local pbData = protobuf.encode("dodo.RPCRequest", request)
				sendPB(session, _type, pbData)
				local _replyReqID, _data =  callerService:recvResponse()
				assert(callerService.nextRequestID == _replyReqID)
				return _data
			elseif _type == POSTMSG then
				local request = {
					callerHarborIP = harborIP,
					callerHarborPort = harborPort,
					callerServiceID = 0,
					callerReqID = 0,
					remoteServiceName = remoteServiceName,
					remoteServiceID = remoteServiceID,
					body = data,
				}

				local pbData = protobuf.encode("dodo.RPCRequest", request)
				sendPB(session, _type, pbData)
				return true, nil
			else
				local response = {
					callerReqID = _callerWaitReqID,
					callerServiceID = callerService:getID(),
					body = data,
				}

				local pbData = protobuf.encode("dodo.RPCResponse", response)
				sendPB(session, RESPONSE, pbData)
				
				return true, nil
			end
		end
	end
	
	return false, "error"
end

return {
	New = function () return service:new() end,
	
	RPCReply = function(remoteIP, remotePort, remoteServiceID, data, _callerWaitReqID)
		return _RPCCall(remoteIP, remotePort, remoteServiceID, nil, RESPONSE, data, _callerWaitReqID)
	end,
	
	--非阻塞RPC调用(无返回这,所以也无需调用者service参数)
	AsyncRPCCall = function (remoteIP, remotePort, remoteServiceID, remoteServiceName, data)
		_RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, POSTMSG, data)
	end,
	
	--同步RPC调用(需要传递调用者service参数,且对他加锁,避免多个协程同时使用一个RPCService对象调用其它服务可能造成response乱序问题)
	SyncRPCCall = function(service, remoteIP, remotePort, remoteServiceID, remoteServiceName, data)
		service.rpcCallGuard:Lock()
		local _response = _RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, REQUEST, data, 0, service)
		service.rpcCallGuard:Unlock()
		return _response
	end
}