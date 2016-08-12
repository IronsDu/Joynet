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
	while self.flag do
		local coObject = coroutine_running()
		self.block:Push(coObject)
		coroutine_sleep(coObject, 10000000)
	end
	self.flag = true
end

function lock:Unlock()
	self.flag = false
	local coObject = self.block:Pop()
	if co then
		coroutine_wakeup(coObject)
	end
end

return {
	New = function () return lock:new() end
}



