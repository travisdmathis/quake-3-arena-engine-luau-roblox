--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MapRuntimeContract = require(sharedRoot:WaitForChild("maps"):WaitForChild("MapRuntimeContract"))
local MatchConfig = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchConfig"))
local MatchEliminationShadowRules =
	require(sharedRoot:WaitForChild("match"):WaitForChild("MatchEliminationShadowRules"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local MatchRulesCore = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchRulesCore"))
local RocketArenaRoundTimingRules =
	require(sharedRoot:WaitForChild("match"):WaitForChild("RocketArenaRoundTimingRules"))
local RemoteNames = require(sharedRoot:WaitForChild("RemoteNames"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local MatchEliminationPreparedRegistry = require(script.Parent.MatchEliminationPreparedRegistry)
local MatchRosterRuntime = require(script.Parent.MatchRosterRuntime)
local MatchStandingsRuntime = require(script.Parent.MatchStandingsRuntime)

local MatchService = {}
MatchService.LoadingPresentationTimeoutSeconds = 120

type State = MatchConfig.State
type ModeId = MatchConfig.ModeId
type TeamId = MatchConfig.TeamId
type Rules = MatchConfig.Rules
type SuddenDeathBasis = MatchRulesCore.SuddenDeathBasis
export type MoverEliminationShadow = MatchEliminationShadowRules.State
export type PlayerSourceOrderResolver = (player: Player) -> unknown
export type EliminationBatchToken = {}
export type PreparedEliminationBatch = {}
export type EliminationBatchCommitReceipt = {}
export type MatchLineage = {}
export type LoadingPresentationFailureCause = "MapPresentationFailed" | "MapPresentationTimedOut"
type RuntimeMap = MapRuntimeContract.RuntimeMap
type Participation = "Active" | "Spectator"
type RoundStatus = "Inactive" | "Preparing" | "Live" | "Resolved"

type PlayerMatchRecord = {
	score: number,
	deaths: number,
	roundWins: number,
	eliminatedCurrentLife: boolean,
	roundEligible: boolean,
	participation: Participation,
	teamId: TeamId?,
	joinOrder: number,
}

type EliminationSide = {
	key: string,
	teamId: TeamId?,
	userId: number?,
}

export type ScoreRow = {
	userId: number,
	name: string,
	displayName: string,
	score: number,
	deaths: number,
	roundWins: number,
	participation: Participation,
	teamId: TeamId?,
	roundEligible: boolean,
}

export type TeamRow = {
	teamId: TeamId,
	displayName: string,
	score: number,
	roundWins: number,
	playerCount: number,
	eligiblePlayerCount: number,
}

export type MatchSnapshot = {
	sequence: number,
	modeId: ModeId,
	rulesetId: ModeId,
	displayName: string,
	modeKind: string,
	scoreType: string,
	state: State,
	matchId: string?,
	matchNumber: number,
	round: number,
	roundStatus: RoundStatus,
	serverTime: number,
	stateStartedAt: number,
	stateEndsAt: number?,
	remainingSeconds: number?,
	intermissionQueued: boolean,
	intermissionQualifiedAt: number?,
	intermissionStartsAt: number?,
	scoreLimit: number,
	roundWinLimit: number,
	timeLimitSeconds: number,
	minimumPlayers: number,
	playerCount: number,
	activePlayerCount: number,
	spectatorCount: number,
	soloDevelopmentActive: boolean,
	combatEnabled: boolean,
	scoringEnabled: boolean,
	suddenDeath: boolean,
	respawnDelaySeconds: number,
	forcedRespawnSeconds: number,
	teamMode: boolean,
	friendlyFire: boolean,
	endReason: string?,
	lastRoundEndReason: string?,
	winnerUserIds: { number },
	winnerTeamId: TeamId?,
	winnerTeamIds: { TeamId },
	lastRoundWinnerUserIds: { number },
	lastRoundWinnerTeamId: TeamId?,
	lastRoundWinnerTeamIds: { TeamId },
	activePlayerUserIds: { number },
	spectatorUserIds: { number },
	teamScores: { [string]: number },
	roundWins: { [string]: number },
	teams: { TeamRow },
	scores: { ScoreRow },
	rules: {
		oneShot: boolean,
		deathmatch: boolean,
		duel: boolean,
		captureTheFlag: boolean,
		teamMode: boolean,
		roundBased: boolean,
		friendlyFire: boolean,
		immediateRespawn: boolean,
		respawnDuringLive: boolean,
		forcedRespawnSeconds: number,
		armorEnabled: boolean,
		pickupsEnabled: boolean,
		maximumHealth: number,
		spawnHealth: number,
		spawnArmor: number,
		spawnWeaponId: number,
	},
}

export type SpawnLoadout = {
	health: number,
	maxHealth: number,
	armor: number,
	weaponId: number,
	respawnDelaySeconds: number,
	armorEnabled: boolean,
	pickupsEnabled: boolean,
}

export type EliminationResult = {
	accepted: boolean,
	scored: boolean,
	shouldRespawn: boolean,
	respawnDelaySeconds: number,
	attackerScore: number?,
	victimScore: number?,
	matchEnded: boolean,
	roundEnded: boolean,
	friendlyFire: boolean,
}

export type StagedEliminationReceipt = {
	read result: EliminationResult,
	read outcome: MatchEliminationShadowRules.EliminationOutcome?,
	read damageOpenAfter: boolean,
}

export type PreparedEliminationBatchSummary = {
	read authoritativeFrame: AuthoritativeFrameService.Frame,
	read authoritativeFrameSummary: AuthoritativeFrameService.Summary,
	read baseShadow: MoverEliminationShadow,
	read finalShadow: MoverEliminationShadow,
	read matchId: string?,
	read matchLineage: MatchLineage?,
	read modeId: ModeId,
	read matchState: State,
	read levelTimeMilliseconds: number,
	read baseSequence: number,
	read operationCount: number,
	read outcomes: { MatchEliminationShadowRules.EliminationOutcome },
	read terminal: MatchEliminationShadowRules.TerminalLatch?,
	read damageOpenAfter: boolean,
	read startingIntermissionQueued: boolean,
	read startingSuddenDeath: boolean,
	read finalSuddenDeath: boolean,
}

export type EliminationPublicationReport = {
	read commitSerial: number,
	read phase: "Attributes" | "Observers" | "Combined",
	read operationCount: number,
	read attemptedPublicationCount: number,
	read faultCount: number,
	read faults: { string },
}

export type ObjectiveResult = {
	accepted: boolean,
	matchEnded: boolean,
	teamScore: number,
}

export type SnapshotCallback = (snapshot: MatchSnapshot) -> ()
export type EliminationCallback = (
	victim: Player,
	attacker: Player?,
	means: string,
	result: EliminationResult
) -> ()
export type RespawnCallback = (player: Player, delaySeconds: number) -> ()
export type ModeCallback = (modeId: ModeId, rules: Rules) -> ()
export type LoadingPresentationFailureCallback = (cause: LoadingPresentationFailureCause) -> ()

type EliminationBatchStatus = "Open" | "Sealed" | "Prepared" | "Applied" | "Aborted"

type PlayerRecordSnapshot = {
	player: Player,
	record: PlayerMatchRecord,
	score: number,
	deaths: number,
	roundWins: number,
	eliminatedCurrentLife: boolean,
	roundEligible: boolean,
	participation: Participation,
	teamId: TeamId?,
	joinOrder: number,
	sourceOrder: number?,
}

type EliminationBatchBase = {
	rules: Rules,
	records: { [Player]: PlayerMatchRecord },
	teamScores: { [string]: number },
	teamRoundWins: { [string]: number },
	playerRecords: { PlayerRecordSnapshot },
	state: State,
	currentMatchId: string?,
	currentMatchLineage: MatchLineage?,
	matchNumber: number,
	round: number,
	roundStatus: RoundStatus,
	suddenDeath: boolean,
	suddenDeathBasis: SuddenDeathBasis?,
	sequence: number,
	stateStartedAtMilliseconds: number,
	stateEndsAtMilliseconds: number?,
	endReason: string?,
	lastRoundEndReason: string?,
	winnerUserIds: { number },
	winnerTeamIds: { TeamId },
	lastRoundWinnerUserIds: { number },
	lastRoundWinnerTeamIds: { TeamId },
	lastSnapshotAtMilliseconds: number,
	roundResolutionGeneration: number,
	roundResolutionScheduled: boolean,
	queuedIntermission: MatchFrameRules.IntermissionLatch?,
	redScore: number,
	blueScore: number,
	redRoundWins: number,
	blueRoundWins: number,
}

type StagedElimination = {
	victim: Player,
	attacker: Player?,
	means: string,
	outcome: MatchEliminationShadowRules.EliminationOutcome,
	result: EliminationResult,
	receipt: StagedEliminationReceipt,
}

type EliminationBatch = {
	token: EliminationBatchToken,
	status: EliminationBatchStatus,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	levelTimeMilliseconds: number,
	base: EliminationBatchBase,
	baseShadow: MoverEliminationShadow,
	shadow: MoverEliminationShadow,
	operations: { StagedElimination },
	prepared: PreparedEliminationBatch?,
}

type PlayerRecordMutation = {
	player: Player,
	record: PlayerMatchRecord,
	base: PlayerRecordSnapshot,
	nextScore: number,
	nextDeaths: number,
	nextEliminatedCurrentLife: boolean,
	nextRoundEligible: boolean,
}

type PreparedRoundResolution = {
	generation: number,
	round: number,
	modeId: ModeId,
	reason: string,
}

type RosterIntent = {
	kind: "Add" | "Remove" | "Respawned",
	player: Player,
}

type ModeIntent = {
	modeId: ModeId,
	reason: string,
}

type EliminationPublicationEnvelope = {
	operations: { StagedElimination },
	mutations: { PlayerRecordMutation },
	snapshot: MatchSnapshot,
	stateChanged: boolean,
	roundResolution: PreparedRoundResolution?,
}

type PreparedEliminationCapability = {
	transaction: EliminationBatch,
	status: "Prepared" | "Applied" | "Aborted",
	base: EliminationBatchBase,
	mutations: { PlayerRecordMutation },
	nextRedScore: number,
	nextBlueScore: number,
	nextSuddenDeath: boolean,
	nextSuddenDeathBasis: SuddenDeathBasis?,
	nextStateEndsAt: number?,
	nextEndReason: string?,
	nextQueuedIntermission: MatchFrameRules.IntermissionLatch?,
	nextRoundResolutionGeneration: number,
	nextRoundResolutionScheduled: boolean,
	nextSequence: number,
	nextLastSnapshotAt: number,
	envelope: EliminationPublicationEnvelope,
	summary: PreparedEliminationBatchSummary,
	baseCommitSerial: number,
	nextCommitSerial: number,
	commitReceipt: EliminationBatchCommitReceipt,
	appliedCapability: AppliedEliminationCapability,
	applyValidated: boolean,
}

type AppliedEliminationCapability = {
	status: "Pending" | "Applied" | "AttributesFlushed" | "Flushed",
	commitSerial: number,
	envelope: EliminationPublicationEnvelope,
}

local ACTIVE: Participation = "Active"
local SPECTATOR: Participation = "Spectator"
local TEAM_ORDER: { TeamId } = table.freeze({
	MatchConfig.TeamIds.Red,
	MatchConfig.TeamIds.Blue,
})
local ROUND_SETUP_GRACE_SECONDS = 10

local rules: Rules = MatchConfig.DefaultRuleset
local records: { [Player]: PlayerMatchRecord } = {}
local loadingPresentationReadyPlayers: { [Player]: boolean } = {}
local loadingPresentationFailureCause: LoadingPresentationFailureCause? = nil
local loadingPresentationDeadlineAtClock: number? = nil
local teamScores: { [string]: number } = {
	[MatchConfig.TeamIds.Red] = 0,
	[MatchConfig.TeamIds.Blue] = 0,
}
local teamRoundWins: { [string]: number } = {
	[MatchConfig.TeamIds.Red] = 0,
	[MatchConfig.TeamIds.Blue] = 0,
}

local started = false
local runtimeMap: RuntimeMap? = nil
local state: State = MatchConfig.States.Waiting
local serverInstanceId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)
local currentMatchId: string? = nil
local currentMatchLineage: MatchLineage? = nil
local matchNumber = 0
local matchSerial = 0
local round = 0
local roundStatus: RoundStatus = "Inactive"
local suddenDeath = false
local suddenDeathBasis: SuddenDeathBasis? = nil
local sequence = 0
local nextJoinOrder = 0
local stateStartedAtMilliseconds = 0
local stateEndsAtMilliseconds: number? = nil
local endReason: string? = nil
local lastRoundEndReason: string? = nil
local winnerUserIds: { number } = {}
local winnerTeamIds: { TeamId } = {}
local lastRoundWinnerUserIds: { number } = {}
local lastRoundWinnerTeamIds: { TeamId } = {}
local lastSnapshotAtMilliseconds = 0
local roundResolutionGeneration = 0
local roundResolutionScheduled = false
local liveSetupInProgress = false
local roundSetupDeadlineMilliseconds: number? = nil
local queuedIntermission: MatchFrameRules.IntermissionLatch? = nil
local activeAuthoritativeFrame: AuthoritativeFrameService.Frame? = nil
local activeAuthoritativeFrameSummary: AuthoritativeFrameService.Summary? = nil
local lastProcessedFrameLevelTimeMilliseconds = -1
local lastFrameLevelTimeMilliseconds = 0
local lastFrameServerTimeSeconds = 0
local lifecycleBootstrapped = false
local snapshotDirty = false
local stateChangedDirty = false
local pendingRosterIntents: { RosterIntent } = {}
local pendingModeIntent: ModeIntent? = nil
local pendingRestartReason: string? = nil
local pendingRoundResolution: PreparedRoundResolution? = nil
local pendingFramePublicationCallbacks: { () -> () } = {}
local pendingFramePublicationOwner: AuthoritativeFrameService.Frame? = nil
local publicationQuarantined = false

local eliminationPreparedRegistry = MatchEliminationPreparedRegistry.new()

local snapshotRemote: RemoteEvent

local stateChangedBindable = Instance.new("BindableEvent")
stateChangedBindable.Name = "MatchStateChanged"

local snapshotChangedBindable = Instance.new("BindableEvent")
snapshotChangedBindable.Name = "MatchSnapshotChanged"

local eliminationBindable = Instance.new("BindableEvent")
eliminationBindable.Name = "MatchEliminationRecorded"

local respawnRequestedBindable = Instance.new("BindableEvent")
respawnRequestedBindable.Name = "MatchRespawnRequested"
local synchronousRespawnHandler: RespawnCallback? = nil

local modeChangedBindable = Instance.new("BindableEvent")
modeChangedBindable.Name = "MatchModeChanged"
local authorityStateCallbacks: { SnapshotCallback } = {}
local authorityModeCallbacks: { ModeCallback } = {}
local authorityEliminationCallbacks: { EliminationCallback } = {}
local loadingPresentationFailureCallbacks: { LoadingPresentationFailureCallback } = {}

local function notifyAuthorityState(snapshot: MatchSnapshot)
	for _, callback in authorityStateCallbacks do
		callback(snapshot)
	end
end

local function notifyAuthorityMode(modeId: ModeId, nextRules: Rules)
	for _, callback in authorityModeCallbacks do
		callback(modeId, nextRules)
	end
end

local function notifyAuthorityElimination(victim: Player, attacker: Player?, means: string, result: EliminationResult)
	for _, callback in authorityEliminationCallbacks do
		callback(victim, attacker, means, result)
	end
end

local function notifyLoadingPresentationFailure(cause: LoadingPresentationFailureCause)
	for _, callback in loadingPresentationFailureCallbacks do
		local succeeded, callbackError = pcall(callback, cause)
		if not succeeded then
			warn(string.format("Loading-presentation failure callback failed: %s", tostring(callbackError)))
		end
	end
end

local function publishOutward(callback: () -> ())
	assert(not publicationQuarantined, "Match outward publication is permanently quarantined")
	if activeAuthoritativeFrame ~= nil then
		table.insert(pendingFramePublicationCallbacks, callback)
	else
		callback()
	end
end

local function invalidatePendingRoundResolution()
	roundResolutionGeneration += 1
	roundResolutionScheduled = false
	pendingRoundResolution = nil
end

local function isNonnegativeInteger(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= 0
		and value <= MatchEliminationShadowRules.MaximumLevelTimeMilliseconds
end

local function activeLevelTimeMilliseconds(): number
	local summary = assert(activeAuthoritativeFrameSummary, "Match authority requires an open authoritative frame")
	return summary.currentTimeMilliseconds
end

local function currentPresentationBasis(): (number, number)
	local summary = activeAuthoritativeFrameSummary
	if summary then
		return summary.currentTimeMilliseconds, summary.currentServerTimeSeconds
	end
	return lastFrameLevelTimeMilliseconds, lastFrameServerTimeSeconds
end

local function presentationTimeForLevel(levelTimeMilliseconds: number): number
	local basisLevelTime, basisServerTime = currentPresentationBasis()
	return assert(
		MatchFrameRules.PresentationTimeForLevel(basisLevelTime, basisServerTime, levelTimeMilliseconds),
		"Match level time could not map to presentation time"
	)
end

local function durationMilliseconds(seconds: number): number
	return assert(
		MatchFrameRules.DurationMilliseconds(seconds),
		"Match duration must resolve to exact bounded integer milliseconds"
	)
end

local function deadlineMilliseconds(startMilliseconds: number, durationSeconds: number): number
	return assert(
		MatchFrameRules.DeadlineMilliseconds(startMilliseconds, durationSeconds),
		"Match deadline exceeded the authoritative integer clock"
	)
end

local function terminalLatchEqual(
	left: MatchEliminationShadowRules.TerminalLatch?,
	right: MatchEliminationShadowRules.TerminalLatch?
): boolean
	if left == right then
		return true
	end
	if not left or not right then
		return false
	end
	return left.reason == right.reason
		and left.operationOrder == right.operationOrder
		and left.qualifiedAtMilliseconds == right.qualifiedAtMilliseconds
		and left.startsAtMilliseconds == right.startsAtMilliseconds
		and left.qualifiedByUserId == right.qualifiedByUserId
		and left.qualifiedByTeamId == right.qualifiedByTeamId
		and left.winnerUserId == right.winnerUserId
		and left.winnerTeamId == right.winnerTeamId
end

local function eliminationShadowEqual(left: MoverEliminationShadow, right: MoverEliminationShadow): boolean
	if
		left.scoreKind ~= right.scoreKind
		or left.scoreLimit ~= right.scoreLimit
		or left.timeLimitAtMilliseconds ~= right.timeLimitAtMilliseconds
		or left.scoringEnabled ~= right.scoringEnabled
		or left.friendlyFire ~= right.friendlyFire
		or left.levelTimeMilliseconds ~= right.levelTimeMilliseconds
		or left.lastOperationOrder ~= right.lastOperationOrder
		or left.redScore ~= right.redScore
		or left.blueScore ~= right.blueScore
		or #left.players ~= #right.players
		or not terminalLatchEqual(left.terminal, right.terminal)
	then
		return false
	end
	for index, leftPlayer in left.players do
		local rightPlayer = right.players[index]
		if
			not rightPlayer
			or leftPlayer.sourceOrder ~= rightPlayer.sourceOrder
			or leftPlayer.userId ~= rightPlayer.userId
			or leftPlayer.teamId ~= rightPlayer.teamId
			or leftPlayer.score ~= rightPlayer.score
			or leftPlayer.deaths ~= rightPlayer.deaths
			or leftPlayer.eliminatedCurrentLife ~= rightPlayer.eliminatedCurrentLife
		then
			return false
		end
	end
	return true
end

local function ensureNetworkFolder(): Folder
	local existing = sharedRoot:FindFirstChild(RemoteNames.Folder)
	if existing then
		assert(existing:IsA("Folder"), string.format("%s must be a Folder", RemoteNames.Folder))
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = RemoteNames.Folder
	folder.Parent = sharedRoot
	return folder
end

local function ensureRemote(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), string.format("%s must be a RemoteEvent", name))
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function isSoloDevelopmentActive(): boolean
	return rules.AllowSoloInStudio and RunService:IsStudio() and MatchRosterRuntime.GetActivePlayerCount(records) == 1
end

local function hasEnoughPlayers(): boolean
	local activeCount = MatchRosterRuntime.GetActivePlayerCount(records)
	if rules.AllowSoloInStudio and RunService:IsStudio() and activeCount >= 1 then
		return true
	end
	if activeCount < rules.MinimumPlayers then
		return false
	end
	if rules.TeamMode then
		return MatchRosterRuntime.GetTeamPlayerCount(records, MatchConfig.TeamIds.Red, false) > 0
			and MatchRosterRuntime.GetTeamPlayerCount(records, MatchConfig.TeamIds.Blue, false) > 0
	end
	return true
end

local function isCombatEnabled(): boolean
	return MatchRulesCore.IsTerminalGameplayOpen(queuedIntermission) and rules.CombatStates[state] == true
end

local function isScoringEnabled(): boolean
	return MatchRulesCore.IsTerminalGameplayOpen(queuedIntermission) and rules.ScoringStates[state] == true
end

local function getRecordRoundWins(record: PlayerMatchRecord): number
	local teamId = record.teamId
	if rules.TeamMode and teamId then
		return teamRoundWins[teamId] or 0
	end
	return record.roundWins
end

local function syncPlayerAttributes(player: Player)
	local record = records[player]
	if not record then
		return
	end

	local isActive = record.participation == ACTIVE
	local participation = record.participation
	local teamId = record.teamId
	local roundEligible = isActive and record.roundEligible
	local score = record.score
	local deaths = record.deaths
	local roundWins = getRecordRoundWins(record)
	publishOutward(function()
		player:SetAttribute("ArenaMatchParticipant", isActive)
		player:SetAttribute("ArenaMatchParticipation", participation)
		player:SetAttribute("ArenaMatchSpectator", not isActive)
		player:SetAttribute("ArenaMatchTeam", teamId)
		player:SetAttribute("ArenaMatchRoundEligible", roundEligible)
		player:SetAttribute("ArenaMatchScore", score)
		player:SetAttribute("ArenaMatchDeaths", deaths)
		player:SetAttribute("ArenaMatchRoundWins", roundWins)
	end)
end

local function syncAllPlayerAttributes()
	for player in records do
		syncPlayerAttributes(player)
	end
end

local function resetRosterForMode()
	local ordered = MatchRosterRuntime.GetOrderedPlayers(records)
	for index, player in ordered do
		local record = records[player]
		local isActive = rules.ActivePlayerLimit == 0 or index <= rules.ActivePlayerLimit
		record.participation = if isActive then ACTIVE else SPECTATOR
		record.teamId = nil
		record.roundEligible = isActive
		record.eliminatedCurrentLife = false
	end

	if rules.TeamMode then
		local teamIndex = 1
		for _, player in ordered do
			local record = records[player]
			if record.participation == ACTIVE then
				record.teamId = TEAM_ORDER[teamIndex]
				teamIndex = if teamIndex == #TEAM_ORDER then 1 else teamIndex + 1
			end
		end
	end
	syncAllPlayerAttributes()
end

local function prepareRosterForMatch()
	local ordered = MatchRosterRuntime.GetOrderedPlayers(records)
	if rules.Deathmatch then
		MatchRosterRuntime.ApplyDeathmatchActiveLimit(records, rules.ActivePlayerLimit)
	elseif rules.Duel then
		local activeCount = 0
		for _, player in ordered do
			local record = records[player]
			if record.participation == ACTIVE and activeCount < rules.ActivePlayerLimit then
				activeCount += 1
			else
				record.participation = SPECTATOR
			end
			record.teamId = nil
		end
		if activeCount < rules.ActivePlayerLimit then
			for _, player in ordered do
				local record = records[player]
				if record.participation == SPECTATOR then
					record.participation = ACTIVE
					activeCount += 1
					if activeCount >= rules.ActivePlayerLimit then
						break
					end
				end
			end
		end
	else
		for _, player in ordered do
			records[player].participation = ACTIVE
		end
	end

	if rules.TeamMode then
		local teamIndex = 1
		for _, player in ordered do
			local record = records[player]
			if record.participation == ACTIVE then
				record.teamId = TEAM_ORDER[teamIndex]
				teamIndex = if teamIndex == #TEAM_ORDER then 1 else teamIndex + 1
			else
				record.teamId = nil
			end
		end
	else
		for _, player in ordered do
			records[player].teamId = nil
		end
	end

	for _, player in ordered do
		local record = records[player]
		record.roundEligible = record.participation == ACTIVE
		record.eliminatedCurrentLife = false
	end
	syncAllPlayerAttributes()
end

local function resetFragScores()
	teamScores[MatchConfig.TeamIds.Red] = 0
	teamScores[MatchConfig.TeamIds.Blue] = 0
	for player, record in records do
		record.score = 0
		record.deaths = 0
		syncPlayerAttributes(player)
	end
end

local function resetMatchProgress()
	resetFragScores()
	teamRoundWins[MatchConfig.TeamIds.Red] = 0
	teamRoundWins[MatchConfig.TeamIds.Blue] = 0
	for player, record in records do
		record.roundWins = 0
		record.eliminatedCurrentLife = false
		record.roundEligible = record.participation == ACTIVE
		syncPlayerAttributes(player)
	end
	lastRoundEndReason = nil
	lastRoundWinnerUserIds = {}
	lastRoundWinnerTeamIds = {}
end

local function prepareRoundEligibility()
	for player, record in records do
		record.roundEligible = record.participation == ACTIVE
		record.eliminatedCurrentLife = false
		syncPlayerAttributes(player)
	end
end

local function prepareRoundSetup()
	for player, record in records do
		if record.participation == ACTIVE then
			record.roundEligible = false
			syncPlayerAttributes(player)
		end
	end
end

local function activeRoundBodiesReady(): boolean
	for player, record in records do
		if record.participation ~= ACTIVE then
			continue
		end
		local character = player.Character
		local lifeSequence = player:GetAttribute("ArenaLifeSequence")
		if
			player.Parent ~= Players
			or not character
			or not character.Parent
			or player:GetAttribute("ArenaAlive") ~= true
			or type(lifeSequence) ~= "number"
			or lifeSequence <= 0
		then
			return false
		end
	end
	return true
end

-- Q3's CheckTournament keeps the level in warmup until all playing clients
-- have arrived, then publishes one fresh countdown deadline. A Roblox client
-- can acknowledge only its own presentation boundary; this server-owned set
-- combines that advisory arrival signal with authoritative admission, roster,
-- Character, alive-state, and life-sequence checks.
local function allActiveLoadingPresentationsReady(): boolean
	for player, record in records do
		if record.participation ~= ACTIVE then
			continue
		end
		if
			player:GetAttribute("ArenaAdmissionState") ~= "Admitted"
			or loadingPresentationReadyPlayers[player] ~= true
		then
			return false
		end
	end
	return true
end

local function activePlayersReadyForInitialCountdown(): boolean
	return loadingPresentationFailureCause == nil and allActiveLoadingPresentationsReady() and activeRoundBodiesReady()
end

local function markLoadingPresentationReady(player: Player, payload: unknown)
	if
		payload ~= nil
		or loadingPresentationFailureCause ~= nil
		or player.Parent ~= Players
		or player:GetAttribute("ArenaAdmissionState") ~= "Admitted"
	then
		return
	end
	loadingPresentationReadyPlayers[player] = true
	player:SetAttribute("ArenaLoadingPresentationState", "Ready")
end

local function latchLoadingPresentationFailure(cause: LoadingPresentationFailureCause): boolean
	if loadingPresentationFailureCause ~= nil then
		return false
	end
	loadingPresentationFailureCause = cause
	loadingPresentationDeadlineAtClock = nil
	game:SetAttribute("Q3EngineLoadingPresentationFailure", cause)
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("ArenaAdmissionState") == "Admitted" then
			player:SetAttribute("ArenaLoadingPresentationState", "Failed")
		end
	end
	notifyLoadingPresentationFailure(cause)
	return true
end

local function markLoadingPresentationFailed(player: Player, payload: unknown)
	if
		payload ~= nil
		or player.Parent ~= Players
		or player:GetAttribute("ArenaAdmissionState") ~= "Admitted"
		or (
			state ~= MatchConfig.States.Waiting
			and state ~= MatchConfig.States.Warmup
			and state ~= MatchConfig.States.Countdown
		)
	then
		return
	end
	latchLoadingPresentationFailure("MapPresentationFailed")
end

local function startLoadingPresentationWatchdog()
	task.spawn(function()
		while started and loadingPresentationFailureCause == nil do
			local deadlineAt = loadingPresentationDeadlineAtClock
			if deadlineAt ~= nil then
				if allActiveLoadingPresentationsReady() then
					loadingPresentationDeadlineAtClock = nil
				elseif os.clock() >= deadlineAt then
					latchLoadingPresentationFailure("MapPresentationTimedOut")
					return
				end
			end
			task.wait(0.25)
		end
	end)
end

local function requestRespawn(player: Player, delaySeconds: number)
	local handler = synchronousRespawnHandler
	if handler then
		handler(player, delaySeconds)
	end
	publishOutward(function()
		respawnRequestedBindable:Fire(player, delaySeconds)
	end)
end

local function requestActiveRespawns(delaySeconds: number)
	for _, player in MatchRosterRuntime.GetSourceOrderedPlayers(records, EntitySlotService.GetPlayerSourceOrder) do
		local record = records[player]
		if
			record.participation == ACTIVE
			and (not rules.RoundBased or state ~= MatchConfig.States.Live or record.roundEligible)
		then
			requestRespawn(player, delaySeconds)
		end
	end
end

local function canPlayerFightInternal(player: Player): boolean
	local record = records[player]
	if not record or record.participation ~= ACTIVE or record.eliminatedCurrentLife or not isCombatEnabled() then
		return false
	end
	return not rules.RoundBased or state ~= MatchConfig.States.Live or record.roundEligible
end

local function findPlayerLeaders(): { number }
	local leaders: { number } = {}
	local leadingScore: number? = nil
	for _, row in
		MatchStandingsRuntime.BuildScoreRows(
			MatchRosterRuntime.GetOrderedPlayers(records),
			records :: any,
			rules,
			teamRoundWins,
			ACTIVE
		)
	do
		if row.participation ~= ACTIVE then
			continue
		end
		if leadingScore == nil then
			leadingScore = row.score
		end
		if row.score ~= leadingScore then
			break
		end
		table.insert(leaders, row.userId)
	end
	return leaders
end

local function findTeamLeaders(metric: { [string]: number }): { TeamId }
	local leaders: { TeamId } = {}
	local leadingScore: number? = nil
	for _, teamId in TEAM_ORDER do
		if MatchRosterRuntime.GetTeamPlayerCount(records, teamId, false) == 0 then
			continue
		end
		local score = metric[teamId] or 0
		if leadingScore == nil or score > leadingScore then
			leadingScore = score
			leaders = { teamId }
		elseif score == leadingScore then
			table.insert(leaders, teamId)
		end
	end
	return leaders
end

local function getUserIdsForTeams(teamIds: { TeamId }): { number }
	local included: { [string]: boolean } = {}
	for _, teamId in teamIds do
		included[teamId] = true
	end
	local userIds: { number } = {}
	for _, player in MatchRosterRuntime.GetOrderedPlayers(records) do
		local record = records[player]
		if record.participation == ACTIVE and record.teamId and included[record.teamId] then
			table.insert(userIds, player.UserId)
		end
	end
	return userIds
end

local function resolveMatchWinners(): ({ number }, { TeamId })
	if rules.TeamMode then
		local leaders = if rules.ScoreType == "RoundWins"
			then findTeamLeaders(teamRoundWins)
			else findTeamLeaders(teamScores)
		return getUserIdsForTeams(leaders), leaders
	end
	return findPlayerLeaders(), {}
end

local function resolveUniqueLeader(): (boolean, { number }, { TeamId })
	local users, teams = resolveMatchWinners()
	local unique = if rules.TeamMode then #teams == 1 else #users == 1
	return unique, users, teams
end

local function collectScoreLimitValues(): { number }
	local values: { number } = {}
	if rules.TeamMode then
		local metric = if rules.ScoreType == "RoundWins" then teamRoundWins else teamScores
		for _, teamId in TEAM_ORDER do
			table.insert(values, metric[teamId] or 0)
		end
	else
		for _, player in MatchRosterRuntime.GetOrderedPlayers(records) do
			local record = records[player]
			if record.participation == ACTIVE then
				table.insert(values, if rules.ScoreType == "RoundWins" then record.roundWins else record.score)
			end
		end
	end
	return values
end

local function resolveConfiguredScoreLimitState(limit: number): MatchRulesCore.ScoreLimitState
	return MatchRulesCore.ResolveScoreLimitState(
		collectScoreLimitValues(),
		limit,
		MatchRosterRuntime.GetActivePlayerCount(records)
	)
end

local function rotateDuelRosterAfterMatch()
	if not rules.Duel or #winnerUserIds ~= 1 then
		return
	end

	local winningUserId = winnerUserIds[1]
	local loserUserId, promotedUserId =
		MatchRulesCore.ResolveDuelRotation(MatchRosterRuntime.BuildRulesRoster(records), winningUserId)
	local loser = if loserUserId then Players:GetPlayerByUserId(loserUserId) else nil
	local oldestSpectator = if promotedUserId then Players:GetPlayerByUserId(promotedUserId) else nil

	-- With no waiting spectator, the current pair rematches. A forfeit can also leave no
	-- connected loser; normal roster preparation fills that vacancy on the next match.
	if not loser or not oldestSpectator then
		return
	end

	local loserRecord = records[loser]
	local promotedRecord = records[oldestSpectator]
	loserRecord.participation = SPECTATOR
	loserRecord.roundEligible = false
	nextJoinOrder += 1
	loserRecord.joinOrder = nextJoinOrder
	promotedRecord.participation = ACTIVE
	promotedRecord.roundEligible = true
	promotedRecord.eliminatedCurrentLife = false
	syncPlayerAttributes(loser)
	syncPlayerAttributes(oldestSpectator)
end

local function buildSnapshot(): MatchSnapshot
	local currentLevelTimeMilliseconds, serverTime = currentPresentationBasis()
	local remainingSeconds = if stateEndsAtMilliseconds
		then assert(MatchFrameRules.RemainingSeconds(stateEndsAtMilliseconds, currentLevelTimeMilliseconds))
		else nil
	local orderedPlayers = MatchRosterRuntime.GetOrderedPlayers(records)
	local activeUserIds = MatchStandingsRuntime.BuildParticipationUserIds(orderedPlayers, records :: any, ACTIVE)
	local spectatorUserIds = MatchStandingsRuntime.BuildParticipationUserIds(orderedPlayers, records :: any, SPECTATOR)

	return {
		sequence = sequence,
		modeId = rules.ModeId,
		rulesetId = rules.RulesetId,
		displayName = rules.DisplayName,
		modeKind = rules.ModeKind,
		scoreType = rules.ScoreType,
		state = state,
		matchId = currentMatchId,
		matchNumber = matchNumber,
		round = round,
		roundStatus = roundStatus,
		serverTime = serverTime,
		stateStartedAt = presentationTimeForLevel(stateStartedAtMilliseconds),
		stateEndsAt = if stateEndsAtMilliseconds then presentationTimeForLevel(stateEndsAtMilliseconds) else nil,
		remainingSeconds = remainingSeconds,
		intermissionQueued = queuedIntermission ~= nil,
		intermissionQualifiedAt = if queuedIntermission
			then presentationTimeForLevel(queuedIntermission.qualifiedAtMilliseconds)
			else nil,
		intermissionStartsAt = if queuedIntermission
			then presentationTimeForLevel(queuedIntermission.startsAtMilliseconds)
			else nil,
		scoreLimit = rules.ScoreLimit,
		roundWinLimit = rules.RoundWinLimit,
		timeLimitSeconds = rules.TimeLimitSeconds,
		minimumPlayers = rules.MinimumPlayers,
		playerCount = MatchRosterRuntime.GetPlayerCount(records),
		activePlayerCount = #activeUserIds,
		spectatorCount = #spectatorUserIds,
		soloDevelopmentActive = isSoloDevelopmentActive(),
		combatEnabled = isCombatEnabled(),
		scoringEnabled = isScoringEnabled(),
		suddenDeath = suddenDeath,
		respawnDelaySeconds = rules.RespawnDelaySeconds,
		forcedRespawnSeconds = rules.ForcedRespawnSeconds,
		teamMode = rules.TeamMode,
		friendlyFire = rules.FriendlyFire,
		endReason = endReason,
		lastRoundEndReason = lastRoundEndReason,
		winnerUserIds = table.clone(winnerUserIds),
		winnerTeamId = if #winnerTeamIds == 1 then winnerTeamIds[1] else nil,
		winnerTeamIds = table.clone(winnerTeamIds),
		lastRoundWinnerUserIds = table.clone(lastRoundWinnerUserIds),
		lastRoundWinnerTeamId = if #lastRoundWinnerTeamIds == 1 then lastRoundWinnerTeamIds[1] else nil,
		lastRoundWinnerTeamIds = table.clone(lastRoundWinnerTeamIds),
		activePlayerUserIds = activeUserIds,
		spectatorUserIds = spectatorUserIds,
		teamScores = MatchStandingsRuntime.CloneNumberMap(teamScores),
		roundWins = MatchStandingsRuntime.CloneNumberMap(teamRoundWins),
		teams = MatchStandingsRuntime.BuildTeamRows(
			TEAM_ORDER,
			records :: any,
			rules,
			teamScores,
			teamRoundWins,
			ACTIVE
		),
		scores = MatchStandingsRuntime.BuildScoreRows(orderedPlayers, records :: any, rules, teamRoundWins, ACTIVE),
		rules = {
			oneShot = rules.OneShot,
			deathmatch = rules.Deathmatch,
			duel = rules.Duel,
			captureTheFlag = rules.CaptureTheFlag,
			teamMode = rules.TeamMode,
			roundBased = rules.RoundBased,
			friendlyFire = rules.FriendlyFire,
			immediateRespawn = rules.ImmediateRespawn,
			respawnDuringLive = rules.RespawnDuringLive,
			forcedRespawnSeconds = rules.ForcedRespawnSeconds,
			armorEnabled = rules.ArmorEnabled,
			pickupsEnabled = rules.PickupsEnabled,
			maximumHealth = rules.MaximumHealth,
			spawnHealth = rules.SpawnHealth,
			spawnArmor = rules.SpawnArmor,
			spawnWeaponId = rules.SpawnWeaponId,
		},
	}
end

local function publishSnapshot(): MatchSnapshot
	sequence += 1
	local snapshot = buildSnapshot()
	lastSnapshotAtMilliseconds = select(1, currentPresentationBasis())
	snapshotDirty = false

	publishOutward(function()
		sharedRoot:SetAttribute("ArenaMatchState", snapshot.state)
		sharedRoot:SetAttribute("ArenaMatchId", snapshot.matchId)
		sharedRoot:SetAttribute("ArenaMatchSequence", snapshot.sequence)
		sharedRoot:SetAttribute("ArenaMatchMode", snapshot.modeId)
		sharedRoot:SetAttribute("ArenaMatchRuleset", snapshot.rulesetId)
		sharedRoot:SetAttribute("ArenaMatchNumber", snapshot.matchNumber)
		sharedRoot:SetAttribute("ArenaMatchRound", snapshot.round)
		sharedRoot:SetAttribute("ArenaMatchRoundStatus", snapshot.roundStatus)
		sharedRoot:SetAttribute("ArenaMatchSuddenDeath", snapshot.suddenDeath)
		sharedRoot:SetAttribute("ArenaMatchStateEndsAt", snapshot.stateEndsAt)
		sharedRoot:SetAttribute("ArenaMatchIntermissionQueued", snapshot.intermissionQueued)
		sharedRoot:SetAttribute("ArenaMatchIntermissionStartsAt", snapshot.intermissionStartsAt)
		sharedRoot:SetAttribute("ArenaMatchWinnerTeam", snapshot.winnerTeamId)
		sharedRoot:SetAttribute("ArenaMatchRedScore", teamScores[MatchConfig.TeamIds.Red] or 0)
		sharedRoot:SetAttribute("ArenaMatchBlueScore", teamScores[MatchConfig.TeamIds.Blue] or 0)
		sharedRoot:SetAttribute("ArenaMatchRedRoundWins", teamRoundWins[MatchConfig.TeamIds.Red] or 0)
		sharedRoot:SetAttribute("ArenaMatchBlueRoundWins", teamRoundWins[MatchConfig.TeamIds.Blue] or 0)
		snapshotRemote:FireAllClients(snapshot)
		snapshotChangedBindable:Fire(snapshot)
	end)
	return snapshot
end

local function transition(nextState: State, durationSeconds: number?, reason: string?, beforePublish: (() -> ())?)
	invalidatePendingRoundResolution()
	queuedIntermission = nil
	state = nextState
	stateStartedAtMilliseconds = activeLevelTimeMilliseconds()
	stateEndsAtMilliseconds = if durationSeconds
		then deadlineMilliseconds(stateStartedAtMilliseconds, durationSeconds)
		else nil
	endReason = reason
	if beforePublish then
		beforePublish()
	end

	local snapshot = publishSnapshot()
	notifyAuthorityState(snapshot)
	publishOutward(function()
		stateChangedBindable:Fire(snapshot)
	end)
	stateChangedDirty = false
end

local function enterWaiting(reason: string?)
	suddenDeath = false
	suddenDeathBasis = nil
	roundSetupDeadlineMilliseconds = nil
	currentMatchId = nil
	currentMatchLineage = nil
	winnerUserIds = {}
	winnerTeamIds = {}
	roundStatus = "Inactive"
	loadingPresentationDeadlineAtClock = nil
	resetMatchProgress()
	transition(MatchConfig.States.Waiting, nil, reason)
end

local function enterWarmup()
	suddenDeath = false
	suddenDeathBasis = nil
	roundSetupDeadlineMilliseconds = nil
	prepareRosterForMatch()
	matchNumber += 1
	matchSerial += 1
	currentMatchId = string.format("%s:%d:%s", serverInstanceId, matchSerial, rules.ModeId)
	currentMatchLineage = table.freeze({})
	round = if rules.RoundBased then 1 else matchNumber
	winnerUserIds = {}
	winnerTeamIds = {}
	resetMatchProgress()
	roundStatus = if rules.RoundBased then "Preparing" else "Inactive"
	loadingPresentationDeadlineAtClock = os.clock() + MatchService.LoadingPresentationTimeoutSeconds
	transition(MatchConfig.States.Warmup, rules.WarmupSeconds, nil)
	requestActiveRespawns(0)
end

local function enterCountdown(nextRound: boolean, advanceRound: boolean?)
	loadingPresentationDeadlineAtClock = nil
	suddenDeath = false
	suddenDeathBasis = nil
	if rules.RoundBased then
		if nextRound and advanceRound ~= false then
			round += 1
		end
		prepareRoundSetup()
		roundStatus = "Preparing"
	else
		resetFragScores()
		roundStatus = "Inactive"
	end
	local duration = assert(
		RocketArenaRoundTimingRules.GetCountdownDuration(rules, rules.RoundBased and nextRound),
		"configured Match countdown duration is invalid"
	)
	transition(MatchConfig.States.Countdown, duration, nil, function()
		if rules.RoundBased then
			roundSetupDeadlineMilliseconds =
				deadlineMilliseconds(stateStartedAtMilliseconds, duration + ROUND_SETUP_GRACE_SECONDS)
			liveSetupInProgress = true
			requestActiveRespawns(0)
			liveSetupInProgress = false
		end
	end)
end

local function enterRoundOver()
	suddenDeath = false
	suddenDeathBasis = nil
	roundSetupDeadlineMilliseconds = nil
	roundStatus = "Resolved"
	local duration = assert(
		RocketArenaRoundTimingRules.GetRoundOverDuration(rules),
		"configured Match round-over duration is invalid"
	)
	transition(MatchConfig.States.Countdown, duration, nil)
end

local function enterLive()
	suddenDeath = false
	suddenDeathBasis = nil
	roundSetupDeadlineMilliseconds = nil
	if rules.RoundBased then
		roundStatus = "Live"
	else
		resetFragScores()
		roundStatus = "Inactive"
	end
	transition(MatchConfig.States.Live, rules.TimeLimitSeconds, nil, function()
		if rules.RoundBased then
			prepareRoundEligibility()
		else
			liveSetupInProgress = true
			requestActiveRespawns(0)
			liveSetupInProgress = false
		end
	end)
end

local function enterIntermission(reason: string, explicitWinnerUserIds: { number }?, explicitWinnerTeamIds: { TeamId }?)
	suddenDeath = false
	suddenDeathBasis = nil
	roundSetupDeadlineMilliseconds = nil
	if explicitWinnerUserIds and explicitWinnerTeamIds then
		winnerUserIds = table.clone(explicitWinnerUserIds)
		winnerTeamIds = table.clone(explicitWinnerTeamIds)
	else
		winnerUserIds, winnerTeamIds = resolveMatchWinners()
	end
	rotateDuelRosterAfterMatch()
	if rules.RoundBased then
		roundStatus = "Resolved"
	end
	transition(MatchConfig.States.Intermission, rules.IntermissionSeconds, reason)
end

-- Q3 LogExit latches the terminal result and sets level.intermissionQueued.
-- G_Damage then rejects further damage while CheckExitRules waits the canonical
-- one-second INTERMISSION_DELAY_TIME before BeginIntermission. Publishing this
-- snapshot is held until the explicit frame publication phase so the terminal
-- Damage/Elimination or FlagEvent is emitted first.
local function queueIntermission(
	reason: string,
	explicitWinnerUserIds: { number }?,
	explicitWinnerTeamIds: { TeamId }?,
	qualifiedAtMilliseconds: number?
): boolean
	local users = explicitWinnerUserIds
	local teams = explicitWinnerTeamIds
	if not users or not teams then
		users, teams = resolveMatchWinners()
	end

	local latch, created, latchError = MatchFrameRules.CreateIntermissionLatch(
		queuedIntermission,
		qualifiedAtMilliseconds or activeLevelTimeMilliseconds(),
		reason,
		users,
		teams :: any
	)
	assert(latch, latchError or "unable to create integer Match intermission latch")
	if not created then
		return false
	end

	queuedIntermission = latch
	stateEndsAtMilliseconds = nil
	endReason = reason
	invalidatePendingRoundResolution()
	snapshotDirty = true
	return true
end

local function restart(reason: string?)
	prepareRosterForMatch()
	if hasEnoughPlayers() then
		enterWarmup()
	else
		enterWaiting(reason or "NotEnoughPlayers")
	end
end

local function enterSuddenDeath(basis: SuddenDeathBasis)
	suddenDeath = true
	suddenDeathBasis = basis
	stateEndsAtMilliseconds = nil
	endReason = "SuddenDeath"
	snapshotDirty = true
	stateChangedDirty = true
end

-- Q3 CalculateRanks updates numPlayingClients before CheckExitRules runs again.
-- If a departure removes one side of an FFA tie, the remaining leader therefore
-- qualifies without waiting for another frag. Team score buckets do not change
-- when one teammate leaves, and a missing team is handled by the forfeit branch
-- before this check.
local function requalifySuddenDeathAfterRosterMutation(): boolean
	if state ~= MatchConfig.States.Live or rules.RoundBased or not suddenDeath then
		return false
	end
	local basis = suddenDeathBasis
	if
		not basis
		or not MatchRulesCore.ShouldQualifySuddenDeathAfterRosterMutation(
			basis,
			collectScoreLimitValues(),
			rules.ScoreLimit,
			MatchRosterRuntime.GetActivePlayerCount(records)
		)
	then
		return false
	end

	local unique, users, teams = resolveUniqueLeader()
	if not unique then
		return false
	end
	return queueIntermission(
		if basis == MatchRulesCore.SuddenDeathBases.TimeLimit then "TimeLimit" else "SuddenDeath",
		users,
		teams
	)
end

local function collectSides(eligibleOnly: boolean): { EliminationSide }
	return MatchRulesCore.CollectEliminationSides(
		MatchRosterRuntime.BuildRulesRoster(records),
		rules.TeamMode,
		eligibleOnly
	) :: any
end

local function getSideWinnerIds(sides: { EliminationSide }): ({ number }, { TeamId })
	local users: { number } = {}
	local teams: { TeamId } = {}
	for _, side in sides do
		if side.teamId then
			table.insert(teams, side.teamId)
		elseif side.userId then
			table.insert(users, side.userId)
		end
	end
	if #teams > 0 then
		users = getUserIdsForTeams(teams)
	end
	return users, teams
end

local function finishEliminationRound(sides: { EliminationSide }, reason: string)
	lastRoundEndReason = reason
	lastRoundWinnerUserIds, lastRoundWinnerTeamIds = getSideWinnerIds(sides)

	-- RA3 remains in ROUND_OVER before either ending the match or respawning
	-- into ROUND_COUNTDOWN_ROUND. roundStatus closes combat while retaining the
	-- existing public Countdown state used by current clients.
	enterRoundOver()
end

local function awardResolvedRound()
	if #lastRoundWinnerTeamIds == 1 then
		local teamId = lastRoundWinnerTeamIds[1]
		teamRoundWins[teamId] = (teamRoundWins[teamId] or 0) + 1
	elseif #lastRoundWinnerTeamIds == 0 and #lastRoundWinnerUserIds == 1 then
		local winnerUserId = lastRoundWinnerUserIds[1]
		for player, record in records do
			if player.UserId == winnerUserId then
				record.roundWins += 1
				syncPlayerAttributes(player)
				break
			end
		end
	end
	syncAllPlayerAttributes()
end

local function runEliminationRoundResolution(
	generation: number,
	scheduledRound: number,
	scheduledMode: ModeId,
	reason: string
)
	if generation ~= roundResolutionGeneration then
		return
	end
	roundResolutionScheduled = false
	if
		state ~= MatchConfig.States.Live
		or not rules.RoundBased
		or round ~= scheduledRound
		or rules.ModeId ~= scheduledMode
	then
		return
	end

	local finalSides = collectSides(true)
	if #finalSides <= 1 then
		finishEliminationRound(finalSides, if #finalSides == 0 then "Draw" else reason)
	end
end

local function scheduleEliminationRoundResolution(reason: string)
	if roundResolutionScheduled then
		return
	end

	roundResolutionScheduled = true
	pendingRoundResolution = table.freeze({
		generation = roundResolutionGeneration,
		round = round,
		modeId = rules.ModeId,
		reason = reason,
	})
end

local function enterForfeitIntermission()
	local remainingSides = collectSides(false)
	local users, teams = getSideWinnerIds(remainingSides)
	if #remainingSides == 1 and rules.RoundBased then
		lastRoundEndReason = "Forfeit"
		lastRoundWinnerUserIds = table.clone(users)
		lastRoundWinnerTeamIds = table.clone(teams)
		local side = remainingSides[1]
		if side.teamId then
			teamRoundWins[side.teamId] = (teamRoundWins[side.teamId] or 0) + 1
		elseif side.userId then
			for player, record in records do
				if player.UserId == side.userId then
					record.roundWins += 1
					break
				end
			end
		end
		syncAllPlayerAttributes()
	end
	if #remainingSides == 1 then
		queueIntermission("Forfeit", users, teams)
	else
		queueIntermission("NotEnoughPlayers")
	end
end

local function advanceLifecycle()
	if loadingPresentationFailureCause ~= nil then
		return
	end
	local nowMilliseconds = activeLevelTimeMilliseconds()
	local terminal = queuedIntermission
	if terminal then
		if MatchFrameRules.IsIntermissionLatchDue(terminal, nowMilliseconds) then
			enterIntermission(terminal.reason, terminal.winnerUserIds, terminal.winnerTeamIds :: any)
		end
		return
	end

	if state == MatchConfig.States.Waiting then
		if hasEnoughPlayers() then
			enterWarmup()
		end
		return
	end

	if (state == MatchConfig.States.Warmup or state == MatchConfig.States.Countdown) and not hasEnoughPlayers() then
		enterWaiting("NotEnoughPlayers")
		return
	end

	if state == MatchConfig.States.Live and not hasEnoughPlayers() then
		enterForfeitIntermission()
		return
	end
	if requalifySuddenDeathAfterRosterMutation() then
		return
	end

	local endsAt = stateEndsAtMilliseconds
	if not endsAt or nowMilliseconds < endsAt then
		return
	end

	if state == MatchConfig.States.Warmup then
		if not activePlayersReadyForInitialCountdown() then
			return
		end
		enterCountdown(false)
	elseif state == MatchConfig.States.Countdown then
		local countdownDisposition =
			RocketArenaRoundTimingRules.GetCountdownExpiryDisposition(rules.RoundBased, roundStatus)
		if countdownDisposition == "PrepareNextRound" then
			-- RA3 calls fight_done and records the winning score only after the
			-- three-second ROUND_OVER timer expires.
			awardResolvedRound()
			local matchEnded = resolveConfiguredScoreLimitState(rules.RoundWinLimit)
				== MatchRulesCore.ScoreLimitStates.UniqueLeaderAtLimit
			if matchEnded then
				queueIntermission("RoundWinLimit", lastRoundWinnerUserIds, lastRoundWinnerTeamIds)
			else
				enterCountdown(
					true,
					RocketArenaRoundTimingRules.ShouldAdvanceRound(#lastRoundWinnerTeamIds, #lastRoundWinnerUserIds)
				)
			end
			return
		end
		if rules.RoundBased and not activeRoundBodiesReady() then
			if roundSetupDeadlineMilliseconds and nowMilliseconds >= roundSetupDeadlineMilliseconds then
				enterWaiting("RoundSetupFailed")
			end
			return
		end
		enterLive()
	elseif state == MatchConfig.States.Live then
		if rules.RoundBased then
			local sides = collectSides(true)
			if #sides > 1 then
				sides = {}
			end
			finishEliminationRound(sides, "TimeLimit")
		else
			local unique, users, teams = resolveUniqueLeader()
			if unique then
				queueIntermission("TimeLimit", users, teams)
			else
				enterSuddenDeath(MatchRulesCore.SuddenDeathBases.TimeLimit)
			end
		end
	elseif state == MatchConfig.States.Intermission then
		restart("AutomaticRestart")
	end
end

local function notifyPlayerRespawned(player: Player): boolean
	local record = records[player]
	if not record then
		return false
	end

	record.eliminatedCurrentLife = false
	syncPlayerAttributes(player)
	if not liveSetupInProgress then
		snapshotDirty = true
	end
	return true
end

local function addPlayer(player: Player)
	if records[player] then
		return
	end

	nextJoinOrder += 1
	local participation: Participation = ACTIVE
	if
		(rules.Duel or rules.Deathmatch)
		and MatchRosterRuntime.GetActivePlayerCount(records) >= rules.ActivePlayerLimit
	then
		participation = SPECTATOR
	end
	local teamId: TeamId? = nil
	if rules.TeamMode and participation == ACTIVE then
		teamId = MatchRosterRuntime.ChooseBalancedTeam(records)
	end
	local roundEligible = participation == ACTIVE and (not rules.RoundBased or state ~= MatchConfig.States.Live)
	local record: PlayerMatchRecord = {
		score = 0,
		deaths = 0,
		roundWins = 0,
		eliminatedCurrentLife = false,
		roundEligible = roundEligible,
		participation = participation,
		teamId = teamId,
		joinOrder = nextJoinOrder,
	}
	records[player] = record
	player:SetAttribute(
		"ArenaLoadingPresentationState",
		if loadingPresentationFailureCause == nil then "Waiting" else "Failed"
	)
	syncPlayerAttributes(player)

	player.CharacterAdded:Connect(function()
		table.insert(pendingRosterIntents, {
			kind = "Respawned",
			player = player,
		})
	end)

	if
		state == MatchConfig.States.Waiting
		or state == MatchConfig.States.Warmup
		or state == MatchConfig.States.Countdown
	then
		prepareRosterForMatch()
	end
	snapshotDirty = true
end

local function removePlayer(player: Player)
	loadingPresentationReadyPlayers[player] = nil
	if records[player] == nil then
		return
	end
	records[player] = nil
	player:SetAttribute("ArenaMatchParticipant", nil)
	player:SetAttribute("ArenaMatchParticipation", nil)
	player:SetAttribute("ArenaMatchSpectator", nil)
	player:SetAttribute("ArenaMatchTeam", nil)
	player:SetAttribute("ArenaMatchRoundEligible", nil)
	player:SetAttribute("ArenaMatchScore", nil)
	player:SetAttribute("ArenaMatchDeaths", nil)
	player:SetAttribute("ArenaMatchRoundWins", nil)
	player:SetAttribute("ArenaLoadingPresentationState", nil)
	if state == MatchConfig.States.Live and rules.Deathmatch then
		local promoted = MatchRosterRuntime.ApplyDeathmatchActiveLimit(records, rules.ActivePlayerLimit)
		syncAllPlayerAttributes()
		for _, promotedPlayer in promoted do
			requestRespawn(promotedPlayer, 0)
		end
	end
	if
		state == MatchConfig.States.Waiting
		or state == MatchConfig.States.Warmup
		or state == MatchConfig.States.Countdown
	then
		prepareRosterForMatch()
	end
	snapshotDirty = true
	if state == MatchConfig.States.Live and rules.RoundBased and hasEnoughPlayers() then
		scheduleEliminationRoundResolution("Departure")
	end
end

local function applyPendingRosterIntents()
	local intents = pendingRosterIntents
	pendingRosterIntents = {}
	for _, intent in intents do
		if intent.kind == "Add" then
			if intent.player.Parent == Players then
				addPlayer(intent.player)
			end
		elseif intent.kind == "Remove" then
			removePlayer(intent.player)
		elseif intent.player.Parent == Players then
			notifyPlayerRespawned(intent.player)
		end
	end
end

function MatchService.GetState(): State
	return state
end

function MatchService.GetLoadingPresentationFailureCause(): LoadingPresentationFailureCause?
	return loadingPresentationFailureCause
end

function MatchService.OnLoadingPresentationFailed(callback: LoadingPresentationFailureCallback)
	assert(type(callback) == "function", "loading-presentation failure callback must be a function")
	table.insert(loadingPresentationFailureCallbacks, callback)
	local cause = loadingPresentationFailureCause
	if cause then
		local succeeded, callbackError = pcall(callback, cause)
		if not succeeded then
			warn(string.format("Late loading-presentation failure callback failed: %s", tostring(callbackError)))
		end
	end
end

function MatchService.GetRules(): Rules
	return rules
end

function MatchService.GetModeId(): ModeId
	return rules.ModeId
end

function MatchService.GetMatchId(): string?
	return currentMatchId
end

-- Match IDs are presentation/data keys. Prepared cross-owner work binds this
-- opaque identity as well, so even an accidentally reused or stale string
-- cannot carry authority across match or mode lineage.
function MatchService.GetCurrentMatchLineage(matchIdValue: unknown): MatchLineage?
	if type(matchIdValue) ~= "string" or matchIdValue ~= currentMatchId then
		return nil
	end
	return currentMatchLineage
end

function MatchService.ValidateMatchLineage(lineageValue: unknown, matchIdValue: unknown): boolean
	return type(lineageValue) == "table"
		and lineageValue == currentMatchLineage
		and type(matchIdValue) == "string"
		and matchIdValue == currentMatchId
		and currentMatchLineage ~= nil
end

function MatchService.GetRuntimeMap(): RuntimeMap
	return assert(runtimeMap, "MatchService runtime map is unavailable before Start")
end

-- Q3 G_RunFrame reaches client entities in entity-number order, and AddScore
-- synchronously runs CalculateRanks -> CheckExitRules inside player_die. This
-- read-only server boundary snapshots the exact Match inputs needed to shadow
-- that sequence before a composite mover transaction publishes anything.
-- sourceOrder is entityNum + 1; the trusted resolver is never sourced from a
-- client attribute, remote payload, or presentation Instance.
function MatchService.CreateMoverEliminationShadow(
	sourceOrderForPlayer: PlayerSourceOrderResolver,
	levelTimeMilliseconds: number
): (MoverEliminationShadow?, string?)
	if not started then
		return nil, "match-service-not-started"
	end
	if activeAuthoritativeFrame == nil or activeAuthoritativeFrameSummary == nil then
		return nil, "elimination-shadow-outside-authoritative-frame"
	end
	if levelTimeMilliseconds ~= activeLevelTimeMilliseconds() then
		return nil, "elimination-shadow-time-mismatch"
	end
	local scoreKind: MatchEliminationShadowRules.ScoreKind
	if not rules.TeamMode then
		scoreKind = MatchEliminationShadowRules.ScoreKinds.PlayerFrags
	elseif rules.ScoreType == "TeamFrags" then
		scoreKind = MatchEliminationShadowRules.ScoreKinds.TeamFrags
	else
		-- CTF and round-elimination participants retain teams and personal frag
		-- scores, but a death must not mutate objective/round-win buckets.
		scoreKind = MatchEliminationShadowRules.ScoreKinds.TeamObjective
	end

	local players: { MatchEliminationShadowRules.PlayerSeed } = {}
	local seenSourceOrders: { [number]: boolean } = {}
	for player, record in records do
		if record.participation ~= ACTIVE then
			continue
		end
		if player.Parent ~= Players then
			return nil, "stale-active-player"
		end
		local resolved, sourceOrderValue = pcall(sourceOrderForPlayer, player)
		if not resolved then
			return nil, "source-order-resolver-failed"
		end
		if
			type(sourceOrderValue) ~= "number"
			or sourceOrderValue ~= sourceOrderValue
			or math.abs(sourceOrderValue) == math.huge
			or sourceOrderValue % 1 ~= 0
			or sourceOrderValue < 1
			or sourceOrderValue > MatchEliminationShadowRules.MaximumClients
		then
			return nil, "invalid-client-source-order"
		end
		local sourceOrder = sourceOrderValue :: number
		if seenSourceOrders[sourceOrder] then
			return nil, "duplicate-client-source-order"
		end
		seenSourceOrders[sourceOrder] = true

		local teamId: MatchEliminationShadowRules.TeamId
		if not rules.TeamMode then
			teamId = MatchEliminationShadowRules.TeamIds.None
		elseif record.teamId == MatchConfig.TeamIds.Red then
			teamId = MatchEliminationShadowRules.TeamIds.Red
		elseif record.teamId == MatchConfig.TeamIds.Blue then
			teamId = MatchEliminationShadowRules.TeamIds.Blue
		else
			return nil, "active-player-missing-team"
		end

		table.insert(players, {
			sourceOrder = sourceOrder,
			userId = player.UserId,
			teamId = teamId,
			score = record.score,
			deaths = record.deaths,
			eliminatedCurrentLife = record.eliminatedCurrentLife,
		})
	end
	table.sort(
		players,
		function(left: MatchEliminationShadowRules.PlayerSeed, right: MatchEliminationShadowRules.PlayerSeed): boolean
			return left.sourceOrder < right.sourceOrder
		end
	)

	local fragLimit = 0
	if
		not rules.RoundBased
		and (
			scoreKind == MatchEliminationShadowRules.ScoreKinds.PlayerFrags
			or scoreKind == MatchEliminationShadowRules.ScoreKinds.TeamFrags
		)
	then
		fragLimit = rules.ScoreLimit
	end

	local timeLimitAtMilliseconds = -1
	-- CheckExitRules clears the active deadline once a tie enters sudden death or
	-- an intermission latch has qualified. The shadow remains Live until the
	-- later frame phase publishes that transition, so neither terminal state may
	-- fabricate or require the former timelimit boundary.
	if
		state == MatchConfig.States.Live
		and not rules.RoundBased
		and rules.TimeLimitSeconds > 0
		and not suddenDeath
		and queuedIntermission == nil
	then
		timeLimitAtMilliseconds =
			assert(stateEndsAtMilliseconds, "live timed Match is missing its integer level-time deadline")
	end

	local redScore = 0
	local blueScore = 0
	if rules.TeamMode then
		local scoreBuckets = if rules.ScoreType == "RoundWins" then teamRoundWins else teamScores
		redScore = scoreBuckets[MatchConfig.TeamIds.Red] or 0
		blueScore = scoreBuckets[MatchConfig.TeamIds.Blue] or 0
	end

	return MatchEliminationShadowRules.Create({
		scoreKind = scoreKind,
		scoreLimit = fragLimit,
		timeLimitAtMilliseconds = timeLimitAtMilliseconds,
		scoringEnabled = isScoringEnabled(),
		friendlyFire = rules.FriendlyFire,
		levelTimeMilliseconds = levelTimeMilliseconds,
		redScore = redScore,
		blueScore = blueScore,
		players = players,
	})
end

local function captureEliminationBatchBase(): (EliminationBatchBase?, string?)
	local playerRecords: { PlayerRecordSnapshot } = {}
	for _, player in MatchRosterRuntime.GetOrderedPlayers(records) do
		local record = records[player]
		local sourceOrder = EntitySlotService.GetPlayerSourceOrder(player)
		if record.participation == ACTIVE and sourceOrder == nil then
			return nil, "active-player-missing-entity-slot"
		end
		local snapshot: PlayerRecordSnapshot = {
			player = player,
			record = record,
			score = record.score,
			deaths = record.deaths,
			roundWins = record.roundWins,
			eliminatedCurrentLife = record.eliminatedCurrentLife,
			roundEligible = record.roundEligible,
			participation = record.participation,
			teamId = record.teamId,
			joinOrder = record.joinOrder,
			sourceOrder = sourceOrder,
		}
		table.freeze(snapshot)
		table.insert(playerRecords, snapshot)
	end
	table.freeze(playerRecords)
	local base: EliminationBatchBase = {
		rules = rules,
		records = records,
		teamScores = teamScores,
		teamRoundWins = teamRoundWins,
		playerRecords = playerRecords,
		state = state,
		currentMatchId = currentMatchId,
		currentMatchLineage = currentMatchLineage,
		matchNumber = matchNumber,
		round = round,
		roundStatus = roundStatus,
		suddenDeath = suddenDeath,
		suddenDeathBasis = suddenDeathBasis,
		sequence = sequence,
		stateStartedAtMilliseconds = stateStartedAtMilliseconds,
		stateEndsAtMilliseconds = stateEndsAtMilliseconds,
		endReason = endReason,
		lastRoundEndReason = lastRoundEndReason,
		winnerUserIds = winnerUserIds,
		winnerTeamIds = winnerTeamIds,
		lastRoundWinnerUserIds = lastRoundWinnerUserIds,
		lastRoundWinnerTeamIds = lastRoundWinnerTeamIds,
		lastSnapshotAtMilliseconds = lastSnapshotAtMilliseconds,
		roundResolutionGeneration = roundResolutionGeneration,
		roundResolutionScheduled = roundResolutionScheduled,
		queuedIntermission = queuedIntermission,
		redScore = teamScores[MatchConfig.TeamIds.Red] or 0,
		blueScore = teamScores[MatchConfig.TeamIds.Blue] or 0,
		redRoundWins = teamRoundWins[MatchConfig.TeamIds.Red] or 0,
		blueRoundWins = teamRoundWins[MatchConfig.TeamIds.Blue] or 0,
	}
	table.freeze(base)
	return base, nil
end

local function eliminationBatchBaseCurrentError(base: EliminationBatchBase, checkEntitySlots: boolean): string?
	if
		rules ~= base.rules
		or records ~= base.records
		or teamScores ~= base.teamScores
		or teamRoundWins ~= base.teamRoundWins
		or state ~= base.state
		or currentMatchId ~= base.currentMatchId
		or currentMatchLineage ~= base.currentMatchLineage
		or matchNumber ~= base.matchNumber
		or round ~= base.round
		or roundStatus ~= base.roundStatus
		or suddenDeath ~= base.suddenDeath
		or suddenDeathBasis ~= base.suddenDeathBasis
		or sequence ~= base.sequence
		or stateStartedAtMilliseconds ~= base.stateStartedAtMilliseconds
		or stateEndsAtMilliseconds ~= base.stateEndsAtMilliseconds
		or endReason ~= base.endReason
		or lastRoundEndReason ~= base.lastRoundEndReason
		or winnerUserIds ~= base.winnerUserIds
		or winnerTeamIds ~= base.winnerTeamIds
		or lastRoundWinnerUserIds ~= base.lastRoundWinnerUserIds
		or lastRoundWinnerTeamIds ~= base.lastRoundWinnerTeamIds
		or lastSnapshotAtMilliseconds ~= base.lastSnapshotAtMilliseconds
		or roundResolutionGeneration ~= base.roundResolutionGeneration
		or roundResolutionScheduled ~= base.roundResolutionScheduled
		or queuedIntermission ~= base.queuedIntermission
		or (teamScores[MatchConfig.TeamIds.Red] or 0) ~= base.redScore
		or (teamScores[MatchConfig.TeamIds.Blue] or 0) ~= base.blueScore
		or (teamRoundWins[MatchConfig.TeamIds.Red] or 0) ~= base.redRoundWins
		or (teamRoundWins[MatchConfig.TeamIds.Blue] or 0) ~= base.blueRoundWins
	then
		return "stale-elimination-batch-match-state"
	end

	local recordCount = 0
	for _ in records do
		recordCount += 1
	end
	if recordCount ~= #base.playerRecords then
		return "stale-elimination-batch-roster"
	end
	for _, snapshot in base.playerRecords do
		local record = records[snapshot.player]
		if
			record ~= snapshot.record
			or snapshot.player.Parent ~= Players
			or record.score ~= snapshot.score
			or record.deaths ~= snapshot.deaths
			or record.roundWins ~= snapshot.roundWins
			or record.eliminatedCurrentLife ~= snapshot.eliminatedCurrentLife
			or record.roundEligible ~= snapshot.roundEligible
			or record.participation ~= snapshot.participation
			or record.teamId ~= snapshot.teamId
			or record.joinOrder ~= snapshot.joinOrder
		then
			return "stale-elimination-batch-player-record"
		end
		if checkEntitySlots and EntitySlotService.GetPlayerSourceOrder(snapshot.player) ~= snapshot.sourceOrder then
			return "stale-elimination-batch-entity-slot"
		end
	end
	return nil
end

local function getEliminationBatch(
	tokenValue: unknown,
	expectedStatus: EliminationBatchStatus?
): (EliminationBatch?, string?)
	if type(tokenValue) ~= "table" or not table.isfrozen(tokenValue :: any) then
		return nil, "invalid-elimination-batch-token"
	end
	local transaction = MatchEliminationPreparedRegistry.GetActive(eliminationPreparedRegistry)
	if not transaction or transaction.token ~= tokenValue then
		return nil, "stale-elimination-batch-token"
	end
	if
		transaction.frame ~= activeAuthoritativeFrame
		or transaction.frameSummary ~= activeAuthoritativeFrameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(transaction.frame, transaction.frameSummary)
	then
		return nil, "stale-elimination-batch-frame"
	end
	if expectedStatus and transaction.status ~= expectedStatus then
		return nil, "invalid-elimination-batch-status"
	end
	return transaction, nil
end

-- Cleanup must remain available after an external frame dependency goes stale.
-- The exact frozen token identity is sufficient to identify the one active
-- transaction; re-entering AuthoritativeFrameService here would strand Match's
-- reservation precisely when a composite is trying to unwind a failed plan.
local function getEliminationBatchForAbort(tokenValue: unknown): EliminationBatch?
	if type(tokenValue) ~= "table" or not table.isfrozen(tokenValue :: any) then
		return nil
	end
	local transaction = MatchEliminationPreparedRegistry.GetActive(eliminationPreparedRegistry)
	if not transaction or transaction.token ~= tokenValue then
		return nil
	end
	return transaction
end

-- MatchEliminationShadowRules owns a terminal latch created inside this batch.
-- The already-queued level latch is an owner root captured separately in the
-- base, and Q3 G_Damage rejects both live clients and corpses while it exists.
local function eliminationBatchDamageOpen(transaction: EliminationBatch, shadow: MoverEliminationShadow?): boolean
	return transaction.base.queuedIntermission == nil
		and MatchEliminationShadowRules.IsDamageOpen(shadow or transaction.shadow)
end

local function rejectedEliminationResult(victimRecord: PlayerMatchRecord?, friendlyFire: boolean): EliminationResult
	return table.freeze({
		accepted = false,
		scored = false,
		shouldRespawn = false,
		respawnDelaySeconds = rules.RespawnDelaySeconds,
		attackerScore = nil,
		victimScore = if victimRecord then victimRecord.score else nil,
		matchEnded = false,
		roundEnded = false,
		friendlyFire = friendlyFire,
	})
end

local function findBasePlayerRecord(base: EliminationBatchBase, player: Player): PlayerRecordSnapshot?
	for _, snapshot in base.playerRecords do
		if snapshot.player == player then
			return snapshot
		end
	end
	return nil
end

function MatchService.BeginEliminationBatch(levelTimeMillisecondsValue: number?): (EliminationBatchToken?, string?)
	if not started then
		return nil, "match-service-not-started"
	end
	if MatchEliminationPreparedRegistry.GetActive(eliminationPreparedRegistry) then
		return nil, "elimination-batch-active"
	end
	if activeAuthoritativeFrame == nil or activeAuthoritativeFrameSummary == nil then
		return nil, "elimination-batch-outside-authoritative-frame"
	end
	local levelTimeMilliseconds = activeLevelTimeMilliseconds()
	if levelTimeMillisecondsValue ~= nil and levelTimeMillisecondsValue ~= levelTimeMilliseconds then
		return nil, "elimination-batch-time-mismatch"
	end
	if not isNonnegativeInteger(levelTimeMilliseconds) then
		return nil, "invalid-elimination-batch-time"
	end

	local base, baseError = captureEliminationBatchBase()
	if not base then
		return nil, baseError
	end
	local shadow, shadowError =
		MatchService.CreateMoverEliminationShadow(EntitySlotService.GetPlayerSourceOrder, levelTimeMilliseconds)
	if not shadow then
		return nil, shadowError or "elimination-shadow-unavailable"
	end
	local token: EliminationBatchToken = table.freeze({})
	local frame = assert(activeAuthoritativeFrame, "active Match frame disappeared")
	local frameSummary = assert(activeAuthoritativeFrameSummary, "active Match frame summary disappeared")
	local transaction: EliminationBatch = {
		token = token,
		status = "Open",
		frame = frame,
		frameSummary = frameSummary,
		levelTimeMilliseconds = levelTimeMilliseconds,
		base = base,
		baseShadow = shadow,
		shadow = shadow,
		operations = {},
		prepared = nil,
	}
	MatchEliminationPreparedRegistry.SetActive(eliminationPreparedRegistry, transaction)
	return token, nil
end

function MatchService.IsEliminationBatchDamageOpen(tokenValue: unknown): boolean
	local transaction = select(1, getEliminationBatch(tokenValue, "Open"))
	return transaction ~= nil and eliminationBatchDamageOpen(transaction, nil)
end

function MatchService.StageElimination(
	tokenValue: unknown,
	victim: Player,
	attacker: Player?,
	meansValue: string?,
	bypassCombatEligibility: boolean?
): (StagedEliminationReceipt?, string?)
	local transaction, transactionError = getEliminationBatch(tokenValue, "Open")
	if not transaction then
		return nil, transactionError
	end
	local baseError = eliminationBatchBaseCurrentError(transaction.base, true)
	if baseError then
		return nil, baseError
	end
	local victimSnapshot = findBasePlayerRecord(transaction.base, victim)
	local attackerSnapshot = if attacker then findBasePlayerRecord(transaction.base, attacker) else nil
	local means = if type(meansValue) == "string" and meansValue ~= "" then meansValue else "Unknown"
	local friendlyFire = attacker ~= nil
		and attacker ~= victim
		and rules.TeamMode
		and attackerSnapshot ~= nil
		and victimSnapshot ~= nil
		and attackerSnapshot.teamId ~= nil
		and attackerSnapshot.teamId == victimSnapshot.teamId
	local shadowVictim = if victimSnapshot
		then MatchEliminationShadowRules.GetPlayer(transaction.shadow, victim.UserId)
		else nil
	local forcedTelefrag = bypassCombatEligibility == true and means == "Telefrag"
	local eligible = victimSnapshot ~= nil
		and victimSnapshot.participation == ACTIVE
		and shadowVictim ~= nil
		and eliminationBatchDamageOpen(transaction, nil)
		and not shadowVictim.eliminatedCurrentLife
		and (if forcedTelefrag then true else canPlayerFightInternal(victim))
	if not eligible then
		local result = rejectedEliminationResult(if victimSnapshot then victimSnapshot.record else nil, friendlyFire)
		return table.freeze({
			result = result,
			outcome = nil,
			damageOpenAfter = eliminationBatchDamageOpen(transaction, nil),
		}),
			nil
	end

	local attackerUserId = 0
	if attacker and attackerSnapshot and attackerSnapshot.participation == ACTIVE then
		local shadowAttacker = MatchEliminationShadowRules.GetPlayer(transaction.shadow, attacker.UserId)
		if shadowAttacker then
			attackerUserId = attacker.UserId
		end
	end
	local nextShadow, outcome, stageError = MatchEliminationShadowRules.StageElimination(transaction.shadow, {
		operationOrder = transaction.shadow.lastOperationOrder + 1,
		levelTimeMilliseconds = transaction.levelTimeMilliseconds,
		victimUserId = victim.UserId,
		attackerUserId = attackerUserId,
		bypassTeamProtection = means == "Telefrag",
	})
	if not nextShadow or not outcome then
		return nil, stageError or "elimination-shadow-stage-failed"
	end
	if not outcome.accepted then
		local result = rejectedEliminationResult(victimSnapshot.record, friendlyFire)
		return table.freeze({
			result = result,
			outcome = outcome,
			damageOpenAfter = eliminationBatchDamageOpen(transaction, nil),
		}),
			nil
	end

	local finalVictim = MatchEliminationShadowRules.GetPlayer(nextShadow, victim.UserId)
	local finalAttacker = if attackerUserId ~= 0
		then MatchEliminationShadowRules.GetPlayer(nextShadow, attackerUserId)
		else nil
	if not finalVictim then
		return nil, "staged-elimination-victim-missing"
	end
	local matchEnded = outcome.terminalQualified and not rules.RoundBased
	local result: EliminationResult = table.freeze({
		accepted = true,
		scored = outcome.scored,
		shouldRespawn = not matchEnded
			and (state == MatchConfig.States.Warmup or (state == MatchConfig.States.Live and rules.RespawnDuringLive)),
		respawnDelaySeconds = rules.RespawnDelaySeconds,
		attackerScore = if finalAttacker then finalAttacker.score else nil,
		victimScore = finalVictim.score,
		matchEnded = matchEnded,
		roundEnded = false,
		friendlyFire = friendlyFire,
	})
	local receipt: StagedEliminationReceipt = table.freeze({
		result = result,
		outcome = outcome,
		damageOpenAfter = eliminationBatchDamageOpen(transaction, nextShadow),
	})
	local operation: StagedElimination = {
		victim = victim,
		attacker = attacker,
		means = means,
		outcome = outcome,
		result = result,
		receipt = receipt,
	}
	table.freeze(operation)
	table.insert(transaction.operations, operation)
	transaction.shadow = nextShadow
	return receipt, nil
end

function MatchService.SealEliminationBatch(tokenValue: unknown, expectedFinalShadowValue: unknown?): (boolean, string?)
	local transaction, transactionError = getEliminationBatch(tokenValue, "Open")
	if not transaction then
		return false, transactionError
	end
	if #transaction.operations == 0 then
		return false, "empty-elimination-batch"
	end
	local baseError = eliminationBatchBaseCurrentError(transaction.base, true)
	if baseError then
		return false, baseError
	end
	if MatchEliminationShadowRules.Inspect(transaction.shadow) ~= transaction.shadow then
		return false, "invalid-final-elimination-shadow"
	end
	if expectedFinalShadowValue ~= nil then
		if
			type(expectedFinalShadowValue) ~= "table"
			or not eliminationShadowEqual(transaction.shadow, expectedFinalShadowValue :: MoverEliminationShadow)
		then
			return false, "expected-final-elimination-shadow-diverged"
		end
	end
	table.freeze(transaction.operations)
	transaction.status = "Sealed"
	return true, nil
end

local function getPlannedRecordValues(player: Player, mutations: { PlayerRecordMutation }): (number, number, boolean)
	local record = records[player]
	for _, mutation in mutations do
		if mutation.player == player then
			return mutation.nextScore, mutation.nextDeaths, mutation.nextRoundEligible
		end
	end
	return record.score, record.deaths, record.roundEligible
end

local function buildPreparedScoreRows(mutations: { PlayerRecordMutation }): { ScoreRow }
	local rows: { ScoreRow } = {}
	for _, player in MatchRosterRuntime.GetOrderedPlayers(records) do
		local record = records[player]
		local plannedScore, plannedDeaths, plannedRoundEligible = getPlannedRecordValues(player, mutations)
		local row: ScoreRow = {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
			score = plannedScore,
			deaths = plannedDeaths,
			roundWins = getRecordRoundWins(record),
			participation = record.participation,
			teamId = record.teamId,
			roundEligible = record.participation == ACTIVE and plannedRoundEligible,
		}
		table.freeze(row)
		table.insert(rows, row)
	end
	table.sort(rows, function(left: ScoreRow, right: ScoreRow): boolean
		if left.participation ~= right.participation then
			return left.participation == ACTIVE
		end
		if rules.ScoreType == "RoundWins" and left.roundWins ~= right.roundWins then
			return left.roundWins > right.roundWins
		end
		if left.score ~= right.score then
			return left.score > right.score
		end
		if left.deaths ~= right.deaths then
			return left.deaths < right.deaths
		end
		return left.userId < right.userId
	end)
	table.freeze(rows)
	return rows
end

local function buildPreparedTeamRows(
	mutations: { PlayerRecordMutation },
	nextRedScore: number,
	nextBlueScore: number
): { TeamRow }
	local rows: { TeamRow } = {}
	if not rules.TeamMode then
		table.freeze(rows)
		return rows
	end
	for _, teamId in TEAM_ORDER do
		local playerCount = 0
		local eligiblePlayerCount = 0
		for player, record in records do
			if record.participation == ACTIVE and record.teamId == teamId then
				playerCount += 1
				local _, _, plannedRoundEligible = getPlannedRecordValues(player, mutations)
				if plannedRoundEligible then
					eligiblePlayerCount += 1
				end
			end
		end
		local definition = MatchConfig.Teams[teamId]
		local row: TeamRow = {
			teamId = teamId,
			displayName = definition.DisplayName,
			score = if teamId == MatchConfig.TeamIds.Red then nextRedScore else nextBlueScore,
			roundWins = teamRoundWins[teamId] or 0,
			playerCount = playerCount,
			eligiblePlayerCount = eligiblePlayerCount,
		}
		table.freeze(row)
		table.insert(rows, row)
	end
	table.freeze(rows)
	return rows
end

local function freezeArray<T>(values: { T }): { T }
	table.freeze(values)
	return values
end

local function buildPreparedEliminationSnapshot(
	mutations: { PlayerRecordMutation },
	nextRedScore: number,
	nextBlueScore: number,
	nextSuddenDeath: boolean,
	nextStateEndsAt: number?,
	nextEndReason: string?,
	nextQueuedIntermission: MatchFrameRules.IntermissionLatch?,
	nextSequence: number,
	snapshotLevelTimeMilliseconds: number
): MatchSnapshot
	local orderedPlayers = MatchRosterRuntime.GetOrderedPlayers(records)
	local activeUserIds =
		freezeArray(MatchStandingsRuntime.BuildParticipationUserIds(orderedPlayers, records :: any, ACTIVE))
	local spectatorUserIds =
		freezeArray(MatchStandingsRuntime.BuildParticipationUserIds(orderedPlayers, records :: any, SPECTATOR))
	local snapshotWinnerUserIds = freezeArray(table.clone(winnerUserIds))
	local snapshotWinnerTeamIds = freezeArray(table.clone(winnerTeamIds))
	local snapshotLastRoundWinnerUserIds = freezeArray(table.clone(lastRoundWinnerUserIds))
	local snapshotLastRoundWinnerTeamIds = freezeArray(table.clone(lastRoundWinnerTeamIds))
	local snapshotTeamScores = {
		[MatchConfig.TeamIds.Red] = nextRedScore,
		[MatchConfig.TeamIds.Blue] = nextBlueScore,
	}
	table.freeze(snapshotTeamScores)
	local snapshotRoundWins = MatchStandingsRuntime.CloneNumberMap(teamRoundWins)
	table.freeze(snapshotRoundWins)
	local snapshotRules = {
		oneShot = rules.OneShot,
		deathmatch = rules.Deathmatch,
		duel = rules.Duel,
		captureTheFlag = rules.CaptureTheFlag,
		teamMode = rules.TeamMode,
		roundBased = rules.RoundBased,
		friendlyFire = rules.FriendlyFire,
		immediateRespawn = rules.ImmediateRespawn,
		respawnDuringLive = rules.RespawnDuringLive,
		forcedRespawnSeconds = rules.ForcedRespawnSeconds,
		armorEnabled = rules.ArmorEnabled,
		pickupsEnabled = rules.PickupsEnabled,
		maximumHealth = rules.MaximumHealth,
		spawnHealth = rules.SpawnHealth,
		spawnArmor = rules.SpawnArmor,
		spawnWeaponId = rules.SpawnWeaponId,
	}
	table.freeze(snapshotRules)
	local serverTime = presentationTimeForLevel(snapshotLevelTimeMilliseconds)
	local remainingSeconds = if nextStateEndsAt
		then assert(MatchFrameRules.RemainingSeconds(nextStateEndsAt, snapshotLevelTimeMilliseconds))
		else nil
	local snapshot: MatchSnapshot = {
		sequence = nextSequence,
		modeId = rules.ModeId,
		rulesetId = rules.RulesetId,
		displayName = rules.DisplayName,
		modeKind = rules.ModeKind,
		scoreType = rules.ScoreType,
		state = state,
		matchId = currentMatchId,
		matchNumber = matchNumber,
		round = round,
		roundStatus = roundStatus,
		serverTime = serverTime,
		stateStartedAt = presentationTimeForLevel(stateStartedAtMilliseconds),
		stateEndsAt = if nextStateEndsAt then presentationTimeForLevel(nextStateEndsAt) else nil,
		remainingSeconds = remainingSeconds,
		intermissionQueued = nextQueuedIntermission ~= nil,
		intermissionQualifiedAt = if nextQueuedIntermission
			then presentationTimeForLevel(nextQueuedIntermission.qualifiedAtMilliseconds)
			else nil,
		intermissionStartsAt = if nextQueuedIntermission
			then presentationTimeForLevel(nextQueuedIntermission.startsAtMilliseconds)
			else nil,
		scoreLimit = rules.ScoreLimit,
		roundWinLimit = rules.RoundWinLimit,
		timeLimitSeconds = rules.TimeLimitSeconds,
		minimumPlayers = rules.MinimumPlayers,
		playerCount = MatchRosterRuntime.GetPlayerCount(records),
		activePlayerCount = #activeUserIds,
		spectatorCount = #spectatorUserIds,
		soloDevelopmentActive = isSoloDevelopmentActive(),
		combatEnabled = nextQueuedIntermission == nil and rules.CombatStates[state] == true,
		scoringEnabled = nextQueuedIntermission == nil and rules.ScoringStates[state] == true,
		suddenDeath = nextSuddenDeath,
		respawnDelaySeconds = rules.RespawnDelaySeconds,
		forcedRespawnSeconds = rules.ForcedRespawnSeconds,
		teamMode = rules.TeamMode,
		friendlyFire = rules.FriendlyFire,
		endReason = nextEndReason,
		lastRoundEndReason = lastRoundEndReason,
		winnerUserIds = snapshotWinnerUserIds,
		winnerTeamId = if #snapshotWinnerTeamIds == 1 then snapshotWinnerTeamIds[1] else nil,
		winnerTeamIds = snapshotWinnerTeamIds,
		lastRoundWinnerUserIds = snapshotLastRoundWinnerUserIds,
		lastRoundWinnerTeamId = if #snapshotLastRoundWinnerTeamIds == 1 then snapshotLastRoundWinnerTeamIds[1] else nil,
		lastRoundWinnerTeamIds = snapshotLastRoundWinnerTeamIds,
		activePlayerUserIds = activeUserIds,
		spectatorUserIds = spectatorUserIds,
		teamScores = snapshotTeamScores,
		roundWins = snapshotRoundWins,
		teams = buildPreparedTeamRows(mutations, nextRedScore, nextBlueScore),
		scores = buildPreparedScoreRows(mutations),
		rules = snapshotRules,
	}
	table.freeze(snapshot)
	return snapshot
end

local function preparedEliminationCurrentError(
	preparedValue: unknown,
	capability: PreparedEliminationCapability,
	checkEntitySlots: boolean
): string?
	local transaction = capability.transaction
	if
		capability.status ~= "Prepared"
		or MatchEliminationPreparedRegistry.GetActive(eliminationPreparedRegistry) ~= transaction
		or transaction.status ~= "Prepared"
		or transaction.prepared ~= preparedValue
		or MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, preparedValue) ~= capability
		or MatchEliminationPreparedRegistry.GetPreparedForSummary(eliminationPreparedRegistry, capability.summary) ~= preparedValue :: PreparedEliminationBatch
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.mutations)
		or not table.isfrozen(capability.envelope)
		or not table.isfrozen(capability.envelope.operations)
		or not table.isfrozen(capability.envelope.snapshot)
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(capability.summary.outcomes)
		or capability.summary.authoritativeFrame ~= transaction.frame
		or capability.summary.authoritativeFrameSummary ~= transaction.frameSummary
		or capability.summary.matchId ~= transaction.base.currentMatchId
		or capability.summary.matchLineage ~= transaction.base.currentMatchLineage
		or (capability.summary.matchId == nil) ~= (capability.summary.matchLineage == nil)
		or (checkEntitySlots and capability.summary.matchId ~= nil and not MatchService.ValidateMatchLineage(
			capability.summary.matchLineage,
			capability.summary.matchId
		))
		or (checkEntitySlots and (transaction.frame ~= activeAuthoritativeFrame or transaction.frameSummary ~= activeAuthoritativeFrameSummary or not AuthoritativeFrameService.ValidateFrameDependency(
			transaction.frame,
			transaction.frameSummary
		)))
		or MatchEliminationPreparedRegistry.GetCommitSerial(eliminationPreparedRegistry) ~= capability.baseCommitSerial
		or capability.nextCommitSerial ~= capability.baseCommitSerial + 1
		or not table.isfrozen(capability.commitReceipt :: any)
		or capability.appliedCapability.status ~= "Pending"
		or capability.appliedCapability.commitSerial ~= capability.nextCommitSerial
		or capability.appliedCapability.envelope ~= capability.envelope
		or MatchEliminationPreparedRegistry.GetApplied(eliminationPreparedRegistry, capability.commitReceipt)
			~= capability.appliedCapability
	then
		return "stale-prepared-elimination-batch"
	end
	local baseError = eliminationBatchBaseCurrentError(capability.base, checkEntitySlots)
	if baseError then
		return baseError
	end
	for _, mutation in capability.mutations do
		if
			not table.isfrozen(mutation)
			or records[mutation.player] ~= mutation.record
			or mutation.record ~= mutation.base.record
		then
			return "stale-prepared-elimination-mutation"
		end
	end
	return nil
end

function MatchService.PrepareEliminationBatch(tokenValue: unknown): (PreparedEliminationBatch?, string?)
	local transaction, transactionError = getEliminationBatch(tokenValue, "Sealed")
	if not transaction then
		return nil, transactionError
	end
	if transaction.prepared ~= nil then
		return nil, "elimination-batch-already-prepared"
	end
	local commitSerial = MatchEliminationPreparedRegistry.GetCommitSerial(eliminationPreparedRegistry)
	if commitSerial >= 9_007_199_254_740_991 then
		return nil, "elimination-commit-serial-exhausted"
	end
	local baseError = eliminationBatchBaseCurrentError(transaction.base, true)
	if baseError then
		return nil, baseError
	end

	local mutations: { PlayerRecordMutation } = {}
	for _, snapshot in transaction.base.playerRecords do
		if snapshot.participation ~= ACTIVE then
			continue
		end
		local finalPlayer = MatchEliminationShadowRules.GetPlayer(transaction.shadow, snapshot.player.UserId)
		if not finalPlayer or finalPlayer.sourceOrder ~= snapshot.sourceOrder then
			return nil, "prepared-elimination-player-shadow-diverged"
		end
		local nextRoundEligible = snapshot.roundEligible
		if rules.RoundBased and state == MatchConfig.States.Live and finalPlayer.eliminatedCurrentLife then
			nextRoundEligible = false
		end
		if
			finalPlayer.score ~= snapshot.score
			or finalPlayer.deaths ~= snapshot.deaths
			or finalPlayer.eliminatedCurrentLife ~= snapshot.eliminatedCurrentLife
			or nextRoundEligible ~= snapshot.roundEligible
		then
			local mutation: PlayerRecordMutation = {
				player = snapshot.player,
				record = snapshot.record,
				base = snapshot,
				nextScore = finalPlayer.score,
				nextDeaths = finalPlayer.deaths,
				nextEliminatedCurrentLife = finalPlayer.eliminatedCurrentLife,
				nextRoundEligible = nextRoundEligible,
			}
			table.freeze(mutation)
			table.insert(mutations, mutation)
		end
	end
	table.freeze(mutations)

	local nextRedScore = transaction.base.redScore
	local nextBlueScore = transaction.base.blueScore
	if transaction.shadow.scoreKind == MatchEliminationShadowRules.ScoreKinds.TeamFrags then
		nextRedScore = transaction.shadow.redScore
		nextBlueScore = transaction.shadow.blueScore
	end

	local nextSuddenDeath = transaction.base.suddenDeath
	local nextSuddenDeathBasis = transaction.base.suddenDeathBasis
	local terminalReason: string? = nil
	for _, operation in transaction.operations do
		local outcome = operation.outcome
		if outcome.terminalQualified then
			local terminal = outcome.terminal
			if not terminal then
				return nil, "terminal-elimination-missing-latch"
			end
			terminalReason = if terminal.reason == "TimeLimit"
				then "TimeLimit"
				elseif nextSuddenDeath then "SuddenDeath"
				else "ScoreLimit"
			break
		end
		local timeLimitTie = outcome.scoreTied
			and transaction.shadow.timeLimitAtMilliseconds >= 0
			and transaction.levelTimeMilliseconds >= transaction.shadow.timeLimitAtMilliseconds
		if timeLimitTie then
			nextSuddenDeath = true
			nextSuddenDeathBasis = MatchRulesCore.SuddenDeathBases.TimeLimit
		elseif outcome.tiedAtLimit and not nextSuddenDeath then
			nextSuddenDeath = true
			nextSuddenDeathBasis = MatchRulesCore.SuddenDeathBases.ScoreLimit
		end
	end

	local nextQueuedIntermission = transaction.base.queuedIntermission
	local nextStateEndsAt = transaction.base.stateEndsAtMilliseconds
	local nextEndReason = transaction.base.endReason
	local nextRoundResolutionGeneration = transaction.base.roundResolutionGeneration
	local nextRoundResolutionScheduled = transaction.base.roundResolutionScheduled
	local preparedRoundResolution: PreparedRoundResolution? = nil
	local terminal = transaction.shadow.terminal
	if terminal then
		local endingUsers: { number } = {}
		local endingTeams: { TeamId } = {}
		if terminal.winnerUserId then
			table.insert(endingUsers, terminal.winnerUserId)
		elseif terminal.winnerTeamId then
			local winnerTeam = terminal.winnerTeamId :: TeamId
			table.insert(endingTeams, winnerTeam)
			endingUsers = getUserIdsForTeams(endingTeams)
		end
		local latch, created = MatchFrameRules.CreateIntermissionLatch(
			nil,
			terminal.qualifiedAtMilliseconds,
			terminalReason or terminal.reason,
			endingUsers,
			endingTeams :: any
		)
		if
			not latch
			or not created
			or latch.qualifiedAtMilliseconds ~= terminal.qualifiedAtMilliseconds
			or latch.startsAtMilliseconds ~= terminal.startsAtMilliseconds
		then
			return nil, "prepared-elimination-terminal-time-diverged"
		end
		nextQueuedIntermission = latch
		nextStateEndsAt = nil
		nextEndReason = terminalReason or terminal.reason
		nextRoundResolutionGeneration += 1
		nextRoundResolutionScheduled = false
	elseif nextSuddenDeath and not transaction.base.suddenDeath then
		nextStateEndsAt = nil
		nextEndReason = "SuddenDeath"
	elseif
		rules.RoundBased
		and state == MatchConfig.States.Live
		and transaction.shadow.scoringEnabled
		and not nextRoundResolutionScheduled
	then
		nextRoundResolutionScheduled = true
		preparedRoundResolution = table.freeze({
			generation = nextRoundResolutionGeneration,
			round = round,
			modeId = rules.ModeId,
			reason = "Elimination",
		})
	end

	local nextSequence = transaction.base.sequence + 1
	local nextLastSnapshotAt = transaction.levelTimeMilliseconds
	local snapshot = buildPreparedEliminationSnapshot(
		mutations,
		nextRedScore,
		nextBlueScore,
		nextSuddenDeath,
		nextStateEndsAt,
		nextEndReason,
		nextQueuedIntermission,
		nextSequence,
		nextLastSnapshotAt
	)
	local envelope: EliminationPublicationEnvelope = {
		operations = transaction.operations,
		mutations = mutations,
		snapshot = snapshot,
		stateChanged = nextSuddenDeath and not transaction.base.suddenDeath and terminal == nil,
		roundResolution = preparedRoundResolution,
	}
	table.freeze(envelope)

	local outcomes: { MatchEliminationShadowRules.EliminationOutcome } = {}
	for _, operation in transaction.operations do
		table.insert(outcomes, operation.outcome)
	end
	table.freeze(outcomes)
	local summary: PreparedEliminationBatchSummary = {
		authoritativeFrame = transaction.frame,
		authoritativeFrameSummary = transaction.frameSummary,
		baseShadow = transaction.baseShadow,
		finalShadow = transaction.shadow,
		matchId = transaction.base.currentMatchId,
		matchLineage = transaction.base.currentMatchLineage,
		modeId = transaction.base.rules.ModeId,
		matchState = transaction.base.state,
		levelTimeMilliseconds = transaction.levelTimeMilliseconds,
		baseSequence = transaction.base.sequence,
		operationCount = #transaction.operations,
		outcomes = outcomes,
		terminal = terminal,
		damageOpenAfter = eliminationBatchDamageOpen(transaction, transaction.shadow),
		startingIntermissionQueued = transaction.base.queuedIntermission ~= nil,
		startingSuddenDeath = transaction.base.suddenDeath,
		finalSuddenDeath = nextSuddenDeath,
	}
	table.freeze(summary)

	local prepared: PreparedEliminationBatch = table.freeze({})
	local commitReceipt: EliminationBatchCommitReceipt = table.freeze({})
	local appliedCapability: AppliedEliminationCapability = {
		status = "Pending",
		commitSerial = commitSerial + 1,
		envelope = envelope,
	}
	local capability: PreparedEliminationCapability = {
		transaction = transaction,
		status = "Prepared",
		base = transaction.base,
		mutations = mutations,
		nextRedScore = nextRedScore,
		nextBlueScore = nextBlueScore,
		nextSuddenDeath = nextSuddenDeath,
		nextSuddenDeathBasis = nextSuddenDeathBasis,
		nextStateEndsAt = nextStateEndsAt,
		nextEndReason = nextEndReason,
		nextQueuedIntermission = nextQueuedIntermission,
		nextRoundResolutionGeneration = nextRoundResolutionGeneration,
		nextRoundResolutionScheduled = nextRoundResolutionScheduled,
		nextSequence = nextSequence,
		nextLastSnapshotAt = nextLastSnapshotAt,
		envelope = envelope,
		summary = summary,
		baseCommitSerial = commitSerial,
		nextCommitSerial = commitSerial + 1,
		commitReceipt = commitReceipt,
		appliedCapability = appliedCapability,
		applyValidated = false,
	}
	MatchEliminationPreparedRegistry.SetPrepared(eliminationPreparedRegistry, prepared, capability)
	MatchEliminationPreparedRegistry.SetPreparedForSummary(eliminationPreparedRegistry, summary, prepared)
	MatchEliminationPreparedRegistry.SetApplied(eliminationPreparedRegistry, commitReceipt, appliedCapability)
	transaction.prepared = prepared
	transaction.status = "Prepared"
	return prepared, nil
end

function MatchService.InspectPreparedEliminationBatch(preparedValue: unknown): PreparedEliminationBatchSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, preparedValue)
	if not capability or capability.status ~= "Prepared" then
		return nil
	end
	if preparedEliminationCurrentError(preparedValue, capability, true) then
		return nil
	end
	return capability.summary
end

function MatchService.InspectPreparedEliminationBatchReceipt(preparedValue: unknown): EliminationBatchCommitReceipt?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, preparedValue)
	if not capability or capability.status ~= "Prepared" then
		return nil
	end
	if preparedEliminationCurrentError(preparedValue, capability, true) then
		return nil
	end
	return capability.commitReceipt
end

function MatchService.ValidatePreparedEliminationBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-prepared-elimination-dependency"
	end
	local prepared = preparedValue :: PreparedEliminationBatch
	local summary = summaryValue :: PreparedEliminationBatchSummary
	local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, prepared)
	if
		not capability
		or capability.status ~= "Prepared"
		or capability.summary ~= summary
		or MatchEliminationPreparedRegistry.GetPreparedForSummary(eliminationPreparedRegistry, summary)
			~= prepared
	then
		return false, "forged-prepared-elimination-dependency"
	end
	local currentError = preparedEliminationCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function MatchService.CanApplyPreparedEliminationBatch(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-elimination-batch"
	end
	local prepared = preparedValue :: PreparedEliminationBatch
	local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, prepared)
	if not capability then
		return false, "stale-prepared-elimination-batch"
	end
	capability.applyValidated = false
	local currentError = preparedEliminationCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- Every allocating, sorting, snapshot-building, winner-resolution, and
