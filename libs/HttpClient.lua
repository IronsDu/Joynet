local function setHttpType(request, t)
    request.t = t
end

local function setRequestUrl(request, url)
    request.url = url
end

local function setRequestHost(request, host)
    request.host = host
end

local function addRequestArg(request, k, v)
    table.insert(request.arg_ks, k)
    table.insert(request.arg_vs, v)
end

local function addRequestHeadValue(request, k, v)
    table.insert(request.head_ks, k)
    table.insert(request.head_vs, v)
end

-- 根据request表构造http 报文
local function buildRequestData(request)
    local tmpUrl = request.url
    local questionMark = ""
    local allArgsStr = ""
    if request.t ~= "POST" then
        if next(request.arg_ks) ~= nil then
            questionMark = "?"
        end
        for i,v in ipairs(request.arg_ks) do
            allArgsStr = allArgsStr .. v.."="..request.arg_vs[i]
            if i ~= #request.arg_ks then
                allArgsStr = allArgsStr.."&"
            end
        end
    end

    local r = request.t.." "..request.url..questionMark..allArgsStr.." ".."HTTP/1.1".."\r\n"
    
    r = r.."Host: "..request.host.."\r\n"
    for i,v in ipairs(request.head_ks) do
        r = r..v..": "..request.head_vs[i].."\r\n"
    end
    r = r.."\r\n"

    if request.t == "POST" then
        r = r..allArgsStr.."\r\n"
    end

    return r
end

-- 访问http,返回response
local function request_http(service, ip, port, useSSL, _type, _url, _host, _args, _headvalues)
    local startTime = CoreDD:getNowUnixTime()

    local response = nil
    local session = service:connect(ip, port, 10000, useSSL)

    if session ~= nil then

        -- 构造http request 对象
        local request = {}
        request.head_ks = {}
        request.head_vs = {}
        request.arg_ks = {}
        request.arg_vs = {}
        setHttpType(request, _type)
        setRequestUrl(request, _url)
        setRequestHost(request, _host)

        if _args ~= nil then
            for k,v in pairs(_args) do
                addRequestArg(request, k, v)
            end
        end

        if _headvalues ~= nil then
            for k,v in pairs(_headvalues) do
                addRequestHeadValue(request, k, v)
            end
        end

        -- 生成http报文并发送
        local httpReuqestStr = buildRequestData(request)
        session:send(httpReuqestStr)

        -- 开始读取(解析)http response
        local packet = session:receiveUntil("\r\n", 10000)
        
        local content_len = 0
        local isChunked = false

        --读取多行头部
        while true do
            packet = session:receiveUntil("\r\n", 10000)
            if packet ~= nil then
                if #packet == 0 then
                    break
                end

                if content_len == 0 and not isChunked then
                    local s, e = string.find(packet, "Content%-Length: ")
                    if s ~= nil then
                        content_len = tonumber(string.sub(packet, e+1, string.len(packet)))
                    else
                        s, e = string.find(packet, "Transfer%-Encoding: chunked")
                        isChunked = s ~= nil
                    end
                end
            end
        end

        if content_len > 0 then
            response = session:receive(content_len, 100000)
        elseif isChunked then
            --如果是chunked协议
            while true do
                packet = session:receiveUntil("\r\n", 100000)
                if packet == nil then
                    response = nil
                    break
                end

                local num = tonumber("0x"..packet)
                if num == nil then
                    response = nil
                    break
                end

                if num == 0 then
                    break
                end

                local tmp = session:receive(num, 100000)
                if tmp ~= nil then
                    if response == nil then
                        response = tmp
                    else
                        response = response .. tmp
                    end
                else
                    response = nil
                    break
                end
                
                session:receiveUntil("\r\n", 100000)
            end
        end

        session:postClose()
    end

    return response
end

return {
    Request = request_http
}