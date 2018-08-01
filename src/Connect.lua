local function asyncConnect(joynet, serviceID, ip, port, timeout, useOpenSSL)
    return joynet:asyncConnect(serviceID, ip, port, timeout, useOpenSSL)
end

return {
    AsyncConnect = asyncConnect
}