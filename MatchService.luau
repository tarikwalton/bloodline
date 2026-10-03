-- MatchService (Server)
-- Match state machine: Waiting -> Intermission -> Loading -> InProgress -> Ended -> (Intermission)
-- Hosts the active mode (Server/Modes), owns the mode-agnostic scoreboard and leaderstats,
-- and replicates state through attributes on ReplicatedStorage.MatchState (no remote spam;
-- clients count down locally from StateEndsAt using workspace:GetServerTimeNow()).
-- Every timer is a task.delay guarded by a state token - no polling loops.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Constants.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ModeConfig = require(ReplicatedStorage.Shared.Config.ModeConfig)
local Signal = require(ReplicatedStorage.Shared.Utilities.Signal)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local Combatants = require(script.Parent.Parent.Core.Combatants)

local State = Enums.MatchState
local KillFlag = Enums.KillFlag
local modesFolder = script.Parent.Parent.Modes

local MatchService = {}
MatchService.StateChanged = Signal.new() -- (state)
MatchService.MatchStarted = Signal.new() -- (modeId, mapId)
MatchService.MatchEnded = Signal.new() -- (results) -> RewardService / DataService in Phase 2

local matchState -- ReplicatedStorage.MatchState (Configuration)

function MatchService:Init(services)
	self.Services = services
	self.State = nil
	self.StateToken = 0
	self.Mode = nil
	self.ModeId = nil
	self.MapId = nil
	self.LastMapId = nil
	self.Scoreboard = {} -- [Player] = { Kills, Deaths, Score, Streak, BestStreak, Headshots, KnifeKills }

	matchState = ReplicatedStorage:FindFirstChild("MatchState")
	if not matchState then
		matchState = Instance.new("Configuration")
		matchState.Name = "MatchState"
		matchState.Parent = ReplicatedStorage
	end
	self:_clearMatchAttributes()
end

function MatchService:Start()
	local PlayerService = self.Services.PlayerService
	PlayerService.PlayerJoined:Connect(function(player)
		self:_onPlayerJoined(player)
	end)
	PlayerService.PlayerLeaving:Connect(function(player)
		self:_onPlayerLeaving(player)
	end)
	self:_setState(State.Waiting)
end

-- Replicated attributes ------------------------------------------------------------
function MatchService:SetMatchAttribute(name, value)
	matchState:SetAttribute(name, value)
end

function MatchService:_clearMatchAttributes()
	for _, name in { "ModeId", "ModeName", "MapId", "MapName", "Winner" } do
		matchState:SetAttribute(name, "")
	end
	matchState:SetAttribute("KillTarget", 0)
end

-- State machine ----------------------------------------------------------------------
function MatchService:_setState(state, duration)
	self.StateToken += 1
	local token = self.StateToken
	self.State = state
	matchState:SetAttribute("State", state)
	matchState:SetAttribute("StateEndsAt", if duration then workspace:GetServerTimeNow() + duration else 0)
	self.StateChanged:Fire(state)

	if duration then
		task.delay(duration, function()
			if self.StateToken == token then
				self:_onStateTimeout(state)
			end
		end)
	end

	if state == State.Waiting then
		self:_checkStart()
	end
end

function MatchService:_onStateTimeout(state)
	if state == State.Intermission then
		if #Players:GetPlayers() < GameConfig.MinPlayers then
			self:_setState(State.Waiting)
		else
			self:_beginLoading()
		end
	elseif state == State.Loading then
		self:_startMatch()
	elseif state == State.InProgress then
		if self.Mode then
			self:EndMatch(self.Mode:OnTimeExpired())
		end
	elseif state == State.Ended then
		self:_returnToLobby()
	end
end

function MatchService:_checkStart()
	if self.State == State.Waiting and #Players:GetPlayers() >= GameConfig.MinPlayers then
		self:_setState(State.Intermission, GameConfig.IntermissionTime)
	end
end

