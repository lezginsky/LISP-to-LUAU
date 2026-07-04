local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteEvent = Instance.new("RemoteEvent")
RemoteEvent.Name = "LispExec"
RemoteEvent.Parent = ReplicatedStorage

local Runtime = require(script.Parent.Runtime)

RemoteEvent.OnServerEvent:Connect(function(player, code)
	local result, err = Runtime.execute(code)
	if err then
		RemoteEvent:FireClient(player, err, true)
	else
		RemoteEvent:FireClient(player, result, false)
	end
end)
