local Reader = require(script.Parent.Reader)
local Evaluator = require(script.Parent.Evaluator)
local Environment = require(script.Parent.Environment)

local Runtime = {}
Runtime.env = Environment.create()

Runtime.env["game"] = game
Runtime.env["workspace"] = workspace

Runtime.env["spawn"] = function(fn)
	if type(fn) == "table" and fn.type == "function" then
		local lispFn = fn
		task.spawn(function()
			local localEnv = {}
			setmetatable(localEnv, {__index = lispFn.closure})
			for _, expr in ipairs(lispFn.body) do
				Evaluator.eval(expr, localEnv, false)
			end
		end)
	else
		task.spawn(fn)
	end
end

local function toLispString(val)
	if val == nil then
		return "nil"
	elseif type(val) == "table" and val.type == "function" then
		return "#<function>"
	elseif type(val) == "table" then
		if val.car ~= nil and val.cdr ~= nil then
			return "(" .. toLispString(val.car) .. " . " .. toLispString(val.cdr) .. ")"
		else
			local items = {}
			for i, v in ipairs(val) do
				table.insert(items, toLispString(v))
			end
			return "(" .. table.concat(items, " ") .. ")"
		end
	else
		return tostring(val)
	end
end

function Runtime.execute(lispCode)
	local ast = Reader.parse(lispCode)
	if #ast == 0 then return nil end

	local results = {}
	for _, expr in ipairs(ast) do
		local success, result = pcall(Evaluator.evaluate, expr, Runtime.env)
		if not success then
			local errMsg = "RUNTIME ERROR: " .. tostring(result)
			print(errMsg)
			return nil, errMsg
		end
		table.insert(results, result)
	end

	local output
	if #results == 1 then
		output = toLispString(results[1])
	else
		local parts = {}
		for _, r in ipairs(results) do
			table.insert(parts, toLispString(r))
		end
		output = table.concat(parts, "\n")
	end
	print(output)
	return output
end

function Runtime.resetEnv()
	Runtime.env = Environment.create()
	Runtime.env["game"] = game
	Runtime.env["workspace"] = workspace
	Runtime.env["spawn"] = Runtime.env["spawn"]
end

return Runtime
