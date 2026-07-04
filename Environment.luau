local Environment = {}

function Environment.create()
	local env = {}
	env.__macros__ = {}

	env["+"] = function(a, b) return a + b end
	env["-"] = function(a, b) return a - b end
	env["*"] = function(a, b) return a * b end
	env["/"] = function(a, b) return a / b end
	env["%"] = function(a, b) return a % b end
	env["^"] = function(a, b) return a ^ b end
	env["="] = function(a, b) return a == b end
	env["<"] = function(a, b) return a < b end
	env[">"] = function(a, b) return a > b end
	env["<="] = function(a, b) return a <= b end
	env[">="] = function(a, b) return a >= b end
	env["~="] = function(a, b) return a ~= b end

	env["print"] = function(...) print(...) end
	env["warn"] = function(...) warn(...) end

	env["vector3"] = function(x, y, z) return Vector3.new(x, y, z) end
	env["vector2"] = function(x, y) return Vector2.new(x, y) end
	env["cframe"] = function(x, y, z) return CFrame.new(x, y, z) end
	env["color3"] = function(r, g, b) return Color3.fromRGB(r, g, b) end

	env["vector3+"] = function(a, b) return a + b end
	env["vector3-"] = function(a, b) return a - b end
	env["vector3*"] = function(v, s) return v * s end
	env["vector3/"] = function(v, s) return v / s end
	env["vector3-dot"] = function(a, b) return a:Dot(b) end
	env["vector3-cross"] = function(a, b) return a:Cross(b) end
	env["vector3-length"] = function(v) return v.Magnitude end
	env["vector3-unit"] = function(v) return v.Unit end
	env["vector3-lerp"] = function(a, b, t) return a:Lerp(b, t) end

	env["cframe*"] = function(a, b) return a * b end
	env["cframe-lookAt"] = function(from, to) return CFrame.lookAt(from, to) end
	env["cframe-angles"] = function(rx, ry, rz) return CFrame.Angles(rx, ry, rz) end

	env["wait"] = function(t) task.wait(t) end
	env["spawn"] = function(fn) task.spawn(fn) end

	env["apply"] = function(fn, ...)
		local args = {...}
		if #args > 0 and type(args[#args]) == "table" then
			local last = table.remove(args)
			for _, v in ipairs(last) do
				table.insert(args, v)
			end
		end
		return fn(table.unpack(args))
	end

	env["null?"] = function(lst)
		if lst == nil then return true end
		if type(lst) == "table" and #lst == 0 then return true end
		return false
	end

	env["gensym"] = function()
		return "G__" .. tostring(math.random(1000000))
	end

	env["string-append"] = function(...)
		return table.concat({...})
	end

	env["string-length"] = function(s)
		return #s
	end

	env["string-ref"] = function(s, i)
		return s:sub(i, i)
	end

	env["substring"] = function(s, start, finish)
		return s:sub(start, finish or #s)
	end

	env["string-upcase"] = function(s)
		return s:upper()
	end

	env["string-downcase"] = function(s)
		return s:lower()
	end

	env["string-split"] = function(s, sep)
		local result = {}
		for part in s:gmatch("[^" .. sep .. "]+") do
			table.insert(result, part)
		end
		return result
	end

	env["string-trim"] = function(s)
		return s:match("^%s*(.-)%s*$")
	end

	env["sort"] = function(lst, cmp)
		local copy = {}
		for _, v in ipairs(lst) do
			table.insert(copy, v)
		end
		if cmp then
			table.sort(copy, function(a, b) return cmp(a, b) end)
		else
			table.sort(copy)
		end
		return copy
	end

	env["filter"] = function(fn, lst)
		local result = {}
		for _, v in ipairs(lst) do
			if fn(v) then
				table.insert(result, v)
			end
		end
		return result
	end

	env["reduce"] = function(fn, init, lst)
		local acc = init
		for _, v in ipairs(lst) do
			acc = fn(acc, v)
		end
		return acc
	end

	env["map"] = function(fn, lst)
		local result = {}
		for _, v in ipairs(lst) do
			table.insert(result, fn(v))
		end
		return result
	end

	env["range"] = function(start, stop, step)
		step = step or 1
		local result = {}
		if step > 0 then
			for i = start, stop, step do
				table.insert(result, i)
			end
		else
			for i = start, stop, step do
				table.insert(result, i)
			end
		end
		return result
	end

	env["zip"] = function(...)
		local lists = {...}
		local result = {}
		local minLen = math.huge
		for _, lst in ipairs(lists) do
			if #lst < minLen then
				minLen = #lst
			end
		end
		for i = 1, minLen do
			local tuple = {}
			for _, lst in ipairs(lists) do
				table.insert(tuple, lst[i])
			end
			table.insert(result, tuple)
		end
		return result
	end

	env["curry"] = function(fn, ...)
		local fixed = {...}
		return function(...)
			local args = {}
			for _, v in ipairs(fixed) do
				table.insert(args, v)
			end
			for _, v in ipairs({...}) do
				table.insert(args, v)
			end
			return fn(table.unpack(args))
		end
	end

	env["compose"] = function(...)
		local fns = {...}
		return function(x)
			local result = x
			for i = #fns, 1, -1 do
				result = fns[i](result)
			end
			return result
		end
	end

	env["printf"] = function(fmt, ...)
		print(string.format(fmt, ...))
	end

	env["time"] = function(fn)
		local start = os.clock()
		fn()
		return os.clock() - start
	end

	env["assert"] = function(condition, msg)
		if not condition then
			error(msg or "assertion failed")
		end
		return condition
	end

	env["memoize"] = function(fn)
		local cache = {}
		return function(...)
			local key = table.concat({...}, "\0")
			if cache[key] == nil then
				cache[key] = fn(...)
			end
			return cache[key]
		end
	end

	env["raycast"] = function(origin, direction, params)
		local raycastParams = params or RaycastParams.new()
		return workspace:Raycast(origin, direction, raycastParams)
	end

	env["disconnect"] = function(connection)
		connection:Disconnect()
	end

	setmetatable(env, {
		__index = function(t, k)
			if rawget(t, k) ~= nil then
				return rawget(t, k)
			end
			if _G[k] ~= nil then
				return _G[k]
			end
			if _G.game and _G.game[k] ~= nil then
				return _G.game[k]
			end
			return nil
		end
	})

	return env
end

return Environment
