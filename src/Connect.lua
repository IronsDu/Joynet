local __connect__callback = {}

--fd为-1表示失败
--TODO::设置为joynet回掉
function __on_async_connectd__(fd, uid)
    local callback = __connect__callback[uid]
    if callback ~= nil then
        __connect__callback[uid] = nil
        callback(fd, uid)
    end
end

local function asyncConnect(joynet, ip, port, timeout, callback)
    local uid = joynet:asyncConnect(ip, port, timeout)
    __connect__callback[uid] = callback
    return uid
end

return {
    AsyncConnect = asyncConnect
}