-- publication-envelope operation happens in Prepare. After the composite
-- preflight, Apply repeats only fixed identity/scalar checks and swaps Match
-- authority by assignment. It invokes no Instance method, callback, remote,
-- task scheduler, clock, resolver, or yielding API and has no failure return.
function MatchService.ApplyPreparedEliminationBatch(preparedValue: unknown): EliminationBatchCommitReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-elimination-batch")
	local prepared = preparedValue :: PreparedEliminationBatch
	local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, prepared)
	assert(capability, "stale-prepared-elimination-batch")
	assert(capability.applyValidated, "prepared-elimination-batch-not-validated")
	local currentError = preparedEliminationCurrentError(prepared, capability, false)
	assert(currentError == nil, currentError or "stale-prepared-elimination-batch")

	for _, mutation in capability.mutations do
		local record = mutation.record
		record.score = mutation.nextScore
		record.deaths = mutation.nextDeaths
		record.eliminatedCurrentLife = mutation.nextEliminatedCurrentLife
		record.roundEligible = mutation.nextRoundEligible
	end
	teamScores[MatchConfig.TeamIds.Red] = capability.nextRedScore
	teamScores[MatchConfig.TeamIds.Blue] = capability.nextBlueScore
	suddenDeath = capability.nextSuddenDeath
	suddenDeathBasis = capability.nextSuddenDeathBasis
	stateEndsAtMilliseconds = capability.nextStateEndsAt
	endReason = capability.nextEndReason
	queuedIntermission = capability.nextQueuedIntermission
	roundResolutionGeneration = capability.nextRoundResolutionGeneration
	roundResolutionScheduled = capability.nextRoundResolutionScheduled
	sequence = capability.nextSequence
	lastSnapshotAtMilliseconds = capability.nextLastSnapshotAt
	MatchEliminationPreparedRegistry.SetCommitSerial(eliminationPreparedRegistry, capability.nextCommitSerial)

	local transaction = capability.transaction
	local receipt = capability.commitReceipt
	transaction.status = "Applied"
	transaction.prepared = nil
	MatchEliminationPreparedRegistry.SetActive(eliminationPreparedRegistry, nil)
	capability.status = "Applied"
	capability.applyValidated = false
	MatchEliminationPreparedRegistry.SetPrepared(eliminationPreparedRegistry, prepared, nil)
	MatchEliminationPreparedRegistry.SetPreparedForSummary(eliminationPreparedRegistry, capability.summary, nil)
	capability.appliedCapability.status = "Applied"
	return receipt
