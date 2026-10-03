-- KillService (Server)
-- The single place kill logic lives. Weapons never award kills themselves - CombatService
-- calls RegisterKill, which computes bonuses (headshot, backstab, longshot, revenge, knife,
-- throw, first blood), multi-kills and streaks, updates the match, and broadcasts feedback.
-- RewardService / ChallengeService (Phase 2+) subscribe to KillService.Killed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Constants.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Utilities.Signal)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local WeaponRegistry = require(ReplicatedStorage.Shared.Registry.WeaponRegistry)
local Combatants = require(script.Parent.Parent.Core.Combatants)

local KillFlag = Enums.KillFlag
local Source = Enums.DamageSource
local KILL = GameConfig.Kill

local KillService = {}
KillService.Killed = Signal.new() -- (killInfo)

local multiKills = {} -- [Player] = { Count, Last }
local lastKillerOf = {} -- [Player victim] = { Killer, Time }
local firstBloodTaken = false

function KillService:Init(services)
	self.Services = services
end

function KillService:Start()
	Combatants.Removing:Connect(function(player)
		multiKills[player] = nil
		lastKillerOf[player] = nil
	end)
end

-- Called by MatchService when a new match starts.
function KillService:Reset()
	table.clear(multiKills)
	table.clear(lastKillerOf)
	firstBloodTaken = false
end

function KillService:GetMultiKillName(count)
	if count < 2 then
		return nil
	end
	return KILL.MultiKillNames[math.min(count, 5)]
end

-- Phase 3: InventoryService provides the equipped kill effect cosmetic.
function KillService:GetKillEffect(_player)
	return KILL.DefaultKillEffect
end

-- info comes from CombatService: { Attacker, Victim, WeaponId, Source, IsHeadshot, IsBackstab, Distance, Position }
function KillService:RegisterKill(info)
	local victim = info.Victim
	local killer = info.Attacker
	if killer == victim or (killer and killer.Parent == nil) then
		killer = nil
	end

	local now = os.clock()
	local flags = {}
	local multiKill = 0

	if killer then
		local weapon = WeaponRegistry.Get(info.WeaponId)
		if info.IsHeadshot then
			table.insert(flags, KillFlag.Headshot)
		end
		if info.IsBackstab then
			table.insert(flags, KillFlag.Backstab)
		end
		if info.Source == Source.Melee or info.Source == Source.Throw then
			if weapon and weapon.Category == "Knife" then
				table.insert(flags, KillFlag.KnifeKill)
			end
		end
		if info.Source == Source.Throw then
			table.insert(flags, KillFlag.ThrowKill)
		end
		if info.Source == Source.Ability then
			table.insert(flags, KillFlag.AbilityKill)
		end
		if info.Source == Source.Gun and (info.Distance or 0) >= KILL.LongshotDistance then
			table.insert(flags, KillFlag.Longshot)
		end
		if info.Source == Source.Environment then
			table.insert(flags, KillFlag.Environment)
		end

		local previous = lastKillerOf[killer]
		if previous and previous.Killer == victim and now - previous.Time <= KILL.RevengeWindow then
			table.insert(flags, KillFlag.Revenge)
			lastKillerOf[killer] = nil
		end

		if not firstBloodTaken and self.Services.MatchService:IsCombatEnabled() then
			firstBloodTaken = true
			table.insert(flags, KillFlag.FirstBlood)
		end

		local chain = multiKills[killer]
		if chain and now - chain.Last <= KILL.MultiKillWindow then
			chain.Count += 1
		else
			chain = { Count = 1, Last = now }
			multiKills[killer] = chain
		end
		chain.Last = now
		multiKill = chain.Count

		lastKillerOf[victim] = { Killer = killer, Time = now }
	else
		table.insert(flags, KillFlag.Environment)
	end
	multiKills[victim] = nil

	local killInfo = {
		Killer = killer,
		Victim = victim,
		WeaponId = info.WeaponId,
		Source = info.Source,
		Flags = flags,
		MultiKill = multiKill,
		Distance = info.Distance,
		Position = info.Position,
		Time = now,
		Streak = 0,
	}

	-- Match bookkeeping first (scores, respawn, win check). Sets killInfo.Streak.
	self.Services.MatchService:HandleKill(killInfo)

	-- Presentation --------------------------------------------------------------
	Net.FireAll("KillFeed", {
		Killer = killer and killer.DisplayName or nil,
		KillerId = killer and killer.UserId or 0,
		Victim = victim.DisplayName,
		VictimId = victim.UserId,
		WeaponId = info.WeaponId,
		Flags = flags,
	})
	if killer then
		Net.Fire("KillConfirm", killer, {
			Victim = victim.DisplayName,
			Flags = flags,
			MultiKill = multiKill,
			MultiKillName = self:GetMultiKillName(multiKill),
			Streak = killInfo.Streak,
		})
	end
	if info.Position then
		Net.FireAll("Effect", "KillEffect", {
			Position = info.Position,
			EffectId = killer and self:GetKillEffect(killer) or KILL.DefaultKillEffect,
		})
	end

	self.Killed:Fire(killInfo)
	return killInfo
end

return KillService
