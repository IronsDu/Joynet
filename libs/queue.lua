local Que = {}

function Que:new(o)
	local o = o or {}   
	setmetatable(o, self)
	self.__index = self
	o.data = {}
	return o
end

function Que:Push(v)
    table.insert(self.data,v)
end

function Que:Front()
    if #self.data <= 0 then
        return nil
    end
    
    return self.data[1]
end


function Que:Pop()
    if #self.data <= 0 then
        return nil
    end

    local r = self.data[1]
    table.remove(self.data,1)
    return r
end

function Que:IsEmpty()
    return #self.data == 0
end

function Que:Len()
    return #self.data
end

return {
    New = function () return Que:new() end
}