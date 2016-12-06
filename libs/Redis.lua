local TcpService = require "TcpService"
local AcyncConnect = require "Connect"

local commands = {
    "append",            "auth",              "bgrewriteaof",
    "bgsave",            "bitcount",          "bitop",
    "blpop",             "brpop",
    "brpoplpush",        "client",            "config",
    "dbsize",
    "debug",             "decr",              "decrby",
    "del",               "discard",           "dump",
    "echo",
    "eval",              "exec",              "exists",
    "expire",            "expireat",          "flushall",
    "flushdb",           "get",               "getbit",
    "getrange",          "getset",            "hdel",
    "hexists",           "hget",              "hgetall",
    "hincrby",           "hincrbyfloat",      "hkeys",
    "hlen",
    "hmget",             --[[ "hmset", ]]     "hscan",
    "hset",
    "hsetnx",            "hvals",             "incr",
    "incrby",            "incrbyfloat",       "info",
    "keys",
    "lastsave",          "lindex",            "linsert",
    "llen",              "lpop",              "lpush",
    "lpushx",            "lrange",            "lrem",
    "lset",              "ltrim",             "mget",
    "migrate",
    "monitor",           "move",              "mset",
    "msetnx",            "multi",             "object",
    "persist",           "pexpire",           "pexpireat",
    "ping",              "psetex",       --[[ "psubscribe", ]]
    "pttl",
    "publish",      --[[ "punsubscribe", ]]   "pubsub",
    "quit",
    "randomkey",         "rename",            "renamenx",
    "restore",
    "rpop",              "rpoplpush",         "rpush",
    "rpushx",            "sadd",              "save",
    "scan",              "scard",             "script",
    "sdiff",             "sdiffstore",
    "select",            "set",               "setbit",
    "setex",             "setnx",             "setrange",
    "shutdown",          "sinter",            "sinterstore",
    "sismember",         "slaveof",           "slowlog",
    "smembers",          "smove",             "sort",
    "spop",              "srandmember",       "srem",
    "sscan",
    "strlen",       --[[ "subscribe", ]]      "sunion",
    "sunionstore",       "sync",              "time",
    "ttl",
    "type",         --[[ "unsubscribe", ]]    "unwatch",
    "watch",             "zadd",              "zcard",
    "zcount",            "zincrby",           "zinterstore",
    "zrange",            "zrangebyscore",     "zrank",
    "zrem",              "zremrangebyrank",   "zremrangebyscore",
    "zrevrange",         "zrevrangebyscore",  "zrevrank",
    "zscan",
    "zscore",            "zunionstore",       "evalsha"
}


--[[
允许多个协程同时执行redis command
但当有一个协程在执行pipeline时，其他协程需要等待
]]

local RedisSession = {
}

for i=1,#commands do
    local cmd = commands[i]
    RedisSession[cmd] = function (self, ... )
        return self:_do_cmd(cmd, ...)
    end
end

local function RedisSessionNew(p)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.tcpsession = nil
    o.pendingWaitPipelineCo = {}
    o.pipelineCo = nil

    return o
end

function RedisSession:connect(tcpservice, ip, port, timeout)
    self.tcpsession = tcpservice:connect(ip, port, timeout)
    return self.tcpsession ~= nil
end

local function _gen_req(args)
    local nargs = #args

    local req = {}
    req[1] = "*" .. nargs .. "\r\n"
    local nbits = 2

    for i = 1, nargs do
        local arg = args[i]
        if type(arg) ~= "string" then
            arg = tostring(arg)
        end

        req[nbits] = "$"
        req[nbits + 1] = #arg
        req[nbits + 2] = "\r\n"
        req[nbits + 3] = arg
        req[nbits + 4] = "\r\n"

        nbits = nbits + 5
    end

    return req
end

function RedisSession:sendRequest(req)
    for i,v in ipairs(req) do
        self.tcpsession:send(v)
    end
end

