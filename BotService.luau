-- BotService (Server)
-- Spawns and runs AI bots. Bots register with Combatants and join through PlayerService, so
-- the match, spawning, damage, kills, scoring and results treat them like real players.
--
-- Fill rule: each match is topped up to BotConfig.FillTo combatants (players + bots) while at
-- least one real player is present. Studio / place-owner chat commands:
--   /bots <n>        force exactly n bots        /bots auto   back to the fill rule
--   /botdiff easy|normal|hard

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local BotConfig = require(ReplicatedStorage.Shared.Config.BotConfig)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local Combatants = require(script.Parent.Parent.Core.Combatants)
local Bot = require(script.Parent.Parent.Bots.Bot)
local BotBrain = require(script.Parent.Parent.Bots.BotBrain)

local BotService = {}

function BotService:Init(services)
	self.Services = services
	self.Bots = {}
	self.Brains = {}
	self.Difficulty = BotConfig.Difficulty
	self.ForcedCount = nil
	self._nextId = 0
	self._warned = {}
end

function BotService:Start()
	if not BotConfig.Enabled then
		return
	end
	Bot.GetBotsFolder()

	self.Services.PlayerService.CharacterSpawned:Connect(function(combatant, character)
		local brain = self.Brains[combatant]
		if brain then
			brain:OnCharacter(character)
		end
	end)
	self.Services.MatchService.MatchStarted:Connect(function()
		self:Rebalance()
	end)
	Players.PlayerAdded:Connect(function()
		task.defer(self.Rebalance, self)
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(self.Rebalance, self)
	end)

	-- One shared think loop for every bot, throttled to ThinkRate.
	local interval = 1 / BotConfig.ThinkRate
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		local now = os.clock()
		for _, bot in self.Bots do
			local brain = self.Brains[bot]
			if brain then
				local ok, err = pcall(brain.Think, brain, step, now)
				if not ok and not self._warned[bot] then
					self._warned[bot] = true
					warn("[BotService] " .. bot.Name .. " think error: " .. tostring(err))
				end
			end
		end
	end)

	self:_setupCommands()
	task.defer(self.Rebalance, self)
end

function BotService:GetDesiredCount()
	if self.ForcedCount then
		return math.clamp(self.ForcedCount, 0, BotConfig.MaxBots)
	end
	local realPlayers = #Players:GetPlayers()
	if realPlayers == 0 then
		return 0
	end
	return math.clamp(BotConfig.FillTo - realPlayers, 0, BotConfig.MaxBots)
end

function BotService:Rebalance()
	if not BotConfig.Enabled then
		return
	end
	local desired = self:GetDesiredCount()
	while #self.Bots < desired do
		self:AddBot()
	end
	while #self.Bots > desired do
		self:RemoveBot(self.Bots[#self.Bots])
	end
end

function BotService:AddBot()
	self._nextId += 1
	local names = BotConfig.Names
	local nameIndex = (self._nextId - 1) % #names + 1
	local callsign = names[nameIndex]
	if self._nextId > #names then
		callsign ..= "_" .. math.ceil(self._nextId / #names)
	end
	local palette = BotConfig.Colors[(self._nextId - 1) % #BotConfig.Colors + 1]

	local bot = Bot.new(self._nextId, callsign, palette)
	table.insert(self.Bots, bot)
	self.Brains[bot] = BotBrain.new(bot, self.Services, self)
	Combatants.RegisterBot(bot)
	self.Services.PlayerService:AddCombatant(bot) -- joins lobby or the running match
	return bot
end

function BotService:RemoveBot(bot)
	local index = table.find(self.Bots, bot)
	if index then
		table.remove(self.Bots, index)
	end
	local brain = self.Brains[bot]
	if brain then
		brain:Destroy()
		self.Brains[bot] = nil
	end
	self.Services.PlayerService:RemoveCombatant(bot)
	Combatants.UnregisterBot(bot)
	bot:Destroy()
end

function BotService:SetDifficulty(name)
	if BotConfig.Difficulties[name] then
		self.Difficulty = name
	end
end

-- Chat commands (Studio, or the place owner in a live server) ----------------------------
function BotService:_setupCommands()
	local function canControl(player)
		return player ~= nil and (RunService:IsStudio() or player.UserId == game.CreatorId)
	end
	local function notify(player)
		Net.Fire("Notify", player, {
			Text = string.format("BOTS: %d", #self.Bots),
			Subtext = "Difficulty: " .. string.upper(self.Difficulty)
				.. (if self.ForcedCount then "" else "  ·  auto-fill to " .. BotConfig.FillTo),
		})
	end
	local function command(name, alias, handler)
		local textCommand = Instance.new("TextChatCommand")
		textCommand.Name = name
		textCommand.PrimaryAlias = alias
		textCommand.Parent = TextChatService
		textCommand.Triggered:Connect(function(textSource, message)
			local player = Players:GetPlayerByUserId(textSource.UserId)
			if not canControl(player) then
				return
			end
			handler(player, string.match(message, "^%S+%s+(%S+)"))
			notify(player)
		end)
	end

	command("BloodlineBots", "/bots", function(_, argument)
		if argument == "auto" then
			self.ForcedCount = nil
		elseif tonumber(argument) then
			self.ForcedCount = math.floor(tonumber(argument))
		end
		self:Rebalance()
	end)
	command("BloodlineBotDifficulty", "/botdiff", function(_, argument)
		if argument then
			self:SetDifficulty(string.upper(string.sub(argument, 1, 1)) .. string.lower(string.sub(argument, 2)))
		end
	end)
end

return BotService
