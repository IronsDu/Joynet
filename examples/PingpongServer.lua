package.path = "./src/?.lua;./libs/?.lua;"

require("Joynet")

local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

local totalRecvNum = 0
local totalClientNum = 0
local totalRecvNum = 0

function userMain()

    --开启服务器
    local serverService = TcpService.New(joynet, scheduler)
    serverService:listen("0.0.0.0", 9999)

    scheduler:Start(function()
        while true do
            local session = serverService:accept()
            if session ~= nil then
                totalClientNum = totalClientNum + 1
                scheduler:Start(function ()
                    local strLen = 5        --读取5个字节
                    while true do
                        local packet = session:receive(strLen)
                        if packet ~= nil then
                            totalRecvNum = totalRecvNum + 1
                            session:send(packet)
                        end
                        if session:isClose() then
                            totalClientNum = totalClientNum - 1
                            break
                        end
                    end
                end)
            end
        end
    end)

    scheduler:Start(function ()
            while true do
                scheduler:Sleep(scheduler:Running(), 1000)
                print("total recv :"..totalRecvNum.."/s"..", totalClientNum: "..totalClientNum)
                totalRecvNum = 0
            end
        end)
end

scheduler:Start(function ()
    userMain()
end)

while true
do
    joynet:loop()
    scheduler:Schedule()
end