end

function MatchService.AbortEliminationBatch(tokenValue: unknown): boolean
	local transaction = getEliminationBatchForAbort(tokenValue)
	if not transaction then
		return false
	end
	if transaction.status ~= "Open" and transaction.status ~= "Sealed" and transaction.status ~= "Prepared" then
		return false
	end
	local prepared = transaction.prepared
	if prepared then
		local capability = MatchEliminationPreparedRegistry.GetPrepared(eliminationPreparedRegistry, prepared)
		if capability then
			capability.status = "Aborted"
			capability.applyValidated = false
			MatchEliminationPreparedRegistry.SetPreparedForSummary(eliminationPreparedRegistry, capability.summary, nil)
			MatchEliminationPreparedRegistry.SetApplied(eliminationPreparedRegistry, capability.commitReceipt, nil)
		end
		MatchEliminationPreparedRegistry.SetPrepared(eliminationPreparedRegistry, prepared, nil)
		transaction.prepared = nil
	end
	transaction.status = "Aborted"
	MatchEliminationPreparedRegistry.SetActive(eliminationPreparedRegistry, nil)
	return true
end

local function publishPreparedSnapshot(snapshot: MatchSnapshot)
	sharedRoot:SetAttribute("ArenaMatchState", snapshot.state)
	sharedRoot:SetAttribute("ArenaMatchId", snapshot.matchId)
	sharedRoot:SetAttribute("ArenaMatchSequence", snapshot.sequence)
	sharedRoot:SetAttribute("ArenaMatchMode", snapshot.modeId)
	sharedRoot:SetAttribute("ArenaMatchRuleset", snapshot.rulesetId)
	sharedRoot:SetAttribute("ArenaMatchNumber", snapshot.matchNumber)
	sharedRoot:SetAttribute("ArenaMatchRound", snapshot.round)
	sharedRoot:SetAttribute("ArenaMatchRoundStatus", snapshot.roundStatus)
	sharedRoot:SetAttribute("ArenaMatchSuddenDeath", snapshot.suddenDeath)
	sharedRoot:SetAttribute("ArenaMatchStateEndsAt", snapshot.stateEndsAt)
	sharedRoot:SetAttribute("ArenaMatchIntermissionQueued", snapshot.intermissionQueued)
	sharedRoot:SetAttribute("ArenaMatchIntermissionStartsAt", snapshot.intermissionStartsAt)
	sharedRoot:SetAttribute("ArenaMatchWinnerTeam", snapshot.winnerTeamId)
	sharedRoot:SetAttribute("ArenaMatchRedScore", snapshot.teamScores[MatchConfig.TeamIds.Red] or 0)
	sharedRoot:SetAttribute("ArenaMatchBlueScore", snapshot.teamScores[MatchConfig.TeamIds.Blue] or 0)
	sharedRoot:SetAttribute("ArenaMatchRedRoundWins", snapshot.roundWins[MatchConfig.TeamIds.Red] or 0)
	sharedRoot:SetAttribute("ArenaMatchBlueRoundWins", snapshot.roundWins[MatchConfig.TeamIds.Blue] or 0)
