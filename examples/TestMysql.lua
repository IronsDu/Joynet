package.path = "./src/?.lua;./libs/?.lua;"
require("Joynet")
local TcpService = require "TcpService"
local AcyncConnect = require "Connect"
local MYSQL = require "Mysql"
local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

local totalQueryNum = 0

function userMain()
    local mysqlService = TcpService.New(joynet, scheduler)
    mysqlService:createService()
    local mysql = MYSQL.New(scheduler)
    local isOK, err = mysql:connect(mysqlService, "127.0.0.1", 3306, 1000, "test_database", "root", "password")
    for i=1, 8 do
        scheduler:Start(function ( ... )
            
            if not isOK then
                print("connect failed, err:"..err)
                return
            else
                print("connect success")
            end

            local res, err = mysql:query("update test_table set test_cloumn ='asxs' where id = ' '")
            if not res then
                print("query failed, err :"..err)
            end

            while true do
                local res, err = mysql:query("select * from test_table where id = ' '")
                if not res then
                    print("query failed, err :"..err)
                else
                    print("query result")
                    totalQueryNum = totalQueryNum + 1
                    for i,v in ipairs(res) do
                        print(string.format("data : %s\t%s",v.id, v.test_cloumn))
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