require "Scheduler"

local LinkQue  = require "linkque"
local lock = {}

function lock:new()
  local o = {}
  self.__index = self      
  setmetatable(o,self)
  o.block = LinkQue.New()
  o.flag  = false
  return o
end

--添加断言
function lock:Lock()
    if self.flag then
        local coObject = coroutine_running()
		self.block:Push(coObject)
        
        while self.flag do
            coroutine_sleep(coObject, 10000000)
        end
    end
    
	self.flag = true
end

function lock:Unlock()
	self.flag = false
	local coObject = self.block:Pop()
	if coObject then
		coroutine_wakeup(coObject)
	end
end

return {
	New = function () return lock:new() end
}



