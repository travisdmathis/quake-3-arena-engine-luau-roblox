--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of selected deterministic gameplay rules from:
  code/game/g_client.c (PickTeam)
  code/game/g_main.c (AddTournamentPlayer, RemoveTournamentLoser, CheckVote,
    CalculateRanks, ScoreIsTied, CheckExitRules, LogExit)
  code/game/g_local.h (INTERMISSION_DELAY_TIME)
  code/game/g_team.c (Team_TouchOurFlag, Team_TouchEnemyFlag, OnSameTeam)
  code/game/g_combat.c (G_Damage team-protection and queued-exit gate)

Arena Elimination side grouping, per-mode replaceable ballots, deterministic
tie-breaking, and the service-free test boundary are original the Roblox Luau port
adaptations. The public-vote quorum follows CheckVote's strict-majority rule.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

-- Pure deterministic rules used by the live match services and one-window
-- synthetic multiplayer tests. This module deliberately has no Roblox service,
-- Instance, clock, remote, storage, or yielding dependencies.

export type Participation = "Active" | "Spectator"

export type RosterEntry = {
	userId: number,
	joinOrder: number,
	participation: Participation,
	teamId: string?,
	roundEligible: boolean,
}

export type EliminationSide = {
	key: string,
	teamId: string?,
	userId: number?,
}

export type ScoreLimitState = "BelowLimit" | "TiedAtLimit" | "UniqueLeaderAtLimit"
export type SuddenDeathBasis = "ScoreLimit" | "TimeLimit"

export type IntermissionLatch = {
	read qualifiedAt: number,
	read startsAt: number,
	read reason: string,
	read winnerUserIds: { number },
	read winnerTeamIds: { string },
}

local MatchRulesCore = {}

local ScoreLimitStates = table.freeze({
	BelowLimit = "BelowLimit" :: ScoreLimitState,
	TiedAtLimit = "TiedAtLimit" :: ScoreLimitState,
	UniqueLeaderAtLimit = "UniqueLeaderAtLimit" :: ScoreLimitState,
})

local SuddenDeathBases = table.freeze({
	ScoreLimit = "ScoreLimit" :: SuddenDeathBasis,
	TimeLimit = "TimeLimit" :: SuddenDeathBasis,
})

-- code/game/g_local.h:INTERMISSION_DELAY_TIME. Q3 qualifies the result first,
-- freezes further damage/scoring, and begins the actual intermission one second
-- later so the terminal event remains visible.
local INTERMISSION_DELAY_SECONDS = 1

local function chooseBalancedTeam(redCount: number, blueCount: number): string
	return if redCount <= blueCount then "Red" else "Blue"
end

local function orderedRoster(roster: { RosterEntry }): { RosterEntry }
	local ordered = table.clone(roster)
	table.sort(ordered, function(left: RosterEntry, right: RosterEntry): boolean
		if left.joinOrder ~= right.joinOrder then
			return left.joinOrder < right.joinOrder
		end
		return left.userId < right.userId
	end)
	return ordered
end

local function resolveDuelRotation(roster: { RosterEntry }, winnerUserId: number): (number?, number?)
	local winnerFound = false
	local loserUserId: number? = nil
	local promotedUserId: number? = nil
	for _, entry in orderedRoster(roster) do
		if entry.participation == "Active" then
			if entry.userId == winnerUserId then
				winnerFound = true
			elseif loserUserId == nil then
				loserUserId = entry.userId
			end
		elseif promotedUserId == nil then
			promotedUserId = entry.userId
		end
	end
	if not winnerFound or loserUserId == nil or promotedUserId == nil then
		return nil, nil
	end
	return loserUserId, promotedUserId
end

