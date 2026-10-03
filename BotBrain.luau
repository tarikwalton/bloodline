-- BotBrain (Server)
-- Decision-making for one bot, run by BotService at BotConfig.ThinkRate.
--
--   1. Pick a target: nearest visible living enemy (sticky), within view distance.
--   2. Pick a weapon by distance: knife up close, shotgun mid, pistol far; sometimes
--      switch to the knife at mid range to throw it (with gravity + lead compensation).
--   3. Move: close to the weapon's preferred distance, strafe, try to get behind knife
--      targets, never walk off ledges; pathfind when the target is hidden or unreachable.
--   4. Attack through WeaponService's Request* API - the same validated path players use.
--
-- Difficulty (reaction time, aim error, headshot chance, pacing) comes from BotConfig.

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BotConfig = require(ReplicatedStorage.Shared.Config.BotConfig)
local CombatMath = require(ReplicatedStorage.Shared.Utilities.CombatMath)
local WeaponRegistry = require(ReplicatedStorage.Shared.Registry.WeaponRegistry)
local Combatants = require(script.Parent.Parent.Core.Combatants)
local HitQuery = require(script.Parent.Parent.Weapons.HitQuery)

-- Roblox's default R15 animations (the same ones the default Animate script uses).
local ANIMATIONS = {
	Idle = "rbxassetid://507766388",
	Walk = "rbxassetid://507777826",
	Run = "rbxassetid://507767714",
	Fall = "rbxassetid://507767968",
	Hold = "rbxassetid://507768375",
	Slash = "rbxassetid://522635514", -- R15 toolslash
	Lunge = "rbxassetid://522638767", -- R15 toollunge
}
local ONE_SHOT = { Slash = true, Lunge = true }

local BotBrain = {}
BotBrain.__index = BotBrain

function BotBrain.new(bot, services, botService)
	local self = setmetatable({}, BotBrain)
	self.Bot = bot
	self.Services = services
	self.BotService = botService
	self.Rng = Random.new()
	self.Tracks = nil
	self.CurrentMove = nil
	self:_resetCombatState()
	return self
end

function BotBrain:_resetCombatState()
	self.Target = nil
	self.AcquiredAt = 0
	self.NextShotAt = 0
	self.NextWeaponSwitch = 0
	self.StrafeDir = 1
	self.NextStrafeFlip = 0
	self.Waypoints = nil
	self.WaypointIndex = 0
	self.PathGoal = nil
	self.NextPathAt = 0
	self.Computing = false
	self.PendingThrow = false
	self.PendingThrowSince = 0
	self.HeavyBusy = false
	self.Align = nil
end

function BotBrain:GetDifficulty()
	return BotConfig.Difficulties[self.BotService.Difficulty] or BotConfig.Difficulties.Normal
end

-- Character setup ----------------------------------------------------------------------
function BotBrain:OnCharacter(character)
	self:_resetCombatState()
	self.Tracks = {}
	self.CurrentMove = nil
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for name, id in ANIMATIONS do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(animator.LoadAnimation, animator, animation)
		if ok then
			track.Looped = not ONE_SHOT[name]
			track.Priority = if name == "Hold" or ONE_SHOT[name] then Enum.AnimationPriority.Action
				elseif name == "Idle" then Enum.AnimationPriority.Core
				else Enum.AnimationPriority.Movement
			self.Tracks[name] = track
		end
	end
end

function BotBrain:_playOnce(name, speed)
	local track = self.Tracks and self.Tracks[name]
	if track then
		track:Play(0.05, 1, speed or 1)
	end
end

function BotBrain:_animate(character, humanoid, root)
	local tracks = self.Tracks
	if not tracks or not tracks.Idle then
		return
	end
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local state = humanoid:GetState()
	local move
	if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		move = "Fall"
	elseif speed > 20 then
		move = "Run"
	elseif speed > 1 then
		move = "Walk"
	else
		move = "Idle"
	end
	if move ~= self.CurrentMove and tracks[move] then
		if self.CurrentMove and tracks[self.CurrentMove] then
			tracks[self.CurrentMove]:Stop(0.15)
		end
		tracks[move]:Play(0.15)
		self.CurrentMove = move
	end
	if move == "Walk" and tracks.Walk then
		tracks.Walk:AdjustSpeed(math.clamp(speed / 16, 0.5, 1.6))
	end
	local hold = tracks.Hold
	if hold then
		local holding = character:FindFirstChildOfClass("Tool") ~= nil
		if holding and not hold.IsPlaying then
			hold:Play(0.1)
		elseif not holding and hold.IsPlaying then
			hold:Stop(0.1)
		end
	end