function MatchService:_beginLoading()
	-- Phase 4: VoteService supplies the voted map (and mode) here.
	local modeId = GameConfig.DefaultModeId
	local modeConfig = ModeConfig.Modes[modeId]
	if not modeConfig or not modeConfig.Enabled or not modesFolder:FindFirstChild(modeConfig.Module) then
		warn("[MatchService] Mode unavailable:", modeId)
		self:_setState(State.Waiting)
		return
	end
	local MapService = self.Services.MapService
	local mapId = MapService:PickRandomMap(modeId, self.LastMapId)
	if not mapId or not MapService:LoadMap(mapId) then
		warn("[MatchService] No map available for mode", modeId)
		self:_setState(State.Waiting)
		return
	end

	self.ModeId = modeId
	self.MapId = mapId
	matchState:SetAttribute("ModeId", modeId)
	matchState:SetAttribute("ModeName", modeConfig.DisplayName)
	matchState:SetAttribute("MapId", mapId)
	matchState:SetAttribute("MapName", MapService:GetDisplayName(mapId))
	matchState:SetAttribute("Winner", "")
	self:_setState(State.Loading, GameConfig.LoadingTime)
end

function MatchService:_startMatch()
	local modeConfig = ModeConfig.Modes[self.ModeId]
	local ModeClass = require(modesFolder[modeConfig.Module])
	self.Mode = ModeClass.new(self, modeConfig)

	table.clear(self.Scoreboard)
	self.Services.KillService:Reset()
	for _, player in Combatants.GetAll() do
		self:_updateLeaderstats(player)
	end

	self:_setState(State.InProgress, modeConfig.Duration)
	self.Mode:Start()
	for _, combatant in Combatants.GetAll() do
		self:_addToMatch(combatant)
	end

	Net.FireAll("Notify", {
		Text = string.upper(modeConfig.DisplayName),
		Subtext = matchState:GetAttribute("MapName"),
		Style = "MatchStart",
	})
	self.MatchStarted:Fire(self.ModeId, self.MapId)
end

function MatchService:EndMatch(results)
	if self.State ~= State.InProgress or not results then
		return
	end
	self:_setState(State.Ended, GameConfig.EndedTime)
	self.Services.ProjectileService:ClearAll()
	for player in self.Scoreboard do
		self.Services.PlayerService:CancelRespawn(player)
	end

	local winnerNames = {}
	for _, winner in results.Winners do
		table.insert(winnerNames, winner.DisplayName)
	end
	matchState:SetAttribute("Winner", table.concat(winnerNames, ", "))

	-- Plain copy for clients (no Player instances needed on the wire).
	local standings = {}
	for index, row in results.Standings do
		standings[index] = {
			Name = row.Name,
			UserId = row.UserId,
			Kills = row.Kills,
			Deaths = row.Deaths,
			Score = row.Score,
		}
	end
	Net.FireAll("MatchResults", {
		Reason = results.Reason,
		Winners = winnerNames,
		Standings = standings,
		ModeName = matchState:GetAttribute("ModeName"),
		MapName = matchState:GetAttribute("MapName"),
	})
	self.MatchEnded:Fire(results)
	self.LastMapId = self.MapId
end

function MatchService:_returnToLobby()
	local PlayerService = self.Services.PlayerService
	if self.Mode then
		self.Mode:Cleanup()
		self.Mode = nil
	end
	for _, combatant in Combatants.GetAll() do
		PlayerService:SetInMatch(combatant, false)
		task.spawn(PlayerService.SpawnInLobby, PlayerService, combatant)
	end
	table.clear(self.Scoreboard)

	-- Unload shortly after, once everyone has been moved off the map.
	local mapId = self.MapId
	task.delay(1, function()
		self.Services.MapService:UnloadMap(mapId)
	end)
	self.ModeId = nil
	self.MapId = nil
	self:_clearMatchAttributes()
	self:_setState(State.Waiting)
end

-- Players ----------------------------------------------------------------------------
function MatchService:_ensureLeaderstats(player)
	if typeof(player) ~= "Instance" then
		return nil -- bots don't appear in the Roblox player list
	end
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		for _, statName in { "Kills", "Deaths" } do
			local value = Instance.new("IntValue")
			value.Name = statName
			value.Parent = folder
		end
		folder.Parent = player
	end
	return folder
end

