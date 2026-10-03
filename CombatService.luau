-- CombatService (Server)
-- Custom health/armor and the ONE damage pipeline. Every source of damage (guns, knives,
-- projectiles, abilities, environment) goes through ApplyDamage / KillEnvironment.
--
-- Health lives here (server memory) and is mirrored to character attributes
-- (Health, MaxHealth, Armor) for the HUD. Humanoid.Health is only a mirror used to
-- trigger Roblox's death/ragdoll; default regeneration is disabled by the empty
-- StarterCharacterScripts.Health script.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Constants.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Utilities.Signal)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local Combatants = require(script.Parent.Parent.Core.Combatants)

local HEALTH = GameConfig.Health

local CombatService = {}
CombatService.Damaged = Signal.new() -- (damageInfo) after damage is applied

-- [Player] = { Health, MaxHealth, Armor, Alive, Character, Humanoid, LastAttacker, LastAttackerTime, LastWeaponId }
local states = {}

function CombatService:Init(services)
	self.Services = services
end

function CombatService:Start()
	Combatants.Removing:Connect(function(player)
		states[player] = nil
	end)
end

local function publish(state)
	local character = state.Character
	if character and character.Parent then
		character:SetAttribute("Health", state.Health)
		character:SetAttribute("MaxHealth", state.MaxHealth)
		character:SetAttribute("Armor", state.Armor)
	end
end

function CombatService:InitCharacter(player, character, humanoid)
	local state = {
		Health = HEALTH.Max,
		MaxHealth = HEALTH.Max,
		Armor = HEALTH.DefaultArmor,
		Alive = true,
		Character = character,
		Humanoid = humanoid,
		LastAttacker = nil,
		LastAttackerTime = 0,
		LastWeaponId = nil,
	}
	states[player] = state
	humanoid.MaxHealth = HEALTH.Max
	humanoid.Health = HEALTH.Max
	publish(state)
end

function CombatService:IsAlive(player)
	local state = states[player]
	return state ~= nil and state.Alive and state.Character == player.Character
end

function CombatService:GetHealth(player)
	local state = states[player]
	return state and state.Health or 0, state and state.MaxHealth or 0
end

-- Central permission check used by every damage source.
function CombatService:CanDamage(attacker, victim)
	if not self:IsAlive(victim) then
		return false
	end
	local PlayerService = self.Services.PlayerService
	if PlayerService:IsSpawnProtected(victim) then
		return false
	end
	if attacker then
		if attacker == victim or not self:IsAlive(attacker) then
			return false
		end
		local MatchService = self.Services.MatchService
		if not MatchService:IsCombatEnabled() then
			return false
		end
		if not PlayerService:IsInMatch(attacker) or not PlayerService:IsInMatch(victim) then
			return false
		end
		if not MatchService:CanDamage(attacker, victim) then
			return false
		end
	end
	return true
end

-- info = { Attacker: Player?, Victim: Player, Amount: number, WeaponId: string, Source: string,
--          IsHeadshot: boolean?, IsBackstab: boolean?, IsCritical: boolean?, Position: Vector3?, Distance: number? }
-- Returns the info table (with final Amount and Killed) or nil if the damage was rejected.
function CombatService:ApplyDamage(info)
	local victim = info.Victim
	if not self:CanDamage(info.Attacker, victim) then
		return nil
	end
	local state = states[victim]
	local amount = math.max(0, info.Amount or 0)
	if amount <= 0 then
		return nil
	end

	if state.Armor > 0 then
		local absorbed = math.min(state.Armor, amount * HEALTH.ArmorAbsorb)
		state.Armor -= absorbed
		amount -= absorbed
	end
	amount = math.max(1, math.floor(amount + 0.5)) -- whole numbers keep the UI clean

	state.Health = math.max(0, state.Health - amount)
	if info.Attacker then
		state.LastAttacker = info.Attacker
		state.LastAttackerTime = os.clock()
		state.LastWeaponId = info.WeaponId
	end

	local killed = state.Health <= 0
	info.Amount = amount
	info.Killed = killed
	publish(state)

	local victimRoot = state.Character:FindFirstChild("HumanoidRootPart")
	if info.Attacker then
		Net.Fire("HitConfirm", info.Attacker, {
			Damage = amount,
			Headshot = info.IsHeadshot == true,
			Critical = info.IsCritical == true,
			Backstab = info.IsBackstab == true,
			Kill = killed,
			Position = info.Position or (victimRoot and victimRoot.Position),
		})
	end
	local attackerRoot = info.Attacker and self.Services.PlayerService:GetRoot(info.Attacker)
	Net.Fire("DamageTaken", victim, {
		Amount = amount,
		From = attackerRoot and attackerRoot.Position or info.Position,
		Source = info.Source,
	})

	self.Damaged:Fire(info)

	if killed then
		self:_kill(victim, info)
	else
		state.Humanoid.Health = state.Health
	end
	return info
end

function CombatService:_kill(victim, info)
	local state = states[victim]
	if not state or not state.Alive then
		return
	end
	state.Alive = false
	state.Health = 0
	publish(state)

	local root = state.Character and state.Character:FindFirstChild("HumanoidRootPart")
	info.Position = info.Position or (root and root.Position)

	self.Services.PlayerService:MarkDead(victim)
	self.Services.KillService:RegisterKill(info)

	if state.Humanoid and state.Humanoid.Parent then
		state.Humanoid.Health = 0
	end
end

-- Environment death (void, kill plane, reset). Credits the last attacker if recent
-- ("knocked off the roof" still counts as their kill).
function CombatService:KillEnvironment(victim)
	local state = states[victim]
	if not state or not state.Alive then
		return
	end
	local credited = nil
	if state.LastAttacker
		and state.LastAttacker ~= victim
		and state.LastAttacker.Parent ~= nil
		and os.clock() - state.LastAttackerTime <= HEALTH.LastHitCreditWindow
	then
		credited = state.LastAttacker
	end
	self:_kill(victim, {
		Attacker = credited,
		Victim = victim,
		Amount = state.Health,
		WeaponId = credited and state.LastWeaponId or "Environment",
		Source = Enums.DamageSource.Environment,
	})
end

function CombatService:HandleUnexpectedDeath(player)
	local state = states[player]
	if state and state.Alive then
		self:KillEnvironment(player)
	end
end

-- Used by abilities / pickups in later phases.
function CombatService:Heal(player, amount)
	local state = states[player]
	if not state or not state.Alive or amount <= 0 then
		return
	end
	state.Health = math.min(state.MaxHealth, state.Health + amount)
	state.Humanoid.Health = state.Health
	publish(state)
end

function CombatService:AddArmor(player, amount)
	local state = states[player]
	if not state or not state.Alive then
		return
	end
	state.Armor = math.max(0, state.Armor + amount)
	publish(state)
end

return CombatService
