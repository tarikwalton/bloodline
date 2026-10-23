-- MapService (Server)
-- Loads maps from ServerStorage.Maps into Workspace.ActiveMap, validates and scores spawns,
-- applies per-map lighting and cleans everything up afterwards.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local MapConfig = require(ReplicatedStorage.Shared.Config.MapConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Utilities.Signal)
local HitQuery = require(script.Parent.Parent.Weapons.HitQuery)

local SPAWN = GameConfig.Spawn

local MapService = {}
MapService.MapLoaded = Signal.new() -- (mapId)
MapService.MapUnloaded = Signal.new() -- (mapId)

local mapsFolder = ServerStorage:WaitForChild("Maps")
local activeFolder = workspace:WaitForChild("ActiveMap")
local lobby = workspace:WaitForChild("Lobby")
local rng = Random.new()

local current = nil -- { Id, Model, Spawns: {CFrame}, KillY }

-- Applies a lighting preset. Plain keys set Lighting properties; table values configure the
-- Lighting child of that class (e.g. Atmosphere = { Density = 0.3 }).
local function applyLighting(settings)
	if not settings then
		return
	end
	for property, value in settings do
		if type(value) == "table" then
			local effect = Lighting:FindFirstChildOfClass(property)
			if not effect then
				local ok, created = pcall(Instance.new, property)
				if ok then
					created.Parent = Lighting
					effect = created
				end
			end
			if effect then
				for key, subValue in value do
					local ok, err = pcall(function()
						effect[key] = subValue
					end)
					if not ok then
						warn("[MapService] Lighting effect property failed:", property, key, err)
					end
				end
			end
		else
			local ok, err = pcall(function()
				Lighting[property] = value
			end)
			if not ok then
				warn("[MapService] Lighting property failed:", property, err)
			end
		end
	end
end

function MapService:Init(services)
	self.Services = services
	applyLighting(MapConfig.LobbyLighting)
end

function MapService:Start() end

-- Map ids that are enabled, exist in ServerStorage, and support the mode.
function MapService:GetAvailableMaps(modeId)
	local list = {}
	for id, config in MapConfig.Maps do
		if config.Enabled and mapsFolder:FindFirstChild(id) and table.find(config.Modes, modeId) then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

function MapService:PickRandomMap(modeId, excludeId)
	local list = self:GetAvailableMaps(modeId)
	if #list > 1 and excludeId then
		local index = table.find(list, excludeId)
		if index then
			table.remove(list, index)
		end
	end
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

-- Spawn validation: a spawn must have floor beneath it.
local function isSpawnValid(cframe)
	local result = workspace:Raycast(cframe.Position + Vector3.new(0, 1, 0), Vector3.new(0, -12, 0), HitQuery.WorldParams())
	return result ~= nil
end

function MapService:LoadMap(mapId)
	self:UnloadMap()

	local template = mapsFolder:FindFirstChild(mapId)
	if not template then
		warn("[MapService] Map not found in ServerStorage.Maps:", mapId)
		return nil
	end

	local model = template:Clone()
	model.Parent = activeFolder

	local spawns = {}
	local spawnFolder = model:FindFirstChild("Spawns")
	if spawnFolder then
		for _, part in spawnFolder:GetChildren() do
			if part:IsA("BasePart") then
				if isSpawnValid(part.CFrame) then
					table.insert(spawns, part.CFrame)
				else
					warn("[MapService] Spawn has no floor, skipping:", part:GetFullName())
				end
			end
		end
	end
	if #spawns == 0 then
		warn("[MapService] Map has no valid spawns:", mapId)
	end

	current = {
		Id = mapId,
		Model = model,
		Spawns = spawns,
		KillY = model:GetAttribute("KillY"),
	}
	local config = MapConfig.Maps[mapId]
	applyLighting(config and config.Lighting)
	self.MapLoaded:Fire(mapId)
	return model
end

-- expectedId (optional): only unload if that map is still the active one.
function MapService:UnloadMap(expectedId)
	if expectedId and (not current or current.Id ~= expectedId) then
		return
	end
	local previous = current
	current = nil
	activeFolder:ClearAllChildren()
	applyLighting(MapConfig.LobbyLighting)
	if previous then
		self.MapUnloaded:Fire(previous.Id)
	end
end

function MapService:GetCurrentMapId()
	return current and current.Id
end

function MapService:GetDisplayName(mapId)
	local config = MapConfig.Maps[mapId]
	return config and config.DisplayName or mapId
end

function MapService:GetKillY()
	return current and current.KillY
end

function MapService:GetSpawnPoints()
	return current and current.Spawns or {}
end

-- Picks a spawn that is far from enemies. Random among the safest N for unpredictability.
function MapService:GetSpawnCFrame(enemyPositions)
	if not current or #current.Spawns == 0 then
		return nil
	end

	local scored = {}
	for _, cframe in current.Spawns do
		local nearest = math.huge
		for _, position in enemyPositions do
			local distance = (position - cframe.Position).Magnitude
			if distance < nearest then
				nearest = distance
			end
		end
		table.insert(scored, { CFrame = cframe, Score = nearest + rng:NextNumber() }) -- jitter breaks ties
	end
	table.sort(scored, function(a, b)
		return a.Score > b.Score
	end)

	local candidates = {}
	for index, entry in scored do
		if index > SPAWN.RandomTopN then
			break
		end
		if index == 1 or entry.Score >= SPAWN.MinEnemyDistance then
			table.insert(candidates, entry)
		end
	end
	local pick = candidates[rng:NextInteger(1, #candidates)]
	return pick.CFrame + Vector3.new(0, SPAWN.HeightOffset, 0)
end

function MapService:GetLobbySpawnCFrame()
	local folder = lobby:FindFirstChild("LobbySpawns")
	local spawns = folder and folder:GetChildren() or {}
	if #spawns == 0 then
		return CFrame.new(0, 5, 0)
	end
	local part = spawns[rng:NextInteger(1, #spawns)]
	return part.CFrame + Vector3.new(0, SPAWN.HeightOffset, 0)
end

return MapService