end

-- Facing: AlignOrientation turns the bot smoothly toward its target while it strafes.
function BotBrain:_setFacing(humanoid, root, flatDirection)
	if not self.Align or self.Align.Parent ~= root then
		local attachment = Instance.new("Attachment")
		attachment.Name = "BotAlign"
		attachment.Parent = root
		local align = Instance.new("AlignOrientation")
		align.Mode = Enum.OrientationAlignmentMode.OneAttachment
		align.Attachment0 = attachment
		align.Responsiveness = 35
		align.MaxTorque = 1e6
		align.Enabled = false
		align.Parent = root
		self.Align = align
	end
	if flatDirection and flatDirection.Magnitude > 0.1 then
		self.Align.CFrame = CFrame.lookAt(Vector3.zero, flatDirection.Unit)
		self.Align.Enabled = true
		humanoid.AutoRotate = false
	else
		self.Align.Enabled = false
		humanoid.AutoRotate = true
	end
end

-- Terrain safety -----------------------------------------------------------------------
local function hasFloor(position, killY)
	local result = workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -20, 0), HitQuery.WorldParams())
	return result ~= nil and (not killY or result.Position.Y > killY + 1)
end

function BotBrain:_isSafe(from, to)
	local delta = to - from
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 1 then
		return true
	end
	local killY = self.Services.MapService:GetKillY()
	for _, alpha in { 0.5, 1 } do
		if not hasFloor(from + flat * alpha, killY) then
			return false
		end
	end
	return true
end

-- Main loop ----------------------------------------------------------------------------
function BotBrain:Think(dt, now)
	local bot = self.Bot
	local services = self.Services
	local character = bot.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
	if not humanoid or not root or not head or not services.CombatService:IsAlive(bot) then
		self.Target = nil
		return
	end

	self:_animate(character, humanoid, root)

	if not services.MatchService:IsCombatEnabled() or not services.PlayerService:IsInMatch(bot) then
		self:_setFacing(humanoid, root, nil)
		humanoid:MoveTo(root.Position)
		return
	end

	local difficulty = self:GetDifficulty()
	local target, targetRoot, distance = self:_selectTarget(root, head, difficulty)
	if target then
		if target ~= self.Target then
			self.Target = target
			self.AcquiredAt = now
		end
		self:_combat(dt, now, difficulty, humanoid, root, head, target, targetRoot, distance)
	else
		self.Target = nil
		self.PendingThrow = false
		self:_setFacing(humanoid, root, nil)
		humanoid.WalkSpeed = difficulty.WalkSpeed
		self:_hunt(now, humanoid, root)
	end
end

function BotBrain:_selectTarget(root, head, difficulty)
	local services = self.Services
	local bot = self.Bot
	local best, bestRoot, bestScore = nil, nil, math.huge
	for _, other in Combatants.GetAll() do
		if other ~= bot
			and services.CombatService:IsAlive(other)
			and services.PlayerService:IsInMatch(other)
			and not services.PlayerService:IsSpawnProtected(other)
			and services.MatchService:IsEnemy(bot, other)
		then
			local otherCharacter = other.Character
			local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			local otherHead = otherCharacter and otherCharacter:FindFirstChild("Head")
			if otherRoot and otherHead then
				local distance = (otherRoot.Position - root.Position).Magnitude
				-- Prefer the current target so bots don't flicker between enemies.
				local score = if other == self.Target then distance * 0.7 else distance
				if distance <= difficulty.ViewDistance
					and score < bestScore
					and HitQuery.HasLineOfSight(head.Position, otherHead.Position)
				then
					best, bestRoot, bestScore = other, otherRoot, score
				end
			end
		end
	end
	if not best then
		return nil
	end
	return best, bestRoot, (bestRoot.Position - root.Position).Magnitude
end

