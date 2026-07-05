--!strict

local CEKMachine = {}

local function tableClone(tbl: {any}): {any}
	local result = {}
	for k, v in pairs(tbl) do
		result[k] = v
	end
	return result
end

local function parseLambdaArgs(argsAst: any): any
	local required: { string } = {}
	local optional: { any } = {}
	local key: { any } = {}
	local vararg = false
	local varargName: string? = nil

	if argsAst.type == "symbol" then
		vararg = true
		varargName = argsAst.name
		return { required = required, optional = optional, key = key, vararg = vararg, varargName = varargName }
	end

	local elements: { any } = argsAst.elements
	local i = 1
	local mode = "required"

	while i <= #elements do
		local elem = elements[i]
		if elem.type == "symbol" then
			local name: string = elem.name
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
					i = i + 1
				elseif mode == "optional" then
					if i + 1 <= #elements and elements[i + 1].type ~= "symbol" then
						table.insert(optional, { name = name, default = elements[i + 1] })
						i = i + 2
					else
						table.insert(optional, { name = name, default = { type = "nil" } })
						i = i + 1
					end
				elseif mode == "key" then
					if i + 1 <= #elements and elements[i + 1].type ~= "symbol" then
						table.insert(key, { name = name, default = elements[i + 1] })
						i = i + 2
					else
						table.insert(key, { name = name, default = { type = "nil" } })
						i = i + 1
					end
				end
			end
		else
			i = i + 1
		end
	end

	return { required = required, optional = optional, key = key, vararg = vararg, varargName = varargName }
end

local function bindLambdaArgs(argsInfo: any, args: { any }, localEnv: { [string]: any }): ()
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
			localEnv[opt.name] = CEKMachine.evaluate(opt.default, localEnv)
		end
	end

	if argsInfo.vararg then
		local rest: { any } = {}
		while argIndex <= #args do
			table.insert(rest, args[argIndex])
			argIndex = argIndex + 1
		end
		localEnv[argsInfo.varargName :: string] = rest
	else
		for _, kw in ipairs(argsInfo.key) do
			localEnv[kw.name] = nil
		end

		for _, kw in ipairs(argsInfo.key) do
			local found = false
			local keyIdx = 1
			while keyIdx < #args do
				local keySym = args[keyIdx]
				if type(keySym) == "string" and keySym:sub(1, 1) == ":" and keySym:sub(2) == kw.name then
					localEnv[kw.name] = args[keyIdx + 1]
					found = true
					break
				end
				keyIdx = keyIdx + 2
			end
			if not found then
				localEnv[kw.name] = CEKMachine.evaluate(kw.default, localEnv)
			end
		end
	end
end

