--!strict

local Reader = require(script.Parent.Reader)
local Evaluator = require(script.Parent.Evaluator)
local Environment = require(script.Parent.Environment)

local Runtime = {}
Runtime.env = Environment.create()

Runtime.env["game"] = game
Runtime.env["workspace"] = workspace

Runtime.env["spawn"] = function(fn: any): ()
	if type(fn) == "table" and (fn :: any).type == "function" then
		local lispFn = fn :: any
		task.spawn(function()
			local localEnv = {}
			setmetatable(localEnv, {__index = lispFn.closure})
			for _, expr in lispFn.body do
				Evaluator.eval(expr, localEnv, false)
			end
		end)
	else
		task.spawn(fn)
	end
end

local IGNORED_KEYS = {
	closure = true,
	__macros__ = true,
	type = true,
	argsInfo = true,
	body = true,
	literals = true,
	rules = true,
	isMacro = true,
}

local function toLispString(val: any, depth: number?, visited: any?): string
	depth = depth or 0
	if depth > 100 then return "..." end
	visited = visited or {}
	if val == nil then return "nil"
	elseif type(val) == "table" then
		if visited[val] then return "#<circular>" end
		visited[val] = true
		local mt = (val :: any)
		if mt.type == "function" then return "#<function>"
		elseif mt.type == "syntax-rules" then return "#<syntax-rules>"
		elseif mt.car ~= nil and mt.cdr ~= nil then
			return "(" .. toLispString(mt.car, depth + 1, visited) .. " . " .. toLispString(mt.cdr, depth + 1, visited) .. ")"
		else
			local items = {}
			for k, v in val do
				if type(k) == "number" and not IGNORED_KEYS[k] then
					table.insert(items, toLispString(v, depth + 1, visited))
				end
			end
			return "(" .. table.concat(items, " ") .. ")"
		end
	else
		return tostring(val)
	end
end

function Runtime.execute(lispCode: string): (string?, string?)
	print("[Runtime] Parsing...")
	local ast = Reader.parse(lispCode)
	print("[Runtime] AST parsed, expressions: " .. #ast)
	if #ast == 0 then return nil end

	local results = {}
	for i, expr in ipairs(ast) do
		print("[Runtime] Evaluating expression #" .. i)
		local success, result = pcall(function()
			return Evaluator.evaluate(expr, Runtime.env)
		end)
		if not success then
			local errMsg = "RUNTIME ERROR: " .. tostring(result)
			print("[Runtime] ERROR: " .. errMsg)
			return nil, errMsg
		end
		print("[Runtime] Expression #" .. i .. " returned: " .. toLispString(result, 0, {}))
		table.insert(results, result)
	end

	local output: string
	if #results == 1 then
		output = toLispString(results[1], 0, {})
	else
		local parts = {}
		for _, r in results do
			table.insert(parts, toLispString(r, 0, {}))
		end
		output = table.concat(parts, "\n")
	end
	print("[Runtime] Final output: " .. output)
	return output, nil
end

function Runtime.resetEnv(): ()
	Runtime.env = Environment.create()
	Runtime.env["game"] = game
	Runtime.env["workspace"] = workspace
	Runtime.env["spawn"] = Runtime.env["spawn"]
end

return Runtime