-- Q3 GT_FFA admits clients directly to TEAM_FREE. the Roblox Luau port retains a
-- bounded active domain, so canonical join order selects the first N clients;
-- UserId breaks an impossible duplicate join-order tie deterministically.
local function selectFreeForAllActiveUserIds(roster: { RosterEntry }, activePlayerLimit: number): { number }
	local selected: { number } = {}
	if activePlayerLimit < 1 or activePlayerLimit % 1 ~= 0 then
		return selected
	end
	for _, entry in orderedRoster(roster) do
		if #selected >= activePlayerLimit then
			break
		end
		table.insert(selected, entry.userId)
	end
	return selected
end

local function collectEliminationSides(
	roster: { RosterEntry },
	teamMode: boolean,
	eligibleOnly: boolean
): { EliminationSide }
	local byKey: { [string]: EliminationSide } = {}
	for _, entry in roster do
		if entry.participation ~= "Active" or (eligibleOnly and not entry.roundEligible) then
			continue
		end
		if teamMode then
			if entry.teamId then
				local key = "Team:" .. entry.teamId
				byKey[key] = {
					key = key,
					teamId = entry.teamId,
					userId = nil,
				}
			end
		else
			local key = string.format("Player:%d", entry.userId)
			byKey[key] = {
				key = key,
				teamId = nil,
				userId = entry.userId,
			}
		end
	end

	local sides: { EliminationSide } = {}
	for _, side in byKey do
		table.insert(sides, side)
	end
	table.sort(sides, function(left: EliminationSide, right: EliminationSide): boolean
		return left.key < right.key
	end)
	return sides
end

local function requiredModeVotes(playerCount: number): number
	return math.floor(math.max(playerCount, 0) / 2) + 1
end

local function recordModeVote(ballots: { [number]: string }, userId: number, modeId: string): { [number]: string }
	local updated = table.clone(ballots)
	updated[userId] = modeId
	return updated
end

