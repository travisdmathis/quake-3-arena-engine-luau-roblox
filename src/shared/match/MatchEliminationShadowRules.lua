--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure same-frame elimination and terminal-latch rules translated from Quake III Arena:
  code/game/g_combat.c (AddScore, player_die, G_Damage)
  code/game/g_main.c (CalculateRanks, ScoreIsTied, CheckExitRules, LogExit, G_RunFrame)
  code/game/g_local.h (INTERMISSION_DELAY_TIME)

The immutable transaction shape, stable Roblox user identities, explicit operation
ordering, and service-free validation boundary are the Roblox Luau port adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type ScoreKind = "PlayerFrags" | "TeamFrags" | "TeamObjective"
export type TeamId = "None" | "Red" | "Blue"
export type RejectionReason = "TerminalLatched" | "AlreadyEliminated" | "TeamProtection"

export type PlayerSeed = {
	sourceOrder: number,
	userId: number,
	teamId: TeamId,
	score: number,
	deaths: number,
	eliminatedCurrentLife: boolean,
}

export type CreateRequest = {
	scoreKind: ScoreKind,
	scoreLimit: number,
	timeLimitAtMilliseconds: number,
	scoringEnabled: boolean,
	friendlyFire: boolean,
	levelTimeMilliseconds: number,
	redScore: number,
	blueScore: number,
	players: { PlayerSeed },
}

export type TerminalLatch = {
	reason: "FragLimit" | "TimeLimit",
	operationOrder: number,
	qualifiedAtMilliseconds: number,
	startsAtMilliseconds: number,
	qualifiedByUserId: number?,
	qualifiedByTeamId: ("Red" | "Blue")?,
	winnerUserId: number?,
	winnerTeamId: ("Red" | "Blue")?,
}

export type State = {
	scoreKind: ScoreKind,
	scoreLimit: number,
	timeLimitAtMilliseconds: number,
	scoringEnabled: boolean,
	friendlyFire: boolean,
	levelTimeMilliseconds: number,
	lastOperationOrder: number,
	redScore: number,
	blueScore: number,
	players: { PlayerSeed },
	terminal: TerminalLatch?,
}

export type EliminationRequest = {
	operationOrder: number,
	levelTimeMilliseconds: number,
	victimUserId: number,
	attackerUserId: number,
	bypassTeamProtection: boolean,
}

export type EliminationOutcome = {
	accepted: boolean,
	rejectionReason: RejectionReason?,
	scored: boolean,
	scoreDelta: number,
	scoringUserId: number,
	victimUserId: number,
	victimDeaths: number,
	victimScore: number,
	attackerScore: number?,
	scoreTied: boolean,
	tiedAtLimit: boolean,
	terminalQualified: boolean,
	terminal: TerminalLatch?,
}

local MatchEliminationShadowRules = {}

local MAXIMUM_CLIENTS = 64
local MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991
local MAXIMUM_OPERATION_ORDER = 2_147_483_647
local MAXIMUM_SCORE_MAGNITUDE = 1_000_000
local MAXIMUM_DEATHS = 2_147_483_647
local INTERMISSION_DELAY_MILLISECONDS = 1000
local MAXIMUM_LEVEL_TIME_MILLISECONDS = MAXIMUM_SAFE_INTEGER - INTERMISSION_DELAY_MILLISECONDS

local ScoreKinds = table.freeze({
	PlayerFrags = "PlayerFrags" :: ScoreKind,
	TeamFrags = "TeamFrags" :: ScoreKind,
	TeamObjective = "TeamObjective" :: ScoreKind,
})

local TeamIds = table.freeze({
	None = "None" :: TeamId,
	Red = "Red" :: TeamId,
	Blue = "Blue" :: TeamId,
})

local CREATE_REQUEST_KEYS = table.freeze({
	scoreKind = true,
	scoreLimit = true,
	timeLimitAtMilliseconds = true,
	scoringEnabled = true,
	friendlyFire = true,
	levelTimeMilliseconds = true,
	redScore = true,
	blueScore = true,
	players = true,
})
local PLAYER_SEED_KEYS = table.freeze({
	sourceOrder = true,
	userId = true,
	teamId = true,
	score = true,
	deaths = true,
	eliminatedCurrentLife = true,
})
local ELIMINATION_REQUEST_KEYS = table.freeze({
	operationOrder = true,
	levelTimeMilliseconds = true,
	victimUserId = true,
	attackerUserId = true,
	bypassTeamProtection = true,
})