-- Combat -------------------------------------------------------------------------------
function BotBrain:_combat(dt, now, difficulty, humanoid, root, head, target, targetRoot, distance)
	local WeaponService = self.Services.WeaponService
	local bot = self.Bot
	local state = WeaponService:GetState(bot)
	if not state then
		return
	end

	local toTarget = targetRoot.Position - root.Position
	self:_setFacing(humanoid, root, Vector3.new(toTarget.X, 0, toTarget.Z))

	-- Decide whether to try a knife throw at mid range.
	local meleeConfig = WeaponRegistry.Get(state.Loadout.Melee)
	if self.PendingThrow and now - self.PendingThrowSince > 2.5 then
		self.PendingThrow = false
	end
	if not self.PendingThrow and meleeConfig and meleeConfig.Throw and meleeConfig.Throw.Enabled
		and distance > 14 and distance < 50
	then
		local available = WeaponService:GetThrowCharges(state, meleeConfig)
		if available > 0 and self.Rng:NextNumber() < difficulty.ThrowChance * dt then
			self.PendingThrow = true
			self.PendingThrowSince = now
		end
	end

	-- Weapon choice by distance.
	local slot
	if self.PendingThrow or distance <= BotConfig.Ranges.Knife then
		slot = "Melee"
	elseif distance <= BotConfig.Ranges.Shotgun then
		slot = "Primary"
	else
		slot = "Secondary"
	end
	if state.Equipped ~= slot and now >= self.NextWeaponSwitch and not self.HeavyBusy and state.Loadout[slot] then
		WeaponService:Equip(bot, slot)
		self.NextWeaponSwitch = now + 0.6
	end
	local config = WeaponRegistry.Get(state.Loadout[state.Equipped])

	local speed = difficulty.WalkSpeed * (config and config.MovementMultiplier or 1)
	if distance > 30 then
		speed *= 1.25 -- "sprint" when closing big gaps
	end
	humanoid.WalkSpeed = speed
	self:_combatMove(now, difficulty, humanoid, root, targetRoot, distance, config)

	if not config or now - self.AcquiredAt < difficulty.ReactionTime then
		return
	end
	if config.Class == "Gun" then
		self:_shoot(now, difficulty, state, config, head, target)
	elseif config.Class == "Melee" then
		self:_knife(now, difficulty, state, config, root, head, target, targetRoot, distance)
	end
end

function BotBrain:_combatMove(now, difficulty, humanoid, root, targetRoot, distance, config)
	local preferred = BotConfig.PreferredDistance
	local desired = preferred.Pistol
	if config and config.Class == "Melee" then
		desired = preferred.Melee
	elseif config and config.Category == "Shotgun" then
		desired = preferred.Shotgun
	end

	local offset = targetRoot.Position - root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude < 0.1 then
		return
	end
	local forward = flat.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)
	if now >= self.NextStrafeFlip then
		self.StrafeDir = if self.Rng:NextNumber() < 0.5 then -1 else 1
		self.NextStrafeFlip = now + self.Rng:NextNumber(0.6, 1.6)
	end

	local goal
	local chasing = false
	if distance > desired + 3 then
		chasing = true
		goal = root.Position + forward * math.min(distance - desired, 12)
		-- With the knife, circle toward the target's back for a backstab.
		if config and config.Class == "Melee" and distance < 16 then
			goal = targetRoot.Position - targetRoot.CFrame.LookVector * 3
		end
	elseif distance < desired - 3 and config and config.Class ~= "Melee" then
		goal = root.Position - forward * 6
	elseif self.Rng:NextNumber() < difficulty.StrafeChance then
		goal = root.Position + right * self.StrafeDir * 6
	else
		goal = root.Position
	end

	if self:_isSafe(root.Position, goal) then
		self.Waypoints = nil
		humanoid:MoveTo(goal)
	elseif chasing then
		self:_followPath(now, humanoid, root, targetRoot.Position) -- gap in the way: path around it
	else
		self.StrafeDir = -self.StrafeDir
		humanoid:MoveTo(root.Position)
	end

	if self.Rng:NextNumber() < 0.02 then
		humanoid.Jump = true
	end
end

function BotBrain:_shoot(now, difficulty, state, config, head, target)
	local WeaponService = self.Services.WeaponService
	if (state.Ammo[config.Id] or 0) <= 0 then
		WeaponService:Reload(self.Bot)
		return
	end
	if state.ReloadingUntil or now < self.NextShotAt then
		return
	end
	local targetCharacter = target.Character
	local aimPart = nil
	if self.Rng:NextNumber() < difficulty.HeadshotChance then
		aimPart = targetCharacter:FindFirstChild("Head")
	end
	aimPart = aimPart or targetCharacter:FindFirstChild("UpperTorso") or targetCharacter:FindFirstChild("HumanoidRootPart")
	if not aimPart then
		return
	end
	local direction = CombatMath.RandomInCone((aimPart.Position - head.Position).Unit, difficulty.AimError, self.Rng)
	WeaponService:RequestFire(self.Bot, head.Position, direction, nil)
	self.NextShotAt = now + 60 / config.FireRate + self.Rng:NextNumber(difficulty.ShotPause[1], difficulty.ShotPause[2])
end

