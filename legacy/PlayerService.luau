-- PlayerService (Server)
-- Owns player life-cycle: joining, character spawning (lobby or match), life state,
-- spawn protection, respawn scheduling and out-of-bounds kills.
-- CharacterAutoLoads is OFF - every character is spawned deliberately by this service.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Enums = require(ReplicatedStorage.Shared.Constants.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Utilities.Signal)
local Maid = require(ReplicatedStorage.Shared.Utilities.Maid)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local HitQuery = require(script.Parent.Parent.Weapons.HitQuery)

local LifeState = Enums.LifeState

local PlayerService = {}
PlayerService.PlayerJoined = Signal.new() -- (player)
PlayerService.PlayerLeaving = Signal.new() -- (player)
PlayerService.CharacterSpawned = Signal.new() -- (player, character, inMatch)
PlayerService.CharacterDied = Signal.new() -- (player, character)

local states = {} -- [Player] = { LifeState, InMatch, CharacterMaid, SpawnToken, RespawnToken }

function PlayerService:Init(services)
	self.Services = services
	Players.CharacterAutoLoads = false
	HitQuery.Setup()
end

function PlayerService:Start()
	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)
	-- Players who joined before the server finished booting (common in Studio). Deferred so
	-- every other service has finished Start() and connected to PlayerJoined.
	task.defer(function()
		for _, player in Players:GetPlayers() do
			self:_onPlayerAdded(player)
		end
	end)

	-- Out-of-bounds check at 5 Hz (cheap, avoids per-frame work)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= 0.2 then
			accumulator = 0
			self:_checkOutOfBounds()
		end
	end)
end

-- Joining / leaving ----------------------------------------------------------------
function PlayerService:_onPlayerAdded(player)
	if states[player] then
		return
	end
	states[player] = {
		LifeState = LifeState.Lobby,
		InMatch = false,
		CharacterMaid = Maid.new(),
		SpawnToken = 0,
		RespawnToken = 0,
	}
	player:SetAttribute("InMatch", false)
	player:SetAttribute("LifeState", LifeState.Lobby)
	player:SetAttribute("RespawnAt", 0)
	self.PlayerJoined:Fire(player)
end

function PlayerService:_onPlayerRemoving(player)
	local state = states[player]
	if not state then
		return
	end
	self.PlayerLeaving:Fire(player)
	state.CharacterMaid:Clean()
	states[player] = nil
end

-- Bots join and leave through the same path as players.
function PlayerService:AddCombatant(combatant)
	self:_onPlayerAdded(combatant)
end

function PlayerService:RemoveCombatant(combatant)
	self:_onPlayerRemoving(combatant)
end

-- Queries --------------------------------------------------------------------------
function PlayerService:GetState(player)
	return states[player]
end

function PlayerService:IsAlive(player)
	local state = states[player]
	if not state or state.LifeState ~= LifeState.Alive then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function PlayerService:IsInMatch(player)
	local state = states[player]
	return state ~= nil and state.InMatch
end

