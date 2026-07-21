--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure respawn/body-queue authority translated from Quake III Arena:
  code/game/g_local.h (BODY_QUEUE_SIZE, gentity_t body fields)
  code/game/g_combat.c (player_die, GibEntity, GIB_HEALTH)
  code/game/g_active.c (ClientThink_real strict respawn comparisons)
  code/game/g_client.c (InitBodyQue, CopyToBodyQue, BodySink, respawn)

Pinned source behavior represented here:
  * player_die records respawnTime = level.time + 1700. ClientThink_real tests
    both the manual gate and g_forcerespawn with strict > comparisons.
  * InitBodyQue reserves eight never-free entities and starts bodyQueIndex at 0.
  * respawn calls CopyToBodyQue before ClientSpawn. CopyToBodyQue unlinks the
    client, samples CONTENTS_NODROP, and only then selects/advances bodyQueIndex.
    GibEntity makes the client ET_INVISIBLE with zero contents but does not
    unlink it; player_die's final trap_LinkEntity also runs after direct gib.
    That linked invisible client still consumes a queue slot outside no-drop.
    The no-drop request is therefore a
    distinct minimal shape and never carries or validates a CopySource.
  * CopyToBodyQue copies the client's entity state at respawn time, not a pose
    captured at death. Grounded TR_STATIONARY preserves copied trDelta; airborne
    TR_GRAVITY replaces trDelta with the current player-state velocity. This
    module records that trajectory descriptor and advances the later
    physicsObject through G_RunItem's trajectory/trace/zero-bounce path.
  * CopyToBodyQue never assigns body->health. Reusing a slot preserves its prior
    health, while body->takedamage is assigned from sourceHealth > GIB_HEALTH.
  * BodySink checks age > 6500 before motion, otherwise subtracts one Q3 unit
    from trajectory trBase and schedules nextthink = actual level.time + 100.
    It does not relink or rewrite r.currentOrigin, so collision position is kept
    separate from the sinking trajectory/presentation base in this port.

The eight descriptors come from EntitySlotService.GetBodyQueueRegistration.
A future live composite must compare StageCopy's selected descriptor with
EntitySlotService.NextBodyQueue before committing both owners. No server service,
Instance, async avatar operation, combat mutation, or presentation side effect
occurs in this module.

Opaque queue/death/transaction/prepared/sink capabilities, explicit lineage,
and immutable data-only records are the Roblox Luau port authority adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)
local EntitySourceOrderRules = require(script.Parent.EntitySourceOrderRules)
local MoverConsequenceRules = require(script.Parent.MoverConsequenceRules)
local MoverPushRules = require(script.Parent.MoverPushRules)

export type QueueSlotDescriptor = {
	read index: number,
	read bodyId: string,
	read sourceOrder: number,
	read leaseGeneration: number,
}

export type QueueSlot = {
	read index: number,
	read bodyId: string,
	read sourceOrder: number,
	read leaseGeneration: number,
	read occupantGeneration: number,
	read retainedHealth: number,
	read takedamage: boolean,
	read hasOccupant: boolean,
}

export type QueueState = {
	read lineage: unknown,
	read revision: number,
	read nextQueueIndex: number,
	read slots: { QueueSlot },
}

export type PlayerLeaseIdentity = {
	read bodyId: string,
	read sourceOrder: number,
	read leaseGeneration: number,
	read playerUserId: number,
	read lifeSequence: number,
}

export type DeadClientSnapshot = {
	read queueLineage: unknown,
	read matchLineage: unknown,
	read deathTimeMilliseconds: number,
	read respawnTimeMilliseconds: number,
	read player: PlayerLeaseIdentity,
}

-- Opaque capability for one preallocated death record. The snapshot and its
-- committed duplicate-life key remain unpublished until ApplyPreparedDeathRecord.
export type PreparedDeathRecord = {}
export type PreparedDeathRecordSummary = {
	read queueLineage: unknown,
	read queueRevision: number,
	read deathIndexRevision: number,
	read matchLineage: unknown,
	read deathTimeMilliseconds: number,
	read respawnTimeMilliseconds: number,
	read player: PlayerLeaseIdentity,
}

-- Q3 may run several source-ordered player_die transitions in one server
-- frame. One opaque batch publishes those distinct life records against a
-- single duplicate-index root revision without sorting caller order.
export type PreparedDeathRecordBatch = {}
export type PreparedDeathRecordBatchSummary = {
	read queueLineage: unknown,
	read queueRevision: number,
	read deathIndexRevision: number,
	read matchLineage: unknown,
	read operationCount: number,
	read records: { PreparedDeathRecordSummary },
}

export type RespawnKind = "Wait" | "Manual" | "Forced"
export type RespawnDecision = {
	read kind: RespawnKind,
	read canRespawn: boolean,
	read nowMilliseconds: number,
	read elapsedSinceDeathMilliseconds: number,
	read elapsedSinceRespawnGateMilliseconds: number,
}

export type GroundState = "Grounded" | "Airborne"
export type EntityType = "Player" | "Invisible"
export type CopySource = {
	matchLineage: unknown,
	playerBodyId: string,
	playerSourceOrder: number,
	playerLeaseGeneration: number,
	playerUserId: number,
	lifeSequence: number,
	body: MoverPushRules.Body,
	sourceLinked: boolean,
	entityType: EntityType,
	visible: boolean,
	groundState: GroundState,
	entityTrajectoryDelta: Vector3,
	playerStateVelocity: Vector3,
	sourceHealth: number,
}

export type TrajectoryState = {
	read kind: "Stationary" | "Gravity",
	read basePosition: Vector3,
	read delta: Vector3,
	read startTimeMilliseconds: number,
}

export type PresentationState = {
	read entityType: EntityType,
	read visible: boolean,
	read copiedFromLinkedSource: boolean,
}

export type TrajectoryEvaluation = {
	read position: Vector3,
	read velocity: Vector3,
}

export type PhysicsTrace = {
	read fraction: number,
	read endPosition: Vector3,
	read normal: Vector3?,
	read moverId: string?,
	read startSolid: boolean,
	read noDrop: boolean,
}

export type Transaction = {
	read phase: "Open" | "Staged" | "Sealed",
	read generation: number,
	read baseRevision: number,
	read nextQueueIndex: number,
}

export type PreparedCopy = {
	read kind: "NoDrop" | "BodyCopy",
	read decision: RespawnDecision,
	read sourceLinked: boolean,
	read queueIndex: number?,
	read bodyId: string?,
	read sourceOrder: number?,
	read leaseGeneration: number?,
	read occupantGeneration: number?,
	read retainedHealth: number?,
	read takedamage: boolean?,
	read collisionBody: MoverPushRules.Body?,
	read trajectory: TrajectoryState?,
	read presentation: PresentationState?,
}

export type SinkState = {
	read queueLineage: unknown,
	read queueIndex: number,
	read occupantGeneration: number,
	read collisionBody: MoverPushRules.Body,
	read trajectory: TrajectoryState,
	read presentation: PresentationState,
	read timestampMilliseconds: number,
	read nextThinkTimeMilliseconds: number?,
	read evaluatedThroughMilliseconds: number,
	read linked: boolean,
	read physicsObject: boolean,
	read sinkStepCount: number,
}

export type DamageResult = {
	read applied: boolean,
	read gibbed: boolean,
	read queueIndex: number,
	read occupantGeneration: number,
	read beforeHealth: number,
	read afterHealth: number,
	read takedamage: boolean,
}

export type PreparedSinkMoverUpdate = {}

export type CommitResult = {
	read kind: "RespawnWithoutBody" | "RespawnWithBody",
	read decision: RespawnDecision,
	read queueIndex: number?,
	read occupantGeneration: number?,
	read sink: SinkState?,
}

-- Opaque capability for a fully allocated commit plan. The plan's public
-- handle intentionally carries no forgeable lineage fields.
export type PreparedCommit = {}

type SlotData = {
	index: number,
	bodyId: string,
	sourceOrder: number,
	leaseGeneration: number,
	occupantGeneration: number,
	retainedHealth: number,
	takedamage: boolean,
	hasOccupant: boolean,
	sinkRoot: any?,
}

type QueueData = {
	revision: number,
	nextQueueIndex: number,
	slots: { SlotData },
}

type QueueRoot = {
	lineage: unknown,
	currentState: QueueState?,
	activeTransaction: any?,
	deathKeysByMatch: { [table]: { [string]: boolean } },
	deathIndexRevision: number,
	pendingDeathKeysByMatch: { [table]: any },
}

type QueueCapability = {
	current: boolean,
	root: QueueRoot,
	data: QueueData,
}

type DeathCapability = {
	root: QueueRoot,
	matchLineage: table,
	published: boolean,
	consumed: boolean,
	reservedBy: any?,
}

type PendingDeathBucket = {
	count: number,
	reservations: { [string]: any },
}

type PreparedDeathRecordCapability = {
	prepared: PreparedDeathRecord,
	current: boolean,
	applyValidated: boolean,
	root: QueueRoot,
	baseState: QueueState,
	baseQueueCapability: QueueCapability,
	baseDeathKeysByMatch: { [table]: { [string]: boolean } },
	baseDeathIndexRevision: number,
	nextDeathKeysByMatch: { [table]: { [string]: boolean } },
	nextDeathIndexRevision: number,
	matchLineage: table,
	identityKey: string,
	pendingBucket: PendingDeathBucket,
	snapshot: DeadClientSnapshot,
	deathCapability: DeathCapability,
	summary: PreparedDeathRecordSummary,
}

type PreparedDeathRecordBatchEntry = {
	identityKey: string,
	player: PlayerLeaseIdentity,
	snapshot: DeadClientSnapshot,
	deathCapability: DeathCapability,
	summary: PreparedDeathRecordSummary,
}

type PreparedDeathRecordBatchCapability = {
	prepared: PreparedDeathRecordBatch,
	current: boolean,
	applyValidated: boolean,
	root: QueueRoot,
	baseState: QueueState,
	baseQueueCapability: QueueCapability,
	baseDeathKeysByMatch: { [table]: { [string]: boolean } },
	baseDeathIndexRevision: number,
	nextDeathKeysByMatch: { [table]: { [string]: boolean } },
	nextDeathIndexRevision: number,
	matchLineage: table,
	pendingBucket: PendingDeathBucket,
	entries: { PreparedDeathRecordBatchEntry },
	snapshots: { DeadClientSnapshot },
	summary: PreparedDeathRecordBatchSummary,
}

type TransactionRoot = {
	identity: unknown,
	queueRoot: QueueRoot,
	baseState: QueueState,
	baseCapability: QueueCapability,
	prepared: PreparedCopy?,
	preparedCapability: any?,
	preparedCommit: PreparedCommit?,
	preparedCommitCapability: any?,
	death: DeadClientSnapshot?,
	deathCapability: DeathCapability?,
	open: boolean,
}

type TransactionCapability = {
	current: boolean,
	root: TransactionRoot,
	phase: "Open" | "Staged" | "Sealed",
	generation: number,
}

type PreparedCapability = {
	current: boolean,
	root: TransactionRoot,
}

type SinkData = {
	queueLineage: unknown,
	queueIndex: number,
	occupantGeneration: number,
	collisionBody: MoverPushRules.Body,
	trajectory: TrajectoryState,
	presentation: PresentationState,
	timestampMilliseconds: number,
	nextThinkTimeMilliseconds: number?,
	evaluatedThroughMilliseconds: number,
	linked: boolean,
	physicsObject: boolean,
	sinkStepCount: number,
}

type SinkRoot = {
	active: boolean,
	current: SinkState?,
}

type SinkCapability = {
	current: boolean,
	root: SinkRoot,
	data: SinkData,
}

type PreparedSinkMoverCapability = {
	status: "Prepared" | "Applied" | "Aborted",
	baseState: SinkState,
	baseCapability: SinkCapability,
	nextState: SinkState,
	nextCapability: SinkCapability,
	applyValidated: boolean,
}

type PreparedCommitCapability = {
	current: boolean,
	root: TransactionRoot,
	transactionCapability: TransactionCapability,
	nextData: QueueData,
	nextState: QueueState,
	nextStateCapability: QueueCapability,
	result: CommitResult,
	sinkRoot: SinkRoot?,
	sinkState: SinkState?,
	sinkCapability: SinkCapability?,
	displacedRoot: SinkRoot?,
	displacedState: SinkState?,
	displacedCapability: SinkCapability?,
	applyValidated: boolean,
}

local BodyQueueRules = {}

