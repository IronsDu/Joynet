local coObject = 
{
}

local function coObjectNew(p)
    local o = {}

    setmetatable(o, p)
    p.__index = p
    
    o.co = nil
    o.status = 0
    o.sc = nil

    return o
end

function coObject:init(sc,co)
    self.sc = sc
    self.co = co
end

return {
    New = function () return coObjectNew(coObject) end
}