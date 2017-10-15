package.path = "./src/?.lua;./libs/?.lua;"
require("Joynet")
local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local Redis = require "Redis"
local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

local totalRecvNum = 0

function userMain()
    local redisService = TcpService.New(joynet, scheduler)
    redisService:createService()

    scheduler:Start(function ( ... )
        local redis = Redis:New()
        redis:connect(redisService, "192.168.12.128", 6979, 10000)
        redis:set("haha", "heihei")

        while true do
            local v, err = redis:get("haha")
            if v ~= nil then
                totalRecvNum = totalRecvNum + 1
            end
        end
    end)

    scheduler:Start(function ()
            while true do
                scheduler:SLeep(scheduler:Running(), 1000)
                print("total recv :"..totalRecvNum.."/s")
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
    scheduler:Scheduler()
end