local BODY_QUEUE_SIZE = 8
local RESPAWN_DELAY_MILLISECONDS = 1700
local SINK_START_DELAY_MILLISECONDS = 5000
local SINK_STEP_MILLISECONDS = 100
local UNLINK_AGE_EXCLUSIVE_MILLISECONDS = 6500
local GIB_HEALTH = -40
local MINIMUM_HEALTH = -100_000
local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_FORCE_RESPAWN_SECONDS = 2_147_480
local MAXIMUM_GENERATION = 2_147_483_647
local MAXIMUM_STABLE_ID_LENGTH = 64
local MAXIMUM_USER_ID = 9_007_199_254_740_991
local MAXIMUM_DEATH_RECORD_BATCH_SIZE = EntitySourceOrderRules.MaximumClients
local SINK_STEP_VECTOR = Vector3.new(0, -Constants.UnitsToStuds, 0)

assert(EntitySourceOrderRules.BodyQueueSize == BODY_QUEUE_SIZE, "Q3 body queue size drifted")
assert(MoverConsequenceRules.GibHealth == GIB_HEALTH, "Q3 gib health drifted")

local queueCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: QueueCapability }
local deathCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: DeathCapability }
local preparedDeathRecordCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedDeathRecord]: PreparedDeathRecordCapability,
}
local preparedDeathRecordSummaries = setmetatable({}, { __mode = "k" }) :: {
	[PreparedDeathRecordSummary]: PreparedDeathRecord,
}
local preparedDeathRecordBatchCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedDeathRecordBatch]: PreparedDeathRecordBatchCapability,
}
local preparedDeathRecordBatchSummaries = setmetatable({}, { __mode = "k" }) :: {
	[PreparedDeathRecordBatchSummary]: PreparedDeathRecordBatch,
}
local transactionCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: TransactionCapability }
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: PreparedCapability }
local sinkCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: SinkCapability }
local preparedSinkMoverCapabilities: { [PreparedSinkMoverUpdate]: PreparedSinkMoverCapability } = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local preparedCommitCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedCommit]: PreparedCommitCapability,
}

local SLOT_KEYS = table.freeze({
	index = true,
	bodyId = true,
	sourceOrder = true,
	leaseGeneration = true,
})
local DEATH_KEYS = table.freeze({
	matchLineage = true,
	deathTimeMilliseconds = true,
	playerBodyId = true,
	playerSourceOrder = true,
	playerLeaseGeneration = true,
	playerUserId = true,
	lifeSequence = true,
})
local RESPAWN_KEYS = table.freeze({
	nowMilliseconds = true,
	attackPressed = true,
	useHoldablePressed = true,
	forceRespawnSeconds = true,
})
local NO_DROP_STAGE_KEYS = table.freeze({
	nowMilliseconds = true,
	attackPressed = true,
	useHoldablePressed = true,
	forceRespawnSeconds = true,
	noDrop = true,
})
local BODY_COPY_STAGE_KEYS = table.freeze({
	nowMilliseconds = true,
	attackPressed = true,
	useHoldablePressed = true,
	forceRespawnSeconds = true,
	noDrop = true,
	copySource = true,
})
local COPY_SOURCE_KEYS = table.freeze({
	matchLineage = true,
	playerBodyId = true,
	playerSourceOrder = true,
	playerLeaseGeneration = true,
	playerUserId = true,
	lifeSequence = true,
	body = true,
	sourceLinked = true,
	entityType = true,
	visible = true,
	groundState = true,
	entityTrajectoryDelta = true,
	playerStateVelocity = true,
	sourceHealth = true,
})
local PHYSICS_TRACE_KEYS = table.freeze({
	fraction = true,
	endPosition = true,
	normal = true,
	moverId = true,
	startSolid = true,
	noDrop = true,
})

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

local function hasPhysicsTraceKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or PHYSICS_TRACE_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count >= 4
		and count <= 6
		and rawget(value, "fraction") ~= nil
		and rawget(value, "endPosition") ~= nil
		and rawget(value, "startSolid") ~= nil
		and rawget(value, "noDrop") ~= nil
end

local function denseArrayLength(value: unknown, expectedCount: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	return count == expectedCount and maximumIndex == expectedCount
end

local function boundedDenseArrayLength(value: unknown, maximumCount: number): number?
	if type(value) ~= "table" or getmetatable(value :: table) ~= nil then
		return nil
	end
	local count = 0
	local maximumIndex = 0
	for key in next, value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	if count < 1 or count > maximumCount or maximumIndex ~= count then
		return nil
	end
	return count
end

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isStableId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_STABLE_ID_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function isBoundedVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return vector.X == vector.X
		and vector.Y == vector.Y
		and vector.Z == vector.Z
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= 100_000
end

local function copySlots(slots: { SlotData }): { SlotData }
	local output: { SlotData } = {}
	for index, slot in slots do
		output[index] = {
			index = slot.index,
			bodyId = slot.bodyId,
			sourceOrder = slot.sourceOrder,
			leaseGeneration = slot.leaseGeneration,
			occupantGeneration = slot.occupantGeneration,
			retainedHealth = slot.retainedHealth,
			takedamage = slot.takedamage,
			hasOccupant = slot.hasOccupant,
			sinkRoot = slot.sinkRoot,
		}
	end
	return output
end

local function publicSlots(slots: { SlotData }): { QueueSlot }
	local output: { QueueSlot } = {}
	for index, data in slots do
		local slot: QueueSlot = {
			index = data.index,
			bodyId = data.bodyId,
			sourceOrder = data.sourceOrder,
			leaseGeneration = data.leaseGeneration,
			occupantGeneration = data.occupantGeneration,
			retainedHealth = data.retainedHealth,
			takedamage = data.takedamage,
			hasOccupant = data.hasOccupant,
		}
		table.freeze(slot)
		output[index] = slot
	end
	table.freeze(output)
	return output
end

local function buildQueueState(root: QueueRoot, data: QueueData): (QueueState, QueueCapability)
	local state: QueueState = {
		lineage = root.lineage,
		revision = data.revision,
		nextQueueIndex = data.nextQueueIndex,
		slots = publicSlots(data.slots),
	}
	table.freeze(state)
	local capability: QueueCapability = { current = false, root = root, data = data }
	return state, capability
end

local function publishQueueState(root: QueueRoot, state: QueueState, capability: QueueCapability): QueueState
	capability.current = true
	queueCapabilities[state :: table] = capability
	root.currentState = state
	return state
end

local function makeQueueState(root: QueueRoot, data: QueueData): QueueState
	local state, capability = buildQueueState(root, data)
	return publishQueueState(root, state, capability)
end

local function inspectQueue(value: unknown): (QueueState?, QueueCapability?, string?)
	if type(value) ~= "table" then
		return nil, nil, "body-queue-state-not-table"
	end
	local capability = queueCapabilities[value :: table]
	if not capability then
		return nil, nil, "unknown-body-queue-state"
	end
	if not capability.current or capability.root.currentState ~= value then
		return nil, nil, "stale-body-queue-state"
	end
	return value :: QueueState, capability, nil
end

local function makePlayerIdentity(raw: { [unknown]: unknown }): PlayerLeaseIdentity
	local identity: PlayerLeaseIdentity = {
		bodyId = raw.playerBodyId :: string,
		sourceOrder = raw.playerSourceOrder :: number,
		leaseGeneration = raw.playerLeaseGeneration :: number,
		playerUserId = raw.playerUserId :: number,
		lifeSequence = raw.lifeSequence :: number,
	}
	table.freeze(identity)
	return identity
end

local function identityKey(identity: PlayerLeaseIdentity): string
	return string.format(
		"%s:%d:%d:%d:%d",
		identity.bodyId,
		identity.sourceOrder,
		identity.leaseGeneration,
		identity.playerUserId,
		identity.lifeSequence
	)
end

local function playerLeaseKey(identity: PlayerLeaseIdentity): string
	return string.format(
		"%s:%d:%d:%d",
		identity.bodyId,
		identity.sourceOrder,
		identity.leaseGeneration,
		identity.playerUserId
	)
end

local function validIdentityFields(raw: { [unknown]: unknown }): boolean
	return isStableId(raw.playerBodyId)
		and isInteger(raw.playerSourceOrder, 1, EntitySourceOrderRules.MaximumClients)
		and isInteger(raw.playerLeaseGeneration, 1, MAXIMUM_GENERATION)
		and isInteger(raw.playerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		and isInteger(raw.lifeSequence, 1, MAXIMUM_GENERATION)
end

local function validateDeathRequest(
	requestValue: unknown
): ({ [unknown]: unknown }?, PlayerLeaseIdentity?, string?, string?)
	if type(requestValue) ~= "table" then
		return nil, nil, nil, "record-death-request-not-table"
	end
	local raw = requestValue :: { [unknown]: unknown }
	if
		not hasExactKeys(raw, DEATH_KEYS, 7)
		or type(raw.matchLineage) ~= "table"
		or not table.isfrozen(raw.matchLineage :: table)
		or not validIdentityFields(raw)
		or not isInteger(raw.deathTimeMilliseconds, 0, MAXIMUM_TIME_MILLISECONDS - RESPAWN_DELAY_MILLISECONDS)
	then
		return nil, nil, nil, "invalid-record-death-request"
	end
	local player = makePlayerIdentity(raw)
	return raw, player, identityKey(player), nil
end

local function buildCommittedDeathKeys(
	base: { [table]: { [string]: boolean } },
	selectedMatchLineage: table,
	selectedIdentityKey: string
): { [table]: { [string]: boolean } }
	local nextByMatch = setmetatable({}, { __mode = "k" }) :: {
		[table]: { [string]: boolean },
	}
	local selectedCopied = false
	for matchLineage, keys in base do
		local nextKeys: { [string]: boolean } = {}
		for key in keys do
			nextKeys[key] = true
		end
		if matchLineage == selectedMatchLineage then
			nextKeys[selectedIdentityKey] = true
			selectedCopied = true
		end
		table.freeze(nextKeys)
		nextByMatch[matchLineage] = nextKeys
	end
	if not selectedCopied then
		local nextKeys = { [selectedIdentityKey] = true }
		table.freeze(nextKeys)
		nextByMatch[selectedMatchLineage] = nextKeys
	end
	table.freeze(nextByMatch)
	return nextByMatch
end

local function buildCommittedDeathKeysForBatch(
	base: { [table]: { [string]: boolean } },
	selectedMatchLineage: table,
	selectedIdentityKeys: { string }
): { [table]: { [string]: boolean } }
	local nextByMatch = setmetatable({}, { __mode = "k" }) :: {
		[table]: { [string]: boolean },
	}
	local selectedCopied = false
	for matchLineage, keys in base do
		local nextKeys: { [string]: boolean } = {}
		for key in keys do
			nextKeys[key] = true
		end
		if matchLineage == selectedMatchLineage then
			for _, key in selectedIdentityKeys do
				nextKeys[key] = true
			end
			selectedCopied = true
		end
		table.freeze(nextKeys)
		nextByMatch[matchLineage] = nextKeys
	end
	if not selectedCopied then
		local nextKeys: { [string]: boolean } = {}
		for _, key in selectedIdentityKeys do
			nextKeys[key] = true
		end
		table.freeze(nextKeys)
		nextByMatch[selectedMatchLineage] = nextKeys
	end
	table.freeze(nextByMatch)
	return nextByMatch
end

local function inspectDeath(value: unknown): (DeadClientSnapshot?, DeathCapability?, string?)
	if type(value) ~= "table" then
		return nil, nil, "dead-client-snapshot-not-table"
	end
	local capability = deathCapabilities[value :: table]
	if not capability then
		return nil, nil, "unknown-dead-client-snapshot"
	end
	if not capability.published then
		return nil, nil, "unpublished-dead-client-snapshot"
	end
	if capability.consumed then
		return nil, nil, "consumed-dead-client-snapshot"
	end
	return value :: DeadClientSnapshot, capability, nil
end

local function makeDecision(snapshot: DeadClientSnapshot, raw: { [unknown]: unknown }): RespawnDecision
	local now = raw.nowMilliseconds :: number
	local sinceGate = now - snapshot.respawnTimeMilliseconds
	local kind: RespawnKind = "Wait"
	if now > snapshot.respawnTimeMilliseconds then
		local forceSeconds = raw.forceRespawnSeconds :: number
		if forceSeconds > 0 and sinceGate > forceSeconds * 1000 then
			kind = "Forced"
		elseif raw.attackPressed == true or raw.useHoldablePressed == true then
			kind = "Manual"
		end
	end
	local decision: RespawnDecision = {
		kind = kind,
		canRespawn = kind ~= "Wait",
		nowMilliseconds = now,
		elapsedSinceDeathMilliseconds = now - snapshot.deathTimeMilliseconds,
		elapsedSinceRespawnGateMilliseconds = sinceGate,
	}
	table.freeze(decision)
	return decision
end

local function validateRespawnRequest(
	value: unknown,
	allowed: { [string]: boolean },
	count: number,
	snapshot: DeadClientSnapshot
): ({ [unknown]: unknown }?, string?)
	if type(value) ~= "table" then
		return nil, "respawn-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, allowed, count) then
		return nil, "invalid-respawn-request-shape"
	end
	if
		not isInteger(raw.nowMilliseconds, snapshot.deathTimeMilliseconds, MAXIMUM_TIME_MILLISECONDS)
		or not isInteger(raw.forceRespawnSeconds, 0, MAXIMUM_FORCE_RESPAWN_SECONDS)
		or type(raw.attackPressed) ~= "boolean"
		or type(raw.useHoldablePressed) ~= "boolean"
	then
		return nil, "invalid-respawn-request"
	end
	return raw, nil
end

local function cloneBody(
	body: MoverPushRules.Body,
	id: string,
	sourceOrder: number,
	velocity: Vector3
): (MoverPushRules.Body?, string?)
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({
		{
			id = id,
			sourceOrder = sourceOrder,
			position = body.position,
			size = body.size,
			centerOffset = body.centerOffset,
			velocity = velocity,
			groundMoverId = body.groundMoverId,
			contents = body.contents,
			clipMask = body.clipMask,
		},
	})
	if not bodies then
		return nil, bodyError
	end
	return bodies[1], nil
end

local function validateCopySource(value: unknown, snapshot: DeadClientSnapshot): (CopySource?, string?)
	if type(value) ~= "table" then
		return nil, "copy-source-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, COPY_SOURCE_KEYS, 14) or not validIdentityFields(raw) then
		return nil, "invalid-copy-source-shape-or-identity"
	end
	if
		raw.matchLineage ~= snapshot.matchLineage
		or raw.playerBodyId ~= snapshot.player.bodyId
		or raw.playerSourceOrder ~= snapshot.player.sourceOrder
		or raw.playerLeaseGeneration ~= snapshot.player.leaseGeneration
		or raw.playerUserId ~= snapshot.player.playerUserId
		or raw.lifeSequence ~= snapshot.player.lifeSequence
	then
		return nil, "copy-source-death-lineage-mismatch"
	end
	if
		raw.sourceLinked ~= true
		or (raw.entityType ~= "Player" and raw.entityType ~= "Invisible")
		or type(raw.visible) ~= "boolean"
		or raw.visible ~= (raw.entityType == "Player")
		or (raw.groundState ~= "Grounded" and raw.groundState ~= "Airborne")
		or not isBoundedVector(raw.entityTrajectoryDelta)
		or not isBoundedVector(raw.playerStateVelocity)
		or not isInteger(raw.sourceHealth, MINIMUM_HEALTH, 0)
	then
		return nil, "invalid-copy-source-state"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ raw.body })
	if not bodies then
		return nil, bodyError
	end
	local body = bodies[1]
	if
		body.id ~= snapshot.player.bodyId
		or body.sourceOrder ~= snapshot.player.sourceOrder
		or body.size ~= MoverConsequenceRules.ClientCorpseSize
		or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
		or body.contents ~= MoverPushRules.Contents.Corpse
		or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
	then
		return nil, "copy-source-body-not-current-client-corpse"
	end
	if raw.groundState == "Airborne" and body.groundMoverId ~= nil then
		return nil, "airborne-copy-source-has-ground-mover"
	end
	return {
		matchLineage = raw.matchLineage,
		playerBodyId = raw.playerBodyId :: string,
		playerSourceOrder = raw.playerSourceOrder :: number,
		playerLeaseGeneration = raw.playerLeaseGeneration :: number,
		playerUserId = raw.playerUserId :: number,
		lifeSequence = raw.lifeSequence :: number,
		body = body,
		sourceLinked = raw.sourceLinked :: boolean,
		entityType = raw.entityType :: EntityType,
		visible = raw.visible :: boolean,
		groundState = raw.groundState :: GroundState,
		entityTrajectoryDelta = raw.entityTrajectoryDelta :: Vector3,
		playerStateVelocity = raw.playerStateVelocity :: Vector3,
		sourceHealth = raw.sourceHealth :: number,
	},
		nil
