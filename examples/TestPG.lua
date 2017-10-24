package.path = "./src/?.lua;./libs/?.lua;"
require("Joynet")
local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local PG = require "Postgres"
local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

local totalQueryNum = 0

function userMain()
    local pgService = TcpService.New(joynet, scheduler)
    pgService:createService()

    for i=1, 10 do
        scheduler:Start(function ( ... )
            local pg = PG.New(scheduler)
            local isOK, err = pg:connect(pgService, "192.168.12.1", 5432, 1000, "postgres", "postgres", "19870323")
            if not isOK then
                print("connect failed, err:"..err)
                return
            else
                print("connect success")
            end

            local res, err = pg:query("update public.heros set name='asxs' where id = 1")
            if not res then
                print("query failed, err :"..err)
            end

            while true do
                res, err = pg:query("select id,name from heros")
                if not res then
                    print("query failed, err :"..err)
                else
                    totalQueryNum = totalQueryNum + 1
                    for i,v in ipairs(res) do
                        --print(string.format("%s\t%s",v.id,v.name))
                    end
                end
            end
        end)
    end

    scheduler:Start(function ()
        while true do
            scheduler:Sleep(scheduler:Running(), 1000)
            print("total query :"..totalQueryNum.."/s")
            totalQueryNum = 0
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