end

local function makeEliminationPublicationReport(
	capability: AppliedEliminationCapability,
	phase: "Attributes" | "Observers" | "Combined",
	attemptedPublicationCount: number,
	faults: { string }
): EliminationPublicationReport
	table.freeze(faults)
	local report: EliminationPublicationReport = {
		commitSerial = capability.commitSerial,
		phase = phase,
		operationCount = #capability.envelope.operations,
		attemptedPublicationCount = attemptedPublicationCount,
		faultCount = #faults,
		faults = faults,
	}
	table.freeze(report)
	return report
end

local function getAppliedEliminationCapability(
	receiptValue: unknown
): (EliminationBatchCommitReceipt?, AppliedEliminationCapability?, string?)
	if type(receiptValue) ~= "table" or not table.isfrozen(receiptValue :: any) then
		return nil, nil, "invalid-elimination-batch-commit-receipt"
	end
	local receipt = receiptValue :: EliminationBatchCommitReceipt
	local capability = MatchEliminationPreparedRegistry.GetApplied(eliminationPreparedRegistry, receipt)
	if not capability then
		return nil, nil, "stale-elimination-batch-commit-receipt"
	end
	return receipt, capability, nil
end

-- The first publication phase is intentionally limited to Match-owned Player
-- attributes. Combat can then publish its own state/Damage/Elimination before
-- Match semantic observers and the scoreboard snapshot, preserving the
-- player_die ordering without placing any Instance call inside authority Apply.
function MatchService.FlushPreparedEliminationAttributes(
	receiptValue: unknown
): (EliminationPublicationReport?, string?)
	local _receipt, capability, receiptError = getAppliedEliminationCapability(receiptValue)
	if not capability then
		return nil, receiptError
	end
	if capability.status == "AttributesFlushed" or capability.status == "Flushed" then
		return nil, "elimination-attributes-already-flushed"
	end
	if capability.status ~= "Applied" then
		return nil, "invalid-elimination-attribute-publication-status"
	end
	capability.status = "AttributesFlushed"
	local attemptedPublicationCount = 0
	local faults: { string } = {}
	local function attempt(label: string, callback: () -> ())
		attemptedPublicationCount += 1
		local succeeded = pcall(callback)
		if not succeeded then
			table.insert(faults, label)
		end
	end

	local envelope = capability.envelope
	for _, mutation in envelope.mutations do
		attempt("PlayerAttributes:" .. tostring(mutation.player.UserId), function()
			syncPlayerAttributes(mutation.player)
		end)
	end
	return makeEliminationPublicationReport(capability, "Attributes", attemptedPublicationCount, faults), nil
