local harborIP = "127.0.0.1"	--TODO::获取本地IP
local harborPort = nil

return {
	GetHarborIP = function () return harborIP	end,
	GetHarborPort = function () return harborPort end,
	SetHarborPort = function (port) harborPort = port end
}