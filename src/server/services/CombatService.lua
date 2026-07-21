--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-authoritative Roblox translation of selected behavior from:
  code/game/bg_pmove.c (PM_Weapon cadence and weapon-change timing)
  code/game/g_weapon.c (hitscan, shotgun, lightning, gauntlet,
  weapon_grenadelauncher_fire, CalcMuzzlePoint)
  code/game/g_missile.c (rocket, plasma, grenade, bounce, G_RunMissile,
  MISSILE_PRESTEP_TIME)
  code/game/g_combat.c (CheckArmor, G_Damage, G_RadiusDamage, player_die)
  code/game/g_mover.c (G_MoverPush Sine crush and Blocked_Door G_Damage order)
  code/game/g_active.c (ClientEvents falling damage)
  code/game/g_active.c and code/game/g_client.c (attack-gated respawn lifecycle)
  code/game/g_main.c (G_RunFrame level time, entity order, g_forcerespawn)
  code/game/bg_pmove.c and code/game/g_active.c
    (PM_CrashLand events and 5/10 MOD_FALLING damage)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local AccuracyRules = require(sharedRoot.combat.AccuracyRules)
local OneShotRules = require(sharedRoot.combat.OneShotRules)
local RailImpressiveRules = require(sharedRoot.combat.RailImpressiveRules)
local HoldableRules = require(sharedRoot.items.HoldableRules)
local PowerupRules = require(sharedRoot.items.PowerupRules)
local Catalog = require(sharedRoot.commerce.Catalog)
local CombatEventPresentationRules = require(sharedRoot.combat.CombatEventPresentationRules)
local Constants = require(sharedRoot.simulation.Constants)
local CommandQuantization = require(sharedRoot.simulation.CommandQuantization)
local CombatShotTraceRules = require(sharedRoot.simulation.CombatShotTraceRules)
local EntityStateConversionRules = require(sharedRoot.simulation.EntityStateConversionRules)
local EliminationPresentationRules = require(sharedRoot.presentation.EliminationPresentationRules)
local EnvironmentDamageRules = require(sharedRoot.combat.EnvironmentDamageRules)
local HitscanRewindRules = require(sharedRoot.combat.HitscanRewindRules)
local Landing = require(sharedRoot.simulation.Landing)
local MatchConfig = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchConfig"))
local MatchEliminationShadowRules =
	require(sharedRoot:WaitForChild("match"):WaitForChild("MatchEliminationShadowRules"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local Movement = require(sharedRoot.simulation.Movement)
local MoverConsequenceRules = require(sharedRoot.simulation.MoverConsequenceRules)
local MoverPushRules = require(sharedRoot.simulation.MoverPushRules)
local ProjectileEntityLifecycleRules = require(sharedRoot.combat.ProjectileEntityLifecycleRules)
local ProjectileFrameTimeRules = require(sharedRoot.combat.ProjectileFrameTimeRules)
local ProjectileTrajectory = require(sharedRoot.combat.ProjectileTrajectory)
local DroppedWeaponRules = require(sharedRoot.items.DroppedWeaponRules)
local NoImpactRules = require(sharedRoot.combat.NoImpactRules)
local RemoteNames = require(sharedRoot.RemoteNames)
local SplashVisibility = require(sharedRoot.combat.SplashVisibility)
local SurfaceContact = require(sharedRoot.simulation.SurfaceContact)
local WeaponDefinitions = require(sharedRoot.combat.WeaponDefinitions)
local WeaponSelection = require(sharedRoot.combat.WeaponSelection)
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local CorpseService = require(script.Parent.CorpseService)
local CombatInventoryRuntime = require(script.Parent.CombatInventoryRuntime)
local CombatHitscanRewindRuntime = require(script.Parent.CombatHitscanRewindRuntime)
local CombatPersonalTeleporterCoordinator = require(script.Parent.CombatPersonalTeleporterCoordinator)
local CombatRespawnCoordinator = require(script.Parent.CombatRespawnCoordinator)
local CombatFramePublicationService = require(script.Parent.CombatFramePublicationService)
local BodyQueuePresentationService = require(script.Parent.BodyQueuePresentationService)
local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local MatchService = require(script.Parent.MatchService)
local MovementService = require(script.Parent.MovementService)
local CombatMoverDamageCoordinator = require(script.Parent.CombatMoverDamageCoordinator)
local ProjectileEntityService = require(script.Parent.ProjectileEntityService)

local CombatService = {}

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
	matchId: string,
	railCooldownReset: boolean,
	effectId: string?,
}

export type InventorySnapshot = {
	selectedWeaponId: number,
	infiniteAmmo: boolean,
	holdableId: number,
	holdableUseHeld: boolean,
	ownedWeaponIds: { number },
	ammoByWeapon: { [number]: number },
}

export type ItemState = {
	alive: boolean,
	pickupsEnabled: boolean,
	position: Vector3,
	look: Vector3,
	lifeSequence: number,
	matchId: string?,
	health: number,
	maxHealth: number,
	armor: number,
	ammoByWeapon: { [number]: number },
}

type RewindBuffer = CombatHitscanRewindRuntime.Buffer
export type HitscanRewindObservation = CombatHitscanRewindRuntime.Observation
export type HitscanRewindDebugMetrics = CombatHitscanRewindRuntime.DebugMetrics

type AmmoEntry = {
	weaponId: number,
	ammo: number,
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
	-- One-Shot rail-jump is a mod action with an independent integer deadline.
	railJumpReadyAtMilliseconds: number,
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
	railAccurateCount: number,
	impressiveCount: number,
	impressiveRewardUntilMilliseconds: number?,
	noAmmoEvents: number,
	lifeSequence: number,
	movementLifeBinding: MovementService.MovementLifeBinding?,
	serverShotSequence: number,
	lastShotId: string,
	character: Model?,
	characterMatchId: string?,
	-- Q3 client->timeResidual, stored as exact integer milliseconds.
	overstackAccumulator: number,
	respawnEligibleAtMilliseconds: number?,
	forcedRespawnAtMilliseconds: number?,
	manualRespawnQueued: boolean,
	respawnRequested: boolean,
	lastDroppedLifeSequence: number,
	lastLandingFrame: number,
	lastLandingContactIndex: number,
	powerupExpiries: { [number]: number },
	environmentDamageState: EnvironmentDamageRules.State,
	pendingPainFeedbackLevelTimeMilliseconds: number?,
}

export type DeathWeaponDropRequest = {
	dropId: string,
	matchId: string,
	itemId: string,
	quantity: number,
	position: Vector3,
	velocity: Vector3,
}

export type DirectDeathWeaponDropDecision = "Insert" | "Omit"
export type DirectDeathWeaponDropOmissionReason =
	"NoDrop"
	| "Void"
	| "AlreadyDropped"
	| "DisabledByRules"
	| "IneligibleMatchState"
	| "IneligibleWeapon"

type DeathDropInsertionPublicationReport = {
	read authorityApplied: boolean,
	read attemptedPublicationCount: number,
	read faultCount: number,
	read markerCreated: boolean,
}

type DeathDropBatchPublicationReport = {
	read authorityApplied: boolean,
	read requestedCount: number,
	read insertedCount: number,
	read attemptedPublicationCount: number,
	read faultCount: number,
	read markerCreatedCount: number,
}

export type DeathDropInsertionAdapter = {
	read StageSynchronousMover: (
		requestValue: unknown,
		operationOrderValue: unknown
	) -> (MoverPushRules.Body?, string?),
	read Prepare: (
		requestValue: unknown,
		operationOrderValue: unknown,
		frameValue: unknown,
		frameSummaryValue: unknown
	) -> (unknown?, unknown?, string?),
	read InspectPrepared: (preparedValue: unknown) -> unknown?,
	read ValidatePreparedDependency: (preparedValue: unknown, summaryValue: unknown) -> boolean,
	read CanApplyPrepared: (preparedValue: unknown) -> (boolean, string?),
	read ApplyPrepared: (preparedValue: unknown) -> unknown,
	read ValidateAppliedDependency: (receiptValue: unknown, summaryValue: unknown) -> (boolean, string?),
	read FlushPrepared: (receiptValue: unknown) -> (DeathDropInsertionPublicationReport?, string?),
	read AbortPrepared: (preparedValue: unknown) -> (boolean, string?),
	read PrepareBatch: (
		requestsValue: unknown,
		operationOrderValue: unknown,
		frameValue: unknown,
		frameSummaryValue: unknown
	) -> (unknown?, unknown?, string?),
	read InspectPreparedBatch: (preparedValue: unknown) -> unknown?,
	read ValidatePreparedBatchDependency: (preparedValue: unknown, summaryValue: unknown) -> boolean,
	read CanApplyPreparedBatch: (preparedValue: unknown) -> (boolean, string?),
	read ApplyPreparedBatch: (preparedValue: unknown) -> unknown,
	read ValidateAppliedBatchDependency: (receiptValue: unknown, summaryValue: unknown) -> (boolean, string?),
	read FlushPreparedBatch: (receiptValue: unknown) -> (DeathDropBatchPublicationReport?, string?),
	read AbortPreparedBatch: (preparedValue: unknown) -> (boolean, string?),
}

export type DirectDeathCollisionContext = {
	read postDamageHealth: number,
	read meansOfDeath: MoverConsequenceRules.MeansOfDeath,
	read bloodEnabled: boolean,
	read noDrop: boolean,
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

export type PreparedDirectDeath = {}
export type DirectDeathApplyReceipt = {}
export type DirectDeathCause = {}
export type DirectDeathCauseKind =
	"PlayerDirect"
	| "MissileImpact"
	| "ProjectileSplash"
	| "WorldDamage"
	| "ForcedWorldPlayerDie"
	| "SuicidePlayerDie"
	| "Telefrag"
export type DirectDeathDamageMode = "GDamage" | "PlayerDie"
export type DirectDeathHandoff = {}
export type DirectDeathHandoffSummary = {
	read target: Player,
	read targetUserId: number,
	read lifeSequence: number,
	read matchId: string,
	read matchLineage: MatchService.MatchLineage,
	read deathTimeMilliseconds: number,
	read bodyQueueHandle: unknown,
	read bodyQueueDeathSummary: unknown,
	read corpseTombstone: CorpseService.RespawnCopyTombstone,
	read preparedCorpseTombstoneSummary: CorpseService.PreparedRespawnCopyTombstoneSummary,
}
export type PreparedDirectDeathSummary = {
	read authoritativeFrame: AuthoritativeFrameService.Frame,
	read authoritativeFrameSummary: AuthoritativeFrameService.Summary,
	read target: Player,
	read attacker: Player?,
	read targetUserId: number,
	read attackerUserId: number,
	read lifeSequence: number,
	read matchId: string,
	read matchLineage: MatchService.MatchLineage,
	read levelTimeMilliseconds: number,
	read causeKind: DirectDeathCauseKind,
	read damageMode: DirectDeathDamageMode,
	read pointContents: number,
	read publishesDamage: boolean,
	read means: string,
	read rawDamage: number,
	read adjustedDamage: number,
	read armorSave: number,
	read healthDamage: number,
	read postDamageHealth: number,
	read meansOfDeath: MoverConsequenceRules.MeansOfDeath,
	read bloodEnabled: boolean,
	read noDrop: boolean,
	read lethalVelocityDelta: Vector3,
	read lethalKnockbackSeconds: number?,
	read attackerSourceSummary: MovementService.NormalToDeadSourceSummary,
	read inflictorSourceSummary: MovementService.NormalToDeadSourceSummary,
	read deathWeaponDropDecision: DirectDeathWeaponDropDecision,
	read deathWeaponDropOmissionReason: DirectDeathWeaponDropOmissionReason?,
	read deathWeaponDropInsertionSummary: unknown?,
	read deathPowerupDropCount: number,
	read deathDropBatchInsertionSummary: unknown?,
}

type DirectDeathCauseCaptureRequest = {
	kind: DirectDeathCauseKind,
	target: Player,
	attacker: Player?,
	rawDamage: number?,
	direction: Vector3?,
	shot: ShotContext,
	targetBody: MoverPushRules.Body?,
	projectileSource: ProjectileEntityService.ProjectileSource?,
	worldMeans: string?,
}

local executeDirectDeath: (request: DirectDeathCauseCaptureRequest) -> (boolean, string?)

type DirectDeathCauseStatus = "Current" | "Bound" | "Retired"
type DirectDeathProjectileWitness = {
	owner: Player,
	source: ProjectileEntityService.ProjectileSource,
	shot: ShotContext,
	authorityTrajectoryState: ProjectileTrajectory.State,
	position: Vector3,
}
type DirectDeathCauseCapability = {
	cause: DirectDeathCause,
	status: DirectDeathCauseStatus,
	kind: DirectDeathCauseKind,
	damageMode: DirectDeathDamageMode,
	classification: unknown,
	target: Player,
	targetRecord: CombatRecord,
	targetHealth: number,
	targetArmor: number,
	targetLifeBinding: MovementService.MovementLifeBinding,
	targetLifeSummary: MovementService.MovementLifeBindingSummary,
	targetBody: MoverPushRules.Body,
	hitBody: MoverPushRules.Body,
	attacker: Player?,
	attackerRecord: CombatRecord?,
	rawDamage: number,
	direction: Vector3,
	means: string,
	isSplash: boolean,
	bypassCombatEligibility: boolean,
	publishesDamage: boolean,
	fixedPostDamageHealth: number?,
	shot: ShotContext,
	shotSnapshot: ShotContext,
	shotEventSequence: number,
	pointContents: number,
	meansOfDeath: MoverConsequenceRules.MeansOfDeath,
	bloodEnabled: boolean,
	attackerSource: MovementService.NormalToDeadSource,
	attackerSourceSummary: MovementService.NormalToDeadSourceSummary,
	inflictorSource: MovementService.NormalToDeadSource,
	inflictorSourceSummary: MovementService.NormalToDeadSourceSummary,
	projectileSource: ProjectileEntityService.ProjectileSource?,
	projectileSourceSummary: ProjectileEntityService.SourceSummary?,
	projectile: DirectDeathProjectileWitness?,
	authoritativeFrame: AuthoritativeFrameService.Frame,
	authoritativeFrameSummary: AuthoritativeFrameService.Summary,
	matchId: string,
	matchLineage: MatchService.MatchLineage,
}
export type DirectDeathPublicationReport = {
	read authorityApplied: boolean,
	read publicationCount: number,
	read publicationFaultCount: number,
	read powerupDropRequestedCount: number,
	read powerupDropInsertedCount: number,
	read powerupDropFaultCount: number,
}

type DirectDeathCombatMutation = {
	target: Player,
	record: CombatRecord,
	attacker: Player?,
	attackerRecord: CombatRecord?,
	railCooldownReset: boolean,
	shot: ShotContext,
	shotEventSequenceBefore: number,
	shotEventSequenceAfter: number,
	beforeHealth: number,
	beforeArmor: number,
	beforeAlive: boolean,
	beforeScore: number,
	beforeDeaths: number,
	beforeWeaponId: number,
	beforeCommandWeaponId: number,
	beforeWeaponState: WeaponState,
	beforeWeaponTimeMilliseconds: number,
	beforeLastWeaponPmoveLevelTimeMilliseconds: number,
	beforeLastPrePmoveGauntletLevelTimeMilliseconds: number,
	beforeOverstackAccumulator: number,
	beforePowerupExpiries: { [number]: number },
	beforeRespawnEligibleAtMilliseconds: number?,
	beforeForcedRespawnAtMilliseconds: number?,
	beforeManualRespawnQueued: boolean,
	beforeRespawnRequested: boolean,
	beforeLastDroppedLifeSequence: number,
	beforeOwnedWeapons: { [number]: boolean },
	beforeAmmoByWeapon: { [number]: number },
	beforeInfiniteAmmo: boolean,
	beforeMovementLifeBinding: MovementService.MovementLifeBinding,
	beforeCharacter: Model?,
	beforeAttackerScore: number?,
	beforeAttackerDeaths: number?,
	beforeAttackerWeaponState: WeaponState?,
	beforeAttackerWeaponTimeMilliseconds: number?,
	afterHealth: number,
	afterArmor: number,
	afterAlive: boolean,
	afterScore: number,
	afterDeaths: number,
	afterCommandWeaponId: number,
	afterWeaponState: WeaponState,
	afterWeaponTimeMilliseconds: number,
	afterOverstackAccumulator: number,
	afterPowerupExpiries: { [number]: number },
	afterRespawnEligibleAtMilliseconds: number?,
	afterForcedRespawnAtMilliseconds: number?,
	afterManualRespawnQueued: boolean,
	afterRespawnRequested: boolean,
	afterLastDroppedLifeSequence: number,
	afterAttackerScore: number?,
	afterAttackerDeaths: number?,
	afterAttackerWeaponState: WeaponState?,
	afterAttackerWeaponTimeMilliseconds: number?,
}

type DirectDeathPreparedStatus = "Prepared" | "Applied" | "Flushed" | "Aborted"
type DirectDeathHandoffCapability = {
	handoff: DirectDeathHandoff,
	status: "Pending" | "Current" | "Retired",
	summary: DirectDeathHandoffSummary,
	target: Player,
	record: CombatRecord,
	bodyQueueHandle: unknown,
	bodyQueueDeathSummary: unknown,
	corpseTombstone: CorpseService.RespawnCopyTombstone,
	preparedCorpseSource: CorpseService.RespawnCopyTombstoneData,
	movementLifeBinding: MovementService.MovementLifeBinding,
	movementLifeSummary: MovementService.MovementLifeBindingSummary,
	character: Model?,
	respawnEligibleAtMilliseconds: number?,
	forcedRespawnAtMilliseconds: number?,
}
type DirectDeathPreparedCapability = {
	prepared: PreparedDirectDeath,
	receipt: DirectDeathApplyReceipt,
	status: DirectDeathPreparedStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	cause: DirectDeathCause,
	causeCapability: DirectDeathCauseCapability,
	summary: PreparedDirectDeathSummary,
	mutation: DirectDeathCombatMutation,
	collisionContext: DirectDeathCollisionContext,
	deathWeaponDrop: DeathWeaponDropRequest?,
	deathWeaponDropDecision: DirectDeathWeaponDropDecision,
	deathWeaponDropOmissionReason: DirectDeathWeaponDropOmissionReason?,
	deathDropInsertionAdapter: DeathDropInsertionAdapter?,
	deathDropInsertionPrepared: unknown?,
	deathDropInsertionSummary: unknown?,
	deathDropInsertionReceipt: unknown?,
	deathDropInsertionFlushed: boolean,
	deathDropBatchRequests: { DeathWeaponDropRequest },
	deathPowerupDropRequests: { DeathWeaponDropRequest },
	bodyQueuePrepared: unknown,
	bodyQueueSummary: unknown,
	bodyQueueHandles: { unknown },
	movementPrepared: MovementService.PreparedNormalToDead,
	movementSummary: MovementService.PreparedNormalToDeadSummary,
	movementReceipt: MovementService.NormalToDeadApplyReceipt,
	attackerSource: MovementService.NormalToDeadSource,
	inflictorSource: MovementService.NormalToDeadSource,
	matchToken: unknown,
	matchPrepared: unknown,
	matchSummary: MatchService.PreparedEliminationBatchSummary,
	matchReceipt: unknown,
	matchResult: MatchService.EliminationResult,
	matchOutcome: MatchEliminationShadowRules.EliminationOutcome,
	corpseToken: CorpseService.TransactionToken,
	corpsePrepared: CorpseService.PreparedCommit,
	corpseReceipt: CorpseService.CommitReceipt,
	corpseTombstone: CorpseService.RespawnCopyTombstone,
	corpseTombstoneSummary: CorpseService.PreparedRespawnCopyTombstoneSummary,
	deathBody: MoverPushRules.Body,
	handoff: DirectDeathHandoff,
	handoffSummary: DirectDeathHandoffSummary,
	handoffCapability: DirectDeathHandoffCapability,
	damagePayload: { [string]: any }?,
	elimination: EliminationEvent,
	eliminationPresentationPlans: { EliminationPresentationRules.OrbPlan },
	corpseAbortComplete: boolean,
	movementAbortComplete: boolean,
	bodyQueueAbortComplete: boolean,
	matchAbortComplete: boolean,
	deathDropInsertionAbortComplete: boolean,
}

type PendingExternalElimination = {
	record: CombatRecord,
	character: Model?,
	lifeSequence: number,
	matchId: string?,
	means: string,
	collisionContext: DirectDeathCollisionContext,
	requireDeadHumanoid: boolean,
}

type GauntletPrePmoveReceipt = {
	read player: Player,
	read inputSequence: number,
	read revision: number,
	read lifeSequence: number,
	read levelTimeMilliseconds: number,
	read origin: Vector3,
	read direction: Vector3,
	read position: Vector3,
	read hitMarker: boolean,
	read shot: ShotContext,
}

export type MoverDamagePrepared = CombatMoverDamageCoordinator.MoverDamagePrepared
export type MoverDamageApplyReceipt = CombatMoverDamageCoordinator.MoverDamageApplyReceipt
export type MoverDamageStageReceipt = CombatMoverDamageCoordinator.MoverDamageStageReceipt
export type MoverDamagePublicationReport = CombatMoverDamageCoordinator.MoverDamagePublicationReport
export type MoverDamageContext = CombatMoverDamageCoordinator.MoverDamageContext
export type MoverDamageMatchDependencySummary = CombatMoverDamageCoordinator.MoverDamageMatchDependencySummary
export type MoverDamageMovementDependencySummary = CombatMoverDamageCoordinator.MoverDamageMovementDependencySummary
export type MoverDamageLethalSourceDependency = CombatMoverDamageCoordinator.MoverDamageLethalSourceDependency
export type MoverDamageMovementLifeDependency = CombatMoverDamageCoordinator.MoverDamageMovementLifeDependency
export type MoverDamageAdapter = CombatMoverDamageCoordinator.MoverDamageAdapter

type Projectile = {
	part: Part?,
	owner: Player,
	source: ProjectileEntityService.ProjectileSource,
	registration: EntitySlotService.Registration,
	dynamicBinding: EntityFrameDispatcherService.DynamicBinding,
	trajectoryOrigin: Vector3,
	-- This state is serialized for clients and is evaluated in synchronized
	-- Roblox server time. It is never consulted for collision, damage, or fuse
	-- authority.
	trajectoryState: ProjectileTrajectory.State,
	-- Q3 BG_EvaluateTrajectory consumes integer level.time. Keep a separate
	-- server-only epoch so scheduler/clamp time can never advance gameplay.
	authorityTrajectoryState: ProjectileTrajectory.State,
	position: Vector3,
	velocity: Vector3,
	trajectoryStartServerTime: number,
	simulatedThroughServerTime: number,
	simulatedThroughLevelTimeMilliseconds: number,
	fuseExpiresLevelTimeMilliseconds: number,
	bounceCount: number,
	stationary: boolean,
	shot: ShotContext,
	cleanupIntent: ProjectileEntityLifecycleRules.AdministrativeReleaseReason?,
}

type ProjectileRuntime = {
	getAppearance: (weaponId: number) -> (string, Color3, number),
	ensureFolder: () -> Folder,
	applyTrajectoryState: (part: Part, state: ProjectileTrajectory.State) -> (),
	createPart: (
		player: Player,
		shot: ShotContext,
		position: Vector3,
		trajectoryStartServerTime: number,
		trajectoryOrigin: Vector3,
		trajectoryState: ProjectileTrajectory.State
	) -> Part,
	rebasePresentation: (projectile: Projectile, stepServerTime: number) -> (),
	advance: (
		projectile: Projectile,
		frame: AuthoritativeFrameService.Frame,
		summary: AuthoritativeFrameService.Summary,
		stepServerTime: number
	) -> "Missile" | "Event" | "Released",
	fire: (
		player: Player,
		origin: Vector3,
		direction: Vector3,
		shot: ShotContext,
		launchServerTime: number,
		launchLevelTimeMilliseconds: number
	) -> (),
	queueCleanup: (owner: Player?, reason: ProjectileEntityLifecycleRules.AdministrativeReleaseReason) -> (),
	quarantine: () -> (),
	destroyPresentation: (projectile: Projectile) -> (),
	installRecord: (projectile: Projectile) -> (),
	removeRecord: (projectile: Projectile) -> (),
	inspectSource: (
		projectile: Projectile,
		expectedPhase: "Missile" | "Event"
	) -> ProjectileEntityService.SourceSummary,
	commitRelease: (
		projectile: Projectile,
		frame: AuthoritativeFrameService.Frame,
		reason: "NoImpact" | "EventExpired" | ProjectileEntityLifecycleRules.AdministrativeReleaseReason
	) -> (),
	transitionToEvent: (
		projectile: Projectile,
		frame: AuthoritativeFrameService.Frame,
		summary: AuthoritativeFrameService.Summary,
		stepServerTime: number,
		hitResult: CombatTraceResult?,
		directImpactVelocity: Vector3?
	) -> (),
}

type AccuracyContact = AccuracyRules.Contact
type AccuracyShotResult = AccuracyRules.ShotResult

local records: { [Player]: CombatRecord } = {}
local pendingExternalEliminations: { [Player]: PendingExternalElimination } = {}
local pendingSuicides: { [Player]: { record: CombatRecord, lifeSequence: number } } = {}
local suicideRequestTimes: { [Player]: number } = {}
local pendingGauntletPrePmoveByPlayer: { [Player]: GauntletPrePmoveReceipt } = {}
local snapshotRequestTimes: { [Player]: number } = {}
local lastLifeSequenceByUserId: { [number]: number } = {}
local projectiles: { Projectile } = {}
local projectilesByRegistration: { [EntitySlotService.Registration]: Projectile } = {}
local projectilesBySource: { [ProjectileEntityService.ProjectileSource]: Projectile } = {}
local projectileRuntime = ({} :: any) :: ProjectileRuntime
local projectilePhaseFaulted = false
local projectileDynamicBindingActivated = false
local started = false
local simulationFaultExtension: (() -> ())? = nil
local combatQueryEnabledByCharacter = setmetatable({}, { __mode = "k" }) :: {
	[Model]: boolean,
}

local OVERSTACK_DECAY_INTERVAL_MILLISECONDS = 1000
local OVERSTACK_DECAY_AMOUNT = 1
local PROJECTILE_EVENT_VALID_MILLISECONDS = ProjectileEntityLifecycleRules.EventValidMilliseconds
local MAXIMUM_DEBUG_COUNTER = 9_007_199_254_740_991
local SHADOW_REWIND_WEAPONS = table.freeze({
	[WeaponDefinitions.WeaponId.LightningGun] = true,
	[WeaponDefinitions.WeaponId.Railgun] = true,
})
local FIRE_PAYLOAD_KEYS = table.freeze({ sequence = true })
local ORDINARY_EXTERNAL_DEATH_CONTEXT: DirectDeathCollisionContext = table.freeze({
	postDamageHealth = 0,
	meansOfDeath = MoverConsequenceRules.MeansOfDeath.Ordinary,
	bloodEnabled = true,
	noDrop = false,
})
local ACCURACY_FAMILY_BY_WEAPON_ID: { [number]: AccuracyRules.WeaponFamily } = table.freeze({
	[WeaponDefinitions.WeaponId.Gauntlet] = AccuracyRules.WeaponFamilies.Gauntlet,
	[WeaponDefinitions.WeaponId.Machinegun] = AccuracyRules.WeaponFamilies.Machinegun,
	[WeaponDefinitions.WeaponId.Shotgun] = AccuracyRules.WeaponFamilies.Shotgun,
	[WeaponDefinitions.WeaponId.LightningGun] = AccuracyRules.WeaponFamilies.Lightning,
	[WeaponDefinitions.WeaponId.Railgun] = AccuracyRules.WeaponFamilies.Rail,
	[WeaponDefinitions.WeaponId.GrenadeLauncher] = AccuracyRules.WeaponFamilies.Projectile,
	[WeaponDefinitions.WeaponId.RocketLauncher] = AccuracyRules.WeaponFamilies.Projectile,
	[WeaponDefinitions.WeaponId.PlasmaGun] = AccuracyRules.WeaponFamilies.Projectile,
	[WeaponDefinitions.WeaponId.Bfg] = AccuracyRules.WeaponFamilies.Projectile,
})

local snapshotRemote: RemoteEvent?
local eventRemote: RemoteEvent?
local projectileFolder: Folder?
local worldFolder: Folder?
local eliminationSignal = Instance.new("BindableEvent")
local damageSignal = Instance.new("BindableEvent")
local requestCharacterRespawn: (Player, CombatRecord, number) -> boolean
local deathWeaponDropHandler: ((request: DeathWeaponDropRequest) -> boolean)? = nil
local synchronousMoverFlagDropHandler: ((Player, Vector3, number) -> ({ MoverPushRules.Body }?, string?))? = nil
local corpseDepartureCleanupOwner: CorpseService.DepartureCleanupOwner? = nil
local corpseMatchTransitionCleanupOwner: CorpseService.MatchTransitionCleanupOwner? = nil
local movementMatchTransitionCleanupOwner: MovementService.MatchTransitionCleanupOwner? = nil
local pendingPostBeginMatchCleanupId: string? = nil
local canDamageFrom: ((origin: Vector3, targetPosition: Vector3) -> boolean)? = nil
local directDeathOwner = {
	bodyQueueService = require(script.Parent.BodyQueueService),
	causeRules = require(sharedRoot.combat.DirectDeathCauseRules),
	worldPointContents = require(sharedRoot.simulation.WorldPointContents),
	deathDropInsertionAdapter = nil :: DeathDropInsertionAdapter?,
	powerupDropRuntime = require(script.Parent.DirectDeathPowerupDropRuntime).new({
		ResolveDeathDrops = PowerupRules.ResolveDeathDrops,
		ItemIdByPowerupId = PowerupRules.ItemIdByPowerupId,
		MakeSeed = DroppedWeaponRules.MakeSeed,
		LaunchVelocity = DroppedWeaponRules.LaunchVelocity,
	}),
	knownPointContentsMask = bit32.bor(1, 8, 16, 32, 2_147_483_648),
	traceCauseKinds = table.freeze({
		PlayerDirect = true,
		MissileImpact = true,
		ProjectileSplash = true,
	}),
	projectileCauseKinds = table.freeze({
		MissileImpact = true,
		ProjectileSplash = true,
	}),
	shotKeys = table.freeze({
		id = true,
		matchId = true,
		lifeSequence = true,
		weaponId = true,
		ownerUserId = true,
		revision = true,
		clientSequence = true,
		serverFrame = true,
		levelTimeMilliseconds = true,
		firedAtServerTime = true,
		eventSequence = true,
		seed = true,
		inputReceivedServerTime = true,
	}),
	causeCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[DirectDeathCause]: DirectDeathCauseCapability,
	},
	activePrepared = nil :: PreparedDirectDeath?,
	preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[PreparedDirectDeath]: DirectDeathPreparedCapability,
	},
	preparedBySummary = setmetatable({}, { __mode = "k" }) :: {
		[PreparedDirectDeathSummary]: PreparedDirectDeath,
	},
	receiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[DirectDeathApplyReceipt]: DirectDeathPreparedCapability,
	},
	handoffCapabilities = setmetatable({}, { __mode = "k" }) :: {
		[DirectDeathHandoff]: DirectDeathHandoffCapability,
	},
	handoffBySummary = setmetatable({}, { __mode = "k" }) :: {
		[DirectDeathHandoffSummary]: DirectDeathHandoff,
	},
	handoffByPlayer = {} :: { [Player]: DirectDeathHandoff },
}
local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function presentationTimeForLevel(levelTimeMilliseconds: number?): number?
	if levelTimeMilliseconds == nil then
		return nil
	end
	local frame = AuthoritativeFrameService.GetOpenFrame() or AuthoritativeFrameService.GetCurrentFrame()
	if not frame then
		return nil
	end
	local summary = AuthoritativeFrameService.InspectFrame(frame)
	if not summary then
		return nil
	end
	return MatchFrameRules.PresentationTimeForLevel(
		summary.currentTimeMilliseconds,
		summary.currentServerTimeSeconds,
		levelTimeMilliseconds
	)
end

local function orderedPlayersBySourceOrder(): { Player }
	local orderedPlayers = Players:GetPlayers()
	table.sort(orderedPlayers, function(left: Player, right: Player): boolean
		local leftSourceOrder = MovementService.GetPlayerSourceOrder(left)
		local rightSourceOrder = MovementService.GetPlayerSourceOrder(right)
		if leftSourceOrder ~= nil and rightSourceOrder ~= nil then
			if leftSourceOrder ~= rightSourceOrder then
				return leftSourceOrder < rightSourceOrder
			end
		elseif leftSourceOrder ~= nil then
			return true
		elseif rightSourceOrder ~= nil then
			return false
		end
		if left.UserId ~= right.UserId then
			return left.UserId < right.UserId
		end
		return left.Name < right.Name
	end)
	return orderedPlayers
end

local function saturatedAdd(current: number, amount: number): number
	return math.min(current + math.max(amount, 0), MAXIMUM_DEBUG_COUNTER)
end

local function hasExactKeys(value: unknown, allowed: { [string]: boolean }, count: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local observed = 0
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == count
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

local function ensureLeaderstats(player: Player): (IntValue, IntValue)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local score = leaderstats:FindFirstChild("Score") :: IntValue?
	if not score then
		score = Instance.new("IntValue")
		score.Name = "Score"
		score.Parent = leaderstats
	end

	local deaths = leaderstats:FindFirstChild("Deaths") :: IntValue?
	if not deaths then
		deaths = Instance.new("IntValue")
		deaths.Name = "Deaths"
		deaths.Parent = leaderstats
	end

	return score, deaths
end

local function broadcast(payload: { [string]: any })
	local remote = eventRemote
	if remote then
		local wire = CombatFramePublicationService.Snapshot(payload) :: { [string]: any }
		CombatFramePublicationService.Queue(function()
			remote:FireAllClients(wire)
		end)
	end
end

local function setPresentationInstance(instance: Instance, visible: boolean)
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		local visual: any = instance
		local original = visual:GetAttribute("ArenaOriginalTransparency")
		if type(original) ~= "number" then
			original = visual.Transparency
			visual:SetAttribute("ArenaOriginalTransparency", original)
		end
		visual.Transparency = if visible then original else 1
	elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") then
		local original = instance:GetAttribute("ArenaOriginalEnabled")
		if type(original) ~= "boolean" then
			original = instance.Enabled
			instance:SetAttribute("ArenaOriginalEnabled", original)
		end
		instance.Enabled = visible and original
	end
end

local function setCharacterCombatQuery(character: Model?, enabled: boolean)
	if not character then
		return
	end
	combatQueryEnabledByCharacter[character] = enabled

	local function applyToHitbox(): boolean
		if not character.Parent then
			return true
		end
		local hitbox = character:FindFirstChild("ArenaHitbox")
		if hitbox and hitbox:IsA("BasePart") then
			hitbox.CanQuery = combatQueryEnabledByCharacter[character] == true
			return true
		end
		return false
	end

	if not applyToHitbox() then
		task.defer(applyToHitbox)
	end

	-- CanQuery is authoritative and must change immediately so later entities in
	-- this frame see the death/spawn. Visibility is replication-only and remains
	-- behind the successful frame-close barrier.
	CombatFramePublicationService.Queue(function()
		character:SetAttribute("ArenaCombatQueryEnabled", enabled)
		character:SetAttribute("ArenaPresentationVisible", enabled)
		for _, descendant in character:GetDescendants() do
			setPresentationInstance(descendant, enabled)
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local originalNameDistance = humanoid:GetAttribute("ArenaOriginalNameDisplayDistance")
			if type(originalNameDistance) ~= "number" then
				originalNameDistance = humanoid.NameDisplayDistance
				humanoid:SetAttribute("ArenaOriginalNameDisplayDistance", originalNameDistance)
			end
			local originalHealthDistance = humanoid:GetAttribute("ArenaOriginalHealthDisplayDistance")
			if type(originalHealthDistance) ~= "number" then
				originalHealthDistance = humanoid.HealthDisplayDistance
				humanoid:SetAttribute("ArenaOriginalHealthDisplayDistance", originalHealthDistance)
			end
			humanoid.NameDisplayDistance = if enabled then originalNameDistance else 0
			humanoid.HealthDisplayDistance = if enabled then originalHealthDistance else 0
		end
	end)
end

local function syncHumanoidHealth(record: CombatRecord)
	local character = record.character
	if not record.alive or not character then
		return
	end

	local visibleMaximum = math.max(record.baseHealth, record.health, 1)
	local visibleHealth = math.clamp(record.health, 0, visibleMaximum)
	CombatFramePublicationService.Queue(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.MaxHealth = visibleMaximum
			humanoid.Health = visibleHealth
		end
	end)
end

local function weaponPhaseRemainingSeconds(record: CombatRecord): number
	return math.max(record.weaponTimeMilliseconds, 0) / 1000
end

local function weaponReadyRemainingSeconds(record: CombatRecord): number
	local remaining = weaponPhaseRemainingSeconds(record)
	if record.weaponState == "Dropping" then
		return remaining + WeaponDefinitions.WeaponRaiseMilliseconds / 1000
	end
	return remaining
end

local function publishPlayerRecord(player: Player, record: CombatRecord)
	local serverNow = Workspace:GetServerTimeNow()
	local transitionRemaining = if record.weaponState == "Dropping" or record.weaponState == "Raising"
		then weaponPhaseRemainingSeconds(record)
		else 0
	local transitionEndsAt = if transitionRemaining > 0 then serverNow + transitionRemaining else nil
	local weaponReadyAt = if record.weaponState ~= "Ready" then serverNow + weaponReadyRemainingSeconds(record) else nil
	local selectedAmmo = CombatInventoryRuntime.GetSelectedAmmo(record)
	local impressiveRewardEndsAt = presentationTimeForLevel(record.impressiveRewardUntilMilliseconds)
	local respawnEligibleAt = presentationTimeForLevel(record.respawnEligibleAtMilliseconds)
	local inventory = CombatInventoryRuntime.BuildSnapshot(record)
	table.freeze(inventory.ownedWeaponIds)
	local ammoByWeapon, ammoEntries = CombatInventoryRuntime.SerializeAmmo(inventory.ammoByWeapon)
	local powerupExpiries = table.freeze(table.clone(record.powerupExpiries))
	local powerupAttributes = {}
	for _, powerupId in PowerupRules.PowerupId do
		local expiry = powerupExpiries[powerupId] or 0
		table.insert(
			powerupAttributes,
			table.freeze({
				id = powerupId,
				active = expiry > 0,
				endsAt = presentationTimeForLevel(if expiry > 0 then expiry else nil),
			})
		)
	end
	table.freeze(powerupAttributes)
	local wire = table.freeze({
		health = record.health,
		armor = record.armor,
		alive = record.alive,
		weaponId = record.commandWeaponId,
		activeWeaponId = record.weaponId,
		weaponState = record.weaponState,
		weaponTimeMilliseconds = record.weaponTimeMilliseconds,
		railJumpReadyAtMilliseconds = record.railJumpReadyAtMilliseconds,
		weaponTransitionAt = transitionEndsAt,
		weaponReadyAt = weaponReadyAt,
		ammo = selectedAmmo,
		infiniteAmmo = record.infiniteAmmo,
		holdableId = record.holdableId,
		holdableUseHeld = record.holdableUseHeld,
		powerupExpiries = powerupExpiries,
		powerupAttributes = powerupAttributes,
		ownedWeaponIds = inventory.ownedWeaponIds,
		ammoByWeapon = ammoByWeapon,
		ammoEntries = ammoEntries,
		score = record.score,
		deaths = record.deaths,
		shotsFired = record.shotsFired,
		accuracyShots = record.accuracyShots,
		accuracyHits = record.accuracyHits,
		accuracyMatchId = record.accuracyMatchId,
		railAccurateCount = record.railAccurateCount,
		impressiveCount = record.impressiveCount,
		impressiveRewardEndsAt = impressiveRewardEndsAt,
		noAmmoEvents = record.noAmmoEvents,
		lastWeaponCommandSequence = record.lastWeaponCommandSequence,
		lifeSequence = record.lifeSequence,
		lastShotId = record.lastShotId,
		respawnEligibleAt = respawnEligibleAt,
	})
	CombatFramePublicationService.Queue(function()
		player:SetAttribute("ArenaHealth", wire.health)
		player:SetAttribute("ArenaArmor", wire.armor)
		player:SetAttribute("ArenaAlive", wire.alive)
		player:SetAttribute("ArenaWeaponId", wire.weaponId)
		player:SetAttribute("ArenaActiveWeaponId", wire.activeWeaponId)
		player:SetAttribute("ArenaWeaponState", wire.weaponState)
		player:SetAttribute("ArenaRailJumpReadyAtMilliseconds", wire.railJumpReadyAtMilliseconds)
		player:SetAttribute("ArenaWeaponTransitionEndsAt", wire.weaponTransitionAt)
		player:SetAttribute("ArenaWeaponReadyAt", wire.weaponReadyAt)
		player:SetAttribute("ArenaAmmo", wire.ammo)
		player:SetAttribute("ArenaInfiniteAmmo", wire.infiniteAmmo)
		player:SetAttribute("ArenaHoldableId", wire.holdableId)
		player:SetAttribute("ArenaHoldableUseHeld", wire.holdableUseHeld)
		for _, powerup in wire.powerupAttributes do
			player:SetAttribute(string.format("ArenaPowerup%dActive", powerup.id), powerup.active)
			player:SetAttribute(string.format("ArenaPowerup%dEndsAt", powerup.id), powerup.endsAt)
		end
		player:SetAttribute("ArenaScore", wire.score)
		player:SetAttribute("ArenaDeaths", wire.deaths)
		player:SetAttribute("ArenaShotsFired", wire.shotsFired)
		player:SetAttribute("ArenaAccuracyShots", wire.accuracyShots)
		player:SetAttribute("ArenaAccuracyHits", wire.accuracyHits)
		player:SetAttribute("ArenaAccuracyMatchId", wire.accuracyMatchId)
		player:SetAttribute("ArenaRailAccurateCount", wire.railAccurateCount)
		player:SetAttribute("ArenaImpressiveCount", wire.impressiveCount)
		player:SetAttribute("ArenaImpressiveActive", wire.impressiveRewardEndsAt ~= nil)
		player:SetAttribute("ArenaImpressiveRewardEndsAt", wire.impressiveRewardEndsAt)
		player:SetAttribute("ArenaNoAmmoEvents", wire.noAmmoEvents)
		player:SetAttribute("ArenaLastWeaponCommandSequence", wire.lastWeaponCommandSequence)
		player:SetAttribute("ArenaLifeSequence", wire.lifeSequence)
		player:SetAttribute("ArenaLastShotId", wire.lastShotId)
		player:SetAttribute("ArenaRespawnEligibleAt", wire.respawnEligibleAt)
		local scoreValue, deathsValue = ensureLeaderstats(player)
		scoreValue.Value = wire.score
		deathsValue.Value = wire.deaths
		local remote = snapshotRemote
		if remote then
			remote:FireClient(player, {
				health = wire.health,
				armor = wire.armor,
				alive = wire.alive,
				weaponId = wire.weaponId,
				activeWeaponId = wire.activeWeaponId,
				weaponState = wire.weaponState,
				weaponTimeMilliseconds = wire.weaponTimeMilliseconds,
				railJumpReadyAtMilliseconds = wire.railJumpReadyAtMilliseconds,
				weaponTransitionAt = wire.weaponTransitionAt,
				weaponTransitionEndsAt = wire.weaponTransitionAt,
				weaponReadyAt = wire.weaponReadyAt,
				ammo = wire.ammo,
				infiniteAmmo = wire.infiniteAmmo,
				holdableId = wire.holdableId,
				holdableUseHeld = wire.holdableUseHeld,
				powerupExpiries = wire.powerupExpiries,
				ownedWeaponIds = wire.ownedWeaponIds,
				ammoByWeapon = wire.ammoByWeapon,
				ammoEntries = wire.ammoEntries,
				score = wire.score,
				deaths = wire.deaths,
				shotsFired = wire.shotsFired,
				accuracyShots = wire.accuracyShots,
				accuracyHits = wire.accuracyHits,
				accuracyMatchId = wire.accuracyMatchId,
				railAccurateCount = wire.railAccurateCount,
				impressiveCount = wire.impressiveCount,
				impressiveRewardEndsAt = wire.impressiveRewardEndsAt,
				noAmmoEvents = wire.noAmmoEvents,
				acknowledgedWeaponCommandSequence = wire.lastWeaponCommandSequence,
				lifeSequence = wire.lifeSequence,
				lastShotId = wire.lastShotId,
				respawnEligibleAt = wire.respawnEligibleAt,
			})
		end
	end)
end

local function syncPlayer(player: Player)
	local record = records[player]
	if not record then
		return
	end
	record.score = MatchService.GetPlayerScore(player)
	record.deaths = MatchService.GetPlayerDeaths(player)
	publishPlayerRecord(player, record)
end

local function resetAccuracyForMatchIdentity(matchId: unknown)
	if type(matchId) ~= "string" or matchId == "" then
		return
	end
	for _, record in records do
		if record.accuracyMatchId ~= matchId then
			record.accuracyMatchId = matchId
			record.accuracyShots = 0
			record.accuracyHits = 0
			record.railAccurateCount = 0
			record.impressiveCount = 0
			record.impressiveRewardUntilMilliseconds = nil
		end
	end
end

local function resolveAccuracyShot(
	player: Player,
	shot: ShotContext,
	directContacts: { AccuracyContact },
	radiusContacts: { AccuracyContact }
): AccuracyShotResult
	local family = assert(ACCURACY_FAMILY_BY_WEAPON_ID[shot.weaponId], "accepted weapon has no accuracy family")
	local result, resolveError = AccuracyRules.ResolveShot({
		family = family,
		directContacts = directContacts,
		radiusContacts = radiusContacts,
	})
	assert(result, resolveError or "accuracy shot could not be resolved")
	local record = records[player]
	if record and record.accuracyMatchId == shot.matchId then
		record.accuracyHits = saturatedAdd(record.accuracyHits, result.accuracyHitsDelta)
	end
	return result
end

local function recordAcceptedAccuracyShot(record: CombatRecord, shot: ShotContext)
	local family = assert(ACCURACY_FAMILY_BY_WEAPON_ID[shot.weaponId], "accepted weapon has no accuracy family")
	local result, resolveError = AccuracyRules.ResolveShot({
		family = family,
		directContacts = {},
		radiusContacts = {},
	})
	assert(result, resolveError or "accepted accuracy shot could not be resolved")
	if record.accuracyMatchId == shot.matchId then
		record.accuracyShots = saturatedAdd(record.accuracyShots, result.accuracyShotsDelta)
	end
end

local function appendLiveFilter(filters: { Instance }, instance: Instance?)
	if instance and instance.Parent then
		table.insert(filters, instance)
	end
end

local function excludeParameters(filters: { Instance }): RaycastParams
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = filters
	parameters.IgnoreWater = true
	return parameters
end

type PlayerCombatTarget = {
	read kind: "LivePlayer" | "ClientCorpse",
	read player: Player,
	read body: MoverPushRules.Body,
}
type BodyQueueCombatTarget = {
	read kind: "BodyQueueCorpse",
	read queueIndex: number,
	read occupantGeneration: number,
	read retainedHealth: number,
	read takedamage: boolean,
	read body: MoverPushRules.Body,
}
type CombatTarget = PlayerCombatTarget | BodyQueueCombatTarget

type CombatTraceResult = {
	read position: Vector3,
	read normal: Vector3,
	read distance: number,
	read startSolid: boolean,
	read allSolid: boolean,
	read worldInstance: Instance?,
	read target: CombatTarget?,
}

local function collectCombatShotTargets(): ({ MoverPushRules.Body }, { [string]: CombatTarget })
	local orderedPlayers = Players:GetPlayers()
	local bodies: { MoverPushRules.Body } = table.create(#orderedPlayers)
	local targetsByBodyId: { [string]: CombatTarget } = {}
	for _, player in orderedPlayers do
		local record = records[player]
		local body = if record and record.alive then MovementService.GetPlayerMoverBody(player) else nil
		if body then
			assert(targetsByBodyId[body.id] == nil, "duplicate live shot body identity")
			table.insert(bodies, body)
			local target: CombatTarget = {
				kind = "LivePlayer",
				player = player,
				body = body,
			}
			table.freeze(target)
			targetsByBodyId[body.id] = target
		end
	end
	local corpseCollection = CorpseService.GetCommittedCollection()
	for _, body in corpseCollection.bodies do
		local player = corpseCollection.playersByBodyId[body.id]
		assert(player ~= nil, "committed corpse shot body lost its player binding")
		assert(targetsByBodyId[body.id] == nil, "live and corpse shot bodies overlapped")
		table.insert(bodies, body)
		local target: CombatTarget = {
			kind = "ClientCorpse",
			player = player,
			body = body,
		}
		table.freeze(target)
		targetsByBodyId[body.id] = target
	end
	for _, bodyQueueTarget in directDeathOwner.bodyQueueService.CollectCombatTargets() do
		local body = bodyQueueTarget.body
		assert(targetsByBodyId[body.id] == nil, "body-queue shot body identity overlapped")
		table.insert(bodies, body)
		local target: BodyQueueCombatTarget = {
			kind = "BodyQueueCorpse",
			queueIndex = bodyQueueTarget.queueIndex,
			occupantGeneration = bodyQueueTarget.occupantGeneration,
			retainedHealth = bodyQueueTarget.retainedHealth,
			takedamage = bodyQueueTarget.takedamage,
			body = body,
		}
		table.freeze(target)
		targetsByBodyId[body.id] = target
	end
	local orderedBodies, bodyError = MoverPushRules.ValidateAndOrderBodies(bodies)
	assert(orderedBodies, bodyError or "combat shot bodies were invalid")
	table.freeze(targetsByBodyId)
	return orderedBodies, targetsByBodyId
end

local function appendAllCharacterFilters(filters: { Instance })
	for _, player in Players:GetPlayers() do
		appendLiveFilter(filters, MovementService.GetCharacter(player))
	end
end

local traceMoverSolids: (Vector3, Vector3) -> CombatShotTraceRules.Result

local function mergeCombatEntityTraces(
	left: CombatShotTraceRules.Result,
	right: CombatShotTraceRules.Result
): CombatShotTraceRules.Result
	local selected = left
	if left.allSolid ~= right.allSolid then
		selected = if right.allSolid then right else left
	elseif left.allSolid and right.allSolid then
		local leftContact = assert(left.contact, "all-solid left trace lost its contact")
		local rightContact = assert(right.contact, "all-solid right trace lost its contact")
		selected = if rightContact.sourceOrder < leftContact.sourceOrder then right else left
	elseif right.hit then
		if not left.hit or right.fraction < left.fraction then
			selected = right
		elseif right.fraction == left.fraction then
			local leftContact = assert(left.contact, "left hit trace lost its contact")
			local rightContact = assert(right.contact, "right hit trace lost its contact")
			if rightContact.sourceOrder < leftContact.sourceOrder then
				selected = right
			end
		end
	end

	local result: CombatShotTraceRules.Result = {
		hit = selected.hit,
		fraction = selected.fraction,
		distance = selected.distance,
		position = selected.position,
		normal = selected.normal,
		startSolid = left.startSolid or right.startSolid,
		allSolid = selected.allSolid,
		contact = selected.contact,
	}
	table.freeze(result)
	return result
end

local function traceCombatShot(
	origin: Vector3,
	displacement: Vector3,
	ignoredBodyIds: CombatShotTraceRules.IgnoredBodyIds?
): (CombatTraceResult?, boolean)
	local exclusions: { Instance } = {}
	appendLiveFilter(exclusions, projectileFolder)
	appendAllCharacterFilters(exclusions)
	local worldResult = if displacement.Magnitude > 0
		then Workspace:Raycast(origin, displacement, excludeParameters(exclusions))
		else nil
	local bodies, targetsByBodyId = collectCombatShotTargets()
	local dynamicResult, dynamicError =
		CombatShotTraceRules.Trace(bodies, origin, displacement, MoverPushRules.Masks.Shot, ignoredBodyIds)
	assert(dynamicResult, dynamicError or "combat dynamic shot trace failed")
	dynamicResult = mergeCombatEntityTraces(dynamicResult, traceMoverSolids(origin, displacement))
	if dynamicResult.hit and (not worldResult or dynamicResult.distance < worldResult.Distance) then
		local contact = assert(dynamicResult.contact, "dynamic shot result lost its contact")
		-- Solid movers intentionally have no CombatTarget: they terminate hitscan
		-- and projectiles (or bounce grenades) without becoming damage recipients.
		local target = targetsByBodyId[contact.bodyId]
		local result: CombatTraceResult = {
			position = dynamicResult.position,
			normal = dynamicResult.normal,
			distance = dynamicResult.distance,
			startSolid = dynamicResult.startSolid,
			allSolid = dynamicResult.allSolid,
			worldInstance = nil,
			target = target,
		}
		table.freeze(result)
		return result, dynamicResult.startSolid
	end
	if worldResult then
		local result: CombatTraceResult = {
			position = worldResult.Position,
			normal = worldResult.Normal,
			distance = worldResult.Distance,
			-- SV_ClipMoveToEntities ORs an exiting entity's startsolid bit
			-- into the world-first result. A fraction-zero world collision returns
			-- before entity clipping, so only a positive-distance world hit carries it.
			startSolid = worldResult.Distance > 0 and dynamicResult.startSolid,
			allSolid = false,
			worldInstance = worldResult.Instance,
			target = nil,
		}
		table.freeze(result)
		return result, result.startSolid
	end
	return nil, dynamicResult.startSolid
end

traceMoverSolids = function(origin: Vector3, displacement: Vector3): CombatShotTraceRules.Result
	local moverResult = MovementService.TraceMoverPoint(origin, displacement, MoverPushRules.Masks.Solid)
	local distance = displacement.Magnitude * moverResult.fraction
	local contact = if moverResult.moverId
		then table.freeze({
			bodyId = moverResult.moverId,
			sourceOrder = assert(moverResult.sourceOrder, "mover point contact lost its source order"),
			contents = moverResult.contents,
		})
		else nil
	local result: CombatShotTraceRules.Result = {
		hit = moverResult.hit,
		fraction = moverResult.fraction,
		distance = distance,
		position = origin + displacement * moverResult.fraction,
		normal = moverResult.normal,
		startSolid = moverResult.startSolid,
		allSolid = moverResult.allSolid,
		contact = contact,
	}
	table.freeze(result)
	return result
end

local function traceRailJumpSurface(origin: Vector3, direction: Vector3): Vector3?
	local range =
		assert(OneShotRules.RailJumpRangeStuds(Constants.UnitsToStuds), "One-Shot rail-jump range must be valid")
	local displacement = direction.Unit * range
	local exclusions: { Instance } = {}
	appendLiveFilter(exclusions, projectileFolder)
	-- Rail-jump is self movement only. Player bodies neither receive an effect nor
	-- hide the nearby static/mover surface the player is aiming at.
	appendAllCharacterFilters(exclusions)
	local worldResult = Workspace:Raycast(origin, displacement, excludeParameters(exclusions))
	local moverResult = traceMoverSolids(origin, displacement)
	if
		moverResult.hit
		and not moverResult.startSolid
		and not moverResult.allSolid
		and (not worldResult or moverResult.distance < worldResult.Distance)
	then
		return moverResult.position
	end
	if worldResult then
		return worldResult.Position
	end
	return nil
end

local function recordAuthoritativeHistorySample(player: Player, state: any, revision: number, serverTime: number)
	local record = records[player]
	local character = record and record.character
	local matchId = MatchService.GetMatchId()
	if
		not record
		or not record.alive
		or not character
		or character ~= MovementService.GetCharacter(player)
		or not character.Parent
		or type(matchId) ~= "string"
		or matchId == ""
		or record.lifeSequence < 1
	then
		CombatHitscanRewindRuntime.ClearPlayer(player)
		return
	end

	local buffer = CombatHitscanRewindRuntime.GetOrCreateBuffer(player)
	local inserted, disposition = HitscanRewindRules.Insert(buffer, {
		userId = player.UserId,
		matchId = matchId,
		character = character,
		lifeSequence = record.lifeSequence,
		revision = revision,
		serverTime = serverTime,
		frame = state.frame,
		center = state.position + Constants.ColliderCenterOffsetFor(state.crouched),
		size = Constants.ColliderSizeFor(state.crouched),
		teleported = false,
	})
	if not inserted or disposition ~= HitscanRewindRules.InsertDisposition.Inserted then
		CombatHitscanRewindRuntime.RecordInsertionDisposition(disposition)
	end
end

local function rewindIdentityForPlayer(player: Player, matchId: string): HitscanRewindRules.Identity?
	local record = records[player]
	local character = record and record.character
	local revision = MovementService.GetRevision(player)
	if
		not record
		or not record.alive
		or not MatchService.CanPlayerFight(player)
		or not character
		or character ~= MovementService.GetCharacter(player)
		or not character.Parent
		or revision == nil
		or record.lifeSequence < 1
		or MatchService.GetMatchId() ~= matchId
	then
		return nil
	end
	return {
		userId = player.UserId,
		matchId = matchId,
		character = character,
		lifeSequence = record.lifeSequence,
		revision = revision,
	}
end

local function staticWorldCutoffDistance(origin: Vector3, direction: Vector3, range: number): number
	-- Match the live hitscan query's Workspace/CanQuery semantics while removing
	-- every current player hull. This retains Terrain and queryable blockers
	-- outside the authored arena folder and prevents a current body pose from
	-- masquerading as static cover for a historical hull.
	local exclusions: { Instance } = {}
	appendLiveFilter(exclusions, projectileFolder)
	for _, player in Players:GetPlayers() do
		appendLiveFilter(exclusions, MovementService.GetCharacter(player))
	end
	local displacement = direction.Unit * range
	local result = Workspace:Raycast(origin, displacement, excludeParameters(exclusions))
	local cutoff = if result then (result.Position - origin).Magnitude else range
	local moverResult = traceMoverSolids(origin, displacement)
	-- SV_Trace retains the static world on an exact fraction tie.
	if moverResult.hit and moverResult.distance < cutoff then
		return moverResult.distance
	end
	return cutoff
end

type HistoricalCandidate = {
	userId: number,
	distance: number,
}

local function historicalTargetsForTrace(
	shooter: Player,
	matchId: string,
	targetServerTime: number,
	origin: Vector3,
	direction: Vector3,
	range: number,
	maximumTargets: number
): ({ number }, { number })
	local candidates: { HistoricalCandidate } = {}
	local occludedUserIds: { number } = {}
	local worldCutoff = staticWorldCutoffDistance(origin, direction, range)
	local orderedPlayers = Players:GetPlayers()
	table.sort(orderedPlayers, function(left: Player, right: Player): boolean
		if left.UserId == right.UserId then
			return left.Name < right.Name
		end
		return left.UserId < right.UserId
	end)

	for _, target in orderedPlayers do
		if target == shooter then
			continue
		end
		local targetRecord = records[target]
		if not targetRecord or not targetRecord.alive or not MatchService.CanPlayerFight(target) then
			CombatHitscanRewindRuntime.Increment("ineligibleTargetSkipCount")
			continue
		end
		local identity = rewindIdentityForPlayer(target, matchId)
		local buffer = CombatHitscanRewindRuntime.GetBuffer(target)
		if not identity or not buffer then
			CombatHitscanRewindRuntime.Increment("historyMissingTargetCount")
			continue
		end

		local sample, disposition = HitscanRewindRules.ResolveAt(buffer, identity, targetServerTime)
		local resolveDispositions = HitscanRewindRules.ResolveDisposition
		if disposition == resolveDispositions.IdentityMismatch then
			CombatHitscanRewindRuntime.Increment("historyIdentityMismatchCount")
		elseif disposition == resolveDispositions.UnavailableBeforeSegment then
			CombatHitscanRewindRuntime.Increment("historyBeforeSegmentCount")
		elseif disposition == resolveDispositions.ClampedOldest then
			CombatHitscanRewindRuntime.Increment("historyClampedOldestCount")
		elseif disposition == resolveDispositions.ClampedLatest then
			CombatHitscanRewindRuntime.Increment("historyClampedLatestCount")
		elseif not sample then
			CombatHitscanRewindRuntime.Increment("historyMissingTargetCount")
		end
		if not sample then
			continue
		end

		local distance = HitscanRewindRules.RayAabbDistance(origin, direction, range, sample.center, sample.size)
		if distance == nil then
			continue
		end
		if distance + Constants.CollisionSkin >= worldCutoff then
			table.insert(occludedUserIds, target.UserId)
			CombatHitscanRewindRuntime.Increment("historicalOccludedTargetCount")
			continue
		end
		table.insert(candidates, {
			userId = target.UserId,
			distance = distance,
		})
	end

	table.sort(candidates, function(left: HistoricalCandidate, right: HistoricalCandidate): boolean
		if math.abs(left.distance - right.distance) <= 1e-6 then
			return left.userId < right.userId
		end
		return left.distance < right.distance
	end)
	local userIds: { number } = {}
	for index = 1, math.min(#candidates, maximumTargets) do
		table.insert(userIds, candidates[index].userId)
	end
	return userIds, occludedUserIds
end

local function copyUserIds(source: { number }): { number }
	local result = table.clone(source)
	return table.freeze(result)
end

local function sameUserIdSet(left: { number }, right: { number }): boolean
	if #left ~= #right then
		return false
	end
	local present: { [number]: boolean } = {}
	for _, userId in left do
		present[userId] = true
	end
	for _, userId in right do
		if not present[userId] then
			return false
		end
	end
	return true
end

local function classifyShadowTrace(currentUserIds: { number }, historicalUserIds: { number }): string
	if #currentUserIds == 0 and #historicalUserIds == 0 then
		return "AgreeMiss"
	end
	if sameUserIdSet(currentUserIds, historicalUserIds) then
		return "AgreeHitSet"
	end
	if #currentUserIds > 0 and #historicalUserIds == 0 then
		return "CurrentOnly"
	end
	if #currentUserIds == 0 and #historicalUserIds > 0 then
		return "HistoricalOnly"
	end
	return "DifferentTargetSet"
end

local function safeRoundTripSeconds(player: Player): number
	local success, value = pcall(function(): number
		return player:GetNetworkPing()
	end)
	return if success and isFinite(value) and value >= 0 then value else 0
end

local function recordHitscanRewindShadow(
	player: Player,
	shot: ShotContext,
	origin: Vector3,
	direction: Vector3,
	range: number,
	maximumTargets: number,
	currentUserIds: { number }
)
	if SHADOW_REWIND_WEAPONS[shot.weaponId] ~= true then
		return
	end
	local inputReceivedServerTime = shot.inputReceivedServerTime
	if inputReceivedServerTime == nil or shot.matchId == nil then
		return
	end

	local serverNow = Workspace:GetServerTimeNow()
	if
		not CombatHitscanRewindRuntime.ShouldMeasure(
			player,
			shot.weaponId == WeaponDefinitions.WeaponId.LightningGun,
			serverNow,
			#Players:GetPlayers()
		)
	then
		return
	end
	local targetTime =
		HitscanRewindRules.ComputeTargetTime(inputReceivedServerTime, serverNow, safeRoundTripSeconds(player))
	local historicalUserIds: { number } = {}
	local occludedUserIds: { number } = {}
	local classification = "HistoryUnavailable"
	if targetTime then
		CombatHitscanRewindRuntime.RecordTargetTime(targetTime.rewindSeconds, targetTime.clamped)
		historicalUserIds, occludedUserIds = historicalTargetsForTrace(
			player,
			shot.matchId,
			targetTime.serverTime,
			origin,
			direction,
			range,
			maximumTargets
		)
		classification = classifyShadowTrace(currentUserIds, historicalUserIds)
		CombatHitscanRewindRuntime.IncrementClassification(classification)
	else
		CombatHitscanRewindRuntime.Increment("targetTimeRejectCount")
	end

	CombatHitscanRewindRuntime.AppendObservation({
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		inputReceivedServerTime = inputReceivedServerTime,
		targetServerTime = if targetTime then targetTime.serverTime else nil,
		rewindSeconds = if targetTime then targetTime.rewindSeconds else nil,
		targetTimeClamped = if targetTime then targetTime.clamped else false,
		currentUserIds = copyUserIds(currentUserIds),
		historicalUserIds = copyUserIds(historicalUserIds),
		occludedUserIds = copyUserIds(occludedUserIds),
		classification = classification,
		damageEnabled = CombatHitscanRewindRuntime.DamageEnabled,
	})
end

local function nextEventId(shot: ShotContext): string
	shot.eventSequence += 1
	return WeaponDefinitions.MakeEventId(shot.id, shot.eventSequence)
end

local function reserveShotContext(
	player: Player,
	record: CombatRecord,
	weaponId: number,
	inputSequence: number,
	inputReceivedServerTime: number,
	serverFrame: number,
	revision: number,
	levelTimeMilliseconds: number,
	firedAtServerTime: number
): ShotContext
	record.serverShotSequence += 1
	local lifeSequence = record.lifeSequence
	record.lastShotId = WeaponDefinitions.MakeShotId(player.UserId, lifeSequence, record.serverShotSequence)
	return {
		id = record.lastShotId,
		matchId = MatchService.GetSnapshot().matchId,
		lifeSequence = lifeSequence,
		weaponId = weaponId,
		ownerUserId = player.UserId,
		revision = revision,
		clientSequence = inputSequence,
		serverFrame = serverFrame,
		levelTimeMilliseconds = levelTimeMilliseconds,
		firedAtServerTime = firedAtServerTime,
		eventSequence = 0,
		seed = WeaponDefinitions.MakeShotSeed(player.UserId, lifeSequence, record.serverShotSequence),
		inputReceivedServerTime = inputReceivedServerTime,
	}
end

local function emitNoAmmo(
	player: Player,
	record: CombatRecord,
	weaponId: number,
	clientSequence: number,
	serverFrame: number
)
	record.noAmmoEvents += 1
	local remote = eventRemote
	if not remote then
		return
	end
	local payload = table.freeze({
		kind = "NoAmmo",
		eventId = string.format("noammo:%d:%d:%d", player.UserId, record.lifeSequence, record.noAmmoEvents),
		ownerUserId = player.UserId,
		weaponId = weaponId,
		clientSequence = clientSequence,
		serverFrame = serverFrame,
		weaponReadyAt = Workspace:GetServerTimeNow() + weaponReadyRemainingSeconds(record),
	})
	CombatFramePublicationService.Queue(function()
		remote:FireClient(player, payload)
	end)
end

local function makeEnvironmentContext(target: Player, record: CombatRecord, levelTimeMilliseconds: number?): ShotContext
	local resolvedLevelTimeMilliseconds = levelTimeMilliseconds
	if resolvedLevelTimeMilliseconds == nil then
		local frame = AuthoritativeFrameService.GetOpenFrame()
		local summary = if frame then AuthoritativeFrameService.InspectFrame(frame) else nil
		resolvedLevelTimeMilliseconds = if summary then summary.currentTimeMilliseconds else nil
	end
	local state = MovementService.GetState(target)
	return {
		id = string.format("environment:%d:%d", target.UserId, record.lifeSequence),
		matchId = MatchService.GetMatchId(),
		lifeSequence = record.lifeSequence,
		weaponId = WeaponDefinitions.WeaponId.None,
		ownerUserId = 0,
		revision = MovementService.GetRevision(target) or 0,
		clientSequence = 0,
		serverFrame = if state then state.frame else 0,
		levelTimeMilliseconds = resolvedLevelTimeMilliseconds,
		firedAtServerTime = presentationTimeForLevel(resolvedLevelTimeMilliseconds),
		eventSequence = 0,
		seed = 0,
		inputReceivedServerTime = nil,
	}
end

local function applyKnockback(target: Player, direction: Vector3, damage: number)
	if direction.Magnitude <= 1e-6 then
		return
	end

	local knockbackDamage = math.min(damage, 200)
	local q3Velocity = WeaponDefinitions.Knockback * knockbackDamage / WeaponDefinitions.PlayerMass
	local velocityDelta = direction.Unit * q3Velocity * Constants.UnitsToStuds
	MovementService.ApplyVelocity(target, velocityDelta, WeaponDefinitions.KnockbackDurationSeconds(knockbackDamage))
end

local function buildDeathWeaponDrop(
	target: Player,
	record: CombatRecord,
	means: string,
	preparedWeaponId: number?,
	preparedCommandWeaponId: number?,
	preparedWeaponState: WeaponState?,
	preparedEntityTrajectoryBase: Vector3?,
	preparedEntityAngularLook: Vector3?
): (
	DeathWeaponDropRequest?,
	DirectDeathWeaponDropOmissionReason? | "MissingAuthoritativeSource"
)
	if means == "Void" then
		return nil, "Void"
	elseif record.lastDroppedLifeSequence == record.lifeSequence then
		return nil, "AlreadyDropped"
	elseif not MatchService.GetRules().DeathWeaponDrops then
		return nil, "DisabledByRules"
	end
	local matchState = MatchService.GetState()
	if matchState ~= "Warmup" and matchState ~= "Live" then
		return nil, "IneligibleMatchState"
	end

	local weaponId = preparedWeaponId or record.weaponId
	-- Exact TossClientItems exception: an MG that has genuinely begun lowering
	-- drops the latest requested weapon. A queued change while MG is still firing
	-- does not qualify.
	local weaponState = preparedWeaponState or record.weaponState
	if weaponId == WeaponDefinitions.WeaponId.Machinegun and weaponState == "Dropping" then
		weaponId = preparedCommandWeaponId or record.commandWeaponId
	end
	local candidate = DroppedWeaponRules.ResolveCandidate(
		weaponId,
		record.ownedWeapons[weaponId] == true,
		record.ammoByWeapon[weaponId] or 0,
		record.infiniteAmmo,
		true
	)
	if not candidate then
		return nil, "IneligibleWeapon"
	end

	local movementState = if preparedEntityTrajectoryBase == nil or preparedEntityAngularLook == nil
		then MovementService.GetState(target)
		else nil
	local dropPosition = preparedEntityTrajectoryBase or (if movementState then movementState.position else nil)
	local dropLook = preparedEntityAngularLook or (if movementState then movementState.look else nil)
	local snapshot = MatchService.GetSnapshot()
	local matchId = snapshot.matchId
	if not dropPosition or not dropLook or type(matchId) ~= "string" or matchId == "" then
		return nil, "MissingAuthoritativeSource"
	end
	local seed = DroppedWeaponRules.MakeSeed(matchId, target.UserId, record.lifeSequence)
	local velocity = DroppedWeaponRules.LaunchVelocity(dropLook, seed)
	return {
		dropId = DroppedWeaponRules.MakeDropId(matchId, target.UserId, record.lifeSequence),
		matchId = matchId,
		itemId = candidate.itemId,
		quantity = candidate.quantity,
		position = dropPosition,
		velocity = velocity,
	},
		nil
end

local function publishPreparedDeathWeaponDrop(request: DeathWeaponDropRequest?)
	local handler = deathWeaponDropHandler
	if not request or not handler then
		return
	end
	local snapshot = MatchService.GetSnapshot()
	if (snapshot.state ~= "Warmup" and snapshot.state ~= "Live") or snapshot.matchId ~= request.matchId then
		return
	end
	local ok, accepted = pcall(handler, request)
	if not ok then
		warn(string.format("Prepared death weapon drop handler failed: %s", tostring(accepted)))
	end
end

local function stageSynchronousMoverDeathWeaponDrop(
	request: DeathWeaponDropRequest,
	operationOrder: number
): (MoverPushRules.Body?, string?)
	local adapter = directDeathOwner.deathDropInsertionAdapter
	if not adapter then
		return nil, "synchronous-mover-death-drop-adapter-unavailable"
	end
	return adapter.StageSynchronousMover(request, operationOrder)
end

local function stageSynchronousMoverPowerupDrops(
	player: Player,
	record: CombatRecord,
	position: Vector3,
	levelTimeMilliseconds: number,
	operationOrder: number
): ({ MoverPushRules.Body }?, string?)
	local adapter = directDeathOwner.deathDropInsertionAdapter
	if not adapter then
		return nil, "synchronous-mover-powerup-drop-adapter-unavailable"
	end
	local drops = PowerupRules.ResolveDeathDrops(
		record.powerupExpiries,
		levelTimeMilliseconds,
		MatchService.GetRules().ModeKind == "TeamDeathmatch"
	)
	if not drops then
		return nil, "synchronous-mover-powerup-drop-state-invalid"
	end
	if RunService:IsStudio() then
		local stage = string.format("Resolved:%d", #drops)
		CombatFramePublicationService.Queue(function()
			player:SetAttribute("ArenaStudioMoverPowerupStage", stage)
		end)
	end
	local movementState = MovementService.GetState(player)
	local baseLook = if movementState then movementState.look else Vector3.zAxis
	local horizontal = Vector3.new(baseLook.X, 0, baseLook.Z)
	if horizontal.Magnitude <= 1e-6 then
		horizontal = Vector3.zAxis
	else
		horizontal = horizontal.Unit
	end
	local matchId = MatchService.GetSnapshot().matchId
	local bodies: { MoverPushRules.Body } = {}
	for _, drop in drops do
		local itemId =
			assert(PowerupRules.ItemIdByPowerupId[drop.powerupId], "powerup death drop lost its item definition")
		local yaw = math.rad(drop.yawOffsetDegrees)
		local look = Vector3.new(
			horizontal.X * math.cos(yaw) - horizontal.Z * math.sin(yaw),
			0,
			horizontal.X * math.sin(yaw) + horizontal.Z * math.cos(yaw)
		)
		local seed = DroppedWeaponRules.MakeSeed(
			string.format("%s:powerup:%d", matchId, drop.powerupId),
			player.UserId,
			record.lifeSequence
		)
		local velocity = DroppedWeaponRules.LaunchVelocity(look, seed)
		local body, stageError = adapter.StageSynchronousMover({
			dropId = string.format("powerup:%s:%d:%d:%d", matchId, player.UserId, record.lifeSequence, drop.powerupId),
			matchId = matchId,
			itemId = itemId,
			quantity = drop.remainingSeconds,
			position = position,
			velocity = velocity,
		}, operationOrder)
		if not body then
			if RunService:IsStudio() then
				local stage = stageError or "StageFailed"
				CombatFramePublicationService.Queue(function()
					player:SetAttribute("ArenaStudioMoverPowerupStage", stage)
				end)
			end
			return nil, stageError or "synchronous-mover-powerup-drop-stage-failed"
		end
		table.insert(bodies, body)
	end
	table.freeze(bodies)
	if RunService:IsStudio() then
		local stage = string.format("Staged:%d", #bodies)
		CombatFramePublicationService.Queue(function()
			player:SetAttribute("ArenaStudioMoverPowerupStage", stage)
		end)
	end
	return bodies, nil
end

local function stageSynchronousMoverFlagDrops(
	player: Player,
	position: Vector3,
	operationOrder: number
): ({ MoverPushRules.Body }?, string?)
	local handler = synchronousMoverFlagDropHandler
	if not handler then
		return table.freeze({}), nil
	end
	return handler(player, position, operationOrder)
end

local function createEliminationOrbNow(position: Vector3, plan: EliminationPresentationRules.OrbPlan)
	local folder = projectileFolder
	if not folder or not folder.Parent then
		return
	end

	local orb = Instance.new("Part")
	orb.Name = "EnergyElimination"
	orb.Shape = plan.shape
	orb.Anchored = plan.anchored
	orb.CanCollide = plan.canCollide
	orb.CanTouch = plan.canTouch
	orb.CanQuery = plan.canQuery
	orb.CastShadow = plan.castShadow
	orb.Material = plan.material
	orb.Color = plan.color
	orb.Transparency = plan.startTransparency
	orb.Size = Vector3.new(plan.startDiameterStuds, plan.startDiameterStuds, plan.startDiameterStuds)
	orb.Position = position
	orb.Parent = folder
	TweenService:Create(orb, TweenInfo.new(plan.durationSeconds, plan.easingStyle, plan.easingDirection), {
		Size = Vector3.new(plan.endDiameterStuds, plan.endDiameterStuds, plan.endDiameterStuds),
		Transparency = plan.endTransparency,
	}):Play()
	Debris:AddItem(orb, plan.durationSeconds + plan.debrisPaddingSeconds)
end

local function createEliminationOrb(position: Vector3, plan: EliminationPresentationRules.OrbPlan)
	CombatFramePublicationService.Queue(function()
		createEliminationOrbNow(position, plan)
	end)
end

local function emitElimination(elimination: EliminationEvent)
	CombatFramePublicationService.Queue(function()
		eliminationSignal:Fire(elimination)
	end)
	broadcast(elimination :: any)

	local effect = if elimination.effectId then Catalog.ById[elimination.effectId] else nil
	local palette = if effect and effect.Slot == "EliminationEffect" then effect.Palette else nil
	for _, plan in EliminationPresentationRules.BuildPlan(palette) do
		createEliminationOrb(elimination.position, plan)
	end
end

local function applyDamage(
	target: Player,
	attacker: Player?,
	rawDamage: number,
	direction: Vector3,
	means: string,
	isSplash: boolean,
	shot: ShotContext,
	allowCapturedAttackAuthorization: boolean?,
	projectileWitness: Projectile?,
	targetBody: MoverPushRules.Body?,
	bypassArmor: boolean?
): boolean
	local record = records[target]
	if not record or not record.alive or rawDamage <= 0 or not MatchService.CanPlayerFight(target) then
		return false
	end
	local damageAuthorized = MatchService.CanDamage(attacker, target)
	if not damageAuthorized and allowCapturedAttackAuthorization == true and attacker ~= nil then
		damageAuthorized = MatchService.CanAuthorizedAttackDamage(attacker, target, shot.matchId)
	end
	if not damageAuthorized then
		-- Q3 applies momentum before friendly-fire health protection. Preserve
		-- that feel while still requiring two active, eligible teammates.
		if
			attacker
			and attacker ~= target
			and (MatchService.CanPlayerFight(attacker) or allowCapturedAttackAuthorization == true)
			and not MatchService.AreOpponents(attacker, target)
		then
			applyKnockback(target, direction, rawDamage)
		end
		return false
	end

	local battleSuitActive = PowerupRules.IsActive(
		record.powerupExpiries[PowerupRules.PowerupId.BattleSuit] or 0,
		assert(shot.levelTimeMilliseconds, "damage requires exact Q3 level time")
	) == true
	local protectedDamage = assert(
		PowerupRules.BattleSuitDamage(rawDamage, battleSuitActive, isSplash, means == "Falling"),
		"Battle Suit damage input must be valid"
	)
	if protectedDamage <= 0 then
		applyKnockback(target, direction, rawDamage)
		return false
	end
	local adjustedDamage: number
	local armorSave: number
	local healthDamage: number
	if bypassArmor then
		adjustedDamage = protectedDamage
		armorSave = 0
		healthDamage = protectedDamage
	else
		adjustedDamage, armorSave, healthDamage =
			WeaponDefinitions.ResolveDamage(protectedDamage, record.armor, attacker == target)
		if attacker == target and MatchService.GetRules().SelfHealthDamageProtected then
			healthDamage = 0
		end
	end
	healthDamage = assert(
		OneShotRules.ResolveHealthDamage(
			MatchService.GetRules().OneShot,
			attacker ~= nil and MatchService.AreOpponents(attacker, target),
			record.health,
			healthDamage
		),
		"One-Shot live damage input must be valid"
	)
	if adjustedDamage <= 0 then
		return false
	end
	local lethal = healthDamage >= record.health
	if lethal then
		local kind: DirectDeathCauseKind
		local capturedRawDamage: number? = nil
		local capturedDirection: Vector3? = nil
		local projectileSource: ProjectileEntityService.ProjectileSource? = nil
		local worldMeans: string? = nil
		if projectileWitness then
			kind = if isSplash then "ProjectileSplash" else "MissileImpact"
			projectileSource = projectileWitness.source
		elseif attacker == nil then
			kind = "WorldDamage"
			capturedRawDamage = rawDamage
			worldMeans = means
		else
			kind = "PlayerDirect"
			capturedDirection = direction
		end
		local applied, applyError = executeDirectDeath({
			kind = kind,
			target = target,
			attacker = attacker,
			rawDamage = capturedRawDamage,
			direction = capturedDirection,
			shot = shot,
			targetBody = targetBody,
			projectileSource = projectileSource,
			worldMeans = worldMeans,
		})
		assert(applied, applyError or "lethal direct-damage transaction failed")
		return true
	end

	applyKnockback(target, direction, rawDamage)

	record.armor -= armorSave
	record.health -= healthDamage
	record.pendingPainFeedbackLevelTimeMilliseconds = shot.levelTimeMilliseconds
	if attacker then
		damageSignal:Fire(
			target,
			attacker,
			healthDamage,
			assert(shot.levelTimeMilliseconds, "damage observer requires shot level time")
		)
	end
	local damageEventId = nextEventId(shot)
	-- Every lethal branch returned through executeDirectDeath above. This path is
	-- therefore strictly nonlethal and cannot enter a compatibility player_die.
	syncHumanoidHealth(record)
	syncPlayer(target)

	broadcast({
		kind = "Damage",
		eventId = damageEventId,
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		revision = shot.revision,
		targetUserId = target.UserId,
		attackerUserId = if attacker then attacker.UserId else 0,
		rawDamage = rawDamage,
		adjustedDamage = adjustedDamage,
		damage = healthDamage,
		armorSave = armorSave,
		means = means,
		isSplash = isSplash,
		isSelfDamage = attacker == target,
		killed = false,
		targetHealth = record.health,
		targetArmor = record.armor,
	})

	return true
end

function directDeathOwner.abortChildren(
	bodyQueuePrepared: unknown?,
	movementPrepared: unknown?,
	matchToken: unknown?,
	corpseToken: unknown?,
	deathDropInsertionAdapter: DeathDropInsertionAdapter?,
	deathDropInsertionPrepared: unknown?
): boolean
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	local deathDropInsertionAborted = deathDropInsertionPrepared == nil
		or (
			deathDropInsertionAdapter ~= nil
			and select(
				1,
				(deathDropInsertionAdapter :: DeathDropInsertionAdapter).AbortPreparedBatch(deathDropInsertionPrepared)
			)
		)
	local corpseAborted = corpseToken == nil or CorpseService.Abort(corpseToken)
	local movementAborted = movementPrepared == nil or MovementService.AbortPreparedNormalToDead(movementPrepared)
	local bodyQueueAborted = bodyQueuePrepared == nil
		or bodyQueueService.AbortPreparedDeathRecordBatch(bodyQueuePrepared)
	local matchAborted = matchToken == nil or MatchService.AbortEliminationBatch(matchToken)
	return deathDropInsertionAborted and corpseAborted and movementAborted and bodyQueueAborted and matchAborted
end

function directDeathOwner.deathDropBatchSummaryError(
	adapter: DeathDropInsertionAdapter,
	prepared: unknown,
	summaryValue: unknown,
	requests: { DeathWeaponDropRequest },
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary
): string?
	if
		type(prepared) ~= "table"
		or type(summaryValue) ~= "table"
		or adapter.InspectPreparedBatch(prepared) ~= summaryValue
		or not adapter.ValidatePreparedBatchDependency(prepared, summaryValue)
	then
		return "stale-direct-death-drop-batch-dependency"
	end
	local summary = summaryValue :: any
	local summarizedRequests = summary.requests
	local itemSummaries = summary.itemSummaries
	if
		summary.operationOrder ~= 1
		or summary.frame ~= frame
		or summary.frameSummary ~= frameSummary
		or type(summarizedRequests) ~= "table"
		or type(itemSummaries) ~= "table"
		or not table.isfrozen(summarizedRequests)
		or not table.isfrozen(itemSummaries)
		or #summarizedRequests ~= #requests
		or #itemSummaries ~= #requests
	then
		return "crossed-direct-death-drop-batch-summary"
	end
	for index, request in requests do
		local summarizedRequest = summarizedRequests[index]
		local itemSummary = itemSummaries[index]
		local insertion = if type(itemSummary) == "table" then itemSummary.insertion else nil
		local participant = if type(itemSummary) == "table" then itemSummary.participant else nil
		local body = if type(participant) == "table" then participant.body else nil
		local binding = if type(insertion) == "table" then insertion.binding else nil
		local order = if type(insertion) == "table" then insertion.order else nil
		local expectedOrdinal = MoverConsequenceRules.PowerupItemOrdinal[request.itemId]
		local expectedPhase = if expectedOrdinal
			then MoverConsequenceRules.InsertionPhase.Powerup
			else MoverConsequenceRules.InsertionPhase.DeathWeapon
		if
			type(summarizedRequest) ~= "table"
			or not table.isfrozen(summarizedRequest)
			or summarizedRequest.dropId ~= request.dropId
			or summarizedRequest.matchId ~= request.matchId
			or summarizedRequest.itemId ~= request.itemId
			or summarizedRequest.quantity ~= request.quantity
			or summarizedRequest.position ~= request.position
			or summarizedRequest.velocity ~= request.velocity
			or type(itemSummary) ~= "table"
			or itemSummary.operationOrder ~= 1
			or itemSummary.dropId ~= request.dropId
			or type(insertion) ~= "table"
			or insertion.kind ~= "Insert"
			or type(order) ~= "table"
			or order.operationOrder ~= 1
			or order.phase ~= expectedPhase
			or order.ordinal ~= (expectedOrdinal or 0)
			or type(binding) ~= "table"
			or binding.kind ~= MoverConsequenceRules.BindingKinds.Item
			or binding.itemId ~= request.itemId
			or type(body) ~= "table"
			or body ~= insertion.body
			or body.id ~= itemSummary.bodyId
			or body.sourceOrder ~= itemSummary.sourceOrder
			or body.position ~= request.position
			or body.velocity ~= request.velocity
		then
			return "crossed-direct-death-drop-batch-item-summary"
		end
	end
	return nil
end

function directDeathOwner.sameBody(left: MoverPushRules.Body, right: MoverPushRules.Body): boolean
	return left.id == right.id
		and left.sourceOrder == right.sourceOrder
		and left.position == right.position
		and left.size == right.size
		and left.centerOffset == right.centerOffset
		and left.velocity == right.velocity
		and left.groundMoverId == right.groundMoverId
		and left.contents == right.contents
		and left.clipMask == right.clipMask
end

function directDeathOwner.validPointContents(value: unknown): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= 0
		and (value :: number) <= 4_294_967_295
		and bit32.band(value :: number, bit32.bnot(directDeathOwner.knownPointContentsMask)) == 0
end

function directDeathOwner.shotError(
	shotValue: unknown,
	frameSummary: AuthoritativeFrameService.Summary,
	matchId: string,
	allowHistoricalProjectileShot: boolean
): string?
	if
		type(shotValue) ~= "table"
		or getmetatable(shotValue :: table) ~= nil
		or not (
			hasExactKeys(shotValue, directDeathOwner.shotKeys, 12)
			or hasExactKeys(shotValue, directDeathOwner.shotKeys, 13)
		)
	then
		return "invalid-direct-death-shot"
	end
	local shot = shotValue :: ShotContext
	local shotLevelTimeMilliseconds = shot.levelTimeMilliseconds
	if
		type(shot.id) ~= "string"
		or shot.id == ""
		or shot.matchId ~= matchId
		or not isFinite(shot.lifeSequence)
		or shot.lifeSequence % 1 ~= 0
		or shot.lifeSequence < 1
		or not isFinite(shot.weaponId)
		or shot.weaponId % 1 ~= 0
		or not isFinite(shot.ownerUserId)
		or shot.ownerUserId % 1 ~= 0
		or not isFinite(shot.revision)
		or shot.revision % 1 ~= 0
		or not isFinite(shot.clientSequence)
		or shot.clientSequence % 1 ~= 0
		or not isFinite(shot.serverFrame)
		or shot.serverFrame % 1 ~= 0
		or shot.serverFrame < 0
		or not isFinite(shotLevelTimeMilliseconds)
		or (shotLevelTimeMilliseconds :: number) % 1 ~= 0
		or (shotLevelTimeMilliseconds :: number) < 0
		or (if allowHistoricalProjectileShot
			then (shotLevelTimeMilliseconds :: number) > frameSummary.currentTimeMilliseconds
			else shotLevelTimeMilliseconds ~= frameSummary.currentTimeMilliseconds)
		or not isFinite(shot.firedAtServerTime)
		or not isFinite(shot.eventSequence)
		or shot.eventSequence % 1 ~= 0
		or shot.eventSequence < 0
		or shot.eventSequence > MAXIMUM_DEBUG_COUNTER - 2
		or not isFinite(shot.seed)
		or shot.seed % 1 ~= 0
		or (shot.inputReceivedServerTime ~= nil and not isFinite(shot.inputReceivedServerTime))
	then
		return "invalid-direct-death-shot"
	end
	return nil
end

function directDeathOwner.shotMatchesSnapshot(shot: ShotContext, snapshot: ShotContext, eventSequence: number): boolean
	return table.isfrozen(snapshot)
		and shot.id == snapshot.id
		and shot.matchId == snapshot.matchId
		and shot.lifeSequence == snapshot.lifeSequence
		and shot.weaponId == snapshot.weaponId
		and shot.ownerUserId == snapshot.ownerUserId
		and shot.revision == snapshot.revision
		and shot.clientSequence == snapshot.clientSequence
		and shot.serverFrame == snapshot.serverFrame
		and shot.levelTimeMilliseconds == snapshot.levelTimeMilliseconds
		and shot.firedAtServerTime == snapshot.firedAtServerTime
		and shot.eventSequence == eventSequence
		and snapshot.eventSequence == eventSequence
		and shot.seed == snapshot.seed
		and shot.inputReceivedServerTime == snapshot.inputReceivedServerTime
end

function directDeathOwner.playerDirectDamage(weaponId: number): number?
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		return nil
	end
	if weaponId == WeaponDefinitions.WeaponId.Machinegun and MatchService.GetRules().ModeKind == "TeamDeathmatch" then
		return definition.TeamDamage
	end
	return definition.Damage
end

local function powerupAdjustedDamage(
	rawDamage: number,
	attackerRecord: CombatRecord?,
	targetRecord: CombatRecord,
	levelTimeMilliseconds: number,
	isSplash: boolean,
	means: string
): number
	local quadActive = attackerRecord ~= nil
		and PowerupRules.IsActive(
				attackerRecord.powerupExpiries[PowerupRules.PowerupId.Quad] or 0,
				levelTimeMilliseconds
			)
			== true
	local poweredDamage =
		assert(PowerupRules.QuadDamage(rawDamage, quadActive), "direct-death Quad damage input must be valid")
	local battleSuitActive = PowerupRules.IsActive(
		targetRecord.powerupExpiries[PowerupRules.PowerupId.BattleSuit] or 0,
		levelTimeMilliseconds
	) == true
	return assert(
		PowerupRules.BattleSuitDamage(poweredDamage, battleSuitActive, isSplash, means == "Falling"),
		"direct-death Battle Suit damage input must be valid"
	)
end

function directDeathOwner.projectileDamageAndDirection(
	kind: DirectDeathCauseKind,
	projectile: DirectDeathProjectileWitness?,
	sourceSummary: ProjectileEntityService.SourceSummary?,
	targetBody: MoverPushRules.Body,
	frameSummary: AuthoritativeFrameService.Summary
): (number?, Vector3?, string?)
	if not projectile or not sourceSummary or projectile.authorityTrajectoryState ~= sourceSummary.trajectoryState then
		return nil, nil, "crossed-projectile-damage-source"
	end
	local definition = WeaponDefinitions.ById[projectile.shot.weaponId]
	if not definition then
		return nil, nil, "projectile-damage-definition-unavailable"
	end
	if kind == "MissileImpact" then
		if sourceSummary.phase ~= "Missile" or not definition.Damage then
			return nil, nil, "invalid-missile-impact-damage-source"
		end
		local direction = ProjectileTrajectory.EvaluateDelta(
			sourceSummary.trajectoryState,
			frameSummary.currentTimeMilliseconds / 1000
		)
		if not direction then
			return nil, nil, "missile-impact-direction-unavailable"
		end
		return definition.Damage, WeaponDefinitions.MissileImpactDirection(direction), nil
	elseif kind == "ProjectileSplash" then
		if
			sourceSummary.phase ~= "Event"
			or sourceSummary.trajectoryState.kind ~= ProjectileTrajectory.Kind.Stationary
			or sourceSummary.trajectoryState.base ~= sourceSummary.trajectoryBase
			or projectile.position ~= sourceSummary.trajectoryBase
			or not definition.SplashDamage
			or not definition.SplashRadius
		then
			return nil, nil, "invalid-projectile-splash-damage-source"
		end
		local explosionPosition = sourceSummary.trajectoryBase
		local targetCenter = targetBody.position + targetBody.centerOffset
		local edgeDistance =
			WeaponDefinitions.DistanceToAxisAlignedBox(explosionPosition, targetCenter, targetBody.size)
		local damage = WeaponDefinitions.SplashDamage(definition.SplashDamage, edgeDistance, definition.SplashRadius)
		local visibilityQuery = canDamageFrom
		local visibilitySucceeded, visible =
			if visibilityQuery then pcall(visibilityQuery, explosionPosition, targetCenter) else false, false
		if damage <= 0 or not visibilitySucceeded or visible ~= true then
			return nil, nil, "projectile-splash-target-not-reachable"
		end
		local direction = targetBody.position
			- explosionPosition
			+ Vector3.yAxis * WeaponDefinitions.RadiusDirectionLift
		return damage, direction, nil
	end
	return nil, nil, "invalid-projectile-damage-cause"
end

function directDeathOwner.causeCurrentError(
	causeValue: unknown,
	capability: DirectDeathCauseCapability,
	expectedStatus: "Current" | "Bound"
): string?
	local classification = select(1, (directDeathOwner.causeRules :: any).Validate(capability.classification))
	local target = capability.target
	local record = records[target]
	local currentBody = MovementService.GetPlayerMoverBody(target)
	local expectedRawDamage: number? = nil
	local expectedDirection: Vector3? = nil
	local fixedDamageError: string? = nil
	if capability.kind == "PlayerDirect" then
		expectedRawDamage = directDeathOwner.playerDirectDamage(capability.shot.weaponId)
		if expectedRawDamage == nil then
			fixedDamageError = "player-direct-damage-definition-unavailable"
		end
	elseif directDeathOwner.projectileCauseKinds[capability.kind] == true then
		expectedRawDamage, expectedDirection, fixedDamageError = directDeathOwner.projectileDamageAndDirection(
			capability.kind,
			capability.projectile,
			capability.projectileSourceSummary,
			capability.hitBody,
			capability.authoritativeFrameSummary
		)
	end
	if expectedRawDamage ~= nil then
		expectedRawDamage = powerupAdjustedDamage(
			expectedRawDamage,
			capability.attackerRecord,
			capability.targetRecord,
			assert(capability.shot.levelTimeMilliseconds, "direct-death currentness requires shot level time"),
			capability.isSplash,
			capability.means
		)
	end
	if
		capability.status ~= expectedStatus
		or capability.cause ~= causeValue
		or directDeathOwner.causeCapabilities[capability.cause] ~= capability
		or not table.isfrozen(capability.cause)
		or classification ~= capability.classification
		or capability.kind ~= (classification :: any).kind
		or capability.damageMode ~= (classification :: any).damageMode
		or capability.means ~= (classification :: any).means
		or capability.meansOfDeath ~= (classification :: any).meansOfDeath
		or capability.isSplash ~= (classification :: any).isSplash
		or capability.bypassCombatEligibility ~= (classification :: any).bypassCombatEligibility
		or capability.publishesDamage ~= (capability.damageMode == "GDamage")
		or capability.bloodEnabled ~= true
		or not isFinite(capability.rawDamage)
		or capability.rawDamage % 1 ~= 0
		or capability.rawDamage < 1
		or capability.rawDamage > 100_000
		or typeof(capability.direction) ~= "Vector3"
		or not isFinite(capability.direction.X)
		or not isFinite(capability.direction.Y)
		or not isFinite(capability.direction.Z)
		or fixedDamageError ~= nil
		or (expectedRawDamage ~= nil and capability.rawDamage ~= expectedRawDamage)
		or (expectedDirection ~= nil and capability.direction ~= expectedDirection)
		or (capability.damageMode == "PlayerDie" and (capability.rawDamage ~= 100_000 or capability.direction ~= Vector3.zero or capability.fixedPostDamageHealth ~= (if capability.kind
				== "SuicidePlayerDie"
			then MoverConsequenceRules.MinimumClampedQ3Health
			else 0)))
		or (capability.damageMode == "GDamage" and capability.fixedPostDamageHealth ~= nil)
		or (capability.kind == "Telefrag" and (capability.rawDamage ~= 100_000 or capability.direction ~= Vector3.zero))
		or (directDeathOwner.traceCauseKinds[capability.kind] == true and (classification :: any).weaponId ~= capability.shot.weaponId)
		or target.Parent ~= Players
		or record ~= capability.targetRecord
		or not record.alive
		or record.health ~= capability.targetHealth
		or record.armor ~= capability.targetArmor
		or capability.targetHealth <= 0
		or record.movementLifeBinding ~= capability.targetLifeBinding
		or capability.targetLifeSummary.player ~= target
		or capability.targetLifeSummary.playerUserId ~= target.UserId
		or capability.targetLifeSummary.lifeSequence ~= record.lifeSequence
		or not MovementService.ValidateMovementLifeBindingDependency(
			capability.targetLifeBinding,
			capability.targetLifeSummary
		)
		or not currentBody
		or capability.targetLifeSummary.playerBodyId ~= currentBody.id
		or capability.targetLifeSummary.playerSourceOrder ~= currentBody.sourceOrder
		or not directDeathOwner.sameBody(currentBody, capability.targetBody)
		or not directDeathOwner.sameBody(currentBody, capability.hitBody)
		or not table.isfrozen(capability.targetBody)
		or not table.isfrozen(capability.hitBody)
		or AuthoritativeFrameService.GetOpenFrame() ~= capability.authoritativeFrame
		or AuthoritativeFrameService.InspectFrame(capability.authoritativeFrame) ~= capability.authoritativeFrameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			capability.authoritativeFrame,
			capability.authoritativeFrameSummary
		)
		or not MatchService.ValidateMatchLineage(capability.matchLineage, capability.matchId)
		or not directDeathOwner.shotMatchesSnapshot(
			capability.shot,
			capability.shotSnapshot,
			capability.shotEventSequence
		)
		or capability.shot.matchId ~= capability.matchId
		or (directDeathOwner.traceCauseKinds[capability.kind] ~= true and capability.shot.weaponId ~= WeaponDefinitions.WeaponId.None)
		or directDeathOwner.shotError(
			capability.shot,
			capability.authoritativeFrameSummary,
			capability.matchId,
			directDeathOwner.projectileCauseKinds[capability.kind] == true
		) ~= nil
		or not directDeathOwner.validPointContents(capability.pointContents)
		or not MovementService.ValidateNormalToDeadSourceDependency(
			capability.attackerSource,
			capability.attackerSourceSummary
		)
		or not MovementService.ValidateNormalToDeadSourceDependency(
			capability.inflictorSource,
			capability.inflictorSourceSummary
		)
	then
		return "stale-direct-death-cause"
	end

	local attacker = capability.attacker
	local attackerRecord = capability.attackerRecord
	if attacker then
		if
			attacker.Parent ~= Players
			or records[attacker] ~= attackerRecord
			or attackerRecord == nil
			or capability.shot.ownerUserId ~= attacker.UserId
			or capability.attackerSourceSummary.kind ~= "Player"
			or capability.attackerSourceSummary.player ~= attacker
			or capability.attackerSourceSummary.lifeBinding ~= attackerRecord.movementLifeBinding
			or capability.attackerSourceSummary.lifeSummary == nil
			or capability.attackerSourceSummary.lifeSummary.player ~= attacker
			or capability.attackerSourceSummary.lifeSummary.playerUserId ~= attacker.UserId
			or capability.attackerSourceSummary.lifeSummary.lifeSequence ~= attackerRecord.lifeSequence
		then
			return "stale-direct-death-cause-attacker"
		end
	elseif
		capability.shot.ownerUserId ~= 0
		or capability.attackerSourceSummary.kind ~= "World"
		or capability.attackerSourceSummary.player ~= nil
	then
		return "stale-direct-death-cause-world-attacker"
	end

	if capability.kind == "PlayerDirect" then
		if
			not attackerRecord
			or not attackerRecord.alive
			or attacker == target
			or capability.shot.lifeSequence ~= attackerRecord.lifeSequence
			or not MatchService.CanDamage(attacker, target)
		then
			return "stale-player-direct-death-cause"
		end
	elseif capability.kind == "MissileImpact" or capability.kind == "ProjectileSplash" then
		if
			not attacker
			or (capability.kind == "MissileImpact" and attacker == target)
			or not MatchService.CanAuthorizedAttackDamage(attacker, target, capability.shot.matchId)
			or not capability.projectileSource
			or projectilesBySource[capability.projectileSource] ~= capability.projectile
			or not capability.projectile
			or capability.projectile.owner ~= attacker
			or capability.projectile.shot ~= capability.shot
			or capability.projectile.source ~= capability.projectileSource
			or ProjectileEntityService.InspectSource(capability.projectileSource) ~= capability.projectileSourceSummary
			or capability.projectileSourceSummary == nil
			or capability.projectileSourceSummary.shotId ~= capability.shot.id
			or capability.projectileSourceSummary.phase
				~= (if capability.kind == "MissileImpact" then "Missile" else "Event")
		then
			return "stale-projectile-direct-death-cause"
		end
	elseif capability.kind == "WorldDamage" or capability.kind == "ForcedWorldPlayerDie" then
		if
			attacker ~= nil
			or (capability.kind == "WorldDamage" and capability.direction ~= Vector3.zero)
			or (capability.kind == "WorldDamage" and capability.means == "Falling" and capability.rawDamage ~= 5 and capability.rawDamage ~= 10)
			or not MatchService.CanDamage(nil, target)
		then
			return "stale-world-direct-death-cause"
		end
	elseif capability.kind == "SuicidePlayerDie" then
		if
			attacker ~= target
			or capability.shot.lifeSequence ~= record.lifeSequence
			or not MatchService.CanDamage(target, target)
		then
			return "stale-suicide-direct-death-cause"
		end
	elseif capability.kind == "Telefrag" then
		if
			not attackerRecord
			or attacker == target
			or not attackerRecord.alive
			or capability.shot.lifeSequence ~= attackerRecord.lifeSequence
		then
			return "stale-telefrag-direct-death-cause"
		end
	else
		return "invalid-direct-death-cause-kind"
	end
	return nil
end

function directDeathOwner.retireCauseCapability(capability: DirectDeathCauseCapability)
	capability.status = "Retired"
	if directDeathOwner.causeCapabilities[capability.cause] == capability then
		directDeathOwner.causeCapabilities[capability.cause] = nil
	end
end

-- Private-only mint. Future live damage callsites must create this capability
-- inline from their exact trace/projectile/environment authority and pass only
-- the opaque handle to PrepareDirectDeath. No service or test mint is exported.
function directDeathOwner.captureCause(request: DirectDeathCauseCaptureRequest): (DirectDeathCause?, string?)
	local frame = AuthoritativeFrameService.GetOpenFrame()
	local frameSummary = if frame then AuthoritativeFrameService.InspectFrame(frame) else nil
	local matchId = MatchService.GetMatchId()
	local matchLineage = if matchId then MatchService.GetCurrentMatchLineage(matchId) else nil
	if
		not frame
		or not frameSummary
		or type(matchId) ~= "string"
		or not matchLineage
		or not MatchService.ValidateMatchLineage(matchLineage, matchId)
	then
		return nil, "direct-death-cause-authoritative-frame-unavailable"
	end
	local shotError = directDeathOwner.shotError(
		request.shot,
		frameSummary,
		matchId,
		directDeathOwner.projectileCauseKinds[request.kind] == true
	)
	if shotError then
		return nil, shotError
	end
	local target = request.target
	local targetRecord = records[target]
	local targetLifeBinding = targetRecord and targetRecord.movementLifeBinding
	local targetLifeSummary = if targetLifeBinding
		then MovementService.InspectMovementLifeBinding(targetLifeBinding)
		else nil
	local targetBody = MovementService.GetPlayerMoverBody(target)
	if
		target.Parent ~= Players
		or not targetRecord
		or not targetRecord.alive
		or targetRecord.health <= 0
		or not targetLifeBinding
		or not targetLifeSummary
		or not targetBody
		or not MovementService.ValidateMovementLifeBindingDependency(targetLifeBinding, targetLifeSummary)
		or targetLifeSummary.player ~= target
		or targetLifeSummary.playerUserId ~= target.UserId
		or targetLifeSummary.lifeSequence ~= targetRecord.lifeSequence
		or targetLifeSummary.playerBodyId ~= targetBody.id
		or targetLifeSummary.playerSourceOrder ~= targetBody.sourceOrder
	then
		return nil, "stale-direct-death-cause-target"
	end
	local targetHealth = targetRecord.health
	local targetArmor = targetRecord.armor
	local hitBody = request.targetBody or targetBody
	if
		(directDeathOwner.traceCauseKinds[request.kind] == true and request.targetBody == nil)
		or not table.isfrozen(hitBody)
		or not directDeathOwner.sameBody(targetBody, hitBody)
	then
		return nil, "crossed-direct-death-hit-body"
	end

	local classificationRequest: { [string]: any }
	if directDeathOwner.traceCauseKinds[request.kind] == true then
		if request.worldMeans ~= nil then
			return nil, "weapon-direct-death-cause-has-world-means"
		end
		local weaponDefinition = WeaponDefinitions.ById[request.shot.weaponId]
		local classifiedMeans = if weaponDefinition
			then if request.kind == "ProjectileSplash"
				then weaponDefinition.SplashMeans
				else weaponDefinition.DirectMeans
			else nil
		classificationRequest = {
			kind = request.kind,
			weaponId = request.shot.weaponId,
			means = classifiedMeans,
		}
	else
		local nonWeaponMeans = request.worldMeans
		if request.kind == "SuicidePlayerDie" or request.kind == "Telefrag" then
			if request.worldMeans ~= nil then
				return nil, "fixed-direct-death-cause-has-authored-means"
			end
			nonWeaponMeans = if request.kind == "SuicidePlayerDie" then "Suicide" else "Telefrag"
		end
		classificationRequest = {
			kind = request.kind,
			means = nonWeaponMeans,
		}
	end
	local classification, classificationError = (directDeathOwner.causeRules :: any).Resolve(classificationRequest)
	if not classification then
		return nil, classificationError or "invalid-direct-death-cause-classification"
	end
	if classification.bypassCombatEligibility ~= true and not MatchService.CanPlayerFight(target) then
		return nil, "direct-death-target-cannot-fight"
	end
	if
		directDeathOwner.traceCauseKinds[request.kind] ~= true
		and request.shot.weaponId ~= WeaponDefinitions.WeaponId.None
	then
		return nil, "nonweapon-direct-death-cause-has-weapon"
	end

	local attacker = request.attacker
	local attackerRecord = if attacker then records[attacker] else nil
	if request.kind == "SuicidePlayerDie" and attacker ~= target then
		return nil, "invalid-suicide-direct-death-attacker"
	end
	if (request.kind == "WorldDamage" or request.kind == "ForcedWorldPlayerDie") and attacker ~= nil then
		return nil, "invalid-world-direct-death-attacker"
	end
	if
		request.kind ~= "WorldDamage"
		and request.kind ~= "ForcedWorldPlayerDie"
		and (
			not attacker
			or not attackerRecord
			or attacker.Parent ~= Players
			or request.shot.ownerUserId ~= attacker.UserId
		)
	then
		return nil, "stale-direct-death-cause-attacker"
	end
	if attacker == nil and request.shot.ownerUserId ~= 0 then
		return nil, "direct-death-world-shot-has-player-owner"
	end

	local rawDamage = request.rawDamage
	local direction = request.direction
	local fixedPostDamageHealth: number? = nil
	local publishesDamage = classification.damageMode == "GDamage"
	if request.kind == "Telefrag" then
		if rawDamage ~= nil or direction ~= nil then
			return nil, "telefrag-direct-death-input-not-fixed"
		end
		rawDamage = 100_000
		direction = Vector3.zero
	elseif classification.damageMode == "PlayerDie" then
		if rawDamage ~= nil or direction ~= nil then
			return nil, "player-die-direct-death-input-not-fixed"
		end
		rawDamage = 100_000
		direction = Vector3.zero
		fixedPostDamageHealth = if request.kind == "SuicidePlayerDie"
			then MoverConsequenceRules.MinimumClampedQ3Health
			else 0
	elseif request.kind == "WorldDamage" then
		if direction ~= nil then
			return nil, "world-direct-death-direction-not-fixed"
		end
		if
			not isFinite(rawDamage)
			or (rawDamage :: number) % 1 ~= 0
			or (rawDamage :: number) < 1
			or (rawDamage :: number) > 100_000
		then
			return nil, "invalid-direct-death-cause-damage-input"
		end
		if classification.means == "Falling" and rawDamage ~= 5 and rawDamage ~= 10 then
			return nil, "falling-direct-death-damage-not-source-fixed"
		end
		direction = Vector3.zero
	elseif request.kind == "PlayerDirect" then
		if
			rawDamage ~= nil
			or typeof(direction) ~= "Vector3"
			or not isFinite((direction :: Vector3).X)
			or not isFinite((direction :: Vector3).Y)
			or not isFinite((direction :: Vector3).Z)
		then
			return nil, "player-direct-death-damage-not-source-fixed"
		end
		rawDamage = directDeathOwner.playerDirectDamage(request.shot.weaponId)
		if rawDamage == nil then
			return nil, "player-direct-damage-definition-unavailable"
		end
	elseif directDeathOwner.projectileCauseKinds[request.kind] == true then
		if rawDamage ~= nil or direction ~= nil then
			return nil, "projectile-direct-death-damage-not-source-fixed"
		end
	else
		return nil, "invalid-direct-death-cause-kind"
	end

	local projectileSource = request.projectileSource
	local projectile: Projectile? = nil
	local projectileSourceSummary: ProjectileEntityService.SourceSummary? = nil
	if request.kind == "MissileImpact" or request.kind == "ProjectileSplash" then
		projectile = if projectileSource then projectilesBySource[projectileSource] else nil
		projectileSourceSummary = if projectileSource
			then ProjectileEntityService.InspectSource(projectileSource)
			else nil
		local expectedPhase = if request.kind == "MissileImpact" then "Missile" else "Event"
		if
			not projectileSource
			or not projectile
			or not projectileSourceSummary
			or projectile.owner ~= attacker
			or projectile.shot ~= request.shot
			or projectile.source ~= projectileSource
			or projectileSourceSummary.owner ~= attacker
			or projectileSourceSummary.shotId ~= request.shot.id
			or projectileSourceSummary.phase ~= expectedPhase
		then
			return nil, "crossed-projectile-direct-death-cause"
		end
	elseif projectileSource ~= nil then
		return nil, "unexpected-projectile-direct-death-source"
	end
	if directDeathOwner.projectileCauseKinds[request.kind] == true then
		local derivedDamage, derivedDirection, derivedError = directDeathOwner.projectileDamageAndDirection(
			request.kind,
			projectile,
			projectileSourceSummary,
			hitBody,
			frameSummary
		)
		if derivedDamage == nil or derivedDirection == nil then
			return nil, derivedError or "projectile-direct-death-damage-unavailable"
		end
		rawDamage = derivedDamage
		direction = derivedDirection
	end
	if classification.damageMode == "GDamage" then
		rawDamage = powerupAdjustedDamage(
			assert(rawDamage, "GDamage cause requires raw damage"),
			attackerRecord,
			targetRecord,
			assert(request.shot.levelTimeMilliseconds, "direct-death preparation requires shot level time"),
			classification.isSplash,
			classification.means
		)
	end

	if request.kind == "PlayerDirect" then
		if
			not attackerRecord
			or not attackerRecord.alive
			or attacker == target
			or request.shot.lifeSequence ~= attackerRecord.lifeSequence
			or not MatchService.CanDamage(attacker, target)
		then
			return nil, "player-direct-death-not-authorized"
		end
	elseif request.kind == "MissileImpact" or request.kind == "ProjectileSplash" then
		if
			not attacker
			or (request.kind == "MissileImpact" and attacker == target)
			or not MatchService.CanAuthorizedAttackDamage(attacker, target, request.shot.matchId)
		then
			return nil, "projectile-direct-death-not-authorized"
		end
	elseif request.kind == "WorldDamage" or request.kind == "ForcedWorldPlayerDie" then
		if request.shot.lifeSequence ~= targetRecord.lifeSequence or not MatchService.CanDamage(nil, target) then
			return nil, "world-direct-death-not-authorized"
		end
	elseif request.kind == "SuicidePlayerDie" then
		if request.shot.lifeSequence ~= targetRecord.lifeSequence or not MatchService.CanDamage(target, target) then
			return nil, "suicide-direct-death-not-authorized"
		end
	elseif request.kind == "Telefrag" then
		if
			not attackerRecord
			or attacker == target
			or not attackerRecord.alive
			or request.shot.lifeSequence ~= attackerRecord.lifeSequence
		then
			return nil, "telefrag-direct-death-not-authorized"
		end
	end

	local pointContentsSucceeded, pointContentsValue = pcall(MovementService.GetPointContents, targetBody.position)
	if not pointContentsSucceeded or not directDeathOwner.validPointContents(pointContentsValue) then
		return nil, "direct-death-point-contents-unavailable"
	end
	local currentTargetBody = MovementService.GetPlayerMoverBody(target)
	if
		AuthoritativeFrameService.GetOpenFrame() ~= frame
		or AuthoritativeFrameService.InspectFrame(frame) ~= frameSummary
		or records[target] ~= targetRecord
		or not targetRecord.alive
		or targetRecord.health ~= targetHealth
		or targetRecord.armor ~= targetArmor
		or targetRecord.movementLifeBinding ~= targetLifeBinding
		or not currentTargetBody
		or not directDeathOwner.sameBody(currentTargetBody, targetBody)
		or not MovementService.ValidateMovementLifeBindingDependency(targetLifeBinding, targetLifeSummary)
		or targetLifeSummary.player ~= target
		or targetLifeSummary.playerUserId ~= target.UserId
		or targetLifeSummary.lifeSequence ~= targetRecord.lifeSequence
		or targetLifeSummary.playerBodyId ~= currentTargetBody.id
		or targetLifeSummary.playerSourceOrder ~= currentTargetBody.sourceOrder
		or (
			projectileSource ~= nil
			and (
				projectile == nil
				or projectileSourceSummary == nil
				or projectilesBySource[projectileSource] ~= projectile
				or ProjectileEntityService.InspectSource(projectileSource) ~= projectileSourceSummary
				or projectile.authorityTrajectoryState ~= projectileSourceSummary.trajectoryState
			)
		)
	then
		return nil, "direct-death-root-changed-during-point-contents"
	end

	local attackerSource: MovementService.NormalToDeadSource?
	local attackerSourceSummary: MovementService.NormalToDeadSourceSummary?
	if attacker then
		local attackerBinding = attackerRecord and attackerRecord.movementLifeBinding
		local attackerLifeSummary = if attackerBinding
			then MovementService.InspectMovementLifeBinding(attackerBinding)
			else nil
		if not attackerBinding or not attackerLifeSummary then
			return nil, "direct-death-attacker-movement-life-unavailable"
		end
		attackerSource, attackerSourceSummary =
			MovementService.CapturePlayerNormalToDeadSource(attackerBinding, attackerLifeSummary)
	else
		attackerSource, attackerSourceSummary = MovementService.GetWorldNormalToDeadSource()
	end
	if not attackerSource or not attackerSourceSummary then
		return nil, "direct-death-attacker-source-unavailable"
	end
	if attacker then
		local currentAttackerRecord = assert(attackerRecord, "direct-death attacker source has no Combat record")
		local attackerLifeSummary = attackerSourceSummary.lifeSummary
		if
			attackerSourceSummary.kind ~= "Player"
			or attackerSourceSummary.player ~= attacker
			or attackerSourceSummary.lifeBinding ~= currentAttackerRecord.movementLifeBinding
			or not attackerLifeSummary
			or attackerLifeSummary.player ~= attacker
			or attackerLifeSummary.playerUserId ~= attacker.UserId
			or attackerLifeSummary.lifeSequence ~= currentAttackerRecord.lifeSequence
		then
			return nil, "crossed-direct-death-attacker-life"
		end
	end
	local inflictorSource: MovementService.NormalToDeadSource
	local inflictorSourceSummary: MovementService.NormalToDeadSourceSummary
	if request.kind == "MissileImpact" then
		local capturedSource, capturedSummary, captureError =
			MovementService.CaptureProjectileNormalToDeadSource(projectileSource)
		if not capturedSource or not capturedSummary then
			return nil, captureError or "direct-death-missile-inflictor-unavailable"
		end
		inflictorSource = capturedSource
		inflictorSourceSummary = capturedSummary
	elseif
		request.kind == "ProjectileSplash"
		or request.kind == "WorldDamage"
		or request.kind == "ForcedWorldPlayerDie"
	then
		inflictorSource, inflictorSourceSummary = MovementService.GetWorldNormalToDeadSource()
	else
		inflictorSource = attackerSource
		inflictorSourceSummary = attackerSourceSummary
	end

	local shotSnapshot = table.clone(request.shot)
	table.freeze(shotSnapshot)
	local cause: DirectDeathCause = table.freeze({})
	local capability: DirectDeathCauseCapability = {
		cause = cause,
		status = "Current",
		kind = classification.kind,
		damageMode = classification.damageMode,
		classification = classification,
		target = target,
		targetRecord = targetRecord,
		targetHealth = targetHealth,
		targetArmor = targetArmor,
		targetLifeBinding = targetLifeBinding,
		targetLifeSummary = targetLifeSummary,
		targetBody = targetBody,
		hitBody = hitBody,
		attacker = attacker,
		attackerRecord = attackerRecord,
		rawDamage = rawDamage :: number,
		direction = direction :: Vector3,
		means = classification.means,
		isSplash = classification.isSplash,
		bypassCombatEligibility = classification.bypassCombatEligibility,
		publishesDamage = publishesDamage,
		fixedPostDamageHealth = fixedPostDamageHealth,
		shot = request.shot,
		shotSnapshot = shotSnapshot,
		shotEventSequence = request.shot.eventSequence,
		pointContents = pointContentsValue :: number,
		meansOfDeath = classification.meansOfDeath,
		bloodEnabled = true,
		attackerSource = attackerSource,
		attackerSourceSummary = attackerSourceSummary,
		inflictorSource = inflictorSource,
		inflictorSourceSummary = inflictorSourceSummary,
		projectileSource = projectileSource,
		projectileSourceSummary = projectileSourceSummary,
		projectile = projectile,
		authoritativeFrame = frame,
		authoritativeFrameSummary = frameSummary,
		matchId = matchId,
		matchLineage = matchLineage,
	}
	directDeathOwner.causeCapabilities[cause] = capability
	local currentError = directDeathOwner.causeCurrentError(cause, capability, "Current")
	if currentError then
		directDeathOwner.retireCauseCapability(capability)
		return nil, currentError
	end
	return cause, nil
end

executeDirectDeath = function(request: DirectDeathCauseCaptureRequest): (boolean, string?)
	local cause, captureError = directDeathOwner.captureCause(request)
	if not cause then
		return false, captureError or "direct-death-cause-capture-failed"
	end
	local prepared, _summary, prepareError = CombatService.PrepareDirectDeath(cause)
	if not prepared then
		return false, prepareError or "direct-death-prepare-failed"
	end
	local canApply, preflightError = CombatService.CanApplyPreparedDirectDeath(prepared)
	if not canApply then
		local aborted, abortError = CombatService.AbortPreparedDirectDeath(prepared)
		if not aborted then
			return false, abortError or preflightError or "direct-death-abort-failed"
		end
		return false, preflightError or "direct-death-preflight-failed"
	end
	local receipt = CombatService.ApplyPreparedDirectDeath(prepared)
	local report = CombatService.FlushPreparedDirectDeath(receipt)
	if not report.authorityApplied then
		return false, "direct-death-authority-not-applied"
	end
	return true, nil
end

function directDeathOwner.retireHandoffCapability(capability: DirectDeathHandoffCapability)
	capability.status = "Retired"
	if directDeathOwner.handoffByPlayer[capability.target] == capability.handoff then
		directDeathOwner.handoffByPlayer[capability.target] = nil
	end
	if directDeathOwner.handoffBySummary[capability.summary] == capability.handoff then
		directDeathOwner.handoffBySummary[capability.summary] = nil
	end
	if directDeathOwner.handoffCapabilities[capability.handoff] == capability then
		directDeathOwner.handoffCapabilities[capability.handoff] = nil
	end
end

function directDeathOwner.rebindHandoffRespawnDeadlines(
	player: Player,
	record: CombatRecord,
	respawnEligibleAtMilliseconds: number?,
	forcedRespawnAtMilliseconds: number?
)
	local handoff = directDeathOwner.handoffByPlayer[player]
	local capability = handoff and directDeathOwner.handoffCapabilities[handoff]
	if capability then
		assert(capability.status == "Current", "respawn deadline rebind found a non-current handoff")
		assert(capability.target == player, "respawn deadline rebind changed handoff target")
		assert(capability.record == record, "respawn deadline rebind changed Combat record")
		assert(
			capability.respawnEligibleAtMilliseconds == record.respawnEligibleAtMilliseconds
				and capability.forcedRespawnAtMilliseconds == record.forcedRespawnAtMilliseconds,
			"respawn deadline rebind found divergent handoff clocks"
		)
		capability.respawnEligibleAtMilliseconds = respawnEligibleAtMilliseconds
		capability.forcedRespawnAtMilliseconds = forcedRespawnAtMilliseconds
	end
	record.respawnEligibleAtMilliseconds = respawnEligibleAtMilliseconds
	record.forcedRespawnAtMilliseconds = forcedRespawnAtMilliseconds
end

function directDeathOwner.handoffCurrentError(handoffValue: unknown, capability: DirectDeathHandoffCapability): string?
	local summary = capability.summary
	local target = capability.target
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	local corpseSource = CorpseService.InspectRespawnCopyTombstone(capability.corpseTombstone)
	if
		capability.status ~= "Current"
		or capability.handoff ~= handoffValue
		or directDeathOwner.handoffCapabilities[capability.handoff] ~= capability
		or directDeathOwner.handoffBySummary[summary] ~= capability.handoff
		or directDeathOwner.handoffByPlayer[target] ~= capability.handoff
		or not table.isfrozen(capability.handoff)
		or not table.isfrozen(summary)
		or summary.target ~= target
		or summary.targetUserId ~= target.UserId
		or summary.lifeSequence ~= capability.record.lifeSequence
		or summary.bodyQueueHandle ~= capability.bodyQueueHandle
		or summary.bodyQueueDeathSummary ~= capability.bodyQueueDeathSummary
		or summary.corpseTombstone ~= capability.corpseTombstone
		or summary.preparedCorpseTombstoneSummary.source ~= capability.preparedCorpseSource
		or target.Parent ~= Players
		or records[target] ~= capability.record
		or capability.record.alive
		or capability.record.health ~= 0
		or capability.record.movementLifeBinding ~= capability.movementLifeBinding
		or capability.record.character ~= capability.character
		or capability.record.respawnEligibleAtMilliseconds ~= capability.respawnEligibleAtMilliseconds
		or capability.record.forcedRespawnAtMilliseconds ~= capability.forcedRespawnAtMilliseconds
		or capability.record.respawnRequested ~= false
		or not MovementService.ValidateMovementLifeBindingDependency(
			capability.movementLifeBinding,
			capability.movementLifeSummary
		)
		or not MatchService.ValidateMatchLineage(summary.matchLineage, summary.matchId)
		or not bodyQueueService.ValidateDeathHandleDependency(
			capability.bodyQueueHandle,
			capability.bodyQueueDeathSummary
		)
		or (capability.bodyQueueDeathSummary :: any).matchLineage ~= summary.matchLineage
		or (capability.bodyQueueDeathSummary :: any).deathTimeMilliseconds ~= summary.deathTimeMilliseconds
		or (capability.bodyQueueDeathSummary :: any).playerUserId ~= summary.targetUserId
		or (capability.bodyQueueDeathSummary :: any).lifeSequence ~= summary.lifeSequence
		or corpseSource == nil
		or corpseSource.matchId ~= summary.matchId
		or corpseSource.matchLineage ~= summary.matchLineage
		or corpseSource.playerUserId ~= summary.targetUserId
		or corpseSource.lifeSequence ~= summary.lifeSequence
		or corpseSource.playerBodyId ~= (capability.bodyQueueDeathSummary :: any).playerBodyId
		or corpseSource.playerSourceOrder ~= (capability.bodyQueueDeathSummary :: any).playerSourceOrder
		or corpseSource.playerLeaseGeneration ~= (capability.bodyQueueDeathSummary :: any).playerLeaseGeneration
	then
		return "stale-direct-death-handoff"
	end
	return nil
end

function directDeathOwner.powerupDropRequestsCurrentError(capability: DirectDeathPreparedCapability): string?
	local summary = capability.summary
	local mutation = capability.mutation
	local requests = capability.deathPowerupDropRequests
	local batchRequests = capability.deathDropBatchRequests
	local firstPowerupBatchIndex = if capability.deathWeaponDrop then 2 else 1
	if
		not table.isfrozen(requests)
		or not table.isfrozen(batchRequests)
		or summary.deathPowerupDropCount ~= #requests
		or #batchRequests ~= #requests + firstPowerupBatchIndex - 1
		or (#batchRequests > 0 and capability.deathDropInsertionAdapter ~= directDeathOwner.deathDropInsertionAdapter)
		or (#batchRequests == 0 and capability.deathDropInsertionAdapter ~= nil)
		or (capability.deathWeaponDrop ~= nil and batchRequests[1] ~= capability.deathWeaponDrop)
	then
		return "stale-direct-death-powerup-drop-plan"
	end
	local suppressed = summary.noDrop or MatchService.GetRules().ModeKind == "TeamDeathmatch"
	if suppressed then
		return if #requests == 0 then nil else "unsuppressed-direct-death-powerup-drop-plan"
	end

	local baseLook = capability.movementSummary.callbackEntityAngularTrajectoryBase.look
	local horizontal = Vector3.new(baseLook.X, 0, baseLook.Z)
	if horizontal.Magnitude <= 1e-6 then
		horizontal = Vector3.zAxis
	else
		horizontal = horizontal.Unit
	end
	local requestIndex = 0
	for powerupId = PowerupRules.PowerupId.Quad, PowerupRules.PowerupId.Flight do
		local expiry = mutation.beforePowerupExpiries[powerupId]
		if type(expiry) == "number" and expiry > summary.levelTimeMilliseconds then
			requestIndex += 1
			local request = requests[requestIndex]
			local batchRequest = batchRequests[firstPowerupBatchIndex + requestIndex - 1]
			local itemId = PowerupRules.ItemIdByPowerupId[powerupId]
			if not request or batchRequest ~= request or not itemId or not table.isfrozen(request) then
				return "stale-direct-death-powerup-drop-request"
			end
			local yaw = math.rad(
				PowerupRules.FirstDeathDropAngleDegrees + (requestIndex - 1) * PowerupRules.DeathDropAngleStepDegrees
			)
			local look = Vector3.new(
				horizontal.X * math.cos(yaw) - horizontal.Z * math.sin(yaw),
				0,
				horizontal.X * math.sin(yaw) + horizontal.Z * math.cos(yaw)
			)
			local seed = DroppedWeaponRules.MakeSeed(
				string.format("%s:powerup:%d", summary.matchId, powerupId),
				summary.targetUserId,
				summary.lifeSequence
			)
			if
				request.dropId
					~= string.format(
						"powerup:%s:%d:%d:%d",
						summary.matchId,
						summary.targetUserId,
						summary.lifeSequence,
						powerupId
					)
				or request.matchId ~= summary.matchId
				or request.itemId ~= itemId
				or request.quantity ~= math.max(1, math.floor((expiry - summary.levelTimeMilliseconds) / 1_000))
				or request.position ~= capability.movementSummary.callbackEntityTrajectoryBase
				or request.velocity ~= DroppedWeaponRules.LaunchVelocity(look, seed)
			then
				return "stale-direct-death-powerup-drop-request"
			end
		end
	end
	if requestIndex ~= #requests then
		return "stale-direct-death-powerup-drop-count"
	end
	return nil
end

function directDeathOwner.preparedCurrentError(
	preparedValue: unknown,
	capability: DirectDeathPreparedCapability,
	checkExternal: boolean
): string?
	local summary = capability.summary
	local mutation = capability.mutation
	local record = records[mutation.target]
	local shot = mutation.shot
	local deathWeaponDrop = capability.deathWeaponDrop
	local hasDeathWeaponDrop = deathWeaponDrop ~= nil
	local hasDeathDropBatch = #capability.deathDropBatchRequests > 0
	local handoffCapability = capability.handoffCapability
	local causeCapability = capability.causeCapability
	local powerupDropPlanError = directDeathOwner.powerupDropRequestsCurrentError(capability)
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or directDeathOwner.activePrepared ~= preparedValue
		or directDeathOwner.preparedCapabilities[preparedValue :: PreparedDirectDeath] ~= capability
		or directDeathOwner.preparedBySummary[summary] ~= preparedValue
		or directDeathOwner.receiptCapabilities[capability.receipt] ~= capability
		or causeCapability.status ~= "Bound"
		or causeCapability.cause ~= capability.cause
		or directDeathOwner.causeCapabilities[capability.cause] ~= causeCapability
		or summary.causeKind ~= causeCapability.kind
		or summary.damageMode ~= causeCapability.damageMode
		or summary.pointContents ~= causeCapability.pointContents
		or summary.publishesDamage ~= causeCapability.publishesDamage
		or summary.means ~= causeCapability.means
		or summary.meansOfDeath ~= causeCapability.meansOfDeath
		or summary.bloodEnabled ~= causeCapability.bloodEnabled
		or summary.noDrop ~= (directDeathOwner.worldPointContents :: any).IsNoDrop(causeCapability.pointContents)
		or handoffCapability.status ~= "Pending"
		or handoffCapability.handoff ~= capability.handoff
		or handoffCapability.summary ~= capability.handoffSummary
		or directDeathOwner.handoffCapabilities[capability.handoff] ~= handoffCapability
		or directDeathOwner.handoffBySummary[capability.handoffSummary] ~= capability.handoff
		or directDeathOwner.handoffByPlayer[mutation.target] ~= nil
		or capability.handoffSummary.target ~= mutation.target
		or capability.handoffSummary.lifeSequence ~= summary.lifeSequence
		or capability.handoffSummary.matchId ~= summary.matchId
		or capability.handoffSummary.matchLineage ~= summary.matchLineage
		or capability.handoffSummary.deathTimeMilliseconds ~= summary.levelTimeMilliseconds
		or capability.handoffSummary.bodyQueueHandle ~= capability.bodyQueueHandles[1]
		or capability.handoffSummary.bodyQueueDeathSummary ~= (capability.bodyQueueSummary :: any).records[1]
		or capability.handoffSummary.corpseTombstone ~= capability.corpseTombstone
		or capability.handoffSummary.preparedCorpseTombstoneSummary ~= capability.corpseTombstoneSummary
		or handoffCapability.target ~= mutation.target
		or handoffCapability.record ~= mutation.record
		or handoffCapability.bodyQueueHandle ~= capability.bodyQueueHandles[1]
		or handoffCapability.bodyQueueDeathSummary ~= (capability.bodyQueueSummary :: any).records[1]
		or handoffCapability.corpseTombstone ~= capability.corpseTombstone
		or handoffCapability.preparedCorpseSource ~= capability.corpseTombstoneSummary.source
		or handoffCapability.movementLifeBinding ~= mutation.beforeMovementLifeBinding
		or handoffCapability.movementLifeSummary ~= capability.movementSummary.lifeSummary
		or handoffCapability.character ~= mutation.beforeCharacter
		or handoffCapability.respawnEligibleAtMilliseconds ~= mutation.afterRespawnEligibleAtMilliseconds
		or handoffCapability.forcedRespawnAtMilliseconds ~= mutation.afterForcedRespawnAtMilliseconds
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(capability.handoff)
		or not table.isfrozen(capability.handoffSummary)
		or not table.isfrozen(mutation)
		or not table.isfrozen(capability.collisionContext)
		or (deathWeaponDrop ~= nil and not table.isfrozen(deathWeaponDrop))
		or (summary.noDrop and deathWeaponDrop ~= nil)
		or (deathWeaponDrop ~= nil and (deathWeaponDrop.matchId ~= summary.matchId or deathWeaponDrop.position ~= capability.movementSummary.callbackEntityTrajectoryBase))
		or capability.deathWeaponDropDecision ~= summary.deathWeaponDropDecision
		or capability.deathWeaponDropOmissionReason ~= summary.deathWeaponDropOmissionReason
		or capability.deathDropInsertionSummary ~= summary.deathDropBatchInsertionSummary
		or summary.deathWeaponDropInsertionSummary ~= (if hasDeathWeaponDrop
			then capability.deathDropInsertionSummary
			else nil)
		or capability.deathWeaponDropDecision ~= (if hasDeathWeaponDrop then "Insert" else "Omit")
		or (hasDeathWeaponDrop and capability.deathWeaponDropOmissionReason ~= nil)
		or (not hasDeathWeaponDrop and capability.deathWeaponDropOmissionReason == nil)
		or (hasDeathDropBatch and (capability.deathDropInsertionAdapter == nil or capability.deathDropInsertionAdapter ~= directDeathOwner.deathDropInsertionAdapter or capability.deathDropInsertionPrepared == nil or capability.deathDropInsertionSummary == nil or capability.deathDropInsertionReceipt ~= nil or capability.deathDropInsertionFlushed))
		or (not hasDeathDropBatch and (capability.deathDropInsertionAdapter ~= nil or capability.deathDropInsertionPrepared ~= nil or capability.deathDropInsertionSummary ~= nil or capability.deathDropInsertionReceipt ~= nil or capability.deathDropInsertionFlushed))
		or powerupDropPlanError ~= nil
		or mutation.afterLastDroppedLifeSequence ~= (if hasDeathWeaponDrop
			then summary.lifeSequence
			else mutation.beforeLastDroppedLifeSequence)
		or not table.isfrozen(capability.bodyQueueHandles)
		or (capability.damagePayload ~= nil and not table.isfrozen(capability.damagePayload))
		or (summary.publishesDamage ~= (capability.damagePayload ~= nil))
		or not table.isfrozen(capability.elimination)
		or not table.isfrozen(capability.eliminationPresentationPlans)
		or mutation.target.Parent ~= Players
		or record ~= mutation.record
		or table.isfrozen(record)
		or record.lifeSequence ~= summary.lifeSequence
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
		or shot.eventSequence ~= mutation.shotEventSequenceBefore
		or shot.id ~= capability.elimination.shotId
		or shot.weaponId ~= capability.elimination.weaponId
		or shot.serverFrame ~= capability.elimination.serverFrame
		or shot.revision ~= capability.elimination.revision
		or capability.elimination.matchId ~= summary.matchId
		or capability.elimination.railCooldownReset ~= mutation.railCooldownReset
		or (mutation.railCooldownReset and (mutation.attackerRecord == nil or mutation.attacker == mutation.target or mutation.afterAttackerWeaponState ~= "Ready" or mutation.afterAttackerWeaponTimeMilliseconds ~= 0))
		or (not mutation.railCooldownReset and (mutation.afterAttackerWeaponState ~= mutation.beforeAttackerWeaponState or mutation.afterAttackerWeaponTimeMilliseconds ~= mutation.beforeAttackerWeaponTimeMilliseconds))
		or shot.matchId ~= summary.matchId
		or (directDeathOwner.projectileCauseKinds[causeCapability.kind] ~= true and shot.levelTimeMilliseconds ~= summary.levelTimeMilliseconds)
		or shot.ownerUserId ~= summary.attackerUserId
		or capability.collisionContext.postDamageHealth ~= summary.postDamageHealth
		or capability.collisionContext.meansOfDeath ~= summary.meansOfDeath
		or capability.collisionContext.bloodEnabled ~= summary.bloodEnabled
		or capability.collisionContext.noDrop ~= summary.noDrop
	then
		return "stale-direct-death-combat-root"
	end
	local attackerRecord = mutation.attackerRecord
	if attackerRecord and mutation.attacker ~= mutation.target then
		if
			mutation.attacker == nil
			or mutation.attacker.Parent ~= Players
			or records[mutation.attacker] ~= attackerRecord
			or attackerRecord.score ~= mutation.beforeAttackerScore
			or attackerRecord.deaths ~= mutation.beforeAttackerDeaths
			or attackerRecord.weaponState ~= mutation.beforeAttackerWeaponState
			or attackerRecord.weaponTimeMilliseconds ~= mutation.beforeAttackerWeaponTimeMilliseconds
		then
			return "stale-direct-death-attacker-root"
		end
	end
	if not checkExternal then
		return nil
	end
	if deathWeaponDrop then
		if
			deathWeaponDrop.dropId
			~= DroppedWeaponRules.MakeDropId(summary.matchId, summary.targetUserId, summary.lifeSequence)
		then
			return "crossed-direct-death-drop-id"
		end
	end
	if hasDeathDropBatch then
		local insertionSummaryError = directDeathOwner.deathDropBatchSummaryError(
			capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter,
			capability.deathDropInsertionPrepared,
			capability.deathDropInsertionSummary,
			capability.deathDropBatchRequests,
			summary.authoritativeFrame,
			summary.authoritativeFrameSummary
		)
		if insertionSummaryError then
			return insertionSummaryError
		end
	end
	if
		directDeathOwner.causeCurrentError(capability.cause, causeCapability, "Bound") ~= nil
		or AuthoritativeFrameService.GetOpenFrame() ~= summary.authoritativeFrame
		or AuthoritativeFrameService.InspectFrame(summary.authoritativeFrame) ~= summary.authoritativeFrameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			summary.authoritativeFrame,
			summary.authoritativeFrameSummary
		)
		or not MatchService.ValidateMatchLineage(summary.matchLineage, summary.matchId)
		or MatchService.GetPlayerScore(mutation.target) ~= mutation.beforeScore
		or MatchService.GetPlayerDeaths(mutation.target) ~= mutation.beforeDeaths
		or (mutation.attackerRecord ~= nil and mutation.attacker ~= mutation.target and (mutation.attacker == nil or MatchService.GetPlayerScore(
			mutation.attacker
		) ~= mutation.beforeAttackerScore or MatchService.GetPlayerDeaths(mutation.attacker) ~= mutation.beforeAttackerDeaths))
		or not MovementService.ValidateMovementLifeBindingDependency(
			mutation.beforeMovementLifeBinding,
			capability.movementSummary.lifeSummary
		)
		or not MovementService.ValidateNormalToDeadSourceDependency(
			capability.attackerSource,
			summary.attackerSourceSummary
		)
		or not MovementService.ValidateNormalToDeadSourceDependency(
			capability.inflictorSource,
			summary.inflictorSourceSummary
		)
	then
		return "stale-direct-death-source-root"
	end

	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	local bodyQueueSummary = capability.bodyQueueSummary :: any
	local bodyQueueHandles = bodyQueueService.InspectPreparedDeathRecordBatchHandles(capability.bodyQueuePrepared)
	local deathSummary = bodyQueueSummary.records and bodyQueueSummary.records[1]
	if
		bodyQueueService.InspectPreparedDeathRecordBatchSummary(capability.bodyQueuePrepared)
			~= capability.bodyQueueSummary
		or bodyQueueHandles ~= capability.bodyQueueHandles
		or #capability.bodyQueueHandles ~= 1
		or not deathSummary
		or not bodyQueueService.ValidatePreparedDeathRecordBatchDependency(
			capability.bodyQueuePrepared,
			capability.bodyQueueSummary
		)
		or deathSummary.matchLineage ~= summary.matchLineage
		or deathSummary.deathTimeMilliseconds ~= summary.levelTimeMilliseconds
		or deathSummary.playerBodyId ~= capability.movementSummary.lifeSummary.playerBodyId
		or deathSummary.playerSourceOrder ~= capability.movementSummary.lifeSummary.playerSourceOrder
		or deathSummary.playerLeaseGeneration ~= capability.movementSummary.lifeSummary.playerLeaseGeneration
		or deathSummary.playerUserId ~= summary.targetUserId
		or deathSummary.lifeSequence ~= summary.lifeSequence
		or (
			capability.matchResult.shouldRespawn
			and mutation.afterRespawnEligibleAtMilliseconds ~= deathSummary.respawnTimeMilliseconds
		)
	then
		return "stale-direct-death-body-queue-dependency"
	end
	if
		MovementService.InspectPreparedNormalToDead(capability.movementPrepared) ~= capability.movementSummary
		or MovementService.InspectPreparedNormalToDeadReceipt(capability.movementPrepared) ~= capability.movementReceipt
		or not MovementService.ValidatePreparedNormalToDeadDependency(
			capability.movementPrepared,
			capability.movementSummary
		)
		or capability.movementSummary.mode ~= "Direct"
		or capability.movementSummary.player ~= mutation.target
		or capability.movementSummary.lifeBinding ~= mutation.beforeMovementLifeBinding
		or capability.movementSummary.lethalVelocityDelta ~= summary.lethalVelocityDelta
		or capability.movementSummary.lethalKnockbackSeconds ~= summary.lethalKnockbackSeconds
		or capability.movementSummary.attackerSource ~= summary.attackerSourceSummary
		or capability.movementSummary.inflictorSource ~= summary.inflictorSourceSummary
	then
		return "stale-direct-death-movement-dependency"
	end
	if
		MatchService.InspectPreparedEliminationBatch(capability.matchPrepared) ~= capability.matchSummary
		or MatchService.InspectPreparedEliminationBatchReceipt(capability.matchPrepared) ~= capability.matchReceipt
		or not MatchService.ValidatePreparedEliminationBatchDependency(
			capability.matchPrepared,
			capability.matchSummary
		)
		or capability.matchSummary.authoritativeFrame ~= summary.authoritativeFrame
		or capability.matchSummary.authoritativeFrameSummary ~= summary.authoritativeFrameSummary
		or capability.matchSummary.matchId ~= summary.matchId
		or capability.matchSummary.matchLineage ~= summary.matchLineage
		or capability.matchSummary.levelTimeMilliseconds ~= summary.levelTimeMilliseconds
		or capability.matchSummary.operationCount ~= 1
		or capability.matchSummary.outcomes[1] ~= capability.matchOutcome
		or not capability.matchOutcome.accepted
	then
		return "stale-direct-death-match-dependency"
	end
	local tombstoneSummary =
		CorpseService.InspectPreparedRespawnCopyTombstoneSummary(capability.corpsePrepared, capability.corpseTombstone)
	local tombstoneSource = capability.corpseTombstoneSummary.source
	if
		tombstoneSummary ~= capability.corpseTombstoneSummary
		or CorpseService.InspectPreparedCommitReceipt(capability.corpsePrepared) ~= capability.corpseReceipt
		or not CorpseService.ValidatePreparedRespawnCopyTombstoneDependency(
			capability.corpsePrepared,
			capability.corpseTombstone,
			capability.corpseTombstoneSummary
		)
		or tombstoneSource.matchId ~= summary.matchId
		or tombstoneSource.matchLineage ~= summary.matchLineage
		or tombstoneSource.playerBodyId ~= capability.deathBody.id
		or tombstoneSource.playerSourceOrder ~= capability.deathBody.sourceOrder
		or tombstoneSource.playerUserId ~= summary.targetUserId
		or tombstoneSource.lifeSequence ~= summary.lifeSequence
		or tombstoneSource.body.position ~= capability.deathBody.position
		or tombstoneSource.body.velocity ~= capability.movementSummary.nextState.velocity
	then
		return "stale-direct-death-corpse-dependency"
	end
	return nil
end

function directDeathOwner.runTwoPassPreflight(
	prepared: PreparedDirectDeath,
	capability: DirectDeathPreparedCapability
): (boolean, string?)
	capability.applyValidated = false
	capability.preflightPassCount = 0
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	for _pass = 1, 2 do
		local currentError = directDeathOwner.preparedCurrentError(prepared, capability, true)
		if currentError then
			capability.preflightPassCount = 0
			return false, currentError
		end
		local bodyQueueCanApply, bodyQueueError =
			bodyQueueService.CanApplyPreparedDeathRecordBatch(capability.bodyQueuePrepared)
		if not bodyQueueCanApply then
			capability.preflightPassCount = 0
			return false, bodyQueueError or "direct-death-body-queue-preflight-failed"
		end
		local movementCanApply, movementError =
			MovementService.CanApplyPreparedNormalToDead(capability.movementPrepared)
		if not movementCanApply then
			capability.preflightPassCount = 0
			return false, movementError or "direct-death-movement-preflight-failed"
		end
		local matchCanApply, matchError = MatchService.CanApplyPreparedEliminationBatch(capability.matchPrepared)
		if not matchCanApply then
			capability.preflightPassCount = 0
			return false, matchError or "direct-death-match-preflight-failed"
		end
		local combatError = directDeathOwner.preparedCurrentError(prepared, capability, false)
		if combatError then
			capability.preflightPassCount = 0
			return false, combatError
		end
		local corpseCanApply, corpseError = CorpseService.CanApplyPrepared(capability.corpsePrepared)
		if not corpseCanApply then
			capability.preflightPassCount = 0
			return false, corpseError or "direct-death-corpse-preflight-failed"
		end
		local deathDropInsertionPrepared = capability.deathDropInsertionPrepared
		if deathDropInsertionPrepared ~= nil then
			local deathDropCanApply, deathDropError = (
				capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter
			).CanApplyPreparedBatch(deathDropInsertionPrepared)
			if not deathDropCanApply then
				capability.preflightPassCount = 0
				return false, deathDropError or "direct-death-drop-insertion-preflight-failed"
			end
		end
		local completedPassError = directDeathOwner.preparedCurrentError(prepared, capability, true)
		if completedPassError then
			capability.preflightPassCount = 0
			return false, completedPassError
		end
		capability.preflightPassCount += 1
	end
	capability.applyValidated = capability.preflightPassCount == 2
	return capability.applyValidated,
		if capability.applyValidated then nil else "direct-death-two-pass-preflight-incomplete"
end

-- Dormant, single-player g_combat.c::player_die coordinator. It accepts only a
-- private opaque cause minted from an exact Combat trace/projectile/world root;
-- raw Players, vectors, means, source handles, collision flags, and no-drop
-- booleans are not part of this public boundary.
function CombatService.PrepareDirectDeath(
	causeValue: unknown
): (PreparedDirectDeath?, PreparedDirectDeathSummary?, string?)
	if directDeathOwner.activePrepared ~= nil then
		return nil, nil, "direct-death-already-prepared"
	end
	if type(causeValue) ~= "table" then
		return nil, nil, "invalid-direct-death-cause"
	end
	local cause = causeValue :: DirectDeathCause
	local causeCapability = directDeathOwner.causeCapabilities[cause]
	if not causeCapability or directDeathOwner.causeCurrentError(cause, causeCapability, "Current") ~= nil then
		return nil, nil, "stale-or-forged-direct-death-cause"
	end
	local target = causeCapability.target
	local attacker = causeCapability.attacker
	local rawDamage = causeCapability.rawDamage
	local direction = causeCapability.direction
	local means = causeCapability.means
	local isSplash = causeCapability.isSplash
	local bypassCombatEligibility = causeCapability.bypassCombatEligibility
	local shot = causeCapability.shot
	local frame = causeCapability.authoritativeFrame
	local frameSummary = causeCapability.authoritativeFrameSummary
	local matchId = causeCapability.matchId
	local matchLineage = causeCapability.matchLineage
	local record = causeCapability.targetRecord
	local lifeBinding = causeCapability.targetLifeBinding
	local lifeSummary = causeCapability.targetLifeSummary
	local currentBody = causeCapability.targetBody
	if record.score ~= MatchService.GetPlayerScore(target) or record.deaths ~= MatchService.GetPlayerDeaths(target) then
		return nil, nil, "stale-direct-death-target-match-mirror"
	end
	if directDeathOwner.handoffByPlayer[target] ~= nil then
		return nil, nil, "direct-death-target-handoff-not-consumed"
	end
	local attackerRecord = causeCapability.attackerRecord
	if attackerRecord then
		if
			attackerRecord.score
				~= MatchService.GetPlayerScore(assert(attacker, "direct-death attacker record has no attacker"))
			or attackerRecord.deaths
				~= MatchService.GetPlayerDeaths(assert(attacker, "direct-death attacker record has no attacker"))
		then
			return nil, nil, "stale-direct-death-attacker-life"
		end
	end
	local adjustedDamage = 0
	local armorSave = 0
	local healthDamage = 0
	local rawPostDamageHealth: number
	if causeCapability.damageMode == "GDamage" then
		if causeCapability.means == "Water" then
			adjustedDamage = rawDamage
			armorSave = 0
			healthDamage = rawDamage
		else
			adjustedDamage, armorSave, healthDamage =
				WeaponDefinitions.ResolveDamage(rawDamage, record.armor, attacker == target)
		end
		healthDamage = assert(
			OneShotRules.ResolveHealthDamage(
				MatchService.GetRules().OneShot,
				attacker ~= nil and MatchService.AreOpponents(attacker, target),
				record.health,
				healthDamage
			),
			"One-Shot prepared direct-death damage input must be valid"
		)
		rawPostDamageHealth = math.max(record.health - healthDamage, MoverConsequenceRules.MinimumClampedQ3Health)
		if adjustedDamage <= 0 or healthDamage <= 0 or rawPostDamageHealth > 0 then
			return nil, nil, "direct-death-damage-is-not-exact-lethal"
		end
	else
		rawPostDamageHealth =
			assert(causeCapability.fixedPostDamageHealth, "player_die cause omitted its fixed post-damage health")
	end
	local lethalVelocityDelta = Vector3.zero
	local lethalKnockbackSeconds: number? = nil
	if causeCapability.damageMode == "GDamage" and direction.Magnitude > 1e-6 then
		local knockbackDamage = math.min(rawDamage, 200)
		local q3Velocity = WeaponDefinitions.Knockback * knockbackDamage / WeaponDefinitions.PlayerMass
		lethalVelocityDelta = direction.Unit * q3Velocity * Constants.UnitsToStuds
		lethalKnockbackSeconds = WeaponDefinitions.KnockbackDurationSeconds(knockbackDamage)
	end
	local collisionContext: DirectDeathCollisionContext = table.freeze({
		postDamageHealth = rawPostDamageHealth,
		meansOfDeath = causeCapability.meansOfDeath,
		bloodEnabled = causeCapability.bloodEnabled,
		noDrop = (directDeathOwner.worldPointContents :: any).IsNoDrop(causeCapability.pointContents),
	})
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	local bodyQueuePrepared, bodyQueueSummary, bodyQueueError = bodyQueueService.PrepareDeathRecordBatch({
		{
			player = target,
			matchLineage = matchLineage,
			deathTimeMilliseconds = frameSummary.currentTimeMilliseconds,
			lifeSequence = record.lifeSequence,
		},
	})
	if not bodyQueuePrepared or not bodyQueueSummary then
		return nil, nil, bodyQueueError or "direct-death-body-queue-prepare-failed"
	end
	local bodyQueueHandles = bodyQueueService.InspectPreparedDeathRecordBatchHandles(bodyQueuePrepared)
	if not bodyQueueHandles or #bodyQueueHandles ~= 1 then
		directDeathOwner.abortChildren(bodyQueuePrepared, nil, nil, nil)
		return nil, nil, "direct-death-body-queue-handle-unavailable"
	end

	local movementPrepared, movementSummary, movementError = MovementService.PrepareNormalToDead(
		lifeBinding,
		lifeSummary,
		lethalVelocityDelta,
		lethalKnockbackSeconds,
		causeCapability.attackerSource,
		causeCapability.attackerSourceSummary,
		causeCapability.inflictorSource,
		causeCapability.inflictorSourceSummary
	)
	if not movementPrepared or not movementSummary then
		directDeathOwner.abortChildren(bodyQueuePrepared, nil, nil, nil)
		return nil, nil, movementError or "direct-death-movement-prepare-failed"
	end
	local movementReceipt = MovementService.InspectPreparedNormalToDeadReceipt(movementPrepared)
	if not movementReceipt then
		local _validMovement, movementDependencyError =
			MovementService.ValidatePreparedNormalToDeadDependency(movementPrepared, movementSummary)
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
		return nil, nil, movementDependencyError or "direct-death-movement-receipt-unavailable"
	end
	local deathWeaponDrop: DeathWeaponDropRequest? = nil
	local deathWeaponDropOmissionReason: DirectDeathWeaponDropOmissionReason? = nil
	if collisionContext.noDrop then
		deathWeaponDropOmissionReason = "NoDrop"
	else
		local buildOmissionReason: DirectDeathWeaponDropOmissionReason? | "MissingAuthoritativeSource"
		deathWeaponDrop, buildOmissionReason = buildDeathWeaponDrop(
			target,
			record,
			means,
			nil,
			nil,
			nil,
			movementSummary.callbackEntityTrajectoryBase,
			movementSummary.callbackEntityAngularTrajectoryBase.look
		)
		if not deathWeaponDrop and buildOmissionReason == "MissingAuthoritativeSource" then
			directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
			return nil, nil, "direct-death-drop-authoritative-source-unavailable"
		end
		deathWeaponDropOmissionReason = buildOmissionReason :: DirectDeathWeaponDropOmissionReason?
	end
	if deathWeaponDrop then
		table.freeze(deathWeaponDrop)
		if
			deathWeaponDrop.matchId ~= matchId
			or deathWeaponDrop.dropId ~= DroppedWeaponRules.MakeDropId(matchId, target.UserId, record.lifeSequence)
		then
			directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
			return nil, nil, "direct-death-drop-match-diverged"
		end
	elseif deathWeaponDropOmissionReason == nil then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
		return nil, nil, "direct-death-drop-decision-incomplete"
	end
	local deathPowerupDropRequests, powerupDropBuildError = directDeathOwner.powerupDropRuntime.BuildRequests({
		targetUserId = target.UserId,
		lifeSequence = record.lifeSequence,
		matchId = matchId,
		position = movementSummary.callbackEntityTrajectoryBase,
		look = movementSummary.callbackEntityAngularTrajectoryBase.look,
		powerupExpiries = record.powerupExpiries,
		levelTimeMilliseconds = frameSummary.currentTimeMilliseconds,
		suppressForTeamDeathmatch = MatchService.GetRules().ModeKind == "TeamDeathmatch",
		suppressForNoDrop = collisionContext.noDrop,
	})
	if not deathPowerupDropRequests then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
		return nil, nil, powerupDropBuildError or "direct-death-powerup-drop-request-build-failed"
	end
	local matchToken, matchBeginError = MatchService.BeginEliminationBatch(frameSummary.currentTimeMilliseconds)
	if not matchToken then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, nil, nil)
		return nil, nil, matchBeginError or "direct-death-match-begin-failed"
	end
	local stagedMatch, matchStageError =
		MatchService.StageElimination(matchToken, target, attacker, means, bypassCombatEligibility)
	if not stagedMatch or not stagedMatch.result.accepted or not stagedMatch.outcome then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, matchStageError or "direct-death-match-elimination-rejected"
	end
	local matchSealed, matchSealError = MatchService.SealEliminationBatch(matchToken)
	if not matchSealed then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, matchSealError or "direct-death-match-seal-failed"
	end
	local matchPrepared, matchPrepareError = MatchService.PrepareEliminationBatch(matchToken)
	if not matchPrepared then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, matchPrepareError or "direct-death-match-prepare-failed"
	end
	local matchSummary = MatchService.InspectPreparedEliminationBatch(matchPrepared)
	local matchReceipt = MatchService.InspectPreparedEliminationBatchReceipt(matchPrepared)
	if
		not matchSummary
		or not matchReceipt
		or matchSummary.operationCount ~= 1
		or matchSummary.outcomes[1] ~= stagedMatch.outcome
		or matchSummary.matchId ~= matchId
		or matchSummary.matchLineage ~= matchLineage
	then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, "direct-death-match-summary-diverged"
	end

	local orderedDeathBodies, deathBodyError = MoverPushRules.ValidateAndOrderBodies({
		{
			id = currentBody.id,
			sourceOrder = currentBody.sourceOrder,
			position = currentBody.position,
			size = currentBody.size,
			centerOffset = currentBody.centerOffset,
			velocity = movementSummary.nextState.velocity,
			groundMoverId = currentBody.groundMoverId,
			contents = currentBody.contents,
			clipMask = currentBody.clipMask,
		},
	})
	local deathBody = orderedDeathBodies and orderedDeathBodies[1]
	if
		not deathBody
		or deathBody.position ~= movementSummary.baseState.position
		or deathBody.id ~= lifeSummary.playerBodyId
		or deathBody.sourceOrder ~= lifeSummary.playerSourceOrder
	then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, deathBodyError or "direct-death-body-diverged"
	end
	local corpseToken, corpseBeginError = CorpseService.Begin()
	if not corpseToken then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, nil)
		return nil, nil, corpseBeginError or "direct-death-corpse-begin-failed"
	end
	local corpseTombstone, tombstoneError = CorpseService.StageRespawnCopyTombstone(corpseToken, target, {
		matchId = matchId,
		matchLineage = matchLineage,
		playerBodyId = lifeSummary.playerBodyId,
		playerSourceOrder = lifeSummary.playerSourceOrder,
		playerLeaseGeneration = lifeSummary.playerLeaseGeneration,
		playerUserId = target.UserId,
		lifeSequence = record.lifeSequence,
		body = deathBody,
	})
	if not corpseTombstone then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, tombstoneError or "direct-death-corpse-tombstone-failed"
	end
	local liveBinding, bindingError = MoverConsequenceRules.ValidateBinding({
		kind = MoverConsequenceRules.BindingKinds.LivePlayer,
		bodyId = deathBody.id,
		playerUserId = target.UserId,
		lifeSequence = record.lifeSequence,
	})
	local corpseEffect, _resolvedCorpseHealth, corpseStageError =
		if liveBinding
			then CorpseService.StageCollision(
				corpseToken,
				target,
				liveBinding,
				deathBody,
				collisionContext.postDamageHealth,
				collisionContext.meansOfDeath,
				collisionContext.bloodEnabled,
				collisionContext.noDrop
			)
			else nil,
		nil,
		bindingError
	if not corpseEffect then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, corpseStageError or "direct-death-corpse-collision-failed"
	end
	local corpseCollection, corpseCollectionError = CorpseService.Collect(corpseToken)
	local corpseBodiesApplied, corpseBodiesError =
		if corpseCollection then CorpseService.ApplyMoverBodies(corpseToken, corpseCollection.bodies) else false,
		corpseCollectionError
	if not corpseBodiesApplied then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, corpseBodiesError or "direct-death-corpse-finalization-failed"
	end
	local corpseSealed, corpseSealError = CorpseService.Seal(corpseToken)
	local corpsePrepared, corpsePrepareError =
		if corpseSealed then CorpseService.Prepare(corpseToken) else nil, corpseSealError
	if not corpsePrepared then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, corpsePrepareError or "direct-death-corpse-prepare-failed"
	end
	local corpseTombstoneSummary =
		CorpseService.InspectPreparedRespawnCopyTombstoneSummary(corpsePrepared, corpseTombstone)
	local corpseReceipt = CorpseService.InspectPreparedCommitReceipt(corpsePrepared)
	if not corpseTombstoneSummary or not corpseReceipt then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, "direct-death-corpse-proof-unavailable"
	end

	local outcome = stagedMatch.outcome
	local matchResult = stagedMatch.result
	local afterRespawnEligibleAt = if matchResult.shouldRespawn
		then MatchFrameRules.DeadlineMilliseconds(frameSummary.currentTimeMilliseconds, matchResult.respawnDelaySeconds)
		else nil
	local forcedRespawnSeconds = MatchService.GetRules().ForcedRespawnSeconds
	local afterForcedRespawnAt = if afterRespawnEligibleAt and forcedRespawnSeconds > 0
		then MatchFrameRules.DeadlineMilliseconds(afterRespawnEligibleAt, forcedRespawnSeconds)
		else nil
	local bodyQueueDeathSummary = (bodyQueueSummary :: any).records[1]
	if not bodyQueueDeathSummary then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, "direct-death-body-queue-summary-unavailable"
	end
	if matchResult.shouldRespawn and (afterRespawnEligibleAt ~= bodyQueueDeathSummary.respawnTimeMilliseconds) then
		directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
		return nil, nil, "direct-death-respawn-deadline-diverged"
	end
	local deathWeaponDropDecision: DirectDeathWeaponDropDecision = if deathWeaponDrop then "Insert" else "Omit"
	local deathDropBatchRequests: { DeathWeaponDropRequest } = {}
	if deathWeaponDrop then
		table.insert(deathDropBatchRequests, deathWeaponDrop)
	end
	for _, powerupDropRequest in deathPowerupDropRequests do
		table.insert(deathDropBatchRequests, powerupDropRequest)
	end
	table.freeze(deathDropBatchRequests)
	local deathDropInsertionAdapter: DeathDropInsertionAdapter? = nil
	local deathDropInsertionPrepared: unknown? = nil
	local deathDropInsertionSummary: unknown? = nil
	if #deathDropBatchRequests > 0 then
		deathDropInsertionAdapter = directDeathOwner.deathDropInsertionAdapter
		if not deathDropInsertionAdapter then
			directDeathOwner.abortChildren(bodyQueuePrepared, movementPrepared, matchToken, corpseToken)
			return nil, nil, "direct-death-drop-insertion-adapter-unavailable"
		end
		local insertionPrepareError: string?
		deathDropInsertionPrepared, deathDropInsertionSummary, insertionPrepareError =
			deathDropInsertionAdapter.PrepareBatch(deathDropBatchRequests, 1, frame, frameSummary)
		if not deathDropInsertionPrepared or not deathDropInsertionSummary then
			directDeathOwner.abortChildren(
				bodyQueuePrepared,
				movementPrepared,
				matchToken,
				corpseToken,
				deathDropInsertionAdapter,
				deathDropInsertionPrepared
			)
			return nil, nil, insertionPrepareError or "direct-death-drop-batch-prepare-failed"
		end
		local insertionSummaryError = directDeathOwner.deathDropBatchSummaryError(
			deathDropInsertionAdapter,
			deathDropInsertionPrepared,
			deathDropInsertionSummary,
			deathDropBatchRequests,
			frame,
			frameSummary
		)
		if insertionSummaryError then
			directDeathOwner.abortChildren(
				bodyQueuePrepared,
				movementPrepared,
				matchToken,
				corpseToken,
				deathDropInsertionAdapter,
				deathDropInsertionPrepared
			)
			return nil, nil, insertionSummaryError
		end
	end
	local afterAttackerScore: number? = nil
	local afterAttackerDeaths: number? = nil
	if attackerRecord and attacker ~= target then
		afterAttackerScore = outcome.attackerScore or attackerRecord.score
		afterAttackerDeaths = attackerRecord.deaths
	end
	local railCooldownReset = OneShotRules.ShouldResetRailCooldown(
		MatchService.GetRules().OneShot,
		if attacker then attacker.UserId else 0,
		target.UserId,
		outcome.scoringUserId,
		shot.weaponId,
		WeaponDefinitions.WeaponId.Railgun
	)
	assert(railCooldownReset ~= nil, "One-Shot Railgun cooldown reset input must be valid")
	local deathEventIncrement = if causeCapability.publishesDamage then 2 else 1
	local mutation: DirectDeathCombatMutation = {
		target = target,
		record = record,
		attacker = attacker,
		attackerRecord = attackerRecord,
		railCooldownReset = railCooldownReset,
		shot = shot,
		shotEventSequenceBefore = shot.eventSequence,
		shotEventSequenceAfter = shot.eventSequence + deathEventIncrement,
		beforeHealth = record.health,
		beforeArmor = record.armor,
		beforeAlive = record.alive,
		beforeScore = record.score,
		beforeDeaths = record.deaths,
		beforeWeaponId = record.weaponId,
		beforeCommandWeaponId = record.commandWeaponId,
		beforeWeaponState = record.weaponState,
		beforeWeaponTimeMilliseconds = record.weaponTimeMilliseconds,
		beforeLastWeaponPmoveLevelTimeMilliseconds = record.lastWeaponPmoveLevelTimeMilliseconds,
		beforeLastPrePmoveGauntletLevelTimeMilliseconds = record.lastPrePmoveGauntletLevelTimeMilliseconds,
		beforeOverstackAccumulator = record.overstackAccumulator,
		beforePowerupExpiries = record.powerupExpiries,
		beforeRespawnEligibleAtMilliseconds = record.respawnEligibleAtMilliseconds,
		beforeForcedRespawnAtMilliseconds = record.forcedRespawnAtMilliseconds,
		beforeManualRespawnQueued = record.manualRespawnQueued,
		beforeRespawnRequested = record.respawnRequested,
		beforeLastDroppedLifeSequence = record.lastDroppedLifeSequence,
		beforeOwnedWeapons = record.ownedWeapons,
		beforeAmmoByWeapon = record.ammoByWeapon,
		beforeInfiniteAmmo = record.infiniteAmmo,
		beforeMovementLifeBinding = lifeBinding,
		beforeCharacter = record.character,
		beforeAttackerScore = if attackerRecord and attacker ~= target then attackerRecord.score else nil,
		beforeAttackerDeaths = if attackerRecord and attacker ~= target then attackerRecord.deaths else nil,
		beforeAttackerWeaponState = if attackerRecord and attacker ~= target then attackerRecord.weaponState else nil,
		beforeAttackerWeaponTimeMilliseconds = if attackerRecord and attacker ~= target
			then attackerRecord.weaponTimeMilliseconds
			else nil,
		afterHealth = 0,
		afterArmor = record.armor - armorSave,
		afterAlive = false,
		afterScore = outcome.victimScore,
		afterDeaths = outcome.victimDeaths,
		afterCommandWeaponId = record.weaponId,
		afterWeaponState = "Ready",
		afterWeaponTimeMilliseconds = 0,
		afterOverstackAccumulator = 0,
		afterPowerupExpiries = {},
		afterRespawnEligibleAtMilliseconds = afterRespawnEligibleAt,
		afterForcedRespawnAtMilliseconds = afterForcedRespawnAt,
		afterManualRespawnQueued = false,
		afterRespawnRequested = false,
		afterLastDroppedLifeSequence = if deathWeaponDrop then record.lifeSequence else record.lastDroppedLifeSequence,
		afterAttackerScore = afterAttackerScore,
		afterAttackerDeaths = afterAttackerDeaths,
		afterAttackerWeaponState = if railCooldownReset
			then "Ready"
			elseif attackerRecord and attacker ~= target then attackerRecord.weaponState
			else nil,
		afterAttackerWeaponTimeMilliseconds = if railCooldownReset
			then 0
			elseif attackerRecord and attacker ~= target then attackerRecord.weaponTimeMilliseconds
			else nil,
	}
	table.freeze(mutation)
	local effectId: string? = nil
	if attacker and attacker ~= target then
		local candidate = attacker:GetAttribute("ArenaEliminationEffectId")
		if type(candidate) == "string" then
			local definition = Catalog.ById[candidate]
			if definition and definition.Slot == "EliminationEffect" then
				effectId = candidate
			end
		end
	end
	local elimination: EliminationEvent = table.freeze({
		kind = "Elimination",
		eventId = WeaponDefinitions.MakeEventId(shot.id, shot.eventSequence + deathEventIncrement),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		revision = shot.revision,
		position = deathBody.position + deathBody.centerOffset,
		targetUserId = target.UserId,
		attackerUserId = if attacker then attacker.UserId else 0,
		scoringUserId = outcome.scoringUserId,
		means = means,
		isSuicide = attacker == target,
		isWorldKill = attacker == nil,
		scoreDelta = outcome.scoreDelta,
		attackerScore = if attackerRecord
			then if attacker == target then outcome.victimScore else outcome.attackerScore or attackerRecord.score
			else 0,
		targetScore = outcome.victimScore,
		targetDeaths = outcome.victimDeaths,
		targetLifeSequence = record.lifeSequence,
		matchId = matchId,
		railCooldownReset = railCooldownReset,
		effectId = effectId,
	})
	local damagePayload: { [string]: any }? = if causeCapability.publishesDamage
		then {
			kind = "Damage",
			eventId = WeaponDefinitions.MakeEventId(shot.id, shot.eventSequence + 1),
			shotId = shot.id,
			weaponId = shot.weaponId,
			serverFrame = shot.serverFrame,
			revision = shot.revision,
			targetUserId = target.UserId,
			attackerUserId = if attacker then attacker.UserId else 0,
			rawDamage = rawDamage,
			adjustedDamage = adjustedDamage,
			damage = healthDamage,
			armorSave = armorSave,
			means = means,
			isSplash = isSplash,
			isSelfDamage = attacker == target,
			killed = true,
			targetHealth = 0,
			targetArmor = mutation.afterArmor,
		}
		else nil
	if damagePayload then
		table.freeze(damagePayload)
	end
	local eliminationEffect = if effectId then Catalog.ById[effectId] else nil
	local eliminationPalette = if eliminationEffect and eliminationEffect.Slot == "EliminationEffect"
		then eliminationEffect.Palette
		else nil
	local eliminationPresentationPlans = EliminationPresentationRules.BuildPlan(eliminationPalette)
	local summary: PreparedDirectDeathSummary = {
		authoritativeFrame = frame,
		authoritativeFrameSummary = frameSummary,
		target = target,
		attacker = attacker,
		targetUserId = target.UserId,
		attackerUserId = if attacker then attacker.UserId else 0,
		lifeSequence = record.lifeSequence,
		matchId = matchId,
		matchLineage = matchLineage,
		levelTimeMilliseconds = frameSummary.currentTimeMilliseconds,
		causeKind = causeCapability.kind,
		damageMode = causeCapability.damageMode,
		pointContents = causeCapability.pointContents,
		publishesDamage = causeCapability.publishesDamage,
		means = means,
		rawDamage = rawDamage,
		adjustedDamage = adjustedDamage,
		armorSave = armorSave,
		healthDamage = healthDamage,
		postDamageHealth = rawPostDamageHealth,
		meansOfDeath = collisionContext.meansOfDeath,
		bloodEnabled = collisionContext.bloodEnabled,
		noDrop = collisionContext.noDrop,
		lethalVelocityDelta = lethalVelocityDelta,
		lethalKnockbackSeconds = lethalKnockbackSeconds,
		attackerSourceSummary = causeCapability.attackerSourceSummary,
		inflictorSourceSummary = causeCapability.inflictorSourceSummary,
		deathWeaponDropDecision = deathWeaponDropDecision,
		deathWeaponDropOmissionReason = deathWeaponDropOmissionReason,
		deathWeaponDropInsertionSummary = if deathWeaponDrop then deathDropInsertionSummary else nil,
		deathPowerupDropCount = #deathPowerupDropRequests,
		deathDropBatchInsertionSummary = deathDropInsertionSummary,
	}
	table.freeze(summary)
	local handoff: DirectDeathHandoff = table.freeze({})
	local handoffSummary: DirectDeathHandoffSummary = {
		target = target,
		targetUserId = target.UserId,
		lifeSequence = record.lifeSequence,
		matchId = matchId,
		matchLineage = matchLineage,
		deathTimeMilliseconds = frameSummary.currentTimeMilliseconds,
		bodyQueueHandle = bodyQueueHandles[1],
		bodyQueueDeathSummary = bodyQueueDeathSummary,
		corpseTombstone = corpseTombstone,
		preparedCorpseTombstoneSummary = corpseTombstoneSummary,
	}
	table.freeze(handoffSummary)
	local handoffCapability: DirectDeathHandoffCapability = {
		handoff = handoff,
		status = "Pending",
		summary = handoffSummary,
		target = target,
		record = record,
		bodyQueueHandle = bodyQueueHandles[1],
		bodyQueueDeathSummary = bodyQueueDeathSummary,
		corpseTombstone = corpseTombstone,
		preparedCorpseSource = corpseTombstoneSummary.source,
		movementLifeBinding = lifeBinding,
		movementLifeSummary = lifeSummary,
		character = record.character,
		respawnEligibleAtMilliseconds = afterRespawnEligibleAt,
		forcedRespawnAtMilliseconds = afterForcedRespawnAt,
	}
	local prepared: PreparedDirectDeath = table.freeze({})
	local receipt: DirectDeathApplyReceipt = table.freeze({})
	local capability: DirectDeathPreparedCapability = {
		prepared = prepared,
		receipt = receipt,
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		cause = cause,
		causeCapability = causeCapability,
		summary = summary,
		mutation = mutation,
		collisionContext = collisionContext,
		deathWeaponDrop = deathWeaponDrop,
		deathWeaponDropDecision = deathWeaponDropDecision,
		deathWeaponDropOmissionReason = deathWeaponDropOmissionReason,
		deathDropInsertionAdapter = deathDropInsertionAdapter,
		deathDropInsertionPrepared = deathDropInsertionPrepared,
		deathDropInsertionSummary = deathDropInsertionSummary,
		deathDropInsertionReceipt = nil,
		deathDropInsertionFlushed = false,
		deathDropBatchRequests = deathDropBatchRequests,
		deathPowerupDropRequests = deathPowerupDropRequests,
		bodyQueuePrepared = bodyQueuePrepared,
		bodyQueueSummary = bodyQueueSummary,
		bodyQueueHandles = bodyQueueHandles,
		movementPrepared = movementPrepared,
		movementSummary = movementSummary,
		movementReceipt = movementReceipt,
		attackerSource = causeCapability.attackerSource,
		inflictorSource = causeCapability.inflictorSource,
		matchToken = matchToken,
		matchPrepared = matchPrepared,
		matchSummary = matchSummary,
		matchReceipt = matchReceipt,
		matchResult = matchResult,
		matchOutcome = outcome,
		corpseToken = corpseToken,
		corpsePrepared = corpsePrepared,
		corpseReceipt = corpseReceipt,
		corpseTombstone = corpseTombstone,
		corpseTombstoneSummary = corpseTombstoneSummary,
		deathBody = deathBody,
		handoff = handoff,
		handoffSummary = handoffSummary,
		handoffCapability = handoffCapability,
		damagePayload = damagePayload,
		elimination = elimination,
		eliminationPresentationPlans = eliminationPresentationPlans,
		corpseAbortComplete = false,
		movementAbortComplete = false,
		bodyQueueAbortComplete = false,
		matchAbortComplete = false,
		deathDropInsertionAbortComplete = deathDropInsertionPrepared == nil,
	}
	local finalCauseError = directDeathOwner.causeCurrentError(cause, causeCapability, "Current")
	if finalCauseError then
		directDeathOwner.abortChildren(
			bodyQueuePrepared,
			movementPrepared,
			matchToken,
			corpseToken,
			deathDropInsertionAdapter,
			deathDropInsertionPrepared
		)
		return nil, nil, finalCauseError
	end
	causeCapability.status = "Bound"
	directDeathOwner.handoffCapabilities[handoff] = handoffCapability
	directDeathOwner.handoffBySummary[handoffSummary] = handoff
	directDeathOwner.preparedCapabilities[prepared] = capability
	directDeathOwner.preparedBySummary[summary] = prepared
	directDeathOwner.receiptCapabilities[receipt] = capability
	directDeathOwner.activePrepared = prepared
	return prepared, summary, nil
end

function CombatService.InspectPreparedDirectDeath(preparedValue: unknown): PreparedDirectDeathSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = directDeathOwner.preparedCapabilities[preparedValue :: PreparedDirectDeath]
	if not capability then
		return nil
	end
	local currentError = directDeathOwner.preparedCurrentError(preparedValue, capability, true)
	if currentError then
		capability.applyValidated = false
		capability.preflightPassCount = 0
		return nil
	end
	return capability.summary
end

function CombatService.ValidatePreparedDirectDeathDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-prepared-direct-death-dependency"
	end
	local prepared = preparedValue :: PreparedDirectDeath
	local summary = summaryValue :: PreparedDirectDeathSummary
	local capability = directDeathOwner.preparedCapabilities[prepared]
	if not capability or capability.summary ~= summary or directDeathOwner.preparedBySummary[summary] ~= prepared then
		return false, "forged-prepared-direct-death-dependency"
	end
	local currentError = directDeathOwner.preparedCurrentError(prepared, capability, true)
	if currentError then
		capability.applyValidated = false
		capability.preflightPassCount = 0
		return false, currentError
	end
	return true, nil
end

function CombatService.CanApplyPreparedDirectDeath(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-direct-death"
	end
	local prepared = preparedValue :: PreparedDirectDeath
	local capability = directDeathOwner.preparedCapabilities[prepared]
	if not capability then
		return false, "invalid-prepared-direct-death"
	end
	return directDeathOwner.runTwoPassPreflight(prepared, capability)
end

function CombatService.ApplyPreparedDirectDeath(preparedValue: unknown): DirectDeathApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-direct-death")
	local prepared = preparedValue :: PreparedDirectDeath
	local capability = assert(directDeathOwner.preparedCapabilities[prepared], "invalid-prepared-direct-death")
	assert(capability.status == "Prepared", "invalid-prepared-direct-death-state")
	local applyReady, applyError = directDeathOwner.runTwoPassPreflight(prepared, capability)
	assert(applyReady, applyError or "prepared-direct-death-not-validated")
	assert(capability.preflightPassCount == 2, "prepared-direct-death-two-pass-proof-missing")

	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	assert(
		bodyQueueService.ApplyPreparedDeathRecordBatch(capability.bodyQueuePrepared) == capability.bodyQueueHandles,
		"direct-death-body-queue-apply-returned-another-handle-array"
	)
	assert(
		MovementService.ApplyPreparedNormalToDead(capability.movementPrepared) == capability.movementReceipt,
		"direct-death-movement-apply-returned-another-receipt"
	)
	assert(
		MatchService.ApplyPreparedEliminationBatch(capability.matchPrepared) == capability.matchReceipt,
		"direct-death-match-apply-returned-another-receipt"
	)
	local applyGapCombatError = directDeathOwner.preparedCurrentError(prepared, capability, false)
	assert(applyGapCombatError == nil, applyGapCombatError or "stale-direct-death-combat-root-in-apply-gap")

	local mutation = capability.mutation
	local record = mutation.record
	record.health = mutation.afterHealth
	record.armor = mutation.afterArmor
	record.alive = mutation.afterAlive
	record.score = mutation.afterScore
	record.deaths = mutation.afterDeaths
	record.commandWeaponId = mutation.afterCommandWeaponId
	record.weaponState = mutation.afterWeaponState
	record.weaponTimeMilliseconds = mutation.afterWeaponTimeMilliseconds
	record.overstackAccumulator = mutation.afterOverstackAccumulator
	record.powerupExpiries = mutation.afterPowerupExpiries
	record.respawnEligibleAtMilliseconds = mutation.afterRespawnEligibleAtMilliseconds
	record.forcedRespawnAtMilliseconds = mutation.afterForcedRespawnAtMilliseconds
	record.manualRespawnQueued = mutation.afterManualRespawnQueued
	record.respawnRequested = mutation.afterRespawnRequested
	record.lastDroppedLifeSequence = mutation.afterLastDroppedLifeSequence
	local attackerRecord = mutation.attackerRecord
	if attackerRecord and mutation.attacker ~= mutation.target then
		attackerRecord.score = assert(mutation.afterAttackerScore, "direct-death attacker score plan disappeared")
		attackerRecord.deaths = assert(mutation.afterAttackerDeaths, "direct-death attacker deaths plan disappeared")
		attackerRecord.weaponState =
			assert(mutation.afterAttackerWeaponState, "direct-death attacker weapon-state plan disappeared")
		attackerRecord.weaponTimeMilliseconds =
			assert(mutation.afterAttackerWeaponTimeMilliseconds, "direct-death attacker weapon-time plan disappeared")
	end
	mutation.shot.eventSequence = mutation.shotEventSequenceAfter
	local handoffCapability = capability.handoffCapability
	assert(handoffCapability.status == "Pending", "direct-death handoff is not pending")
	assert(
		directDeathOwner.handoffByPlayer[mutation.target] == nil,
		"direct-death target already has a current handoff"
	)
	handoffCapability.status = "Current"
	directDeathOwner.handoffByPlayer[mutation.target] = capability.handoff

	assert(
		CorpseService.ApplyPrepared(capability.corpsePrepared) == capability.corpseReceipt,
		"direct-death-corpse-apply-returned-another-receipt"
	)
	local deathDropInsertionPrepared = capability.deathDropInsertionPrepared
	if deathDropInsertionPrepared ~= nil then
		capability.deathDropInsertionReceipt = (capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter).ApplyPreparedBatch(
			deathDropInsertionPrepared
		)
		assert(capability.deathDropInsertionReceipt ~= nil, "direct-death-drop-insertion-apply-omitted-receipt")
	end
	capability.status = "Applied"
	capability.applyValidated = false
	capability.preflightPassCount = 0
	return capability.receipt
end

function CombatService.ValidateAppliedDirectDeathDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-applied-direct-death-dependency"
	end
	local receipt = receiptValue :: DirectDeathApplyReceipt
	local summary = summaryValue :: PreparedDirectDeathSummary
	local capability = directDeathOwner.receiptCapabilities[receipt]
	if
		not capability
		or capability.receipt ~= receipt
		or capability.summary ~= summary
		or capability.status ~= "Applied"
		or capability.causeCapability.status ~= "Bound"
		or capability.causeCapability.cause ~= capability.cause
		or directDeathOwner.causeCapabilities[capability.cause] ~= capability.causeCapability
	then
		return false, "forged-applied-direct-death-dependency"
	end
	local handoffError = directDeathOwner.handoffCurrentError(capability.handoff, capability.handoffCapability)
	if handoffError then
		return false, handoffError
	end
	local mutation = capability.mutation
	local record = records[mutation.target]
	if
		record ~= mutation.record
		or not table.isfrozen(capability.deathPowerupDropRequests)
		or not table.isfrozen(capability.deathDropBatchRequests)
		or summary.deathPowerupDropCount ~= #capability.deathPowerupDropRequests
		or #capability.deathDropBatchRequests ~= #capability.deathPowerupDropRequests + (if capability.deathWeaponDrop
			then 1
			else 0)
		or record.health ~= mutation.afterHealth
		or record.armor ~= mutation.afterArmor
		or record.alive ~= mutation.afterAlive
		or record.score ~= mutation.afterScore
		or record.deaths ~= mutation.afterDeaths
		or record.weaponId ~= mutation.beforeWeaponId
		or record.commandWeaponId ~= mutation.afterCommandWeaponId
		or record.weaponState ~= mutation.afterWeaponState
		or record.weaponTimeMilliseconds ~= mutation.afterWeaponTimeMilliseconds
		or record.lastWeaponPmoveLevelTimeMilliseconds ~= mutation.beforeLastWeaponPmoveLevelTimeMilliseconds
		or record.lastPrePmoveGauntletLevelTimeMilliseconds ~= mutation.beforeLastPrePmoveGauntletLevelTimeMilliseconds
		or record.overstackAccumulator ~= mutation.afterOverstackAccumulator
		or record.powerupExpiries ~= mutation.afterPowerupExpiries
		or record.respawnEligibleAtMilliseconds ~= mutation.afterRespawnEligibleAtMilliseconds
		or record.forcedRespawnAtMilliseconds ~= mutation.afterForcedRespawnAtMilliseconds
		or record.manualRespawnQueued ~= mutation.afterManualRespawnQueued
		or record.respawnRequested ~= mutation.afterRespawnRequested
		or record.lastDroppedLifeSequence ~= mutation.afterLastDroppedLifeSequence
		or record.ownedWeapons ~= mutation.beforeOwnedWeapons
		or record.ammoByWeapon ~= mutation.beforeAmmoByWeapon
		or record.infiniteAmmo ~= mutation.beforeInfiniteAmmo
		or record.movementLifeBinding ~= mutation.beforeMovementLifeBinding
		or record.character ~= mutation.beforeCharacter
		or mutation.shot.eventSequence ~= mutation.shotEventSequenceAfter
		or MatchService.GetPlayerScore(mutation.target) ~= mutation.afterScore
		or MatchService.GetPlayerDeaths(mutation.target) ~= mutation.afterDeaths
	then
		return false, "stale-applied-direct-death-combat-root"
	end
	local attackerRecord = mutation.attackerRecord
	if attackerRecord and mutation.attacker ~= mutation.target then
		if
			mutation.attacker == nil
			or records[mutation.attacker] ~= attackerRecord
			or attackerRecord.score ~= mutation.afterAttackerScore
			or attackerRecord.deaths ~= mutation.afterAttackerDeaths
			or attackerRecord.weaponState ~= mutation.afterAttackerWeaponState
			or attackerRecord.weaponTimeMilliseconds ~= mutation.afterAttackerWeaponTimeMilliseconds
			or MatchService.GetPlayerScore(mutation.attacker) ~= mutation.afterAttackerScore
			or MatchService.GetPlayerDeaths(mutation.attacker) ~= mutation.afterAttackerDeaths
		then
			return false, "stale-applied-direct-death-attacker-root"
		end
	end
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	local bodyQueueSummary = capability.bodyQueueSummary :: any
	local deathSummary = bodyQueueSummary.records and bodyQueueSummary.records[1]
	if
		not deathSummary
		or #capability.bodyQueueHandles ~= 1
		or not bodyQueueService.ValidateDeathHandleDependency(capability.bodyQueueHandles[1], deathSummary)
	then
		return false, "stale-applied-direct-death-body-queue-root"
	end
	if
		not MovementService.ValidateAppliedNormalToDeadRootDependency(
			capability.movementReceipt,
			capability.movementSummary
		)
	then
		return false, "stale-applied-direct-death-movement-root"
	end
	local tombstoneData = CorpseService.InspectRespawnCopyTombstone(capability.corpseTombstone)
	if
		tombstoneData ~= capability.corpseTombstoneSummary.source
		or tombstoneData.matchId ~= summary.matchId
		or tombstoneData.matchLineage ~= summary.matchLineage
		or tombstoneData.playerBodyId ~= capability.deathBody.id
		or tombstoneData.playerSourceOrder ~= capability.deathBody.sourceOrder
		or tombstoneData.playerUserId ~= summary.targetUserId
		or tombstoneData.lifeSequence ~= summary.lifeSequence
		or tombstoneData.body.position ~= capability.deathBody.position
		or tombstoneData.body.velocity ~= capability.movementSummary.nextState.velocity
	then
		return false, "stale-applied-direct-death-corpse-root"
	end
	local deathDropInsertionPrepared = capability.deathDropInsertionPrepared
	if deathDropInsertionPrepared ~= nil then
		local deathDropInsertionReceipt = capability.deathDropInsertionReceipt
		if deathDropInsertionReceipt == nil or capability.deathDropInsertionFlushed then
			return false, "stale-applied-direct-death-drop-insertion-receipt"
		end
		local itemApplied, itemAppliedError = (capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter).ValidateAppliedBatchDependency(
			deathDropInsertionReceipt,
			capability.deathDropInsertionSummary
		)
		if not itemApplied then
			return false, itemAppliedError or "stale-applied-direct-death-drop-insertion-root"
		end
	elseif capability.deathDropInsertionReceipt ~= nil or capability.deathDropInsertionFlushed then
		return false, "unexpected-applied-direct-death-drop-insertion"
	end
	return true, nil
end

-- Movement and Match receive PlayerRemoving before Combat. This validator is
-- deliberately narrower than a blanket stale-proof bypass: it is admitted only
-- for the exact target/attacker being removed and waives only that participant's
-- already-retired Movement/Match projection while retaining every other owner.
function directDeathOwner.appliedDepartureError(
	capability: DirectDeathPreparedCapability,
	departingPlayer: Player
): string?
	local mutation = capability.mutation
	local target = mutation.target
	local attacker = mutation.attacker
	if departingPlayer ~= target and departingPlayer ~= attacker then
		return "unrelated-direct-death-departure"
	end
	if
		capability.status ~= "Applied"
		or directDeathOwner.activePrepared ~= capability.prepared
		or directDeathOwner.preparedCapabilities[capability.prepared] ~= capability
		or directDeathOwner.receiptCapabilities[capability.receipt] ~= capability
		or capability.causeCapability.status ~= "Bound"
		or directDeathOwner.causeCapabilities[capability.cause] ~= capability.causeCapability
		or capability.handoffCapability.status ~= "Current"
		or directDeathOwner.handoffCapabilities[capability.handoff] ~= capability.handoffCapability
		or directDeathOwner.handoffByPlayer[target] ~= capability.handoff
		or directDeathOwner.handoffBySummary[capability.handoffSummary] ~= capability.handoff
		or not MatchService.ValidateMatchLineage(capability.summary.matchLineage, capability.summary.matchId)
	then
		return "stale-applied-direct-death-departure-owner"
	end
	local record = records[target]
	if
		record ~= mutation.record
		or record.health ~= mutation.afterHealth
		or record.armor ~= mutation.afterArmor
		or record.alive ~= mutation.afterAlive
		or record.score ~= mutation.afterScore
		or record.deaths ~= mutation.afterDeaths
		or record.weaponId ~= mutation.beforeWeaponId
		or record.commandWeaponId ~= mutation.afterCommandWeaponId
		or record.weaponState ~= mutation.afterWeaponState
		or record.weaponTimeMilliseconds ~= mutation.afterWeaponTimeMilliseconds
		or record.lastWeaponPmoveLevelTimeMilliseconds ~= mutation.beforeLastWeaponPmoveLevelTimeMilliseconds
		or record.lastPrePmoveGauntletLevelTimeMilliseconds ~= mutation.beforeLastPrePmoveGauntletLevelTimeMilliseconds
		or record.overstackAccumulator ~= mutation.afterOverstackAccumulator
		or record.powerupExpiries ~= mutation.afterPowerupExpiries
		or record.respawnEligibleAtMilliseconds ~= mutation.afterRespawnEligibleAtMilliseconds
		or record.forcedRespawnAtMilliseconds ~= mutation.afterForcedRespawnAtMilliseconds
		or record.manualRespawnQueued ~= mutation.afterManualRespawnQueued
		or record.respawnRequested ~= mutation.afterRespawnRequested
		or record.lastDroppedLifeSequence ~= mutation.afterLastDroppedLifeSequence
		or record.ownedWeapons ~= mutation.beforeOwnedWeapons
		or record.ammoByWeapon ~= mutation.beforeAmmoByWeapon
		or record.infiniteAmmo ~= mutation.beforeInfiniteAmmo
		or record.movementLifeBinding ~= mutation.beforeMovementLifeBinding
		or record.character ~= mutation.beforeCharacter
		or mutation.shot.eventSequence ~= mutation.shotEventSequenceAfter
		or (
			departingPlayer ~= target
			and (
				MatchService.GetPlayerScore(target) ~= mutation.afterScore
				or MatchService.GetPlayerDeaths(target) ~= mutation.afterDeaths
			)
		)
	then
		return "stale-applied-direct-death-departure-combat"
	end
	local attackerRecord = mutation.attackerRecord
	if attackerRecord and attacker ~= target then
		if
			not attacker
			or records[attacker] ~= attackerRecord
			or attackerRecord.score ~= mutation.afterAttackerScore
			or attackerRecord.deaths ~= mutation.afterAttackerDeaths
			or attackerRecord.weaponState ~= mutation.afterAttackerWeaponState
			or attackerRecord.weaponTimeMilliseconds ~= mutation.afterAttackerWeaponTimeMilliseconds
			or (
				departingPlayer ~= attacker
				and (
					MatchService.GetPlayerScore(attacker) ~= mutation.afterAttackerScore
					or MatchService.GetPlayerDeaths(attacker) ~= mutation.afterAttackerDeaths
				)
			)
		then
			return "stale-applied-direct-death-departure-attacker"
		end
	end
	local bodyQueueSummary = capability.bodyQueueSummary :: any
	local deathSummary = bodyQueueSummary.records and bodyQueueSummary.records[1]
	local bodyQueueService = directDeathOwner.bodyQueueService :: any
	if
		not deathSummary
		or #capability.bodyQueueHandles ~= 1
		or not bodyQueueService.ValidateDeathHandleDependency(capability.bodyQueueHandles[1], deathSummary)
		or (
			departingPlayer ~= target
			and not MovementService.ValidateAppliedNormalToDeadRootDependency(
				capability.movementReceipt,
				capability.movementSummary
			)
		)
	then
		return "stale-applied-direct-death-departure-child"
	end
	local tombstoneData = CorpseService.InspectRespawnCopyTombstone(capability.corpseTombstone)
	if
		not tombstoneData
		or tombstoneData.matchId ~= capability.summary.matchId
		or tombstoneData.matchLineage ~= capability.summary.matchLineage
		or tombstoneData.playerBodyId ~= capability.deathBody.id
		or tombstoneData.playerSourceOrder ~= capability.deathBody.sourceOrder
		or tombstoneData.playerUserId ~= capability.summary.targetUserId
		or tombstoneData.lifeSequence ~= capability.summary.lifeSequence
		or tombstoneData.body.position ~= capability.deathBody.position
		or tombstoneData.body.velocity ~= capability.movementSummary.nextState.velocity
	then
		return "stale-applied-direct-death-departure-corpse"
	end
	if capability.deathDropInsertionPrepared ~= nil then
		local deathDropInsertionReceipt = capability.deathDropInsertionReceipt
		if deathDropInsertionReceipt == nil or capability.deathDropInsertionFlushed then
			return "stale-applied-direct-death-departure-drop-receipt"
		end
		local itemApplied, itemAppliedError = (capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter).ValidateAppliedBatchDependency(
			deathDropInsertionReceipt,
			capability.deathDropInsertionSummary
		)
		if not itemApplied then
			return itemAppliedError or "stale-applied-direct-death-departure-drop-root"
		end
	elseif capability.deathDropInsertionReceipt ~= nil or capability.deathDropInsertionFlushed then
		return "unexpected-applied-direct-death-departure-drop"
	end
	return nil
end

-- This is the durable per-life join consumed by the future authoritative
-- respawn composite. It exposes only opaque BodyQueue/Corpse capabilities and
-- their frozen summaries; neither child may be discovered independently.
function CombatService.GetDirectDeathHandoff(playerValue: unknown): DirectDeathHandoff?
	if typeof(playerValue) ~= "Instance" or not (playerValue :: Instance):IsA("Player") then
		return nil
	end
	local player = playerValue :: Player
	local handoff = directDeathOwner.handoffByPlayer[player]
	local capability = handoff and directDeathOwner.handoffCapabilities[handoff]
	if not handoff or not capability or directDeathOwner.handoffCurrentError(handoff, capability) then
		return nil
	end
	return handoff
end

function CombatService.InspectDirectDeathHandoff(handoffValue: unknown): DirectDeathHandoffSummary?
	if type(handoffValue) ~= "table" then
		return nil
	end
	local handoff = handoffValue :: DirectDeathHandoff
	local capability = directDeathOwner.handoffCapabilities[handoff]
	if not capability or directDeathOwner.handoffCurrentError(handoff, capability) then
		return nil
	end
	return capability.summary
end

function CombatService.ValidateDirectDeathHandoffDependency(
	handoffValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(handoffValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-direct-death-handoff-dependency"
	end
	local handoff = handoffValue :: DirectDeathHandoff
	local summary = summaryValue :: DirectDeathHandoffSummary
	local capability = directDeathOwner.handoffCapabilities[handoff]
	if not capability or capability.summary ~= summary or directDeathOwner.handoffBySummary[summary] ~= handoff then
		return false, "forged-direct-death-handoff-dependency"
	end
	local currentError = directDeathOwner.handoffCurrentError(handoff, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function CombatService.AbortPreparedDirectDeath(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-direct-death"
	end
	local prepared = preparedValue :: PreparedDirectDeath
	local capability = directDeathOwner.preparedCapabilities[prepared]
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-prepared-direct-death"
	end
	capability.applyValidated = false
	capability.preflightPassCount = 0
	if not capability.deathDropInsertionAbortComplete then
		local deathDropInsertionPrepared = capability.deathDropInsertionPrepared
		local deathDropInsertionAdapter = capability.deathDropInsertionAdapter
		if deathDropInsertionPrepared ~= nil and deathDropInsertionAdapter ~= nil then
			capability.deathDropInsertionAbortComplete =
				select(1, deathDropInsertionAdapter.AbortPreparedBatch(deathDropInsertionPrepared))
		end
	end
	if not capability.corpseAbortComplete then
		capability.corpseAbortComplete = CorpseService.Abort(capability.corpseToken)
	end
	if not capability.movementAbortComplete then
		capability.movementAbortComplete = MovementService.AbortPreparedNormalToDead(capability.movementPrepared)
		if not capability.movementAbortComplete then
			capability.movementAbortComplete = select(
				1,
				MovementService.ValidateRetiredPreparedNormalToDeadDependency(
					capability.movementPrepared,
					capability.movementSummary
				)
			)
		end
	end
	if not capability.bodyQueueAbortComplete then
		local bodyQueueService = directDeathOwner.bodyQueueService :: any
		capability.bodyQueueAbortComplete = bodyQueueService.AbortPreparedDeathRecordBatch(capability.bodyQueuePrepared)
	end
	if not capability.matchAbortComplete then
		capability.matchAbortComplete = MatchService.AbortEliminationBatch(capability.matchToken)
	end
	local childrenAborted = capability.deathDropInsertionAbortComplete
		and capability.corpseAbortComplete
		and capability.movementAbortComplete
		and capability.bodyQueueAbortComplete
		and capability.matchAbortComplete
	if not childrenAborted then
		return false, "direct-death-child-abort-incomplete"
	end
	capability.status = "Aborted"
	directDeathOwner.retireCauseCapability(capability.causeCapability)
	directDeathOwner.retireHandoffCapability(capability.handoffCapability)
	directDeathOwner.activePrepared = nil
	directDeathOwner.preparedCapabilities[prepared] = nil
	directDeathOwner.preparedBySummary[capability.summary] = nil
	directDeathOwner.receiptCapabilities[capability.receipt] = nil
	return true, nil
end

function directDeathOwner.flushAppliedPublication(
	capability: DirectDeathPreparedCapability,
	requireCurrentDependency: boolean
): DirectDeathPublicationReport
	local receipt = capability.receipt
	if requireCurrentDependency then
		assert(
			CombatService.ValidateAppliedDirectDeathDependency(receipt, capability.summary),
			"stale-applied-direct-death-before-flush"
		)
	end
	local publicationCount = 0
	local publicationFaultCount = 0
	local powerupDropRequestedCount = #capability.deathPowerupDropRequests
	local powerupDropInsertedCount = 0
	local powerupDropFaultCount = 0
	local batchRequestedCount = #capability.deathDropBatchRequests
	if capability.deathDropInsertionPrepared ~= nil then
		local deathDropInsertionReceipt =
			assert(capability.deathDropInsertionReceipt, "direct-death drop insertion receipt disappeared before flush")
		assert(not capability.deathDropInsertionFlushed, "direct-death drop insertion flushed twice")
		local itemReport, itemFlushError = (capability.deathDropInsertionAdapter :: DeathDropInsertionAdapter).FlushPreparedBatch(
			deathDropInsertionReceipt
		)
		assert(itemReport, itemFlushError or "direct-death drop batch flush failed")
		assert(itemReport.authorityApplied, "direct-death drop batch denied applied authority")
		assert(
			itemReport.requestedCount == batchRequestedCount and itemReport.insertedCount == itemReport.requestedCount,
			"direct-death drop batch committed fewer records than requested"
		)
		capability.deathDropInsertionFlushed = true
		publicationCount += itemReport.attemptedPublicationCount
		publicationFaultCount += itemReport.faultCount
		powerupDropInsertedCount = itemReport.insertedCount - (if capability.deathWeaponDrop then 1 else 0)
		powerupDropFaultCount = if powerupDropRequestedCount > 0 then itemReport.faultCount else 0
	end
	assert(
		powerupDropInsertedCount == powerupDropRequestedCount,
		"direct-death timed-powerup batch omitted a requested drop"
	)
	local function publish(label: string, callback: () -> ())
		publicationCount += 1
		local succeeded, failure = xpcall(callback, debug.traceback)
		if not succeeded then
			publicationFaultCount += 1
			warn("Direct death publication failed after authority applied", label, failure)
		end
	end
	local matchReceipt = capability.matchReceipt
	publish("MatchAttributes", function()
		local report, flushError = MatchService.FlushPreparedEliminationAttributes(matchReceipt)
		if not report then
			error(flushError or "direct-death Match attribute publication failed")
		end
		publicationCount += report.attemptedPublicationCount
		publicationFaultCount += report.faultCount
	end)
	publish("CombatVictimQuery", function()
		setCharacterCombatQuery(capability.mutation.record.character, false)
	end)
	local mutation = capability.mutation
	if mutation.attacker and mutation.attacker ~= mutation.target then
		publish("CombatAttackerState", function()
			publishPlayerRecord(
				assert(mutation.attacker, "direct-death attacker disappeared"),
				assert(mutation.attackerRecord, "direct-death attacker publication record disappeared")
			)
		end)
	end
	publish("CombatVictimState", function()
		publishPlayerRecord(mutation.target, mutation.record)
	end)
	if capability.damagePayload then
		publish("DamageEvent", function()
			broadcast(capability.damagePayload)
		end)
	end
	publish("EliminationObserver", function()
		CombatFramePublicationService.Queue(function()
			eliminationSignal:Fire(capability.elimination)
		end)
	end)
	publish("EliminationRemote", function()
		broadcast(capability.elimination :: any)
	end)
	for planIndex, plan in capability.eliminationPresentationPlans do
		publish(string.format("EliminationPresentation:%d", planIndex), function()
			createEliminationOrb(capability.elimination.position, plan)
		end)
	end
	publish("HumanoidProjection", function()
		local character = MovementService.GetCharacter(capability.mutation.target)
		CombatFramePublicationService.Queue(function()
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end)
	end)
	publish("MatchObservers", function()
		local report, flushError = MatchService.FlushPreparedEliminationObservers(matchReceipt)
		if not report then
			error(flushError or "direct-death Match observer publication failed")
		end
		publicationCount += report.attemptedPublicationCount
		publicationFaultCount += report.faultCount
	end)
	capability.status = "Flushed"
	directDeathOwner.retireCauseCapability(capability.causeCapability)
	directDeathOwner.activePrepared = nil
	directDeathOwner.preparedCapabilities[capability.prepared] = nil
	directDeathOwner.preparedBySummary[capability.summary] = nil
	directDeathOwner.receiptCapabilities[receipt] = nil
	local report: DirectDeathPublicationReport = {
		authorityApplied = true,
		publicationCount = publicationCount,
		publicationFaultCount = publicationFaultCount,
		powerupDropRequestedCount = powerupDropRequestedCount,
		powerupDropInsertedCount = powerupDropInsertedCount,
		powerupDropFaultCount = powerupDropFaultCount,
	}
	table.freeze(report)
	return report
end

function CombatService.FlushPreparedDirectDeath(receiptValue: unknown): DirectDeathPublicationReport
	assert(type(receiptValue) == "table", "invalid-direct-death-receipt")
	local receipt = receiptValue :: DirectDeathApplyReceipt
	local capability = assert(directDeathOwner.receiptCapabilities[receipt], "invalid-direct-death-receipt")
	assert(capability.status == "Applied", "invalid-direct-death-receipt-state")
	return directDeathOwner.flushAppliedPublication(capability, true)
end

type ClientCorpseDamageResult = {
	read removed: boolean,
	read armorSave: number,
	read healthDamage: number,
	read beforeHealth: number,
	read afterHealth: number,
}

-- The immediate Q3 corpse is still the client gentity: MASK_SHOT can reach it,
-- CheckArmor still consumes the retained client armor, and body_die may unlink
-- it without running player_die or scoring again. This direct, no-yield
-- path is shared by ordinary weapon/projectile/splash traces. The retained
-- Combat armor scalar and Corpse root join one no-yield prepared boundary;
-- mover callbacks use the larger fixed-step shadow transaction below.
local function applyClientCorpseDamage(
	target: Player,
	attacker: Player?,
	expectedBodyId: string,
	rawDamage: number,
	_direction: Vector3,
	means: string,
	isSplash: boolean,
	shot: ShotContext
): (ClientCorpseDamageResult?, string?)
	local record = records[target]
	if
		not record
		or record.alive
		or record.health ~= 0
		or type(expectedBodyId) ~= "string"
		or expectedBodyId == ""
		or not isFinite(rawDamage)
		or rawDamage <= 0
		or not MatchService.CanAuthorizedAttackDamageCorpse(attacker, target, shot.matchId)
	then
		return nil, "client-corpse-damage-not-authorized"
	end

	local token, beginError = CorpseService.Begin()
	if not token then
		return nil, beginError or "client-corpse-transaction-unavailable"
	end
	local function abortWith(message: string): (ClientCorpseDamageResult?, string?)
		assert(CorpseService.Abort(token), "client-corpse damage transaction did not abort")
		return nil, message
	end

	local collection, collectionError = CorpseService.Collect(token)
	if not collection then
		return abortWith(collectionError or "client-corpse-collection-unavailable")
	end
	local body: MoverPushRules.Body? = nil
	for _, candidate in collection.bodies do
		if candidate.id == expectedBodyId then
			body = candidate
			break
		end
	end
	if not body or collection.playersByBodyId[expectedBodyId] ~= target then
		return abortWith("stale-client-corpse-shot-target")
	end
	local binding = CorpseService.GetBinding(token, target, expectedBodyId)
	local beforeCorpseHealth = CorpseService.GetHealth(token, target, expectedBodyId)
	if
		not binding
		or binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
		or binding.lifeSequence ~= record.lifeSequence
		or beforeCorpseHealth == nil
	then
		return abortWith("stale-client-corpse-shot-binding")
	end

	local beforeArmor = record.armor
	local adjustedDamage, armorSave, healthDamage =
		WeaponDefinitions.ResolveDamage(rawDamage, beforeArmor, attacker == target)
	if adjustedDamage <= 0 then
		return abortWith("client-corpse-damage-empty")
	end
	local afterArmor = beforeArmor - armorSave
	local postDamageHealth =
		math.max(beforeCorpseHealth - healthDamage, MoverConsequenceRules.MinimumRawPostDamageHealth)
	local effect, resolvedHealth, stageError = CorpseService.StageCollision(
		token,
		target,
		binding,
		body,
		postDamageHealth,
		MoverConsequenceRules.MeansOfDeath.Ordinary,
		true,
		false
	)
	if not effect or resolvedHealth == nil then
		return abortWith(stageError or "client-corpse-shot-stage-failed")
	end
	local finalCollection, finalCollectionError = CorpseService.Collect(token)
	if not finalCollection then
		return abortWith(finalCollectionError or "client-corpse-final-collection-failed")
	end
	local appliedBodies, applyBodiesError = CorpseService.ApplyMoverBodies(token, finalCollection.bodies)
	if not appliedBodies then
		return abortWith(applyBodiesError or "client-corpse-final-bodies-failed")
	end
	local sealed, sealError = CorpseService.Seal(token)
	if not sealed then
		return abortWith(sealError or "client-corpse-shot-seal-failed")
	end
	local prepared, prepareError = CorpseService.Prepare(token)
	if not prepared then
		return abortWith(prepareError or "client-corpse-shot-prepare-failed")
	end
	if
		records[target] ~= record
		or table.isfrozen(record)
		or record.alive
		or record.health ~= 0
		or record.armor ~= beforeArmor
		or record.lifeSequence ~= binding.lifeSequence
	then
		return abortWith("client-corpse-combat-state-changed")
	end

	-- Reserve every identifier and build every caller/publication artifact before
	-- either owner enters its apply boundary. These frozen values remain the
	-- successful authority result even if outward publication later faults.
	local damageEventId = nextEventId(shot)
	local damagePayload: { [string]: any } = {
		kind = "Damage",
		eventId = damageEventId,
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		revision = shot.revision,
		targetUserId = target.UserId,
		attackerUserId = if attacker then attacker.UserId else 0,
		rawDamage = rawDamage,
		adjustedDamage = adjustedDamage,
		damage = healthDamage,
		armorSave = armorSave,
		means = means,
		isSplash = isSplash,
		isSelfDamage = attacker == target,
		killed = false,
		targetHealth = 0,
		targetArmor = afterArmor,
	}
	table.freeze(damagePayload)
	local result: ClientCorpseDamageResult = {
		removed = effect.kind == "Remove",
		armorSave = armorSave,
		healthDamage = healthDamage,
		beforeHealth = beforeCorpseHealth,
		afterHealth = postDamageHealth,
	}
	table.freeze(result)
	local function publishClientCorpsePlayerState()
		syncPlayer(target)
	end
	local function publishClientCorpseDamageEvent()
		broadcast(damagePayload)
	end

	local corpseCanApply, corpseCanApplyError = CorpseService.CanApplyPrepared(prepared)
	if not corpseCanApply then
		return abortWith(corpseCanApplyError or "client-corpse-shot-preflight-failed")
	end
	if
		records[target] ~= record
		or table.isfrozen(record)
		or record.alive
		or record.health ~= 0
		or record.armor ~= beforeArmor
		or record.lifeSequence ~= binding.lifeSequence
	then
		return abortWith("client-corpse-combat-state-changed-after-preflight")
	end

	-- Every fallible check, allocation, and callback has completed. Corpse's
	-- apply repeats only allocation-free lineage checks before its root swap;
	-- this scalar assignment is the no-failure Combat participant. Keep both
	-- authority assignments adjacent and publish only after both have applied.
	CorpseService.ApplyPrepared(prepared)
	record.armor = afterArmor

	-- Publication is not authority. Attempt each channel independently so one
	-- failure cannot suppress the other or make the caller retry committed
	-- damage. Diagnostics deliberately do not roll either owner back.
	local playerStatePublished, playerStatePublicationError = xpcall(publishClientCorpsePlayerState, debug.traceback)
	if not playerStatePublished then
		warn(
			"Client corpse player-state publication failed after authority applied",
			target.UserId,
			playerStatePublicationError
		)
	end
	local damageEventPublished, damageEventPublicationError = xpcall(publishClientCorpseDamageEvent, debug.traceback)
	if not damageEventPublished then
		warn(
			"Client corpse damage-event publication failed after authority applied",
			target.UserId,
			damageEventPublicationError
		)
	end
	return result, nil
end

type CombatTargetDamageResult = {
	read applied: boolean,
	read presentationHit: boolean,
	read corpseRemoved: boolean,
	read accuracyContact: AccuracyContact,
}

local function applyCombatTargetDamage(
	target: CombatTarget,
	attacker: Player,
	rawDamage: number,
	direction: Vector3,
	means: string,
	isSplash: boolean,
	shot: ShotContext,
	projectileWitness: Projectile?
): CombatTargetDamageResult
	local targetRecord = if target.kind ~= "BodyQueueCorpse" then records[target.player] else nil
	local attackerRecord = records[attacker]
	local quadActive = attackerRecord ~= nil
		and PowerupRules.IsActive(
				attackerRecord.powerupExpiries[PowerupRules.PowerupId.Quad] or 0,
				assert(shot.levelTimeMilliseconds, "weapon damage requires exact Q3 level time")
			)
			== true
	local poweredDamage =
		assert(PowerupRules.QuadDamage(rawDamage, quadActive), "Quad weapon damage input must be valid")
	local targetTakesDamage = (target.kind == "ClientCorpse")
		or (target.kind == "BodyQueueCorpse" and target.takedamage)
		or (targetRecord ~= nil and targetRecord.alive)
	local beforeHealth = if target.kind == "LivePlayer" and targetRecord
		then targetRecord.health
		elseif target.kind == "BodyQueueCorpse" then target.retainedHealth
		else 0
	local afterHealth = beforeHealth
	local rules = MatchService.GetRules()
	local targetTeam = if target.kind ~= "BodyQueueCorpse" then MatchService.GetPlayerTeam(target.player) else nil
	local attackerTeam = MatchService.GetPlayerTeam(attacker)
	local sameTeam = rules.TeamMode and targetTeam ~= nil and attackerTeam ~= nil and targetTeam == attackerTeam
	local applied = false
	local corpseRemoved = false
	local presentationEligible = target.kind == "LivePlayer"
		and target.player ~= attacker
		and MatchService.AreOpponents(target.player, attacker)
	if target.kind == "LivePlayer" then
		applied = applyDamage(
			target.player,
			attacker,
			poweredDamage,
			direction,
			means,
			isSplash,
			shot,
			true,
			projectileWitness,
			target.body
		)
		if records[target.player] == targetRecord and targetRecord then
			afterHealth = targetRecord.health
		end
	elseif target.kind == "ClientCorpse" then
		local corpseResult, corpseError = applyClientCorpseDamage(
			target.player,
			attacker,
			target.body.id,
			poweredDamage,
			direction,
			means,
			isSplash,
			shot
		)
		if corpseResult then
			applied = true
			corpseRemoved = corpseResult.removed
			beforeHealth = corpseResult.beforeHealth
			afterHealth = corpseResult.afterHealth
		elseif corpseError ~= "client-corpse-damage-not-authorized" then
			-- A protection/intermission rejection is an ordinary G_Damage no-op.
			-- Once a trusted MASK_SHOT body was selected, stale lineage or an owner
			-- transaction failure is an authority fault—not a geometric miss that a
			-- projectile may silently exclude from both direct and splash damage.
			error(corpseError or "client-corpse-damage-failed")
		end
	else
		if MatchService.CanAuthorizedAttackDamageBodyQueue(attacker, shot.matchId) then
			local bodyResult, bodyError = directDeathOwner.bodyQueueService.DamageBody(
				target.queueIndex,
				target.occupantGeneration,
				poweredDamage
			)
			if not bodyResult then
				error(bodyError or "body-queue-corpse-damage-failed")
			end
			applied = bodyResult.applied
			corpseRemoved = bodyResult.gibbed
			beforeHealth = bodyResult.beforeHealth
			afterHealth = bodyResult.afterHealth
			if bodyResult.applied then
				broadcast({
					kind = "BodyQueueDamage",
					eventId = nextEventId(shot),
					shotId = shot.id,
					weaponId = shot.weaponId,
					serverFrame = shot.serverFrame,
					revision = shot.revision,
					attackerUserId = attacker.UserId,
					bodyId = target.body.id,
					queueIndex = target.queueIndex,
					occupantGeneration = target.occupantGeneration,
					damage = poweredDamage,
					means = means,
					isSplash = isSplash,
					gibbed = bodyResult.gibbed,
					targetHealth = bodyResult.afterHealth,
					position = target.body.position,
				})
			end
		end
	end
	local accuracyContact: AccuracyContact = {
		targetKind = if target.kind == "LivePlayer"
			then AccuracyRules.TargetKinds.LiveClient
			elseif target.kind == "ClientCorpse" then AccuracyRules.TargetKinds.ClientCorpse
			else AccuracyRules.TargetKinds.NonClient,
		targetTakesDamage = targetTakesDamage,
		attackerIsClient = records[attacker] ~= nil,
		sameEntity = target.kind ~= "BodyQueueCorpse" and target.player == attacker,
		sameTeam = sameTeam,
		healthBefore = beforeHealth,
		healthAfter = afterHealth,
	}
	table.freeze(accuracyContact)
	local result: CombatTargetDamageResult = {
		applied = applied,
		presentationHit = applied and presentationEligible,
		corpseRemoved = corpseRemoved,
		accuracyContact = accuracyContact,
	}
	table.freeze(result)
	return result
end

local moverDamageAdapter: MoverDamageAdapter = CombatMoverDamageCoordinator.new({
	records = records,
	isStarted = function(): boolean
		return started
	end,
	makeEnvironmentContext = makeEnvironmentContext,
	buildDeathWeaponDrop = buildDeathWeaponDrop,
	broadcast = broadcast,
	setCharacterCombatQuery = setCharacterCombatQuery,
	publishPreparedDeathWeaponDrop = publishPreparedDeathWeaponDrop,
	stageSynchronousMoverDeathWeaponDrop = stageSynchronousMoverDeathWeaponDrop,
	stageSynchronousMoverPowerupDrops = stageSynchronousMoverPowerupDrops,
	stageSynchronousMoverFlagDrops = stageSynchronousMoverFlagDrops,
	syncHumanoidHealth = syncHumanoidHealth,
	publishPlayerRecord = publishPlayerRecord,
	emitElimination = emitElimination,
})

canDamageFrom = function(origin: Vector3, targetPosition: Vector3): boolean
	local folder = worldFolder
	if not folder or not folder.Parent then
		return false
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = { folder }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true

	return SplashVisibility.CanReach(targetPosition, function(sample: Vector3): boolean
		local displacement = sample - origin
		if displacement.Magnitude <= Constants.CollisionSkin then
			return true
		end

		local castOrigin = origin + displacement.Unit * Constants.CollisionSkin
		local castDisplacement = sample - castOrigin
		if Workspace:Raycast(castOrigin, castDisplacement, parameters) ~= nil then
			return false
		end
		-- Mover visuals are deliberately presentation-only and non-queryable.
		-- G_RadiusDamage's CanDamage uses MASK_SOLID, so merge the authoritative
		-- snapshot-time mover frame after the world query just like SV_Trace.
		return not traceMoverSolids(castOrigin, castDisplacement).hit
	end)
end

function CombatService.HasWorldVisibility(origin: Vector3, targetPosition: Vector3): boolean
	local query = canDamageFrom
	return query ~= nil and query(origin, targetPosition)
end

function CombatService.OnPlayerDamaged(callback: (Player, Player, number, number) -> ()): RBXScriptConnection
	return damageSignal.Event:Connect(callback)
end

local function radiusDamage(
	origin: Vector3,
	attacker: Player,
	ignoreBodyId: string?,
	projectile: Projectile
): { AccuracyContact }
	local contacts: { AccuracyContact } = {}
	local shot = projectile.shot
	local definition = WeaponDefinitions.ById[shot.weaponId]
	if not definition or not definition.SplashRadius or not definition.SplashDamage then
		return contacts
	end

	local bodies, targetsByBodyId = collectCombatShotTargets()
	for _, body in bodies do
		if body.id == ignoreBodyId then
			continue
		end
		local target = targetsByBodyId[body.id]
		if not target then
			continue
		end

		local targetCenter = body.position + body.centerOffset
		local edgeDistance = WeaponDefinitions.DistanceToAxisAlignedBox(origin, targetCenter, body.size)
		local points = WeaponDefinitions.SplashDamage(definition.SplashDamage, edgeDistance, definition.SplashRadius)
		if points <= 0 or not canDamageFrom(origin, targetCenter) then
			continue
		end

		local direction = body.position - origin + Vector3.yAxis * WeaponDefinitions.RadiusDirectionLift
		local damageResult =
			applyCombatTargetDamage(target, attacker, points, direction, definition.SplashMeans, true, shot, projectile)
		table.insert(contacts, damageResult.accuracyContact)
	end
	return contacts
end

function projectileRuntime.destroyPresentation(projectile: Projectile)
	local part = projectile.part
	projectile.part = nil
	if part then
		CombatFramePublicationService.RetireProjectilePart(part)
	end
end

function projectileRuntime.installRecord(projectile: Projectile)
	assert(projectilesByRegistration[projectile.registration] == nil, "projectile registration is already installed")
	assert(projectilesBySource[projectile.source] == nil, "projectile source is already installed")
	projectilesByRegistration[projectile.registration] = projectile
	projectilesBySource[projectile.source] = projectile
	table.insert(projectiles, projectile)
end

function projectileRuntime.removeRecord(projectile: Projectile)
	assert(
		projectilesByRegistration[projectile.registration] == projectile,
		"projectile registration registry diverged"
	)
	assert(projectilesBySource[projectile.source] == projectile, "projectile source registry diverged")
	local index = table.find(projectiles, projectile)
	assert(index ~= nil, "projectile ordered registry diverged")
	projectilesByRegistration[projectile.registration] = nil
	projectilesBySource[projectile.source] = nil
	table.remove(projectiles, index :: number)
end

function projectileRuntime.inspectSource(
	projectile: Projectile,
	expectedPhase: "Missile" | "Event"
): ProjectileEntityService.SourceSummary
	local sourceSummary =
		assert(ProjectileEntityService.InspectSource(projectile.source), "projectile source is not current")
	assert(
		sourceSummary.registration == projectile.registration
			and sourceSummary.dynamicBinding == projectile.dynamicBinding
			and sourceSummary.phase == expectedPhase
			and sourceSummary.owner == projectile.owner
			and sourceSummary.shotId == projectile.shot.id,
		"projectile source identity diverged"
	)
	return sourceSummary
end

function projectileRuntime.commitRelease(
	projectile: Projectile,
	frame: AuthoritativeFrameService.Frame,
	reason: "NoImpact" | "EventExpired" | ProjectileEntityLifecycleRules.AdministrativeReleaseReason
)
	local prepared: ProjectileEntityService.PreparedMutation?
	local prepareError: string?
	if reason == "NoImpact" then
		prepared, prepareError = ProjectileEntityService.PrepareNoImpact({
			source = projectile.source,
			frame = frame,
		})
	elseif reason == "EventExpired" then
		prepared, prepareError = ProjectileEntityService.PrepareEventExpired({
			source = projectile.source,
			frame = frame,
		})
	else
		prepared, prepareError = ProjectileEntityService.PrepareAdministrativeRelease({
			source = projectile.source,
			frame = frame,
			reason = reason,
		})
	end
	assert(prepared, prepareError or "projectile release could not be prepared")
	local receipt, commitError = ProjectileEntityService.CommitPrepared(prepared)
	assert(receipt, commitError or "projectile release could not be committed")
	assert(
		receipt.kind == reason and receipt.source == projectile.source and receipt.summary == nil,
		"projectile release receipt diverged"
	)
	-- G_FreeEntity removes both the world slot and its dynamic dispatch identity
	-- before presentation/local mirrors are discarded.
	projectileRuntime.destroyPresentation(projectile)
	projectileRuntime.removeRecord(projectile)
end

function projectileRuntime.transitionToEvent(
	projectile: Projectile,
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	stepServerTime: number,
	hitResult: CombatTraceResult?,
	directImpactVelocity: Vector3?
)
	local definition =
		assert(WeaponDefinitions.ById[projectile.shot.weaponId], "projectile weapon definition is unavailable")
	local target = if hitResult then hitResult.target else nil
	local explosionPosition = if hitResult
		then assert(
			EntityStateConversionRules.SnapTrajectoryBaseTowards(
				hitResult.position,
				projectile.authorityTrajectoryState.base
			),
			"G_MissileImpact terminal position could not SnapVectorTowards"
		)
		else assert(
			EntityStateConversionRules.SnapTrajectoryBase(projectile.position),
			"G_ExplodeMissile terminal position could not SnapVector"
		)
	local directContacts: { AccuracyContact } = {}

	-- G_MissileImpact applies the direct G_Damage call while the inflictor is
	-- still ET_MISSILE. The later event conversion is intentionally not rolled
	-- back if a subsequent authority operation faults the frame. G_RunMissile's
	-- trace passes ownerNum, so the firing client cannot become `other` here.
	if target and (target.kind == "BodyQueueCorpse" or target.player ~= projectile.owner) then
		local impactDirection = WeaponDefinitions.MissileImpactDirection(directImpactVelocity or projectile.velocity)
		local damageResult = applyCombatTargetDamage(
			target,
			projectile.owner,
			definition.Damage,
			impactDirection,
			definition.DirectMeans,
			false,
			projectile.shot,
			projectile
		)
		table.insert(directContacts, damageResult.accuracyContact)
	end

	local eventTrajectoryState, eventTrajectoryError = ProjectileTrajectory.Create(
		ProjectileTrajectory.Kind.Stationary,
		explosionPosition,
		Vector3.zero,
		summary.currentTimeMilliseconds / 1000,
		0,
		projectile.authorityTrajectoryState.revision + 1
	)
	assert(eventTrajectoryState, eventTrajectoryError or "projectile event trajectory is invalid")
	local prepared: ProjectileEntityService.PreparedMutation?
	local prepareError: string?
	if hitResult then
		prepared, prepareError = ProjectileEntityService.PrepareImpact({
			source = projectile.source,
			trajectoryState = eventTrajectoryState,
			frame = frame,
		})
	else
		prepared, prepareError = ProjectileEntityService.PrepareFuse({
			source = projectile.source,
			trajectoryState = eventTrajectoryState,
			frame = frame,
		})
	end
	assert(prepared, prepareError or "projectile event transition could not be prepared")
	local receipt, commitError = ProjectileEntityService.CommitPrepared(prepared)
	assert(receipt, commitError or "projectile event transition could not be committed")
	local expectedKind = if hitResult then "Impact" else "Fuse"
	assert(
		receipt.kind == expectedKind
			and receipt.source == projectile.source
			and receipt.summary ~= nil
			and receipt.summary.phase == "Event",
		"projectile event receipt diverged"
	)
	local eventSourceSummary = projectileRuntime.inspectSource(projectile, "Event")
	assert(
		eventSourceSummary == receipt.summary and eventSourceSummary.trajectoryState == eventTrajectoryState,
		"projectile event source diverged after commit"
	)

	projectile.authorityTrajectoryState = eventTrajectoryState
	projectile.position = explosionPosition
	projectile.velocity = Vector3.zero
	projectile.stationary = true
	projectile.simulatedThroughLevelTimeMilliseconds = summary.currentTimeMilliseconds
	projectile.simulatedThroughServerTime = stepServerTime
	projectileRuntime.destroyPresentation(projectile)

	-- G_ExplodeMissile/G_MissileImpact convert and relink the event entity before
	-- radius damage and presentation publication. Direct damage above is the sole
	-- exception and exists only for the impact path.
	local radiusContacts =
		radiusDamage(explosionPosition, projectile.owner, if target then target.body.id else nil, projectile)
	local accuracyResult = resolveAccuracyShot(projectile.owner, projectile.shot, directContacts, radiusContacts)
	syncPlayer(projectile.owner)
	broadcast({
		kind = "Explosion",
		eventId = nextEventId(projectile.shot),
		shotId = projectile.shot.id,
		weaponId = projectile.shot.weaponId,
		serverFrame = projectile.shot.serverFrame,
		revision = projectile.shot.revision,
		position = explosionPosition,
		ownerUserId = projectile.owner.UserId,
		clientSequence = projectile.shot.clientSequence,
		lifeSequence = projectile.shot.lifeSequence,
		matchId = projectile.shot.matchId,
		trajectoryStartServerTime = projectile.trajectoryStartServerTime,
		bounces = projectile.bounceCount,
		accuracyCreditedChannel = accuracyResult.creditedChannel,
	})
end

function projectileRuntime.getAppearance(weaponId: number): (string, Color3, number)
	if weaponId == WeaponDefinitions.WeaponId.GrenadeLauncher then
		return "Grenade", Color3.fromRGB(126, 210, 78), 0.7
	elseif weaponId == WeaponDefinitions.WeaponId.PlasmaGun then
		return "Plasma", Color3.fromRGB(202, 101, 255), 0.38
	elseif weaponId == WeaponDefinitions.WeaponId.Bfg then
		return "BFG", Color3.fromRGB(102, 255, 158), 0.75
	end
	return "Rocket", Color3.fromRGB(255, 120, 42), 0.55
end

function projectileRuntime.ensureFolder(): Folder
	local folder = projectileFolder
	if folder and folder.Parent == Workspace then
		return folder
	end
	local replacement = Instance.new("Folder")
	replacement.Name = "Q3EngineProjectiles"
	replacement.Parent = Workspace
	projectileFolder = replacement
	return replacement
end

function projectileRuntime.applyTrajectoryState(part: Part, state: ProjectileTrajectory.State)
	local wire = assert(ProjectileTrajectory.Serialize(state), "projectile trajectory wire is invalid")
	local function apply()
		local attributes = ProjectileTrajectory.Attributes
		part:SetAttribute(attributes.Kind, state.kind)
		part:SetAttribute(attributes.Base, state.base)
		part:SetAttribute(attributes.Velocity, state.velocity)
		part:SetAttribute(attributes.StartServerTime, state.startServerTime)
		part:SetAttribute(attributes.Gravity, state.gravity)
		part:SetAttribute(attributes.Revision, state.revision)
		-- One persistent Attribute is the atomic transport contract. The individual
		-- fields above remain diagnostics; clients adopt only this complete wire.
		part:SetAttribute(attributes.Wire, wire)
	end
	if CombatFramePublicationService.IsOpen() and part.Parent ~= nil then
		CombatFramePublicationService.Queue(apply)
	else
		apply()
	end
end

function projectileRuntime.createPart(
	player: Player,
	shot: ShotContext,
	position: Vector3,
	trajectoryStartServerTime: number,
	trajectoryOrigin: Vector3,
	trajectoryState: ProjectileTrajectory.State
): Part
	local folder = projectileRuntime.ensureFolder()
	local projectileName, color, size = projectileRuntime.getAppearance(shot.weaponId)
	local part = Instance.new("Part")
	part.Name = string.format("Arena%s_%d_%s", projectileName, player.UserId, shot.id)
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one * size
	part.Position = position
	part:SetAttribute("ArenaAuthoritativeProjectile", true)
	part:SetAttribute("ShotId", shot.id)
	part:SetAttribute("OwnerUserId", player.UserId)
	part:SetAttribute("WeaponId", shot.weaponId)
	part:SetAttribute("ClientSequence", shot.clientSequence)
	part:SetAttribute("LifeSequence", shot.lifeSequence)
	part:SetAttribute("Revision", shot.revision)
	if shot.matchId then
		part:SetAttribute("MatchId", shot.matchId)
	end
	part:SetAttribute("TrajectoryStartServerTime", trajectoryStartServerTime)
	part:SetAttribute("TrajectoryOrigin", trajectoryOrigin)
	part:SetAttribute("SpawnFrame", shot.serverFrame)
	if shot.levelTimeMilliseconds ~= nil then
		part:SetAttribute("FiredLevelTimeMilliseconds", shot.levelTimeMilliseconds)
	end
	projectileRuntime.applyTrajectoryState(part, trajectoryState)
	CombatFramePublicationService.TrackProjectilePart(part, folder)
	return part
end

function projectileRuntime.rebasePresentation(projectile: Projectile, stepServerTime: number)
	local part = assert(projectile.part, "missile presentation is unavailable")
	local authorityState = projectile.authorityTrajectoryState
	local trajectoryState, trajectoryError = ProjectileTrajectory.Create(
		authorityState.kind,
		projectile.position,
		projectile.velocity,
		stepServerTime,
		authorityState.gravity,
		projectile.trajectoryState.revision + 1
	)
	assert(trajectoryState, trajectoryError or "projectile presentation rebase is invalid")
	projectile.trajectoryState = trajectoryState
	projectileRuntime.applyTrajectoryState(part, trajectoryState)
end

function projectileRuntime.advance(
	projectile: Projectile,
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	stepServerTime: number
): "Missile" | "Event" | "Released"
	local framePreviousLevelTimeMilliseconds = summary.previousTimeMilliseconds
	local stepLevelTimeMilliseconds = summary.currentTimeMilliseconds
	local frameWindow, frameWindowError =
		ProjectileFrameTimeRules.ValidateFrameWindow(framePreviousLevelTimeMilliseconds, stepLevelTimeMilliseconds)
	assert(frameWindow, frameWindowError or "projectile authority frame window is invalid")
	local definition =
		assert(WeaponDefinitions.ById[projectile.shot.weaponId], "projectile weapon definition is unavailable")
	local part = assert(projectile.part, "missile presentation is unavailable")
	local previousLevelTimeMilliseconds = projectile.simulatedThroughLevelTimeMilliseconds
	if stepLevelTimeMilliseconds <= previousLevelTimeMilliseconds then
		return "Missile"
	end
	local previousServerTime = projectile.simulatedThroughServerTime
	assert(
		isFinite(previousServerTime) and isFinite(stepServerTime) and stepServerTime > previousServerTime,
		"projectile presentation clock did not advance"
	)
	local presentationElapsedSeconds = stepServerTime - previousServerTime
	local presentationClockDiscontinuous, presentationClockError =
		ProjectileFrameTimeRules.IsPresentationClockDiscontinuous(
			stepLevelTimeMilliseconds - previousLevelTimeMilliseconds,
			presentationElapsedSeconds
		)
	assert(
		presentationClockDiscontinuous ~= nil,
		presentationClockError or "projectile presentation interval is invalid"
	)
	local authorityState = projectile.authorityTrajectoryState
	local stepLevelTimeSeconds = stepLevelTimeMilliseconds / 1000
	local targetPosition = assert(
		ProjectileTrajectory.Evaluate(authorityState, stepLevelTimeSeconds),
		"projectile trajectory position could not be evaluated"
	)
	local endVelocity = assert(
		ProjectileTrajectory.EvaluateDelta(authorityState, stepLevelTimeSeconds),
		"projectile trajectory velocity could not be evaluated"
	)
	local displacement = targetPosition - projectile.position
	local ignoredBodyIds: CombatShotTraceRules.IgnoredBodyIds = {}
	local ownerBodyId = MovementService.GetPlayerBodyId(projectile.owner)
	if ownerBodyId then
		ignoredBodyIds[ownerBodyId] = true
	end
	-- G_RunMissile still traces a TR_STATIONARY grenade from its current origin
	-- to that same origin. A player who steps onto it therefore reaches
	-- G_MissileImpact before the later fuse think; do not short-circuit zero
	-- displacement here.
	local result, startSolid = traceCombatShot(projectile.position, displacement, ignoredBodyIds)
	if startSolid then
		-- G_RunMissile does not treat an exiting startsolid as a hitscan impact.
		-- It repeats a zero-length trace at the old origin to identify the body it
		-- is embedded in, then forces fraction zero before G_MissileImpact.
		local retryResult, retryStartSolid = traceCombatShot(projectile.position, Vector3.zero, ignoredBodyIds)
		assert(
			retryResult and retryStartSolid and retryResult.allSolid,
			"projectile startsolid retry lost its authoritative collision body"
		)
		result = retryResult
	end

	if result then
		local noImpactDecision =
			NoImpactRules.Resolve(NoImpactRules.Family.Projectile, SurfaceContact.IsNoImpact(result.worldInstance))
		if noImpactDecision and noImpactDecision.destroyProjectile then
			-- G_RunMissile frees SURF_NOIMPACT missiles before G_MissileImpact.
			-- This must precede target lookup, grenade bounce, direct/splash damage,
			-- and every collision event, including the immediate 50 ms prestep.
			projectileRuntime.commitRelease(projectile, frame, "NoImpact")
			return "Released"
		end

		local target = result.target
		if definition.BounceFactor and not target then
			local displacementLength = displacement.Magnitude
			local impactFraction = if displacementLength > 1e-6
				then math.clamp(result.distance / displacementLength, 0, 1)
				else 0
			-- G_BounceMissile assigns its float interpolation result to an int.
			-- This deliberately uses global level.previousTime/level.time, even for
			-- a fresh missile whose trace spans the longer 50 ms prestep interval.
			local impactLevelTimeMilliseconds, impactLevelTimeError =
				ProjectileFrameTimeRules.DeriveBounceTimeMilliseconds(
					frameWindow.previousLevelTimeMilliseconds,
					frameWindow.currentLevelTimeMilliseconds,
					impactFraction
				)
			assert(impactLevelTimeMilliseconds, impactLevelTimeError or "projectile bounce time is invalid")
			local impactVelocity = assert(
				ProjectileTrajectory.EvaluateDelta(authorityState, impactLevelTimeMilliseconds / 1000),
				"projectile impact velocity could not be evaluated"
			)
			local bounceVelocity, stationary = WeaponDefinitions.BounceVelocity(
				impactVelocity,
				result.normal,
				definition.BounceFactor,
				definition.BounceStopSpeed
			)
			-- G_BounceMissile leaves a stopped EF_BOUNCE_HALF missile at endpos;
			-- a continuing bounce relinks one source unit off the impact plane.
			local bouncePosition = if stationary
				then result.position
				else result.position + result.normal * Constants.PlaneNudge
			local trajectoryKind = if stationary
				then ProjectileTrajectory.Kind.Stationary
				elseif (definition.ProjectileGravity or 0) > 0 then ProjectileTrajectory.Kind.Gravity
				else ProjectileTrajectory.Kind.Linear
			local authorityTrajectoryState, authorityTrajectoryError = ProjectileTrajectory.Create(
				trajectoryKind,
				bouncePosition,
				bounceVelocity,
				stepLevelTimeSeconds,
				if stationary then 0 else definition.ProjectileGravity or 0,
				authorityState.revision + 1
			)
			assert(
				authorityTrajectoryState,
				authorityTrajectoryError or "projectile authority bounce trajectory is invalid"
			)
			local prepared, prepareError = ProjectileEntityService.PrepareBounce({
				source = projectile.source,
				trajectoryState = authorityTrajectoryState,
				frame = frame,
			})
			assert(prepared, prepareError or "projectile bounce could not be prepared")
			local receipt, commitError = ProjectileEntityService.CommitPrepared(prepared)
			assert(receipt, commitError or "projectile bounce could not be committed")
			assert(
				receipt.kind == "Bounce"
					and receipt.source == projectile.source
					and receipt.summary ~= nil
					and receipt.summary.phase == "Missile",
				"projectile bounce receipt diverged"
			)
			local bounceSourceSummary = projectileRuntime.inspectSource(projectile, "Missile")
			assert(
				bounceSourceSummary == receipt.summary
					and bounceSourceSummary.trajectoryState == authorityTrajectoryState,
				"projectile bounce source diverged after commit"
			)

			-- The source-owner commit precedes every local and presentation mutation,
			-- matching G_BounceMissile's retained-entity identity.
			projectile.velocity = bounceVelocity
			projectile.stationary = stationary
			projectile.position = bouncePosition
			if CombatFramePublicationService.IsOpen() and part.Parent ~= nil then
				CombatFramePublicationService.Queue(function()
					part.Position = bouncePosition
				end)
			else
				part.Position = bouncePosition
			end
			projectile.bounceCount += 1
			projectile.authorityTrajectoryState = authorityTrajectoryState
			projectile.simulatedThroughLevelTimeMilliseconds = stepLevelTimeMilliseconds
			projectile.simulatedThroughServerTime = stepServerTime
			projectileRuntime.rebasePresentation(projectile, stepServerTime)
			broadcast({
				kind = "ProjectileBounce",
				eventId = nextEventId(projectile.shot),
				shotId = projectile.shot.id,
				weaponId = projectile.shot.weaponId,
				serverFrame = projectile.shot.serverFrame,
				revision = projectile.shot.revision,
				position = projectile.position,
				normal = result.normal,
				velocity = projectile.velocity,
				ownerUserId = projectile.owner.UserId,
				bounce = projectile.bounceCount,
			})
			return "Missile"
		end

		-- G_MissileImpact evaluates direct-hit knockback at level.time, not at
		-- the earlier trace fraction used only for bounce reflection.
		projectileRuntime.transitionToEvent(projectile, frame, summary, stepServerTime, result, endVelocity)
		return "Event"
	end

	projectile.position = targetPosition
	projectile.velocity = endVelocity
	if presentationClockDiscontinuous then
		projectileRuntime.rebasePresentation(projectile, stepServerTime)
	end
	projectile.simulatedThroughLevelTimeMilliseconds = stepLevelTimeMilliseconds
	projectile.simulatedThroughServerTime = stepServerTime
	local presentationPosition = projectile.position
	if CombatFramePublicationService.IsOpen() and part.Parent ~= nil then
		CombatFramePublicationService.Queue(function()
			part.Position = presentationPosition
		end)
	else
		part.Position = presentationPosition
	end
	return "Missile"
end

function projectileRuntime.fire(
	player: Player,
	origin: Vector3,
	direction: Vector3,
	shot: ShotContext,
	launchServerTime: number,
	launchLevelTimeMilliseconds: number
)
	local definition = WeaponDefinitions.ById[shot.weaponId]
	assert(
		type(launchServerTime) == "number"
			and launchServerTime == launchServerTime
			and math.abs(launchServerTime) < math.huge
			and launchServerTime >= 0,
		"projectile launch requires the synchronized fixed-step presentation timestamp"
	)
	local launchTiming, launchTimingError = ProjectileFrameTimeRules.DeriveLaunchTiming(
		launchLevelTimeMilliseconds,
		WeaponDefinitions.ProjectilePrestepMilliseconds,
		definition.FuseMilliseconds
	)
	assert(launchTiming, launchTimingError or "projectile Q3 launch timing is invalid")
	local trajectoryStartServerTime = launchServerTime - WeaponDefinitions.ProjectilePrestepSeconds
	local trajectoryStartLevelTimeMilliseconds = launchTiming.trajectoryStartLevelTimeMilliseconds
	local velocity = assert(
		EntityStateConversionRules.SnapTrajectoryBase(direction * definition.ProjectileSpeed),
		"projectile launch velocity could not SnapVector"
	)
	local gravity = definition.ProjectileGravity or 0
	local trajectoryKind = if gravity > 0 then ProjectileTrajectory.Kind.Gravity else ProjectileTrajectory.Kind.Linear
	local trajectoryState, trajectoryError =
		ProjectileTrajectory.Create(trajectoryKind, origin, velocity, trajectoryStartServerTime, gravity, 1)
	assert(trajectoryState, trajectoryError or "projectile launch trajectory is invalid")
	local authorityTrajectoryState, authorityTrajectoryError = ProjectileTrajectory.Create(
		trajectoryKind,
		origin,
		velocity,
		trajectoryStartLevelTimeMilliseconds / 1000,
		gravity,
		1
	)
	assert(authorityTrajectoryState, authorityTrajectoryError or "projectile authority launch trajectory is invalid")
	local frame =
		assert(AuthoritativeFrameService.GetOpenFrame(), "projectile launch occurred outside the authoritative frame")
	local frameSummary =
		assert(AuthoritativeFrameService.InspectFrame(frame), "projectile launch lost its authoritative frame")
	assert(
		frameSummary.currentTimeMilliseconds == launchLevelTimeMilliseconds,
		"projectile launch level time diverged from the authoritative frame"
	)
	local prepared, source, prepareError = ProjectileEntityService.PrepareSpawn({
		owner = player,
		shotId = shot.id,
		trajectoryState = authorityTrajectoryState,
		frame = frame,
	})
	assert(prepared and source, prepareError or "projectile spawn could not be prepared")
	local receipt, commitError = ProjectileEntityService.CommitPrepared(prepared)
	assert(receipt, commitError or "projectile spawn could not be committed")
	assert(
		receipt.kind == "Spawn" and receipt.source == source and receipt.summary ~= nil,
		"projectile spawn receipt diverged"
	)
	local sourceSummary =
		assert(ProjectileEntityService.InspectSource(source), "projectile source disappeared after spawn")
	local dynamicBinding = assert(sourceSummary.dynamicBinding, "projectile spawn has no dynamic dispatcher binding")
	assert(
		sourceSummary == receipt.summary
			and sourceSummary.phase == "Missile"
			and sourceSummary.owner == player
			and sourceSummary.shotId == shot.id
			and sourceSummary.trajectoryState == authorityTrajectoryState,
		"projectile spawn source diverged"
	)

	local projectile: Projectile = {
		part = nil,
		owner = player,
		source = source,
		registration = sourceSummary.registration,
		dynamicBinding = dynamicBinding,
		trajectoryOrigin = origin,
		trajectoryState = trajectoryState,
		authorityTrajectoryState = authorityTrajectoryState,
		position = origin,
		velocity = velocity,
		trajectoryStartServerTime = trajectoryStartServerTime,
		simulatedThroughServerTime = trajectoryStartServerTime,
		simulatedThroughLevelTimeMilliseconds = trajectoryStartLevelTimeMilliseconds,
		fuseExpiresLevelTimeMilliseconds = launchTiming.fuseDeadlineLevelTimeMilliseconds,
		bounceCount = 0,
		stationary = false,
		shot = shot,
		cleanupIntent = nil,
	}
	projectileRuntime.installRecord(projectile)
	projectile.part =
		projectileRuntime.createPart(player, shot, origin, trajectoryStartServerTime, origin, trajectoryState)

	broadcast({
		kind = if shot.weaponId == WeaponDefinitions.WeaponId.RocketLauncher then "RocketFired" else "ProjectileFired",
		eventId = nextEventId(shot),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		clientSequence = shot.clientSequence,
		firedAtServerTime = shot.firedAtServerTime,
		lifeSequence = shot.lifeSequence,
		revision = shot.revision,
		matchId = shot.matchId,
		seed = shot.seed,
		origin = origin,
		direction = direction,
		trajectoryStartServerTime = trajectoryStartServerTime,
		ownerUserId = player.UserId,
	})

	-- The committed higher world slot is visible to the dispatcher's live upper
	-- bound immediately. Its untouched trajectory receives the one authoritative
	-- 50 ms prestep when that numeric entity is reached later in this G_RunFrame.
end

local function traceHitscan(
	player: Player,
	origin: Vector3,
	direction: Vector3,
	range: number
): (CombatTraceResult?, Vector3)
	local ignoredBodyIds: CombatShotTraceRules.IgnoredBodyIds = {}
	local ownerBodyId = MovementService.GetPlayerBodyId(player)
	if ownerBodyId then
		ignoredBodyIds[ownerBodyId] = true
	end
	local result = traceCombatShot(origin, direction * range, ignoredBodyIds)
	return result, if result then result.position else origin + direction * range
end

local function traceGauntletContact(player: Player, origin: Vector3, direction: Vector3): CombatTraceResult?
	local definition = WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Gauntlet]
	local result = traceHitscan(player, origin, direction, definition.Range)
	local noImpactDecision = NoImpactRules.Resolve(
		NoImpactRules.Family.Gauntlet,
		SurfaceContact.IsNoImpact(if result then result.worldInstance else nil)
	)
	if noImpactDecision and noImpactDecision.action == NoImpactRules.Action.AbortAttack then
		-- CheckGauntletAttack returns false before PM_Weapon consumes the shot.
		return nil
	end
	return if result and result.target then result else nil
end

local function broadcastPreparedGauntlet(player: Player, receipt: GauntletPrePmoveReceipt)
	local shot = receipt.shot
	local presentation =
		CombatEventPresentationRules.ResolveWeaponPresentation(WeaponDefinitions.WeaponId.Gauntlet, false)
	assert(presentation, "gauntlet must have a legal CombatEvent presentation")
	broadcast({
		kind = "Melee",
		eventId = nextEventId(shot),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		clientSequence = shot.clientSequence,
		firedAtServerTime = shot.firedAtServerTime,
		lifeSequence = shot.lifeSequence,
		revision = shot.revision,
		matchId = shot.matchId,
		seed = shot.seed,
		origin = receipt.origin,
		position = receipt.position,
		ownerUserId = player.UserId,
		-- Q3 deliberately excludes gauntlet from accuracy_shots/accuracy_hits.
		-- This scalar drives only the local hit marker presentation.
		hits = if receipt.hitMarker then 1 else 0,
		tracePresentation = presentation.tracePresentation,
		terminalImpactPresentation = presentation.terminalImpactPresentation,
	})
end

local function fireSingleHitscan(player: Player, origin: Vector3, direction: Vector3, shot: ShotContext)
	assert(
		shot.weaponId ~= WeaponDefinitions.WeaponId.Gauntlet,
		"post-Pmove gauntlet path must consume its pretrace without retracing"
	)
	local definition = WeaponDefinitions.ById[shot.weaponId]
	local traceDirection = direction
	if definition.Spread then
		traceDirection =
			WeaponDefinitions.BulletSpreadDirection(direction, definition.Spread, definition.Range, shot.seed)
	end

	local result, finalPosition = traceHitscan(player, origin, traceDirection, definition.Range)
	local target = if result then result.target else nil
	local taggedSurface = SurfaceContact.IsNoImpact(if result then result.worldInstance else nil)
	-- Weapon_LightningFire checks damageable clients before the world-impact
	-- branch, so SURF_NOIMPACT suppresses only a tagged terminal world impact.
	-- Bullet_Fire and CheckGauntletAttack instead test the flag first.
	local surfaceNoImpact = taggedSurface
		and (shot.weaponId ~= WeaponDefinitions.WeaponId.LightningGun or target == nil)
	local noImpactFamily = if shot.weaponId == WeaponDefinitions.WeaponId.Gauntlet
		then NoImpactRules.Family.Gauntlet
		elseif shot.weaponId == WeaponDefinitions.WeaponId.LightningGun then NoImpactRules.Family.Lightning
		else NoImpactRules.Family.Machinegun
	local noImpactDecision = NoImpactRules.Resolve(noImpactFamily, surfaceNoImpact)
	if noImpactDecision and noImpactDecision.action == NoImpactRules.Action.AbortAttack then
		-- The pre-PM_Weapon gauntlet trace normally prevents reaching this path;
		-- retain the source guard if the world changes before event draining.
		return
	end
	-- Q3 returns before EV_MISSILE_MISS when lightning reaches open air. Its
	-- client beam still reaches the traced endpoint, but there is no terminal
	-- impact—identical presentation flags to a SURF_NOIMPACT world endpoint.
	local suppressTerminalImpact = surfaceNoImpact
		or (shot.weaponId == WeaponDefinitions.WeaponId.LightningGun and result == nil)
	local presentation = CombatEventPresentationRules.ResolveWeaponPresentation(shot.weaponId, suppressTerminalImpact)
	assert(presentation, "traced weapon must have a legal CombatEvent presentation")
	local directDamage = noImpactDecision == nil or noImpactDecision.directDamage
	local currentUserIds: { number } = {}
	if target and target.kind == "LivePlayer" and directDamage then
		table.insert(currentUserIds, target.player.UserId)
	end
	recordHitscanRewindShadow(player, shot, origin, traceDirection, definition.Range, 1, currentUserIds)
	local damage = if shot.weaponId == WeaponDefinitions.WeaponId.Machinegun
			and MatchService.GetRules().ModeKind == "TeamDeathmatch"
		then definition.TeamDamage
		else definition.Damage
	local damageResult = if directDamage and target
		then applyCombatTargetDamage(target, player, damage, traceDirection, definition.DirectMeans, false, shot)
		else nil
	local directContacts: { AccuracyContact } = {}
	if damageResult then
		table.insert(directContacts, damageResult.accuracyContact)
	end
	resolveAccuracyShot(player, shot, directContacts, {})
	local hit = damageResult ~= nil and damageResult.presentationHit

	broadcast({
		kind = if shot.weaponId == WeaponDefinitions.WeaponId.Gauntlet then "Melee" else "Hitscan",
		eventId = nextEventId(shot),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		clientSequence = shot.clientSequence,
		firedAtServerTime = shot.firedAtServerTime,
		lifeSequence = shot.lifeSequence,
		revision = shot.revision,
		matchId = shot.matchId,
		seed = shot.seed,
		origin = origin,
		position = finalPosition,
		ownerUserId = player.UserId,
		hits = if hit then 1 else 0,
		tracePresentation = presentation.tracePresentation,
		terminalImpactPresentation = presentation.terminalImpactPresentation,
	})
end

local function fireShotgun(player: Player, origin: Vector3, direction: Vector3, shot: ShotContext)
	local definition = WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Shotgun]
	local seed = shot.seed
	local hitPellets = 0
	local accuracyContacts: { AccuracyContact } = {}
	local pelletPositions: { Vector3 } = {}
	local pelletTraceMask = 0
	local pelletImpactMask = 0

	for pelletIndex = 1, definition.Pellets do
		local pelletDirection: Vector3
		pelletDirection, seed = WeaponDefinitions.SpreadDirection(direction, definition.Spread, definition.Range, seed)
		local result, finalPosition = traceHitscan(player, origin, pelletDirection, definition.Range)
		table.insert(pelletPositions, finalPosition)
		local noImpactDecision = NoImpactRules.Resolve(
			NoImpactRules.Family.ShotgunPellet,
			SurfaceContact.IsNoImpact(if result then result.worldInstance else nil)
		)
		local tracePresentation = noImpactDecision == nil or noImpactDecision.pathPresentation
		local terminalImpactPresentation = noImpactDecision == nil or noImpactDecision.terminalImpact
		pelletTraceMask =
			assert(CombatEventPresentationRules.PelletMask.Set(pelletTraceMask, pelletIndex, tracePresentation))
		pelletImpactMask = assert(
			CombatEventPresentationRules.PelletMask.Set(pelletImpactMask, pelletIndex, terminalImpactPresentation)
		)

		local target = if result then result.target else nil
		if (noImpactDecision == nil or noImpactDecision.directDamage) and target then
			local damageResult = applyCombatTargetDamage(
				target,
				player,
				definition.Damage,
				pelletDirection,
				definition.DirectMeans,
				false,
				shot
			)
			table.insert(accuracyContacts, damageResult.accuracyContact)
			if damageResult.presentationHit then
				hitPellets += 1
			end
		end
	end
	resolveAccuracyShot(player, shot, accuracyContacts, {})

	broadcast({
		kind = "Shotgun",
		eventId = nextEventId(shot),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		clientSequence = shot.clientSequence,
		firedAtServerTime = shot.firedAtServerTime,
		lifeSequence = shot.lifeSequence,
		revision = shot.revision,
		matchId = shot.matchId,
		seed = shot.seed,
		origin = origin,
		direction = direction,
		pelletPositions = pelletPositions,
		ownerUserId = player.UserId,
		hits = hitPellets,
		tracePresentation = pelletTraceMask ~= 0,
		terminalImpactPresentation = pelletImpactMask ~= 0,
		pelletTraceMask = pelletTraceMask,
		pelletImpactMask = pelletImpactMask,
	})
end

local function fireRail(player: Player, origin: Vector3, direction: Vector3, shot: ShotContext)
	local definition = WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Railgun]
	local remaining = definition.Range
	local traceStart = origin
	local finalPosition = origin + direction * remaining
	local ignoredBodyIds: CombatShotTraceRules.IgnoredBodyIds = {}
	local ownerBodyId = MovementService.GetPlayerBodyId(player)
	if ownerBodyId then
		ignoredBodyIds[ownerBodyId] = true
	end

	local penetrations = 0
	local targets: { CombatTarget } = {}
	local currentUserIds: { number } = {}
	local terminalSurfaceNoImpact = false
	-- Resolve the complete current geometric trace before applying any damage.
	-- A first penetration may eliminate a target and disable its query hitbox;
	-- shadow comparison must not observe that mutation halfway through the ray.
	-- Live damage is still applied below in the same front-to-back order.
	while remaining > 0 and penetrations < definition.MaximumPenetrations do
		local result = traceCombatShot(traceStart, direction * remaining, ignoredBodyIds)
		if not result then
			finalPosition = traceStart + direction * remaining
			break
		end

		finalPosition = result.position
		local target = result.target
		if not target then
			-- Only the final solid trace controls rail endpoint presentation. Player
			-- penetrations retain their damage and do not become terminal surfaces.
			terminalSurfaceNoImpact = SurfaceContact.IsNoImpact(result.worldInstance)
			break
		end

		penetrations += 1
		table.insert(targets, target)
		if target.kind == "LivePlayer" then
			table.insert(currentUserIds, target.player.UserId)
		end
		ignoredBodyIds[target.body.id] = true

		local travelled = result.distance
		remaining -= travelled + Constants.CollisionSkin
		traceStart = result.position + direction * Constants.CollisionSkin
	end

	recordHitscanRewindShadow(
		player,
		shot,
		origin,
		direction,
		definition.Range,
		definition.MaximumPenetrations,
		currentUserIds
	)

	local hitPlayers = 0
	local accuracyContacts: { AccuracyContact } = {}
	local noImpactDecision = NoImpactRules.Resolve(NoImpactRules.Family.Rail, terminalSurfaceNoImpact)
	local presentation = CombatEventPresentationRules.ResolveWeaponPresentation(shot.weaponId, terminalSurfaceNoImpact)
	assert(presentation, "rail must have a legal CombatEvent presentation")
	for _, target in targets do
		if noImpactDecision == nil or noImpactDecision.directDamage then
			local damageResult = applyCombatTargetDamage(
				target,
				player,
				definition.Damage,
				direction,
				definition.DirectMeans,
				false,
				shot
			)
			table.insert(accuracyContacts, damageResult.accuracyContact)
			if damageResult.presentationHit then
				hitPlayers += 1
			end
		end
	end
	local accuracyResult = resolveAccuracyShot(player, shot, accuracyContacts, {})
	local record = assert(records[player], "rail shooter lost its Combat record")
	local nextAccurateCount, impressiveDelta =
		RailImpressiveRules.Advance(record.railAccurateCount, accuracyResult.impressiveQualifyingPenetrationCount)
	record.railAccurateCount = assert(nextAccurateCount, "rail accurateCount transition failed")
	if assert(impressiveDelta, "rail Impressive delta was unavailable") > 0 then
		record.impressiveCount = saturatedAdd(record.impressiveCount, impressiveDelta)
		record.impressiveRewardUntilMilliseconds = assert(
			RailImpressiveRules.RewardDeadline(shot.levelTimeMilliseconds),
			"rail Impressive deadline overflowed"
		)
	end

	broadcast({
		kind = "Rail",
		eventId = nextEventId(shot),
		shotId = shot.id,
		weaponId = shot.weaponId,
		serverFrame = shot.serverFrame,
		clientSequence = shot.clientSequence,
		firedAtServerTime = shot.firedAtServerTime,
		lifeSequence = shot.lifeSequence,
		revision = shot.revision,
		matchId = shot.matchId,
		seed = shot.seed,
		origin = origin,
		position = finalPosition,
		ownerUserId = player.UserId,
		hits = hitPlayers,
		accuracyQualifyingPenetrations = accuracyResult.impressiveQualifyingPenetrationCount,
		tracePresentation = presentation.tracePresentation,
		terminalImpactPresentation = presentation.terminalImpactPresentation,
	})
end

local function consumeAmmo(record: CombatRecord, weaponId: number): boolean
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		return false
	end
	local cost = definition.AmmoPerShot
	if cost <= 0 or record.infiniteAmmo then
		return true
	end

	local available = record.ammoByWeapon[weaponId] or 0
	if available < cost then
		return false
	end
	record.ammoByWeapon[weaponId] = available - cost
	return true
end

requestCharacterRespawn = function(player: Player, record: CombatRecord, currentLevelTimeMilliseconds: number): boolean
	local eligibleAt = record.respawnEligibleAtMilliseconds
	if
		record.alive
		or record.respawnRequested
		or eligibleAt == nil
		or currentLevelTimeMilliseconds <= eligibleAt
		or not MatchService.CanPlayerSpawn(player)
	then
		return false
	end
	local character = record.character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return false
	end

	record.respawnRequested = true
	record.manualRespawnQueued = false
	record.forcedRespawnAtMilliseconds = nil
	task.spawn(function()
		while
			player.Parent == Players
			and records[player] == record
			and not record.alive
			and record.respawnRequested
			and MatchService.CanPlayerSpawn(player)
		do
			local success, loadError = pcall(function()
				player:LoadCharacter()
			end)
			if success then
				return
			end
			warn(string.format("Unable to respawn %s: %s", player.Name, tostring(loadError)))
			-- Roblox avatar loading may yield/fail after CopyToBodyQue committed.
			-- No prepared gameplay owner remains held; retry only this external
			-- replacement while the exact dead Combat record still owns the request.
			task.wait(1)
		end
	end)
	return true
end

local function prepareFireWeapon(
	player: Player,
	sequence: number,
	inputReceivedServerTime: number,
	state: Movement.State,
	attack: boolean,
	attackBranchReachable: boolean,
	revision: number,
	stepServerTime: number,
	stepLevelTimeMilliseconds: number,
	gauntletReceipt: GauntletPrePmoveReceipt?
): (() -> ())?
	local record = records[player]
	if gauntletReceipt ~= nil and record ~= nil and record.weaponId ~= WeaponDefinitions.WeaponId.Gauntlet then
		-- A command-side weapon transition may suppress PM_Weapon after the
		-- source-faithful pretrace. Never let that receipt authorize another gun.
		gauntletReceipt = nil
	end
	if not record or state.respawned or not attack then
		return nil
	end

	if not record.alive then
		return nil
	end
	if not MatchService.CanPlayerFight(player) and gauntletReceipt == nil then
		return nil
	end
	if not attackBranchReachable then
		return nil
	end
	assert(
		record.weaponState == "Ready" or record.weaponState == "Firing",
		"PM_Weapon attack branch retained a transition state"
	)

	local weaponId = record.weaponId
	local definition = WeaponDefinitions.ById[weaponId]
	if
		not definition
		or not WeaponDefinitions.LiveAllowed[weaponId]
		or not MatchService.CanSelectWeapon(player, weaponId)
		or record.ownedWeapons[weaponId] ~= true
	then
		return nil
	end
	if
		definition.AmmoPerShot > 0
		and not record.infiniteAmmo
		and (record.ammoByWeapon[weaponId] or 0) < definition.AmmoPerShot
	then
		-- PM_Weapon enters WEAPON_FIRING, emits EV_NOAMMO, and adds 500 ms
		-- before cgame chooses another owned weapon.
		local weaponState, weaponTimeMilliseconds, outcome = WeaponSelection.ResolveAttackTiming(
			record.weaponState,
			record.weaponTimeMilliseconds,
			true,
			weaponId == WeaponDefinitions.WeaponId.Gauntlet,
			gauntletReceipt ~= nil,
			false,
			definition.RefireMilliseconds
		)
		assert(outcome == "NoAmmo", "PM_Weapon no-ammo timing diverged")
		record.weaponState = weaponState :: WeaponState
		record.weaponTimeMilliseconds = weaponTimeMilliseconds
		return function()
			emitNoAmmo(player, record, weaponId, sequence, state.frame)
			syncPlayer(player)
		end
	end

	local direction = if gauntletReceipt then gauntletReceipt.direction else state.look
	if direction.Magnitude < 0.9 or direction.Magnitude > 1.1 then
		return nil
	end
	direction = direction.Unit
	local origin = if gauntletReceipt
		then gauntletReceipt.origin
		else state.position
			+ Vector3.yAxis * Constants.ViewHeightFor(state.crouched)
			+ direction * WeaponDefinitions.MuzzleForwardOffset
	if weaponId == WeaponDefinitions.WeaponId.Gauntlet and gauntletReceipt == nil then
		-- Base Q3 checks gauntlet contact before starting its 400 ms weapon timer.
		-- Holding the gauntlet while closing distance must connect on the first
		-- simulation opportunity instead of waiting out a cooldown from a miss.
		local weaponState, weaponTimeMilliseconds, outcome = WeaponSelection.ResolveAttackTiming(
			record.weaponState,
			record.weaponTimeMilliseconds,
			true,
			true,
			false,
			true,
			definition.RefireMilliseconds
		)
		assert(outcome == "GauntletMiss", "PM_Weapon gauntlet miss timing diverged")
		record.weaponState = weaponState :: WeaponState
		record.weaponTimeMilliseconds = weaponTimeMilliseconds
		syncPlayer(player)
		return nil
	end
	if not consumeAmmo(record, weaponId) then
		return nil
	end
	local hasteActive = PowerupRules.IsActive(
		record.powerupExpiries[PowerupRules.PowerupId.Haste] or 0,
		stepLevelTimeMilliseconds
	) == true
	local refireMilliseconds = assert(
		PowerupRules.HasteWeaponMilliseconds(definition.RefireMilliseconds, hasteActive),
		"Haste weapon cadence input must be valid"
	)

	-- Preserve signed integer cadence overshoot while attack remains held.
	-- PM_Weapon adds refire time to the possibly-negative shared counter.
	local weaponState, weaponTimeMilliseconds, outcome = WeaponSelection.ResolveAttackTiming(
		record.weaponState,
		record.weaponTimeMilliseconds,
		true,
		weaponId == WeaponDefinitions.WeaponId.Gauntlet,
		gauntletReceipt ~= nil,
		true,
		refireMilliseconds
	)
	assert(outcome == "Fire", "PM_Weapon fire timing diverged")
	record.weaponState = weaponState :: WeaponState
	record.weaponTimeMilliseconds = weaponTimeMilliseconds
	record.shotsFired += 1
	local shot = if gauntletReceipt
		then gauntletReceipt.shot
		else reserveShotContext(
			player,
			record,
			weaponId,
			sequence,
			inputReceivedServerTime,
			state.frame,
			revision,
			stepLevelTimeMilliseconds,
			stepServerTime
		)
	recordAcceptedAccuracyShot(record, shot)
	local lifeSequence = shot.lifeSequence

	return function()
		-- PM_Weapon consumed ammo/timing and queued this event before ClientEvents.
		-- Drain it even if an earlier same-command fall event killed the owner.
		if records[player] ~= record or record.lifeSequence ~= lifeSequence then
			return
		end
		if weaponId == WeaponDefinitions.WeaponId.Gauntlet then
			broadcastPreparedGauntlet(player, assert(gauntletReceipt, "gauntlet fire lost its pre-Pmove trace receipt"))
		elseif weaponId == WeaponDefinitions.WeaponId.Railgun then
			fireRail(player, origin, direction, shot)
		elseif weaponId == WeaponDefinitions.WeaponId.Shotgun then
			fireShotgun(player, origin, direction, shot)
		elseif
			weaponId == WeaponDefinitions.WeaponId.GrenadeLauncher
			or weaponId == WeaponDefinitions.WeaponId.RocketLauncher
			or weaponId == WeaponDefinitions.WeaponId.PlasmaGun
		then
			local launchDirection = direction
			if weaponId == WeaponDefinitions.WeaponId.GrenadeLauncher then
				-- weapon_grenadelauncher_fire adds 0.2 source-space vertical aim before
				-- normalizing, producing Q3's characteristic raised arc.
				launchDirection = (direction + Vector3.yAxis * 0.2).Unit
			end
			projectileRuntime.fire(player, origin, launchDirection, shot, stepServerTime, stepLevelTimeMilliseconds)
		else
			fireSingleHitscan(player, origin, direction, shot)
		end

		syncPlayer(player)
	end
end

function CombatService.HandlePrePmoveCommand(
	player: Player,
	inputSequence: number,
	inputReceivedServerTime: number,
	state: Movement.State,
	command: Movement.Command,
	revision: number,
	stepServerTime: number,
	stepLevelTimeMilliseconds: number,
	_freshCommand: boolean
): unknown?
	pendingGauntletPrePmoveByPlayer[player] = nil
	local record = records[player]
	if not record then
		return nil
	end
	if
		not WeaponSelection.ShouldRunPmoveStep(
			record.lastPrePmoveGauntletLevelTimeMilliseconds,
			stepLevelTimeMilliseconds
		)
	then
		return nil
	end
	record.lastPrePmoveGauntletLevelTimeMilliseconds = stepLevelTimeMilliseconds
	local attack = CommandQuantization.AttackFromButtonBits(command.buttons)
	if
		attack ~= true
		or not record.alive
		or record.weaponId ~= WeaponDefinitions.WeaponId.Gauntlet
		or not MatchService.CanPlayerFight(player)
	then
		return nil
	end
	-- ClientThink_real checks the pre-Pmove value. A stored value of 1 ms must
	-- suppress this trace even when this command's later PM_Weapon decrement
	-- will carry it through zero.
	if record.weaponTimeMilliseconds > 0 then
		return nil
	end
	local direction = state.look
	if direction.Magnitude < 0.9 or direction.Magnitude > 1.1 then
		return nil
	end
	direction = direction.Unit
	local origin = state.position
		+ Vector3.yAxis * Constants.ViewHeightFor(state.crouched)
		+ direction * WeaponDefinitions.MuzzleForwardOffset
	local traceResult = traceGauntletContact(player, origin, direction)
	if not traceResult then
		return nil
	end
	local target = assert(traceResult.target, "gauntlet contact lost its damageable target")
	local shot = reserveShotContext(
		player,
		record,
		WeaponDefinitions.WeaponId.Gauntlet,
		inputSequence,
		inputReceivedServerTime,
		state.frame,
		revision,
		stepLevelTimeMilliseconds,
		stepServerTime
	)
	local currentUserIds: { number } = {}
	if target.kind == "LivePlayer" then
		table.insert(currentUserIds, target.player.UserId)
	end
	recordHitscanRewindShadow(
		player,
		shot,
		origin,
		direction,
		WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Gauntlet].Range,
		1,
		currentUserIds
	)
	local damageResult = applyCombatTargetDamage(
		target,
		player,
		WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Gauntlet].Damage,
		direction,
		WeaponDefinitions.ById[WeaponDefinitions.WeaponId.Gauntlet].DirectMeans,
		false,
		shot
	)
	local receipt: GauntletPrePmoveReceipt = {
		player = player,
		inputSequence = inputSequence,
		revision = revision,
		lifeSequence = record.lifeSequence,
		levelTimeMilliseconds = stepLevelTimeMilliseconds,
		origin = origin,
		direction = direction,
		position = traceResult.position,
		hitMarker = damageResult.presentationHit,
		shot = shot,
	}
	table.freeze(receipt)
	pendingGauntletPrePmoveByPlayer[player] = receipt
	syncPlayer(player)
	return receipt
end

function CombatService.HandleMovementCommand(
	player: Player,
	inputSequence: number,
	inputReceivedServerTime: number,
	state: Movement.State,
	command: Movement.Command,
	revision: number,
	stepServerTime: number,
	stepLevelTimeMilliseconds: number,
	stepMsec: number,
	freshCommand: boolean,
	prePmoveData: unknown?
): (() -> ())?
	local record = records[player]
	local pendingReceipt = pendingGauntletPrePmoveByPlayer[player]
	pendingGauntletPrePmoveByPlayer[player] = nil
	local gauntletReceipt = if prePmoveData == pendingReceipt
			and pendingReceipt ~= nil
			and pendingReceipt.player == player
			and pendingReceipt.inputSequence == inputSequence
			and pendingReceipt.revision == revision
			and record ~= nil
			and pendingReceipt.lifeSequence == record.lifeSequence
			and pendingReceipt.levelTimeMilliseconds == stepLevelTimeMilliseconds
		then pendingReceipt
		else nil
	if not record then
		return nil
	end
	assert(
		isFinite(stepLevelTimeMilliseconds)
			and stepLevelTimeMilliseconds % 1 == 0
			and stepLevelTimeMilliseconds >= stepMsec,
		"PM_Weapon requires exact integer level time"
	)
	if
		not WeaponSelection.ShouldRunPmoveStep(record.lastWeaponPmoveLevelTimeMilliseconds, stepLevelTimeMilliseconds)
	then
		return nil
	end
	record.lastWeaponPmoveLevelTimeMilliseconds = stepLevelTimeMilliseconds

	local attack = CommandQuantization.AttackFromButtonBits(command.buttons)
	assert(attack ~= nil, "MovementService passed invalid Q3 button bits")
	local useHoldable = CommandQuantization.UseHoldableFromButtonBits(command.buttons)
	assert(useHoldable ~= nil, "MovementService passed invalid Q3 Use-Holdable bits")
	local requestedWeaponId = command.weaponId
	local acceptedIntent = record.alive
		and WeaponDefinitions.LiveAllowed[requestedWeaponId] == true
		and MatchService.CanSelectWeapon(player, requestedWeaponId)
		and record.ownedWeapons[requestedWeaponId] == true
	local decision = WeaponSelection.ResolveCommand(
		state.respawned,
		record.weaponId,
		record.commandWeaponId,
		record.weaponState,
		requestedWeaponId,
		acceptedIntent,
		attack
	)
	-- PMF_RESPAWNED returns from PM_Weapon before either weapon selection or
	-- attack. Movement.step has already consumed a release in PmoveSingle, so
	-- that exact release command reaches the selection branch below.
	if not decision.process then
		return nil
	end
	local oneShot = MatchService.GetRules().OneShot
	local holdableStateChanged = false
	local preparedHoldable: (() -> ())? = nil
	local preparedRailJump: (() -> ())? = nil
	if oneShot then
		local previousUseHeld = record.holdableUseHeld
		holdableStateChanged = previousUseHeld ~= useHoldable or record.holdableId ~= HoldableRules.HoldableId.None
		record.holdableUseHeld = useHoldable
		record.holdableId = HoldableRules.HoldableId.None

		local canAttemptRailJump = OneShotRules.CanAttemptRailJump(
			true,
			record.alive,
			useHoldable,
			previousUseHeld,
			record.weaponId,
			WeaponDefinitions.WeaponId.Railgun,
			stepLevelTimeMilliseconds,
			record.railJumpReadyAtMilliseconds
		)
		assert(canAttemptRailJump ~= nil, "One-Shot rail-jump command state must be valid")
		canAttemptRailJump = canAttemptRailJump and MatchService.CanPlayerFight(player)
		local direction = state.look
		if canAttemptRailJump and direction.Magnitude >= 0.9 and direction.Magnitude <= 1.1 then
			direction = direction.Unit
			local origin = state.position
				+ Vector3.yAxis * Constants.ViewHeightFor(state.crouched)
				+ direction * WeaponDefinitions.MuzzleForwardOffset
			local surfacePosition = traceRailJumpSurface(origin, direction)
			local jumpDirection = if surfacePosition
				then OneShotRules.ResolveRailJumpDirection(state.position, surfacePosition, Constants.UnitsToStuds)
				else nil
			if jumpDirection then
				record.railJumpReadyAtMilliseconds = assert(
					OneShotRules.RailJumpReadyAt(stepLevelTimeMilliseconds),
					"One-Shot rail-jump cooldown must be valid"
				)
				local consumedLifeSequence = record.lifeSequence
				local consumedMatchId = MatchService.GetMatchId()
				preparedRailJump = function()
					if
						records[player] ~= record
						or record.lifeSequence ~= consumedLifeSequence
						or MatchService.GetMatchId() ~= consumedMatchId
						or not record.alive
					then
						return
					end
					applyKnockback(player, jumpDirection, OneShotRules.RailJumpKnockbackDamage)
					syncPlayer(player)
				end
			end
		end
	else
		local holdableDecision = assert(
			HoldableRules.ResolveCommand(
				useHoldable,
				record.holdableUseHeld,
				record.holdableId,
				record.health,
				record.baseHealth
			),
			"PM_Weapon holdable state was invalid"
		)
		local preparedPersonalTeleport = nil
		if holdableDecision.consumedHoldableId == HoldableRules.HoldableId.Teleporter then
			local prepareError: string?
			preparedPersonalTeleport, _, prepareError = CombatPersonalTeleporterCoordinator.Prepare(player)
			assert(
				preparedPersonalTeleport ~= nil,
				prepareError or "Personal Teleporter composition could not be prepared"
			)
		end
		holdableStateChanged = record.holdableUseHeld ~= holdableDecision.held
			or record.holdableId ~= holdableDecision.holdableId
		record.holdableUseHeld = holdableDecision.held
		record.holdableId = holdableDecision.holdableId
		if holdableDecision.consumedHoldableId == HoldableRules.HoldableId.Teleporter then
			local prepared =
				assert(preparedPersonalTeleport, "Personal Teleporter consumption requires its prepared composition")
			preparedHoldable = function()
				assert(
					select(1, CombatPersonalTeleporterCoordinator.CanApply(prepared)) == true,
					"prepared Personal Teleporter composition became stale before EV_USE_ITEM1"
				)
				assert(
					CombatPersonalTeleporterCoordinator.Apply(prepared),
					"prepared Personal Teleporter composition failed at EV_USE_ITEM1"
				)
				syncPlayer(player)
			end
		elseif holdableDecision.consumedHoldableId == HoldableRules.HoldableId.Medkit then
			local consumedLifeSequence = record.lifeSequence
			preparedHoldable = function()
				if records[player] ~= record or record.lifeSequence ~= consumedLifeSequence or not record.alive then
					return
				end
				record.health = assert(
					HoldableRules.ApplyMedkit(record.health, record.baseHealth, holdableDecision.consumedHoldableId),
					"consumed medkit effect was invalid"
				)
				syncHumanoidHealth(record)
				syncPlayer(player)
			end
		elseif holdableDecision.consumedHoldableId ~= nil then
			error("unimplemented live holdable effect")
		end
		if holdableDecision.blocksWeapon then
			if holdableStateChanged or holdableDecision.consumedHoldableId ~= nil then
				syncPlayer(player)
			end
			return preparedHoldable
		end
	end
	local rawIntentChanged = freshCommand and requestedWeaponId ~= record.lastWeaponIntentId
	if rawIntentChanged then
		record.lastWeaponIntentId = requestedWeaponId
	end
	-- Install the current accepted cmd.weapon before processing any expired
	-- Dropping/Raising boundary. PM_FinishWeaponChange reads this command, not
	-- the previous command's selection.
	local weaponStateChanged, phaseConsumed, commandWeaponChanged, attackBranchReachable =
		CombatInventoryRuntime.AdvanceWeaponCommandPhase(record, stepMsec, decision.acceptedWeaponId)
	if freshCommand and (rawIntentChanged or commandWeaponChanged) then
		record.lastWeaponCommandSequence = inputSequence
	end
	if not decision.attackRequested and attackBranchReachable then
		local weaponState, weaponTimeMilliseconds, outcome = WeaponSelection.ResolveAttackTiming(
			record.weaponState,
			record.weaponTimeMilliseconds,
			false,
			false,
			false,
			false,
			0
		)
		assert(outcome == "Release", "PM_Weapon release timing diverged")
		weaponStateChanged = weaponStateChanged
			or record.weaponState ~= weaponState
			or record.weaponTimeMilliseconds ~= weaponTimeMilliseconds
		record.weaponState = weaponState :: WeaponState
		record.weaponTimeMilliseconds = weaponTimeMilliseconds
	end
	if rawIntentChanged or commandWeaponChanged or weaponStateChanged or holdableStateChanged then
		-- Reconcile both accepted and semantically rejected intent edges without
		-- granting the client ownership or mode authority. Command processing can
		-- also advance a held, attack=false transition; synchronize the exact
		-- command-consumed phase here without a second timer observer.
		syncPlayer(player)
	end

	local preparedAttack: (() -> ())? = nil
	if decision.attackRequested and not phaseConsumed then
		-- Q3 g_active.c processes BUTTON_ATTACK as part of the same usercmd whose
		-- movement established ps.origin/viewangles. The selection branch above can
		-- put the weapon into Dropping, so this same command cannot fire the old gun.
		preparedAttack = prepareFireWeapon(
			player,
			inputSequence,
			inputReceivedServerTime,
			state,
			attack,
			attackBranchReachable,
			revision,
			stepServerTime,
			stepLevelTimeMilliseconds,
			gauntletReceipt
		)
	end
	if preparedRailJump and preparedAttack then
		return function()
			preparedRailJump()
			preparedAttack()
		end
	end
	return preparedRailJump or preparedAttack
end

function CombatService.HandleDeadMovementCommand(
	player: Player,
	_command: Movement.Command,
	attackPressed: boolean,
	useHoldablePressed: boolean,
	levelTimeMilliseconds: number,
	postPmoveCapture: unknown,
	postPmoveCaptureSummary: unknown,
	playerStateVelocity: Vector3
)
	local record = records[player]
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local frameSummary = if openFrame then AuthoritativeFrameService.InspectFrame(openFrame) else nil
	if
		not record
		or record.alive
		or record.respawnEligibleAtMilliseconds == nil
		or not frameSummary
		or frameSummary.currentTimeMilliseconds ~= levelTimeMilliseconds
	then
		return
	end
	-- g_active.c tests BUTTON_ATTACK || BUTTON_USE_HOLDABLE after PM_DEAD.
	-- The shared dead kernel has already preserved/sanitized those exact levels.
	if attackPressed or useHoldablePressed then
		record.manualRespawnQueued = true
	end
	if not MatchService.CanPlayerSpawn(player) then
		return
	end
	local handoff = CombatService.GetDirectDeathHandoff(player)
	local handoffSummary = if handoff then CombatService.InspectDirectDeathHandoff(handoff) else nil
	if not handoff or not handoffSummary then
		return
	end
	local corpseSource = handoffSummary.preparedCorpseTombstoneSummary.source
	local pointContents = function(position: Vector3): number
		return assert(MovementService.GetPointContents(position), "respawn point-contents authority unavailable")
	end
	local result, respawnError = CombatRespawnCoordinator.Execute({
		deathHandle = handoffSummary.bodyQueueHandle,
		corpseTombstone = handoffSummary.corpseTombstone,
		lineage = {
			matchId = handoffSummary.matchId,
			matchLineage = handoffSummary.matchLineage,
			playerBodyId = corpseSource.playerBodyId,
			playerSourceOrder = corpseSource.playerSourceOrder,
			playerLeaseGeneration = corpseSource.playerLeaseGeneration,
			playerUserId = handoffSummary.targetUserId,
			lifeSequence = handoffSummary.lifeSequence,
		},
		postPmoveCapture = postPmoveCapture,
		postPmoveCaptureSummary = postPmoveCaptureSummary,
		playerStateVelocity = playerStateVelocity,
		pointContents = pointContents,
		nowMilliseconds = levelTimeMilliseconds,
		attackPressed = attackPressed or record.manualRespawnQueued,
		useHoldablePressed = useHoldablePressed,
		forceRespawnSeconds = MatchService.GetRules().ForcedRespawnSeconds,
	})
	if not result then
		if respawnError == "respawn-not-ready" then
			return
		end
		error(respawnError or "prepared respawn transaction failed")
	end
	local handoffCapability =
		assert(directDeathOwner.handoffCapabilities[handoff], "applied respawn lost its direct-death handoff")
	directDeathOwner.retireHandoffCapability(handoffCapability)
	if result.sink then
		local presentationSucceeded, presentationError = BodyQueuePresentationService.StageCopy(player, result.sink)
		if not presentationSucceeded then
			warn(
				string.format("Unable to stage body-queue avatar for %s: %s", player.Name, tostring(presentationError))
			)
		end
	end
	assert(
		requestCharacterRespawn(player, record, levelTimeMilliseconds),
		"applied CopyToBodyQue did not start avatar replacement"
	)
end

function projectileRuntime.queueCleanup(
	owner: Player?,
	reason: ProjectileEntityLifecycleRules.AdministrativeReleaseReason
)
	for _, projectile in projectiles do
		if owner == nil or projectile.owner == owner then
			-- Match cleanup is the broader terminal intent if both callbacks arrive
			-- before this numeric entity receives its next canonical visit.
			if
				projectile.cleanupIntent == nil
				or reason == ProjectileEntityLifecycleRules.AdministrativeReleaseReason.MatchCleanup
			then
				projectile.cleanupIntent = reason
			end
		end
	end
end

function projectileRuntime.quarantine()
	-- A G_RunFrame entity error is terminal. Quarantine only Combat's local
	-- mirrors and presentation. ProjectileEntityService/EntitySlot mutations are
	-- deliberately not invented outside the faulting canonical frame.
	local abandonedProjectiles = projectiles
	projectiles = {}
	projectilesByRegistration = {}
	projectilesBySource = {}
	for _, projectile in abandonedProjectiles do
		pcall(function()
			projectileRuntime.destroyPresentation(projectile)
		end)
	end
	table.clear(abandonedProjectiles)
	local folder = projectileFolder
	if folder then
		local children: { Instance } = {}
		pcall(function()
			children = folder:GetChildren()
		end)
		for _, child in children do
			pcall(function()
				child:Destroy()
			end)
		end
	end
end

function CombatService.HandleSimulationFault()
	if projectilePhaseFaulted then
		return
	end
	projectilePhaseFaulted = true
	CombatFramePublicationService.Quarantine()
	EntityFrameDispatcherService.HandleSimulationFault()
	MatchService.HandleSimulationFault()
	local extension = simulationFaultExtension
	if extension then
		pcall(extension)
	end
	projectileRuntime.quarantine()
end

function CombatService.SetSimulationFaultExtension(callback: () -> ())
	assert(simulationFaultExtension == nil, "Combat simulation-fault extension is already configured")
	simulationFaultExtension = callback
end

function CombatService.HandleAuthoritativeFrameBegin(frameValue: unknown)
	assert(started, "CombatService must start before its authoritative frame phase")
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	assert(
		openFrame ~= nil and frameValue == openFrame and summary ~= nil,
		"Combat respawn phase received a stale authoritative frame"
	)
	CombatFramePublicationService.Begin(openFrame)
	local levelTimeMilliseconds = summary.currentTimeMilliseconds
	local orderedPlayers = orderedPlayersBySourceOrder()

	-- Cmd_Kill_f is a request only. Resolve it once at the next canonical frame,
	-- preserving Q3's self-attacker player_die attribution without client-authored
	-- damage, means, health, or time.
	for _, player in orderedPlayers do
		local pending = pendingSuicides[player]
		if pending == nil then
			continue
		end
		pendingSuicides[player] = nil
		local record = records[player]
		if
			record ~= pending.record
			or record.lifeSequence ~= pending.lifeSequence
			or not record.alive
			or not MatchService.CanDamage(player, player)
		then
			continue
		end
		local state = MovementService.GetState(player)
		local shot: ShotContext = {
			id = string.format("suicide:%d:%d:%d", player.UserId, record.lifeSequence, levelTimeMilliseconds),
			matchId = MatchService.GetMatchId(),
			lifeSequence = record.lifeSequence,
			weaponId = WeaponDefinitions.WeaponId.None,
			ownerUserId = player.UserId,
			revision = MovementService.GetRevision(player) or 0,
			clientSequence = 0,
			serverFrame = if state then state.frame else 0,
			levelTimeMilliseconds = levelTimeMilliseconds,
			firedAtServerTime = presentationTimeForLevel(levelTimeMilliseconds),
			eventSequence = 0,
			seed = 0,
			inputReceivedServerTime = nil,
		}
		local applied, applyError = executeDirectDeath({
			kind = "SuicidePlayerDie",
			target = player,
			attacker = player,
			rawDamage = nil,
			direction = nil,
			shot = shot,
			targetBody = nil,
			projectileSource = nil,
			worldMeans = nil,
		})
		assert(applied, applyError or "queued suicide failed")
	end

	-- Humanoid.Died and explicit server hazard requests can arrive outside a Q3
	-- entity phase. Consume either once at the next canonical frame boundary so
	-- player_die, Match, corpse, and respawn clocks observe one exact level.time.
	for _, player in orderedPlayers do
		local pending = pendingExternalEliminations[player]
		if pending == nil then
			continue
		end
		pendingExternalEliminations[player] = nil
		local record = records[player]
		if
			not record
			or record ~= pending.record
			or record.lifeSequence ~= pending.lifeSequence
			or MatchService.GetMatchId() ~= pending.matchId
			or record.characterMatchId ~= pending.matchId
			or not record.alive
		then
			continue
		end
		local pendingCharacter = pending.character
		local pendingHumanoid = if pendingCharacter then pendingCharacter:FindFirstChildOfClass("Humanoid") else nil
		if
			pending.requireDeadHumanoid
			and (record.character ~= pendingCharacter or not pendingHumanoid or pendingHumanoid.Health > 0)
		then
			continue
		end
		local forcedEnvironmentAllowed =
			OneShotRules.AllowsForcedEnvironmentElimination(MatchService.GetRules().OneShot, pending.means)
		assert(forcedEnvironmentAllowed ~= nil, "One-Shot forced-environment rule must be valid")
		if not forcedEnvironmentAllowed then
			-- The One-Shot ruleset ignores arbitrary Roblox/Humanoid world
			-- deaths. Void/kill-volume deaths take the explicit route below;
			-- mover crushers own their separate synchronous lethal transition.
			syncHumanoidHealth(record)
			syncPlayer(player)
			continue
		end

		local environment = makeEnvironmentContext(player, record, levelTimeMilliseconds)
		local applied, applyError = executeDirectDeath({
			kind = "ForcedWorldPlayerDie",
			target = player,
			attacker = nil,
			rawDamage = nil,
			direction = nil,
			shot = environment,
			targetBody = nil,
			projectileSource = nil,
			worldMeans = pending.means,
		})
		assert(applied, applyError or "queued forced-world death failed")
	end

	-- g_active.c evaluates both buttons and g_forcerespawn with strict `>`
	-- comparisons against client->respawnTime after the death delay. The current
	-- Roblox PM_DEAD integration is still a later slice, but the clocks and the
	-- single frame-bound LoadCharacter request already preserve those boundaries.
	for _, player in orderedPlayers do
		local record = records[player]
		local eligibleAt = record and record.respawnEligibleAtMilliseconds
		if record == nil or record.alive or eligibleAt == nil then
			continue
		end
		if CombatService.GetDirectDeathHandoff(player) ~= nil then
			continue
		end
		local manualDue = record.manualRespawnQueued and levelTimeMilliseconds > eligibleAt
		local forcedAt = record.forcedRespawnAtMilliseconds
		local forcedDue = forcedAt ~= nil and levelTimeMilliseconds > forcedAt
		if manualDue or forcedDue then
			requestCharacterRespawn(player, record, levelTimeMilliseconds)
		end
	end
end

function CombatService.HandlePreMoverMatchTransitionCleanup(frameValue: unknown)
	local retiredMatchId = pendingPostBeginMatchCleanupId
	local frame = AuthoritativeFrameService.GetOpenFrame()
	assert(
		frame ~= nil and frameValue == frame and AuthoritativeFrameService.InspectFrame(frame) ~= nil,
		"pre-mover Match-transition cleanup received a stale frame"
	)
	local cleanupOwner =
		assert(corpseMatchTransitionCleanupOwner, "pre-mover corpse Match-transition cleanup owner disappeared")
	local currentMatchId = MatchService.GetMatchId()
	if type(currentMatchId) == "string" and currentMatchId ~= "" then
		local clearedPlayers, staleCleanupError = CorpseService.ClearStaleMatchAuthority(cleanupOwner, currentMatchId)
		assert(clearedPlayers ~= nil, staleCleanupError or "stale Match corpse cleanup failed")
		for _, player in clearedPlayers do
			local record = records[player]
			if record and MovementService.GetState(player) ~= nil then
				record.health = 0
				record.armor = 0
				record.alive = false
				record.characterMatchId = nil
				assert(
					MovementService.RetireDeadClientForMatchTransition(
						player,
						assert(
							movementMatchTransitionCleanupOwner,
							"pre-mover Movement Match-transition cleanup owner disappeared"
						)
					),
					"pre-mover old-Match dead Movement client could not retire"
				)
			end
		end
	end
	if not retiredMatchId then
		return
	end
	for player in records do
		assert(
			CorpseService.ClearPlayerForMatchTransition(player, cleanupOwner, retiredMatchId),
			"pre-mover old-Match client corpse could not be cleared"
		)
		local handoff = directDeathOwner.handoffByPlayer[player]
		local handoffCapability = if handoff then directDeathOwner.handoffCapabilities[handoff] else nil
		if handoffCapability and handoffCapability.summary.matchId == retiredMatchId then
			directDeathOwner.retireHandoffCapability(handoffCapability)
		end
	end
	local corpseDebug = CorpseService.GetDebugSnapshot()
	assert(
		corpseDebug.committedCorpseCount == 0 and corpseDebug.committedTombstoneCount == 0,
		"pre-mover Match transition retained client corpse authority"
	)
	pendingPostBeginMatchCleanupId = nil
end

function CombatService.HandleDynamicProjectile(
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration,
	binding: EntityFrameDispatcherService.DynamicBinding,
	declaredKind: EntityFrameDispatcherService.DynamicKind
)
	assert(started, "CombatService must start before projectile dispatch")
	assert(not projectilePhaseFaulted, "authoritative projectile phase is permanently faulted")
	assert(
		declaredKind == "Projectile"
			and AuthoritativeFrameService.GetOpenFrame() == frame
			and AuthoritativeFrameService.InspectFrame(frame) == summary,
		"Combat projectile dispatch received a stale identity or frame"
	)
	local source, sourceSummary = ProjectileEntityService.InspectSourceForRegistration(registration)
	assert(source and sourceSummary, "dynamic projectile registration has no current source")
	local projectile =
		assert(projectilesByRegistration[registration], "dynamic projectile registration has no Combat record")
	assert(
		projectile.source == source
			and projectilesBySource[source] == projectile
			and projectile.registration == registration
			and projectile.dynamicBinding == binding
			and sourceSummary.dynamicBinding == binding
			and sourceSummary.owner == projectile.owner
			and sourceSummary.shotId == projectile.shot.id,
		"dynamic projectile identity diverged"
	)

	local cleanupIntent = projectile.cleanupIntent
	if cleanupIntent then
		projectileRuntime.commitRelease(projectile, frame, cleanupIntent)
		return
	end

	if sourceSummary.phase == "Event" then
		local lifecycle = sourceSummary.lifecycle
		assert(lifecycle.phase == "Event", "projectile event lifecycle diverged")
		local eventAge = summary.currentTimeMilliseconds - lifecycle.eventTimeMilliseconds
		assert(eventAge >= 0, "projectile event clock regressed")
		-- Q3 frees a freeAfterEvent entity only when event age is strictly greater
		-- than EVENT_VALID_MSEC. The entity remains addressable at exactly 300 ms.
		if eventAge > PROJECTILE_EVENT_VALID_MILLISECONDS then
			projectileRuntime.commitRelease(projectile, frame, "EventExpired")
		end
		return
	end
	assert(sourceSummary.phase == "Missile", "projectile source has an invalid live phase")
	projectileRuntime.inspectSource(projectile, "Missile")

	local folder = projectileRuntime.ensureFolder()
	local part = projectile.part
	if part == nil or (part.Parent ~= folder and not CombatFramePublicationService.IsProjectilePartPending(part)) then
		if part then
			CombatFramePublicationService.ForgetProjectilePart(part)
			part:Destroy()
		end
		projectile.part = projectileRuntime.createPart(
			projectile.owner,
			projectile.shot,
			projectile.position,
			projectile.trajectoryStartServerTime,
			projectile.trajectoryOrigin,
			projectile.trajectoryState
		)
	end

	local stepServerTime = assert(
		AuthoritativeFrameService.InspectFrameStepServerTime(frame),
		"Combat projectile dispatch is missing fixed-step presentation time"
	)
	-- A retained missile may already have consumed this boundary through a prior
	-- trajectory epoch. A fresh source begins 50 ms behind and is therefore
	-- eligible for its same-frame prestep when its higher numeric slot is reached.
	local advanceOutcome = projectileRuntime.advance(projectile, frame, summary, stepServerTime)
	if advanceOutcome ~= "Missile" then
		return
	end

	-- G_RunMissile resolves trace/no-impact/bounce/direct impact before G_RunThink.
	-- A collision on the exact fuse frame therefore wins over the timed event.
	if summary.currentTimeMilliseconds >= projectile.fuseExpiresLevelTimeMilliseconds then
		projectileRuntime.transitionToEvent(projectile, frame, summary, stepServerTime, nil, nil)
	end
end

export type ProjectilePhaseDebugSnapshot = {
	read faulted: boolean,
	read dynamicBindingActivated: boolean,
	read projectileCount: number,
	read missileCount: number,
	read eventCount: number,
	read presentationCount: number,
	read cleanupIntentCount: number,
	read registrationCount: number,
	read sourceCount: number,
	read authorityProjectileCount: number,
	read authorityDynamicBindingCount: number,
}

function CombatService.GetProjectilePhaseDebugSnapshot(): ProjectilePhaseDebugSnapshot
	local missileCount = 0
	local eventCount = 0
	local presentationCount = 0
	local cleanupIntentCount = 0
	for _, projectile in projectiles do
		local sourceSummary = ProjectileEntityService.InspectSource(projectile.source)
		if sourceSummary and sourceSummary.phase == "Missile" then
			missileCount += 1
		elseif sourceSummary and sourceSummary.phase == "Event" then
			eventCount += 1
		end
		if projectile.part ~= nil then
			presentationCount += 1
		end
		if projectile.cleanupIntent ~= nil then
			cleanupIntentCount += 1
		end
	end
	local registrationCount = 0
	for _ in projectilesByRegistration do
		registrationCount += 1
	end
	local sourceCount = 0
	for _ in projectilesBySource do
		sourceCount += 1
	end
	local authoritySnapshot = ProjectileEntityService.GetDebugSnapshot()
	return table.freeze({
		faulted = projectilePhaseFaulted,
		dynamicBindingActivated = projectileDynamicBindingActivated,
		projectileCount = #projectiles,
		missileCount = missileCount,
		eventCount = eventCount,
		presentationCount = presentationCount,
		cleanupIntentCount = cleanupIntentCount,
		registrationCount = registrationCount,
		sourceCount = sourceCount,
		authorityProjectileCount = authoritySnapshot.count,
		authorityDynamicBindingCount = authoritySnapshot.dynamicBindingCount,
	})
end

function CombatService.HandleClientTimer(player: Player, msec: number, levelTimeMilliseconds: number)
	assert(
		isFinite(msec)
			and msec % 1 == 0
			and msec > 0
			and isFinite(levelTimeMilliseconds)
			and levelTimeMilliseconds % 1 == 0
			and levelTimeMilliseconds >= msec,
		"ClientTimerActions requires an exact advancing integer level-time interval"
	)
	local record = records[player]
	if not record then
		return
	end
	local rewardCleared = false
	local rewardDeadline = record.impressiveRewardUntilMilliseconds
	if rewardDeadline ~= nil and RailImpressiveRules.IsRewardExpired(rewardDeadline, levelTimeMilliseconds) == true then
		record.impressiveRewardUntilMilliseconds = nil
		rewardCleared = true
	end
	if not record.alive then
		record.overstackAccumulator = 0
		if rewardCleared then
			syncPlayer(player)
		end
		return
	end

	-- Q3's client->timeResidual is integer milliseconds accumulated from
	-- ClientThink_real msec, not a second independent wall-clock Heartbeat.
	record.overstackAccumulator += msec
	local changed = false
	local healthChanged = false
	for powerupId, expiry in record.powerupExpiries do
		if PowerupRules.IsActive(expiry, levelTimeMilliseconds) == false then
			record.powerupExpiries[powerupId] = nil
			changed = true
		end
	end
	while record.overstackAccumulator >= OVERSTACK_DECAY_INTERVAL_MILLISECONDS do
		record.overstackAccumulator -= OVERSTACK_DECAY_INTERVAL_MILLISECONDS
		local regenerationActive = PowerupRules.IsActive(
			record.powerupExpiries[PowerupRules.PowerupId.Regeneration] or 0,
			levelTimeMilliseconds
		) == true
		if regenerationActive then
			local nextHealth = assert(
				PowerupRules.RegenerateHealth(record.health, record.baseHealth, true),
				"live Regeneration state must be valid"
			)
			if nextHealth ~= record.health then
				record.health = nextHealth
				changed = true
				healthChanged = true
			end
		elseif record.health > record.baseHealth then
			record.health = math.max(record.health - OVERSTACK_DECAY_AMOUNT, record.baseHealth)
			changed = true
			healthChanged = true
		end
		if record.armor > record.baseHealth then
			record.armor = math.max(record.armor - OVERSTACK_DECAY_AMOUNT, record.baseHealth)
			changed = true
		end
	end

	if changed or rewardCleared then
		if healthChanged then
			syncHumanoidHealth(record)
		end
		syncPlayer(player)
	end
end

local function addPlayer(player: Player)
	local now = os.clock()
	records[player] = {
		health = 0,
		baseHealth = WeaponDefinitions.InitialHealth,
		armor = WeaponDefinitions.InitialArmor,
		alive = false,
		score = 0,
		deaths = 0,
		weaponId = WeaponDefinitions.InitialWeaponId,
		commandWeaponId = WeaponDefinitions.InitialWeaponId,
		weaponState = "Ready",
		weaponTimeMilliseconds = 0,
		railJumpReadyAtMilliseconds = 0,
		ownedWeapons = {},
		ammoByWeapon = {},
		infiniteAmmo = false,
		holdableId = HoldableRules.HoldableId.None,
		holdableUseHeld = false,
		lastRespawnRequestSequence = -1,
		lastWeaponCommandSequence = -1,
		lastWeaponIntentId = WeaponDefinitions.InitialWeaponId,
		lastWeaponPmoveLevelTimeMilliseconds = -1,
		lastPrePmoveGauntletLevelTimeMilliseconds = -1,
		rateWindowStart = now,
		rateWindowCount = 0,
		shotsFired = 0,
		accuracyShots = 0,
		accuracyHits = 0,
		accuracyMatchId = MatchService.GetMatchId(),
		railAccurateCount = 0,
		impressiveCount = 0,
		impressiveRewardUntilMilliseconds = nil,
		noAmmoEvents = 0,
		lifeSequence = 0,
		movementLifeBinding = nil,
		serverShotSequence = 0,
		lastShotId = "",
		character = nil,
		characterMatchId = nil,
		overstackAccumulator = 0,
		respawnEligibleAtMilliseconds = nil,
		forcedRespawnAtMilliseconds = nil,
		manualRespawnQueued = false,
		respawnRequested = false,
		lastDroppedLifeSequence = -1,
		lastLandingFrame = -1,
		lastLandingContactIndex = 0,
		powerupExpiries = {},
		environmentDamageState = assert(
			EnvironmentDamageRules.SpawnState(0),
			"initial environment-damage state must be valid"
		),
		pendingPainFeedbackLevelTimeMilliseconds = nil,
	}

	local function onCharacter(character: Model)
		local record = records[player]
		if not record or record.character == character then
			return
		end
		pendingExternalEliminations[player] = nil
		assert(CorpseService.ClearPlayer(player), "client corpse could not be cleared before a new character spawn")

		record.character = character
		record.characterMatchId = nil
		record.alive = false
		record.movementLifeBinding = nil
		record.health = 0
		record.armor = 0
		record.overstackAccumulator = 0
		record.respawnEligibleAtMilliseconds = nil
		record.forcedRespawnAtMilliseconds = nil
		record.manualRespawnQueued = false
		-- LoadCharacter is a yielding replacement boundary. Preserve an existing
		-- request latch until Movement has reserved this exact Character; clearing it
		-- in CharacterAdded lets the next authoritative frame issue a second
		-- LoadCharacter and unparent the avatar still completing this handshake.
		record.serverShotSequence = 0
		record.lastShotId = ""
		record.lastLandingFrame = -1
		record.lastLandingContactIndex = 0
		character.DescendantAdded:Connect(function(descendant: Instance)
			if character:GetAttribute("ArenaPresentationVisible") == false then
				setPresentationInstance(descendant, false)
			end
		end)
		local humanoidInstance = character:WaitForChild("Humanoid", 10)
		if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
			MovementService.ReleaseSpawn(player)
			syncPlayer(player)
			return
		end
		-- Q3 CopyToBodyQue preserves the client model as a corpse. Roblox's
		-- default Humanoid death teardown would destroy that joint pose before the
		-- post-close body-queue presentation can clone it.
		humanoidInstance.BreakJointsOnDeath = false

		record = records[player]
		if not record or record.character ~= character then
			return
		end

		local spawnTime = os.clock()
		local loadout = MatchService.GetSpawnLoadout(player)
		record.baseHealth = loadout.maxHealth
		if not MatchService.CanPlayerSpawn(player) then
			MovementService.ReleaseSpawn(player)
			record.ownedWeapons = {}
			record.ammoByWeapon = {}
			record.infiniteAmmo = false
			record.weaponId = loadout.weaponId
			record.commandWeaponId = loadout.weaponId
			record.weaponState = "Ready"
			record.weaponTimeMilliseconds = 0
			humanoidInstance.MaxHealth = math.max(loadout.maxHealth, loadout.health)
			humanoidInstance.Health = loadout.health
			setCharacterCombatQuery(character, false)
			syncPlayer(player)
			return
		end
		local spawnReserved, spawnReservationError = MovementService.WaitForSpawnReservation(player, character, 10)
		if not spawnReserved then
			if records[player] ~= record or record.character ~= character or player.Character ~= character then
				setCharacterCombatQuery(character, false)
				return
			end
			MovementService.ReleaseSpawn(player)
			record.respawnRequested = false
			record.manualRespawnQueued = MatchService.CanPlayerSpawn(player)
			setCharacterCombatQuery(character, false)
			syncPlayer(player)
			warn(
				string.format(
					"Movement spawn reservation failed for %s: %s",
					player.Name,
					spawnReservationError or "unknown"
				)
			)
			return
		end

		local lifeSequence = (lastLifeSequenceByUserId[player.UserId] or 0) + 1
		lastLifeSequenceByUserId[player.UserId] = lifeSequence
		record.lifeSequence = lifeSequence
		record.health = loadout.health
		record.armor = loadout.armor
		record.alive = true
		local spawnFrame = AuthoritativeFrameService.GetOpenFrame()
		local spawnFrameSummary = if spawnFrame then AuthoritativeFrameService.InspectFrame(spawnFrame) else nil
		record.environmentDamageState = assert(
			EnvironmentDamageRules.SpawnState(
				if spawnFrameSummary then spawnFrameSummary.currentTimeMilliseconds else 0
			),
			"spawn environment-damage state must be valid"
		)
		record.pendingPainFeedbackLevelTimeMilliseconds = nil
		record.overstackAccumulator = 0
		record.respawnEligibleAtMilliseconds = nil
		record.forcedRespawnAtMilliseconds = nil
		record.manualRespawnQueued = false
		record.respawnRequested = false
		local spawnRules = MatchService.GetRules()
		CombatInventoryRuntime.Reset(
			record,
			spawnRules,
			loadout.weaponId,
			if spawnRules.ModeId == "ArenaElimination"
					and MatchService.GetState() == MatchConfig.States.Warmup
				then true
				else nil
		)
		record.railJumpReadyAtMilliseconds = 0
		record.rateWindowStart = spawnTime
		record.rateWindowCount = 0
		humanoidInstance.MaxHealth = math.max(loadout.maxHealth, loadout.health)
		humanoidInstance.Health = loadout.health
		local movementLifeBinding = MovementService.ConfirmSpawn(player, lifeSequence)
		if not movementLifeBinding then
			record.health = 0
			record.armor = 0
			record.alive = false
			record.movementLifeBinding = nil
			record.respawnRequested = false
			record.manualRespawnQueued = MatchService.CanPlayerSpawn(player)
			setCharacterCombatQuery(character, false)
			syncPlayer(player)
			return
		end
		record.movementLifeBinding = movementLifeBinding
		record.characterMatchId = MatchService.GetMatchId()
		setCharacterCombatQuery(character, true)

		humanoidInstance.Died:Connect(function()
			local current = records[player]
			if
				not current
				or current.character ~= character
				or not current.alive
				or current.characterMatchId ~= MatchService.GetMatchId()
			then
				return
			end
			-- A Roblox Humanoid may die outside a translated G_Damage call. Never
			-- manufacture Match/death authority in that asynchronous callback: bind
			-- the fallback to the next integer G_RunFrame boundary instead.
			local pending = pendingExternalEliminations[player]
			if
				pending == nil
				or pending.record ~= current
				or pending.lifeSequence ~= current.lifeSequence
				or pending.matchId ~= MatchService.GetMatchId()
			then
				pendingExternalEliminations[player] = {
					record = current,
					character = character,
					lifeSequence = current.lifeSequence,
					matchId = MatchService.GetMatchId(),
					means = "World",
					collisionContext = ORDINARY_EXTERNAL_DEATH_CONTEXT,
					requireDeadHumanoid = true,
				}
			end
		end)
		syncPlayer(player)
	end

	local function onCharacterRemoving(character: Model)
		local record = records[player]
		if not record or record.character ~= character then
			return
		end
		pendingExternalEliminations[player] = nil
		record.character = nil
		record.characterMatchId = nil
		record.movementLifeBinding = nil
		record.health = 0
		record.alive = false
		record.overstackAccumulator = 0
		syncPlayer(player)
	end

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(onCharacterRemoving)
	if player.Character then
		task.defer(onCharacter, player.Character)
	else
		syncPlayer(player)
		records[player].respawnEligibleAtMilliseconds = 0
		records[player].manualRespawnQueued = true
	end
end

local function isLiveWeaponId(weaponId: number): boolean
	return isFinite(weaponId) and weaponId % 1 == 0 and WeaponDefinitions.LiveAllowed[weaponId] == true
end

local function resolveGrantAmount(weaponId: number, requestedAmount: number?, isWeaponPickup: boolean): number?
	if not isLiveWeaponId(weaponId) then
		return nil
	end
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		return nil
	end
	local amount = if requestedAmount == nil
		then if isWeaponPickup then definition.WeaponPickupAmmo else definition.AmmoPickupAmmo
		else requestedAmount
	if not isFinite(amount) or amount % 1 ~= 0 or amount < 0 then
		return nil
	end
	return math.min(amount, definition.MaximumAmmo)
end

local function canReceivePickup(player: Player, weaponId: number): CombatRecord?
	local record = records[player]
	if not record or not record.alive or not isLiveWeaponId(weaponId) or not MatchService.CanUsePickups(player) then
		return nil
	end
	return record
end

local function resolveVitalCap(record: CombatRecord, amount: number, cap: number): (number?, number?)
	if not isFinite(amount) or not isFinite(cap) then
		return nil, nil
	end
	local grant = math.floor(amount)
	local maximum = math.min(math.floor(cap), record.baseHealth * 2)
	if grant <= 0 or maximum <= 0 then
		return nil, nil
	end
	return grant, maximum
end

function CombatService.GetItemState(player: Player): ItemState?
	local record = records[player]
	local movementState = MovementService.GetState(player)
	if not record or not movementState then
		return nil
	end

	return {
		alive = record.alive,
		pickupsEnabled = record.alive and MatchService.CanUsePickups(player),
		position = movementState.position,
		look = movementState.look,
		lifeSequence = record.lifeSequence,
		health = record.health,
		maxHealth = record.baseHealth,
		armor = record.armor,
		ammoByWeapon = CombatInventoryRuntime.BuildSnapshot(record).ammoByWeapon,
		holdableId = record.holdableId,
	}
end

function CombatService.TryGrantHoldable(player: Player, holdableId: number, _context: unknown?): boolean
	local record = records[player]
	if
		not record
		or not record.alive
		or not MatchService.CanUsePickups(player)
		or record.holdableId ~= HoldableRules.HoldableId.None
		or (holdableId ~= HoldableRules.HoldableId.Teleporter and holdableId ~= HoldableRules.HoldableId.Medkit)
	then
		return false
	end
	record.holdableId = holdableId
	syncPlayer(player)
	return true
end

function CombatService.TryGrantPowerup(player: Player, powerupId: number, context: any): boolean
	local record = records[player]
	if
		not record
		or not record.alive
		or not MatchService.CanUsePickups(player)
		or not PowerupRules.IsId(powerupId)
		or type(context) ~= "table"
	then
		return false
	end
	local levelTimeMilliseconds = context.levelTimeMilliseconds
	local durationSeconds = context.grantAmount
	local nextExpiry = PowerupRules.PickupExpiryMilliseconds(
		record.powerupExpiries[powerupId] or 0,
		levelTimeMilliseconds,
		durationSeconds
	)
	if not nextExpiry then
		return false
	end
	record.powerupExpiries[powerupId] = nextExpiry
	syncPlayer(player)
	return true
end

function CombatService.TryGrantHealth(player: Player, amount: number, cap: number, _context: unknown?): boolean
	local record = records[player]
	if not record or not record.alive or not MatchService.CanUsePickups(player) then
		return false
	end

	local grant, maximum = resolveVitalCap(record, amount, cap)
	if not grant or not maximum then
		return false
	end
	local nextHealth = math.min(record.health + grant, maximum)
	if nextHealth <= record.health then
		return false
	end

	record.health = nextHealth
	syncHumanoidHealth(record)
	syncPlayer(player)
	return true
end

function CombatService.TryGrantArmor(player: Player, amount: number, cap: number, _context: unknown?): boolean
	local record = records[player]
	if
		not record
		or not record.alive
		or not MatchService.GetRules().ArmorEnabled
		or not MatchService.CanUsePickups(player)
	then
		return false
	end

	local grant, maximum = resolveVitalCap(record, amount, cap)
	if not grant or not maximum then
		return false
	end
	local nextArmor = math.min(record.armor + grant, maximum)
	if nextArmor <= record.armor then
		return false
	end

	record.armor = nextArmor
	syncPlayer(player)
	return true
end

function CombatService.HasWeapon(player: Player, weaponId: number): boolean
	local record = records[player]
	return record ~= nil and isLiveWeaponId(weaponId) and record.ownedWeapons[weaponId] == true
end

function CombatService.GetAmmo(player: Player, weaponId: number): number?
	local record = records[player]
	if not record or not isLiveWeaponId(weaponId) then
		return nil
	end
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		return nil
	end
	if record.infiniteAmmo and definition.AmmoPerShot > 0 then
		return -1
	end
	return record.ammoByWeapon[weaponId] or 0
end

function CombatService.GetInventory(player: Player): InventorySnapshot?
	local record = records[player]
	return if record then CombatInventoryRuntime.BuildSnapshot(record) else nil
end

function CombatService.GetWeaponState(player: Player): {
	activeWeaponId: number,
	commandWeaponId: number,
	state: string,
	weaponTimeMilliseconds: number,
	transitionAt: number,
	nextFireAt: number,
}?
	local record = records[player]
	if not record then
		return nil
	end
	local now = os.clock()
	local transitionAt = if record.weaponState == "Dropping" or record.weaponState == "Raising"
		then now + weaponPhaseRemainingSeconds(record)
		else 0
	return {
		activeWeaponId = record.weaponId,
		commandWeaponId = record.commandWeaponId,
		state = record.weaponState,
		weaponTimeMilliseconds = record.weaponTimeMilliseconds,
		transitionAt = transitionAt,
		nextFireAt = now + weaponReadyRemainingSeconds(record),
	}
end

function CombatService.CanGrantWeapon(player: Player, weaponId: number, ammoAmount: number?): boolean
	local record = canReceivePickup(player, weaponId)
	local amount = resolveGrantAmount(weaponId, ammoAmount, true)
	if not record or amount == nil then
		return false
	end
	-- Base Q3 always consumes an eligible world weapon, even when the player
	-- already owns it at maximum ammo. That denial/timing behavior matters in Duel.
	return true
end

function CombatService.GrantWeapon(player: Player, weaponId: number, ammoAmount: number?): boolean
	if not CombatService.CanGrantWeapon(player, weaponId, ammoAmount) then
		return false
	end

	local record = records[player] :: CombatRecord
	local definition = WeaponDefinitions.ById[weaponId]
	local amount = resolveGrantAmount(weaponId, ammoAmount, true) :: number
	record.ownedWeapons[weaponId] = true
	record.ammoByWeapon[weaponId] = math.min((record.ammoByWeapon[weaponId] or 0) + amount, definition.MaximumAmmo)
	syncPlayer(player)
	return true
end

function CombatService.GrantStudioFixtureWeapon(player: Player, weaponId: number, ammoAmount: number): boolean
	local world = Workspace:FindFirstChild("Q3EngineWorld")
	local record = records[player]
	local definition = WeaponDefinitions.ById[weaponId]
	if
		not RunService:IsStudio()
		or not world
		or world:GetAttribute("ArenaStudioMoverFixture") == nil
		or not record
		or not record.alive
		or not definition
		or not isLiveWeaponId(weaponId)
		or not isFinite(ammoAmount)
		or ammoAmount % 1 ~= 0
		or ammoAmount < 1
	then
		return false
	end
	record.ownedWeapons[weaponId] = true
	record.ammoByWeapon[weaponId] = math.min(ammoAmount, definition.MaximumAmmo)
	record.weaponId = weaponId
	record.commandWeaponId = weaponId
	record.weaponState = "Ready"
	record.weaponTimeMilliseconds = 0
	syncPlayer(player)
	return true
end

function CombatService.GrantStudioFixturePowerup(player: Player, powerupId: number, remainingSeconds: number): boolean
	local world = Workspace:FindFirstChild("Q3EngineWorld")
	local record = records[player]
	if
		not RunService:IsStudio()
		or not world
		or world:GetAttribute("ArenaStudioMoverFixture") == nil
		or not record
		or not record.alive
		or not PowerupRules.IsId(powerupId)
		or not isFinite(remainingSeconds)
		or remainingSeconds % 1 ~= 0
		or remainingSeconds < 1
	then
		return false
	end
	record.powerupExpiries[powerupId] = EntitySlotService.GetDebugSnapshot().levelTimeMilliseconds
		+ remainingSeconds * 1_000
	syncPlayer(player)
	return true
end

function CombatService.CanGrantAmmo(player: Player, weaponId: number, ammoAmount: number?): boolean
	local record = canReceivePickup(player, weaponId)
	local amount = resolveGrantAmount(weaponId, ammoAmount, false)
	if not record or not amount or amount <= 0 then
		return false
	end

	local definition = WeaponDefinitions.ById[weaponId]
	return definition.MaximumAmmo > 0 and (record.ammoByWeapon[weaponId] or 0) < definition.MaximumAmmo
end

function CombatService.GrantAmmo(player: Player, weaponId: number, ammoAmount: number?): boolean
	if not CombatService.CanGrantAmmo(player, weaponId, ammoAmount) then
		return false
	end

	local record = records[player] :: CombatRecord
	local definition = WeaponDefinitions.ById[weaponId]
	local amount = resolveGrantAmount(weaponId, ammoAmount, false) :: number
	record.ammoByWeapon[weaponId] = math.min((record.ammoByWeapon[weaponId] or 0) + amount, definition.MaximumAmmo)
	syncPlayer(player)
	return true
end

function CombatService.OnElimination(callback: (event: EliminationEvent) -> ()): RBXScriptConnection
	return eliminationSignal.Event:Connect(callback)
end

function CombatService.SetPreparedDeathDropInsertionAdapter(adapterValue: DeathDropInsertionAdapter)
	assert(started, "CombatService must be started before installing the prepared death-drop adapter")
	assert(type(adapterValue) == "table", "prepared death-drop adapter must be a table")
	assert(table.isfrozen(adapterValue), "prepared death-drop adapter must be frozen")
	assert(
		type(adapterValue.StageSynchronousMover) == "function",
		"synchronous mover death-drop staging is unavailable"
	)
	assert(type(adapterValue.Prepare) == "function", "prepared death-drop Prepare is unavailable")
	assert(type(adapterValue.InspectPrepared) == "function", "prepared death-drop inspection is unavailable")
	assert(
		type(adapterValue.ValidatePreparedDependency) == "function",
		"prepared death-drop dependency validation is unavailable"
	)
	assert(type(adapterValue.CanApplyPrepared) == "function", "prepared death-drop preflight is unavailable")
	assert(type(adapterValue.ApplyPrepared) == "function", "prepared death-drop Apply is unavailable")
	assert(
		type(adapterValue.ValidateAppliedDependency) == "function",
		"applied death-drop dependency validation is unavailable"
	)
	assert(type(adapterValue.FlushPrepared) == "function", "prepared death-drop Flush is unavailable")
	assert(type(adapterValue.AbortPrepared) == "function", "prepared death-drop Abort is unavailable")
	for _, methodName in
		{
			"PrepareBatch",
			"InspectPreparedBatch",
			"ValidatePreparedBatchDependency",
			"CanApplyPreparedBatch",
			"ApplyPreparedBatch",
			"ValidateAppliedBatchDependency",
			"FlushPreparedBatch",
			"AbortPreparedBatch",
		}
	do
		assert(
			type((adapterValue :: any)[methodName]) == "function",
			string.format("prepared death-drop batch %s is unavailable", methodName)
		)
	end
	assert(directDeathOwner.deathDropInsertionAdapter == nil, "prepared death-drop adapter may only be installed once")
	directDeathOwner.deathDropInsertionAdapter = adapterValue
end

function CombatService.SetDeathWeaponDropHandler(handler: (request: DeathWeaponDropRequest) -> boolean)
	assert(started, "CombatService must be started before installing the death-drop handler")
	assert(type(handler) == "function", "death-drop handler must be a function")
	assert(deathWeaponDropHandler == nil, "death-drop handler may only be installed once")
	deathWeaponDropHandler = handler
end

function CombatService.SetSynchronousMoverFlagDropHandler(handler: (
	Player,
	Vector3,
	number
) -> ({ MoverPushRules.Body }?, string?))
	assert(started, "CombatService must start before installing mover flag drops")
	assert(synchronousMoverFlagDropHandler == nil, "synchronous mover flag-drop handler may only be installed once")
	synchronousMoverFlagDropHandler = handler
end

function CombatService.HandleLanding(player: Player, landingResult: Landing.Result, contactIndex: number): boolean
	local record = records[player]
	if not record or landingResult.valid ~= true or contactIndex % 1 ~= 0 or contactIndex < 1 or contactIndex > 2 then
		return false
	end

	-- PM_CrashLand can intentionally suppress the complete event on a no-damage
	-- surface or while fully submerged. Treat that as a successfully consumed
	-- landing without producing presentation or damage events.
	if landingResult.suppressed then
		return true
	end

	local classification = landingResult.classification
	local expectedDamage: number
	if classification == Landing.Classification.Far then
		expectedDamage = 10
	elseif classification == Landing.Classification.Medium then
		expectedDamage = 5
	elseif
		classification == Landing.Classification.Short
		or classification == Landing.Classification.Footstep
		or classification == Landing.Classification.None
	then
		expectedDamage = 0
	else
		return false
	end
	if
		landingResult.damage ~= expectedDamage
		or not isFinite(landingResult.rawDelta)
		or not isFinite(landingResult.delta)
		or not isFinite(landingResult.cameraOffsetStuds)
		or landingResult.rawDelta < 0
		or landingResult.delta < 0
	then
		return false
	end
	if classification == Landing.Classification.None then
		return true
	end
	local worldDamageAllowed = OneShotRules.AllowsWorldDamage(MatchService.GetRules().OneShot)
	assert(worldDamageAllowed ~= nil, "One-Shot world-damage rule must be valid")
	local appliedDamage = if worldDamageAllowed then expectedDamage else 0

	local state = MovementService.GetState(player)
	local revision = MovementService.GetRevision(player)
	if not state or revision == nil then
		return false
	end
	local serverFrame = state.frame
	local authoritativeFrame = AuthoritativeFrameService.GetOpenFrame()
	local authoritativeSummary = if authoritativeFrame
		then AuthoritativeFrameService.InspectFrame(authoritativeFrame)
		else nil
	local levelTimeMilliseconds = if authoritativeSummary then authoritativeSummary.currentTimeMilliseconds else nil
	if serverFrame == record.lastLandingFrame and contactIndex <= record.lastLandingContactIndex then
		return true
	end
	local drainsAfterSameCommandDeath = not record.alive
		and serverFrame == record.lastLandingFrame
		and contactIndex == record.lastLandingContactIndex + 1
	if not record.alive and not drainsAfterSameCommandDeath then
		return false
	end
	record.lastLandingFrame = serverFrame
	record.lastLandingContactIndex = contactIndex

	-- A deterministic per-life/per-frame context gives Landing, Damage, and any
	-- resulting Elimination distinct event ids while making duplicate delivery
	-- of the same simulation edge harmless.
	local context: ShotContext = {
		id = string.format("landing:%d:%d:%d:%d", player.UserId, record.lifeSequence, serverFrame, contactIndex),
		matchId = MatchService.GetSnapshot().matchId,
		lifeSequence = record.lifeSequence,
		weaponId = WeaponDefinitions.WeaponId.None,
		ownerUserId = 0,
		revision = revision,
		clientSequence = 0,
		serverFrame = serverFrame,
		levelTimeMilliseconds = levelTimeMilliseconds,
		firedAtServerTime = presentationTimeForLevel(levelTimeMilliseconds),
		eventSequence = 0,
		seed = 0,
		inputReceivedServerTime = nil,
	}
	broadcast({
		kind = "Landing",
		eventId = nextEventId(context),
		shotId = context.id,
		serverFrame = serverFrame,
		revision = context.revision,
		targetUserId = player.UserId,
		targetLifeSequence = record.lifeSequence,
		classification = classification,
		rawDelta = landingResult.rawDelta,
		delta = landingResult.delta,
		damage = appliedDamage,
		cameraOffsetStuds = landingResult.cameraOffsetStuds,
		cameraDeflectSeconds = Landing.CameraDeflectSeconds,
		cameraReturnSeconds = Landing.CameraReturnSeconds,
	})

	if appliedDamage == 0 or not record.alive then
		return true
	end
	return applyDamage(player, nil, appliedDamage, Vector3.zero, "Falling", false, context)
end

local WATER_EVENT_KIND: { [Movement.WaterEvent]: string } = table.freeze({
	Touch = "WaterTouch",
	Leave = "WaterLeave",
	Under = "WaterUnder",
	Clear = "WaterClear",
})

function CombatService.HandleWaterEvent(player: Player, event: Movement.WaterEvent, eventIndex: number): boolean
	local record = records[player]
	local state = MovementService.GetState(player)
	local revision = MovementService.GetRevision(player)
	local kind = WATER_EVENT_KIND[event]
	if
		not record
		or not state
		or revision == nil
		or kind == nil
		or eventIndex % 1 ~= 0
		or eventIndex < 1
		or eventIndex > 2
	then
		return false
	end

	-- PM_WaterEvents is a predictable event appended after PM_Weapon. Keep its
	-- per-life/frame/index identity deterministic so presentation can deduplicate
	-- without giving the client any water-state authority.
	broadcast({
		kind = kind,
		eventId = string.format(
			"water:%d:%d:%d:%d:%s",
			player.UserId,
			record.lifeSequence,
			state.frame,
			eventIndex,
			event
		),
		serverFrame = state.frame,
		revision = revision,
		matchId = MatchService.GetMatchId(),
		targetUserId = player.UserId,
		targetLifeSequence = record.lifeSequence,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
	})
	return true
end

function CombatService.HandleWorldEffectsFrame(frameValue: unknown)
	local frame = AuthoritativeFrameService.GetOpenFrame()
	local summary = if frame then AuthoritativeFrameService.InspectFrame(frame) else nil
	assert(
		frame ~= nil
			and frameValue == frame
			and summary ~= nil
			and MatchService.GetIntegerClockDebugSnapshot().frameOpen,
		"P_WorldEffects requires the exact open post-client frame"
	)
	local orderedPlayers = Players:GetPlayers()
	table.sort(orderedPlayers, function(left: Player, right: Player): boolean
		return left.UserId < right.UserId
	end)
	local worldDamageAllowed = OneShotRules.AllowsWorldDamage(MatchService.GetRules().OneShot)
	assert(worldDamageAllowed ~= nil, "One-Shot world-damage rule must be valid")
	for _, player in orderedPlayers do
		local record = records[player]
		local movementState = MovementService.GetState(player)
		if not record or not movementState then
			continue
		end
		local battleSuitActive = PowerupRules.IsActive(
			record.powerupExpiries[PowerupRules.PowerupId.BattleSuit] or 0,
			summary.currentTimeMilliseconds
		) == true
		local result = assert(
			EnvironmentDamageRules.Step(
				record.environmentDamageState,
				summary.currentTimeMilliseconds,
				movementState.waterLevel,
				movementState.waterType,
				battleSuitActive,
				record.alive
			),
			"live P_WorldEffects state must be valid"
		)
		record.environmentDamageState = result.state
		if worldDamageAllowed then
			for damageIndex, damage in result.damages do
				if not record.alive then
					break
				end
				local context = makeEnvironmentContext(player, record, summary.currentTimeMilliseconds)
				context.id = string.format(
					"environment:%d:%d:%d:%s:%d",
					player.UserId,
					record.lifeSequence,
					summary.currentTimeMilliseconds,
					damage.means,
					damageIndex
				)
				applyDamage(
					player,
					nil,
					damage.amount,
					Vector3.zero,
					damage.means,
					false,
					context,
					nil,
					nil,
					nil,
					damage.bypassArmor
				)
			end
		end
		local pendingPainTime = record.pendingPainFeedbackLevelTimeMilliseconds
		if pendingPainTime ~= nil and pendingPainTime <= summary.currentTimeMilliseconds then
			record.pendingPainFeedbackLevelTimeMilliseconds = nil
			local environmentState = record.environmentDamageState
			if record.alive and environmentState.painDebounceUntilMilliseconds <= summary.currentTimeMilliseconds then
				record.environmentDamageState = table.freeze({
					airOutTimeMilliseconds = environmentState.airOutTimeMilliseconds,
					drowningDamage = environmentState.drowningDamage,
					painDebounceUntilMilliseconds = summary.currentTimeMilliseconds + 700,
				})
			end
		end
	end
end

function CombatService.EndAuthoritativeFrame(frameValue: unknown): () -> ()
	return CombatFramePublicationService.Seal(frameValue)
end

function CombatService.FlushAuthoritativeFramePublications(frameValue: unknown)
	CombatFramePublicationService.Flush(frameValue)
end

function CombatService.EliminateForEnvironment(
	player: Player,
	means: string?,
	_collisionContext: DirectDeathCollisionContext?
): boolean
	local record = records[player]
	if not record then
		return false
	end
	if not record.alive then
		return true
	end
	if record.characterMatchId ~= MatchService.GetMatchId() then
		-- The Match replacement callback has not rebound this Roblox Character.
		-- An old movement/Humanoid observation cannot author a death in the new
		-- Q3 match identity while avatar replacement is still pending.
		return true
	end
	-- Q3 has no arbitrary environment means through player_die. Roblox's Void
	-- boundary is the sole extension; all other administrative/Humanoid death
	-- labels normalize to the canonical World route before capability capture.
	local resolvedMeans = if means == "Void" then "Void" else "World"
	local forcedEnvironmentAllowed =
		OneShotRules.AllowsForcedEnvironmentElimination(MatchService.GetRules().OneShot, resolvedMeans)
	assert(forcedEnvironmentAllowed ~= nil, "One-Shot forced-environment rule must be valid")
	if not forcedEnvironmentAllowed then
		pendingExternalEliminations[player] = nil
		syncHumanoidHealth(record)
		syncPlayer(player)
		return true
	end
	local frame = AuthoritativeFrameService.GetOpenFrame()
	local matchFrameOpen = MatchService.GetIntegerClockDebugSnapshot().frameOpen
	if frame == nil or not matchFrameOpen then
		local pending = pendingExternalEliminations[player]
		if
			pending == nil
			or pending.record ~= record
			or pending.lifeSequence ~= record.lifeSequence
			or pending.matchId ~= MatchService.GetMatchId()
		then
			pendingExternalEliminations[player] = {
				record = record,
				character = record.character,
				lifeSequence = record.lifeSequence,
				matchId = MatchService.GetMatchId(),
				means = resolvedMeans,
				collisionContext = ORDINARY_EXTERNAL_DEATH_CONTEXT,
				requireDeadHumanoid = false,
			}
		end
		return true
	end
	local context = makeEnvironmentContext(player, record)
	local applied, applyError = executeDirectDeath({
		kind = "ForcedWorldPlayerDie",
		target = player,
		attacker = nil,
		rawDamage = nil,
		direction = nil,
		shot = context,
		targetBody = nil,
		projectileSource = nil,
		worldMeans = resolvedMeans,
	})
	assert(applied, applyError or "forced-world death failed")
	return applied
end

function CombatService.GetMoverDamageAdapter(): MoverDamageAdapter
	return moverDamageAdapter
end

-- Legacy direct callbacks deliberately fail closed. Mover simulation must hold
-- the opaque adapter capability and cannot publish damage before its frame commits.
function CombatService.HandleMoverCrush(
	_player: Player,
	_moverId: string
): (MoverPushRules.SynchronousCrushTransition?, string?)
	return nil, "direct-mover-damage-disabled"
end

function CombatService.HandleBinaryMoverBlocked(
	_player: Player,
	_moverId: string,
	_damage: number
): (MoverPushRules.SynchronousCrushTransition?, string?)
	return nil, "direct-mover-damage-disabled"
end

function CombatService.EliminateForTelefrag(
	target: Player,
	attacker: Player,
	provisionalLifeBinding: MovementService.MovementLifeBinding?
): boolean
	local attackerRecord = records[attacker]
	if target == attacker or not attackerRecord then
		return false
	end
	local targetRecord = records[target]
	if not targetRecord then
		return false
	end
	if not targetRecord.alive then
		return true
	end
	local attackerRevision = MovementService.GetRevision(attacker)
	local authoritativeFrame = AuthoritativeFrameService.GetOpenFrame()
	local authoritativeSummary = if authoritativeFrame
		then AuthoritativeFrameService.InspectFrame(authoritativeFrame)
		else nil
	if attackerRevision == nil or authoritativeSummary == nil then
		return false
	end
	local attackerState = MovementService.GetState(attacker)
	local context: ShotContext = {
		id = string.format("telefrag:%d:%d:%d", attacker.UserId, target.UserId, targetRecord.lifeSequence),
		matchId = MatchService.GetSnapshot().matchId,
		lifeSequence = attackerRecord.lifeSequence,
		weaponId = WeaponDefinitions.WeaponId.None,
		ownerUserId = attacker.UserId,
		revision = attackerRevision,
		clientSequence = 0,
		serverFrame = if attackerState then attackerState.frame else 0,
		levelTimeMilliseconds = authoritativeSummary.currentTimeMilliseconds,
		firedAtServerTime = presentationTimeForLevel(authoritativeSummary.currentTimeMilliseconds),
		eventSequence = 0,
		seed = 0,
		inputReceivedServerTime = nil,
	}
	local installedProvisionalBinding = false
	if provisionalLifeBinding and attackerRecord.movementLifeBinding == nil then
		local provisionalSummary = MovementService.InspectMovementLifeBinding(provisionalLifeBinding)
		if
			not provisionalSummary
			or provisionalSummary.player ~= attacker
			or provisionalSummary.lifeSequence ~= attackerRecord.lifeSequence
		then
			return false
		end
		attackerRecord.movementLifeBinding = provisionalLifeBinding
		installedProvisionalBinding = true
	end
	if attackerRecord.alive and attackerRecord.movementLifeBinding ~= nil then
		local applied, applyError = executeDirectDeath({
			kind = "Telefrag",
			target = target,
			attacker = attacker,
			rawDamage = nil,
			direction = nil,
			shot = context,
			targetBody = nil,
			projectileSource = nil,
			worldMeans = nil,
		})
		if not applied then
			if installedProvisionalBinding then
				attackerRecord.movementLifeBinding = nil
			end
			warn(applyError or "live Telefrag direct-death composition failed")
		end
		return applied
	end
	return false
end

function CombatService.GetHitscanRewindObservations(): { HitscanRewindObservation }
	return CombatHitscanRewindRuntime.GetObservations()
end

function CombatService.GetHitscanRewindDebugMetrics(): HitscanRewindDebugMetrics
	return CombatHitscanRewindRuntime.GetDebugMetrics()
end

function CombatService.Start(arenaWorld: Folder)
	assert(not started, "CombatService.Start may only be called once")
	local departureOwner, departureOwnerError = CorpseService.ClaimDepartureCleanupOwner()
	assert(departureOwner, departureOwnerError or "corpse departure cleanup owner unavailable")
	corpseDepartureCleanupOwner = departureOwner
	local matchTransitionOwner, matchTransitionOwnerError = CorpseService.ClaimMatchTransitionCleanupOwner()
	assert(matchTransitionOwner, matchTransitionOwnerError or "corpse Match-transition cleanup owner unavailable")
	corpseMatchTransitionCleanupOwner = matchTransitionOwner
	local movementTransitionOwner, movementTransitionOwnerError = MovementService.ClaimMatchTransitionCleanupOwner()
	assert(
		movementTransitionOwner,
		movementTransitionOwnerError or "Movement Match-transition cleanup owner unavailable"
	)
	movementMatchTransitionCleanupOwner = movementTransitionOwner
	started = true
	worldFolder = arenaWorld
	Players.RespawnTime = MatchService.GetRules().ForcedRespawnSeconds

	local network = sharedRoot:WaitForChild(RemoteNames.Folder) :: Folder
	local fireRemote = ensureRemote(network, RemoteNames.FireCommand)
	local suicideRemote = ensureRemote(network, RemoteNames.SuicideRequest)
	snapshotRemote = ensureRemote(network, RemoteNames.CombatSnapshot)
	eventRemote = ensureRemote(network, RemoteNames.CombatEvent)
	local combatSnapshotRequestRemote = assert(snapshotRemote, "CombatSnapshot remote is unavailable")
	combatSnapshotRequestRemote.OnServerEvent:Connect(function(player: Player)
		local now = os.clock()
		local previous = snapshotRequestTimes[player] or -math.huge
		if now - previous < 0.5 then
			return
		end
		snapshotRequestTimes[player] = now
		syncPlayer(player)
	end)

	assert(
		#projectiles == 0 and next(projectilesByRegistration) == nil and next(projectilesBySource) == nil,
		"CombatService started with stale projectile mirrors"
	)
	CombatHitscanRewindRuntime.Reset()
	table.clear(pendingGauntletPrePmoveByPlayer)
	local oldProjectileFolder = Workspace:FindFirstChild("Q3EngineProjectiles")
	if oldProjectileFolder then
		oldProjectileFolder:Destroy()
	end
	local newProjectileFolder = Instance.new("Folder")
	newProjectileFolder.Name = "Q3EngineProjectiles"
	newProjectileFolder.Parent = Workspace
	projectileFolder = newProjectileFolder
	local dynamicBindingActivated, dynamicBindingError =
		ProjectileEntityService.ActivateDynamicBinding(CombatService.HandleDynamicProjectile)
	assert(
		dynamicBindingActivated,
		dynamicBindingError or "projectile dynamic dispatcher binding could not be activated"
	)
	projectileDynamicBindingActivated = true
	MovementService.SetAuthoritativeStepObserver(recordAuthoritativeHistorySample)
	MovementService.SetPrePmoveCommandHandler(CombatService.HandlePrePmoveCommand)
	MovementService.SetClientTimerHandler(CombatService.HandleClientTimer)
	MovementService.SetSimulationFaultHandler(CombatService.HandleSimulationFault)

	fireRemote.OnServerEvent:Connect(function(player: Player, payload: unknown)
		local record = records[player]
		if not record then
			return
		end

		local now = os.clock()
		if now - record.rateWindowStart >= 1 then
			record.rateWindowStart = now
			record.rateWindowCount = 0
		end
		record.rateWindowCount += 1
		if record.rateWindowCount > WeaponDefinitions.MaximumFireCommandsPerSecond then
			return
		end
		if not hasExactKeys(payload, FIRE_PAYLOAD_KEYS, 1) then
			return
		end
		-- FireCommand is retained only for Q3's attack-gated dead respawn. Live
		-- weapon fire comes exclusively from the atomic InputCommand path.
		if record.alive then
			return
		end
		local request = payload :: any
		local sequence = request.sequence
		if not WeaponDefinitions.IsValidSequence(sequence, record.lastRespawnRequestSequence) then
			return
		end
		record.lastRespawnRequestSequence = sequence
		record.manualRespawnQueued = true
	end)
	suicideRemote.OnServerEvent:Connect(function(player: Player, payload: unknown)
		-- FireServer() supplies no payload. Reject every client-authored field.
		if payload ~= nil then
			return
		end
		local record = records[player]
		if not record or not record.alive or pendingSuicides[player] ~= nil then
			return
		end
		local now = os.clock()
		if now - (suicideRequestTimes[player] or -math.huge) < 1 then
			return
		end
		suicideRequestTimes[player] = now
		pendingSuicides[player] = { record = record, lifeSequence = record.lifeSequence }
	end)

	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local activeDirectDeath = directDeathOwner.activePrepared
		if activeDirectDeath then
			local activeCapability = assert(
				directDeathOwner.preparedCapabilities[activeDirectDeath],
				"active direct death lost its owner capability"
			)
			if activeCapability.status == "Prepared" then
				local aborted, abortError = CombatService.AbortPreparedDirectDeath(activeDirectDeath)
				assert(aborted, abortError or "departing player direct death could not abort")
			elseif activeCapability.status == "Applied" then
				if player == activeCapability.mutation.target or player == activeCapability.mutation.attacker then
					local departureError = directDeathOwner.appliedDepartureError(activeCapability, player)
					assert(departureError == nil, departureError or "departing player direct death became stale")
					directDeathOwner.flushAppliedPublication(activeCapability, false)
				else
					CombatService.FlushPreparedDirectDeath(activeCapability.receipt)
				end
			else
				error("departing player encountered an invalid active direct-death state")
			end
		end
		local directDeathHandoff = directDeathOwner.handoffByPlayer[player]
		local directDeathHandoffCapability = if directDeathHandoff
			then directDeathOwner.handoffCapabilities[directDeathHandoff]
			else nil
		assert(
			CorpseService.ClearDepartingPlayer(player, corpseDepartureCleanupOwner),
			"departing client corpse could not be cleared"
		)
		if directDeathHandoffCapability then
			directDeathOwner.retireHandoffCapability(directDeathHandoffCapability)
		end
		projectileRuntime.queueCleanup(
			player,
			ProjectileEntityLifecycleRules.AdministrativeReleaseReason.OwnerDisconnected
		)
		pendingExternalEliminations[player] = nil
		pendingSuicides[player] = nil
		suicideRequestTimes[player] = nil
		snapshotRequestTimes[player] = nil
		CombatHitscanRewindRuntime.RemovePlayer(player)
		pendingGauntletPrePmoveByPlayer[player] = nil
		records[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end

	local observedMatchId = MatchService.GetMatchId()
	MatchService.OnAuthorityStateChanged(function(snapshot: any)
		local snapshotMatchId = if type(snapshot) == "table" then snapshot.matchId else nil
		if type(observedMatchId) == "string" and observedMatchId ~= "" and snapshotMatchId ~= observedMatchId then
			pendingPostBeginMatchCleanupId = observedMatchId
			local cleanupOwner =
				assert(corpseMatchTransitionCleanupOwner, "corpse Match-transition cleanup owner disappeared")
			for player in records do
				-- A Humanoid/world callback captured under the retired Match may not
				-- execute after the replacement identity is installed, even when Roblox
				-- has not produced the replacement Character yet.
				pendingExternalEliminations[player] = nil
				pendingSuicides[player] = nil
				local record = records[player]
				local transitionHumanoid = if record and record.character
					then record.character:FindFirstChildOfClass("Humanoid")
					else nil
				local transitionDead = record ~= nil
					and (
						not record.alive
						or transitionHumanoid == nil
						or transitionHumanoid.Health <= 0
						or transitionHumanoid:GetState() == Enum.HumanoidStateType.Dead
					)
				if record and not transitionDead and transitionHumanoid then
					record.characterMatchId = snapshotMatchId
				end
				if record and transitionDead then
					record.health = 0
					record.armor = 0
					record.alive = false
					record.characterMatchId = nil
					setCharacterCombatQuery(record.character, false)
				end
				assert(
					CorpseService.ClearPlayerForMatchTransition(player, cleanupOwner, observedMatchId),
					"old-Match client corpse could not be cleared"
				)
				if record and transitionDead and MovementService.GetState(player) ~= nil then
					assert(
						MovementService.RetireDeadClientForMatchTransition(
							player,
							assert(
								movementMatchTransitionCleanupOwner,
								"Movement Match-transition cleanup owner disappeared"
							)
						),
						"old-Match dead Movement client could not retire"
					)
				end
				local handoff = directDeathOwner.handoffByPlayer[player]
				local handoffCapability = if handoff then directDeathOwner.handoffCapabilities[handoff] else nil
				if handoffCapability then
					directDeathOwner.retireHandoffCapability(handoffCapability)
				end
			end
			local corpseDebug = CorpseService.GetDebugSnapshot()
			assert(
				corpseDebug.committedCorpseCount == 0 and corpseDebug.committedTombstoneCount == 0,
				"Match transition retained client corpse authority"
			)
		end
		observedMatchId = snapshotMatchId
		if type(snapshot) == "table" and snapshot.state ~= "Live" then
			projectileRuntime.queueCleanup(nil, ProjectileEntityLifecycleRules.AdministrativeReleaseReason.MatchCleanup)
		end
		if type(snapshot) == "table" then
			resetAccuracyForMatchIdentity(snapshot.matchId)
		end
		for player, record in records do
			if not MatchService.CanPlayerSpawn(player) then
				MovementService.ReleaseSpawn(player)
				record.health = 0
				record.armor = 0
				record.alive = false
				record.overstackAccumulator = 0
				record.respawnEligibleAtMilliseconds = nil
				record.forcedRespawnAtMilliseconds = nil
				record.manualRespawnQueued = false
				record.respawnRequested = false
				pendingExternalEliminations[player] = nil
				setCharacterCombatQuery(record.character, false)
			end
			syncPlayer(player)
		end
	end)
	MatchService.SetRespawnHandler(function(player: Player, delaySeconds: number)
		local record = records[player]
		if not record then
			return
		end
		local frame = assert(
			AuthoritativeFrameService.GetOpenFrame(),
			"Match respawn request occurred outside the authoritative frame"
		)
		local summary =
			assert(AuthoritativeFrameService.InspectFrame(frame), "Match respawn request lost its authoritative frame")
		local levelTimeMilliseconds = summary.currentTimeMilliseconds
		assert(
			isFinite(delaySeconds) and delaySeconds >= 0,
			"Match respawn delay must be a finite nonnegative duration"
		)
		if delaySeconds > 0 then
			local respawnEligibleAtMilliseconds = assert(
				MatchFrameRules.DeadlineMilliseconds(levelTimeMilliseconds, delaySeconds),
				"Match respawn delay overflowed integer level time"
			)
			local forcedRespawnSeconds = MatchService.GetRules().ForcedRespawnSeconds
			local forcedRespawnAtMilliseconds = if forcedRespawnSeconds > 0
				then assert(
					MatchFrameRules.DeadlineMilliseconds(respawnEligibleAtMilliseconds, forcedRespawnSeconds),
					"forced respawn deadline overflowed integer level time"
				)
				else nil
			directDeathOwner.rebindHandoffRespawnDeadlines(
				player,
				record,
				respawnEligibleAtMilliseconds,
				forcedRespawnAtMilliseconds
			)
			record.manualRespawnQueued = false
			record.respawnRequested = false
			syncPlayer(player)
			return
		end
		-- Arena round setup can request a zero-delay spawn while the player still
		-- owns the durable CopyToBodyQue handoff from the eliminated life. Do not
		-- bypass that tombstone through the surviving-character shortcut. Queue the
		-- normal PM_DEAD coordinator so its post-Pmove capture copies the body and
		-- consumes every corpse/dead-client root before Roblox replaces the avatar.
		if not record.alive and directDeathOwner.handoffByPlayer[player] ~= nil then
			directDeathOwner.rebindHandoffRespawnDeadlines(player, record, levelTimeMilliseconds, nil)
			record.manualRespawnQueued = true
			record.respawnRequested = false
			syncPlayer(player)
			return
		end
		-- Q3 missiles survive an ordinary live respawn. Match-state transitions
		-- clear the whole projectile set above, while disconnects clear ownership.
		local character = record.character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not MatchService.CanPlayerSpawn(player) then
			return
		end
		if
			not character
			or not humanoid
			or humanoid.Health <= 0
			or humanoid:GetState() == Enum.HumanoidStateType.Dead
		then
			-- Q3 respawn -> ClientSpawn is one synchronous replacement. LoadCharacter
			-- is the yielding Roblox boundary, so a Match transition that observes the
			-- still-missing body must preserve an already-issued request instead of
			-- clearing its latch and starting a second replacement on the next frame.
			directDeathOwner.rebindHandoffRespawnDeadlines(player, record, levelTimeMilliseconds, nil)
			if not record.respawnRequested then
				record.manualRespawnQueued = true
			end
			syncPlayer(player)
			return
		end

		local loadout = MatchService.GetSpawnLoadout(player)
		assert(CorpseService.ClearPlayer(player), "client corpse could not be cleared before same-character respawn")
		record.baseHealth = loadout.maxHealth
		record.health = loadout.health
		record.armor = loadout.armor
		record.alive = true
		record.environmentDamageState = assert(
			EnvironmentDamageRules.SpawnState(levelTimeMilliseconds),
			"same-character respawn environment-damage state must be valid"
		)
		record.pendingPainFeedbackLevelTimeMilliseconds = nil
		record.overstackAccumulator = 0
		record.respawnEligibleAtMilliseconds = nil
		record.forcedRespawnAtMilliseconds = nil
		record.manualRespawnQueued = false
		record.respawnRequested = false
		pendingExternalEliminations[player] = nil
		local spawnRules = MatchService.GetRules()
		CombatInventoryRuntime.Reset(
			record,
			spawnRules,
			loadout.weaponId,
			if spawnRules.ModeId == "ArenaElimination"
					and MatchService.GetState() == MatchConfig.States.Warmup
				then true
				else nil
		)
		record.railJumpReadyAtMilliseconds = 0
		local nextLifeSequence = math.max(lastLifeSequenceByUserId[player.UserId] or 0, record.lifeSequence) + 1
		lastLifeSequenceByUserId[player.UserId] = nextLifeSequence
		record.lifeSequence = nextLifeSequence
		record.lastLandingFrame = -1
		record.lastLandingContactIndex = 0
		record.serverShotSequence = 0
		record.lastShotId = ""
		record.movementLifeBinding = nil
		humanoid.MaxHealth = math.max(loadout.maxHealth, loadout.health)
		humanoid.Health = loadout.health
		if not MovementService.Respawn(player) then
			record.health = 0
			record.armor = 0
			record.alive = false
			record.respawnEligibleAtMilliseconds = levelTimeMilliseconds
			record.forcedRespawnAtMilliseconds = nil
			record.manualRespawnQueued = true
			record.respawnRequested = false
			setCharacterCombatQuery(character, false)
			humanoid.Health = 0
			syncPlayer(player)
			return
		end
		local movementLifeBinding = MovementService.ConfirmSpawn(player, nextLifeSequence)
		if not movementLifeBinding then
			record.health = 0
			record.armor = 0
			record.alive = false
			record.movementLifeBinding = nil
			record.respawnEligibleAtMilliseconds = levelTimeMilliseconds
			record.forcedRespawnAtMilliseconds = nil
			record.manualRespawnQueued = true
			record.respawnRequested = false
			MovementService.ReleaseSpawn(player)
			setCharacterCombatQuery(character, false)
			humanoid.Health = 0
			syncPlayer(player)
			return
		end
		record.movementLifeBinding = movementLifeBinding
		record.characterMatchId = MatchService.GetMatchId()
		setCharacterCombatQuery(character, true)
		MatchService.NotifyPlayerRespawned(player)
		syncPlayer(player)
	end)
end

return table.freeze(CombatService)
