--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only owner for the Quake III respawn body queue translated from:
  code/game/g_client.c (InitBodyQue, CopyToBodyQue, BodySink, respawn)
  code/game/g_active.c (ClientThink_real respawn gates)
  code/game/g_combat.c (player_die, body_die, GIB_HEALTH)

This live boundary owns the already-reserved body-queue descriptors, their
cursor agreement with EntitySlotService, prepared death/respawn capabilities,
and numeric physicsObject advancement. Combat's respawn coordinator binds the
exact post-Pmove/Corpse dependencies; a separate presentation owner consumes
only data diagnostics and never becomes collision or lifecycle authority.

For a normal copy, StageRespawn lets BodyQueueRules select the slot first, then
advances EntitySlotService's private cursor and requires the two descriptors to
match exactly. This service is the sole holder of EntitySlotService's opaque
body-cursor owner capability. CONTENTS_NODROP never opens the entity-slot owner.
Prepare does all allocation in both nested owners; ApplyPrepared performs the
final repeated allocation-free checks and applies EntitySlot before BodyQueue
with no yield or callback between them. Abort remains legal only before the
first apply, and public sink inspection returns cloned data rather than kernel
capabilities.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "BodyQueueService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local BodyQueueRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("BodyQueueRules"))
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))
local WorldPointContents = require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldPointContents"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntitySlotService = require(script.Parent.EntitySlotService)

local BodyQueueService = {}

export type DeathHandle = {}
export type PreparedDeathRecord = {}
export type PreparedDeathRecordBatch = {}
export type PreparedMoverUpdate = {}
export type MoverUpdateReceipt = {}
export type MoverAdapter = {
	read Collect: () -> ({ MoverPushRules.Body }, { [string]: number }),
	read ResolveSine: (bodyId: string) -> MoverPushRules.BodyMutation,
	read ResolveBlockedDoor: (bodyId: string) -> MoverPushRules.BodyMutation,
	read Prepare: (finalBodies: unknown) -> (PreparedMoverUpdate?, string?),
	read CanApply: (prepared: unknown) -> (boolean, string?),
	read Apply: (prepared: unknown) -> MoverUpdateReceipt,
	read Flush: (receipt: unknown) -> boolean,
	read Abort: (prepared: unknown) -> boolean,
}
export type PhysicsTraceResult = {
	read hit: boolean,
	read fraction: number,
	read position: Vector3,
	read normal: Vector3,
	read moverId: string?,
	read startSolid: boolean,
}
export type PhysicsAdapter = {
	read Trace: (frame: unknown, origin: Vector3, displacement: Vector3) -> PhysicsTraceResult,
	read PointContents: (position: Vector3) -> number,
}
export type PresentationAdapter = {
	read StageSink: (sink: SinkDiagnostic) -> boolean,
}

type MoverPreparedCapability = {
	status: "Prepared" | "Applied" | "Flushed" | "Aborted",
	children: { { prepared: BodyQueueRules.PreparedSinkMoverUpdate, aborted: boolean } },
	prepared: PreparedMoverUpdate,
	receipt: MoverUpdateReceipt,
}
export type TransactionToken = {}
export type PreparedRespawn = {}
export type AcceptedRespawnGate = {}

export type DeathHandleSummary = {
	read queueLineage: unknown,
	read queueRevision: number,
	read deathIndexRevision: number,
	read matchLineage: unknown,
	read deathTimeMilliseconds: number,
	read respawnTimeMilliseconds: number,
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read playerUserId: number,
	read lifeSequence: number,
}
export type PreparedDeathRecordSummary = DeathHandleSummary

export type DeathRecordBatchRequest = {
	read player: Player,
	read matchLineage: unknown,
	read deathTimeMilliseconds: number,
	read lifeSequence: number,
}

export type PreparedDeathRecordBatchSummary = {
	read queueLineage: unknown,
	read queueRevision: number,
	read deathIndexRevision: number,
	read matchLineage: unknown,
	read operationCount: number,
	read records: { PreparedDeathRecordSummary },
}

export type AcceptedRespawnGateSummary = {
	read deathHandleSummary: DeathHandleSummary,
	read respawnKind: BodyQueueRules.RespawnKind,
	read nowMilliseconds: number,
	read attackPressed: boolean,
	read useHoldablePressed: boolean,
	read forceRespawnSeconds: number,
}

export type StageDiagnostic = {
	read kind: "NoDrop" | "BodyCopy",
	read respawnKind: BodyQueueRules.RespawnKind,
	read nowMilliseconds: number,
	read queueIndex: number?,
	read bodyId: string?,
	read sourceOrder: number?,
	read leaseGeneration: number?,
	read occupantGeneration: number?,
	read retainedHealth: number?,
	read takedamage: boolean?,
	read trajectoryKind: ("Stationary" | "Gravity")?,
}

export type SinkDiagnostic = {
	read queueIndex: number,
	read occupantGeneration: number,
	read collisionPosition: Vector3,
	read trajectoryKind: "Stationary" | "Gravity",
	read trajectoryBasePosition: Vector3,
	read trajectoryDelta: Vector3,
	read timestampMilliseconds: number,
	read nextThinkTimeMilliseconds: number?,
	read evaluatedThroughMilliseconds: number,
	read linked: boolean,
	read physicsObject: boolean,
	read sinkStepCount: number,
	read visible: boolean,
}

export type ApplyDiagnostic = {
	read kind: "RespawnWithoutBody" | "RespawnWithBody",
	read respawnKind: BodyQueueRules.RespawnKind,
	read nowMilliseconds: number,
	read queueIndex: number?,
	read occupantGeneration: number?,
	read sink: SinkDiagnostic?,
}

export type CombatTarget = {
	read queueIndex: number,
	read occupantGeneration: number,
	read body: MoverPushRules.Body,
	read retainedHealth: number,
	read takedamage: boolean,
}

export type DebugSnapshot = {
	read started: boolean,
	read revision: number,
	read nextBodyQueueIndex: number,
	read entityNextBodyQueueIndex: number,
	read cursorsSynchronized: boolean,
	read occupiedSlotCount: number,
	read transactionActive: boolean,
	read transactionStatus: string?,
	read transactionKind: string?,
	read transactionApplyValidated: boolean,
	read entityLifecycleDrainPending: boolean,
}

type TransactionStatus = "Sealed" | "Prepared" | "Applied" | "Aborted"
type Transaction = {
	token: TransactionToken,
	status: TransactionStatus,
	kind: "NoDrop" | "BodyCopy",
	deathHandle: DeathHandle,
	deathHandleCapability: DeathHandleCapability,
	bodyTransaction: BodyQueueRules.Transaction,
	preparedCopy: BodyQueueRules.PreparedCopy,
	stageDiagnostic: StageDiagnostic,
	applyDiagnostic: ApplyDiagnostic?,
	entityToken: EntitySlotService.TransactionToken?,
	entityBaseSnapshot: EntitySlotService.DebugSnapshot?,
	entityPrepared: EntitySlotService.PreparedCommit?,
	bodyPrepared: BodyQueueRules.PreparedCommit?,
	prepared: PreparedRespawn?,
}

type PreparedCapability = {
	transaction: Transaction,
	status: "Prepared" | "Applied" | "Aborted",
	applyValidated: boolean,
}

type DeathHandleCapability = {
	status: "Prepared" | "Applied" | "Consumed" | "Aborted",
	snapshot: BodyQueueRules.DeadClientSnapshot?,
	player: Player,
	registration: EntitySlotService.Registration,
	handle: DeathHandle,
	summary: DeathHandleSummary,
	acceptedRespawnGate: AcceptedRespawnGate?,
}

type AcceptedRespawnRequest = {
	nowMilliseconds: number,
	attackPressed: boolean,
	useHoldablePressed: boolean,
	forceRespawnSeconds: number,
}

type AcceptedRespawnGateCapability = {
	gate: AcceptedRespawnGate,
	status: "Accepted" | "Consumed" | "Aborted",
	deathHandle: DeathHandle,
	deathHandleCapability: DeathHandleCapability,
	request: AcceptedRespawnRequest,
	decision: BodyQueueRules.RespawnDecision,
	summary: AcceptedRespawnGateSummary,
}

type PreparedDeathRecordCapability = {
	prepared: PreparedDeathRecord,
	status: "Prepared" | "Applied" | "Aborted",
	applyValidated: boolean,
	player: Player,
	registration: EntitySlotService.Registration,
	rulesPrepared: BodyQueueRules.PreparedDeathRecord,
	rulesSummary: BodyQueueRules.PreparedDeathRecordSummary,
	handle: DeathHandle,
	handleCapability: DeathHandleCapability,
	summary: PreparedDeathRecordSummary,
}

type PreparedDeathRecordBatchEntry = {
	player: Player,
	registration: EntitySlotService.Registration,
	rulesSummary: BodyQueueRules.PreparedDeathRecordSummary,
	handle: DeathHandle,
	handleCapability: DeathHandleCapability,
	summary: PreparedDeathRecordSummary,
}

type PreparedDeathRecordBatchCapability = {
	prepared: PreparedDeathRecordBatch,
	status: "Prepared" | "Applied" | "Aborted",
	applyValidated: boolean,
	rulesPrepared: BodyQueueRules.PreparedDeathRecordBatch,
	rulesSummary: BodyQueueRules.PreparedDeathRecordBatchSummary,
	entries: { PreparedDeathRecordBatchEntry },
	handles: { DeathHandle },
	summary: PreparedDeathRecordBatchSummary,
}

local started = false
local queueState: BodyQueueRules.QueueState? = nil
local entityCursorOwner: EntitySlotService.BodyQueueCursorOwner? = nil
local activeTransaction: Transaction? = nil
local lastEntityFrameLevelTimeMilliseconds = -1
local lastEntityFrameSourceOrder = -1
local activePreparedMoverUpdate: PreparedMoverUpdate? = nil
local moverPreparedCapabilities: { [PreparedMoverUpdate]: MoverPreparedCapability } = setmetatable({}, { __mode = "k" }) :: any
local moverReceiptCapabilities: { [MoverUpdateReceipt]: MoverPreparedCapability } = setmetatable({}, { __mode = "k" }) :: any
local entityLifecycleDrainPending = false
local physicsAdapter: PhysicsAdapter? = nil
local presentationAdapter: PresentationAdapter? = nil
local deathSnapshots = setmetatable({}, { __mode = "k" }) :: {
	[DeathHandle]: DeathHandleCapability,
}
local deathHandleSummaries = setmetatable({}, { __mode = "k" }) :: {
	[DeathHandleSummary]: DeathHandle,
}
local acceptedRespawnGateCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[AcceptedRespawnGate]: AcceptedRespawnGateCapability,
}
local acceptedRespawnGateSummaries = setmetatable({}, { __mode = "k" }) :: {
	[AcceptedRespawnGateSummary]: AcceptedRespawnGate,
}
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
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedRespawn]: PreparedCapability,
}

