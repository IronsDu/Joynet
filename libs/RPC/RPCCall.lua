local protobuf = require "protobuf"
local TcpService = require "TcpService"
local RPCServiceMgr = require "RPCServiceMgr"
local RPCDefine = require "RPCDefine"
local HarborAddress = require "harborAddress"
local Lock = require "lock"

local REQUEST = RPCDefine.REQUEST
local RESPONSE = RPCDefine.RESPONSE
local POSTMSG = RPCDefine.POSTMSG

local joynet = nil
local scheduler = nil
local harborOutTcpService = nil
local harborOutMgr = {}
local harborOutMgrGuard = {}

local function sendPB(session, op, message)
    local packet = string.pack(">I4", 8+#message) .. string.pack(">I4", op) .. message
    session:send(packet)
end

local function _RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, _type, data, err, _callerWaitReqID, callerService)
    if _type ~= REQUEST and _type ~= RESPONSE and _type ~= POSTMSG then
        return "type is error", nil
    end
    
    local harborIP = HarborAddress.GetHarborIP()
    local harborPort = HarborAddress.GetHarborPort()
    
    if remoteIP == harborIP and remotePort == harborPort then    --如果对方处于自己同一个节点
        local destService = RPCServiceMgr.FindServiceByID(remoteServiceID)
        if destService == nil then
            destService = RPCServiceMgr.FindServiceByName(remoteServiceName)
        end
        if destService ~= nil then
            if _type == REQUEST then
                callerService.nextRequestID = callerService.nextRequestID + 1
                destService:pushRequest(harborIP, harborPort, callerService:getID(), callerService.nextRequestID, _type, data)
                local err, _replyReqID, _data =  callerService:recvResponse()
                assert(_replyReqID == callerService.nextRequestID)
                return err, _data
                
            elseif _type == POSTMSG then
                destService:pushRequest(harborIP, harborPort, 0, 0, _type, data)
            elseif _type == RESPONSE then
                if _callerWaitReqID == destService.nextRequestID then
                    destService:pushResponse(err, _callerWaitReqID, data)
                else
                    return "dest wait timeout, reply req id is invalid", nil
                end
            end
        else
            return "not find dest service", nil
        end
    else
        if harborOutTcpService == nil then
            harborOutTcpService = TcpService.New(joynet, scheduler)
            harborOutTcpService:createService()
        end
        local remoteAddr = remoteIP..remotePort
        local session = harborOutMgr[remoteAddr]
        if session ~= nil and session:isClose() then
            harborOutMgr[remoteAddr] = nil
            session = nil
        end
        
        if session == nil then
            local lock = harborOutMgrGuard[remoteAddr]
            if lock == nil then
                lock = Lock.New(scheduler)
                harborOutMgrGuard[remoteAddr] = lock
            end
            
            lock:Lock()
            
            session = harborOutMgr[remoteAddr]
            
            if session == nil then
                print("start connect")
                session = harborOutTcpService:connect(remoteIP, remotePort, 5000)
                print("connect success, remoteAddr is:"..remoteAddr)
                if session ~= nil then
                    harborOutMgr[remoteAddr] = session
                    harborOutMgrGuard[remoteAddr] = nil
                end
            end
            
            lock:Unlock()
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
                local err, _replyReqID, _data =  callerService:recvResponse()
                if err == nil then
                    assert(callerService.nextRequestID == _replyReqID)
                end
                return err, _data
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
                return nil, true
            else
                local response = {
                    callerReqID = _callerWaitReqID,
                    callerServiceID = remoteServiceID,
                    error = err,
                    body = data
                }

                local pbData = protobuf.encode("dodo.RPCResponse", response)
                sendPB(session, RESPONSE, pbData)
                return nil, true
            end
        else
            return "connect failed", nil
        end
    end
    
    return "unknown error", false
end

return {
    Setup = function(_joynet, _scheduler)
        joynet = _joynet
        scheduler = _scheduler
    end,

    RPCCall = function (remoteIP, remotePort, remoteServiceID, remoteServiceName, _type, data, _callerWaitReqID, callerService)
        return _RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, _type, data, nil, _callerWaitReqID, callerService)
    end,
    
    --提供给RPCRequest对象调用(用于返回数据给调用者)
    RPCReply = function(remoteIP, remotePort, remoteServiceID, data, err, _callerWaitReqID)
        return _RPCCall(remoteIP, remotePort, remoteServiceID, nil, RESPONSE, data, err, _callerWaitReqID)
    end,
    
    --非阻塞RPC调用(无返回值,所以也无需调用者service参数)
    AsyncRPCCall = function (remoteIP, remotePort, remoteService, data)
        local remoteServiceID = nil
        local remoteServiceName = nil
        if type(remoteService) == "string" then
            remoteServiceName = remoteService
        else
            remoteServiceID = remoteService
        end
        return _RPCCall(remoteIP, remotePort, remoteServiceID, remoteServiceName, POSTMSG, data)
    end,
}