end

-- The second phase consumes the receipt after every owner has published its
-- authoritative state. Callback/remote/task faults are diagnostics only; they
-- never reopen or negate the already-applied Match commit.
local function flushPreparedEliminationObservers(
	receiptValue: unknown,
	invokeCompatibilityRespawnHandler: boolean
): (EliminationPublicationReport?, string?)
	local _receipt, capability, receiptError = getAppliedEliminationCapability(receiptValue)
	if not capability then
		return nil, receiptError
	end
	if capability.status == "Flushed" then
		return nil, "elimination-observers-already-flushed"
	end
	if capability.status ~= "AttributesFlushed" then
		return nil, "elimination-attributes-not-flushed"
	end
	capability.status = "Flushed"

	local attemptedPublicationCount = 0
	local faults: { string } = {}
	local function attempt(label: string, callback: () -> ())
		attemptedPublicationCount += 1
		local succeeded = pcall(callback)
		if not succeeded then
			table.insert(faults, label)
		end
	end
	local envelope = capability.envelope
	for _, operation in envelope.operations do
		notifyAuthorityElimination(operation.victim, operation.attacker, operation.means, operation.result)
		attempt("EliminationObserver:" .. tostring(operation.victim.UserId), function()
			publishOutward(function()
				eliminationBindable:Fire(operation.victim, operation.attacker, operation.means, operation.result)
			end)
		end)
		if operation.result.shouldRespawn then
			if invokeCompatibilityRespawnHandler and synchronousRespawnHandler then
				attempt("CompatibilityRespawnAuthority:" .. tostring(operation.victim.UserId), function()
					(synchronousRespawnHandler :: RespawnCallback)(
						operation.victim,
						operation.result.respawnDelaySeconds
					)
				end)
			end
			-- The synchronous handler is Combat authority and therefore belongs to
			-- Combat's prepared participant. Match emits only the observer intent.
			attempt("RespawnObserver:" .. tostring(operation.victim.UserId), function()
				publishOutward(function()
					respawnRequestedBindable:Fire(operation.victim, operation.result.respawnDelaySeconds)
				end)
			end)
		end
	end
	attempt("SnapshotAttributes", function()
		publishOutward(function()
			publishPreparedSnapshot(envelope.snapshot)
		end)
	end)
	attempt("SnapshotRemote", function()
		publishOutward(function()
			snapshotRemote:FireAllClients(envelope.snapshot)
		end)
	end)
	attempt("SnapshotObserver", function()
		publishOutward(function()
			snapshotChangedBindable:Fire(envelope.snapshot)
		end)
	end)
	if envelope.stateChanged then
		attempt("StateObserver", function()
			publishOutward(function()
				stateChangedBindable:Fire(envelope.snapshot)
			end)
		end)
	end
	local resolution = envelope.roundResolution
	if resolution then
		attempt("RoundResolutionIntent", function()
			pendingRoundResolution = resolution
		end)
	end
	return makeEliminationPublicationReport(capability, "Observers", attemptedPublicationCount, faults), nil