local RESPAWN_GATE_REQUEST_KEYS = table.freeze({
	nowMilliseconds = true,
	attackPressed = true,
	useHoldablePressed = true,
	forceRespawnSeconds = true,
})
local DEATH_RECORD_BATCH_REQUEST_KEYS = table.freeze({
	player = true,
	matchLineage = true,
	deathTimeMilliseconds = true,
	lifeSequence = true,
})
local NO_DROP_COPY_REQUEST_KEYS = table.freeze({ noDrop = true })
local BODY_COPY_REQUEST_KEYS = table.freeze({ noDrop = true, copySource = true })
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
local BODY_VALUE_KEYS = table.freeze({
	id = true,
	sourceOrder = true,
	position = true,
	size = true,
	centerOffset = true,
	velocity = true,
	groundMoverId = true,
	contents = true,
	clipMask = true,
})

local function hasExactRawKeys(
	value: { [unknown]: unknown },
	allowed: { [string]: boolean },
	expectedCount: number
): boolean
	if getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value do
		if type(key) ~= "string" or not allowed[key] then
			return false
		end
		count += 1
	end
	return count == expectedCount
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

local function makeAcceptedRespawnRequest(value: unknown): (AcceptedRespawnRequest?, string?)
	if type(value) ~= "table" then
		return nil, "respawn-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactRawKeys(raw, RESPAWN_GATE_REQUEST_KEYS, 4) then
		return nil, "invalid-respawn-request-shape"
	end
	local request: AcceptedRespawnRequest = {
		nowMilliseconds = rawget(raw, "nowMilliseconds") :: any,
		attackPressed = rawget(raw, "attackPressed") :: any,
		useHoldablePressed = rawget(raw, "useHoldablePressed") :: any,
		forceRespawnSeconds = rawget(raw, "forceRespawnSeconds") :: any,
	}
	table.freeze(request)
	return request, nil
end

local function canonicalizeBodyValue(value: unknown): ({ [string]: any }?, string?)
	if type(value) ~= "table" then
		return nil, "body-queue-copy-source-body-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	local groundMoverId = rawget(raw, "groundMoverId")
	local expectedCount = if groundMoverId == nil then 8 else 9
	if not hasExactRawKeys(raw, BODY_VALUE_KEYS, expectedCount) then
		return nil, "invalid-body-queue-copy-source-body-shape"
	end
	local body: { [string]: any } = {
		id = rawget(raw, "id"),
		sourceOrder = rawget(raw, "sourceOrder"),
		position = rawget(raw, "position"),
		size = rawget(raw, "size"),
		centerOffset = rawget(raw, "centerOffset"),
		velocity = rawget(raw, "velocity"),
		contents = rawget(raw, "contents"),
		clipMask = rawget(raw, "clipMask"),
	}
	if groundMoverId ~= nil then
		body.groundMoverId = groundMoverId
	end
	table.freeze(body)
	return body, nil
end

local function canonicalizeCopySourceValue(value: unknown): ({ [string]: any }?, string?)
	if type(value) ~= "table" then
		return nil, "body-queue-copy-source-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactRawKeys(raw, COPY_SOURCE_KEYS, 14) then
		return nil, "invalid-body-queue-copy-source-shape"
	end
	local body, bodyError = canonicalizeBodyValue(rawget(raw, "body"))
	if not body then
		return nil, bodyError
	end
	local source: { [string]: any } = {
		matchLineage = rawget(raw, "matchLineage"),
		playerBodyId = rawget(raw, "playerBodyId"),
		playerSourceOrder = rawget(raw, "playerSourceOrder"),
		playerLeaseGeneration = rawget(raw, "playerLeaseGeneration"),
		playerUserId = rawget(raw, "playerUserId"),
		lifeSequence = rawget(raw, "lifeSequence"),
		body = body,
		sourceLinked = rawget(raw, "sourceLinked"),
		entityType = rawget(raw, "entityType"),
		visible = rawget(raw, "visible"),
		groundState = rawget(raw, "groundState"),
		entityTrajectoryDelta = rawget(raw, "entityTrajectoryDelta"),
		playerStateVelocity = rawget(raw, "playerStateVelocity"),
		sourceHealth = rawget(raw, "sourceHealth"),
	}
	table.freeze(source)
	return source, nil
end

local function makeBodyCopyStageRequest(accepted: AcceptedRespawnRequest, value: unknown): ({ [string]: any }?, string?)
	if type(value) ~= "table" then
		return nil, "body-queue-copy-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	local noDrop = rawget(raw, "noDrop")
	if type(noDrop) ~= "boolean" then
		return nil, "invalid-no-drop-policy"
	end
	local expectedKeys = if noDrop then NO_DROP_COPY_REQUEST_KEYS else BODY_COPY_REQUEST_KEYS
	local expectedCount = if noDrop then 1 else 2
	if not hasExactRawKeys(raw, expectedKeys, expectedCount) then
		return nil, "invalid-body-queue-copy-request-shape"
	end
	local request: { [string]: any } = {
		nowMilliseconds = accepted.nowMilliseconds,
		attackPressed = accepted.attackPressed,
		useHoldablePressed = accepted.useHoldablePressed,
		forceRespawnSeconds = accepted.forceRespawnSeconds,
		noDrop = noDrop,
	}
	if not noDrop then
		local copySource, copySourceError = canonicalizeCopySourceValue(rawget(raw, "copySource"))
		if not copySource then
			return nil, copySourceError
		end
		request.copySource = copySource
	end
	table.freeze(request)
	return request, nil
end

local function currentQueue(): (BodyQueueRules.QueueState?, string?)
	if not started or not queueState then
		return nil, "body-queue-service-not-started"
	end
	return queueState, nil
end

local function getTransaction(tokenValue: unknown, requiredStatus: TransactionStatus?): (Transaction?, string?)
	local transaction = activeTransaction
	if type(tokenValue) ~= "table" or not transaction or transaction.token ~= tokenValue then
		return nil, "invalid-body-queue-service-transaction"
	end
	if requiredStatus and transaction.status ~= requiredStatus then
		return nil, "invalid-body-queue-service-transaction-state"
	end
	return transaction, nil
end

local function getPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-service-prepared-respawn"
	end
	local capability = preparedCapabilities[preparedValue :: PreparedRespawn]
	if not capability then
		return nil, "invalid-body-queue-service-prepared-respawn"
	end
	local transaction = capability.transaction
	if
		capability.status ~= "Prepared"
		or transaction.status ~= "Prepared"
		or transaction.prepared ~= preparedValue
		or activeTransaction ~= transaction
		or not table.isfrozen(preparedValue :: any)
	then
		return nil, "stale-body-queue-service-prepared-respawn"
	end
	return capability, nil
end

local function getPreparedDeathRecordCapability(preparedValue: unknown): (PreparedDeathRecordCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-service-prepared-death-record"
	end
	local capability = preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord]
	if not capability or capability.prepared ~= preparedValue then
		return nil, "invalid-body-queue-service-prepared-death-record"
	end
	return capability, nil
end

local function preparedDeathRecordCurrentError(
	preparedValue: unknown,
	capability: PreparedDeathRecordCapability
): string?
	local registration = EntitySlotService.GetPlayerRegistration(capability.player)
	local summary = capability.summary
	local rulesSummary = capability.rulesSummary
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] ~= capability
		or preparedDeathRecordSummaries[summary] ~= preparedValue
		or capability.player.Parent ~= Players
		or capability.player.UserId ~= summary.playerUserId
		or registration ~= capability.registration
		or registration.bodyId ~= summary.playerBodyId
		or registration.sourceOrder ~= summary.playerSourceOrder
		or registration.generation ~= summary.playerLeaseGeneration
		or capability.handleCapability.status ~= "Prepared"
		or capability.handleCapability.snapshot ~= nil
		or capability.handleCapability.player ~= capability.player
		or capability.handleCapability.registration ~= capability.registration
		or capability.handleCapability.handle ~= capability.handle
		or capability.handleCapability.summary ~= summary
		or deathSnapshots[capability.handle] ~= capability.handleCapability
		or deathHandleSummaries[summary] ~= capability.handle
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.handle)
		or not table.isfrozen(summary)
		or summary.queueLineage ~= rulesSummary.queueLineage
		or summary.queueRevision ~= rulesSummary.queueRevision
		or summary.deathIndexRevision ~= rulesSummary.deathIndexRevision
		or summary.matchLineage ~= rulesSummary.matchLineage
		or summary.deathTimeMilliseconds ~= rulesSummary.deathTimeMilliseconds
		or summary.respawnTimeMilliseconds ~= rulesSummary.respawnTimeMilliseconds
		or summary.playerBodyId ~= rulesSummary.player.bodyId
		or summary.playerSourceOrder ~= rulesSummary.player.sourceOrder
		or summary.playerLeaseGeneration ~= rulesSummary.player.leaseGeneration
		or summary.playerUserId ~= rulesSummary.player.playerUserId
		or summary.lifeSequence ~= rulesSummary.player.lifeSequence
		or summary.respawnTimeMilliseconds ~= summary.deathTimeMilliseconds + BodyQueueRules.RespawnDelayMilliseconds
		or BodyQueueRules.InspectPreparedDeathRecordSummary(capability.rulesPrepared) ~= rulesSummary
	then
		return "stale-body-queue-service-prepared-death-record"
	end
	local validRulesDependency =
		BodyQueueRules.ValidatePreparedDeathRecordDependency(capability.rulesPrepared, rulesSummary)
	if not validRulesDependency then
		return "stale-body-queue-service-prepared-death-record"
	end
	return nil
end

local function getPreparedDeathRecordBatchCapability(
	preparedValue: unknown
): (PreparedDeathRecordBatchCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-body-queue-service-prepared-death-record-batch"
	end
	local capability = preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch]
	if not capability or capability.prepared ~= preparedValue then
		return nil, "invalid-body-queue-service-prepared-death-record-batch"
	end
	return capability, nil
end