function RedisSession:recvReply()

    local line = self.tcpsession:receiveUntil("\r\n")
    if line == nil then
        return false, "server close"
    end

    local prefix = string.byte(line, 1)
    if prefix == 36 then    -- $

        local size = tonumber(string.sub(line, 2))
        local data = self.tcpsession:receive(size)
        self.tcpsession:receive(2)
        return data

    elseif prefix == 43 then  -- +
        return string.sub(line, 2)
    elseif prefix == 42 then  -- *

        local vals = {}
        local n = tonumber(string.sub(line, 2))
        for i=1,n do
            local res, err = self:recvReply()
            if res then
                vals[i] = res
            elseif res == nil then
                return nil, err
            else
                vals[i] = {false, err}
            end
        end
        return vals

    elseif prefix == 58 then  -- :
        return tonumber(string.sub(line, 2))
    elseif prefix == 45 then  -- -
        return false, string.sub(line, 2)
    else
        print("prefix error")
        return nil, "unkown prefix: " .. tostring(prefix)
    end
end

function RedisSession:_do_cmd(...)
    if self.tcpsession == nil then
        return nil , "not connection"
    end

    self:waitPipelineCo()
    local req = _gen_req({...})
    if self._pipeReqs ~= nil then
        self._pipeReqs[#self._pipeReqs+1] = req
        return
    end

    self:sendRequest(req)
    local _a, _b =  self:recvReply()
    self.tcpsession:releaseRecvLock()
    
    if self.tcpsession:isClose() then
        self.tcpsession = nil
    end

    return _a, _b
end

function RedisSession:hmset(hashname, ...)
    if select('#', ...) == 1 then
        local t = select(1, ...)

        local n = 0
        for k, v in pairs(t) do
            n = n + 2
        end

        local array = {}

        local i = 0
        for k, v in pairs(t) do
            array[i + 1] = k
            array[i + 2] = v
            i = i + 2
        end
        -- print("key", hashname)
        return self:_do_cmd("hmset", hashname, unpack(array))
    end

    -- backwards compatibility
    return self:_do_cmd("hmset", hashname, ...)
end

function RedisSession:waitPipelineCo()
    local current = coroutine_running()
    if self.pipelineCo ~= nil and self.pipelineCo ~= current then
        --等待其他协程的pipeline完成
        table.insert(self.pendingWaitPipelineCo, current)
        while true do
            coroutine_sleep(current, 1000)
            if self.pipelineCo == nil then
                break
            end
        end
    end
end

function RedisSession:releasePipelineLock()
    if self.pipelineCo == coroutine_running() then
        self.pipelineCo = nil
        --唤醒所有等待的co
        for i,v in ipairs(self.pendingWaitPipelineCo) do
            coroutine_wakeup(v)
        end
        self.pendingWaitPipelineCo = {}
    end
end

function RedisSession:initPipeline()
    self:waitPipelineCo()
    self._pipeReqs = {}
    self.pipelineCo = coroutine_running()
end

function RedisSession:cancelPipeline()
    if self.pipelineCo == coroutine_running() then
        self._pipeReqs = nil
        self:releasePipelineLock()
    end
end

function RedisSession:commitPipeline()
    if self.tcpsession == nil then
        return nil , "not connection"
    end

    if self.pipelineCo ~= coroutine_running() then
        return nil, "error"
    end

    local reqs = self._pipeReqs
    if not reqs then
        return nil, "no pipeline"
    end

    self._pipeReqs = nil

    for i,v in ipairs(reqs) do
        self:sendRequest(v)
    end

    local nvals = 0
    local nreqs = #reqs
    local vals = {}
    local retErr = nil

    for i=1,nreqs do
        local res, err = self:recvReply()
        if res then
            nvals = nvals + 1
            vals[nvals] = res
        elseif res == nil then
            retErr = err
            break
        else
            -- be a valid redis error value
            nvals = nvals + 1
            vals[nvals] = {false, err}
        end
    end

    self.tcpsession:releaseRecvLock()
    self:releasePipelineLock()
    
    if self.tcpsession:isClose() then
        self.tcpsession = nil
    end

    if retErr ~= nil then
        return nil, retErr
    end

    return vals
end

return {
    New = function () return RedisSessionNew(RedisSession) end
}