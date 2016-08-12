local serviceTableOfName = {}
local serviceTableOfID = {}

local function findServiceByID(id)
	if id ~= nil then
		return serviceTableOfID[id]
	end
	
	return nil
end

local function addServiceByID(service, id)
	serviceTableOfID[id] = service
end

local function findServiceByName(name)
	if name ~= nil then
		return serviceTableOfName[name]
	end
	
	return nil
end

local function addServiceByName(service, name)
	serviceTableOfName[name] = service
end

return {
	FindServiceByID = findServiceByID,
	AddServiceByID = addServiceByID,
	FindServiceByName = findServiceByName,
	AddServiceByName = addServiceByName,
}