local function preparedDeathRecordBatchCurrentError(
	preparedValue: unknown,
	capability: PreparedDeathRecordBatchCapability
): string?
	local summary = capability.summary
	local rulesSummary = capability.rulesSummary
	local entries = capability.entries
	local handles = capability.handles
	local operationCount = #entries
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] ~= capability
		or preparedDeathRecordBatchSummaries[summary] ~= preparedValue
		or operationCount < 1
		or operationCount > BodyQueueRules.MaximumDeathRecordBatchSize
		or #handles ~= operationCount
		or summary.operationCount ~= operationCount
		or #summary.records ~= operationCount
		or rulesSummary.operationCount ~= operationCount
		or #rulesSummary.records ~= operationCount
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(entries)
		or not table.isfrozen(handles)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.records)
		or summary.queueLineage ~= rulesSummary.queueLineage
		or summary.queueRevision ~= rulesSummary.queueRevision
		or summary.deathIndexRevision ~= rulesSummary.deathIndexRevision
		or summary.matchLineage ~= rulesSummary.matchLineage
		or BodyQueueRules.InspectPreparedDeathRecordBatchSummary(capability.rulesPrepared) ~= rulesSummary
	then
		return "stale-body-queue-service-prepared-death-record-batch"
	end
	for index, entry in entries do
		local registration = EntitySlotService.GetPlayerRegistration(entry.player)
		local recordSummary = entry.summary
		local rulesRecordSummary = entry.rulesSummary
		if
			not table.isfrozen(entry)
			or handles[index] ~= entry.handle
			or summary.records[index] ~= recordSummary
			or rulesSummary.records[index] ~= rulesRecordSummary
			or entry.player.Parent ~= Players
			or entry.player.UserId ~= recordSummary.playerUserId
			or registration ~= entry.registration
			or registration.bodyId ~= recordSummary.playerBodyId
			or registration.sourceOrder ~= recordSummary.playerSourceOrder
			or registration.generation ~= recordSummary.playerLeaseGeneration
			or entry.handleCapability.status ~= "Prepared"
			or entry.handleCapability.snapshot ~= nil
			or entry.handleCapability.player ~= entry.player
			or entry.handleCapability.registration ~= entry.registration
			or entry.handleCapability.handle ~= entry.handle
			or entry.handleCapability.summary ~= recordSummary
			or deathSnapshots[entry.handle] ~= entry.handleCapability
			or deathHandleSummaries[recordSummary] ~= entry.handle
			or not table.isfrozen(entry.handle)
			or not table.isfrozen(recordSummary)
			or recordSummary.queueLineage ~= rulesRecordSummary.queueLineage
			or recordSummary.queueRevision ~= rulesRecordSummary.queueRevision
			or recordSummary.deathIndexRevision ~= rulesRecordSummary.deathIndexRevision
			or recordSummary.matchLineage ~= rulesRecordSummary.matchLineage
			or recordSummary.deathTimeMilliseconds ~= rulesRecordSummary.deathTimeMilliseconds
			or recordSummary.respawnTimeMilliseconds ~= rulesRecordSummary.respawnTimeMilliseconds
			or recordSummary.playerBodyId ~= rulesRecordSummary.player.bodyId
			or recordSummary.playerSourceOrder ~= rulesRecordSummary.player.sourceOrder
			or recordSummary.playerLeaseGeneration ~= rulesRecordSummary.player.leaseGeneration
			or recordSummary.playerUserId ~= rulesRecordSummary.player.playerUserId
			or recordSummary.lifeSequence ~= rulesRecordSummary.player.lifeSequence
			or recordSummary.respawnTimeMilliseconds
				~= recordSummary.deathTimeMilliseconds + BodyQueueRules.RespawnDelayMilliseconds
		then
			return "stale-body-queue-service-prepared-death-record-batch"
		end
	end
	local validRulesDependency =
		BodyQueueRules.ValidatePreparedDeathRecordBatchDependency(capability.rulesPrepared, rulesSummary)
	if not validRulesDependency then
		return "stale-body-queue-service-prepared-death-record-batch"
	end
	return nil
end

-- An applied Q3 death snapshot remains pending through the strict respawn
-- delay, but its Roblox Player/clientNum lease must remain the exact same live
-- owner. A disconnected player or a released/reused EntitySlot can never spend
-- the old handle to advance the body ring. This check is repeated at Stage,
-- CanApply, and in both final pre-apply passes.
local function appliedDeathHandleCurrentError(capability: DeathHandleCapability): string?
	local snapshot = capability.snapshot
	local handle = capability.handle
	local summary = capability.summary
	local registration = EntitySlotService.GetPlayerRegistration(capability.player)
	if
		capability.status ~= "Applied"
		or not snapshot
		or deathSnapshots[handle] ~= capability
		or deathHandleSummaries[summary] ~= handle
		or not table.isfrozen(handle)
		or not table.isfrozen(summary)
		or capability.player.Parent ~= Players
		or not registration
		or registration ~= capability.registration
		or registration.bodyId ~= snapshot.player.bodyId
		or registration.sourceOrder ~= snapshot.player.sourceOrder
		or registration.generation ~= snapshot.player.leaseGeneration
		or capability.player.UserId ~= snapshot.player.playerUserId
		or summary.queueLineage ~= snapshot.queueLineage
		or summary.matchLineage ~= snapshot.matchLineage
		or summary.deathTimeMilliseconds ~= snapshot.deathTimeMilliseconds
		or summary.respawnTimeMilliseconds ~= snapshot.respawnTimeMilliseconds
		or summary.playerBodyId ~= snapshot.player.bodyId
		or summary.playerSourceOrder ~= snapshot.player.sourceOrder
		or summary.playerLeaseGeneration ~= snapshot.player.leaseGeneration
		or summary.playerUserId ~= snapshot.player.playerUserId
		or summary.lifeSequence ~= snapshot.player.lifeSequence
		or summary.respawnTimeMilliseconds
			~= summary.deathTimeMilliseconds + BodyQueueRules.RespawnDelayMilliseconds
	then
		return "stale-body-queue-service-death-handle"
	end
	return nil
end

local function getAcceptedRespawnGateCapability(gateValue: unknown): (AcceptedRespawnGateCapability?, string?)
	if type(gateValue) ~= "table" then
		return nil, "invalid-body-queue-service-accepted-respawn-gate"
	end
	local capability = acceptedRespawnGateCapabilities[gateValue :: AcceptedRespawnGate]
	if not capability or capability.gate ~= gateValue then
		return nil, "invalid-body-queue-service-accepted-respawn-gate"
	end
	return capability, nil
end

local function acceptedRespawnGateCurrentError(gateValue: unknown, capability: AcceptedRespawnGateCapability): string?
	local request = capability.request
	local decision = capability.decision
	local summary = capability.summary
	local deathHandleCapability = capability.deathHandleCapability
	local deathSnapshot = deathHandleCapability.snapshot
	if
		capability.status ~= "Accepted"
		or capability.gate ~= gateValue
		or acceptedRespawnGateCapabilities[capability.gate] ~= capability
		or acceptedRespawnGateSummaries[summary] ~= capability.gate
		or deathHandleCapability.acceptedRespawnGate ~= capability.gate
		or deathSnapshots[capability.deathHandle] ~= deathHandleCapability
		or deathHandleCapability.handle ~= capability.deathHandle
		or not table.isfrozen(capability.gate)
		or not table.isfrozen(request)
		or not table.isfrozen(decision)
		or not table.isfrozen(summary)
		or not deathSnapshot
		or appliedDeathHandleCurrentError(deathHandleCapability) ~= nil
		or summary.deathHandleSummary ~= deathHandleCapability.summary
		or summary.respawnKind ~= decision.kind
		or summary.nowMilliseconds ~= request.nowMilliseconds
		or summary.nowMilliseconds ~= decision.nowMilliseconds
		or summary.attackPressed ~= request.attackPressed
		or summary.useHoldablePressed ~= request.useHoldablePressed
		or summary.forceRespawnSeconds ~= request.forceRespawnSeconds
		or not decision.canRespawn
		or decision.kind == "Wait"
		or decision.elapsedSinceDeathMilliseconds ~= request.nowMilliseconds - deathSnapshot.deathTimeMilliseconds
		or decision.elapsedSinceRespawnGateMilliseconds
			~= request.nowMilliseconds - deathSnapshot.respawnTimeMilliseconds
	then
		return "stale-body-queue-service-accepted-respawn-gate"
	end
	return nil
end

-- EntitySlotService.Abort restores its transaction base and then drains any
-- PlayerRemoving work that arrived while the transaction was open. World,
-- map, level-time, and cursor authority must therefore be exact; only client
-- counts may decrease and revision may advance through that documented drain.
local function entityAuthorityPreservedAfterAbort(
	base: EntitySlotService.DebugSnapshot,
	current: EntitySlotService.DebugSnapshot
): boolean
	local clientLifecycleUnchanged = current.activeClientCount == base.activeClientCount
		and current.registeredPlayerCount == base.registeredPlayerCount
	local revisionValid = if clientLifecycleUnchanged
		then current.revision == base.revision
		else current.revision >= base.revision
	return current.started == base.started
		and current.playerReleaseLifecycleSealed == base.playerReleaseLifecycleSealed
		and current.levelTimeMilliseconds == base.levelTimeMilliseconds
		and current.highestWorldSourceOrder == base.highestWorldSourceOrder
		and current.activeWorldCount == base.activeWorldCount
		and current.registeredWorldCount == base.registeredWorldCount
		and current.mapSpawnPlanInstalled == base.mapSpawnPlanInstalled
		and current.mapRegistrationCount == base.mapRegistrationCount
		and current.bodyQueueCount == base.bodyQueueCount
		and current.nextBodyQueueIndex == base.nextBodyQueueIndex
		and current.bodyQueueCursorOwnerClaimed == base.bodyQueueCursorOwnerClaimed
		and current.activeClientCount <= base.activeClientCount
		and current.registeredPlayerCount <= base.registeredPlayerCount
		and current.pendingPlayerReleaseCount == 0
		and not current.transactionOpen
		and revisionValid
end

local function abortNested(
	bodyTransaction: BodyQueueRules.Transaction,
	entityToken: EntitySlotService.TransactionToken?,
	entityBaseSnapshot: EntitySlotService.DebugSnapshot?
): (boolean, string?)
	local baseQueue = queueState
	local abortedQueue, bodyError = BodyQueueRules.Abort(bodyTransaction)
	local entityAborted = true
	local entityError: string? = nil
	if entityToken then
		entityAborted, entityError = EntitySlotService.Abort(entityToken)
	end
	if not abortedQueue or abortedQueue ~= baseQueue then
		return false, bodyError or "body-queue-rules-abort-failed"
	end
	if not entityAborted then
		return false, entityError or "body-queue-entity-slot-abort-failed"
	end
	if entityBaseSnapshot then
		local currentEntitySnapshot = EntitySlotService.GetDebugSnapshot()
		if not entityAuthorityPreservedAfterAbort(entityBaseSnapshot, currentEntitySnapshot) then
			return false, "body-queue-entity-slot-abort-authority-drift"
		end
	end
	return true, nil
end

local function descriptorMatches(
	preparedCopy: BodyQueueRules.PreparedCopy,
	registration: EntitySlotService.Registration
): boolean
	return preparedCopy.kind == "BodyCopy"
		and registration.kind == "BodyQueue"
		and registration.bodyQueueIndex == preparedCopy.queueIndex
		and registration.bodyId == preparedCopy.bodyId
		and registration.sourceOrder == preparedCopy.sourceOrder
		and registration.generation == preparedCopy.leaseGeneration
end

local function makeStageDiagnostic(copy: BodyQueueRules.PreparedCopy): StageDiagnostic
	local diagnostic: StageDiagnostic = {
		kind = copy.kind,
		respawnKind = copy.decision.kind,
		nowMilliseconds = copy.decision.nowMilliseconds,
		queueIndex = copy.queueIndex,
		bodyId = copy.bodyId,
		sourceOrder = copy.sourceOrder,
		leaseGeneration = copy.leaseGeneration,
		occupantGeneration = copy.occupantGeneration,
		retainedHealth = copy.retainedHealth,
		takedamage = copy.takedamage,
		trajectoryKind = if copy.trajectory then copy.trajectory.kind else nil,
	}
	table.freeze(diagnostic)
	return diagnostic
