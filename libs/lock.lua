require "Scheduler"

local LinkQue  = require "linkque"
local lock = {}

local function lockNew(p, scheduler)
    local o = {}

    p.__index = p      
    setmetatable(o,p)

    o.block = LinkQue.New()
    o.flag  = false
    o.owner = nil
    o.scheduler = scheduler

    return o
end

function lock:Lock()
    local coObject = self.scheduler:Running()
    assert(self.owner ~= coObject)
    
    if self.flag then
        self.block:Push(coObject)
        
        while self.flag do
            self.scheduler:Sleep(coObject)
        end
    end
    
    self.flag = true
    self.owner = coObject
end

function lock:Unlock()
    assert(self.flag == true)
    assert(self.owner == self.scheduler:Running())
    
    self.flag = false
    self.owner = nil
    
    local coObject = self.block:Pop()
    if coObject then
        self.scheduler:ForceWakeup(coObject)
    end
end

return {
    New = function(scheduler) return lockNew(lock, scheduler) end
}