end

local function makeTrajectory(
	kind: "Stationary" | "Gravity",
	basePosition: Vector3,
	delta: Vector3,
	startTimeMilliseconds: number
): TrajectoryState
	local trajectory: TrajectoryState = {
		kind = kind,
		basePosition = basePosition,
		delta = delta,
		startTimeMilliseconds = startTimeMilliseconds,
	}
	table.freeze(trajectory)
	return trajectory
end

local function evaluateTrajectory(trajectory: TrajectoryState, nowMilliseconds: number): TrajectoryEvaluation
	local elapsedSeconds = math.max(nowMilliseconds - trajectory.startTimeMilliseconds, 0) / 1000
	local position = trajectory.basePosition
	local velocity = Vector3.zero
	if trajectory.kind == "Gravity" then
		position += trajectory.delta * elapsedSeconds - Vector3.yAxis * (0.5 * Constants.Gravity * elapsedSeconds * elapsedSeconds)
		velocity = trajectory.delta - Vector3.yAxis * (Constants.Gravity * elapsedSeconds)
	end
	local evaluation: TrajectoryEvaluation = {
		position = position,
		velocity = velocity,
	}
	table.freeze(evaluation)
	return evaluation
end

local function cloneBodyPose(
	body: MoverPushRules.Body,
	position: Vector3,
	velocity: Vector3,
	groundMoverId: string?
): MoverPushRules.Body
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({
		{
			id = body.id,
			sourceOrder = body.sourceOrder,
			position = position,
			size = body.size,
			centerOffset = body.centerOffset,
			velocity = velocity,
			groundMoverId = groundMoverId,
			contents = body.contents,
			clipMask = body.clipMask,
		},
	})
	return assert(bodies, bodyError or "body-queue physics body is invalid")[1]
end

local function cloneBodyContents(body: MoverPushRules.Body, contents: number): MoverPushRules.Body
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({
		{
			id = body.id,
			sourceOrder = body.sourceOrder,
			position = body.position,
			size = body.size,
			centerOffset = body.centerOffset,
			velocity = body.velocity,
			groundMoverId = body.groundMoverId,
			contents = contents,
			clipMask = body.clipMask,
		},
	})
	return assert(bodies, bodyError or "body-queue contents mutation is invalid")[1]
end

local function snapSourceVector(position: Vector3): Vector3
	local function snap(component: number): number
		local integral = math.modf(component / Constants.UnitsToStuds)
		return integral * Constants.UnitsToStuds
	end
	return Vector3.new(snap(position.X), snap(position.Y), snap(position.Z))
end

local function makePresentation(source: CopySource): PresentationState
	local presentation: PresentationState = {
		entityType = source.entityType,
		visible = source.visible,
		copiedFromLinkedSource = source.sourceLinked,
	}
	table.freeze(presentation)
	return presentation
end

local function buildPrepared(
	queueData: QueueData,
	decision: RespawnDecision,
	noDrop: boolean,
	source: CopySource?
): (PreparedCopy?, string?)
	if noDrop then
		local prepared: PreparedCopy = {
			kind = "NoDrop",
			decision = decision,
			-- CopyToBodyQue unlinks the client and returns immediately after the
			-- CONTENTS_NODROP test. No corpse pose/source payload is sampled.
			sourceLinked = false,
			queueIndex = nil,
			bodyId = nil,
			sourceOrder = nil,
			leaseGeneration = nil,
			occupantGeneration = nil,
			retainedHealth = nil,
			takedamage = nil,
			collisionBody = nil,
			trajectory = nil,
			presentation = nil,
		}
		table.freeze(prepared)
		return prepared, nil
	end
	if not source then
		return nil, "body-copy-source-required"
	end
	if decision.nowMilliseconds > MAXIMUM_TIME_MILLISECONDS - SINK_START_DELAY_MILLISECONDS then
		return nil, "body-copy-time-too-late"
	end
	local slot = queueData.slots[queueData.nextQueueIndex]
	if slot.occupantGeneration >= MAXIMUM_GENERATION then
		return nil, "body-queue-occupant-generation-exhausted"
	end
	local trajectoryKind = if source.groundState == "Grounded" then "Stationary" else "Gravity"
	local trajectoryDelta = if trajectoryKind == "Stationary"
		then source.entityTrajectoryDelta
		else source.playerStateVelocity
	local effectiveSource, sourceError =
		cloneBody(source.body, source.body.id, source.body.sourceOrder, trajectoryDelta)
	if not effectiveSource then
		return nil, sourceError
	end
	local copiedBody, copyError = MoverConsequenceRules.BuildBodyQueueCorpseBody({
		sourceBody = effectiveSource,
		bodyId = slot.bodyId,
		sourceOrder = slot.sourceOrder,
	})
	if not copiedBody then
		return nil, copyError
	end
	-- r.currentOrigin/collision ownership is distinct from s.pos trajectory.
	local collisionBody, collisionError = cloneBody(copiedBody, copiedBody.id, copiedBody.sourceOrder, Vector3.zero)
	if not collisionBody then
		return nil, collisionError
	end
	local prepared: PreparedCopy = {
		kind = "BodyCopy",
		decision = decision,
		sourceLinked = source.sourceLinked,
		queueIndex = slot.index,
		bodyId = slot.bodyId,
		sourceOrder = slot.sourceOrder,
		leaseGeneration = slot.leaseGeneration,
		occupantGeneration = slot.occupantGeneration + 1,
		retainedHealth = slot.retainedHealth,
		takedamage = source.sourceHealth > GIB_HEALTH,
		collisionBody = collisionBody,
		trajectory = makeTrajectory(trajectoryKind, source.body.position, trajectoryDelta, decision.nowMilliseconds),
		presentation = makePresentation(source),
	}
	table.freeze(prepared)
	return prepared, nil
end

local function makeTransaction(
	root: TransactionRoot,
	phase: "Open" | "Staged" | "Sealed",
	generation: number
): Transaction
	local transaction: Transaction = {
		phase = phase,
		generation = generation,
		baseRevision = root.baseCapability.data.revision,
		nextQueueIndex = root.baseCapability.data.nextQueueIndex,
	}
	table.freeze(transaction)
	transactionCapabilities[transaction :: table] = {
		current = true,
		root = root,
		phase = phase,
		generation = generation,
	}
	return transaction
end

local function inspectTransaction(value: unknown): (Transaction?, TransactionCapability?, string?)
	if type(value) ~= "table" then
		return nil, nil, "body-queue-transaction-not-table"
	end
	local capability = transactionCapabilities[value :: table]
	if not capability then
		return nil, nil, "unknown-body-queue-transaction"
	end
	if
		not capability.current
		or not capability.root.open
		or capability.root.queueRoot.activeTransaction ~= capability.root
	then
		return nil, nil, "stale-body-queue-transaction"
	end
	return value :: Transaction, capability, nil
end

local function buildSinkState(root: SinkRoot, data: SinkData): (SinkState, SinkCapability)
	local sink: SinkState = {
		queueLineage = data.queueLineage,
		queueIndex = data.queueIndex,
		occupantGeneration = data.occupantGeneration,
		collisionBody = data.collisionBody,
		trajectory = data.trajectory,
		presentation = data.presentation,
		timestampMilliseconds = data.timestampMilliseconds,
		nextThinkTimeMilliseconds = data.nextThinkTimeMilliseconds,
		evaluatedThroughMilliseconds = data.evaluatedThroughMilliseconds,
		linked = data.linked,
		physicsObject = data.physicsObject,
		sinkStepCount = data.sinkStepCount,
	}
	table.freeze(sink)
	local capability: SinkCapability = { current = false, root = root, data = data }
	return sink, capability
end

local function publishSinkState(root: SinkRoot, sink: SinkState, capability: SinkCapability): SinkState
	capability.current = true
	sinkCapabilities[sink :: table] = capability
	root.current = sink
	return sink
end

local function makeSinkState(root: SinkRoot, data: SinkData): SinkState
	local sink, capability = buildSinkState(root, data)
	return publishSinkState(root, sink, capability)
end

local function inspectSink(value: unknown): (SinkState?, SinkCapability?, string?)
	if type(value) ~= "table" then
		return nil, nil, "sink-state-not-table"
	end
	local capability = sinkCapabilities[value :: table]
	if not capability then
		return nil, nil, "unknown-sink-state"
	end
	if not capability.current or not capability.root.active or capability.root.current ~= value then
		return nil, nil, "stale-or-displaced-sink-state"
	end
	return value :: SinkState, capability, nil
end