function BotBrain:_knife(now, difficulty, state, config, root, head, target, targetRoot, distance)
	local WeaponService = self.Services.WeaponService
	local bot = self.Bot
	if now < state.NextMelee or self.HeavyBusy then
		return
	end

	-- Throw: aim above the target to cancel gravity drop, and lead its movement.
	if self.PendingThrow and config.Throw then
		local throw = config.Throw
		local aim = targetRoot.Position + Vector3.new(0, 0.6, 0)
		local travelTime = (aim - head.Position).Magnitude / throw.Speed
		aim += targetRoot.AssemblyLinearVelocity * travelTime * 0.8
		aim += Vector3.new(0, 0.5 * throw.Gravity * travelTime * travelTime, 0)
		local direction = CombatMath.RandomInCone((aim - head.Position).Unit, difficulty.AimError * 0.7, self.Rng)
		WeaponService:RequestThrow(bot, head.Position, direction, 0)
		self:_playOnce("Slash", 1.6)
		self.PendingThrow = false
		return
	end

	if distance > config.Light.Range - 0.5 then
		return
	end
	local look = targetRoot.Position - root.Position
	if self.Rng:NextNumber() < difficulty.HeavyChance then
		self.HeavyBusy = true
		WeaponService:RequestBeginHeavy(bot)
		task.delay(config.Heavy.Windup * 0.6, function()
			self:_playOnce("Lunge")
		end)
		task.delay(config.Heavy.Windup, function()
			self.HeavyBusy = false
			local myRoot = self.Services.PlayerService:GetRoot(bot)
			local theirRoot = self.Services.PlayerService:GetRoot(target)
			if myRoot and theirRoot and self.Services.CombatService:IsAlive(bot) then
				WeaponService:RequestMelee(bot, "Heavy", theirRoot.Position - myRoot.Position, target.Character)
			end
		end)
	else
		WeaponService:RequestMelee(bot, "Light", look, target.Character)
		self:_playOnce("Slash")
	end
end

-- Navigation ---------------------------------------------------------------------------
-- No visible enemy: head for the nearest living enemy (or a random spawn) using pathfinding.
function BotBrain:_hunt(now, humanoid, root)
	local services = self.Services
	local goal, bestDistance = nil, math.huge
	for _, other in Combatants.GetAll() do
		if other ~= self.Bot and services.CombatService:IsAlive(other) and services.PlayerService:IsInMatch(other) then
			local otherRoot = services.PlayerService:GetRoot(other)
			if otherRoot then
				local distance = (otherRoot.Position - root.Position).Magnitude
				if distance < bestDistance then
					goal, bestDistance = otherRoot.Position, distance
				end
			end
		end
	end
	if not goal then
		local spawns = services.MapService:GetSpawnPoints()
		if #spawns == 0 then
			return
		end
		if not self.PathGoal or (self.PathGoal - root.Position).Magnitude < 6 then
			self.PathGoal = spawns[self.Rng:NextInteger(1, #spawns)].Position
		end
		goal = self.PathGoal
	end
	self:_followPath(now, humanoid, root, goal)
end

function BotBrain:_followPath(now, humanoid, root, goal)
	local needsPath = not self.Waypoints
		or now >= self.NextPathAt
		or (self.PathGoal and (self.PathGoal - goal).Magnitude > 15)
	if needsPath and not self.Computing then
		self.Computing = true
		self.NextPathAt = now + BotConfig.PathRecompute
		local from = root.Position
		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				WaypointSpacing = 4,
			})
			local ok = pcall(path.ComputeAsync, path, from, goal)
			self.Computing = false
			if ok and path.Status == Enum.PathStatus.Success then
				self.Waypoints = path:GetWaypoints()
				self.WaypointIndex = 2
				self.PathGoal = goal
			else
				self.Waypoints = nil
			end
		end)
	end

	local waypoints = self.Waypoints
	local waypoint = waypoints and waypoints[self.WaypointIndex]
	if waypoint then
		local offset = waypoint.Position - root.Position
		if Vector3.new(offset.X, 0, offset.Z).Magnitude < 3 then
			self.WaypointIndex += 1
			waypoint = waypoints[self.WaypointIndex]
		end
	end
	if waypoint then
		humanoid:MoveTo(waypoint.Position)
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
	elseif self:_isSafe(root.Position, goal) then
		humanoid:MoveTo(goal)
	else
		humanoid:MoveTo(root.Position)
	end
end

function BotBrain:Destroy()
	if self.Tracks then
		for _, track in self.Tracks do
			track:Stop()
		end
	end
	self.Tracks = nil
end

return BotBrain
