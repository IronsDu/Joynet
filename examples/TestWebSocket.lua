package.path = "./src/?.lua;./libs/?.lua;"
require("Joynet")
local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local WebSocket = require "WebSocket"
local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

function userMain()
    local clientService = TcpService.New(joynet, scheduler)
    clientService:createService()
    local ws = WebSocket:New()
    ws:setSession(clientService:connect("127.0.0.1", 8080, 10000, false))
    print(ws:connectHandshake("/ws"))
    ws:sendText("hello world")
    print(ws:readFrame())
end

scheduler:Start(function ()
    userMain()
end)

while true
do
    joynet:loop()
    scheduler:Scheduler()
end