end

function MatchService.FlushPreparedEliminationObservers(receiptValue: unknown): (EliminationPublicationReport?, string?)
	return flushPreparedEliminationObservers(receiptValue, false)
end

-- Compatibility convenience for callers that do not participate in the
-- Combat/Corpse/Movement composite publication coordinator.
function MatchService.FlushPreparedEliminationBatch(receiptValue: unknown): (EliminationPublicationReport?, string?)
	local attributesReport, attributesError = MatchService.FlushPreparedEliminationAttributes(receiptValue)
	if not attributesReport then
		return nil, attributesError
	end
	local observersReport, observersError = flushPreparedEliminationObservers(receiptValue, false)
	if not observersReport then
		return nil, observersError
	end
	local faults = table.clone(attributesReport.faults)
	for _, fault in observersReport.faults do
		table.insert(faults, fault)
	end
	local capability = MatchEliminationPreparedRegistry.GetApplied(eliminationPreparedRegistry, receiptValue)
	assert(capability, "applied elimination capability disappeared during flush")
	return makeEliminationPublicationReport(
		capability,
		"Combined",
		attributesReport.attemptedPublicationCount + observersReport.attemptedPublicationCount,
		faults
	),
		nil
end

function MatchService.IsModeAvailable(modeId: string): (boolean, string?)
	local candidateRules = MatchConfig.GetMode(modeId)
	if not candidateRules then
		return false, "UnknownMode"
	end
	local currentRuntimeMap = runtimeMap
	if not currentRuntimeMap then
		return false, "MapContractUnavailable"
	end
	if not MapRuntimeContract.AllowsMode(currentRuntimeMap, candidateRules.ModeId) then
		return false, string.format("ModeUnavailable:NotDeclared:%s", candidateRules.ModeId)
	end
	local supported, missing =
		MapRuntimeContract.Supports(currentRuntimeMap.capabilities, candidateRules.RequiredMapCapabilities)
	if supported then
		return true, nil
	end
	return false, string.format("ModeUnavailable:%s", table.concat(missing, ","))
