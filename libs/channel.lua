local LinkQue = require "linkque"
require "Scheduler"

local channel = {}

local function channelNew(p, scheduler)
    local o = {}
    p.__index = p      
    setmetatable(o, p)

    o.chan = LinkQue.New()
    o.block = LinkQue.New()
    o.scheduler = scheduler
    
    return o
end

function channel:Send(...)
    self.chan:Push({...})
    local coObject = self.block:Pop()  
    if coObject then
        self.scheduler:ForceWakeup(coObject)
    end
end

function channel:Recv()
    while true do
        local msg = self.chan:Pop()
        if msg ~= nil then
            return table.unpack(msg)
        end

        local coObject = self.scheduler:Running()
        self.block:Push(coObject)
        self.scheduler:Sleep(coObject)
    end
end

return {
    New = function (scheduler) return channelNew(channel, scheduler) end
}