-- ModeBase (Server)
-- Base class for every game mode. MatchService only talks to modes through these hooks,
-- so Team Deathmatch, Gun Game, Infection, Duel... are new subclasses, not MatchService edits.
--
-- Hooks (override as needed):
--   Start()                      mode begins (players are added right after)
--   OnPlayerAdded(player)        player joined the match (start or join-in-progress)
--   OnPlayerRemoving(player)
--   CanDamage(attacker, victim)  friendly fire rules
--   IsEnemy(a, b)                used for spawn safety
--   GetKillScore(killInfo)       score for a kill
--   OnKill(killInfo) -> results? return results to end the match
--   OnTimeExpired() -> results
--   GetRespawnDelay(player)
--   Compare(a, b)                standings sort
--   Cleanup()

local ModeBase = {}
ModeBase.__index = ModeBase

function ModeBase.new(match, config)
	local self = setmetatable({}, ModeBase)
	self.Match = match -- MatchService
	self.Config = config -- ModeConfig entry
	return self
end

function ModeBase:Start() end
function ModeBase:OnPlayerAdded(_player) end
function ModeBase:OnPlayerRemoving(_player) end
function ModeBase:Cleanup() end

function ModeBase:CanDamage(attacker, victim)
	return attacker ~= victim
end

function ModeBase:IsEnemy(a, b)
	return a ~= b
end

function ModeBase:GetRespawnDelay(_player)
	return self.Config.RespawnDelay or 3
end

function ModeBase:GetKillScore(killInfo)
	local scoreTable = self.Config.Score or {}
	local score = scoreTable.Kill or 100
	for _, flag in killInfo.Flags do
		score += scoreTable[flag] or 0
	end
	if killInfo.MultiKill >= 2 then
		score += (killInfo.MultiKill - 1) * (scoreTable.MultiKillPerTier or 0)
	end
	return score
end

function ModeBase:OnKill(_killInfo)
	return nil
end

function ModeBase:OnTimeExpired()
	return self:BuildResults("TimeExpired")
end

-- Default ranking: score, then kills, then fewest deaths.
function ModeBase:Compare(a, b)
	if a.Score ~= b.Score then
		return a.Score > b.Score
	end
	if a.Kills ~= b.Kills then
		return a.Kills > b.Kills
	end
	return a.Deaths < b.Deaths
end

-- Builds the results table MatchService broadcasts and RewardService (Phase 2) consumes.
-- forcedWinners: optional list of players (e.g. whoever hit the kill target).
function ModeBase:BuildResults(reason, forcedWinners)
	local standings = {}
	for player, entry in self.Match.Scoreboard do
		table.insert(standings, {
			Player = player,
			Name = player.DisplayName,
			UserId = player.UserId,
			Kills = entry.Kills,
			Deaths = entry.Deaths,
			Score = entry.Score,
			BestStreak = entry.BestStreak,
		})
	end
	table.sort(standings, function(a, b)
		return self:Compare(a, b)
	end)

	local winners = {}
	if forcedWinners then
		winners = forcedWinners
	elseif standings[1] then
		local top = standings[1]
		for _, row in standings do
			if not self:Compare(top, row) and not self:Compare(row, top) then
				table.insert(winners, row.Player) -- exact tie = shared win
			end
		end
	end

	return {
		Reason = reason,
		ModeId = self.Match.ModeId,
		MapId = self.Match.MapId,
		Winners = winners,
		Standings = standings,
	}
end

return ModeBase
