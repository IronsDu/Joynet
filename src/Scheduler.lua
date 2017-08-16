local CoObject = require "Co"

local CO_STATUS_NONE = 1
local CO_STATUS_ACTIVED = 2 --激活
local CO_STATUS_SLEEP = 3   --睡眠状态
local CO_STATUS_YIELD = 4   --暂时释放控制权
local CO_STATUS_DEAD = 5    --销毁
local CO_STATUS_RUNNING = 6 --运行中

local scheduler =
{
    
}

local function SchedulerNew(p, joynet)
    local o = {}
    setmetatable(o, p)
    p.__index = p
    
    o.joynet = joynet
    o.nowRunning = nil
    o.process = {}
    o.nextPid = 1

    return o
end

--coroutine_wakeup
--强制唤醒
function scheduler:ForceWakeup(coObj)
    if coObj.status == CO_STATUS_SLEEP then
        self:CancelSleep(coObj)
        self:Add2Active(coObj)
    end
end

--coroutine_running
function scheduler:Running()
    return self.nowRunning
end

--添加到激活列表中
function scheduler:Add2Active(coObj)
    if coObj.status == CO_STATUS_NONE then
        coObj.status = CO_STATUS_ACTIVED
        self.process[self.nextPid] = coObj
        self.nextPid = self.nextPid + 1
    end
end

--取消sleep
function scheduler:CancelSleep(coObj)
    if coObj.status == CO_STATUS_SLEEP then
        if coObj.sleepID ~= nil then
            self.joynet:removeTimer(coObj.sleepID)
        end
        
        coObj.status = CO_STATUS_NONE
    end
end

local function __scheduler_timer_callback(scheduler, sleepCo)
    sleepCo.sleepID = nil
    if sleepCo.status == CO_STATUS_SLEEP then
        sleepCo.status = CO_STATUS_NONE
        scheduler:Add2Active(sleepCo)
    end
end

--coroutine_sleep(coObj, delay)
--delay为nil,则为无限等待(睡眠)
--睡眠ms
function scheduler:Sleep(coObj,ms)
    if coObj.sc ~= self then
        error("sc not equal self")
    end

    if coObj.status == CO_STATUS_RUNNING then
        if ms ~= nil then
            local id = self.joynet:startLuaTimer(ms, function()
                    __scheduler_timer_callback(self, coObj)
                end)
            coObj.sleepID = id
        end
        
        coObj.status = CO_STATUS_SLEEP
        coroutine.yield(coObj.co)
    end
end

--coroutine_yield
--暂时释放执行权
function scheduler:Yield(coObj)
    if coObj.status == CO_STATUS_RUNNING then
        coObj.status = CO_STATUS_ACTIVED
        --继续放入激活队列
        self.process[self.nextPid] = coObj
        self.nextPid = self.nextPid + 1
        coroutine.yield(coObj.co)
    end
end

--coroutine_schedule
--主调度循环
function scheduler:Schedule()
    for _, v in pairs(self.process) do
        self.nowRunning = v
        v.status = CO_STATUS_RUNNING
        self.joynet:startMonitor()
        local r, e = coroutine.resume(v.co,v)
        self.nowRunning = nil
        
        if not r and e ~= nil then
            print("resume error :"..e)
        end
        
        if coroutine.status(v.co) == "dead" then
            v.status = CO_STATUS_DEAD
        end
    end
    
    --清空运行列表
    for k in pairs(self.process) do
        self.process[k] = nil
    end
    
    --重置下一个被调度的协程的Pid
    self.nextPid = 1
end

--coroutine_start(func)
function scheduler:Start(func)
    local coObj = CoObject.New()
    coObj.status = CO_STATUS_NONE
    local co = coroutine.create(func)
    coObj:init(self, co)
    self:Add2Active(coObj)
    return coObj
end

--coroutine_pengdingnum
function scheduler:PendingNum()
    return self.nextPid -1 --下一个被调度的协程的pid减1则为当前运行中的协程数量
end

return {
    New = function (joynet)
        joynet:startMonitor()
        return SchedulerNew(scheduler, joynet)
    end
}