function BodyQueueRules.Create(slotsValue: unknown): (QueueState?, string?)
	if not denseArrayLength(slotsValue, BODY_QUEUE_SIZE) then
		return nil, "body-queue-slots-not-fixed-array"
	end
	local source = slotsValue :: { [unknown]: unknown }
	local slots: { SlotData } = {}
	local seenIds: { [string]: boolean } = {}
	for index = 1, BODY_QUEUE_SIZE do
		local rawValue = source[index]
		if type(rawValue) ~= "table" then
			return nil, string.format("body-queue-slot-%d-not-table", index)
		end
		local raw = rawValue :: { [unknown]: unknown }
		if not hasExactKeys(raw, SLOT_KEYS, 4) then
			return nil, string.format("body-queue-slot-%d-invalid-shape", index)
		end
		if
			raw.index ~= index
			or raw.sourceOrder ~= EntitySourceOrderRules.FirstWorldSourceOrder + index - 1
			or not isStableId(raw.bodyId)
			or seenIds[raw.bodyId :: any]
			or not isInteger(raw.leaseGeneration, 1, MAXIMUM_GENERATION)
		then
			return nil, string.format("body-queue-slot-%d-invalid", index)
		end
		seenIds[raw.bodyId :: string] = true
		slots[index] = {
			index = index,
			bodyId = raw.bodyId :: string,
			sourceOrder = raw.sourceOrder :: number,
			leaseGeneration = raw.leaseGeneration :: number,
			occupantGeneration = 0,
			retainedHealth = 0,
			takedamage = false,
			hasOccupant = false,
			sinkRoot = nil,
		}
	end
	local root: QueueRoot = {
		lineage = table.freeze({}),
		currentState = nil,
		activeTransaction = nil,
		-- A current snapshot/death capability strongly retains its match lineage.
		-- Once those handles collect, completed-match duplicate-key maps may too.
		deathKeysByMatch = setmetatable({}, { __mode = "k" }) :: { [table]: { [string]: boolean } },
		deathIndexRevision = 0,
		pendingDeathKeysByMatch = setmetatable({}, { __mode = "k" }) :: { [table]: any },
	}
	return makeQueueState(root, { revision = 0, nextQueueIndex = 1, slots = slots }), nil
end

local function getPreparedDeathRecordCapability(preparedValue: unknown): (PreparedDeathRecordCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-prepared-death-record"
	end
	local capability = preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord]
	if not capability or capability.prepared ~= preparedValue then
		return nil, "invalid-body-queue-prepared-death-record"
	end
	return capability, nil
end

local function preparedDeathRecordCurrentError(
	preparedValue: unknown,
	capability: PreparedDeathRecordCapability
): string?
	local root = capability.root
	local snapshot = capability.snapshot
	local summary = capability.summary
	local player = snapshot.player
	local pendingBucket = capability.pendingBucket
	local committedMatchKeys = capability.baseDeathKeysByMatch[capability.matchLineage]
	local nextMatchKeys = capability.nextDeathKeysByMatch[capability.matchLineage]
	if
		not capability.current
		or capability.prepared ~= preparedValue
		or preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] ~= capability
		or preparedDeathRecordSummaries[summary] ~= preparedValue
		or not capability.baseQueueCapability.current
		or capability.baseQueueCapability.root ~= root
		or root.currentState ~= capability.baseState
		or root.activeTransaction ~= nil
		or root.deathKeysByMatch ~= capability.baseDeathKeysByMatch
		or root.deathIndexRevision ~= capability.baseDeathIndexRevision
		or capability.nextDeathIndexRevision ~= capability.baseDeathIndexRevision + 1
		or capability.nextDeathIndexRevision > MAXIMUM_GENERATION
		or root.pendingDeathKeysByMatch[capability.matchLineage] ~= pendingBucket
		or pendingBucket.count < 1
		or pendingBucket.reservations[capability.identityKey] ~= capability
		or (committedMatchKeys and committedMatchKeys[capability.identityKey] == true)
		or not nextMatchKeys
		or nextMatchKeys[capability.identityKey] ~= true
		or not table.isfrozen(capability.nextDeathKeysByMatch)
		or not table.isfrozen(nextMatchKeys)
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(snapshot)
		or not table.isfrozen(player)
		or not table.isfrozen(summary)
		or snapshot.queueLineage ~= root.lineage
		or snapshot.matchLineage ~= capability.matchLineage
		or snapshot.deathTimeMilliseconds ~= summary.deathTimeMilliseconds
		or snapshot.respawnTimeMilliseconds ~= summary.respawnTimeMilliseconds
		or snapshot.respawnTimeMilliseconds ~= snapshot.deathTimeMilliseconds + RESPAWN_DELAY_MILLISECONDS
		or snapshot.player ~= summary.player
		or summary.queueLineage ~= root.lineage
		or summary.queueRevision ~= capability.baseState.revision
		or summary.deathIndexRevision ~= capability.nextDeathIndexRevision
		or summary.matchLineage ~= capability.matchLineage
		or player.bodyId == ""
		or capability.deathCapability.root ~= root
		or capability.deathCapability.matchLineage ~= capability.matchLineage
		or capability.deathCapability.published
		or capability.deathCapability.consumed
		or capability.deathCapability.reservedBy ~= nil
		or deathCapabilities[snapshot :: table] ~= capability.deathCapability
	then
		return "stale-body-queue-prepared-death-record"
	end
	return nil
end

-- player_die writes respawnTime from the exact integer level.time at death.
-- This prepared owner preallocates the immutable snapshot and a complete next
-- duplicate-life index, but neither becomes inspectable until Apply.
function BodyQueueRules.PrepareDeathRecord(stateValue: unknown, requestValue: unknown): (PreparedDeathRecord?, string?)
	local state, queueCapability, stateError = inspectQueue(stateValue)
	if not state or not queueCapability then
		return nil, stateError
	end
	if queueCapability.root.activeTransaction then
		return nil, "body-queue-transaction-active"
	end
	if queueCapability.root.deathIndexRevision >= MAXIMUM_GENERATION then
		return nil, "body-queue-death-index-revision-exhausted"
	end
	local raw, player, key, requestError = validateDeathRequest(requestValue)
	if not raw or not player or not key then
		return nil, requestError
	end
	local matchLineage = raw.matchLineage :: table
	local committedKeys = queueCapability.root.deathKeysByMatch[matchLineage]
	if committedKeys and committedKeys[key] then
		return nil, "duplicate-death-life"
	end
	local pendingBucket = queueCapability.root.pendingDeathKeysByMatch[matchLineage] :: PendingDeathBucket?
	if pendingBucket and pendingBucket.reservations[key] then
		return nil, "duplicate-death-life-pending"
	end
	if not pendingBucket then
		pendingBucket = { count = 0, reservations = {} }
		queueCapability.root.pendingDeathKeysByMatch[matchLineage] = pendingBucket
	end
	local deathTime = raw.deathTimeMilliseconds :: number
	local snapshot: DeadClientSnapshot = {
		queueLineage = queueCapability.root.lineage,
		matchLineage = matchLineage,
		deathTimeMilliseconds = deathTime,
		respawnTimeMilliseconds = deathTime + RESPAWN_DELAY_MILLISECONDS,
		player = player,
	}
	table.freeze(snapshot)
	local deathCapability: DeathCapability = {
		root = queueCapability.root,
		matchLineage = matchLineage,
		published = false,
		consumed = false,
		reservedBy = nil,
	}
	local nextDeathIndexRevision = queueCapability.root.deathIndexRevision + 1
	local summary: PreparedDeathRecordSummary = {
		queueLineage = queueCapability.root.lineage,
		queueRevision = state.revision,
		deathIndexRevision = nextDeathIndexRevision,
		matchLineage = matchLineage,
		deathTimeMilliseconds = deathTime,
		respawnTimeMilliseconds = deathTime + RESPAWN_DELAY_MILLISECONDS,
		player = player,
	}
	table.freeze(summary)
	local prepared: PreparedDeathRecord = table.freeze({})
	local capability: PreparedDeathRecordCapability = {
		prepared = prepared,
		current = true,
		applyValidated = false,
		root = queueCapability.root,
		baseState = state,
		baseQueueCapability = queueCapability,
		baseDeathKeysByMatch = queueCapability.root.deathKeysByMatch,
		baseDeathIndexRevision = queueCapability.root.deathIndexRevision,
		nextDeathKeysByMatch = buildCommittedDeathKeys(queueCapability.root.deathKeysByMatch, matchLineage, key),
		nextDeathIndexRevision = nextDeathIndexRevision,
		matchLineage = matchLineage,
		identityKey = key,
		pendingBucket = pendingBucket,
		snapshot = snapshot,
		deathCapability = deathCapability,
		summary = summary,
	}
	pendingBucket.count += 1
	pendingBucket.reservations[key] = capability
	deathCapabilities[snapshot :: table] = deathCapability
	preparedDeathRecordCapabilities[prepared] = capability
	preparedDeathRecordSummaries[summary] = prepared
	return prepared, nil
end

function BodyQueueRules.InspectPreparedDeathRecordSummary(preparedValue: unknown): PreparedDeathRecordSummary?
	local capability = select(1, getPreparedDeathRecordCapability(preparedValue))
	if not capability or preparedDeathRecordCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

function BodyQueueRules.ValidatePreparedDeathRecordDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-prepared-death-summary"
	end
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or preparedDeathRecordSummaries[summaryValue :: PreparedDeathRecordSummary] ~= preparedValue
	then
		return false, "forged-body-queue-prepared-death-summary"
	end
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function BodyQueueRules.CanApplyPreparedDeathRecord(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- All tables, frozen public values, capabilities, and the complete next
-- duplicate index are allocated by PrepareDeathRecord. After the repeated
-- exact-current check, this boundary performs only owner assignments.
function BodyQueueRules.ApplyPreparedDeathRecord(preparedValue: unknown): DeadClientSnapshot
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-prepared-death-record")
	assert(capability.applyValidated, "body-queue-prepared-death-record-not-validated")
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-body-queue-prepared-death-record")

	local root = capability.root
	local pendingBucket = capability.pendingBucket
	root.deathKeysByMatch = capability.nextDeathKeysByMatch
	root.deathIndexRevision = capability.nextDeathIndexRevision
	pendingBucket.reservations[capability.identityKey] = nil
	pendingBucket.count -= 1
	if pendingBucket.count == 0 then
		root.pendingDeathKeysByMatch[capability.matchLineage] = nil
	end
	capability.deathCapability.published = true
	capability.current = false
	capability.applyValidated = false
	preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] = nil
	preparedDeathRecordSummaries[capability.summary] = nil
	return capability.snapshot
end

function BodyQueueRules.AbortPreparedDeathRecord(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	local pendingBucket = capability.pendingBucket
	if
		not capability.current
		or capability.deathCapability.published
		or capability.deathCapability.consumed
		or capability.root.pendingDeathKeysByMatch[capability.matchLineage] ~= pendingBucket
		or pendingBucket.reservations[capability.identityKey] ~= capability
	then
		return false, "stale-body-queue-prepared-death-record"
	end
	pendingBucket.reservations[capability.identityKey] = nil
	pendingBucket.count -= 1
	if pendingBucket.count == 0 then
		capability.root.pendingDeathKeysByMatch[capability.matchLineage] = nil
	end
	capability.current = false
	capability.applyValidated = false
	deathCapabilities[capability.snapshot :: table] = nil
	preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] = nil
	preparedDeathRecordSummaries[capability.summary] = nil
	return true, nil
end

local function getPreparedDeathRecordBatchCapability(
	preparedValue: unknown
): (PreparedDeathRecordBatchCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-prepared-death-record-batch"
	end
	local capability = preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch]
	if not capability or capability.prepared ~= preparedValue then
		return nil, "invalid-body-queue-prepared-death-record-batch"
	end
	return capability, nil
end