end

local function makePreparedSinkDiagnostic(copy: BodyQueueRules.PreparedCopy): SinkDiagnostic?
	if copy.kind ~= "BodyCopy" then
		return nil
	end
	local collisionBody = assert(copy.collisionBody, "prepared body copy lost collision")
	local trajectory = assert(copy.trajectory, "prepared body copy lost trajectory")
	local queueIndex = assert(copy.queueIndex, "prepared body copy lost queue index")
	local occupantGeneration = assert(copy.occupantGeneration, "prepared body copy lost occupant generation")
	local now = copy.decision.nowMilliseconds
	local diagnostic: SinkDiagnostic = {
		queueIndex = queueIndex,
		occupantGeneration = occupantGeneration,
		collisionPosition = collisionBody.position,
		trajectoryKind = trajectory.kind,
		trajectoryBasePosition = trajectory.basePosition,
		trajectoryDelta = trajectory.delta,
		timestampMilliseconds = now,
		nextThinkTimeMilliseconds = now + BodyQueueRules.SinkStartDelayMilliseconds,
		evaluatedThroughMilliseconds = now,
		linked = true,
		physicsObject = true,
		sinkStepCount = 0,
		visible = assert(copy.presentation, "prepared body copy lost presentation").visible,
	}
	table.freeze(diagnostic)
	return diagnostic
end

local function makeApplyDiagnostic(copy: BodyQueueRules.PreparedCopy): ApplyDiagnostic
	local diagnostic: ApplyDiagnostic = {
		kind = if copy.kind == "BodyCopy" then "RespawnWithBody" else "RespawnWithoutBody",
		respawnKind = copy.decision.kind,
		nowMilliseconds = copy.decision.nowMilliseconds,
		queueIndex = copy.queueIndex,
		occupantGeneration = copy.occupantGeneration,
		sink = makePreparedSinkDiagnostic(copy),
	}
	table.freeze(diagnostic)
	return diagnostic
end

function BodyQueueService.Start(): (boolean, string?)
	if started then
		return false, "body-queue-service-already-started"
	end
	if not EntitySlotService.IsStarted() then
		return false, "entity-slot-service-not-started"
	end
	local descriptors: { BodyQueueRules.QueueSlotDescriptor } = {}
	for index = 1, BodyQueueRules.BodyQueueSize do
		local registration = EntitySlotService.GetBodyQueueRegistration(index)
		if not registration or registration.kind ~= "BodyQueue" or registration.bodyQueueIndex ~= index then
			return false, string.format("body-queue-registration-%d-unavailable", index)
		end
		descriptors[index] = {
			index = index,
			bodyId = registration.bodyId,
			sourceOrder = registration.sourceOrder,
			leaseGeneration = registration.generation,
		}
	end
	local state, createError = BodyQueueRules.Create(descriptors)
	if not state then
		return false, createError or "body-queue-state-create-failed"
	end
	local entitySnapshot = EntitySlotService.GetDebugSnapshot()
	if entitySnapshot.nextBodyQueueIndex ~= state.nextQueueIndex then
		return false, "body-queue-startup-cursor-mismatch"
	end
	local cursorOwner, cursorOwnerError = EntitySlotService.ClaimBodyQueueCursorOwner()
	if not cursorOwner then
		return false, cursorOwnerError or "body-queue-cursor-owner-claim-failed"
	end
	queueState = state
	entityCursorOwner = cursorOwner
	activeTransaction = nil
	entityLifecycleDrainPending = false
	started = true
	return true, nil
end

-- This ticket is still unwired to Combat. Its frozen summary is the future
-- exact cross-owner dependency: queue/match/player lease/life/time are captured
-- now, while its prebuilt DeathHandle remains unusable until Apply.
function BodyQueueService.PrepareDeathRecord(
	playerValue: unknown,
	matchLineageValue: unknown,
	deathTimeMillisecondsValue: unknown,
	lifeSequenceValue: unknown
): (PreparedDeathRecord?, PreparedDeathRecordSummary?, string?)
	local state, stateError = currentQueue()
	if not state then
		return nil, nil, stateError
	end
	if typeof(playerValue) ~= "Instance" or not (playerValue :: Instance):IsA("Player") then
		return nil, nil, "invalid-body-queue-death-player"
	end
	local player = playerValue :: Player
	if player.Parent ~= Players then
		return nil, nil, "stale-body-queue-death-player"
	end
	local registration = EntitySlotService.GetPlayerRegistration(player)
	if not registration then
		return nil, nil, "body-queue-death-player-registration-unavailable"
	end
	local rulesPrepared, prepareError = BodyQueueRules.PrepareDeathRecord(state, {
		matchLineage = matchLineageValue,
		deathTimeMilliseconds = deathTimeMillisecondsValue,
		playerBodyId = registration.bodyId,
		playerSourceOrder = registration.sourceOrder,
		playerLeaseGeneration = registration.generation,
		playerUserId = player.UserId,
		lifeSequence = lifeSequenceValue,
	})
	if not rulesPrepared then
		return nil, nil, prepareError or "body-queue-death-record-prepare-failed"
	end
	local rulesSummary = BodyQueueRules.InspectPreparedDeathRecordSummary(rulesPrepared)
	if not rulesSummary then
		BodyQueueRules.AbortPreparedDeathRecord(rulesPrepared)
		return nil, nil, "body-queue-death-record-summary-unavailable"
	end
	local handle: DeathHandle = table.freeze({})
	local summary: PreparedDeathRecordSummary = {
		queueLineage = rulesSummary.queueLineage,
		queueRevision = rulesSummary.queueRevision,
		deathIndexRevision = rulesSummary.deathIndexRevision,
		matchLineage = rulesSummary.matchLineage,
		deathTimeMilliseconds = rulesSummary.deathTimeMilliseconds,
		respawnTimeMilliseconds = rulesSummary.respawnTimeMilliseconds,
		playerBodyId = rulesSummary.player.bodyId,
		playerSourceOrder = rulesSummary.player.sourceOrder,
		playerLeaseGeneration = rulesSummary.player.leaseGeneration,
		playerUserId = rulesSummary.player.playerUserId,
		lifeSequence = rulesSummary.player.lifeSequence,
	}
	table.freeze(summary)
	local handleCapability: DeathHandleCapability = {
		status = "Prepared",
		snapshot = nil,
		player = player,
		registration = registration,
		handle = handle,
		summary = summary,
		acceptedRespawnGate = nil,
	}
	local prepared: PreparedDeathRecord = table.freeze({})
	local capability: PreparedDeathRecordCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		player = player,
		registration = registration,
		rulesPrepared = rulesPrepared,
		rulesSummary = rulesSummary,
		handle = handle,
		handleCapability = handleCapability,
		summary = summary,
	}
	deathSnapshots[handle] = handleCapability
	deathHandleSummaries[summary] = handle
	preparedDeathRecordCapabilities[prepared] = capability
	preparedDeathRecordSummaries[summary] = prepared
	return prepared, summary, nil
end

function BodyQueueService.InspectPreparedDeathRecordSummary(preparedValue: unknown): PreparedDeathRecordSummary?
	local capability = select(1, getPreparedDeathRecordCapability(preparedValue))
	if not capability or preparedDeathRecordCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

function BodyQueueService.ValidatePreparedDeathRecordDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-service-prepared-death-summary"
	end
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or preparedDeathRecordSummaries[summaryValue :: PreparedDeathRecordSummary] ~= preparedValue
	then
		return false, "forged-body-queue-service-prepared-death-summary"
	end
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

-- The same summary object is allocated before death apply so a future
-- multi-owner composite can bind the exact death dependency without creating
-- capabilities inside an assignment-only commit. It is intentionally hidden
-- while Prepared and disappears as soon as the handle is consumed or stale.
function BodyQueueService.InspectDeathHandleSummary(deathHandleValue: unknown): DeathHandleSummary?
	if type(deathHandleValue) ~= "table" then
		return nil
	end
	local capability = deathSnapshots[deathHandleValue :: DeathHandle]
	if not capability or appliedDeathHandleCurrentError(capability) then
		return nil
	end
	return capability.summary
end

