-- LagCompensationService (Server)
-- Keeps a short ring buffer of every character's pose so the server can check whether a
-- client's claimed hit was plausible at the moment that client saw it.
--
-- A laggy player sees enemies slightly in the past. When the server's own raycast misses but the
-- client supplied a "hint" character, we test the shot against that character's recorded poses
-- inside [now - (ping + interpolation), now], capped at MaxRewind. The server still owns the ray,
-- the damage, and the world line-of-sight - the client only nominates a target.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local CombatMath = require(ReplicatedStorage.Shared.Utilities.CombatMath)
local Combatants = require(script.Parent.Parent.Core.Combatants)

local CONFIG = GameConfig.LagComp
local HITBOX = GameConfig.Hitbox
local SAMPLE_INTERVAL = 1 / CONFIG.SampleRate
local CAPACITY = math.ceil(CONFIG.HistoryLength * CONFIG.SampleRate) + 2
local BODY_BOTTOM = Vector3.new(0, HITBOX.BodyBottom, 0)
local BODY_TOP = Vector3.new(0, HITBOX.BodyTop, 0)

local LagCompensationService = {}

local histories = {} -- [Player] = { Samples = { {Time, Root: CFrame, Head: Vector3} }, Index, Count }

function LagCompensationService:Init(services)
	self.Services = services
end

function LagCompensationService:Start()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < SAMPLE_INTERVAL then
			return
		end
		accumulator = 0
		local now = os.clock()
		for _, combatant in Combatants.GetAll() do
			self:_record(combatant, now)
		end
	end)

	Combatants.Removing:Connect(function(player)
		histories[player] = nil
	end)
end

function LagCompensationService:_record(player, now)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	if not root or not head then
		return
	end

	local history = histories[player]
	if not history then
		history = { Samples = table.create(CAPACITY), Index = 0, Count = 0 }
		histories[player] = history
	end
	history.Index = history.Index % CAPACITY + 1
	local sample = history.Samples[history.Index]
	if sample then
		sample.Time = now
		sample.Root = root.CFrame
		sample.Head = head.Position
	else
		history.Samples[history.Index] = { Time = now, Root = root.CFrame, Head = head.Position }
	end
	history.Count = math.min(history.Count + 1, CAPACITY)
end

-- Call on respawn/teleport so old positions can't be "hit".
function LagCompensationService:Reset(player)
	histories[player] = nil
end

function LagCompensationService:GetRewindStart(shooter)
	local ping = 0
	local ok, value = pcall(shooter.GetNetworkPing, shooter)
	if ok and type(value) == "number" then
		ping = value
	end
	local rewind = math.min(ping + CONFIG.InterpolationBuffer, CONFIG.MaxRewind)
	return os.clock() - rewind - SAMPLE_INTERVAL
end

-- Live pose + every recorded pose newer than fromTime.
function LagCompensationService:GetPoses(target, fromTime)
	local poses = {}
	local character = target.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
	if root and head then
		table.insert(poses, { Root = root.CFrame, Head = head.Position })
	end
	local history = histories[target]
	if history then
		for i = 1, history.Count do
			local sample = history.Samples[i]
			if sample and sample.Time >= fromTime then
				table.insert(poses, sample)
			end
		end
	end
	return poses
end

-- Does the ray origin + dirUnit * maxDistance pass through the target's hitbox at any
-- pose in the shooter's rewind window? Returns { IsHeadshot, Distance, Position } or nil.
function LagCompensationService:ValidateRay(shooter, target, origin, dirUnit, maxDistance)
	local fromTime = self:GetRewindStart(shooter)
	local tolerance = CONFIG.HitTolerance
	local rayEnd = origin + dirUnit * maxDistance
	local bodyHit = nil

	for _, pose in self:GetPoses(target, fromTime) do
		local headDistance, headT = CombatMath.PointRayDistance(pose.Head, origin, dirUnit, maxDistance)
		if headDistance <= HITBOX.HeadRadius + tolerance and headT > 0 and headT < maxDistance then
			return { IsHeadshot = true, Distance = headT, Position = origin + dirUnit * headT }
		end
		if not bodyHit then
			local rootPosition = pose.Root.Position
			local distance, s, point = CombatMath.SegmentSegmentDistance(
				origin,
				rayEnd,
				rootPosition + BODY_BOTTOM,
				rootPosition + BODY_TOP
			)
			if distance <= HITBOX.BodyRadius + tolerance and s > 0 then
				bodyHit = { IsHeadshot = false, Distance = s * maxDistance, Position = point }
			end
		end
	end
	return bodyHit
end

-- Was target within range + arc of the attacker at any pose in the rewind window?
-- Returns the matching pose or nil.
function LagCompensationService:ValidateMelee(attacker, target, origin, lookDirection, range, arcDegrees)
	local fromTime = self:GetRewindStart(attacker)
	local maxRange = range + CONFIG.HitTolerance
	for _, pose in self:GetPoses(target, fromTime) do
		local position = pose.Root.Position
		if (position - origin).Magnitude <= maxRange and CombatMath.InArc(origin, lookDirection, position, arcDegrees) then
			return pose
		end
	end
	return nil
end

return LagCompensationService