local function preparedDeathRecordBatchCurrentError(
	preparedValue: unknown,
	capability: PreparedDeathRecordBatchCapability
): string?
	local root = capability.root
	local pendingBucket = capability.pendingBucket
	local entries = capability.entries
	local snapshots = capability.snapshots
	local summary = capability.summary
	local operationCount = #entries
	local committedMatchKeys = capability.baseDeathKeysByMatch[capability.matchLineage]
	local nextMatchKeys = capability.nextDeathKeysByMatch[capability.matchLineage]
	if
		not capability.current
		or capability.prepared ~= preparedValue
		or preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] ~= capability
		or preparedDeathRecordBatchSummaries[summary] ~= preparedValue
		or not capability.baseQueueCapability.current
		or capability.baseQueueCapability.root ~= root
		or root.currentState ~= capability.baseState
		or root.activeTransaction ~= nil
		or root.deathKeysByMatch ~= capability.baseDeathKeysByMatch
		or root.deathIndexRevision ~= capability.baseDeathIndexRevision
		or capability.nextDeathIndexRevision ~= capability.baseDeathIndexRevision + 1
		or capability.nextDeathIndexRevision > MAXIMUM_GENERATION
		or root.pendingDeathKeysByMatch[capability.matchLineage] ~= pendingBucket
		or operationCount < 1
		or operationCount > MAXIMUM_DEATH_RECORD_BATCH_SIZE
		or #snapshots ~= operationCount
		or summary.operationCount ~= operationCount
		or #summary.records ~= operationCount
		or pendingBucket.count < operationCount
		or not nextMatchKeys
		or not table.isfrozen(capability.nextDeathKeysByMatch)
		or not table.isfrozen(nextMatchKeys)
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(entries)
		or not table.isfrozen(snapshots)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.records)
		or summary.queueLineage ~= root.lineage
		or summary.queueRevision ~= capability.baseState.revision
		or summary.deathIndexRevision ~= capability.nextDeathIndexRevision
		or summary.matchLineage ~= capability.matchLineage
	then
		return "stale-body-queue-prepared-death-record-batch"
	end
	for index, entry in entries do
		local snapshot = entry.snapshot
		local player = entry.player
		local recordSummary = entry.summary
		if
			not table.isfrozen(entry)
			or snapshots[index] ~= snapshot
			or summary.records[index] ~= recordSummary
			or pendingBucket.reservations[entry.identityKey] ~= capability
			or (committedMatchKeys and committedMatchKeys[entry.identityKey] == true)
			or nextMatchKeys[entry.identityKey] ~= true
			or not table.isfrozen(snapshot)
			or not table.isfrozen(player)
			or not table.isfrozen(recordSummary)
			or snapshot.queueLineage ~= root.lineage
			or snapshot.matchLineage ~= capability.matchLineage
			or snapshot.deathTimeMilliseconds ~= recordSummary.deathTimeMilliseconds
			or snapshot.respawnTimeMilliseconds ~= recordSummary.respawnTimeMilliseconds
			or snapshot.respawnTimeMilliseconds ~= snapshot.deathTimeMilliseconds + RESPAWN_DELAY_MILLISECONDS
			or snapshot.player ~= player
			or recordSummary.player ~= player
			or recordSummary.queueLineage ~= root.lineage
			or recordSummary.queueRevision ~= capability.baseState.revision
			or recordSummary.deathIndexRevision ~= capability.nextDeathIndexRevision
			or recordSummary.matchLineage ~= capability.matchLineage
			or player.bodyId == ""
			or entry.deathCapability.root ~= root
			or entry.deathCapability.matchLineage ~= capability.matchLineage
			or entry.deathCapability.published
			or entry.deathCapability.consumed
			or entry.deathCapability.reservedBy ~= nil
			or deathCapabilities[snapshot :: table] ~= entry.deathCapability
		then
			return "stale-body-queue-prepared-death-record-batch"
		end
	end
	return nil
end

-- A server frame may contain several lethal player transitions. Prepare keeps
-- their exact traversal order, reserves every match/player/life identity only
-- after the complete bounded list validates, and prebuilds one immutable next
-- duplicate index. All entries must belong to the same frozen match lineage.
function BodyQueueRules.PrepareDeathRecordBatch(
	stateValue: unknown,
	requestsValue: unknown
): (PreparedDeathRecordBatch?, string?)
	local state, queueCapability, stateError = inspectQueue(stateValue)
	if not state or not queueCapability then
		return nil, stateError
	end
	if queueCapability.root.activeTransaction then
		return nil, "body-queue-transaction-active"
	end
	if queueCapability.root.deathIndexRevision >= MAXIMUM_GENERATION then
		return nil, "body-queue-death-index-revision-exhausted"
	end
	local operationCount = boundedDenseArrayLength(requestsValue, MAXIMUM_DEATH_RECORD_BATCH_SIZE)
	if not operationCount then
		return nil, "body-queue-death-record-batch-not-dense-bounded-array"
	end
	local requests = requestsValue :: { [unknown]: unknown }
	local validatedEntries: { { raw: { [unknown]: unknown }, player: PlayerLeaseIdentity, key: string } } = {}
	local identityKeys: { string } = {}
	local seenIdentityKeys: { [string]: boolean } = {}
	local seenPlayerLeaseKeys: { [string]: boolean } = {}
	local matchLineage: table? = nil
	for index = 1, operationCount do
		local requestValue = rawget(requests, index)
		if type(requestValue) ~= "table" or getmetatable(requestValue :: table) ~= nil then
			return nil, "invalid-body-queue-death-record-batch-entry"
		end
		local raw, player, key, requestError = validateDeathRequest(requestValue)
		if not raw or not player or not key then
			return nil, requestError or "invalid-body-queue-death-record-batch-entry"
		end
		local entryMatchLineage = raw.matchLineage :: table
		if matchLineage == nil then
			matchLineage = entryMatchLineage
		elseif matchLineage ~= entryMatchLineage then
			return nil, "cross-lineage-body-queue-death-record-batch"
		end
		if seenIdentityKeys[key] then
			return nil, "duplicate-death-life-in-batch"
		end
		local leaseKey = playerLeaseKey(player)
		if seenPlayerLeaseKeys[leaseKey] then
			return nil, "duplicate-player-lease-in-death-record-batch"
		end
		local committedKeys = queueCapability.root.deathKeysByMatch[entryMatchLineage]
		if committedKeys and committedKeys[key] then
			return nil, "duplicate-death-life"
		end
		local pendingBucket = queueCapability.root.pendingDeathKeysByMatch[entryMatchLineage] :: PendingDeathBucket?
		if pendingBucket and pendingBucket.reservations[key] then
			return nil, "duplicate-death-life-pending"
		end
		seenIdentityKeys[key] = true
		seenPlayerLeaseKeys[leaseKey] = true
		identityKeys[index] = key
		validatedEntries[index] = { raw = raw, player = player, key = key }
	end
	local exactMatchLineage = matchLineage :: table
	table.freeze(identityKeys)
	local nextDeathIndexRevision = queueCapability.root.deathIndexRevision + 1
	local entries: { PreparedDeathRecordBatchEntry } = {}
	local snapshots: { DeadClientSnapshot } = {}
	local recordSummaries: { PreparedDeathRecordSummary } = {}
	for index, validated in validatedEntries do
		local deathTime = validated.raw.deathTimeMilliseconds :: number
		local snapshot: DeadClientSnapshot = {
			queueLineage = queueCapability.root.lineage,
			matchLineage = exactMatchLineage,
			deathTimeMilliseconds = deathTime,
			respawnTimeMilliseconds = deathTime + RESPAWN_DELAY_MILLISECONDS,
			player = validated.player,
		}
		table.freeze(snapshot)
		local deathCapability: DeathCapability = {
			root = queueCapability.root,
			matchLineage = exactMatchLineage,
			published = false,
			consumed = false,
			reservedBy = nil,
		}
		local recordSummary: PreparedDeathRecordSummary = {
			queueLineage = queueCapability.root.lineage,
			queueRevision = state.revision,
			deathIndexRevision = nextDeathIndexRevision,
			matchLineage = exactMatchLineage,
			deathTimeMilliseconds = deathTime,
			respawnTimeMilliseconds = deathTime + RESPAWN_DELAY_MILLISECONDS,
			player = validated.player,
		}
		table.freeze(recordSummary)
		local entry: PreparedDeathRecordBatchEntry = {
			identityKey = validated.key,
			player = validated.player,
			snapshot = snapshot,
			deathCapability = deathCapability,
			summary = recordSummary,
		}
		table.freeze(entry)
		entries[index] = entry
		snapshots[index] = snapshot
		recordSummaries[index] = recordSummary
	end
	table.freeze(entries)
	table.freeze(snapshots)
	table.freeze(recordSummaries)
	local summary: PreparedDeathRecordBatchSummary = {
		queueLineage = queueCapability.root.lineage,
		queueRevision = state.revision,
		deathIndexRevision = nextDeathIndexRevision,
		matchLineage = exactMatchLineage,
		operationCount = operationCount,
		records = recordSummaries,
	}
	table.freeze(summary)
	local pendingBucket = queueCapability.root.pendingDeathKeysByMatch[exactMatchLineage] :: PendingDeathBucket?
	if not pendingBucket then
		pendingBucket = { count = 0, reservations = {} }
		queueCapability.root.pendingDeathKeysByMatch[exactMatchLineage] = pendingBucket
	end
	local prepared: PreparedDeathRecordBatch = table.freeze({})
	local capability: PreparedDeathRecordBatchCapability = {
		prepared = prepared,
		current = true,
		applyValidated = false,
		root = queueCapability.root,
		baseState = state,
		baseQueueCapability = queueCapability,
		baseDeathKeysByMatch = queueCapability.root.deathKeysByMatch,
		baseDeathIndexRevision = queueCapability.root.deathIndexRevision,
		nextDeathKeysByMatch = buildCommittedDeathKeysForBatch(
			queueCapability.root.deathKeysByMatch,
			exactMatchLineage,
			identityKeys
		),
		nextDeathIndexRevision = nextDeathIndexRevision,
		matchLineage = exactMatchLineage,
		pendingBucket = pendingBucket,
		entries = entries,
		snapshots = snapshots,
		summary = summary,
	}
	for _, entry in entries do
		pendingBucket.count += 1
		pendingBucket.reservations[entry.identityKey] = capability
		deathCapabilities[entry.snapshot :: table] = entry.deathCapability
	end
	preparedDeathRecordBatchCapabilities[prepared] = capability
	preparedDeathRecordBatchSummaries[summary] = prepared
	return prepared, nil
end

function BodyQueueRules.InspectPreparedDeathRecordBatchSummary(preparedValue: unknown): PreparedDeathRecordBatchSummary?
	local capability = select(1, getPreparedDeathRecordBatchCapability(preparedValue))
	if not capability or preparedDeathRecordBatchCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

function BodyQueueRules.ValidatePreparedDeathRecordBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-prepared-death-record-batch-summary"
	end
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or preparedDeathRecordBatchSummaries[summaryValue :: PreparedDeathRecordBatchSummary] ~= preparedValue
	then
		return false, "forged-body-queue-prepared-death-record-batch-summary"
	end
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function BodyQueueRules.CanApplyPreparedDeathRecordBatch(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- Prepare owns every public/internal table and the complete next duplicate
-- index. After the repeated exact-current check, Apply only swaps the root,
-- clears reservations, publishes capabilities, and returns the prebuilt array.
function BodyQueueRules.ApplyPreparedDeathRecordBatch(preparedValue: unknown): { DeadClientSnapshot }
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-prepared-death-record-batch")
	assert(capability.applyValidated, "body-queue-prepared-death-record-batch-not-validated")
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-body-queue-prepared-death-record-batch")

	local root = capability.root
	local pendingBucket = capability.pendingBucket
	root.deathKeysByMatch = capability.nextDeathKeysByMatch
	root.deathIndexRevision = capability.nextDeathIndexRevision
	for _, entry in capability.entries do
		pendingBucket.reservations[entry.identityKey] = nil
		entry.deathCapability.published = true
	end
	pendingBucket.count -= #capability.entries
	if pendingBucket.count == 0 then
		root.pendingDeathKeysByMatch[capability.matchLineage] = nil
	end
	capability.current = false
	capability.applyValidated = false
	preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] = nil
	preparedDeathRecordBatchSummaries[capability.summary] = nil
	return capability.snapshots
end

function BodyQueueRules.AbortPreparedDeathRecordBatch(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	local pendingBucket = capability.pendingBucket
	if
		not capability.current
		or capability.root.pendingDeathKeysByMatch[capability.matchLineage] ~= pendingBucket
		or pendingBucket.count < #capability.entries
	then
		return false, "stale-body-queue-prepared-death-record-batch"
	end
	for _, entry in capability.entries do
		if
			entry.deathCapability.published
			or entry.deathCapability.consumed
			or pendingBucket.reservations[entry.identityKey] ~= capability
		then
			return false, "stale-body-queue-prepared-death-record-batch"
		end
	end
	for _, entry in capability.entries do
		pendingBucket.reservations[entry.identityKey] = nil
		deathCapabilities[entry.snapshot :: table] = nil
	end
	pendingBucket.count -= #capability.entries
	if pendingBucket.count == 0 then
		capability.root.pendingDeathKeysByMatch[capability.matchLineage] = nil
	end
	capability.current = false
	capability.applyValidated = false
	preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] = nil
	preparedDeathRecordBatchSummaries[capability.summary] = nil
	return true, nil
end

