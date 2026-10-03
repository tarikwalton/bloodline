-- ServerMain (Script)
-- Boots the server: creates remotes, requires every service, then runs Init() on all
-- services followed by Start() on all services. Services never start work in Init().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

Players.CharacterAutoLoads = false
Net.Init()

-- Explicit order: dependencies first. Any extra service modules added later are loaded after these.
local LOAD_ORDER = {
	"LagCompensationService",
	"MapService",
	"PlayerService",
	"CombatService",
	"KillService",
	"ProjectileService",
	"WeaponService",
	"MatchService",
}

local servicesFolder = script.Parent.Services
local services = {}
local ordered = {}

local function load(module)
	local ok, service = pcall(require, module)
	if not ok then
		error(string.format("[ServerMain] Failed to require %s: %s", module.Name, tostring(service)))
	end
	service.Name = service.Name or module.Name
	services[module.Name] = service
	table.insert(ordered, service)
end

for _, name in LOAD_ORDER do
	local module = servicesFolder:FindFirstChild(name)
	if module then
		load(module)
	else
		warn("[ServerMain] Missing service module:", name)
	end
end
for _, module in servicesFolder:GetChildren() do
	if module:IsA("ModuleScript") and not services[module.Name] then
		load(module)
	end
end

for _, service in ordered do
	if service.Init then
		service:Init(services)
	end
end
for _, service in ordered do
	if service.Start then
		service:Start()
	end
end

-- Basic security log. Phase 5 turns repeated offenders into kicks.
Net.Violation:Connect(function(player, remoteName, reason, count)
	if count == 1 or count % GameConfig.Security.ViolationWarnThreshold == 0 then
		warn(string.format("[Security] %s dropped packet on %s (%s). Total: %d", player.Name, remoteName, reason, count))
	end
end)

print("[BLOODLINE] Server ready with", #ordered, "services")
