-- ProjectileService (Server)
-- Server-authoritative projectiles (throwing knives now; grenades/rockets later).
-- Every projectile is stepped on ONE shared Heartbeat connection with a spherecast per step,
-- so fast projectiles never tunnel through thin walls. The connection disconnects when idle.
-- Clients receive only Spawn/End packets and simulate the same ballistic arc cosmetically.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net.Net)

local ProjectileService = {}

local active = {} -- [id] = projectile
local nextId = 0
local connection = nil
local effectsFolder = workspace:WaitForChild("Effects")

function ProjectileService:Init(services)
	self.Services = services
end

function ProjectileService:Start() end

-- spec = { Owner: Player, Origin: Vector3, Velocity: Vector3, Gravity: number, Radius: number,
--          Lifetime: number, WeaponId: string, Seq: number?, Visual: string,
--          OnHit: (RaycastResult, travelDistance) -> boolean (true if a character was damaged) }
function ProjectileService:Launch(spec)
	nextId += 1
	local character = spec.Owner and spec.Owner.Character
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { effectsFolder, character }
	params.IgnoreWater = true

	local projectile = {
		Id = nextId,
		Owner = spec.Owner,
		Position = spec.Origin,
		Velocity = spec.Velocity,
		Gravity = spec.Gravity or 0,
		Radius = spec.Radius or 0.3,
		DieAt = os.clock() + (spec.Lifetime or 3),
		Params = params,
		OnHit = spec.OnHit,
		Travel = 0,
	}
	active[projectile.Id] = projectile

	Net.FireAll("ProjectileEvent", "Spawn", {
		Id = projectile.Id,
		OwnerId = spec.Owner and spec.Owner.UserId or 0,
		Seq = spec.Seq,
		Origin = spec.Origin,
		Velocity = spec.Velocity,
		Gravity = projectile.Gravity,
		Visual = spec.Visual,
		WeaponId = spec.WeaponId,
	})

	if not connection then
		connection = RunService.Heartbeat:Connect(function(dt)
			self:_step(dt)
		end)
	end
	return projectile.Id
end

function ProjectileService:_step(dt)
	local now = os.clock()
	for _, projectile in active do
		local gravity = Vector3.new(0, -projectile.Gravity, 0)
		local displacement = projectile.Velocity * dt + gravity * (0.5 * dt * dt)
		local result = workspace:Spherecast(projectile.Position, projectile.Radius, displacement, projectile.Params)
		if result then
			projectile.Travel += (result.Position - projectile.Position).Magnitude
			self:_finish(projectile, result)
		else
			projectile.Position += displacement
			projectile.Velocity += gravity * dt
			projectile.Travel += displacement.Magnitude
			if now >= projectile.DieAt then
				self:_finish(projectile, nil)
			end
		end
	end
	if next(active) == nil and connection then
		connection:Disconnect()
		connection = nil
	end
end

function ProjectileService:_finish(projectile, result)
	active[projectile.Id] = nil
	local hitCharacter = false
	if result and projectile.OnHit then
		local ok, value = pcall(projectile.OnHit, result, projectile.Travel)
		if ok then
			hitCharacter = value == true
		else
			warn("[ProjectileService] OnHit error:", value)
		end
	end
	Net.FireAll("ProjectileEvent", "End", {
		Id = projectile.Id,
		Position = result and result.Position or projectile.Position,
		Normal = result and result.Normal or nil,
		HitCharacter = hitCharacter,
	})
end

-- Removes every projectile (match end). Clients are told so visuals vanish.
function ProjectileService:ClearAll()
	for _, projectile in active do
		active[projectile.Id] = nil
		Net.FireAll("ProjectileEvent", "End", { Id = projectile.Id, Position = projectile.Position, HitCharacter = false })
	end
end

return ProjectileService
