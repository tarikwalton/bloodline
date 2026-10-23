-- Bot (Server)
-- A bot combatant. Mirrors the subset of the Player API the services use, so PlayerService,
-- CombatService, WeaponService, KillService and MatchService treat it like a player.
-- The character is an R15 rig built from a HumanoidDescription, owned by the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BotConfig = require(ReplicatedStorage.Shared.Config.BotConfig)

local Bot = {}
Bot.__index = Bot

local function getBotsFolder()
	local folder = workspace:FindFirstChild("Bots")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Bots"
		folder.Parent = workspace
	end
	return folder
end
Bot.GetBotsFolder = getBotsFolder

function Bot.new(id, callsign, palette)
	local self = setmetatable({}, Bot)
	self.IsBot = true
	self.UserId = -id -- negative ids never collide with real users
	self.Name = "Bot_" .. callsign
	self.DisplayName = callsign
	self.Parent = workspace -- like Player.Parent: non-nil while the bot is in the game
	self.Character = nil
	self._attributes = {}
	self._palette = palette
	self._template = nil
	return self
end

function Bot:GetAttribute(name)
	return self._attributes[name]
end

function Bot:SetAttribute(name, value)
	self._attributes[name] = value
end

function Bot:GetNetworkPing()
	return 0
end

function Bot:_buildTemplate()
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = BotConfig.SkinColor
	description.TorsoColor = self._palette.Torso
	description.LeftArmColor = self._palette.Limbs
	description.RightArmColor = self._palette.Limbs
	description.LeftLegColor = self._palette.Limbs
	description.RightLegColor = self._palette.Limbs
	local ok, model = pcall(Players.CreateHumanoidModelFromDescription, Players, description, Enum.HumanoidRigType.R15)
	if not ok then
		warn("[Bot] Could not build rig:", model)
		return nil
	end
	return model
end

-- Called by PlayerService:Spawn exactly like Player:LoadCharacter(). Yields on first call.
function Bot:LoadCharacter()
	if self.Character then
		self.Character:Destroy()
		self.Character = nil
	end
	if not self._template then
		self._template = self:_buildTemplate()
	end
	if not self._template or self.Parent == nil then
		error("bot rig unavailable")
	end

	local model = self._template:Clone()
	model.Name = self.Name
	model:SetAttribute("IsBot", true)
	model:SetAttribute("UserId", self.UserId)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	humanoid.DisplayName = "[BOT] " .. self.DisplayName
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	model.PrimaryPart = root
	model.Parent = getBotsFolder()
	pcall(root.SetNetworkOwner, root, nil) -- server simulates bot physics
	self.Character = model
end

function Bot:Destroy()
	self.Parent = nil
	if self.Character then
		self.Character:Destroy()
		self.Character = nil
	end
	if self._template then
		self._template:Destroy()
		self._template = nil
	end
end

return Bot
