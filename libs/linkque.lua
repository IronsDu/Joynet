local LinkQue = {}

function LinkQue:new(o)
    local o = o or {}

    setmetatable(o, self)
    self.__index = self
    o.size = 0
    o.head = {}
    o.tail = {}
    o.size = 0
    o.head.__pre = nil
    o.head.__next = o.tail
    o.tail.__next = nil
    o.tail.__pre = o.head

    return o
end

function LinkQue:Push(node)
    if node.__owner then
        return false
    end

    self.tail.__pre.__next = node
    node.__pre = self.tail.__pre
    self.tail.__pre = node
    node.__next = self.tail
    node.__owner = self
    self.size = self.size + 1

    return true
end

function LinkQue:Front()
    if self.size <= 0 then
        return nil
    end
    
    return self.head.__next
end

function LinkQue:Remove(node)
    if node.__owner ~= self or self.size <= 0 then
        return false
    end

    node.__pre.__next = node.__next
    node.__next.__pre = node.__pre
    node.__next = nil
    node.__pre = nil
    node.__owner = nil
    self.size = self.size - 1
    
    return true
end

function LinkQue:Pop()
    if self.size <= 0 then
        return nil
    end

    local node = self.head.__next
    self:Remove(node)
    return node
end

function LinkQue:IsEmpty()
    return self.size == 0
end

function LinkQue:Len()
    return self.size
end

return {
    New = function () return LinkQue:new() end
}