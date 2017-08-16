local LinkQue = require "linkque"
require "Scheduler"

local channel = {}

function channelNew(p, scheduler)
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
        scheduler:ForceWakeup(coObject)
    end
end

function channel:Recv()
    while true do
        local msg = self.chan:Pop()
        if not msg then
            local coObject = scheduler:Running()
            self.block:Push(coObject)
            scheduler:Sleep(coObject)
        else
            return table.unpack(msg)
        end
    end
end

return {
    New = function (scheduler) return channelNew(channel, scheduler) end
}