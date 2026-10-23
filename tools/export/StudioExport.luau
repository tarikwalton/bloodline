-- StudioExport
-- Read-only exporter: walks the open place and returns every script as JSON so
-- tools/export/write_export.py can write it into the Rojo layout. It never changes
-- the place. Run it from the Studio command bar or an execute_luau call.
--
-- Usage: paste this file, then call Export(fromIndex, maxBytes). Each call returns
-- one JSON chunk: { total, from, to, done, warnings, files = { {path, content} } }.
-- Keep calling with from = previous `to` + 1 until done is true.

local HttpService = game:GetService("HttpService")

-- Rojo-managed roots: these round-trip with `rojo build` / `rojo serve`.
local MANAGED_ROOTS = {
	{ instance = game:GetService("ReplicatedFirst"), path = "src/ReplicatedFirst" },
	{ instance = game:GetService("ReplicatedStorage"), path = "src/ReplicatedStorage" },
	{ instance = game:GetService("ServerScriptService"), path = "src/ServerScriptService" },
	{ instance = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"), path = "src/StarterPlayer/StarterPlayerScripts" },
	{ instance = game:GetService("StarterPlayer"):WaitForChild("StarterCharacterScripts"), path = "src/StarterPlayer/StarterCharacterScripts" },
}

-- Scripts that live inside Studio-built instances (GUIs, maps, models). Exported for
-- review and history only; Studio stays the source of truth for these.
local SNAPSHOT_ROOTS = {
	{ instance = game:GetService("StarterGui"), path = "studio-only/StarterGui" },
	{ instance = game:GetService("ServerStorage"), path = "studio-only/ServerStorage" },
	{ instance = game:GetService("Workspace"), path = "studio-only/Workspace" },
	{ instance = game:GetService("StarterPack"), path = "studio-only/StarterPack" },
}

-- Backups and third-party sources are skipped anywhere in the tree.
local SKIP_NAMES = {
	ScriptBackups = true,
	OldBackups_SafeToDelete = true,
	MapsBackup = true,
	WeaponSources = true,
}

local function isScript(inst: Instance): boolean
	return inst:IsA("LuaSourceContainer") and (inst:IsA("Script") or inst:IsA("LocalScript") or inst:IsA("ModuleScript"))
end

local function hasScriptBelow(inst: Instance): boolean
	for _, d in inst:GetDescendants() do
		if isScript(d) then
			return true
		end
	end
	return false
end

local function shouldSkip(inst: Instance): boolean
	return SKIP_NAMES[inst.Name] == true or inst.Name:match("^Before%u") ~= nil
end

local function suffixFor(inst: Instance): string
	if inst:IsA("ModuleScript") then
		return ".luau"
	elseif inst:IsA("LocalScript") then
		return ".client.luau"
	elseif (inst :: any).RunContext == Enum.RunContext.Client then
		return ".client.luau"
	end
	return ".server.luau"
end

local function safeName(name: string): string
	local cleaned = name:gsub('[<>:"/\\|%?%*%c]', "_")
	if cleaned == "" or cleaned == "." or cleaned == ".." then
		cleaned = "_"
	end
	return cleaned
end

local function sortedChildren(inst: Instance): { Instance }
	local children = inst:GetChildren()
	table.sort(children, function(a, b)
		if a.Name == b.Name then
			return a.ClassName < b.ClassName
		end
		return a.Name < b.Name
	end)
	return children
end

local function collect(): ({ any }, { string })
	local files = {}
	local warnings = {}

	local function addMeta(filePath: string, meta: { [string]: any })
		table.insert(files, { path = filePath, content = HttpService:JSONEncode(meta) .. "\n" })
	end

	local function scriptMeta(inst: Instance, hasOtherChildren: boolean): { [string]: any }?
		local meta: { [string]: any } = {}
		local any = false
		if inst:IsA("BaseScript") and not (inst :: any).Enabled then
			meta.properties = { Enabled = false }
			any = true
		end
		if hasOtherChildren then
			meta.ignoreUnknownInstances = true
			any = true
		end
		return if any then meta else nil
	end

	local function visit(parent: Instance, dirPath: string)
		local used = {}
		for _, child in sortedChildren(parent) do
			if shouldSkip(child) then
				continue
			end
			local scriptChild = isScript(child)
			if not scriptChild and not hasScriptBelow(child) then
				continue
			end

			local name = safeName(child.Name)
			local key = name:lower()
			if used[key] then
				local n = 2
				while used[key .. "_" .. n] do
					n += 1
				end
				table.insert(warnings, ("duplicate sibling name %s under %s, exported as %s_%d"):format(child.Name, parent:GetFullName(), name, n))
				name = name .. "_" .. n
				key = key .. "_" .. n
			end
			used[key] = true

			local hasNonScriptChildren = false
			for _, c in child:GetChildren() do
				if not isScript(c) then
					hasNonScriptChildren = true
					break
				end
			end

			if scriptChild then
				local source = (child :: any).Source
				if hasScriptBelow(child) then
					local dir = dirPath .. "/" .. name
					local suffix = suffixFor(child)
					table.insert(files, { path = dir .. "/init" .. suffix, content = source })
					local meta = scriptMeta(child, hasNonScriptChildren)
					if meta then
						addMeta(dir .. "/init.meta.json", meta)
					end
					visit(child, dir)
				else
					table.insert(files, { path = dirPath .. "/" .. name .. suffixFor(child), content = source })
					local meta = scriptMeta(child, hasNonScriptChildren)
					if meta then
						addMeta(dirPath .. "/" .. name .. ".meta.json", meta)
					end
				end
			else
				local dir = dirPath .. "/" .. name
				local meta: { [string]: any } = { ignoreUnknownInstances = true }
				if child.ClassName ~= "Folder" then
					meta.className = child.ClassName
				end
				addMeta(dir .. "/init.meta.json", meta)
				visit(child, dir)
			end
		end
	end

	for _, root in MANAGED_ROOTS do
		visit(root.instance, root.path)
	end
	for _, root in SNAPSHOT_ROOTS do
		visit(root.instance, root.path)
	end
	return files, warnings
end

function Export(fromIndex: number?, maxBytes: number?): string
	local files, warnings = collect()
	local from = fromIndex or 1
	local budget = maxBytes or 150000
	local chunk = {}
	local used = 0
	local last = from - 1
	for i = from, #files do
		local size = #files[i].content + #files[i].path
		if #chunk > 0 and used + size > budget then
			break
		end
		table.insert(chunk, files[i])
		used += size
		last = i
	end
	return HttpService:JSONEncode({
		total = #files,
		from = from,
		to = last,
		done = last >= #files,
		warnings = if from == 1 then warnings else {},
		files = chunk,
	})
end

-- Quick summary without the sources: file count, line count, warnings.
function ExportSummary(): string
	local files, warnings = collect()
	local lines = 0
	for _, f in files do
		local _, n = f.content:gsub("\n", "")
		lines += n + 1
	end
	return HttpService:JSONEncode({ files = #files, lines = lines, warnings = warnings })
end
