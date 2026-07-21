--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-authoritative mover damage transaction coordinator extracted from
CombatService. Translates the g_mover.c -> G_Damage ordering already mapped by
the host combat engine without changing authority or publication order.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MatchEliminationShadowRules =
	require(sharedRoot:WaitForChild("match"):WaitForChild("MatchEliminationShadowRules"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local OneShotRules = require(sharedRoot.combat.OneShotRules)
local Movement = require(sharedRoot.simulation.Movement)
local MoverConsequenceRules = require(sharedRoot.simulation.MoverConsequenceRules)
local MoverPushRules = require(sharedRoot.simulation.MoverPushRules)
local WeaponDefinitions = require(sharedRoot.combat.WeaponDefinitions)
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local CorpseService = require(script.Parent.CorpseService)
local MatchService = require(script.Parent.MatchService)
local MovementService = require(script.Parent.MovementService)

export type EliminationEvent = {
	kind: string,
	eventId: string,
	shotId: string,
	weaponId: number,
	serverFrame: number,
	revision: number,
	position: Vector3,
	targetUserId: number,
	attackerUserId: number,
	scoringUserId: number,
	means: string,
	isSuicide: boolean,
	isWorldKill: boolean,
	scoreDelta: number,
	attackerScore: number,
	targetScore: number,
	targetDeaths: number,
	targetLifeSequence: number,
	effectId: string?,
}

type WeaponState = "Ready" | "Firing" | "Dropping" | "Raising"

type CombatRecord = {
	health: number,
	baseHealth: number,
	armor: number,
	alive: boolean,
	score: number,
	deaths: number,
	-- weaponId is the source-faithful active ps.weapon. commandWeaponId is
	-- the latest pers.cmd.weapon and may differ during a switch.
	weaponId: number,
	commandWeaponId: number,
	weaponState: WeaponState,
	-- Q3 ps.weaponTime is one signed integer counter shared by firing,
	-- dropping, raising, and no-ammo. Negative Pmove overshoot is retained.
	weaponTimeMilliseconds: number,
	ownedWeapons: { [number]: boolean },
	ammoByWeapon: { [number]: number },
	infiniteAmmo: boolean,
	lastRespawnRequestSequence: number,
	-- Acknowledges the movement usercmd that most recently changed or rejected
	-- repeated weapon intent; this shares InputCommand's wrap-safe sequence.
	lastWeaponCommandSequence: number,
	lastWeaponIntentId: number,
	lastWeaponPmoveLevelTimeMilliseconds: number,
	lastPrePmoveGauntletLevelTimeMilliseconds: number,
	rateWindowStart: number,
	rateWindowCount: number,
	shotsFired: number,
	accuracyShots: number,
	accuracyHits: number,
	accuracyMatchId: string?,
	noAmmoEvents: number,
	lifeSequence: number,
	movementLifeBinding: MovementService.MovementLifeBinding?,
	serverShotSequence: number,
	lastShotId: string,
	character: Model?,
	-- Q3 client->timeResidual, stored as exact integer milliseconds.
	overstackAccumulator: number,
	powerupExpiries: { [number]: number },
	respawnEligibleAtMilliseconds: number?,
	forcedRespawnAtMilliseconds: number?,
	manualRespawnQueued: boolean,
	respawnRequested: boolean,
	lastDroppedLifeSequence: number,
	lastLandingFrame: number,
	lastLandingContactIndex: number,
}

export type DeathWeaponDropRequest = {
	dropId: string,
	matchId: string,
	itemId: string,
	quantity: number,
	position: Vector3,
	velocity: Vector3,
}

type ShotContext = {
	id: string,
	matchId: string?,
	lifeSequence: number,
	weaponId: number,
	ownerUserId: number,
	revision: number,
	clientSequence: number,
	serverFrame: number,
	levelTimeMilliseconds: number?,
	firedAtServerTime: number?,
	eventSequence: number,
	seed: number,
	inputReceivedServerTime: number?,
}

type MoverDamageStatus =
	"Open"
	| "Sealed"
	| "Prepared"
	| "Applied"
	| "Flushed"
	| "Committing"
	| "Committed"
	| "Aborted"
	| "Faulted"

type MoverDamageToken = {}
export type MoverDamagePrepared = {}
export type MoverDamageApplyReceipt = {}
export type MoverDamageStageReceipt = {}
export type MoverDamagePublicationReport = {
	read authorityApplied: boolean,
	read operationCount: number,
	read publicationCount: number,
	read publicationFaultCount: number,
}

export type MoverDamageContext = {
	read id: string,
	read matchId: string?,
	read lifeSequence: number,
	read weaponId: number,
	read ownerUserId: number,
	read revision: number,
	read clientSequence: number,
	read serverFrame: number,
	read levelTimeMilliseconds: number,
	read firedAtServerTime: number,
	read seed: number,
	read inputReceivedServerTime: number?,
}

export type MoverMatchExpectation = {
	read outcome: MatchEliminationShadowRules.EliminationOutcome,
	read scoreKind: MatchEliminationShadowRules.ScoreKind,
	read levelTimeMilliseconds: number,
	read redScore: number,
	read blueScore: number,
	read terminal: MatchEliminationShadowRules.TerminalLatch?,
	read suddenDeath: boolean,
}

type MoverDamageShadow = {
	player: Player,
	record: CombatRecord,
	sourceOrder: number,
	lifeSequence: number,
	startingHealth: number,
	startingArmor: number,
	startingAlive: boolean,
	startingCanFight: boolean,
	health: number,
	armor: number,
	alive: boolean,
}

type MoverDamageOperation = {
	read kind: "LivePlayer" | "ClientCorpse",
	read player: Player,
	read record: CombatRecord,
	read sourceOrder: number,
	read lifeSequence: number,
	read rawDamage: number,
	read beforeHealth: number,
	read beforeArmor: number,
	read beforeAlive: boolean,
	-- G_Damage subtracts health before player_die classifies a corpse/gib. The
	-- public CombatRecord still canonicalizes an accepted lethal to zero, but
	-- the mover consequence layer must retain this raw bounded value.
	read rawPostDamageHealth: number,
	read afterHealth: number,
	read afterArmor: number,
	read afterAlive: boolean,
	read operationIndex: number,
	read body: MoverPushRules.Body,
	read context: MoverDamageContext,
	read moverDeathSource: MovementService.MoverDeathSource?,
	read moverDeathSourceSummary: MovementService.MoverDeathSourceSummary?,
	read moverDeathStageReceipt: MoverDamageStageReceipt?,
	read matchExpectation: MoverMatchExpectation?,
	read beforeCorpseHealth: number?,
	read afterCorpseHealth: number?,
	read deathPosition: Vector3?,
	read deathWeaponDrop: DeathWeaponDropRequest?,
}

type MoverDamageStageReceiptStatus = "PendingClaim" | "Staged" | "Prepared" | "Retired"
type MoverDamageStageReceiptCapability = {
	receipt: MoverDamageStageReceipt,
	status: MoverDamageStageReceiptStatus,
	transaction: MoverDamageTransaction,
	player: Player,
	body: MoverPushRules.Body,
	moverId: string,
	operationIndex: number,
	context: MoverDamageContext,
	moverDeathSource: MovementService.MoverDeathSource,
	moverDeathSourceSummary: MovementService.MoverDeathSourceSummary,
}

export type MoverDamageMatchDependencySummary = {
	read matchId: string?,
	read matchState: string,
	read levelTimeMilliseconds: number,
	read operationCount: number,
	read baseShadow: MatchEliminationShadowRules.State,
	read finalShadow: MatchEliminationShadowRules.State,
	read outcomes: { MatchEliminationShadowRules.EliminationOutcome },
	read terminal: MatchEliminationShadowRules.TerminalLatch?,
	read damageOpenAfter: boolean,
	read startingIntermissionQueued: boolean,
	read startingSuddenDeath: boolean,
	read finalSuddenDeath: boolean,
}

export type MoverDamageMovementDependencySummary = {
	read releaseSpawnPlayers: { Player },
	read lifeBindings: { MoverDamageMovementLifeDependency },
	read lethalMoverSources: { MoverDamageLethalSourceDependency },
}

export type MoverDamageLethalSourceDependency = {
	read player: Player,
	read source: MovementService.MoverDeathSource,
	read sourceSummary: MovementService.MoverDeathSourceSummary,
	read stageReceipt: MoverDamageStageReceipt,
	read body: MoverPushRules.Body,
	read operationIndex: number,
	read context: MoverDamageContext,
}

export type MoverDamageMovementLifeDependency = {
	read player: Player,
	read binding: MovementService.MovementLifeBinding,
	read summary: MovementService.MovementLifeBindingSummary,
}

type MoverDamagePreparedMutation = {
	read player: Player,
	read record: CombatRecord,
	read lifeSequence: number,
	read beforeHealth: number,
	read beforeArmor: number,
	read beforeAlive: boolean,
	read beforeScore: number,
	read beforeDeaths: number,
	read beforeWeaponId: number,
	read beforeCommandWeaponId: number,
	read beforeWeaponState: WeaponState,
	read beforeWeaponTimeMilliseconds: number,
	read beforeLastWeaponPmoveLevelTimeMilliseconds: number,
	read beforeLastPrePmoveGauntletLevelTimeMilliseconds: number,
	read beforeOverstackAccumulator: number,
	read beforePowerupExpiries: { [number]: number },
	read beforeRespawnEligibleAtMilliseconds: number?,
	read beforeForcedRespawnAtMilliseconds: number?,
	read beforeManualRespawnQueued: boolean,
	read beforeRespawnRequested: boolean,
	read beforeLastDroppedLifeSequence: number,
	read beforeOwnedWeapons: { [number]: boolean },
	read beforeAmmoByWeapon: { [number]: number },
	read beforeInfiniteAmmo: boolean,
	read beforeMovementLifeBinding: MovementService.MovementLifeBinding?,
	read beforeCharacter: Model?,
	read afterHealth: number,
	read afterArmor: number,
	read afterAlive: boolean,
	read lethal: boolean,
	read afterWeaponId: number,
	read afterCommandWeaponId: number,
	read afterWeaponState: WeaponState,
	read afterWeaponTimeMilliseconds: number,
	read afterOverstackAccumulator: number,
	read afterPowerupExpiries: { [number]: number },
	read afterForcedRespawnAtMilliseconds: number?,
	read afterManualRespawnQueued: boolean,
	read afterRespawnRequested: boolean,
	read afterScore: number,
	read afterDeaths: number,
	read afterLastDroppedLifeSequence: number,
	read shouldRespawn: boolean,
	read respawnEligibleAtMilliseconds: number?,
	read forcedRespawnAtMilliseconds: number?,
	read deathWeaponDrop: DeathWeaponDropRequest?,
}

type MoverDamagePreparedPublication = {
	read player: Player,
	read record: CombatRecord,
	read damagePayload: { [string]: any }?,
	read elimination: EliminationEvent?,
}

type MoverDamagePreparedCapabilityStatus = "Prepared" | "Applied" | "Flushed" | "Aborted"
type MoverDamagePreparedCapability = {
	transaction: MoverDamageTransaction,
	status: MoverDamagePreparedCapabilityStatus,
	prepared: MoverDamagePrepared,
	receipt: MoverDamageApplyReceipt,
	corpsePrepared: CorpseService.PreparedCommit,
	dependencySummary: MoverDamageMatchDependencySummary,
	movementDependencySummary: MoverDamageMovementDependencySummary,
	boundMatchPrepared: unknown?,
	boundMatchSummary: unknown?,
	matchApplyReceipt: unknown?,
	matchDependencySatisfied: boolean,
	mutations: { MoverDamagePreparedMutation },
	publications: { MoverDamagePreparedPublication },
	applyValidated: boolean,
}

type MoverDamageTransaction = {
	token: MoverDamageToken,
	corpseToken: CorpseService.TransactionToken,
	status: MoverDamageStatus,
	stepServerTime: number,
	levelTimeMilliseconds: number,
	matchId: string?,
	matchState: string,
	startingMatchShadow: MatchEliminationShadowRules.State,
	matchShadow: MatchEliminationShadowRules.State,
	oneShot: boolean,
	startingCombatEnabled: boolean,
	startingIntermissionQueued: boolean,
	startingSuddenDeath: boolean,
	expectedSuddenDeath: boolean,
	shadows: { [Player]: MoverDamageShadow },
	operations: { MoverDamageOperation },
	stageReceipts: { MoverDamageStageReceipt },
	matchToken: unknown?,
	finalCorpseCollection: CorpseService.Collection?,
	prepared: MoverDamagePrepared?,
}

export type MoverDamageAdapter = {
	read Begin: (stepServerTime: number) -> (unknown?, string?),
	read CollectBodies: (token: unknown) -> ({ MoverPushRules.Body }?, { [string]: Player }?, string?),
	read StageSineCrush: (
		token: unknown,
		player: Player,
		moverId: string,
		body: MoverPushRules.Body,
		moverDeathSource: MovementService.MoverDeathSource?,
		moverDeathSourceSummary: MovementService.MoverDeathSourceSummary?
	) -> (MoverPushRules.SynchronousCrushTransition?, string?),
	read StageDoorDamage: (
		token: unknown,
		player: Player,
		moverId: string,
		damage: number,
		body: MoverPushRules.Body,
		moverDeathSource: MovementService.MoverDeathSource?,
		moverDeathSourceSummary: MovementService.MoverDeathSourceSummary?
	) -> (MoverPushRules.SynchronousCrushTransition?, string?),
	read ValidateMoverDeathStageReceipt: (
		token: unknown,
		stageReceipt: unknown,
		moverDeathSource: unknown,
		moverDeathSourceSummary: unknown
	) -> (boolean, string?),
	read IsAlive: (token: unknown, player: Player) -> boolean?,
	read ApplyMoverBodies: (token: unknown, bodies: { MoverPushRules.Body }) -> (boolean, string?),
	read Seal: (token: unknown) -> (boolean, string?),
	read Prepare: (token: unknown) -> (MoverDamagePrepared?, MoverDamageMatchDependencySummary?, string?),
	read BindMatchPreparedDependency: (
		prepared: unknown,
		matchPrepared: unknown,
		matchSummary: unknown
	) -> (boolean, string?),
	read InspectPreparedMovementDependency: (prepared: unknown) -> MoverDamageMovementDependencySummary?,
	read ValidatePreparedMovementDependency: (prepared: unknown, summary: unknown) -> (boolean, string?),
	read CanApplyPrepared: (prepared: unknown) -> (boolean, string?),
	read ApplyPrepared: (prepared: unknown) -> MoverDamageApplyReceipt,
	read FlushPrepared: (receipt: unknown) -> MoverDamagePublicationReport,
	read Abort: (token: unknown) -> boolean,
}

export type Host = {
	records: { [Player]: CombatRecord },
	isStarted: () -> boolean,
	makeEnvironmentContext: (Player, CombatRecord, number?) -> ShotContext,
	buildDeathWeaponDrop: (...any) -> ...any,
	broadcast: (payload: { [string]: any }) -> (),
	setCharacterCombatQuery: (character: Model?, enabled: boolean) -> (),
	publishPreparedDeathWeaponDrop: (request: DeathWeaponDropRequest?) -> (),
	stageSynchronousMoverDeathWeaponDrop: (
		request: DeathWeaponDropRequest,
		operationOrder: number
	) -> (MoverPushRules.Body?, string?),
	stageSynchronousMoverPowerupDrops: (
		player: Player,
		record: CombatRecord,
		position: Vector3,
		levelTimeMilliseconds: number,
		operationOrder: number
	) -> ({ MoverPushRules.Body }?, string?),
	stageSynchronousMoverFlagDrops: (
		player: Player,
		position: Vector3,
		operationOrder: number
	) -> ({ MoverPushRules.Body }?, string?),
	syncHumanoidHealth: (record: CombatRecord) -> (),
	publishPlayerRecord: (player: Player, record: CombatRecord) -> (),
	emitElimination: (elimination: EliminationEvent) -> (),
}

local CombatMoverDamageCoordinator = {}

function CombatMoverDamageCoordinator.new(host: Host): MoverDamageAdapter
	local records = host.records
	local isStarted = host.isStarted
	local makeEnvironmentContext = host.makeEnvironmentContext
	local buildDeathWeaponDrop = host.buildDeathWeaponDrop
	local broadcast = host.broadcast
	local setCharacterCombatQuery = host.setCharacterCombatQuery
	local stageSynchronousMoverDeathWeaponDrop = host.stageSynchronousMoverDeathWeaponDrop
	local stageSynchronousMoverPowerupDrops = host.stageSynchronousMoverPowerupDrops
	local stageSynchronousMoverFlagDrops = host.stageSynchronousMoverFlagDrops
	local syncHumanoidHealth = host.syncHumanoidHealth
	local publishPlayerRecord = host.publishPlayerRecord
	local emitElimination = host.emitElimination
	local activeMoverDamageToken: MoverDamageToken? = nil
	local activeMoverDamageTransaction: MoverDamageTransaction? = nil
	local moverDamagePreparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[MoverDamagePrepared]: MoverDamagePreparedCapability,
	}
	local moverDamageReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[MoverDamageApplyReceipt]: MoverDamagePreparedCapability,
	}
	local moverDeathSourceOwner = {
		stageReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
			[MoverDamageStageReceipt]: MoverDamageStageReceiptCapability,
		},
	}

	local function isFinite(value: unknown): boolean
		return type(value) == "number" and value == value and math.abs(value) < math.huge
	end

	local function getActiveMoverDamageTransaction(
		token: unknown,
		requiredStatus: MoverDamageStatus?
	): (MoverDamageTransaction?, string?)
		local transaction = activeMoverDamageTransaction
		if
			type(token) ~= "table"
			or token ~= activeMoverDamageToken
			or not transaction
			or transaction.token ~= token
		then
			return nil, "invalid-mover-damage-token"
		end
		if requiredStatus and transaction.status ~= requiredStatus then
			return nil, "invalid-mover-damage-state"
		end
		return transaction, nil
	end

	function moverDeathSourceOwner.retireStageReceipts(transaction: MoverDamageTransaction)
		for _, receipt in transaction.stageReceipts do
			local capability = moverDeathSourceOwner.stageReceiptCapabilities[receipt]
			if capability and capability.transaction == transaction then
				capability.status = "Retired"
				moverDeathSourceOwner.stageReceiptCapabilities[receipt] = nil
			end
		end
	end

	local function finishMoverDamageTransaction(transaction: MoverDamageTransaction, status: MoverDamageStatus)
		MovementService.RetireMoverDeathSourcesForDamageToken(transaction.token)
		moverDeathSourceOwner.retireStageReceipts(transaction)
		transaction.status = status
		if activeMoverDamageTransaction == transaction then
			activeMoverDamageTransaction = nil
			activeMoverDamageToken = nil
		end
	end

	local function faultMoverDamageTransaction(
		transaction: MoverDamageTransaction,
		errorCode: string
	): (boolean, string?)
		if transaction.matchToken ~= nil then
			MatchService.AbortEliminationBatch(transaction.matchToken)
			transaction.matchToken = nil
		end
		CorpseService.Abort(transaction.corpseToken)
		finishMoverDamageTransaction(transaction, "Faulted")
		return false, errorCode
	end

	local function captureMoverDamageShadow(
		transaction: MoverDamageTransaction,
		player: Player
	): (MoverDamageShadow?, string?)
		local existing = transaction.shadows[player]
		if existing then
			return existing, nil
		end
		local record = records[player]
		if not record then
			return nil, "missing-combat-record"
		end
		local sourceOrder = MovementService.GetPlayerSourceOrder(player)
		if
			type(sourceOrder) ~= "number"
			or sourceOrder ~= sourceOrder
			or math.abs(sourceOrder) == math.huge
			or sourceOrder % 1 ~= 0
			or sourceOrder < 1
			or sourceOrder > MatchEliminationShadowRules.MaximumClients
		then
			return nil, "invalid-mover-player-source-order"
		end
		local shadow: MoverDamageShadow = {
			player = player,
			record = record,
			sourceOrder = sourceOrder,
			lifeSequence = record.lifeSequence,
			startingHealth = record.health,
			startingArmor = record.armor,
			startingAlive = record.alive,
			startingCanFight = MatchService.CanPlayerFight(player),
			health = record.health,
			armor = record.armor,
			alive = record.alive,
		}
		transaction.shadows[player] = shadow
		return shadow, nil
	end

	local function captureMoverDamageContext(
		transaction: MoverDamageTransaction,
		shadow: MoverDamageShadow,
		moverId: string,
		operationKind: string,
		operationIndex: number
	): MoverDamageContext
		local context = makeEnvironmentContext(shadow.player, shadow.record, transaction.levelTimeMilliseconds)
		return table.freeze({
			id = string.format(
				"mover-%s:%s:%d:%d:%d:%d:%.6f",
				operationKind,
				moverId,
				shadow.player.UserId,
				shadow.lifeSequence,
				context.serverFrame,
				operationIndex,
				transaction.stepServerTime
			),
			matchId = context.matchId,
			lifeSequence = context.lifeSequence,
			weaponId = context.weaponId,
			ownerUserId = context.ownerUserId,
			revision = context.revision,
			clientSequence = context.clientSequence,
			serverFrame = context.serverFrame,
			levelTimeMilliseconds = transaction.levelTimeMilliseconds,
			firedAtServerTime = transaction.stepServerTime,
			seed = context.seed,
			inputReceivedServerTime = context.inputReceivedServerTime,
		})
	end

	function moverDeathSourceOwner.validateStageReceipt(
		token: unknown,
		stageReceiptValue: unknown,
		moverDeathSourceValue: unknown,
		moverDeathSourceSummaryValue: unknown
	): (boolean, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return false, transactionError
		end
		if type(stageReceiptValue) ~= "table" then
			return false, "invalid-mover-death-stage-receipt"
		end
		local receipt = stageReceiptValue :: MoverDamageStageReceipt
		local capability = moverDeathSourceOwner.stageReceiptCapabilities[receipt]
		if
			not capability
			or capability.receipt ~= receipt
			or capability.status ~= "PendingClaim"
			or capability.transaction ~= transaction
			or capability.moverDeathSource ~= moverDeathSourceValue
			or capability.moverDeathSourceSummary ~= moverDeathSourceSummaryValue
			or capability.operationIndex ~= #transaction.operations + 1
			or capability.player ~= capability.moverDeathSourceSummary.victim
			or capability.body ~= capability.moverDeathSourceSummary.victimBody
			or capability.moverId ~= capability.moverDeathSourceSummary.moverId
			or not table.isfrozen(receipt)
			or not table.isfrozen(capability.body)
			or not table.isfrozen(capability.context)
		then
			return false, "stale-mover-death-stage-receipt"
		end
		return true, nil
	end

	function moverDeathSourceOwner.claimOperationSource(
		transaction: MoverDamageTransaction,
		player: Player,
		body: MoverPushRules.Body,
		moverId: string,
		operationIndex: number,
		context: MoverDamageContext,
		moverDeathSource: MovementService.MoverDeathSource,
		moverDeathSourceSummary: MovementService.MoverDeathSourceSummary
	): (MoverDamageStageReceipt?, string?)
		local receipt: MoverDamageStageReceipt = table.freeze({})
		local capability: MoverDamageStageReceiptCapability = {
			receipt = receipt,
			status = "PendingClaim",
			transaction = transaction,
			player = player,
			body = body,
			moverId = moverId,
			operationIndex = operationIndex,
			context = context,
			moverDeathSource = moverDeathSource,
			moverDeathSourceSummary = moverDeathSourceSummary,
		}
		moverDeathSourceOwner.stageReceiptCapabilities[receipt] = capability
		table.insert(transaction.stageReceipts, receipt)
		local claimed, claimError =
			MovementService.ClaimMoverDeathSource(moverDeathSource, moverDeathSourceSummary, receipt)
		if not claimed then
			moverDeathSourceOwner.stageReceiptCapabilities[receipt] = nil
			table.remove(transaction.stageReceipts, #transaction.stageReceipts)
			return nil, claimError or "mover-death-source-claim-failed"
		end
		capability.status = "Staged"
		return receipt, nil
	end

	local function moverMatchTerminalEqual(
		left: MatchEliminationShadowRules.TerminalLatch?,
		right: MatchEliminationShadowRules.TerminalLatch?
	): boolean
		if left == nil or right == nil then
			return left == right
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

	local function moverMatchOutcomeEqual(
		left: MatchEliminationShadowRules.EliminationOutcome,
		right: MatchEliminationShadowRules.EliminationOutcome
	): boolean
		return left.accepted == right.accepted
			and left.rejectionReason == right.rejectionReason
			and left.scored == right.scored
			and left.scoreDelta == right.scoreDelta
			and left.scoringUserId == right.scoringUserId
			and left.victimUserId == right.victimUserId
			and left.victimDeaths == right.victimDeaths
			and left.victimScore == right.victimScore
			and left.attackerScore == right.attackerScore
			and left.scoreTied == right.scoreTied
			and left.tiedAtLimit == right.tiedAtLimit
			and left.terminalQualified == right.terminalQualified
			and moverMatchTerminalEqual(left.terminal, right.terminal)
	end

	local function moverMatchStateEqual(
		left: MatchEliminationShadowRules.State,
		right: MatchEliminationShadowRules.State
	): boolean
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
			or not moverMatchTerminalEqual(left.terminal, right.terminal)
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

	local function makeMoverMatchExpectation(
		state: MatchEliminationShadowRules.State,
		outcome: MatchEliminationShadowRules.EliminationOutcome,
		suddenDeath: boolean
	): MoverMatchExpectation
		return table.freeze({
			outcome = outcome,
			scoreKind = state.scoreKind,
			levelTimeMilliseconds = state.levelTimeMilliseconds,
			redScore = state.redScore,
			blueScore = state.blueScore,
			terminal = state.terminal,
			suddenDeath = suddenDeath,
		})
	end

	local function moverMatchExpectationEqual(left: MoverMatchExpectation, right: MoverMatchExpectation): boolean
		return moverMatchOutcomeEqual(left.outcome, right.outcome)
			and left.scoreKind == right.scoreKind
			and left.levelTimeMilliseconds == right.levelTimeMilliseconds
			and left.redScore == right.redScore
			and left.blueScore == right.blueScore
			and moverMatchTerminalEqual(left.terminal, right.terminal)
			and left.suddenDeath == right.suddenDeath
	end

	local function moverOutcomeEntersSuddenDeath(
		state: MatchEliminationShadowRules.State,
		outcome: MatchEliminationShadowRules.EliminationOutcome,
		levelTimeMilliseconds: number
	): boolean
		return not outcome.terminalQualified
			and (
				outcome.tiedAtLimit
				or (
					outcome.scoreTied
					and state.timeLimitAtMilliseconds >= 0
					and levelTimeMilliseconds >= state.timeLimitAtMilliseconds
				)
			)
	end

	local function validateMoverDamageStartingState(
		transaction: MoverDamageTransaction
	): (string?, MatchEliminationShadowRules.State?)
		if
			MatchService.GetMatchId() ~= transaction.matchId
			or MatchService.GetState() ~= transaction.matchState
			or MatchService.GetRules().OneShot ~= transaction.oneShot
		then
			return "stale-mover-damage-match", nil
		end
		local matchSnapshot = MatchService.GetSnapshot()
		if
			matchSnapshot.matchId ~= transaction.matchId
			or matchSnapshot.state ~= transaction.matchState
			or matchSnapshot.combatEnabled ~= transaction.startingCombatEnabled
			or matchSnapshot.intermissionQueued ~= transaction.startingIntermissionQueued
			or matchSnapshot.suddenDeath ~= transaction.startingSuddenDeath
		then
			return "stale-mover-damage-match-latch", nil
		end
		local replayShadow, replayError = MatchService.CreateMoverEliminationShadow(
			MovementService.GetPlayerSourceOrder,
			transaction.levelTimeMilliseconds
		)
		if not replayShadow then
			return "stale-mover-damage-match-shadow:" .. (replayError or "unavailable"), nil
		end
		if not moverMatchStateEqual(replayShadow, transaction.startingMatchShadow) then
			return "stale-mover-damage-match-shadow", nil
		end
		for player, shadow in transaction.shadows do
			local record = records[player]
			if
				player.Parent ~= Players
				or record ~= shadow.record
				or record.lifeSequence ~= shadow.lifeSequence
				or MovementService.GetPlayerSourceOrder(player) ~= shadow.sourceOrder
			then
				return "stale-mover-damage-identity", nil
			end
			if
				record.health ~= shadow.startingHealth
				or record.armor ~= shadow.startingArmor
				or record.alive ~= shadow.startingAlive
				or MatchService.CanPlayerFight(player) ~= shadow.startingCanFight
			then
				return "stale-mover-damage-state", nil
			end
		end
		return nil, replayShadow
	end

	local function preflightMoverDamageOperations(
		transaction: MoverDamageTransaction,
		replayMatchShadow: MatchEliminationShadowRules.State
	): string?
		local projected: {
			[Player]: {
				health: number,
				armor: number,
				alive: boolean,
			},
		} = {}
		local replaySuddenDeath = transaction.startingSuddenDeath
		for operationIndex, operation in transaction.operations do
			if not MatchEliminationShadowRules.IsDamageOpen(replayMatchShadow) then
				return "mover-damage-operation-after-terminal"
			end
			local shadow = transaction.shadows[operation.player]
			if
				not shadow
				or shadow.record ~= operation.record
				or shadow.sourceOrder ~= operation.sourceOrder
				or shadow.lifeSequence ~= operation.lifeSequence
			then
				return "invalid-mover-damage-operation"
			end
			local before = projected[operation.player]
			if not before then
				before = {
					health = shadow.startingHealth,
					armor = shadow.startingArmor,
					alive = shadow.startingAlive,
				}
			end
			if
				before.health ~= operation.beforeHealth
				or before.armor ~= operation.beforeArmor
				or operation.beforeAlive ~= before.alive
				or not isFinite(operation.rawDamage)
				or operation.rawDamage % 1 ~= 0
				or operation.rawDamage <= 0
				or operation.rawDamage > 100_000
				or operation.operationIndex ~= operationIndex
				or not table.isfrozen(operation.body)
				or not table.isfrozen(operation.context)
			then
				return "invalid-mover-damage-operation"
			end
			local adjustedDamage, armorSave, resolvedHealthDamage =
				WeaponDefinitions.ResolveDamage(operation.rawDamage, before.armor, false)
			local healthDamage = if operation.kind == "LivePlayer"
				then assert(
					OneShotRules.ResolveCrushHealthDamage(transaction.oneShot, before.health, resolvedHealthDamage),
					"One-Shot mover preflight damage input must be valid"
				)
				else resolvedHealthDamage
			local expectedArmor = before.armor - armorSave
			local context = operation.context
			if operation.kind == "ClientCorpse" then
				local beforeCorpseHealth = operation.beforeCorpseHealth
				local afterCorpseHealth = operation.afterCorpseHealth
				if
					adjustedDamage <= 0
					or before.alive
					or before.health ~= 0
					or operation.afterAlive
					or operation.afterHealth ~= 0
					or type(beforeCorpseHealth) ~= "number"
					or type(afterCorpseHealth) ~= "number"
					or operation.rawPostDamageHealth ~= afterCorpseHealth
					or afterCorpseHealth ~= math.max(
						beforeCorpseHealth - healthDamage,
						MoverConsequenceRules.MinimumRawPostDamageHealth
					)
					or operation.afterArmor ~= expectedArmor
					or operation.matchExpectation ~= nil
					or operation.moverDeathSource ~= nil
					or operation.moverDeathSourceSummary ~= nil
					or operation.moverDeathStageReceipt ~= nil
					or context.lifeSequence ~= operation.lifeSequence
					or context.weaponId ~= WeaponDefinitions.WeaponId.None
					or context.ownerUserId ~= 0
				then
					return "invalid-mover-corpse-damage-operation"
				end
				projected[operation.player] = {
					health = 0,
					armor = expectedArmor,
					alive = false,
				}
				continue
			end
			if operation.kind ~= "LivePlayer" or not before.alive or not shadow.startingCanFight then
				return "invalid-mover-damage-operation"
			end
			local moverDeathSource = operation.moverDeathSource
			local moverDeathSourceSummary = operation.moverDeathSourceSummary
			local moverDeathStageReceipt = operation.moverDeathStageReceipt
			local stageCapability = if moverDeathStageReceipt
				then moverDeathSourceOwner.stageReceiptCapabilities[moverDeathStageReceipt]
				else nil
			if
				not moverDeathSource
				or not moverDeathSourceSummary
				or not moverDeathStageReceipt
				or not stageCapability
				or stageCapability.transaction ~= transaction
				or (stageCapability.status ~= "Staged" and stageCapability.status ~= "Prepared")
				or stageCapability.player ~= operation.player
				or stageCapability.body ~= operation.body
				or stageCapability.operationIndex ~= operation.operationIndex
				or stageCapability.context ~= operation.context
				or stageCapability.moverDeathSource ~= moverDeathSource
				or stageCapability.moverDeathSourceSummary ~= moverDeathSourceSummary
				or moverDeathSourceSummary.victim ~= operation.player
				or moverDeathSourceSummary.victimBody ~= operation.body
				or not MovementService.ValidateMoverDeathSourceDependency(moverDeathSource, moverDeathSourceSummary)
			then
				return "invalid-mover-death-source-operation"
			end
			local rawPostDamageHealth = before.health - healthDamage
			local expectedHealth = rawPostDamageHealth
			local expectedAlive = rawPostDamageHealth > 0
			if not expectedAlive then
				expectedHealth = 0
			end
			if
				adjustedDamage <= 0
				or operation.rawPostDamageHealth ~= rawPostDamageHealth
				or operation.afterHealth ~= expectedHealth
				or operation.afterArmor ~= expectedArmor
				or operation.afterAlive ~= expectedAlive
				or context.lifeSequence ~= operation.lifeSequence
				or context.weaponId ~= WeaponDefinitions.WeaponId.None
				or context.ownerUserId ~= 0
			then
				return "invalid-mover-damage-operation"
			end
			projected[operation.player] = {
				health = expectedHealth,
				armor = expectedArmor,
				alive = expectedAlive,
			}
			if expectedAlive then
				if operation.matchExpectation ~= nil then
					return "nonlethal-mover-damage-has-match-outcome"
				end
			else
				local nextMatchShadow, matchOutcome, matchError =
					MatchEliminationShadowRules.StageElimination(replayMatchShadow, {
						operationOrder = replayMatchShadow.lastOperationOrder + 1,
						levelTimeMilliseconds = transaction.levelTimeMilliseconds,
						victimUserId = operation.player.UserId,
						attackerUserId = 0,
						bypassTeamProtection = false,
					})
				if not nextMatchShadow or not matchOutcome or matchError or not matchOutcome.accepted then
					return "invalid-mover-match-elimination"
				end
				local matchPlayer = MatchEliminationShadowRules.GetPlayer(nextMatchShadow, operation.player.UserId)
				if not matchPlayer or matchPlayer.sourceOrder ~= operation.sourceOrder then
					return "invalid-mover-match-player-order"
				end
				replaySuddenDeath = replaySuddenDeath
					or moverOutcomeEntersSuddenDeath(nextMatchShadow, matchOutcome, transaction.levelTimeMilliseconds)
				local expectedMatch = makeMoverMatchExpectation(nextMatchShadow, matchOutcome, replaySuddenDeath)
				if
					not operation.matchExpectation
					or not moverMatchExpectationEqual(operation.matchExpectation, expectedMatch)
				then
					return "invalid-mover-match-expectation"
				end
				replayMatchShadow = nextMatchShadow
			end
		end
		for player, shadow in transaction.shadows do
			local final = projected[player]
			local finalHealth = if final then final.health else shadow.startingHealth
			local finalArmor = if final then final.armor else shadow.startingArmor
			local finalAlive = if final then final.alive else shadow.startingAlive
			if shadow.health ~= finalHealth or shadow.armor ~= finalArmor or shadow.alive ~= finalAlive then
				return "invalid-mover-damage-shadow"
			end
		end
		if
			not moverMatchStateEqual(replayMatchShadow, transaction.matchShadow)
			or replaySuddenDeath ~= transaction.expectedSuddenDeath
		then
			return "invalid-mover-match-shadow"
		end
		return nil
	end

	local function beginMoverDamageTransaction(frameValue: unknown, stepServerTime: number): (unknown?, string?)
		if not isStarted() then
			return nil, "combat-service-not-started"
		end
		if not isFinite(stepServerTime) then
			return nil, "invalid-mover-damage-step-time"
		end
		local frameSummary = AuthoritativeFrameService.InspectFrame(frameValue)
		local frameStepServerTime = AuthoritativeFrameService.InspectFrameStepServerTime(frameValue)
		if not frameSummary or frameStepServerTime ~= stepServerTime then
			return nil, "invalid-mover-damage-frame"
		end
		if activeMoverDamageToken ~= nil or activeMoverDamageTransaction ~= nil then
			return nil, "mover-damage-transaction-active"
		end
		local levelTimeMilliseconds = frameSummary.currentTimeMilliseconds
		local matchSnapshot = MatchService.GetSnapshot()
		local matchShadow, matchShadowError =
			MatchService.CreateMoverEliminationShadow(MovementService.GetPlayerSourceOrder, levelTimeMilliseconds)
		if not matchShadow then
			return nil, "mover-match-shadow-unavailable:" .. (matchShadowError or "unknown")
		end
		local matchToken, matchBatchError = MatchService.BeginEliminationBatch(levelTimeMilliseconds)
		if not matchToken then
			return nil, "mover-match-batch-unavailable:" .. (matchBatchError or "unknown")
		end
		local corpseToken, corpseError = CorpseService.Begin()
		if not corpseToken then
			assert(MatchService.AbortEliminationBatch(matchToken), "failed mover begin leaked its Match batch")
			return nil, "mover-corpse-shadow-unavailable:" .. (corpseError or "unknown")
		end

		local token: MoverDamageToken = table.freeze({})
		local transaction: MoverDamageTransaction = {
			token = token,
			corpseToken = corpseToken,
			status = "Open",
			stepServerTime = stepServerTime,
			levelTimeMilliseconds = levelTimeMilliseconds,
			matchId = matchSnapshot.matchId,
			matchState = matchSnapshot.state,
			startingMatchShadow = matchShadow,
			matchShadow = matchShadow,
			oneShot = MatchService.GetRules().OneShot,
			startingCombatEnabled = matchSnapshot.combatEnabled,
			startingIntermissionQueued = matchSnapshot.intermissionQueued,
			startingSuddenDeath = matchSnapshot.suddenDeath,
			expectedSuddenDeath = matchSnapshot.suddenDeath,
			shadows = {},
			operations = {},
			stageReceipts = {},
			matchToken = matchToken,
			finalCorpseCollection = nil,
			prepared = nil,
		}
		activeMoverDamageToken = token
		activeMoverDamageTransaction = transaction
		return token, nil
	end

	local EMPTY_MOVER_CRUSH_INSERTIONS: { MoverPushRules.Body } = table.freeze({})
	local RETAIN_MOVER_CRUSH_EFFECT: MoverPushRules.SynchronousCrushEffect = table.freeze({
		kind = "Retain",
		insertedBodies = EMPTY_MOVER_CRUSH_INSERTIONS,
	})
	local function stageExistingCorpseDamage(
		transaction: MoverDamageTransaction,
		player: Player,
		body: MoverPushRules.Body,
		rawDamage: number,
		moverId: string
	): (MoverPushRules.SynchronousCrushTransition?, string?)
		local binding = CorpseService.GetBinding(transaction.corpseToken, player, body.id)
		local beforeHealth = CorpseService.GetHealth(transaction.corpseToken, player, body.id)
		if not binding or beforeHealth == nil then
			return nil, "missing-mover-client-corpse"
		end
		if rawDamage == 0 then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end
		local shadow, shadowError = captureMoverDamageShadow(transaction, player)
		if not shadow then
			return nil, shadowError
		end
		if shadow.alive or shadow.health ~= 0 then
			return nil, "client-corpse-retained-live-combat-state"
		end
		local adjustedDamage, armorSave, healthDamage = WeaponDefinitions.ResolveDamage(rawDamage, shadow.armor, false)
		if adjustedDamage <= 0 then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end
		local beforeArmor = shadow.armor
		local afterArmor = beforeArmor - armorSave
		local postDamageHealth = math.max(beforeHealth - healthDamage, MoverConsequenceRules.MinimumRawPostDamageHealth)
		local effect, _resolvedHealth, corpseError = CorpseService.StageCollision(
			transaction.corpseToken,
			player,
			binding,
			body,
			postDamageHealth,
			MoverConsequenceRules.MeansOfDeath.Ordinary,
			true,
			false
		)
		if not effect then
			return nil, corpseError
		end
		local operationIndex = #transaction.operations + 1
		local context = captureMoverDamageContext(transaction, shadow, moverId, "corpse", operationIndex)
		local operation: MoverDamageOperation = table.freeze({
			kind = "ClientCorpse",
			player = player,
			record = shadow.record,
			sourceOrder = shadow.sourceOrder,
			lifeSequence = shadow.lifeSequence,
			rawDamage = rawDamage,
			beforeHealth = 0,
			beforeArmor = beforeArmor,
			beforeAlive = false,
			rawPostDamageHealth = postDamageHealth,
			afterHealth = 0,
			afterArmor = afterArmor,
			afterAlive = false,
			operationIndex = operationIndex,
			body = body,
			context = context,
			moverDeathSource = nil,
			moverDeathSourceSummary = nil,
			moverDeathStageReceipt = nil,
			matchExpectation = nil,
			beforeCorpseHealth = beforeHealth,
			afterCorpseHealth = postDamageHealth,
			deathPosition = nil,
		})
		table.insert(transaction.operations, operation)
		shadow.armor = afterArmor
		return effect, nil
	end

	local function stageMoverDamage(
		token: unknown,
		player: Player,
		moverId: string,
		rawDamage: number,
		operationKind: string,
		body: MoverPushRules.Body,
		moverDeathSourceValue: unknown,
		moverDeathSourceSummaryValue: unknown
	): (MoverPushRules.SynchronousCrushTransition?, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return nil, transactionError
		end
		if Movement.ValidateMoverId(moverId) == nil then
			return nil, "invalid-mover-id"
		end
		local validatedBodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ body })
		if not validatedBodies then
			return nil, "invalid-mover-client-body:" .. (bodyError or "invalid")
		end
		local canonicalBody = validatedBodies[1]
		if
			not table.isfrozen(body)
			or canonicalBody.id ~= body.id
			or canonicalBody.sourceOrder ~= body.sourceOrder
			or canonicalBody.position ~= body.position
			or canonicalBody.size ~= body.size
			or canonicalBody.centerOffset ~= body.centerOffset
			or canonicalBody.velocity ~= body.velocity
			or canonicalBody.groundMoverId ~= body.groundMoverId
			or canonicalBody.contents ~= body.contents
			or canonicalBody.clipMask ~= body.clipMask
		then
			return nil, "noncanonical-mover-client-body"
		end
		if body.contents == MoverPushRules.Contents.Corpse then
			if moverDeathSourceValue ~= nil or moverDeathSourceSummaryValue ~= nil then
				return nil, "mover-client-corpse-received-death-source"
			end
		elseif rawDamage > 0 then
			if type(moverDeathSourceValue) ~= "table" or type(moverDeathSourceSummaryValue) ~= "table" then
				return nil, "mover-live-player-missing-death-source"
			end
		elseif moverDeathSourceValue ~= nil or moverDeathSourceSummaryValue ~= nil then
			return nil, "zero-damage-mover-received-death-source"
		end
		-- G_Damage returns before either player_die or body_die once intermission is
		-- queued. Keep the currently linked live/corpse body unchanged.
		if
			not transaction.startingCombatEnabled
			or transaction.startingIntermissionQueued
			or not MatchEliminationShadowRules.IsDamageOpen(transaction.matchShadow)
		then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end
		if body.contents == MoverPushRules.Contents.Corpse then
			return stageExistingCorpseDamage(transaction, player, body, rawDamage, moverId)
		end
		if body.contents ~= MoverPushRules.Contents.Body or body.id ~= MovementService.GetPlayerBodyId(player) then
			return nil, "mover-live-player-body-identity-drifted"
		end
		local shadow, shadowError = captureMoverDamageShadow(transaction, player)
		if not shadow then
			return nil, shadowError
		end
		if MatchEliminationShadowRules.Inspect(transaction.matchShadow) ~= transaction.matchShadow then
			return nil, "invalid-mover-match-shadow"
		end
		if not shadow.alive then
			return nil, "dead-player-retained-live-mover-body"
		end
		if rawDamage == 0 or not shadow.startingCanFight then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end

		local adjustedDamage, armorSave, resolvedHealthDamage =
			WeaponDefinitions.ResolveDamage(rawDamage, shadow.armor, false)
		if adjustedDamage <= 0 then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end

		local beforeHealth = shadow.health
		local healthDamage = assert(
			OneShotRules.ResolveCrushHealthDamage(transaction.oneShot, beforeHealth, resolvedHealthDamage),
			"One-Shot mover crush damage input must be valid"
		)
		local beforeArmor = shadow.armor
		local beforeAlive = shadow.alive
		local afterArmor = beforeArmor - armorSave
		local rawPostDamageHealth = beforeHealth - healthDamage
		local afterHealth = rawPostDamageHealth
		local afterAlive = rawPostDamageHealth > 0
		if not afterAlive then
			-- The prepared player_die mutation canonicalizes accepted lethal health to zero.
			afterHealth = 0
		end
		local matchExpectation: MoverMatchExpectation? = nil
		if beforeAlive and not afterAlive then
			local nextMatchShadow, matchOutcome, matchError =
				MatchEliminationShadowRules.StageElimination(transaction.matchShadow, {
					operationOrder = transaction.matchShadow.lastOperationOrder + 1,
					levelTimeMilliseconds = transaction.levelTimeMilliseconds,
					victimUserId = player.UserId,
					attackerUserId = 0,
					bypassTeamProtection = false,
				})
			if not nextMatchShadow or not matchOutcome or matchError then
				return nil, "mover-match-elimination-failed:" .. (matchError or "unknown")
			end
			if not matchOutcome.accepted then
				return nil, "mover-match-elimination-rejected:" .. (matchOutcome.rejectionReason or "unknown")
			end
			local matchPlayer = MatchEliminationShadowRules.GetPlayer(nextMatchShadow, player.UserId)
			if not matchPlayer or matchPlayer.sourceOrder ~= shadow.sourceOrder then
				return nil, "mover-match-player-order-diverged"
			end
			local matchToken = transaction.matchToken
			if matchToken == nil then
				return nil, "mover-match-batch-missing"
			end
			local stagedMatch, stagedMatchError = MatchService.StageElimination(matchToken, player, nil, "Crush", nil)
			if
				not stagedMatch
				or not stagedMatch.result.accepted
				or not stagedMatch.outcome
				or not moverMatchOutcomeEqual(stagedMatch.outcome, matchOutcome)
				or stagedMatch.damageOpenAfter
					~= (transaction.startingCombatEnabled and not transaction.startingIntermissionQueued and MatchEliminationShadowRules.IsDamageOpen(
						nextMatchShadow
					))
			then
				return nil, "mover-match-batch-stage-diverged:" .. (stagedMatchError or "unknown")
			end
			transaction.expectedSuddenDeath = transaction.expectedSuddenDeath
				or moverOutcomeEntersSuddenDeath(nextMatchShadow, matchOutcome, transaction.levelTimeMilliseconds)
			matchExpectation = makeMoverMatchExpectation(nextMatchShadow, matchOutcome, transaction.expectedSuddenDeath)
			transaction.matchShadow = nextMatchShadow
		end
		local operationIndex = #transaction.operations + 1
		local context = captureMoverDamageContext(transaction, shadow, moverId, operationKind, operationIndex)
		local deathWeaponDrop: DeathWeaponDropRequest? = nil
		if not afterAlive then
			deathWeaponDrop = buildDeathWeaponDrop(
				player,
				shadow.record,
				"Crush",
				shadow.record.weaponId,
				shadow.record.commandWeaponId,
				shadow.record.weaponState
			)
		end
		local moverDeathSource = moverDeathSourceValue :: MovementService.MoverDeathSource
		local moverDeathSourceSummary = moverDeathSourceSummaryValue :: MovementService.MoverDeathSourceSummary
		local moverDeathStageReceipt, sourceClaimError = moverDeathSourceOwner.claimOperationSource(
			transaction,
			player,
			body,
			moverId,
			operationIndex,
			context,
			moverDeathSource,
			moverDeathSourceSummary
		)
		if not moverDeathStageReceipt then
			return nil, sourceClaimError or "mover-death-source-operation-claim-failed"
		end
		local operation: MoverDamageOperation = table.freeze({
			kind = "LivePlayer",
			player = player,
			record = shadow.record,
			sourceOrder = shadow.sourceOrder,
			lifeSequence = shadow.lifeSequence,
			rawDamage = rawDamage,
			beforeHealth = beforeHealth,
			beforeArmor = beforeArmor,
			beforeAlive = beforeAlive,
			rawPostDamageHealth = rawPostDamageHealth,
			afterHealth = afterHealth,
			afterArmor = afterArmor,
			afterAlive = afterAlive,
			operationIndex = operationIndex,
			body = body,
			context = context,
			moverDeathSource = moverDeathSource,
			moverDeathSourceSummary = moverDeathSourceSummary,
			moverDeathStageReceipt = moverDeathStageReceipt,
			matchExpectation = matchExpectation,
			deathPosition = if afterAlive then nil else body.position + body.centerOffset,
			deathWeaponDrop = deathWeaponDrop,
		})
		table.insert(transaction.operations, operation)
		shadow.health = afterHealth
		shadow.armor = afterArmor
		shadow.alive = afterAlive
		if afterAlive then
			return RETAIN_MOVER_CRUSH_EFFECT, nil
		end
		local liveBinding = assert(MoverConsequenceRules.ValidateBinding({
			kind = MoverConsequenceRules.BindingKinds.LivePlayer,
			bodyId = body.id,
			playerUserId = player.UserId,
			lifeSequence = shadow.lifeSequence,
		}))
		local corpseEffect, _resolvedHealth, corpseError = CorpseService.StageCollision(
			transaction.corpseToken,
			player,
			liveBinding,
			body,
			rawPostDamageHealth,
			MoverConsequenceRules.MeansOfDeath.Ordinary,
			true,
			false
		)
		if not corpseEffect then
			return nil, "mover-client-corpse-stage-failed:" .. (corpseError or "unknown")
		end
		local insertedBodies: { MoverPushRules.Body } = {}
		if deathWeaponDrop then
			local insertedBody, insertionError = stageSynchronousMoverDeathWeaponDrop(deathWeaponDrop, operationIndex)
			if not insertedBody then
				return nil, insertionError or "mover-death-drop-synchronous-stage-failed"
			end
			table.insert(insertedBodies, insertedBody)
		end
		local powerupBodies, powerupError = stageSynchronousMoverPowerupDrops(
			player,
			shadow.record,
			body.position + body.centerOffset,
			transaction.levelTimeMilliseconds,
			operationIndex
		)
		if not powerupBodies then
			return nil, powerupError or "mover-powerup-drop-synchronous-stage-failed"
		end
		for _, powerupBody in powerupBodies do
			table.insert(insertedBodies, powerupBody)
		end
		local flagBodies, flagError =
			stageSynchronousMoverFlagDrops(player, body.position + body.centerOffset, operationIndex)
		if not flagBodies then
			return nil, flagError or "mover-flag-drop-synchronous-stage-failed"
		end
		for _, flagBody in flagBodies do
			table.insert(insertedBodies, flagBody)
		end
		if #insertedBodies == 0 then
			return corpseEffect, nil
		end
		table.sort(insertedBodies, function(left, right)
			return left.sourceOrder < right.sourceOrder
		end)
		table.freeze(insertedBodies)
		local effect: MoverPushRules.SynchronousCrushEffect
		if corpseEffect.kind == "Replace" then
			effect = {
				kind = "Replace",
				replacementBody = corpseEffect.replacementBody,
				insertedBodies = insertedBodies,
			}
		elseif corpseEffect.kind == "Remove" then
			effect = { kind = "Remove", insertedBodies = insertedBodies }
		else
			effect = { kind = "Retain", insertedBodies = insertedBodies }
		end
		table.freeze(effect)
		return effect, nil
	end

	local function stageSineMoverCrush(
		token: unknown,
		player: Player,
		moverId: string,
		body: MoverPushRules.Body,
		moverDeathSource: MovementService.MoverDeathSource?,
		moverDeathSourceSummary: MovementService.MoverDeathSourceSummary?
	): (MoverPushRules.SynchronousCrushTransition?, string?)
		return stageMoverDamage(
			token,
			player,
			moverId,
			99_999,
			"crush",
			body,
			moverDeathSource,
			moverDeathSourceSummary
		)
	end

	local function stageDoorMoverDamage(
		token: unknown,
		player: Player,
		moverId: string,
		damage: number,
		body: MoverPushRules.Body,
		moverDeathSource: MovementService.MoverDeathSource?,
		moverDeathSourceSummary: MovementService.MoverDeathSourceSummary?
	): (MoverPushRules.SynchronousCrushTransition?, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return nil, transactionError
		end
		if not isFinite(damage) or damage % 1 ~= 0 or damage < 0 or damage > 100_000 then
			return nil, "invalid-mover-blocked-damage"
		end
		return stageMoverDamage(
			transaction.token,
			player,
			moverId,
			damage,
			"blocked",
			body,
			moverDeathSource,
			moverDeathSourceSummary
		)
	end

	local function collectMoverCorpseBodies(token: unknown): ({ MoverPushRules.Body }?, { [string]: Player }?, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return nil, nil, transactionError
		end
		local collection, corpseError = CorpseService.Collect(transaction.corpseToken)
		if not collection then
			return nil, nil, corpseError or "mover-corpse-collection-failed"
		end
		return collection.bodies, collection.playersByBodyId, nil
	end

	local function applyMoverCorpseBodies(token: unknown, bodies: { MoverPushRules.Body }): (boolean, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return false, transactionError
		end
		return CorpseService.ApplyMoverBodies(transaction.corpseToken, bodies)
	end

	local function isMoverDamageShadowAlive(token: unknown, player: Player): boolean?
		local transaction, transactionError = getActiveMoverDamageTransaction(token, nil)
		if not transaction or transactionError then
			return nil
		end
		local corpseCollection = select(1, CorpseService.Collect(transaction.corpseToken))
		if corpseCollection then
			for bodyId, corpsePlayer in corpseCollection.playersByBodyId do
				if corpsePlayer == player and CorpseService.GetBinding(transaction.corpseToken, player, bodyId) then
					return false
				end
			end
		end
		if transaction.status == "Open" then
			local shadow = select(1, captureMoverDamageShadow(transaction, player))
			return if shadow then shadow.alive else nil
		elseif transaction.status == "Sealed" then
			local shadow = transaction.shadows[player]
			return if shadow then shadow.alive else nil
		end
		return nil
	end

	local function sealMoverDamageTransaction(token: unknown): (boolean, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Open")
		if not transaction then
			return false, transactionError
		end
		local staleError, replayMatchShadow = validateMoverDamageStartingState(transaction)
		if staleError then
			return faultMoverDamageTransaction(transaction, staleError)
		end
		local operationError = preflightMoverDamageOperations(
			transaction,
			assert(replayMatchShadow, "validated mover Match replay is missing")
		)
		if operationError then
			return faultMoverDamageTransaction(transaction, operationError)
		end
		local lethalOperationCount = 0
		for _, operation in transaction.operations do
			if operation.matchExpectation then
				lethalOperationCount += 1
			end
		end
		local matchToken = transaction.matchToken
		if matchToken == nil then
			return faultMoverDamageTransaction(transaction, "mover-match-batch-missing-at-seal")
		end
		if lethalOperationCount > 0 then
			local matchSealed, matchSealError = MatchService.SealEliminationBatch(matchToken, transaction.matchShadow)
			if not matchSealed then
				return faultMoverDamageTransaction(
					transaction,
					"mover-match-batch-seal-failed:" .. (matchSealError or "unknown")
				)
			end
		else
			if not MatchService.AbortEliminationBatch(matchToken) then
				return faultMoverDamageTransaction(transaction, "empty-mover-match-batch-abort-failed")
			end
			transaction.matchToken = nil
		end
		local finalCorpseCollection, finalCorpseCollectionError = CorpseService.Collect(transaction.corpseToken)
		if not finalCorpseCollection then
			return faultMoverDamageTransaction(
				transaction,
				"mover-corpse-final-collection-failed:" .. (finalCorpseCollectionError or "unknown")
			)
		end
		local corpseSealed, corpseSealError = CorpseService.Seal(transaction.corpseToken)
		if not corpseSealed then
			return faultMoverDamageTransaction(
				transaction,
				"mover-corpse-seal-failed:" .. (corpseSealError or "unknown")
			)
		end

		table.freeze(transaction.operations)
		table.freeze(transaction.stageReceipts)
		transaction.finalCorpseCollection = finalCorpseCollection
		transaction.status = "Sealed"
		return true, nil
	end

	local function buildMoverDamagePreparedPlan(transaction: MoverDamageTransaction): (
		{ MoverDamagePreparedMutation }?,
		{ MoverDamagePreparedPublication }?,
		MoverDamageMatchDependencySummary?,
		string?
	)
		local finalOperationByPlayer: { [Player]: MoverDamageOperation } = {}
		local lethalOperationByPlayer: { [Player]: MoverDamageOperation } = {}
		local orderedPlayers: { Player } = {}
		local playerSeen: { [Player]: boolean } = {}
		local outcomes: { MatchEliminationShadowRules.EliminationOutcome } = {}
		for _, operation in transaction.operations do
			if not playerSeen[operation.player] then
				playerSeen[operation.player] = true
				table.insert(orderedPlayers, operation.player)
			end
			finalOperationByPlayer[operation.player] = operation
			if operation.matchExpectation then
				lethalOperationByPlayer[operation.player] = operation
				table.insert(outcomes, operation.matchExpectation.outcome)
			end
		end
		table.freeze(outcomes)

		local dependencySummary: MoverDamageMatchDependencySummary = {
			matchId = transaction.matchId,
			matchState = transaction.matchState,
			levelTimeMilliseconds = transaction.levelTimeMilliseconds,
			operationCount = #outcomes,
			baseShadow = transaction.startingMatchShadow,
			finalShadow = transaction.matchShadow,
			outcomes = outcomes,
			terminal = transaction.matchShadow.terminal,
			damageOpenAfter = transaction.startingCombatEnabled
				and not transaction.startingIntermissionQueued
				and MatchEliminationShadowRules.IsDamageOpen(transaction.matchShadow),
			startingIntermissionQueued = transaction.startingIntermissionQueued,
			startingSuddenDeath = transaction.startingSuddenDeath,
			finalSuddenDeath = transaction.expectedSuddenDeath,
		}
		table.freeze(dependencySummary)

		local matchSnapshot = MatchService.GetSnapshot()
		if matchSnapshot.matchId ~= transaction.matchId or matchSnapshot.state ~= transaction.matchState then
			return nil, nil, nil, "stale-mover-damage-match-before-prepare"
		end
		local mutations: { MoverDamagePreparedMutation } = {}
		for _, player in orderedPlayers do
			local shadow = transaction.shadows[player]
			local finalOperation = finalOperationByPlayer[player]
			if not shadow or not finalOperation then
				return nil, nil, nil, "missing-mover-damage-prepared-shadow"
			end
			local lethalOperation = lethalOperationByPlayer[player]
			local expectation = if lethalOperation then lethalOperation.matchExpectation else nil
			local lethal = expectation ~= nil
			local afterScore = shadow.record.score
			local afterDeaths = shadow.record.deaths
			local shouldRespawn = false
			local respawnEligibleAtMilliseconds = shadow.record.respawnEligibleAtMilliseconds
			local forcedRespawnAtMilliseconds: number? = nil
			local deathWeaponDrop: DeathWeaponDropRequest? = nil
			local afterWeaponId = shadow.record.weaponId
			local afterCommandWeaponId = shadow.record.commandWeaponId
			if expectation then
				-- Movers run after every client PM_Weapon phase in this frame. A lethal
				-- mover consequence snapshots that already-resolved active/state tuple;
				-- it must not decrement or resolve weaponTime a second time.
				afterCommandWeaponId = afterWeaponId
				afterScore = expectation.outcome.victimScore
				afterDeaths = expectation.outcome.victimDeaths
				shouldRespawn = not expectation.outcome.terminalQualified
					and (
						transaction.matchState == "Warmup"
						or (transaction.matchState == "Live" and matchSnapshot.rules.respawnDuringLive)
					)
				respawnEligibleAtMilliseconds = if shouldRespawn
					then assert(
						MatchFrameRules.DeadlineMilliseconds(
							transaction.levelTimeMilliseconds,
							matchSnapshot.respawnDelaySeconds
						)
					)
					else nil
				if shouldRespawn and matchSnapshot.forcedRespawnSeconds > 0 then
					forcedRespawnAtMilliseconds = assert(
						MatchFrameRules.DeadlineMilliseconds(
							assert(respawnEligibleAtMilliseconds, "mover lethal respawn lost its eligibility deadline"),
							matchSnapshot.forcedRespawnSeconds
						)
					)
				end
				deathWeaponDrop = lethalOperation.deathWeaponDrop
			end
			local mutation: MoverDamagePreparedMutation = {
				player = player,
				record = shadow.record,
				lifeSequence = shadow.lifeSequence,
				beforeHealth = shadow.startingHealth,
				beforeArmor = shadow.startingArmor,
				beforeAlive = shadow.startingAlive,
				beforeScore = shadow.record.score,
				beforeDeaths = shadow.record.deaths,
				beforeWeaponId = shadow.record.weaponId,
				beforeCommandWeaponId = shadow.record.commandWeaponId,
				beforeWeaponState = shadow.record.weaponState,
				beforeWeaponTimeMilliseconds = shadow.record.weaponTimeMilliseconds,
				beforeLastWeaponPmoveLevelTimeMilliseconds = shadow.record.lastWeaponPmoveLevelTimeMilliseconds,
				beforeLastPrePmoveGauntletLevelTimeMilliseconds = shadow.record.lastPrePmoveGauntletLevelTimeMilliseconds,
				beforeOverstackAccumulator = shadow.record.overstackAccumulator,
				beforePowerupExpiries = shadow.record.powerupExpiries,
				beforeRespawnEligibleAtMilliseconds = shadow.record.respawnEligibleAtMilliseconds,
				beforeForcedRespawnAtMilliseconds = shadow.record.forcedRespawnAtMilliseconds,
				beforeManualRespawnQueued = shadow.record.manualRespawnQueued,
				beforeRespawnRequested = shadow.record.respawnRequested,
				beforeLastDroppedLifeSequence = shadow.record.lastDroppedLifeSequence,
				beforeOwnedWeapons = shadow.record.ownedWeapons,
				beforeAmmoByWeapon = shadow.record.ammoByWeapon,
				beforeInfiniteAmmo = shadow.record.infiniteAmmo,
				beforeMovementLifeBinding = shadow.record.movementLifeBinding,
				beforeCharacter = shadow.record.character,
				afterHealth = shadow.health,
				afterArmor = shadow.armor,
				afterAlive = shadow.alive,
				lethal = lethal,
				afterWeaponId = afterWeaponId,
				afterCommandWeaponId = afterCommandWeaponId,
				afterWeaponState = if lethal then "Ready" else shadow.record.weaponState,
				afterWeaponTimeMilliseconds = if lethal then 0 else shadow.record.weaponTimeMilliseconds,
				afterOverstackAccumulator = if lethal then 0 else shadow.record.overstackAccumulator,
				afterPowerupExpiries = if lethal then table.freeze({}) else shadow.record.powerupExpiries,
				afterForcedRespawnAtMilliseconds = if lethal
					then forcedRespawnAtMilliseconds
					else shadow.record.forcedRespawnAtMilliseconds,
				afterManualRespawnQueued = if lethal then false else shadow.record.manualRespawnQueued,
				afterRespawnRequested = if lethal then false else shadow.record.respawnRequested,
				afterScore = afterScore,
				afterDeaths = afterDeaths,
				afterLastDroppedLifeSequence = if lethal and deathWeaponDrop ~= nil
					then shadow.lifeSequence
					else shadow.record.lastDroppedLifeSequence,
				shouldRespawn = shouldRespawn,
				respawnEligibleAtMilliseconds = respawnEligibleAtMilliseconds,
				forcedRespawnAtMilliseconds = forcedRespawnAtMilliseconds,
				deathWeaponDrop = deathWeaponDrop,
			}
			table.freeze(mutation)
			table.insert(mutations, mutation)
		end
		table.freeze(mutations)

		local publications: { MoverDamagePreparedPublication } = {}
		for _, operation in transaction.operations do
			local damagePayload: { [string]: any }? = nil
			local elimination: EliminationEvent? = nil
			if operation.kind == "LivePlayer" then
				local adjustedDamage, armorSave, resolvedHealthDamage =
					WeaponDefinitions.ResolveDamage(operation.rawDamage, operation.beforeArmor, false)
				local healthDamage = assert(
					OneShotRules.ResolveCrushHealthDamage(
						transaction.oneShot,
						operation.beforeHealth,
						resolvedHealthDamage
					),
					"One-Shot mover publication damage input must be valid"
				)
				damagePayload = {
					kind = "Damage",
					eventId = WeaponDefinitions.MakeEventId(operation.context.id, 1),
					shotId = operation.context.id,
					weaponId = operation.context.weaponId,
					serverFrame = operation.context.serverFrame,
					revision = operation.context.revision,
					targetUserId = operation.player.UserId,
					attackerUserId = 0,
					rawDamage = operation.rawDamage,
					adjustedDamage = adjustedDamage,
					damage = healthDamage,
					armorSave = armorSave,
					means = "Crush",
					isSplash = false,
					isSelfDamage = false,
					killed = operation.matchExpectation ~= nil,
					targetHealth = operation.afterHealth,
					targetArmor = operation.afterArmor,
				}
				table.freeze(damagePayload)
				local expectation = operation.matchExpectation
				if expectation then
					local deathPosition = operation.deathPosition
					if not deathPosition then
						return nil, nil, nil, "mover-lethal-death-position-missing"
					end
					local outcome = expectation.outcome
					elimination = table.freeze({
						kind = "Elimination",
						eventId = WeaponDefinitions.MakeEventId(operation.context.id, 2),
						shotId = operation.context.id,
						weaponId = operation.context.weaponId,
						serverFrame = operation.context.serverFrame,
						revision = operation.context.revision,
						position = deathPosition,
						targetUserId = operation.player.UserId,
						attackerUserId = 0,
						scoringUserId = if outcome.scored then operation.player.UserId else 0,
						means = "Crush",
						isSuicide = false,
						isWorldKill = true,
						scoreDelta = if outcome.scored then -1 else 0,
						attackerScore = 0,
						targetScore = outcome.victimScore,
						targetDeaths = outcome.victimDeaths,
						targetLifeSequence = operation.lifeSequence,
						-- MOD_CRUSH is a world kill. Paid elimination presentation belongs
						-- only to a distinct credited attacker, never to the victim.
						effectId = nil,
					}) :: EliminationEvent
				end
			end
			local publication: MoverDamagePreparedPublication = {
				player = operation.player,
				record = operation.record,
				damagePayload = damagePayload,
				elimination = elimination,
			}
			table.freeze(publication)
			table.insert(publications, publication)
		end
		table.freeze(publications)
		return mutations, publications, dependencySummary, nil
	end

	local function getMoverDamagePreparedCapability(
		preparedValue: unknown,
		requiredStatus: MoverDamagePreparedCapabilityStatus?
	): (MoverDamagePreparedCapability?, string?)
		if type(preparedValue) ~= "table" then
			return nil, "invalid-mover-damage-prepared"
		end
		local capability = moverDamagePreparedCapabilities[preparedValue :: MoverDamagePrepared]
		if not capability or capability.prepared ~= preparedValue then
			return nil, "invalid-mover-damage-prepared"
		end
		if requiredStatus and capability.status ~= requiredStatus then
			return nil, "invalid-mover-damage-prepared-state"
		end
		return capability, nil
	end

	local function getMoverDamageReceiptCapability(receiptValue: unknown): (MoverDamagePreparedCapability?, string?)
		if type(receiptValue) ~= "table" then
			return nil, "invalid-mover-damage-receipt"
		end
		local capability = moverDamageReceiptCapabilities[receiptValue :: MoverDamageApplyReceipt]
		if not capability or capability.receipt ~= receiptValue then
			return nil, "invalid-mover-damage-receipt"
		end
		return capability, nil
	end

	local function moverDamagePreparedCurrentError(
		preparedValue: unknown,
		capability: MoverDamagePreparedCapability,
		validateMovementDependencies: boolean
	): string?
		local transaction = capability.transaction
		if
			capability.status ~= "Prepared"
			or transaction.status ~= "Prepared"
			or transaction.prepared ~= preparedValue
			or activeMoverDamageTransaction ~= transaction
			or activeMoverDamageToken ~= transaction.token
			or not table.isfrozen(preparedValue :: any)
			or not table.isfrozen(capability.receipt)
			or not table.isfrozen(transaction.operations)
			or not table.isfrozen(transaction.stageReceipts)
			or not table.isfrozen(capability.mutations)
			or not table.isfrozen(capability.publications)
			or not table.isfrozen(capability.dependencySummary)
			or not table.isfrozen(capability.movementDependencySummary)
			or (
				capability.dependencySummary.operationCount > 0
				and (
					type(capability.matchApplyReceipt) ~= "table"
					or not table.isfrozen(capability.matchApplyReceipt :: any)
				)
			)
		then
			return "stale-mover-damage-prepared"
		end
		local movementDependencySummary = capability.movementDependencySummary
		if
			not table.isfrozen(movementDependencySummary.releaseSpawnPlayers)
			or not table.isfrozen(movementDependencySummary.lifeBindings)
			or not table.isfrozen(movementDependencySummary.lethalMoverSources)
			or #movementDependencySummary.releaseSpawnPlayers ~= #movementDependencySummary.lifeBindings
			or #movementDependencySummary.lethalMoverSources ~= #movementDependencySummary.releaseSpawnPlayers
		then
			return "stale-mover-damage-movement-life-dependency"
		end
		for index, dependency in movementDependencySummary.lifeBindings do
			if
				not table.isfrozen(dependency)
				or movementDependencySummary.releaseSpawnPlayers[index] ~= dependency.player
				or (
					validateMovementDependencies
					and not MovementService.ValidateMovementLifeBindingDependency(
						dependency.binding,
						dependency.summary
					)
				)
			then
				return "stale-mover-damage-movement-life-dependency"
			end
		end
		local previousCallbackOrder = 0
		local previousOperationIndex = 0
		for _, dependency in movementDependencySummary.lethalMoverSources do
			local stageCapability = moverDeathSourceOwner.stageReceiptCapabilities[dependency.stageReceipt]
			if
				not table.isfrozen(dependency)
				or not stageCapability
				or stageCapability.status ~= "Prepared"
				or stageCapability.transaction ~= transaction
				or stageCapability.player ~= dependency.player
				or stageCapability.body ~= dependency.body
				or stageCapability.operationIndex ~= dependency.operationIndex
				or stageCapability.context ~= dependency.context
				or stageCapability.moverDeathSource ~= dependency.source
				or stageCapability.moverDeathSourceSummary ~= dependency.sourceSummary
				or dependency.sourceSummary.victim ~= dependency.player
				or dependency.sourceSummary.victimBody ~= dependency.body
				or dependency.operationIndex <= previousOperationIndex
				or dependency.sourceSummary.callbackTraversalOrder <= previousCallbackOrder
				or (
					validateMovementDependencies
					and not MovementService.ValidateBoundMoverDeathSourceDependency(
						dependency.source,
						dependency.sourceSummary,
						dependency.stageReceipt
					)
				)
			then
				return "stale-mover-damage-lethal-source-dependency"
			end
			previousOperationIndex = dependency.operationIndex
			previousCallbackOrder = dependency.sourceSummary.callbackTraversalOrder
		end
		for _, mutation in capability.mutations do
			local record = records[mutation.player]
			if
				not table.isfrozen(mutation)
				or mutation.player.Parent ~= Players
				or record ~= mutation.record
				or table.isfrozen(record)
				or record.lifeSequence ~= mutation.lifeSequence
				or record.health ~= mutation.beforeHealth
				or record.armor ~= mutation.beforeArmor
				or record.alive ~= mutation.beforeAlive
				or record.score ~= mutation.beforeScore
				or record.deaths ~= mutation.beforeDeaths
				or record.weaponId ~= mutation.beforeWeaponId
				or record.commandWeaponId ~= mutation.beforeCommandWeaponId
				or record.weaponState ~= mutation.beforeWeaponState
				or record.weaponTimeMilliseconds ~= mutation.beforeWeaponTimeMilliseconds
				or record.lastWeaponPmoveLevelTimeMilliseconds ~= mutation.beforeLastWeaponPmoveLevelTimeMilliseconds
				or record.lastPrePmoveGauntletLevelTimeMilliseconds ~= mutation.beforeLastPrePmoveGauntletLevelTimeMilliseconds
				or record.overstackAccumulator ~= mutation.beforeOverstackAccumulator
				or record.powerupExpiries ~= mutation.beforePowerupExpiries
				or record.respawnEligibleAtMilliseconds ~= mutation.beforeRespawnEligibleAtMilliseconds
				or record.forcedRespawnAtMilliseconds ~= mutation.beforeForcedRespawnAtMilliseconds
				or record.manualRespawnQueued ~= mutation.beforeManualRespawnQueued
				or record.respawnRequested ~= mutation.beforeRespawnRequested
				or record.lastDroppedLifeSequence ~= mutation.beforeLastDroppedLifeSequence
				or record.ownedWeapons ~= mutation.beforeOwnedWeapons
				or record.ammoByWeapon ~= mutation.beforeAmmoByWeapon
				or record.infiniteAmmo ~= mutation.beforeInfiniteAmmo
				or record.movementLifeBinding ~= mutation.beforeMovementLifeBinding
				or record.character ~= mutation.beforeCharacter
			then
				return "stale-mover-damage-combat-root"
			end
		end
		for _, publication in capability.publications do
			if
				not table.isfrozen(publication)
				or publication.record ~= records[publication.player]
				or (publication.damagePayload ~= nil and not table.isfrozen(publication.damagePayload))
				or (publication.elimination ~= nil and not table.isfrozen(publication.elimination))
			then
				return "stale-mover-damage-publication-plan"
			end
		end
		return nil
	end

	local function moverMatchPreparedSummaryMatches(
		dependency: MoverDamageMatchDependencySummary,
		matchSummaryValue: unknown
	): boolean
		if type(matchSummaryValue) ~= "table" or not table.isfrozen(matchSummaryValue) then
			return false
		end
		local summary = matchSummaryValue :: any
		if
			summary.matchId ~= dependency.matchId
			or summary.matchState ~= dependency.matchState
			or summary.levelTimeMilliseconds ~= dependency.levelTimeMilliseconds
			or summary.operationCount ~= dependency.operationCount
			or summary.startingIntermissionQueued ~= dependency.startingIntermissionQueued
			or summary.startingSuddenDeath ~= dependency.startingSuddenDeath
			or summary.finalSuddenDeath ~= dependency.finalSuddenDeath
			or summary.damageOpenAfter ~= dependency.damageOpenAfter
			or not moverMatchTerminalEqual(summary.terminal, dependency.terminal)
			or type(summary.outcomes) ~= "table"
			or #summary.outcomes ~= #dependency.outcomes
			or type(summary.baseShadow) ~= "table"
			or type(summary.finalShadow) ~= "table"
			or not moverMatchStateEqual(summary.baseShadow, dependency.baseShadow)
			or not moverMatchStateEqual(summary.finalShadow, dependency.finalShadow)
		then
			return false
		end
		for index, outcome in dependency.outcomes do
			if not moverMatchOutcomeEqual(summary.outcomes[index], outcome) then
				return false
			end
		end
		return true
	end

	local function validateBoundMoverMatchDependency(capability: MoverDamagePreparedCapability): (boolean, string?)
		local dependency = capability.dependencySummary
		if dependency.operationCount == 0 then
			return capability.matchDependencySatisfied,
				if capability.matchDependencySatisfied then nil else "empty-mover-match-dependency-not-satisfied"
		end
		local matchPrepared = capability.boundMatchPrepared
		local matchSummary = capability.boundMatchSummary
		if not capability.matchDependencySatisfied or matchPrepared == nil or matchSummary == nil then
			return false, "mover-match-prepared-dependency-unbound"
		end
		local matchApi = MatchService :: any
		if
			type(matchApi.InspectPreparedEliminationBatch) ~= "function"
			or type(matchApi.ValidatePreparedEliminationBatchDependency) ~= "function"
		then
			return false, "mover-match-prepared-api-unavailable"
		end
		if matchApi.InspectPreparedEliminationBatch(matchPrepared) ~= matchSummary then
			return false, "mover-match-prepared-summary-drifted"
		end
		if
			type(matchApi.InspectPreparedEliminationBatchReceipt) ~= "function"
			or matchApi.InspectPreparedEliminationBatchReceipt(matchPrepared) ~= capability.matchApplyReceipt
		then
			return false, "mover-match-prepared-receipt-drifted"
		end
		local valid, validationError = matchApi.ValidatePreparedEliminationBatchDependency(matchPrepared, matchSummary)
		if not valid then
			return false, validationError or "mover-match-prepared-dependency-stale"
		end
		if not moverMatchPreparedSummaryMatches(dependency, matchSummary) then
			return false, "mover-match-prepared-summary-mismatch"
		end
		return true, nil
	end

	local function prepareMoverDamageTransaction(
		token: unknown
	): (MoverDamagePrepared?, MoverDamageMatchDependencySummary?, string?)
		local transaction, transactionError = getActiveMoverDamageTransaction(token, "Sealed")
		if not transaction then
			return nil, nil, transactionError
		end
		local staleError, replayMatchShadow = validateMoverDamageStartingState(transaction)
		if staleError then
			faultMoverDamageTransaction(transaction, staleError)
			return nil, nil, staleError
		end
		local operationError = preflightMoverDamageOperations(
			transaction,
			assert(replayMatchShadow, "validated mover Match replay is missing")
		)
		if operationError then
			faultMoverDamageTransaction(transaction, operationError)
			return nil, nil, operationError
		end
		local mutations, publications, dependencySummary, planError = buildMoverDamagePreparedPlan(transaction)
		if not mutations or not publications or not dependencySummary then
			local errorCode = planError or "mover-damage-prepare-plan-failed"
			faultMoverDamageTransaction(transaction, errorCode)
			return nil, nil, errorCode
		end
		local boundMatchPrepared: unknown? = nil
		local boundMatchSummary: unknown? = nil
		local boundMatchApplyReceipt: unknown? = nil
		if dependencySummary.operationCount > 0 then
			local matchToken = transaction.matchToken
			if matchToken == nil then
				local errorCode = "mover-match-batch-missing-at-prepare"
				faultMoverDamageTransaction(transaction, errorCode)
				return nil, nil, errorCode
			end
			local matchPrepared, matchPrepareError = MatchService.PrepareEliminationBatch(matchToken)
			if not matchPrepared then
				local errorCode = "mover-match-batch-prepare-failed:" .. (matchPrepareError or "unknown")
				faultMoverDamageTransaction(transaction, errorCode)
				return nil, nil, errorCode
			end
			local matchSummary = MatchService.InspectPreparedEliminationBatch(matchPrepared)
			if
				not matchSummary
				or not MatchService.ValidatePreparedEliminationBatchDependency(matchPrepared, matchSummary)
				or not moverMatchPreparedSummaryMatches(dependencySummary, matchSummary)
			then
				local errorCode = "mover-match-batch-prepared-summary-diverged"
				faultMoverDamageTransaction(transaction, errorCode)
				return nil, nil, errorCode
			end
			boundMatchPrepared = matchPrepared
			boundMatchSummary = matchSummary
			boundMatchApplyReceipt = MatchService.InspectPreparedEliminationBatchReceipt(matchPrepared)
			if boundMatchApplyReceipt == nil then
				local errorCode = "mover-match-batch-prebuilt-receipt-missing"
				faultMoverDamageTransaction(transaction, errorCode)
				return nil, nil, errorCode
			end
		end
		local corpsePrepared, corpsePrepareError = CorpseService.Prepare(transaction.corpseToken)
		if not corpsePrepared then
			local errorCode = "mover-corpse-prepare-failed:" .. (corpsePrepareError or "unknown")
			faultMoverDamageTransaction(transaction, errorCode)
			return nil, nil, errorCode
		end

		local releaseSpawnPlayers: { Player } = {}
		local releaseSourceOrderByPlayer: { [Player]: number } = {}
		for _, operation in transaction.operations do
			if operation.matchExpectation then
				releaseSourceOrderByPlayer[operation.player] = operation.sourceOrder
			end
		end
		for _, mutation in mutations do
			if mutation.lethal then
				assert(
					releaseSourceOrderByPlayer[mutation.player] ~= nil,
					"lethal mover mutation lost its source order"
				)
				table.insert(releaseSpawnPlayers, mutation.player)
			end
		end
		-- Damage/Match publications retain mover traversal order. Spawn-release is
		-- only a Movement ownership dependency, so canonicalize that separate list
		-- by client source order. A later mover may legitimately kill a lower-slot
		-- player after an earlier mover killed a higher-slot player.
		table.sort(releaseSpawnPlayers, function(left: Player, right: Player): boolean
			local leftSourceOrder = assert(releaseSourceOrderByPlayer[left], "left mover release lost its source order")
			local rightSourceOrder =
				assert(releaseSourceOrderByPlayer[right], "right mover release lost its source order")
			if leftSourceOrder ~= rightSourceOrder then
				return leftSourceOrder < rightSourceOrder
			end
			return left.UserId < right.UserId
		end)
		table.freeze(releaseSpawnPlayers)
		local mutationByPlayer: { [Player]: MoverDamagePreparedMutation } = {}
		for _, mutation in mutations do
			mutationByPlayer[mutation.player] = mutation
		end
		local lifeBindings: { MoverDamageMovementLifeDependency } = {}
		for _, player in releaseSpawnPlayers do
			local mutation = mutationByPlayer[player]
			local binding = mutation and mutation.beforeMovementLifeBinding
			local summary = if binding then MovementService.InspectMovementLifeBinding(binding) else nil
			if
				not mutation
				or not mutation.lethal
				or not binding
				or not summary
				or not MovementService.ValidateMovementLifeBindingDependency(binding, summary)
				or summary.player ~= player
				or summary.character ~= mutation.beforeCharacter
				or summary.lifeSequence ~= mutation.lifeSequence
				or summary.playerSourceOrder ~= releaseSourceOrderByPlayer[player]
			then
				local errorCode = "mover-movement-life-dependency-unavailable"
				faultMoverDamageTransaction(transaction, errorCode)
				return nil, nil, errorCode
			end
			local dependency: MoverDamageMovementLifeDependency = {
				player = player,
				binding = binding,
				summary = summary,
			}
			table.freeze(dependency)
			table.insert(lifeBindings, dependency)
		end
		table.freeze(lifeBindings)
		local lethalMoverSources: { MoverDamageLethalSourceDependency } = {}
		for _, operation in transaction.operations do
			if operation.matchExpectation then
				local moverDeathSource = operation.moverDeathSource
				local moverDeathSourceSummary = operation.moverDeathSourceSummary
				local stageReceipt = operation.moverDeathStageReceipt
				local stageCapability = if stageReceipt
					then moverDeathSourceOwner.stageReceiptCapabilities[stageReceipt]
					else nil
				if
					operation.kind ~= "LivePlayer"
					or not moverDeathSource
					or not moverDeathSourceSummary
					or not stageReceipt
					or not stageCapability
					or stageCapability.status ~= "Staged"
					or stageCapability.transaction ~= transaction
					or stageCapability.body ~= operation.body
					or stageCapability.context ~= operation.context
					or stageCapability.operationIndex ~= operation.operationIndex
					or stageCapability.moverDeathSource ~= moverDeathSource
					or stageCapability.moverDeathSourceSummary ~= moverDeathSourceSummary
				then
					local errorCode = "mover-lethal-source-dependency-unavailable"
					faultMoverDamageTransaction(transaction, errorCode)
					return nil, nil, errorCode
				end
				local dependency: MoverDamageLethalSourceDependency = {
					player = operation.player,
					source = moverDeathSource,
					sourceSummary = moverDeathSourceSummary,
					stageReceipt = stageReceipt,
					body = operation.body,
					operationIndex = operation.operationIndex,
					context = operation.context,
				}
				table.freeze(dependency)
				table.insert(lethalMoverSources, dependency)
			end
		end
		table.freeze(lethalMoverSources)
		local movementDependencySummary: MoverDamageMovementDependencySummary = {
			releaseSpawnPlayers = releaseSpawnPlayers,
			lifeBindings = lifeBindings,
			lethalMoverSources = lethalMoverSources,
		}
		table.freeze(movementDependencySummary)
		local prepared: MoverDamagePrepared = table.freeze({})
		local receipt: MoverDamageApplyReceipt = table.freeze({})
		local capability: MoverDamagePreparedCapability = {
			transaction = transaction,
			status = "Prepared",
			prepared = prepared,
			receipt = receipt,
			corpsePrepared = corpsePrepared,
			dependencySummary = dependencySummary,
			movementDependencySummary = movementDependencySummary,
			boundMatchPrepared = boundMatchPrepared,
			boundMatchSummary = boundMatchSummary,
			matchApplyReceipt = boundMatchApplyReceipt,
			matchDependencySatisfied = dependencySummary.operationCount == 0,
			mutations = mutations,
			publications = publications,
			applyValidated = false,
		}
		if dependencySummary.operationCount > 0 then
			capability.matchDependencySatisfied = true
		end
		for _, stageReceipt in transaction.stageReceipts do
			local stageCapability = moverDeathSourceOwner.stageReceiptCapabilities[stageReceipt]
			if stageCapability and stageCapability.transaction == transaction then
				stageCapability.status = "Prepared"
			end
		end
		moverDamagePreparedCapabilities[prepared] = capability
		moverDamageReceiptCapabilities[receipt] = capability
		transaction.prepared = prepared
		transaction.status = "Prepared"
		return prepared, dependencySummary, nil
	end

	local function bindMoverMatchPreparedDependency(
		preparedValue: unknown,
		matchPrepared: unknown,
		matchSummary: unknown
	): (boolean, string?)
		local capability, capabilityError = getMoverDamagePreparedCapability(preparedValue, "Prepared")
		if not capability then
			return false, capabilityError
		end
		if capability.dependencySummary.operationCount == 0 then
			return false, "mover-match-prepared-dependency-empty"
		end
		if capability.boundMatchPrepared ~= nil or capability.boundMatchSummary ~= nil then
			if matchPrepared == capability.boundMatchPrepared and matchSummary == capability.boundMatchSummary then
				return validateBoundMoverMatchDependency(capability)
			end
			return false, "mover-match-prepared-dependency-already-bound"
		end
		local matchApi = MatchService :: any
		if
			type(matchApi.InspectPreparedEliminationBatch) ~= "function"
			or type(matchApi.ValidatePreparedEliminationBatchDependency) ~= "function"
		then
			return false, "mover-match-prepared-api-unavailable"
		end
		if matchApi.InspectPreparedEliminationBatch(matchPrepared) ~= matchSummary then
			return false, "invalid-mover-match-prepared-association"
		end
		local valid, validationError = matchApi.ValidatePreparedEliminationBatchDependency(matchPrepared, matchSummary)
		if not valid then
			return false, validationError or "invalid-mover-match-prepared-dependency"
		end
		if not moverMatchPreparedSummaryMatches(capability.dependencySummary, matchSummary) then
			return false, "mover-match-prepared-summary-mismatch"
		end
		capability.boundMatchPrepared = matchPrepared
		capability.boundMatchSummary = matchSummary
		capability.matchDependencySatisfied = true
		capability.applyValidated = false
		return true, nil
	end

	local function inspectMoverPreparedMovementDependency(preparedValue: unknown): MoverDamageMovementDependencySummary?
		local capability = select(1, getMoverDamagePreparedCapability(preparedValue, "Prepared"))
		return if capability then capability.movementDependencySummary else nil
	end

	local function validateMoverPreparedMovementDependency(
		preparedValue: unknown,
		summaryValue: unknown
	): (boolean, string?)
		local capability, capabilityError = getMoverDamagePreparedCapability(preparedValue, "Prepared")
		if not capability then
			return false, capabilityError
		end
		if
			summaryValue ~= capability.movementDependencySummary
			or not table.isfrozen(capability.movementDependencySummary)
		then
			return false, "invalid-mover-damage-movement-dependency"
		end
		return true, nil
	end

	local function canApplyPreparedMoverDamage(preparedValue: unknown): (boolean, string?)
		local capability, capabilityError = getMoverDamagePreparedCapability(preparedValue, "Prepared")
		if not capability then
			return false, capabilityError
		end
		capability.applyValidated = false
		local currentError = moverDamagePreparedCurrentError(preparedValue, capability, true)
		if currentError then
			return false, currentError
		end
		local dependencyValid, dependencyError = validateBoundMoverMatchDependency(capability)
		if not dependencyValid then
			return false, dependencyError
		end
		if capability.boundMatchPrepared ~= nil then
			local matchCanApply, matchCanApplyError =
				MatchService.CanApplyPreparedEliminationBatch(capability.boundMatchPrepared)
			if not matchCanApply then
				return false, matchCanApplyError or "mover-match-prepared-preflight-failed"
			end
		end
		local corpseCanApply, corpseCanApplyError = CorpseService.CanApplyPrepared(capability.corpsePrepared)
		if not corpseCanApply then
			return false, corpseCanApplyError or "mover-corpse-prepared-preflight-failed"
		end
		capability.applyValidated = true
		return true, nil
	end

	local function applyPreparedMoverDamage(preparedValue: unknown): MoverDamageApplyReceipt
		local capability, capabilityError = getMoverDamagePreparedCapability(preparedValue, "Prepared")
		assert(capability, capabilityError or "invalid-mover-damage-prepared")
		assert(capability.applyValidated, "mover-damage-prepared-not-validated")
		assert(capability.matchDependencySatisfied, "mover-damage-match-prepared-dependency-not-satisfied")
		-- Movement has already swapped its prepared frame root. All cross-owner life
		-- capability validation ran in both adjacent preflight passes; this final
		-- local check must not re-enter Movement/EntitySlot inside the apply gap.
		local currentError = moverDamagePreparedCurrentError(preparedValue, capability, false)
		assert(currentError == nil, currentError or "stale-mover-damage-prepared")
		moverDeathSourceOwner.retireStageReceipts(capability.transaction)

		-- The coordinator has already preflighted Movement and this nested
		-- Match/Combat/Corpse participant. Match returns its pre-registered receipt;
		-- everything after that first root swap is a fixed assignment into roots
		-- proven mutable above.
		if capability.boundMatchPrepared ~= nil then
			assert(
				MatchService.ApplyPreparedEliminationBatch(capability.boundMatchPrepared)
					== capability.matchApplyReceipt,
				"mover Match apply returned an unprepared receipt"
			)
		end
		for _, mutation in capability.mutations do
			local record = mutation.record
			record.health = mutation.afterHealth
			record.armor = mutation.afterArmor
			record.alive = mutation.afterAlive
			record.score = mutation.afterScore
			record.deaths = mutation.afterDeaths
			if mutation.lethal then
				record.weaponId = mutation.afterWeaponId
				record.commandWeaponId = mutation.afterCommandWeaponId
				record.weaponState = mutation.afterWeaponState
				record.weaponTimeMilliseconds = mutation.afterWeaponTimeMilliseconds
				record.overstackAccumulator = mutation.afterOverstackAccumulator
				record.powerupExpiries = mutation.afterPowerupExpiries
				record.respawnEligibleAtMilliseconds = mutation.respawnEligibleAtMilliseconds
				record.forcedRespawnAtMilliseconds = mutation.afterForcedRespawnAtMilliseconds
				record.manualRespawnQueued = mutation.afterManualRespawnQueued
				record.respawnRequested = mutation.afterRespawnRequested
				record.lastDroppedLifeSequence = mutation.afterLastDroppedLifeSequence
			end
		end
		CorpseService.ApplyPrepared(capability.corpsePrepared)
		local transaction = capability.transaction
		transaction.prepared = nil
		transaction.status = "Applied"
		capability.status = "Applied"
		capability.applyValidated = false
		moverDamagePreparedCapabilities[preparedValue :: MoverDamagePrepared] = nil
		return capability.receipt
	end

	local function flushPreparedMoverDamage(receiptValue: unknown): MoverDamagePublicationReport
		local capability, capabilityError = getMoverDamageReceiptCapability(receiptValue)
		assert(capability, capabilityError or "invalid-mover-damage-receipt")
		assert(capability.status == "Applied", "invalid-mover-damage-receipt-state")
		local publicationCount = 0
		local publicationFaultCount = 0
		local function publish(label: string, callback: () -> ())
			publicationCount += 1
			local succeeded, failure = xpcall(callback, debug.traceback)
			if not succeeded then
				publicationFaultCount += 1
				warn("Mover damage publication failed after authority applied", label, failure)
			end
		end
		if capability.matchApplyReceipt ~= nil then
			publish("MatchAttributes", function()
				local matchReport, matchFlushError =
					MatchService.FlushPreparedEliminationAttributes(capability.matchApplyReceipt)
				if not matchReport then
					error(matchFlushError or "mover Match attribute publication flush failed")
				end
				publicationCount += matchReport.attemptedPublicationCount
				publicationFaultCount += matchReport.faultCount
			end)
		end

		for _, mutation in capability.mutations do
			publish("CombatState", function()
				local record = mutation.record
				if mutation.lethal then
					setCharacterCombatQuery(record.character, false)
				elseif mutation.afterAlive then
					syncHumanoidHealth(record)
				end
				if
					MatchService.GetPlayerScore(mutation.player) ~= record.score
					or MatchService.GetPlayerDeaths(mutation.player) ~= record.deaths
				then
					error("prepared Combat/Match publication root diverged")
				end
				publishPlayerRecord(mutation.player, record)
			end)
		end
		for _, publication in capability.publications do
			if publication.damagePayload then
				publish("DamageEvent", function()
					broadcast(publication.damagePayload :: { [string]: any })
				end)
			end
			if publication.elimination then
				publish("EliminationEvent", function()
					emitElimination(publication.elimination :: EliminationEvent)
					local character = MovementService.GetCharacter(publication.player)
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if humanoid then
						humanoid.Health = 0
					end
				end)
			end
		end
		if capability.matchApplyReceipt ~= nil then
			publish("MatchObservers", function()
				local matchReport, matchFlushError =
					MatchService.FlushPreparedEliminationObservers(capability.matchApplyReceipt)
				if not matchReport then
					error(matchFlushError or "mover Match observer publication flush failed")
				end
				publicationCount += matchReport.attemptedPublicationCount
				publicationFaultCount += matchReport.faultCount
			end)
		end

		capability.status = "Flushed"
		moverDamageReceiptCapabilities[receiptValue :: MoverDamageApplyReceipt] = nil
		finishMoverDamageTransaction(capability.transaction, "Flushed")
		local report: MoverDamagePublicationReport = {
			authorityApplied = true,
			operationCount = #capability.publications,
			publicationCount = publicationCount,
			publicationFaultCount = publicationFaultCount,
		}
		table.freeze(report)
		return report
	end

	local function abortMoverDamageTransaction(token: unknown): boolean
		local transaction = select(1, getActiveMoverDamageTransaction(token, nil))
		if not transaction then
			return false
		end
		local status: MoverDamageStatus = transaction.status
		if status ~= "Open" and status ~= "Sealed" and status ~= "Prepared" then
			return false
		end
		if status == "Prepared" then
			local prepared = transaction.prepared
			local capability = if prepared then moverDamagePreparedCapabilities[prepared] else nil
			if not prepared or not capability or capability.status ~= "Prepared" then
				return false
			end
			capability.status = "Aborted"
			capability.applyValidated = false
			moverDamagePreparedCapabilities[prepared] = nil
			moverDamageReceiptCapabilities[capability.receipt] = nil
			transaction.prepared = nil
		end
		if transaction.matchToken ~= nil then
			if not MatchService.AbortEliminationBatch(transaction.matchToken) then
				return false
			end
			transaction.matchToken = nil
		end
		CorpseService.Abort(transaction.corpseToken)
		finishMoverDamageTransaction(transaction, "Aborted")
		return true
	end

	local moverDamageAdapter: MoverDamageAdapter = table.freeze({
		Begin = beginMoverDamageTransaction,
		CollectBodies = collectMoverCorpseBodies,
		StageSineCrush = stageSineMoverCrush,
		StageDoorDamage = stageDoorMoverDamage,
		ValidateMoverDeathStageReceipt = moverDeathSourceOwner.validateStageReceipt,
		IsAlive = isMoverDamageShadowAlive,
		ApplyMoverBodies = applyMoverCorpseBodies,
		Seal = sealMoverDamageTransaction,
		Prepare = prepareMoverDamageTransaction,
		BindMatchPreparedDependency = bindMoverMatchPreparedDependency,
		InspectPreparedMovementDependency = inspectMoverPreparedMovementDependency,
		ValidatePreparedMovementDependency = validateMoverPreparedMovementDependency,
		CanApplyPrepared = canApplyPreparedMoverDamage,
		ApplyPrepared = applyPreparedMoverDamage,
		FlushPrepared = flushPreparedMoverDamage,
		Abort = abortMoverDamageTransaction,
	})

	return moverDamageAdapter
end

return table.freeze(CombatMoverDamageCoordinator)
