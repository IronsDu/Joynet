package.path = "./src/?.lua;./libs/?.lua;"
require("Joynet")
local TcpService = require "TcpService"

local Scheduler = require "Scheduler"
local joynet = JoynetCore()
local scheduler = Scheduler.New(joynet)

--HTTP处理器
local httpHandlers = {}

local function AddHandle(f)
    local handleObj = {next = nil, callback = f}

    if #httpHandlers > 0 then
        local tail = httpHandlers[#httpHandlers]
        tail.next = handleObj
    end

    table.insert(httpHandlers, handleObj)
end

--从某一个处理器开始处理(链表)
local function startCall(request, response, handle)
    if handle == nil then
        return
    end

    assert(handle.callback ~= nil)

    local makeNext = function(request, response, handle)
        return function()
            startCall(request, response, handle)
        end
    end

    handle.callback(request, response, makeNext(request, response, handle.next))
end

local function createRouter()
    local router = {
        get = function (request, response, next)
        end,
        keyFromArg = nil,
    }
    setmetatable(router, {
            __index = function(o, key)
                local subRouter = createRouter()
                if string.sub(key, 1, 1) == ':' then
                    local subKey = string.sub(key, 2, string.len(key))
                    rawset(o, "keyFromArg", subKey)
                    rawset(o, subKey, subRouter)
                else
                    rawset(o, key, subRouter)
                end
                
                return subRouter
            end})
    return router
end

local rootRouter = createRouter()

local function InitHttpRequestHandle()
    --添加常规HTTP请求的处理
    AddHandle(function(request, response, next)
        local subGroups = {}

        if request.uri ~= nil then
            do
                local endQeury = "index"
                local i = 2
                while true do
                    local j = string.find(request.uri, "/", i)
                    if j ~= nil then
                        local subGroup = string.sub(request.uri, i, j-1)
                        table.insert(subGroups, subGroup)
                        i = j+1
                    else
                        -- 得到最后的query,如果为""则设置为index 表示访问 /a/的index,即/a/index, 否则表示/a中的a
                        if i <= string.len(request.uri) then
                            local j = string.find(request.uri, "?", i)
                            if j == nil then
                                endQeury = string.sub(request.uri, i, string.len(request.uri))
                            else
                                endQeury = string.sub(request.uri, i, j-1)
                            end
                        end
                        break
                    end
                end

                table.insert(subGroups, endQeury)
            end
        end

        local findRouter = rootRouter

        for _,v in ipairs(subGroups) do
            local tmp = rawget(findRouter, "keyFromArg")
            if tmp ~= nil then
                request.parms[tmp] = v
                findRouter = rawget(findRouter, tmp)
            else
                findRouter = rawget(findRouter, v)
            end

            if findRouter == nil then
                break
            end
        end

        if findRouter ~= nil then
            local methodHandle = rawget(findRouter, string.lower(request.method))
            if methodHandle ~= nil then
                methodHandle(request, response, next)
            else
                print("methodHandle is nil of method:"..request.method)
            end
        else
            print("not found router")
        end
                        
        response.session:postShutdown()
    end)
end

function startHttpService(port)
    --开启http服务器
    local serverService = TcpService:New(joynet, scheduler)
    serverService:listen("0.0.0.0", port)
    InitHttpRequestHandle()

    scheduler:Start(function()
        while true do
            local session = serverService:accept()
            if session ~= nil then
                scheduler:Start(function ()

                    local request = {
                        parms = {},
                        uri = nil,
                        method = nil,
                        headValues = {}
                    }

                    do
                        --读取报文头
                        local packet = session:receiveUntil("\r\n")

                        if packet ~= nil then
                            local i = 0
                            local j = 0

                            while true do
                                j = string.find(packet, " ", j+1)
                                if j ~= nil then
                                    local tmp = string.sub(packet, i, j-1)
                                    if request.method == nil then
                                        request.method = tmp
                                    elseif request.uri == nil then
                                        request.uri = tmp
                                        break
                                    end

                                    i = j+1
                                else
                                    break
                                end
                            end
                        end

                        --读取多行头部
                        while true do
                            packet = session:receiveUntil("\r\n")
                            if packet ~= nil then
                                if #packet == 0 then
                                    break
                                else
                                    local i, j = string.find(packet, ": ")
                                    request.headValues[string.sub(packet, 1, i-1)] = string.sub(packet, j+1, string.len(packet))
                                end
                            else
                                break
                            end
                        end
                    end

                    local response = {
                        session = session,
                        headValue = {},
                        status = 200,

                        setStatus = function(self, status)
                            self.status = status
                        end,
                        setHeader = function(self, key, value)
                            self.headValue[key] = value
                        end,

                        text = function(self, content)
                            self:setHeader('Content-Type', 'text/plain; charset=UTF-8')
                            self:_send(data)
                        end,
                        html = function(self, data)
                            self:setHeader('Content-Type', 'text/html; charset=UTF-8')
                            self:_send(data)
                        end,
                        json = function(self, data)
                            self:setHeader('Content-Type', 'application/json; charset=utf-8')
                        end,

                        _send = function(self, data)
                            --TODO::status code to string
                            local str = "HTTP/1.1 "..tostring(self.status).." OK\r\n"
                            for k,v in pairs(self.headValue) do
                                str = str..k..": "..v.."\r\n"
                            end
                            str = str.."\r\n"..data
                            session:send(str)
                        end,
                    }
                    
                    startCall(request, response, httpHandlers[1])
                end)
            end
        end
    end)
end

scheduler:Start(function ()
    startHttpService(80)
end)

--设置路由处理器

--/a/b/c
rootRouter.a.b.c.get = function (req, res, next)
    res:html("<html><head><title> This is /a/b/c </title></head><body>hello world</body></html>")
end

--/a/b/c/
rootRouter.a.b.c.index.get = function (req, res, next)
    res:html("<html><head><title> This is /a/b/c/ </title></head><body>hello world</body></html>")
end

--/
rootRouter.index.get = function (req, res, next)
    res:html("<html><head><title> This is index  </title></head><body>hello world</body></html>")
end

--/topics/1111/delete
rootRouter.topics[":id"].delete.get = function (req, res, next)
    res:html("<html><head><title> This is topics  </title></head><body>hello world:"..tostring(req.parms.id).."</body></html>")
end

--添加自定义过滤器
AddHandle(function(request, response, next)
    print("1")
    next()
end
)

AddHandle(function(request, response, next)
    print("3")
    next()
end
)

AddHandle(function(request, response, next)
    print("2")
    next()
end
)

--主循环
while true
do
    joynet:loop()
    scheduler:Scheduler()
end