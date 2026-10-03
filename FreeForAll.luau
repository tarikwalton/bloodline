-- FreeForAll (Server mode)
-- Everyone is an enemy. First to Config.KillTarget kills wins; on timeout most kills wins
-- (ties broken by score, then fewest deaths).

local ModeBase = require(script.Parent.ModeBase)

local FreeForAll = setmetatable({}, { __index = ModeBase })
FreeForAll.__index = FreeForAll

function FreeForAll.new(match, config)
	local self = ModeBase.new(match, config)
	return setmetatable(self, FreeForAll)
end

function FreeForAll:Start()
	self.Match:SetMatchAttribute("KillTarget", self.Config.KillTarget)
end

function FreeForAll:Compare(a, b)
	if a.Kills ~= b.Kills then
		return a.Kills > b.Kills
	end
	if a.Score ~= b.Score then
		return a.Score > b.Score
	end
	return a.Deaths < b.Deaths
end

function FreeForAll:OnKill(killInfo)
	local killer = killInfo.Killer
	if not killer then
		return nil
	end
	local entry = self.Match.Scoreboard[killer]
	if entry and entry.Kills >= self.Config.KillTarget then
		return self:BuildResults("KillTarget", { killer })
	end
	return nil
end

return FreeForAll
