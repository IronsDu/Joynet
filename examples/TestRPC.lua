package.path = "./src/?.lua;./libs/?.lua;./libs/RPC/?.lua;"

local Service = require "RPCService"
local RPCCall = require "RPCCall"
local harbor = require "harbor"

function userMain()

	--一个进程最多只能允许一个harbor
	--一个物理机允许多个进程,但各自的harbor监听不同的端口
	harbor.OpenHarbor(8888)
	
	coroutine_start(function()
	
        local server = Service:New()
		server:setName("echoServer")
		
		while true do
			local request = server:recvRequest()
			print("request data is "..request:getData())
			if request:isSync() then	--如果对方是同步call,则可以reply
				request:reply("echo:"..request:getData())
			end
		end
    end)
	
	coroutine_start(function()
        local client = Service:New()
		--SyncRPCCall本应该是service的成员函数,可是遇到循环重复引用的问题……
		local _response = RPCCall.SyncRPCCall(client, "127.0.0.1", 8888, nil, "echoServer", "hello1")
		print("response is ".._response.."\n")
		
		RPCCall.AsyncRPCCall("127.0.0.1", 8888, nil, "echoServer", "hello4")
		
		_response = RPCCall.SyncRPCCall(client, "127.0.0.1", 8888, nil, "echoServer", "hello5")
		print("response is ".._response.."\n")
    end)
	
	coroutine_start(function()
        RPCCall.AsyncRPCCall("127.0.0.1", 8888, nil, "echoServer", "hello2")
		RPCCall.AsyncRPCCall("127.0.0.1", 8888, nil, "echoServer", "hello3")
    end)
end

coroutine_start(function ()
    userMain()
end)

while true
do
    CoreDD:loop()
    while coroutine_pengdingnum() > 0
    do
        coroutine_schedule()
    end
end