-- Compatibility seam for isolated callers. It executes the prepared owner
-- synchronously, so failure cannot strand a pending duplicate-life reservation.
function BodyQueueRules.RecordDeath(
	stateValue: unknown,
	requestValue: unknown
): (QueueState?, DeadClientSnapshot?, string?)
	local state = select(1, inspectQueue(stateValue))
	if not state then
		local _, _, stateError = inspectQueue(stateValue)
		return nil, nil, stateError
	end
	local prepared, prepareError = BodyQueueRules.PrepareDeathRecord(state, requestValue)
	if not prepared then
		return nil, nil, prepareError
	end
	local canApply, canApplyError = BodyQueueRules.CanApplyPreparedDeathRecord(prepared)
	if not canApply then
		BodyQueueRules.AbortPreparedDeathRecord(prepared)
		return nil, nil, canApplyError
	end
	local snapshot = BodyQueueRules.ApplyPreparedDeathRecord(prepared)
	-- Death binds only lineage/timing. Queue cursor and per-slot occupants are
	-- unchanged until a sealed respawn copy transaction commits.
	return state, snapshot, nil
end

function BodyQueueRules.ResolveRespawn(snapshotValue: unknown, requestValue: unknown): (RespawnDecision?, string?)
	local snapshot, _, snapshotError = inspectDeath(snapshotValue)
	if not snapshot then
		return nil, snapshotError
	end
	local raw, requestError = validateRespawnRequest(requestValue, RESPAWN_KEYS, 4, snapshot)
	if not raw then
		return nil, requestError
	end
	return makeDecision(snapshot, raw), nil
end

function BodyQueueRules.Begin(stateValue: unknown): (Transaction?, string?)
	local state, capability, stateError = inspectQueue(stateValue)
	if not state or not capability then
		return nil, stateError
	end
	if capability.root.activeTransaction then
		return nil, "body-queue-transaction-active"
	end
	local root: TransactionRoot = {
		identity = table.freeze({}),
		queueRoot = capability.root,
		baseState = state,
		baseCapability = capability,
		prepared = nil,
		preparedCapability = nil,
		preparedCommit = nil,
		preparedCommitCapability = nil,
		death = nil,
		deathCapability = nil,
		open = true,
	}
	capability.root.activeTransaction = root
	return makeTransaction(root, "Open", 1), nil
end

function BodyQueueRules.StageCopy(
	transactionValue: unknown,
	snapshotValue: unknown,
	requestValue: unknown
): (Transaction?, PreparedCopy?, string?)
	local _, transactionCapability, transactionError = inspectTransaction(transactionValue)
	if not transactionCapability then
		return nil, nil, transactionError
	end
	if transactionCapability.phase ~= "Open" then
		return nil, nil, "body-queue-transaction-not-open"
	end
	local snapshot, deathCapability, snapshotError = inspectDeath(snapshotValue)
	if not snapshot or not deathCapability then
		return nil, nil, snapshotError
	end
	local root = transactionCapability.root
	if deathCapability.root ~= root.queueRoot or snapshot.queueLineage ~= root.queueRoot.lineage then
		return nil, nil, "cross-queue-death-snapshot"
	end
	if deathCapability.reservedBy ~= nil then
		return nil, nil, "death-snapshot-already-staged"
	end
	if type(requestValue) ~= "table" then
		return nil, nil, "respawn-request-not-table"
	end
	local request = requestValue :: { [unknown]: unknown }
	if type(request.noDrop) ~= "boolean" then
		return nil, nil, "invalid-no-drop-policy"
	end
	local noDrop = request.noDrop :: boolean
	local raw, requestError = validateRespawnRequest(
		requestValue,
		if noDrop then NO_DROP_STAGE_KEYS else BODY_COPY_STAGE_KEYS,
		if noDrop then 5 else 6,
		snapshot
	)
	if not raw then
		return nil, nil, requestError
	end
	local decision = makeDecision(snapshot, raw)
	if not decision.canRespawn then
		return nil, nil, "respawn-not-ready"
	end
	local copySource: CopySource? = nil
	if not noDrop then
		local validatedCopySource, copySourceError = validateCopySource(raw.copySource, snapshot)
		if not validatedCopySource then
			return nil, nil, copySourceError
		end
		copySource = validatedCopySource
	end
	local prepared, preparedError = buildPrepared(root.baseCapability.data, decision, noDrop, copySource)
	if not prepared then
		return nil, nil, preparedError
	end
	local preparedCapability: PreparedCapability = { current = true, root = root }
	preparedCapabilities[prepared :: table] = preparedCapability
	root.prepared = prepared
	root.preparedCapability = preparedCapability
	root.death = snapshot
	root.deathCapability = deathCapability
	deathCapability.reservedBy = root
	transactionCapability.current = false
	return makeTransaction(root, "Staged", transactionCapability.generation + 1), prepared, nil
end

function BodyQueueRules.InspectPrepared(value: unknown): (PreparedCopy?, string?)
	if type(value) ~= "table" then
		return nil, "prepared-copy-not-table"
	end
	local capability = preparedCapabilities[value :: table]
	if not capability or not capability.current or not capability.root.open or capability.root.prepared ~= value then
		return nil, "stale-or-unknown-prepared-copy"
	end
	return value :: PreparedCopy, nil
end

function BodyQueueRules.Seal(transactionValue: unknown, preparedValue: unknown): (Transaction?, string?)
	local _, capability, transactionError = inspectTransaction(transactionValue)
	if not capability then
		return nil, transactionError
	end
	if capability.phase ~= "Staged" then
		return nil, "body-queue-transaction-not-staged"
	end
	local prepared, preparedError = BodyQueueRules.InspectPrepared(preparedValue)
	if not prepared or capability.root.prepared ~= prepared then
		return nil, preparedError or "prepared-copy-transaction-mismatch"
	end
	capability.current = false
	return makeTransaction(capability.root, "Sealed", capability.generation + 1), nil
end

local function invalidatePrepared(root: TransactionRoot)
	if root.preparedCapability then
		(root.preparedCapability :: PreparedCapability).current = false
	end
end

local function invalidatePreparedCommit(root: TransactionRoot)
	local preparedCommit = root.preparedCommit
	local capability = root.preparedCommitCapability :: PreparedCommitCapability?
	if capability then
		capability.current = false
		capability.applyValidated = false
		capability.nextStateCapability.current = false
		queueCapabilities[capability.nextState :: table] = nil
		if capability.sinkCapability then
			(capability.sinkCapability :: SinkCapability).current = false
		end
		if capability.sinkState then
			sinkCapabilities[capability.sinkState :: table] = nil
		end
	end
	if preparedCommit then
		preparedCommitCapabilities[preparedCommit] = nil
	end
	root.preparedCommit = nil
	root.preparedCommitCapability = nil
end

local function releaseDeathReservation(root: TransactionRoot)
	if root.deathCapability and root.deathCapability.reservedBy == root then
		root.deathCapability.reservedBy = nil
	end
end

function BodyQueueRules.Abort(transactionValue: unknown): (QueueState?, string?)
	local _, capability, transactionError = inspectTransaction(transactionValue)
	if not capability then
		return nil, transactionError
	end
	local root = capability.root
	capability.current = false
	invalidatePrepared(root)
	invalidatePreparedCommit(root)
	releaseDeathReservation(root)
	root.open = false
	root.queueRoot.activeTransaction = nil
	-- The base queue state was never invalidated or mutated.
	return root.baseState, nil
end

local function buildPreparedSink(queueRoot: QueueRoot, prepared: PreparedCopy): (SinkRoot, SinkState, SinkCapability)
	-- This root stays inactive until ApplyPrepared publishes every prebuilt
	-- capability inside the assignment-only owner boundary.
	local sinkRoot: SinkRoot = { active = false, current = nil }
	local sink, capability = buildSinkState(sinkRoot, {
		queueLineage = queueRoot.lineage,
		queueIndex = prepared.queueIndex :: number,
		occupantGeneration = prepared.occupantGeneration :: number,
		collisionBody = prepared.collisionBody :: MoverPushRules.Body,
		trajectory = prepared.trajectory :: TrajectoryState,
		presentation = prepared.presentation :: PresentationState,
		timestampMilliseconds = prepared.decision.nowMilliseconds,
		nextThinkTimeMilliseconds = prepared.decision.nowMilliseconds + SINK_START_DELAY_MILLISECONDS,
		evaluatedThroughMilliseconds = prepared.decision.nowMilliseconds,
		linked = true,
		physicsObject = true,
		sinkStepCount = 0,
	})
	return sinkRoot, sink, capability
end

local function getPreparedCommitCapability(preparedValue: unknown): (PreparedCommitCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-prepared-commit"
	end
	local capability = preparedCommitCapabilities[preparedValue :: PreparedCommit]
	if not capability then
		return nil, "invalid-body-queue-prepared-commit"
	end
	return capability, nil
end

-- Allocation-free lineage/currentness check shared by CanApplyPrepared and
-- ApplyPrepared. In particular, the exact displaced sink state is pinned: a
-- BodySink think between preparation and application invalidates the plan.
local function preparedCommitCurrentError(preparedValue: unknown, capability: PreparedCommitCapability): string?
	local root = capability.root
	local transactionCapability = capability.transactionCapability
	local preparedCopy = root.prepared
	local preparedCopyCapability = root.preparedCapability :: PreparedCapability?
	local deathCapability = root.deathCapability
	if
		not capability.current
		or not root.open
		or root.queueRoot.activeTransaction ~= root
		or root.preparedCommit ~= preparedValue
		or root.preparedCommitCapability ~= capability
		or not transactionCapability.current
		or transactionCapability.root ~= root
		or transactionCapability.phase ~= "Sealed"
		or not preparedCopy
		or not preparedCopyCapability
		or not preparedCopyCapability.current
		or preparedCopyCapability.root ~= root
		or preparedCapabilities[preparedCopy :: table] ~= preparedCopyCapability
		or not deathCapability
		or deathCapability.reservedBy ~= root
		or deathCapability.consumed
		or not root.death
		or deathCapabilities[root.death :: table] ~= deathCapability
		or not root.baseCapability.current
		or root.baseCapability.root ~= root.queueRoot
		or root.queueRoot.currentState ~= root.baseState
		or root.baseCapability.data.revision >= MAXIMUM_GENERATION
		or capability.nextData.revision ~= root.baseCapability.data.revision + 1
		or capability.nextState.revision ~= capability.nextData.revision
		or capability.nextState.lineage ~= root.queueRoot.lineage
		or capability.nextStateCapability.root ~= root.queueRoot
		or capability.nextStateCapability.data ~= capability.nextData
		or capability.nextStateCapability.current
		or queueCapabilities[capability.nextState :: table] ~= capability.nextStateCapability
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.nextState)
		or not table.isfrozen(capability.nextState.slots)
		or not table.isfrozen(capability.result)
		or capability.result.decision ~= preparedCopy.decision
		or capability.result.queueIndex ~= preparedCopy.queueIndex
		or capability.result.occupantGeneration ~= preparedCopy.occupantGeneration
	then
		return "stale-body-queue-prepared-commit"
	end

	if preparedCopy.kind == "NoDrop" then
		if
			capability.result.kind ~= "RespawnWithoutBody"
			or capability.result.sink ~= nil
			or capability.sinkRoot ~= nil
			or capability.sinkState ~= nil
			or capability.sinkCapability ~= nil
			or capability.displacedRoot ~= nil
			or capability.displacedState ~= nil
			or capability.displacedCapability ~= nil
			or capability.nextData.nextQueueIndex ~= root.baseCapability.data.nextQueueIndex
		then
			return "stale-body-queue-prepared-commit"
		end
		return nil
	end

	local queueIndex = preparedCopy.queueIndex :: number
	local baseSlot = root.baseCapability.data.slots[queueIndex]
	local nextSlot = capability.nextData.slots[queueIndex]
	local sinkRoot = capability.sinkRoot
	local sinkState = capability.sinkState
	local sinkCapability = capability.sinkCapability
	if
		queueIndex ~= root.baseCapability.data.nextQueueIndex
		or capability.result.kind ~= "RespawnWithBody"
		or capability.result.sink ~= sinkState
		or not baseSlot
		or not nextSlot
		or not sinkRoot
		or not sinkState
		or not sinkCapability
		or sinkRoot.active
		or sinkRoot.current ~= nil
		or sinkCapability.root ~= sinkRoot
		or sinkCapability.current
		or sinkCapabilities[sinkState :: table] ~= sinkCapability
		or not table.isfrozen(sinkState)
		or nextSlot.sinkRoot ~= sinkRoot
		or nextSlot.occupantGeneration ~= preparedCopy.occupantGeneration
		or nextSlot.retainedHealth ~= preparedCopy.retainedHealth
		or nextSlot.takedamage ~= preparedCopy.takedamage
		or not nextSlot.hasOccupant
		or capability.nextData.nextQueueIndex ~= (queueIndex % BODY_QUEUE_SIZE) + 1
	then
		return "stale-body-queue-prepared-commit"
	end

	local displacedRoot = capability.displacedRoot
	local displacedState = capability.displacedState
	local displacedCapability = capability.displacedCapability
	if baseSlot.sinkRoot ~= displacedRoot then
		return "stale-body-queue-prepared-commit"
	end
	if displacedRoot then
		if
			not displacedState
			or not displacedCapability
			or not displacedRoot.active
			or displacedRoot.current ~= displacedState
			or not displacedCapability.current
			or displacedCapability.root ~= displacedRoot
			or sinkCapabilities[displacedState :: table] ~= displacedCapability
		then
			return "stale-body-queue-prepared-commit"
		end
	elseif displacedState ~= nil or displacedCapability ~= nil then
		return "stale-body-queue-prepared-commit"
	end
	return nil
