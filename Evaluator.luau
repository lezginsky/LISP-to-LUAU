local Evaluator = {}

local function qqExpand(template, env)
	if template.type == "symbol" then
		return template
	elseif template.type == "list" then
		local elements = template.elements
		if #elements > 0 and elements[1].type == "symbol" then
			local firstSym = elements[1].name
			if firstSym == "unquote" then
				local value = Evaluator.eval(elements[2], env)
				if type(value) == "table" and value.type then
					return value
				else
					return {type = "quote", value = value}
				end
			elseif firstSym == "unquote-splicing" then
				local list = Evaluator.eval(elements[2], env)
				if type(list) == "table" and list.elements then
					return list
				else
					error("unquote-splicing requires a list")
				end
			end
		end
		local newElements = {}
		for _, elem in ipairs(elements) do
			local expanded = qqExpand(elem, env)
			if expanded.type == "list" and expanded.splicing then
				for _, e in ipairs(expanded.elements) do
					table.insert(newElements, e)
				end
			else
				table.insert(newElements, expanded)
			end
		end
		return {type = "list", elements = newElements}
	elseif template.type == "quote" then
		return template
	else
		return template
	end
end

local function parseLambdaArgs(argsAst)
	local required = {}
	local optional = {}
	local key = {}
	local vararg = false
	local varargName = nil

	if argsAst.type == "symbol" then
		vararg = true
		varargName = argsAst.name
		return {required = required, optional = optional, key = key, vararg = vararg, varargName = varargName}
	end

	local elements = argsAst.elements
	local i = 1
	local mode = "required"

	while i <= #elements do
		local elem = elements[i]
		if elem.type == "symbol" then
			local name = elem.name
			if name == "&optional" then
				mode = "optional"
				i = i + 1
			elseif name == "&key" then
				mode = "key"
				i = i + 1
			elseif name == "&rest" then
				vararg = true
				i = i + 1
				if i <= #elements and elements[i].type == "symbol" then
					varargName = elements[i].name
					i = i + 1
				end
			else
				if mode == "required" then
					table.insert(required, name)
				elseif mode == "optional" then
					if i + 1 <= #elements and elements[i + 1].type ~= "symbol" then
						table.insert(optional, {name = name, default = elements[i + 1]})
						i = i + 2
					else
						table.insert(optional, {name = name, default = {type = "nil"}})
						i = i + 1
					end
				elseif mode == "key" then
					if i + 1 <= #elements and elements[i + 1].type ~= "symbol" then
						table.insert(key, {name = name, default = elements[i + 1]})
						i = i + 2
					else
						table.insert(key, {name = name, default = {type = "nil"}})
						i = i + 1
					end
				end
			end
		else
			i = i + 1
		end
	end

	return {required = required, optional = optional, key = key, vararg = vararg, varargName = varargName}
end

local function bindLambdaArgs(argsInfo, args, localEnv)
	local argIndex = 1

	for _, name in ipairs(argsInfo.required) do
		if argIndex <= #args then
			localEnv[name] = args[argIndex]
			argIndex = argIndex + 1
		else
			error("Missing required argument: " .. name)
		end
	end

	for _, opt in ipairs(argsInfo.optional) do
		if argIndex <= #args then
			localEnv[opt.name] = args[argIndex]
			argIndex = argIndex + 1
		else
			localEnv[opt.name] = Evaluator.eval(opt.default, localEnv, false)
		end
	end

	if argsInfo.vararg then
		local rest = {}
		while argIndex <= #args do
			table.insert(rest, args[argIndex])
			argIndex = argIndex + 1
		end
		localEnv[argsInfo.varargName] = rest
	else
		for _, kw in ipairs(argsInfo.key) do
			localEnv[kw.name] = Evaluator.eval(kw.default, localEnv, false)
		end

		while argIndex < #args do
			local keySym = args[argIndex]
			local keyVal = args[argIndex + 1]
			if type(keySym) == "string" and keySym:sub(1, 1) == ":" then
				local keyName = keySym:sub(2)
				for _, kw in ipairs(argsInfo.key) do
					if kw.name == keyName then
						localEnv[kw.name] = keyVal
						break
					end
				end
				argIndex = argIndex + 2
			else
				break
			end
		end
	end