function PlayerService:GetRoot(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

function PlayerService:SetInMatch(player, inMatch)
	local state = states[player]
	if not state then
		return
	end
	state.InMatch = inMatch
	player:SetAttribute("InMatch", inMatch)
	if not inMatch then
		self:CancelRespawn(player)
	end
end

function PlayerService:_setLifeState(player, lifeState)
	local state = states[player]
	if state then
		state.LifeState = lifeState
		player:SetAttribute("LifeState", lifeState)
	end
end

-- Spawning -------------------------------------------------------------------------
-- Yields (LoadCharacter). Call from task.spawn when spawning many players.
function PlayerService:Spawn(player, cframe, inMatch)
	local state = states[player]
	if not state then
		return nil
	end
	state.SpawnToken += 1
	local token = state.SpawnToken
	self:CancelRespawn(player)
	state.CharacterMaid:Clean()

	local ok, err = pcall(player.LoadCharacter, player)
	if not ok then
		warn("[PlayerService] LoadCharacter failed for", player.Name, err)
		return nil
	end
	-- A newer spawn request (or leaving) supersedes this one.
	if states[player] ~= state or state.SpawnToken ~= token then
		return nil
	end

	local character = player.Character
	local humanoid = character and character:WaitForChild("Humanoid", 5)
	local root = character and character:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not root then
		return nil
	end
	character:PivotTo(cframe)
	self:_setupCharacter(player, state, character, humanoid, root, inMatch)
	return character
end

function PlayerService:SpawnInLobby(player)
	return self:Spawn(player, self.Services.MapService:GetLobbySpawnCFrame(), false)
end

function PlayerService:SpawnInMatch(player)
	local enemies = self.Services.MatchService:GetEnemyPositions(player)
	local cframe = self.Services.MapService:GetSpawnCFrame(enemies)
	if not cframe then
		return self:SpawnInLobby(player)
	end
	return self:Spawn(player, cframe, true)
end

function PlayerService:_setupCharacter(player, state, character, humanoid, root, inMatch)
	local maid = state.CharacterMaid
	self:_setLifeState(player, LifeState.Alive)
	player:SetAttribute("RespawnAt", 0)

	humanoid.BreakJointsOnDeath = true
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	-- Collision group for world-only line-of-sight; accessories/tools never block shots.
	local function prepare(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = HitQuery.CHARACTER_GROUP
			if descendant:FindFirstAncestorOfClass("Accessory") or descendant:FindFirstAncestorOfClass("Tool") then
				descendant.CanQuery = false
				descendant.CanTouch = false
			end
		end
	end
	for _, descendant in character:GetDescendants() do
		prepare(descendant)
	end
	maid:Give(character.DescendantAdded:Connect(prepare))

	self.Services.LagCompensationService:Reset(player)
	self.Services.CombatService:InitCharacter(player, character, humanoid)

	maid:Give(humanoid.Died:Connect(function()
		self:_onHumanoidDied(player, character)
	end))

	if inMatch then
		self:_applySpawnProtection(player, character)
		Net.FireAll("Effect", "Spawn", { Position = root.Position })
	end

	self.CharacterSpawned:Fire(player, character, inMatch)
end

-- Death / respawn ------------------------------------------------------------------
-- Called by CombatService when it kills a player (before Humanoid.Died fires).
function PlayerService:MarkDead(player)
	local state = states[player]
	if not state or state.LifeState == LifeState.Dead then
		return
	end
	self:_setLifeState(player, LifeState.Dead)
	self.CharacterDied:Fire(player, player.Character)
end

-- Deaths not caused by CombatService (void, reset, physics) are routed back through it
-- so they are still credited and counted.
function PlayerService:_onHumanoidDied(player, character)
	local state = states[player]
	if not state or player.Character ~= character then
		return
	end
	if state.LifeState ~= LifeState.Dead then
		self.Services.CombatService:HandleUnexpectedDeath(player)
	end
end

function PlayerService:ScheduleRespawn(player, delaySeconds)
	local state = states[player]
	if not state then
		return
	end
	state.RespawnToken += 1
	local token = state.RespawnToken
	player:SetAttribute("RespawnAt", workspace:GetServerTimeNow() + delaySeconds)
	task.delay(delaySeconds, function()
		if states[player] ~= state or state.RespawnToken ~= token then
			return
		end
		if state.InMatch then
			self:SpawnInMatch(player)
		else
			self:SpawnInLobby(player)
		end
	end)
end

function PlayerService:CancelRespawn(player)
	local state = states[player]
	if state then
		state.RespawnToken += 1
		player:SetAttribute("RespawnAt", 0)
	end
end

-- Spawn protection -----------------------------------------------------------------
function PlayerService:_applySpawnProtection(player, character)
	local duration = GameConfig.Respawn.ProtectionTime
	character:SetAttribute("SpawnProtected", true)
	local forceField = Instance.new("ForceField")
	forceField.Name = "SpawnProtection"
	forceField.Visible = true
	forceField.Parent = character
	task.delay(duration, function()
		if player.Character == character then
			self:ClearSpawnProtection(player)
		end
	end)
end

function PlayerService:IsSpawnProtected(player)
	local character = player.Character
	return character ~= nil and character:GetAttribute("SpawnProtected") == true
end

-- Called by weapon handlers with fromAttack = true, and by the protection timer.
function PlayerService:ClearSpawnProtection(player, fromAttack)
	local character = player.Character
	if not character or character:GetAttribute("SpawnProtected") ~= true then
		return
	end
	if fromAttack and not GameConfig.Respawn.ProtectionBreaksOnAttack then
		return
	end
	character:SetAttribute("SpawnProtected", false)
	local forceField = character:FindFirstChild("SpawnProtection")
	if forceField then
		forceField:Destroy()
	end
end

-- Out of bounds --------------------------------------------------------------------
function PlayerService:_checkOutOfBounds()
	local killY = self.Services.MapService:GetKillY()
	if not killY then
		return
	end
	for player, state in states do
		if state.InMatch and state.LifeState == LifeState.Alive then
			local root = self:GetRoot(player)
			if root and root.Position.Y < killY then
				self.Services.CombatService:KillEnvironment(player)
			end
		end
	end
end

return PlayerService