function CEKMachine.evaluate(ast: any, globalEnv: { [string]: any }): any
	local control: any = ast
	local env: { [string]: any } = globalEnv
	local val: any = nil
	local kStack: { any } = {}

	while control ~= nil or #kStack > 0 do
		if control ~= nil then
			if type(control) == "table" and control.type == "value" then
				val = control.value
				control = nil
			else
				local node = control
				control = nil

				if node.type == "number" or node.type == "string" or node.type == "boolean" or node.type == "nil" then
					val = node.value
				elseif node.type == "symbol" then
					local name: string = node.name
					if name:sub(1, 1) == ":" then
						val = name
					else
						local current: any = env
						local found = nil
						while current do
							if rawget(current, name) ~= nil then
								found = rawget(current, name)
								break
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
						if found == nil then
							if _G[name] ~= nil then found = _G[name]
							elseif _G.game and (_G.game :: any)[name] ~= nil then found = (_G.game :: any)[name]
							else error("Undefined symbol: " .. name) end
						end
						val = found
					end
				elseif node.type == "list" then
					local elements: { any } = node.elements
					if #elements == 0 then
						val = nil
					else
						local first = elements[1]

						if first.type == "symbol" then
							local formName: string = first.name

							if formName == "call/cc" then
								local stackSnapshot = {}
								for _, frame in ipairs(kStack) do
									local frameCopy = {
										type = frame.type,
										env = frame.env,
										pending = frame.pending and tableClone(frame.pending) or nil,
										ready = frame.ready and tableClone(frame.ready) or nil,
										varName = frame.varName,
										thenBranch = frame.thenBranch,
										elseBranch = frame.elseBranch,
										bindings = frame.bindings,
										index = frame.index,
										body = frame.body,
									}
									table.insert(stackSnapshot, frameCopy)
								end
								local continuationObject = {
									type = "continuation",
									stack = stackSnapshot,
								}
								table.insert(kStack, {
									type = "callcc",
									env = env,
									cont = continuationObject
								})
								control = elements[2]

							elseif formName == "define" then
								local varName = elements[2].name
								table.insert(kStack, { type = "define-var", env = env, varName = varName })
								control = elements[3]

							elseif formName == "lambda" then
								local argsAst = elements[2]
								local body: { any } = {}
								for i = 3, #elements do table.insert(body, elements[i]) end
								local func = {
									type = "function",
									argsInfo = parseLambdaArgs(argsAst),
									body = body,
									closure = env
								}
								val = func

							elseif formName == "if" then
								table.insert(kStack, {
									type = "if-branch",
									env = env,
									thenBranch = elements[3],
									elseBranch = elements[4]
								})
								control = elements[2]

							elseif formName == "begin" then
								for i = #elements, 2, -1 do
									if i == #elements then
										control = elements[i]
									else
										table.insert(kStack, { type = "begin-seq", env = env })
										control = elements[i]
									end
								end

							elseif formName == "quote" then
								val = elements[2]

							elseif formName == "set!" then
								local varName = elements[2].name
								table.insert(kStack, { type = "set-var", env = env, varName = varName })
								control = elements[3]

							elseif formName == "let" then
								local bindingsList = elements[2].elements
								local body: { any } = {}
								for i = 3, #elements do table.insert(body, elements[i]) end
								local newEnv: { [string]: any } = {}
								setmetatable(newEnv, { __index = env })
								if #bindingsList > 0 then
									local binding = bindingsList[1]
									if binding.type == "list" and #binding.elements == 2 then
										table.insert(kStack, {
											type = "let-bind",
											env = newEnv,
											varName = binding.elements[1].name,
											bindings = bindingsList,
											index = 1,
											body = body
										})
										control = binding.elements[2]
									end
								else
									if #body > 0 then
										control = body[1]
										env = newEnv
									else
										val = nil
									end
								end

							elseif formName == "syntax-rules" then
								local literalsList = elements[2].elements
								local literals = {}
								for _, lit in ipairs(literalsList) do table.insert(literals, lit.name) end
								local rules = {}
								for i = 3, #elements do
									local rule = elements[i]
									if rule.type == "list" and #rule.elements == 2 then
										table.insert(rules, { pattern = rule.elements[1], template = rule.elements[2] })
									end
								end
								val = { type = "syntax-rules", rules = rules, literals = literals, closure = env }

							else
								local pendingArgs = {}
								for i = 2, #elements do table.insert(pendingArgs, elements[i]) end
								table.insert(kStack, { type = "eval-arg", env = env, pending = pendingArgs, ready = {} })
								control = first
							end
						else
							local pendingArgs = {}
							for i = 2, #elements do table.insert(pendingArgs, elements[i]) end
							table.insert(kStack, { type = "eval-arg", env = env, pending = pendingArgs, ready = {} })
							control = first
						end
					end
				end
			end
		else
			if #kStack == 0 then break end
			local frame = table.remove(kStack)

			if frame.type == "define-var" then
				frame.env[frame.varName] = val
				val = frame.varName

			elseif frame.type == "if-branch" then
				local cond = val
				local branch = cond and frame.thenBranch or frame.elseBranch
				if branch then
					control = branch
				else
					val = nil
				end

			elseif frame.type == "begin-seq" then
				-- nothing

			elseif frame.type == "set-var" then
				local varName = frame.varName
				local cur = frame.env
				while cur do
					if rawget(cur, varName) ~= nil then
						cur[varName] = val
						break
					end
					local mt = getmetatable(cur)
					if mt and mt.__index and type(mt.__index) == "table" then
						cur = mt.__index
					else
						break
					end
				end
				if not rawget(frame.env, varName) then
					frame.env[varName] = val
				end

			elseif frame.type == "let-bind" then
				frame.env[frame.varName] = val
				local nextIndex = frame.index + 1
				if nextIndex <= #frame.bindings then
					local binding = frame.bindings[nextIndex]
					if binding.type == "list" and #binding.elements == 2 then
						frame.index = nextIndex
						table.insert(kStack, frame)
						control = binding.elements[2]
					end
				else
					env = frame.env
					if #frame.body > 0 then
						control = frame.body[1]
					else
						val = nil
					end
				end

			elseif frame.type == "callcc" then
				local f = val
				if type(f) == "table" and f.type == "function" then
					local localEnv: { [string]: any } = {}
					setmetatable(localEnv, { __index = f.closure })
					if f.argsInfo.required[1] then
						localEnv[f.argsInfo.required[1]] = frame.cont
					end
					if #f.body > 0 then
						if #f.body > 1 then
							table.insert(kStack, {
								type = "func-body",
								body = { table.unpack(f.body, 2) },
								env = localEnv
							})
						end
						control = f.body[1]
						env = localEnv
					else
						val = nil
					end
				elseif type(f) == "function" then
					val = f(frame.cont)
					control = nil
				else
					error("call/cc: argument must be a function")
				end

			elseif frame.type == "func-body" then
				if #frame.body > 0 then
					local nextExpr = table.remove(frame.body, 1)
					table.insert(kStack, frame)
					control = nextExpr
				end

			elseif frame.type == "eval-arg" then
				table.insert(frame.ready, val)
				if #frame.pending > 0 then
					local nextNode = table.remove(frame.pending, 1)
					table.insert(kStack, frame)
					control = nextNode
				else
					local func = table.remove(frame.ready, 1)
					local args = frame.ready

					if type(func) == "table" and func.type == "continuation" then
						kStack = {}
						for _, savedFrame in ipairs(func.stack) do
							local restoredFrame = {
								type = savedFrame.type,
								env = savedFrame.env,
								pending = savedFrame.pending and tableClone(savedFrame.pending) or nil,
								ready = savedFrame.ready and tableClone(savedFrame.ready) or nil,
								varName = savedFrame.varName,
								thenBranch = savedFrame.thenBranch,
								elseBranch = savedFrame.elseBranch,
								bindings = savedFrame.bindings,
								index = savedFrame.index,
								body = savedFrame.body,
							}
							table.insert(kStack, restoredFrame)
						end
						if #kStack > 0 then
							local topFrame = kStack[#kStack]
							if topFrame.type == "eval-arg" then
								topFrame.pending = {}
							end
						end
						val = args[1] or nil
						control = nil
					elseif type(func) == "table" and func.type == "function" then
						local localEnv: { [string]: any } = {}
						setmetatable(localEnv, { __index = func.closure })
						bindLambdaArgs(func.argsInfo, args, localEnv)
						if #func.body > 0 then
							if #func.body > 1 then
								table.insert(kStack, {
									type = "func-body",
									body = { table.unpack(func.body, 2) },
									env = localEnv
								})
							end
							control = func.body[1]
							env = localEnv
						else
							val = nil
						end
					elseif type(func) == "table" and func.type == "syntax-rules" then
						local oldEval = require(script.Parent.Evaluator)
						local expanded = oldEval.expandSyntaxRules(func, { { type = "symbol", name = "macro" }, table.unpack(args) }, frame.env)
						if expanded then
							control = expanded
							env = frame.env
						else
							error("syntax-rules: no matching pattern")
						end
					elseif type(func) == "function" then
						val = func(table.unpack(args))
						control = nil
					else
						error("Not a function: " .. tostring(func))
					end
				end
			end
		end
	end
	return val
end

return CEKMachine
