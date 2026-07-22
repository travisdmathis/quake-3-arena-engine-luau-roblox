--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-authoritative Roblox translation of Quake III Arena item interaction
behavior from:
  code/game/bg_misc.c (BG_PlayerTouchesItem, BG_CanItemBeGrabbed)
  code/game/g_combat.c (TossClientItems weapon-before-powerup order)
  code/game/g_items.c (Touch_Item, RespawnItem, Add_Ammo, Pickup_Weapon,
    Pickup_Ammo, Pickup_Health, Pickup_Armor, LaunchItem, Drop_Item)
  code/game/g_main.c (ascending entity traversal)
  code/game/g_mover.c (fixed per-pusher entity list)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.

Live death drops use a real provisional EntitySlot registration and lease,
bind the exact prepared Dispatcher `DroppedItem` generation, and apply the
immutable Item root only after both preceding owners return their exact
prebuilt receipts. Presentation follows all three authority swaps.

Live item clocks consume only the exact OPEN AuthoritativeFrame. Client touches
traverse retained map items and registered drops in EntitySlot source order.
Each registered drop runs from the shared dynamic tail with launch-frame delta
zero, exact G_RunItem motion/bounce/think behavior, and strict post-event slot
release. The legacy collection remains only as an empty compatibility cleanup
domain; SpawnDroppedWeapon no longer authors it.

Marker discovery, hook boundaries, deterministic event identities, Roblox
attributes, and network snapshots are original the Roblox Luau port infrastructure.
No retail Quake models, textures, icons, or sounds are used or referenced.

Integration contract:
  ItemService.Start(worldRoot, hooks) discovers BaseParts carrying the
  ArenaItemId attribute (the ArenaPickup CollectionService tag is optional).
  Authored map markers must also carry ArenaMapEntityId matching their exact
  installed Item registration. Generated death-drop presentation markers are
  non-authoritative projections of registered logical drops.
  hooks.GetPlayerState must return canonical server state and position.
  TryGrant* hooks must atomically revalidate and clamp the canonical state;
  returning true consumes the pickup. Clients never submit pickup grants.
]]