local stateCapabilities: { [State]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function hasExactKeys(
	value: { [unknown]: unknown },
	allowed: { [string]: boolean },
	expectedCount: number
): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function isScore(value: unknown): boolean
	return isInteger(value, -MAXIMUM_SCORE_MAGNITUDE, MAXIMUM_SCORE_MAGNITUDE)
end

local function denseArrayLength(value: unknown): number?
	if type(value) ~= "table" then
		return nil
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	if count ~= maximumIndex then
		return nil
	end
	return count
end

local function copyPlayer(raw: { [unknown]: unknown }): PlayerSeed?
	if not hasExactKeys(raw, PLAYER_SEED_KEYS, 6) then
		return nil
	end
	if
		not isInteger(raw.sourceOrder, 1, MAXIMUM_CLIENTS)
		or not isInteger(raw.userId, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER)
		or raw.userId == 0
		or (raw.teamId ~= TeamIds.None and raw.teamId ~= TeamIds.Red and raw.teamId ~= TeamIds.Blue)
		or not isScore(raw.score)
		or not isInteger(raw.deaths, 0, MAXIMUM_DEATHS)
		or type(raw.eliminatedCurrentLife) ~= "boolean"
	then
		return nil
	end
	local player: PlayerSeed = {
		sourceOrder = raw.sourceOrder :: number,
		userId = raw.userId :: number,
		teamId = raw.teamId :: TeamId,
		score = raw.score :: number,
		deaths = raw.deaths :: number,
		eliminatedCurrentLife = raw.eliminatedCurrentLife :: boolean,
	}
	return table.freeze(player)
end

local function findPlayerIndex(players: { PlayerSeed }, userId: number): number?
	for index, player in players do
		if player.userId == userId then
			return index
		end
	end
	return nil
end

local function scoreIsTied(scoreKind: ScoreKind, players: { PlayerSeed }, redScore: number, blueScore: number): boolean
	-- Q3 ScoreIsTied returns false before comparing scores when fewer than two
	-- clients are playing. Death does not remove a client from this count.
	if #players < 2 then
		return false
	end
	if scoreKind ~= ScoreKinds.PlayerFrags then
		return redScore == blueScore
	end

	local leadingScore = -math.huge
	local leaders = 0
	for _, player in players do
		if player.score > leadingScore then
			leadingScore = player.score
			leaders = 1
		elseif player.score == leadingScore then
			leaders += 1
		end
	end
	return leaders > 1
end

local function leadingScore(scoreKind: ScoreKind, players: { PlayerSeed }, redScore: number, blueScore: number): number
	if scoreKind ~= ScoreKinds.PlayerFrags then
		return math.max(redScore, blueScore)
	end
	local score = -math.huge
	for _, player in players do
		score = math.max(score, player.score)
	end
	return score
end

local function buildTerminal(
	scoreKind: ScoreKind,
	players: { PlayerSeed },
	redScore: number,
	blueScore: number,
	scoreLimit: number,
	timeLimitAtMilliseconds: number,
	operationOrder: number,
	levelTimeMilliseconds: number
): TerminalLatch?
	if scoreIsTied(scoreKind, players, redScore, blueScore) then
		return nil
	end

	local qualifiedByUserId: number? = nil
	local qualifiedByTeamId: ("Red" | "Blue")? = nil
	local winnerUserId: number? = nil
	local winnerTeamId: ("Red" | "Blue")? = nil
	if scoreKind ~= ScoreKinds.PlayerFrags then
		if redScore > blueScore then
			winnerTeamId = TeamIds.Red
		elseif blueScore > redScore then
			winnerTeamId = TeamIds.Blue
		end
	else
		local winnerScore = -math.huge
		for _, player in players do
			if player.score > winnerScore then
				winnerScore = player.score
				winnerUserId = player.userId
			end
		end
	end

	local reason: "FragLimit" | "TimeLimit"
	if timeLimitAtMilliseconds >= 0 and levelTimeMilliseconds >= timeLimitAtMilliseconds then
		-- CheckExitRules evaluates an expired timelimit after the tie gate but
		-- before its two-playing-client guard and every frag-limit branch.
		reason = "TimeLimit"
	else
		if scoreLimit <= 0 or #players < 2 then
			return nil
		end
		reason = "FragLimit"
	end

	if reason == "FragLimit" and scoreKind == ScoreKinds.TeamFrags then
		-- Preserve CheckExitRules' RED-before-BLUE test. After a tied-at-limit
		-- state breaks, the first qualifying bucket need not be the winner.
		if redScore >= scoreLimit then
			qualifiedByTeamId = TeamIds.Red
		elseif blueScore >= scoreLimit then
			qualifiedByTeamId = TeamIds.Blue
		else
			return nil
		end
	elseif reason == "FragLimit" then
		-- CheckExitRules scans client slots, not sorted rank order, when it asks
		-- which FFA client crossed the limit. The winner is still the unique top
		-- score captured by LogExit's already-sorted scoreboard.
		for _, player in players do
			if qualifiedByUserId == nil and player.score >= scoreLimit then
				qualifiedByUserId = player.userId
			end
		end
		if qualifiedByUserId == nil then
			return nil
		end
	end

	local terminal: TerminalLatch = {
		reason = reason,
		operationOrder = operationOrder,
		qualifiedAtMilliseconds = levelTimeMilliseconds,
		startsAtMilliseconds = levelTimeMilliseconds + INTERMISSION_DELAY_MILLISECONDS,
		qualifiedByUserId = qualifiedByUserId,
		qualifiedByTeamId = qualifiedByTeamId,
		winnerUserId = winnerUserId,
		winnerTeamId = winnerTeamId,
	}
	return table.freeze(terminal)
end

local function registerState(state: State): State
	table.freeze(state.players)
	table.freeze(state)
	stateCapabilities[state] = true
	return state
end

local function create(value: unknown): (State?, string?)
	if type(value) ~= "table" then
		return nil, "create-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, CREATE_REQUEST_KEYS, 9) then
		return nil, "invalid-create-request-shape"
	end
	local scoreKind = raw.scoreKind
	if
		scoreKind ~= ScoreKinds.PlayerFrags
		and scoreKind ~= ScoreKinds.TeamFrags
		and scoreKind ~= ScoreKinds.TeamObjective
	then
		return nil, "invalid-score-kind"
	end
	if
		not isInteger(raw.scoreLimit, 0, MAXIMUM_SCORE_MAGNITUDE)
		or not isInteger(raw.timeLimitAtMilliseconds, -1, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or type(raw.scoringEnabled) ~= "boolean"
		or type(raw.friendlyFire) ~= "boolean"
		or not isInteger(raw.levelTimeMilliseconds, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isScore(raw.redScore)
		or not isScore(raw.blueScore)
	then
		return nil, "invalid-create-request"
	end
	if scoreKind == ScoreKinds.PlayerFrags and (raw.redScore ~= 0 or raw.blueScore ~= 0) then
		return nil, "player-frag-team-score"
	end
	if scoreKind == ScoreKinds.TeamObjective and raw.scoreLimit ~= 0 then
		return nil, "team-objective-frag-limit"
	end

	local count = denseArrayLength(raw.players)
	if count == nil or count > MAXIMUM_CLIENTS then
		return nil, "invalid-player-array"
	end
	local players: { PlayerSeed } = table.create(count)
	local seenSourceOrders: { [number]: boolean } = {}
	local seenUserIds: { [number]: boolean } = {}
	for index, playerValue in raw.players :: { unknown } do
		if type(playerValue) ~= "table" then
			return nil, "player-not-table"
		end
		local player = copyPlayer(playerValue :: { [unknown]: unknown })
		if not player then
			return nil, "invalid-player"
		end
		if seenSourceOrders[player.sourceOrder] or seenUserIds[player.userId] then
			return nil, "duplicate-player-identity"
		end
		if
			(scoreKind == ScoreKinds.PlayerFrags and player.teamId ~= TeamIds.None)
			or (scoreKind ~= ScoreKinds.PlayerFrags and player.teamId == TeamIds.None)
		then
			return nil, "player-team-kind-mismatch"
		end
		seenSourceOrders[player.sourceOrder] = true
		seenUserIds[player.userId] = true
		players[index] = player
	end
	table.sort(players, function(left: PlayerSeed, right: PlayerSeed): boolean
		return left.sourceOrder < right.sourceOrder
	end)

	local state: State = {
		scoreKind = scoreKind :: ScoreKind,
		scoreLimit = raw.scoreLimit :: number,
		timeLimitAtMilliseconds = raw.timeLimitAtMilliseconds :: number,
		scoringEnabled = raw.scoringEnabled :: boolean,
		friendlyFire = raw.friendlyFire :: boolean,
		levelTimeMilliseconds = raw.levelTimeMilliseconds :: number,
		lastOperationOrder = 0,
		redScore = raw.redScore :: number,
		blueScore = raw.blueScore :: number,
		players = players,
		terminal = nil,
	}
	return registerState(state), nil
end

local function rejection(state: State, victim: PlayerSeed, reason: RejectionReason): EliminationOutcome
	local outcome: EliminationOutcome = {
		accepted = false,
		rejectionReason = reason,
		scored = false,
		scoreDelta = 0,
		scoringUserId = 0,
		victimUserId = victim.userId,
		victimDeaths = victim.deaths,
		victimScore = victim.score,
		attackerScore = nil,
		scoreTied = scoreIsTied(state.scoreKind, state.players, state.redScore, state.blueScore),
		tiedAtLimit = false,
		terminalQualified = false,
		terminal = state.terminal,
	}
	return table.freeze(outcome)
end

local function stageElimination(stateValue: unknown, requestValue: unknown): (State?, EliminationOutcome?, string?)
	if type(stateValue) ~= "table" or stateCapabilities[stateValue :: any] ~= true then
		return nil, nil, "invalid-state"
	end
	local state = stateValue :: State
	if type(requestValue) ~= "table" then
		return nil, nil, "elimination-request-not-table"
	end
	local raw = requestValue :: { [unknown]: unknown }
	if not hasExactKeys(raw, ELIMINATION_REQUEST_KEYS, 5) then
		return nil, nil, "invalid-elimination-request-shape"
	end
	if
		not isInteger(raw.operationOrder, state.lastOperationOrder + 1, MAXIMUM_OPERATION_ORDER)
		or not isInteger(raw.levelTimeMilliseconds, state.levelTimeMilliseconds, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isInteger(raw.victimUserId, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER)
		or raw.victimUserId == 0
		or not isInteger(raw.attackerUserId, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER)
		or type(raw.bypassTeamProtection) ~= "boolean"
	then
		return nil, nil, "invalid-elimination-request"
	end

	local victimIndex = findPlayerIndex(state.players, raw.victimUserId :: number)
	if not victimIndex then
		return nil, nil, "unknown-victim"
	end
	local victim = state.players[victimIndex]
	local attackerIndex: number? = nil
	if raw.attackerUserId ~= 0 then
		attackerIndex = findPlayerIndex(state.players, raw.attackerUserId :: number)
		if not attackerIndex then
			return nil, nil, "unknown-attacker"
		end
	end

	-- This is the pure equivalent of G_Damage's early intermissionQueued gate.
	-- It is intentionally checked before any health-independent match mutation.
	if state.terminal then
		return state, rejection(state, victim, "TerminalLatched"), nil
	end
	if victim.eliminatedCurrentLife then
		return state, rejection(state, victim, "AlreadyEliminated"), nil
	end

	local attacker = if attackerIndex then state.players[attackerIndex] else nil
	local friendly = attacker ~= nil
		and attacker.userId ~= victim.userId
		and state.scoreKind ~= ScoreKinds.PlayerFrags
		and attacker.teamId == victim.teamId
	if friendly and not state.friendlyFire and raw.bypassTeamProtection ~= true then
		return state, rejection(state, victim, "TeamProtection"), nil
	end

	local players = table.clone(state.players)
	local scoreDelta = 0
	local scoringIndex: number? = nil
	if state.scoringEnabled then
		if attacker then
			scoringIndex = attackerIndex
			scoreDelta = if attacker.userId == victim.userId or friendly then -1 else 1
		else
			scoringIndex = victimIndex
			scoreDelta = -1
		end
	end

	local victimScore = victim.score
	-- player_die increments PERS_KILLED before AddScore. Warmup suppresses score
	-- and CalculateRanks, but it does not suppress the victim's death count.
	local victimDeaths = victim.deaths + 1
	local attackerScore: number? = if attacker then attacker.score else nil
	if scoringIndex == victimIndex then
		victimScore += scoreDelta
	end
	if attacker and scoringIndex == attackerIndex then
		attackerScore = attacker.score + scoreDelta
	end
	if not isScore(victimScore) or (attackerScore ~= nil and not isScore(attackerScore)) then
		return nil, nil, "score-overflow"
	end
	if victimDeaths > MAXIMUM_DEATHS then
		return nil, nil, "death-overflow"
	end

	local nextVictim: PlayerSeed = table.freeze({
		sourceOrder = victim.sourceOrder,
		userId = victim.userId,
		teamId = victim.teamId,
		score = victimScore,
		deaths = victimDeaths,
		eliminatedCurrentLife = true,
	})
	players[victimIndex] = nextVictim
	if attacker and attackerIndex and attackerIndex ~= victimIndex then
		local nextAttacker: PlayerSeed = table.freeze({
			sourceOrder = attacker.sourceOrder,
			userId = attacker.userId,
			teamId = attacker.teamId,
			score = attackerScore :: number,
			deaths = attacker.deaths,
			eliminatedCurrentLife = attacker.eliminatedCurrentLife,
		})
		players[attackerIndex] = nextAttacker
	end

	local redScore = state.redScore
	local blueScore = state.blueScore
	if state.scoringEnabled and state.scoreKind == ScoreKinds.TeamFrags then
		local scoringPlayer = players[scoringIndex :: number]
		if scoringPlayer.teamId == TeamIds.Red then
			redScore += scoreDelta
		else
			blueScore += scoreDelta
		end
		if not isScore(redScore) or not isScore(blueScore) then
			return nil, nil, "team-score-overflow"
		end
	end

	local operationOrder = raw.operationOrder :: number
	local levelTimeMilliseconds = raw.levelTimeMilliseconds :: number
	local terminal = if state.scoringEnabled
		then buildTerminal(
			state.scoreKind,
			players,
			redScore,
			blueScore,
			state.scoreLimit,
			state.timeLimitAtMilliseconds,
			operationOrder,
			levelTimeMilliseconds
		)
		else nil
	local tied = scoreIsTied(state.scoreKind, players, redScore, blueScore)
	local tiedAtLimit = tied
		and state.scoreLimit > 0
		and leadingScore(state.scoreKind, players, redScore, blueScore) >= state.scoreLimit

	local nextState: State = {
		scoreKind = state.scoreKind,
		scoreLimit = state.scoreLimit,
		timeLimitAtMilliseconds = state.timeLimitAtMilliseconds,
		scoringEnabled = state.scoringEnabled,
		friendlyFire = state.friendlyFire,
		levelTimeMilliseconds = levelTimeMilliseconds,
		lastOperationOrder = operationOrder,
		redScore = redScore,
		blueScore = blueScore,
		players = players,
		terminal = terminal,
	}
	-- A successful operation advances one authoritative lineage. Keeping the
	-- prior immutable state usable would permit the server adapter to fork two
	-- valid commits from the same starting snapshot. Rejections return the same
	-- current state and deliberately do not consume it.
	stateCapabilities[state] = nil
	registerState(nextState)

	local outcome: EliminationOutcome = {
		accepted = true,
		rejectionReason = nil,
		scored = state.scoringEnabled,
		scoreDelta = scoreDelta,
		scoringUserId = if state.scoringEnabled then players[scoringIndex :: number].userId else 0,
		victimUserId = victim.userId,
		victimDeaths = victimDeaths,
		victimScore = victimScore,
		attackerScore = attackerScore,
		scoreTied = tied,
		tiedAtLimit = tiedAtLimit,
		terminalQualified = terminal ~= nil,
		terminal = terminal,
	}
	return nextState, table.freeze(outcome), nil
end

local function inspect(value: unknown): State?
	if type(value) ~= "table" or stateCapabilities[value :: any] ~= true then
		return nil
	end
	return value :: State
end

local function getPlayer(stateValue: unknown, userIdValue: unknown): PlayerSeed?
	local state = inspect(stateValue)
	if not state or not isInteger(userIdValue, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER) or userIdValue == 0 then
		return nil
	end
	local index = findPlayerIndex(state.players, userIdValue :: number)
	return if index then state.players[index] else nil
end

local function isDamageOpen(stateValue: unknown): boolean
	local state = inspect(stateValue)
	return state ~= nil and state.terminal == nil
end

local function isIntermissionDue(stateValue: unknown, levelTimeMillisecondsValue: unknown): boolean
	local state = inspect(stateValue)
	return state ~= nil
		and state.terminal ~= nil
		and isInteger(levelTimeMillisecondsValue, 0, MAXIMUM_SAFE_INTEGER)
		and (levelTimeMillisecondsValue :: number) >= state.terminal.startsAtMilliseconds
end

MatchEliminationShadowRules.ScoreKinds = ScoreKinds
MatchEliminationShadowRules.TeamIds = TeamIds
MatchEliminationShadowRules.MaximumClients = MAXIMUM_CLIENTS
MatchEliminationShadowRules.IntermissionDelayMilliseconds = INTERMISSION_DELAY_MILLISECONDS
MatchEliminationShadowRules.MaximumLevelTimeMilliseconds = MAXIMUM_LEVEL_TIME_MILLISECONDS
MatchEliminationShadowRules.Create = create
MatchEliminationShadowRules.StageElimination = stageElimination
MatchEliminationShadowRules.Inspect = inspect
MatchEliminationShadowRules.GetPlayer = getPlayer
MatchEliminationShadowRules.IsDamageOpen = isDamageOpen
MatchEliminationShadowRules.IsIntermissionDue = isIntermissionDue

return table.freeze(MatchEliminationShadowRules)