function MatchService:_updateLeaderstats(player)
	local folder = self:_ensureLeaderstats(player)
	local entry = self.Scoreboard[player]
	if folder then
		folder.Kills.Value = entry and entry.Kills or 0
		folder.Deaths.Value = entry and entry.Deaths or 0
	end
	player:SetAttribute("MatchScore", entry and entry.Score or 0)
end

function MatchService:_addToMatch(player)
	if self.Scoreboard[player] or not self.Mode then
		return
	end
	self.Scoreboard[player] = {
		Kills = 0,
		Deaths = 0,
		Score = 0,
		Streak = 0,
		BestStreak = 0,
		Headshots = 0,
		KnifeKills = 0,
	}
	self:_updateLeaderstats(player)
	local PlayerService = self.Services.PlayerService
	PlayerService:SetInMatch(player, true)
	self.Mode:OnPlayerAdded(player)
	task.spawn(PlayerService.SpawnInMatch, PlayerService, player)
end

function MatchService:_onPlayerJoined(player)
	self:_ensureLeaderstats(player)
	if self.State == State.InProgress and self.Mode and self.Mode.Config.AllowJoinInProgress then
		self:_addToMatch(player)
	else
		task.spawn(self.Services.PlayerService.SpawnInLobby, self.Services.PlayerService, player)
	end
	if self.State == State.Waiting then
		self:_checkStart()
	end
end

function MatchService:_onPlayerLeaving(player)
	if self.Mode then
		self.Mode:OnPlayerRemoving(player)
	end
	self.Scoreboard[player] = nil
end

-- Combat hooks ------------------------------------------------------------------------
function MatchService:IsCombatEnabled()
	return self.State == State.InProgress
end

function MatchService:CanDamage(attacker, victim)
	return self.Mode ~= nil and self.Mode:CanDamage(attacker, victim)
end

function MatchService:IsEnemy(a, b)
	return a ~= b and (self.Mode == nil or self.Mode:IsEnemy(a, b))
end

-- Positions of living enemies, for safe spawn selection.
function MatchService:GetEnemyPositions(player)
	local positions = {}
	local PlayerService = self.Services.PlayerService
	for other in self.Scoreboard do
		if other ~= player and PlayerService:IsAlive(other) and (not self.Mode or self.Mode:IsEnemy(player, other)) then
			local root = PlayerService:GetRoot(other)
			if root then
				table.insert(positions, root.Position)
			end
		end
	end
	return positions
end

function MatchService:GetStreak(player)
	local entry = self.Scoreboard[player]
	return entry and entry.Streak or 0
end

-- Called by KillService for every death.
function MatchService:HandleKill(killInfo)
	local victim, killer = killInfo.Victim, killInfo.Killer
	local PlayerService = self.Services.PlayerService
	local victimEntry = self.Scoreboard[victim]

	if self.State ~= State.InProgress or not victimEntry then
		-- Lobby / post-match death: just respawn.
		PlayerService:ScheduleRespawn(victim, GameConfig.Respawn.DefaultDelay)
		return
	end

	victimEntry.Deaths += 1
	victimEntry.Streak = 0
	self:_updateLeaderstats(victim)

	local killerEntry = killer and self.Scoreboard[killer]
	if killerEntry then
		killerEntry.Kills += 1
		killerEntry.Streak += 1
		killerEntry.BestStreak = math.max(killerEntry.BestStreak, killerEntry.Streak)
		if table.find(killInfo.Flags, KillFlag.Headshot) then
			killerEntry.Headshots += 1
		end
		if table.find(killInfo.Flags, KillFlag.KnifeKill) then
			killerEntry.KnifeKills += 1
		end
		killerEntry.Score += self.Mode:GetKillScore(killInfo)
		killInfo.Streak = killerEntry.Streak
		self:_updateLeaderstats(killer)
	end

	PlayerService:ScheduleRespawn(victim, self.Mode:GetRespawnDelay(victim))

	local results = self.Mode:OnKill(killInfo)
	if results then
		-- Deferred so the kill feed / confirm for the winning kill goes out first.
		task.defer(function()
			self:EndMatch(results)
		end)
	end
end

return MatchService