end

function MatchService.GetModeIds(): { ModeId }
	local available: { ModeId } = {}
	for _, modeId in MatchConfig.ModeOrder do
		if MatchService.IsModeAvailable(modeId) then
			table.insert(available, modeId)
		end
	end
	return available
end

function MatchService.GetSnapshot(): MatchSnapshot
	return buildSnapshot()
end

function MatchService.GetPlayerScore(player: Player): number
	local record = records[player]
	return if record then record.score else 0
end

function MatchService.GetPlayerDeaths(player: Player): number
	local record = records[player]
	return if record then record.deaths else 0
end

function MatchService.GetPlayerRoundWins(player: Player): number
	local record = records[player]
	return if record then getRecordRoundWins(record) else 0
end

function MatchService.GetPlayerTeam(player: Player): TeamId?
	local record = records[player]
	return if record then record.teamId else nil
end

function MatchService.GetPlayerParticipation(player: Player): Participation?
	local record = records[player]
	return if record then record.participation else nil
end

function MatchService.GetTeamScore(teamId: TeamId): number
	return teamScores[teamId] or 0
end

function MatchService.GetTeamRoundWins(teamId: TeamId): number
	return teamRoundWins[teamId] or 0
end

function MatchService.IsPlayerSpectating(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.participation == SPECTATOR
end

function MatchService.IsPlayerRoundEligible(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.participation == ACTIVE and record.roundEligible
end

function MatchService.CanPlayerFight(player: Player): boolean
	return canPlayerFightInternal(player)
end

function MatchService.CanDamage(attacker: Player?, target: Player): boolean
	if not canPlayerFightInternal(target) then
		return false
	end
	if not attacker then
		return true
	end
	if not canPlayerFightInternal(attacker) then
		return false
	end
	local attackerRecord = records[attacker]
	local targetRecord = records[target]
	return MatchRulesCore.CanTeamDamage(
		rules.TeamMode,
		rules.FriendlyFire,
		if attackerRecord then attackerRecord.teamId else nil,
		if targetRecord then targetRecord.teamId else nil,
		attacker == target
	)
end

function MatchService.CanAuthorizedAttackDamage(attacker: Player, target: Player, shotMatchId: string?): boolean
	if
		type(shotMatchId) ~= "string"
		or shotMatchId == ""
		or shotMatchId ~= currentMatchId
		or not canPlayerFightInternal(target)
	then
		return false
	end
	local attackerRecord = records[attacker]
	if not attackerRecord or attackerRecord.participation ~= ACTIVE then
		return false
	end
	local targetRecord = records[target]
	return MatchRulesCore.CanTeamDamage(
		rules.TeamMode,
		rules.FriendlyFire,
		attackerRecord.teamId,
		if targetRecord then targetRecord.teamId else nil,
		attacker == target
	)
end

-- Q3 leaves the immediate client corpse associated with its client/team and
-- takedamage=true. MASK_SHOT may therefore reach it after player_die even
-- though the target is no longer eligible to fight. A missile fired before
-- its owner died also remains authorized against the current match. Preserve
-- team protection and the queued-intermission gate without requiring either
-- dead participant to pass the live-player eligibility predicate.
function MatchService.CanAuthorizedAttackDamageCorpse(attacker: Player?, target: Player, shotMatchId: string?): boolean
	if type(shotMatchId) ~= "string" or shotMatchId == "" or shotMatchId ~= currentMatchId or not isCombatEnabled() then
		return false
	end
	local targetRecord = records[target]
	if not targetRecord or targetRecord.participation ~= ACTIVE or not targetRecord.eliminatedCurrentLife then
		return false
	end
	if not attacker then
		return true
	end
	local attackerRecord = records[attacker]
	if not attackerRecord or attackerRecord.participation ~= ACTIVE then
		return false
	end
	return MatchRulesCore.CanTeamDamage(
		rules.TeamMode,
		rules.FriendlyFire,
		attackerRecord.teamId,
		targetRecord.teamId,
		attacker == target
	)
end

-- A CopyToBodyQue entity has no client/team pointer in Q3. G_Damage therefore
-- retains only the current-level/intermission gate and attacker's client
-- participation; team protection and self-damage scaling do not apply.
function MatchService.CanAuthorizedAttackDamageBodyQueue(attacker: Player?, shotMatchId: string?): boolean
	if type(shotMatchId) ~= "string" or shotMatchId == "" or shotMatchId ~= currentMatchId or not isCombatEnabled() then
		return false
	end
	if not attacker then
		return true
	end
	local attackerRecord = records[attacker]
	return attackerRecord ~= nil and attackerRecord.participation == ACTIVE
end

function MatchService.AreOpponents(left: Player, right: Player): boolean
	if left == right then
		return false
	end
	local leftRecord = records[left]
	local rightRecord = records[right]
	if
		not leftRecord
		or not rightRecord
		or leftRecord.participation ~= ACTIVE
		or rightRecord.participation ~= ACTIVE
	then
		return false
	end
	return not rules.TeamMode or leftRecord.teamId ~= rightRecord.teamId
end

function MatchService.CanPlayerSpawn(player: Player): boolean
	local record = records[player]
	if not record or record.participation ~= ACTIVE then
		return false
	end
	return not rules.RoundBased or state ~= MatchConfig.States.Live or record.roundEligible
end

function MatchService.CanSelectWeapon(player: Player, weaponId: number): boolean
	local record = records[player]
	return record ~= nil and record.participation == ACTIVE and rules.AllowedWeaponIds[weaponId] == true
end

function MatchService.CanUsePickups(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.participation == ACTIVE and rules.PickupsEnabled
end

function MatchService.GetSpawnLoadout(_player: Player): SpawnLoadout
	return {
		health = rules.SpawnHealth,
		maxHealth = rules.MaximumHealth,
		armor = rules.SpawnArmor,
		weaponId = rules.SpawnWeaponId,
		respawnDelaySeconds = rules.RespawnDelaySeconds,
		armorEnabled = rules.ArmorEnabled,
		pickupsEnabled = rules.PickupsEnabled,
	}
end

function MatchService.NotifyPlayerRespawned(player: Player): boolean
	if not started or player.Parent ~= Players then
		return false
	end
	table.insert(pendingRosterIntents, {
		kind = "Respawned",
		player = player,
	})
	return true
end

function MatchService.ReportElimination(
	victim: Player,
	attacker: Player?,
	means: string?,
	bypassCombatEligibility: boolean?,
	evaluationTimeMilliseconds: number?
): EliminationResult
	if evaluationTimeMilliseconds ~= nil then
		assert(
			isNonnegativeInteger(evaluationTimeMilliseconds),
			"trusted elimination evaluation time must be a bounded nonnegative integer"
		)
	end
	local token, beginError = MatchService.BeginEliminationBatch(evaluationTimeMilliseconds)
	if not token then
		error(beginError or "unable to begin elimination batch")
	end
	local staged, stageError = MatchService.StageElimination(token, victim, attacker, means, bypassCombatEligibility)
	if not staged then
		MatchService.AbortEliminationBatch(token)
		error(stageError or "unable to stage elimination")
	end
	if not staged.result.accepted then
		MatchService.AbortEliminationBatch(token)
		return staged.result
	end

	local sealed, sealError = MatchService.SealEliminationBatch(token)
	if not sealed then
		MatchService.AbortEliminationBatch(token)
		error(sealError or "unable to seal elimination batch")
	end
	local prepared, prepareError = MatchService.PrepareEliminationBatch(token)
	if not prepared then
		MatchService.AbortEliminationBatch(token)
		error(prepareError or "unable to prepare elimination batch")
	end
	local canApply, canApplyError = MatchService.CanApplyPreparedEliminationBatch(prepared)
	if not canApply then
		MatchService.AbortEliminationBatch(token)
		error(canApplyError or "unable to preflight elimination batch")
	end
	local receipt = MatchService.ApplyPreparedEliminationBatch(prepared)
	local attributesReport, attributesError = MatchService.FlushPreparedEliminationAttributes(receipt)
	if not attributesReport then
		warn(attributesError or "prepared Match attribute publication failed")
		return staged.result
	end
	local observersReport, observersError = flushPreparedEliminationObservers(receipt, true)
	if not observersReport then
		warn(observersError or "prepared Match observer publication failed")
	elseif attributesReport.faultCount + observersReport.faultCount > 0 then
		warn("prepared Match elimination committed with isolated publication faults")
	end
	return staged.result
end

function MatchService.ReportTeamObjective(
	teamId: TeamId,
	points: number,
	reason: string?,
	actor: Player?
): ObjectiveResult
	local validTeam = teamId == MatchConfig.TeamIds.Red or teamId == MatchConfig.TeamIds.Blue
	if
		activeAuthoritativeFrame == nil
		or activeAuthoritativeFrameSummary == nil
		or not validTeam
		or rules.ScoreType ~= "Captures"
		or not rules.TeamMode
		or not isScoringEnabled()
		or type(points) ~= "number"
		or points ~= points
		or math.abs(points) == math.huge
		or points % 1 ~= 0
		or points < 1
		or points > 10
	then
		return {
			accepted = false,
			matchEnded = false,
			teamScore = teamScores[teamId] or 0,
		}
	end

	local actorRecord = if actor then records[actor] else nil
	if actor and (not actorRecord or actorRecord.participation ~= ACTIVE or actorRecord.teamId ~= teamId) then
		return {
			accepted = false,
			matchEnded = false,
			teamScore = teamScores[teamId] or 0,
		}
	end

	teamScores[teamId] = (teamScores[teamId] or 0) + points
	-- AddTeamScore changes only the CTF team bucket. g_team.c awards the
	-- carrier's personal CTF_CAPTURE_BONUS separately through AddScore.

	local endingUsers: { number } = {}
	local endingTeams: { TeamId } = {}
	local matchEnded = false
	local scoreLimitTie = false
	if suddenDeath then
		matchEnded, endingUsers, endingTeams = resolveUniqueLeader()
	else
		local limitState = resolveConfiguredScoreLimitState(rules.ScoreLimit)
		if limitState == MatchRulesCore.ScoreLimitStates.UniqueLeaderAtLimit then
			matchEnded, endingUsers, endingTeams = resolveUniqueLeader()
		elseif limitState == MatchRulesCore.ScoreLimitStates.TiedAtLimit then
			scoreLimitTie = true
		end
	end
	if matchEnded then
		queueIntermission(if suddenDeath then "SuddenDeath" else reason or "CaptureLimit", endingUsers, endingTeams)
	elseif scoreLimitTie then
		enterSuddenDeath(MatchRulesCore.SuddenDeathBases.ScoreLimit)
	else
		snapshotDirty = true
	end
	return {
		accepted = true,
		matchEnded = matchEnded,
		teamScore = teamScores[teamId],
	}
end

function MatchService.AwardObjectiveBonus(player: Player, points: number, _reason: string): boolean
	local record = records[player]
	if
		activeAuthoritativeFrame == nil
		or activeAuthoritativeFrameSummary == nil
		or rules.ScoreType ~= "Captures"
		or not isScoringEnabled()
		or not record
		or record.participation ~= ACTIVE
		or type(points) ~= "number"
		or points % 1 ~= 0
		or points < 0
		or points > 100
	then
		return false
	end
	if points > 0 then
		record.score += points
		syncPlayerAttributes(player)
		snapshotDirty = true
	end
	return true
end

local function applyModeRules(nextRules: Rules, reason: string?, restartAfter: boolean)
	rules = nextRules
	Players.RespawnTime = rules.ForcedRespawnSeconds
	matchNumber = 0
	currentMatchId = nil
	currentMatchLineage = nil
	round = 0
	roundStatus = "Inactive"
	suddenDeath = false
	suddenDeathBasis = nil
	invalidatePendingRoundResolution()
	winnerUserIds = {}
	winnerTeamIds = {}
	lastRoundWinnerUserIds = {}
	lastRoundWinnerTeamIds = {}
	lastRoundEndReason = nil
	resetRosterForMode()
	resetMatchProgress()
	notifyAuthorityMode(rules.ModeId, rules)
	publishOutward(function()
		modeChangedBindable:Fire(rules.ModeId, rules)
	end)

	if restartAfter then
		restart(reason or "ModeChanged")
	end
	snapshotDirty = true
end

function MatchService.SelectMode(modeId: string, reason: string?): (boolean, string?)
	local nextRules = MatchConfig.GetMode(modeId)
	if not nextRules then
		return false, "UnknownMode"
	end
	local available, unavailableReason = MatchService.IsModeAvailable(modeId)
	if not available then
		return false, unavailableReason
	end
	if nextRules.ModeId == rules.ModeId and pendingModeIntent == nil then
		return true, nil
	end
	if not started then
		applyModeRules(nextRules, reason, false)
		return true, nil
	end
	pendingModeIntent = table.freeze({
		modeId = nextRules.ModeId,
		reason = reason or "ModeChanged",
	})
	return true, nil
end

function MatchService.Restart(reason: string?)
	assert(started, "MatchService must be started before Restart")
	pendingRestartReason = reason or "ManualRestart"
end

function MatchService.OnStateChanged(callback: SnapshotCallback): RBXScriptConnection
	return stateChangedBindable.Event:Connect(callback)
end

function MatchService.OnAuthorityStateChanged(callback: SnapshotCallback)
	assert(
		activeAuthoritativeFrame == nil and #authorityStateCallbacks < 32,
		"Match authority state observer registration is closed"
	)
	table.insert(authorityStateCallbacks, callback)
end

function MatchService.OnSnapshotChanged(callback: SnapshotCallback): RBXScriptConnection
	return snapshotChangedBindable.Event:Connect(callback)
end

function MatchService.OnModeChanged(callback: ModeCallback): RBXScriptConnection
	return modeChangedBindable.Event:Connect(callback)
end

function MatchService.OnAuthorityModeChanged(callback: ModeCallback)
	assert(
		activeAuthoritativeFrame == nil and #authorityModeCallbacks < 32,
		"Match authority mode observer registration is closed"
	)
	table.insert(authorityModeCallbacks, callback)
end

function MatchService.OnEliminationRecorded(callback: EliminationCallback): RBXScriptConnection
	return eliminationBindable.Event:Connect(callback)
end

function MatchService.OnAuthorityEliminationRecorded(callback: EliminationCallback)
	assert(
		activeAuthoritativeFrame == nil and #authorityEliminationCallbacks < 32,
		"Match authority elimination observer registration is closed"
	)
	table.insert(authorityEliminationCallbacks, callback)
end

function MatchService.OnRespawnRequested(callback: RespawnCallback): RBXScriptConnection
	return respawnRequestedBindable.Event:Connect(callback)
end

function MatchService.SetRespawnHandler(callback: RespawnCallback)
	assert(synchronousRespawnHandler == nil, "MatchService synchronous respawn handler is already configured")
	synchronousRespawnHandler = callback
end

local function applyPendingControlIntents()
	local modeIntent = pendingModeIntent
	pendingModeIntent = nil
	if modeIntent then
		local nextRules =
			assert(MatchConfig.GetMode(modeIntent.modeId), "queued Match mode disappeared from immutable configuration")
		applyModeRules(nextRules, modeIntent.reason, true)
	end
	local restartReason = pendingRestartReason
	pendingRestartReason = nil
	if restartReason and not modeIntent then
		restart(restartReason)
	end
end

function MatchService.BeginAuthoritativeFrame(frameValue: unknown)
	assert(started, "MatchService must start before its authoritative frame phase")
	assert(not publicationQuarantined, "MatchService authoritative frame is quarantined")
	assert(
		activeAuthoritativeFrame == nil and activeAuthoritativeFrameSummary == nil,
		"MatchService already has an open authoritative frame"
	)
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	assert(summary, "MatchService received a stale authoritative frame")
	assert(
		MatchFrameRules.ShouldRunFrame(lastProcessedFrameLevelTimeMilliseconds, summary.currentTimeMilliseconds),
		"MatchService authoritative frame ran twice"
	)
	activeAuthoritativeFrame = frameValue :: AuthoritativeFrameService.Frame
	activeAuthoritativeFrameSummary = summary
	assert(
		pendingFramePublicationOwner == nil and #pendingFramePublicationCallbacks == 0,
		"Match publication callbacks survived into the next frame"
	)
	applyPendingControlIntents()
	applyPendingRosterIntents()
end

function MatchService.EndAuthoritativeFrame(frameValue: unknown)
	local frame = activeAuthoritativeFrame
	local summary = activeAuthoritativeFrameSummary
	assert(frame and summary, "MatchService has no open authoritative frame to end")
	assert(frameValue == frame, "MatchService post-ClientEndFrame phase received another frame")
	assert(
		AuthoritativeFrameService.ValidateFrameDependency(frame, summary),
		"MatchService authoritative frame became stale before post-ClientEndFrame"
	)
	assert(
		MatchEliminationPreparedRegistry.GetActive(eliminationPreparedRegistry) == nil,
		"Match elimination batch survived to ClientEndFrame"
	)

	local resolution = pendingRoundResolution
	pendingRoundResolution = nil
	if resolution then
		runEliminationRoundResolution(resolution.generation, resolution.round, resolution.modeId, resolution.reason)
	end

	if not lifecycleBootstrapped then
		lifecycleBootstrapped = true
		if hasEnoughPlayers() then
			enterWarmup()
		else
			enterWaiting(nil)
		end
	else
		-- Q3 runs CheckTournament and then CheckExitRules after the complete
		-- ClientEndFrame pass. The custom Waiting/Warmup/round policy is resolved
		-- here once on the same integer level.time.
		advanceLifecycle()
	end

	local snapshotIntervalMilliseconds = durationMilliseconds(rules.SnapshotIntervalSeconds)
	if
		snapshotDirty
		or summary.currentTimeMilliseconds - lastSnapshotAtMilliseconds >= snapshotIntervalMilliseconds
	then
		local snapshot = publishSnapshot()
		if stateChangedDirty then
			notifyAuthorityState(snapshot)
			publishOutward(function()
				stateChangedBindable:Fire(snapshot)
			end)
			stateChangedDirty = false
		end
	end

	lastProcessedFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
	lastFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
	lastFrameServerTimeSeconds = summary.currentServerTimeSeconds
	pendingFramePublicationOwner = frame
	activeAuthoritativeFrame = nil
	activeAuthoritativeFrameSummary = nil
end

function MatchService.FlushAuthoritativeFramePublications(frameValue: unknown)
	assert(
		pendingFramePublicationOwner ~= nil and frameValue == pendingFramePublicationOwner,
		"Match publication flush received another frame"
	)
	local callbacks = pendingFramePublicationCallbacks
	pendingFramePublicationCallbacks = {}
	pendingFramePublicationOwner = nil
	local failed = false
	for _, callback in callbacks do
		if not pcall(callback) then
			failed = true
		end
	end
	assert(not failed, "Match outward publication callback failed")
end

function MatchService.HandleSimulationFault()
	if publicationQuarantined then
		return
	end
	publicationQuarantined = true
	pendingFramePublicationCallbacks = {}
	pendingFramePublicationOwner = nil
	activeAuthoritativeFrame = nil
	activeAuthoritativeFrameSummary = nil
end

export type IntegerClockDebugSnapshot = {
	read frameOpen: boolean,
	read bootstrapped: boolean,
	read lastProcessedLevelTimeMilliseconds: number,
	read stateStartedAtMilliseconds: number,
	read stateEndsAtMilliseconds: number?,
	read roundSetupDeadlineMilliseconds: number?,
	read lastSnapshotAtMilliseconds: number,
	read intermissionQualifiedAtMilliseconds: number?,
	read intermissionStartsAtMilliseconds: number?,
}

function MatchService.GetIntegerClockDebugSnapshot(): IntegerClockDebugSnapshot
	return table.freeze({
		frameOpen = activeAuthoritativeFrame ~= nil,
		bootstrapped = lifecycleBootstrapped,
		lastProcessedLevelTimeMilliseconds = lastProcessedFrameLevelTimeMilliseconds,
		stateStartedAtMilliseconds = stateStartedAtMilliseconds,
		stateEndsAtMilliseconds = stateEndsAtMilliseconds,
		roundSetupDeadlineMilliseconds = roundSetupDeadlineMilliseconds,
		lastSnapshotAtMilliseconds = lastSnapshotAtMilliseconds,
		intermissionQualifiedAtMilliseconds = if queuedIntermission
			then queuedIntermission.qualifiedAtMilliseconds
			else nil,
		intermissionStartsAtMilliseconds = if queuedIntermission then queuedIntermission.startsAtMilliseconds else nil,
	})
end

function MatchService.Start(initialModeId: string?, runtimeMapData: RuntimeMap)
	assert(not started, "MatchService.Start may only be called once")
	assert(type(runtimeMapData) == "table", "MatchService.Start requires a runtime map")
	runtimeMap = runtimeMapData

	local requestedModeId = initialModeId or rules.ModeId
	local selected, selectError = MatchService.SelectMode(requestedModeId, "InitialMode")
	if not selected then
		local fallbackModeId: ModeId? = nil
		for _, modeId in MatchConfig.ModeOrder do
			if MatchService.IsModeAvailable(modeId) then
				fallbackModeId = modeId
				break
			end
		end
		assert(
			fallbackModeId ~= nil,
			string.format(
				"Runtime map supports no match mode (requested %s: %s)",
				requestedModeId,
				selectError or "Unavailable"
			)
		)
		warn(
			string.format(
				"Runtime map rejected initial mode %s (%s); using %s",
				requestedModeId,
				selectError or "Unavailable",
				fallbackModeId
			)
		)
		local fallbackSelected, fallbackError = MatchService.SelectMode(fallbackModeId, "InitialModeFallback")
		assert(fallbackSelected, fallbackError or "Unable to select fallback match mode")
	end
	started = true

	local network = ensureNetworkFolder()
	snapshotRemote = ensureRemote(network, RemoteNames.MatchSnapshot)
	local loadingPresentationReadyRemote = ensureRemote(network, RemoteNames.LoadingPresentationReady)
	loadingPresentationReadyRemote.OnServerEvent:Connect(markLoadingPresentationReady)
	local loadingPresentationFailedRemote = ensureRemote(network, RemoteNames.LoadingPresentationFailed)
	loadingPresentationFailedRemote.OnServerEvent:Connect(markLoadingPresentationFailed)
	startLoadingPresentationWatchdog()
	Players.RespawnTime = rules.ForcedRespawnSeconds

	for _, player in Players:GetPlayers() do
		table.insert(pendingRosterIntents, {
			kind = "Add",
			player = player,
		})
	end
	Players.PlayerAdded:Connect(function(player: Player)
		table.insert(pendingRosterIntents, {
			kind = "Add",
			player = player,
		})
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		loadingPresentationReadyPlayers[player] = nil
		table.insert(pendingRosterIntents, {
			kind = "Remove",
			player = player,
		})
	end)
end

return table.freeze(MatchService)