end

function BodyQueueRules.Prepare(transactionValue: unknown): (PreparedCommit?, string?)
	local _, capability, transactionError = inspectTransaction(transactionValue)
	if not capability then
		return nil, transactionError
	end
	if capability.phase ~= "Sealed" then
		return nil, "body-queue-transaction-not-sealed"
	end
	local root = capability.root
	local prepared = root.prepared
	local deathCapability = root.deathCapability
	if
		not prepared
		or not root.preparedCapability
		or not root.preparedCapability.current
		or not deathCapability
		or deathCapability.reservedBy ~= root
		or not root.baseCapability.current
		or root.queueRoot.currentState ~= root.baseState
		or root.preparedCommit ~= nil
		or root.preparedCommitCapability ~= nil
	then
		return nil, "body-queue-commit-preflight-failed"
	end
	if root.baseCapability.data.revision >= MAXIMUM_GENERATION then
		return nil, "body-queue-revision-exhausted"
	end
	local nextData: QueueData = {
		revision = root.baseCapability.data.revision + 1,
		nextQueueIndex = root.baseCapability.data.nextQueueIndex,
		slots = copySlots(root.baseCapability.data.slots),
	}
	local sink: SinkState? = nil
	local sinkRoot: SinkRoot? = nil
	local sinkCapability: SinkCapability? = nil
	local displacedRoot: SinkRoot? = nil
	local displacedState: SinkState? = nil
	local displacedCapability: SinkCapability? = nil
	if prepared.kind == "BodyCopy" then
		local queueIndex = prepared.queueIndex :: number
		local slot = nextData.slots[queueIndex]
		displacedRoot = slot.sinkRoot :: SinkRoot?
		if displacedRoot then
			displacedState = displacedRoot.current
			if not displacedRoot.active or not displacedState then
				return nil, "body-queue-displaced-sink-stale"
			end
			displacedCapability = sinkCapabilities[displacedState :: table]
			if
				not displacedCapability
				or not displacedCapability.current
				or displacedCapability.root ~= displacedRoot
			then
				return nil, "body-queue-displaced-sink-stale"
			end
		end
		sinkRoot, sink, sinkCapability = buildPreparedSink(root.queueRoot, prepared)
		slot.occupantGeneration = prepared.occupantGeneration :: number
		-- Deliberately preserve slot.retainedHealth: Q3 does not copy ent->health.
		slot.takedamage = prepared.takedamage :: boolean
		slot.hasOccupant = true
		slot.sinkRoot = sinkRoot
		nextData.nextQueueIndex = (queueIndex % BODY_QUEUE_SIZE) + 1
	end
	local nextState, nextStateCapability = buildQueueState(root.queueRoot, nextData)
	local result: CommitResult = {
		kind = if prepared.kind == "BodyCopy" then "RespawnWithBody" else "RespawnWithoutBody",
		decision = prepared.decision,
		queueIndex = prepared.queueIndex,
		occupantGeneration = prepared.occupantGeneration,
		sink = sink,
	}
	table.freeze(result)
	local preparedCommit: PreparedCommit = table.freeze({})
	local preparedCommitCapability: PreparedCommitCapability = {
		current = true,
		root = root,
		transactionCapability = capability,
		nextData = nextData,
		nextState = nextState,
		nextStateCapability = nextStateCapability,
		result = result,
		sinkRoot = sinkRoot,
		sinkState = sink,
		sinkCapability = sinkCapability,
		displacedRoot = displacedRoot,
		displacedState = displacedState,
		displacedCapability = displacedCapability,
		applyValidated = false,
	}
	-- Pre-register unpublished capabilities while allocation is still allowed.
	-- Their current=false flags plus unchanged owner roots keep them invisible to
	-- every public inspector until ApplyPrepared flips the prebuilt authority.
	queueCapabilities[nextState :: table] = nextStateCapability
	if sink then
		sinkCapabilities[sink :: table] = sinkCapability :: SinkCapability
	end
	preparedCommitCapabilities[preparedCommit] = preparedCommitCapability
	root.preparedCommit = preparedCommit
	root.preparedCommitCapability = preparedCommitCapability
	return preparedCommit, nil
end

function BodyQueueRules.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCommitCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- Prepare performs all cloning, freezing, canonicalization, sink creation, and
-- result construction. After the repeated allocation-free checks below,
-- ApplyPrepared contains only precomputed root/capability assignments and has
-- no fallible return channel.
function BodyQueueRules.ApplyPrepared(preparedValue: unknown): (QueueState, CommitResult)
	local capability, capabilityError = getPreparedCommitCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-prepared-commit")
	assert(capability.applyValidated, "body-queue-prepared-commit-not-validated")
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-body-queue-prepared-commit")

	local root = capability.root
	local transactionCapability = capability.transactionCapability
	local deathCapability = root.deathCapability :: DeathCapability
	local preparedCopyCapability = root.preparedCapability :: PreparedCapability
	local displacedRoot = capability.displacedRoot
	local displacedCapability = capability.displacedCapability
	local sinkRoot = capability.sinkRoot
	local sinkState = capability.sinkState
	local sinkCapability = capability.sinkCapability

	if displacedRoot then
		displacedRoot.active = false
		(displacedCapability :: SinkCapability).current = false
	end
	if sinkRoot then
		(sinkCapability :: SinkCapability).current = true
		sinkRoot.active = true
		sinkRoot.current = sinkState
	end
	transactionCapability.current = false
	preparedCopyCapability.current = false
	deathCapability.reservedBy = nil
	deathCapability.consumed = true
	root.baseCapability.current = false
	root.open = false
	root.queueRoot.activeTransaction = nil
	capability.nextStateCapability.current = true
	root.queueRoot.currentState = capability.nextState
	capability.current = false
	capability.applyValidated = false
	root.preparedCommit = nil
	root.preparedCommitCapability = nil
	preparedCommitCapabilities[preparedValue :: PreparedCommit] = nil
	return capability.nextState, capability.result
end

function BodyQueueRules.Commit(transactionValue: unknown): (QueueState?, CommitResult?, string?)
	local preparedCommit, prepareError = BodyQueueRules.Prepare(transactionValue)
	if not preparedCommit then
		return nil, nil, prepareError
	end
	local canApply, canApplyError = BodyQueueRules.CanApplyPrepared(preparedCommit)
	if not canApply then
		return nil, nil, canApplyError
	end
	local nextState, result = BodyQueueRules.ApplyPrepared(preparedCommit)
	return nextState, result, nil
end

function BodyQueueRules.GetCurrentSink(stateValue: unknown, queueIndexValue: unknown): (SinkState?, string?)
	local _, capability, stateError = inspectQueue(stateValue)
	if not capability then
		return nil, stateError
	end
	if not isInteger(queueIndexValue, 1, BODY_QUEUE_SIZE) then
		return nil, "invalid-body-queue-index"
	end
	local slot = capability.data.slots[queueIndexValue :: number]
	local sinkRoot = slot.sinkRoot :: SinkRoot?
	if not sinkRoot or not sinkRoot.active or not sinkRoot.current then
		return nil, "body-queue-slot-has-no-current-sink"
	end
	local sink, _, sinkError = inspectSink(sinkRoot.current)
	return sink, sinkError
end

function BodyQueueRules.DamageSink(
	stateValue: unknown,
	queueIndexValue: unknown,
	occupantGenerationValue: unknown,
	damageValue: unknown,
	bloodEnabledValue: unknown
): (QueueState?, SinkState?, DamageResult?, string?)
	local state, queueCapability, queueError = inspectQueue(stateValue)
	if not state or not queueCapability then
		return nil, nil, nil, queueError
	end
	if
		not isInteger(queueIndexValue, 1, BODY_QUEUE_SIZE)
		or not isInteger(occupantGenerationValue, 1, MAXIMUM_GENERATION)
		or not isInteger(damageValue, 1, -MINIMUM_HEALTH)
		or type(bloodEnabledValue) ~= "boolean"
	then
		return nil, nil, nil, "invalid-body-queue-damage-request"
	end
	local queueIndex = queueIndexValue :: number
	local slot = queueCapability.data.slots[queueIndex]
	local sinkRoot = slot.sinkRoot :: SinkRoot?
	local sink = if sinkRoot then sinkRoot.current else nil
	local currentSink, sinkCapability, sinkError = inspectSink(sink)
	if
		not currentSink
		or not sinkCapability
		or slot.occupantGeneration ~= occupantGenerationValue
		or currentSink.occupantGeneration ~= occupantGenerationValue
		or not slot.hasOccupant
		or not currentSink.linked
	then
		return nil, nil, nil, sinkError or "stale-body-queue-damage-target"
	end
	local beforeHealth = slot.retainedHealth
	if not slot.takedamage then
		local ignored: DamageResult = {
			applied = false,
			gibbed = false,
			queueIndex = queueIndex,
			occupantGeneration = occupantGenerationValue :: number,
			beforeHealth = beforeHealth,
			afterHealth = beforeHealth,
			takedamage = false,
		}
		table.freeze(ignored)
		return state, currentSink, ignored, nil
	end
	if queueCapability.data.revision >= MAXIMUM_GENERATION then
		return nil, nil, nil, "body-queue-damage-revision-exhausted"
	end

	local afterHealth = math.max(beforeHealth - (damageValue :: number), MINIMUM_HEALTH)
	local gibbed = false
	local takedamage = true
	local presentation: PresentationState = currentSink.presentation
	local collisionBody = currentSink.collisionBody
	if afterHealth <= GIB_HEALTH then
		if bloodEnabledValue == true then
			gibbed = true
			takedamage = false
			local invisiblePresentation: PresentationState = {
				entityType = "Invisible",
				visible = false,
				copiedFromLinkedSource = presentation.copiedFromLinkedSource,
			}
			table.freeze(invisiblePresentation)
			presentation = invisiblePresentation
			collisionBody = cloneBodyContents(collisionBody, 0)
		else
			afterHealth = GIB_HEALTH + 1
		end
	end

	local slots = copySlots(queueCapability.data.slots)
	slots[queueIndex].retainedHealth = afterHealth
	slots[queueIndex].takedamage = takedamage
	local nextQueue, nextQueueCapability = buildQueueState(queueCapability.root, {
		revision = queueCapability.data.revision + 1,
		nextQueueIndex = queueCapability.data.nextQueueIndex,
		slots = slots,
	})
	local nextSink, nextSinkCapability = buildSinkState(sinkCapability.root, {
		queueLineage = currentSink.queueLineage,
		queueIndex = currentSink.queueIndex,
		occupantGeneration = currentSink.occupantGeneration,
		collisionBody = collisionBody,
		trajectory = currentSink.trajectory,
		presentation = presentation,
		timestampMilliseconds = currentSink.timestampMilliseconds,
		nextThinkTimeMilliseconds = currentSink.nextThinkTimeMilliseconds,
		evaluatedThroughMilliseconds = currentSink.evaluatedThroughMilliseconds,
		linked = currentSink.linked,
		physicsObject = currentSink.physicsObject,
		sinkStepCount = currentSink.sinkStepCount,
	})
	local result: DamageResult = {
		applied = true,
		gibbed = gibbed,
		queueIndex = queueIndex,
		occupantGeneration = occupantGenerationValue :: number,
		beforeHealth = beforeHealth,
		afterHealth = afterHealth,
		takedamage = takedamage,
	}
	table.freeze(result)

	-- All validation/allocation completed above. Publish the paired sink/queue
	-- roots adjacently; copied-body damage owns no Player, Match, or score state.
	sinkCapability.current = false
	publishSinkState(sinkCapability.root, nextSink, nextSinkCapability)
	queueCapability.current = false
	publishQueueState(queueCapability.root, nextQueue, nextQueueCapability)
	return nextQueue, nextSink, result, nil
end