local function countModeVotes(
	ballots: { [number]: string },
	eligibleUserIds: { number },
	modeId: string
): (number, number)
	local count = 0
	for _, userId in eligibleUserIds do
		if ballots[userId] == modeId then
			count += 1
		end
	end
	return count, requiredModeVotes(#eligibleUserIds)
end

local function userIdPrecedes(leftUserId: number, rightUserId: number): boolean
	return leftUserId < rightUserId
end

local function resolveFlagTouchAction(candidateTeamId: string, flagTeamId: string, flagState: string): string?
	if candidateTeamId == flagTeamId then
		return if flagState == "Dropped" then "Return" else nil
	end
	return if flagState == "AtBase" or flagState == "Dropped" then "Pickup" else nil
end

local function canTeamDamage(
	teamMode: boolean,
	friendlyFire: boolean,
	attackerTeamId: string?,
	targetTeamId: string?,
	isSelfDamage: boolean
): boolean
	if isSelfDamage or not teamMode then
		return true
	end
	if attackerTeamId == nil or targetTeamId == nil or attackerTeamId ~= targetTeamId then
		return true
	end
	return friendlyFire
end

-- Q3 CheckExitRules checks ScoreIsTied before every score-limit branch. Combining
-- those two checks here keeps every Luau score type on the same rule: at least two
-- active participants must exist, the leading score must reach the limit, and that lead
-- must be unique before intermission may begin.
local function resolveScoreLimitState(
	scores: { number },
	scoreLimit: number,
	activeParticipantCount: number
): ScoreLimitState
	-- Q3 ScoreIsTied and CheckExitRules use level.numPlayingClients for this
	-- guard. Team modes still compare the two team score buckets, but an empty
	-- opposing team must not make a single active player satisfy a score limit.
	if scoreLimit <= 0 or activeParticipantCount < 2 or #scores < 2 then
		return ScoreLimitStates.BelowLimit
	end

	local leadingScore = -math.huge
	local leadingSideCount = 0
	for _, score in scores do
		if score > leadingScore then
			leadingScore = score
			leadingSideCount = 1
		elseif score == leadingScore then
			leadingSideCount += 1
		end
	end

	if leadingScore < scoreLimit then
		return ScoreLimitStates.BelowLimit
	end
	if leadingSideCount > 1 then
		return ScoreLimitStates.TiedAtLimit
	end
	return ScoreLimitStates.UniqueLeaderAtLimit
end

-- Q3 CheckExitRules re-runs after CalculateRanks changes the playing roster. A
-- roster mutation can therefore resolve a tie without another scoring event.
-- Preserve why sudden death began: an expired timelimit only needs a unique
-- leader, while a frag/capture limit still requires that leader to be at the
-- configured limit. The caller has already enforced the live match's roster
-- policy; this helper retains Q3's two-playing-participant guard for the
-- departure requalification path.
local function shouldQualifySuddenDeathAfterRosterMutation(
	basis: SuddenDeathBasis,
	scores: { number },
	scoreLimit: number,
	activeParticipantCount: number
): boolean
	if activeParticipantCount < 2 or #scores < 2 then
		return false
	end

	local leadingScore = -math.huge
	local leadingSideCount = 0
	for _, score in scores do
		if score > leadingScore then
			leadingScore = score
			leadingSideCount = 1
		elseif score == leadingScore then
			leadingSideCount += 1
		end
	end
	if leadingSideCount ~= 1 then
		return false
	end

	if basis == SuddenDeathBases.TimeLimit then
		return true
	end
	return basis == SuddenDeathBases.ScoreLimit and scoreLimit > 0 and leadingScore >= scoreLimit
end

local function createIntermissionLatch(
	existing: IntermissionLatch?,
	qualifiedAt: number,
	reason: string,
	winnerUserIds: { number },
	winnerTeamIds: { string }
): (IntermissionLatch, boolean)
	if existing then
		return existing, false
	end

	local users = table.clone(winnerUserIds)
	local teams = table.clone(winnerTeamIds)
	table.freeze(users)
	table.freeze(teams)
	local latch: IntermissionLatch = {
		qualifiedAt = qualifiedAt,
		startsAt = qualifiedAt + INTERMISSION_DELAY_SECONDS,
		reason = reason,
		winnerUserIds = users,
		winnerTeamIds = teams,
	}
	return table.freeze(latch), true
end

local function isIntermissionLatchDue(latch: IntermissionLatch, now: number): boolean
	return now >= latch.startsAt
end

local function isTerminalGameplayOpen(latch: IntermissionLatch?): boolean
	return latch == nil
end

MatchRulesCore.ScoreLimitStates = ScoreLimitStates
MatchRulesCore.SuddenDeathBases = SuddenDeathBases
MatchRulesCore.IntermissionDelaySeconds = INTERMISSION_DELAY_SECONDS
MatchRulesCore.ChooseBalancedTeam = chooseBalancedTeam
MatchRulesCore.ResolveDuelRotation = resolveDuelRotation
MatchRulesCore.SelectFreeForAllActiveUserIds = selectFreeForAllActiveUserIds
MatchRulesCore.CollectEliminationSides = collectEliminationSides
MatchRulesCore.RequiredModeVotes = requiredModeVotes
MatchRulesCore.RecordModeVote = recordModeVote
MatchRulesCore.CountModeVotes = countModeVotes
MatchRulesCore.UserIdPrecedes = userIdPrecedes
MatchRulesCore.ResolveFlagTouchAction = resolveFlagTouchAction
MatchRulesCore.CanTeamDamage = canTeamDamage
MatchRulesCore.ResolveScoreLimitState = resolveScoreLimitState
MatchRulesCore.ShouldQualifySuddenDeathAfterRosterMutation = shouldQualifySuddenDeathAfterRosterMutation
MatchRulesCore.CreateIntermissionLatch = createIntermissionLatch
MatchRulesCore.IsIntermissionLatchDue = isIntermissionLatchDue
MatchRulesCore.IsTerminalGameplayOpen = isTerminalGameplayOpen

return table.freeze(MatchRulesCore)