function BodyQueueService.ValidateDeathHandleDependency(
	deathHandleValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(deathHandleValue) ~= "table" then
		return false, "invalid-body-queue-service-death-handle"
	end
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-service-death-handle-summary"
	end
	local deathHandle = deathHandleValue :: DeathHandle
	local capability = deathSnapshots[deathHandle]
	if not capability then
		return false, "invalid-body-queue-service-death-handle"
	end
	if
		capability.summary ~= summaryValue
		or deathHandleSummaries[summaryValue :: DeathHandleSummary] ~= deathHandle
	then
		return false, "forged-body-queue-service-death-handle-summary"
	end
	local currentError = appliedDeathHandleCurrentError(capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

-- ClientThink_real resolves the strict integer respawn gate before respawn()
-- reaches CopyToBodyQue. This source-free capability mirrors that order: a
-- Wait returns no gate and cannot open either queue owner or inspect the world.
function BodyQueueService.EvaluateRespawn(
	deathHandleValue: unknown,
	requestValue: unknown
): (AcceptedRespawnGate?, BodyQueueRules.RespawnDecision?, string?)
	local state, stateError = currentQueue()
	if not state then
		return nil, nil, stateError
	end
	if activeTransaction then
		return nil, nil, "body-queue-service-transaction-active"
	end
	if entityLifecycleDrainPending then
		return nil, nil, "body-queue-entity-lifecycle-drain-pending"
	end
	if type(deathHandleValue) ~= "table" then
		return nil, nil, "invalid-body-queue-service-death-handle"
	end
	local deathHandle = deathHandleValue :: DeathHandle
	local deathHandleCapability = deathSnapshots[deathHandle]
	if not deathHandleCapability or appliedDeathHandleCurrentError(deathHandleCapability) ~= nil then
		return nil, nil, "invalid-body-queue-service-death-handle"
	end
	if deathHandleCapability.acceptedRespawnGate ~= nil then
		return nil, nil, "body-queue-service-accepted-respawn-gate-active"
	end
	local request, requestError = makeAcceptedRespawnRequest(requestValue)
	if not request then
		return nil, nil, requestError
	end
	local snapshot = deathHandleCapability.snapshot :: BodyQueueRules.DeadClientSnapshot
	local decision, decisionError = BodyQueueRules.ResolveRespawn(snapshot, request)
	if not decision then
		return nil, nil, decisionError or "body-queue-respawn-evaluation-failed"
	end
	if not decision.canRespawn or decision.kind == "Wait" then
		return nil, decision, "respawn-not-ready"
	end
	local gate: AcceptedRespawnGate = table.freeze({})
	local summary: AcceptedRespawnGateSummary = {
		deathHandleSummary = deathHandleCapability.summary,
		respawnKind = decision.kind,
		nowMilliseconds = request.nowMilliseconds,
		attackPressed = request.attackPressed,
		useHoldablePressed = request.useHoldablePressed,
		forceRespawnSeconds = request.forceRespawnSeconds,
	}
	table.freeze(summary)
	local capability: AcceptedRespawnGateCapability = {
		gate = gate,
		status = "Accepted",
		deathHandle = deathHandle,
		deathHandleCapability = deathHandleCapability,
		request = request,
		decision = decision,
		summary = summary,
	}
	acceptedRespawnGateCapabilities[gate] = capability
	acceptedRespawnGateSummaries[summary] = gate
	deathHandleCapability.acceptedRespawnGate = gate
	return gate, decision, nil
end

function BodyQueueService.InspectAcceptedRespawnGateSummary(gateValue: unknown): AcceptedRespawnGateSummary?
	local capability = select(1, getAcceptedRespawnGateCapability(gateValue))
	if not capability or acceptedRespawnGateCurrentError(gateValue, capability) then
		return nil
	end
	return capability.summary
end

function BodyQueueService.ValidateAcceptedRespawnGateDependency(
	gateValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-service-accepted-respawn-gate-summary"
	end
	local capability, capabilityError = getAcceptedRespawnGateCapability(gateValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or acceptedRespawnGateSummaries[summaryValue :: AcceptedRespawnGateSummary] ~= capability.gate
	then
		return false, "forged-body-queue-service-accepted-respawn-gate-summary"
	end
	local currentError = acceptedRespawnGateCurrentError(gateValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function BodyQueueService.AbortAcceptedRespawnGate(gateValue: unknown): (boolean, string?)
	local capability, capabilityError = getAcceptedRespawnGateCapability(gateValue)
	if not capability then
		return false, capabilityError
	end
	local deathHandleCapability = capability.deathHandleCapability
	if
		capability.status ~= "Accepted"
		or acceptedRespawnGateCapabilities[capability.gate] ~= capability
		or acceptedRespawnGateSummaries[capability.summary] ~= capability.gate
		or deathHandleCapability.acceptedRespawnGate ~= capability.gate
	then
		return false, "stale-body-queue-service-accepted-respawn-gate"
	end
	capability.status = "Aborted"
	deathHandleCapability.acceptedRespawnGate = nil
	acceptedRespawnGateCapabilities[capability.gate] = nil
	acceptedRespawnGateSummaries[capability.summary] = nil
	return true, nil
end

function BodyQueueService.CanApplyPreparedDeathRecord(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local canApplyRules, rulesError = BodyQueueRules.CanApplyPreparedDeathRecord(capability.rulesPrepared)
	if not canApplyRules then
		return false, rulesError or "body-queue-death-record-rules-preflight-failed"
	end
	capability.applyValidated = true
	return true, nil
end

-- Rules owns the duplicate index and snapshot publication; this layer owns the
-- prebuilt opaque handle. Both exact-current checks run before the first owner
-- assignment, and the remaining work has no allocation, callback, or yield.
function BodyQueueService.ApplyPreparedDeathRecord(preparedValue: unknown): DeathHandle
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-service-prepared-death-record")
	assert(capability.applyValidated, "body-queue-service-prepared-death-record-not-validated")
	local currentError = preparedDeathRecordCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-body-queue-service-prepared-death-record")
	local canApplyRules, rulesError = BodyQueueRules.CanApplyPreparedDeathRecord(capability.rulesPrepared)
	assert(canApplyRules, rulesError or "body-queue-death-record-rules-preflight-failed")

	local snapshot = BodyQueueRules.ApplyPreparedDeathRecord(capability.rulesPrepared)
	capability.handleCapability.snapshot = snapshot
	capability.handleCapability.status = "Applied"
	capability.status = "Applied"
	capability.applyValidated = false
	preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] = nil
	preparedDeathRecordSummaries[capability.summary] = nil
	return capability.handle
end

function BodyQueueService.AbortPreparedDeathRecord(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.status ~= "Prepared"
		or capability.handleCapability.status ~= "Prepared"
		or capability.handleCapability.snapshot ~= nil
		or deathSnapshots[capability.handle] ~= capability.handleCapability
	then
		return false, "stale-body-queue-service-prepared-death-record"
	end
	local aborted, abortError = BodyQueueRules.AbortPreparedDeathRecord(capability.rulesPrepared)
	if not aborted then
		return false, abortError or "body-queue-death-record-rules-abort-failed"
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	capability.handleCapability.status = "Aborted"
	deathSnapshots[capability.handle] = nil
	deathHandleSummaries[capability.summary] = nil
	preparedDeathRecordCapabilities[preparedValue :: PreparedDeathRecord] = nil
	preparedDeathRecordSummaries[capability.summary] = nil
	return true, nil
end

-- Several source-ordered player_die transitions can share one frame. The
-- service canonicalizes a dense bounded list, captures each exact live Player
-- lease, and asks BodyQueueRules to prebuild one duplicate-index root revision.
-- No sorting occurs; the returned summary and eventual handle array retain the
-- caller's operation order exactly.
function BodyQueueService.PrepareDeathRecordBatch(requestsValue: unknown): (
	PreparedDeathRecordBatch?,
	PreparedDeathRecordBatchSummary?,
	string?
)
	local state, stateError = currentQueue()
	if not state then
		return nil, nil, stateError
	end
	local operationCount = boundedDenseArrayLength(requestsValue, BodyQueueRules.MaximumDeathRecordBatchSize)
	if not operationCount then
		return nil, nil, "body-queue-service-death-record-batch-not-dense-bounded-array"
	end
	local requests = requestsValue :: { [unknown]: unknown }
	local validatedEntries: {
		{
			player: Player,
			registration: EntitySlotService.Registration,
			matchLineage: unknown,
			deathTimeMilliseconds: unknown,
			lifeSequence: unknown,
		}
	} =
		{}
	local rulesRequests: { { [string]: any } } = {}
	for index = 1, operationCount do
		local requestValue = rawget(requests, index)
		if type(requestValue) ~= "table" then
			return nil, nil, "invalid-body-queue-service-death-record-batch-entry"
		end
		local raw = requestValue :: { [unknown]: unknown }
		if not hasExactRawKeys(raw, DEATH_RECORD_BATCH_REQUEST_KEYS, 4) then
			return nil, nil, "invalid-body-queue-service-death-record-batch-entry"
		end
		local playerValue = rawget(raw, "player")
		if typeof(playerValue) ~= "Instance" or not (playerValue :: Instance):IsA("Player") then
			return nil, nil, "invalid-body-queue-death-player"
		end
		local player = playerValue :: Player
		if player.Parent ~= Players then
			return nil, nil, "stale-body-queue-death-player"
		end
		local registration = EntitySlotService.GetPlayerRegistration(player)
		if not registration then
			return nil, nil, "body-queue-death-player-registration-unavailable"
		end
		local matchLineage = rawget(raw, "matchLineage")
		local deathTimeMilliseconds = rawget(raw, "deathTimeMilliseconds")
		local lifeSequence = rawget(raw, "lifeSequence")
		validatedEntries[index] = {
			player = player,
			registration = registration,
			matchLineage = matchLineage,
			deathTimeMilliseconds = deathTimeMilliseconds,
			lifeSequence = lifeSequence,
		}
		rulesRequests[index] = {
			matchLineage = matchLineage,
			deathTimeMilliseconds = deathTimeMilliseconds,
			playerBodyId = registration.bodyId,
			playerSourceOrder = registration.sourceOrder,
			playerLeaseGeneration = registration.generation,
			playerUserId = player.UserId,
			lifeSequence = lifeSequence,
		}
	end
	local rulesPrepared, prepareError = BodyQueueRules.PrepareDeathRecordBatch(state, rulesRequests)
	if not rulesPrepared then
		return nil, nil, prepareError or "body-queue-death-record-batch-prepare-failed"
	end
	local rulesSummary = BodyQueueRules.InspectPreparedDeathRecordBatchSummary(rulesPrepared)
	if not rulesSummary or rulesSummary.operationCount ~= operationCount then
		BodyQueueRules.AbortPreparedDeathRecordBatch(rulesPrepared)
		return nil, nil, "body-queue-death-record-batch-summary-unavailable"
	end
	for index, validated in validatedEntries do
		local rulesRecordSummary = rulesSummary.records[index]
		if
			not rulesRecordSummary
			or rulesRecordSummary.matchLineage ~= validated.matchLineage
			or rulesRecordSummary.deathTimeMilliseconds ~= validated.deathTimeMilliseconds
			or rulesRecordSummary.player.bodyId ~= validated.registration.bodyId
			or rulesRecordSummary.player.sourceOrder ~= validated.registration.sourceOrder
			or rulesRecordSummary.player.leaseGeneration ~= validated.registration.generation
			or rulesRecordSummary.player.playerUserId ~= validated.player.UserId
			or rulesRecordSummary.player.lifeSequence ~= validated.lifeSequence
		then
			BodyQueueRules.AbortPreparedDeathRecordBatch(rulesPrepared)
			return nil, nil, "body-queue-death-record-batch-summary-diverged"
		end
	end
	local entries: { PreparedDeathRecordBatchEntry } = {}
	local handles: { DeathHandle } = {}
	local recordSummaries: { PreparedDeathRecordSummary } = {}
	for index, validated in validatedEntries do
		local rulesRecordSummary = rulesSummary.records[index]
		local handle: DeathHandle = table.freeze({})
		local recordSummary: PreparedDeathRecordSummary = {
			queueLineage = rulesRecordSummary.queueLineage,
			queueRevision = rulesRecordSummary.queueRevision,
			deathIndexRevision = rulesRecordSummary.deathIndexRevision,
			matchLineage = rulesRecordSummary.matchLineage,
			deathTimeMilliseconds = rulesRecordSummary.deathTimeMilliseconds,
			respawnTimeMilliseconds = rulesRecordSummary.respawnTimeMilliseconds,
			playerBodyId = rulesRecordSummary.player.bodyId,
			playerSourceOrder = rulesRecordSummary.player.sourceOrder,
			playerLeaseGeneration = rulesRecordSummary.player.leaseGeneration,
			playerUserId = rulesRecordSummary.player.playerUserId,
			lifeSequence = rulesRecordSummary.player.lifeSequence,
		}
		table.freeze(recordSummary)
		local handleCapability: DeathHandleCapability = {
			status = "Prepared",
			snapshot = nil,
			player = validated.player,
			registration = validated.registration,
			handle = handle,
			summary = recordSummary,
			acceptedRespawnGate = nil,
		}
		local entry: PreparedDeathRecordBatchEntry = {
			player = validated.player,
			registration = validated.registration,
			rulesSummary = rulesRecordSummary,
			handle = handle,
			handleCapability = handleCapability,
			summary = recordSummary,
		}
		table.freeze(entry)
		entries[index] = entry
		handles[index] = handle
		recordSummaries[index] = recordSummary
	end
	table.freeze(entries)
	table.freeze(handles)
	table.freeze(recordSummaries)
	local summary: PreparedDeathRecordBatchSummary = {
		queueLineage = rulesSummary.queueLineage,
		queueRevision = rulesSummary.queueRevision,
		deathIndexRevision = rulesSummary.deathIndexRevision,
		matchLineage = rulesSummary.matchLineage,
		operationCount = operationCount,
		records = recordSummaries,
	}
	table.freeze(summary)
	local prepared: PreparedDeathRecordBatch = table.freeze({})
	local capability: PreparedDeathRecordBatchCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		rulesPrepared = rulesPrepared,
		rulesSummary = rulesSummary,
		entries = entries,
		handles = handles,
		summary = summary,
	}
	for _, entry in entries do
		deathSnapshots[entry.handle] = entry.handleCapability
		deathHandleSummaries[entry.summary] = entry.handle
	end
	preparedDeathRecordBatchCapabilities[prepared] = capability
	preparedDeathRecordBatchSummaries[summary] = prepared
	return prepared, summary, nil
end

function BodyQueueService.InspectPreparedDeathRecordBatchSummary(
	preparedValue: unknown
): PreparedDeathRecordBatchSummary?
	local capability = select(1, getPreparedDeathRecordBatchCapability(preparedValue))
	if not capability or preparedDeathRecordBatchCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

-- The handles remain unusable while Prepared, but a future multi-owner death
-- coordinator must know the exact prebuilt identities before BodyQueue becomes
-- its first authority swap. Apply returns this same frozen array.
function BodyQueueService.InspectPreparedDeathRecordBatchHandles(preparedValue: unknown): { DeathHandle }?
	local capability = select(1, getPreparedDeathRecordBatchCapability(preparedValue))
	if not capability or preparedDeathRecordBatchCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.handles
end

function BodyQueueService.ValidatePreparedDeathRecordBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-body-queue-service-prepared-death-record-batch-summary"
	end
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or preparedDeathRecordBatchSummaries[summaryValue :: PreparedDeathRecordBatchSummary] ~= preparedValue
	then
		return false, "forged-body-queue-service-prepared-death-record-batch-summary"
	end
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function BodyQueueService.CanApplyPreparedDeathRecordBatch(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local canApplyRules, rulesError = BodyQueueRules.CanApplyPreparedDeathRecordBatch(capability.rulesPrepared)
	if not canApplyRules then
		return false, rulesError or "body-queue-death-record-batch-rules-preflight-failed"
	end
	capability.applyValidated = true
	return true, nil
end

-- The exact frozen handle array and every nested summary/capability are built
-- in Prepare. Apply repeats current/dependency checks, publishes the Rules
-- snapshots, updates handle statuses by assignment, and returns that same array.
function BodyQueueService.ApplyPreparedDeathRecordBatch(preparedValue: unknown): { DeathHandle }
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-service-prepared-death-record-batch")
	assert(capability.applyValidated, "body-queue-service-prepared-death-record-batch-not-validated")
	local currentError = preparedDeathRecordBatchCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-body-queue-service-prepared-death-record-batch")
	local canApplyRules, rulesError = BodyQueueRules.CanApplyPreparedDeathRecordBatch(capability.rulesPrepared)
	assert(canApplyRules, rulesError or "body-queue-death-record-batch-rules-preflight-failed")

	local snapshots = BodyQueueRules.ApplyPreparedDeathRecordBatch(capability.rulesPrepared)
	for index, entry in capability.entries do
		entry.handleCapability.snapshot = snapshots[index]
		entry.handleCapability.status = "Applied"
	end
	capability.status = "Applied"
	capability.applyValidated = false
	preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] = nil
	preparedDeathRecordBatchSummaries[capability.summary] = nil
	return capability.handles
end

function BodyQueueService.AbortPreparedDeathRecordBatch(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedDeathRecordBatchCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if capability.status ~= "Prepared" then
		return false, "stale-body-queue-service-prepared-death-record-batch"
	end
	for _, entry in capability.entries do
		if
			entry.handleCapability.status ~= "Prepared"
			or entry.handleCapability.snapshot ~= nil
			or deathSnapshots[entry.handle] ~= entry.handleCapability
			or deathHandleSummaries[entry.summary] ~= entry.handle
		then
			return false, "stale-body-queue-service-prepared-death-record-batch"
		end
	end
	local aborted, abortError = BodyQueueRules.AbortPreparedDeathRecordBatch(capability.rulesPrepared)
	if not aborted then
		return false, abortError or "body-queue-death-record-batch-rules-abort-failed"
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	for _, entry in capability.entries do
		entry.handleCapability.status = "Aborted"
		deathSnapshots[entry.handle] = nil
		deathHandleSummaries[entry.summary] = nil
	end
	preparedDeathRecordBatchCapabilities[preparedValue :: PreparedDeathRecordBatch] = nil
	preparedDeathRecordBatchSummaries[capability.summary] = nil
	return true, nil
end

-- Compatibility seam for isolated verification. It now traverses the same
-- prepared ticket and cannot bypass duplicate reservation or exact preflight.
function BodyQueueService.RecordCommittedDeath(
	playerValue: unknown,
	matchLineageValue: unknown,
	deathTimeMillisecondsValue: unknown,
	lifeSequenceValue: unknown
): (DeathHandle?, string?)
	local prepared, _, prepareError = BodyQueueService.PrepareDeathRecord(
		playerValue,
		matchLineageValue,
		deathTimeMillisecondsValue,
		lifeSequenceValue
	)
	if not prepared then
		return nil, prepareError
	end
	local canApply, canApplyError = BodyQueueService.CanApplyPreparedDeathRecord(prepared)
	if not canApply then
		BodyQueueService.AbortPreparedDeathRecord(prepared)
		return nil, canApplyError
	end
	return BodyQueueService.ApplyPreparedDeathRecord(prepared), nil
end

-- Only an exact accepted ClientThink_real gate may reach StageCopy. The
-- CONTENTS_NODROP/body source request is separate, so a Wait cannot make the
-- caller sample the source or open BodyQueue/EntitySlot through this API.
function BodyQueueService.StageRespawn(
	acceptedGateValue: unknown,
	copyRequestValue: unknown
): (TransactionToken?, StageDiagnostic?, string?)
	local state, stateError = currentQueue()
	if not state then
		return nil, nil, stateError
	end
	if activeTransaction then
		return nil, nil, "body-queue-service-transaction-active"
	end
	if entityLifecycleDrainPending then
		return nil, nil, "body-queue-entity-lifecycle-drain-pending"
	end
	local gateCapability, gateCapabilityError = getAcceptedRespawnGateCapability(acceptedGateValue)
	if not gateCapability then
		return nil, nil, gateCapabilityError
	end
	local gateCurrentError = acceptedRespawnGateCurrentError(acceptedGateValue, gateCapability)
	if gateCurrentError then
		return nil, nil, gateCurrentError
	end
	local request, requestError = makeBodyCopyStageRequest(gateCapability.request, copyRequestValue)
	if not request then
		return nil, nil, requestError
	end
	gateCurrentError = acceptedRespawnGateCurrentError(acceptedGateValue, gateCapability)
	if gateCurrentError then
		return nil, nil, gateCurrentError
	end
	local deathHandle = gateCapability.deathHandle
	local deathHandleCapability = gateCapability.deathHandleCapability
	local deathSnapshot = deathHandleCapability.snapshot :: BodyQueueRules.DeadClientSnapshot
	local bodyOpen, bodyBeginError = BodyQueueRules.Begin(state)
	if not bodyOpen then
		return nil, nil, bodyBeginError or "body-queue-rules-begin-failed"
	end
	local bodyStaged, preparedCopy, stageError = BodyQueueRules.StageCopy(bodyOpen, deathSnapshot, request)
	if not bodyStaged or not preparedCopy then
		local aborted, abortError = abortNested(bodyOpen, nil, nil)
		if not aborted then
			return nil, nil, abortError
		end
		return nil, nil, stageError or "body-queue-copy-stage-failed"
	end

	local entityToken: EntitySlotService.TransactionToken? = nil
	local entityBaseSnapshot: EntitySlotService.DebugSnapshot? = nil
	if preparedCopy.kind == "BodyCopy" then
		entityBaseSnapshot = EntitySlotService.GetDebugSnapshot()
		if entityBaseSnapshot.transactionOpen then
			local aborted, abortError = abortNested(bodyStaged, nil, nil)
			if not aborted then
				return nil, nil, abortError
			end
			return nil, nil, "body-queue-entity-slot-transaction-active"
		end
		local openedEntityToken, entityBeginError = EntitySlotService.Begin(preparedCopy.decision.nowMilliseconds)
		if not openedEntityToken then
			local aborted, abortError = abortNested(bodyStaged, nil, nil)
			if not aborted then
				return nil, nil, abortError
			end
			return nil, nil, entityBeginError or "body-queue-entity-slot-begin-failed"
		end
		entityToken = openedEntityToken
		local registration, registrationError = EntitySlotService.NextBodyQueue(entityToken, entityCursorOwner)
		if not registration or not descriptorMatches(preparedCopy, registration) then
			local aborted, abortError = abortNested(bodyStaged, entityToken, entityBaseSnapshot)
			if not aborted then
				return nil, nil, abortError
			end
			return nil, nil, registrationError or "body-queue-registration-descriptor-mismatch"
		end
	end

	local bodySealed, sealError = BodyQueueRules.Seal(bodyStaged, preparedCopy)
	if not bodySealed then
		local aborted, abortError = abortNested(bodyStaged, entityToken, entityBaseSnapshot)
		if not aborted then
			return nil, nil, abortError
		end
		return nil, nil, sealError or "body-queue-rules-seal-failed"
	end
	local token: TransactionToken = table.freeze({})
	local stageDiagnostic = makeStageDiagnostic(preparedCopy)
	activeTransaction = {
		token = token,
		status = "Sealed",
		kind = preparedCopy.kind,
		deathHandle = deathHandle,
		deathHandleCapability = deathHandleCapability,
		bodyTransaction = bodySealed,
		preparedCopy = preparedCopy,
		stageDiagnostic = stageDiagnostic,
		applyDiagnostic = nil,
		entityToken = entityToken,
		entityBaseSnapshot = entityBaseSnapshot,
		entityPrepared = nil,
		bodyPrepared = nil,
		prepared = nil,
	}
	gateCapability.status = "Consumed"
	deathHandleCapability.acceptedRespawnGate = nil
	acceptedRespawnGateCapabilities[gateCapability.gate] = nil
	acceptedRespawnGateSummaries[gateCapability.summary] = nil
	return token, stageDiagnostic, nil
end

function BodyQueueService.Prepare(tokenValue: unknown): (PreparedRespawn?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Sealed")
	if not transaction then
		return nil, transactionError
	end
	local entityPrepared: EntitySlotService.PreparedCommit? = nil
	if transaction.entityToken then
		local prepared, entityPrepareError = EntitySlotService.Prepare(transaction.entityToken)
		if not prepared then
			local aborted, abortError = BodyQueueService.Abort(tokenValue)
			if not aborted then
				return nil, abortError
			end
			return nil, entityPrepareError or "body-queue-entity-slot-prepare-failed"
		end
		entityPrepared = prepared
	end
	local bodyPrepared, bodyPrepareError = BodyQueueRules.Prepare(transaction.bodyTransaction)
	if not bodyPrepared then
		local aborted, abortError = BodyQueueService.Abort(tokenValue)
		if not aborted then
			return nil, abortError
		end
		return nil, bodyPrepareError or "body-queue-rules-prepare-failed"
	end
	local applyDiagnostic = makeApplyDiagnostic(transaction.preparedCopy)
	local prepared: PreparedRespawn = table.freeze({})
	preparedCapabilities[prepared] = {
		transaction = transaction,
		status = "Prepared",
		applyValidated = false,
	}
	transaction.entityPrepared = entityPrepared
	transaction.bodyPrepared = bodyPrepared
	transaction.applyDiagnostic = applyDiagnostic
	transaction.prepared = prepared
	transaction.status = "Prepared"
	return prepared, nil
end

function BodyQueueService.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local transaction = capability.transaction
	if deathSnapshots[transaction.deathHandle] ~= transaction.deathHandleCapability then
		return false, "stale-body-queue-service-death-handle"
	end
	local deathHandleError = appliedDeathHandleCurrentError(transaction.deathHandleCapability)
	if deathHandleError then
		return false, "stale-body-queue-service-death-handle"
	end
	if transaction.entityPrepared then
		local canApplyEntity, entityError = EntitySlotService.CanApplyPrepared(transaction.entityPrepared)
		if not canApplyEntity then
			return false, entityError or "body-queue-entity-slot-preflight-failed"
		end
	end
	local canApplyBody, bodyError = BodyQueueRules.CanApplyPrepared(transaction.bodyPrepared)
	if not canApplyBody then
		return false, bodyError or "body-queue-rules-preflight-failed"
	end
	capability.applyValidated = true
	return true, nil
end

-- The caller may yield between CanApplyPrepared and ApplyPrepared. Repeat both
-- nested allocation-free checks twice before the first root swap so stale sink
-- or allocator lineage fails before EntitySlot can apply. No callback/yield is
-- permitted between the fixed EntitySlot -> BodyQueue assignments below.
function BodyQueueService.ApplyPrepared(preparedValue: unknown): (EntitySlotService.CommitReceipt?, ApplyDiagnostic)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	assert(capability, capabilityError or "invalid-body-queue-service-prepared-respawn")
	assert(capability.applyValidated, "body-queue-service-prepared-respawn-not-validated")
	local transaction = capability.transaction
	local bodyPrepared = transaction.bodyPrepared
	assert(bodyPrepared, "body-queue prepared owner disappeared")
	local applyDiagnostic = transaction.applyDiagnostic
	assert(applyDiagnostic, "body-queue apply diagnostic disappeared")
	for _ = 1, 2 do
		local deathHandleError = appliedDeathHandleCurrentError(transaction.deathHandleCapability)
		assert(
			deathSnapshots[transaction.deathHandle] == transaction.deathHandleCapability and deathHandleError == nil,
			deathHandleError or "stale-body-queue-service-death-handle"
		)
		if transaction.entityPrepared then
			local canApplyEntity, entityError = EntitySlotService.CanApplyPrepared(transaction.entityPrepared)
			assert(canApplyEntity, entityError or "body-queue-entity-slot-preflight-failed")
		end
		local canApplyBody, bodyError = BodyQueueRules.CanApplyPrepared(bodyPrepared)
		assert(canApplyBody, bodyError or "body-queue-rules-preflight-failed")
	end

	local entityReceipt: EntitySlotService.CommitReceipt? = nil
	if transaction.entityPrepared then
		entityReceipt = EntitySlotService.ApplyPrepared(transaction.entityPrepared)
	end
	local nextQueue = BodyQueueRules.ApplyPrepared(bodyPrepared)
	queueState = nextQueue
	entityLifecycleDrainPending = entityReceipt ~= nil
	transaction.deathHandleCapability.status = "Consumed"
	deathSnapshots[transaction.deathHandle] = nil
	deathHandleSummaries[transaction.deathHandleCapability.summary] = nil
	transaction.status = "Applied"
	transaction.prepared = nil
	transaction.applyDiagnostic = nil
	activeTransaction = nil
	capability.status = "Applied"
	capability.applyValidated = false
	preparedCapabilities[preparedValue :: PreparedRespawn] = nil
	return entityReceipt, applyDiagnostic
end

function BodyQueueService.Abort(tokenValue: unknown): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue, nil)
	if not transaction then
		return false, transactionError
	end
	if transaction.status ~= "Sealed" and transaction.status ~= "Prepared" then
		return false, "invalid-body-queue-service-transaction-state"
	end
	local aborted, abortError =
		abortNested(transaction.bodyTransaction, transaction.entityToken, transaction.entityBaseSnapshot)
	if not aborted then
		return false, abortError
	end
	local prepared = transaction.prepared
	if prepared then
		local capability = preparedCapabilities[prepared]
		if capability then
			capability.status = "Aborted"
			capability.applyValidated = false
		end
		preparedCapabilities[prepared] = nil
	end
	transaction.status = "Aborted"
	transaction.prepared = nil
	transaction.applyDiagnostic = nil
	activeTransaction = nil
	return true, nil
end

-- EntitySlot deliberately leaves queued PlayerRemoving work outside its
-- assignment-only apply. Exactly one normal paired commit arms this lifecycle
-- phase. No-drop has no EntitySlot participant and therefore cannot drain it.
function BodyQueueService.DrainEntitySlotLifecycleAfterCommit(): (boolean, string?)
	if activeTransaction then
		return false, "body-queue-service-transaction-active"
	end
	if not entityLifecycleDrainPending then
		return false, "body-queue-entity-lifecycle-drain-not-pending"
	end
	local drained, drainError = EntitySlotService.DrainPendingPlayerReleases()
	if not drained then
		return false, drainError or "body-queue-entity-lifecycle-drain-failed"
	end
	entityLifecycleDrainPending = false
	return true, nil
end

local function makeSinkDiagnostic(sink: BodyQueueRules.SinkState): SinkDiagnostic
	local diagnostic: SinkDiagnostic = {
		queueIndex = sink.queueIndex,
		occupantGeneration = sink.occupantGeneration,
		collisionPosition = sink.collisionBody.position,
		trajectoryKind = sink.trajectory.kind,
		trajectoryBasePosition = sink.trajectory.basePosition,
		trajectoryDelta = sink.trajectory.delta,
		timestampMilliseconds = sink.timestampMilliseconds,
		nextThinkTimeMilliseconds = sink.nextThinkTimeMilliseconds,
		evaluatedThroughMilliseconds = sink.evaluatedThroughMilliseconds,
		linked = sink.linked,
		physicsObject = sink.physicsObject,
		sinkStepCount = sink.sinkStepCount,
		visible = sink.presentation.visible,
	}
	table.freeze(diagnostic)
	return diagnostic
end

function BodyQueueService.HandleEntityFrame(
	frameValue: unknown,
	summaryValue: unknown,
	registration: EntitySlotService.Registration
)
	assert(started and activeTransaction == nil, "BodyQueue entity frame owner is unavailable")
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	assert(
		openFrame ~= nil
			and frameValue == openFrame
			and summary ~= nil
			and summary == summaryValue
			and AuthoritativeFrameService.ValidateFrameDependency(frameValue, summary),
		"BodyQueue entity frame dependency is stale"
	)
	local queueIndex = registration.bodyQueueIndex
	assert(
		registration.kind == "BodyQueue"
			and type(queueIndex) == "number"
			and EntitySlotService.GetBodyQueueRegistration(queueIndex) == registration,
		"BodyQueue entity frame registration is stale"
	)
	if summary.currentTimeMilliseconds > lastEntityFrameLevelTimeMilliseconds then
		lastEntityFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
		lastEntityFrameSourceOrder = -1
	else
		assert(
			summary.currentTimeMilliseconds == lastEntityFrameLevelTimeMilliseconds,
			"BodyQueue entity frame time regressed"
		)
	end
	assert(registration.sourceOrder > lastEntityFrameSourceOrder, "BodyQueue entities did not run in source order")
	lastEntityFrameSourceOrder = registration.sourceOrder
	local state = assert(queueState, "BodyQueue state is unavailable")
	local sink = BodyQueueRules.GetCurrentSink(state, queueIndex)
	if not sink then
		return
	end
	local nextSink: BodyQueueRules.SinkState?
	local advanceError: string?
	if sink.physicsObject and sink.trajectory.kind == "Gravity" then
		local adapter = assert(physicsAdapter, "BodyQueue physics adapter is unavailable")
		local evaluation, evaluationError = BodyQueueRules.EvaluateSinkTrajectory(sink, summary.currentTimeMilliseconds)
		assert(evaluation, evaluationError or "BodyQueue trajectory evaluation failed")
		local trace =
			adapter.Trace(frameValue, sink.collisionBody.position, evaluation.position - sink.collisionBody.position)
		local physicsTrace: BodyQueueRules.PhysicsTrace = table.freeze({
			fraction = trace.fraction,
			endPosition = trace.position,
			normal = if trace.hit or trace.startSolid then trace.normal else nil,
			moverId = trace.moverId,
			startSolid = trace.startSolid,
			noDrop = WorldPointContents.IsNoDrop(adapter.PointContents(trace.position)),
		})
		nextSink, advanceError = BodyQueueRules.RunSinkPhysics(sink, summary.currentTimeMilliseconds, physicsTrace)
	else
		nextSink, advanceError = BodyQueueRules.AdvanceSink(sink, summary.currentTimeMilliseconds)
	end
	assert(nextSink, advanceError or "BodyQueue sink frame failed")
	local adapter = assert(presentationAdapter, "BodyQueue presentation adapter is unavailable")
	adapter.StageSink(makeSinkDiagnostic(nextSink))
end

function BodyQueueService.CollectMoverBodies(): ({ MoverPushRules.Body }, { [string]: number })
	assert(started and activeTransaction == nil, "BodyQueue mover collection is unavailable")
	assert(activePreparedMoverUpdate == nil, "BodyQueue mover collection crossed prepare")
	local state = assert(queueState, "BodyQueue state is unavailable")
	local bodies: { MoverPushRules.Body } = {}
	local queueIndexByBodyId: { [string]: number } = {}
	for queueIndex = 1, BodyQueueRules.BodyQueueSize do
		local sink = BodyQueueRules.GetCurrentSink(state, queueIndex)
		if sink and sink.linked and sink.physicsObject then
			local body = sink.collisionBody
			assert(queueIndexByBodyId[body.id] == nil, "BodyQueue mover body ID collided")
			queueIndexByBodyId[body.id] = queueIndex
			table.insert(bodies, body)
		end
	end
	table.sort(bodies, function(left, right)
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(bodies)
	table.freeze(queueIndexByBodyId)
	return bodies, queueIndexByBodyId
end

local function preparedMoverUpdateBlocksAuthority(): boolean
	local prepared = activePreparedMoverUpdate
	if not prepared then
		return false
	end
	for _, capability in moverReceiptCapabilities do
		if capability.prepared == prepared then
			-- G_RunFrame applies the mover/body update before later missile entities.
			-- Only an unapplied Prepare blocks reads/writes; Applied retains merely the
			-- post-close presentation receipt and exposes the new collision authority.
			return capability.status ~= "Applied"
		end
	end
	return true
end

function BodyQueueService.CollectCombatTargets(): { CombatTarget }
	assert(started and activeTransaction == nil, "BodyQueue combat collection is unavailable")
	assert(not preparedMoverUpdateBlocksAuthority(), "BodyQueue combat collection crossed mover prepare")
	local state = assert(queueState, "BodyQueue state is unavailable")
	local targets: { CombatTarget } = {}
	for queueIndex = 1, BodyQueueRules.BodyQueueSize do
		local sink = BodyQueueRules.GetCurrentSink(state, queueIndex)
		local slot = state.slots[queueIndex]
		if sink and sink.linked then
			local target: CombatTarget = {
				queueIndex = queueIndex,
				occupantGeneration = sink.occupantGeneration,
				body = sink.collisionBody,
				retainedHealth = slot.retainedHealth,
				takedamage = slot.takedamage,
			}
			table.freeze(target)
			table.insert(targets, target)
		end
	end
	table.sort(targets, function(left, right)
		return left.body.sourceOrder < right.body.sourceOrder
	end)
	table.freeze(targets)
	return targets
end

function BodyQueueService.DamageBody(
	queueIndex: number,
	occupantGeneration: number,
	damage: number
): (BodyQueueRules.DamageResult?, string?)
	assert(started and activeTransaction == nil, "BodyQueue damage owner is unavailable")
	assert(not preparedMoverUpdateBlocksAuthority(), "BodyQueue damage crossed mover prepare")
	assert(AuthoritativeFrameService.GetOpenFrame() ~= nil, "BodyQueue damage occurred outside the authoritative frame")
	local nextQueue, nextSink, result, damageError = BodyQueueRules.DamageSink(
		assert(queueState, "BodyQueue state is unavailable"),
		queueIndex,
		occupantGeneration,
		damage,
		true
	)
	if not nextQueue or not nextSink or not result then
		return nil, damageError
	end
	queueState = nextQueue
	if result.applied then
		local adapter = assert(presentationAdapter, "BodyQueue presentation adapter is unavailable")
		adapter.StageSink(makeSinkDiagnostic(nextSink))
	end
	return result, nil
end

local function bodyQueueRemoveMutation(bodyId: string): MoverPushRules.BodyMutation
	local _bodies, queueIndexByBodyId = BodyQueueService.CollectMoverBodies()
	assert(queueIndexByBodyId[bodyId] ~= nil, "BodyQueue mover body is stale")
	return table.freeze({
		kind = "Remove",
		bodyId = bodyId,
	}) :: any
end

function BodyQueueService.PrepareMoverUpdate(finalBodiesValue: unknown): (PreparedMoverUpdate?, string?)
	if activePreparedMoverUpdate ~= nil or type(finalBodiesValue) ~= "table" then
		return nil, "body-queue-mover-owner-unavailable"
	end
	local finalBodiesById: { [string]: unknown } = {}
	for _, body in finalBodiesValue :: { any } do
		if type(body) == "table" and type(body.id) == "string" then
			finalBodiesById[body.id] = body
		end
	end
	local state = assert(queueState, "BodyQueue state is unavailable")
	local children: { { prepared: BodyQueueRules.PreparedSinkMoverUpdate, aborted: boolean } } = {}
	for queueIndex = 1, BodyQueueRules.BodyQueueSize do
		local sink = BodyQueueRules.GetCurrentSink(state, queueIndex)
		if sink and sink.linked and sink.physicsObject then
			local child, childError =
				BodyQueueRules.PrepareSinkMoverUpdate(sink, finalBodiesById[sink.collisionBody.id])
			if not child then
				for index = #children, 1, -1 do
					BodyQueueRules.AbortPreparedSinkMoverUpdate(children[index].prepared)
				end
				return nil, childError
			end
			table.insert(children, { prepared = child, aborted = false })
		end
	end
	table.freeze(children)
	local prepared: PreparedMoverUpdate = table.freeze({})
	local receipt: MoverUpdateReceipt = table.freeze({})
	local capability: MoverPreparedCapability = {
		status = "Prepared",
		children = children,
		prepared = prepared,
		receipt = receipt,
	}
	moverPreparedCapabilities[prepared] = capability
	moverReceiptCapabilities[receipt] = capability
	activePreparedMoverUpdate = prepared
	return prepared, nil
end

function BodyQueueService.CanApplyPreparedMoverUpdate(preparedValue: unknown): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then moverPreparedCapabilities[preparedValue :: PreparedMoverUpdate]
		else nil
	if not capability or capability.status ~= "Prepared" or activePreparedMoverUpdate ~= preparedValue then
		return false, "stale-prepared-body-queue-mover-update"
	end
	for _, child in capability.children do
		local canApply, childError = BodyQueueRules.CanApplyPreparedSinkMoverUpdate(child.prepared)
		if not canApply then
			return false, childError
		end
	end
	return true, nil
end

function BodyQueueService.ApplyPreparedMoverUpdate(preparedValue: unknown): MoverUpdateReceipt
	local prepared = preparedValue :: PreparedMoverUpdate
	local capability = assert(moverPreparedCapabilities[prepared], "invalid prepared BodyQueue mover update")
	assert(
		capability.status == "Prepared" and activePreparedMoverUpdate == prepared,
		"stale prepared BodyQueue mover update"
	)
	for _, child in capability.children do
		BodyQueueRules.ApplyPreparedSinkMoverUpdate(child.prepared)
	end
	capability.status = "Applied"
	moverPreparedCapabilities[prepared] = nil
	return capability.receipt
end

function BodyQueueService.FlushPreparedMoverUpdate(receiptValue: unknown): boolean
	local capability = if type(receiptValue) == "table"
		then moverReceiptCapabilities[receiptValue :: MoverUpdateReceipt]
		else nil
	if not capability or capability.status ~= "Applied" then
		return false
	end
	capability.status = "Flushed"
	moverReceiptCapabilities[capability.receipt] = nil
	activePreparedMoverUpdate = nil
	return true
end

function BodyQueueService.AbortPreparedMoverUpdate(preparedValue: unknown): boolean
	local prepared = if type(preparedValue) == "table" then preparedValue :: PreparedMoverUpdate else nil
	local capability = if prepared then moverPreparedCapabilities[prepared] else nil
	if not capability or capability.status ~= "Prepared" or activePreparedMoverUpdate ~= prepared then
		return false
	end
	for index = #capability.children, 1, -1 do
		local child = capability.children[index]
		if not child.aborted then
			if not BodyQueueRules.AbortPreparedSinkMoverUpdate(child.prepared) then
				return false
			end
			child.aborted = true
		end
	end
	capability.status = "Aborted"
	moverPreparedCapabilities[prepared :: PreparedMoverUpdate] = nil
	moverReceiptCapabilities[capability.receipt] = nil
	activePreparedMoverUpdate = nil
	return true
end

local moverAdapter: MoverAdapter = table.freeze({
	Collect = BodyQueueService.CollectMoverBodies,
	ResolveSine = bodyQueueRemoveMutation,
	ResolveBlockedDoor = bodyQueueRemoveMutation,
	Prepare = BodyQueueService.PrepareMoverUpdate,
	CanApply = BodyQueueService.CanApplyPreparedMoverUpdate,
	Apply = BodyQueueService.ApplyPreparedMoverUpdate,
	Flush = BodyQueueService.FlushPreparedMoverUpdate,
	Abort = BodyQueueService.AbortPreparedMoverUpdate,
})

function BodyQueueService.GetMoverAdapter(): MoverAdapter
	return moverAdapter
end

function BodyQueueService.SetPhysicsAdapter(adapterValue: PhysicsAdapter)
	assert(started, "BodyQueueService must start before physics adapter installation")
	assert(physicsAdapter == nil, "BodyQueue physics adapter is already configured")
	assert(
		type(adapterValue) == "table"
			and table.isfrozen(adapterValue)
			and type(adapterValue.Trace) == "function"
			and type(adapterValue.PointContents) == "function",
		"BodyQueue physics adapter is invalid"
	)
	physicsAdapter = adapterValue
end

function BodyQueueService.SetPresentationAdapter(adapterValue: PresentationAdapter)
	assert(started, "BodyQueueService must start before presentation adapter installation")
	assert(presentationAdapter == nil, "BodyQueue presentation adapter is already configured")
	assert(
		type(adapterValue) == "table" and table.isfrozen(adapterValue) and type(adapterValue.StageSink) == "function",
		"BodyQueue presentation adapter is invalid"
	)
	presentationAdapter = adapterValue
end

function BodyQueueService.GetSinkDiagnostic(queueIndexValue: unknown): (SinkDiagnostic?, string?)
	local state, stateError = currentQueue()
	if not state then
		return nil, stateError
	end
	local sink, sinkError = BodyQueueRules.GetCurrentSink(state, queueIndexValue)
	if not sink then
		return nil, sinkError
	end
	return makeSinkDiagnostic(sink), nil
end

function BodyQueueService.AdvanceSink(
	queueIndexValue: unknown,
	nowMillisecondsValue: unknown
): (SinkDiagnostic?, string?)
	local state, stateError = currentQueue()
	if not state then
		return nil, stateError
	end
	local sink, sinkError = BodyQueueRules.GetCurrentSink(state, queueIndexValue)
	if not sink then
		return nil, sinkError
	end
	local nextSink, advanceError = BodyQueueRules.AdvanceSink(sink, nowMillisecondsValue)
	if not nextSink then
		return nil, advanceError
	end
	return makeSinkDiagnostic(nextSink), nil
end

function BodyQueueService.GetDebugSnapshot(): DebugSnapshot
	local state = queueState
	local entitySnapshot = EntitySlotService.GetDebugSnapshot()
	local occupied = 0
	if state then
		for _, slot in state.slots do
			if slot.hasOccupant then
				occupied += 1
			end
		end
	end
	local transaction = activeTransaction
	local preparedCapability = if transaction and transaction.prepared
		then preparedCapabilities[transaction.prepared]
		else nil
	local snapshot: DebugSnapshot = {
		started = started,
		revision = if state then state.revision else 0,
		nextBodyQueueIndex = if state then state.nextQueueIndex else 0,
		entityNextBodyQueueIndex = entitySnapshot.nextBodyQueueIndex,
		cursorsSynchronized = state ~= nil and state.nextQueueIndex == entitySnapshot.nextBodyQueueIndex,
		occupiedSlotCount = occupied,
		transactionActive = transaction ~= nil,
		transactionStatus = if transaction then transaction.status else nil,
		transactionKind = if transaction then transaction.kind else nil,
		transactionApplyValidated = if preparedCapability then preparedCapability.applyValidated else false,
		entityLifecycleDrainPending = entityLifecycleDrainPending,
	}
	table.freeze(snapshot)
	return snapshot
end

function BodyQueueService.IsStarted(): boolean
	return started
end

return table.freeze(BodyQueueService)