--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local EntitySourceOrderRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntitySourceOrderRules"))
local MoverConsequenceRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverConsequenceRules"))
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))
local WorldPointContents =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldPointContents"))
local ItemDefs = require(sharedRoot:WaitForChild("items"):WaitForChild("ItemDefs"))
local DroppedWeaponRules =
	require(sharedRoot:WaitForChild("items"):WaitForChild("DroppedWeaponRules"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local ItemFramePublicationService = require(script.Parent.ItemFramePublicationService)
local MatchService = require(script.Parent.MatchService)
local MoverParticipantCoordinatorService = require(script.Parent.MoverParticipantCoordinatorService)
local MoverParticipantReleaseBrokerService =
	require(script.Parent.MoverParticipantReleaseBrokerService)

local ItemService = {}

type ItemDefinition = ItemDefs.ItemDefinition
export type ItemEventKind = "PickupTaken" | "PickupRespawned"

export type DeathDropRequest = {
	dropId: string,
	matchId: string,
	itemId: string,
	quantity: number,
	position: Vector3,
	velocity: Vector3,
}

export type PreparedMoverDeathDrop = {}
export type MoverDeathDropApplyReceipt = {}

export type PreparedMoverDeathDropSummary = {
	read revision: number,
	read operationOrder: number,
	read dropId: string,
	read bodyId: string,
	read sourceOrder: number,
	read registration: EntitySlotService.Registration,
	read lease: EntitySourceOrderRules.Lease,
	read insertion: MoverConsequenceRules.InsertionDescriptor,
	read participant: MoverItemFlagParticipantRules.Participant,
	read evictedDropId: string?,
	read evictedRegistration: EntitySlotService.Registration?,
	read evictedLease: EntitySourceOrderRules.Lease?,
}

export type MoverDeathDropPublicationReport = {
	read authorityApplied: boolean,
	read attemptedPublicationCount: number,
	read faultCount: number,
	read markerCreated: boolean,
}

-- Opaque owner of the complete death-drop insertion tail. Unlike the lower
-- PreparedMoverDeathDrop capability, this bundle owns the EntitySlot
-- transaction and the prepared Dispatcher batch that precede Item authority.
export type PreparedDeathDropInsertion = {}
export type DeathDropInsertionApplyReceipt = {}
export type PreparedDeathDropBatch = {}
export type DeathDropBatchApplyReceipt = {}

export type PreparedDeathDropInsertionSummary = {
	read operationOrder: number,
	read frame: AuthoritativeFrameService.Frame,
	read frameSummary: AuthoritativeFrameService.Summary,
	read request: DeathDropRequest,
	read itemSummary: PreparedMoverDeathDropSummary,
	read entitySlotSummary: EntitySlotService.PreparedCommitSummary,
	read dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary,
}

export type PreparedDeathDropBatchSummary = {
	read operationOrder: number,
	read frame: AuthoritativeFrameService.Frame,
	read frameSummary: AuthoritativeFrameService.Summary,
	read requests: { DeathDropRequest },
	read itemSummaries: { PreparedMoverDeathDropSummary },
}

export type DeathDropBatchPublicationReport = {
	read authorityApplied: boolean,
	read requestedCount: number,
	read insertedCount: number,
	read attemptedPublicationCount: number,
	read faultCount: number,
	read markerCreatedCount: number,
}

export type PreparedDeathDropInsertionAdapter = {
	read StageSynchronousMover: (
		requestValue: unknown,
		operationOrderValue: unknown
	) -> (MoverItemFlagParticipantRules.Body?, string?),
	read Prepare: (
		requestValue: unknown,
		operationOrderValue: unknown,
		frameValue: unknown,
		frameSummaryValue: unknown
	) -> (PreparedDeathDropInsertion?, PreparedDeathDropInsertionSummary?, string?),
	read InspectPrepared: (preparedValue: unknown) -> PreparedDeathDropInsertionSummary?,
	read ValidatePreparedDependency: (preparedValue: unknown, summaryValue: unknown) -> boolean,
	read CanApplyPrepared: (preparedValue: unknown) -> (boolean, string?),
	read ApplyPrepared: (preparedValue: unknown) -> DeathDropInsertionApplyReceipt,
	read ValidateAppliedDependency: (
		receiptValue: unknown,
		summaryValue: unknown
	) -> (boolean, string?),
	read FlushPrepared: (receiptValue: unknown) -> (MoverDeathDropPublicationReport?, string?),
	read AbortPrepared: (preparedValue: unknown) -> (boolean, string?),
	read PrepareBatch: (
		requestsValue: unknown,
		operationOrderValue: unknown,
		frameValue: unknown,
		frameSummaryValue: unknown
	) -> (PreparedDeathDropBatch?, PreparedDeathDropBatchSummary?, string?),
	read InspectPreparedBatch: (preparedValue: unknown) -> PreparedDeathDropBatchSummary?,
	read ValidatePreparedBatchDependency: (
		preparedValue: unknown,
		summaryValue: unknown
	) -> boolean,
	read CanApplyPreparedBatch: (preparedValue: unknown) -> (boolean, string?),
	read ApplyPreparedBatch: (preparedValue: unknown) -> DeathDropBatchApplyReceipt,
	read ValidateAppliedBatchDependency: (
		receiptValue: unknown,
		summaryValue: unknown
	) -> (boolean, string?),
	read FlushPreparedBatch: (
		receiptValue: unknown
	) -> (DeathDropBatchPublicationReport?, string?),
	read AbortPreparedBatch: (preparedValue: unknown) -> (boolean, string?),
}

export type MoverDeathDropDebugSnapshot = {
	read revision: number,
	read count: number,
	read spawnSequence: number,
	read activePrepared: boolean,
	read presentationMarkerCount: number,
	read dispatcherBindingCount: number,
	read cleanupIntentCount: number,
}
export type MoverDeathDropDebugRecord = {
	read dropId: string,
	read itemId: string,
	read quantity: number,
	read bodyId: string,
	read sourceOrder: number,
	read position: Vector3,
}

export type PlayerItemState = {
	alive: boolean,
	pickupsEnabled: boolean,
	position: Vector3,
	health: number,
	maxHealth: number,
	armor: number,
	ammoByWeapon: { [number]: number },
	holdableId: number,
}

export type GrantContext = {
	pickupId: string,
	itemId: string,
	kind: ItemDefs.ItemKind,
	marker: BasePart,
	definition: ItemDefinition,
	configuredQuantity: number,
	grantAmount: number,
	current: number,
	cap: number,
	weaponId: number?,
	holdableId: number?,
	powerupId: number?,
	levelTimeMilliseconds: number,
	serverTime: number,
}

export type Hooks = {
	GetPlayerState: (player: Player) -> PlayerItemState?,
	TryGrantHealth: (
		player: Player,
		amount: number,
		cap: number,
		context: GrantContext
	) -> boolean,
	TryGrantArmor: (
		player: Player,
		amount: number,
		cap: number,
		context: GrantContext
	) -> boolean,
	TryGrantAmmo: (
		player: Player,
		weaponId: number,
		amount: number,
		cap: number,
		context: GrantContext
	) -> boolean,
	TryGrantWeapon: (
		player: Player,
		weaponId: number,
		ammoAmount: number,
		ammoCap: number,
		context: GrantContext
	) -> boolean,
	TryGrantHoldable: (player: Player, holdableId: number, context: GrantContext) -> boolean,
	TryGrantPowerup: (player: Player, powerupId: number, context: GrantContext) -> boolean,
	CanPickup: ((player: Player, definition: ItemDefinition, marker: BasePart) -> boolean)?,
	UseFullWeaponAmmo: ((
		player: Player,
		definition: ItemDefinition,
		marker: BasePart
	) -> boolean)?,
	ResolveRespawnSeconds: ((
		player: Player,
		definition: ItemDefinition,
		marker: BasePart,
		defaultSeconds: number,
		teamSeconds: number?
	) -> number)?,
	GetMatchId: (() -> string?)?,
	GetPointContents: ((position: Vector3) -> number)?,
}

export type PickupSnapshot = {
	pickupId: string,
	itemId: string,
	kind: ItemDefs.ItemKind,
	active: boolean,
	position: Vector3,
	quantity: number,
	weaponId: number?,
	respawnAt: number?,
	revision: number,
}

export type ItemSnapshot = {
	sequence: number,
	serverTime: number,
	pickups: { PickupSnapshot },
}

export type ItemEvent = {
	sequence: number,
	eventId: string,
	kind: ItemEventKind,
	serverTime: number,
	pickupId: string,
	itemId: string,
	itemKind: ItemDefs.ItemKind,
	position: Vector3,
	quantity: number,
	weaponId: number?,
	playerUserId: number,
	respawnAt: number?,
	revision: number,
}

type PickupRecord = {
	marker: BasePart,
	authorityPosition: Vector3,
	pickupId: string,
	itemId: string,
	definition: ItemDefinition,
	quantity: number,
	respawnOverride: number?,
	enabled: boolean,
	active: boolean,
	respawnAtMilliseconds: number?,
	generation: number,
	revision: number,
	originalTransparency: number,
	originalCanCollide: boolean,
	originalCanTouch: boolean,
	originalCanQuery: boolean,
	originalPickupIdAttribute: unknown,
	connections: { RBXScriptConnection },
	source: "Map" | "DeathDrop",
	mapEntityId: string?,
	mapRegistration: EntitySlotService.MapRegistration?,
	mapSourceOrder: number?,
	matchId: string?,
	velocity: Vector3?,
	settled: boolean,
	expiresAtMilliseconds: number?,
	trajectoryTimeMilliseconds: number?,
	spawnSequence: number,
	claiming: boolean,
}

-- Immutable registered death-drop authority. EntitySlot owns identity,
-- EntityFrameDispatcherService owns source-ordered execution, and this root
-- owns item lifecycle/trajectory data. Presentation Instances never enter it.
type MoverDeathDropRecord = {
	registration: EntitySlotService.Registration,
	lease: EntitySourceOrderRules.Lease,
	dropId: string,
	matchId: string,
	itemId: string,
	definition: ItemDefinition,
	quantity: number,
	participant: MoverItemFlagParticipantRules.Participant,
	spawnTimeMilliseconds: number,
	trajectoryTimeMilliseconds: number,
	eventStartedAtMilliseconds: number?,
	settled: boolean,
	expiresAtMilliseconds: number,
	spawnSequence: number,
	revision: number,
}

type MoverDeathDropAuthority = {
	revision: number,
	recordsById: { [string]: MoverDeathDropRecord },
	order: { MoverDeathDropRecord },
	count: number,
	spawnSequence: number,
}

type MapMoverRecord = {
	pickupId: string,
	itemId: string,
	recordGeneration: number,
	registration: EntitySlotService.Registration,
	participant: MoverItemFlagParticipantRules.Participant,
	eventStartedAtMilliseconds: number?,
}

type MapMoverAuthority = {
	revision: number,
	recordsById: { [string]: MapMoverRecord },
	order: { MapMoverRecord },
}

export type PreparedMoverParticipantUpdate = {}
export type MoverParticipantUpdateReceipt = {}
export type MoverParticipantUpdateAdapter = {
	read Collect: () -> MoverItemFlagParticipantRules.Collection,
	read ResolveSine: (bodyId: string) -> MoverItemFlagParticipantRules.SynchronousCrushEffect,
	read ResolveBlockedDoor: (bodyId: string) -> MoverItemFlagParticipantRules.Transition,
	read Prepare: (finalBodies: unknown) -> (PreparedMoverParticipantUpdate?, string?),
	read CanApply: (prepared: unknown) -> (boolean, string?),
	read Apply: (prepared: unknown) -> MoverParticipantUpdateReceipt,
	read Flush: (receipt: unknown) -> boolean,
	read Abort: (prepared: unknown) -> boolean,
	read BindSharedMutation: (
		prepared: unknown,
		sharedPrepared: MoverParticipantReleaseBrokerService.Prepared
	) -> (boolean, string?),
}
type MoverParticipantUpdateStatus = "Prepared" | "Applied" | "Flushed" | "Aborted"
type MoverParticipantUpdateCapability = {
	status: MoverParticipantUpdateStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	baseAuthority: MoverDeathDropAuthority,
	nextAuthority: MoverDeathDropAuthority,
	baseDispatcherBindings: { [string]: EntityFrameDispatcherService.DynamicBinding },
	nextDispatcherBindings: { [string]: EntityFrameDispatcherService.DynamicBinding },
	changedRecords: { MoverDeathDropRecord },
	removedRecords: { MoverDeathDropRecord },
	baseMapAuthority: MapMoverAuthority,
	nextMapAuthority: MapMoverAuthority,
	changedMapRecords: { MapMoverRecord },
	removedMapRecords: { MapMoverRecord },
	entitySlotToken: unknown?,
	entitySlotPrepared: EntitySlotService.PreparedCommit?,
	entitySlotReceipt: EntitySlotService.CommitReceipt?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt?,
	dispatcherAborted: boolean,
	entitySlotAborted: boolean,
	prepared: PreparedMoverParticipantUpdate,
	receipt: MoverParticipantUpdateReceipt,
	sharedDeathDropPrepareds: { PreparedMoverDeathDrop },
	sharedDeathDropReceipts: { MoverDeathDropApplyReceipt },
	sharedDeathDropFlushIndex: number,
	sharedDeathDropAbortIndex: number,
	sharedCanceledEvictedRecords: { MoverDeathDropRecord },
	sharedDeathDropAttemptedPublicationCount: number,
	sharedDeathDropPublicationFaultCount: number,
	sharedDeathDropMarkerCreatedCount: number,
}

type MoverDeathDropPresentation = {
	dropId: string,
	matchId: string,
	itemId: string,
	quantity: number,
	position: Vector3,
	velocity: Vector3,
	expiresAt: number,
	revision: number,
	evictedDropId: string?,
}

type MoverDeathDropPreparedStatus = "Prepared" | "Applied" | "Aborted"
type MoverDeathDropReceiptStatus = "Pending" | "Applied" | "Flushing" | "Flushed" | "Aborted"

type MoverDeathDropPreparedCapability = {
	status: MoverDeathDropPreparedStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	request: DeathDropRequest,
	stepTimeMilliseconds: number,
	matchLineage: MatchService.MatchLineage,
	entitySlotPrepared: EntitySlotService.PreparedCommit?,
	entitySlotSummary: EntitySlotService.PreparedCommitSummary?,
	entitySlotReceipt: EntitySlotService.CommitReceipt?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary?,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt?,
	baseDispatcherBindings: { [string]: EntityFrameDispatcherService.DynamicBinding },
	nextDispatcherBindings: { [string]: EntityFrameDispatcherService.DynamicBinding }?,
	baseAuthority: MoverDeathDropAuthority,
	nextAuthority: MoverDeathDropAuthority,
	baseServiceEnabled: boolean,
	baseConfigurationRevision: number,
	baseLegacyDeathDropCount: number,
	baseLegacyRecord: PickupRecord?,
	record: MoverDeathDropRecord,
	summary: PreparedMoverDeathDropSummary,
	receipt: MoverDeathDropApplyReceipt,
	presentation: MoverDeathDropPresentation,
	evictedReceipt: MoverDeathDropApplyReceipt?,
	evictedReceiptCapability: MoverDeathDropReceiptCapability?,
	sharedMoverFrame: boolean,
}

type MoverDeathDropReceiptCapability = {
	status: MoverDeathDropReceiptStatus,
	receipt: MoverDeathDropApplyReceipt,
	record: MoverDeathDropRecord,
	presentation: MoverDeathDropPresentation,
}

type DeathDropInsertionStatus =
	"Prepared"
	| "Applied"
	| "Flushing"
	| "Flushed"
	| "Aborting"
	| "Aborted"

type DeathDropInsertionCapability = {
	prepared: PreparedDeathDropInsertion,
	receipt: DeathDropInsertionApplyReceipt,
	status: DeathDropInsertionStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	operationOrder: number,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	request: DeathDropRequest,
	entitySlotToken: EntitySlotService.TransactionToken,
	entitySlotPrepared: EntitySlotService.PreparedCommit,
	entitySlotSummary: EntitySlotService.PreparedCommitSummary,
	entitySlotReceipt: EntitySlotService.CommitReceipt,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch,
	dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt,
	itemPrepared: PreparedMoverDeathDrop,
	itemSummary: PreparedMoverDeathDropSummary,
	itemReceipt: MoverDeathDropApplyReceipt,
	dispatcherBinding: EntityFrameDispatcherService.DynamicBinding,
	summary: PreparedDeathDropInsertionSummary,
	dispatcherAborted: boolean,
	itemAborted: boolean,
	entitySlotAborted: boolean,
}

type DeathDropInsertionPrepareCleanup = {
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	itemPrepared: PreparedMoverDeathDrop?,
	entitySlotToken: EntitySlotService.TransactionToken?,
	itemAborted: boolean,
	dispatcherAborted: boolean,
	entitySlotAborted: boolean,
}

type DeathDropBatchStatus = "Prepared" | "Applied" | "Flushed" | "Aborted"

type DeathDropBatchCapability = {
	prepared: PreparedDeathDropBatch,
	receipt: DeathDropBatchApplyReceipt,
	status: DeathDropBatchStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	operationOrder: number,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	requests: { DeathDropRequest },
	itemPrepareds: { PreparedMoverDeathDrop },
	itemSummaries: { PreparedMoverDeathDropSummary },
	itemParticipantPrepared: PreparedMoverParticipantUpdate,
	itemParticipantCapability: MoverParticipantUpdateCapability,
	expectedAuthority: MoverDeathDropAuthority,
	expectedDispatcherBindings: { [string]: EntityFrameDispatcherService.DynamicBinding },
	coordinatorPrepared: unknown,
	coordinatorReceipt: unknown?,
	summary: PreparedDeathDropBatchSummary,
}

local recordsByMarker: { [BasePart]: PickupRecord } = {}
local recordsById: { [string]: PickupRecord } = {}
local mapRecordsByRegistration: { [EntitySlotService.MapRegistration]: PickupRecord } = {}
local cachedMapRecordsInSourceOrder: { PickupRecord }? = nil
local deathDropRecords: { [BasePart]: PickupRecord } = {}
local deathDropOrder: { PickupRecord } = {}
local generationById: { [string]: number } = {}
local warnedMarkers: { [BasePart]: boolean } = {}
local snapshotRequestTimes: { [Player]: number } = {}
local lastClientTriggerAtMillisecondsByPlayer: { [Player]: number } = {}
local _serviceConnections: { RBXScriptConnection } = {}

local started = false
local serviceEnabled = true
local serviceConfigurationRevision = 0
local worldRoot: Instance?
local serviceHooks: Hooks?
local snapshotRemote: RemoteEvent?
local eventRemote: RemoteEvent?
local snapshotSequence = 0
local eventSequence = 0
local deathDropCount = 0
local deathDropCastParameters: RaycastParams?
local snapshotScheduled = false
local lastHookWarningAt = 0
local lastFrameLevelTimeMilliseconds = 0
local lastFrameServerTimeSeconds = 0
local clientTriggerFrameLevelTimeMilliseconds = -1
local clientTriggerLastSourceOrder = -1
local preMoverFrameLevelTimeMilliseconds = -1
local postMoverFrameLevelTimeMilliseconds = -1
local activePreMoverMapFrameLevelTimeMilliseconds: number? = nil
local activePreMoverMapLastSourceOrder = -1
local PREPARED_MOVER_DROP_PRESENTATION_ATTRIBUTE = "Q3EnginePreparedMoverDropPresentation"
local MAP_ENTITY_ID_ATTRIBUTE = "Q3EngineMapEntityId"

local applyMarkerState: (record: PickupRecord) -> ()
local unregisterMarker: (marker: BasePart, restore: boolean) -> ()

local EMPTY_MOVER_DEATH_DROP_RECORDS: { [string]: MoverDeathDropRecord } = table.freeze({})
local EMPTY_MOVER_DEATH_DROP_ORDER: { MoverDeathDropRecord } = table.freeze({})
local EMPTY_MOVER_DEATH_DROP_DISPATCHER_BINDINGS: {
	[string]: EntityFrameDispatcherService.DynamicBinding,
} =
	table.freeze({})
local moverDeathDropAuthority: MoverDeathDropAuthority = table.freeze({
	revision = 0,
	recordsById = EMPTY_MOVER_DEATH_DROP_RECORDS,
	order = EMPTY_MOVER_DEATH_DROP_ORDER,
	count = 0,
	spawnSequence = 0,
})
local EMPTY_MAP_MOVER_RECORDS: { [string]: MapMoverRecord } = table.freeze({})
local EMPTY_MAP_MOVER_ORDER: { MapMoverRecord } = table.freeze({})
local mapMoverAuthority: MapMoverAuthority = table.freeze({
	revision = 0,
	recordsById = EMPTY_MAP_MOVER_RECORDS,
	order = EMPTY_MAP_MOVER_ORDER,
})
local activePreparedMoverParticipantUpdate: PreparedMoverParticipantUpdate? = nil
local preparedMoverParticipantUpdateCapabilities: {
	[PreparedMoverParticipantUpdate]: MoverParticipantUpdateCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local moverParticipantUpdateReceiptCapabilities: {
	[MoverParticipantUpdateReceipt]: MoverParticipantUpdateCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local activePreparedMoverDeathDrop: PreparedMoverDeathDrop? = nil
local activeSharedMoverDeathDrops: { PreparedMoverDeathDrop } = {}
local activeSharedMoverDeathDropCapabilities: {
	[PreparedMoverDeathDrop]: MoverDeathDropPreparedCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local preparedMoverDeathDropCapabilities: {
	[PreparedMoverDeathDrop]: MoverDeathDropPreparedCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local moverDeathDropReceiptCapabilities: {
	[MoverDeathDropApplyReceipt]: MoverDeathDropReceiptCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local activePreparedDeathDropInsertion: PreparedDeathDropInsertion? = nil
local preparedDeathDropInsertionCapabilities: {
	[PreparedDeathDropInsertion]: DeathDropInsertionCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local deathDropInsertionReceiptCapabilities: {
	[DeathDropInsertionApplyReceipt]: DeathDropInsertionCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local retiredDeathDropInsertionAborts: {
	[PreparedDeathDropInsertion]: PreparedDeathDropInsertionSummary,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local activeDeathDropInsertionPrepareCleanup: DeathDropInsertionPrepareCleanup? = nil
local activePreparedDeathDropBatch: PreparedDeathDropBatch? = nil
local preparedDeathDropBatchCapabilities: {
	[PreparedDeathDropBatch]: DeathDropBatchCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local deathDropBatchReceiptCapabilities: {
	[DeathDropBatchApplyReceipt]: DeathDropBatchCapability,
} = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local moverDeathDropReceiptByDropId: { [string]: MoverDeathDropApplyReceipt } = {}
local moverDeathDropFlushActive = false
local moverDeathDropPresentationMarkers: { [string]: BasePart } = {}
local moverDeathDropDispatcherBindings: {
	[string]: EntityFrameDispatcherService.DynamicBinding,
} =
	EMPTY_MOVER_DEATH_DROP_DISPATCHER_BINDINGS
type MoverDeathDropCleanupReason = "Match" | "NoDrop" | "Cleanup"
local moverDeathDropCleanupIntents: { [string]: MoverDeathDropCleanupReason } = {}
local moverDeathDropClaims: { [string]: boolean } = {}
local cloneMoverDeathDropRecord: (...any) -> MoverDeathDropRecord
local runRegisteredMoverDeathDrop: EntityFrameDispatcherService.DynamicHandler
local scheduleSnapshot: () -> ()
local applyMoverDeathDropPresentation: (record: MoverDeathDropRecord) -> ()

local snapshotSignal = Instance.new("BindableEvent")
snapshotSignal.Name = "ItemSnapshotChanged"
local itemEventSignal = Instance.new("BindableEvent")
itemEventSignal.Name = "ItemEvent"

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function updatePresentationBasis(summary: AuthoritativeFrameService.Summary)
	assert(
		summary.currentTimeMilliseconds >= lastFrameLevelTimeMilliseconds,
		"Item presentation basis regressed"
	)
	lastFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
	lastFrameServerTimeSeconds = summary.currentServerTimeSeconds
end

local function currentPresentationBasis(): (number, number)
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local openSummary = if openFrame then AuthoritativeFrameService.InspectFrame(openFrame) else nil
	if openSummary then
		updatePresentationBasis(openSummary)
		return openSummary.currentTimeMilliseconds, openSummary.currentServerTimeSeconds
	end
	local currentFrame = AuthoritativeFrameService.GetCurrentFrame()
	local currentSummary = if currentFrame
		then AuthoritativeFrameService.InspectCurrentFrame(currentFrame)
		else nil
	if currentSummary then
		updatePresentationBasis(currentSummary)
		return currentSummary.currentTimeMilliseconds, currentSummary.currentServerTimeSeconds
	end
	return lastFrameLevelTimeMilliseconds, lastFrameServerTimeSeconds
end

local function presentationTimeForLevel(levelTimeMilliseconds: number): number
	local basisLevelTime, basisServerTime = currentPresentationBasis()
	return assert(
		MatchFrameRules.PresentationTimeForLevel(
			basisLevelTime,
			basisServerTime,
			levelTimeMilliseconds
		),
		"Item level time could not map to presentation time"
	)
end

local function currentPresentationServerTime(): number
	local _, serverTimeSeconds = currentPresentationBasis()
	return serverTimeSeconds
end

local function durationMilliseconds(seconds: number): number
	return assert(
		MatchFrameRules.DurationMilliseconds(seconds),
		"Item duration must resolve to exact bounded integer milliseconds"
	)
end

local function deadlineMilliseconds(startMilliseconds: number, seconds: number): number
	return assert(
		MatchFrameRules.DeadlineMilliseconds(startMilliseconds, seconds),
		"Item deadline exceeded the authoritative integer clock"
	)
end

local function inspectOpenFrame(
	frameValue: unknown,
	phaseName: string
): AuthoritativeFrameService.Summary
	assert(started, string.format("ItemService must start before %s", phaseName))
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	assert(
		openFrame ~= nil and frameValue == openFrame,
		phaseName .. " requires the exact open frame"
	)
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	assert(summary, phaseName .. " received a stale authoritative frame")
	assert(
		AuthoritativeFrameService.ValidateFrameDependency(frameValue, summary),
		phaseName .. " authoritative frame dependency is invalid"
	)
	assert(
		summary.msec % 1 == 0
			and summary.msec > 0
			and summary.currentTimeMilliseconds - summary.previousTimeMilliseconds
				== summary.msec,
		phaseName .. " received an invalid integer frame interval"
	)
	updatePresentationBasis(summary)
	return summary
end

local function isFiniteVector(value: unknown): boolean
	return typeof(value) == "Vector3"
		and isFinite(value.X)
		and isFinite(value.Y)
		and isFinite(value.Z)
end

local function warnHook(message: string)
	local now = os.clock()
	if now - lastHookWarningAt >= 1 then
		lastHookWarningAt = now
		warn(message)
	end
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("Folder"), string.format("%s must be a Folder", name))
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
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

local function sortedRecords(): { PickupRecord }
	local records: { PickupRecord } = {}
	for _, record in recordsById do
		table.insert(records, record)
	end
	table.sort(records, function(left: PickupRecord, right: PickupRecord): boolean
		return left.pickupId < right.pickupId
	end)
	return records
end

local function invalidateMapRecordOrder()
	cachedMapRecordsInSourceOrder = nil
end

local function mapRecordsInSourceOrder(): { PickupRecord }
	local cached = cachedMapRecordsInSourceOrder
	if cached then
		return cached
	end
	local records: { PickupRecord } = {}
	for mapRegistration, record in mapRecordsByRegistration do
		local mapEntityId = assert(record.mapEntityId, "map pickup lost ArenaMapEntityId")
		local registration = mapRegistration.registration
		assert(
			record.source == "Map"
				and record.mapRegistration == mapRegistration
				and recordsById[record.pickupId] == record
				and mapRegistration.eventId == mapEntityId
				and mapRegistration.kind == "Item"
				and record.mapSourceOrder == registration.sourceOrder
				and EntitySlotService.GetMapRegistration(mapEntityId) == mapRegistration
				and EntitySlotService.GetWorldRegistrationBySourceOrder(
						registration.sourceOrder
					)
					== registration,
			"map pickup EntitySlot binding became stale"
		)
		table.insert(records, record)
	end
	table.sort(records, function(left: PickupRecord, right: PickupRecord): boolean
		local leftOrder = assert(left.mapSourceOrder, "left map pickup lost source order")
		local rightOrder = assert(right.mapSourceOrder, "right map pickup lost source order")
		return leftOrder < rightOrder
	end)
	for index = 2, #records do
		assert(
			records[index - 1].mapSourceOrder ~= records[index].mapSourceOrder,
			"map pickups share one EntitySlot source order"
		)
	end
	table.freeze(records)
	cachedMapRecordsInSourceOrder = records
	return records
end

local function mapParticipantForRecord(
	record: PickupRecord,
	position: Vector3,
	groundMoverId: string?
): MoverItemFlagParticipantRules.Participant
	local registration = assert(record.mapRegistration, "map pickup lost registration").registration
	local participant, participantError = MoverItemFlagParticipantRules.Create({
		binding = {
			kind = "Item",
			bodyId = registration.bodyId,
			itemId = record.itemId,
		},
		body = {
			id = registration.bodyId,
			sourceOrder = registration.sourceOrder,
			position = position,
			size = Vector3.new(3, 3, 3),
			centerOffset = Vector3.zero,
			velocity = Vector3.zero,
			groundMoverId = groundMoverId,
			contents = if record.active then 0x40000000 else 0,
			clipMask = 0x1,
		},
		lifecycle = if record.active then "ActiveLinked" else "HiddenLinked",
		dropped = false,
	})
	return assert(participant, participantError or "map mover participant invalid")
end

local function preparedMoverParticipantUpdateBlocksAuthority(): boolean
	local prepared = activePreparedMoverParticipantUpdate
	if not prepared then
		return false
	end
	for _, capability in moverParticipantUpdateReceiptCapabilities do
		if capability.prepared == prepared then
			return capability.status ~= "Applied"
		end
	end
	return true
end

local function replaceMapMoverRecord(
	record: PickupRecord,
	participantOverride: MoverItemFlagParticipantRules.Participant?,
	eventStartedAtMilliseconds: number?
)
	assert(
		not preparedMoverParticipantUpdateBlocksAuthority(),
		"map Item changed during mover prepare"
	)
	local baseAuthority = mapMoverAuthority
	local previous = baseAuthority.recordsById[record.pickupId]
	local previousParticipant = if previous then previous.participant else nil
	local participant = participantOverride
		or mapParticipantForRecord(
			record,
			if previousParticipant
				then previousParticipant.body.position
				else record.authorityPosition,
			if previousParticipant then previousParticipant.body.groundMoverId else nil
		)
	local nextRecord: MapMoverRecord = table.freeze({
		pickupId = record.pickupId,
		itemId = record.itemId,
		recordGeneration = record.generation,
		registration = assert(record.mapRegistration).registration,
		participant = participant,
		eventStartedAtMilliseconds = eventStartedAtMilliseconds,
	})
	local nextRecordsById = table.clone(baseAuthority.recordsById)
	nextRecordsById[record.pickupId] = nextRecord
	table.freeze(nextRecordsById)
	local nextOrder: { MapMoverRecord } = {}
	for _, current in baseAuthority.order do
		if current.pickupId ~= record.pickupId then
			table.insert(nextOrder, current)
		end
	end
	table.insert(nextOrder, nextRecord)
	table.sort(nextOrder, function(left: MapMoverRecord, right: MapMoverRecord): boolean
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(nextOrder)
	mapMoverAuthority = table.freeze({
		revision = baseAuthority.revision + 1,
		recordsById = nextRecordsById,
		order = nextOrder,
	})
end

local function removeMapMoverRecord(pickupId: string)
	local baseAuthority = mapMoverAuthority
	if baseAuthority.recordsById[pickupId] == nil then
		return
	end
	assert(
		not preparedMoverParticipantUpdateBlocksAuthority(),
		"map Item removed during mover prepare"
	)
	local nextRecordsById = table.clone(baseAuthority.recordsById)
	nextRecordsById[pickupId] = nil
	table.freeze(nextRecordsById)
	local nextOrder: { MapMoverRecord } = {}
	for _, current in baseAuthority.order do
		if current.pickupId ~= pickupId then
			table.insert(nextOrder, current)
		end
	end
	table.freeze(nextOrder)
	mapMoverAuthority = table.freeze({
		revision = baseAuthority.revision + 1,
		recordsById = nextRecordsById,
		order = nextOrder,
	})
end

local function legacyDeathDropsInSpawnOrder(): { PickupRecord }
	local records = table.clone(deathDropOrder)
	table.sort(records, function(left: PickupRecord, right: PickupRecord): boolean
		return left.spawnSequence < right.spawnSequence
	end)
	for index = 2, #records do
		assert(
			records[index - 1].spawnSequence ~= records[index].spawnSequence,
			"legacy death drops share one spawn sequence"
		)
	end
	return records
end

local function registeredDeathDropsInSourceOrder(): { MoverDeathDropRecord }
	local records = table.clone(moverDeathDropAuthority.order)
	table.sort(records, function(left: MoverDeathDropRecord, right: MoverDeathDropRecord): boolean
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	for index, record in records do
		assert(
			moverDeathDropAuthority.recordsById[record.dropId] == record
				and EntitySlotService.GetWorldRegistrationBySourceOrder(
					record.registration.sourceOrder
				) == record.registration
				and moverDeathDropDispatcherBindings[record.dropId] ~= nil,
			"registered death-drop authority became stale"
		)
		if index > 1 then
			assert(
				records[index - 1].registration.sourceOrder ~= record.registration.sourceOrder,
				"registered death drops share one source order"
			)
		end
	end
	return records
end

function ItemService.CollectRegisteredMoverParticipants(): MoverItemFlagParticipantRules.Collection
	assert(started, "ItemService must start before collecting mover participants")
	assert(
		activePreparedMoverParticipantUpdate == nil
			and activePreparedMoverDeathDrop == nil
			and activePreparedDeathDropInsertion == nil
			and activeDeathDropInsertionPrepareCleanup == nil,
		"ItemService mover participant collection crossed an active insertion"
	)
	local participants: { MoverItemFlagParticipantRules.Participant } = {}
	for _, record in mapMoverAuthority.order do
		table.insert(participants, record.participant)
	end
	for _, record in registeredDeathDropsInSourceOrder() do
		table.insert(participants, record.participant)
	end
	for _, prepared in activeSharedMoverDeathDrops do
		local capability = activeSharedMoverDeathDropCapabilities[prepared]
		if capability then
			table.insert(participants, capability.record.participant)
		end
	end
	local collection, collectionError = MoverItemFlagParticipantRules.Collect(participants)
	return assert(collection, collectionError or "registered mover participant collection failed")
end

function ItemService.PrepareRegisteredMoverParticipantUpdate(finalBodiesValue: unknown): (
	PreparedMoverParticipantUpdate?,
	string?
)
	local sharedDeathDropPrepareds = table.clone(activeSharedMoverDeathDrops)
	local latestSharedPrepared = sharedDeathDropPrepareds[#sharedDeathDropPrepareds]
	local latestSharedShadowCapability = if latestSharedPrepared
		then activeSharedMoverDeathDropCapabilities[latestSharedPrepared]
		else nil
	local canceledSharedDeathDropCapabilities: { MoverDeathDropPreparedCapability } = {}
	if
		not started
		or activePreparedMoverParticipantUpdate ~= nil
		or activePreparedMoverDeathDrop ~= nil
		or activePreparedDeathDropInsertion ~= nil
		or activeDeathDropInsertionPrepareCleanup ~= nil
	then
		return nil, "item-mover-participant-owner-unavailable"
	end
	if type(finalBodiesValue) ~= "table" then
		return nil, "item-mover-final-bodies-not-table"
	end
	local finalBodiesById: { [string]: unknown } = {}
	local finalBodyCount = #(finalBodiesValue :: { unknown })
	local observedFinalBodyCount = 0
	for key, body in finalBodiesValue :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > finalBodyCount then
			return nil, "item-mover-final-bodies-not-array"
		end
		observedFinalBodyCount += 1
		if type(body) ~= "table" or type((body :: any).id) ~= "string" then
			return nil, "item-mover-final-body-invalid"
		end
		local bodyId = (body :: any).id :: string
		if finalBodiesById[bodyId] ~= nil then
			return nil, "item-mover-final-body-duplicate"
		end
		finalBodiesById[bodyId] = body
	end
	if observedFinalBodyCount ~= finalBodyCount then
		return nil, "item-mover-final-bodies-not-dense"
	end
	local brokerToken = MoverParticipantReleaseBrokerService.GetActiveToken()
	for index = #sharedDeathDropPrepareds, 1, -1 do
		local sharedPrepared = sharedDeathDropPrepareds[index]
		local sharedCapability = activeSharedMoverDeathDropCapabilities[sharedPrepared]
		if
			sharedCapability
			and finalBodiesById[sharedCapability.record.participant.body.id] == nil
		then
			if not brokerToken then
				return nil, "removed-shared-mover-death-drop-lost-broker"
			end
			local canceled, cancelError = MoverParticipantReleaseBrokerService.CancelAllocation(
				brokerToken,
				sharedCapability.record.registration
			)
			if not canceled then
				return nil, cancelError or "removed-shared-mover-death-drop-cancel-failed"
			end
			if not ItemService.AbortPreparedMoverDeathDrop(sharedPrepared) then
				return nil, "removed-shared-mover-death-drop-item-abort-failed"
			end
			table.insert(canceledSharedDeathDropCapabilities, 1, sharedCapability)
			table.remove(sharedDeathDropPrepareds, index)
		end
	end
	local baseMapAuthority = mapMoverAuthority
	local nextMapRecordsById = table.clone(baseMapAuthority.recordsById)
	local nextMapOrder: { MapMoverRecord } = {}
	local changedMapRecords: { MapMoverRecord } = {}
	local removedMapRecords: { MapMoverRecord } = {}
	for _, record in baseMapAuthority.order do
		local finalBody = finalBodiesById[record.participant.body.id]
		if finalBody == nil then
			nextMapRecordsById[record.pickupId] = nil
			table.insert(removedMapRecords, record)
			continue
		end
		local nextParticipant, participantError =
			MoverItemFlagParticipantRules.ApplyMoverBody(record.participant, finalBody)
		if not nextParticipant then
			return nil, participantError or "map-item-mover-participant-body-invalid"
		end
		local nextRecord = record
		if
			nextParticipant.body.position ~= record.participant.body.position
			or nextParticipant.body.groundMoverId ~= record.participant.body.groundMoverId
		then
			nextRecord = table.freeze({
				pickupId = record.pickupId,
				itemId = record.itemId,
				quantity = record.quantity,
				recordGeneration = record.recordGeneration,
				registration = record.registration,
				participant = nextParticipant,
				eventStartedAtMilliseconds = record.eventStartedAtMilliseconds,
			})
			nextMapRecordsById[record.pickupId] = nextRecord
			table.insert(changedMapRecords, nextRecord)
		end
		table.insert(nextMapOrder, nextRecord)
	end
	table.freeze(nextMapRecordsById)
	table.freeze(nextMapOrder)
	table.freeze(changedMapRecords)
	table.freeze(removedMapRecords)
	local nextMapAuthority: MapMoverAuthority = baseMapAuthority
	if #changedMapRecords > 0 or #removedMapRecords > 0 then
		nextMapAuthority = table.freeze({
			revision = baseMapAuthority.revision + 1,
			recordsById = nextMapRecordsById,
			order = nextMapOrder,
		})
	end
	local baseAuthority = moverDeathDropAuthority
	local workingAuthority = if latestSharedShadowCapability
		then latestSharedShadowCapability.nextAuthority
		else baseAuthority
	local baseDispatcherBindings = moverDeathDropDispatcherBindings
	local nextRecordsById = table.clone(workingAuthority.recordsById)
	local nextOrder: { MoverDeathDropRecord } = {}
	local changedRecords: { MoverDeathDropRecord } = {}
	local removedRecords: { MoverDeathDropRecord } = {}
	for _, record in workingAuthority.order do
		local finalBody = finalBodiesById[record.participant.body.id]
		if finalBody == nil then
			nextRecordsById[record.dropId] = nil
			table.insert(removedRecords, record)
			continue
		end
		local nextParticipant, participantError =
			MoverItemFlagParticipantRules.ApplyMoverBody(record.participant, finalBody)
		if not nextParticipant then
			return nil, participantError or "item-mover-participant-body-invalid"
		end
		local nextRecord = record
		if
			nextParticipant.body.position ~= record.participant.body.position
			or nextParticipant.body.groundMoverId ~= record.participant.body.groundMoverId
		then
			nextRecord = cloneMoverDeathDropRecord(
				record,
				nextParticipant,
				record.trajectoryTimeMilliseconds,
				record.eventStartedAtMilliseconds,
				record.settled
			)
			nextRecordsById[record.dropId] = nextRecord
			table.insert(changedRecords, nextRecord)
		end
		table.insert(nextOrder, nextRecord)
	end
	table.freeze(nextRecordsById)
	table.freeze(nextOrder)
	table.freeze(changedRecords)
	table.freeze(removedRecords)
	local nextAuthority: MoverDeathDropAuthority = workingAuthority
	local nextDispatcherBindings = baseDispatcherBindings
	for _, canceledCapability in canceledSharedDeathDropCapabilities do
		local evictedDropId = canceledCapability.summary.evictedDropId
		if evictedDropId then
			local nextBindings = table.clone(nextDispatcherBindings)
			nextBindings[evictedDropId] = nil
			table.freeze(nextBindings)
			nextDispatcherBindings = nextBindings
		end
	end
	if #changedRecords > 0 or #removedRecords > 0 then
		nextAuthority = {
			revision = workingAuthority.revision + 1,
			recordsById = nextRecordsById,
			order = nextOrder,
			count = workingAuthority.count - #removedRecords,
			spawnSequence = workingAuthority.spawnSequence,
		}
		table.freeze(nextAuthority)
		if #removedRecords > 0 then
			local nextBindings = table.clone(baseDispatcherBindings)
			for _, record in removedRecords do
				nextBindings[record.dropId] = nil
			end
			table.freeze(nextBindings)
			nextDispatcherBindings = nextBindings
		end
	end

	local entitySlotToken: unknown? = nil
	local entitySlotPrepared: EntitySlotService.PreparedCommit? = nil
	local entitySlotReceipt: EntitySlotService.CommitReceipt? = nil
	local dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch? = nil
	local dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt? = nil
	local releaseBrokerToken = MoverParticipantReleaseBrokerService.GetActiveToken()
	if (#removedRecords > 0 or #removedMapRecords > 0) and releaseBrokerToken then
		for _, record in removedMapRecords do
			local staged, stageError = MoverParticipantReleaseBrokerService.StageRelease(
				releaseBrokerToken,
				record.registration,
				nil
			)
			if not staged then
				return nil, stageError or "map-item-shared-release-stage-failed"
			end
		end
		for _, record in removedRecords do
			local canceledProvisional = false
			for _, canceledCapability in canceledSharedDeathDropCapabilities do
				if record.registration == canceledCapability.record.registration then
					canceledProvisional = true
					break
				end
			end
			if canceledProvisional then
				continue
			end
			local binding = baseDispatcherBindings[record.dropId]
			if not binding then
				return nil, "dropped-item-shared-release-binding-missing"
			end
			local staged, stageError = MoverParticipantReleaseBrokerService.StageRelease(
				releaseBrokerToken,
				record.registration,
				binding
			)
			if not staged then
				return nil, stageError or "dropped-item-shared-release-stage-failed"
			end
		end
	elseif #removedRecords > 0 or #removedMapRecords > 0 then
		local frame = AuthoritativeFrameService.GetOpenFrame()
		local summary = if frame then AuthoritativeFrameService.InspectFrame(frame) else nil
		if not frame or not summary then
			return nil, "item-mover-participant-removal-outside-frame"
		end
		local token, beginError = EntitySlotService.Begin(summary.currentTimeMilliseconds)
		if not token then
			return nil, beginError or "item-mover-participant-release-begin-failed"
		end
		entitySlotToken = token
		local operations: { EntityFrameDispatcherService.DynamicOperation } = {}
		for _, record in removedMapRecords do
			if not EntitySlotService.ReleaseWorld(token, record.registration) then
				EntitySlotService.Abort(token)
				return nil, "map-item-mover-participant-release-stage-failed"
			end
		end
		for _, record in removedRecords do
			local binding = baseDispatcherBindings[record.dropId]
			if not binding or not EntitySlotService.ReleaseWorld(token, record.registration) then
				EntitySlotService.Abort(token)
				return nil, "item-mover-participant-release-stage-failed"
			end
			table.insert(operations, {
				kind = "Unbind",
				registration = record.registration,
				binding = binding,
			})
		end
		local preparedChild, prepareError = EntitySlotService.Prepare(token)
		if not preparedChild then
			EntitySlotService.Abort(token)
			return nil, prepareError or "item-mover-participant-release-prepare-failed"
		end
		entitySlotPrepared = preparedChild
		local entitySummary = EntitySlotService.InspectPreparedCommitSummary(preparedChild)
		entitySlotReceipt = EntitySlotService.InspectPreparedCommitReceipt(preparedChild)
		if not entitySummary or not entitySlotReceipt then
			EntitySlotService.Abort(token)
			return nil, "item-mover-participant-release-dependency-missing"
		end
		if #operations > 0 then
			local preparedDispatcher, _dispatcherSummary, dispatcherError =
				EntityFrameDispatcherService.PrepareDynamicBatch(
					preparedChild,
					entitySummary,
					operations
				)
			if not preparedDispatcher then
				EntitySlotService.Abort(token)
				return nil, dispatcherError or "item-mover-participant-unbind-prepare-failed"
			end
			dispatcherPrepared = preparedDispatcher
			dispatcherReceipt =
				EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(preparedDispatcher)
			if not dispatcherReceipt then
				EntityFrameDispatcherService.AbortPreparedDynamicBatch(preparedDispatcher)
				EntitySlotService.Abort(token)
				return nil, "item-mover-participant-unbind-receipt-missing"
			end
		end
	end
	local canceledEvictedRecords: { MoverDeathDropRecord } = {}
	for _, canceledCapability in canceledSharedDeathDropCapabilities do
		local evictedDropId = canceledCapability.summary.evictedDropId
		local evictedRecord = if evictedDropId
			then baseAuthority.recordsById[evictedDropId]
			else nil
		if evictedRecord and not table.find(canceledEvictedRecords, evictedRecord) then
			table.insert(canceledEvictedRecords, evictedRecord)
		end
	end
	table.freeze(sharedDeathDropPrepareds)
	table.freeze(canceledEvictedRecords)
	local prepared: PreparedMoverParticipantUpdate = table.freeze({})
	local receipt: MoverParticipantUpdateReceipt = table.freeze({})
	local capability: MoverParticipantUpdateCapability = {
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		baseAuthority = baseAuthority,
		nextAuthority = nextAuthority,
		baseDispatcherBindings = baseDispatcherBindings,
		nextDispatcherBindings = nextDispatcherBindings,
		changedRecords = changedRecords,
		removedRecords = removedRecords,
		baseMapAuthority = baseMapAuthority,
		nextMapAuthority = nextMapAuthority,
		changedMapRecords = changedMapRecords,
		removedMapRecords = removedMapRecords,
		entitySlotToken = entitySlotToken,
		entitySlotPrepared = entitySlotPrepared,
		entitySlotReceipt = entitySlotReceipt,
		dispatcherPrepared = dispatcherPrepared,
		dispatcherReceipt = dispatcherReceipt,
		dispatcherAborted = dispatcherPrepared == nil,
		entitySlotAborted = entitySlotToken == nil,
		prepared = prepared,
		receipt = receipt,
		sharedDeathDropPrepareds = sharedDeathDropPrepareds,
		sharedDeathDropReceipts = {},
		sharedDeathDropFlushIndex = 1,
		sharedDeathDropAbortIndex = #sharedDeathDropPrepareds,
		sharedCanceledEvictedRecords = canceledEvictedRecords,
		sharedDeathDropAttemptedPublicationCount = 0,
		sharedDeathDropPublicationFaultCount = 0,
		sharedDeathDropMarkerCreatedCount = 0,
	}
	preparedMoverParticipantUpdateCapabilities[prepared] = capability
	moverParticipantUpdateReceiptCapabilities[receipt] = capability
	activePreparedMoverParticipantUpdate = prepared
	return prepared, nil
end

function ItemService.CanApplyPreparedMoverParticipantUpdate(
	preparedValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-item-mover-participant-update"
	end
	local capability =
		preparedMoverParticipantUpdateCapabilities[preparedValue :: PreparedMoverParticipantUpdate]
	if
		not capability
		or capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or activePreparedMoverParticipantUpdate ~= preparedValue
		or moverDeathDropAuthority ~= capability.baseAuthority
		or mapMoverAuthority ~= capability.baseMapAuthority
		or moverDeathDropDispatcherBindings ~= capability.baseDispatcherBindings
		or activePreparedMoverDeathDrop ~= nil
		or activePreparedDeathDropInsertion ~= nil
		or activeDeathDropInsertionPrepareCleanup ~= nil
	then
		return false, "stale-prepared-item-mover-participant-update"
	end
	for _, sharedPrepared in capability.sharedDeathDropPrepareds do
		local dropCanApply, dropError = ItemService.CanApplyPreparedMoverDeathDrop(sharedPrepared)
		if not dropCanApply then
			return false, dropError or "shared-mover-death-drop-preflight-failed"
		end
	end
	if capability.entitySlotPrepared then
		local entityCanApply, entityError =
			EntitySlotService.CanApplyPrepared(capability.entitySlotPrepared)
		if not entityCanApply then
			return false, entityError or "item-mover-participant-release-preflight-failed"
		end
		if capability.dispatcherPrepared then
			local dispatcherCanApply, dispatcherError =
				EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(
					capability.dispatcherPrepared
				)
			if not dispatcherCanApply then
				return false, dispatcherError or "item-mover-participant-unbind-preflight-failed"
			end
		end
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	capability.applyValidated = true
	return true, nil
end

function ItemService.ApplyPreparedMoverParticipantUpdate(
	preparedValue: unknown
): MoverParticipantUpdateReceipt
	local prepared = preparedValue :: PreparedMoverParticipantUpdate
	local capability = assert(
		preparedMoverParticipantUpdateCapabilities[prepared],
		"invalid prepared Item mover participant update"
	)
	assert(
		capability.status == "Prepared"
			and capability.applyValidated
			and capability.preflightPassCount >= 2
			and activePreparedMoverParticipantUpdate == prepared
			and moverDeathDropAuthority == capability.baseAuthority
			and mapMoverAuthority == capability.baseMapAuthority
			and moverDeathDropDispatcherBindings == capability.baseDispatcherBindings,
		"stale prepared Item mover participant update at apply"
	)
	for _, sharedDeathDropPrepared in capability.sharedDeathDropPrepareds do
		local dropCapability = assert(
			preparedMoverDeathDropCapabilities[sharedDeathDropPrepared],
			"shared mover death-drop capability disappeared"
		)
		local dropReceipt = ItemService.ApplyPreparedMoverDeathDrop(
			sharedDeathDropPrepared,
			dropCapability.entitySlotReceipt,
			dropCapability.dispatcherReceipt
		)
		table.insert(capability.sharedDeathDropReceipts, dropReceipt)
		local finalRecord = assert(
			capability.nextAuthority.recordsById[dropCapability.record.dropId],
			"shared mover death-drop final record disappeared"
		)
		local receiptCapability = assert(
			moverDeathDropReceiptCapabilities[dropReceipt],
			"shared mover death-drop receipt capability disappeared"
		)
		receiptCapability.record = finalRecord
	end
	for _, canceledEvictedRecord in capability.sharedCanceledEvictedRecords do
		local evictedReceipt = moverDeathDropReceiptByDropId[canceledEvictedRecord.dropId]
		local evictedReceiptCapability = if evictedReceipt
			then moverDeathDropReceiptCapabilities[evictedReceipt]
			else nil
		if evictedReceipt and evictedReceiptCapability then
			evictedReceiptCapability.status = "Aborted"
			moverDeathDropReceiptCapabilities[evictedReceipt] = nil
			moverDeathDropReceiptByDropId[canceledEvictedRecord.dropId] = nil
		end
		moverDeathDropCleanupIntents[canceledEvictedRecord.dropId] = nil
		moverDeathDropClaims[canceledEvictedRecord.dropId] = nil
	end
	if capability.entitySlotPrepared then
		assert(
			EntitySlotService.ApplyPrepared(capability.entitySlotPrepared)
				== capability.entitySlotReceipt,
			"Item mover participant EntitySlot receipt drifted"
		)
		if capability.dispatcherPrepared then
			assert(
				EntityFrameDispatcherService.ApplyPreparedDynamicBatch(
					capability.dispatcherPrepared
				) == capability.dispatcherReceipt,
				"Item mover participant Dispatcher receipt drifted"
			)
		end
	end
	moverDeathDropAuthority = capability.nextAuthority
	mapMoverAuthority = capability.nextMapAuthority
	moverDeathDropDispatcherBindings = capability.nextDispatcherBindings
	capability.status = "Applied"
	capability.applyValidated = false
	preparedMoverParticipantUpdateCapabilities[prepared] = nil
	-- Authority is committed at Apply. Publication retains the receipt below, but
	-- must not keep the child owner busy through the later dynamic entity suffix:
	-- a lethal projectile can synchronously prepare a weapon/powerup drop there.
	if activePreparedMoverParticipantUpdate == prepared then
		activePreparedMoverParticipantUpdate = nil
	end
	return capability.receipt
end

function ItemService.FlushPreparedMoverParticipantUpdate(receiptValue: unknown): boolean
	if type(receiptValue) ~= "table" then
		return false
	end
	local receipt = receiptValue :: MoverParticipantUpdateReceipt
	local capability = moverParticipantUpdateReceiptCapabilities[receipt]
	if not capability or capability.status ~= "Applied" then
		return false
	end
	while capability.sharedDeathDropFlushIndex <= #capability.sharedDeathDropReceipts do
		local dropReceipt = capability.sharedDeathDropReceipts[capability.sharedDeathDropFlushIndex]
		local report = ItemService.FlushPreparedMoverDeathDrop(dropReceipt)
		if not report then
			return false
		end
		capability.sharedDeathDropAttemptedPublicationCount += report.attemptedPublicationCount
		capability.sharedDeathDropPublicationFaultCount += report.faultCount
		if report.markerCreated then
			capability.sharedDeathDropMarkerCreatedCount += 1
		end
		capability.sharedDeathDropFlushIndex += 1
	end
	capability.status = "Flushed"
	moverParticipantUpdateReceiptCapabilities[receipt] = nil
	-- An older deferred publication must never release a newer prepare.
	if activePreparedMoverParticipantUpdate == capability.prepared then
		activePreparedMoverParticipantUpdate = nil
	end
	for _, record in capability.changedRecords do
		-- A registered drop may have advanced again in the dynamic suffix after
		-- this mover authority was applied. Do not publish its older position over
		-- that newer canonical record.
		if moverDeathDropAuthority.recordsById[record.dropId] == record then
			applyMoverDeathDropPresentation(record)
		end
	end
	for _, record in capability.removedRecords do
		if moverDeathDropAuthority.recordsById[record.dropId] == nil then
			moverDeathDropCleanupIntents[record.dropId] = nil
			moverDeathDropClaims[record.dropId] = nil
			local marker = moverDeathDropPresentationMarkers[record.dropId]
			moverDeathDropPresentationMarkers[record.dropId] = nil
			if marker then
				ItemFramePublicationService.RetirePart(marker)
			end
		end
	end
	for _, canceledEvictedRecord in capability.sharedCanceledEvictedRecords do
		if moverDeathDropAuthority.recordsById[canceledEvictedRecord.dropId] == nil then
			local marker = moverDeathDropPresentationMarkers[canceledEvictedRecord.dropId]
			moverDeathDropPresentationMarkers[canceledEvictedRecord.dropId] = nil
			if marker then
				ItemFramePublicationService.RetirePart(marker)
			end
		end
	end
	for _, moverRecord in capability.changedMapRecords do
		if mapMoverAuthority.recordsById[moverRecord.pickupId] == moverRecord then
			local record = recordsById[moverRecord.pickupId]
			assert(
				record ~= nil
					and record.source == "Map"
					and record.generation == moverRecord.recordGeneration
					and record.mapRegistration ~= nil
					and record.mapRegistration.registration == moverRecord.registration,
				"moved map Item presentation binding drifted"
			)
			record.authorityPosition = moverRecord.participant.body.position
			applyMarkerState(record)
		end
	end
	for _, moverRecord in capability.removedMapRecords do
		if mapMoverAuthority.recordsById[moverRecord.pickupId] == nil then
			local record = recordsById[moverRecord.pickupId]
			assert(
				record ~= nil
					and record.source == "Map"
					and record.generation == moverRecord.recordGeneration,
				"removed map Item presentation binding drifted"
			)
			local marker = record.marker
			unregisterMarker(marker, false)
			ItemFramePublicationService.RetirePart(marker)
		end
	end
	if
		#capability.changedRecords > 0
		or #capability.removedRecords > 0
		or #capability.changedMapRecords > 0
		or #capability.removedMapRecords > 0
	then
		scheduleSnapshot()
	end
	return true
end

function ItemService.AbortPreparedMoverParticipantUpdate(preparedValue: unknown): boolean
	if type(preparedValue) ~= "table" then
		return false
	end
	local prepared = preparedValue :: PreparedMoverParticipantUpdate
	local capability = preparedMoverParticipantUpdateCapabilities[prepared]
	if
		not capability
		or capability.status ~= "Prepared"
		or activePreparedMoverParticipantUpdate ~= prepared
	then
		return false
	end
	while capability.sharedDeathDropAbortIndex >= 1 do
		local sharedPrepared =
			capability.sharedDeathDropPrepareds[capability.sharedDeathDropAbortIndex]
		if not ItemService.AbortPreparedMoverDeathDrop(sharedPrepared) then
			return false
		end
		capability.sharedDeathDropAbortIndex -= 1
	end
	if not capability.dispatcherAborted then
		if
			not EntityFrameDispatcherService.AbortPreparedDynamicBatch(
				assert(capability.dispatcherPrepared, "dispatcher prepare disappeared")
			)
		then
			return false
		end
		capability.dispatcherAborted = true
	end
	if not capability.entitySlotAborted then
		if
			not EntitySlotService.Abort(
				assert(capability.entitySlotToken, "EntitySlot token disappeared")
			)
		then
			return false
		end
		capability.entitySlotAborted = true
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	preparedMoverParticipantUpdateCapabilities[prepared] = nil
	moverParticipantUpdateReceiptCapabilities[capability.receipt] = nil
	activePreparedMoverParticipantUpdate = nil
	return true
end

local function registeredParticipantForBodyId(
	bodyId: string
): MoverItemFlagParticipantRules.Participant
	for _, record in mapMoverAuthority.order do
		if record.participant.body.id == bodyId then
			return record.participant
		end
	end
	for _, record in moverDeathDropAuthority.order do
		if record.participant.body.id == bodyId then
			return record.participant
		end
	end
	for _, prepared in activeSharedMoverDeathDrops do
		local sharedCapability = activeSharedMoverDeathDropCapabilities[prepared]
		if sharedCapability and sharedCapability.record.participant.body.id == bodyId then
			return sharedCapability.record.participant
		end
	end
	error("registered Item mover participant body is stale")
end

function ItemService.ResolveRegisteredMoverSine(
	bodyId: string
): MoverItemFlagParticipantRules.SynchronousCrushEffect
	return assert(
		MoverItemFlagParticipantRules.ResolveSineCrush(registeredParticipantForBodyId(bodyId)),
		"registered Item Sine consequence failed"
	)
end

function ItemService.ResolveRegisteredMoverBlockedDoor(
	bodyId: string
): MoverItemFlagParticipantRules.Transition
	return assert(
		MoverItemFlagParticipantRules.ResolveBlockedDoor(registeredParticipantForBodyId(bodyId)),
		"registered Item Door consequence failed"
	)
end

function ItemService.BindPreparedMoverParticipantSharedMutation(
	preparedValue: unknown,
	sharedPreparedValue: MoverParticipantReleaseBrokerService.Prepared
): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedMoverParticipantUpdateCapabilities[preparedValue :: PreparedMoverParticipantUpdate]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-prepared-item-mover-participant-update"
	end
	if #capability.sharedDeathDropPrepareds == 0 then
		return true, nil
	end
	local entityPrepared, entitySummary =
		MoverParticipantReleaseBrokerService.InspectPreparedEntitySlotDependency(
			sharedPreparedValue
		)
	if not entityPrepared or not entitySummary then
		return false, "shared-mover-death-drop-entity-dependency-bind-failed"
	end
	local dispatcherPrepared, dispatcherSummary =
		MoverParticipantReleaseBrokerService.InspectPreparedDispatcherDependency(
			sharedPreparedValue
		)
	if not dispatcherPrepared or not dispatcherSummary then
		return false, "shared-mover-death-drop-dispatcher-dependency-bind-failed"
	end
	local bindingShadow = capability.baseDispatcherBindings
	for _, deathDropPrepared in capability.sharedDeathDropPrepareds do
		local deathDropCapability = preparedMoverDeathDropCapabilities[deathDropPrepared]
		if not deathDropCapability then
			return false, "shared-mover-death-drop-capability-missing"
		end
		deathDropCapability.baseDispatcherBindings = bindingShadow
		if
			not ItemService.BindPreparedMoverDeathDropEntitySlotDependency(
				deathDropPrepared,
				entityPrepared,
				entitySummary
			)
		then
			return false, "shared-mover-death-drop-entity-dependency-bind-failed"
		end
		if
			not ItemService.BindPreparedMoverDeathDropDispatcherDependency(
				deathDropPrepared,
				dispatcherPrepared,
				dispatcherSummary
			) or not deathDropCapability.nextDispatcherBindings
		then
			return false, "shared-mover-death-drop-dispatcher-dependency-bind-failed"
		end
		bindingShadow = deathDropCapability.nextDispatcherBindings
	end
	local finalBindings = table.clone(bindingShadow)
	for _, record in capability.removedRecords do
		finalBindings[record.dropId] = nil
	end
	for _, record in capability.sharedCanceledEvictedRecords do
		finalBindings[record.dropId] = nil
	end
	table.freeze(finalBindings)
	capability.nextDispatcherBindings = finalBindings
	return true, nil
end

local moverParticipantUpdateAdapter: MoverParticipantUpdateAdapter = table.freeze({
	Collect = ItemService.CollectRegisteredMoverParticipants,
	ResolveSine = ItemService.ResolveRegisteredMoverSine,
	ResolveBlockedDoor = ItemService.ResolveRegisteredMoverBlockedDoor,
	Prepare = ItemService.PrepareRegisteredMoverParticipantUpdate,
	CanApply = ItemService.CanApplyPreparedMoverParticipantUpdate,
	Apply = ItemService.ApplyPreparedMoverParticipantUpdate,
	Flush = ItemService.FlushPreparedMoverParticipantUpdate,
	Abort = ItemService.AbortPreparedMoverParticipantUpdate,
	BindSharedMutation = ItemService.BindPreparedMoverParticipantSharedMutation,
})

function ItemService.GetMoverParticipantUpdateAdapter(): MoverParticipantUpdateAdapter
	return moverParticipantUpdateAdapter
end

local function moverDeathDropForRegistration(
	registration: EntitySlotService.Registration
): MoverDeathDropRecord?
	local found: MoverDeathDropRecord? = nil
	for _, record in moverDeathDropAuthority.order do
		if record.registration.sourceOrder == registration.sourceOrder then
			if record.registration ~= registration or found ~= nil then
				return nil
			end
			found = record
		elseif record.registration == registration then
			return nil
		end
	end
	return found
end

cloneMoverDeathDropRecord = function(
	record: MoverDeathDropRecord,
	participant: MoverItemFlagParticipantRules.Participant,
	trajectoryTimeMilliseconds: number,
	eventStartedAtMilliseconds: number?,
	settled: boolean
): MoverDeathDropRecord
	local nextRecord: MoverDeathDropRecord = {
		registration = record.registration,
		lease = record.lease,
		dropId = record.dropId,
		matchId = record.matchId,
		itemId = record.itemId,
		definition = record.definition,
		quantity = record.quantity,
		participant = participant,
		spawnTimeMilliseconds = record.spawnTimeMilliseconds,
		trajectoryTimeMilliseconds = trajectoryTimeMilliseconds,
		eventStartedAtMilliseconds = eventStartedAtMilliseconds,
		settled = settled,
		expiresAtMilliseconds = record.expiresAtMilliseconds,
		spawnSequence = record.spawnSequence,
		revision = record.revision + 1,
	}
	table.freeze(nextRecord)
	return nextRecord
end

local function replaceMoverDeathDropRecord(
	currentRecord: MoverDeathDropRecord,
	nextRecord: MoverDeathDropRecord
)
	local baseAuthority = moverDeathDropAuthority
	assert(
		baseAuthority.recordsById[currentRecord.dropId] == currentRecord
			and nextRecord.dropId == currentRecord.dropId
			and nextRecord.registration == currentRecord.registration,
		"registered death-drop replacement became stale"
	)
	local nextRecordsById = table.clone(baseAuthority.recordsById)
	local nextOrder = table.clone(baseAuthority.order)
	local orderIndex = table.find(nextOrder, currentRecord)
	assert(orderIndex ~= nil, "registered death-drop order lost its exact record")
	nextRecordsById[currentRecord.dropId] = nextRecord
	nextOrder[orderIndex] = nextRecord
	table.freeze(nextRecordsById)
	table.freeze(nextOrder)
	local nextAuthority: MoverDeathDropAuthority = {
		revision = baseAuthority.revision + 1,
		recordsById = nextRecordsById,
		order = nextOrder,
		count = baseAuthority.count,
		spawnSequence = baseAuthority.spawnSequence,
	}
	table.freeze(nextAuthority)
	moverDeathDropAuthority = nextAuthority
end

local function removeRecordFromList(records: { PickupRecord }, target: PickupRecord)
	local index = table.find(records, target)
	if index then
		table.remove(records, index)
	end
end

local function makePickupSnapshot(record: PickupRecord): PickupSnapshot
	return {
		pickupId = record.pickupId,
		itemId = record.itemId,
		kind = record.definition.kind,
		active = serviceEnabled and record.enabled and record.active,
		position = record.authorityPosition,
		quantity = record.quantity,
		weaponId = record.definition.weaponId,
		respawnAt = if record.respawnAtMilliseconds
			then presentationTimeForLevel(record.respawnAtMilliseconds)
			else nil,
		revision = record.revision,
	}
end

local function makeMoverDeathDropSnapshot(record: MoverDeathDropRecord): PickupSnapshot
	return {
		pickupId = record.dropId,
		itemId = record.itemId,
		kind = record.definition.kind,
		active = serviceEnabled
			and record.participant.lifecycle == MoverItemFlagParticipantRules.Lifecycle.ActiveLinked
			and moverDeathDropCleanupIntents[record.dropId] == nil,
		position = record.participant.body.position,
		quantity = record.quantity,
		weaponId = record.definition.weaponId,
		respawnAt = nil,
		revision = record.revision,
	}
end

local function buildSnapshot(): ItemSnapshot
	local pickups: { PickupSnapshot } = {}
	for _, record in sortedRecords() do
		table.insert(pickups, makePickupSnapshot(record))
	end
	for _, record in moverDeathDropAuthority.order do
		table.insert(pickups, makeMoverDeathDropSnapshot(record))
	end
	table.sort(pickups, function(left: PickupSnapshot, right: PickupSnapshot): boolean
		return left.pickupId < right.pickupId
	end)
	return {
		sequence = snapshotSequence,
		serverTime = currentPresentationServerTime(),
		pickups = pickups,
	}
end

local function publishSnapshot()
	snapshotScheduled = false
	snapshotSequence += 1
	local snapshot = ItemFramePublicationService.Snapshot(buildSnapshot()) :: ItemSnapshot
	ItemFramePublicationService.Queue(function()
		snapshotSignal:Fire(snapshot)
	end)
	local remote = snapshotRemote
	if remote then
		ItemFramePublicationService.Queue(function()
			remote:FireAllClients(snapshot)
		end)
	end
end

scheduleSnapshot = function()
	if snapshotScheduled or not started then
		return
	end
	snapshotScheduled = true
	if ItemFramePublicationService.IsOpen() then
		return
	end
	task.defer(function()
		if snapshotScheduled and started then
			publishSnapshot()
		end
	end)
end

local function sendSnapshot(player: Player)
	local remote = snapshotRemote
	if remote and player.Parent == Players then
		local snapshot = ItemFramePublicationService.Snapshot(buildSnapshot()) :: ItemSnapshot
		ItemFramePublicationService.Queue(function()
			if player.Parent == Players then
				remote:FireClient(player, snapshot)
			end
		end)
	end
end

local function emitItemEvent(
	record: PickupRecord,
	kind: ItemEventKind,
	player: Player?,
	quantity: number,
	summary: AuthoritativeFrameService.Summary
)
	eventSequence += 1
	local event = ItemFramePublicationService.Snapshot({
		sequence = eventSequence,
		eventId = string.format(
			"item:%s:%d:%d:%s",
			record.pickupId,
			record.generation,
			record.revision,
			kind
		),
		kind = kind,
		serverTime = summary.currentServerTimeSeconds,
		pickupId = record.pickupId,
		itemId = record.itemId,
		itemKind = record.definition.kind,
		position = record.authorityPosition,
		quantity = quantity,
		weaponId = record.definition.weaponId,
		playerUserId = if player then player.UserId else 0,
		respawnAt = if record.respawnAtMilliseconds
			then presentationTimeForLevel(record.respawnAtMilliseconds)
			else nil,
		revision = record.revision,
	}) :: ItemEvent
	ItemFramePublicationService.Queue(function()
		itemEventSignal:Fire(event)
	end)
	local remote = eventRemote
	if remote then
		ItemFramePublicationService.Queue(function()
			remote:FireAllClients(event)
		end)
	end
end

local function emitMoverDeathDropTakenEvent(
	record: MoverDeathDropRecord,
	player: Player,
	quantity: number,
	summary: AuthoritativeFrameService.Summary
)
	eventSequence += 1
	local event = ItemFramePublicationService.Snapshot({
		sequence = eventSequence,
		eventId = string.format(
			"item:%s:%d:%d:PickupTaken",
			record.dropId,
			record.spawnSequence,
			record.revision
		),
		kind = "PickupTaken",
		serverTime = summary.currentServerTimeSeconds,
		pickupId = record.dropId,
		itemId = record.itemId,
		itemKind = record.definition.kind,
		position = record.participant.body.position,
		quantity = quantity,
		weaponId = record.definition.weaponId,
		playerUserId = player.UserId,
		respawnAt = nil,
		revision = record.revision,
	}) :: ItemEvent
	ItemFramePublicationService.Queue(function()
		itemEventSignal:Fire(event)
	end)
	local remote = eventRemote
	if remote then
		ItemFramePublicationService.Queue(function()
			remote:FireAllClients(event)
		end)
	end
end

applyMoverDeathDropPresentation = function(record: MoverDeathDropRecord)
	local marker = moverDeathDropPresentationMarkers[record.dropId]
	if not marker then
		return
	end
	local visible = serviceEnabled
		and record.participant.lifecycle == MoverItemFlagParticipantRules.Lifecycle.ActiveLinked
		and moverDeathDropCleanupIntents[record.dropId] == nil
	local position = record.participant.body.position
	local revision = record.revision
	ItemFramePublicationService.Queue(function()
		marker.Position = position
		marker.Transparency = if visible then 0 else 1
		marker.CanCollide = false
		marker.CanTouch = false
		marker.CanQuery = false
		marker:SetAttribute(ItemDefs.Attributes.Active, visible)
		marker:SetAttribute(ItemDefs.Attributes.Revision, revision)
	end)
end

local function isWithinWorldRoot(instance: Instance): boolean
	local root = worldRoot
	return root ~= nil and (instance == root or instance:IsDescendantOf(root))
end

local function generatedPickupId(marker: BasePart, itemId: string): string
	local position = marker.Position
	return string.format("auto:%s:%.3f:%.3f:%.3f", itemId, position.X, position.Y, position.Z)
end

local function readPickupId(marker: BasePart, itemId: string): string?
	local value = marker:GetAttribute(ItemDefs.Attributes.PickupId)
	if value == nil then
		return generatedPickupId(marker, itemId)
	end
	if type(value) ~= "string" or value == "" or #value > 160 then
		return nil
	end
	return value
end

local function readQuantity(marker: BasePart, definition: ItemDefinition): number
	local value = marker:GetAttribute(ItemDefs.Attributes.Quantity)
	if value == nil then
		return definition.quantity
	end
	if isFinite(value) and value % 1 == 0 and value > 0 and value <= 10_000 then
		return value
	end
	warn(
		string.format(
			"Ignoring invalid %s on %s",
			ItemDefs.Attributes.Quantity,
			marker:GetFullName()
		)
	)
	return definition.quantity
end

local function readRespawnOverride(marker: BasePart): number?
	local value = marker:GetAttribute(ItemDefs.Attributes.RespawnSeconds)
	if value == nil or value == 0 then
		return nil
	end
	if isFinite(value) and (value == -1 or value >= 1) then
		return value
	end
	warn(
		string.format(
			"Ignoring invalid %s on %s",
			ItemDefs.Attributes.RespawnSeconds,
			marker:GetFullName()
		)
	)
	return nil
end

applyMarkerState = function(record: PickupRecord)
	local marker = record.marker
	local visible = serviceEnabled and record.enabled and record.active
	local position = record.authorityPosition
	local transparency = if visible then record.originalTransparency else 1
	local canTouch = if visible then record.originalCanTouch else false
	local canQuery = if visible then record.originalCanQuery else false
	local pickupId = record.pickupId
	local kind = record.definition.kind
	local revision = record.revision
	local respawnAt = if record.respawnAtMilliseconds
		then presentationTimeForLevel(record.respawnAtMilliseconds)
		else nil
	ItemFramePublicationService.Queue(function()
		marker.Position = position
		marker.Transparency = transparency
		marker.CanCollide = false
		marker.CanTouch = canTouch
		marker.CanQuery = canQuery
		marker:SetAttribute(ItemDefs.Attributes.PickupId, pickupId)
		marker:SetAttribute(ItemDefs.Attributes.Kind, kind)
		marker:SetAttribute(ItemDefs.Attributes.Active, visible)
		marker:SetAttribute(ItemDefs.Attributes.Revision, revision)
		marker:SetAttribute(ItemDefs.Attributes.RespawnAt, respawnAt)
	end)
end

local function restoreMarker(record: PickupRecord)
	local marker = record.marker
	if not marker.Parent then
		return
	end
	local transparency = record.originalTransparency
	local canCollide = record.originalCanCollide
	local canTouch = record.originalCanTouch
	local canQuery = record.originalCanQuery
	local pickupId = record.originalPickupIdAttribute
	ItemFramePublicationService.Queue(function()
		marker.Transparency = transparency
		marker.CanCollide = canCollide
		marker.CanTouch = canTouch
		marker.CanQuery = canQuery
		marker:SetAttribute(ItemDefs.Attributes.PickupId, pickupId)
		marker:SetAttribute(ItemDefs.Attributes.Kind, nil)
		marker:SetAttribute(ItemDefs.Attributes.Active, nil)
		marker:SetAttribute(ItemDefs.Attributes.Revision, nil)
		marker:SetAttribute(ItemDefs.Attributes.RespawnAt, nil)
	end)
end

unregisterMarker = function(marker: BasePart, restore: boolean)
	local record = recordsByMarker[marker]
	if not record then
		return
	end
	if record.source == "Map" then
		removeMapMoverRecord(record.pickupId)
		local mapRegistration = record.mapRegistration
		if mapRegistration and mapRecordsByRegistration[mapRegistration] == record then
			mapRecordsByRegistration[mapRegistration] = nil
			invalidateMapRecordOrder()
		end
	end

	recordsByMarker[marker] = nil
	if recordsById[record.pickupId] == record then
		recordsById[record.pickupId] = nil
	end
	if deathDropRecords[marker] == record then
		deathDropRecords[marker] = nil
		deathDropCount = math.max(deathDropCount - 1, 0)
		removeRecordFromList(deathDropOrder, record)
		generationById[record.pickupId] = nil
	end
	for _, connection in record.connections do
		connection:Disconnect()
	end
	table.clear(record.connections)
	if restore then
		restoreMarker(record)
	end
	scheduleSnapshot()
end

local function destroyDeathDrop(record: PickupRecord)
	if record.source ~= "DeathDrop" then
		return
	end
	local marker = record.marker
	unregisterMarker(marker, false)
	ItemFramePublicationService.RetirePart(marker)
end

local function clearDeathDrops()
	while #deathDropOrder > 0 do
		destroyDeathDrop(deathDropOrder[#deathDropOrder])
	end
	scheduleSnapshot()
end

local tryRegisterMarker: (marker: BasePart, dynamicDeathDrop: boolean?) -> ()

local function rejectAuthoredMarker(marker: BasePart, message: string)
	if warnedMarkers[marker] then
		return
	end
	warnedMarkers[marker] = true
	warn(string.format("Ignoring pickup %s: %s", marker:GetFullName(), message))
end

local function mapRegistrationForMarker(
	marker: BasePart
): (string?, EntitySlotService.MapRegistration?)
	local mapEntityId = marker:GetAttribute(MAP_ENTITY_ID_ATTRIBUTE)
	if type(mapEntityId) ~= "string" or mapEntityId == "" then
		rejectAuthoredMarker(marker, "missing string ArenaMapEntityId")
		return nil, nil
	end
	local mapRegistration = EntitySlotService.GetMapRegistration(mapEntityId)
	if
		not mapRegistration
		or mapRegistration.eventId ~= mapEntityId
		or mapRegistration.kind ~= "Item"
		or mapRegistration.registration.kind ~= "World"
		or EntitySlotService.GetWorldRegistrationBySourceOrder(
				mapRegistration.registration.sourceOrder
			)
			~= mapRegistration.registration
	then
		rejectAuthoredMarker(marker, "Q3EngineMapEntityId is not the installed Item registration")
		return nil, nil
	end
	return mapEntityId, mapRegistration
end

local function refreshMarker(marker: BasePart)
	unregisterMarker(marker, true)
	task.defer(function()
		if marker.Parent and isWithinWorldRoot(marker) then
			tryRegisterMarker(marker)
		end
	end)
end

tryRegisterMarker = function(marker: BasePart, dynamicDeathDrop: boolean?)
	if
		recordsByMarker[marker]
		or marker:GetAttribute(PREPARED_MOVER_DROP_PRESENTATION_ATTRIBUTE) == true
		or not isWithinWorldRoot(marker)
	then
		return
	end

	local itemIdValue = marker:GetAttribute(ItemDefs.Attributes.ItemId)
	if type(itemIdValue) ~= "string" or itemIdValue == "" then
		if CollectionService:HasTag(marker, ItemDefs.MarkerTag) and not warnedMarkers[marker] then
			warnedMarkers[marker] = true
			warn(
				string.format(
					"Tagged pickup %s is missing string attribute %s",
					marker:GetFullName(),
					ItemDefs.Attributes.ItemId
				)
			)
		end
		return
	end

	local definition = ItemDefs.ById[itemIdValue]
	if not definition then
		if not warnedMarkers[marker] then
			warnedMarkers[marker] = true
			warn(
				string.format("Unknown pickup item id %s on %s", itemIdValue, marker:GetFullName())
			)
		end
		return
	end
	if definition.worldPickupEligible == false then
		rejectAuthoredMarker(marker, "item is not eligible for world pickup")
		return
	end
	local mapEntityId: string? = nil
	local mapRegistration: EntitySlotService.MapRegistration? = nil
	if dynamicDeathDrop ~= true then
		mapEntityId, mapRegistration = mapRegistrationForMarker(marker)
		if not mapEntityId or not mapRegistration then
			return
		end
		if mapRecordsByRegistration[mapRegistration] then
			rejectAuthoredMarker(
				marker,
				"Q3EngineMapEntityId is already bound to another pickup marker"
			)
			return
		end
	end

	local pickupId = readPickupId(marker, itemIdValue)
	if not pickupId then
		warn(string.format("Invalid pickup id on %s", marker:GetFullName()))
		return
	end
	local duplicate = recordsById[pickupId]
	if duplicate and duplicate.marker ~= marker then
		warn(
			string.format(
				"Duplicate pickup id %s on %s and %s",
				pickupId,
				duplicate.marker:GetFullName(),
				marker:GetFullName()
			)
		)
		return
	end
	if moverDeathDropAuthority.recordsById[pickupId] ~= nil then
		warn(
			string.format(
				"Duplicate pickup id %s conflicts with prepared mover Item authority on %s",
				pickupId,
				marker:GetFullName()
			)
		)
		return
	end

	warnedMarkers[marker] = nil
	local generation = (generationById[pickupId] or 0) + 1
	generationById[pickupId] = generation
	local record: PickupRecord = {
		marker = marker,
		authorityPosition = marker.Position,
		pickupId = pickupId,
		itemId = itemIdValue,
		definition = definition,
		quantity = readQuantity(marker, definition),
		respawnOverride = readRespawnOverride(marker),
		enabled = marker:GetAttribute(ItemDefs.Attributes.Enabled) ~= false,
		active = true,
		respawnAtMilliseconds = nil,
		generation = generation,
		revision = 0,
		originalTransparency = marker.Transparency,
		originalCanCollide = marker.CanCollide,
		originalCanTouch = marker.CanTouch,
		originalCanQuery = marker.CanQuery,
		originalPickupIdAttribute = marker:GetAttribute(ItemDefs.Attributes.PickupId),
		connections = {},
		source = "Map",
		mapEntityId = mapEntityId,
		mapRegistration = mapRegistration,
		mapSourceOrder = if mapRegistration then mapRegistration.registration.sourceOrder else nil,
		matchId = nil,
		velocity = nil,
		settled = true,
		expiresAtMilliseconds = nil,
		trajectoryTimeMilliseconds = nil,
		spawnSequence = 0,
		claiming = false,
	}
	recordsByMarker[marker] = record
	recordsById[pickupId] = record
	if mapRegistration then
		mapRecordsByRegistration[mapRegistration] = record
		invalidateMapRecordOrder()
	end
	replaceMapMoverRecord(record, nil, nil)
	applyMarkerState(record)

	for _, attributeName in
		{
			ItemDefs.Attributes.ItemId,
			ItemDefs.Attributes.PickupId,
			ItemDefs.Attributes.Quantity,
			ItemDefs.Attributes.RespawnSeconds,
			MAP_ENTITY_ID_ATTRIBUTE,
		}
	do
		table.insert(
			record.connections,
			marker:GetAttributeChangedSignal(attributeName):Connect(function()
				refreshMarker(marker)
			end)
		)
	end
	table.insert(
		record.connections,
		marker:GetAttributeChangedSignal(ItemDefs.Attributes.Enabled):Connect(function()
			local current = recordsByMarker[marker]
			if not current then
				return
			end
			current.enabled = marker:GetAttribute(ItemDefs.Attributes.Enabled) ~= false
			applyMarkerState(current)
			scheduleSnapshot()
		end)
	)
	scheduleSnapshot()
end

local function scanMarkers()
	local root = worldRoot
	if not root then
		return
	end

	local seen: { [BasePart]: boolean } = {}
	local markers: { BasePart } = {}
	local function consider(instance: Instance)
		if
			instance:IsA("BasePart")
			and not seen[instance]
			and isWithinWorldRoot(instance)
			and (
				instance:GetAttribute(ItemDefs.Attributes.ItemId) ~= nil
				or CollectionService:HasTag(instance, ItemDefs.MarkerTag)
			)
		then
			seen[instance] = true
			table.insert(markers, instance)
		end
	end

	consider(root)
	for _, descendant in root:GetDescendants() do
		consider(descendant)
	end
	for _, tagged in CollectionService:GetTagged(ItemDefs.MarkerTag) do
		consider(tagged)
	end
	table.sort(markers, function(left: BasePart, right: BasePart): boolean
		local leftName = left:GetFullName()
		local rightName = right:GetFullName()
		if leftName ~= rightName then
			return leftName < rightName
		end
		local leftPosition = left.Position
		local rightPosition = right.Position
		if leftPosition.X ~= rightPosition.X then
			return leftPosition.X < rightPosition.X
		elseif leftPosition.Y ~= rightPosition.Y then
			return leftPosition.Y < rightPosition.Y
		end
		return leftPosition.Z < rightPosition.Z
	end)
	for _, marker in markers do
		tryRegisterMarker(marker)
	end
end

local function getPlayerState(player: Player): PlayerItemState?
	local hooks = serviceHooks
	if not hooks then
		return nil
	end
	local ok, state = pcall(hooks.GetPlayerState, player)
	if not ok then
		warnHook(string.format("ItemService.GetPlayerState failed: %s", tostring(state)))
		return nil
	end
	if not state then
		return nil
	end
	if
		type(state.alive) ~= "boolean"
		or type(state.pickupsEnabled) ~= "boolean"
		or not isFiniteVector(state.position)
		or not isFinite(state.health)
		or not isFinite(state.maxHealth)
		or not isFinite(state.armor)
		or type(state.ammoByWeapon) ~= "table"
		or not isFinite(state.holdableId)
		or state.holdableId % 1 ~= 0
	then
		warnHook(string.format("ItemService received invalid state for %s", player.Name))
		return nil
	end
	return state
end

local function canUsePickup(
	player: Player,
	record: PickupRecord,
	state: PlayerItemState
): (boolean, number, number)
	if
		not serviceEnabled
		or not record.enabled
		or not record.active
		or record.claiming
		or not state.alive
		or not state.pickupsEnabled
		or not ItemDefs.PlayerTouchesItem(state.position, record.authorityPosition)
	then
		return false, 0, 0
	end

	local hooks = assert(serviceHooks, "ItemService hooks are unavailable")
	if record.source == "DeathDrop" and hooks.GetMatchId then
		local ok, currentMatchId = pcall(hooks.GetMatchId)
		if not ok or currentMatchId ~= record.matchId then
			return false, 0, 0
		end
	end
	if hooks.CanPickup then
		local ok, allowed = pcall(hooks.CanPickup, player, record.definition, record.marker)
		if not ok then
			warnHook(string.format("ItemService.CanPickup failed: %s", tostring(allowed)))
			return false, 0, 0
		end
		if not allowed then
			return false, 0, 0
		end
	end

	return ItemDefs.GetEligibility(record.definition, state)
end

local function useFullWeaponAmmo(player: Player, record: PickupRecord): boolean
	if record.source == "DeathDrop" then
		return true
	end
	local hooks = assert(serviceHooks, "ItemService hooks are unavailable")
	if not hooks.UseFullWeaponAmmo then
		return false
	end
	local ok, full = pcall(hooks.UseFullWeaponAmmo, player, record.definition, record.marker)
	if not ok then
		warnHook(string.format("ItemService.UseFullWeaponAmmo failed: %s", tostring(full)))
		return false
	end
	return full == true
end

local function resolveRespawnSeconds(player: Player, record: PickupRecord): number
	if record.respawnOverride ~= nil then
		return record.respawnOverride
	end

	local defaultSeconds = record.definition.respawnSeconds
	local hooks = assert(serviceHooks, "ItemService hooks are unavailable")
	if not hooks.ResolveRespawnSeconds then
		return defaultSeconds
	end
	local ok, result = pcall(
		hooks.ResolveRespawnSeconds,
		player,
		record.definition,
		record.marker,
		defaultSeconds,
		record.definition.teamRespawnSeconds
	)
	if not ok then
		warnHook(string.format("ItemService.ResolveRespawnSeconds failed: %s", tostring(result)))
		return defaultSeconds
	end
	if not isFinite(result) or (result ~= -1 and result < 1) then
		warnHook("ItemService.ResolveRespawnSeconds returned an invalid value")
		return defaultSeconds
	end
	return result
end

local function invokeGrant(
	player: Player,
	record: PickupRecord,
	cap: number,
	current: number,
	summary: AuthoritativeFrameService.Summary
): (boolean, number)
	local definition = record.definition
	local weaponId = definition.weaponId
	local grantAmount: number
	if definition.kind == "Weapon" then
		grantAmount =
			ItemDefs.GetWeaponAmmoGrant(current, record.quantity, useFullWeaponAmmo(player, record))
	else
		grantAmount = ItemDefs.GetGrantAmount(current, record.quantity, cap)
	end

	local context: GrantContext = {
		pickupId = record.pickupId,
		itemId = record.itemId,
		kind = definition.kind,
		marker = record.marker,
		definition = definition,
		configuredQuantity = record.quantity,
		grantAmount = grantAmount,
		current = current,
		cap = cap,
		weaponId = weaponId,
		holdableId = definition.holdableId,
		powerupId = definition.powerupId,
		levelTimeMilliseconds = summary.currentTimeMilliseconds,
		serverTime = summary.currentServerTimeSeconds,
	}
	local hooks = assert(serviceHooks, "ItemService hooks are unavailable")
	local ok: boolean
	local granted: boolean
	if definition.kind == "Health" then
		ok, granted = pcall(hooks.TryGrantHealth, player, grantAmount, cap, context)
	elseif definition.kind == "Armor" then
		ok, granted = pcall(hooks.TryGrantArmor, player, grantAmount, cap, context)
	elseif definition.kind == "Ammo" then
		ok, granted = pcall(
			hooks.TryGrantAmmo,
			player,
			assert(weaponId, "ammo item is missing weaponId"),
			grantAmount,
			cap,
			context
		)
	elseif definition.kind == "Weapon" then
		ok, granted = pcall(
			hooks.TryGrantWeapon,
			player,
			assert(weaponId, "weapon item is missing weaponId"),
			grantAmount,
			cap,
			context
		)
	elseif definition.kind == "Holdable" then
		ok, granted = pcall(
			hooks.TryGrantHoldable,
			player,
			assert(definition.holdableId, "holdable item is missing holdableId"),
			context
		)
	else
		ok, granted = pcall(
			hooks.TryGrantPowerup,
			player,
			assert(definition.powerupId, "powerup item is missing powerupId"),
			context
		)
	end
	if not ok then
		warnHook(string.format("ItemService grant hook failed: %s", tostring(granted)))
		return false, 0
	end
	return granted == true, grantAmount
end

local function takePickup(
	player: Player,
	record: PickupRecord,
	grantAmount: number,
	summary: AuthoritativeFrameService.Summary
)
	record.active = false
	record.revision += 1
	if record.source == "DeathDrop" then
		record.respawnAtMilliseconds = nil
		emitItemEvent(record, "PickupTaken", player, grantAmount, summary)
		local marker = record.marker
		unregisterMarker(marker, false)
		ItemFramePublicationService.RetirePart(marker)
		scheduleSnapshot()
		return
	end
	local respawnSeconds = resolveRespawnSeconds(player, record)
	record.respawnAtMilliseconds = if respawnSeconds < 0
		then nil
		else deadlineMilliseconds(summary.currentTimeMilliseconds, respawnSeconds)
	local moverRecord = assert(
		mapMoverAuthority.recordsById[record.pickupId],
		"map mover record is unavailable during touch"
	)
	local transition, transitionError = MoverItemFlagParticipantRules.ResolveTouch(
		moverRecord.participant,
		if respawnSeconds < 0 then "MapNeverRespawn" else "MapRespawn"
	)
	assert(transition, transitionError or "map Item touch transition failed")
	replaceMapMoverRecord(
		record,
		transition.participant,
		if respawnSeconds < 0 then summary.currentTimeMilliseconds else nil
	)
	applyMarkerState(record)
	emitItemEvent(record, "PickupTaken", player, grantAmount, summary)
	scheduleSnapshot()
end

local function tryPickupRecord(
	player: Player,
	record: PickupRecord,
	knownState: PlayerItemState?,
	summary: AuthoritativeFrameService.Summary
): boolean
	if recordsByMarker[record.marker] ~= record or record.marker.Parent == nil then
		return false
	end
	if record.source == "Map" then
		local mapEntityId = record.mapEntityId
		local mapRegistration = record.mapRegistration
		if
			not mapEntityId
			or not mapRegistration
			or mapRegistration.kind ~= "Item"
			or EntitySlotService.GetMapRegistration(mapEntityId) ~= mapRegistration
			or EntitySlotService.GetWorldRegistrationBySourceOrder(
					mapRegistration.registration.sourceOrder
				)
				~= mapRegistration.registration
		then
			return false
		end
	end
	local state = knownState or getPlayerState(player)
	if not state then
		return false
	end
	local eligible, cap, current = canUsePickup(player, record, state)
	if not eligible then
		return false
	end

	record.claiming = true
	local granted, grantAmount = invokeGrant(player, record, cap, current, summary)
	if not granted then
		record.claiming = false
		return false
	end
	takePickup(player, record, grantAmount, summary)
	return true
end

local function respawnMapPickup(
	record: PickupRecord,
	currentMilliseconds: number,
	summary: AuthoritativeFrameService.Summary
)
	if
		not serviceEnabled
		or not record.enabled
		or record.active
		or record.respawnAtMilliseconds == nil
		or currentMilliseconds < record.respawnAtMilliseconds
	then
		return
	end
	record.active = true
	record.claiming = false
	record.respawnAtMilliseconds = nil
	record.revision += 1
	local moverRecord = assert(
		mapMoverAuthority.recordsById[record.pickupId],
		"map mover record is unavailable during respawn"
	)
	local transition, transitionError =
		MoverItemFlagParticipantRules.Respawn(moverRecord.participant)
	assert(transition, transitionError or "map Item respawn transition failed")
	replaceMapMoverRecord(record, transition.participant, nil)
	applyMarkerState(record)
	emitItemEvent(record, "PickupRespawned", nil, 0, summary)
	scheduleSnapshot()
end

local function finishMapItemEvent(record: PickupRecord, currentMilliseconds: number)
	local moverRecord = mapMoverAuthority.recordsById[record.pickupId]
	if not moverRecord or moverRecord.eventStartedAtMilliseconds == nil then
		return
	end
	local eventStartedAt = moverRecord.eventStartedAtMilliseconds
	if currentMilliseconds - eventStartedAt <= 300 then
		return
	end
	local transition, transitionError = MoverItemFlagParticipantRules.FinishEvent(
		moverRecord.participant,
		currentMilliseconds - eventStartedAt
	)
	assert(transition, transitionError or "map Item event completion failed")
	assert(
		record.generation == moverRecord.recordGeneration and record.source == "Map",
		"map Item event record drifted"
	)
	replaceMapMoverRecord(record, transition.participant, nil)
end

local function currentMatchId(): string?
	local hooks = serviceHooks
	if not hooks or not hooks.GetMatchId then
		return nil
	end
	local ok, matchId = pcall(hooks.GetMatchId)
	return if ok and type(matchId) == "string" then matchId else nil
end

local function stepLegacyDeathDrops(summary: AuthoritativeFrameService.Summary)
	local parameters = deathDropCastParameters
	if not parameters then
		return
	end
	local matchId = currentMatchId()
	local currentMilliseconds = summary.currentTimeMilliseconds

	for _, record in legacyDeathDropsInSpawnOrder() do
		local marker = record.marker
		if
			recordsByMarker[marker] ~= record
			or not marker.Parent
			or not record.active
			or (record.expiresAtMilliseconds ~= nil and currentMilliseconds >= record.expiresAtMilliseconds)
			or record.matchId ~= matchId
		then
			destroyDeathDrop(record)
			continue
		end
		if record.settled then
			continue
		end
		local velocity = record.velocity
		local trajectoryTimeMilliseconds = record.trajectoryTimeMilliseconds
		if
			not velocity
			or not isFiniteVector(velocity)
			or type(trajectoryTimeMilliseconds) ~= "number"
			or trajectoryTimeMilliseconds % 1 ~= 0
			or trajectoryTimeMilliseconds < 0
			or trajectoryTimeMilliseconds > currentMilliseconds
		then
			destroyDeathDrop(record)
			continue
		end
		local deltaMilliseconds = currentMilliseconds - trajectoryTimeMilliseconds
		-- G_RunItem evaluates the trajectory at absolute level.time and traces
		-- from the entity's last linked origin. A late visit therefore advances
		-- the whole monotonic interval; it is not restricted to one frame.
		record.trajectoryTimeMilliseconds = currentMilliseconds
		if deltaMilliseconds == 0 then
			continue
		end
		local deltaTime = deltaMilliseconds / MatchFrameRules.MillisecondsPerSecond

		local start = record.authorityPosition
		local target, nextVelocity = DroppedWeaponRules.Integrate(start, velocity, deltaTime)
		if not DroppedWeaponRules.IsValidPosition(target) or not isFiniteVector(nextVelocity) then
			destroyDeathDrop(record)
			continue
		end
		local displacement = target - start
		local distance = displacement.Magnitude
		local result = if distance > 1e-6
			then Workspace:Blockcast(
				CFrame.new(start),
				DroppedWeaponRules.ItemHullSize,
				displacement,
				parameters
			)
			else nil
		if not result then
			record.authorityPosition = target
			record.velocity = nextVelocity
			applyMarkerState(record)
			continue
		end

		local fraction = math.clamp(result.Distance / math.max(distance, 1e-6), 0, 1)
		local _, impactVelocity =
			DroppedWeaponRules.Integrate(start, velocity, deltaTime * fraction)
		local bouncedVelocity, settled = DroppedWeaponRules.Bounce(impactVelocity, result.Normal)
		local impactPosition = start + displacement.Unit * result.Distance
		if settled then
			-- G_BounceItem lifts one source unit on the vertical axis before
			-- SnapVector when the item settles.
			impactPosition += Vector3.yAxis * DroppedWeaponRules.SurfaceNudge
			impactPosition = Vector3.new(
				DroppedWeaponRules.SnapSourceUnit(impactPosition.X),
				DroppedWeaponRules.SnapSourceUnit(impactPosition.Y),
				DroppedWeaponRules.SnapSourceUnit(impactPosition.Z)
			)
		else
			impactPosition += result.Normal * DroppedWeaponRules.SurfaceNudge
		end
		record.authorityPosition = impactPosition
		record.velocity = bouncedVelocity
		record.settled = settled
		record.revision += 1
		applyMarkerState(record)
		scheduleSnapshot()
	end
end

local function validatePreparedMoverDeathDropRequest(
	requestValue: unknown
): (DeathDropRequest?, ItemDefinition?, string?)
	if type(requestValue) ~= "table" then
		return nil, nil, "mover-death-drop-request-not-table"
	end
	local request = requestValue :: { [unknown]: unknown }
	local allowedKeys: { [string]: boolean } = {
		dropId = true,
		matchId = true,
		itemId = true,
		quantity = true,
		position = true,
		velocity = true,
	}
	local keyCount = 0
	for key in request do
		if type(key) ~= "string" or allowedKeys[key] ~= true then
			return nil, nil, "invalid-mover-death-drop-request-shape"
		end
		keyCount += 1
	end
	if
		keyCount ~= 6
		or type(request.dropId) ~= "string"
		or request.dropId == ""
		or #(request.dropId :: string) > 160
		or type(request.matchId) ~= "string"
		or request.matchId == ""
		or type(request.itemId) ~= "string"
		or not isFinite(request.quantity)
		or (request.quantity :: number) % 1 ~= 0
		or (request.quantity :: number) <= 0
		or not isFiniteVector(request.position)
		or not isFiniteVector(request.velocity)
		or not DroppedWeaponRules.IsValidPosition(request.position :: Vector3)
		or not DroppedWeaponRules.IsValidLaunchVelocity(request.velocity :: Vector3)
	then
		return nil, nil, "invalid-mover-death-drop-request"
	end
	local definition = ItemDefs.ById[request.itemId :: string]
	if not definition or (definition.kind ~= "Weapon" and definition.kind ~= "Powerup") then
		return nil, nil, "invalid-mover-death-drop-item"
	end
	if definition.kind == "Weapon" then
		local weaponId = definition.weaponId
		local expected = if weaponId
			then DroppedWeaponRules.ResolveCandidate(weaponId, true, 1, false, true)
			else nil
		if
			not expected
			or expected.itemId ~= request.itemId
			or expected.quantity ~= request.quantity
		then
			return nil, nil, "mover-death-drop-candidate-drifted"
		end
	elseif
		not definition.powerupId
		or MoverConsequenceRules.PowerupItemOrdinal[request.itemId :: string]
			~= definition.powerupId
	then
		return nil, nil, "mover-powerup-drop-candidate-drifted"
	end
	local copied: DeathDropRequest = {
		dropId = request.dropId :: string,
		matchId = request.matchId :: string,
		itemId = request.itemId :: string,
		quantity = request.quantity :: number,
		position = request.position :: Vector3,
		velocity = request.velocity :: Vector3,
	}
	table.freeze(copied)
	return copied, definition, nil
end

local function isPreparedMoverDropRegistration(value: unknown): boolean
	if type(value) ~= "table" or not table.isfrozen(value :: any) then
		return false
	end
	local registration = value :: any
	return registration.kind == "World"
		and registration.domain == "World"
		and type(registration.bodyId) == "string"
		and type(registration.sourceOrder) == "number"
		and registration.sourceOrder % 1 == 0
		and registration.sourceOrder >= EntitySourceOrderRules.FirstWorldSourceOrder
		and registration.sourceOrder <= EntitySourceOrderRules.MaximumNormalSourceOrder
		and type(registration.generation) == "number"
		and registration.generation % 1 == 0
		and registration.generation >= 1
		and registration.bodyQueueIndex == nil
end

local function preparedMoverDeathDropCurrentError(
	preparedValue: unknown,
	capability: MoverDeathDropPreparedCapability
): string?
	local receiptCapability = moverDeathDropReceiptCapabilities[capability.receipt]
	local sharedCurrent = capability.sharedMoverFrame
		and activeSharedMoverDeathDropCapabilities[preparedValue :: PreparedMoverDeathDrop]
			== capability
	if
		capability.status ~= "Prepared"
		or (if capability.sharedMoverFrame
			then not sharedCurrent
			else activePreparedMoverDeathDrop ~= preparedValue)
		or moverDeathDropFlushActive
		or (not capability.sharedMoverFrame and moverDeathDropAuthority ~= capability.baseAuthority)
		or (not capability.sharedMoverFrame and moverDeathDropDispatcherBindings ~= capability.baseDispatcherBindings)
		or serviceEnabled ~= capability.baseServiceEnabled
		or serviceConfigurationRevision ~= capability.baseConfigurationRevision
		or not MatchService.ValidateMatchLineage(capability.matchLineage, capability.record.matchId)
		or deathDropCount ~= capability.baseLegacyDeathDropCount
		or recordsById[capability.record.dropId] ~= capability.baseLegacyRecord
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.baseAuthority)
		or not table.isfrozen(capability.nextAuthority)
		or not table.isfrozen(capability.nextAuthority.recordsById)
		or not table.isfrozen(capability.nextAuthority.order)
		or not table.isfrozen(capability.baseDispatcherBindings)
		or (capability.nextDispatcherBindings ~= nil and not table.isfrozen(
			capability.nextDispatcherBindings
		))
		or not table.isfrozen(capability.record)
		or not table.isfrozen(capability.request)
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(capability.presentation)
		or capability.nextAuthority.recordsById[capability.record.dropId] ~= capability.record
		or capability.nextAuthority.count ~= capability.baseAuthority.count + 1 - (if capability.summary.evictedDropId
			then 1
			else 0)
		or capability.nextAuthority.spawnSequence ~= capability.baseAuthority.spawnSequence + 1
		or capability.nextAuthority.revision ~= capability.baseAuthority.revision + 1
		or not isPreparedMoverDropRegistration(capability.record.registration)
		or capability.record.registration.bodyId ~= capability.summary.bodyId
		or capability.record.registration.sourceOrder ~= capability.summary.sourceOrder
		or capability.record.registration ~= capability.summary.registration
		or capability.record.lease ~= capability.summary.lease
		or capability.record.spawnTimeMilliseconds ~= capability.stepTimeMilliseconds
		or capability.record.trajectoryTimeMilliseconds ~= capability.stepTimeMilliseconds
		or capability.record.eventStartedAtMilliseconds ~= nil
		or capability.record.settled
		or capability.request.dropId ~= capability.record.dropId
		or capability.request.matchId ~= capability.record.matchId
		or capability.request.itemId ~= capability.record.itemId
		or capability.request.quantity ~= capability.record.quantity
		or capability.request.position ~= capability.record.participant.body.position
		or capability.request.velocity ~= capability.record.participant.body.velocity
		or receiptCapability == nil
		or receiptCapability.receipt ~= capability.receipt
		or receiptCapability.record ~= capability.record
		or receiptCapability.status ~= "Pending"
		or receiptCapability.presentation ~= capability.presentation
		or moverDeathDropReceiptByDropId[capability.record.dropId] ~= capability.receipt
	then
		return "stale-prepared-mover-death-drop"
	end
	local evictedReceipt = capability.evictedReceipt
	local evictedReceiptCapability = capability.evictedReceiptCapability
	if evictedReceipt then
		if
			not evictedReceiptCapability
			or moverDeathDropReceiptCapabilities[evictedReceipt] ~= evictedReceiptCapability
			or evictedReceiptCapability.status ~= "Applied"
			or capability.summary.evictedDropId == nil
			or moverDeathDropReceiptByDropId[capability.summary.evictedDropId] ~= evictedReceipt
		then
			return "stale-prepared-mover-death-drop-eviction-receipt"
		end
	elseif evictedReceiptCapability ~= nil then
		return "stale-prepared-mover-death-drop-eviction-receipt"
	end
	return nil
end

-- Prepares one Q3 TossClientItems weapon insertion. The supplied registration
-- and lease must come from the caller's still-open EntitySlot transaction. This
-- owner prebuilds only Item authority; the live coordinator subsequently binds
-- its exact EntitySlot and Dispatcher prepared outcomes before any root applies.
function ItemService.PrepareMoverDeathDrop(
	requestValue: unknown,
	operationOrderValue: unknown,
	levelTimeMillisecondsValue: unknown,
	entitySlotToken: unknown,
	registrationValue: unknown,
	leaseValue: unknown,
	evictedRegistrationValue: unknown?,
	evictedLeaseValue: unknown?,
	sharedMoverFrameValue: unknown?,
	baseAuthorityValue: unknown?
): (
	PreparedMoverDeathDrop?,
	PreparedMoverDeathDropSummary?,
	string?
)
	if not started then
		return nil, nil, "item-service-not-started"
	end
	local sharedMoverFrame = sharedMoverFrameValue == true
	if
		activePreparedMoverDeathDrop ~= nil
		or (not sharedMoverFrame and #activeSharedMoverDeathDrops > 0)
	then
		return nil, nil, "mover-death-drop-prepare-active"
	end
	if activePreparedMoverParticipantUpdate ~= nil then
		return nil, nil, "item-mover-participant-update-active"
	end
	if activePreparedDeathDropInsertion ~= nil then
		return nil, nil, "death-drop-insertion-active"
	end
	if activeDeathDropInsertionPrepareCleanup ~= nil then
		return nil, nil, "death-drop-insertion-prepare-cleanup-active"
	end
	if moverDeathDropFlushActive then
		return nil, nil, "mover-death-drop-publication-active"
	end
	if
		type(operationOrderValue) ~= "number"
		or operationOrderValue ~= operationOrderValue
		or math.abs(operationOrderValue) == math.huge
		or operationOrderValue % 1 ~= 0
		or operationOrderValue < 1
		or operationOrderValue > 2_147_483_647
		or type(levelTimeMillisecondsValue) ~= "number"
		or levelTimeMillisecondsValue ~= levelTimeMillisecondsValue
		or math.abs(levelTimeMillisecondsValue) == math.huge
		or levelTimeMillisecondsValue % 1 ~= 0
		or levelTimeMillisecondsValue < 0
		or levelTimeMillisecondsValue
			> MatchFrameRules.MaximumLevelTimeMilliseconds - durationMilliseconds(
				DroppedWeaponRules.ExpireSeconds
			)
	then
		return nil, nil, "invalid-mover-death-drop-order-or-time"
	end
	if not serviceEnabled then
		return nil, nil, "mover-death-drop-items-disabled"
	end
	if deathDropCount ~= 0 then
		return nil, nil, "legacy-death-drop-authority-not-migrated"
	end
	local request, definition, requestError = validatePreparedMoverDeathDropRequest(requestValue)
	if not request or not definition then
		return nil, nil, requestError
	end
	if currentMatchId() ~= request.matchId then
		return nil, nil, "mover-death-drop-match-drifted"
	end
	local matchLineage = MatchService.GetCurrentMatchLineage(request.matchId)
	if not matchLineage then
		return nil, nil, "mover-death-drop-match-lineage-unavailable"
	end
	if recordsById[request.dropId] ~= nil then
		return nil, nil, "mover-death-drop-id-already-active"
	end
	if not isPreparedMoverDropRegistration(registrationValue) then
		return nil, nil, "invalid-mover-death-drop-registration"
	end
	local registration = registrationValue :: EntitySlotService.Registration
	local trustedLease = EntitySlotService.GetWorldLease(registration, entitySlotToken)
	if trustedLease == nil or trustedLease ~= leaseValue then
		return nil, nil, "untrusted-mover-death-drop-registration"
	end
	if
		EntitySlotService.GetWorldRegistrationBySourceOrder(registration.sourceOrder) ~= nil
		or EntitySlotService.GetWorldRegistrationByBodyId(registration.bodyId) ~= nil
	then
		return nil, nil, "mover-death-drop-registration-not-provisional"
	end
	local lease = trustedLease

	local baseAuthority = if sharedMoverFrame and type(baseAuthorityValue) == "table"
		then baseAuthorityValue :: MoverDeathDropAuthority
		else moverDeathDropAuthority
	if
		baseAuthority.count ~= #baseAuthority.order
		or baseAuthority.count > DroppedWeaponRules.MaximumLiveDrops
		or not table.isfrozen(baseAuthority)
		or not table.isfrozen(baseAuthority.recordsById)
		or not table.isfrozen(baseAuthority.order)
		or (not sharedMoverFrame and not table.isfrozen(moverDeathDropDispatcherBindings))
	then
		return nil, nil, "invalid-mover-death-drop-authority-root"
	end
	if baseAuthority.recordsById[request.dropId] then
		return nil, nil, "mover-death-drop-id-already-active"
	end
	if not sharedMoverFrame then
		local bindingCount = 0
		for dropId, _binding in moverDeathDropDispatcherBindings do
			if baseAuthority.recordsById[dropId] == nil then
				return nil, nil, "orphan-mover-death-drop-dispatcher-binding"
			end
			bindingCount += 1
		end
		if bindingCount ~= baseAuthority.count then
			return nil, nil, "incomplete-mover-death-drop-dispatcher-bindings"
		end
	end
	local evicted: MoverDeathDropRecord? = nil
	if baseAuthority.count >= DroppedWeaponRules.MaximumLiveDrops then
		evicted = baseAuthority.order[1]
		if
			not evicted
			or evictedRegistrationValue ~= evicted.registration
			or evictedLeaseValue ~= evicted.lease
			or EntitySlotService.GetWorldLease(evicted.registration, entitySlotToken) ~= nil
		then
			return nil, nil, "mover-death-drop-cap-eviction-not-staged"
		end
	elseif evictedRegistrationValue ~= nil or evictedLeaseValue ~= nil then
		return nil, nil, "unexpected-mover-death-drop-cap-eviction"
	end
	local evictedReceipt: MoverDeathDropApplyReceipt? = nil
	local evictedReceiptCapability: MoverDeathDropReceiptCapability? = nil
	if evicted then
		evictedReceipt = moverDeathDropReceiptByDropId[evicted.dropId]
		if evictedReceipt then
			evictedReceiptCapability = moverDeathDropReceiptCapabilities[evictedReceipt]
			if not evictedReceiptCapability or evictedReceiptCapability.status ~= "Applied" then
				return nil, nil, "mover-death-drop-evicted-publication-active"
			end
		end
	end

	local insertion, insertionError = MoverConsequenceRules.BuildDeathDropInsertion({
		bodyId = registration.bodyId,
		sourceOrder = registration.sourceOrder,
		position = request.position,
		velocity = request.velocity,
		itemId = request.itemId,
		operationOrder = operationOrderValue,
	})
	if not insertion then
		return nil, nil, insertionError or "mover-death-drop-insertion-invalid"
	end
	local participant, participantError =
		MoverItemFlagParticipantRules.CreateFromInsertion(insertion)
	if not participant then
		return nil, nil, participantError or "mover-death-drop-participant-invalid"
	end

	local expiresAtMilliseconds =
		deadlineMilliseconds(levelTimeMillisecondsValue :: number, DroppedWeaponRules.ExpireSeconds)
	local spawnSequence = baseAuthority.spawnSequence + 1
	local record: MoverDeathDropRecord = {
		registration = registration,
		lease = lease,
		dropId = request.dropId,
		matchId = request.matchId,
		itemId = request.itemId,
		definition = definition,
		quantity = request.quantity,
		participant = participant,
		spawnTimeMilliseconds = levelTimeMillisecondsValue :: number,
		trajectoryTimeMilliseconds = levelTimeMillisecondsValue :: number,
		eventStartedAtMilliseconds = nil,
		settled = false,
		expiresAtMilliseconds = expiresAtMilliseconds,
		spawnSequence = spawnSequence,
		revision = 0,
	}
	table.freeze(record)
	local nextRecordsById = table.clone(baseAuthority.recordsById)
	local nextOrder = table.clone(baseAuthority.order)
	if evicted then
		nextRecordsById[evicted.dropId] = nil
		table.remove(nextOrder, 1)
	end
	nextRecordsById[record.dropId] = record
	table.insert(nextOrder, record)
	table.freeze(nextRecordsById)
	table.freeze(nextOrder)
	local nextAuthority: MoverDeathDropAuthority = {
		revision = baseAuthority.revision + 1,
		recordsById = nextRecordsById,
		order = nextOrder,
		count = #nextOrder,
		spawnSequence = spawnSequence,
	}
	table.freeze(nextAuthority)

	local summary: PreparedMoverDeathDropSummary = {
		revision = nextAuthority.revision,
		operationOrder = operationOrderValue,
		dropId = record.dropId,
		bodyId = registration.bodyId,
		sourceOrder = registration.sourceOrder,
		registration = registration,
		lease = lease,
		insertion = insertion,
		participant = participant,
		evictedDropId = if evicted then evicted.dropId else nil,
		evictedRegistration = if evicted then evicted.registration else nil,
		evictedLease = if evicted then evicted.lease else nil,
	}
	table.freeze(summary)
	local presentation: MoverDeathDropPresentation = {
		dropId = record.dropId,
		matchId = record.matchId,
		itemId = record.itemId,
		quantity = record.quantity,
		position = participant.body.position,
		velocity = participant.body.velocity,
		expiresAt = presentationTimeForLevel(record.expiresAtMilliseconds),
		revision = record.revision,
		evictedDropId = summary.evictedDropId,
	}
	table.freeze(presentation)
	local prepared: PreparedMoverDeathDrop = table.freeze({})
	local receipt: MoverDeathDropApplyReceipt = table.freeze({})
	local receiptCapability: MoverDeathDropReceiptCapability = {
		status = "Pending",
		receipt = receipt,
		record = record,
		presentation = presentation,
	}
	moverDeathDropReceiptCapabilities[receipt] = receiptCapability
	moverDeathDropReceiptByDropId[record.dropId] = receipt
	preparedMoverDeathDropCapabilities[prepared] = {
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		request = request,
		stepTimeMilliseconds = levelTimeMillisecondsValue :: number,
		matchLineage = matchLineage,
		entitySlotPrepared = nil,
		entitySlotSummary = nil,
		entitySlotReceipt = nil,
		dispatcherPrepared = nil,
		dispatcherSummary = nil,
		dispatcherReceipt = nil,
		baseDispatcherBindings = moverDeathDropDispatcherBindings,
		nextDispatcherBindings = nil,
		baseAuthority = baseAuthority,
		nextAuthority = nextAuthority,
		baseServiceEnabled = serviceEnabled,
		baseConfigurationRevision = serviceConfigurationRevision,
		baseLegacyDeathDropCount = deathDropCount,
		baseLegacyRecord = recordsById[record.dropId],
		record = record,
		summary = summary,
		receipt = receipt,
		presentation = presentation,
		evictedReceipt = evictedReceipt,
		evictedReceiptCapability = evictedReceiptCapability,
		sharedMoverFrame = sharedMoverFrame,
	}
	if sharedMoverFrame then
		table.insert(activeSharedMoverDeathDrops, prepared)
		activeSharedMoverDeathDropCapabilities[prepared] = assert(
			preparedMoverDeathDropCapabilities[prepared],
			"shared mover death-drop capability disappeared during registration"
		)
	else
		activePreparedMoverDeathDrop = prepared
	end
	return prepared, summary, nil
end

-- G_Spawn during a synchronous mover consequence. The shared participant
-- broker owns the provisional EntitySlot/Dispatcher roots; this Item child
-- owns the immutable logical record and returns its body immediately so later
-- pusher parts in the same G_MoverTeam traversal can move or crush it.
function ItemService.StageSynchronousMoverDeathDrop(
	requestValue: unknown,
	operationOrderValue: unknown
): (MoverItemFlagParticipantRules.Body?, string?)
	local brokerToken = MoverParticipantReleaseBrokerService.GetActiveToken()
	if not brokerToken then
		return nil, "synchronous-mover-death-drop-outside-participant-frame"
	end
	local stepTimeMilliseconds = MoverParticipantReleaseBrokerService.GetStepTime(brokerToken)
	if stepTimeMilliseconds == nil then
		return nil, "synchronous-mover-death-drop-frame-stale"
	end
	local lastSharedPrepared = activeSharedMoverDeathDrops[#activeSharedMoverDeathDrops]
	local lastSharedCapability = if lastSharedPrepared
		then activeSharedMoverDeathDropCapabilities[lastSharedPrepared]
		else nil
	local shadowAuthority = if lastSharedCapability
		then lastSharedCapability.nextAuthority
		else moverDeathDropAuthority
	local evicted = if shadowAuthority.count >= DroppedWeaponRules.MaximumLiveDrops
		then shadowAuthority.order[1]
		else nil
	if evicted then
		local provisionalPrepared: PreparedMoverDeathDrop? = nil
		for _, candidatePrepared in activeSharedMoverDeathDrops do
			local candidateCapability = activeSharedMoverDeathDropCapabilities[candidatePrepared]
			if candidateCapability and candidateCapability.record == evicted then
				provisionalPrepared = candidatePrepared
				break
			end
		end
		if provisionalPrepared then
			local canceled, cancelError = MoverParticipantReleaseBrokerService.CancelAllocation(
				brokerToken,
				evicted.registration
			)
			if not canceled or not ItemService.AbortPreparedMoverDeathDrop(provisionalPrepared) then
				return nil,
					cancelError or "synchronous-mover-death-drop-provisional-eviction-failed"
			end
		else
			local binding = moverDeathDropDispatcherBindings[evicted.dropId]
			if not binding then
				return nil, "synchronous-mover-death-drop-eviction-binding-missing"
			end
			local released, releaseError = MoverParticipantReleaseBrokerService.StageRelease(
				brokerToken,
				evicted.registration,
				binding
			)
			if not released then
				return nil, releaseError or "synchronous-mover-death-drop-eviction-stage-failed"
			end
		end
	end
	local registration, allocationError = MoverParticipantReleaseBrokerService.AllocateWorld(
		brokerToken,
		"dropped_item",
		"DroppedItem",
		runRegisteredMoverDeathDrop
	)
	if not registration then
		return nil, allocationError or "synchronous-mover-death-drop-allocation-failed"
	end
	local lease =
		MoverParticipantReleaseBrokerService.GetProvisionalWorldLease(brokerToken, registration)
	local entitySlotToken = MoverParticipantReleaseBrokerService.GetOpenEntitySlotToken(brokerToken)
	if not lease or not entitySlotToken then
		return nil, "synchronous-mover-death-drop-provisional-lineage-missing"
	end
	local prepared, summary, prepareError = ItemService.PrepareMoverDeathDrop(
		requestValue,
		operationOrderValue,
		stepTimeMilliseconds,
		entitySlotToken,
		registration,
		lease,
		if evicted then evicted.registration else nil,
		if evicted then evicted.lease else nil,
		true,
		shadowAuthority
	)
	if not prepared or not summary then
		return nil, prepareError or "synchronous-mover-death-drop-item-prepare-failed"
	end
	return summary.participant.body, nil
end

local function validatePreparedMoverDeathDropEntitySlotDependency(
	capability: MoverDeathDropPreparedCapability,
	entitySlotPrepared: unknown,
	entitySlotSummary: unknown
): (boolean, string?)
	local validSummary, summaryError =
		EntitySlotService.ValidatePreparedCommitDependency(entitySlotPrepared, entitySlotSummary)
	if not validSummary then
		return false, summaryError or "invalid-mover-death-drop-entity-slot-summary"
	end
	local summary = entitySlotSummary :: EntitySlotService.PreparedCommitSummary
	if summary.stepTimeMilliseconds ~= capability.stepTimeMilliseconds then
		return false, "mover-death-drop-entity-slot-time-mismatch"
	end
	local retained, retainedError = EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
		entitySlotPrepared,
		summary,
		capability.record.registration,
		capability.record.lease,
		"Retained"
	)
	if not retained then
		return false, retainedError or "mover-death-drop-registration-not-retained"
	end
	local evictedRegistration = capability.summary.evictedRegistration
	local evictedLease = capability.summary.evictedLease
	if evictedRegistration or evictedLease then
		if not evictedRegistration or not evictedLease then
			return false, "mover-death-drop-eviction-outcome-incomplete"
		end
		local released, releasedError = EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
			entitySlotPrepared,
			summary,
			evictedRegistration,
			evictedLease,
			"Released"
		)
		if not released then
			return false, releasedError or "mover-death-drop-eviction-not-released"
		end
	end
	return true, nil
end

-- Bind this Item insertion to the exact still-current EntitySlot transaction
-- outcome. Dispatcher binding follows; the coordinator then repeats all three
-- preflights and applies EntitySlot -> Dispatcher -> Item without callbacks,
-- yields, allocations, or unrelated authority mutations between root swaps.
function ItemService.BindPreparedMoverDeathDropEntitySlotDependency(
	preparedValue: unknown,
	entitySlotPreparedValue: unknown,
	entitySlotSummaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-mover-death-drop"
	end
	local capability = preparedMoverDeathDropCapabilities[preparedValue :: PreparedMoverDeathDrop]
	if not capability then
		return false, "invalid-prepared-mover-death-drop"
	end
	capability.applyValidated = false
	local currentError = preparedMoverDeathDropCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	if capability.entitySlotPrepared or capability.entitySlotSummary then
		if
			capability.entitySlotPrepared == entitySlotPreparedValue
			and capability.entitySlotSummary == entitySlotSummaryValue
		then
			local validDependency, dependencyError =
				validatePreparedMoverDeathDropEntitySlotDependency(
					capability,
					entitySlotPreparedValue,
					entitySlotSummaryValue
				)
			if not validDependency then
				return false, dependencyError
			end
			if
				EntitySlotService.InspectPreparedCommitReceipt(entitySlotPreparedValue)
				~= capability.entitySlotReceipt
			then
				return false, "stale-mover-death-drop-entity-slot-receipt"
			end
			return true, nil
		end
		return false, "mover-death-drop-entity-slot-dependency-already-bound"
	end
	local validDependency, dependencyError = validatePreparedMoverDeathDropEntitySlotDependency(
		capability,
		entitySlotPreparedValue,
		entitySlotSummaryValue
	)
	if not validDependency then
		return false, dependencyError
	end
	local entitySlotReceipt =
		EntitySlotService.InspectPreparedCommitReceipt(entitySlotPreparedValue)
	if not entitySlotReceipt then
		return false, "mover-death-drop-entity-slot-receipt-unavailable"
	end
	capability.entitySlotPrepared = entitySlotPreparedValue :: EntitySlotService.PreparedCommit
	capability.entitySlotSummary = entitySlotSummaryValue :: EntitySlotService.PreparedCommitSummary
	capability.entitySlotReceipt = entitySlotReceipt
	return true, nil
end

local function validatePreparedMoverDeathDropDispatcherDependency(
	capability: MoverDeathDropPreparedCapability,
	dispatcherPreparedValue: unknown,
	dispatcherSummaryValue: unknown
): (
	EntityFrameDispatcherService.DynamicBinding?,
	string?
)
	if
		not EntityFrameDispatcherService.ValidatePreparedDynamicBatchDependency(
			dispatcherPreparedValue,
			dispatcherSummaryValue
		)
	then
		return nil, "invalid-mover-death-drop-dispatcher-summary"
	end
	local summary =
		dispatcherSummaryValue :: EntityFrameDispatcherService.PreparedDynamicBatchSummary
	if summary.entitySlotSummary ~= capability.entitySlotSummary then
		return nil, "mover-death-drop-dispatcher-entity-slot-summary-mismatch"
	end
	local evictedRegistration = capability.summary.evictedRegistration
	local evictedDropId = capability.summary.evictedDropId
	local evictedBinding = if evictedDropId
		then capability.baseDispatcherBindings[evictedDropId]
		else nil
	local bound: EntityFrameDispatcherService.DynamicBinding? = nil
	local sawEvictedUnbind = false
	for _, outcome in summary.outcomes do
		if
			outcome.kind == "Bound"
			and outcome.registration == capability.record.registration
			and outcome.declaredKind == "DroppedItem"
		then
			if bound ~= nil then
				return nil, "duplicate-mover-death-drop-dispatcher-bind"
			end
			bound = outcome.binding
		elseif
			outcome.kind == "Unbound"
			and evictedRegistration ~= nil
			and outcome.registration == evictedRegistration
			and outcome.declaredKind == "DroppedItem"
			and evictedDropId ~= nil
			and evictedBinding ~= nil
			and outcome.binding == evictedBinding
		then
			if sawEvictedUnbind then
				return nil, "duplicate-mover-death-drop-dispatcher-unbind"
			end
			sawEvictedUnbind = true
		elseif
			outcome.registration == capability.record.registration
			or (evictedRegistration ~= nil and outcome.registration == evictedRegistration)
		then
			return nil, "unexpected-mover-death-drop-dispatcher-outcome"
		end
	end
	if bound == nil or (evictedBinding ~= nil and not sawEvictedUnbind) then
		return nil, "incomplete-mover-death-drop-dispatcher-outcomes"
	end
	return bound, nil
end

function ItemService.BindPreparedMoverDeathDropDispatcherDependency(
	preparedValue: unknown,
	dispatcherPreparedValue: unknown,
	dispatcherSummaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-mover-death-drop"
	end
	local capability = preparedMoverDeathDropCapabilities[preparedValue :: PreparedMoverDeathDrop]
	if not capability then
		return false, "invalid-prepared-mover-death-drop"
	end
	capability.applyValidated = false
	local currentError = preparedMoverDeathDropCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	if not capability.entitySlotPrepared or not capability.entitySlotSummary then
		return false, "mover-death-drop-entity-slot-dependency-not-bound"
	end
	local binding, dependencyError = validatePreparedMoverDeathDropDispatcherDependency(
		capability,
		dispatcherPreparedValue,
		dispatcherSummaryValue
	)
	if not binding then
		return false, dependencyError
	end
	local dispatcherReceipt =
		EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPreparedValue)
	if not dispatcherReceipt then
		return false, "mover-death-drop-dispatcher-receipt-unavailable"
	end
	if capability.dispatcherPrepared or capability.dispatcherSummary then
		if
			capability.dispatcherPrepared ~= dispatcherPreparedValue
			or capability.dispatcherSummary ~= dispatcherSummaryValue
			or capability.dispatcherReceipt ~= dispatcherReceipt
			or capability.nextDispatcherBindings == nil
			or capability.nextDispatcherBindings[capability.record.dropId] ~= binding
		then
			return false, "mover-death-drop-dispatcher-dependency-already-bound"
		end
		return true, nil
	end
	local nextBindings = table.clone(capability.baseDispatcherBindings)
	local evictedDropId = capability.summary.evictedDropId
	if evictedDropId then
		nextBindings[evictedDropId] = nil
	end
	if nextBindings[capability.record.dropId] ~= nil then
		return false, "mover-death-drop-dispatcher-binding-id-collision"
	end
	nextBindings[capability.record.dropId] = binding
	table.freeze(nextBindings)
	capability.dispatcherPrepared =
		dispatcherPreparedValue :: EntityFrameDispatcherService.PreparedDynamicBatch
	capability.dispatcherSummary =
		dispatcherSummaryValue :: EntityFrameDispatcherService.PreparedDynamicBatchSummary
	capability.dispatcherReceipt = dispatcherReceipt
	capability.nextDispatcherBindings = nextBindings
	return true, nil
end

function ItemService.InspectPreparedMoverDeathDrop(
	preparedValue: unknown
): PreparedMoverDeathDropSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = preparedMoverDeathDropCapabilities[preparedValue :: PreparedMoverDeathDrop]
	if not capability or preparedMoverDeathDropCurrentError(preparedValue, capability) ~= nil then
		return nil
	end
	return capability.summary
end

function ItemService.ValidatePreparedMoverDeathDropDependency(
	preparedValue: unknown,
	summaryValue: unknown
): boolean
	local summary = ItemService.InspectPreparedMoverDeathDrop(preparedValue)
	return summary ~= nil and summary == summaryValue
end

function ItemService.CanApplyPreparedMoverDeathDrop(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-mover-death-drop"
	end
	local capability = preparedMoverDeathDropCapabilities[preparedValue :: PreparedMoverDeathDrop]
	if not capability then
		return false, "invalid-prepared-mover-death-drop"
	end
	capability.applyValidated = false
	local currentError = preparedMoverDeathDropCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local entitySlotPrepared = capability.entitySlotPrepared
	local entitySlotSummary = capability.entitySlotSummary
	if not entitySlotPrepared or not entitySlotSummary then
		return false, "prepared-mover-death-drop-entity-slot-outcome-not-bound"
	end
	local dependencyCurrent, dependencyError = validatePreparedMoverDeathDropEntitySlotDependency(
		capability,
		entitySlotPrepared,
		entitySlotSummary
	)
	if not dependencyCurrent then
		return false, dependencyError
	end
	if
		EntitySlotService.InspectPreparedCommitReceipt(entitySlotPrepared)
		~= capability.entitySlotReceipt
	then
		return false, "stale-mover-death-drop-entity-slot-receipt"
	end
	local dispatcherPrepared = capability.dispatcherPrepared
	local dispatcherSummary = capability.dispatcherSummary
	local dispatcherReceipt = capability.dispatcherReceipt
	local nextDispatcherBindings = capability.nextDispatcherBindings
	if
		not dispatcherPrepared
		or not dispatcherSummary
		or not dispatcherReceipt
		or not nextDispatcherBindings
	then
		return false, "prepared-mover-death-drop-dispatcher-outcome-not-bound"
	end
	local dispatcherBinding, dispatcherDependencyError =
		validatePreparedMoverDeathDropDispatcherDependency(
			capability,
			dispatcherPrepared,
			dispatcherSummary
		)
	if not dispatcherBinding then
		return false, dispatcherDependencyError
	end
	if
		EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared)
			~= dispatcherReceipt
		or nextDispatcherBindings[capability.record.dropId] ~= dispatcherBinding
	then
		return false, "stale-mover-death-drop-dispatcher-receipt-or-binding"
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	capability.applyValidated = true
	return true, nil
end

function ItemService.ApplyPreparedMoverDeathDrop(
	preparedValue: unknown,
	entitySlotReceiptValue: unknown,
	dispatcherReceiptValue: unknown
): MoverDeathDropApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-mover-death-drop")
	local prepared = preparedValue :: PreparedMoverDeathDrop
	local capability = preparedMoverDeathDropCapabilities[prepared]
	assert(capability, "invalid-prepared-mover-death-drop")
	assert(capability.applyValidated, "prepared-mover-death-drop-not-validated")
	assert(
		capability.preflightPassCount >= 2,
		"prepared mover death-drop requires two complete preflight passes"
	)
	assert(
		capability.status == "Prepared"
			and (if capability.sharedMoverFrame
				then activeSharedMoverDeathDropCapabilities[prepared] == capability
				else activePreparedMoverDeathDrop == prepared)
			and (capability.sharedMoverFrame or moverDeathDropAuthority == capability.baseAuthority)
			and (
				capability.sharedMoverFrame
				or moverDeathDropDispatcherBindings == capability.baseDispatcherBindings
			),
		"stale prepared mover death-drop at apply"
	)
	assert(
		entitySlotReceiptValue == capability.entitySlotReceipt,
		"prepared mover death-drop received the wrong EntitySlot receipt"
	)
	assert(
		dispatcherReceiptValue == capability.dispatcherReceipt,
		"prepared mover death-drop received the wrong dispatcher receipt"
	)
	local entitySlotSummary = assert(
		capability.entitySlotSummary,
		"prepared mover death-drop EntitySlot summary disappeared"
	)
	local entityApplied, entityAppliedError =
		EntitySlotService.ValidateAppliedCommitDependency(entitySlotReceiptValue, entitySlotSummary)
	assert(
		entityApplied,
		entityAppliedError or "prepared mover death-drop EntitySlot dependency was not applied"
	)
	local dispatcherSummary = assert(
		capability.dispatcherSummary,
		"prepared mover death-drop dispatcher summary disappeared"
	)
	local dispatcherApplied, dispatcherAppliedError =
		EntityFrameDispatcherService.ValidateAppliedDynamicBatchDependency(
			dispatcherReceiptValue,
			dispatcherSummary
		)
	assert(
		dispatcherApplied,
		dispatcherAppliedError or "prepared mover death-drop dispatcher dependency was not applied"
	)
	local receiptCapability = assert(
		moverDeathDropReceiptCapabilities[capability.receipt],
		"prepared mover death-drop receipt capability disappeared"
	)

	local nextDispatcherBindings = assert(
		capability.nextDispatcherBindings,
		"prepared mover death-drop dispatcher bindings are unavailable"
	)
	-- Both exact applied witnesses are now consumed. Everything below is a fixed
	-- assignment into data allocated and frozen before either preceding owner
	-- swapped roots; no further callback, allocation, or external validation occurs.
	moverDeathDropAuthority = capability.nextAuthority
	moverDeathDropDispatcherBindings = nextDispatcherBindings
	moverDeathDropCleanupIntents[capability.record.dropId] = nil
	local evictedReceipt = capability.evictedReceipt
	local evictedReceiptCapability = capability.evictedReceiptCapability
	if evictedReceipt and evictedReceiptCapability then
		evictedReceiptCapability.status = "Aborted"
		moverDeathDropReceiptCapabilities[evictedReceipt] = nil
		local evictedDropId = capability.summary.evictedDropId
		if evictedDropId then
			moverDeathDropReceiptByDropId[evictedDropId] = nil
			moverDeathDropCleanupIntents[evictedDropId] = nil
		end
	end
	if capability.summary.evictedDropId then
		local evictedDropId = capability.summary.evictedDropId :: string
		moverDeathDropCleanupIntents[evictedDropId] = nil
		moverDeathDropClaims[evictedDropId] = nil
	end
	if capability.sharedMoverFrame then
		activeSharedMoverDeathDropCapabilities[prepared] = nil
		local activeIndex = table.find(activeSharedMoverDeathDrops, prepared)
		if activeIndex then
			table.remove(activeSharedMoverDeathDrops, activeIndex)
		end
	else
		activePreparedMoverDeathDrop = nil
	end
	capability.status = "Applied"
	capability.applyValidated = false
	receiptCapability.status = "Applied"
	preparedMoverDeathDropCapabilities[prepared] = nil
	return capability.receipt
end

local function createPreparedMoverDeathDropMarker(
	presentation: MoverDeathDropPresentation
): BasePart
	local definition = assert(
		ItemDefs.ById[presentation.itemId],
		"prepared mover death-drop item definition disappeared"
	)
	local root = assert(worldRoot, "ItemService world root is unavailable")
	local folder = ensureFolder(root, "Q3EngineDroppedWeapons")
	local marker = Instance.new("Part")
	marker.Name = presentation.dropId
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.CastShadow = false
	marker.Material = if definition.presentation.material == "Neon"
		then Enum.Material.Neon
		else Enum.Material.SmoothPlastic
	marker.Color = definition.presentation.color
	marker.Size = definition.presentation.size
	marker.Shape = if definition.presentation.shape == "Ball"
		then Enum.PartType.Ball
		elseif definition.presentation.shape == "Cylinder" then Enum.PartType.Cylinder
		else Enum.PartType.Block
	marker.Position = presentation.position
	marker:SetAttribute(PREPARED_MOVER_DROP_PRESENTATION_ATTRIBUTE, true)
	marker:SetAttribute(ItemDefs.Attributes.ItemId, presentation.itemId)
	marker:SetAttribute(ItemDefs.Attributes.PickupId, presentation.dropId)
	marker:SetAttribute(ItemDefs.Attributes.Quantity, presentation.quantity)
	marker:SetAttribute(ItemDefs.Attributes.RespawnSeconds, -1)
	marker:SetAttribute(ItemDefs.Attributes.Enabled, true)
	marker:SetAttribute(ItemDefs.Attributes.Kind, definition.kind)
	marker:SetAttribute(ItemDefs.Attributes.Active, serviceEnabled)
	marker:SetAttribute(ItemDefs.Attributes.Revision, presentation.revision)
	marker:SetAttribute(ItemDefs.Attributes.RespawnAt, nil)
	ItemFramePublicationService.TrackPart(marker, folder)
	moverDeathDropPresentationMarkers[presentation.dropId] = marker
	local record = moverDeathDropAuthority.recordsById[presentation.dropId]
	if record then
		applyMoverDeathDropPresentation(record)
	end
	return marker
end

function ItemService.FlushPreparedMoverDeathDrop(
	receiptValue: unknown
): (MoverDeathDropPublicationReport?, string?)
	if type(receiptValue) ~= "table" then
		return nil, "invalid-mover-death-drop-receipt"
	end
	local receipt = receiptValue :: MoverDeathDropApplyReceipt
	local capability = moverDeathDropReceiptCapabilities[receipt]
	if not capability or capability.receipt ~= receipt then
		return nil, "invalid-mover-death-drop-receipt"
	end
	if capability.status ~= "Applied" then
		return nil, "invalid-mover-death-drop-receipt-status"
	end
	if moverDeathDropAuthority.recordsById[capability.record.dropId] ~= capability.record then
		return nil, "stale-mover-death-drop-receipt-record"
	end
	capability.status = "Flushing"
	moverDeathDropFlushActive = true
	local attemptedPublicationCount = 0
	local faultCount = 0
	local markerCreated = false
	local function publish(callback: () -> ())
		attemptedPublicationCount += 1
		local succeeded = xpcall(callback, debug.traceback)
		if not succeeded then
			faultCount += 1
		end
	end
	local presentation = capability.presentation
	if presentation.evictedDropId then
		publish(function()
			local evictedMarker =
				moverDeathDropPresentationMarkers[presentation.evictedDropId :: string]
			moverDeathDropPresentationMarkers[presentation.evictedDropId :: string] = nil
			if evictedMarker then
				ItemFramePublicationService.RetirePart(evictedMarker)
			end
		end)
	end
	publish(function()
		createPreparedMoverDeathDropMarker(presentation)
		markerCreated = true
	end)
	publish(function()
		publishSnapshot()
	end)

	moverDeathDropFlushActive = false
	capability.status = "Flushed"
	if moverDeathDropReceiptByDropId[presentation.dropId] == receipt then
		moverDeathDropReceiptByDropId[presentation.dropId] = nil
	end
	moverDeathDropReceiptCapabilities[receipt] = nil
	local report: MoverDeathDropPublicationReport = {
		authorityApplied = true,
		attemptedPublicationCount = attemptedPublicationCount,
		faultCount = faultCount,
		markerCreated = markerCreated,
	}
	table.freeze(report)
	return report, nil
end

-- Aborting this Item capability never mutates the caller-owned EntitySlot
-- transaction. The same coordinator that supplied the registration must abort
-- that transaction separately.
function ItemService.AbortPreparedMoverDeathDrop(preparedValue: unknown): boolean
	if type(preparedValue) ~= "table" then
		return false
	end
	local prepared = preparedValue :: PreparedMoverDeathDrop
	local capability = preparedMoverDeathDropCapabilities[prepared]
	if not capability or capability.status ~= "Prepared" then
		return false
	end
	local receiptCapability = moverDeathDropReceiptCapabilities[capability.receipt]
	if not receiptCapability or receiptCapability.status ~= "Pending" then
		return false
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	receiptCapability.status = "Aborted"
	preparedMoverDeathDropCapabilities[prepared] = nil
	moverDeathDropReceiptCapabilities[capability.receipt] = nil
	if moverDeathDropReceiptByDropId[capability.record.dropId] == capability.receipt then
		moverDeathDropReceiptByDropId[capability.record.dropId] = nil
	end
	if capability.sharedMoverFrame then
		activeSharedMoverDeathDropCapabilities[prepared] = nil
		local activeIndex = table.find(activeSharedMoverDeathDrops, prepared)
		if activeIndex then
			table.remove(activeSharedMoverDeathDrops, activeIndex)
		end
	elseif activePreparedMoverDeathDrop == prepared then
		activePreparedMoverDeathDrop = nil
	end
	return true
end

function ItemService.GetMoverDeathDropDebugSnapshot(): MoverDeathDropDebugSnapshot
	local presentationMarkerCount = 0
	for _ in moverDeathDropPresentationMarkers do
		presentationMarkerCount += 1
	end
	local dispatcherBindingCount = 0
	for _ in moverDeathDropDispatcherBindings do
		dispatcherBindingCount += 1
	end
	local cleanupIntentCount = 0
	for _ in moverDeathDropCleanupIntents do
		cleanupIntentCount += 1
	end
	local snapshot: MoverDeathDropDebugSnapshot = {
		revision = moverDeathDropAuthority.revision,
		count = moverDeathDropAuthority.count,
		spawnSequence = moverDeathDropAuthority.spawnSequence,
		activePrepared = activePreparedMoverDeathDrop ~= nil
			or #activeSharedMoverDeathDrops > 0
			or activePreparedDeathDropInsertion ~= nil
			or activeDeathDropInsertionPrepareCleanup ~= nil,
		presentationMarkerCount = presentationMarkerCount,
		dispatcherBindingCount = dispatcherBindingCount,
		cleanupIntentCount = cleanupIntentCount,
	}
	table.freeze(snapshot)
	return snapshot
end

function ItemService.GetMoverDeathDropDebugRecords(): { MoverDeathDropDebugRecord }
	local records: { MoverDeathDropDebugRecord } = {}
	for _, record in registeredDeathDropsInSourceOrder() do
		table.insert(
			records,
			table.freeze({
				dropId = record.dropId,
				itemId = record.itemId,
				quantity = record.quantity,
				bodyId = record.registration.bodyId,
				sourceOrder = record.registration.sourceOrder,
				position = record.participant.body.position,
			})
		)
	end
	table.freeze(records)
	return records
end

local function pointHasNoDrop(position: Vector3): boolean
	local hooks = serviceHooks
	local getPointContents = if hooks then hooks.GetPointContents else nil
	if not getPointContents then
		return false
	end
	local succeeded, contents = pcall(getPointContents, position)
	if not succeeded or type(contents) ~= "number" then
		warnHook("ItemService.GetPointContents failed or returned an invalid contents mask")
		return true
	end
	return WorldPointContents.IsNoDrop(contents)
end

local function buildMoverDeathDropRemovalRoots(record: MoverDeathDropRecord): (MoverDeathDropAuthority, {
	[string]: EntityFrameDispatcherService.DynamicBinding,
})
	local baseAuthority = moverDeathDropAuthority
	assert(
		baseAuthority.recordsById[record.dropId] == record,
		"registered death-drop removal lost its exact Item record"
	)
	local nextRecordsById = table.clone(baseAuthority.recordsById)
	local nextOrder = table.clone(baseAuthority.order)
	nextRecordsById[record.dropId] = nil
	local orderIndex = table.find(nextOrder, record)
	assert(orderIndex ~= nil, "registered death-drop removal lost spawn order")
	table.remove(nextOrder, orderIndex)
	table.freeze(nextRecordsById)
	table.freeze(nextOrder)
	local nextAuthority: MoverDeathDropAuthority = {
		revision = baseAuthority.revision + 1,
		recordsById = nextRecordsById,
		order = nextOrder,
		count = baseAuthority.count - 1,
		spawnSequence = baseAuthority.spawnSequence,
	}
	table.freeze(nextAuthority)
	local nextBindings = table.clone(moverDeathDropDispatcherBindings)
	nextBindings[record.dropId] = nil
	table.freeze(nextBindings)
	return nextAuthority, nextBindings
end

local function releaseRegisteredMoverDeathDrop(
	record: MoverDeathDropRecord,
	summary: AuthoritativeFrameService.Summary
): boolean
	local binding = moverDeathDropDispatcherBindings[record.dropId]
	if
		moverDeathDropAuthority.recordsById[record.dropId] ~= record
		or binding == nil
		or EntitySlotService.GetWorldRegistrationBySourceOrder(record.registration.sourceOrder)
			~= record.registration
	then
		return false
	end
	local baseAuthority = moverDeathDropAuthority
	local baseBindings = moverDeathDropDispatcherBindings
	local nextAuthority, nextBindings = buildMoverDeathDropRemovalRoots(record)
	local token, _beginError = EntitySlotService.Begin(summary.currentTimeMilliseconds)
	if not token then
		return false
	end
	local released, _releaseError = EntitySlotService.ReleaseWorld(token, record.registration)
	if not released then
		EntitySlotService.Abort(token)
		return false
	end
	local entityPrepared, _entityPrepareError = EntitySlotService.Prepare(token)
	if not entityPrepared then
		EntitySlotService.Abort(token)
		return false
	end
	local entitySummary = EntitySlotService.InspectPreparedCommitSummary(entityPrepared)
	local entityReceipt = EntitySlotService.InspectPreparedCommitReceipt(entityPrepared)
	if not entitySummary or not entityReceipt then
		EntitySlotService.Abort(token)
		return false
	end
	local dispatcherPrepared, _dispatcherSummary, _dispatcherPrepareError =
		EntityFrameDispatcherService.PrepareDynamicBatch(entityPrepared, entitySummary, {
			{
				kind = "Unbind",
				registration = record.registration,
				binding = binding,
			},
		})
	if not dispatcherPrepared then
		EntitySlotService.Abort(token)
		return false
	end
	local dispatcherReceipt =
		EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared)
	if not dispatcherReceipt then
		EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared)
		EntitySlotService.Abort(token)
		return false
	end
	for _pass = 1, 2 do
		if
			moverDeathDropAuthority ~= baseAuthority
			or moverDeathDropDispatcherBindings ~= baseBindings
			or moverDeathDropAuthority.recordsById[record.dropId] ~= record
		then
			EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared)
			EntitySlotService.Abort(token)
			return false
		end
		local entityCanApply = EntitySlotService.CanApplyPrepared(entityPrepared)
		local dispatcherCanApply =
			EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(dispatcherPrepared)
		if not entityCanApply or not dispatcherCanApply then
			EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared)
			EntitySlotService.Abort(token)
			return false
		end
	end

	local appliedEntityReceipt = EntitySlotService.ApplyPrepared(entityPrepared)
	assert(appliedEntityReceipt == entityReceipt, "death-drop release EntitySlot receipt drifted")
	local appliedDispatcherReceipt =
		EntityFrameDispatcherService.ApplyPreparedDynamicBatch(dispatcherPrepared)
	assert(
		appliedDispatcherReceipt == dispatcherReceipt,
		"death-drop release dispatcher receipt drifted"
	)
	moverDeathDropAuthority = nextAuthority
	moverDeathDropDispatcherBindings = nextBindings
	moverDeathDropCleanupIntents[record.dropId] = nil
	moverDeathDropClaims[record.dropId] = nil

	local drained, drainError = EntitySlotService.DrainPendingPlayerReleases()
	if not drained then
		warnHook(drainError or "post-death-drop-release player drain failed")
	end
	local marker = moverDeathDropPresentationMarkers[record.dropId]
	moverDeathDropPresentationMarkers[record.dropId] = nil
	if marker then
		ItemFramePublicationService.RetirePart(marker)
	end
	scheduleSnapshot()
	return true
end

runRegisteredMoverDeathDrop = function(
	_frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration,
	binding: EntityFrameDispatcherService.DynamicBinding,
	declaredKind: EntityFrameDispatcherService.DynamicKind
)
	assert(declaredKind == "DroppedItem", "registered Item handler kind drifted")
	local record = moverDeathDropForRegistration(registration)
	assert(
		record ~= nil
			and moverDeathDropDispatcherBindings[record.dropId] == binding
			and EntitySlotService.GetWorldRegistrationBySourceOrder(registration.sourceOrder)
				== registration,
		"registered Item handler lost its exact authority"
	)
	local currentMilliseconds = summary.currentTimeMilliseconds
	local cleanupReason = moverDeathDropCleanupIntents[record.dropId]
	if cleanupReason ~= nil or record.matchId ~= currentMatchId() then
		if cleanupReason == "NoDrop" then
			local transition =
				assert(MoverItemFlagParticipantRules.ResolveNoDropCollision(record.participant))
			assert(
				transition.releaseSourceOrder
					and transition.participant.lifecycle
						== MoverItemFlagParticipantRules.Lifecycle.Freed,
				"queued no-drop Item cleanup did not free its exact source order"
			)
		end
		assert(
			releaseRegisteredMoverDeathDrop(record, summary),
			"registered Item cleanup did not release its composite"
		)
		return
	end

	local participant = record.participant
	if participant.lifecycle == MoverItemFlagParticipantRules.Lifecycle.PendingFreeAfterEvent then
		local eventStartedAt = assert(
			record.eventStartedAtMilliseconds,
			"pending-free death drop lost its event start"
		)
		local elapsed = currentMilliseconds - eventStartedAt
		local transition, transitionError =
			MoverItemFlagParticipantRules.FinishEvent(participant, elapsed)
		if elapsed <= MoverItemFlagParticipantRules.EventValidMilliseconds then
			assert(
				transition == nil and transitionError == "event-still-valid",
				"death-drop event did not retain exact age 300"
			)
			return
		else
			assert(
				transition ~= nil
					and transition.participant.lifecycle == MoverItemFlagParticipantRules.Lifecycle.Freed
					and transition.releaseSourceOrder,
				"death-drop event did not free strictly after age 300"
			)
			assert(
				releaseRegisteredMoverDeathDrop(record, summary),
				"pending-free death drop did not release its composite"
			)
			return
		end
	elseif currentMilliseconds >= record.expiresAtMilliseconds then
		local transition = assert(
			MoverItemFlagParticipantRules.ResolveDroppedTimeout(
				participant,
				currentMilliseconds - record.spawnTimeMilliseconds
			)
		)
		assert(
			transition.releaseSourceOrder
				and transition.participant.lifecycle
					== MoverItemFlagParticipantRules.Lifecycle.Freed,
			"30-second Item think did not free the exact source order"
		)
		assert(
			releaseRegisteredMoverDeathDrop(record, summary),
			"timed-out death drop did not release its composite"
		)
		return
	end

	assert(
		record.trajectoryTimeMilliseconds >= record.spawnTimeMilliseconds
			and record.trajectoryTimeMilliseconds <= currentMilliseconds,
		"registered death-drop trajectory clock is corrupt"
	)
	if record.settled then
		return
	end
	local deltaMilliseconds = currentMilliseconds - record.trajectoryTimeMilliseconds
	-- Q3 G_RunItem evaluates at absolute level.time and traces from the last
	-- linked origin. Dynamic insertion or a late dispatcher visit may therefore
	-- span multiple fixed steps; the full monotonic elapsed interval is canonical.
	if deltaMilliseconds == 0 then
		return
	end

	local deltaTime = deltaMilliseconds / MatchFrameRules.MillisecondsPerSecond
	local start = participant.body.position
	local velocity = participant.body.velocity
	local target, nextVelocity = DroppedWeaponRules.Integrate(start, velocity, deltaTime)
	assert(
		DroppedWeaponRules.IsValidPosition(target) and isFiniteVector(nextVelocity),
		"registered death-drop trajectory became invalid"
	)
	local displacement = target - start
	local distance = displacement.Magnitude
	local parameters = assert(deathDropCastParameters, "death-drop cast parameters are unavailable")
	local result = if distance > 1e-6
		then Workspace:Blockcast(
			CFrame.new(start),
			DroppedWeaponRules.ItemHullSize,
			displacement,
			parameters
		)
		else nil
	local nextPosition = target
	local settled = false
	if result then
		local fraction = math.clamp(result.Distance / math.max(distance, 1e-6), 0, 1)
		local _, impactVelocity =
			DroppedWeaponRules.Integrate(start, velocity, deltaTime * fraction)
		nextPosition = start + displacement.Unit * result.Distance
		if pointHasNoDrop(nextPosition) then
			local transition =
				assert(MoverItemFlagParticipantRules.ResolveNoDropCollision(participant))
			assert(
				transition.releaseSourceOrder,
				"colliding no-drop Item did not release its source order"
			)
			assert(
				releaseRegisteredMoverDeathDrop(record, summary),
				"colliding no-drop Item did not release its composite"
			)
			return
		end
		nextVelocity, settled = DroppedWeaponRules.Bounce(impactVelocity, result.Normal)
		if settled then
			nextPosition += Vector3.yAxis * DroppedWeaponRules.SurfaceNudge
			nextPosition = Vector3.new(
				DroppedWeaponRules.SnapSourceUnit(nextPosition.X),
				DroppedWeaponRules.SnapSourceUnit(nextPosition.Y),
				DroppedWeaponRules.SnapSourceUnit(nextPosition.Z)
			)
		else
			nextPosition += result.Normal * DroppedWeaponRules.SurfaceNudge
		end
	end
	local nextParticipant = assert(
		MoverItemFlagParticipantRules.ApplyRunItemBody(participant, nextPosition, nextVelocity, nil)
	)
	local nextRecord = cloneMoverDeathDropRecord(
		record,
		nextParticipant,
		currentMilliseconds,
		record.eventStartedAtMilliseconds,
		settled
	)
	replaceMoverDeathDropRecord(record, nextRecord)
	applyMoverDeathDropPresentation(nextRecord)
	scheduleSnapshot()
end

local function runDeathDropInsertionPrepareCleanup(
	cleanup: DeathDropInsertionPrepareCleanup
): string?
	-- Item is the final prepared dependent, so release it before the Dispatcher
	-- proof it consumes, and release Dispatcher before its EntitySlot source.
	-- A partial-Prepare failure has no public handle, so a failed child stops the
	-- reverse walk and retains this private cleanup record for the next Prepare.
	if cleanup.itemPrepared ~= nil and not cleanup.itemAborted then
		if ItemService.AbortPreparedMoverDeathDrop(cleanup.itemPrepared) then
			cleanup.itemAborted = true
		else
			return "death-drop-insertion-item-abort-failed"
		end
	end
	if cleanup.dispatcherPrepared ~= nil and not cleanup.dispatcherAborted then
		if EntityFrameDispatcherService.AbortPreparedDynamicBatch(cleanup.dispatcherPrepared) then
			cleanup.dispatcherAborted = true
		else
			return "death-drop-insertion-dispatcher-abort-failed"
		end
	end
	if cleanup.entitySlotToken ~= nil and not cleanup.entitySlotAborted then
		local aborted, abortError = EntitySlotService.Abort(cleanup.entitySlotToken)
		if aborted then
			cleanup.entitySlotAborted = true
		else
			return abortError or "death-drop-insertion-entity-slot-abort-failed"
		end
	end
	if
		(cleanup.itemPrepared == nil or cleanup.itemAborted)
		and (cleanup.dispatcherPrepared == nil or cleanup.dispatcherAborted)
		and (cleanup.entitySlotToken == nil or cleanup.entitySlotAborted)
	then
		activeDeathDropInsertionPrepareCleanup = nil
	end
	return nil
end

local function abortDeathDropInsertionPrepareChildren(
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	itemPrepared: PreparedMoverDeathDrop?,
	entitySlotToken: EntitySlotService.TransactionToken?
): string?
	local cleanup: DeathDropInsertionPrepareCleanup = {
		dispatcherPrepared = dispatcherPrepared,
		itemPrepared = itemPrepared,
		entitySlotToken = entitySlotToken,
		itemAborted = itemPrepared == nil,
		dispatcherAborted = dispatcherPrepared == nil,
		entitySlotAborted = entitySlotToken == nil,
	}
	activeDeathDropInsertionPrepareCleanup = cleanup
	return runDeathDropInsertionPrepareCleanup(cleanup)
end

local function deathDropInsertionPreparedCurrentError(
	preparedValue: unknown,
	capability: DeathDropInsertionCapability
): string?
	local itemCapability = preparedMoverDeathDropCapabilities[capability.itemPrepared]
	local nextDispatcherBindings = if itemCapability
		then itemCapability.nextDispatcherBindings
		else nil
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or preparedDeathDropInsertionCapabilities[capability.prepared] ~= capability
		or deathDropInsertionReceiptCapabilities[capability.receipt] ~= capability
		or activePreparedDeathDropInsertion ~= capability.prepared
		or not table.isfrozen(capability.prepared)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(capability.summary)
		or capability.operationOrder ~= capability.summary.operationOrder
		or capability.frame ~= capability.summary.frame
		or capability.frameSummary ~= capability.summary.frameSummary
		or capability.request ~= capability.summary.request
		or not table.isfrozen(capability.request)
		or capability.itemSummary ~= capability.summary.itemSummary
		or capability.entitySlotSummary ~= capability.summary.entitySlotSummary
		or capability.dispatcherSummary ~= capability.summary.dispatcherSummary
		or not itemCapability
		or itemCapability.request ~= capability.request
		or itemCapability.summary ~= capability.itemSummary
		or nextDispatcherBindings == nil
		or nextDispatcherBindings[capability.request.dropId] ~= capability.dispatcherBinding
		or capability.dispatcherAborted
		or capability.itemAborted
		or capability.entitySlotAborted
		or AuthoritativeFrameService.GetOpenFrame() ~= capability.frame
		or AuthoritativeFrameService.InspectFrame(capability.frame) ~= capability.frameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			capability.frame,
			capability.frameSummary
		)
		or capability.entitySlotSummary.stepTimeMilliseconds ~= capability.frameSummary.currentTimeMilliseconds
		or not EntitySlotService.ValidatePreparedCommitDependency(
			capability.entitySlotPrepared,
			capability.entitySlotSummary
		)
		or EntitySlotService.InspectPreparedCommitReceipt(capability.entitySlotPrepared) ~= capability.entitySlotReceipt
		or not EntityFrameDispatcherService.ValidatePreparedDynamicBatchDependency(
			capability.dispatcherPrepared,
			capability.dispatcherSummary
		)
		or EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(
			capability.dispatcherPrepared
		) ~= capability.dispatcherReceipt
		or capability.dispatcherSummary.entitySlotSummary ~= capability.entitySlotSummary
		or not ItemService.ValidatePreparedMoverDeathDropDependency(
			capability.itemPrepared,
			capability.itemSummary
		)
	then
		return "stale-prepared-death-drop-insertion"
	end
	return nil
end

local function runDeathDropInsertionPreflight(
	preparedValue: PreparedDeathDropInsertion,
	capability: DeathDropInsertionCapability
): (boolean, string?)
	local currentError = deathDropInsertionPreparedCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local entityCanApply, entityCanApplyError =
		EntitySlotService.CanApplyPrepared(capability.entitySlotPrepared)
	if not entityCanApply then
		return false, entityCanApplyError or "death-drop-insertion-entity-slot-preflight-failed"
	end
	local dispatcherCanApply, dispatcherCanApplyError =
		EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(capability.dispatcherPrepared)
	if not dispatcherCanApply then
		return false, dispatcherCanApplyError or "death-drop-insertion-dispatcher-preflight-failed"
	end
	local itemCanApply, itemCanApplyError =
		ItemService.CanApplyPreparedMoverDeathDrop(capability.itemPrepared)
	if not itemCanApply then
		return false, itemCanApplyError or "death-drop-insertion-item-preflight-failed"
	end
	return true, nil
end

-- Own the complete Item tail for one TossClientItems insertion. Every child is
-- prepared against the exact supplied OPEN frame before this opaque handle is
-- published. SpawnDroppedWeapon is the immediate compatibility wrapper over
-- this same capability; DirectDeath holds it across the preceding core owners.
function ItemService.PrepareDeathDropInsertion(
	requestValue: unknown,
	operationOrderValue: unknown,
	frameValue: unknown,
	frameSummaryValue: unknown
): (
	PreparedDeathDropInsertion?,
	PreparedDeathDropInsertionSummary?,
	string?
)
	if not started then
		return nil, nil, "item-service-not-started"
	end
	local pendingCleanup = activeDeathDropInsertionPrepareCleanup
	if pendingCleanup then
		local cleanupError = runDeathDropInsertionPrepareCleanup(pendingCleanup)
		if cleanupError or activeDeathDropInsertionPrepareCleanup ~= nil then
			return nil, nil, cleanupError or "death-drop-insertion-prepare-cleanup-active"
		end
	end
	if
		type(operationOrderValue) ~= "number"
		or operationOrderValue ~= operationOrderValue
		or math.abs(operationOrderValue) == math.huge
		or operationOrderValue % 1 ~= 0
		or operationOrderValue < 1
		or operationOrderValue > 2_147_483_647
	then
		return nil, nil, "invalid-death-drop-insertion-operation-order"
	end
	if
		type(frameValue) ~= "table"
		or type(frameSummaryValue) ~= "table"
		or AuthoritativeFrameService.GetOpenFrame() ~= frameValue
		or AuthoritativeFrameService.InspectFrame(frameValue) ~= frameSummaryValue
		or not AuthoritativeFrameService.ValidateFrameDependency(frameValue, frameSummaryValue)
	then
		return nil, nil, "invalid-death-drop-insertion-frame"
	end
	if activePreparedDeathDropInsertion ~= nil then
		return nil, nil, "death-drop-insertion-prepare-active"
	end
	if activePreparedMoverParticipantUpdate ~= nil then
		return nil, nil, "item-mover-participant-update-active"
	end
	if
		activePreparedMoverDeathDrop ~= nil
		or #activeSharedMoverDeathDrops > 0
		or moverDeathDropFlushActive
	then
		return nil, nil, "mover-death-drop-owner-unavailable"
	end

	local frame = frameValue :: AuthoritativeFrameService.Frame
	local frameSummary = frameSummaryValue :: AuthoritativeFrameService.Summary
	local entitySlotToken, entitySlotBeginError =
		EntitySlotService.Begin(frameSummary.currentTimeMilliseconds)
	if not entitySlotToken then
		return nil, nil, entitySlotBeginError or "death-drop-insertion-entity-slot-begin-failed"
	end

	local evicted = if moverDeathDropAuthority.count >= DroppedWeaponRules.MaximumLiveDrops
		then moverDeathDropAuthority.order[1]
		else nil
	local evictedBinding = if evicted then moverDeathDropDispatcherBindings[evicted.dropId] else nil
	if evicted then
		if
			not evictedBinding
			or not EntitySlotService.ReleaseWorld(entitySlotToken, evicted.registration)
		then
			local abortError = abortDeathDropInsertionPrepareChildren(nil, nil, entitySlotToken)
			return nil, nil, abortError or "death-drop-insertion-eviction-release-failed"
		end
	end

	local registration, allocationError =
		EntitySlotService.AllocateWorld(entitySlotToken, "dropped_item")
	if not registration then
		local abortError = abortDeathDropInsertionPrepareChildren(nil, nil, entitySlotToken)
		return nil, nil, abortError or allocationError or "death-drop-insertion-allocation-failed"
	end
	local lease = EntitySlotService.GetWorldLease(registration, entitySlotToken)
	if not lease then
		local abortError = abortDeathDropInsertionPrepareChildren(nil, nil, entitySlotToken)
		return nil, nil, abortError or "death-drop-insertion-lease-unavailable"
	end

	local itemPrepared, itemSummary, itemPrepareError = ItemService.PrepareMoverDeathDrop(
		requestValue,
		operationOrderValue,
		frameSummary.currentTimeMilliseconds,
		entitySlotToken,
		registration,
		lease,
		if evicted then evicted.registration else nil,
		if evicted then evicted.lease else nil
	)
	if not itemPrepared or not itemSummary then
		local abortError =
			abortDeathDropInsertionPrepareChildren(nil, itemPrepared, entitySlotToken)
		return nil,
			nil,
			abortError or itemPrepareError or "death-drop-insertion-item-prepare-failed"
	end

	local entitySlotPrepared, entitySlotPrepareError = EntitySlotService.Prepare(entitySlotToken)
	if not entitySlotPrepared then
		local abortError =
			abortDeathDropInsertionPrepareChildren(nil, itemPrepared, entitySlotToken)
		return nil,
			nil,
			abortError
				or entitySlotPrepareError
				or "death-drop-insertion-entity-slot-prepare-failed"
	end
	local entitySlotSummary = EntitySlotService.InspectPreparedCommitSummary(entitySlotPrepared)
	local entitySlotReceipt = EntitySlotService.InspectPreparedCommitReceipt(entitySlotPrepared)
	if
		not entitySlotSummary
		or not entitySlotReceipt
		or not ItemService.BindPreparedMoverDeathDropEntitySlotDependency(
			itemPrepared,
			entitySlotPrepared,
			entitySlotSummary
		)
	then
		local abortError =
			abortDeathDropInsertionPrepareChildren(nil, itemPrepared, entitySlotToken)
		return nil, nil, abortError or "death-drop-insertion-entity-slot-dependency-failed"
	end

	local dispatcherOperations: { EntityFrameDispatcherService.DynamicOperation } = {}
	if evicted and evictedBinding then
		table.insert(dispatcherOperations, {
			kind = "Unbind",
			registration = evicted.registration,
			binding = evictedBinding,
		})
	end
	table.insert(dispatcherOperations, {
		kind = "Bind",
		registration = registration,
		declaredKind = "DroppedItem",
		handler = runRegisteredMoverDeathDrop,
	})
	local dispatcherPrepared, dispatcherSummary, dispatcherPrepareError =
		EntityFrameDispatcherService.PrepareDynamicBatch(
			entitySlotPrepared,
			entitySlotSummary,
			dispatcherOperations
		)
	if not dispatcherPrepared or not dispatcherSummary then
		local abortError = abortDeathDropInsertionPrepareChildren(
			dispatcherPrepared,
			itemPrepared,
			entitySlotToken
		)
		return nil,
			nil,
			abortError or dispatcherPrepareError or "death-drop-insertion-dispatcher-prepare-failed"
	end
	local dispatcherReceipt =
		EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared)
	if
		not dispatcherReceipt
		or not ItemService.BindPreparedMoverDeathDropDispatcherDependency(
			itemPrepared,
			dispatcherPrepared,
			dispatcherSummary
		)
	then
		local abortError = abortDeathDropInsertionPrepareChildren(
			dispatcherPrepared,
			itemPrepared,
			entitySlotToken
		)
		return nil, nil, abortError or "death-drop-insertion-dispatcher-dependency-failed"
	end

	local itemCapability = preparedMoverDeathDropCapabilities[itemPrepared]
	local itemReceipt = if itemCapability then itemCapability.receipt else nil
	local dispatcherBinding = if itemCapability and itemCapability.nextDispatcherBindings
		then itemCapability.nextDispatcherBindings[itemSummary.dropId]
		else nil
	if
		not itemCapability
		or itemCapability.summary ~= itemSummary
		or not dispatcherBinding
		or not itemReceipt
		or moverDeathDropReceiptCapabilities[itemReceipt] == nil
	then
		local abortError = abortDeathDropInsertionPrepareChildren(
			dispatcherPrepared,
			itemPrepared,
			entitySlotToken
		)
		return nil, nil, abortError or "death-drop-insertion-item-receipt-unavailable"
	end
	local request = itemCapability.request

	local summary: PreparedDeathDropInsertionSummary = {
		operationOrder = operationOrderValue :: number,
		frame = frame,
		frameSummary = frameSummary,
		request = request,
		itemSummary = itemSummary,
		entitySlotSummary = entitySlotSummary,
		dispatcherSummary = dispatcherSummary,
	}
	table.freeze(summary)
	local prepared: PreparedDeathDropInsertion = table.freeze({})
	local receipt: DeathDropInsertionApplyReceipt = table.freeze({})
	local capability: DeathDropInsertionCapability = {
		prepared = prepared,
		receipt = receipt,
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		operationOrder = operationOrderValue :: number,
		frame = frame,
		frameSummary = frameSummary,
		request = request,
		entitySlotToken = entitySlotToken,
		entitySlotPrepared = entitySlotPrepared,
		entitySlotSummary = entitySlotSummary,
		entitySlotReceipt = entitySlotReceipt,
		dispatcherPrepared = dispatcherPrepared,
		dispatcherSummary = dispatcherSummary,
		dispatcherReceipt = dispatcherReceipt,
		itemPrepared = itemPrepared,
		itemSummary = itemSummary,
		itemReceipt = itemReceipt,
		dispatcherBinding = dispatcherBinding,
		summary = summary,
		dispatcherAborted = false,
		itemAborted = false,
		entitySlotAborted = false,
	}
	preparedDeathDropInsertionCapabilities[prepared] = capability
	deathDropInsertionReceiptCapabilities[receipt] = capability
	activePreparedDeathDropInsertion = prepared
	return prepared, summary, nil
end

function ItemService.InspectPreparedDeathDropInsertion(
	preparedValue: unknown
): PreparedDeathDropInsertionSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability =
		preparedDeathDropInsertionCapabilities[preparedValue :: PreparedDeathDropInsertion]
	if
		not capability
		or deathDropInsertionPreparedCurrentError(preparedValue, capability) ~= nil
	then
		return nil
	end
	return capability.summary
end

function ItemService.ValidatePreparedDeathDropInsertionDependency(
	preparedValue: unknown,
	summaryValue: unknown
): boolean
	local summary = ItemService.InspectPreparedDeathDropInsertion(preparedValue)
	return summary ~= nil and summary == summaryValue
end

function ItemService.CanApplyPreparedDeathDropInsertion(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-death-drop-insertion"
	end
	local prepared = preparedValue :: PreparedDeathDropInsertion
	local capability = preparedDeathDropInsertionCapabilities[prepared]
	if not capability then
		return false, "invalid-prepared-death-drop-insertion"
	end
	capability.applyValidated = false
	local canApply, canApplyError = runDeathDropInsertionPreflight(prepared, capability)
	if not canApply then
		return false, canApplyError
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	capability.applyValidated = true
	return true, nil
end

function ItemService.ApplyPreparedDeathDropInsertion(
	preparedValue: unknown
): DeathDropInsertionApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-death-drop-insertion")
	local prepared = preparedValue :: PreparedDeathDropInsertion
	local capability = assert(
		preparedDeathDropInsertionCapabilities[prepared],
		"invalid-prepared-death-drop-insertion"
	)
	assert(capability.applyValidated, "prepared-death-drop-insertion-not-validated")
	assert(
		capability.preflightPassCount >= 2,
		"prepared death-drop insertion requires two complete preflight passes"
	)
	capability.applyValidated = false

	-- The caller has already run two whole-composite passes immediately before
	-- its first authority write. Do not call CanApply again here: a direct-death
	-- coordinator reaches this tail only after its preceding owner assignments.
	local appliedEntitySlotReceipt = EntitySlotService.ApplyPrepared(capability.entitySlotPrepared)
	assert(
		appliedEntitySlotReceipt == capability.entitySlotReceipt,
		"death-drop insertion EntitySlot receipt drifted"
	)
	local appliedDispatcherReceipt =
		EntityFrameDispatcherService.ApplyPreparedDynamicBatch(capability.dispatcherPrepared)
	assert(
		appliedDispatcherReceipt == capability.dispatcherReceipt,
		"death-drop insertion Dispatcher receipt drifted"
	)
	local appliedItemReceipt = ItemService.ApplyPreparedMoverDeathDrop(
		capability.itemPrepared,
		appliedEntitySlotReceipt,
		appliedDispatcherReceipt
	)
	assert(
		appliedItemReceipt == capability.itemReceipt,
		"death-drop insertion Item receipt drifted"
	)

	-- Keep the outer slot through Flush. This prevents a second insertion from
	-- retiring the exact applied EntitySlot/Dispatcher witnesses before the
	-- first insertion has published its already-prebuilt presentation.
	capability.status = "Applied"
	return capability.receipt
end

local function validateAppliedDeathDropInsertion(
	receiptValue: unknown,
	summaryValue: unknown
): (DeathDropInsertionCapability?, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return nil, "invalid-applied-death-drop-insertion-dependency"
	end
	local receipt = receiptValue :: DeathDropInsertionApplyReceipt
	local capability = deathDropInsertionReceiptCapabilities[receipt]
	if
		not capability
		or capability.receipt ~= receipt
		or capability.status ~= "Applied"
		or capability.summary ~= summaryValue
		or preparedDeathDropInsertionCapabilities[capability.prepared] ~= capability
		or activePreparedDeathDropInsertion ~= capability.prepared
		or not table.isfrozen(receipt)
		or not table.isfrozen(capability.summary)
		or capability.summary.request ~= capability.request
		or not table.isfrozen(capability.request)
		or AuthoritativeFrameService.GetOpenFrame() ~= capability.frame
		or AuthoritativeFrameService.InspectFrame(capability.frame) ~= capability.frameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			capability.frame,
			capability.frameSummary
		)
	then
		return nil, "stale-applied-death-drop-insertion"
	end
	local entityApplied, entityAppliedError = EntitySlotService.ValidateAppliedCommitDependency(
		capability.entitySlotReceipt,
		capability.entitySlotSummary
	)
	if not entityApplied then
		return nil, entityAppliedError or "death-drop-insertion-entity-slot-dependency-not-applied"
	end
	local dispatcherApplied, dispatcherAppliedError =
		EntityFrameDispatcherService.ValidateAppliedDynamicBatchDependency(
			capability.dispatcherReceipt,
			capability.dispatcherSummary
		)
	if not dispatcherApplied then
		return nil,
			dispatcherAppliedError or "death-drop-insertion-dispatcher-dependency-not-applied"
	end
	local itemReceiptCapability = moverDeathDropReceiptCapabilities[capability.itemReceipt]
	local itemRecord = moverDeathDropAuthority.recordsById[capability.itemSummary.dropId]
	if
		not itemReceiptCapability
		or itemReceiptCapability.receipt ~= capability.itemReceipt
		or itemReceiptCapability.status ~= "Applied"
		or itemReceiptCapability.record ~= itemRecord
		or not itemRecord
		or itemRecord.registration ~= capability.itemSummary.registration
		or itemRecord.lease ~= capability.itemSummary.lease
		or itemRecord.dropId ~= capability.request.dropId
		or itemRecord.matchId ~= capability.request.matchId
		or itemRecord.itemId ~= capability.request.itemId
		or itemRecord.quantity ~= capability.request.quantity
		or itemRecord.participant.body.position ~= capability.request.position
		or itemRecord.participant.body.velocity ~= capability.request.velocity
		or moverDeathDropDispatcherBindings[itemRecord.dropId] ~= capability.dispatcherBinding
	then
		return nil, "death-drop-insertion-item-dependency-not-applied"
	end
	return capability, nil
end

function ItemService.ValidateAppliedDeathDropInsertionDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, dependencyError =
		validateAppliedDeathDropInsertion(receiptValue, summaryValue)
	return capability ~= nil, dependencyError
end

function ItemService.FlushPreparedDeathDropInsertion(
	receiptValue: unknown
): (MoverDeathDropPublicationReport?, string?)
	if type(receiptValue) ~= "table" then
		return nil, "invalid-death-drop-insertion-receipt"
	end
	local receipt = receiptValue :: DeathDropInsertionApplyReceipt
	local capability = deathDropInsertionReceiptCapabilities[receipt]
	if not capability then
		return nil, "invalid-death-drop-insertion-receipt"
	end
	local applied, appliedError = validateAppliedDeathDropInsertion(receipt, capability.summary)
	if not applied then
		return nil, appliedError
	end
	capability.status = "Flushing"
	local drained, drainError = EntitySlotService.DrainPendingPlayerReleases()
	if not drained then
		warnHook(drainError or "post-death-drop-insertion player drain failed")
	end
	local report, publicationError = ItemService.FlushPreparedMoverDeathDrop(capability.itemReceipt)
	if not report then
		capability.status = "Applied"
		return nil, publicationError or "death-drop-insertion-publication-failed"
	end
	capability.status = "Flushed"
	preparedDeathDropInsertionCapabilities[capability.prepared] = nil
	deathDropInsertionReceiptCapabilities[receipt] = nil
	if activePreparedDeathDropInsertion == capability.prepared then
		activePreparedDeathDropInsertion = nil
	end
	return report, nil
end

-- Retryable child abort. A later call resumes after the last successful child,
-- preserving dependency-safe reverse order: Item -> Dispatcher -> EntitySlot.
function ItemService.AbortPreparedDeathDropInsertion(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-death-drop-insertion"
	end
	local prepared = preparedValue :: PreparedDeathDropInsertion
	local capability = preparedDeathDropInsertionCapabilities[prepared]
	if not capability then
		if retiredDeathDropInsertionAborts[prepared] ~= nil then
			return true, nil
		end
		return false, "invalid-prepared-death-drop-insertion"
	end
	if capability.status ~= "Prepared" and capability.status ~= "Aborting" then
		return false, "invalid-prepared-death-drop-insertion-status"
	end
	capability.status = "Aborting"
	capability.applyValidated = false
	if not capability.itemAborted then
		if not ItemService.AbortPreparedMoverDeathDrop(capability.itemPrepared) then
			return false, "death-drop-insertion-item-abort-failed"
		end
		capability.itemAborted = true
	end
	if not capability.dispatcherAborted then
		if
			not EntityFrameDispatcherService.AbortPreparedDynamicBatch(
				capability.dispatcherPrepared
			)
		then
			return false, "death-drop-insertion-dispatcher-abort-failed"
		end
		capability.dispatcherAborted = true
	end
	if not capability.entitySlotAborted then
		local aborted, abortError = EntitySlotService.Abort(capability.entitySlotToken)
		if not aborted then
			return false, abortError or "death-drop-insertion-entity-slot-abort-failed"
		end
		capability.entitySlotAborted = true
	end
	capability.status = "Aborted"
	retiredDeathDropInsertionAborts[prepared] = capability.summary
	preparedDeathDropInsertionCapabilities[prepared] = nil
	deathDropInsertionReceiptCapabilities[capability.receipt] = nil
	if activePreparedDeathDropInsertion == prepared then
		activePreparedDeathDropInsertion = nil
	end
	return true, nil
end

-- Ordinary direct deaths share the same retained multi-drop machinery as a
-- mover callback, but hold it behind one opaque child capability. This keeps
-- weapon -> PW_QUAD..PW_FLIGHT registration in one EntitySlot/Dispatcher/Item
-- transaction that can be completely preflighted before Combat applies death.
local directDeathDropBatchCoordinator =
	MoverParticipantCoordinatorService.Create({ moverParticipantUpdateAdapter })

local function cleanupOpenDeathDropBatch(): (boolean, string?)
	for index = #activeSharedMoverDeathDrops, 1, -1 do
		if not ItemService.AbortPreparedMoverDeathDrop(activeSharedMoverDeathDrops[index]) then
			return false, "death-drop-batch-item-abort-failed"
		end
	end
	if MoverParticipantReleaseBrokerService.GetActiveToken() ~= nil then
		if not directDeathDropBatchCoordinator.AbortFrame() then
			return false, "death-drop-batch-broker-abort-failed"
		end
	end
	return true, nil
end

local function preparedDeathDropBatchCurrentError(
	preparedValue: unknown,
	capability: DeathDropBatchCapability
): string?
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or activePreparedDeathDropBatch ~= preparedValue
		or preparedDeathDropBatchCapabilities[preparedValue :: PreparedDeathDropBatch] ~= capability
		or deathDropBatchReceiptCapabilities[capability.receipt] ~= capability
		or capability.coordinatorReceipt ~= nil
		or activePreparedMoverParticipantUpdate ~= capability.itemParticipantPrepared
		or preparedMoverParticipantUpdateCapabilities[capability.itemParticipantPrepared] ~= capability.itemParticipantCapability
		or capability.itemParticipantCapability.status ~= "Prepared"
		or capability.itemParticipantCapability.nextAuthority ~= capability.expectedAuthority
		or capability.itemParticipantCapability.nextDispatcherBindings ~= capability.expectedDispatcherBindings
		or AuthoritativeFrameService.GetOpenFrame() ~= capability.frame
		or AuthoritativeFrameService.InspectFrame(capability.frame) ~= capability.frameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			capability.frame,
			capability.frameSummary
		)
		or MoverParticipantReleaseBrokerService.GetActiveToken() == nil
		or #capability.requests ~= #capability.itemPrepareds
		or #capability.requests ~= #capability.itemSummaries
		or #activeSharedMoverDeathDrops ~= #capability.itemPrepareds
		or not table.isfrozen(capability.prepared)
		or not table.isfrozen(capability.receipt)
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(capability.requests)
		or not table.isfrozen(capability.itemPrepareds)
		or not table.isfrozen(capability.itemSummaries)
		or capability.summary.operationOrder ~= capability.operationOrder
		or capability.summary.frame ~= capability.frame
		or capability.summary.frameSummary ~= capability.frameSummary
		or capability.summary.requests ~= capability.requests
		or capability.summary.itemSummaries ~= capability.itemSummaries
	then
		return "stale-prepared-death-drop-batch"
	end
	for index, itemPrepared in capability.itemPrepareds do
		local itemCapability = preparedMoverDeathDropCapabilities[itemPrepared]
		local itemSummary = capability.itemSummaries[index]
		if
			activeSharedMoverDeathDrops[index] ~= itemPrepared
			or activeSharedMoverDeathDropCapabilities[itemPrepared] ~= itemCapability
			or not itemCapability
			or itemCapability.request ~= capability.requests[index]
			or itemCapability.summary ~= itemSummary
			or itemSummary.operationOrder ~= capability.operationOrder
			or preparedMoverDeathDropCurrentError(itemPrepared, itemCapability) ~= nil
		then
			return "stale-prepared-death-drop-batch-item"
		end
	end
	return nil
end

function ItemService.PrepareDeathDropBatch(
	requestsValue: unknown,
	operationOrderValue: unknown,
	frameValue: unknown,
	frameSummaryValue: unknown
): (
	PreparedDeathDropBatch?,
	PreparedDeathDropBatchSummary?,
	string?
)
	if not started then
		return nil, nil, "item-service-not-started"
	end
	if
		type(operationOrderValue) ~= "number"
		or operationOrderValue ~= operationOrderValue
		or math.abs(operationOrderValue) == math.huge
		or operationOrderValue % 1 ~= 0
		or operationOrderValue < 1
		or operationOrderValue > 2_147_483_647
	then
		return nil, nil, "invalid-death-drop-batch-operation-order"
	end
	if
		type(frameValue) ~= "table"
		or type(frameSummaryValue) ~= "table"
		or AuthoritativeFrameService.GetOpenFrame() ~= frameValue
		or AuthoritativeFrameService.InspectFrame(frameValue) ~= frameSummaryValue
		or not AuthoritativeFrameService.ValidateFrameDependency(frameValue, frameSummaryValue)
	then
		return nil, nil, "invalid-death-drop-batch-frame"
	end
	if type(requestsValue) ~= "table" or not table.isfrozen(requestsValue :: any) then
		return nil, nil, "death-drop-batch-requests-not-frozen-array"
	end
	local requestedCount = #(requestsValue :: { unknown })
	if requestedCount < 1 or requestedCount > 7 then
		return nil, nil, "death-drop-batch-request-count-invalid"
	end
	local observedRequestCount = 0
	for key, request in requestsValue :: { [unknown]: unknown } do
		if
			type(key) ~= "number"
			or key % 1 ~= 0
			or key < 1
			or key > requestedCount
			or type(request) ~= "table"
			or not table.isfrozen(request :: any)
		then
			return nil, nil, "death-drop-batch-requests-not-dense-frozen-array"
		end
		observedRequestCount += 1
	end
	if observedRequestCount ~= requestedCount then
		return nil, nil, "death-drop-batch-requests-not-dense-frozen-array"
	end
	if
		activePreparedDeathDropBatch ~= nil
		or activePreparedMoverParticipantUpdate ~= nil
		or activePreparedMoverDeathDrop ~= nil
		or #activeSharedMoverDeathDrops > 0
		or activePreparedDeathDropInsertion ~= nil
		or activeDeathDropInsertionPrepareCleanup ~= nil
		or moverDeathDropFlushActive
		or MoverParticipantReleaseBrokerService.GetActiveToken() ~= nil
	then
		return nil, nil, "death-drop-batch-owner-unavailable"
	end

	local frame = frameValue :: AuthoritativeFrameService.Frame
	local frameSummary = frameSummaryValue :: AuthoritativeFrameService.Summary
	local began, beginError =
		directDeathDropBatchCoordinator.BeginFrame(frameSummary.currentTimeMilliseconds)
	if not began then
		return nil, nil, beginError or "death-drop-batch-broker-begin-failed"
	end

	local itemPrepareds: { PreparedMoverDeathDrop } = {}
	local itemSummaries: { PreparedMoverDeathDropSummary } = {}
	local requests: { DeathDropRequest } = {}
	local insertions: { MoverConsequenceRules.InsertionDescriptor } = {}
	for requestIndex, request in requestsValue :: { unknown } do
		local previousSharedCount = #activeSharedMoverDeathDrops
		local body, stageError =
			ItemService.StageSynchronousMoverDeathDrop(request, operationOrderValue)
		local itemPrepared = activeSharedMoverDeathDrops[#activeSharedMoverDeathDrops]
		local itemCapability = if itemPrepared
			then activeSharedMoverDeathDropCapabilities[itemPrepared]
			else nil
		if
			not body
			or #activeSharedMoverDeathDrops ~= previousSharedCount + 1
			or not itemPrepared
			or not itemCapability
			or itemCapability.summary.participant.body ~= body
		then
			local cleaned, cleanupError = cleanupOpenDeathDropBatch()
			return nil,
				nil,
				if not cleaned
					then cleanupError or "death-drop-batch-stage-cleanup-failed"
					else stageError or string.format(
						"death-drop-batch-item-%d-stage-failed",
						requestIndex
					)
		end
		table.insert(itemPrepareds, itemPrepared)
		table.insert(itemSummaries, itemCapability.summary)
		table.insert(requests, itemCapability.request)
		table.insert(insertions, itemCapability.summary.insertion)
	end
	local orderedInsertions, insertionOrderError =
		MoverConsequenceRules.ValidateAndOrderInsertions(insertions)
	if not orderedInsertions then
		local cleaned, cleanupError = cleanupOpenDeathDropBatch()
		return nil,
			nil,
			if not cleaned
				then cleanupError or "death-drop-batch-order-cleanup-failed"
				else insertionOrderError or "death-drop-batch-order-invalid"
	end
	for index, insertion in orderedInsertions do
		-- ValidateAndOrderInsertions reconstructs every descriptor as a canonical,
		-- frozen value, so reference identity can never match the staged input.
		-- Body ids are unique within the validated batch and preserve the exact
		-- Q3 TossClientItems weapon -> powerup order across that reconstruction.
		if insertion.body.id ~= insertions[index].body.id then
			local cleaned, cleanupError = cleanupOpenDeathDropBatch()
			return nil,
				nil,
				if not cleaned
					then cleanupError or "death-drop-batch-order-cleanup-failed"
					else "death-drop-batch-order-noncanonical"
		end
	end
	table.freeze(itemPrepareds)
	table.freeze(itemSummaries)
	table.freeze(requests)
	table.freeze(insertions)

	local collection = directDeathDropBatchCoordinator.Collect()
	local coordinatorPrepared, coordinatorPrepareError =
		directDeathDropBatchCoordinator.Prepare(collection.bodies)
	if not coordinatorPrepared then
		local cleaned, cleanupError = cleanupOpenDeathDropBatch()
		return nil,
			nil,
			if not cleaned
				then cleanupError or "death-drop-batch-prepare-cleanup-failed"
				else coordinatorPrepareError or "death-drop-batch-coordinator-prepare-failed"
	end
	local itemParticipantPrepared = activePreparedMoverParticipantUpdate
	local itemParticipantCapability = if itemParticipantPrepared
		then preparedMoverParticipantUpdateCapabilities[itemParticipantPrepared]
		else nil
	if
		not itemParticipantPrepared
		or not itemParticipantCapability
		or itemParticipantCapability.status ~= "Prepared"
		or #itemParticipantCapability.sharedDeathDropPrepareds ~= requestedCount
	then
		assert(
			directDeathDropBatchCoordinator.Abort(coordinatorPrepared),
			"death-drop batch could not abort an incomplete participant prepare"
		)
		return nil, nil, "death-drop-batch-participant-prepare-incomplete"
	end

	local summary: PreparedDeathDropBatchSummary = {
		operationOrder = operationOrderValue :: number,
		frame = frame,
		frameSummary = frameSummary,
		requests = requests,
		itemSummaries = itemSummaries,
	}
	table.freeze(summary)
	local prepared: PreparedDeathDropBatch = table.freeze({})
	local receipt: DeathDropBatchApplyReceipt = table.freeze({})
	local capability: DeathDropBatchCapability = {
		prepared = prepared,
		receipt = receipt,
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		operationOrder = operationOrderValue :: number,
		frame = frame,
		frameSummary = frameSummary,
		requests = requests,
		itemPrepareds = itemPrepareds,
		itemSummaries = itemSummaries,
		itemParticipantPrepared = itemParticipantPrepared,
		itemParticipantCapability = itemParticipantCapability,
		expectedAuthority = itemParticipantCapability.nextAuthority,
		expectedDispatcherBindings = itemParticipantCapability.nextDispatcherBindings,
		coordinatorPrepared = coordinatorPrepared,
		coordinatorReceipt = nil,
		summary = summary,
	}
	preparedDeathDropBatchCapabilities[prepared] = capability
	deathDropBatchReceiptCapabilities[receipt] = capability
	activePreparedDeathDropBatch = prepared
	return prepared, summary, nil
end

function ItemService.InspectPreparedDeathDropBatch(
	preparedValue: unknown
): PreparedDeathDropBatchSummary?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = preparedDeathDropBatchCapabilities[preparedValue :: PreparedDeathDropBatch]
	if not capability or preparedDeathDropBatchCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

function ItemService.ValidatePreparedDeathDropBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): boolean
	if type(summaryValue) ~= "table" then
		return false
	end
	local summary = ItemService.InspectPreparedDeathDropBatch(preparedValue)
	return summary ~= nil and summary == summaryValue
end

function ItemService.CanApplyPreparedDeathDropBatch(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-death-drop-batch"
	end
	local capability = preparedDeathDropBatchCapabilities[preparedValue :: PreparedDeathDropBatch]
	if not capability then
		return false, "invalid-prepared-death-drop-batch"
	end
	local currentError = preparedDeathDropBatchCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local canApply, applyError =
		directDeathDropBatchCoordinator.CanApply(capability.coordinatorPrepared)
	if not canApply then
		return false, applyError or "death-drop-batch-coordinator-preflight-failed"
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	capability.applyValidated = true
	return true, nil
end

function ItemService.ApplyPreparedDeathDropBatch(preparedValue: unknown): DeathDropBatchApplyReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-death-drop-batch")
	local prepared = preparedValue :: PreparedDeathDropBatch
	local capability =
		assert(preparedDeathDropBatchCapabilities[prepared], "invalid-prepared-death-drop-batch")
	assert(
		capability.applyValidated
			and capability.preflightPassCount >= 2
			and preparedDeathDropBatchCurrentError(prepared, capability) == nil,
		"stale-prepared-death-drop-batch-at-apply"
	)
	capability.coordinatorReceipt =
		directDeathDropBatchCoordinator.Apply(capability.coordinatorPrepared)
	assert(
		moverDeathDropAuthority == capability.expectedAuthority
			and moverDeathDropDispatcherBindings == capability.expectedDispatcherBindings
			and capability.itemParticipantCapability.status == "Applied"
			and moverParticipantUpdateReceiptCapabilities[capability.itemParticipantCapability.receipt]
				== capability.itemParticipantCapability,
		"death-drop-batch-authority-drifted-at-apply"
	)
	capability.status = "Applied"
	capability.applyValidated = false
	preparedDeathDropBatchCapabilities[prepared] = nil
	return capability.receipt
end

local function validateAppliedDeathDropBatch(
	receiptValue: unknown,
	summaryValue: unknown
): (DeathDropBatchCapability?, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return nil, "invalid-applied-death-drop-batch"
	end
	local capability = deathDropBatchReceiptCapabilities[receiptValue :: DeathDropBatchApplyReceipt]
	if
		not capability
		or capability.status ~= "Applied"
		or capability.receipt ~= receiptValue
		or capability.summary ~= summaryValue
		or activePreparedDeathDropBatch ~= capability.prepared
		or capability.coordinatorReceipt == nil
		or moverDeathDropAuthority ~= capability.expectedAuthority
		or moverDeathDropDispatcherBindings ~= capability.expectedDispatcherBindings
		or capability.itemParticipantCapability.status ~= "Applied"
		or moverParticipantUpdateReceiptCapabilities[capability.itemParticipantCapability.receipt] ~= capability.itemParticipantCapability
		or AuthoritativeFrameService.GetOpenFrame() ~= capability.frame
		or AuthoritativeFrameService.InspectFrame(capability.frame) ~= capability.frameSummary
		or not AuthoritativeFrameService.ValidateFrameDependency(
			capability.frame,
			capability.frameSummary
		)
		or #capability.itemParticipantCapability.sharedDeathDropReceipts ~= #capability.requests
	then
		return nil, "stale-applied-death-drop-batch"
	end
	for index, request in capability.requests do
		local record = capability.expectedAuthority.recordsById[request.dropId]
		local itemReceipt = capability.itemParticipantCapability.sharedDeathDropReceipts[index]
		local receiptCapability = moverDeathDropReceiptCapabilities[itemReceipt]
		if
			not record
			or record.dropId ~= request.dropId
			or record.matchId ~= request.matchId
			or record.itemId ~= request.itemId
			or record.quantity ~= request.quantity
			or record.participant.body.position ~= request.position
			or record.participant.body.velocity ~= request.velocity
			or not receiptCapability
			or receiptCapability.status ~= "Applied"
			or receiptCapability.record ~= record
		then
			return nil, "stale-applied-death-drop-batch-item"
		end
	end
	return capability, nil
end

function ItemService.ValidateAppliedDeathDropBatchDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, dependencyError = validateAppliedDeathDropBatch(receiptValue, summaryValue)
	return capability ~= nil, dependencyError
end

function ItemService.FlushPreparedDeathDropBatch(
	receiptValue: unknown
): (DeathDropBatchPublicationReport?, string?)
	local receipt = if type(receiptValue) == "table"
		then receiptValue :: DeathDropBatchApplyReceipt
		else nil
	local capability = if receipt then deathDropBatchReceiptCapabilities[receipt] else nil
	if not receipt or not capability then
		return nil, "invalid-death-drop-batch-receipt"
	end
	local applied, appliedError = validateAppliedDeathDropBatch(receipt, capability.summary)
	if not applied then
		return nil, appliedError
	end
	if not directDeathDropBatchCoordinator.Flush(capability.coordinatorReceipt) then
		return nil, "death-drop-batch-publication-failed"
	end
	local insertedCount = 0
	for _, request in capability.requests do
		local record = moverDeathDropAuthority.recordsById[request.dropId]
		if
			record
			and record.matchId == request.matchId
			and record.itemId == request.itemId
			and record.quantity == request.quantity
		then
			insertedCount += 1
		end
	end
	assert(
		insertedCount == #capability.requests,
		"death-drop batch committed fewer records than requested"
	)
	local itemCapability = capability.itemParticipantCapability
	local report: DeathDropBatchPublicationReport = {
		authorityApplied = true,
		requestedCount = #capability.requests,
		insertedCount = insertedCount,
		attemptedPublicationCount = itemCapability.sharedDeathDropAttemptedPublicationCount,
		faultCount = itemCapability.sharedDeathDropPublicationFaultCount,
		markerCreatedCount = itemCapability.sharedDeathDropMarkerCreatedCount,
	}
	table.freeze(report)
	capability.status = "Flushed"
	deathDropBatchReceiptCapabilities[receipt] = nil
	activePreparedDeathDropBatch = nil
	return report, nil
end

function ItemService.AbortPreparedDeathDropBatch(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-death-drop-batch"
	end
	local prepared = preparedValue :: PreparedDeathDropBatch
	local capability = preparedDeathDropBatchCapabilities[prepared]
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-prepared-death-drop-batch"
	end
	capability.applyValidated = false
	capability.preflightPassCount = 0
	if not directDeathDropBatchCoordinator.Abort(capability.coordinatorPrepared) then
		return false, "death-drop-batch-coordinator-abort-failed"
	end
	capability.status = "Aborted"
	preparedDeathDropBatchCapabilities[prepared] = nil
	deathDropBatchReceiptCapabilities[capability.receipt] = nil
	activePreparedDeathDropBatch = nil
	return true, nil
end

local preparedDeathDropInsertionAdapter: PreparedDeathDropInsertionAdapter = table.freeze({
	StageSynchronousMover = ItemService.StageSynchronousMoverDeathDrop,
	Prepare = ItemService.PrepareDeathDropInsertion,
	InspectPrepared = ItemService.InspectPreparedDeathDropInsertion,
	ValidatePreparedDependency = ItemService.ValidatePreparedDeathDropInsertionDependency,
	CanApplyPrepared = ItemService.CanApplyPreparedDeathDropInsertion,
	ApplyPrepared = ItemService.ApplyPreparedDeathDropInsertion,
	ValidateAppliedDependency = ItemService.ValidateAppliedDeathDropInsertionDependency,
	FlushPrepared = ItemService.FlushPreparedDeathDropInsertion,
	AbortPrepared = ItemService.AbortPreparedDeathDropInsertion,
	PrepareBatch = ItemService.PrepareDeathDropBatch,
	InspectPreparedBatch = ItemService.InspectPreparedDeathDropBatch,
	ValidatePreparedBatchDependency = ItemService.ValidatePreparedDeathDropBatchDependency,
	CanApplyPreparedBatch = ItemService.CanApplyPreparedDeathDropBatch,
	ApplyPreparedBatch = ItemService.ApplyPreparedDeathDropBatch,
	ValidateAppliedBatchDependency = ItemService.ValidateAppliedDeathDropBatchDependency,
	FlushPreparedBatch = ItemService.FlushPreparedDeathDropBatch,
	AbortPreparedBatch = ItemService.AbortPreparedDeathDropBatch,
})

function ItemService.GetPreparedDeathDropInsertionAdapter(): PreparedDeathDropInsertionAdapter
	return preparedDeathDropInsertionAdapter
end

function ItemService.SpawnDroppedWeapon(request: DeathDropRequest): boolean
	assert(started, "ItemService must be started before SpawnDroppedWeapon")
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	if not openFrame then
		return false
	end
	local frameSummary = inspectOpenFrame(openFrame, "ItemService.SpawnDroppedWeapon")
	local prepared, summary =
		ItemService.PrepareDeathDropInsertion(request, 1, openFrame, frameSummary)
	if not prepared or not summary then
		return false
	end
	for _pass = 1, 2 do
		local canApply = ItemService.CanApplyPreparedDeathDropInsertion(prepared)
		if not canApply then
			local aborted, abortError = ItemService.AbortPreparedDeathDropInsertion(prepared)
			assert(aborted, abortError or "death-drop insertion preflight cleanup failed")
			return false
		end
	end
	local receipt = ItemService.ApplyPreparedDeathDropInsertion(prepared)
	local applied, appliedError =
		ItemService.ValidateAppliedDeathDropInsertionDependency(receipt, summary)
	assert(applied, appliedError or "death-drop insertion applied dependency drifted")
	local publication, publicationError = ItemService.FlushPreparedDeathDropInsertion(receipt)
	assert(publication, publicationError or "death-drop insertion publication failed")
	return publication.authorityApplied
end

function ItemService.GetDeathDropCount(): number
	return deathDropCount + moverDeathDropAuthority.count
end

function ItemService.RequestMoverDeathDropCleanup(
	dropIdValue: unknown,
	reasonValue: unknown
): boolean
	if
		type(dropIdValue) ~= "string"
		or (reasonValue ~= "Match" and reasonValue ~= "NoDrop" and reasonValue ~= "Cleanup")
	then
		return false
	end
	local dropId = dropIdValue :: string
	local record = moverDeathDropAuthority.recordsById[dropId]
	if not record then
		return false
	end
	moverDeathDropCleanupIntents[dropId] = reasonValue :: MoverDeathDropCleanupReason
	applyMoverDeathDropPresentation(record)
	scheduleSnapshot()
	return true
end

local function requestAllMoverDeathDropCleanup(reason: MoverDeathDropCleanupReason)
	for _, record in moverDeathDropAuthority.order do
		moverDeathDropCleanupIntents[record.dropId] = reason
		applyMoverDeathDropPresentation(record)
	end
	if moverDeathDropAuthority.count > 0 then
		scheduleSnapshot()
	end
end

function ItemService.ClearDeathDrops()
	assert(started, "ItemService must be started before ClearDeathDrops")
	assert(
		activePreparedMoverParticipantUpdate == nil
			and activePreparedMoverDeathDrop == nil
			and #activeSharedMoverDeathDrops == 0
			and activePreparedDeathDropInsertion == nil
			and activeDeathDropInsertionPrepareCleanup == nil,
		"prepared Item insertion is active"
	)
	clearDeathDrops()
	requestAllMoverDeathDropCleanup("Cleanup")
end

function ItemService.GetSnapshot(): ItemSnapshot
	return buildSnapshot()
end

function ItemService.GetPickupIds(): { string }
	local pickupIds: { string } = {}
	for _, record in sortedRecords() do
		table.insert(pickupIds, record.pickupId)
	end
	for _, record in moverDeathDropAuthority.order do
		table.insert(pickupIds, record.dropId)
	end
	table.sort(pickupIds)
	return pickupIds
end

function ItemService.SetEnabled(enabled: boolean)
	assert(type(enabled) == "boolean", "ItemService.SetEnabled requires a boolean")
	assert(activePreparedMoverParticipantUpdate == nil, "mover participant update is active")
	if serviceEnabled == enabled then
		return
	end
	serviceEnabled = enabled
	serviceConfigurationRevision += 1
	if not enabled then
		clearDeathDrops()
		requestAllMoverDeathDropCleanup("Cleanup")
	end
	for _, record in sortedRecords() do
		applyMarkerState(record)
	end
	scheduleSnapshot()
end

function ItemService.IsEnabled(): boolean
	return serviceEnabled
end

function ItemService.Reset()
	assert(started, "ItemService must be started before Reset")
	assert(
		activePreparedMoverParticipantUpdate == nil
			and activePreparedMoverDeathDrop == nil
			and #activeSharedMoverDeathDrops == 0
			and activePreparedDeathDropInsertion == nil
			and activeDeathDropInsertionPrepareCleanup == nil,
		"prepared Item insertion is active during Reset"
	)
	requestAllMoverDeathDropCleanup("Match")
	local changed = false
	for _, record in sortedRecords() do
		if record.source == "DeathDrop" then
			destroyDeathDrop(record)
			changed = true
			continue
		end
		if not record.active or record.respawnAtMilliseconds ~= nil then
			record.active = true
			record.claiming = false
			record.respawnAtMilliseconds = nil
			record.revision += 1
			changed = true
		end
		replaceMapMoverRecord(record, nil, nil)
		applyMarkerState(record)
	end
	if changed then
		scheduleSnapshot()
	end
end

local function tryPickupMoverDeathDrop(
	player: Player,
	record: MoverDeathDropRecord,
	state: PlayerItemState,
	summary: AuthoritativeFrameService.Summary
): boolean
	local marker = moverDeathDropPresentationMarkers[record.dropId]
	if
		not serviceEnabled
		or moverDeathDropAuthority.recordsById[record.dropId] ~= record
		or moverDeathDropCleanupIntents[record.dropId] ~= nil
		or moverDeathDropClaims[record.dropId]
		or record.participant.lifecycle ~= MoverItemFlagParticipantRules.Lifecycle.ActiveLinked
		or record.matchId ~= currentMatchId()
		or not marker
		or not marker.Parent
		or not state.alive
		or not state.pickupsEnabled
		or not ItemDefs.PlayerTouchesItem(state.position, record.participant.body.position)
	then
		return false
	end
	local hooks = assert(serviceHooks, "ItemService hooks are unavailable")
	if hooks.CanPickup then
		local allowedCall, allowed = pcall(hooks.CanPickup, player, record.definition, marker)
		if not allowedCall or not allowed then
			return false
		end
	end
	local eligible, cap, current = ItemDefs.GetEligibility(record.definition, state)
	if not eligible then
		return false
	end
	local weaponId = record.definition.weaponId
	local powerupId = record.definition.powerupId
	local grantAmount = if record.definition.kind == "Weapon"
		then ItemDefs.GetWeaponAmmoGrant(current, record.quantity, true)
		else record.quantity
	local context: GrantContext = {
		pickupId = record.dropId,
		itemId = record.itemId,
		kind = record.definition.kind,
		marker = marker,
		definition = record.definition,
		configuredQuantity = record.quantity,
		grantAmount = grantAmount,
		current = current,
		cap = cap,
		weaponId = weaponId,
		powerupId = powerupId,
		levelTimeMilliseconds = summary.currentTimeMilliseconds,
		serverTime = summary.currentServerTimeSeconds,
	}
	moverDeathDropClaims[record.dropId] = true
	local grantedCall: boolean
	local granted: boolean
	if record.definition.kind == "Weapon" then
		grantedCall, granted = pcall(
			hooks.TryGrantWeapon,
			player,
			assert(weaponId, "dropped weapon lost its weapon id"),
			grantAmount,
			cap,
			context
		)
	else
		grantedCall, granted = pcall(
			hooks.TryGrantPowerup,
			player,
			assert(powerupId, "dropped powerup lost its powerup id"),
			context
		)
	end
	moverDeathDropClaims[record.dropId] = nil
	if not grantedCall or not granted then
		return false
	end
	local transition = assert(
		MoverItemFlagParticipantRules.ResolveTouch(
			record.participant,
			MoverItemFlagParticipantRules.TouchIntent.DroppedTaken
		)
	)
	assert(
		transition.participant.lifecycle
				== MoverItemFlagParticipantRules.Lifecycle.PendingFreeAfterEvent
			and not transition.releaseSourceOrder
			and transition.participant.body.contents
				== MoverItemFlagParticipantRules.ContentsNone,
		"DroppedTaken did not enter hidden pending-free authority"
	)
	local nextRecord = cloneMoverDeathDropRecord(
		record,
		transition.participant,
		record.trajectoryTimeMilliseconds,
		summary.currentTimeMilliseconds,
		record.settled
	)
	replaceMoverDeathDropRecord(record, nextRecord)
	applyMoverDeathDropPresentation(nextRecord)
	emitMoverDeathDropTakenEvent(nextRecord, player, grantAmount, summary)
	scheduleSnapshot()
	return true
end

function ItemService.HandleClientTriggerFrame(frameValue: unknown, player: Player)
	local summary = inspectOpenFrame(frameValue, "ItemService client-trigger phase")
	local currentMilliseconds = summary.currentTimeMilliseconds
	assert(
		currentMilliseconds > preMoverFrameLevelTimeMilliseconds
			and currentMilliseconds > postMoverFrameLevelTimeMilliseconds,
		"ItemService client-trigger phase ran after a later entity phase"
	)
	local registration = EntitySlotService.GetPlayerRegistration(player)
	assert(
		registration and registration.kind == "Player" and registration.domain == "Client",
		"ItemService client-trigger phase requires a registered client slot"
	)
	local previousPlayerFrame = lastClientTriggerAtMillisecondsByPlayer[player] or -1
	assert(
		MatchFrameRules.ShouldRunFrame(previousPlayerFrame, currentMilliseconds),
		"ItemService client-trigger phase ran twice for one client"
	)
	if currentMilliseconds > clientTriggerFrameLevelTimeMilliseconds then
		clientTriggerFrameLevelTimeMilliseconds = currentMilliseconds
		clientTriggerLastSourceOrder = -1
	else
		assert(
			currentMilliseconds == clientTriggerFrameLevelTimeMilliseconds,
			"ItemService client-trigger phase regressed"
		)
	end
	assert(
		registration.sourceOrder > clientTriggerLastSourceOrder,
		"ItemService client-trigger clients are not in EntitySlot order"
	)
	clientTriggerLastSourceOrder = registration.sourceOrder
	lastClientTriggerAtMillisecondsByPlayer[player] = currentMilliseconds

	local state = getPlayerState(player)
	if not state or not state.alive or not state.pickupsEnabled then
		return
	end
	local function touch(records: { PickupRecord }): boolean
		for _, record in records do
			if
				record.enabled
				and record.active
				and tryPickupRecord(player, record, state, summary)
			then
				local refreshed = getPlayerState(player)
				if not refreshed then
					return false
				end
				state = refreshed
				if not state.alive or not state.pickupsEnabled then
					return false
				end
			end
		end
		return true
	end
	if touch(mapRecordsInSourceOrder()) then
		for _, record in registeredDeathDropsInSourceOrder() do
			if tryPickupMoverDeathDrop(player, record, state, summary) then
				local refreshed = getPlayerState(player)
				if not refreshed or not refreshed.alive or not refreshed.pickupsEnabled then
					return
				end
				state = refreshed
			end
		end
		touch(legacyDeathDropsInSpawnOrder())
	end
end

function ItemService.HandleAuthoritativeFrameBegin(frameValue: unknown)
	inspectOpenFrame(frameValue, "ItemService publication frame begin")
	ItemFramePublicationService.Begin(frameValue)
	if snapshotScheduled then
		publishSnapshot()
	end
end

function ItemService.HandleAuthoritativeFrameEnd(frameValue: unknown): () -> ()
	inspectOpenFrame(frameValue, "ItemService publication frame end")
	if snapshotScheduled then
		publishSnapshot()
	end
	return ItemFramePublicationService.Seal(frameValue)
end

function ItemService.HandleSimulationFault()
	snapshotScheduled = false
	ItemFramePublicationService.Quarantine()
end

function ItemService.BeginPreMoverEntityFrame(frameValue: unknown)
	local summary = inspectOpenFrame(frameValue, "ItemService pre-mover entity phase")
	local currentMilliseconds = summary.currentTimeMilliseconds
	assert(
		MatchFrameRules.ShouldRunFrame(preMoverFrameLevelTimeMilliseconds, currentMilliseconds),
		"ItemService pre-mover entity phase ran twice"
	)
	assert(
		postMoverFrameLevelTimeMilliseconds < currentMilliseconds,
		"ItemService pre-mover entity phase ran after its dynamic phase"
	)
	assert(activePreMoverMapFrameLevelTimeMilliseconds == nil, "map Item phase already open")
	activePreMoverMapFrameLevelTimeMilliseconds = currentMilliseconds
	activePreMoverMapLastSourceOrder = -1
end

function ItemService.HandleMapEntityFrame(
	frameValue: unknown,
	summaryValue: unknown,
	mapRegistration: EntitySlotService.MapRegistration
)
	local summary = inspectOpenFrame(frameValue, "ItemService map entity phase")
	assert(summary == summaryValue, "ItemService map entity summary drifted")
	assert(
		activePreMoverMapFrameLevelTimeMilliseconds == summary.currentTimeMilliseconds,
		"ItemService map entity ran outside its phase"
	)
	assert(mapRegistration.kind == "Item", "ItemService received a non-Item map entity")
	local registration = mapRegistration.registration
	assert(
		registration.sourceOrder > activePreMoverMapLastSourceOrder,
		"map Items did not run in numeric source order"
	)
	activePreMoverMapLastSourceOrder = registration.sourceOrder
	local record = mapRecordsByRegistration[mapRegistration]
	if not record then
		return
	end
	assert(
		record.source == "Map"
			and record.mapRegistration == mapRegistration
			and record.mapSourceOrder == registration.sourceOrder
			and recordsById[record.pickupId] == record
			and recordsByMarker[record.marker] == record
			and EntitySlotService.GetMapRegistration(mapRegistration.eventId) == mapRegistration
			and EntitySlotService.GetWorldRegistrationBySourceOrder(registration.sourceOrder)
				== registration,
		"map Item registration index became stale"
	)
	finishMapItemEvent(record, summary.currentTimeMilliseconds)
	respawnMapPickup(record, summary.currentTimeMilliseconds, summary)
end

function ItemService.EndPreMoverEntityFrame(frameValue: unknown)
	local summary = inspectOpenFrame(frameValue, "ItemService pre-mover entity phase end")
	assert(
		activePreMoverMapFrameLevelTimeMilliseconds == summary.currentTimeMilliseconds,
		"map Item phase end lost its frame"
	)
	preMoverFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
	activePreMoverMapFrameLevelTimeMilliseconds = nil
	activePreMoverMapLastSourceOrder = -1
end

function ItemService.HandlePreMoverEntityFrame(frameValue: unknown)
	ItemService.BeginPreMoverEntityFrame(frameValue)
	local summary = inspectOpenFrame(frameValue, "ItemService compatibility map entity phase")
	for _, record in mapRecordsInSourceOrder() do
		ItemService.HandleMapEntityFrame(
			frameValue,
			summary,
			assert(record.mapRegistration, "map Item lost registration")
		)
	end
	ItemService.EndPreMoverEntityFrame(frameValue)
end

function ItemService.HandlePostMoverDynamicFrame(frameValue: unknown)
	local summary = inspectOpenFrame(frameValue, "ItemService post-mover dynamic phase")
	local currentMilliseconds = summary.currentTimeMilliseconds
	assert(
		preMoverFrameLevelTimeMilliseconds == currentMilliseconds,
		"ItemService dynamic phase requires this frame's pre-mover item phase"
	)
	assert(
		MatchFrameRules.ShouldRunFrame(postMoverFrameLevelTimeMilliseconds, currentMilliseconds),
		"ItemService post-mover dynamic phase ran twice"
	)
	stepLegacyDeathDrops(summary)
	postMoverFrameLevelTimeMilliseconds = currentMilliseconds
end

-- Server-only compatibility seam used by focused probes and trusted callers.
-- It never invents a wall clock: between fixed steps it binds the mutation to
-- the latest fully committed canonical frame, and rejects calls while another
-- frame is open. Live spatial pickup authority uses HandleClientTriggerFrame.
function ItemService.TryPickup(player: Player, pickupId: string): boolean
	assert(started, "ItemService must be started before TryPickup")
	local currentFrame = AuthoritativeFrameService.GetCurrentFrame()
	if not currentFrame then
		return false
	end
	local summary = AuthoritativeFrameService.InspectCurrentFrame(currentFrame)
	if
		not summary
		or not AuthoritativeFrameService.ValidateFrameDependency(currentFrame, summary)
	then
		return false
	end
	updatePresentationBasis(summary)
	local record = recordsById[pickupId]
	if record then
		return tryPickupRecord(player, record, nil, summary)
	end
	local moverRecord = moverDeathDropAuthority.recordsById[pickupId]
	local state = if moverRecord then getPlayerState(player) else nil
	return moverRecord ~= nil
		and state ~= nil
		and tryPickupMoverDeathDrop(player, moverRecord, state, summary)
end

function ItemService.Refresh()
	assert(started, "ItemService must be started before Refresh")
	scanMarkers()
	publishSnapshot()
end

function ItemService.OnSnapshot(callback: (snapshot: ItemSnapshot) -> ()): RBXScriptConnection
	return snapshotSignal.Event:Connect(callback)
end

function ItemService.OnEvent(callback: (event: ItemEvent) -> ()): RBXScriptConnection
	return itemEventSignal.Event:Connect(callback)
end

function ItemService.Start(root: Instance, hooks: Hooks)
	assert(not started, "ItemService.Start may only be called once")
	assert(root.Parent ~= nil or root == game, "ItemService world root must be in the DataModel")
	assert(type(hooks.GetPlayerState) == "function", "GetPlayerState hook is required")
	assert(type(hooks.TryGrantHealth) == "function", "TryGrantHealth hook is required")
	assert(type(hooks.TryGrantArmor) == "function", "TryGrantArmor hook is required")
	assert(type(hooks.TryGrantAmmo) == "function", "TryGrantAmmo hook is required")
	assert(type(hooks.TryGrantWeapon) == "function", "TryGrantWeapon hook is required")
	assert(type(hooks.TryGrantHoldable) == "function", "TryGrantHoldable hook is required")
	assert(type(hooks.TryGrantPowerup) == "function", "TryGrantPowerup hook is required")

	started = true
	worldRoot = root
	serviceHooks = hooks
	local castParameters = RaycastParams.new()
	castParameters.FilterType = Enum.RaycastFilterType.Include
	castParameters.FilterDescendantsInstances = { root }
	castParameters.IgnoreWater = true
	castParameters.RespectCanCollide = true
	deathDropCastParameters = castParameters

	local network = ensureFolder(sharedRoot, ItemDefs.Network.Folder)
	snapshotRemote = ensureRemote(network, ItemDefs.Network.Snapshot)
	eventRemote = ensureRemote(network, ItemDefs.Network.Event)

	local snapshotRequestRemote = assert(snapshotRemote, "ItemSnapshot remote is unavailable")
	table.insert(
		_serviceConnections,
		snapshotRequestRemote.OnServerEvent:Connect(function(player: Player)
			local now = os.clock()
			local previous = snapshotRequestTimes[player] or -math.huge
			if now - previous < 0.5 then
				return
			end
			snapshotRequestTimes[player] = now
			sendSnapshot(player)
		end)
	)

	table.insert(
		_serviceConnections,
		Players.PlayerAdded:Connect(function(player: Player)
			task.delay(0.5, sendSnapshot, player)
		end)
	)
	table.insert(
		_serviceConnections,
		Players.PlayerRemoving:Connect(function(player: Player)
			snapshotRequestTimes[player] = nil
			lastClientTriggerAtMillisecondsByPlayer[player] = nil
		end)
	)
	table.insert(
		_serviceConnections,
		CollectionService:GetInstanceAddedSignal(ItemDefs.MarkerTag)
			:Connect(function(instance: Instance)
				if instance:IsA("BasePart") and isWithinWorldRoot(instance) then
					tryRegisterMarker(instance)
				end
			end)
	)
	table.insert(
		_serviceConnections,
		CollectionService:GetInstanceRemovedSignal(ItemDefs.MarkerTag)
			:Connect(function(instance: Instance)
				if
					instance:IsA("BasePart")
					and instance:GetAttribute(ItemDefs.Attributes.ItemId) == nil
				then
					unregisterMarker(instance, true)
				end
			end)
	)
	table.insert(
		_serviceConnections,
		root.DescendantAdded:Connect(function(instance: Instance)
			if instance:IsA("BasePart") then
				task.defer(function()
					if instance.Parent and isWithinWorldRoot(instance) then
						tryRegisterMarker(instance)
					end
				end)
			end
		end)
	)
	table.insert(
		_serviceConnections,
		root.DescendantRemoving:Connect(function(instance: Instance)
			if instance:IsA("BasePart") then
				unregisterMarker(instance, true)
			end
		end)
	)

	scanMarkers()
	publishSnapshot()
	for _, player in Players:GetPlayers() do
		task.delay(0.5, sendSnapshot, player)
	end
end

return table.freeze(ItemService)