end

local function applyFunction(func, args)
	if type(func) == "table" and func.type == "function" then
		local localEnv = {}
		setmetatable(localEnv, {__index = func.closure})
		bindLambdaArgs(func.argsInfo, args, localEnv)
		local result = nil
		for i, expr in ipairs(func.body) do
			local isTail = (i == #func.body)
			result = Evaluator.eval(expr, localEnv, isTail)
			if isTail and type(result) == "table" and result.tailcall then
				return result
			end
		end
		return result
	elseif type(func) == "function" then
		return func(table.unpack(args))
	else
		error("Not a function: " .. tostring(func))
	end
end

function Evaluator.eval(ast, env, isTail)
	isTail = isTail or false

	if ast.type == "number" then
		return ast.value
	elseif ast.type == "string" then
		return ast.value
	elseif ast.type == "boolean" then
		return ast.value
	elseif ast.type == "nil" then
		return nil
	elseif ast.type == "symbol" then
		local name = ast.name
		local current = env
		while current do
			if rawget(current, name) ~= nil then
				return rawget(current, name)
			end
			local mt = getmetatable(current)
			if mt and mt.__index then
				if type(mt.__index) == "table" then
					current = mt.__index
				else
					break
				end
			else
				break
			end
		end
		if _G[name] ~= nil then
			return _G[name]
		end
		if _G.game and _G.game[name] ~= nil then
			return _G.game[name]
		end
		error("Undefined symbol: " .. name)

	elseif ast.type == "list" then
		local elements = ast.elements
		if #elements == 0 then
			return nil
		end

		local first = elements[1]

		if first.type == "symbol" then
			local formName = first.name

			if formName == "define" then
				local varName = elements[2].name
				local value = Evaluator.eval(elements[3], env, false)
				env[varName] = value
				return value

			elseif formName == "lambda" then
				local argsAst = elements[2]
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				local argsInfo = parseLambdaArgs(argsAst)
				return {
					type = "function",
					argsInfo = argsInfo,
					body = body,
					closure = env
				}

			elseif formName == "if" then
				local cond = Evaluator.eval(elements[2], env, false)
				local branchIndex = cond and 3 or 4
				if elements[branchIndex] then
					return Evaluator.eval(elements[branchIndex], env, isTail)
				else
					return nil
				end

			elseif formName == "begin" then
				local result = nil
				for i = 2, #elements do
					local tail = (i == #elements) and isTail
					result = Evaluator.eval(elements[i], env, tail)
					if tail and type(result) == "table" and result.tailcall then
						return result
					end
				end
				return result

			elseif formName == "quote" then
				return elements[2]

			elseif formName == "set!" then
				local varName = elements[2].name
				if varName:find("%.") then
					local parts = {}
					for part in varName:gmatch("[^%.]+") do
						table.insert(parts, part)
					end
					local objName = parts[1]
					local propName = table.concat(parts, ".", 2)
					local obj = nil
					local current = env
					while current do
						if rawget(current, objName) ~= nil then
							obj = rawget(current, objName)
							break
						end
						local mt = getmetatable(current)
						if mt and mt.__index and type(mt.__index) == "table" then
							current = mt.__index
						else
							break
						end
					end
					if not obj and _G[objName] then
						obj = _G[objName]
					end
					if not obj and _G.game and _G.game[objName] then
						obj = _G.game[objName]
					end
					if obj then
						local value = Evaluator.eval(elements[3], env, false)
						if propName == "BrickColor" and type(value) == "string" then
							value = BrickColor.new(value)
						end
						obj[propName] = value
						return value
					else
						error("Undefined object: " .. objName)
					end
				else
					local value = Evaluator.eval(elements[3], env, false)
					local current = env
					while current do
						if rawget(current, varName) ~= nil then
							current[varName] = value
							return value
						end
						local mt = getmetatable(current)
						current = mt and mt.__index
					end
					env[varName] = value
					return value
				end

			elseif formName == "let" then
				local bindingsList = elements[2].elements
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				local newEnv = {}
				setmetatable(newEnv, {__index = env})
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						local varName = binding.elements[1].name
						local val = Evaluator.eval(binding.elements[2], env, false)
						newEnv[varName] = val
					else
						error("let: invalid binding")
					end
				end
				local result = nil
				for i, expr in ipairs(body) do
					local tail = (i == #body) and isTail
					result = Evaluator.eval(expr, newEnv, tail)
					if tail and type(result) == "table" and result.tailcall then
						return result
					end
				end
				return result

			elseif formName == "let*" then
				local bindingsList = elements[2].elements
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				local newEnv = {}
				setmetatable(newEnv, {__index = env})
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						local varName = binding.elements[1].name
						local val = Evaluator.eval(binding.elements[2], newEnv, false)
						newEnv[varName] = val
					else
						error("let*: invalid binding")
					end
				end
				local result = nil
				for i, expr in ipairs(body) do
					local tail = (i == #body) and isTail
					result = Evaluator.eval(expr, newEnv, tail)
					if tail and type(result) == "table" and result.tailcall then
						return result
					end
				end
				return result

			elseif formName == "letrec" then
				local bindingsList = elements[2].elements
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				local newEnv = {}
				setmetatable(newEnv, {__index = env})
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						local varName = binding.elements[1].name
						newEnv[varName] = nil
					end
				end
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						local varName = binding.elements[1].name
						local val = Evaluator.eval(binding.elements[2], newEnv, false)
						newEnv[varName] = val
					end
				end
				local result = nil
				for i, expr in ipairs(body) do
					local tail = (i == #body) and isTail
					result = Evaluator.eval(expr, newEnv, tail)
					if tail and type(result) == "table" and result.tailcall then
						return result
					end
				end
				return result

			elseif formName == "named-let" then
				local loopName = elements[2].name
				local bindingsList = elements[3].elements
				local body = {}
				for i = 4, #elements do
					table.insert(body, elements[i])
				end
				local newEnv = {}
				setmetatable(newEnv, {__index = env})
				local loopFunc = {
					type = "function",
					argsInfo = {required = {}, optional = {}, key = {}, vararg = false},
					body = body,
					closure = newEnv
				}
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						local varName = binding.elements[1].name
						table.insert(loopFunc.argsInfo.required, varName)
					end
				end
				newEnv[loopName] = loopFunc
				local args = {}
				for _, binding in ipairs(bindingsList) do
					if binding.type == "list" and #binding.elements == 2 then
						table.insert(args, Evaluator.eval(binding.elements[2], env, false))
					end
				end
				return applyFunction(loopFunc, args)

			elseif formName == "cond" then
				for i = 2, #elements do
					local clause = elements[i]
					if clause.type == "list" and #clause.elements > 0 then
						local test = clause.elements[1]
						local isElse = (test.type == "symbol" and test.name == "else")
						if isElse or Evaluator.eval(test, env, false) then
							if #clause.elements > 1 then
								return Evaluator.eval(clause.elements[2], env, isTail)
							else
								return nil
							end
						end
					end
				end
				return nil

			elseif formName == "case" then
				local key = Evaluator.eval(elements[2], env, false)
				for i = 3, #elements do
					local clause = elements[i]
					if clause.type == "list" and #clause.elements > 0 then
						local pattern = clause.elements[1]
						local isElse = (pattern.type == "symbol" and pattern.name == "else")
						if isElse then
							if #clause.elements > 1 then
								return Evaluator.eval(clause.elements[2], env, isTail)
							else
								return nil
							end
						elseif pattern.type == "list" then
							local match = true
							for j, pat in ipairs(pattern.elements) do
								local patVal = Evaluator.eval(pat, env, false)
								if not (patVal == key) then
									match = false
									break
								end
							end
							if match then
								if #clause.elements > 1 then
									return Evaluator.eval(clause.elements[2], env, isTail)
								else
									return nil
								end
							end
						else
							local patVal = Evaluator.eval(pattern, env, false)
							if patVal == key then
								if #clause.elements > 1 then
									return Evaluator.eval(clause.elements[2], env, isTail)
								else
									return nil
								end
							end
						end
					end
				end
				error("case: no matching clause")

			elseif formName == "try" then
				local bodyExpr = elements[2]
				local catchClause = elements[3]
				if catchClause and catchClause.type == "list" and #catchClause.elements > 0 then
					local catchSym = catchClause.elements[1]
					if catchSym.type == "symbol" and catchSym.name == "catch" then
						local varName = catchClause.elements[2].name
						local handlerBody = catchClause.elements[3]
						local success, result = pcall(function()
							return Evaluator.eval(bodyExpr, env, false)
						end)
						if not success then
							local newEnv = {}
							setmetatable(newEnv, {__index = env})
							newEnv[varName] = result
							return Evaluator.eval(handlerBody, newEnv, isTail)
						else
							return result
						end
					end
				end
				return Evaluator.eval(bodyExpr, env, isTail)

			elseif formName == "and" then
				local result = true
				for i = 2, #elements do
					result = Evaluator.eval(elements[i], env, false)
					if not result then
						return false
					end
				end
				return result

			elseif formName == "or" then
				for i = 2, #elements do
					local result = Evaluator.eval(elements[i], env, false)
					if result then
						return result
					end
				end
				return false

			elseif formName == "for" then
				local init, cond, step, body
				if #elements == 3 and elements[2].type == "list" then
					local control = elements[2].elements
					init = control[1]
					cond = control[2]
					step = control[3]
					body = elements[3]
				else
					init = elements[2]
					cond = elements[3]
					step = elements[4]
					body = elements[5]
				end
				Evaluator.eval(init, env, false)
				local result = nil
				while true do
					local condResult = Evaluator.eval(cond, env, false)
					if not condResult then break end
					result = Evaluator.eval(body, env, false)
					Evaluator.eval(step, env, false)
				end
				return result

			elseif formName == "while" then
				local cond = elements[2]
				local body = elements[3]
				local result = nil
				while true do
					local condResult = Evaluator.eval(cond, env, false)
					if not condResult then break end
					result = Evaluator.eval(body, env, false)
				end
				return result

			elseif formName == "when" then
				local cond = elements[2]
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				if Evaluator.eval(cond, env, false) then
					local result = nil
					for _, expr in ipairs(body) do
						result = Evaluator.eval(expr, env, false)
					end
					return result
				end
				return nil

			elseif formName == "unless" then
				local cond = elements[2]
				local body = {}
				for i = 3, #elements do
					table.insert(body, elements[i])
				end
				if not Evaluator.eval(cond, env, false) then
					local result = nil
					for _, expr in ipairs(body) do
						result = Evaluator.eval(expr, env, false)
					end
					return result
				end
				return nil

			elseif formName == "struct" then
				local structName = elements[2].name
				local fieldsAst = elements[3]
				local fields = {}
				if fieldsAst.type == "list" then
					for _, fieldSym in ipairs(fieldsAst.elements) do
						table.insert(fields, fieldSym.name)
					end
				end
				local constructor = function(...)
					local args = {...}
					local obj = {}
					obj.__struct_type = structName
					for i, field in ipairs(fields) do
						obj[field] = args[i]
					end
					return obj
				end
				env[structName] = constructor
				for _, field in ipairs(fields) do
					local getterName = structName .. "-" .. field
					env[getterName] = function(obj)
						return obj[field]
					end
				end
				return constructor

			elseif formName == "tween" then
				local obj = Evaluator.eval(elements[2], env, false)
				local props = {}
				local time = 1
				local easing = "Linear"
				local i = 3
				while i <= #elements do
					local key = elements[i]
					if key.type == "symbol" then
						local keyName = key.name
						if keyName == ":time" then
							time = Evaluator.eval(elements[i + 1], env, false)
							i = i + 2
						elseif keyName == ":easing" then
							easing = elements[i + 1].value
							i = i + 2
						elseif keyName:sub(1, 1) == ":" then
							local propName = keyName:sub(2)
							propName = propName:sub(1, 1):upper() .. propName:sub(2)
							local propVal = Evaluator.eval(elements[i + 1], env, false)
							props[propName] = propVal
							i = i + 2
						else
							i = i + 1
						end
					else
						i = i + 1
					end
				end
				local tweenService = game:GetService("TweenService")
				local tweenInfo = TweenInfo.new(time, Enum.EasingStyle[easing])
				local goals = {}
				for k, v in pairs(props) do
					goals[k] = v
				end
				local tween = tweenService:Create(obj, tweenInfo, goals)
				tween:Play()
				return tween

			elseif formName == "once" then
				local obj = Evaluator.eval(elements[2], env, false)
				local eventName = elements[3].value
				local handler = Evaluator.eval(elements[4], env, false)
				local connection
				local wrappedHandler
				if type(handler) == "table" and handler.type == "function" then
					local lispFn = handler
					wrappedHandler = function(...)
						connection:Disconnect()
						local args = {...}
						local localEnv = {}
						setmetatable(localEnv, {__index = lispFn.closure})
						bindLambdaArgs(lispFn.argsInfo, args, localEnv)
						local result = nil
						for _, expr in ipairs(lispFn.body) do
							result = Evaluator.eval(expr, localEnv, false)
						end
						return result
					end
				else
					wrappedHandler = function(...)
						connection:Disconnect()
						handler(...)
					end
				end
				connection = obj[eventName]:Connect(wrappedHandler)
				return connection

			elseif formName == "on-touched" then
				local obj = Evaluator.eval(elements[2], env, false)
				local handler = Evaluator.eval(elements[3], env, false)
				if type(handler) == "table" and handler.type == "function" then
					local lispFn = handler
					local wrapped = function(...)
						local args = {...}
						local localEnv = {}
						setmetatable(localEnv, {__index = lispFn.closure})
						bindLambdaArgs(lispFn.argsInfo, args, localEnv)
						for _, expr in ipairs(lispFn.body) do
							Evaluator.eval(expr, localEnv, false)
						end
					end
					return obj.Touched:Connect(wrapped)
				else
					return obj.Touched:Connect(handler)
				end

			elseif formName == "defmacro" then
				local macroName = elements[2].name
				local argsAst = elements[3]
				local body = {}
				for i = 4, #elements do
					table.insert(body, elements[i])
				end
				local argsInfo = parseLambdaArgs(argsAst)
				local macroFn = {
					type = "function",
					argsInfo = argsInfo,
					body = body,
					closure = env,
					isMacro = true
				}
				env.__macros__[macroName] = macroFn
				return macroFn

			elseif formName == "quasiquote" then
				local template = elements[2]
				local expanded = qqExpand(template, env)
				return Evaluator.eval(expanded, env, isTail)

			elseif formName == "eval" then
				local quotedAst = Evaluator.eval(elements[2], env, false)
				return Evaluator.eval(quotedAst, env, isTail)

			elseif formName == "apply" then
				local func = Evaluator.eval(elements[2], env, false)
				local args = {}
				for i = 3, #elements do
					table.insert(args, Evaluator.eval(elements[i], env, false))
				end
				if #args > 0 and type(args[#args]) == "table" and args[#args].elements then
					local last = table.remove(args)
					for _, v in ipairs(last.elements) do
						table.insert(args, v)
					end
				end
				return applyFunction(func, args)

			elseif formName == "cons" then
				local car = Evaluator.eval(elements[2], env, false)
				local cdr = Evaluator.eval(elements[3], env, false)
				if cdr == nil then
					return {car}
				elseif type(cdr) == "table" then
					if #cdr > 0 or next(cdr) == nil then
						local result = {car}
						for _, v in ipairs(cdr) do
							table.insert(result, v)
						end
						return result
					end
				end
				return {car = car, cdr = cdr}

			elseif formName == "car" then
				local lst = Evaluator.eval(elements[2], env, false)
				if lst == nil then return nil end
				if type(lst) == "table" then
					if #lst > 0 then
						return lst[1]
					end
					if lst.car ~= nil then
						return lst.car
					end
				end
				return nil

			elseif formName == "cdr" then
				local lst = Evaluator.eval(elements[2], env, false)
				if lst == nil then return nil end
				if type(lst) == "table" then
					if #lst > 1 then
						local result = {}
						for i = 2, #lst do
							table.insert(result, lst[i])
						end
						return result
					elseif #lst == 1 then
						return {}
					end
					if lst.cdr ~= nil then
						return lst.cdr
					end
				end
				return nil

			elseif formName == "list" then
				local lst = {}
				for i = 2, #elements do
					table.insert(lst, Evaluator.eval(elements[i], env, false))
				end
				return lst

			elseif formName == "instance" then
				local className = elements[2].value
				local obj = Instance.new(className)
				local i = 3
				while i < #elements do
					local key = elements[i]
					local val = elements[i + 1]
					if key.type == "symbol" and key.name:sub(1, 1) == ":" then
						local propName = key.name:sub(2)
						local propVal = Evaluator.eval(val, env, false)
						if propName == "BrickColor" and type(propVal) == "string" then
							propVal = BrickColor.new(propVal)
						end
						obj[propName] = propVal
						i = i + 2
					else
						break
					end
				end
				return obj

			elseif formName == "service" then
				local serviceName = elements[2].value
				return game:GetService(serviceName)

			elseif formName == "connect" then
				local obj = Evaluator.eval(elements[2], env, false)
				local eventName = elements[3].value
				local handler = Evaluator.eval(elements[4], env, false)
				if type(handler) == "table" and handler.type == "function" then
					local lispFn = handler
					handler = function(...)
						local args = {...}
						local localEnv = {}
						setmetatable(localEnv, {__index = lispFn.closure})
						bindLambdaArgs(lispFn.argsInfo, args, localEnv)
						local result = nil
						for _, expr in ipairs(lispFn.body) do
							result = Evaluator.eval(expr, localEnv, false)
						end
						return result
					end
				end
				return obj[eventName]:Connect(handler)

			elseif formName:match(":") then
				local parts = {}
				for part in formName:gmatch("[^:]+") do
					table.insert(parts, part)
				end
				if #parts == 2 then
					local objName = parts[1]
					local methodName = parts[2]
					local obj = nil
					local current = env
					while current do
						if rawget(current, objName) ~= nil then
							obj = rawget(current, objName)
							break
						end
						local mt = getmetatable(current)
						if mt and mt.__index and type(mt.__index) == "table" then
							current = mt.__index
						else
							break
						end
					end
					if not obj and _G[objName] then
						obj = _G[objName]
					end
					if not obj and _G.game and _G.game[objName] then
						obj = _G.game[objName]
					end
					if obj then
						local args = {}
						for i = 2, #elements do
							table.insert(args, Evaluator.eval(elements[i], env, false))
						end
						local method = obj[methodName]
						if type(method) == "function" then
							return method(obj, table.unpack(args))
						else
							error("Not a method: " .. methodName)
						end
					else
						error("Undefined object: " .. objName)
					end
				end

			elseif env.__macros__ and env.__macros__[formName] then
				local macro = env.__macros__[formName]
				local macroArgs = {}
				for i = 2, #elements do
					table.insert(macroArgs, elements[i])
				end
				local macroEnv = {}
				setmetatable(macroEnv, {__index = macro.closure})
				bindLambdaArgs(macro.argsInfo, macroArgs, macroEnv)
				local result = nil
				for _, expr in ipairs(macro.body) do
					result = Evaluator.eval(expr, macroEnv, false)
				end
				return Evaluator.eval(result, env, isTail)
			end
		end

		local func = Evaluator.eval(first, env, false)
		local args = {}
		for i = 2, #elements do
			table.insert(args, Evaluator.eval(elements[i], env, false))
		end
		if isTail then
			return {tailcall = true, func = func, args = args}
		else
			return applyFunction(func, args)
		end
	end
end

function Evaluator.evaluate(ast, env)
	local result = Evaluator.eval(ast, env, false)
	while type(result) == "table" and result.tailcall do
		result = applyFunction(result.func, result.args)
	end
	return result
end

return Evaluator