function BodyQueueRules.PrepareSinkMoverUpdate(
	sinkValue: unknown,
	finalBodyValue: unknown?
): (PreparedSinkMoverUpdate?, string?)
	local sink, capability, sinkError = inspectSink(sinkValue)
	if not sink or not capability then
		return nil, sinkError
	end
	local collisionBody = sink.collisionBody
	local trajectory = sink.trajectory
	local presentation = sink.presentation
	local linked = sink.linked
	local physicsObject = sink.physicsObject
	local nextThinkTimeMilliseconds = sink.nextThinkTimeMilliseconds
	if finalBodyValue == nil then
		linked = false
		physicsObject = false
		nextThinkTimeMilliseconds = nil
		presentation = table.freeze({
			entityType = presentation.entityType,
			visible = false,
			copiedFromLinkedSource = presentation.copiedFromLinkedSource,
		})
	else
		local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ finalBodyValue })
		if not bodies then
			return nil, bodyError
		end
		local finalBody = bodies[1]
		if
			finalBody.id ~= collisionBody.id
			or finalBody.sourceOrder ~= collisionBody.sourceOrder
			or finalBody.size ~= collisionBody.size
			or finalBody.centerOffset ~= collisionBody.centerOffset
			or finalBody.contents ~= collisionBody.contents
			or finalBody.clipMask ~= collisionBody.clipMask
		then
			return nil, "body-queue-mover-body-identity-drifted"
		end
		local displacement = finalBody.position - collisionBody.position
		collisionBody = finalBody
		trajectory = makeTrajectory(
			trajectory.kind,
			trajectory.basePosition + displacement,
			finalBody.velocity,
			trajectory.startTimeMilliseconds
		)
	end
	local nextState, nextCapability = buildSinkState(capability.root, {
		queueLineage = sink.queueLineage,
		queueIndex = sink.queueIndex,
		occupantGeneration = sink.occupantGeneration,
		collisionBody = collisionBody,
		trajectory = trajectory,
		presentation = presentation,
		timestampMilliseconds = sink.timestampMilliseconds,
		nextThinkTimeMilliseconds = nextThinkTimeMilliseconds,
		evaluatedThroughMilliseconds = sink.evaluatedThroughMilliseconds,
		linked = linked,
		physicsObject = physicsObject,
		sinkStepCount = sink.sinkStepCount,
	})
	local prepared: PreparedSinkMoverUpdate = table.freeze({})
	preparedSinkMoverCapabilities[prepared] = {
		status = "Prepared",
		baseState = sink,
		baseCapability = capability,
		nextState = nextState,
		nextCapability = nextCapability,
		applyValidated = false,
	}
	return prepared, nil
end

function BodyQueueRules.CanApplyPreparedSinkMoverUpdate(preparedValue: unknown): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedSinkMoverCapabilities[preparedValue :: PreparedSinkMoverUpdate]
		else nil
	if
		not capability
		or capability.status ~= "Prepared"
		or not capability.baseCapability.current
		or capability.baseCapability.root.current ~= capability.baseState
	then
		return false, "stale-prepared-body-queue-mover-update"
	end
	capability.applyValidated = true
	return true, nil
end

function BodyQueueRules.ApplyPreparedSinkMoverUpdate(preparedValue: unknown): SinkState
	local prepared = preparedValue :: PreparedSinkMoverUpdate
	local capability = assert(preparedSinkMoverCapabilities[prepared], "invalid prepared BodyQueue mover update")
	assert(
		capability.status == "Prepared"
			and capability.applyValidated
			and capability.baseCapability.current
			and capability.baseCapability.root.current == capability.baseState,
		"stale prepared BodyQueue mover update at apply"
	)
	capability.baseCapability.current = false
	publishSinkState(capability.nextCapability.root, capability.nextState, capability.nextCapability)
	capability.status = "Applied"
	capability.applyValidated = false
	preparedSinkMoverCapabilities[prepared] = nil
	return capability.nextState
end

function BodyQueueRules.AbortPreparedSinkMoverUpdate(preparedValue: unknown): boolean
	local prepared = if type(preparedValue) == "table" then preparedValue :: PreparedSinkMoverUpdate else nil
	local capability = if prepared then preparedSinkMoverCapabilities[prepared] else nil
	if not capability or capability.status ~= "Prepared" then
		return false
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	preparedSinkMoverCapabilities[prepared :: PreparedSinkMoverUpdate] = nil
	return true
end

function BodyQueueRules.EvaluateSinkTrajectory(
	stateValue: unknown,
	nowMillisecondsValue: unknown
): (TrajectoryEvaluation?, string?)
	local _, capability, stateError = inspectSink(stateValue)
	if not capability then
		return nil, stateError
	end
	if not isInteger(nowMillisecondsValue, capability.data.evaluatedThroughMilliseconds, MAXIMUM_TIME_MILLISECONDS) then
		return nil, "non-monotonic-or-invalid-sink-time"
	end
	return evaluateTrajectory(capability.data.trajectory, nowMillisecondsValue :: number), nil
end

function BodyQueueRules.RunSinkPhysics(
	stateValue: unknown,
	nowMillisecondsValue: unknown,
	traceValue: unknown
): (SinkState?, string?)
	local state, capability, stateError = inspectSink(stateValue)
	if not state or not capability then
		return nil, stateError
	end
	local data = capability.data
	if not isInteger(nowMillisecondsValue, data.evaluatedThroughMilliseconds, MAXIMUM_TIME_MILLISECONDS) then
		return nil, "non-monotonic-or-invalid-sink-time"
	end
	if data.trajectory.kind == "Stationary" then
		return BodyQueueRules.AdvanceSink(state, nowMillisecondsValue)
	end
	if type(traceValue) ~= "table" or getmetatable(traceValue :: table) ~= nil then
		return nil, "body-queue-physics-trace-not-plain-table"
	end
	local trace = traceValue :: { [unknown]: unknown }
	if
		not hasPhysicsTraceKeys(trace)
		or not isBoundedVector(rawget(trace, "endPosition"))
		or type(rawget(trace, "startSolid")) ~= "boolean"
		or type(rawget(trace, "noDrop")) ~= "boolean"
		or type(rawget(trace, "fraction")) ~= "number"
		or (rawget(trace, "fraction") :: number) ~= (rawget(trace, "fraction") :: number)
		or math.abs(rawget(trace, "fraction") :: number) == math.huge
		or (rawget(trace, "fraction") :: number) < 0
		or (rawget(trace, "fraction") :: number) > 1
		or (rawget(trace, "normal") ~= nil and (not isBoundedVector(rawget(trace, "normal")) or (
			rawget(trace, "normal") :: Vector3
		).Magnitude < 0.99 or (rawget(trace, "normal") :: Vector3).Magnitude > 1.01))
		or (rawget(trace, "moverId") ~= nil and type(rawget(trace, "moverId")) ~= "string")
	then
		return nil, "invalid-body-queue-physics-trace"
	end
	local now = nowMillisecondsValue :: number
	if now == data.evaluatedThroughMilliseconds then
		return state, nil
	end
	local fraction = if trace.startSolid == true then 0 else trace.fraction :: number
	local hit = fraction < 1
	if hit and trace.normal == nil then
		return nil, "body-queue-hit-trace-has-no-normal"
	end

	local trajectory = data.trajectory
	local evaluation = evaluateTrajectory(trajectory, now)
	local collisionPosition = trace.endPosition :: Vector3
	local collisionVelocity = evaluation.velocity
	local groundMoverId: string? = nil
	local linked = data.linked
	local physicsObject = data.physicsObject
	local nextThink = data.nextThinkTimeMilliseconds
	local sinkSteps = data.sinkStepCount
	local presentation = data.presentation

	-- G_RunItem links the traced currentOrigin, then runs BodySink before the
	-- no-drop and bounce branches.
	if linked and nextThink ~= nil and nextThink <= now then
		if now - data.timestampMilliseconds > UNLINK_AGE_EXCLUSIVE_MILLISECONDS then
			linked = false
			physicsObject = false
			nextThink = nil
			presentation = table.freeze({
				entityType = presentation.entityType,
				visible = false,
				copiedFromLinkedSource = presentation.copiedFromLinkedSource,
			})
		else
			trajectory = makeTrajectory(
				trajectory.kind,
				trajectory.basePosition - Vector3.yAxis * Constants.UnitsToStuds,
				trajectory.delta,
				trajectory.startTimeMilliseconds
			)
			sinkSteps += 1
			nextThink = now + SINK_STEP_MILLISECONDS
		end
	end

	if linked and hit and trace.noDrop == true then
		linked = false
		physicsObject = false
		nextThink = nil
		presentation = table.freeze({
			entityType = presentation.entityType,
			visible = false,
			copiedFromLinkedSource = presentation.copiedFromLinkedSource,
		})
	elseif linked and hit then
		-- CopyToBodyQue sets physicsBounce = 0. The reflected vector therefore
		-- becomes zero before Q3's upward-plane/40-unit stop check.
		local normal = trace.normal :: Vector3
		collisionVelocity = Vector3.zero
		if normal.Y > 0 then
			collisionPosition = snapSourceVector(collisionPosition + Vector3.yAxis * Constants.UnitsToStuds)
			groundMoverId = trace.moverId :: string?
			trajectory = makeTrajectory("Stationary", collisionPosition, Vector3.zero, 0)
		else
			collisionPosition += normal * Constants.UnitsToStuds
			trajectory = makeTrajectory("Gravity", collisionPosition, Vector3.zero, now)
		end
	end

	local collisionBody = cloneBodyPose(data.collisionBody, collisionPosition, collisionVelocity, groundMoverId)
	local nextState = makeSinkState(capability.root, {
		queueLineage = data.queueLineage,
		queueIndex = data.queueIndex,
		occupantGeneration = data.occupantGeneration,
		collisionBody = collisionBody,
		trajectory = trajectory,
		presentation = presentation,
		timestampMilliseconds = data.timestampMilliseconds,
		nextThinkTimeMilliseconds = nextThink,
		evaluatedThroughMilliseconds = now,
		linked = linked,
		physicsObject = physicsObject,
		sinkStepCount = sinkSteps,
	})
	capability.current = false
	return nextState, nil
end

function BodyQueueRules.AdvanceSink(stateValue: unknown, nowMillisecondsValue: unknown): (SinkState?, string?)
	local state, capability, stateError = inspectSink(stateValue)
	if not state or not capability then
		return nil, stateError
	end
	local data = capability.data
	if not isInteger(nowMillisecondsValue, data.evaluatedThroughMilliseconds, MAXIMUM_TIME_MILLISECONDS) then
		return nil, "non-monotonic-or-invalid-sink-time"
	end
	local now = nowMillisecondsValue :: number
	if now == data.evaluatedThroughMilliseconds then
		return state, nil
	end
	local trajectory = data.trajectory
	local linked = data.linked
	local physicsObject = data.physicsObject
	local nextThink = data.nextThinkTimeMilliseconds
	local sinkSteps = data.sinkStepCount
	-- One call models at most one G_RunThink/BodySink invocation. A late frame
	-- never catches up missed 100 ms ticks.
	if linked and nextThink ~= nil and nextThink <= now then
		if now - data.timestampMilliseconds > UNLINK_AGE_EXCLUSIVE_MILLISECONDS then
			linked = false
			physicsObject = false
			nextThink = nil
		else
			trajectory = makeTrajectory(
				trajectory.kind,
				trajectory.basePosition + SINK_STEP_VECTOR,
				trajectory.delta,
				trajectory.startTimeMilliseconds
			)
			sinkSteps += 1
			nextThink = now + SINK_STEP_MILLISECONDS
		end
	end
	local nextState = makeSinkState(capability.root, {
		queueLineage = data.queueLineage,
		queueIndex = data.queueIndex,
		occupantGeneration = data.occupantGeneration,
		collisionBody = data.collisionBody,
		trajectory = trajectory,
		presentation = data.presentation,
		timestampMilliseconds = data.timestampMilliseconds,
		nextThinkTimeMilliseconds = nextThink,
		evaluatedThroughMilliseconds = now,
		linked = linked,
		physicsObject = physicsObject,
		sinkStepCount = sinkSteps,
	})
	capability.current = false
	return nextState, nil
end

BodyQueueRules.BodyQueueSize = BODY_QUEUE_SIZE
BodyQueueRules.RespawnDelayMilliseconds = RESPAWN_DELAY_MILLISECONDS
BodyQueueRules.SinkStartDelayMilliseconds = SINK_START_DELAY_MILLISECONDS
BodyQueueRules.SinkStepMilliseconds = SINK_STEP_MILLISECONDS
BodyQueueRules.UnlinkAgeExclusiveMilliseconds = UNLINK_AGE_EXCLUSIVE_MILLISECONDS
BodyQueueRules.SinkStepDistance = Constants.UnitsToStuds
BodyQueueRules.GibHealth = GIB_HEALTH
BodyQueueRules.MaximumDeathRecordBatchSize = MAXIMUM_DEATH_RECORD_BATCH_SIZE

return table.freeze(BodyQueueRules)
