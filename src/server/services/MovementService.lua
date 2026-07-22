--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server runtime for the Quake III-derived movement translation in
ReplicatedStorage/Q3Engine/simulation/Movement.lua.

Also integrates selected world-trigger and landing behavior from:
  code/game/g_combat.c (G_Damage impulse/PMF_TIME_KNOCKBACK ordering,
    player_die PM_DEAD selection, LookAtKiller, generic-to-player view copy)
  code/game/g_mover.c (G_MoverPush inline Sine G_Damage and blocked Door
    post-rebase/pre-reversal callback identity)
  code/game/bg_pmove.c (first PM_DEAD water sample through the retained alive
    viewheight, then PM_CheckDuck DEAD_VIEWHEIGHT)
  code/game/bg_pmove.c (PM_CrashLand)
  code/game/bg_misc.c (BG_TouchJumpPad, BG_PlayerStateToEntityState,
    BG_PlayerStateToEntityStateExtraPolate)
  code/game/g_active.c (ClientThink_real atomic usercmd processing,
    synchronous G_RunClient cached-command stepping, ClientEndFrame
    entity-state refresh)
  code/game/g_client.c (CopyToBodyQue grounded copied trDelta versus airborne
    current player-state velocity)
  code/game/g_trigger.c (trigger_push, AimAtTarget, trigger_teleporter)
  code/game/g_misc.c and code/game/g_utils.c (TeleportPlayer, G_KillBox)

Remote opponent frames retain the Q3 snapshot/interpolation split from:
  code/server/sv_snapshot.c (server snapshot cadence)
  code/cgame/cg_snapshot.c and code/cgame/cg_ents.c (client presentation input)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MapMoverContract = require(sharedRoot:WaitForChild("maps"):WaitForChild("MapMoverContract"))
local MapSpatialRules = require(sharedRoot:WaitForChild("maps"):WaitForChild("MapSpatialRules"))
local CommandSequence =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("CommandSequence"))
local CommandQuantization =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("CommandQuantization"))
local CommandQueueRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("CommandQueueRules"))
local Constants = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Constants"))
local HumanoidMovementStatePolicy =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("HumanoidMovementStatePolicy"))
local DeathTransitionRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("DeathTransitionRules"))
local EntityStateConversionRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntityStateConversionRules"))
local EntitySourceOrderRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntitySourceOrderRules"))
local Landing = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Landing"))
local Movement = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Movement"))
local MovementPhaseRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MovementPhaseRules"))
local MoverClock = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverClock"))
local MoverBinaryPolicy =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverBinaryPolicy"))
local MoverBinaryState =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverBinaryState"))
local MoverCollisionFrame =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverCollisionFrame"))
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))
local MoverRuntimeRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverRuntimeRules"))
local MoverSnapshotContract =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverSnapshotContract"))
local MoverTraceComposition =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverTraceComposition"))
local MoverTrajectory =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverTrajectory"))
local PmoveEventOrder =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("PmoveEventOrder"))
local PersistentStaticSolidDomain =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("PersistentStaticSolidDomain"))
local PlayerClipDomain =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("PlayerClipDomain"))
local SpawnSelection = require(sharedRoot:WaitForChild("simulation"):WaitForChild("SpawnSelection"))
local RocketArenaSpawnRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("RocketArenaSpawnRules"))
local SurfaceContact = require(sharedRoot:WaitForChild("simulation"):WaitForChild("SurfaceContact"))
local SweptAABB = require(sharedRoot:WaitForChild("simulation"):WaitForChild("SweptAABB"))
local TraceClipRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("TraceClipRules"))
local WorldOccupancyQuery =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldOccupancyQuery"))
local WorldPointContents =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldPointContents"))
local WorldTriggerRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldTriggerRules"))
local RemoteNames = require(sharedRoot:WaitForChild("RemoteNames"))
local WeaponDefinitions =
	require(sharedRoot:WaitForChild("combat"):WaitForChild("WeaponDefinitions"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local FramePublicationSpool = require(script.Parent.FramePublicationSpool)
local MovementMoverBodyRuntime = require(script.Parent.MovementMoverBodyRuntime)
local MovementMoverCompositeRuntime = require(script.Parent.MovementMoverCompositeRuntime)
local MovementMoverPlayerRuntime = require(script.Parent.MovementMoverPlayerRuntime)
local MovementMoverPresentationRuntime = require(script.Parent.MovementMoverPresentationRuntime)
local MovementMoverRuntime = require(script.Parent.MovementMoverRuntime)
local MovementRemoteRuntime = require(script.Parent.MovementRemoteRuntime)
local MovementDeadRuntime = require(script.Parent.MovementDeadRuntime)
local MovementLifeBindingRuntime = require(script.Parent.MovementLifeBindingRuntime)
local MovementNormalToDeadAuthorityRuntime =
	require(script.Parent.MovementNormalToDeadAuthorityRuntime)
local MovementNormalToDeadSourceRuntime = require(script.Parent.MovementNormalToDeadSourceRuntime)
local MovementNormalToDeadStateRuntime = require(script.Parent.MovementNormalToDeadStateRuntime)
local MovementNormalToDeadPreparedRegistry =
	require(script.Parent.MovementNormalToDeadPreparedRegistry)
local MovementTelemetryRuntime = require(script.Parent.MovementTelemetryRuntime)
local MovementTeleportRuntime = require(script.Parent.MovementTeleportRuntime)

local MovementService = {}

type QueuedCommand = {
	sequence: number,
	command: Movement.Command,
	-- Captured by the server at RemoteEvent arrival. The client never supplies
	-- the timestamp used by shadow hitscan-rewind measurement.
	receivedServerTime: number,
}

type AuthoritativeStepObserver = (
	player: Player,
	state: Movement.State,
	revision: number,
	serverTime: number
) -> ()
type AuthoritativeFrameHandler = (frame: AuthoritativeFrameService.Frame) -> ()
type AuthoritativeFrameBeginHandler = (frame: AuthoritativeFrameService.Frame) -> ()
type PostClientEndFrameHandler = (frame: AuthoritativeFrameService.Frame) -> (() -> ())?
type ClientTriggerFrameHandler = (frame: AuthoritativeFrameService.Frame, player: Player) -> ()
type DoorTriggerFrameHandler = (frame: AuthoritativeFrameService.Frame, player: Player) -> ()
type PreMoverEntityFrameHandler = (frame: AuthoritativeFrameService.Frame) -> ()
type PostMoverDynamicFrameHandler = (frame: AuthoritativeFrameService.Frame) -> ()

type TriggerDefinition = WorldTriggerRules.Definition
type JumpPadEntryState = WorldTriggerRules.JumpPadEntryState
type LandingResult = Landing.Result
type PreparedAttack = () -> ()
type PrePmoveCommandData = unknown
type WaterEventHandler = (
	player: Player,
	event: Movement.WaterEvent,
	eventIndex: number
) -> boolean
export type MoverDamageAdapter = {
	Begin: (
		frame: AuthoritativeFrameService.Frame,
		stepServerTime: number
	) -> (unknown?, string?),
	CollectBodies: (
		token: unknown
	) -> ({ MoverPushRules.Body }?, { [string]: Player }?, string?),
	StageSineCrush: (
		token: unknown,
		player: Player,
		moverId: string,
		body: MoverPushRules.Body,
		moverDeathSource: MoverDeathSource?,
		moverDeathSourceSummary: MoverDeathSourceSummary?
	) -> (MoverPushRules.SynchronousCrushTransition?, string?),
	StageDoorDamage: (
		token: unknown,
		player: Player,
		moverId: string,
		damage: number,
		body: MoverPushRules.Body,
		moverDeathSource: MoverDeathSource?,
		moverDeathSourceSummary: MoverDeathSourceSummary?
	) -> (MoverPushRules.SynchronousCrushTransition?, string?),
	ValidateMoverDeathStageReceipt: (
		token: unknown,
		stageReceipt: unknown,
		moverDeathSource: unknown,
		moverDeathSourceSummary: unknown
	) -> (boolean, string?),
	IsAlive: (token: unknown, player: Player) -> boolean?,
	ApplyMoverBodies: (token: unknown, bodies: { MoverPushRules.Body }) -> (boolean, string?),
	Seal: (token: unknown) -> (boolean, string?),
	Prepare: (token: unknown) -> (unknown?, unknown?, string?),
	InspectPreparedMovementDependency: (prepared: unknown) -> unknown?,
	ValidatePreparedMovementDependency: (
		prepared: unknown,
		summary: unknown
	) -> (boolean, string?),
	CanApplyPrepared: (prepared: unknown) -> (boolean, string?),
	ApplyPrepared: (prepared: unknown) -> unknown,
	FlushPrepared: (receipt: unknown) -> unknown,
	Abort: (token: unknown) -> boolean,
}
export type MoverParticipantAdapter = {
	BeginFrame: (stepTimeMilliseconds: number) -> (boolean, string?),
	AbortFrame: () -> boolean,
	Collect: () -> MoverItemFlagParticipantRules.Collection,
	ResolveSine: (bodyId: string) -> MoverItemFlagParticipantRules.SynchronousCrushEffect,
	ResolveBlockedDoor: (bodyId: string) -> MoverItemFlagParticipantRules.Transition,
	Prepare: (finalBodies: unknown) -> (unknown?, string?),
	CanApply: (prepared: unknown) -> (boolean, string?),
	Apply: (prepared: unknown) -> unknown,
	Flush: (receipt: unknown) -> boolean,
	Abort: (prepared: unknown) -> boolean,
}
export type MoverBodyQueueAdapter = {
	Collect: () -> ({ MoverPushRules.Body }, { [string]: number }),
	ResolveSine: (bodyId: string) -> MoverPushRules.BodyMutation,
	ResolveBlockedDoor: (bodyId: string) -> MoverPushRules.BodyMutation,
	Prepare: (finalBodies: unknown) -> (unknown?, string?),
	CanApply: (prepared: unknown) -> (boolean, string?),
	Apply: (prepared: unknown) -> unknown,
	Flush: (receipt: unknown) -> boolean,
	Abort: (prepared: unknown) -> boolean,
}
type CommandHandler = (
	player: Player,
	inputSequence: number,
	receivedServerTime: number,
	state: Movement.State,
	command: Movement.Command,
	revision: number,
	stepServerTime: number,
	stepLevelTimeMilliseconds: number,
	stepMsec: number,
	freshCommand: boolean,
	prePmoveData: PrePmoveCommandData?
) -> PreparedAttack?
type PrePmoveCommandHandler = (
	player: Player,
	inputSequence: number,
	receivedServerTime: number,
	state: Movement.State,
	command: Movement.Command,
	revision: number,
	stepServerTime: number,
	stepLevelTimeMilliseconds: number,
	freshCommand: boolean
) -> PrePmoveCommandData?
type DeadCommandHandler = (
	player: Player,
	command: Movement.Command,
	attackPressed: boolean,
	useHoldablePressed: boolean,
	levelTimeMilliseconds: number,
	postPmoveCapture: unknown,
	postPmoveCaptureSummary: unknown,
	playerStateVelocity: Vector3
) -> ()
type ClientTimerHandler = (player: Player, msec: number, levelTimeMilliseconds: number) -> ()
type SimulationFaultHandler = () -> ()

local function assertImmediateCorpseMoverDamageEffect(
	effect: MoverPushRules.SynchronousCrushEffect
): MoverPushRules.SynchronousCrushEffect
	assert(table.isfrozen(effect), "mover damage effect must be immutable")
	assert(
		effect.kind == "Retain" or effect.kind == "Remove" or effect.kind == "Replace",
		"mover damage returned an unsupported immediate-corpse effect"
	)
	assert(
		table.isfrozen(effect.insertedBodies),
		"immediate corpse integration requires an immutable insertion batch"
	)
	return effect
end

type SpawnPoint = {
	index: number,
	origin: Vector3,
	teamId: string?,
	facing: Vector3,
	spawnClass: string?,
}

type SpawnChoice = {
	spawnIndex: number,
	origin: Vector3,
	facing: Vector3,
	telefragUserIds: { number },
	usedTelefragFallback: boolean,
}

export type MovementLifeBinding = {}
export type MovementLifeBindingSummary = {
	read player: Player,
	read playerUserId: number,
	read character: Model,
	read recordLineage: {},
	read registration: EntitySlotService.Registration,
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read lifeSequence: number,
}

-- Normal-to-Dead sources are opaque server capabilities. World/current player
-- identities are owned locally; ProjectileEntityService contributes a
-- Missile-only provider capability through a composition-root adapter. Mover
-- and arbitrary external vector sources remain fail-closed.
export type NormalToDeadSource = {}
export type NormalToDeadSourceSummary = {
	read kind: "World" | "Player" | "Projectile",
	read player: Player?,
	read lifeBinding: MovementLifeBinding?,
	read lifeSummary: MovementLifeBindingSummary?,
	read entityTrajectoryBase: Vector3,
}

export type ProjectileDeathSourceAdapter = {
	read Capture: (sourceValue: unknown) -> (unknown?, unknown?, string?),
	read Validate: (inflictorValue: unknown, summaryValue: unknown) -> (boolean, string?),
}

export type MoverDeathSource = {}
export type MoverDeathSourceSummary = {
	read kind: "Mover",
	read victim: Player,
	read victimUserId: number,
	read victimLifeBinding: MovementLifeBinding,
	read victimLifeSummary: MovementLifeBindingSummary,
	read victimBody: MoverPushRules.Body,
	read callbackKind: "SinePush" | "BlockedDoor",
	read callbackTraversalOrder: number,
	read frame: AuthoritativeFrameService.Frame,
	read frameSummary: AuthoritativeFrameService.Summary,
	read clockWindow: MoverClock.Window,
	read baseMoverAuthorityGeneration: number,
	read moverId: string,
	read teamId: string,
	read moverSourceOrder: number,
	read mapRegistration: EntitySlotService.MapRegistration,
	read registration: EntitySlotService.Registration,
	read lease: EntitySourceOrderRules.Lease,
	read definition: MoverPushRules.Definition,
	read entityTrajectoryBase: Vector3,
}

export type NormalToDeadMovementSnapshot = MovementNormalToDeadStateRuntime.Snapshot

export type PreparedNormalToDead = {}
export type NormalToDeadApplyReceipt = {}
export type PreparedNormalToDeadBatch = {}
export type NormalToDeadBatchApplyReceipt = {}
export type NormalToDeadMode = "Direct" | "MoverPushed"
export type NormalToDeadSourceDependencySummary =
	NormalToDeadSourceSummary
	| MoverDeathSourceSummary
export type PreparedNormalToDeadSummary = {
	read mode: NormalToDeadMode,
	read player: Player,
	read playerUserId: number,
	read lifeBinding: MovementLifeBinding,
	read lifeSummary: MovementLifeBindingSummary,
	read baseState: NormalToDeadMovementSnapshot,
	read nextState: NormalToDeadMovementSnapshot,
	read prospectiveState: NormalToDeadMovementSnapshot,
	read deathTrajectoryBase: Vector3,
	read baseEntityTrajectoryBase: Vector3,
	read baseEntityTrajectoryDelta: Vector3,
	read baseEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	read nextEntityTrajectoryBase: Vector3,
	read nextEntityTrajectoryDelta: Vector3,
	read nextEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	read baseEntityGenericAngles: EntityStateConversionRules.Angles,
	read basePlayerStateViewAngles: EntityStateConversionRules.Angles,
	read callbackEntityTrajectoryBase: Vector3,
	read callbackEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	read baseSpawnReserved: boolean,
	read nextSpawnReserved: false,
	read lethalVelocityDelta: Vector3,
	read lethalKnockbackSeconds: number?,
	read attackerSource: NormalToDeadSourceDependencySummary,
	read inflictorSource: NormalToDeadSourceDependencySummary,
	read deathTransition: DeathTransitionRules.Result,
	read deadEntry: MovementPhaseRules.DeadEntryContract,
}
export type PreparedNormalToDeadBatchEntry = {
	read prepared: PreparedNormalToDead,
	read summary: PreparedNormalToDeadSummary,
	read receipt: NormalToDeadApplyReceipt,
}
export type PreparedNormalToDeadBatchSummary = {
	read operationCount: number,
	read records: { PreparedNormalToDeadSummary },
}
export type PreparedMoverNormalToDeadBatchDependency = {
	read operationCount: number,
	read batch: PreparedNormalToDeadBatch,
	read batchSummary: PreparedNormalToDeadBatchSummary,
	read batchReceipt: NormalToDeadBatchApplyReceipt,
	read memberReceipts: { NormalToDeadApplyReceipt },
}

type PlayerRecord = {
	registration: EntitySlotService.Registration,
	recordLineage: {},
	lifeSequence: number?,
	lifeBinding: MovementLifeBinding?,
	state: Movement.State?,
	-- BG_PlayerStateToEntityState owns a cached network/render projection that
	-- can legitimately differ from the precise current playerState. Keep its
	-- linear/angular trajectories, SetClientViewAngle's generic s.angles, and
	-- exact playerState viewangles as five distinct player/entity source domains
	-- for death, drops, and body-queue composition.
	entityTrajectoryBase: Vector3,
	-- BG_PlayerStateToEntityState refreshes this after Pmove and again at
	-- ClientEndFrame. Damage/trigger mutations after a projection remain distinct
	-- until the next explicit projection boundary.
	entityTrajectoryDelta: Vector3,
	entityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	entityGenericAngles: EntityStateConversionRules.Angles,
	-- playerState_t.viewangles remains a fifth, exact float-angle domain.
	-- Normal Pmove supplies SHORT2ANGLE values; SetClientViewAngle/player_die may
	-- supply authored generic floats that must not be forced through State shorts.
	playerStateViewAngles: EntityStateConversionRules.Angles,
	-- Dormant until the multi-owner player_die composite is live. The transition
	-- retains the exact pre-first-step viewheight independently of the future
	-- PM_DEAD command loop and its DEAD_VIEWHEIGHT phase.
	deadState: Movement.DeadState?,
	deathTransition: DeathTransitionRules.Result?,
	firstDeadStepPhase: MovementPhaseRules.Phase?,
	command: Movement.Command,
	character: Model?,
	commandQueue: { QueuedCommand },
	commandQueueHead: number,
	-- A spawn/teleport snapshot can precede the first command in its new
	-- revision. Repeated fixed steps use a presentation-stable raw view without
	-- replacing the last received pers.cmd angles used by SetClientViewAngle.
	awaitingViewCommand: boolean,
	lastReceivedSequence: number,
	lastProcessedSequence: number,
	rateWindowStart: number,
	rateWindowCount: number,
	revision: number,
	snapshotSequence: number,
	respawnCount: number,
	jumpPadEntryState: JumpPadEntryState,
	pendingTeleportLook: Vector3?,
	pendingTeleportTriggerId: number?,
	pendingSpawnLook: Vector3?,
	spawnReserved: boolean,
	pendingSpawnTelefragUserIds: { number }?,
	spawnIndex: number?,
	lastAuthoritativeOrigin: Vector3?,
	moverBodySourceOrder: number,
	moverBodyId: string,
	worldOccupants: WorldOccupancyQuery.QueryFunction,
	trace: Movement.TraceFunction,
	canOccupy: Movement.CanOccupyFunction,
	pointContents: Movement.PointContentsFunction,
}

type NormalToDeadSourceCapability = {
	source: NormalToDeadSource,
	summary: NormalToDeadSourceSummary,
	player: Player?,
	record: PlayerRecord?,
	lifeBinding: MovementLifeBinding?,
	lifeSummary: MovementLifeBindingSummary?,
	entityTrajectoryBase: Vector3,
	projectileInflictor: unknown?,
	projectileInflictorSummary: unknown?,
}

type PreparedNormalToDeadStatus = "Prepared" | "Applied" | "Aborted"
type NormalToDeadReceiptStatus = "Pending" | "Applied" | "Retired"
type NormalToDeadReceiptCapability = {
	receipt: NormalToDeadApplyReceipt,
	status: NormalToDeadReceiptStatus,
	mode: NormalToDeadMode,
	summary: PreparedNormalToDeadSummary,
	player: Player,
	record: PlayerRecord,
	lifeBinding: MovementLifeBinding,
	baseSpawnReserved: boolean,
	baseState: Movement.State,
	nextState: Movement.State,
	prospectiveState: Movement.State,
	deathTrajectoryBase: Vector3,
	nextEntityTrajectoryBase: Vector3,
	nextEntityTrajectoryDelta: Vector3,
	nextEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	deadState: Movement.DeadState,
	deathTransition: DeathTransitionRules.Result,
	firstDeadStepPhase: MovementPhaseRules.Phase,
	attackerSource: NormalToDeadSource | MoverDeathSource,
	attackerSourceSummary: NormalToDeadSourceDependencySummary,
	inflictorSource: NormalToDeadSource | MoverDeathSource,
	inflictorSourceSummary: NormalToDeadSourceDependencySummary,
	moverWitness: MoverNormalToDeadWitness?,
	outerBatchReceipt: NormalToDeadBatchApplyReceipt?,
	outerBatchIndex: number?,
}
type PreparedNormalToDeadCapability = {
	prepared: PreparedNormalToDead,
	status: PreparedNormalToDeadStatus,
	applyValidated: boolean,
	batchOwner: PreparedNormalToDeadBatch?,
	mode: NormalToDeadMode,
	player: Player,
	record: PlayerRecord,
	lifeBinding: MovementLifeBinding,
	lifeSummary: MovementLifeBindingSummary,
	baseState: Movement.State,
	baseStateSnapshot: NormalToDeadMovementSnapshot,
	nextState: Movement.State,
	nextStateSnapshot: NormalToDeadMovementSnapshot,
	prospectiveState: Movement.State,
	prospectiveStateSnapshot: NormalToDeadMovementSnapshot,
	deathTrajectoryBase: Vector3,
	baseEntityTrajectoryBase: Vector3,
	baseEntityTrajectoryDelta: Vector3,
	baseEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	nextEntityTrajectoryBase: Vector3,
	nextEntityTrajectoryDelta: Vector3,
	nextEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	baseEntityGenericAngles: EntityStateConversionRules.Angles,
	basePlayerStateViewAngles: EntityStateConversionRules.Angles,
	callbackEntityTrajectoryBase: Vector3,
	callbackEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	baseSpawnReserved: boolean,
	attackerSource: NormalToDeadSource | MoverDeathSource,
	attackerSourceSummary: NormalToDeadSourceDependencySummary,
	inflictorSource: NormalToDeadSource | MoverDeathSource,
	inflictorSourceSummary: NormalToDeadSourceDependencySummary,
	moverWitness: MoverNormalToDeadWitness?,
	deathTransition: DeathTransitionRules.Result,
	deadState: Movement.DeadState,
	firstDeadStepPhase: MovementPhaseRules.Phase,
	summary: PreparedNormalToDeadSummary,
	receipt: NormalToDeadApplyReceipt,
	receiptCapability: NormalToDeadReceiptCapability,
}
type PreparedNormalToDeadBatchEntryCapability = {
	prepared: PreparedNormalToDead,
	preparedCapability: PreparedNormalToDeadCapability,
	summary: PreparedNormalToDeadSummary,
	receipt: NormalToDeadApplyReceipt,
	player: Player,
	record: PlayerRecord,
	lifeBinding: MovementLifeBinding,
	registration: EntitySlotService.Registration,
}
type NormalToDeadBatchReceiptCapability = {
	receipt: NormalToDeadBatchApplyReceipt,
	status: NormalToDeadReceiptStatus,
	summary: PreparedNormalToDeadBatchSummary,
	receipts: { NormalToDeadApplyReceipt },
	entries: { PreparedNormalToDeadBatchEntryCapability },
}
type PreparedNormalToDeadBatchCapability = {
	prepared: PreparedNormalToDeadBatch,
	status: PreparedNormalToDeadStatus,
	applyValidated: boolean,
	outerMoverOwner: PreparedMoverStep?,
	entries: { PreparedNormalToDeadBatchEntryCapability },
	summary: PreparedNormalToDeadBatchSummary,
	receipts: { NormalToDeadApplyReceipt },
	receipt: NormalToDeadBatchApplyReceipt,
	receiptCapability: NormalToDeadBatchReceiptCapability,
}

type MovementLifeBindingStatus = "Current" | "Invalidated"
type MovementLifeBindingCapability = {
	handle: MovementLifeBinding,
	status: MovementLifeBindingStatus,
	player: Player,
	record: PlayerRecord,
	character: Model,
	registration: EntitySlotService.Registration,
	summary: MovementLifeBindingSummary,
}

type MoverBodyBinding =
	{
		kind: "LivePlayer",
		player: Player,
		record: PlayerRecord,
	}
	| {
		kind: "ClientCorpse",
		player: Player,
	}
	| {
		kind: "Item",
		bodyId: string,
	}
	| {
		kind: "BodyQueue",
		bodyId: string,
		queueIndex: number,
	}

type MoverPresentationOperation = MovementMoverPresentationRuntime.Operation

export type PreparedMoverStep = {}
export type MatchTransitionCleanupOwner = {}
export type MoverStepReceipt = {
	read movedPlayers: { [Player]: boolean },
	read damageToken: unknown?,
}

type MoverDeathSourceStatus = "Minted" | "Claimed" | "BoundLethal" | "Retired"
type MoverDeathSourceSessionStatus = "Preparing" | "Prepared" | "Bound" | "Retired"
type MoverDeathSourceSession = {
	status: MoverDeathSourceSessionStatus,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	clockWindow: MoverClock.Window,
	baseClock: MoverClock.Snapshot,
	baseMoverAuthorityGeneration: number,
	baseDefinitions: { MoverPushRules.Definition },
	damageAdapter: MoverDamageAdapter,
	damageToken: unknown,
	nextCallbackTraversalOrder: number,
	sources: { MoverDeathSourceCapability },
	preparedHandle: PreparedMoverStep?,
}
type MoverDeathSourceCapability = {
	source: MoverDeathSource,
	summary: MoverDeathSourceSummary,
	status: MoverDeathSourceStatus,
	session: MoverDeathSourceSession,
	record: PlayerRecord,
	lifeBinding: MovementLifeBinding,
	lifeSummary: MovementLifeBindingSummary,
	body: MoverPushRules.Body,
	definitionSet: { MoverPushRules.Definition },
	definition: MoverPushRules.Definition,
	mapRegistration: EntitySlotService.MapRegistration,
	lease: EntitySourceOrderRules.Lease,
	stageReceipt: unknown?,
	appliedNormalToDeadReceipt: NormalToDeadApplyReceipt?,
}

type MoverPlayerStateAssignment = {
	player: Player,
	record: PlayerRecord,
	baseState: Movement.State,
	nextState: Movement.State,
	removedCallbackBody: MoverPushRules.Body?,
	baseEntityTrajectoryDelta: Vector3,
	nextEntityTrajectoryDelta: Vector3,
	baseEntityTrajectoryBase: Vector3,
	nextEntityTrajectoryBase: Vector3,
	baseEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	nextEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	baseEntityGenericAngles: EntityStateConversionRules.Angles,
	basePlayerStateViewAngles: EntityStateConversionRules.Angles,
	nextPlayerStateViewAngles: EntityStateConversionRules.Angles,
}

type MoverNormalToDeadWitness = {
	source: MoverDeathSource,
	sourceSummary: MoverDeathSourceSummary,
	sourceCapability: MoverDeathSourceCapability,
	stageReceipt: unknown,
	assignment: MoverPlayerStateAssignment,
	outerPrepared: PreparedMoverStep,
	outerCapability: PreparedMoverStepCapability,
}

type PreparedMoverNormalToDeadApplyEntry = {
	member: PreparedNormalToDeadCapability,
	sourceCapability: MoverDeathSourceCapability,
}

type MoverRecordBaseline = {
	record: PlayerRecord,
	state: Movement.State?,
	awaitingViewCommand: boolean,
	lifeSequence: number?,
	lifeBinding: MovementLifeBinding?,
	entityTrajectoryBase: Vector3,
	entityTrajectoryDelta: Vector3,
	entityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	entityGenericAngles: EntityStateConversionRules.Angles,
	playerStateViewAngles: EntityStateConversionRules.Angles,
	deadState: Movement.DeadState?,
	deathTransition: DeathTransitionRules.Result?,
	firstDeadStepPhase: MovementPhaseRules.Phase?,
}

type MoverSpawnReservationAssignment = {
	player: Player,
	record: PlayerRecord,
	baseSpawnReserved: boolean,
}

type MoverStepDebugState = {
	moverCrushTransitionCount: number,
	moverCrushRemovedCount: number,
	moverCrushRetainedCount: number,
	lastCrushMoverId: string?,
	lastCrushBodyId: string?,
	lastCrushClockStep: number?,
	binaryUseTransitionCount: number,
	lastBinaryUseMoverId: string?,
	lastBinaryUseOutcome: MoverBinaryState.UseOutcome?,
	lastBinaryUseTimeMilliseconds: number?,
	lastBinaryUseClockStep: number?,
	binaryBlockedCallbackCount: number,
	binaryBlockedDamageCount: number,
	binaryBlockedReversalCount: number,
	binaryBlockedRemovalCount: number,
	lastBinaryBlockedMoverId: string?,
	lastBinaryBlockedBodyId: string?,
	lastBinaryBlockedTimeMilliseconds: number?,
}

type PreparedMoverStepStatus = "Prepared" | "Applied" | "Published" | "Aborted"
type PreparedMoverStepCapability = {
	status: PreparedMoverStepStatus,
	applyValidated: boolean,
	baseGeneration: number,
	nextGeneration: number,
	baseFixedStepTransactionOpen: boolean,
	baseWorldLimits: MapSpatialRules.WorldLimits?,
	baseAuthoredLegacyDefinitions: { MoverPushRules.Definition },
	baseBinaryPrograms: { MoverBinaryState.Program },
	baseBinaryPolicies: { MoverBinaryPolicy.Policy },
	baseBinaryPolicyByTeam: { [string]: MoverBinaryPolicy.Policy },
	baseBinaryMoverTeamIds: { [string]: boolean },
	baseBinaryMoverIds: { [string]: boolean },
	baseLegacyMoverIds: { [string]: boolean },
	basePresentationFolder: Folder?,
	baseBodyWorldOccupants: WorldOccupancyQuery.BodyQueryFunction?,
	baseDamageAdapter: MoverDamageAdapter?,
	baseParticipantAdapter: MoverParticipantAdapter?,
	baseBodyQueueAdapter: MoverBodyQueueAdapter?,
	baseLegacyDefinitions: { MoverPushRules.Definition },
	baseBinaryRuntime: MoverBinaryState.Runtime?,
	baseDefinitions: { MoverPushRules.Definition },
	baseClock: MoverClock.Snapshot,
	baseCollisionFrame: MoverCollisionFrame.Frame,
	baseSnapshotWire: MoverSnapshotContract.WireSnapshot?,
	basePendingBinaryMoverUses: { string },
	consumedBinaryMoverUses: { string },
	nextPendingBinaryMoverUses: { string },
	baseDebug: MoverStepDebugState,
	nextDebug: MoverStepDebugState,
	recordBaselines: { [Player]: MoverRecordBaseline },
	recordCount: number,
	stateAssignments: { MoverPlayerStateAssignment },
	boundNormalToDeadBatch: PreparedNormalToDeadBatch?,
	boundNormalToDeadBatchSummary: PreparedNormalToDeadBatchSummary?,
	boundNormalToDeadBatchReceipt: NormalToDeadBatchApplyReceipt?,
	boundNormalToDeadMemberReceipts: { NormalToDeadApplyReceipt }?,
	boundNormalToDeadDependency: PreparedMoverNormalToDeadBatchDependency?,
	lethalNormalToDeadRecords: { [PlayerRecord]: boolean },
	lethalNormalToDeadAssignments: { [PlayerRecord]: MoverPlayerStateAssignment },
	normalToDeadApplyEntries: { PreparedMoverNormalToDeadApplyEntry },
	boundCombatPrepared: unknown?,
	boundCombatMovementSummary: unknown?,
	moverDeathSession: MoverDeathSourceSession?,
	boundLethalMoverDeathSources: { MoverDeathSourceCapability },
	spawnReservationAssignments: { MoverSpawnReservationAssignment },
	nextLegacyDefinitions: { MoverPushRules.Definition },
	nextBinaryRuntime: MoverBinaryState.Runtime?,
	nextDefinitions: { MoverPushRules.Definition },
	nextClock: MoverClock.Snapshot,
	nextCollisionFrame: MoverCollisionFrame.Frame,
	nextSnapshotWire: MoverSnapshotContract.WireSnapshot,
	presentationOperations: { MoverPresentationOperation },
	damageToken: unknown?,
	participantPrepared: unknown?,
	bodyQueuePrepared: unknown?,
	receipt: MoverStepReceipt,
	preparedHandle: PreparedMoverStep,
}

type PreparedMoverNormalToDeadBundle = {
	memberCapabilities: { PreparedNormalToDeadCapability },
	batchCapability: PreparedNormalToDeadBatchCapability,
	dependency: PreparedMoverNormalToDeadBatchDependency,
	lethalRecords: { [PlayerRecord]: boolean },
	lethalAssignments: { [PlayerRecord]: MoverPlayerStateAssignment },
	applyEntries: { PreparedMoverNormalToDeadApplyEntry },
}

export type DebugMetrics = {
	heartbeatCount: number,
	fixedStepCount: number,
	currentAccumulatorSeconds: number,
	maximumAccumulatorSeconds: number,
	clampedTimeSeconds: number,
	maximumStepsPerHeartbeat: number,
	fixedStepCpuSeconds: number,
	maximumFixedStepCpuSeconds: number,
	frameOpenCpuSeconds: number,
	playerCpuSeconds: number,
	preMoverCpuSeconds: number,
	moverCpuSeconds: number,
	postMoverCpuSeconds: number,
	closeCpuSeconds: number,
	currentCommandBacklogByUserId: { [number]: number },
	maximumCommandBacklogByUserId: { [number]: number },
	queueCapacityRejectCount: number,
	rateRejectCount: number,
	remoteBatchCount: number,
	remotePacketCount: number,
	remoteRowCount: number,
	simulationFaulted: boolean,
}

export type StudioWaterJumpObservation = {
	frame: number,
	revision: number,
	position: Vector3,
	velocity: Vector3,
	movementTime: number,
}

export type PlayerEntityTrajectoryDiagnostic = {
	read entityTrajectoryBase: Vector3,
	read entityTrajectoryDelta: Vector3,
	read entityAngularTrajectoryBase: EntityStateConversionRules.Angles,
	read entityGenericAngles: EntityStateConversionRules.Angles,
	read playerStateViewAngles: EntityStateConversionRules.Angles,
	read playerStatePosition: Vector3,
	read playerStateVelocity: Vector3,
}

export type MoverDebugState = {
	clockRevision: number,
	clockStep: number,
	timeMilliseconds: number,
	definitionCount: number,
	legacyDefinitionCount: number,
	binaryProgramCount: number,
	binaryPolicyCount: number,
	binaryRuntimeRevision: number?,
	snapshotSchemaVersion: number,
	poseCount: number,
	queuedBinaryUseCount: number,
	binaryUseTransitionCount: number,
	lastBinaryUseMoverId: string?,
	lastBinaryUseOutcome: MoverBinaryState.UseOutcome?,
	lastBinaryUseTimeMilliseconds: number?,
	lastBinaryUseClockStep: number?,
	binaryBlockedCallbackCount: number,
	binaryBlockedDamageCount: number,
	binaryBlockedReversalCount: number,
	binaryBlockedRemovalCount: number,
	lastBinaryBlockedMoverId: string?,
	lastBinaryBlockedBodyId: string?,
	lastBinaryBlockedTimeMilliseconds: number?,
	crushTransitionCount: number,
	crushRemovedCount: number,
	crushRetainedCount: number,
	lastCrushMoverId: string?,
	lastCrushBodyId: string?,
	lastCrushClockStep: number?,
}

export type StudioBinaryMoverState = {
	moverId: string,
	state: MoverTrajectory.BinaryState,
	effectiveStartTimeMilliseconds: number,
	nextThinkTimeMilliseconds: number,
	runtimeRevision: number,
	queuedUseCount: number,
	useTransitionCount: number,
	lastUseMoverId: string?,
	lastUseOutcome: MoverBinaryState.UseOutcome?,
	lastUseTimeMilliseconds: number?,
	lastUseClockStep: number?,
}

export type BinaryMoverState = StudioBinaryMoverState

local DEFAULT_COMMAND: Movement.Command = table.freeze({
	forward = 0,
	right = 0,
	upMove = 0,
	pitch = 0,
	yaw = 0,
	roll = 0,
	buttons = 0,
	weaponId = WeaponDefinitions.InitialWeaponId,
})

local function stableViewFallbackCommand(
	state: Movement.State,
	command: Movement.Command
): Movement.Command
	local clampedPitch = assert(
		CommandQuantization.ClampViewPitchShort(state.viewPitch),
		"authoritative view pitch left the signed-short domain"
	)
	local pitchBits = assert(CommandQuantization.SignedShortToBits(clampedPitch))
	local yawBits = assert(CommandQuantization.SignedShortToBits(state.viewYaw))
	local rollBits = assert(CommandQuantization.SignedShortToBits(state.viewRoll))
	return {
		forward = command.forward,
		right = command.right,
		upMove = command.upMove,
		pitch = (pitchBits - state.deltaPitch) % CommandQuantization.ShortModulus,
		yaw = (yawBits - state.deltaYaw) % CommandQuantization.ShortModulus,
		roll = (rollBits - state.deltaRoll) % CommandQuantization.ShortModulus,
		buttons = command.buttons,
		weaponId = command.weaponId,
	}
end

local CANONICAL_HITBOX_NAME = "Q3EngineHitbox"
local CANONICAL_HITBOX_ATTRIBUTE = "Q3EngineCanonicalCombatHitbox"

local records: { [Player]: PlayerRecord } = {}
local lifeBindingRuntime = MovementLifeBindingRuntime.new()
local normalToDeadSourceRuntime = MovementNormalToDeadSourceRuntime.new()
local normalToDeadPreparedRegistry = MovementNormalToDeadPreparedRegistry.new()
local normalToDeadAuthorityRuntime =
	MovementNormalToDeadAuthorityRuntime.new(normalToDeadPreparedRegistry)
local normalToDeadOwner = {
	maximumBatchSize = 64,
	bindingRules = require(
		sharedRoot:WaitForChild("simulation"):WaitForChild("MoverNormalToDeadBindingRules")
	),
}
local studioWaterJumpObservations: { [Player]: StudioWaterJumpObservation } = {}
local accumulator = 0
local telemetryRuntime = MovementTelemetryRuntime.new()
local movementSnapshotRemote: RemoteEvent? = nil
local spawnPoints: { SpawnPoint } = {}
local rocketArenaSpawnPartition = false
local spawnWorldOccupants: WorldOccupancyQuery.QueryFunction? = nil
local moverBodyWorldOccupants: WorldOccupancyQuery.BodyQueryFunction? = nil
local worldPointContentsQuery: Movement.PointContentsFunction? = nil
local deadRuntime: MovementDeadRuntime.Runtime? = nil
local triggerDefinitions: { TriggerDefinition } = {}
local worldLimits: MapSpatialRules.WorldLimits? = nil
local moverRuntime = MovementMoverRuntime.new()
local fixedStepTransactionOpen = false
local simulationFaulted = false
local heartbeatConnection: RBXScriptConnection? = nil
local heartbeatArmed = false
local deferredSnapshotPlayers: { [Player]: boolean } = {}
local deferredRenderPlayers: { [Player]: boolean } = {}
local outOfBoundsHandler: ((
	player: Player,
	classification: MapSpatialRules.Classification,
	entityId: string?
) -> boolean)? =
	nil
local movementEnabledPredicate: ((player: Player) -> boolean)? = nil
local spawnTelefragHandler: ((spawningPlayer: Player, victims: { Player }, lifeBinding: MovementLifeBinding?) -> boolean)? =
	nil
local landingHandler: ((player: Player, result: LandingResult, contactIndex: number) -> boolean)? =
	nil
local waterEventHandler: WaterEventHandler? = nil
local moverDamageAdapter: MoverDamageAdapter? = nil
local moverParticipantAdapter: MoverParticipantAdapter? = nil
local moverBodyQueueAdapter: MoverBodyQueueAdapter? = nil
local moverAuthorityGeneration = 0
local activePreparedMoverStep: PreparedMoverStep? = nil
local preparedMoverStepCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedMoverStep]: PreparedMoverStepCapability,
}
local moverStepReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[MoverStepReceipt]: PreparedMoverStepCapability,
}
local prePmoveCommandHandler: PrePmoveCommandHandler? = nil
local commandHandler: CommandHandler? = nil
local deadCommandHandler: DeadCommandHandler? = nil
local clientTimerHandler: ClientTimerHandler? = nil
local simulationFaultHandler: SimulationFaultHandler? = nil
local matchTransitionCleanupOwner: MatchTransitionCleanupOwner? = nil
local authoritativeStepObserver: AuthoritativeStepObserver? = nil
local authoritativeFrameOwner: AuthoritativeFrameService.Owner? = nil
local authoritativeFrameHandler: AuthoritativeFrameHandler? = nil
local authoritativeFrameBeginHandler: AuthoritativeFrameBeginHandler? = nil
local postClientEndFrameHandler: PostClientEndFrameHandler? = nil
local clientTriggerFrameHandler: ClientTriggerFrameHandler? = nil
local doorTriggerFrameHandler: DoorTriggerFrameHandler? = nil
local preMoverEntityFrameHandler: PreMoverEntityFrameHandler? = nil
local postMoverDynamicFrameHandler: PostMoverDynamicFrameHandler? = nil
local openAuthoritativeFrame: AuthoritativeFrameService.Frame? = nil
local openPublicationSpool: FramePublicationSpool.Spool? = nil
local spawnRandom = Random.new()
local MAXIMUM_DEBUG_COUNTER = 9_007_199_254_740_991
local MAXIMUM_BINARY_USE_QUEUE = MoverPushRules.MaximumDefinitions
local INPUT_PAYLOAD_KEYS = table.freeze({
	sequence = true,
	revision = true,
	forward = true,
	right = true,
	upMove = true,
	pitch = true,
	yaw = true,
	roll = true,
	buttons = true,
	weaponId = true,
})

local function saturatedAdd(current: number, amount: number): number
	return math.min(current + math.max(amount, 0), MAXIMUM_DEBUG_COUNTER)
end

local function latchSimulationFault()
	if simulationFaulted then
		return
	end
	simulationFaulted = true
	local frameOwner = authoritativeFrameOwner
	local frame = openAuthoritativeFrame
	openAuthoritativeFrame = nil
	if frameOwner and frame then
		pcall(AuthoritativeFrameService.AbortOpen, frameOwner, frame)
	end
	local publicationSpool = openPublicationSpool
	openPublicationSpool = nil
	if publicationSpool then
		pcall(function()
			publicationSpool:Fault()
		end)
	end
	local handleSimulationFault = simulationFaultHandler
	if handleSimulationFault then
		-- A dependent authority owner must quarantine without being able to stop
		-- Movement's permanent publication barrier from closing.
		pcall(handleSimulationFault)
	end
	local preparedMoverStep = activePreparedMoverStep
	if preparedMoverStep then
		pcall(MovementService.AbortPreparedMoverStep, preparedMoverStep)
	end
	MovementMoverRuntime.RetireDeathSourceSession(
		moverRuntime,
		MovementMoverRuntime.GetDeathSourceSession(moverRuntime) :: MoverDeathSourceSession?
	)
	local adapter = moverDamageAdapter
	local damageToken = moverRuntime.activeDamageToken
	moverRuntime.activeDamageToken = nil
	if adapter and damageToken ~= nil then
		-- A broken consequence adapter must not prevent the terminal movement
		-- barrier, queue purge, and Heartbeat disconnect from completing.
		pcall(adapter.Abort, damageToken)
	end
	-- Keep every movement publication entry point closed permanently. Roblox
	-- event-handler errors stop only that thread; they do not stop the server.
	fixedStepTransactionOpen = true
	deferredSnapshotPlayers = {}
	deferredRenderPlayers = {}
	moverRuntime.pendingBinaryUses = {}
	for _, record in records do
		record.commandQueue = {}
		record.commandQueueHead = 1
	end
	local connection = heartbeatConnection
	heartbeatConnection = nil
	if connection then
		connection:Disconnect()
	end
	-- Do not retain or replicate the caught error/trace. Operators get only a
	-- generic server log and the server-only boolean debug metric.
	warn("MovementService latched a terminal authoritative simulation fault")
end

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local remoteRuntime = MovementRemoteRuntime.new({
	records = records,
	isFaulted = function(): boolean
		return simulationFaulted
	end,
	isFinite = isFinite,
	saturatedAdd = saturatedAdd,
})

local function projectedTrajectoryBase(state: Movement.State): Vector3
	return assert(
		EntityStateConversionRules.SnapTrajectoryBase(state.position),
		"validated playerState origin did not convert to an entity trajectory base"
	)
end

local function playerStateViewAnglesFromState(
	state: Movement.State
): EntityStateConversionRules.Angles
	return assert(
		EntityStateConversionRules.MovementViewAngles(
			state.viewPitch,
			state.viewYaw,
			state.viewRoll
		),
		"validated packed Movement view did not convert to exact playerState angles"
	)
end

local function projectedAngularTrajectoryBase(
	playerStateViewAngles: EntityStateConversionRules.Angles
): EntityStateConversionRules.Angles
	return assert(
		EntityStateConversionRules.SnapAngularTrajectoryBase(playerStateViewAngles),
		"validated playerState view did not convert to an entity angular trajectory"
	)
end

local function applyEntityStateProjection(
	record: PlayerRecord,
	state: Movement.State,
	angularOverride: EntityStateConversionRules.Angles?
)
	normalToDeadAuthorityRuntime.Invalidate(record)
	record.entityTrajectoryBase = projectedTrajectoryBase(state)
	record.entityTrajectoryDelta = state.velocity
	record.entityAngularTrajectoryBase =
		projectedAngularTrajectoryBase(angularOverride or record.playerStateViewAngles)
end

local function invalidateMovementLifeBinding(record: PlayerRecord)
	normalToDeadAuthorityRuntime.Invalidate(record)
	local handle = record.lifeBinding
	if handle then
		lifeBindingRuntime:Invalidate(handle, record)
	end
	record.lifeBinding = nil
	record.lifeSequence = nil
end

local function currentMovementLifeBinding(value: unknown): (MovementLifeBindingCapability?, string?)
	if type(value) ~= "table" then
		return nil, "invalid-movement-life-binding"
	end
	local handle = value :: MovementLifeBinding
	local capability = lifeBindingRuntime:Get(handle) :: any
	if not capability then
		return nil, "invalid-movement-life-binding"
	end
	local record = capability.record
	local summary = capability.summary
	local registration = EntitySlotService.GetPlayerRegistration(capability.player)
	if
		capability.status ~= "Current"
		or records[capability.player] ~= record
		or record.recordLineage ~= summary.recordLineage
		or record.registration ~= capability.registration
		or registration ~= capability.registration
		or record.lifeBinding ~= handle
		or record.lifeSequence ~= summary.lifeSequence
		or record.character ~= capability.character
		or capability.player.Character ~= capability.character
		or not capability.character.Parent
		or capability.player.Parent ~= Players
		or capability.player.UserId ~= summary.playerUserId
		or summary.player ~= capability.player
		or summary.character ~= capability.character
		or summary.registration ~= capability.registration
		or summary.playerBodyId ~= capability.registration.bodyId
		or summary.playerSourceOrder ~= capability.registration.sourceOrder
		or summary.playerLeaseGeneration ~= capability.registration.generation
		or not lifeBindingRuntime:SummaryMatches(capability, summary)
		or not table.isfrozen(handle)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.recordLineage)
	then
		return nil, "stale-movement-life-binding"
	end
	return capability, nil
end

function normalToDeadOwner.localLifeMatches(
	binding: MovementLifeBinding,
	summary: MovementLifeBindingSummary,
	player: Player,
	record: PlayerRecord
): boolean
	local capability = lifeBindingRuntime:Get(binding) :: any
	return capability ~= nil
		and capability.handle == binding
		and capability.status == "Current"
		and capability.player == player
		and capability.record == record
		and capability.summary == summary
		and capability.character == record.character
		and summary.character == record.character
		and capability.registration == record.registration
		and summary.registration == record.registration
		and record.lifeBinding == binding
		and record.lifeSequence == summary.lifeSequence
		and lifeBindingRuntime:SummaryMatches(capability, summary)
		and table.isfrozen(binding)
		and table.isfrozen(summary)
end

function normalToDeadOwner.validatePlayerSource(
	rawCapability: MovementNormalToDeadSourceRuntime.Capability,
	validateLife: boolean
): (boolean, string?)
	local playerCapability = rawCapability :: any
	local player = playerCapability.player :: Player?
	local record = playerCapability.record :: PlayerRecord?
	local binding = playerCapability.lifeBinding :: MovementLifeBinding?
	local lifeSummary = playerCapability.lifeSummary :: MovementLifeBindingSummary?
	local summary = playerCapability.summary :: NormalToDeadSourceSummary
	if
		not player
		or not record
		or not binding
		or not lifeSummary
		or summary.kind ~= "Player"
		or summary.player ~= player
		or summary.lifeBinding ~= binding
		or summary.lifeSummary ~= lifeSummary
		or records[player] ~= record
		or record.entityTrajectoryBase ~= playerCapability.entityTrajectoryBase
		or not normalToDeadOwner.localLifeMatches(binding, lifeSummary, player, record)
	then
		return false, "stale-normal-to-dead-player-source"
	end
	if validateLife then
		local lifeCapability = select(1, currentMovementLifeBinding(binding))
		if
			not lifeCapability
			or lifeCapability.record ~= record
			or lifeCapability.summary ~= lifeSummary
		then
			return false, "stale-normal-to-dead-player-source-life"
		end
	end
	return true, nil
end

function normalToDeadOwner.currentSource(
	sourceValue: unknown,
	summaryValue: unknown,
	validateExternalLife: boolean
): (NormalToDeadSourceCapability?, string?)
	local capability, sourceError = normalToDeadSourceRuntime:Current(
		sourceValue,
		summaryValue,
		validateExternalLife,
		normalToDeadOwner.validatePlayerSource
	)
	return capability :: any, sourceError
end

function normalToDeadOwner.findMoverDefinition(
	definitions: { MoverPushRules.Definition },
	moverId: string
): MoverPushRules.Definition?
	for _, definition in definitions do
		if definition.id == moverId then
			return definition
		end
	end
	return nil
end

function normalToDeadOwner.beginMoverDeathSourceSession(
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	clockWindow: MoverClock.Window,
	baseClock: MoverClock.Snapshot,
	baseMoverAuthorityGeneration: number,
	baseDefinitions: { MoverPushRules.Definition },
	damageAdapter: MoverDamageAdapter,
	damageToken: unknown
): MoverDeathSourceSession
	assert(
		openAuthoritativeFrame == frame
			and AuthoritativeFrameService.InspectFrame(frame) == frameSummary
			and AuthoritativeFrameService.ValidateFrameDependency(frame, frameSummary),
		"mover death-source session requires the exact open frame"
	)
	return MovementMoverRuntime.BeginDeathSourceSession(moverRuntime, {
		frame = frame,
		frameSummary = frameSummary,
		clockWindow = clockWindow,
		baseClock = baseClock,
		currentMoverAuthorityGeneration = moverAuthorityGeneration,
		baseMoverAuthorityGeneration = baseMoverAuthorityGeneration,
		baseDefinitions = baseDefinitions,
		damageAdapter = damageAdapter,
		damageToken = damageToken,
	}) :: any
end

function normalToDeadOwner.mintMoverDeathSource(
	session: MoverDeathSourceSession,
	callbackKind: "SinePush" | "BlockedDoor",
	callbackTraversalOrder: number,
	binding: MoverBodyBinding,
	body: MoverPushRules.Body,
	definitionSet: { MoverPushRules.Definition },
	definition: MoverPushRules.Definition
): (MoverDeathSource, MoverDeathSourceSummary)
	assert(binding.kind == "LivePlayer", "mover death sources require a live player target")
	local player = binding.player
	local record = binding.record
	local lifeBinding = assert(record.lifeBinding, "mover death source lost its victim life")
	local lifeCapability =
		assert(currentMovementLifeBinding(lifeBinding), "mover death source victim life is stale")
	assert(
		records[player] == record
			and lifeCapability.record == record
			and lifeCapability.player == player
			and body.id == record.moverBodyId
			and body.sourceOrder == record.moverBodySourceOrder
			and body.contents == MoverPushRules.Contents.Body
			and table.isfrozen(body)
			and table.isfrozen(definition)
			and normalToDeadOwner.findMoverDefinition(definitionSet, definition.id) == definition
			and callbackTraversalOrder == session.nextCallbackTraversalOrder,
		"mover death source target/definition drifted at callback"
	)
	local mapRegistration = assert(
		EntitySlotService.GetMapRegistration(definition.id),
		"mover death source has no retained map registration"
	)
	local lease = assert(
		EntitySlotService.GetWorldLease(mapRegistration.registration),
		"mover death source has no retained world lease"
	)
	assert(
		mapRegistration.kind == "Mover"
			and mapRegistration.registration.sourceOrder == definition.sourceOrder,
		"mover death source registration diverged from its definition"
	)
	local source, summary = MovementMoverRuntime.MintDeathSource(moverRuntime, {
		session = session,
		player = player,
		record = record,
		lifeBinding = lifeBinding,
		lifeSummary = lifeCapability.summary,
		body = body,
		callbackKind = callbackKind,
		callbackTraversalOrder = callbackTraversalOrder,
		definitionSet = definitionSet,
		definition = definition,
		mapRegistration = mapRegistration,
		lease = lease,
	})
	return source :: any, summary :: any
end

function normalToDeadOwner.currentMoverDeathSource(
	sourceValue: unknown,
	summaryValue: unknown
): (MoverDeathSourceCapability?, string?)
	local capability, sourceError = MovementMoverRuntime.CurrentDeathSource(
		moverRuntime,
		sourceValue,
		summaryValue,
		function(candidate): (boolean, string?)
			local session = candidate.session
			local summary = candidate.summary
			local lifeCapability = currentMovementLifeBinding(candidate.lifeBinding)
			if
				moverAuthorityGeneration ~= session.baseMoverAuthorityGeneration
				or openAuthoritativeFrame ~= session.frame
				or AuthoritativeFrameService.InspectFrame(session.frame) ~= session.frameSummary
				or not AuthoritativeFrameService.ValidateFrameDependency(
					session.frame,
					session.frameSummary
				)
				or records[summary.victim] ~= candidate.record
				or lifeCapability == nil
				or lifeCapability.record ~= candidate.record
				or lifeCapability.summary ~= candidate.lifeSummary
				or candidate.record.lifeBinding ~= candidate.lifeBinding
				or candidate.record.moverBodyId ~= candidate.body.id
				or candidate.record.moverBodySourceOrder ~= candidate.body.sourceOrder
				or normalToDeadOwner.findMoverDefinition(
					candidate.definitionSet,
					candidate.definition.id
				) ~= candidate.definition
				or EntitySlotService.GetMapRegistration(candidate.definition.id) ~= candidate.mapRegistration
				or EntitySlotService.GetWorldLease(candidate.mapRegistration.registration) ~= candidate.lease
				or summary.victim ~= lifeCapability.player
				or summary.victimUserId ~= lifeCapability.summary.playerUserId
			then
				return false, "stale-mover-death-source"
			end
			if session.status == "Preparing" then
				return session.preparedHandle == nil,
					if session.preparedHandle == nil
						then nil
						else "stale-preparing-mover-death-source"
			end
			local preparedHandle = session.preparedHandle
			local preparedCapability = if preparedHandle
				then preparedMoverStepCapabilities[preparedHandle]
				else nil
			if
				not preparedHandle
				or not preparedCapability
				or preparedCapability.moverDeathSession ~= session
				or activePreparedMoverStep ~= preparedHandle
			then
				return false, "stale-prepared-mover-death-source"
			end
			return true, nil
		end
	)
	return capability :: any, sourceError
end

function normalToDeadOwner.resolveSource(
	capability: NormalToDeadSourceCapability,
	victimRecord: PlayerRecord
): DeathTransitionRules.ResolvedSource
	local resolved: DeathTransitionRules.ResolvedSource
	if capability.summary.kind == "Projectile" then
		resolved = {
			kind = "Projectile",
			trajectoryBase = capability.entityTrajectoryBase,
		}
	elseif capability.player == nil then
		resolved = { kind = "World" }
	elseif capability.record == victimRecord then
		-- player_die compares entity identity, not trajectory equality. A self
		-- attacker must become Victim so LookAtKiller may fall through to a
		-- non-self inflictor.
		resolved = { kind = "Victim" }
	else
		resolved = {
			kind = "Player",
			trajectoryBase = capability.entityTrajectoryBase,
		}
	end
	table.freeze(resolved :: any)
	return resolved
end

function normalToDeadOwner.preparedCurrentError(
	preparedValue: unknown,
	capability: PreparedNormalToDeadCapability,
	validateExternalLife: boolean,
	batchOwner: PreparedNormalToDeadBatch?
): string?
	local prepared = preparedValue :: PreparedNormalToDead
	local record = capability.record
	local summary = capability.summary
	local receiptCapability = capability.receiptCapability
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= prepared
		or capability.batchOwner ~= batchOwner
		or normalToDeadPreparedRegistry:GetPreparedCapability(prepared) ~= capability
		or normalToDeadPreparedRegistry:GetPreparedForSummary(summary) ~= prepared
		or normalToDeadPreparedRegistry:GetActiveForRecord(record) ~= prepared
		or normalToDeadPreparedRegistry:GetReceiptCapability(capability.receipt) ~= receiptCapability
		or receiptCapability.receipt ~= capability.receipt
		or receiptCapability.status ~= "Pending"
		or receiptCapability.mode ~= capability.mode
		or receiptCapability.summary ~= summary
	then
		return "stale-prepared-normal-to-dead-ownership"
	end
	if
		record.state ~= capability.baseState
		or record.lifeBinding ~= capability.lifeBinding
		or record.lifeSequence ~= capability.lifeSummary.lifeSequence
		or record.spawnReserved ~= capability.baseSpawnReserved
		or record.deadState ~= nil
		or record.deathTransition ~= nil
		or record.firstDeadStepPhase ~= nil
		or record.entityTrajectoryBase ~= capability.baseEntityTrajectoryBase
		or record.entityTrajectoryDelta ~= capability.baseEntityTrajectoryDelta
		or record.entityAngularTrajectoryBase ~= capability.baseEntityAngularTrajectoryBase
		or record.entityGenericAngles ~= capability.baseEntityGenericAngles
		or record.playerStateViewAngles ~= capability.basePlayerStateViewAngles
	then
		return "stale-prepared-normal-to-dead-record-root"
	end
	if
		summary.player ~= capability.player
		or summary.mode ~= capability.mode
		or summary.lifeBinding ~= capability.lifeBinding
		or summary.lifeSummary ~= capability.lifeSummary
		or summary.baseState ~= capability.baseStateSnapshot
		or summary.nextState ~= capability.nextStateSnapshot
		or summary.prospectiveState ~= capability.prospectiveStateSnapshot
		or summary.deathTransition ~= capability.deathTransition
		or summary.deadEntry.firstStepPhase ~= capability.firstDeadStepPhase
	then
		return "stale-prepared-normal-to-dead-summary"
	end
	if
		not table.isfrozen(prepared)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(capability.baseStateSnapshot)
		or not table.isfrozen(capability.nextState)
		or not table.isfrozen(capability.nextStateSnapshot)
		or (capability.mode == "MoverPushed" and not table.isfrozen(capability.prospectiveState))
		or not table.isfrozen(capability.prospectiveStateSnapshot)
		or not table.isfrozen(capability.deadState)
		or not table.isfrozen(capability.deathTransition)
	then
		return "stale-prepared-normal-to-dead-immutability"
	end
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= prepared
		or capability.batchOwner ~= batchOwner
		or normalToDeadPreparedRegistry:GetPreparedCapability(prepared) ~= capability
		or normalToDeadPreparedRegistry:GetPreparedForSummary(summary) ~= prepared
		or normalToDeadPreparedRegistry:GetActiveForRecord(record) ~= prepared
		or normalToDeadPreparedRegistry:GetReceiptCapability(capability.receipt) ~= receiptCapability
		or receiptCapability.receipt ~= capability.receipt
		or receiptCapability.status ~= "Pending"
		or receiptCapability.mode ~= capability.mode
		or receiptCapability.summary ~= summary
		or receiptCapability.player ~= capability.player
		or receiptCapability.record ~= record
		or receiptCapability.lifeBinding ~= capability.lifeBinding
		or receiptCapability.baseSpawnReserved ~= capability.baseSpawnReserved
		or receiptCapability.baseState ~= capability.baseState
		or receiptCapability.nextState ~= capability.nextState
		or receiptCapability.prospectiveState ~= capability.prospectiveState
		or receiptCapability.deathTrajectoryBase ~= capability.deathTrajectoryBase
		or receiptCapability.nextEntityTrajectoryBase ~= capability.nextEntityTrajectoryBase
		or receiptCapability.nextEntityTrajectoryDelta ~= capability.nextEntityTrajectoryDelta
		or receiptCapability.nextEntityAngularTrajectoryBase ~= capability.nextEntityAngularTrajectoryBase
		or receiptCapability.deadState ~= capability.deadState
		or receiptCapability.deathTransition ~= capability.deathTransition
		or receiptCapability.firstDeadStepPhase ~= capability.firstDeadStepPhase
		or receiptCapability.attackerSource ~= capability.attackerSource
		or receiptCapability.attackerSourceSummary ~= capability.attackerSourceSummary
		or receiptCapability.inflictorSource ~= capability.inflictorSource
		or receiptCapability.inflictorSourceSummary ~= capability.inflictorSourceSummary
		or receiptCapability.moverWitness ~= capability.moverWitness
		or records[capability.player] ~= record
		or record.state ~= capability.baseState
		or not MovementNormalToDeadStateRuntime.Matches(
			capability.baseState,
			capability.baseStateSnapshot
		)
		or record.lifeBinding ~= capability.lifeBinding
		or record.lifeSequence ~= capability.lifeSummary.lifeSequence
		or record.spawnReserved ~= capability.baseSpawnReserved
		or record.deadState ~= nil
		or record.deathTransition ~= nil
		or record.firstDeadStepPhase ~= nil
		or record.entityTrajectoryBase ~= capability.baseEntityTrajectoryBase
		or record.entityTrajectoryDelta ~= capability.baseEntityTrajectoryDelta
		or record.entityAngularTrajectoryBase ~= capability.baseEntityAngularTrajectoryBase
		or record.entityGenericAngles ~= capability.baseEntityGenericAngles
		or record.playerStateViewAngles ~= capability.basePlayerStateViewAngles
		or not normalToDeadOwner.localLifeMatches(
			capability.lifeBinding,
			capability.lifeSummary,
			capability.player,
			record
		)
		or summary.player ~= capability.player
		or summary.mode ~= capability.mode
		or summary.playerUserId ~= capability.lifeSummary.playerUserId
		or summary.lifeBinding ~= capability.lifeBinding
		or summary.lifeSummary ~= capability.lifeSummary
		or summary.baseState ~= capability.baseStateSnapshot
		or summary.nextState ~= capability.nextStateSnapshot
		or not MovementNormalToDeadStateRuntime.Matches(
			capability.nextState,
			capability.nextStateSnapshot
		)
		or summary.prospectiveState ~= capability.prospectiveStateSnapshot
		or not MovementNormalToDeadStateRuntime.Matches(
			capability.prospectiveState,
			capability.prospectiveStateSnapshot
		)
		or summary.deathTrajectoryBase ~= capability.deathTrajectoryBase
		or summary.baseEntityTrajectoryBase ~= capability.baseEntityTrajectoryBase
		or summary.baseEntityTrajectoryDelta ~= capability.baseEntityTrajectoryDelta
		or summary.baseEntityAngularTrajectoryBase ~= capability.baseEntityAngularTrajectoryBase
		or summary.nextEntityTrajectoryBase ~= capability.nextEntityTrajectoryBase
		or summary.nextEntityTrajectoryDelta ~= capability.nextEntityTrajectoryDelta
		or summary.nextEntityAngularTrajectoryBase ~= capability.nextEntityAngularTrajectoryBase
		or summary.baseEntityGenericAngles ~= capability.baseEntityGenericAngles
		or summary.basePlayerStateViewAngles ~= capability.basePlayerStateViewAngles
		or summary.callbackEntityTrajectoryBase ~= capability.callbackEntityTrajectoryBase
		or summary.callbackEntityAngularTrajectoryBase ~= capability.callbackEntityAngularTrajectoryBase
		or summary.baseSpawnReserved ~= capability.baseSpawnReserved
		or summary.nextSpawnReserved ~= false
		or summary.attackerSource ~= capability.attackerSourceSummary
		or summary.inflictorSource ~= capability.inflictorSourceSummary
		or summary.deathTransition ~= capability.deathTransition
		or summary.deadEntry.firstStepPhase ~= capability.firstDeadStepPhase
		or capability.deadState.state ~= capability.nextState
		or capability.deadState.viewHeight ~= summary.deadEntry.initialViewHeight
		or capability.deathTransition.initialViewHeight ~= summary.deadEntry.initialViewHeight
		or capability.deathTransition.deadLifeSequence ~= capability.lifeSummary.lifeSequence
		or capability.firstDeadStepPhase.pmType ~= MovementPhaseRules.PmoveType.Dead
		or capability.firstDeadStepPhase.viewHeight ~= Constants.DeadViewHeight
		or not table.isfrozen(prepared)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(capability.baseStateSnapshot)
		or not table.isfrozen(capability.nextState)
		or not table.isfrozen(capability.nextStateSnapshot)
		or (capability.mode == "MoverPushed" and not table.isfrozen(capability.prospectiveState))
		or not table.isfrozen(capability.prospectiveStateSnapshot)
		or not table.isfrozen(capability.deadState)
		or not table.isfrozen(capability.deathTransition)
		or not table.isfrozen(summary.deadEntry)
		or not table.isfrozen(capability.firstDeadStepPhase)
		or not table.isfrozen(capability.baseEntityAngularTrajectoryBase)
		or not table.isfrozen(capability.nextEntityAngularTrajectoryBase)
		or not table.isfrozen(capability.baseEntityGenericAngles)
		or not table.isfrozen(capability.basePlayerStateViewAngles)
	then
		return "stale-prepared-normal-to-dead"
	end

	if capability.mode == "Direct" then
		if
			capability.moverWitness ~= nil
			or receiptCapability.moverWitness ~= nil
			or receiptCapability.outerBatchReceipt ~= nil
			or receiptCapability.outerBatchIndex ~= nil
			or capability.prospectiveState ~= capability.baseState
			or capability.prospectiveStateSnapshot ~= capability.baseStateSnapshot
			or capability.deathTrajectoryBase ~= capability.baseEntityTrajectoryBase
			or capability.callbackEntityTrajectoryBase ~= capability.baseEntityTrajectoryBase
			or capability.callbackEntityAngularTrajectoryBase ~= capability.baseEntityAngularTrajectoryBase
			or capability.nextEntityTrajectoryBase ~= capability.baseEntityTrajectoryBase
			or capability.nextEntityTrajectoryDelta ~= capability.baseEntityTrajectoryDelta
			or capability.nextEntityAngularTrajectoryBase
				~= capability.baseEntityAngularTrajectoryBase
		then
			return "stale-prepared-normal-to-dead-mode"
		end
		local attackerCapability = select(
			1,
			normalToDeadOwner.currentSource(
				capability.attackerSource,
				capability.attackerSourceSummary,
				validateExternalLife
			)
		)
		local inflictorCapability = select(
			1,
			normalToDeadOwner.currentSource(
				capability.inflictorSource,
				capability.inflictorSourceSummary,
				validateExternalLife
			)
		)
		if not attackerCapability or not inflictorCapability then
			return "stale-prepared-normal-to-dead-source"
		end
	elseif capability.mode == "MoverPushed" then
		local witness = capability.moverWitness
		local sourceCapability = witness and witness.sourceCapability
		local removedCallbackBody = witness and witness.assignment.removedCallbackBody
		if
			not witness
			or not sourceCapability
			or witness.source ~= capability.attackerSource
			or witness.source ~= capability.inflictorSource
			or witness.sourceSummary ~= capability.attackerSourceSummary
			or witness.sourceSummary ~= capability.inflictorSourceSummary
			or batchOwner == nil
			or receiptCapability.outerBatchReceipt == nil
			or receiptCapability.outerBatchIndex == nil
			or witness.stageReceipt ~= sourceCapability.stageReceipt
			or witness.assignment.record ~= capability.record
			or witness.assignment.player ~= capability.player
			or witness.assignment.baseState ~= capability.baseState
			or witness.assignment.nextState ~= capability.prospectiveState
			or (removedCallbackBody ~= nil and (not table.isfrozen(removedCallbackBody) or removedCallbackBody.id ~= capability.record.moverBodyId or removedCallbackBody.sourceOrder ~= capability.record.moverBodySourceOrder or removedCallbackBody.position ~= capability.prospectiveState.position))
			or capability.deathTrajectoryBase ~= witness.sourceSummary.victimBody.position
			or capability.callbackEntityTrajectoryBase ~= witness.sourceSummary.victimBody.position
			or capability.callbackEntityAngularTrajectoryBase ~= witness.assignment.baseEntityAngularTrajectoryBase
			or capability.nextEntityTrajectoryBase ~= witness.assignment.nextEntityTrajectoryBase
			or capability.nextEntityTrajectoryDelta ~= witness.assignment.nextEntityTrajectoryDelta
			or capability.nextState.position ~= capability.prospectiveState.position
			or capability.nextState.velocity ~= capability.prospectiveState.velocity
			or summary.lethalVelocityDelta ~= Vector3.zero
			or summary.lethalKnockbackSeconds ~= nil
			or witness.outerPrepared ~= witness.outerCapability.preparedHandle
			or sourceCapability.appliedNormalToDeadReceipt ~= nil
			or select(
					1,
					normalToDeadOwner.currentMoverDeathSource(witness.source, witness.sourceSummary)
				)
				~= sourceCapability
		then
			return "stale-prepared-mover-normal-to-dead-source"
		end
	else
		return "invalid-prepared-normal-to-dead-mode"
	end
	if validateExternalLife then
		local lifeCapability = select(1, currentMovementLifeBinding(capability.lifeBinding))
		if
			not lifeCapability
			or lifeCapability.record ~= record
			or lifeCapability.summary ~= capability.lifeSummary
		then
			return "stale-prepared-normal-to-dead-life"
		end
	end
	return nil
end

function normalToDeadOwner.boundedDenseBatchLength(value: unknown): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end
	local count = 0
	local maximumIndex = 0
	for key in next, value :: { [unknown]: unknown } do
		if
			type(key) ~= "number"
			or key % 1 ~= 0
			or key < 1
			or key > normalToDeadOwner.maximumBatchSize
		then
			return nil
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	if count < 1 or maximumIndex ~= count then
		return nil
	end
	for index = 1, count do
		if rawget(value :: { [unknown]: unknown }, index) == nil then
			return nil
		end
	end
	return count
end

function normalToDeadOwner.hasExactBatchEntryKeys(value: unknown): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value :: { [unknown]: unknown } do
		if key ~= "prepared" and key ~= "summary" and key ~= "receipt" then
			return false
		end
		count += 1
	end
	return count == 3
		and rawget(value :: { [unknown]: unknown }, "prepared") ~= nil
		and rawget(value :: { [unknown]: unknown }, "summary") ~= nil
		and rawget(value :: { [unknown]: unknown }, "receipt") ~= nil
end

function normalToDeadOwner.preparedBatchCurrentError(
	preparedValue: unknown,
	capability: PreparedNormalToDeadBatchCapability,
	validateExternalLife: boolean,
	outerMoverOwner: PreparedMoverStep?
): string?
	local prepared = preparedValue :: PreparedNormalToDeadBatch
	local summary = capability.summary
	local receiptCapability = capability.receiptCapability
	local operationCount = #capability.entries
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= prepared
		or capability.outerMoverOwner ~= outerMoverOwner
		or (if outerMoverOwner
			then normalToDeadPreparedRegistry:GetMoverStepForBatch(prepared) ~= outerMoverOwner
			else normalToDeadPreparedRegistry:GetMoverStepForBatch(prepared) ~= nil)
		or normalToDeadPreparedRegistry:GetActiveBatch() ~= prepared
		or normalToDeadPreparedRegistry:GetBatchCapability(prepared) ~= capability
		or normalToDeadPreparedRegistry:GetBatchForSummary(summary) ~= prepared
		or normalToDeadPreparedRegistry:GetBatchReceiptCapability(capability.receipt) ~= receiptCapability
		or receiptCapability.receipt ~= capability.receipt
		or receiptCapability.status ~= "Pending"
		or receiptCapability.summary ~= summary
		or receiptCapability.receipts ~= capability.receipts
		or receiptCapability.entries ~= capability.entries
		or operationCount < 1
		or operationCount > normalToDeadOwner.maximumBatchSize
		or #capability.receipts ~= operationCount
		or summary.operationCount ~= operationCount
		or #summary.records ~= operationCount
		or not table.isfrozen(prepared)
		or not table.isfrozen(capability.entries)
		or not table.isfrozen(capability.receipts)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.records)
	then
		return "stale-prepared-normal-to-dead-batch"
	end
	for index = 1, operationCount do
		local entry = capability.entries[index]
		local preparedCapability = entry.preparedCapability
		if
			not table.isfrozen(entry)
			or entry.prepared ~= preparedCapability.prepared
			or entry.summary ~= preparedCapability.summary
			or entry.receipt ~= preparedCapability.receipt
			or entry.player ~= preparedCapability.player
			or entry.record ~= preparedCapability.record
			or entry.lifeBinding ~= preparedCapability.lifeBinding
			or entry.registration ~= preparedCapability.lifeSummary.registration
			or capability.receipts[index] ~= entry.receipt
			or summary.records[index] ~= entry.summary
			or normalToDeadOwner.preparedCurrentError(
					entry.prepared,
					preparedCapability,
					validateExternalLife,
					prepared
				)
				~= nil
		then
			return "stale-prepared-normal-to-dead-batch-member"
		end
	end
	return nil
end

function normalToDeadOwner.buildMoverNormalToDeadMember(
	outerCapability: PreparedMoverStepCapability,
	assignment: MoverPlayerStateAssignment,
	sourceCapability: MoverDeathSourceCapability
): (PreparedNormalToDeadCapability?, string?)
	local sourceSummary = sourceCapability.summary
	local record = sourceCapability.record
	local lifeSummary = sourceCapability.lifeSummary
	local prospectiveState = assignment.nextState
	local removedCallbackBody = assignment.removedCallbackBody
	local baseline = outerCapability.recordBaselines[assignment.player]
	local stageReceipt = sourceCapability.stageReceipt
	if
		not baseline
		or stageReceipt == nil
		or assignment.record ~= record
		or assignment.player ~= sourceSummary.victim
		or assignment.baseState ~= record.state
		or assignment.baseState ~= baseline.state
		or sourceSummary.victimLifeBinding ~= sourceCapability.lifeBinding
		or sourceSummary.victimLifeSummary ~= lifeSummary
		or sourceSummary.victimBody ~= sourceCapability.body
		or sourceSummary.victimBody.position ~= sourceSummary.victimBody.position
		or (removedCallbackBody ~= nil and (not table.isfrozen(removedCallbackBody) or removedCallbackBody.id ~= record.moverBodyId or removedCallbackBody.sourceOrder ~= record.moverBodySourceOrder or prospectiveState.position ~= removedCallbackBody.position))
		or assignment.nextEntityTrajectoryBase ~= projectedTrajectoryBase(prospectiveState)
		or assignment.nextEntityTrajectoryDelta ~= prospectiveState.velocity
		or not table.isfrozen(assignment)
		or not table.isfrozen(sourceSummary)
	then
		return nil, "invalid-mover-normal-to-dead-member"
	end
	local nextState, retainedKnockbackSeconds, lethalError =
		MovementNormalToDeadStateRuntime.BuildLethal(
			prospectiveState,
			Vector3.zero,
			nil,
			Constants.MinimumDamageKnockbackSeconds,
			Constants.MaximumDamageKnockbackSeconds
		)
	if
		not nextState
		or retainedKnockbackSeconds ~= nil
		or nextState == prospectiveState
		or nextState.position ~= prospectiveState.position
		or nextState.velocity ~= prospectiveState.velocity
	then
		return nil, lethalError or "mover-normal-to-dead-zero-impulse-diverged"
	end
	local moverResolved: DeathTransitionRules.ResolvedSource = {
		kind = "Mover",
		trajectoryBase = sourceSummary.entityTrajectoryBase,
	}
	table.freeze(moverResolved :: any)
	local deathTransition, transitionError = DeathTransitionRules.ResolveMoverPushedClient({
		lifeSequence = lifeSummary.lifeSequence,
		crouched = prospectiveState.crouched,
		victimTrajectoryBase = sourceSummary.victimBody.position,
		retainedGenericAngles = assignment.baseEntityGenericAngles,
		attacker = moverResolved,
		inflictor = moverResolved,
	})
	if not deathTransition then
		return nil, transitionError or "mover-normal-to-dead-transition-invalid"
	end
	local deadEntry, deadEntryError = MovementPhaseRules.CreateDeadEntryContract(
		prospectiveState.crouched,
		deathTransition.deadLifeSequence,
		deathTransition.deadYawDegrees
	)
	if not deadEntry then
		return nil, deadEntryError or "mover-normal-to-dead-entry-contract-invalid"
	end
	local deadState = Movement.newDeadState(nextState)
	if
		deadState.viewHeight ~= deathTransition.initialViewHeight
		or deadState.viewHeight ~= deadEntry.initialViewHeight
	then
		return nil, "mover-normal-to-dead-initial-viewheight-diverged"
	end
	table.freeze(deadState)
	local nextEntityAngularTrajectoryBase =
		projectedAngularTrajectoryBase(deathTransition.playerStateViewAngles)
	local baseStateSnapshot = MovementNormalToDeadStateRuntime.Snapshot(assignment.baseState)
	local prospectiveStateSnapshot = MovementNormalToDeadStateRuntime.Snapshot(prospectiveState)
	local nextStateSnapshot = MovementNormalToDeadStateRuntime.Snapshot(nextState)
	return MovementMoverRuntime.AssembleNormalToDeadMember(moverRuntime, {
		outerCapability = outerCapability,
		assignment = assignment,
		sourceCapability = sourceCapability,
		baseStateSnapshot = baseStateSnapshot,
		prospectiveStateSnapshot = prospectiveStateSnapshot,
		nextState = nextState,
		nextStateSnapshot = nextStateSnapshot,
		nextEntityAngularTrajectoryBase = nextEntityAngularTrajectoryBase,
		deathTransition = deathTransition,
		deadEntry = deadEntry,
		deadState = deadState,
	}) :: PreparedNormalToDeadCapability,
		nil
end

function normalToDeadOwner.buildMoverNormalToDeadBundle(
	outerCapability: PreparedMoverStepCapability,
	memberCapabilities: { PreparedNormalToDeadCapability }
): (PreparedMoverNormalToDeadBundle?, string?)
	local operationCount = #memberCapabilities
	if operationCount < 1 or operationCount > normalToDeadOwner.maximumBatchSize then
		return nil, "mover-normal-to-dead-batch-not-dense-bounded"
	end
	local seenPlayers: { [Player]: boolean } = {}
	local seenRecords: { [PlayerRecord]: boolean } = {}
	local seenSources: { [MoverDeathSource]: boolean } = {}
	for index = 1, operationCount do
		local capability = memberCapabilities[index]
		local witness = capability and capability.moverWitness
		if
			not capability
			or capability.mode ~= "MoverPushed"
			or capability.status ~= "Prepared"
			or capability.batchOwner ~= nil
			or not witness
			or witness.outerCapability ~= outerCapability
			or witness.outerPrepared ~= outerCapability.preparedHandle
			or seenPlayers[capability.player]
			or seenRecords[capability.record]
			or seenSources[witness.source]
		then
			return nil, "invalid-mover-normal-to-dead-batch-member"
		end
		seenPlayers[capability.player] = true
		seenRecords[capability.record] = true
		seenSources[witness.source] = true
	end
	return MovementMoverRuntime.AssembleNormalToDeadBundle(
		moverRuntime,
		outerCapability,
		memberCapabilities
	) :: PreparedMoverNormalToDeadBundle,
		nil
end

function normalToDeadOwner.moverNormalToDeadDependencyCurrentError(
	outerCapability: PreparedMoverStepCapability,
	validateExternalLife: boolean
): string?
	local batch = outerCapability.boundNormalToDeadBatch
	local summary = outerCapability.boundNormalToDeadBatchSummary
	local receipt = outerCapability.boundNormalToDeadBatchReceipt
	local memberReceipts = outerCapability.boundNormalToDeadMemberReceipts
	local dependency = outerCapability.boundNormalToDeadDependency
	if
		batch == nil
		and summary == nil
		and receipt == nil
		and memberReceipts == nil
		and dependency == nil
	then
		if
			next(outerCapability.lethalNormalToDeadRecords) ~= nil
			or next(outerCapability.lethalNormalToDeadAssignments) ~= nil
			or #outerCapability.normalToDeadApplyEntries ~= 0
		then
			return "partial-mover-normal-to-dead-dependency"
		end
		return nil
	end
	if
		batch == nil
		or summary == nil
		or receipt == nil
		or memberReceipts == nil
		or dependency == nil
	then
		return "partial-mover-normal-to-dead-dependency"
	end
	local batchCapability = normalToDeadPreparedRegistry:GetBatchCapability(batch) :: any
	if
		not batchCapability
		or batchCapability.summary ~= summary
		or batchCapability.receipt ~= receipt
		or batchCapability.receipts ~= memberReceipts
		or batchCapability.outerMoverOwner ~= outerCapability.preparedHandle
		or normalToDeadPreparedRegistry:GetMoverStepForBatch(batch) ~= outerCapability.preparedHandle
		or dependency.operationCount ~= #outerCapability.boundLethalMoverDeathSources
		or dependency.operationCount ~= #batchCapability.entries
		or dependency.batch ~= batch
		or dependency.batchSummary ~= summary
		or dependency.batchReceipt ~= receipt
		or dependency.memberReceipts ~= memberReceipts
		or not table.isfrozen(dependency)
		or not table.isfrozen(memberReceipts)
		or not table.isfrozen(outerCapability.lethalNormalToDeadRecords)
		or not table.isfrozen(outerCapability.lethalNormalToDeadAssignments)
		or not table.isfrozen(outerCapability.normalToDeadApplyEntries)
		or #outerCapability.normalToDeadApplyEntries ~= dependency.operationCount
		or normalToDeadOwner.preparedBatchCurrentError(
				batch,
				batchCapability,
				validateExternalLife,
				outerCapability.preparedHandle
			)
			~= nil
	then
		return "stale-mover-normal-to-dead-dependency"
	end
	for index = 1, dependency.operationCount do
		local sourceCapability = outerCapability.boundLethalMoverDeathSources[index]
		local entry = batchCapability.entries[index]
		local member = entry.preparedCapability
		local witness = member.moverWitness
		local applyEntry = outerCapability.normalToDeadApplyEntries[index]
		if
			not witness
			or witness.sourceCapability ~= sourceCapability
			or witness.source ~= sourceCapability.source
			or witness.sourceSummary ~= sourceCapability.summary
			or witness.stageReceipt ~= sourceCapability.stageReceipt
			or witness.outerCapability ~= outerCapability
			or witness.outerPrepared ~= outerCapability.preparedHandle
			or member.player ~= sourceCapability.summary.victim
			or member.record ~= sourceCapability.record
			or outerCapability.lethalNormalToDeadRecords[member.record] ~= true
			or outerCapability.lethalNormalToDeadAssignments[member.record] ~= witness.assignment
			or memberReceipts[index] ~= member.receipt
			or member.receiptCapability.outerBatchReceipt ~= receipt
			or member.receiptCapability.outerBatchIndex ~= index
			or summary.records[index] ~= member.summary
			or sourceCapability.appliedNormalToDeadReceipt ~= nil
			or not applyEntry
			or not table.isfrozen(applyEntry)
			or applyEntry.member ~= member
			or applyEntry.sourceCapability ~= sourceCapability
		then
			return "stale-mover-normal-to-dead-member-dependency"
		end
	end
	return nil
end

local function hasExactInputKeys(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local observed = 0
	for key in value do
		if type(key) ~= "string" or INPUT_PAYLOAD_KEYS[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == 10
end

local function moverBodyId(player: Player): string
	local record = records[player]
	assert(record, "player mover-body binding is unavailable")
	assert(
		EntitySlotService.GetPlayerRegistration(player) == record.registration
			and record.registration.sourceOrder == record.moverBodySourceOrder
			and record.registration.bodyId == record.moverBodyId
			and EntitySlotService.GetPlayerSourceOrder(player) == record.moverBodySourceOrder
			and EntitySlotService.GetPlayerBodyId(player) == record.moverBodyId,
		"player mover-body registration diverged from the entity-slot owner"
	)
	return record.moverBodyId
end

local function captureMoverRecordBaselines(): ({ [Player]: MoverRecordBaseline }, number)
	local baselines: { [Player]: MoverRecordBaseline } = {}
	local count = 0
	for player, record in records do
		local baseline: MoverRecordBaseline = {
			record = record,
			state = record.state,
			awaitingViewCommand = record.awaitingViewCommand,
			lifeSequence = record.lifeSequence,
			lifeBinding = record.lifeBinding,
			entityTrajectoryBase = record.entityTrajectoryBase,
			entityTrajectoryDelta = record.entityTrajectoryDelta,
			entityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
			entityGenericAngles = record.entityGenericAngles,
			playerStateViewAngles = record.playerStateViewAngles,
			deadState = record.deadState,
			deathTransition = record.deathTransition,
			firstDeadStepPhase = record.firstDeadStepPhase,
		}
		table.freeze(baseline)
		baselines[player] = baseline
		count += 1
	end
	table.freeze(baselines)
	return baselines, count
end

local function captureMoverStepDebugState(): MoverStepDebugState
	return {
		moverCrushTransitionCount = moverRuntime.crushTransitionCount,
		moverCrushRemovedCount = moverRuntime.crushRemovedCount,
		moverCrushRetainedCount = moverRuntime.crushRetainedCount,
		lastCrushMoverId = moverRuntime.lastCrushMoverId,
		lastCrushBodyId = moverRuntime.lastCrushBodyId,
		lastCrushClockStep = moverRuntime.lastCrushClockStep,
		binaryUseTransitionCount = moverRuntime.binaryUseTransitionCount,
		lastBinaryUseMoverId = moverRuntime.lastBinaryUseMoverId,
		lastBinaryUseOutcome = moverRuntime.lastBinaryUseOutcome,
		lastBinaryUseTimeMilliseconds = moverRuntime.lastBinaryUseTimeMilliseconds,
		lastBinaryUseClockStep = moverRuntime.lastBinaryUseClockStep,
		binaryBlockedCallbackCount = moverRuntime.binaryBlockedCallbackCount,
		binaryBlockedDamageCount = moverRuntime.binaryBlockedDamageCount,
		binaryBlockedReversalCount = moverRuntime.binaryBlockedReversalCount,
		binaryBlockedRemovalCount = moverRuntime.binaryBlockedRemovalCount,
		lastBinaryBlockedMoverId = moverRuntime.lastBinaryBlockedMoverId,
		lastBinaryBlockedBodyId = moverRuntime.lastBinaryBlockedBodyId,
		lastBinaryBlockedTimeMilliseconds = moverRuntime.lastBinaryBlockedTimeMilliseconds,
	}
end

local function moverStepDebugStateIsCurrent(state: MoverStepDebugState): boolean
	return moverRuntime.crushTransitionCount == state.moverCrushTransitionCount
		and moverRuntime.crushRemovedCount == state.moverCrushRemovedCount
		and moverRuntime.crushRetainedCount == state.moverCrushRetainedCount
		and moverRuntime.lastCrushMoverId == state.lastCrushMoverId
		and moverRuntime.lastCrushBodyId == state.lastCrushBodyId
		and moverRuntime.lastCrushClockStep == state.lastCrushClockStep
		and moverRuntime.binaryUseTransitionCount == state.binaryUseTransitionCount
		and moverRuntime.lastBinaryUseMoverId == state.lastBinaryUseMoverId
		and moverRuntime.lastBinaryUseOutcome == state.lastBinaryUseOutcome
		and moverRuntime.lastBinaryUseTimeMilliseconds == state.lastBinaryUseTimeMilliseconds
		and moverRuntime.lastBinaryUseClockStep == state.lastBinaryUseClockStep
		and moverRuntime.binaryBlockedCallbackCount == state.binaryBlockedCallbackCount
		and moverRuntime.binaryBlockedDamageCount == state.binaryBlockedDamageCount
		and moverRuntime.binaryBlockedReversalCount == state.binaryBlockedReversalCount
		and moverRuntime.binaryBlockedRemovalCount == state.binaryBlockedRemovalCount
		and moverRuntime.lastBinaryBlockedMoverId == state.lastBinaryBlockedMoverId
		and moverRuntime.lastBinaryBlockedBodyId == state.lastBinaryBlockedBodyId
		and moverRuntime.lastBinaryBlockedTimeMilliseconds
			== state.lastBinaryBlockedTimeMilliseconds
end

local function serializeMoverSnapshotWire(
	clock: MoverClock.Snapshot,
	legacyDefinitions: { MoverPushRules.Definition },
	binaryRuntime: MoverBinaryState.Runtime?
): MoverSnapshotContract.WireSnapshot
	local configuredLimits = assert(worldLimits, "mover snapshot requires world limits")
	local binaryPrograms: { MoverBinaryState.Program }? = nil
	if #moverRuntime.binaryPrograms > 0 then
		binaryPrograms = moverRuntime.binaryPrograms
		assert(binaryRuntime, "binary mover snapshot requires authoritative runtime")
	else
		assert(binaryRuntime == nil, "empty binary mover domain cannot publish runtime")
	end
	local wire, wireError = MoverSnapshotContract.SerializeServerSnapshot(
		clock,
		legacyDefinitions,
		configuredLimits.bounds,
		moverRuntime.authoredLegacyDefinitions,
		binaryPrograms,
		binaryRuntime
	)
	assert(wire, wireError or "failed to serialize authoritative mover snapshot")
	return wire
end

local function refreshMoverSnapshotWire()
	moverRuntime.snapshotWire = serializeMoverSnapshotWire(
		moverRuntime.clock,
		moverRuntime.runtimeLegacyDefinitions,
		moverRuntime.binaryRuntime
	)
end

local function extractRuntimeLegacyDefinitions(
	definitions: { MoverPushRules.Definition }
): { MoverPushRules.Definition }
	local legacyDefinitions: { MoverPushRules.Definition } =
		table.create(#moverRuntime.authoredLegacyDefinitions)
	for _, definition in definitions do
		if moverRuntime.legacyIds[definition.id] == true then
			table.insert(legacyDefinitions, definition)
		end
	end
	assert(
		#legacyDefinitions == #moverRuntime.authoredLegacyDefinitions,
		"authoritative mover frame lost a legacy definition"
	)
	local validated, validationError = MoverPushRules.ValidateAndOrderDefinitions(legacyDefinitions)
	assert(validated, validationError or "authoritative legacy mover runtime is invalid")
	return validated
end

local function composeRuntimeMoverDefinitions(
	legacyDefinitions: { MoverPushRules.Definition },
	binaryRuntime: MoverBinaryState.Runtime?
): { MoverPushRules.Definition }
	local combined: { MoverPushRules.Definition } =
		table.create(#legacyDefinitions + #moverRuntime.binaryPrograms)
	for _, definition in legacyDefinitions do
		table.insert(combined, definition)
	end
	if #moverRuntime.binaryPrograms > 0 then
		local definitions, definitionError = MoverBinaryState.MaterializeDefinitions(
			moverRuntime.binaryPrograms,
			assert(binaryRuntime, "binary definitions require authoritative runtime")
		)
		assert(definitions, definitionError or "binary mover definitions are invalid")
		for _, definition in definitions do
			table.insert(combined, definition)
		end
	else
		assert(binaryRuntime == nil, "empty binary mover domain cannot materialize runtime")
	end
	local validated, validationError = MoverPushRules.ValidateAndOrderDefinitions(combined)
	assert(validated, validationError or "combined mover runtime definitions are invalid")
	return validated
end

local function applyQueuedBinaryMoverUses(
	frame: MoverPushRules.FrameState,
	binaryRuntime: MoverBinaryState.Runtime?,
	window: MoverClock.Window,
	queuedUses: { string },
	nextDebug: MoverStepDebugState
): (MoverPushRules.FrameState, MoverBinaryState.Runtime?)
	if #queuedUses == 0 then
		return frame, binaryRuntime
	end
	assert(#moverRuntime.binaryPrograms > 0, "binary mover Use queue has no trusted Programs")
	local currentRuntime =
		assert(binaryRuntime, "binary mover Use queue has no authoritative runtime")

	-- Client/trigger uses run after level.time advances but before G_RunMover.
	-- Every request therefore consumes the same server-authored current time;
	-- callers can choose only a trusted mover ID and never submit a timestamp.
	for _, moverId in queuedUses do
		local nextRuntime, outcome, useError = MoverBinaryState.UseTeam(
			moverRuntime.binaryPrograms,
			currentRuntime,
			moverId,
			window.toTimeMilliseconds
		)
		assert(nextRuntime, useError or "binary mover Use transition failed")
		assert(outcome, useError or "binary mover Use outcome is missing")
		currentRuntime = nextRuntime
		nextDebug.binaryUseTransitionCount = saturatedAdd(nextDebug.binaryUseTransitionCount, 1)
		nextDebug.lastBinaryUseMoverId = moverId
		nextDebug.lastBinaryUseOutcome = outcome
		nextDebug.lastBinaryUseTimeMilliseconds = window.toTimeMilliseconds
		nextDebug.lastBinaryUseClockStep = window.toStep
	end

	local definitions =
		composeRuntimeMoverDefinitions(moverRuntime.runtimeLegacyDefinitions, currentRuntime)
	local relinkedFrame, relinkError =
		MoverPushRules.RelinkReadyDefinitionsAtCurrentTime(frame, definitions)
	assert(relinkedFrame, relinkError or "binary mover current-time relink failed")
	return relinkedFrame, currentRuntime
end

local function moverDefinitionsMatch(
	actual: { MoverPushRules.Definition },
	expected: { MoverPushRules.Definition }
): boolean
	if #actual ~= #expected then
		return false
	end
	for index, actualDefinition in actual do
		local expectedDefinition = expected[index]
		local actualTrajectory = actualDefinition.trajectory
		local expectedTrajectory = expectedDefinition.trajectory
		local actualAngularTrajectory = actualDefinition.angularTrajectory
		local expectedAngularTrajectory = expectedDefinition.angularTrajectory
		if
			actualDefinition.id ~= expectedDefinition.id
			or actualDefinition.teamId ~= expectedDefinition.teamId
			or actualDefinition.sourceOrder ~= expectedDefinition.sourceOrder
			or actualDefinition.shape ~= expectedDefinition.shape
			or actualDefinition.cframe ~= expectedDefinition.cframe
			or actualDefinition.size ~= expectedDefinition.size
			or actualDefinition.moverStop ~= expectedDefinition.moverStop
			or actualTrajectory.kind ~= expectedTrajectory.kind
			or actualTrajectory.startTimeMilliseconds ~= expectedTrajectory.startTimeMilliseconds
			or actualTrajectory.durationMilliseconds ~= expectedTrajectory.durationMilliseconds
			or actualTrajectory.base ~= expectedTrajectory.base
			or actualTrajectory.delta ~= expectedTrajectory.delta
			or actualAngularTrajectory.kind ~= expectedAngularTrajectory.kind
			or actualAngularTrajectory.startTimeMilliseconds ~= expectedAngularTrajectory.startTimeMilliseconds
			or actualAngularTrajectory.durationMilliseconds ~= expectedAngularTrajectory.durationMilliseconds
			or actualAngularTrajectory.base ~= expectedAngularTrajectory.base
			or actualAngularTrajectory.delta ~= expectedAngularTrajectory.delta
		then
			return false
		end
	end
	return true
end

function MovementService.PrepareMoverStep(stepServerTime: number): (PreparedMoverStep?, string?)
	if simulationFaulted then
		return nil, "mover-step-simulation-faulted"
	end
	if activePreparedMoverStep ~= nil or moverRuntime.activeDamageToken ~= nil then
		return nil, "mover-step-transaction-active"
	end
	if not isFinite(stepServerTime) then
		return nil, "invalid-mover-step-server-time"
	end
	if not fixedStepTransactionOpen then
		return nil, "mover-step-outside-fixed-step"
	end
	if moverAuthorityGeneration >= MAXIMUM_DEBUG_COUNTER then
		return nil, "mover-step-generation-exhausted"
	end
	local pendingCrushBatch = moverRuntime.pendingStudioCrushBatch
	if pendingCrushBatch then
		moverRuntime.pendingStudioCrushBatch = nil
		for index, player in pendingCrushBatch.players do
			assert(
				MovementService.PlaceStudioPlayerForMoverCrush(
					player,
					pendingCrushBatch.moverIds[index],
					0,
					true
				),
				"queued Studio mover crush placement failed"
			)
		end
	end

	local baseGeneration = moverAuthorityGeneration
	local baseWorldLimits = worldLimits
	local baseAuthoredLegacyDefinitions = moverRuntime.authoredLegacyDefinitions
	local baseBinaryPrograms = moverRuntime.binaryPrograms
	local baseBinaryPolicies = moverRuntime.binaryPolicies
	local baseBinaryPolicyByTeam = moverRuntime.binaryPolicyByTeam
	local baseBinaryMoverTeamIds = moverRuntime.binaryTeamIds
	local baseBinaryMoverIds = moverRuntime.binaryIds
	local baseLegacyMoverIds = moverRuntime.legacyIds
	local basePresentationFolder = moverRuntime.presentationFolder
	local baseBodyWorldOccupants = moverBodyWorldOccupants
	local baseDamageAdapter = moverDamageAdapter
	local baseParticipantAdapter = moverParticipantAdapter
	local baseBodyQueueAdapter = moverBodyQueueAdapter
	local baseLegacyDefinitions = moverRuntime.runtimeLegacyDefinitions
	local baseBinaryRuntime = moverRuntime.binaryRuntime
	local baseDefinitions = moverRuntime.definitions
	local baseClock = moverRuntime.clock
	local baseCollisionFrame = moverRuntime.collisionFrame
	local baseSnapshotWire = moverRuntime.snapshotWire
	local basePendingBinaryMoverUses = moverRuntime.pendingBinaryUses
	local consumedBinaryMoverUses: { string } = table.create(#basePendingBinaryMoverUses)
	for _, moverId in basePendingBinaryMoverUses do
		table.insert(consumedBinaryMoverUses, moverId)
	end
	table.freeze(consumedBinaryMoverUses)
	local nextPendingBinaryMoverUses: { string } = {}
	local baseDebug = captureMoverStepDebugState()
	local nextDebug = captureMoverStepDebugState()
	local recordBaselines, recordCount = captureMoverRecordBaselines()

	local window, windowError = MoverClock.WindowFor(baseClock)
	assert(window, windowError or "authoritative mover clock cannot advance")
	if baseParticipantAdapter then
		local opened, openError = baseParticipantAdapter.BeginFrame(window.toTimeMilliseconds)
		assert(opened, openError or "mover participant frame could not open")
		local studioParticipantCallback = moverRuntime.pendingStudioParticipantFrameCallback
		if studioParticipantCallback then
			moverRuntime.pendingStudioParticipantFrameCallback = nil
			studioParticipantCallback(window.toTimeMilliseconds)
		end
	end
	local damageAdapter = baseDamageAdapter
	local damageToken: unknown? = nil
	local moverDeathSession: MoverDeathSourceSession? = nil
	if damageAdapter then
		local frameForDamage =
			assert(openAuthoritativeFrame, "mover damage began outside an authoritative frame")
		local frameSummary = assert(
			AuthoritativeFrameService.InspectFrame(frameForDamage),
			"mover damage open frame summary is unavailable"
		)
		local token, beginError = damageAdapter.Begin(frameForDamage, stepServerTime)
		assert(token ~= nil, beginError or "mover-damage transaction could not begin")
		damageToken = token
		moverRuntime.activeDamageToken = token
		moverDeathSession = normalToDeadOwner.beginMoverDeathSourceSession(
			frameForDamage,
			frameSummary,
			window,
			baseClock,
			baseGeneration,
			baseDefinitions,
			damageAdapter,
			token
		)
	end
	local bodies, bindings = MovementMoverBodyRuntime.Collect(
		records :: any,
		if damageAdapter then damageAdapter.CollectBodies else nil,
		damageToken,
		if baseBodyQueueAdapter then baseBodyQueueAdapter.Collect else nil,
		if baseParticipantAdapter then baseParticipantAdapter.Collect else nil
	)
	local removedCallbackBodiesByPlayer: { [Player]: MoverPushRules.Body } = {}
	local blockedBoundaryBodiesById: { [string]: MoverPushRules.Body }? = nil
	local blockedBoundaryDefinitions: { MoverPushRules.Definition }? = nil
	local function occupancyTest(
		candidate: MoverPushRules.Body,
		_context: MoverPushRules.OccupancyContext
	): boolean
		local query = assert(
			baseBodyWorldOccupants,
			"authoritative mover arbitrary-body occupancy query is unavailable"
		)
		return #query(
			candidate.position,
			candidate.size,
			candidate.centerOffset,
			bit32.band(candidate.clipMask, MoverPushRules.Contents.PlayerClip) ~= 0
		) > 0
	end
	local function handleBinaryBlocked(
		event: MoverBinaryState.BlockedEvent,
		runtime: MoverBinaryState.Runtime
	): MoverBinaryState.ReachedEffect?
		local policy = moverRuntime.binaryPolicyByTeam[event.teamId]
		assert(policy, "binary mover blocked event has no trusted policy")
		assert(
			policy.captainMoverId == event.captainMoverId,
			"binary mover blocked policy captain drifted"
		)
		if policy.blockedBehavior == MoverBinaryPolicy.BlockedBehavior.None then
			return nil
		end

		-- Client entities retain their client pointer after player_die, so a
		-- blocked Door can damage either the live hull or its immediate corpse.
		-- Ordinary items/flags remain gated until their owners join this adapter.
		local binding = bindings[event.blockedByBodyId]
		assert(binding, "binary Door selected a body without a consequence owner")
		local boundaryBody = blockedBoundaryBodiesById
			and blockedBoundaryBodiesById[event.blockedByBodyId]
		assert(boundaryBody, "binary Door blocked body is absent from its rollback boundary")
		if binding.kind == "BodyQueue" then
			local adapter =
				assert(baseBodyQueueAdapter, "binary Door BodyQueue adapter disappeared")
			local mutation = adapter.ResolveBlockedDoor(binding.bodyId)
			local bodyMutations: { MoverPushRules.BodyMutation } = { mutation }
			nextDebug.binaryBlockedCallbackCount =
				saturatedAdd(nextDebug.binaryBlockedCallbackCount, 1)
			nextDebug.binaryBlockedRemovalCount =
				saturatedAdd(nextDebug.binaryBlockedRemovalCount, 1)
			nextDebug.lastBinaryBlockedMoverId = event.blockedMoverId
			nextDebug.lastBinaryBlockedBodyId = event.blockedByBodyId
			nextDebug.lastBinaryBlockedTimeMilliseconds = event.atTimeMilliseconds
			if policy.crusher then
				return { bodyMutations = bodyMutations }
			end
			local reversedRuntime, outcome, reverseError = MoverBinaryState.UseTeam(
				moverRuntime.binaryPrograms,
				runtime,
				event.teamId,
				event.atTimeMilliseconds
			)
			assert(reversedRuntime, reverseError or "blocked binary Door could not reverse")
			assert(outcome == "Reversed", "blocked binary Door did not reverse")
			nextDebug.binaryBlockedReversalCount =
				saturatedAdd(nextDebug.binaryBlockedReversalCount, 1)
			return { runtime = reversedRuntime, bodyMutations = bodyMutations }
		elseif binding.kind == "Item" then
			local adapter =
				assert(baseParticipantAdapter, "binary Door Item has no participant adapter")
			local transition = adapter.ResolveBlockedDoor(binding.bodyId)
			local mutation = assert(
				transition.bodyMutation,
				"binary Door Item consequence omitted its body mutation"
			)
			local bodyMutations: { MoverPushRules.BodyMutation } = { mutation :: any }
			nextDebug.binaryBlockedCallbackCount =
				saturatedAdd(nextDebug.binaryBlockedCallbackCount, 1)
			nextDebug.binaryBlockedRemovalCount =
				saturatedAdd(nextDebug.binaryBlockedRemovalCount, 1)
			nextDebug.lastBinaryBlockedMoverId = event.blockedMoverId
			nextDebug.lastBinaryBlockedBodyId = event.blockedByBodyId
			nextDebug.lastBinaryBlockedTimeMilliseconds = event.atTimeMilliseconds
			if policy.crusher then
				return { bodyMutations = bodyMutations }
			end
			local reversedRuntime, outcome, reverseError = MoverBinaryState.UseTeam(
				moverRuntime.binaryPrograms,
				runtime,
				event.captainMoverId,
				event.atTimeMilliseconds
			)
			assert(reversedRuntime, reverseError or "blocked Item Door reversal failed")
			assert(outcome == "Reversed", "blocked Item Door did not reverse")
			nextDebug.binaryBlockedReversalCount =
				saturatedAdd(nextDebug.binaryBlockedReversalCount, 1)
			return {
				runtime = reversedRuntime,
				bodyMutations = bodyMutations,
			}
		end
		nextDebug.binaryBlockedCallbackCount = saturatedAdd(nextDebug.binaryBlockedCallbackCount, 1)
		nextDebug.lastBinaryBlockedMoverId = event.blockedMoverId
		nextDebug.lastBinaryBlockedBodyId = event.blockedByBodyId
		nextDebug.lastBinaryBlockedTimeMilliseconds = event.atTimeMilliseconds

		local adapter = assert(damageAdapter, "binary Door has no transactional damage adapter")
		local token = assert(damageToken, "binary Door has no mover-damage transaction")
		local moverDeathSource: MoverDeathSource? = nil
		local moverDeathSourceSummary: MoverDeathSourceSummary? = nil
		if policy.damage > 0 then
			local session = assert(moverDeathSession, "binary Door has no death-source session")
			local callbackOrder = MovementMoverRuntime.NextDeathSourceCallbackOrder(
				moverRuntime,
				session,
				MAXIMUM_DEBUG_COUNTER
			)
			local definitionSet = assert(
				blockedBoundaryDefinitions,
				"binary Door blocked callback lost its rebased definitions"
			)
			local definition = assert(
				normalToDeadOwner.findMoverDefinition(definitionSet, event.captainMoverId),
				"binary Door captain definition is unavailable at callback"
			)
			if
				binding.kind == "LivePlayer"
				and boundaryBody.contents == MoverPushRules.Contents.Body
			then
				moverDeathSource, moverDeathSourceSummary = normalToDeadOwner.mintMoverDeathSource(
					session,
					"BlockedDoor",
					callbackOrder,
					binding,
					boundaryBody,
					definitionSet,
					definition
				)
			end
		end
		local damageEffect, damageError = adapter.StageDoorDamage(
			token,
			binding.player,
			event.captainMoverId,
			policy.damage,
			boundaryBody,
			moverDeathSource,
			moverDeathSourceSummary
		)
		damageEffect = assertImmediateCorpseMoverDamageEffect(
			assert(damageEffect, damageError or "binary Door damage transition failed")
		)
		if policy.damage > 0 then
			nextDebug.binaryBlockedDamageCount = saturatedAdd(nextDebug.binaryBlockedDamageCount, 1)
		end

		local bodyMutations: { MoverPushRules.BodyMutation }? = nil
		if damageEffect.kind == "Remove" then
			assert(
				adapter.IsAlive(token, binding.player) == false,
				"binary Door removed a transactionally live client body"
			)
			bodyMutations = { { kind = "Remove", bodyId = event.blockedByBodyId } }
			if binding.kind == "LivePlayer" then
				removedCallbackBodiesByPlayer[binding.player] = boundaryBody
			end
			nextDebug.binaryBlockedRemovalCount =
				saturatedAdd(nextDebug.binaryBlockedRemovalCount, 1)
		elseif damageEffect.kind == "Replace" then
			assert(
				adapter.IsAlive(token, binding.player) == false,
				"binary Door corpse replacement retained live Combat authority"
			)
			bodyMutations = { { kind = "Replace", body = damageEffect.replacementBody } }
		else
			local expectedAlive = boundaryBody.contents == MoverPushRules.Contents.Body
			assert(
				adapter.IsAlive(token, binding.player) == expectedAlive,
				"binary Door retained a client body with divergent Combat authority"
			)
		end

		if policy.crusher then
			return if bodyMutations then { bodyMutations = bodyMutations } else nil
		end
		local reversedRuntime, outcome, reverseError = MoverBinaryState.UseTeam(
			moverRuntime.binaryPrograms,
			runtime,
			event.captainMoverId,
			event.atTimeMilliseconds
		)
		assert(reversedRuntime, reverseError or "binary Door reversal failed")
		assert(outcome == "Reversed", "blocked binary Door did not reverse")
		nextDebug.binaryBlockedReversalCount = saturatedAdd(nextDebug.binaryBlockedReversalCount, 1)
		local effect: MoverBinaryState.ReachedEffect = {
			runtime = reversedRuntime,
			bodyMutations = bodyMutations,
		}
		return effect
	end
	local frame: MoverPushRules.FrameState?
	local frameError: string?
	if damageAdapter and damageToken ~= nil then
		frame, frameError = MoverPushRules.BeginFrameWithSynchronousCrush(
			baseDefinitions,
			bodies,
			window.fromTimeMilliseconds,
			window.toTimeMilliseconds,
			occupancyTest,
			function(
				crush: MoverPushRules.CrushDisposition,
				body: MoverPushRules.Body
			): MoverPushRules.SynchronousCrushEffect
				local binding = bindings[body.id]
				assert(binding, "Sine mover selected a non-player body without a crush consumer")
				if binding.kind == "BodyQueue" then
					(assert(baseBodyQueueAdapter, "Sine BodyQueue adapter disappeared")).ResolveSine(
						binding.bodyId
					)
					return { kind = "Remove", insertedBodies = {} }
				elseif binding.kind == "Item" then
					return (assert(
							baseParticipantAdapter,
							"Sine Item adapter disappeared"
						)).ResolveSine(binding.bodyId) :: any
				end
				assert(
					moverBodyId(binding.player) == crush.bodyId,
					"Sine mover crush body identity diverged from its player binding"
				)
				local session = assert(moverDeathSession, "Sine mover has no death-source session")
				local callbackOrder = MovementMoverRuntime.NextDeathSourceCallbackOrder(
					moverRuntime,
					session,
					MAXIMUM_DEBUG_COUNTER
				)
				local callbackFrame = assert(frame, "Sine mover callback lost its team frame")
				local definition = assert(
					normalToDeadOwner.findMoverDefinition(callbackFrame.definitions, crush.moverId),
					"Sine mover pusher definition is unavailable at callback"
				)
				local moverDeathSource: MoverDeathSource? = nil
				local moverDeathSourceSummary: MoverDeathSourceSummary? = nil
				if
					binding.kind == "LivePlayer"
					and body.contents == MoverPushRules.Contents.Body
				then
					moverDeathSource, moverDeathSourceSummary =
						normalToDeadOwner.mintMoverDeathSource(
							session,
							"SinePush",
							callbackOrder,
							binding,
							body,
							callbackFrame.definitions,
							definition
						)
				end
				local damageEffect, transitionError = damageAdapter.StageSineCrush(
					damageToken,
					binding.player,
					crush.moverId,
					body,
					moverDeathSource,
					moverDeathSourceSummary
				)
				damageEffect = assertImmediateCorpseMoverDamageEffect(
					assert(
						damageEffect,
						transitionError or "authoritative mover crush transition failed"
					)
				)
				if damageEffect.kind == "Remove" then
					assert(
						damageAdapter.IsAlive(damageToken, binding.player) == false,
						"removed mover-crush body remained transactionally alive"
					)
					if binding.kind == "LivePlayer" then
						removedCallbackBodiesByPlayer[binding.player] = body
					end
					nextDebug.moverCrushRemovedCount =
						saturatedAdd(nextDebug.moverCrushRemovedCount, 1)
				elseif damageEffect.kind == "Replace" then
					assert(
						damageAdapter.IsAlive(damageToken, binding.player) == false,
						"corpse-replaced mover-crush body remained transactionally alive"
					)
					nextDebug.moverCrushRetainedCount =
						saturatedAdd(nextDebug.moverCrushRetainedCount, 1)
				else
					local expectedAlive = body.contents == MoverPushRules.Contents.Body
					assert(
						damageAdapter.IsAlive(damageToken, binding.player) == expectedAlive,
						"retained mover-crush body diverged from its transactional identity"
					)
					nextDebug.moverCrushRetainedCount =
						saturatedAdd(nextDebug.moverCrushRetainedCount, 1)
				end
				nextDebug.moverCrushTransitionCount =
					saturatedAdd(nextDebug.moverCrushTransitionCount, 1)
				nextDebug.lastCrushMoverId = crush.moverId
				nextDebug.lastCrushBodyId = crush.bodyId
				nextDebug.lastCrushClockStep = window.fromStep
				return damageEffect
			end
		)
	else
		frame, frameError = MoverPushRules.BeginFrame(
			baseDefinitions,
			bodies,
			window.fromTimeMilliseconds,
			window.toTimeMilliseconds,
			occupancyTest
		)
	end
	assert(frame, frameError or "authoritative mover frame failed")
	local nextBinaryRuntime = baseBinaryRuntime
	frame, nextBinaryRuntime = applyQueuedBinaryMoverUses(
		frame,
		nextBinaryRuntime,
		window,
		consumedBinaryMoverUses,
		nextDebug
	)

	-- G_RunMover completes one captain's G_MoverTeam, blocked/reached callback,
	-- and think work before the next captain. Keep that boundary explicit here:
	-- a blocked team is rebased and relinked immediately, so every later team
	-- observes the exact authoritative world state produced by its predecessors.
	local runtimeDefinitions = frame.definitions
	while frame.nextTeamIndex <= frame.teamCount do
		local boundary, boundaryError = MoverPushRules.AdvanceNextTeam(frame)
		assert(boundary, boundaryError or "authoritative mover team failed")

		if moverRuntime.binaryTeamIds[boundary.teamId] == true then
			local currentBinaryRuntime =
				assert(nextBinaryRuntime, "binary mover team has no authoritative runtime")
			if boundary.teamResult.disposition == "BlockedRollback" then
				local rebasedRuntime, rebasedBoundary, rebaseError =
					MoverBinaryState.ApplyBlockedBoundaryRebase(
						moverRuntime.binaryPrograms,
						currentBinaryRuntime,
						boundary,
						window
					)
				assert(rebasedRuntime, rebaseError or "binary mover boundary rebase failed")
				assert(rebasedBoundary, rebaseError or "binary mover boundary relink failed")
				blockedBoundaryBodiesById = {}
				for _, boundaryBody in rebasedBoundary.bodies do
					blockedBoundaryBodiesById[boundaryBody.id] = boundaryBody
				end
				blockedBoundaryDefinitions = rebasedBoundary.definitions
				local callbackRuntime, callbackBoundary, _blockedEvent, callbackError =
					MoverBinaryState.ProcessBlockedCallback(
						moverRuntime.binaryPrograms,
						rebasedRuntime,
						rebasedBoundary,
						handleBinaryBlocked
					)
				assert(callbackRuntime, callbackError or "binary mover blocked callback failed")
				assert(
					callbackBoundary,
					callbackError or "binary mover blocked callback relink failed"
				)
				blockedBoundaryBodiesById = nil
				blockedBoundaryDefinitions = nil
				nextBinaryRuntime = callbackRuntime
				boundary = callbackBoundary
			else
				local committedRuntime, committedBoundary, _reachedEvents, committedError =
					MoverBinaryState.ProcessCommittedBoundary(
						moverRuntime.binaryPrograms,
						currentBinaryRuntime,
						boundary,
						window,
						nil
					)
				assert(committedRuntime, committedError or "binary mover reached processing failed")
				assert(
					committedBoundary,
					committedError or "binary mover reached boundary relink failed"
				)
				nextBinaryRuntime = committedRuntime
				boundary = committedBoundary
			end

			local thinkRuntime, thinkBoundary, _ranThink, thinkError =
				MoverBinaryState.ProcessCaptainThink(
					moverRuntime.binaryPrograms,
					assert(nextBinaryRuntime, "binary mover think requires authoritative runtime"),
					boundary
				)
			assert(thinkRuntime, thinkError or "binary mover captain think failed")
			assert(thinkBoundary, thinkError or "binary mover captain think relink failed")
			nextBinaryRuntime = thinkRuntime
			boundary = thinkBoundary
		elseif boundary.teamResult.disposition == "BlockedRollback" then
			local nextDefinitions, rebaseError =
				MoverRuntimeRules.ApplyBlockedBoundaryRebase(boundary.definitions, boundary, window)
			assert(nextDefinitions, rebaseError or "authoritative mover boundary rebase failed")
			local updatedBoundary, updateError = MoverPushRules.ApplyBoundaryUpdate(boundary, {
				definitions = nextDefinitions,
			})
			assert(updatedBoundary, updateError or "authoritative mover boundary relink failed")
			boundary = updatedBoundary
		end

		-- Every callback/rebase can relink the complete source-ordered mover set.
		-- Carry that exact set into the next captain instead of rebuilding a domain.
		runtimeDefinitions = boundary.definitions
		local nextFrame, closeError = MoverPushRules.CloseBoundary(boundary)
		assert(nextFrame, closeError or "authoritative mover boundary close failed")
		frame = nextFrame
	end

	local result, resultError = MoverPushRules.FinishFrame(frame)
	assert(result, resultError or "authoritative mover push failed")
	assert(
		not result.requiresSynchronousCrushTransition,
		"sine mover crush reached a consumer without synchronous damage mutation"
	)
	if #moverRuntime.binaryPrograms > 0 then
		local publishableRuntime, publishableError = MoverBinaryState.InspectPublishableRuntime(
			moverRuntime.binaryPrograms,
			nextBinaryRuntime
		)
		assert(
			publishableRuntime == nextBinaryRuntime,
			publishableError or "binary mover runtime is not publishable"
		)
	else
		assert(nextBinaryRuntime == nil, "empty binary mover domain gained runtime")
	end
	local nextLegacyDefinitions = extractRuntimeLegacyDefinitions(runtimeDefinitions)
	local expectedRuntimeDefinitions =
		composeRuntimeMoverDefinitions(nextLegacyDefinitions, nextBinaryRuntime)
	assert(
		moverDefinitionsMatch(runtimeDefinitions, expectedRuntimeDefinitions),
		"physical mover definitions diverged from legacy and binary authority"
	)
	local nextClock = assert(MoverClock.Advance(baseClock))
	local nextCollisionFrame = assert(MoverCollisionFrame.Build(runtimeDefinitions, nextClock))
	assert(
		#result.movers == #nextCollisionFrame.poses,
		"committed mover pose count diverged from the collision frame"
	)
	for index, pose in result.movers do
		local committedPose = nextCollisionFrame.poses[index]
		assert(
			committedPose.id == pose.id
				and committedPose.position == pose.position
				and committedPose.angles == pose.angles
				and committedPose.size == pose.size,
			"committed mover pose diverged from the collision frame"
		)
	end
	local nextSnapshotWire =
		serializeMoverSnapshotWire(nextClock, nextLegacyDefinitions, nextBinaryRuntime)
	local moverPresentationOperations = MovementMoverPresentationRuntime.Plan(
		moverRuntime.presentationFolder,
		nextCollisionFrame.poses
	)
	if damageAdapter and damageToken ~= nil then
		local appliedBodies, applyBodiesError =
			damageAdapter.ApplyMoverBodies(damageToken, result.bodies)
		assert(appliedBodies, applyBodiesError or "mover consequence bodies could not be finalized")
		local sealed, sealError = damageAdapter.Seal(damageToken)
		assert(sealed, sealError or "mover-damage transaction could not be sealed")
	end
	local participantPrepared: unknown? = nil
	if baseParticipantAdapter then
		local preparedParticipant, participantError = baseParticipantAdapter.Prepare(result.bodies)
		assert(
			preparedParticipant ~= nil,
			participantError or "Item mover participant update could not prepare"
		)
		participantPrepared = preparedParticipant
	end
	local bodyQueuePrepared: unknown? = nil
	if baseBodyQueueAdapter then
		local preparedBodyQueue, bodyQueueError = baseBodyQueueAdapter.Prepare(result.bodies)
		assert(
			preparedBodyQueue ~= nil,
			bodyQueueError or "BodyQueue mover participant update could not prepare"
		)
		bodyQueuePrepared = preparedBodyQueue
	end

	table.freeze(removedCallbackBodiesByPlayer)
	-- G_RunFrame performs ClientEndFrame for every connected client after all
	-- movers. The extracted planner selects each final state; this typed factory
	-- retains Movement's five exact player/entity projection domains.
	local stateAssignments, movedPlayers = MovementMoverPlayerRuntime.Plan(
		result,
		bindings :: any,
		recordBaselines :: any,
		removedCallbackBodiesByPlayer,
		function(
			player: Player,
			baselineValue: any,
			nextState: Movement.State,
			removedCallbackBody: MoverPushRules.Body?
		): MoverPlayerStateAssignment
			local baseline = baselineValue :: MoverRecordBaseline
			local state = assert(baseline.state, "mover assignment baseline lost its state")
			local assignment: MoverPlayerStateAssignment = {
				player = player,
				record = baseline.record,
				baseState = state,
				nextState = nextState,
				removedCallbackBody = removedCallbackBody,
				baseEntityTrajectoryDelta = baseline.entityTrajectoryDelta,
				nextEntityTrajectoryDelta = nextState.velocity,
				baseEntityTrajectoryBase = baseline.entityTrajectoryBase,
				nextEntityTrajectoryBase = projectedTrajectoryBase(nextState),
				baseEntityAngularTrajectoryBase = baseline.entityAngularTrajectoryBase,
				nextEntityAngularTrajectoryBase = if baseline.awaitingViewCommand
					then baseline.entityAngularTrajectoryBase
					else projectedAngularTrajectoryBase(baseline.playerStateViewAngles),
				baseEntityGenericAngles = baseline.entityGenericAngles,
				basePlayerStateViewAngles = baseline.playerStateViewAngles,
				nextPlayerStateViewAngles = baseline.playerStateViewAngles,
			}
			table.freeze(assignment)
			return assignment
		end
	)
	local spawnReservationAssignments: { MoverSpawnReservationAssignment } = {}
	table.freeze(spawnReservationAssignments)
	local boundLethalMoverDeathSources: { MoverDeathSourceCapability } = {}
	table.freeze(boundLethalMoverDeathSources)
	local lethalNormalToDeadRecords: { [PlayerRecord]: boolean } = {}
	table.freeze(lethalNormalToDeadRecords)
	local lethalNormalToDeadAssignments: { [PlayerRecord]: MoverPlayerStateAssignment } = {}
	table.freeze(lethalNormalToDeadAssignments)
	local normalToDeadApplyEntries: { PreparedMoverNormalToDeadApplyEntry } = {}
	table.freeze(normalToDeadApplyEntries)
	table.freeze(baseDebug)
	table.freeze(nextDebug)
	local preparedHandle: PreparedMoverStep = table.freeze({})
	local receipt: MoverStepReceipt = {
		movedPlayers = movedPlayers,
		damageToken = damageToken,
	}
	table.freeze(receipt)
	local capability: PreparedMoverStepCapability = {
		status = "Prepared",
		applyValidated = false,
		baseGeneration = baseGeneration,
		nextGeneration = baseGeneration + 1,
		baseFixedStepTransactionOpen = fixedStepTransactionOpen,
		baseWorldLimits = baseWorldLimits,
		baseAuthoredLegacyDefinitions = baseAuthoredLegacyDefinitions,
		baseBinaryPrograms = baseBinaryPrograms,
		baseBinaryPolicies = baseBinaryPolicies,
		baseBinaryPolicyByTeam = baseBinaryPolicyByTeam,
		baseBinaryMoverTeamIds = baseBinaryMoverTeamIds,
		baseBinaryMoverIds = baseBinaryMoverIds,
		baseLegacyMoverIds = baseLegacyMoverIds,
		basePresentationFolder = basePresentationFolder,
		baseBodyWorldOccupants = baseBodyWorldOccupants,
		baseDamageAdapter = baseDamageAdapter,
		baseParticipantAdapter = baseParticipantAdapter,
		baseBodyQueueAdapter = baseBodyQueueAdapter,
		baseLegacyDefinitions = baseLegacyDefinitions,
		baseBinaryRuntime = baseBinaryRuntime,
		baseDefinitions = baseDefinitions,
		baseClock = baseClock,
		baseCollisionFrame = baseCollisionFrame,
		baseSnapshotWire = baseSnapshotWire,
		basePendingBinaryMoverUses = basePendingBinaryMoverUses,
		consumedBinaryMoverUses = consumedBinaryMoverUses,
		nextPendingBinaryMoverUses = nextPendingBinaryMoverUses,
		baseDebug = baseDebug,
		nextDebug = nextDebug,
		recordBaselines = recordBaselines,
		recordCount = recordCount,
		stateAssignments = stateAssignments,
		boundNormalToDeadBatch = nil,
		boundNormalToDeadBatchSummary = nil,
		boundNormalToDeadBatchReceipt = nil,
		boundNormalToDeadMemberReceipts = nil,
		boundNormalToDeadDependency = nil,
		lethalNormalToDeadRecords = lethalNormalToDeadRecords,
		lethalNormalToDeadAssignments = lethalNormalToDeadAssignments,
		normalToDeadApplyEntries = normalToDeadApplyEntries,
		boundCombatPrepared = nil,
		boundCombatMovementSummary = nil,
		moverDeathSession = moverDeathSession,
		boundLethalMoverDeathSources = boundLethalMoverDeathSources,
		spawnReservationAssignments = spawnReservationAssignments,
		nextLegacyDefinitions = nextLegacyDefinitions,
		nextBinaryRuntime = nextBinaryRuntime,
		nextDefinitions = runtimeDefinitions,
		nextClock = nextClock,
		nextCollisionFrame = nextCollisionFrame,
		nextSnapshotWire = nextSnapshotWire,
		presentationOperations = moverPresentationOperations,
		damageToken = damageToken,
		participantPrepared = participantPrepared,
		bodyQueuePrepared = bodyQueuePrepared,
		receipt = receipt,
		preparedHandle = preparedHandle,
	}
	preparedMoverStepCapabilities[preparedHandle] = capability
	moverStepReceiptCapabilities[receipt] = capability
	activePreparedMoverStep = preparedHandle
	if moverDeathSession then
		MovementMoverRuntime.PrepareDeathSourceSession(
			moverRuntime,
			moverDeathSession,
			preparedHandle
		)
	end
	return preparedHandle, nil
end

local function getPreparedMoverStepCapability(
	preparedValue: unknown
): (PreparedMoverStepCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-prepared-mover-step"
	end
	local capability = preparedMoverStepCapabilities[preparedValue :: PreparedMoverStep]
	if not capability then
		return nil, "invalid-prepared-mover-step"
	end
	return capability, nil
end

-- This function is intentionally allocation-, callback-, Instance-, and
-- adapter-free. It pins every mutable Movement owner root plus every
-- PlayerRecord/state identity before the assignment-only apply boundary.
local function preparedMoverStepCurrentError(
	preparedValue: unknown,
	capability: PreparedMoverStepCapability
): string?
	if
		capability.status ~= "Prepared"
		or activePreparedMoverStep ~= preparedValue
		or preparedMoverStepCapabilities[preparedValue :: PreparedMoverStep] ~= capability
		or moverStepReceiptCapabilities[capability.receipt] ~= capability
		or capability.preparedHandle ~= preparedValue
		or moverAuthorityGeneration ~= capability.baseGeneration
		or capability.nextGeneration ~= capability.baseGeneration + 1
		or fixedStepTransactionOpen ~= capability.baseFixedStepTransactionOpen
		or not fixedStepTransactionOpen
		or worldLimits ~= capability.baseWorldLimits
		or moverRuntime.authoredLegacyDefinitions ~= capability.baseAuthoredLegacyDefinitions
		or moverRuntime.binaryPrograms ~= capability.baseBinaryPrograms
		or moverRuntime.binaryPolicies ~= capability.baseBinaryPolicies
		or moverRuntime.binaryPolicyByTeam ~= capability.baseBinaryPolicyByTeam
		or moverRuntime.binaryTeamIds ~= capability.baseBinaryMoverTeamIds
		or moverRuntime.binaryIds ~= capability.baseBinaryMoverIds
		or moverRuntime.legacyIds ~= capability.baseLegacyMoverIds
		or moverRuntime.presentationFolder ~= capability.basePresentationFolder
		or moverBodyWorldOccupants ~= capability.baseBodyWorldOccupants
		or moverDamageAdapter ~= capability.baseDamageAdapter
		or moverParticipantAdapter ~= capability.baseParticipantAdapter
		or moverBodyQueueAdapter ~= capability.baseBodyQueueAdapter
		or moverRuntime.runtimeLegacyDefinitions ~= capability.baseLegacyDefinitions
		or moverRuntime.binaryRuntime ~= capability.baseBinaryRuntime
		or moverRuntime.definitions ~= capability.baseDefinitions
		or moverRuntime.clock ~= capability.baseClock
		or moverRuntime.collisionFrame ~= capability.baseCollisionFrame
		or moverRuntime.snapshotWire ~= capability.baseSnapshotWire
		or moverRuntime.pendingBinaryUses ~= capability.basePendingBinaryMoverUses
		or moverRuntime.activeDamageToken ~= capability.damageToken
		or capability.receipt.damageToken ~= capability.damageToken
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(capability.receipt.movedPlayers)
		or not table.isfrozen(capability.consumedBinaryMoverUses)
		or not table.isfrozen(capability.baseDebug)
		or not table.isfrozen(capability.nextDebug)
		or not table.isfrozen(capability.recordBaselines)
		or not table.isfrozen(capability.stateAssignments)
		or not table.isfrozen(capability.lethalNormalToDeadRecords)
		or not table.isfrozen(capability.lethalNormalToDeadAssignments)
		or not table.isfrozen(capability.normalToDeadApplyEntries)
		or not table.isfrozen(capability.spawnReservationAssignments)
		or not table.isfrozen(capability.boundLethalMoverDeathSources)
		or not table.isfrozen(capability.presentationOperations)
		or #capability.nextPendingBinaryMoverUses ~= 0
		or not moverStepDebugStateIsCurrent(capability.baseDebug)
	then
		return "stale-prepared-mover-step"
	end

	if #moverRuntime.pendingBinaryUses ~= #capability.consumedBinaryMoverUses then
		return "stale-prepared-mover-step"
	end
	for index, moverId in moverRuntime.pendingBinaryUses do
		if capability.consumedBinaryMoverUses[index] ~= moverId then
			return "stale-prepared-mover-step"
		end
	end

	local currentRecordCount = 0
	local currentStateCount = 0
	for player, record in records do
		currentRecordCount += 1
		local baseline = capability.recordBaselines[player]
		if record.state then
			currentStateCount += 1
		end
		if
			not baseline
			or not table.isfrozen(baseline)
			or baseline.record ~= record
			or baseline.state ~= record.state
			or baseline.awaitingViewCommand ~= record.awaitingViewCommand
			or baseline.lifeSequence ~= record.lifeSequence
			or baseline.lifeBinding ~= record.lifeBinding
			or baseline.entityTrajectoryBase ~= record.entityTrajectoryBase
			or baseline.entityTrajectoryDelta ~= record.entityTrajectoryDelta
			or baseline.entityAngularTrajectoryBase ~= record.entityAngularTrajectoryBase
			or baseline.entityGenericAngles ~= record.entityGenericAngles
			or baseline.playerStateViewAngles ~= record.playerStateViewAngles
			or baseline.deadState ~= record.deadState
			or baseline.deathTransition ~= record.deathTransition
			or baseline.firstDeadStepPhase ~= record.firstDeadStepPhase
			or not table.isfrozen(record.entityAngularTrajectoryBase)
			or not table.isfrozen(record.entityGenericAngles)
			or not table.isfrozen(record.playerStateViewAngles)
			or (
				baseline.lifeBinding ~= nil
				and currentMovementLifeBinding(baseline.lifeBinding) == nil
			)
		then
			return "stale-prepared-mover-step"
		end
	end
	if
		currentRecordCount ~= capability.recordCount
		or currentStateCount ~= #capability.stateAssignments
	then
		return "stale-prepared-mover-step"
	end
	for player, baseline in capability.recordBaselines do
		if
			not table.isfrozen(baseline)
			or records[player] ~= baseline.record
			or baseline.record.state ~= baseline.state
			or baseline.record.awaitingViewCommand ~= baseline.awaitingViewCommand
			or baseline.record.lifeSequence ~= baseline.lifeSequence
			or baseline.record.lifeBinding ~= baseline.lifeBinding
			or baseline.record.entityTrajectoryBase ~= baseline.entityTrajectoryBase
			or baseline.record.entityTrajectoryDelta ~= baseline.entityTrajectoryDelta
			or baseline.record.entityAngularTrajectoryBase ~= baseline.entityAngularTrajectoryBase
			or baseline.record.entityGenericAngles ~= baseline.entityGenericAngles
			or baseline.record.playerStateViewAngles ~= baseline.playerStateViewAngles
			or baseline.record.deadState ~= baseline.deadState
			or baseline.record.deathTransition ~= baseline.deathTransition
			or baseline.record.firstDeadStepPhase ~= baseline.firstDeadStepPhase
			or not table.isfrozen(baseline.entityAngularTrajectoryBase)
			or not table.isfrozen(baseline.entityGenericAngles)
			or not table.isfrozen(baseline.playerStateViewAngles)
		then
			return "stale-prepared-mover-step"
		end
	end
	for _, assignment in capability.stateAssignments do
		local baseline = capability.recordBaselines[assignment.player]
		if
			not table.isfrozen(assignment)
			or not baseline
			or baseline.record ~= assignment.record
			or baseline.state ~= assignment.baseState
			or baseline.entityTrajectoryBase ~= assignment.baseEntityTrajectoryBase
			or baseline.entityTrajectoryDelta ~= assignment.baseEntityTrajectoryDelta
			or baseline.entityAngularTrajectoryBase ~= assignment.baseEntityAngularTrajectoryBase
			or baseline.entityGenericAngles ~= assignment.baseEntityGenericAngles
			or baseline.playerStateViewAngles ~= assignment.basePlayerStateViewAngles
			or records[assignment.player] ~= assignment.record
			or assignment.record.state ~= assignment.baseState
			or assignment.record.entityTrajectoryBase ~= assignment.baseEntityTrajectoryBase
			or assignment.record.entityTrajectoryDelta ~= assignment.baseEntityTrajectoryDelta
			or assignment.record.entityAngularTrajectoryBase ~= assignment.baseEntityAngularTrajectoryBase
			or assignment.record.entityGenericAngles ~= assignment.baseEntityGenericAngles
			or assignment.record.playerStateViewAngles ~= assignment.basePlayerStateViewAngles
			or assignment.nextEntityTrajectoryDelta ~= assignment.nextState.velocity
			or (assignment.removedCallbackBody ~= nil and (not table.isfrozen(
				assignment.removedCallbackBody
			) or assignment.removedCallbackBody.id ~= assignment.record.moverBodyId or assignment.removedCallbackBody.sourceOrder ~= assignment.record.moverBodySourceOrder or assignment.removedCallbackBody.position ~= assignment.nextState.position))
			or not table.isfrozen(assignment.nextEntityAngularTrajectoryBase)
			or assignment.nextPlayerStateViewAngles ~= assignment.basePlayerStateViewAngles
			or not table.isfrozen(assignment.nextPlayerStateViewAngles)
		then
			return "stale-prepared-mover-step"
		end
	end

	local boundCombatPrepared = capability.boundCombatPrepared
	local boundSummaryValue = capability.boundCombatMovementSummary
	local moverDeathSession = capability.moverDeathSession
	if capability.damageToken ~= nil then
		if
			boundCombatPrepared == nil
			or boundSummaryValue == nil
			or not moverDeathSession
			or moverDeathSession.damageToken ~= capability.damageToken
			or moverDeathSession.preparedHandle ~= preparedValue
			or moverDeathSession.status ~= "Bound"
			or MovementMoverRuntime.GetDeathSourceSession(moverRuntime) ~= moverDeathSession
		then
			return "unbound-mover-combat-dependency"
		end
	elseif capability.damageToken == nil then
		if
			boundCombatPrepared ~= nil
			or boundSummaryValue ~= nil
			or moverDeathSession ~= nil
			or #capability.boundLethalMoverDeathSources ~= 0
			or #capability.spawnReservationAssignments ~= 0
		then
			return "unexpected-mover-combat-dependency"
		end
		return normalToDeadOwner.moverNormalToDeadDependencyCurrentError(capability, true)
	end
	if
		type(boundCombatPrepared) ~= "table"
		or not table.isfrozen(boundCombatPrepared :: any)
		or type(boundSummaryValue) ~= "table"
		or not table.isfrozen(boundSummaryValue :: any)
	then
		return "stale-mover-combat-dependency"
	end
	local releaseSpawnPlayers = (boundSummaryValue :: any).releaseSpawnPlayers
	local lifeBindings = (boundSummaryValue :: any).lifeBindings
	local lethalMoverSources = (boundSummaryValue :: any).lethalMoverSources
	if
		type(releaseSpawnPlayers) ~= "table"
		or not table.isfrozen(releaseSpawnPlayers)
		or type(lifeBindings) ~= "table"
		or not table.isfrozen(lifeBindings)
		or type(lethalMoverSources) ~= "table"
		or not table.isfrozen(lethalMoverSources)
		or #releaseSpawnPlayers ~= #capability.spawnReservationAssignments
		or #lifeBindings ~= #releaseSpawnPlayers
		or #lethalMoverSources ~= #capability.boundLethalMoverDeathSources
	then
		return "stale-mover-combat-dependency"
	end
	for index, assignment in capability.spawnReservationAssignments do
		local lifeDependency = lifeBindings[index]
		if
			not table.isfrozen(assignment)
			or releaseSpawnPlayers[index] ~= assignment.player
			or type(lifeDependency) ~= "table"
			or not table.isfrozen(lifeDependency)
			or lifeDependency.player ~= assignment.player
			or lifeDependency.binding ~= assignment.record.lifeBinding
			or not MovementService.ValidateMovementLifeBindingDependency(
				lifeDependency.binding,
				lifeDependency.summary
			)
			or records[assignment.player] ~= assignment.record
			or assignment.record.spawnReserved ~= assignment.baseSpawnReserved
		then
			return "stale-mover-combat-dependency"
		end
	end
	for index, sourceCapability in capability.boundLethalMoverDeathSources do
		local dependency = lethalMoverSources[index]
		if
			type(dependency) ~= "table"
			or not table.isfrozen(dependency)
			or sourceCapability.session ~= moverDeathSession
			or sourceCapability.status ~= "BoundLethal"
			or dependency.source ~= sourceCapability.source
			or dependency.sourceSummary ~= sourceCapability.summary
			or dependency.stageReceipt ~= sourceCapability.stageReceipt
			or dependency.player ~= sourceCapability.summary.victim
			or dependency.body ~= sourceCapability.body
			or not select(
				1,
				normalToDeadOwner.currentMoverDeathSource(
					sourceCapability.source,
					sourceCapability.summary
				)
			)
		then
			return "stale-mover-combat-lethal-source-dependency"
		end
	end
	return normalToDeadOwner.moverNormalToDeadDependencyCurrentError(capability, true)
end

function MovementService.GetPreparedMoverDamageToken(preparedValue: unknown): unknown?
	local capability = select(1, getPreparedMoverStepCapability(preparedValue))
	if not capability or capability.status ~= "Prepared" then
		return nil
	end
	return capability.damageToken
end

function MovementService.BindPreparedMoverCombatDependency(
	preparedValue: unknown,
	combatPreparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, capabilityError = getPreparedMoverStepCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	if
		capability.status ~= "Prepared"
		or activePreparedMoverStep ~= preparedValue
		or capability.damageToken == nil
	then
		return false, "mover-combat-dependency-not-bindable"
	end
	if capability.boundCombatPrepared ~= nil or capability.boundCombatMovementSummary ~= nil then
		return false, "mover-combat-dependency-already-bound"
	end
	local adapter = capability.baseDamageAdapter
	if not adapter then
		return false, "mover-combat-dependency-adapter-missing"
	end
	local validated, validationError =
		adapter.ValidatePreparedMovementDependency(combatPreparedValue, summaryValue)
	if not validated then
		return false, validationError or "invalid-mover-combat-dependency"
	end
	if
		type(combatPreparedValue) ~= "table"
		or not table.isfrozen(combatPreparedValue :: any)
		or type(summaryValue) ~= "table"
		or not table.isfrozen(summaryValue :: any)
	then
		return false, "invalid-mover-combat-dependency-capability"
	end
	local summary = summaryValue :: any
	local releaseSpawnPlayers = summary.releaseSpawnPlayers
	local lifeBindings = summary.lifeBindings
	local lethalMoverSources = summary.lethalMoverSources
	if
		type(releaseSpawnPlayers) ~= "table"
		or not table.isfrozen(releaseSpawnPlayers)
		or type(lifeBindings) ~= "table"
		or not table.isfrozen(lifeBindings)
		or type(lethalMoverSources) ~= "table"
		or not table.isfrozen(lethalMoverSources)
		or #lifeBindings ~= #releaseSpawnPlayers
	then
		return false, "invalid-mover-combat-release-summary"
	end
	local assignments: { MoverSpawnReservationAssignment } = {}
	local seenPlayers: { [Player]: boolean } = {}
	local previousSourceOrder = 0
	local playerCount = 0
	for index, playerValue in releaseSpawnPlayers do
		local lifeDependency = lifeBindings[index]
		if
			type(index) ~= "number"
			or index % 1 ~= 0
			or index < 1
			or typeof(playerValue) ~= "Instance"
			or not (playerValue :: Instance):IsA("Player")
			or type(lifeDependency) ~= "table"
			or not table.isfrozen(lifeDependency)
		then
			return false, "invalid-mover-combat-release-player"
		end
		local player = playerValue :: Player
		if seenPlayers[player] then
			return false, "duplicate-mover-combat-release-player"
		end
		local baseline = capability.recordBaselines[player]
		local record = records[player]
		if
			not baseline
			or record ~= baseline.record
			or record.state ~= baseline.state
			or lifeDependency.player ~= player
			or lifeDependency.binding ~= baseline.lifeBinding
			or not MovementService.ValidateMovementLifeBindingDependency(
				lifeDependency.binding,
				lifeDependency.summary
			)
			or record.moverBodySourceOrder <= previousSourceOrder
		then
			return false, "stale-mover-combat-release-player"
		end
		previousSourceOrder = record.moverBodySourceOrder
		seenPlayers[player] = true
		playerCount += 1
		local assignment: MoverSpawnReservationAssignment = {
			player = player,
			record = record,
			baseSpawnReserved = record.spawnReserved,
		}
		table.freeze(assignment)
		table.insert(assignments, assignment)
	end
	if playerCount ~= #releaseSpawnPlayers then
		return false, "sparse-mover-combat-release-summary"
	end
	local moverDeathSession = capability.moverDeathSession
	if
		not moverDeathSession
		or moverDeathSession.status ~= "Prepared"
		or moverDeathSession.preparedHandle ~= preparedValue
		or moverDeathSession.damageToken ~= capability.damageToken
		or MovementMoverRuntime.GetDeathSourceSession(moverRuntime) ~= moverDeathSession
		or #lethalMoverSources ~= #releaseSpawnPlayers
	then
		return false, "invalid-mover-combat-lethal-source-session"
	end
	local boundLethalMoverDeathSources: { MoverDeathSourceCapability } = {}
	local boundSourceSeen: { [MoverDeathSource]: boolean } = {}
	local boundPlayerSeen: { [Player]: boolean } = {}
	local previousCallbackOrder = 0
	local previousOperationIndex = 0
	for index, dependencyValue in lethalMoverSources do
		if
			type(index) ~= "number"
			or index % 1 ~= 0
			or index < 1
			or type(dependencyValue) ~= "table"
			or not table.isfrozen(dependencyValue)
		then
			return false, "invalid-mover-combat-lethal-source-entry"
		end
		local dependency = dependencyValue :: any
		local sourceCapability, sourceError =
			normalToDeadOwner.currentMoverDeathSource(dependency.source, dependency.sourceSummary)
		if
			not sourceCapability
			or sourceCapability.status ~= "Claimed"
			or sourceCapability.session ~= moverDeathSession
			or sourceCapability.stageReceipt ~= dependency.stageReceipt
			or dependency.player ~= sourceCapability.summary.victim
			or dependency.body ~= sourceCapability.body
			or not seenPlayers[dependency.player]
			or type(dependency.operationIndex) ~= "number"
			or dependency.operationIndex % 1 ~= 0
			or dependency.operationIndex <= previousOperationIndex
			or sourceCapability.summary.callbackTraversalOrder <= previousCallbackOrder
			or type(dependency.context) ~= "table"
			or not table.isfrozen(dependency.context)
			or boundSourceSeen[sourceCapability.source]
			or boundPlayerSeen[dependency.player]
		then
			return false, sourceError or "invalid-mover-combat-lethal-source-binding"
		end
		boundSourceSeen[sourceCapability.source] = true
		boundPlayerSeen[dependency.player] = true
		previousCallbackOrder = sourceCapability.summary.callbackTraversalOrder
		previousOperationIndex = dependency.operationIndex
		table.insert(boundLethalMoverDeathSources, sourceCapability)
	end
	if #boundLethalMoverDeathSources ~= #lethalMoverSources then
		return false, "sparse-mover-combat-lethal-source-summary"
	end
	table.freeze(boundLethalMoverDeathSources)
	for _, sourceCapability in moverDeathSession.sources do
		if boundSourceSeen[sourceCapability.source] then
			sourceCapability.status = "BoundLethal"
		else
			sourceCapability.status = "Retired"
			sourceCapability.stageReceipt = nil
		end
	end
	moverDeathSession.status = "Bound"
	table.freeze(assignments)
	capability.boundCombatPrepared = combatPreparedValue
	capability.boundCombatMovementSummary = summaryValue
	capability.boundLethalMoverDeathSources = boundLethalMoverDeathSources
	capability.spawnReservationAssignments = assignments
	return true, nil
end

-- Dormant prospective player_die binding. The exact Combat owner and its
-- Movement summary must already be bound to this mover step. No raw impulse,
-- vector, source ID, or replacement Player state is accepted here.
function MovementService.BindPreparedMoverNormalToDeadBatch(
	preparedValue: unknown,
	combatPreparedValue: unknown,
	combatMovementSummaryValue: unknown
): (boolean, string?)
	local capability, capabilityError = getPreparedMoverStepCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.status ~= "Prepared"
		or activePreparedMoverStep ~= preparedValue
		or combatPreparedValue ~= capability.boundCombatPrepared
		or combatMovementSummaryValue ~= capability.boundCombatMovementSummary
	then
		return false, "invalid-mover-normal-to-dead-combat-dependency"
	end
	if
		capability.boundNormalToDeadBatch ~= nil
		or capability.boundNormalToDeadBatchSummary ~= nil
		or capability.boundNormalToDeadBatchReceipt ~= nil
		or capability.boundNormalToDeadMemberReceipts ~= nil
		or capability.boundNormalToDeadDependency ~= nil
		or next(capability.lethalNormalToDeadRecords) ~= nil
		or next(capability.lethalNormalToDeadAssignments) ~= nil
		or #capability.normalToDeadApplyEntries ~= 0
	then
		return false, "mover-normal-to-dead-dependency-already-bound"
	end
	local currentError = preparedMoverStepCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local combatSummary = combatMovementSummaryValue :: any
	local lethalDependencies = combatSummary.lethalMoverSources
	if
		type(lethalDependencies) ~= "table"
		or not table.isfrozen(lethalDependencies)
		or #lethalDependencies ~= #capability.boundLethalMoverDeathSources
	then
		return false, "invalid-mover-normal-to-dead-lethal-summary"
	end
	local assignmentDescriptors: { any } = {}
	for _, assignment in capability.stateAssignments do
		local descriptor = {
			player = assignment.player,
			assignment = assignment,
			playerSourceOrder = assignment.record.moverBodySourceOrder,
			prospectiveState = assignment.nextState,
			nextEntityTrajectoryBase = assignment.nextEntityTrajectoryBase,
			nextEntityTrajectoryDelta = assignment.nextEntityTrajectoryDelta,
			callbackEntityAngularTrajectoryBase = assignment.baseEntityAngularTrajectoryBase,
		}
		table.freeze(descriptor)
		table.insert(assignmentDescriptors, descriptor)
	end
	table.freeze(assignmentDescriptors)
	local lethalDescriptors: { any } = {}
	for index, dependencyValue in lethalDependencies do
		local dependency = dependencyValue :: any
		local sourceCapability = capability.boundLethalMoverDeathSources[index]
		if
			not sourceCapability
			or dependency.source ~= sourceCapability.source
			or dependency.sourceSummary ~= sourceCapability.summary
			or dependency.stageReceipt ~= sourceCapability.stageReceipt
			or dependency.player ~= sourceCapability.summary.victim
			or dependency.body ~= sourceCapability.body
			or sourceCapability.status ~= "BoundLethal"
			or sourceCapability.appliedNormalToDeadReceipt ~= nil
			or select(
					1,
					normalToDeadOwner.currentMoverDeathSource(
						sourceCapability.source,
						sourceCapability.summary
					)
				)
				~= sourceCapability
		then
			return false, "stale-mover-normal-to-dead-lethal-source"
		end
		local descriptor = {
			player = dependency.player,
			source = sourceCapability.source,
			body = sourceCapability.body,
			operationIndex = dependency.operationIndex,
			callbackTraversalOrder = sourceCapability.summary.callbackTraversalOrder,
			callbackEntityTrajectoryBase = sourceCapability.summary.victimBody.position,
			moverEntityTrajectoryBase = sourceCapability.summary.entityTrajectoryBase,
		}
		table.freeze(descriptor)
		table.insert(lethalDescriptors, descriptor)
	end
	table.freeze(lethalDescriptors)
	local plan, planError =
		normalToDeadOwner.bindingRules.Plan(lethalDescriptors, assignmentDescriptors)
	if not plan then
		return false, planError or "mover-normal-to-dead-binding-plan-failed"
	end
	if plan.operationCount == 0 then
		if plan ~= normalToDeadOwner.bindingRules.EmptyPlan then
			return false, "mover-normal-to-dead-empty-plan-diverged"
		end
		return true, nil
	end
	if
		plan.operationCount ~= #capability.boundLethalMoverDeathSources
		or plan.operationCount > normalToDeadOwner.maximumBatchSize
		or normalToDeadPreparedRegistry:GetActiveBatch() ~= nil
	then
		return false, "mover-normal-to-dead-plan-not-bindable"
	end
	local memberCapabilities: { PreparedNormalToDeadCapability } = {}
	local seenRecords: { [PlayerRecord]: boolean } = {}
	for index, planEntry in plan.entries do
		local sourceCapability = capability.boundLethalMoverDeathSources[index]
		local assignment = planEntry.assignment :: MoverPlayerStateAssignment
		local record = sourceCapability and sourceCapability.record
		if
			not sourceCapability
			or not record
			or planEntry.player ~= sourceCapability.summary.victim
			or planEntry.source ~= sourceCapability.source
			or planEntry.body ~= sourceCapability.body
			or planEntry.operationIndex ~= (lethalDependencies[index] :: any).operationIndex
			or planEntry.callbackTraversalOrder ~= sourceCapability.summary.callbackTraversalOrder
			or planEntry.callbackEntityTrajectoryBase ~= sourceCapability.summary.victimBody.position
			or planEntry.moverEntityTrajectoryBase ~= sourceCapability.summary.entityTrajectoryBase
			or assignment.player ~= sourceCapability.summary.victim
			or assignment.record ~= record
			or planEntry.prospectiveState ~= assignment.nextState
			or planEntry.nextEntityTrajectoryBase ~= assignment.nextEntityTrajectoryBase
			or planEntry.nextEntityTrajectoryDelta ~= assignment.nextEntityTrajectoryDelta
			or planEntry.callbackEntityAngularTrajectoryBase ~= assignment.baseEntityAngularTrajectoryBase
			or normalToDeadPreparedRegistry:GetActiveForRecord(record) ~= nil
			or seenRecords[record]
		then
			return false, "crossed-mover-normal-to-dead-binding-plan"
		end
		seenRecords[record] = true
		local member, memberError =
			normalToDeadOwner.buildMoverNormalToDeadMember(capability, assignment, sourceCapability)
		if not member then
			return false, memberError or "mover-normal-to-dead-member-build-failed"
		end
		table.insert(memberCapabilities, member)
	end
	local bundle, bundleError =
		normalToDeadOwner.buildMoverNormalToDeadBundle(capability, memberCapabilities)
	if not bundle then
		return false, bundleError or "mover-normal-to-dead-batch-build-failed"
	end
	local batchCapability = bundle.batchCapability
	local dependency = bundle.dependency
	for _, member in bundle.memberCapabilities do
		normalToDeadAuthorityRuntime.RetireAppliedReceipt(member.record)
	end
	capability.applyValidated = false
	-- Everything above is built and frozen before these adoption assignments.
	-- No rejection path exists after the first proof is published.
	for _, member in bundle.memberCapabilities do
		normalToDeadPreparedRegistry:SetPreparedCapability(member.prepared, member)
		normalToDeadPreparedRegistry:SetPreparedForSummary(member.summary, member.prepared)
		normalToDeadPreparedRegistry:SetReceiptCapability(member.receipt, member.receiptCapability)
		normalToDeadPreparedRegistry:SetActiveForRecord(member.record, member.prepared)
	end
	normalToDeadPreparedRegistry:SetBatchCapability(batchCapability.prepared, batchCapability)
	normalToDeadPreparedRegistry:SetBatchForSummary(
		batchCapability.summary,
		batchCapability.prepared
	)
	normalToDeadPreparedRegistry:SetBatchReceiptCapability(
		batchCapability.receipt,
		batchCapability.receiptCapability
	)
	normalToDeadPreparedRegistry:SetMoverStepForBatch(
		batchCapability.prepared,
		capability.preparedHandle
	)
	normalToDeadPreparedRegistry:SetActiveBatch(batchCapability.prepared)
	capability.boundNormalToDeadBatch = batchCapability.prepared
	capability.boundNormalToDeadBatchSummary = batchCapability.summary
	capability.boundNormalToDeadBatchReceipt = batchCapability.receipt
	capability.boundNormalToDeadMemberReceipts = batchCapability.receipts
	capability.boundNormalToDeadDependency = dependency
	capability.lethalNormalToDeadRecords = bundle.lethalRecords
	capability.lethalNormalToDeadAssignments = bundle.lethalAssignments
	capability.normalToDeadApplyEntries = bundle.applyEntries
	return true, nil
end

function MovementService.InspectPreparedMoverNormalToDeadBatchDependency(
	preparedValue: unknown
): PreparedMoverNormalToDeadBatchDependency?
	local capability = select(1, getPreparedMoverStepCapability(preparedValue))
	if
		not capability
		or capability.status ~= "Prepared"
		or capability.boundNormalToDeadDependency == nil
		or preparedMoverStepCurrentError(preparedValue, capability) ~= nil
	then
		return nil
	end
	return capability.boundNormalToDeadDependency
end

function MovementService.ValidatePreparedMoverNormalToDeadBatchDependency(
	preparedValue: unknown,
	dependencyValue: unknown
): (boolean, string?)
	if type(dependencyValue) ~= "table" then
		return false, "invalid-prepared-mover-normal-to-dead-dependency"
	end
	local capability, capabilityError = getPreparedMoverStepCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	local dependency = capability.boundNormalToDeadDependency
	local batch = capability.boundNormalToDeadBatch
	if
		not dependency
		or not batch
		or dependency ~= dependencyValue
		or dependency.batch ~= batch
		or normalToDeadPreparedRegistry:GetMoverStepForBatch(batch) ~= preparedValue
	then
		return false, "forged-prepared-mover-normal-to-dead-dependency"
	end
	local currentError = preparedMoverStepCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function MovementService.CanApplyPreparedMoverStep(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedMoverStepCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedMoverStepCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- Every constructor, freeze, canonicalizer, adapter call, and presentation
-- lookup ran in PrepareMoverStep. After the repeated currentness check, this
-- owner boundary performs only precomputed table/global assignments.
local function applyPreparedMoverStepAuthority(
	preparedValue: unknown,
	capability: PreparedMoverStepCapability
): MoverStepReceipt
	local normalBatch = capability.boundNormalToDeadBatch
	local normalBatchCapability = if normalBatch
		then assert(
			normalToDeadPreparedRegistry:GetBatchCapability(normalBatch) :: any,
			"prepared mover Normal-to-Dead batch disappeared after preflight"
		)
		else nil
	local normalApplyEntries = capability.normalToDeadApplyEntries
	local moverDeathSession = capability.moverDeathSession
	-- Retire unrelated direct-death proofs before the first mover/player root
	-- assignment. Lethal records are owned by the adopted private batch and must
	-- never pass through ordinary invalidation.
	for _, assignment in capability.stateAssignments do
		if capability.lethalNormalToDeadRecords[assignment.record] ~= true then
			normalToDeadAuthorityRuntime.Invalidate(assignment.record)
		end
	end

	-- No checks, constructors, callbacks, provider calls, or fallible returns
	-- occur after this first assignment. Every remaining value and exact order
	-- was frozen by Prepare/Bind and revalidated by both preflight passes.
	for _, assignment in capability.stateAssignments do
		if capability.lethalNormalToDeadRecords[assignment.record] ~= true then
			assignment.record.state = assignment.nextState
			assignment.record.entityTrajectoryBase = assignment.nextEntityTrajectoryBase
			assignment.record.entityTrajectoryDelta = assignment.nextEntityTrajectoryDelta
			assignment.record.entityAngularTrajectoryBase =
				assignment.nextEntityAngularTrajectoryBase
			assignment.record.playerStateViewAngles = assignment.nextPlayerStateViewAngles
		end
	end
	if normalBatchCapability then
		for _, applyEntry in normalApplyEntries do
			local member = applyEntry.member
			local record = member.record
			local sourceCapability = applyEntry.sourceCapability
			record.state = member.nextState
			record.entityTrajectoryBase = member.nextEntityTrajectoryBase
			record.entityTrajectoryDelta = member.nextEntityTrajectoryDelta
			record.entityAngularTrajectoryBase = member.nextEntityAngularTrajectoryBase
			record.entityGenericAngles = member.deathTransition.deathGenericAngles
			record.playerStateViewAngles = member.deathTransition.playerStateViewAngles
			record.deadState = member.deadState
			record.deathTransition = member.deathTransition
			record.firstDeadStepPhase = member.firstDeadStepPhase
			record.spawnReserved = false
			member.status = "Applied"
			member.applyValidated = false
			member.batchOwner = nil
			member.receiptCapability.status = "Applied"
			sourceCapability.appliedNormalToDeadReceipt = member.receipt
			normalToDeadPreparedRegistry:SetActiveForRecord(record, nil)
			normalToDeadPreparedRegistry:SetPreparedForSummary(member.summary, nil)
			normalToDeadPreparedRegistry:SetPreparedCapability(member.prepared, nil)
			normalToDeadPreparedRegistry:SetAppliedReceiptForRecord(record, member.receipt)
		end
		normalBatchCapability.status = "Applied"
		normalBatchCapability.applyValidated = false
		normalBatchCapability.receiptCapability.status = "Applied"
		normalToDeadPreparedRegistry:SetActiveBatch(nil)
		normalToDeadPreparedRegistry:SetBatchForSummary(normalBatchCapability.summary, nil)
		normalToDeadPreparedRegistry:SetBatchCapability(normalBatch, nil)
		normalToDeadPreparedRegistry:SetMoverStepForBatch(normalBatch, nil)
	end
	for _, assignment in capability.spawnReservationAssignments do
		if capability.lethalNormalToDeadRecords[assignment.record] ~= true then
			assignment.record.spawnReserved = false
		end
	end
	if moverDeathSession then
		for _, sourceCapability in moverDeathSession.sources do
			sourceCapability.status = "Retired"
			sourceCapability.stageReceipt = nil
		end
		moverDeathSession.status = "Retired"
		MovementMoverRuntime.SetDeathSourceSession(moverRuntime, nil)
	end
	moverRuntime.runtimeLegacyDefinitions = capability.nextLegacyDefinitions
	moverRuntime.binaryRuntime = capability.nextBinaryRuntime
	moverRuntime.definitions = capability.nextDefinitions
	moverRuntime.clock = capability.nextClock
	moverRuntime.collisionFrame = capability.nextCollisionFrame
	moverRuntime.snapshotWire = capability.nextSnapshotWire
	moverRuntime.pendingBinaryUses = capability.nextPendingBinaryMoverUses
	moverRuntime.crushTransitionCount = capability.nextDebug.moverCrushTransitionCount
	moverRuntime.crushRemovedCount = capability.nextDebug.moverCrushRemovedCount
	moverRuntime.crushRetainedCount = capability.nextDebug.moverCrushRetainedCount
	moverRuntime.lastCrushMoverId = capability.nextDebug.lastCrushMoverId
	moverRuntime.lastCrushBodyId = capability.nextDebug.lastCrushBodyId
	moverRuntime.lastCrushClockStep = capability.nextDebug.lastCrushClockStep
	moverRuntime.binaryUseTransitionCount = capability.nextDebug.binaryUseTransitionCount
	moverRuntime.lastBinaryUseMoverId = capability.nextDebug.lastBinaryUseMoverId
	moverRuntime.lastBinaryUseOutcome = capability.nextDebug.lastBinaryUseOutcome
	moverRuntime.lastBinaryUseTimeMilliseconds = capability.nextDebug.lastBinaryUseTimeMilliseconds
	moverRuntime.lastBinaryUseClockStep = capability.nextDebug.lastBinaryUseClockStep
	moverRuntime.binaryBlockedCallbackCount = capability.nextDebug.binaryBlockedCallbackCount
	moverRuntime.binaryBlockedDamageCount = capability.nextDebug.binaryBlockedDamageCount
	moverRuntime.binaryBlockedReversalCount = capability.nextDebug.binaryBlockedReversalCount
	moverRuntime.binaryBlockedRemovalCount = capability.nextDebug.binaryBlockedRemovalCount
	moverRuntime.lastBinaryBlockedMoverId = capability.nextDebug.lastBinaryBlockedMoverId
	moverRuntime.lastBinaryBlockedBodyId = capability.nextDebug.lastBinaryBlockedBodyId
	moverRuntime.lastBinaryBlockedTimeMilliseconds =
		capability.nextDebug.lastBinaryBlockedTimeMilliseconds
	moverAuthorityGeneration = capability.nextGeneration
	capability.status = "Applied"
	capability.applyValidated = false
	activePreparedMoverStep = nil
	preparedMoverStepCapabilities[preparedValue :: PreparedMoverStep] = nil
	return capability.receipt
end

function MovementService.ApplyPreparedMoverStep(preparedValue: unknown): MoverStepReceipt
	local capability, capabilityError = getPreparedMoverStepCapability(preparedValue)
	assert(capability, capabilityError or "invalid-prepared-mover-step")
	assert(capability.applyValidated, "prepared-mover-step-not-validated")
	local currentError = preparedMoverStepCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-prepared-mover-step")
	return applyPreparedMoverStepAuthority(preparedValue, capability)
end

function MovementService.GetPreparedMoverParticipantUpdate(preparedValue: unknown): unknown?
	local capability = select(1, getPreparedMoverStepCapability(preparedValue))
	return if capability and capability.status == "Prepared"
		then capability.participantPrepared
		else nil
end

function MovementService.GetPreparedMoverBodyQueueUpdate(preparedValue: unknown): unknown?
	local capability = select(1, getPreparedMoverStepCapability(preparedValue))
	return if capability and capability.status == "Prepared"
		then capability.bodyQueuePrepared
		else nil
end

function MovementService.AbortPreparedMoverStep(preparedValue: unknown): boolean
	local capability = select(1, getPreparedMoverStepCapability(preparedValue))
	if
		not capability
		or capability.status ~= "Prepared"
		or activePreparedMoverStep ~= preparedValue
	then
		return false
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	local normalBatch = capability.boundNormalToDeadBatch
	if normalBatch then
		local normalBatchCapability =
			normalToDeadPreparedRegistry:GetBatchCapability(normalBatch) :: any
		if normalBatchCapability then
			normalToDeadAuthorityRuntime.RetirePreparedBatch(normalBatchCapability)
		end
	end
	MovementMoverRuntime.RetireDeathSourceSession(moverRuntime, capability.moverDeathSession)
	activePreparedMoverStep = nil
	preparedMoverStepCapabilities[preparedValue :: PreparedMoverStep] = nil
	moverStepReceiptCapabilities[capability.receipt] = nil
	-- The damage token belongs to the adapter owner. A coordinator or the
	-- compatibility wrapper must abort it separately.
	return true
end

-- Presentation is deliberately outside authority. Each operation is isolated
-- so a destroyed visual cannot roll back or misreport the already-applied mover
-- frame, and the receipt is consumed exactly once before any Instance call.
function MovementService.PublishMoverStep(receiptValue: unknown)
	assert(type(receiptValue) == "table", "invalid-mover-step-receipt")
	local capability = moverStepReceiptCapabilities[receiptValue :: MoverStepReceipt]
	assert(capability, "invalid-mover-step-receipt")
	assert(
		capability.status == "Applied" and capability.receipt == receiptValue,
		"stale-mover-step-receipt"
	)
	capability.status = "Published"
	moverStepReceiptCapabilities[receiptValue :: MoverStepReceipt] = nil
	for _, operation in capability.presentationOperations do
		local published = pcall(MovementMoverPresentationRuntime.Apply, operation)
		if not published then
			warn("MovementService isolated a mover presentation publication failure")
		end
	end
end

-- Movement owns the outer frame and Combat encapsulates its nested
-- Match/Corpse participants. Every participant prepares first, the exact
-- Combat lethal summary is bound into Movement, every fallible preflight runs,
-- and only then do the assignment-only owner applies execute without yielding.
local function runAuthoritativeMoverStep(
	stepServerTime: number
): (MoverStepReceipt, unknown?, unknown?, unknown?)
	local movementReceipt, combatReceipt, participantReceipt, bodyQueueReceipt =
		MovementMoverCompositeRuntime.Run(stepServerTime, {
			prepareMovement = MovementService.PrepareMoverStep,
			getDamageToken = MovementService.GetPreparedMoverDamageToken,
			getParticipantPrepared = MovementService.GetPreparedMoverParticipantUpdate,
			getBodyQueuePrepared = MovementService.GetPreparedMoverBodyQueueUpdate,
			bindCombatDependency = MovementService.BindPreparedMoverCombatDependency,
			canApplyMovement = MovementService.CanApplyPreparedMoverStep,
			applyMovement = MovementService.ApplyPreparedMoverStep,
			abortMovement = MovementService.AbortPreparedMoverStep,
			clearActiveDamageToken = function()
				moverRuntime.activeDamageToken = nil
			end,
			damageAdapter = moverDamageAdapter,
			participantAdapter = moverParticipantAdapter,
			bodyQueueAdapter = moverBodyQueueAdapter,
		})
	return movementReceipt :: MoverStepReceipt, combatReceipt, participantReceipt, bodyQueueReceipt
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

local function ensureUnreliableRemote(folder: Folder, name: string): UnreliableRemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(
			existing:IsA("UnreliableRemoteEvent"),
			string.format("%s must be an UnreliableRemoteEvent", name)
		)
		return existing
	end

	local remote = Instance.new("UnreliableRemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function collectSpawnPoints(worldFolder: Folder, fallbackOrigin: Vector3): { SpawnPoint }
	local markers: {
		{
			key: string,
			origin: Vector3,
			teamId: string?,
			facing: Vector3,
			spawnClass: string?,
		}
	} =
		{}
	for _, descendant in worldFolder:GetDescendants() do
		local origin = descendant:GetAttribute("Q3EngineSpawnOrigin")
		if typeof(origin) == "Vector3" then
			local teamValue = descendant:GetAttribute("Q3EngineSpawnTeam")
			local facingValue = descendant:GetAttribute("Q3EngineSpawnFacing")
			local horizontalFacing = if typeof(facingValue) == "Vector3"
				then Vector3.new(facingValue.X, 0, facingValue.Z)
				else Vector3.zero
			local facing = if isFinite(horizontalFacing.X)
					and isFinite(horizontalFacing.Z)
					and horizontalFacing.Magnitude > 1e-6
				then horizontalFacing.Unit
				else Vector3.new(0, 0, -1)
			local spawnClassValue = descendant:GetAttribute("Q3EngineSpawnClass")
			table.insert(markers, {
				key = descendant:GetFullName(),
				origin = origin,
				teamId = if teamValue == "Red" or teamValue == "Blue" then teamValue else nil,
				facing = facing,
				spawnClass = if type(spawnClassValue) == "string" then spawnClassValue else nil,
			})
		end
	end

	table.sort(markers, function(left, right)
		return left.key < right.key
	end)

	local points: { SpawnPoint } = {}
	for index, marker in markers do
		table.insert(points, {
			index = index,
			origin = marker.origin,
			teamId = marker.teamId,
			facing = marker.facing,
			spawnClass = marker.spawnClass,
		})
	end
	if #points == 0 then
		assert(RunService:IsStudio(), "the Roblox Luau port world has no valid ArenaSpawnOrigin markers")
		table.insert(points, {
			index = 1,
			origin = fallbackOrigin,
			teamId = nil,
			facing = Vector3.new(0, 0, -1),
			spawnClass = nil,
		})
	end
	return points
end

local function collectCanonicalPlayerBodies(player: Player): { SweptAABB.Body }
	local bodies: { SweptAABB.Body } = {}
	for otherPlayer, otherRecord in records do
		local otherState = otherRecord.state
		if
			otherPlayer ~= player
			and otherPlayer:GetAttribute("Q3EngineAlive") == true
			and otherState
		then
			table.insert(bodies, {
				userId = otherPlayer.UserId,
				origin = otherState.position,
				size = Constants.ColliderSizeFor(otherState.crouched),
				centerOffset = Constants.ColliderCenterOffsetFor(otherState.crouched),
				active = true,
			})
		end
	end
	return bodies
end

local function makeTrace(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain,
	player: Player,
	worldOccupants: WorldOccupancyQuery.QueryFunction
): Movement.TraceFunction
	local staticSolidModel = PersistentStaticSolidDomain.RequireCurrent(staticSolidDomain)
	local worldParameters = RaycastParams.new()
	worldParameters.FilterType = Enum.RaycastFilterType.Include
	worldParameters.FilterDescendantsInstances = { staticSolidModel }
	worldParameters.IgnoreWater = true
	worldParameters.RespectCanCollide = true
	-- Blockcast does not report initial overlap. Use the shared exact-geometry
	-- adapter for the trace_t startsolid/allsolid inputs consumed by pmove.
	local function sharesOccupant(
		first: { WorldOccupancyQuery.Occupant },
		second: { WorldOccupancyQuery.Occupant }
	): boolean
		local firstSet: { [WorldOccupancyQuery.Occupant]: boolean } = {}
		for _, part in first do
			firstSet[part] = true
		end
		for _, part in second do
			if firstSet[part] then
				return true
			end
		end
		return false
	end

	return function(origin: Vector3, displacement: Vector3, crouched: boolean): Movement.TraceResult
		assert(
			PersistentStaticSolidDomain.IsCurrent(staticSolidDomain)
				and PlayerClipDomain.IsCurrent(playerClipDomain),
			"authoritative player-solid domains were invalidated"
		)
		local distance = displacement.Magnitude
		local castFrame = CFrame.new(origin + Constants.ColliderCenterOffsetFor(crouched))
		-- cm_trace.c expands brush planes by the exact mins/maxs. Do not reuse the
		-- zero-length overlap skin here: it can hide a contact for longer than
		-- PM_GroundTrace's complete probe and admit the full hull into corners.
		local castSize = Constants.ColliderSizeFor(crouched)
			- Vector3.one * Constants.StaticWorldSweepInset * 2
		local worldResult = if distance > 1e-6
			then Workspace:Blockcast(castFrame, castSize, displacement, worldParameters)
			else nil
		local playerClipResult, playerClipError = PlayerClipDomain.Trace(
			playerClipDomain,
			origin,
			displacement,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched)
		)
		assert(playerClipResult, playerClipError or "authoritative playerclip trace failed")
		local startWorldOccupants = worldOccupants(origin, crouched)
		local endWorldOccupants = if #startWorldOccupants > 0
			then worldOccupants(origin + displacement, crouched)
			else {}
		local worldAllSolid = sharesOccupant(startWorldOccupants, endWorldOccupants)
		local bodies = collectCanonicalPlayerBodies(player)
		local bodyResult = SweptAABB.TraceBodies(
			origin,
			displacement,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched),
			bodies
		)
		local startSolid = #startWorldOccupants > 0 or bodyResult.startSolid
		local bodyDistance = distance * bodyResult.fraction
		if worldAllSolid or bodyResult.allSolid or playerClipResult.allSolid then
			return {
				hit = true,
				fraction = 0,
				position = origin,
				normal = if bodyResult.allSolid
					then bodyResult.normal
					elseif playerClipResult.allSolid then playerClipResult.normal
					else Vector3.yAxis,
				startSolid = true,
				allSolid = true,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
		end
		if distance <= 1e-6 then
			return {
				hit = false,
				fraction = 1,
				position = origin,
				normal = Vector3.yAxis,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
		end
		local bodyClip = if bodyResult.hit
			then assert(TraceClipRules.Resolve(bodyDistance, displacement, bodyResult.normal, 0))
			else nil
		local worldClip = if worldResult
			then assert(
				TraceClipRules.Resolve(
					worldResult.Distance,
					displacement,
					worldResult.Normal,
					Constants.StaticWorldSweepInset
				)
			)
			else nil
		local playerClip = if playerClipResult.hit
			then assert(
				TraceClipRules.Resolve(
					distance * playerClipResult.fraction,
					displacement,
					playerClipResult.normal,
					Constants.StaticWorldSweepInset
				)
			)
			else nil
		if
			bodyClip
			and (not worldClip or bodyClip.travelDistance < worldClip.travelDistance)
			and (not playerClip or bodyClip.travelDistance < playerClip.travelDistance)
		then
			local travel = bodyClip.travelDistance
			return {
				hit = true,
				fraction = travel / distance,
				position = origin + displacement.Unit * travel,
				normal = bodyResult.normal,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
		end
		if
			playerClip
			and (not worldClip or playerClip.travelDistance < worldClip.travelDistance)
		then
			local travel = playerClip.travelDistance
			return {
				hit = true,
				fraction = travel / distance,
				position = origin + displacement.Unit * travel,
				normal = playerClipResult.normal,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
		end

		if not worldResult then
			return {
				hit = false,
				fraction = 1,
				position = origin + displacement,
				normal = Vector3.yAxis,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
		end

		local travel = assert(worldClip).travelDistance
		local fraction = travel / distance
		local surfaceSlick, surfaceNoDamage = SurfaceContact.Read(worldResult.Instance)

		return {
			hit = true,
			fraction = fraction,
			position = origin + displacement.Unit * travel,
			normal = worldResult.Normal,
			startSolid = startSolid,
			allSolid = false,
			surfaceSlick = surfaceSlick,
			surfaceNoDamage = surfaceNoDamage,
		}
	end
end

local function makeCanOccupy(
	player: Player,
	worldOccupants: WorldOccupancyQuery.QueryFunction
): Movement.CanOccupyFunction
	return function(origin: Vector3, crouched: boolean): boolean
		if #worldOccupants(origin, crouched) > 0 then
			return false
		end

		-- bg_pmove.c PM_CheckDuck performs a zero-length standing-hull trace and
		-- checks allsolid. Use the same canonical AABBs as movement sweeps; avatar
		-- limbs and late-loading accessories never decide stand clearance.
		local bodyResult = SweptAABB.TraceBodies(
			origin,
			Vector3.zero,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched),
			collectCanonicalPlayerBodies(player)
		)
		return not bodyResult.allSolid
	end
end

local function configureCharacterBasePart(character: Model, part: BasePart)
	local isCanonicalHitbox = part.Parent == character
		and part.Name == CANONICAL_HITBOX_NAME
		and part:GetAttribute(CANONICAL_HITBOX_ATTRIBUTE) == true
	if isCanonicalHitbox then
		return
	end

	-- Avatar appearance can finish after CharacterAdded. Keep every body/accessory/tool
	-- part out of combat queries so only the fixed ArenaHitbox can receive weapon traces.
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
end

local function prepareCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart

	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.UseJumpPower = true
	HumanoidMovementStatePolicy.Apply(humanoid)

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			configureCharacterBasePart(character, descendant)
		end
	end

	local oldHitbox = character:FindFirstChild(CANONICAL_HITBOX_NAME)
	if oldHitbox then
		oldHitbox:Destroy()
	end

	local hitbox = Instance.new("Part")
	hitbox.Name = CANONICAL_HITBOX_NAME
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = character:GetAttribute("Q3EngineCombatQueryEnabled") == true
	hitbox.CastShadow = false
	hitbox.Massless = true
	hitbox.Size = Constants.StandingColliderSize
	hitbox.Transparency = 1
	hitbox.CFrame = root.CFrame
		* CFrame.new(Constants.StandingColliderCenterOffset - Constants.VisualRootOffset)
	hitbox:SetAttribute(CANONICAL_HITBOX_ATTRIBUTE, true)
	hitbox.Parent = character
	assert(
		hitbox.CanQuery == (character:GetAttribute("Q3EngineCombatQueryEnabled") == true)
			and not hitbox.CanCollide
			and not hitbox.CanTouch,
		"Q3EngineHitbox query state must follow the server combat gate"
	)

	character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			configureCharacterBasePart(character, descendant)
		end
	end)

	root.Anchored = true
end

local function renderCharacter(player: Player, record: PlayerRecord)
	if simulationFaulted then
		return
	end
	if fixedStepTransactionOpen then
		deferredRenderPlayers[player] = true
		return
	end
	local character = record.character
	local state = record.state
	if not character or not state or not character.Parent then
		return
	end

	local look = Vector3.new(state.look.X, 0, state.look.Z)
	if look.Magnitude < 1e-6 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end

	local visualPosition = state.position + Constants.VisualRootOffset
	character:PivotTo(CFrame.lookAt(visualPosition, visualPosition + look))
	local hitbox = character:FindFirstChild(CANONICAL_HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		local center = state.position + Constants.ColliderCenterOffsetFor(state.crouched)
		hitbox.Size = Constants.ColliderSizeFor(state.crouched)
		hitbox.CFrame = CFrame.lookAt(center, center + look)
	end
	if player:GetAttribute("Q3EngineCrouched") ~= state.crouched then
		player:SetAttribute("Q3EngineCrouched", state.crouched)
	end
	local resolvedCommand = Movement.ResolveCommand(state, record.command)
	local walking = resolvedCommand ~= nil and resolvedCommand.walking
	if player:GetAttribute("Q3EngineWalking") ~= walking then
		player:SetAttribute("Q3EngineWalking", walking)
	end
	if player:GetAttribute("Q3EngineWaterLevel") ~= state.waterLevel then
		player:SetAttribute("Q3EngineWaterLevel", state.waterLevel)
	end
	if player:GetAttribute("Q3EngineWaterType") ~= state.waterType then
		player:SetAttribute("Q3EngineWaterType", state.waterType)
	end
	if player:GetAttribute("Q3EngineWaterJump") ~= state.timeWaterJump then
		player:SetAttribute("Q3EngineWaterJump", state.timeWaterJump)
	end
end

local function sendSnapshot(player: Player, record: PlayerRecord)
	if simulationFaulted then
		return
	end
	if fixedStepTransactionOpen then
		deferredSnapshotPlayers[player] = true
		return
	end
	local remote = movementSnapshotRemote
	local state = record.state
	local moverSnapshot = moverRuntime.snapshotWire
	if not remote or not state or not moverSnapshot then
		return
	end
	assert(
		state.groundMoverId == nil or Movement.ValidateMoverId(state.groundMoverId) ~= nil,
		"refusing to publish an invalid ground mover identity"
	)
	assert(
		state.groundMoverId == nil or state.grounded,
		"refusing to publish an airborne ground mover identity"
	)
	local deathTransition = record.deathTransition
	local phase = if record.deadState
		then assert(
			MovementPhaseRules.Validate(
				MovementPhaseRules.PmoveType.Dead,
				Constants.DeadViewHeight,
				state.crouched,
				assert(record.lifeSequence, "dead snapshot lost its life sequence"),
				assert(deathTransition, "dead snapshot lost its transition").deadYawDegrees
			)
		)
		else assert(
			MovementPhaseRules.Validate(
				MovementPhaseRules.PmoveType.Normal,
				Constants.ViewHeightFor(state.crouched),
				state.crouched,
				nil,
				nil
			)
		)

	record.snapshotSequence += 1
	remote:FireClient(player, {
		snapshotSequence = record.snapshotSequence,
		pmType = phase.pmType,
		viewHeight = phase.viewHeight,
		frame = state.frame,
		revision = record.revision,
		ackSequence = record.lastProcessedSequence,
		character = record.character,
		position = state.position,
		velocity = state.velocity,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = state.grounded,
		groundPlane = state.groundPlane,
		groundNormal = state.groundNormal,
		groundSlick = state.groundSlick,
		groundNoDamage = state.groundNoDamage,
		groundMoverId = state.groundMoverId,
		moverSnapshot = moverSnapshot,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
		jumpHeld = state.jumpHeld,
		crouched = state.crouched,
		movementTime = state.movementTime,
		timeLand = state.timeLand,
		timeKnockback = state.timeKnockback,
		timeWaterJump = state.timeWaterJump,
		respawned = state.respawned,
		teleportLook = record.pendingTeleportLook,
		teleportTriggerId = record.pendingTeleportTriggerId,
		spawnLook = record.pendingSpawnLook,
		weaponId = record.command.weaponId,
	})
	record.pendingTeleportLook = nil
	record.pendingTeleportTriggerId = nil
	-- A respawn snapshot can reach the client before Player.Character has replicated.
	-- decodeSnapshot deliberately rejects that snapshot, so keep the authored heading
	-- on every snapshot for this revision until the client proves it accepted one by
	-- returning a valid command carrying the new revision.
end

local function chooseSpawn(
	player: Player,
	record: PlayerRecord,
	requestedIndex: number?,
	selectionRoll: number?,
	countRespawn: boolean?
): SpawnChoice?
	local occupants = {}
	for otherPlayer, otherRecord in records do
		local otherState = otherRecord.state
		local otherCharacter = otherRecord.character
		if otherPlayer ~= player and otherState and otherCharacter and otherCharacter.Parent then
			table.insert(occupants, {
				userId = otherPlayer.UserId,
				origin = otherState.position,
				size = Constants.ColliderSizeFor(otherState.crouched),
				centerOffset = Constants.ColliderCenterOffsetFor(otherState.crouched),
				-- SpotWouldTelefrag checks every linked non-spectator client; the
				-- upstream health test is intentionally commented out. Dead bodies
				-- block ordinary selection even though only live bodies are movement
				-- solids. KillBox is the all-occupied fallback.
				active = otherRecord.spawnReserved
					or otherPlayer:GetAttribute("Q3EngineMatchParticipation") == "Active",
			})
		end
	end

	local eligibleSpawnPoints: { SpawnPoint } = {}
	local queryWorld = spawnWorldOccupants
	for _, spawnPoint in spawnPoints do
		if not queryWorld or #queryWorld(spawnPoint.origin, false) == 0 then
			table.insert(eligibleSpawnPoints, spawnPoint)
		end
	end
	if #eligibleSpawnPoints == 0 then
		return nil
	end

	local modeId = sharedRoot:GetAttribute("Q3EngineMatchMode")
	-- Q3 ClientSpawn uses team-class spawn filtering only for GT_CTF and above;
	-- TDM, Duel, and ordinary deathmatch share the deathmatch pool. Our
	-- team-round Arena adaptation also opts into its authored team markers.
	local teamSpawnPolicy = modeId == "CaptureTheFlag" or modeId == "ArenaElimination"
	local roll = selectionRoll or spawnRandom:NextInteger(0, 2_147_483_647)
	local rocketArenaPartition = modeId == "ArenaElimination" and rocketArenaSpawnPartition
	local choice
	if rocketArenaPartition then
		local matchId = sharedRoot:GetAttribute("Q3EngineMatchId")
		local matchRound = sharedRoot:GetAttribute("Q3EngineMatchRound")
		local nearTeam = if type(matchId) == "string" and type(matchRound) == "number"
			then RocketArenaSpawnRules.ResolveNearTeam(matchId, matchRound)
			else nil
		local playerTeam = player:GetAttribute("Q3EngineMatchTeam")
		if nearTeam == nil or (playerTeam ~= "Red" and playerTeam ~= "Blue") then
			return nil
		end
		choice = SpawnSelection.SelectRocketArena(
			eligibleSpawnPoints,
			occupants,
			Constants.StandingColliderSize,
			Constants.StandingColliderCenterOffset,
			playerTeam == nearTeam,
			roll,
			requestedIndex
		)
	else
		choice = SpawnSelection.Select(
			eligibleSpawnPoints,
			occupants,
			Constants.StandingColliderSize,
			Constants.StandingColliderCenterOffset,
			if teamSpawnPolicy then player:GetAttribute("Q3EngineMatchTeam") else nil,
			if record.state
				then record.state.position
				else record.lastAuthoritativeOrigin or Vector3.zero,
			roll,
			if teamSpawnPolicy then "Uniform" else "FarthestHalf",
			requestedIndex
		)
	end
	if choice then
		if countRespawn ~= false then
			record.respawnCount += 1
		end
		for _, spawnPoint in eligibleSpawnPoints do
			if spawnPoint.index == choice.spawnIndex then
				return {
					spawnIndex = choice.spawnIndex,
					origin = choice.origin,
					facing = spawnPoint.facing,
					telefragUserIds = choice.telefragUserIds,
					usedTelefragFallback = choice.usedTelefragFallback,
				}
			end
		end
	end
	return nil
end

local function applyTelefrags(
	attacker: Player,
	userIds: { number },
	lifeBinding: MovementLifeBinding?
): boolean
	if #userIds == 0 then
		return true
	end

	local victims: { Player } = {}
	for _, userId in userIds do
		for otherPlayer in records do
			if otherPlayer.UserId == userId then
				table.insert(victims, otherPlayer)
				break
			end
		end
	end
	local handler = spawnTelefragHandler
	return handler ~= nil and #victims == #userIds and handler(attacker, victims, lifeBinding)
end

local function resetMovement(
	player: Player,
	record: PlayerRecord,
	requestedSpawnIndex: number?
): boolean
	if not record.character or not record.character.Parent then
		return false
	end

	local choice = chooseSpawn(player, record, requestedSpawnIndex)
	if not choice then
		return false
	end
	local deferSpawnTelefrags = record.lifeBinding == nil
	if not deferSpawnTelefrags and not applyTelefrags(player, choice.telefragUserIds, nil) then
		return false
	end

	invalidateMovementLifeBinding(record)
	studioWaterJumpObservations[player] = nil
	local previousCommand = record.command
	local spawnCommand: Movement.Command = {
		forward = 0,
		right = 0,
		upMove = 0,
		-- SetClientViewAngle computes delta_angles against pers.cmd.angles rather
		-- than replacing the raw command. Preserve those last received bits here.
		pitch = previousCommand.pitch,
		yaw = previousCommand.yaw,
		roll = previousCommand.roll,
		-- ClientSpawn must retain PMF_RESPAWNED until an actual new-revision
		-- command proves BUTTON_ATTACK is released.
		buttons = CommandQuantization.ButtonAttack,
		weaponId = WeaponDefinitions.InitialWeaponId,
	}
	local spawnState = assert(
		Movement.SetViewAngle(Movement.newSpawnState(choice.origin), spawnCommand, choice.facing),
		"authored spawn facing must produce a valid Q3 view angle"
	)
	local spawnEntityAngles = assert(
		EntityStateConversionRules.AnglesForLook(choice.facing),
		"authored spawn facing did not produce generic entity angles"
	)
	record.state = spawnState
	record.entityGenericAngles = spawnEntityAngles
	record.playerStateViewAngles = playerStateViewAnglesFromState(spawnState)
	record.deadState = nil
	record.deathTransition = nil
	record.firstDeadStepPhase = nil
	-- ClientSpawn runs its synthetic ClientThink before the explicit BG
	-- projection at the bottom of g_client.c. The generic SetClientViewAngle
	-- source remains authored, while s.apos samples the packed Pmove view.
	applyEntityStateProjection(record, spawnState, nil)
	record.spawnReserved = true
	record.pendingSpawnTelefragUserIds = if deferSpawnTelefrags
		then table.freeze(table.clone(choice.telefragUserIds))
		else nil
	record.spawnIndex = choice.spawnIndex
	record.command = spawnCommand
	record.awaitingViewCommand = true
	record.commandQueue = {}
	record.commandQueueHead = 1
	-- Discarded pre-respawn inputs are acknowledged so they cannot be replayed into the new life.
	record.lastProcessedSequence = record.lastReceivedSequence
	record.revision += 1
	record.jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState()
	record.pendingTeleportLook = nil
	record.pendingTeleportTriggerId = nil
	record.pendingSpawnLook = choice.facing
	renderCharacter(player, record)
	sendSnapshot(player, record)
	return true
end

local function handleWorldExit(player: Player, record: PlayerRecord, state: Movement.State): boolean
	local configuredLimits = worldLimits :: MapSpatialRules.WorldLimits
	local classification, entityId =
		MapSpatialRules.ClassifyPlayerOrigin(state.position, state.crouched, configuredLimits)
	if classification == MapSpatialRules.Classifications.Playable then
		return false
	end

	local handled = outOfBoundsHandler and outOfBoundsHandler(player, classification, entityId)
	if not handled then
		resetMovement(player, record, nil)
	end
	return true
end

local function pendingCommandCount(record: PlayerRecord): number
	return math.max(#record.commandQueue - record.commandQueueHead + 1, 0)
end

local function observeCommandBacklog(player: Player, record: PlayerRecord)
	local backlog = pendingCommandCount(record)
	telemetryRuntime:ObserveCommandBacklog(player.UserId, backlog)
end

local function dequeueCommand(record: PlayerRecord): QueuedCommand?
	local head = record.commandQueueHead
	local tail = #record.commandQueue
	if head > tail then
		return nil
	end

	-- Reliable input can arrive in bursts. SV_UserMove executes every accepted
	-- newer usercmd in order; do not collapse identical semantic levels because
	-- each authored command owns one canonical fixed-time Pmove step.
	local selectedIndex = CommandQueueRules.SelectIndex(record.commandQueue, head) :: number
	local queued = record.commandQueue[selectedIndex]
	if not queued then
		return nil
	end

	record.commandQueueHead = selectedIndex + 1
	if record.commandQueueHead > 64 and record.commandQueueHead > #record.commandQueue / 2 then
		local compacted: { QueuedCommand } = {}
		for index = record.commandQueueHead, #record.commandQueue do
			table.insert(compacted, record.commandQueue[index])
		end
		record.commandQueue = compacted
		record.commandQueueHead = 1
	end
	return queued
end

type TriggerOutcome = {
	touched: boolean,
	snapshotRequested: boolean,
}

local teleportRuntime = MovementTeleportRuntime.new({
	records = records,
	applyTelefrags = applyTelefrags,
	invalidateAuthority = normalToDeadAuthorityRuntime.Invalidate,
	applyProjection = applyEntityStateProjection,
})

local function applyWorldTriggers(player: Player, record: PlayerRecord): TriggerOutcome
	local state = record.state
	if not state then
		return { touched = false, snapshotRequested = false }
	end

	local touching = WorldTriggerRules.FindTouching(
		triggerDefinitions,
		state.position,
		Constants.ColliderSizeFor(state.crouched),
		Constants.ColliderCenterOffsetFor(state.crouched)
	)
	local teleport = WorldTriggerRules.ResolveTeleporter(touching)
	if teleport then
		return {
			touched = true,
			snapshotRequested = teleportRuntime:ApplyAuthored(
				player,
				record,
				teleport.position,
				teleport.look,
				teleport.velocity,
				teleport.movementTime,
				teleport.triggerId
			),
		}
	end

	local jumpPad =
		WorldTriggerRules.ResolveJumpPad(touching, state.velocity, record.jumpPadEntryState)
	record.jumpPadEntryState = jumpPad.entryState
	if jumpPad.touchedTriggerId == nil then
		return { touched = false, snapshotRequested = false }
	end

	normalToDeadAuthorityRuntime.Invalidate(record)
	record.state = {
		frame = state.frame,
		position = state.position,
		-- BG_TouchJumpPad replaces all three components on every touched frame,
		-- including consecutive contact while already airborne.
		velocity = jumpPad.velocity,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = false,
		groundPlane = false,
		groundNormal = Vector3.yAxis,
		groundSlick = false,
		groundNoDamage = false,
		groundMoverId = nil,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
		jumpHeld = state.jumpHeld,
		crouched = state.crouched,
		movementTime = state.movementTime,
		timeLand = state.timeLand,
		timeKnockback = state.timeKnockback,
		timeWaterJump = state.timeWaterJump,
		respawned = state.respawned,
	}
	return { touched = true, snapshotRequested = jumpPad.emitEntryEvent }
end

function MovementService.GetState(player: Player): Movement.State?
	local record = records[player]
	return if record then record.state else nil
end

-- Server-only diagnostic for the cached entity projection and precise
-- playerState domains consumed by future death/CopyToBodyQue composition. This
-- exposes no mutation capability and returns only immutable/value data.
function MovementService.GetPlayerEntityTrajectoryDiagnostic(
	player: Player
): PlayerEntityTrajectoryDiagnostic?
	local record = records[player]
	local state = record and record.state
	if not record or not state then
		return nil
	end
	local diagnostic: PlayerEntityTrajectoryDiagnostic = {
		entityTrajectoryBase = record.entityTrajectoryBase,
		entityTrajectoryDelta = record.entityTrajectoryDelta,
		entityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		entityGenericAngles = record.entityGenericAngles,
		playerStateViewAngles = record.playerStateViewAngles,
		playerStatePosition = state.position,
		playerStateVelocity = state.velocity,
	}
	table.freeze(diagnostic)
	return diagnostic
end

-- clientNum is the first-class player order in the Q3 game VM. Downstream
-- consequence shadows consume this server-owned translation instead of Roblox
-- UserId ordering, which is presentation-only and not an engine entity order.
function MovementService.GetPlayerSourceOrder(player: Player): number?
	local record = records[player]
	if not record then
		return nil
	end
	local sourceOrder = EntitySlotService.GetPlayerSourceOrder(player)
	assert(
		sourceOrder == record.moverBodySourceOrder,
		"movement player source order diverged from the entity-slot owner"
	)
	return sourceOrder
end

function MovementService.GetPlayerBodyId(player: Player): string?
	local record = records[player]
	if not record then
		return nil
	end
	local bodyId = EntitySlotService.GetPlayerBodyId(player)
	assert(
		bodyId == record.moverBodyId,
		"movement player body identity diverged from the entity-slot owner"
	)
	return bodyId
end

function MovementService.GetPointContents(position: Vector3): number?
	local query = worldPointContentsQuery
	if
		not query
		or typeof(position) ~= "Vector3"
		or position.X ~= position.X
		or position.Y ~= position.Y
		or position.Z ~= position.Z
		or math.abs(position.X) == math.huge
		or math.abs(position.Y) == math.huge
		or math.abs(position.Z) == math.huge
	then
		return nil
	end
	local contents = query(position)
	local fixture = moverRuntime.studioNoDropPointFixture
	if fixture then
		local localPoint = fixture.cframe:PointToObjectSpace(position)
		local half = fixture.size * 0.5
		if
			math.abs(localPoint.X) <= half.X
			and math.abs(localPoint.Y) <= half.Y
			and math.abs(localPoint.Z) <= half.Z
		then
			contents = bit32.bor(contents, WorldPointContents.Contents.NoDrop)
		end
	end
	return contents
end

function MovementService.GetPlayerMoverBody(player: Player): MoverPushRules.Body?
	local record = records[player]
	if not record or player:GetAttribute("Q3EngineAlive") ~= true then
		return nil
	end
	local body = MovementMoverBodyRuntime.LivePlayerBody(record)
	if not body then
		return nil
	end
	assert(
		EntitySlotService.GetPlayerBodyId(player) == body.id
			and EntitySlotService.GetPlayerSourceOrder(player) == body.sourceOrder,
		"live movement body diverged from the entity-slot owner"
	)
	return body
end

function MovementService.TraceMoverPoint(
	origin: Vector3,
	displacement: Vector3,
	clipMask: number
): MoverCollisionFrame.TraceResult
	local result, traceError =
		MoverCollisionFrame.TracePoint(moverRuntime.collisionFrame, origin, displacement, clipMask)
	assert(result, traceError or "authoritative mover point trace failed")
	return result
end

function MovementService.GetCommand(player: Player): Movement.ResolvedCommand?
	local record = records[player]
	local state = record and record.state
	return if record and state then Movement.ResolveCommand(state, record.command) else nil
end

function MovementService.GetPackedCommand(player: Player): Movement.Command?
	local record = records[player]
	return if record then record.command else nil
end

function MovementService.GetRevision(player: Player): number?
	local record = records[player]
	return if record then record.revision else nil
end

function MovementService.GetStudioCommandDebug(player: Player): { [string]: number }?
	if not RunService:IsStudio() then
		return nil
	end
	local record = records[player]
	if record == nil then
		return nil
	end
	return {
		revision = record.revision,
		lastReceivedSequence = record.lastReceivedSequence,
		lastProcessedSequence = record.lastProcessedSequence,
		pendingCommandCount = pendingCommandCount(record),
		rateWindowCount = record.rateWindowCount,
	}
end

function MovementService.GetStudioWaterJumpObservation(player: Player): StudioWaterJumpObservation?
	if not RunService:IsStudio() then
		return nil
	end
	return studioWaterJumpObservations[player]
end

function MovementService.QueueBinaryMoverUse(moverIdValue: unknown): (boolean, string?)
	if simulationFaulted then
		return false, "SimulationFaulted"
	end
	if heartbeatConnection == nil then
		return false, "MovementNotStarted"
	end
	if type(moverIdValue) ~= "string" or Movement.ValidateMoverId(moverIdValue) == nil then
		return false, "InvalidMoverId"
	end
	local moverId = moverIdValue :: string
	if moverRuntime.binaryIds[moverId] ~= true then
		return false, "UnknownBinaryMover"
	end
	if #moverRuntime.pendingBinaryUses >= MAXIMUM_BINARY_USE_QUEUE then
		return false, "BinaryUseQueueFull"
	end
	table.insert(moverRuntime.pendingBinaryUses, moverId)
	return true, nil
end

function MovementService.QueueBinaryDoorTriggerUse(moverIdValue: unknown): (boolean, string?)
	if type(moverIdValue) ~= "string" or Movement.ValidateMoverId(moverIdValue) == nil then
		return false, "InvalidMoverId"
	end
	local moverId = moverIdValue :: string
	local currentRuntime = moverRuntime.binaryRuntime
	if not currentRuntime or moverRuntime.binaryIds[moverId] ~= true then
		return false, "UnknownBinaryMover"
	end
	for _, team in currentRuntime.teams do
		for _, member in team.members do
			if member.id == moverId then
				for _, queuedMoverId in moverRuntime.pendingBinaryUses do
					for _, teamMember in team.members do
						if teamMember.id == queuedMoverId then
							return false, "DoorAlreadyOpening"
						end
					end
				end
				if member.state == MoverTrajectory.BinaryStates.OneToTwo then
					return false, "DoorAlreadyOpening"
				end
			end
		end
	end
	return MovementService.QueueBinaryMoverUse(moverId)
end

function MovementService.GetMoverDebugState(): MoverDebugState
	local snapshot =
		assert(moverRuntime.snapshotWire, "mover debug state requires a published snapshot")
	return table.freeze({
		clockRevision = moverRuntime.clock.revision,
		clockStep = moverRuntime.clock.step,
		timeMilliseconds = moverRuntime.collisionFrame.timeMilliseconds,
		definitionCount = #moverRuntime.definitions,
		legacyDefinitionCount = #moverRuntime.runtimeLegacyDefinitions,
		binaryProgramCount = #moverRuntime.binaryPrograms,
		binaryPolicyCount = #moverRuntime.binaryPolicies,
		binaryRuntimeRevision = if moverRuntime.binaryRuntime
			then moverRuntime.binaryRuntime.revision
			else nil,
		snapshotSchemaVersion = snapshot.schemaVersion,
		poseCount = #moverRuntime.collisionFrame.poses,
		queuedBinaryUseCount = #moverRuntime.pendingBinaryUses,
		binaryUseTransitionCount = moverRuntime.binaryUseTransitionCount,
		lastBinaryUseMoverId = moverRuntime.lastBinaryUseMoverId,
		lastBinaryUseOutcome = moverRuntime.lastBinaryUseOutcome,
		lastBinaryUseTimeMilliseconds = moverRuntime.lastBinaryUseTimeMilliseconds,
		lastBinaryUseClockStep = moverRuntime.lastBinaryUseClockStep,
		binaryBlockedCallbackCount = moverRuntime.binaryBlockedCallbackCount,
		binaryBlockedDamageCount = moverRuntime.binaryBlockedDamageCount,
		binaryBlockedReversalCount = moverRuntime.binaryBlockedReversalCount,
		binaryBlockedRemovalCount = moverRuntime.binaryBlockedRemovalCount,
		lastBinaryBlockedMoverId = moverRuntime.lastBinaryBlockedMoverId,
		lastBinaryBlockedBodyId = moverRuntime.lastBinaryBlockedBodyId,
		lastBinaryBlockedTimeMilliseconds = moverRuntime.lastBinaryBlockedTimeMilliseconds,
		crushTransitionCount = moverRuntime.crushTransitionCount,
		crushRemovedCount = moverRuntime.crushRemovedCount,
		crushRetainedCount = moverRuntime.crushRetainedCount,
		lastCrushMoverId = moverRuntime.lastCrushMoverId,
		lastCrushBodyId = moverRuntime.lastCrushBodyId,
		lastCrushClockStep = moverRuntime.lastCrushClockStep,
	})
end

local function studioMoverFixtureEnabled(): boolean
	local world = Workspace:FindFirstChild("Q3EngineWorld")
	return RunService:IsStudio()
		and world ~= nil
		and world:GetAttribute("Q3EngineStudioMoverFixture") ~= nil
end

function MovementService.GetBinaryMoverState(moverId: string): BinaryMoverState?
	if Movement.ValidateMoverId(moverId) == nil or moverRuntime.binaryIds[moverId] ~= true then
		return nil
	end
	local runtime = moverRuntime.binaryRuntime
	if not runtime then
		return nil
	end
	local inspected =
		MoverBinaryState.InspectAuthoritativeRuntime(moverRuntime.binaryPrograms, runtime)
	if inspected ~= runtime then
		return nil
	end
	for _, team in runtime.teams do
		for _, member in team.members do
			if member.id == moverId then
				return table.freeze({
					moverId = moverId,
					state = member.state,
					effectiveStartTimeMilliseconds = member.effectiveStartTimeMilliseconds,
					nextThinkTimeMilliseconds = member.nextThinkTimeMilliseconds,
					runtimeRevision = runtime.revision,
					queuedUseCount = #moverRuntime.pendingBinaryUses,
					useTransitionCount = moverRuntime.binaryUseTransitionCount,
					lastUseMoverId = moverRuntime.lastBinaryUseMoverId,
					lastUseOutcome = moverRuntime.lastBinaryUseOutcome,
					lastUseTimeMilliseconds = moverRuntime.lastBinaryUseTimeMilliseconds,
					lastUseClockStep = moverRuntime.lastBinaryUseClockStep,
				})
			end
		end
	end
	return nil
end

function MovementService.GetStudioBinaryMoverState(moverId: string): StudioBinaryMoverState?
	if not studioMoverFixtureEnabled() then
		return nil
	end
	return MovementService.GetBinaryMoverState(moverId)
end

function MovementService.GetStudioMoverPose(moverId: string): Vector3?
	if not studioMoverFixtureEnabled() or Movement.ValidateMoverId(moverId) == nil then
		return nil
	end
	for _, pose in moverRuntime.collisionFrame.poses do
		if pose.id == moverId then
			return pose.position
		end
	end
	return nil
end

function MovementService.PlaceStudioPlayerOnMover(
	player: Player,
	moverId: string,
	placementValue: "Top" | "DoorField"?
): boolean
	if not studioMoverFixtureEnabled() then
		return false
	end
	local record = records[player]
	local state = record and record.state
	if not record or not state or player:GetAttribute("Q3EngineAlive") ~= true then
		return false
	end
	local selectedPose: MoverPushRules.Pose? = nil
	for _, pose in moverRuntime.collisionFrame.poses do
		if pose.id == moverId then
			selectedPose = pose
			break
		end
	end
	if not selectedPose then
		return false
	end

	local size = Constants.ColliderSizeFor(state.crouched)
	local centerOffset = Constants.ColliderCenterOffsetFor(state.crouched)
	local bottomGap = Constants.GroundProbeDistance * 0.5
	local placement = placementValue or "Top"
	if placement ~= "Top" and placement ~= "DoorField" then
		return false
	end
	local position = if placement == "DoorField"
		then selectedPose.position + Vector3.new(-6, -centerOffset.Y, 0)
		else Vector3.new(
			selectedPose.position.X,
			selectedPose.position.Y
				+ selectedPose.size.Y * 0.5
				+ size.Y * 0.5
				- centerOffset.Y
				+ bottomGap,
			selectedPose.position.Z
		)
	local grounded = placement == "Top"
	normalToDeadAuthorityRuntime.Invalidate(record)
	record.state = {
		frame = state.frame,
		position = position,
		velocity = Vector3.zero,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = grounded,
		groundPlane = grounded,
		groundNormal = Vector3.yAxis,
		groundSlick = false,
		groundNoDamage = false,
		groundMoverId = if grounded then moverId else nil,
		waterLevel = 0,
		waterType = WorldPointContents.Empty,
		jumpHeld = false,
		crouched = state.crouched,
		movementTime = 0,
		timeLand = false,
		timeKnockback = false,
		timeWaterJump = false,
		respawned = false,
	}
	applyEntityStateProjection(record, record.state :: Movement.State, nil)
	record.commandQueue = {}
	record.commandQueueHead = 1
	record.lastProcessedSequence = record.lastReceivedSequence
	record.awaitingViewCommand = false
	record.revision += 1
	record.jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState()
	record.pendingTeleportLook = nil
	record.pendingTeleportTriggerId = nil
	record.pendingSpawnLook = nil
	renderCharacter(player, record)
	sendSnapshot(player, record)
	return true
end

function MovementService.PrepareStudioBinaryMoverBlock(player: Player, moverId: string): boolean
	if not studioMoverFixtureEnabled() or moverRuntime.binaryIds[moverId] ~= true then
		return false
	end
	local program: MoverBinaryState.Program? = nil
	for _, candidate in moverRuntime.binaryPrograms do
		if candidate.id == moverId then
			program = candidate
			break
		end
	end
	if not program then
		return false
	end
	local travel = program.position2 - program.position1
	if travel.Magnitude <= Constants.CollisionSkin * 2 then
		return false
	end
	local direction = travel.Unit
	-- This opt-in fixture helper builds an axis-aligned ceiling. Production
	-- blocker geometry remains map-authored and never enters this branch.
	if direction:Dot(Vector3.yAxis) < 1 - 1e-6 then
		return false
	end
	if not MovementService.PlaceStudioPlayerOnMover(player, moverId) then
		return false
	end
	local record = records[player]
	local state = record and record.state
	if not record or not state then
		return false
	end
	local world = Workspace:FindFirstChild("Q3EngineWorld")
	if not world or not world:IsA("Folder") then
		return false
	end
	local stale = world:FindFirstChild("__StudioBinaryMoverBlocker")
	if stale then
		stale:Destroy()
	end
	local bodySize = Constants.ColliderSizeFor(state.crouched)
	local bodyCenter = state.position + Constants.ColliderCenterOffsetFor(state.crouched)
	local blockerSize = Vector3.new(program.size.X + 8, 2, program.size.Z + 8)
	local blockerCenter = bodyCenter + direction * (bodySize.Y * 0.5 + blockerSize.Y * 0.5)
	local blocker = Instance.new("Part")
	blocker.Name = "__StudioBinaryMoverBlocker"
	blocker.Anchored = true
	blocker.CanCollide = true
	blocker.CanQuery = true
	blocker.CanTouch = false
	blocker.Transparency = 1
	blocker.Size = blockerSize
	blocker.Position = blockerCenter
	blocker:SetAttribute("Q3EngineSystemFixture", true)
	blocker:SetAttribute("Q3EngineBinaryMoverBlocker", true)
	blocker.Parent = world
	return true
end

function MovementService.PlaceStudioPlayerForMoverCrush(
	player: Player,
	moverId: string,
	laneOffsetValue: number?,
	retainExistingBlocker: boolean?
): boolean
	if not studioMoverFixtureEnabled() then
		return false
	end
	local record = records[player]
	local state = record and record.state
	if not record or not state or player:GetAttribute("Q3EngineAlive") ~= true then
		return false
	end

	local definition: MoverPushRules.Definition? = nil
	for _, candidate in moverRuntime.definitions do
		if candidate.id == moverId then
			definition = candidate
			break
		end
	end
	if not definition or definition.trajectory.kind ~= MoverTrajectory.Kinds.Sine then
		return false
	end
	local window = assert(MoverClock.WindowFor(moverRuntime.clock))
	local currentPosition =
		MoverTrajectory.Evaluate(definition.trajectory, window.fromTimeMilliseconds)
	local targetPosition =
		MoverTrajectory.Evaluate(definition.trajectory, window.toTimeMilliseconds)
	local move = targetPosition - currentPosition
	if move.Magnitude <= Constants.CollisionSkin * 2 then
		return false
	end

	local direction = move.Unit
	local laneOffset = laneOffsetValue or 0
	if
		type(laneOffset) ~= "number"
		or laneOffset ~= laneOffset
		or math.abs(laneOffset) == math.huge
		or math.abs(laneOffset) > 3
	then
		return false
	end
	local bodySize = Constants.ColliderSizeFor(state.crouched)
	local centerOffset = Constants.ColliderCenterOffsetFor(state.crouched)
	local function supportRadius(size: Vector3): number
		return (
			math.abs(direction.X) * size.X
			+ math.abs(direction.Y) * size.Y
			+ math.abs(direction.Z) * size.Z
		) * 0.5
	end
	local overlapDepth = math.min(move.Magnitude * 0.5, 0.1)
	local bodyCenter = targetPosition
		+ direction * (supportRadius(definition.size) + supportRadius(bodySize) - overlapDepth)
		+ Vector3.zAxis * laneOffset
	local wallSize = Vector3.new(2, 12, 12)
	local proposedCenter = bodyCenter + move
	local wallCenter = proposedCenter
		- Vector3.zAxis * laneOffset
		+ direction * (supportRadius(bodySize) + supportRadius(wallSize) - overlapDepth)

	local world = Workspace:FindFirstChild("Q3EngineWorld")
	if not world or not world:IsA("Folder") then
		return false
	end
	if retainExistingBlocker ~= true then
		local collisionRoot = world:FindFirstChild("__StudioMoverCrushCollision") or world
		local staleBlocker = collisionRoot:FindFirstChild("__StudioMoverCrushBlocker")
		if staleBlocker then
			staleBlocker:Destroy()
		end
		local blocker = Instance.new("Part")
		blocker.Name = "__StudioMoverCrushBlocker"
		blocker.Anchored = true
		blocker.CanCollide = true
		blocker.CanQuery = true
		blocker.CanTouch = false
		blocker.CastShadow = false
		blocker.Transparency = 1
		blocker.Size = wallSize
		blocker.CFrame = CFrame.new(wallCenter)
		blocker:SetAttribute("Q3EngineSystemFixture", true)
		blocker.Parent = collisionRoot
	end

	normalToDeadAuthorityRuntime.Invalidate(record)
	record.state = {
		frame = state.frame,
		position = bodyCenter - centerOffset,
		velocity = Vector3.zero,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = false,
		groundPlane = false,
		groundNormal = Vector3.yAxis,
		groundSlick = false,
		groundNoDamage = false,
		groundMoverId = nil,
		waterLevel = 0,
		waterType = WorldPointContents.Empty,
		jumpHeld = false,
		crouched = state.crouched,
		movementTime = 0,
		timeLand = false,
		timeKnockback = false,
		timeWaterJump = false,
		respawned = false,
	}
	applyEntityStateProjection(record, record.state :: Movement.State, nil)
	record.commandQueue = {}
	record.commandQueueHead = 1
	record.lastProcessedSequence = record.lastReceivedSequence
	record.awaitingViewCommand = false
	record.revision += 1
	record.jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState()
	record.pendingTeleportLook = nil
	record.pendingTeleportTriggerId = nil
	record.pendingSpawnLook = nil
	renderCharacter(player, record)
	sendSnapshot(player, record)
	return true
end

function MovementService.QueueStudioMoverCrushBatch(
	playersValue: { Player },
	moverIdsValue: { string }
): boolean
	if
		not studioMoverFixtureEnabled()
		or moverRuntime.pendingStudioCrushBatch ~= nil
		or #playersValue ~= 2
		or #moverIdsValue ~= 2
		or playersValue[1] == playersValue[2]
	then
		return false
	end
	moverRuntime.pendingStudioCrushBatch = {
		players = table.clone(playersValue),
		moverIds = table.clone(moverIdsValue),
	}
	return true
end

function MovementService.QueueStudioMoverParticipantFrameCallback(callback: (number) -> ()): boolean
	if
		not studioMoverFixtureEnabled()
		or moverRuntime.pendingStudioParticipantFrameCallback ~= nil
		or type(callback) ~= "function"
	then
		return false
	end
	moverRuntime.pendingStudioParticipantFrameCallback = callback
	return true
end

function MovementService.SetStudioNoDropPointFixture(cframe: CFrame?, size: Vector3?): boolean
	if not studioMoverFixtureEnabled() then
		return false
	end
	if cframe == nil and size == nil then
		moverRuntime.studioNoDropPointFixture = nil
		return true
	end
	if
		typeof(cframe) ~= "CFrame"
		or typeof(size) ~= "Vector3"
		or size.X <= 0
		or size.Y <= 0
		or size.Z <= 0
	then
		return false
	end
	moverRuntime.studioNoDropPointFixture = { cframe = cframe, size = size }
	return true
end

function MovementService.GetDebugMetrics(): DebugMetrics
	local currentBacklogs: { [number]: number } = {}
	for player, record in records do
		local userId = player.UserId
		local current = pendingCommandCount(record)
		currentBacklogs[userId] = current
	end
	local telemetry = telemetryRuntime:Snapshot(currentBacklogs)
	local remoteMetrics = remoteRuntime:GetMetrics()
	return table.freeze({
		heartbeatCount = telemetry.heartbeatCount,
		fixedStepCount = telemetry.fixedStepCount,
		currentAccumulatorSeconds = accumulator,
		maximumAccumulatorSeconds = telemetry.maximumAccumulatorSeconds,
		clampedTimeSeconds = telemetry.clampedTimeSeconds,
		maximumStepsPerHeartbeat = telemetry.maximumStepsPerHeartbeat,
		fixedStepCpuSeconds = telemetry.fixedStepCpuSeconds,
		maximumFixedStepCpuSeconds = telemetry.maximumFixedStepCpuSeconds,
		frameOpenCpuSeconds = telemetry.frameOpenCpuSeconds,
		playerCpuSeconds = telemetry.playerCpuSeconds,
		preMoverCpuSeconds = telemetry.preMoverCpuSeconds,
		moverCpuSeconds = telemetry.moverCpuSeconds,
		postMoverCpuSeconds = telemetry.postMoverCpuSeconds,
		closeCpuSeconds = telemetry.closeCpuSeconds,
		currentCommandBacklogByUserId = table.freeze(currentBacklogs),
		maximumCommandBacklogByUserId = telemetry.maximumCommandBacklogByUserId,
		queueCapacityRejectCount = telemetry.queueCapacityRejectCount,
		rateRejectCount = telemetry.rateRejectCount,
		remoteBatchCount = remoteMetrics.batchCount,
		remotePacketCount = remoteMetrics.packetCount,
		remoteRowCount = remoteMetrics.rowCount,
		simulationFaulted = simulationFaulted,
	})
end

function MovementService.GetCharacter(player: Player): Model?
	local record = records[player]
	return if record then record.character else nil
end

function MovementService.GetSpawnOrigins(): { Vector3 }
	local origins: { Vector3 } = {}
	for _, point in spawnPoints do
		table.insert(origins, point.origin)
	end
	return origins
end

function MovementService.GetSpawnIndex(player: Player): number?
	local record = records[player]
	return if record then record.spawnIndex else nil
end

function MovementService.WaitForSpawnReservation(
	player: Player,
	character: Model,
	timeoutSeconds: number
): (boolean, string?)
	-- This is a yielding Roblox lifecycle boundary, not Q3 level time. os.clock
	-- advances with process CPU consumption and can expire ten nominal seconds in
	-- under one wall-clock second while Studio is overloaded.
	local deadline = Workspace:GetServerTimeNow() + math.max(timeoutSeconds, 0)
	repeat
		local record = records[player]
		if
			record
			and record.character == character
			and record.state ~= nil
			and record.spawnReserved
		then
			return true, nil
		end
		if player.Character ~= character then
			return false, "player-character-replaced"
		end
		task.wait()
	until Workspace:GetServerTimeNow() >= deadline
	local record = records[player]
	if not record then
		return false, "movement-record-missing"
	elseif player.Character ~= character then
		return false, "player-character-replaced"
	elseif not character.Parent then
		return false, "character-unparented"
	elseif record.character ~= character then
		return false, "movement-character-mismatch"
	elseif record.state == nil then
		return false, "movement-state-missing"
	elseif not record.spawnReserved then
		return false, "movement-reservation-missing"
	end
	return false, "movement-reservation-timeout"
end

function MovementService.ConfirmSpawn(
	player: Player,
	lifeSequenceValue: unknown
): MovementLifeBinding?
	local record = records[player]
	local character = record and record.character
	if
		not record
		or player.Parent ~= Players
		or not record.state
		or not record.spawnReserved
		or not character
		or not character.Parent
		or player.Character ~= character
		or record.lifeBinding ~= nil
		or record.lifeSequence ~= nil
		or type(lifeSequenceValue) ~= "number"
		or lifeSequenceValue ~= lifeSequenceValue
		or math.abs(lifeSequenceValue :: number) == math.huge
		or (lifeSequenceValue :: number) % 1 ~= 0
		or (lifeSequenceValue :: number) < 1
		or (lifeSequenceValue :: number) > MAXIMUM_DEBUG_COUNTER
		or EntitySlotService.GetPlayerRegistration(player) ~= record.registration
		or not table.isfrozen(record.registration)
	then
		return nil
	end
	local lifeSequence = lifeSequenceValue :: number
	local handleValue = lifeBindingRuntime:Mint({
		player = player,
		record = record,
		character = character,
		recordLineage = record.recordLineage,
		registration = record.registration,
		lifeSequence = lifeSequence,
	})
	local handle = handleValue :: any
	record.lifeSequence = lifeSequence
	record.lifeBinding = handle
	local pendingTelefrags = record.pendingSpawnTelefragUserIds
	if pendingTelefrags and not applyTelefrags(player, pendingTelefrags, handle) then
		latchSimulationFault()
		invalidateMovementLifeBinding(record)
		record.pendingSpawnTelefragUserIds = nil
		return nil
	end
	record.pendingSpawnTelefragUserIds = nil
	record.spawnReserved = false
	return handle
end

function MovementService.GetMovementLifeBinding(player: Player): MovementLifeBinding?
	local record = records[player]
	local handle = record and record.lifeBinding
	return if handle and currentMovementLifeBinding(handle) then handle else nil
end

function MovementService.InspectMovementLifeBinding(
	bindingValue: unknown
): MovementLifeBindingSummary?
	local capability = select(1, currentMovementLifeBinding(bindingValue))
	return if capability then capability.summary else nil
end

function MovementService.ValidateMovementLifeBindingDependency(
	bindingValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, bindingError = currentMovementLifeBinding(bindingValue)
	if not capability then
		return false, bindingError
	end
	if
		summaryValue ~= capability.summary
		or type(summaryValue) ~= "table"
		or not lifeBindingRuntime:SummaryMatches(capability :: any, summaryValue)
	then
		return false, "forged-movement-life-binding-summary"
	end
	return true, nil
end

function MovementService.SetProjectileDeathSourceAdapter(adapterValue: unknown)
	normalToDeadSourceRuntime:SetProjectileAdapter(adapterValue)
end

function MovementService.GetWorldNormalToDeadSource(): (NormalToDeadSource, NormalToDeadSourceSummary)
	local source, summary = normalToDeadSourceRuntime:GetWorld()
	return source :: any, summary :: any
end

function MovementService.CapturePlayerNormalToDeadSource(
	bindingValue: unknown,
	lifeSummaryValue: unknown
): (
	NormalToDeadSource?,
	NormalToDeadSourceSummary?,
	string?
)
	local lifeCapability, lifeError = currentMovementLifeBinding(bindingValue)
	if not lifeCapability then
		return nil, nil, lifeError or "invalid-normal-to-dead-player-source-life"
	end
	if
		type(lifeSummaryValue) ~= "table"
		or lifeSummaryValue ~= lifeCapability.summary
		or not lifeBindingRuntime:SummaryMatches(lifeCapability :: any, lifeSummaryValue)
	then
		return nil, nil, "forged-normal-to-dead-player-source-life-summary"
	end
	local record = lifeCapability.record
	if not record.state then
		return nil, nil, "normal-to-dead-player-source-state-unavailable"
	end
	local source, summary = normalToDeadSourceRuntime:CapturePlayer({
		player = lifeCapability.player,
		lifeBinding = lifeCapability.handle,
		lifeSummary = lifeCapability.summary,
		record = record,
		entityTrajectoryBase = record.entityTrajectoryBase,
	})
	return source :: any, summary :: any, nil
end

function MovementService.CaptureProjectileNormalToDeadSource(projectileSourceValue: unknown): (
	NormalToDeadSource?,
	NormalToDeadSourceSummary?,
	string?
)
	local source, summary, captureError =
		normalToDeadSourceRuntime:CaptureProjectile(projectileSourceValue)
	return source :: any, summary :: any, captureError
end

function MovementService.ValidateMoverDeathSourceDependency(
	sourceValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, sourceError =
		normalToDeadOwner.currentMoverDeathSource(sourceValue, summaryValue)
	return capability ~= nil, sourceError
end

function MovementService.ClaimMoverDeathSource(
	sourceValue: unknown,
	summaryValue: unknown,
	stageReceiptValue: unknown
): (boolean, string?)
	local capability, sourceError =
		normalToDeadOwner.currentMoverDeathSource(sourceValue, summaryValue)
	if not capability then
		return false, sourceError
	end
	if capability.status ~= "Minted" or capability.stageReceipt ~= nil then
		return false, "mover-death-source-already-claimed"
	end
	if
		type(stageReceiptValue) ~= "table"
		or getmetatable(stageReceiptValue) ~= nil
		or not table.isfrozen(stageReceiptValue :: table)
	then
		return false, "invalid-mover-death-stage-receipt"
	end
	local session = capability.session
	if session.status ~= "Preparing" then
		return false, "mover-death-source-not-claimable"
	end
	local validated, validationError = session.damageAdapter.ValidateMoverDeathStageReceipt(
		session.damageToken,
		stageReceiptValue,
		capability.source,
		capability.summary
	)
	if not validated then
		return false, validationError or "invalid-mover-death-stage-receipt-association"
	end
	capability.stageReceipt = stageReceiptValue
	capability.status = "Claimed"
	return true, nil
end

function MovementService.ValidateBoundMoverDeathSourceDependency(
	sourceValue: unknown,
	summaryValue: unknown,
	stageReceiptValue: unknown
): (boolean, string?)
	local capability, sourceError =
		normalToDeadOwner.currentMoverDeathSource(sourceValue, summaryValue)
	if not capability then
		return false, sourceError
	end
	if
		capability.status ~= "BoundLethal"
		or capability.stageReceipt ~= stageReceiptValue
		or capability.session.status ~= "Bound"
	then
		return false, "mover-death-source-not-bound-lethal"
	end
	return true, nil
end

function MovementService.RetireMoverDeathSourcesForDamageToken(tokenValue: unknown): boolean
	local session =
		MovementMoverRuntime.GetDeathSourceSession(moverRuntime) :: MoverDeathSourceSession?
	if not session or session.damageToken ~= tokenValue then
		return false
	end
	MovementMoverRuntime.RetireDeathSourceSession(moverRuntime, session)
	return true
end

function MovementService.InspectNormalToDeadSource(sourceValue: unknown): NormalToDeadSourceSummary?
	return normalToDeadSourceRuntime:Inspect(
			sourceValue,
			normalToDeadOwner.validatePlayerSource
		) :: any
end

function MovementService.ValidateNormalToDeadSourceDependency(
	sourceValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, sourceError = normalToDeadOwner.currentSource(sourceValue, summaryValue, true)
	return capability ~= nil, sourceError
end

-- Dormant prepared owner for g_combat.c::player_die. The caller supplies only
-- trusted source capabilities and the already-authorized lethal impulse; every
-- victim field comes from the exact private current Movement life. No Combat or
-- frame path calls this until the complete multi-owner death composite exists.
function MovementService.PrepareNormalToDead(
	lifeBindingValue: unknown,
	lifeSummaryValue: unknown,
	lethalVelocityDeltaValue: unknown,
	lethalKnockbackSecondsValue: unknown,
	attackerSourceValue: unknown,
	attackerSourceSummaryValue: unknown,
	inflictorSourceValue: unknown,
	inflictorSourceSummaryValue: unknown
): (
	PreparedNormalToDead?,
	PreparedNormalToDeadSummary?,
	string?
)
	local lifeCapability, lifeError = currentMovementLifeBinding(lifeBindingValue)
	if not lifeCapability then
		return nil, nil, lifeError or "invalid-normal-to-dead-life"
	end
	if
		type(lifeSummaryValue) ~= "table"
		or lifeSummaryValue ~= lifeCapability.summary
		or not lifeBindingRuntime:SummaryMatches(lifeCapability :: any, lifeCapability.summary)
	then
		return nil, nil, "forged-normal-to-dead-life-summary"
	end
	local player = lifeCapability.player
	local record = lifeCapability.record
	local baseState = record.state
	if
		not baseState
		or record.deadState ~= nil
		or record.deathTransition ~= nil
		or record.firstDeadStepPhase ~= nil
	then
		return nil, nil, "normal-to-dead-requires-current-normal-state"
	end
	if normalToDeadPreparedRegistry:GetActiveForRecord(record) ~= nil then
		return nil, nil, "normal-to-dead-already-prepared-for-life"
	end
	if
		not table.isfrozen(record.entityAngularTrajectoryBase)
		or not table.isfrozen(record.entityGenericAngles)
		or not table.isfrozen(record.playerStateViewAngles)
	then
		return nil, nil, "normal-to-dead-cached-angles-not-immutable"
	end

	local attackerCapability, attackerError =
		normalToDeadOwner.currentSource(attackerSourceValue, attackerSourceSummaryValue, true)
	if not attackerCapability then
		return nil, nil, attackerError or "invalid-normal-to-dead-attacker-source"
	end
	if attackerCapability.summary.kind == "Projectile" then
		-- g_missile.c supplies ent->parent as attacker and the Missile as
		-- inflictor. A projectile capability must never stand in for the
		-- separately captured current player trajectory base.
		return nil, nil, "normal-to-dead-projectile-source-is-inflictor-only"
	end
	local inflictorCapability, inflictorError =
		normalToDeadOwner.currentSource(inflictorSourceValue, inflictorSourceSummaryValue, true)
	if not inflictorCapability then
		return nil, nil, inflictorError or "invalid-normal-to-dead-inflictor-source"
	end
	local nextState, retainedKnockbackSeconds, lethalStateError =
		MovementNormalToDeadStateRuntime.BuildLethal(
			baseState,
			lethalVelocityDeltaValue,
			lethalKnockbackSecondsValue,
			Constants.MinimumDamageKnockbackSeconds,
			Constants.MaximumDamageKnockbackSeconds
		)
	if not nextState then
		return nil, nil, lethalStateError or "normal-to-dead-lethal-state-invalid"
	end
	local attackerResolved = normalToDeadOwner.resolveSource(attackerCapability, record)
	local inflictorResolved = normalToDeadOwner.resolveSource(inflictorCapability, record)
	local deathTransition, transitionError = DeathTransitionRules.Resolve({
		lifeSequence = lifeCapability.summary.lifeSequence,
		crouched = baseState.crouched,
		victimTrajectoryBase = record.entityTrajectoryBase,
		retainedGenericAngles = record.entityGenericAngles,
		attacker = attackerResolved,
		inflictor = inflictorResolved,
	})
	if not deathTransition then
		return nil, nil, transitionError or "normal-to-dead-transition-invalid"
	end
	local deadEntry, deadEntryError = MovementPhaseRules.CreateDeadEntryContract(
		baseState.crouched,
		deathTransition.deadLifeSequence,
		deathTransition.deadYawDegrees
	)
	if not deadEntry then
		return nil, nil, deadEntryError or "normal-to-dead-entry-contract-invalid"
	end
	local deadState = Movement.newDeadState(nextState)
	if
		deadState.viewHeight ~= deathTransition.initialViewHeight
		or deadState.viewHeight ~= deadEntry.initialViewHeight
	then
		return nil, nil, "normal-to-dead-initial-viewheight-diverged"
	end
	table.freeze(deadState)

	local baseStateSnapshot = MovementNormalToDeadStateRuntime.Snapshot(baseState)
	local nextStateSnapshot = MovementNormalToDeadStateRuntime.Snapshot(nextState)
	local summary: PreparedNormalToDeadSummary = {
		mode = "Direct",
		player = player,
		playerUserId = lifeCapability.summary.playerUserId,
		lifeBinding = lifeCapability.handle,
		lifeSummary = lifeCapability.summary,
		baseState = baseStateSnapshot,
		nextState = nextStateSnapshot,
		prospectiveState = baseStateSnapshot,
		deathTrajectoryBase = record.entityTrajectoryBase,
		baseEntityTrajectoryBase = record.entityTrajectoryBase,
		baseEntityTrajectoryDelta = record.entityTrajectoryDelta,
		baseEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		nextEntityTrajectoryBase = record.entityTrajectoryBase,
		nextEntityTrajectoryDelta = record.entityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		baseEntityGenericAngles = record.entityGenericAngles,
		basePlayerStateViewAngles = record.playerStateViewAngles,
		callbackEntityTrajectoryBase = record.entityTrajectoryBase,
		callbackEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		baseSpawnReserved = record.spawnReserved,
		nextSpawnReserved = false,
		lethalVelocityDelta = lethalVelocityDeltaValue :: Vector3,
		lethalKnockbackSeconds = retainedKnockbackSeconds,
		attackerSource = attackerCapability.summary,
		inflictorSource = inflictorCapability.summary,
		deathTransition = deathTransition,
		deadEntry = deadEntry,
	}
	table.freeze(summary)
	local prepared: PreparedNormalToDead = table.freeze({})
	local receipt: NormalToDeadApplyReceipt = table.freeze({})
	local receiptCapability: NormalToDeadReceiptCapability = {
		receipt = receipt,
		status = "Pending",
		mode = "Direct",
		summary = summary,
		player = player,
		record = record,
		lifeBinding = lifeCapability.handle,
		baseSpawnReserved = record.spawnReserved,
		baseState = baseState,
		nextState = nextState,
		prospectiveState = baseState,
		deathTrajectoryBase = record.entityTrajectoryBase,
		nextEntityTrajectoryBase = record.entityTrajectoryBase,
		nextEntityTrajectoryDelta = record.entityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		deadState = deadState,
		deathTransition = deathTransition,
		firstDeadStepPhase = deadEntry.firstStepPhase,
		attackerSource = attackerCapability.source,
		attackerSourceSummary = attackerCapability.summary,
		inflictorSource = inflictorCapability.source,
		inflictorSourceSummary = inflictorCapability.summary,
		moverWitness = nil,
		outerBatchReceipt = nil,
		outerBatchIndex = nil,
	}
	local capability: PreparedNormalToDeadCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		batchOwner = nil,
		mode = "Direct",
		player = player,
		record = record,
		lifeBinding = lifeCapability.handle,
		lifeSummary = lifeCapability.summary,
		baseState = baseState,
		baseStateSnapshot = baseStateSnapshot,
		nextState = nextState,
		nextStateSnapshot = nextStateSnapshot,
		prospectiveState = baseState,
		prospectiveStateSnapshot = baseStateSnapshot,
		deathTrajectoryBase = record.entityTrajectoryBase,
		baseEntityTrajectoryBase = record.entityTrajectoryBase,
		baseEntityTrajectoryDelta = record.entityTrajectoryDelta,
		baseEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		nextEntityTrajectoryBase = record.entityTrajectoryBase,
		nextEntityTrajectoryDelta = record.entityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		baseEntityGenericAngles = record.entityGenericAngles,
		basePlayerStateViewAngles = record.playerStateViewAngles,
		callbackEntityTrajectoryBase = record.entityTrajectoryBase,
		callbackEntityAngularTrajectoryBase = record.entityAngularTrajectoryBase,
		baseSpawnReserved = record.spawnReserved,
		attackerSource = attackerCapability.source,
		attackerSourceSummary = attackerCapability.summary,
		inflictorSource = inflictorCapability.source,
		inflictorSourceSummary = inflictorCapability.summary,
		moverWitness = nil,
		deathTransition = deathTransition,
		deadState = deadState,
		firstDeadStepPhase = deadEntry.firstStepPhase,
		summary = summary,
		receipt = receipt,
		receiptCapability = receiptCapability,
	}
	-- A successfully prepared successor permanently retires any old witness for
	-- this record even if the successor is later aborted.
	normalToDeadAuthorityRuntime.RetireAppliedReceipt(record)
	normalToDeadPreparedRegistry:SetPreparedCapability(prepared, capability)
	normalToDeadPreparedRegistry:SetPreparedForSummary(summary, prepared)
	normalToDeadPreparedRegistry:SetReceiptCapability(receipt, receiptCapability)
	normalToDeadPreparedRegistry:SetActiveForRecord(record, prepared)
	return prepared, summary, nil
end

function MovementService.InspectPreparedNormalToDead(
	preparedValue: unknown
): PreparedNormalToDeadSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = normalToDeadPreparedRegistry:GetPreparedCapability(preparedValue) :: any
	if
		not capability
		or normalToDeadOwner.preparedCurrentError(preparedValue, capability, true) ~= nil
	then
		return nil
	end
	return capability.summary
end

function MovementService.InspectPreparedNormalToDeadReceipt(
	preparedValue: unknown
): NormalToDeadApplyReceipt?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = normalToDeadPreparedRegistry:GetPreparedCapability(preparedValue) :: any
	if
		not capability
		or normalToDeadOwner.preparedCurrentError(preparedValue, capability, true) ~= nil
	then
		return nil
	end
	return capability.receipt
end

function MovementService.ValidatePreparedNormalToDeadDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-prepared-normal-to-dead-dependency"
	end
	local prepared = preparedValue :: PreparedNormalToDead
	local capability = normalToDeadPreparedRegistry:GetPreparedCapability(prepared) :: any
	if
		not capability
		or capability.summary ~= summaryValue
		or normalToDeadPreparedRegistry:GetPreparedForSummary(summaryValue) ~= prepared
	then
		return false, "forged-prepared-normal-to-dead-dependency"
	end
	local currentError = normalToDeadOwner.preparedCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function MovementService.CanApplyPreparedNormalToDead(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-normal-to-dead"
	end
	local prepared = preparedValue :: PreparedNormalToDead
	local capability = normalToDeadPreparedRegistry:GetPreparedCapability(prepared) :: any
	if not capability then
		return false, "invalid-prepared-normal-to-dead"
	end
	capability.applyValidated = false
	local currentError = normalToDeadOwner.preparedCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

function MovementService.ApplyPreparedNormalToDead(preparedValue: unknown): NormalToDeadApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-normal-to-dead")
	local prepared = preparedValue :: PreparedNormalToDead
	local capability = assert(
		normalToDeadPreparedRegistry:GetPreparedCapability(prepared),
		"invalid-prepared-normal-to-dead"
	)
	assert(capability.applyValidated, "prepared-normal-to-dead-not-validated")
	assert(
		normalToDeadOwner.preparedCurrentError(prepared, capability, false) == nil,
		"stale-prepared-normal-to-dead-at-apply"
	)

	-- All construction, freezing, source resolution, external life validation,
	-- and dependency inspection ended above. This authority boundary performs
	-- only precomputed private root/capability assignments.
	normalToDeadAuthorityRuntime.ApplyPrepared(capability)
	return capability.receipt
end

local function validateAppliedNormalToDeadRootDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (NormalToDeadReceiptCapability?, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return nil, "invalid-applied-normal-to-dead-dependency"
	end
	local receipt = receiptValue :: NormalToDeadApplyReceipt
	local capability = normalToDeadPreparedRegistry:GetReceiptCapability(receipt) :: any
	if not capability or capability.receipt ~= receipt then
		return nil, "invalid-applied-normal-to-dead-receipt"
	end
	if capability.summary ~= summaryValue then
		return nil, "forged-applied-normal-to-dead-summary"
	end
	if capability.status ~= "Applied" then
		return nil, "normal-to-dead-dependency-not-applied"
	end
	local record = capability.record
	local summary = capability.summary
	if
		capability.mode ~= summary.mode
		or capability.deathTrajectoryBase ~= summary.deathTrajectoryBase
		or capability.nextEntityTrajectoryBase ~= summary.nextEntityTrajectoryBase
		or capability.nextEntityTrajectoryDelta ~= summary.nextEntityTrajectoryDelta
		or capability.nextEntityAngularTrajectoryBase ~= summary.nextEntityAngularTrajectoryBase
		or normalToDeadPreparedRegistry:GetAppliedReceiptForRecord(record) ~= receipt
		or normalToDeadPreparedRegistry:GetActiveForRecord(record) ~= nil
		or records[capability.player] ~= record
		or record.state ~= capability.nextState
		or not MovementNormalToDeadStateRuntime.Matches(capability.nextState, summary.nextState)
		or record.lifeBinding ~= capability.lifeBinding
		or record.lifeSequence ~= summary.lifeSummary.lifeSequence
		or record.spawnReserved ~= false
		or record.entityTrajectoryBase ~= capability.nextEntityTrajectoryBase
		or record.entityTrajectoryDelta ~= capability.nextEntityTrajectoryDelta
		or record.entityAngularTrajectoryBase ~= capability.nextEntityAngularTrajectoryBase
		or record.entityGenericAngles ~= capability.deathTransition.deathGenericAngles
		or record.playerStateViewAngles ~= capability.deathTransition.playerStateViewAngles
		or record.deadState ~= capability.deadState
		or record.deathTransition ~= capability.deathTransition
		or record.firstDeadStepPhase ~= capability.firstDeadStepPhase
		or capability.deadState.state ~= capability.nextState
		or capability.deadState.viewHeight ~= summary.deadEntry.initialViewHeight
		or capability.firstDeadStepPhase ~= summary.deadEntry.firstStepPhase
		or not table.isfrozen(receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(capability.nextState)
		or not table.isfrozen(capability.deadState)
		or not table.isfrozen(capability.deathTransition)
		or not table.isfrozen(capability.nextEntityAngularTrajectoryBase)
	then
		return nil, "stale-applied-normal-to-dead-dependency"
	end
	local currentLife = select(1, currentMovementLifeBinding(capability.lifeBinding))
	if
		not currentLife
		or currentLife.record ~= record
		or currentLife.summary ~= summary.lifeSummary
	then
		return nil, "stale-applied-normal-to-dead-life"
	end
	return capability, nil
end

-- A direct player_die source can be intentionally short-lived: the attacker
-- may move on its next command and a Missile becomes an Event immediately
-- after impact. The durable death composite therefore proves the exact applied
-- Movement root and one-use receipt association without requiring those old
-- source capabilities to remain current forever. Callers that still need the
-- stronger adjacency proof use ValidateAppliedNormalToDeadDependency below.
function MovementService.ValidateAppliedNormalToDeadRootDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, dependencyError =
		validateAppliedNormalToDeadRootDependency(receiptValue, summaryValue)
	return capability ~= nil, dependencyError
end

function MovementService.ValidateAppliedNormalToDeadDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, dependencyError =
		validateAppliedNormalToDeadRootDependency(receiptValue, summaryValue)
	if not capability then
		return false, dependencyError
	end
	local receipt = receiptValue :: NormalToDeadApplyReceipt
	local summary = capability.summary
	local record = capability.record
	if capability.mode == "Direct" then
		if
			capability.moverWitness ~= nil
			or not select(
				1,
				normalToDeadOwner.currentSource(
					capability.attackerSource,
					capability.attackerSourceSummary,
					true
				)
			)
			or not select(
				1,
				normalToDeadOwner.currentSource(
					capability.inflictorSource,
					capability.inflictorSourceSummary,
					true
				)
			)
		then
			return false, "stale-applied-normal-to-dead-source"
		end
	elseif capability.mode == "MoverPushed" then
		local witness = capability.moverWitness
		local sourceCapability = witness and witness.sourceCapability
		local removedCallbackBody = witness and witness.assignment.removedCallbackBody
		local batchReceipt = capability.outerBatchReceipt
		local batchIndex = capability.outerBatchIndex
		local batchReceiptCapability = if batchReceipt
			then normalToDeadPreparedRegistry:GetBatchReceiptCapability(batchReceipt)
			else nil
		local batchIndexIsValid = batchReceiptCapability ~= nil
			and batchIndex ~= nil
			and isFinite(batchIndex)
			and batchIndex % 1 == 0
			and batchIndex >= 1
			and batchIndex <= #batchReceiptCapability.entries
		local batchEntry = if batchReceiptCapability
				and batchIndexIsValid
				and batchIndex
			then batchReceiptCapability.entries[batchIndex]
			else nil
		if
			not witness
			or not sourceCapability
			or not batchReceipt
			or not batchIndex
			or not batchReceiptCapability
			or not batchIndexIsValid
			or not batchEntry
			or batchReceiptCapability.status ~= "Applied"
			or batchReceiptCapability.receipt ~= batchReceipt
			or batchReceiptCapability.receipts[batchIndex] ~= receipt
			or batchReceiptCapability.summary.records[batchIndex] ~= summary
			or batchEntry.receipt ~= receipt
			or batchEntry.summary ~= summary
			or batchEntry.player ~= capability.player
			or batchEntry.record ~= record
			or batchEntry.lifeBinding ~= capability.lifeBinding
			or batchEntry.preparedCapability.receiptCapability ~= capability
			or batchEntry.preparedCapability.moverWitness ~= witness
			or witness.source ~= capability.attackerSource
			or witness.source ~= capability.inflictorSource
			or witness.sourceSummary ~= capability.attackerSourceSummary
			or witness.sourceSummary ~= capability.inflictorSourceSummary
			or witness.assignment.nextState ~= capability.prospectiveState
			or (removedCallbackBody ~= nil and (not table.isfrozen(removedCallbackBody) or removedCallbackBody.id ~= record.moverBodyId or removedCallbackBody.sourceOrder ~= record.moverBodySourceOrder or removedCallbackBody.position ~= capability.prospectiveState.position))
			or witness.outerPrepared ~= witness.outerCapability.preparedHandle
			or (witness.outerCapability.status ~= "Applied" and witness.outerCapability.status ~= "Published")
			or MovementMoverRuntime.GetDeathSourceCapability(moverRuntime, witness.source) ~= sourceCapability
			or sourceCapability.status ~= "Retired"
			or sourceCapability.session.status ~= "Retired"
			or sourceCapability.stageReceipt ~= nil
			or sourceCapability.appliedNormalToDeadReceipt ~= receipt
		then
			return false, "stale-applied-mover-normal-to-dead-source"
		end
	else
		return false, "invalid-applied-normal-to-dead-mode"
	end
	return true, nil
end

function MovementService.AbortPreparedNormalToDead(preparedValue: unknown): boolean
	if type(preparedValue) ~= "table" then
		return false
	end
	local prepared = preparedValue :: PreparedNormalToDead
	local capability = normalToDeadPreparedRegistry:GetPreparedCapability(prepared) :: any
	if
		not capability
		or capability.status ~= "Prepared"
		or capability.batchOwner ~= nil
		or normalToDeadPreparedRegistry:GetActiveForRecord(capability.record) ~= prepared
	then
		return false
	end
	normalToDeadAuthorityRuntime.RetirePrepared(capability)
	return true
end

-- Administrative PlayerRemoving invalidation may retire the exact prepared
-- capability before an outer owner receives its disconnect callback. This
-- read-only witness lets that owner distinguish the already-retired child from
-- a forged or applied handle without making ordinary Abort idempotent.
function MovementService.ValidateRetiredPreparedNormalToDeadDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-retired-prepared-normal-to-dead-dependency"
	end
	local prepared = preparedValue :: PreparedNormalToDead
	if not normalToDeadPreparedRegistry:RetiredSummaryMatches(prepared, summaryValue) then
		return false, "forged-retired-prepared-normal-to-dead-dependency"
	end
	return true, nil
end

-- This dormant coordinator adopts exact already-prepared player_die plans. It
-- never accepts raw impulses, sources, Players, or vectors, and it preserves
-- caller order for future source-ordered multi-owner death composition.
function MovementService.PrepareNormalToDeadBatch(entriesValue: unknown): (
	PreparedNormalToDeadBatch?,
	PreparedNormalToDeadBatchSummary?,
	string?
)
	if normalToDeadPreparedRegistry:GetActiveBatch() ~= nil then
		return nil, nil, "normal-to-dead-batch-already-prepared"
	end
	local operationCount = normalToDeadOwner.boundedDenseBatchLength(entriesValue)
	if not operationCount then
		return nil, nil, "normal-to-dead-batch-not-dense-bounded-array"
	end
	local values = entriesValue :: { [unknown]: unknown }
	local entries: { PreparedNormalToDeadBatchEntryCapability } = {}
	local recordsInOrder: { PreparedNormalToDeadSummary } = {}
	local receiptsInOrder: { NormalToDeadApplyReceipt } = {}
	local seenPlayers: { [Player]: boolean } = {}
	local seenLives: { [MovementLifeBinding]: boolean } = {}
	local seenLeases: { [EntitySlotService.Registration]: boolean } = {}
	local seenRecords: { [PlayerRecord]: boolean } = {}
	local seenPrepared: { [PreparedNormalToDead]: boolean } = {}
	local seenSummaries: { [PreparedNormalToDeadSummary]: boolean } = {}
	local seenReceipts: { [NormalToDeadApplyReceipt]: boolean } = {}
	for index = 1, operationCount do
		local entryValue = rawget(values, index)
		if not normalToDeadOwner.hasExactBatchEntryKeys(entryValue) then
			return nil, nil, "invalid-normal-to-dead-batch-entry"
		end
		local raw = entryValue :: { [unknown]: unknown }
		local preparedValue = rawget(raw, "prepared")
		local summaryValue = rawget(raw, "summary")
		local receiptValue = rawget(raw, "receipt")
		if
			type(preparedValue) ~= "table"
			or type(summaryValue) ~= "table"
			or type(receiptValue) ~= "table"
		then
			return nil, nil, "invalid-normal-to-dead-batch-entry-dependency"
		end
		local prepared = preparedValue :: PreparedNormalToDead
		local summary = summaryValue :: PreparedNormalToDeadSummary
		local receipt = receiptValue :: NormalToDeadApplyReceipt
		local preparedCapability =
			normalToDeadPreparedRegistry:GetPreparedCapability(prepared) :: any
		if
			not preparedCapability
			or preparedCapability.summary ~= summary
			or preparedCapability.receipt ~= receipt
			or normalToDeadPreparedRegistry:GetPreparedForSummary(summary) ~= prepared
			or normalToDeadPreparedRegistry:GetReceiptCapability(receipt)
				~= preparedCapability.receiptCapability
		then
			return nil, nil, "forged-normal-to-dead-batch-entry-dependency"
		end
		if preparedCapability.batchOwner ~= nil then
			return nil, nil, "normal-to-dead-batch-entry-already-bound"
		end
		local currentError =
			normalToDeadOwner.preparedCurrentError(prepared, preparedCapability, true)
		if currentError then
			return nil, nil, currentError
		end
		local player = preparedCapability.player
		local lifeBinding = preparedCapability.lifeBinding
		local registration = preparedCapability.lifeSummary.registration
		local record = preparedCapability.record
		if seenPlayers[player] then
			return nil, nil, "duplicate-normal-to-dead-batch-player"
		end
		if seenLives[lifeBinding] then
			return nil, nil, "duplicate-normal-to-dead-batch-life"
		end
		if seenLeases[registration] then
			return nil, nil, "duplicate-normal-to-dead-batch-lease"
		end
		if seenRecords[record] then
			return nil, nil, "duplicate-normal-to-dead-batch-record"
		end
		if seenPrepared[prepared] or seenSummaries[summary] or seenReceipts[receipt] then
			return nil, nil, "duplicate-normal-to-dead-batch-proof"
		end
		seenPlayers[player] = true
		seenLives[lifeBinding] = true
		seenLeases[registration] = true
		seenRecords[record] = true
		seenPrepared[prepared] = true
		seenSummaries[summary] = true
		seenReceipts[receipt] = true
		local entry: PreparedNormalToDeadBatchEntryCapability = {
			prepared = prepared,
			preparedCapability = preparedCapability,
			summary = summary,
			receipt = receipt,
			player = player,
			record = record,
			lifeBinding = lifeBinding,
			registration = registration,
		}
		table.freeze(entry)
		entries[index] = entry
		recordsInOrder[index] = summary
		receiptsInOrder[index] = receipt
	end
	table.freeze(entries)
	table.freeze(recordsInOrder)
	table.freeze(receiptsInOrder)
	local summary: PreparedNormalToDeadBatchSummary = {
		operationCount = operationCount,
		records = recordsInOrder,
	}
	table.freeze(summary)
	local prepared: PreparedNormalToDeadBatch = table.freeze({})
	local receipt: NormalToDeadBatchApplyReceipt = table.freeze({})
	local receiptCapability: NormalToDeadBatchReceiptCapability = {
		receipt = receipt,
		status = "Pending",
		summary = summary,
		receipts = receiptsInOrder,
		entries = entries,
	}
	local capability: PreparedNormalToDeadBatchCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		outerMoverOwner = nil,
		entries = entries,
		summary = summary,
		receipts = receiptsInOrder,
		receipt = receipt,
		receiptCapability = receiptCapability,
	}
	for index = 1, operationCount do
		entries[index].preparedCapability.applyValidated = false
		entries[index].preparedCapability.batchOwner = prepared
	end
	normalToDeadPreparedRegistry:SetBatchCapability(prepared, capability)
	normalToDeadPreparedRegistry:SetBatchForSummary(summary, prepared)
	normalToDeadPreparedRegistry:SetBatchReceiptCapability(receipt, receiptCapability)
	normalToDeadPreparedRegistry:SetActiveBatch(prepared)
	return prepared, summary, nil
end

function MovementService.InspectPreparedNormalToDeadBatch(
	preparedValue: unknown
): PreparedNormalToDeadBatchSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(preparedValue) :: any
	if
		not capability
		or normalToDeadOwner.preparedBatchCurrentError(preparedValue, capability, true) ~= nil
	then
		return nil
	end
	return capability.summary
end

function MovementService.InspectPreparedNormalToDeadBatchReceipts(
	preparedValue: unknown
): { NormalToDeadApplyReceipt }?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(preparedValue) :: any
	if
		not capability
		or normalToDeadOwner.preparedBatchCurrentError(preparedValue, capability, true) ~= nil
	then
		return nil
	end
	return capability.receipts
end

function MovementService.InspectPreparedNormalToDeadBatchReceipt(
	preparedValue: unknown
): NormalToDeadBatchApplyReceipt?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(preparedValue) :: any
	if
		not capability
		or normalToDeadOwner.preparedBatchCurrentError(preparedValue, capability, true) ~= nil
	then
		return nil
	end
	return capability.receipt
end

function MovementService.ValidatePreparedNormalToDeadBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-prepared-normal-to-dead-batch-dependency"
	end
	local prepared = preparedValue :: PreparedNormalToDeadBatch
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(prepared) :: any
	if
		not capability
		or capability.summary ~= summaryValue
		or normalToDeadPreparedRegistry:GetBatchForSummary(summaryValue) ~= prepared
	then
		return false, "forged-prepared-normal-to-dead-batch-dependency"
	end
	local currentError = normalToDeadOwner.preparedBatchCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function MovementService.CanApplyPreparedNormalToDeadBatch(
	preparedValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-normal-to-dead-batch"
	end
	local prepared = preparedValue :: PreparedNormalToDeadBatch
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(prepared) :: any
	if not capability then
		return false, "invalid-prepared-normal-to-dead-batch"
	end
	capability.applyValidated = false
	local currentError = normalToDeadOwner.preparedBatchCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

function MovementService.ApplyPreparedNormalToDeadBatch(
	preparedValue: unknown
): NormalToDeadBatchApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-normal-to-dead-batch")
	local prepared = preparedValue :: PreparedNormalToDeadBatch
	local capability = assert(
		normalToDeadPreparedRegistry:GetBatchCapability(prepared) :: any,
		"invalid-prepared-normal-to-dead-batch"
	)
	assert(capability.applyValidated, "prepared-normal-to-dead-batch-not-validated")
	assert(
		normalToDeadOwner.preparedBatchCurrentError(prepared, capability, false) == nil,
		"stale-prepared-normal-to-dead-batch-at-apply"
	)

	-- The complete caller-ordered member set passed its local-root recheck
	-- above. This is the sole batch authority boundary; it performs only the
	-- prebuilt per-record/capability assignments shared with single Apply.
	normalToDeadAuthorityRuntime.ApplyPreparedBatch(capability)
	return capability.receipt
end

function MovementService.ValidateAppliedNormalToDeadBatchDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-applied-normal-to-dead-batch-dependency"
	end
	local receipt = receiptValue :: NormalToDeadBatchApplyReceipt
	local capability = normalToDeadPreparedRegistry:GetBatchReceiptCapability(receipt) :: any
	if not capability or capability.receipt ~= receipt then
		return false, "invalid-applied-normal-to-dead-batch-receipt"
	end
	if capability.summary ~= summaryValue then
		return false, "forged-applied-normal-to-dead-batch-summary"
	end
	if capability.status ~= "Applied" then
		return false, "normal-to-dead-batch-dependency-not-applied"
	end
	local summary = capability.summary
	local operationCount = #capability.entries
	if
		operationCount < 1
		or operationCount > normalToDeadOwner.maximumBatchSize
		or summary.operationCount ~= operationCount
		or #summary.records ~= operationCount
		or #capability.receipts ~= operationCount
		or not table.isfrozen(receipt)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.records)
		or not table.isfrozen(capability.receipts)
		or not table.isfrozen(capability.entries)
	then
		return false, "stale-applied-normal-to-dead-batch-dependency"
	end
	for index = 1, operationCount do
		local entry = capability.entries[index]
		if
			not table.isfrozen(entry)
			or summary.records[index] ~= entry.summary
			or capability.receipts[index] ~= entry.receipt
			or entry.preparedCapability.summary ~= entry.summary
			or entry.preparedCapability.receipt ~= entry.receipt
			or entry.preparedCapability.player ~= entry.player
			or entry.preparedCapability.record ~= entry.record
			or entry.preparedCapability.lifeBinding ~= entry.lifeBinding
			or entry.preparedCapability.lifeSummary.registration ~= entry.registration
			or not select(
				1,
				MovementService.ValidateAppliedNormalToDeadDependency(entry.receipt, entry.summary)
			)
		then
			return false, "stale-applied-normal-to-dead-batch-member"
		end
	end
	return true, nil
end

function MovementService.AbortPreparedNormalToDeadBatch(preparedValue: unknown): boolean
	if type(preparedValue) ~= "table" then
		return false
	end
	local prepared = preparedValue :: PreparedNormalToDeadBatch
	local capability = normalToDeadPreparedRegistry:GetBatchCapability(prepared) :: any
	if
		not capability
		or capability.status ~= "Prepared"
		or capability.outerMoverOwner ~= nil
		or normalToDeadPreparedRegistry:GetActiveBatch() ~= prepared
	then
		return false
	end
	-- Cleanup intentionally does not require external source currentness. A
	-- projectile provider may drift after Prepare; all local reservations and
	-- every pending proof must still be retired together.
	normalToDeadAuthorityRuntime.RetirePreparedBatch(capability)
	return true
end

function MovementService.ReleaseSpawn(player: Player): boolean
	local record = records[player]
	if not record then
		return false
	end
	normalToDeadAuthorityRuntime.Invalidate(record)
	record.spawnReserved = false
	record.pendingSpawnTelefragUserIds = nil
	return true
end

function MovementService.ClaimMatchTransitionCleanupOwner(): (MatchTransitionCleanupOwner?, string?)
	if matchTransitionCleanupOwner then
		return nil, "movement-match-transition-cleanup-owner-already-claimed"
	end
	local owner: MatchTransitionCleanupOwner = table.freeze({})
	matchTransitionCleanupOwner = owner
	return owner, nil
end

-- Roblox may need a later Character replacement for a dead client while a Q3
-- map/mode restart has already discarded the old corpse. Retire only that dead
-- PM_DEAD state so the same fixed frame cannot step without its corpse owner;
-- the retained Player/EntitySlot record admits the later authoritative spawn.
function MovementService.RetireDeadClientForMatchTransition(
	player: Player,
	ownerValue: unknown
): boolean
	local record = records[player]
	if
		type(ownerValue) ~= "table"
		or ownerValue ~= matchTransitionCleanupOwner
		or not record
		or record.state == nil
		or record.deadState == nil
		or record.deathTransition == nil
	then
		return false
	end
	normalToDeadAuthorityRuntime.Invalidate(record)
	invalidateMovementLifeBinding(record)
	record.state = nil
	record.deadState = nil
	record.deathTransition = nil
	record.firstDeadStepPhase = nil
	record.spawnReserved = false
	record.pendingSpawnTelefragUserIds = nil
	return true
end

function MovementService.Respawn(player: Player, spawnIndex: number?): boolean
	local record = records[player]
	return if record then resetMovement(player, record, spawnIndex) else false
end

function MovementService.TeleportToSpawn(player: Player, spawnIndex: number?): boolean
	return MovementService.Respawn(player, spawnIndex)
end

function MovementService.PreparePersonalTeleport(player: Player): (
	MovementTeleportRuntime.Prepared?,
	MovementTeleportRuntime.PreparedSummary?,
	string?
)
	local record = records[player]
	local lifeBinding = record and record.lifeBinding
	if
		not fixedStepTransactionOpen
		or not record
		or player:GetAttribute("Q3EngineAlive") ~= true
		or not lifeBinding
		or currentMovementLifeBinding(lifeBinding) == nil
	then
		return nil, nil, "personal-teleporter-outside-live-client-frame"
	end
	local choice = chooseSpawn(player, record, nil, nil, false)
	if not choice then
		return nil, nil, "personal-teleporter-spawn-unavailable"
	end
	local look = choice.facing.Unit
	return teleportRuntime:Prepare(
		player,
		record,
		choice.origin + Vector3.yAxis * WorldTriggerRules.TeleportVerticalOffset,
		look,
		look * WorldTriggerRules.TeleportExitSpeed,
		WorldTriggerRules.TeleportKnockbackSeconds,
		lifeBinding
	)
end

function MovementService.InspectPreparedPersonalTeleport(
	prepared: unknown
): MovementTeleportRuntime.PreparedSummary?
	return teleportRuntime:InspectPrepared(prepared)
end

function MovementService.CanApplyPreparedPersonalTeleport(prepared: unknown): (boolean, string?)
	return teleportRuntime:CanApplyPrepared(prepared)
end

function MovementService.ApplyPreparedPersonalTeleport(
	prepared: unknown
): MovementTeleportRuntime.ApplyReceipt?
	return teleportRuntime:ApplyPrepared(prepared)
end

function MovementService.AbortPreparedPersonalTeleport(prepared: unknown): boolean
	return teleportRuntime:AbortPrepared(prepared)
end

-- The multiplayer fidelity harness needs repeatable pose isolation without
-- fabricating a new Combat life. A normal Respawn invalidates the exact
-- Movement/Combat life capability by design, so this server-only Studio seam
-- performs only the pose/reset portion while retaining the current binding.
function MovementService.ResetStudioGameplayFidelityPose(
	player: Player,
	spawnIndex: number?
): boolean
	if
		not RunService:IsStudio()
		or game:GetAttribute("Q3EngineGameplayFidelityStatus") ~= "running"
	then
		return false
	end
	local record = records[player]
	local lifeBinding = record and record.lifeBinding
	if
		not record
		or not record.character
		or not record.character.Parent
		or player.Character ~= record.character
		or player:GetAttribute("Q3EngineAlive") ~= true
		or not lifeBinding
		or currentMovementLifeBinding(lifeBinding) == nil
	then
		return false
	end
	-- Requested-index selection does not need entropy. Keep this test-only pose
	-- reset from consuming the production spawn RNG or respawn counter.
	local choice = chooseSpawn(player, record, spawnIndex, 0, false)
	if not choice or #choice.telefragUserIds > 0 then
		return false
	end
	local previousCommand = record.command
	local poseCommand: Movement.Command = {
		forward = 0,
		right = 0,
		upMove = 0,
		pitch = previousCommand.pitch,
		yaw = previousCommand.yaw,
		roll = previousCommand.roll,
		buttons = CommandQuantization.ButtonAttack,
		weaponId = previousCommand.weaponId,
	}
	local poseState = assert(
		Movement.SetViewAngle(Movement.newSpawnState(choice.origin), poseCommand, choice.facing),
		"fidelity pose facing must produce a valid Q3 view angle"
	)
	local genericAngles = assert(
		EntityStateConversionRules.AnglesForLook(choice.facing),
		"fidelity pose facing did not produce generic entity angles"
	)
	if
		records[player] ~= record
		or record.lifeBinding ~= lifeBinding
		or currentMovementLifeBinding(lifeBinding) == nil
	then
		return false
	end
	normalToDeadAuthorityRuntime.Invalidate(record)
	record.state = poseState
	record.entityGenericAngles = genericAngles
	record.playerStateViewAngles = playerStateViewAnglesFromState(poseState)
	record.deadState = nil
	record.deathTransition = nil
	record.firstDeadStepPhase = nil
	applyEntityStateProjection(record, poseState, nil)
	record.spawnReserved = false
	record.spawnIndex = choice.spawnIndex
	record.command = poseCommand
	record.awaitingViewCommand = true
	record.commandQueue = {}
	record.commandQueueHead = 1
	record.lastProcessedSequence = record.lastReceivedSequence
	record.revision += 1
	record.jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState()
	record.pendingTeleportLook = nil
	record.pendingTeleportTriggerId = nil
	record.pendingSpawnLook = choice.facing
	renderCharacter(player, record)
	sendSnapshot(player, record)
	return true
end

function MovementService.ApplyVelocity(
	player: Player,
	velocityDelta: Vector3,
	knockbackSeconds: number?
): boolean
	local record = records[player]
	local state = record and record.state
	if
		not record
		or not state
		or typeof(velocityDelta) ~= "Vector3"
		or not isFinite(velocityDelta.X)
		or not isFinite(velocityDelta.Y)
		or not isFinite(velocityDelta.Z)
		or (knockbackSeconds ~= nil and (not isFinite(knockbackSeconds) or knockbackSeconds < 0))
	then
		return false
	end
	local nextMovementTime = state.movementTime
	local nextTimeKnockback = state.timeKnockback
	-- G_Damage starts TIME_KNOCKBACK only when the shared pm_time is zero. An
	-- active landing or knockback window is never extended by another hit.
	if nextMovementTime <= 0 and knockbackSeconds and knockbackSeconds > 0 then
		nextMovementTime = math.clamp(
			knockbackSeconds,
			Constants.MinimumDamageKnockbackSeconds,
			Constants.MaximumDamageKnockbackSeconds
		)
		nextTimeKnockback = true
	end

	normalToDeadAuthorityRuntime.Invalidate(record)
	record.state = {
		frame = state.frame,
		position = state.position,
		velocity = state.velocity + velocityDelta,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		-- Q3 damage impulses change velocity immediately but leave the current
		-- ground entity intact until the next Pmove ground trace decides whether
		-- the velocity kicks away. Forcing airborne here also creates false
		-- airborne-to-ground landing events for horizontal/downward impulses.
		grounded = state.grounded,
		groundPlane = state.groundPlane,
		groundNormal = state.groundNormal,
		groundSlick = state.groundSlick,
		groundNoDamage = state.groundNoDamage,
		groundMoverId = state.groundMoverId,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
		jumpHeld = state.jumpHeld,
		crouched = state.crouched,
		movementTime = nextMovementTime,
		timeLand = state.timeLand,
		timeKnockback = nextTimeKnockback,
		timeWaterJump = state.timeWaterJump,
		respawned = state.respawned,
	}
	sendSnapshot(player, record)
	return true
end

function MovementService.SetOutOfBoundsHandler(handler: (
	player: Player,
	classification: MapSpatialRules.Classification,
	entityId: string?
) -> boolean)
	assert(outOfBoundsHandler == nil, "MovementService out-of-bounds handler is already configured")
	outOfBoundsHandler = handler
end

function MovementService.SetMovementEnabledPredicate(predicate: (player: Player) -> boolean)
	assert(
		movementEnabledPredicate == nil,
		"MovementService movement-enabled predicate is already configured"
	)
	movementEnabledPredicate = predicate
end

function MovementService.SetLandingHandler(handler: (
	player: Player,
	result: LandingResult,
	contactIndex: number
) -> boolean)
	assert(landingHandler == nil, "MovementService landing handler is already configured")
	landingHandler = handler
end

function MovementService.SetWaterEventHandler(handler: WaterEventHandler)
	assert(waterEventHandler == nil, "MovementService water-event handler is already configured")
	waterEventHandler = handler
end

function MovementService.SetMoverDamageAdapter(adapter: MoverDamageAdapter)
	assert(moverDamageAdapter == nil, "MovementService mover-damage adapter is already configured")
	assert(type(adapter) == "table", "MovementService mover-damage adapter must be a table")
	for _, methodName in
		{
			"Begin",
			"CollectBodies",
			"StageSineCrush",
			"StageDoorDamage",
			"ValidateMoverDeathStageReceipt",
			"IsAlive",
			"ApplyMoverBodies",
			"Seal",
			"Prepare",
			"InspectPreparedMovementDependency",
			"ValidatePreparedMovementDependency",
			"CanApplyPrepared",
			"ApplyPrepared",
			"FlushPrepared",
			"Abort",
		}
	do
		assert(
			type((adapter :: any)[methodName]) == "function",
			string.format("MovementService mover-damage adapter requires %s", methodName)
		)
	end
	moverDamageAdapter = adapter
end

function MovementService.SetMoverParticipantAdapter(adapter: MoverParticipantAdapter)
	assert(
		moverParticipantAdapter == nil,
		"MovementService mover-participant adapter is already configured"
	)
	assert(type(adapter) == "table", "mover-participant adapter must be a table")
	for _, methodName in
		{
			"Collect",
			"ResolveSine",
			"ResolveBlockedDoor",
			"Prepare",
			"CanApply",
			"Apply",
			"Flush",
			"Abort",
		}
	do
		assert(
			type((adapter :: any)[methodName]) == "function",
			string.format("mover-participant adapter requires %s", methodName)
		)
	end
	moverParticipantAdapter = adapter
end

function MovementService.SetMoverBodyQueueAdapter(adapter: MoverBodyQueueAdapter)
	assert(
		moverBodyQueueAdapter == nil,
		"MovementService BodyQueue mover adapter is already configured"
	)
	assert(type(adapter) == "table", "BodyQueue mover adapter must be a table")
	for _, methodName in
		{
			"Collect",
			"ResolveSine",
			"ResolveBlockedDoor",
			"Prepare",
			"CanApply",
			"Apply",
			"Flush",
			"Abort",
		}
	do
		assert(
			type((adapter :: any)[methodName]) == "function",
			string.format("BodyQueue mover adapter requires %s", methodName)
		)
	end
	moverBodyQueueAdapter = adapter
end

function MovementService.GetBodyQueuePhysicsAdapter()
	local runtime = assert(deadRuntime, "dead-body trace runtime is unavailable")
	return table.freeze({
		Trace = function(frame: unknown, origin: Vector3, displacement: Vector3)
			assert(
				AuthoritativeFrameService.GetOpenFrame() == frame,
				"BodyQueue trace received a stale authoritative frame"
			)
			return MovementDeadRuntime.TraceBodyQueue(
				runtime,
				moverRuntime.collisionFrame,
				origin,
				displacement
			)
		end,
		PointContents = function(position: Vector3): number
			return assert(
				MovementService.GetPointContents(position),
				"BodyQueue point-contents authority is unavailable"
			)
		end,
	})
end

function MovementService.SetSpawnTelefragHandler(handler: (
	spawningPlayer: Player,
	victims: { Player },
	lifeBinding: MovementLifeBinding?
) -> boolean)
	assert(spawnTelefragHandler == nil, "MovementService telefrag handler is already configured")
	spawnTelefragHandler = handler
end

function MovementService.SetCommandHandler(handler: CommandHandler)
	assert(commandHandler == nil, "MovementService command handler is already configured")
	commandHandler = handler
end

function MovementService.SetDeadCommandHandler(handler: DeadCommandHandler)
	assert(deadCommandHandler == nil, "MovementService dead-command handler is already configured")
	deadCommandHandler = handler
end

function MovementService.SetPrePmoveCommandHandler(handler: PrePmoveCommandHandler)
	assert(
		prePmoveCommandHandler == nil,
		"MovementService pre-Pmove command handler is already configured"
	)
	prePmoveCommandHandler = handler
end

function MovementService.SetClientTimerHandler(handler: ClientTimerHandler)
	assert(clientTimerHandler == nil, "client timer handler may only be registered once")
	clientTimerHandler = handler
end

function MovementService.SetSimulationFaultHandler(handler: SimulationFaultHandler)
	assert(simulationFaultHandler == nil, "simulation fault handler may only be registered once")
	simulationFaultHandler = handler
end

function MovementService.SetAuthoritativeStepObserver(handler: AuthoritativeStepObserver)
	assert(
		authoritativeStepObserver == nil,
		"MovementService authoritative-step observer is already configured"
	)
	authoritativeStepObserver = handler
end

function MovementService.SetAuthoritativeFrameOwner(ownerValue: unknown)
	assert(
		authoritativeFrameOwner == nil,
		"MovementService authoritative-frame owner is already configured"
	)
	assert(
		AuthoritativeFrameService.ValidateOwner(ownerValue),
		"MovementService requires the exact authoritative-frame owner capability"
	)
	authoritativeFrameOwner = ownerValue :: AuthoritativeFrameService.Owner
end

function MovementService.SetAuthoritativeFrameHandler(handler: AuthoritativeFrameHandler)
	assert(
		authoritativeFrameHandler == nil,
		"MovementService authoritative-frame handler is already configured"
	)
	assert(type(handler) == "function", "authoritative-frame handler must be a function")
	authoritativeFrameHandler = handler
end

function MovementService.SetAuthoritativeFrameBeginHandler(handler: AuthoritativeFrameBeginHandler)
	assert(
		authoritativeFrameBeginHandler == nil,
		"MovementService authoritative-frame begin handler is already configured"
	)
	assert(type(handler) == "function", "authoritative-frame begin handler must be a function")
	authoritativeFrameBeginHandler = handler
end

function MovementService.SetPostClientEndFrameHandler(handler: PostClientEndFrameHandler)
	assert(
		postClientEndFrameHandler == nil,
		"MovementService post-ClientEndFrame handler is already configured"
	)
	assert(type(handler) == "function", "post-ClientEndFrame handler must be a function")
	postClientEndFrameHandler = handler
end

function MovementService.SetClientTriggerFrameHandler(handler: ClientTriggerFrameHandler)
	assert(
		clientTriggerFrameHandler == nil,
		"MovementService client-trigger frame handler is already configured"
	)
	assert(type(handler) == "function", "client-trigger frame handler must be a function")
	clientTriggerFrameHandler = handler
end

function MovementService.SetDoorTriggerFrameHandler(handler: DoorTriggerFrameHandler)
	assert(
		doorTriggerFrameHandler == nil,
		"MovementService door-trigger frame handler is already configured"
	)
	assert(type(handler) == "function", "door-trigger frame handler must be a function")
	doorTriggerFrameHandler = handler
end

function MovementService.SetPreMoverEntityFrameHandler(handler: PreMoverEntityFrameHandler)
	assert(
		preMoverEntityFrameHandler == nil,
		"MovementService pre-mover entity frame handler is already configured"
	)
	assert(type(handler) == "function", "pre-mover entity frame handler must be a function")
	preMoverEntityFrameHandler = handler
end

function MovementService.SetPostMoverDynamicFrameHandler(handler: PostMoverDynamicFrameHandler)
	assert(
		postMoverDynamicFrameHandler == nil,
		"MovementService post-mover dynamic frame handler is already configured"
	)
	assert(type(handler) == "function", "post-mover dynamic frame handler must be a function")
	postMoverDynamicFrameHandler = handler
end

local function isMovementEnabled(player: Player): boolean
	local predicate = movementEnabledPredicate
	return predicate == nil or predicate(player)
end

local function validateCommand(
	record: PlayerRecord,
	payload: unknown,
	receivedServerTime: number
): QueuedCommand?
	local now = os.clock()
	if now - record.rateWindowStart >= 1 then
		record.rateWindowStart = now
		record.rateWindowCount = 0
	end
	record.rateWindowCount += 1
	if record.rateWindowCount > 90 then
		telemetryRuntime:ObserveRateReject()
		return nil
	end
	if not hasExactInputKeys(payload) then
		return nil
	end

	local request = payload :: any
	local sequence = request.sequence
	local revision = request.revision
	local forward = request.forward
	local right = request.right
	local upMove = request.upMove
	local pitch = request.pitch
	local yaw = request.yaw
	local roll = request.roll
	local buttons = request.buttons
	local weaponId = request.weaponId
	local decodedAxes = CommandQuantization.DecodeAxes({
		forward = forward,
		right = right,
		upMove = upMove,
	})
	local packedPitch = CommandQuantization.ValidateAngleBits(pitch)
	local packedYaw = CommandQuantization.ValidateAngleBits(yaw)
	local packedRoll = CommandQuantization.ValidateAngleBits(roll)
	local buttonLevels = CommandQuantization.DecodeButtonBits(buttons)
	local decodedWeaponId = CommandQuantization.ValidateWeaponByte(weaponId)

	if
		not CommandSequence.IsInRange(sequence)
		or (record.lastReceivedSequence ~= -1 and not CommandSequence.IsNewer(
			sequence,
			record.lastReceivedSequence
		))
		or not isFinite(revision)
		or revision % 1 ~= 0
		or revision ~= record.revision
		or decodedAxes == nil
		or packedPitch == nil
		or packedYaw == nil
		or packedRoll == nil
		or buttonLevels == nil
		or decodedWeaponId == nil
	then
		return nil
	end

	if pendingCommandCount(record) >= Constants.MaximumServerCommandBacklog then
		telemetryRuntime:ObserveQueueCapacityReject()
		return nil
	end

	record.lastReceivedSequence = sequence
	return {
		sequence = sequence,
		receivedServerTime = receivedServerTime,
		command = {
			-- Retain q_shared.h's raw usercmd_t domain through authority. Decoding
			-- above is validation only; PM_CmdScale and PM_UpdateViewAngles consume
			-- these exact signed-char and unsigned-short values.
			forward = forward,
			right = right,
			upMove = upMove,
			pitch = packedPitch,
			yaw = packedYaw,
			roll = packedRoll,
			buttons = buttons,
			weaponId = decodedWeaponId,
		},
	}
end

function MovementService.Start(
	worldFolder: Folder,
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain,
	spawnOrigin: Vector3,
	configuredWorldLimits: MapSpatialRules.WorldLimits,
	configuredWaterVolumes: { WorldPointContents.WaterVolume },
	configuredNoDropVolumes: { WorldPointContents.NoDropVolume },
	configuredTriggerDefinitions: { WorldTriggerRules.Definition },
	configuredMoverDefinitions: { MoverPushRules.Definition },
	configuredMoverBinaryPrograms: { MoverBinaryState.Program },
	configuredMoverBinaryPolicies: { MoverBinaryPolicy.Policy },
	configuredMoverPresentationFolder: Folder
)
	assert(
		not simulationFaulted,
		"MovementService cannot restart after a terminal simulation fault"
	)
	assert(heartbeatConnection == nil, "MovementService authoritative Heartbeat is already running")
	assert(not heartbeatArmed, "MovementService authoritative Heartbeat is already armed")
	assert(
		EntitySlotService.IsStarted(),
		"EntitySlotService must reserve clients/body queues before MovementService starts"
	)
	assert(
		EntitySlotService.GetDebugSnapshot().mapSpawnPlanInstalled,
		"EntitySlotService must install the retained map entity plan before MovementService starts"
	)
	assert(
		authoritativeFrameOwner ~= nil
			and AuthoritativeFrameService.ValidateOwner(authoritativeFrameOwner),
		"AuthoritativeFrameService must be configured before MovementService starts"
	)
	local validWorldLimits, worldLimitsError =
		MapSpatialRules.ValidateWorldLimits(configuredWorldLimits)
	assert(validWorldLimits, worldLimitsError or "MovementService world limits are invalid")
	worldLimits = table.freeze({
		bounds = configuredWorldLimits.bounds,
		killVolumes = configuredWorldLimits.killVolumes,
	})
	local validatedTriggerDefinitions, triggerDefinitionsError =
		WorldTriggerRules.ValidateAndOrderDefinitions(configuredTriggerDefinitions)
	assert(
		validatedTriggerDefinitions == configuredTriggerDefinitions
			and WorldTriggerRules.IsCanonicalDefinitions(validatedTriggerDefinitions),
		triggerDefinitionsError or "MovementService trigger definitions are not canonical"
	)
	triggerDefinitions = validatedTriggerDefinitions
	assert(
		PersistentStaticSolidDomain.IsCurrent(staticSolidDomain),
		"MovementService requires a validated persistent static-solid domain"
	)
	assert(
		PlayerClipDomain.IsCurrent(playerClipDomain),
		"MovementService requires a validated movement-only playerclip domain"
	)
	assert(
		configuredMoverPresentationFolder:IsDescendantOf(worldFolder),
		"mover presentation folder must belong to the authoritative world"
	)
	assert(
		configuredMoverPresentationFolder:GetAttribute("Q3EngineMoverPresentationOnly") == true,
		"mover presentation folder is missing its presentation-only boundary"
	)
	local moverDomains, moverDomainsError =
		MapMoverContract.ComposeDomains(configuredMoverDefinitions, configuredMoverBinaryPrograms)
	assert(moverDomains, moverDomainsError or "invalid mover domains")
	local firstMapEntitySourceOrder = EntitySourceOrderRules.FirstWorldSourceOrder
		+ EntitySourceOrderRules.BodyQueueSize
	for _, definition in moverDomains.initialDefinitions do
		assert(
			definition.sourceOrder >= firstMapEntitySourceOrder
				and definition.sourceOrder <= EntitySourceOrderRules.MaximumNormalSourceOrder,
			"live movers must occupy normal world entity slots after the body queue"
		)
		local mapRegistration = EntitySlotService.GetMapRegistration(definition.id)
		assert(
			mapRegistration
				and mapRegistration.kind == "Mover"
				and mapRegistration.registration.sourceOrder == definition.sourceOrder,
			"live mover source order is not owned by the installed map entity plan"
		)
	end
	local validatedMoverDefinitions = moverDomains.legacyDefinitions
	local validatedBinaryPolicies, binaryPoliciesError = MoverBinaryPolicy.ValidateAndOrder(
		moverDomains.binaryPrograms,
		configuredMoverBinaryPolicies
	)
	assert(validatedBinaryPolicies, binaryPoliciesError or "invalid binary mover policies")
	local validatedBinaryPolicyByTeam, binaryPolicyIndexError =
		MoverBinaryPolicy.IndexByTeam(moverDomains.binaryPrograms, validatedBinaryPolicies)
	assert(
		validatedBinaryPolicyByTeam,
		binaryPolicyIndexError or "invalid binary mover policy index"
	)
	local requiresMoverDamageAdapter = false
	for _, definition in validatedMoverDefinitions do
		if definition.trajectory.kind == MoverTrajectory.Kinds.Sine then
			requiresMoverDamageAdapter = true
		end
	end
	for _, policy in validatedBinaryPolicies do
		if policy.blockedBehavior == MoverBinaryPolicy.BlockedBehavior.Door then
			requiresMoverDamageAdapter = true
		end
	end
	assert(
		not requiresMoverDamageAdapter or moverDamageAdapter ~= nil,
		"Sine and binary Door movers require a transactional damage adapter before Start"
	)
	moverRuntime.authoredLegacyDefinitions = validatedMoverDefinitions
	moverRuntime.runtimeLegacyDefinitions = validatedMoverDefinitions
	moverRuntime.binaryPrograms = moverDomains.binaryPrograms
	moverRuntime.binaryPolicies = validatedBinaryPolicies
	moverRuntime.binaryPolicyByTeam = validatedBinaryPolicyByTeam
	if #moverRuntime.binaryPrograms > 0 then
		local binaryRuntime, binaryRuntimeError =
			MoverBinaryState.Create(moverRuntime.binaryPrograms)
		assert(binaryRuntime, binaryRuntimeError or "invalid authoritative binary mover runtime")
		moverRuntime.binaryRuntime = binaryRuntime
		local publishableRuntime, publishableError = MoverBinaryState.InspectPublishableRuntime(
			moverRuntime.binaryPrograms,
			moverRuntime.binaryRuntime
		)
		assert(
			publishableRuntime == moverRuntime.binaryRuntime,
			publishableError or "initial binary mover runtime is not publishable"
		)
	else
		moverRuntime.binaryRuntime = nil
	end
	moverRuntime.definitions = composeRuntimeMoverDefinitions(
		moverRuntime.runtimeLegacyDefinitions,
		moverRuntime.binaryRuntime
	)
	local configuredBinaryTeamIds: { [string]: boolean } = {}
	local configuredBinaryMoverIds: { [string]: boolean } = {}
	for _, program in moverRuntime.binaryPrograms do
		configuredBinaryTeamIds[program.teamId] = true
		configuredBinaryMoverIds[program.id] = true
	end
	moverRuntime.binaryTeamIds = table.freeze(configuredBinaryTeamIds)
	moverRuntime.binaryIds = table.freeze(configuredBinaryMoverIds)
	local configuredLegacyMoverIds: { [string]: boolean } = {}
	for _, definition in moverRuntime.authoredLegacyDefinitions do
		configuredLegacyMoverIds[definition.id] = true
	end
	moverRuntime.legacyIds = table.freeze(configuredLegacyMoverIds)
	moverRuntime.clock = assert(MoverClock.Create(1, 0))
	moverRuntime.collisionFrame =
		assert(MoverCollisionFrame.Build(moverRuntime.definitions, moverRuntime.clock))
	moverRuntime.presentationFolder = configuredMoverPresentationFolder
	moverRuntime.crushTransitionCount = 0
	moverRuntime.crushRemovedCount = 0
	moverRuntime.crushRetainedCount = 0
	moverRuntime.lastCrushMoverId = nil
	moverRuntime.lastCrushBodyId = nil
	moverRuntime.lastCrushClockStep = nil
	moverRuntime.pendingBinaryUses = {}
	moverRuntime.binaryUseTransitionCount = 0
	moverRuntime.lastBinaryUseMoverId = nil
	moverRuntime.lastBinaryUseOutcome = nil
	moverRuntime.lastBinaryUseTimeMilliseconds = nil
	moverRuntime.lastBinaryUseClockStep = nil
	moverRuntime.binaryBlockedCallbackCount = 0
	moverRuntime.binaryBlockedDamageCount = 0
	moverRuntime.binaryBlockedReversalCount = 0
	moverRuntime.binaryBlockedRemovalCount = 0
	moverRuntime.lastBinaryBlockedMoverId = nil
	moverRuntime.lastBinaryBlockedBodyId = nil
	moverRuntime.lastBinaryBlockedTimeMilliseconds = nil
	moverAuthorityGeneration = 0
	activePreparedMoverStep = nil
	moverRuntime.activeDamageToken = nil
	MovementMoverRuntime.SetDeathSourceSession(moverRuntime, nil)
	MovementMoverPresentationRuntime.Render(
		moverRuntime.presentationFolder,
		moverRuntime.collisionFrame.poses
	)
	refreshMoverSnapshotWire()
	local network = sharedRoot:FindFirstChild(RemoteNames.Folder)
	if network and not network:IsA("Folder") then
		error(string.format("%s must be a Folder", RemoteNames.Folder))
	end
	if not network then
		network = Instance.new("Folder")
		network.Name = RemoteNames.Folder
		network.Parent = sharedRoot
	end

	local inputRemote = ensureRemote(network, RemoteNames.InputCommand)
	local snapshotRemote = ensureRemote(network, RemoteNames.MovementSnapshot)
	local remoteFrameRemote = ensureUnreliableRemote(network, RemoteNames.RemoteMovementFrame)
	movementSnapshotRemote = snapshotRemote
	remoteRuntime:SetRemote(remoteFrameRemote)
	spawnPoints = collectSpawnPoints(worldFolder, spawnOrigin)
	rocketArenaSpawnPartition = worldFolder:GetAttribute("Q3EngineRocketArenaSpawnPartition") == true
	local exactSpawnOccupancyAvailable: boolean
	spawnWorldOccupants, exactSpawnOccupancyAvailable =
		WorldOccupancyQuery.CreatePlayerMovement(staticSolidDomain, playerClipDomain)
	assert(
		exactSpawnOccupancyAvailable,
		"Exact world occupancy is unavailable; refusing to start authoritative movement"
	)
	local exactMoverBodyOccupancyAvailable: boolean
	moverBodyWorldOccupants, exactMoverBodyOccupancyAvailable =
		WorldOccupancyQuery.CreateBodyPlayerMovement(staticSolidDomain, playerClipDomain)
	assert(
		exactMoverBodyOccupancyAvailable,
		"Exact arbitrary-body occupancy is unavailable; refusing to start authoritative movers"
	)
	if RunService:IsStudio() and worldFolder:GetAttribute("Q3EngineStudioMoverFixture") ~= nil then
		local fixtureCollision = Instance.new("Folder")
		fixtureCollision.Name = "__StudioMoverCrushCollision"
		fixtureCollision:SetAttribute("Q3EngineSystemFixture", true)
		fixtureCollision.Parent = worldFolder
		moverBodyWorldOccupants, exactMoverBodyOccupancyAvailable =
			WorldOccupancyQuery.CreateBodyFixture(fixtureCollision)
		assert(
			exactMoverBodyOccupancyAvailable,
			"Exact Studio mover fixture occupancy is unavailable"
		)
	end
	local authoritativePointContents, exactPointContentsAvailable = WorldPointContents.CreateBound(
		staticSolidDomain,
		configuredWaterVolumes,
		configuredNoDropVolumes
	)
	assert(
		exactPointContentsAvailable,
		"Exact world point contents are unavailable; refusing to start authoritative movement"
	)
	worldPointContentsQuery = authoritativePointContents
	deadRuntime = MovementDeadRuntime.new(staticSolidDomain, playerClipDomain)
	local queryWorld = spawnWorldOccupants :: WorldOccupancyQuery.QueryFunction
	for _, spawnPoint in spawnPoints do
		assert(
			#queryWorld(spawnPoint.origin, false) == 0,
			string.format("Q3Engine spawn %d intersects world collision", spawnPoint.index)
		)
		local hasAuthoredGroundSupport = false
		-- g_client.c::SelectSpawnPoint and g_team.c::SelectCTFSpawnPoint preserve
		-- authored origins, add 9 source Z units, and may therefore hand
		-- ClientSpawn an airborne point. STEPSIZE is a movement-obstacle limit,
		-- not a spawn-to-floor limit. Keep this Roblox authoring guard bounded to
		-- one standing hull height while admitting the source-authored fall.
		local supportSampleCount =
			math.ceil(Constants.StandingColliderSize.Y / Constants.UnitsToStuds)
		for sampleIndex = 1, supportSampleCount do
			local sampleDistance = sampleIndex * Constants.UnitsToStuds
			if #queryWorld(spawnPoint.origin - Vector3.yAxis * sampleDistance, false) > 0 then
				hasAuthoredGroundSupport = true
				break
			end
		end
		-- Some authored Q3 spawn origins intentionally begin a few source units
		-- above their platform. Certify the immediate landing corridor without
		-- requiring the initial standing hull to already be grounded.
		assert(
			hasAuthoredGroundSupport,
			string.format("Q3Engine spawn %d has no authored ground support", spawnPoint.index)
		)
	end
	local function addPlayer(player: Player)
		if records[player] then
			return
		end
		studioWaterJumpObservations[player] = nil
		-- EntitySlotService observes admission before any gameplay service. Adopt
		-- that server-owned clientNum registration idempotently; a reservation
		-- failure has already denied admission and must not create a partial mover.
		local slotRegistration = EntitySlotService.EnsurePlayerRegistration(player)
		if not slotRegistration then
			return
		end
		local playerWorldOccupants, exactPlayerOccupancyAvailable =
			WorldOccupancyQuery.CreatePlayerMovement(staticSolidDomain, playerClipDomain)
		assert(
			exactPlayerOccupancyAvailable,
			"Exact world occupancy became unavailable while adding a movement player"
		)
		local record: PlayerRecord = {
			registration = slotRegistration,
			recordLineage = table.freeze({}),
			lifeSequence = nil,
			lifeBinding = nil,
			state = nil,
			entityTrajectoryBase = Vector3.zero,
			entityTrajectoryDelta = Vector3.zero,
			entityAngularTrajectoryBase = EntityStateConversionRules.ZeroAngles,
			entityGenericAngles = EntityStateConversionRules.ZeroAngles,
			playerStateViewAngles = EntityStateConversionRules.ZeroAngles,
			deadState = nil,
			deathTransition = nil,
			firstDeadStepPhase = nil,
			command = DEFAULT_COMMAND,
			character = nil,
			commandQueue = {},
			commandQueueHead = 1,
			awaitingViewCommand = false,
			lastReceivedSequence = -1,
			lastProcessedSequence = -1,
			rateWindowStart = os.clock(),
			rateWindowCount = 0,
			revision = 0,
			snapshotSequence = 0,
			respawnCount = 0,
			jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState(),
			pendingTeleportLook = nil,
			pendingTeleportTriggerId = nil,
			pendingSpawnLook = nil,
			spawnReserved = false,
			pendingSpawnTelefragUserIds = nil,
			spawnIndex = nil,
			lastAuthoritativeOrigin = nil,
			moverBodySourceOrder = slotRegistration.sourceOrder,
			moverBodyId = slotRegistration.bodyId,
			worldOccupants = playerWorldOccupants,
			trace = makeTrace(staticSolidDomain, playerClipDomain, player, playerWorldOccupants),
			canOccupy = makeCanOccupy(player, playerWorldOccupants),
			pointContents = authoritativePointContents,
		}
		records[player] = record
		telemetryRuntime:AddPlayer(player.UserId)
		player:SetAttribute("Q3EngineCrouched", false)
		player:SetAttribute("Q3EngineWalking", false)
		player:SetAttribute("Q3EngineWaterLevel", 0)
		player:SetAttribute("Q3EngineWaterType", WorldPointContents.Empty)
		player:SetAttribute("Q3EngineWaterJump", false)

		local function onCharacter(character: Model)
			prepareCharacter(character)
			-- Roblox may signal CharacterAdded before LoadCharacter parents the model.
			-- Q3 ClientSpawn is synchronous, so keep this replacement boundary pending
			-- until the exact Character enters the DataModel instead of permanently
			-- losing its one movement reservation attempt.
			while
				player.Character == character
				and records[player] == record
				and character.Parent == nil
			do
				task.wait()
			end
			if
				player.Character ~= character
				or records[player] ~= record
				or character.Parent == nil
			then
				return
			end
			record.character = character
			resetMovement(player, record, nil)
		end

		player.CharacterAdded:Connect(onCharacter)
		player.CharacterRemoving:Connect(function(character: Model)
			if record.character == character then
				invalidateMovementLifeBinding(record)
				if record.state then
					record.lastAuthoritativeOrigin = record.state.position
				end
				record.character = nil
				record.state = nil
				record.entityTrajectoryBase = Vector3.zero
				record.entityTrajectoryDelta = Vector3.zero
				record.entityAngularTrajectoryBase = EntityStateConversionRules.ZeroAngles
				record.entityGenericAngles = EntityStateConversionRules.ZeroAngles
				record.playerStateViewAngles = EntityStateConversionRules.ZeroAngles
				record.deadState = nil
				record.deathTransition = nil
				record.firstDeadStepPhase = nil
				record.awaitingViewCommand = false
				record.spawnReserved = false
				record.spawnIndex = nil
				player:SetAttribute("Q3EngineCrouched", false)
				player:SetAttribute("Q3EngineWalking", false)
				player:SetAttribute("Q3EngineWaterLevel", 0)
				player:SetAttribute("Q3EngineWaterType", WorldPointContents.Empty)
				player:SetAttribute("Q3EngineWaterJump", false)
			end
		end)
		if player.Character then
			task.defer(onCharacter, player.Character)
		end
	end

	inputRemote.OnServerEvent:Connect(function(player: Player, payload: unknown)
		if simulationFaulted then
			return
		end
		local record = records[player]
		if not record or not isMovementEnabled(player) then
			return
		end

		local receivedServerTime = Workspace:GetServerTimeNow()
		local queued = validateCommand(record, payload, receivedServerTime)
		if queued then
			-- The client can only learn the current revision from a successfully decoded
			-- authoritative snapshot. Because every pending snapshot carries spawnLook,
			-- this is also the acknowledgement that the authored spawn heading arrived.
			record.pendingSpawnLook = nil
			table.insert(record.commandQueue, queued)
			observeCommandBacklog(player, record)
		end
	end)

	Players.PlayerAdded:Connect(addPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local record = records[player]
		if record then
			invalidateMovementLifeBinding(record)
		end
		records[player] = nil
		studioWaterJumpObservations[player] = nil
		telemetryRuntime:RemovePlayer(player.UserId)
	end)
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		if not heartbeatArmed or simulationFaulted then
			return
		end
		local succeeded = xpcall(function()
			telemetryRuntime:ObserveHeartbeat()
			local heartbeatServerTime = Workspace:GetServerTimeNow()
			local accumulated = accumulator + deltaTime
			if accumulated > Constants.MaximumAccumulatedTime then
				telemetryRuntime:AddClampedTime(accumulated - Constants.MaximumAccumulatedTime)
			end
			accumulator = math.min(accumulated, Constants.MaximumAccumulatedTime)
			-- Q3 sv_main.c::SV_Frame drains the complete time residual because the
			-- authoritative server owns its process. In Roblox, an overloaded local
			-- client/server process must yield after a bounded number of fixed steps or
			-- the catch-up work can prevent Heartbeat from ever recovering.
			local heartbeatStepBudget = Constants.FixedStep
				* Constants.MaximumCatchUpStepsPerHeartbeat
			if accumulator > heartbeatStepBudget then
				telemetryRuntime:AddClampedTime(accumulator - heartbeatStepBudget)
				accumulator = heartbeatStepBudget
			end
			telemetryRuntime:ObserveAccumulator(accumulator)
			local stepsThisHeartbeat = 0

			while
				accumulator >= Constants.FixedStep
				and stepsThisHeartbeat < Constants.MaximumCatchUpStepsPerHeartbeat
			do
				local stepCpuStart = os.clock()
				accumulator -= Constants.FixedStep
				local stepClockWindow = assert(
					MoverClock.WindowFor(moverRuntime.clock),
					"authoritative fixed step has no canonical Q3 level-time window"
				)
				local stepLevelTimeMilliseconds = stepClockWindow.toTimeMilliseconds
				-- If Heartbeat catches up multiple fixed steps, assign each step its
				-- corresponding server time instead of giving every sample the same
				-- wall-clock timestamp.
				local stepServerTime = heartbeatServerTime - accumulator
				local nextFrameClock = assert(
					MoverClock.Advance(moverRuntime.clock),
					"authoritative fixed step cannot advance its Q3 frame clock"
				)
				local frameForAuthority, frameBeginError = AuthoritativeFrameService.BeginNext(
					assert(
						authoritativeFrameOwner,
						"authoritative-frame owner disappeared before the fixed step"
					),
					nextFrameClock,
					stepServerTime
				)
				assert(
					frameForAuthority,
					frameBeginError or "authoritative global frame failed to open"
				)
				openAuthoritativeFrame = frameForAuthority
				local publicationSpool = FramePublicationSpool.new(nextFrameClock.step)
				openPublicationSpool = publicationSpool
				local beginAuthoritativeFrame = assert(
					authoritativeFrameBeginHandler,
					"authoritative-frame begin handler is not configured"
				)
				beginAuthoritativeFrame(frameForAuthority)
				stepsThisHeartbeat += 1
				telemetryRuntime:ObserveFixedStep()
				local remoteSnapshotRequested = false
				local steppedPlayers: { [Player]: boolean } = {}
				local snapshotRequestedByPlayer: { [Player]: boolean } = {}
				deferredSnapshotPlayers = {}
				deferredRenderPlayers = {}
				fixedStepTransactionOpen = true
				-- Every Pmove callback in this fixed step closes over this exact immutable
				-- mover frame. Mover authority advances only after all commands/events and
				-- world triggers have consumed the snapshot-time geometry.
				local frameForStep = moverRuntime.collisionFrame

				local playerPhaseCpuStart = os.clock()
				local orderedPlayers = Players:GetPlayers()
				table.sort(orderedPlayers, function(left: Player, rightPlayer: Player)
					local leftRecord = records[left]
					local rightRecord = records[rightPlayer]
					if not leftRecord then
						return false
					elseif not rightRecord then
						return true
					end
					return leftRecord.moverBodySourceOrder < rightRecord.moverBodySourceOrder
				end)

				for _, player in orderedPlayers do
					local record = records[player]
					local state = record and record.state
					if not record or not state then
						continue
					end
					if not isMovementEnabled(player) then
						-- Pausing movement is a Roblox policy gate, not a new usercmd. Keep
						-- the last raw view bits so existing delta_angles remain continuous.
						record.command = {
							forward = 0,
							right = 0,
							upMove = 0,
							pitch = record.command.pitch,
							yaw = record.command.yaw,
							roll = record.command.roll,
							-- Until a fresh command arrives, preserve PMF_RESPAWNED instead of
							-- treating an internal idle fallback as the first released attack.
							buttons = if state.respawned
								then CommandQuantization.ButtonAttack
								else 0,
							weaponId = record.command.weaponId,
						}
						record.commandQueue = {}
						record.commandQueueHead = 1
						record.lastProcessedSequence = record.lastReceivedSequence
						continue
					end

					if record.deadState == nil and handleWorldExit(player, record, state) then
						continue
					end

					local queued = dequeueCommand(record)
					if queued then
						record.command = queued.command
						record.awaitingViewCommand = false
						record.lastProcessedSequence = queued.sequence
					end
					local simulationInputSequence = if not record.awaitingViewCommand
							and record.lastProcessedSequence ~= -1
						then record.lastProcessedSequence
						else nil
					local simulationInputReceivedServerTime = if queued
						then queued.receivedServerTime
						else stepServerTime
					local freshSimulationCommand = queued ~= nil

					local previousState = state
					local stepCommand = if record.awaitingViewCommand and not queued
						then stableViewFallbackCommand(previousState, record.command)
						else record.command
					local currentDeadState = record.deadState
					if currentDeadState then
						local lifeSequence = assert(
							record.lifeSequence,
							"dead Pmove lost its Movement life sequence"
						)
						local nextDeadState, deadEffects, postPmoveCapture, postPmoveCaptureSummary =
							MovementDeadRuntime.Step(
								assert(deadRuntime, "dead-player runtime is unavailable"),
								frameForStep,
								player,
								{
									deadState = currentDeadState,
									command = stepCommand,
									deltaTime = Constants.FixedStep,
									pointContents = record.pointContents,
									movementRevision = record.revision,
									commandSequence = record.lastProcessedSequence,
									lifeSequence = lifeSequence,
									moverClockRevision = moverRuntime.clock.revision,
									moverClockStep = moverRuntime.clock.step,
									moverTimeMilliseconds = MoverClock.TimeForStep(
										moverRuntime.clock.step
									),
								}
							)
						record.deadState = nextDeadState
						record.state = nextDeadState.state
						applyEntityStateProjection(record, nextDeadState.state)
						steppedPlayers[player] = true
						local handleDeadCommand =
							assert(deadCommandHandler, "dead-command handler is not configured")
						handleDeadCommand(
							player,
							deadEffects.command,
							deadEffects.attackPressed,
							deadEffects.useHoldablePressed,
							stepLevelTimeMilliseconds,
							postPmoveCapture,
							postPmoveCaptureSummary,
							nextDeadState.state.velocity
						)
						local handleDeadWaterEvent = waterEventHandler
						if handleDeadWaterEvent then
							for eventIndex, event in deadEffects.waterEvents do
								handleDeadWaterEvent(player, event, eventIndex)
							end
						end
						continue
					end
					local prePmoveData: PrePmoveCommandData? = nil
					local handlePrePmoveCommand = prePmoveCommandHandler
					if simulationInputSequence ~= nil and handlePrePmoveCommand then
						-- ClientThink_real runs CheckGauntletAttack before Pmove. Keep this
						-- hook deliberately narrower than the ordinary post-Pmove weapon
						-- handler so a trusted MASK_SHOT result cannot be retargeted by
						-- movement or by the later ClientEvents landing batch. Fixed-step
						-- Pmove reuses the latest real command between network arrivals, so
						-- held Gauntlet contact must run on that same cadence.
						prePmoveData = handlePrePmoveCommand(
							player,
							simulationInputSequence,
							simulationInputReceivedServerTime,
							previousState,
							stepCommand,
							record.revision,
							stepServerTime,
							stepLevelTimeMilliseconds,
							freshSimulationCommand
						)
					end
					local moverQueries, moverQueriesError =
						MoverTraceComposition.CreatePlayerQueries(
							frameForStep,
							record.trace,
							record.canOccupy,
							record.pointContents
						)
					assert(
						moverQueries,
						moverQueriesError or "failed to bind authoritative mover frame"
					)
					local steppedState, landingContacts, waterEvents = Movement.step(
						previousState,
						stepCommand,
						Constants.FixedStep,
						moverQueries.trace,
						moverQueries.canOccupy,
						moverQueries.pointContents,
						player:GetAttribute("Q3EnginePowerup6Active") == true
					)
					normalToDeadAuthorityRuntime.Invalidate(record)
					record.state = steppedState
					-- ClientThink_real projects playerState to entityState immediately
					-- after Pmove and before predictable events can apply damage/death.
					-- Our fixed clock may advance a newly spawned/teleported player before
					-- Roblox has delivered that revision's first real usercmd. Q3 has no
					-- corresponding ClientThink in that gap, so refresh position/velocity
					-- while retaining the exact cached spawn/TeleportPlayer angular source.
					if not record.awaitingViewCommand or queued then
						record.playerStateViewAngles = playerStateViewAnglesFromState(steppedState)
					end
					applyEntityStateProjection(
						record,
						steppedState,
						if record.awaitingViewCommand and not queued
							then record.entityAngularTrajectoryBase
							else nil
					)
					steppedPlayers[player] = true
					if
						RunService:IsStudio()
						and steppedState.timeWaterJump
						and not previousState.timeWaterJump
					then
						studioWaterJumpObservations[player] = table.freeze({
							frame = steppedState.frame,
							revision = record.revision,
							position = steppedState.position,
							velocity = steppedState.velocity,
							movementTime = steppedState.movementTime,
						})
					end
					local preparedAttack: PreparedAttack? = nil
					local eventBaseRevision = record.revision
					local handleCommand = commandHandler
					if simulationInputSequence ~= nil and handleCommand then
						-- PmoveSingle has already cleared PMF_RESPAWNED for a release
						-- command. PM_Weapon now consumes the same command's repeated
						-- weapon intent before it considers BUTTON_ATTACK. Run this on
						-- every fixed Pmove step backed by a real command; transport gaps
						-- must not freeze the shared integer weapon counter.
						preparedAttack = handleCommand(
							player,
							simulationInputSequence,
							simulationInputReceivedServerTime,
							steppedState,
							record.command,
							record.revision,
							stepServerTime,
							stepLevelTimeMilliseconds,
							stepClockWindow.toTimeMilliseconds
								- stepClockWindow.fromTimeMilliseconds,
							freshSimulationCommand,
							prePmoveData
						)
					end
					-- Q3 drains ordered PM_CrashLand events and then the prepared PM_Weapon
					-- event before G_TouchTriggers can rewrite pose or revision.
					PmoveEventOrder.DrainLandingThenAttack(
						landingContacts,
						function(contactIndex: number, contact: Movement.LandingContact)
							local result = Landing.Evaluate({
								previousOriginY = contact.previousOriginY,
								landedOriginY = contact.landedOriginY,
								previousVelocityY = contact.previousVelocityY,
								gravity = Constants.Gravity,
								crouched = contact.crouched,
								waterLevel = contact.waterLevel,
								noDamageSurface = contact.noDamageSurface,
							})
							local handler = landingHandler
							if handler and result.valid then
								handler(player, result, contactIndex)
							end
						end,
						preparedAttack
					)
					if record.revision ~= eventBaseRevision then
						remoteSnapshotRequested = true
						snapshotRequestedByPlayer[player] = true
					end
					-- PM_WaterEvents is appended after PM_Weapon and drained before
					-- G_TouchTriggers. Direct 0->3 and 3->0 transitions intentionally
					-- carry two ordered events.
					local handleWaterEvent = waterEventHandler
					if handleWaterEvent then
						for eventIndex, event in waterEvents do
							handleWaterEvent(player, event, eventIndex)
						end
					end
					-- Drain the complete predictable-event batch even if falling damage kills
					-- the owner, then prevent a dead traveler from touching world triggers.
					if player:GetAttribute("Q3EngineAlive") ~= true then
						continue
					end
					if handleWorldExit(player, record, record.state :: Movement.State) then
						continue
					end
					-- G_TouchTriggers is part of this client's G_RunClient visit. The
					-- retained map plan allocates team flags and items before authored
					-- jump/teleport/kill triggers, so the external trigger participant
					-- consumes the exact open frame before Movement applies those later
					-- trigger entities. Registered weapon drops are also touched here in
					-- exact source order; dynamic flags remain a later dispatcher migration.
					local handleClientTriggerFrame = assert(
						clientTriggerFrameHandler,
						"client-trigger frame handler is not configured"
					)
					handleClientTriggerFrame(frameForAuthority, player)
					if player:GetAttribute("Q3EngineAlive") ~= true then
						continue
					end
					local triggerOutcome = applyWorldTriggers(player, record)
					remoteSnapshotRequested = remoteSnapshotRequested
						or triggerOutcome.snapshotRequested
					snapshotRequestedByPlayer[player] = triggerOutcome.snapshotRequested
					if player:GetAttribute("Q3EngineAlive") ~= true then
						continue
					end
					-- Door triggers are dynamic G_Spawn entities allocated after the
					-- contiguous map mover tail, so their numeric G_TouchTriggers visits
					-- follow authored map triggers rather than joining that static array.
					local handleDoorTriggerFrame = assert(
						doorTriggerFrameHandler,
						"door-trigger frame handler is not configured"
					)
					handleDoorTriggerFrame(frameForAuthority, player)
					state = record.state :: Movement.State
					-- G_TouchTriggers runs only after the ClientEvents batch. Validate the
					-- discontinuity before the later mover/body transaction can consume it.
					if handleWorldExit(player, record, state) then
						continue
					end
					-- ClientThink_real performs ClientTimerActions only for a surviving
					-- client, after events/triggers/impacts and before later world entities.
					-- Supply the exact integer G_RunFrame interval instead of Heartbeat dt.
					if player:GetAttribute("Q3EngineAlive") == true then
						local handleClientTimer = assert(
							clientTimerHandler,
							"authoritative client timer handler is not configured"
						)
						handleClientTimer(
							player,
							stepClockWindow.toTimeMilliseconds
								- stepClockWindow.fromTimeMilliseconds,
							stepLevelTimeMilliseconds
						)
					end
				end

				-- Stationary retained ET_ITEM entities run their integer think before
				-- the map plan's contiguous mover tail. Registered moving drops run in
				-- the later source-ordered Dispatcher suffix.
				local preMoverPhaseCpuStart = os.clock()
				local handlePreMoverEntities = assert(
					preMoverEntityFrameHandler,
					"pre-mover entity frame handler is not configured"
				)
				handlePreMoverEntities(frameForAuthority)

				-- g_mover.c moves the pusher, transports riders/contacts transactionally,
				-- and rolls a blocked team back before the frame can be linked/rendered.
				-- Keep the same publication barrier: no character, rewind sample, or owner
				-- snapshot above can expose a half-applied mover transaction.
				local moverPhaseCpuStart = os.clock()
				local moverStepReceipt, combatReceipt, participantReceipt, bodyQueueReceipt =
					runAuthoritativeMoverStep(stepServerTime)
				local postMoverPhaseCpuStart = os.clock()
				local movedPlayers = moverStepReceipt.movedPlayers
				if combatReceipt ~= nil then
					local adapter =
						assert(moverDamageAdapter, "prepared mover damage adapter disappeared")
					publicationSpool:Queue(table.freeze({ kind = "MoverCombat" }), function()
						assert(
							adapter.FlushPrepared(combatReceipt) ~= nil,
							"mover Combat publication report is missing"
						)
					end)
				end
				if participantReceipt ~= nil then
					local adapter = assert(
						moverParticipantAdapter,
						"mover participant adapter disappeared before publication"
					)
					publicationSpool:Queue(table.freeze({ kind = "MoverParticipant" }), function()
						assert(
							adapter.Flush(participantReceipt),
							"mover Item participant publication failed"
						)
					end)
				end
				if bodyQueueReceipt ~= nil then
					local adapter = assert(
						moverBodyQueueAdapter,
						"BodyQueue mover adapter disappeared before publication"
					)
					publicationSpool:Queue(table.freeze({ kind = "MoverBodyQueue" }), function()
						assert(
							adapter.Flush(bodyQueueReceipt),
							"BodyQueue mover participant publication failed"
						)
					end)
				end
				publicationSpool:Queue(table.freeze({ kind = "MoverStep" }), function()
					MovementService.PublishMoverStep(moverStepReceipt)
				end)
				fixedStepTransactionOpen = false
				-- Dynamic Projectile and DroppedItem/Event generations have higher world
				-- entity numbers than the retained foundation movers. Run their exact
				-- source-ordered suffix before ClientEndFrame projection/history/snapshots.
				local handleAuthoritativeEntities = assert(
					authoritativeFrameHandler,
					"authoritative-frame entity handler is not configured"
				)
				handleAuthoritativeEntities(frameForAuthority)
				local handlePostMoverDynamics = assert(
					postMoverDynamicFrameHandler,
					"post-mover dynamic frame handler is not configured"
				)
				handlePostMoverDynamics(frameForAuthority)
				for _, player in orderedPlayers do
					local shouldFinalize = steppedPlayers[player] == true
						or movedPlayers[player] == true
						or deferredRenderPlayers[player] == true
						or deferredSnapshotPlayers[player] == true
					if not shouldFinalize then
						continue
					end
					local record = records[player]
					local state = record and record.state
					if not record or not state then
						continue
					end
					local alive = player:GetAttribute("Q3EngineAlive") == true
					if alive and handleWorldExit(player, record, state) then
						continue
					end
					if alive then
						local observer = authoritativeStepObserver
						local shouldObserve = observer ~= nil
							and (steppedPlayers[player] == true or movedPlayers[player] == true)
						publicationSpool:Queue(
							table.freeze({
								kind = "ClientRender",
								userId = player.UserId,
							}),
							function()
								renderCharacter(player, record)
								if shouldObserve then
									(observer :: AuthoritativeStepObserver)(
										player,
										state,
										record.revision,
										stepServerTime
									)
								end
							end
						)
					end
					if
						deferredSnapshotPlayers[player] == true
						or snapshotRequestedByPlayer[player] == true
						or (steppedPlayers[player] == true and state.frame % Constants.SnapshotStepFrames == 0)
						or (
							movedPlayers[player] == true
							and moverRuntime.clock.step % Constants.SnapshotStepFrames == 0
						)
					then
						publicationSpool:Queue(
							table.freeze({
								kind = "MovementSnapshot",
								userId = player.UserId,
							}),
							function()
								sendSnapshot(player, record)
							end
						)
					end
				end
				deferredSnapshotPlayers = {}
				deferredRenderPlayers = {}
				local handlePostClientEndFrame = assert(
					postClientEndFrameHandler,
					"post-ClientEndFrame Match handler is not configured"
				)
				local postClientPublication = handlePostClientEndFrame(frameForAuthority)
				if postClientPublication then
					publicationSpool:Queue(
						table.freeze({ kind = "PostClientMatch" }),
						postClientPublication
					)
				end

				if remoteRuntime:AdvanceStepShouldBroadcast(remoteSnapshotRequested) then
					publicationSpool:Queue(table.freeze({ kind = "MoverBroadcast" }), function()
						remoteRuntime:Broadcast()
					end)
				end
				local closePhaseCpuStart = os.clock()
				local committedFrame, frameCommitError = AuthoritativeFrameService.CommitOpen(
					assert(
						authoritativeFrameOwner,
						"authoritative-frame owner disappeared while closing the fixed step"
					),
					frameForAuthority,
					moverRuntime.clock
				)
				assert(
					committedFrame == frameForAuthority,
					frameCommitError or "authoritative global frame failed to commit"
				)
				openAuthoritativeFrame = nil
				publicationSpool:CloseAndFlush()
				openPublicationSpool = nil
				local stepCpuEnd = os.clock()
				telemetryRuntime:ObserveFixedStepCpu(
					stepCpuEnd - stepCpuStart,
					playerPhaseCpuStart - stepCpuStart,
					preMoverPhaseCpuStart - playerPhaseCpuStart,
					moverPhaseCpuStart - preMoverPhaseCpuStart,
					postMoverPhaseCpuStart - moverPhaseCpuStart,
					closePhaseCpuStart - postMoverPhaseCpuStart,
					stepCpuEnd - closePhaseCpuStart
				)
			end
			telemetryRuntime:ObserveStepsPerHeartbeat(stepsThisHeartbeat)
		end, function(errorValue: unknown)
			if RunService:IsStudio() then
				warn(
					"MovementService Studio diagnostic caught authoritative fixed-step error: "
						.. tostring(errorValue)
				)
			end
			-- Deliberately discard the caught value and stack. Neither is retained in
			-- service state or placed on a replicated surface.
			return nil
		end)
		if not succeeded then
			latchSimulationFault()
		end
	end)
end

function MovementService.ArmAuthoritativeHeartbeat(): (boolean, string?)
	if heartbeatArmed then
		return false, "movement-authoritative-heartbeat-already-armed"
	end
	if heartbeatConnection == nil then
		return false, "movement-authoritative-heartbeat-not-prepared"
	end
	if
		authoritativeFrameHandler == nil
		or authoritativeFrameBeginHandler == nil
		or postClientEndFrameHandler == nil
		or clientTriggerFrameHandler == nil
		or doorTriggerFrameHandler == nil
		or preMoverEntityFrameHandler == nil
		or postMoverDynamicFrameHandler == nil
		or clientTimerHandler == nil
		or simulationFaultHandler == nil
		or authoritativeFrameOwner == nil
		or not AuthoritativeFrameService.ValidateOwner(authoritativeFrameOwner)
	then
		return false, "movement-authoritative-frame-participants-not-ready"
	end
	heartbeatArmed = true
	return true, nil
end

return table.freeze(MovementService)
