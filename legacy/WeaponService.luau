-- WeaponService (Server)
-- Owns every player's weapon runtime state (loadout, equipped slot, ammo, reloads, cooldowns,
-- throw charges), applies the checks shared by all weapons, then dispatches to class handlers
-- (Server/Weapons/GunHandler, MeleeHandler). New weapon classes = new handler, not new remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Constants.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local WeaponRegistry = require(ReplicatedStorage.Shared.Registry.WeaponRegistry)
local Net = require(ReplicatedStorage.Shared.Net.Net)

local WeaponsFolder = script.Parent.Parent.Weapons
local HitQuery = require(WeaponsFolder.HitQuery)
local GunHandler = require(WeaponsFolder.GunHandler)
local MeleeHandler = require(WeaponsFolder.MeleeHandler)
local Combatants = require(script.Parent.Parent.Core.Combatants)

local WeaponService = {}

-- [Player] = { Character, Loadout, Equipped, Tool, Ammo = {[id]=n}, NextFire = {[id]=t},
--              NextMelee, HeavyStartedAt, ThrowUses = {[id]={t...}}, ReloadToken, ReloadingUntil, ReloadingWeapon }
local states = {}

function WeaponService:Init(services)
	self.Services = services
	GunHandler.Init(self, services)
	MeleeHandler.Init(self, services)
end

function WeaponService:Start()
	local PlayerService = self.Services.PlayerService
	PlayerService.CharacterSpawned:Connect(function(player, character, inMatch)
		self:_onCharacterSpawned(player, character, inMatch)
	end)
	PlayerService.CharacterDied:Connect(function(player)
		local state = states[player]
		if state then
			self:_cancelReload(state)
			state.HeavyStartedAt = nil
		end
	end)
	Combatants.Removing:Connect(function(player)
		local state = states[player]
		if state then
			self:_cancelReload(state)
		end
		states[player] = nil
	end)

	-- Network intents: players reach the same Request* methods bots call directly,
	-- so both go through identical validation.
	Net.On("EquipSlot", function(player, slot)
		self:Equip(player, slot)
	end)
	Net.On("ReloadWeapon", function(player)
		self:Reload(player)
	end)
	Net.On("FireWeapon", function(player, origin, direction, hint)
		self:RequestFire(player, origin, direction, hint)
	end)
	Net.On("MeleeBeginHeavy", function(player)
		self:RequestBeginHeavy(player)
	end)
	Net.On("MeleeAttack", function(player, kind, lookDirection, hint)
		self:RequestMelee(player, kind, lookDirection, hint)
	end)
	Net.On("ThrowKnife", function(player, origin, direction, sequence)
		self:RequestThrow(player, origin, direction, sequence)
	end)
end

-- Intent API (players via Net, bots directly) -----------------------------------------
function WeaponService:RequestFire(combatant, origin, direction, hint)
	local state, config = self:_getActive(combatant, Enums.WeaponClass.Gun)
	if state then
		GunHandler.Fire(combatant, state, config, origin, direction, hint)
	end
end

function WeaponService:RequestBeginHeavy(combatant)
	local state, config = self:_getActive(combatant, Enums.WeaponClass.Melee)
	if state then
		MeleeHandler.BeginHeavy(combatant, state, config)
	end
end

function WeaponService:RequestMelee(combatant, kind, lookDirection, hint)
	local state, config = self:_getActive(combatant, Enums.WeaponClass.Melee)
	if state then
		MeleeHandler.Attack(combatant, state, config, kind, lookDirection, hint)
	end
end

function WeaponService:RequestThrow(combatant, origin, direction, sequence)
	local state, config = self:_getActive(combatant, Enums.WeaponClass.Melee)
	if state then
		MeleeHandler.Throw(combatant, state, config, origin, direction, sequence)
	end
end

-- Loadout -------------------------------------------------------------------------
-- Phase 3: read the player's saved, ownership-validated loadout from InventoryService.
function WeaponService:GetLoadout(_player)
	return table.clone(GameConfig.DefaultLoadout)
end

function WeaponService:GetState(player)
	return states[player]
end

function WeaponService:_onCharacterSpawned(player, character, inMatch)
	local previous = states[player]
	if previous then
		self:_cancelReload(previous)
	end
	if not inMatch then
		states[player] = nil
		self:SendState(player)
		return
	end

	local loadout = self:GetLoadout(player)
	local state = {
		Character = character,
		Loadout = loadout,
		Equipped = nil,
		Tool = nil,
		Ammo = {},
		NextFire = {},
		NextMelee = 0,
		HeavyStartedAt = nil,
		ThrowUses = {},
		ReloadToken = 0,
		ReloadingUntil = nil,
		ReloadingWeapon = nil,
	}
	for _, weaponId in loadout do
		local config = WeaponRegistry.Get(weaponId)
		if config and config.Class == Enums.WeaponClass.Gun then
			state.Ammo[weaponId] = config.MagazineSize
		end
	end
	states[player] = state
	self:Equip(player, GameConfig.SpawnSlot, true)
end

-- Shared validation: returns (state, config) when the player may use their equipped weapon
-- of the given class right now.
function WeaponService:_getActive(player, weaponClass)
	local state = states[player]
	if not state or not state.Equipped or state.Character ~= player.Character then
		return nil
	end
	if not self.Services.CombatService:IsAlive(player) then
		return nil
	end
	if not self.Services.MatchService:IsCombatEnabled() then
		return nil
	end
	local config = WeaponRegistry.Get(state.Loadout[state.Equipped])
	if not config or config.Class ~= weaponClass then
		return nil
	end
	return state, config
end

