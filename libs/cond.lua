require "Scheduler"

local LinkQue  = require "linkque"
local cond = {}

function condNew(p, scheduler)
    local o = {}
    p.__index = p      
    setmetatable(o,p)

    o.block = LinkQue.New()
    o.scheduler = scheduler

    return o
end

function cond:wait()
    local coObject = scheduler:Running()
    self.block:Push(coObject)
    scheduler:Sleep(coObject)
end

function cond:notifyOne()    
    local coObject = self.block:Pop()
    if coObject then
        scheduler:ForceWakeup(coObject)
    end
end

function cond:notifyAll()
    while not self.block:IsEmpty() do
        self:notifyOne()
    end
end

return {
    New = function(scheduler) return condNew(cond, scheduler) end
}