local protobuf = require "protobuf"
local TcpService = require "TcpService"
local RPCServiceMgr = require "RPCServiceMgr"
local HarborAddress = require "harborAddress"
local RPCCall = require "RPCCall"
local RPCDefine = require "RPCDefine"
local REQUEST = RPCDefine.REQUEST
local RESPONSE = RPCDefine.RESPONSE
local POSTMSG = RPCDefine.POSTMSG

local harborTcpService = nil

--harbor服务,用于接收其他节点上的服务向此节点发起RPC操作

local function recvPB(session, len)
    local opBuff, err = session:receive(4, 10000)
    if opBuff == nil then
        return nil, nil, err
    end
    local pbData, err = session:receive(len-8, 10000)
    return pbData, string.unpack(">I4", opBuff, 1), err
end

local function harborSessionRecvThread(session)
    while true do
        local lenBuff, err = session:receive(4, 100000)
        if lenBuff ~= nil then
            local pbData, OP, err = recvPB(session, string.unpack(">I4", lenBuff, 1))
            if pbData ~= nil then
                if OP == REQUEST or OP == POSTMSG then
                    local request = protobuf.decode("dodo.RPCRequest" , pbData)
                    if request ~= nil then
                        local service = RPCServiceMgr.FindServiceByID(request.remoteServiceID)
                        if service == nil then
                            service = RPCServiceMgr.FindServiceByName(request.remoteServiceName)
                        end
                        if service ~= nil then
                            service:pushRequest(request.callerHarborIP, request.callerHarborPort, request.callerServiceID, request.callerReqID, OP, request.body)
                        else
                            RPCCall.RPCReply(request.callerHarborIP, request.callerHarborPort, request.callerServiceID, nil, "service is not found", request.callerReqID)
                        end
                    end
                elseif OP == RESPONSE then
                    local response = protobuf.decode("dodo.RPCResponse" , pbData)
                    if response ~= nil then
                        local service = RPCServiceMgr.FindServiceByID(response.callerServiceID)
                        
                        if service ~= nil and service.nextRequestID == response.callerReqID then
                            service:pushResponse(response.error, response.callerReqID, response.body)
                        end
                    end
                else
                end
                --TODO::记录消息(及其反序列化)错误日志
            else
                session:postClose()
                break
            end
        end
        if session:isClose() then
            break
        end
    end
end

local function harborAcceptThread(tcpService)
    while true do
        local session = harborTcpService:accept()
        if session ~= nil then
            coroutine_start(function ()
                harborSessionRecvThread(session)
            end)
        end
    end
end

local function OpenHarbor(port)
    local harborPort = HarborAddress.GetHarborPort()
    if harborPort == nil and port ~= nil then
        HarborAddress.SetHarborPort(port)
        harborTcpService = TcpService:New()
        harborTcpService:listen("0.0.0.0", port)
        
        coroutine_start(function()
            harborAcceptThread(harborTcpService)
        end)
    end
end

return {
    OpenHarbor = OpenHarbor,
}