-- Equip -----------------------------------------------------------------------------
function WeaponService:Equip(player, slot, force)
	local state = states[player]
	if not state or not table.find(Enums.SlotOrder, slot) then
		return
	end
	if state.Equipped == slot and not force then
		return
	end
	local weaponId = state.Loadout[slot]
	local config = WeaponRegistry.Get(weaponId)
	local character = player.Character
	if not config or not character or character ~= state.Character then
		return
	end
	if not self.Services.CombatService:IsAlive(player) then
		return
	end

	self:_cancelReload(state)
	state.HeavyStartedAt = nil
	if state.Tool then
		state.Tool:Destroy()
		state.Tool = nil
	end

	-- The weapon model is a Tool: parenting it to the character makes Roblox weld it to the
	-- right hand and play the default arm-raise animation for every client.
	local template = WeaponRegistry.GetModelTemplate(weaponId)
	if template then
		local tool = template:Clone()
		tool.Parent = character
		state.Tool = tool
	else
		warn("[WeaponService] Missing weapon model:", config.Model)
	end

	state.Equipped = slot
	local now = os.clock()
	state.NextFire[weaponId] = math.max(state.NextFire[weaponId] or 0, now + config.EquipTime)
	if config.Class == Enums.WeaponClass.Melee then
		state.NextMelee = math.max(state.NextMelee, now + config.EquipTime)
	end
	character:SetAttribute("EquippedWeapon", weaponId)
	self:SendState(player)
end

-- Fire-rate token: tolerates small network jitter without allowing sustained over-rate fire.
function WeaponService:ConsumeFireToken(state, key, interval)
	local now = os.clock()
	local nextTime = state.NextFire[key] or 0
	if now < nextTime - GameConfig.FireTolerance then
		return false
	end
	state.NextFire[key] = math.max(nextTime, now) + interval
	return true
end

-- Reload ----------------------------------------------------------------------------
function WeaponService:Reload(player)
	local state, config = self:_getActive(player, Enums.WeaponClass.Gun)
	if not state or state.ReloadingUntil then
		return
	end
	if (state.Ammo[config.Id] or 0) >= config.MagazineSize then
		return
	end
	state.ReloadToken += 1
	local token = state.ReloadToken
	state.ReloadingUntil = os.clock() + config.ReloadTime
	state.ReloadingWeapon = config.Id
	self:SendState(player)

	task.delay(config.ReloadTime, function()
		if states[player] ~= state or state.ReloadToken ~= token then
			return
		end
		state.ReloadingUntil = nil
		state.ReloadingWeapon = nil
		state.Ammo[config.Id] = config.MagazineSize -- ReserveAmmo = nil means infinite reserve
		self:SendState(player)
	end)
end

function WeaponService:_cancelReload(state)
	state.ReloadToken += 1
	state.ReloadingUntil = nil
	state.ReloadingWeapon = nil
end

-- Throw charges ----------------------------------------------------------------------
-- Returns (availableCharges, usesTable). usesTable holds timestamps of charges still recharging.
function WeaponService:GetThrowCharges(state, config)
	local throw = config.Throw
	local now = os.clock()
	local uses = state.ThrowUses[config.Id]
	if not uses then
		uses = {}
		state.ThrowUses[config.Id] = uses
	end
	local index = 1
	while index <= #uses do
		if now - uses[index] >= throw.RechargeTime then
			table.remove(uses, index)
		else
			index += 1
		end
	end
	return throw.MaxCharges - #uses, uses
end

-- Helpers for handlers -------------------------------------------------------------
-- Accept the client's origin only if it is near the server head AND not through a wall.
function WeaponService:ResolveOrigin(player, clientOrigin)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return nil
	end
	local serverOrigin = head.Position
	if clientOrigin
		and (clientOrigin - serverOrigin).Magnitude <= GameConfig.LagComp.MaxOriginDrift
		and HitQuery.HasLineOfSight(serverOrigin, clientOrigin)
	then
		return clientOrigin
	end
	return serverOrigin
end

-- 0 when standing still, 1 at full sprint or airborne. Used for movement spread.
function WeaponService:GetMovementSpreadFactor(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return 0
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return 1
	end
	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return math.clamp(horizontal / MovementConfig.SprintSpeed, 0, 1)
end

-- Replication -------------------------------------------------------------------------
-- Authoritative weapon state for the owning client (HUD + prediction reconciliation).
function WeaponService:SendState(player)
	local state = states[player]
	if not state then
		Net.Fire("WeaponState", player, { Active = false })
		return
	end
	local serverNow = workspace:GetServerTimeNow()
	local clockNow = os.clock()
	local function toServerTime(clockTime)
		return serverNow + (clockTime - clockNow)
	end

	local throwInfo = nil
	local meleeConfig = WeaponRegistry.Get(state.Loadout.Melee)
	if meleeConfig and meleeConfig.Throw and meleeConfig.Throw.Enabled then
		local available, uses = self:GetThrowCharges(state, meleeConfig)
		throwInfo = {
			Available = available,
			Max = meleeConfig.Throw.MaxCharges,
			NextChargeAt = if uses[1] then toServerTime(uses[1] + meleeConfig.Throw.RechargeTime) else 0,
		}
	end

	Net.Fire("WeaponState", player, {
		Active = true,
		Loadout = state.Loadout,
		Equipped = state.Equipped,
		Ammo = state.Ammo,
		ReloadEndsAt = if state.ReloadingUntil then toServerTime(state.ReloadingUntil) else nil,
		ReloadWeapon = state.ReloadingWeapon,
		Throw = throwInfo,
	})
end

return WeaponService
