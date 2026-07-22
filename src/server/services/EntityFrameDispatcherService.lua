--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only source-ordered entity dispatcher translated from Quake III
Arena:
  code/game/g_main.c (G_RunFrame)
  code/game/g_utils.c (G_Spawn, G_FreeEntity)

G_RunFrame rereads level.num_entities for every numeric entity slot. A
G_Spawn-equivalent committed by an earlier entity can therefore extend the
same pass, while a freed or inactive slot is skipped at the time its number is
reached. the Roblox Luau port dispatches only exact committed EntitySlot registrations;
transaction-local allocations never enter this view.

Typed one-time handlers, opaque generation-bound dynamic bindings, immutable
linear traversal cursors, and terminal fault quarantine are Roblox authority
adaptations. ServerMain runs the claimed DynamicTail after retained movers.

The separately claimed DynamicTail mode lets an outer scheduler retain the
client, body-queue, and original-map prefix while this owner runs only the
G_RunFrame suffix. Claim captures the exact installed contiguous map prefix;
each suffix step rereads the live upper bound so forward G_Spawn growth remains
eligible in the same frame. Full and DynamicTail execution modes never mix.

Prepared dynamic batches bind their exact Retained/Released outcomes to one
still-current EntitySlot prepared commit. Every next root, binding capability,
mutation, summary, and receipt is allocated before either owner applies. Both
owners are preflighted twice. Dispatcher Apply consumes the exact private
applied EntitySlot receipt before its assignment-only root swap, then arms a
separate applied Dispatcher receipt for the next prepared owner. A successor
batch, direct binding mutation, or terminal fault permanently retires that
adjacency witness.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "EntityFrameDispatcherService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local EntityFrameTraversalRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntityFrameTraversalRules"))
local EntitySpawnPlanRules =
	require(sharedRoot:WaitForChild("maps"):WaitForChild("EntitySpawnPlanRules"))

local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntitySlotService = require(script.Parent.EntitySlotService)

local EntityFrameDispatcherService = {}

export type DynamicBinding = {}
export type DynamicKind = string
export type PreparedDynamicBatch = {}
export type DynamicBatchReceipt = {}
export type DynamicTailOwner = {}
export type ExecutionMode = "Unclaimed" | "Full" | "DynamicTail"
export type FaultPhase = "Full" | "PreMoverWorld" | "DynamicTail"
export type FaultCheckpoint = "Traversal" | "Handler" | "Postconditions"

export type ClientHandler = (
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	player: Player,
	registration: EntitySlotService.Registration
) -> ()

export type BodyQueueHandler = (
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration
) -> ()

export type MapHandler = (
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	mapRegistration: EntitySlotService.MapRegistration
) -> ()

export type DynamicHandler = (
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration,
	binding: DynamicBinding,
	declaredKind: DynamicKind
) -> ()

export type DynamicBindOperation = {
	kind: "Bind",
	registration: EntitySlotService.Registration,
	declaredKind: DynamicKind,
	handler: DynamicHandler,
}

export type DynamicUnbindOperation = {
	kind: "Unbind",
	registration: EntitySlotService.Registration,
	binding: DynamicBinding,
}

export type DynamicOperation = DynamicBindOperation | DynamicUnbindOperation

export type DynamicOutcome = {
	read kind: "Bound" | "Unbound",
	read registration: EntitySlotService.Registration,
	read binding: DynamicBinding,
	read declaredKind: DynamicKind,
}

export type PreparedDynamicBatchSummary = {
	read revision: number,
	read entitySlotSummary: EntitySlotService.PreparedCommitSummary,
	read outcomes: { DynamicOutcome },
}

export type DebugSnapshot = {
	read started: boolean,
	read faulted: boolean,
	read running: boolean,
	read configurationSealed: boolean,
	read completedFrameCount: number,
	read lastClockRevision: number,
	read lastFrameStep: number,
	read lastFrameLevelTimeMilliseconds: number,
	read lastCoveredThrough: number,
	read lastTraversalStartSourceOrder: number,
	read lastVisitCount: number,
	read lastSkipCount: number,
	read lastUpperBoundReadCount: number,
	read lastClientDispatchCount: number,
	read lastBodyQueueDispatchCount: number,
	read lastMapDispatchCount: number,
	read lastDynamicDispatchCount: number,
	read dynamicBindingCount: number,
	read dynamicBindingRevision: number,
	read activePreparedDynamicBatch: boolean,
	read executionMode: ExecutionMode,
	read dynamicTailOwnerClaimed: boolean,
	read dynamicTailMapPrefixCount: number,
	read dynamicTailMapPrefixEndSourceOrder: number?,
	read dynamicTailFirstSourceOrder: number?,
	read dynamicTailFirstMoverSourceOrder: number?,
	read dynamicTailValidatedMapRegistrationRevision: number?,
	read dynamicPrefixFrameOpen: boolean,
	read dynamicTailPrefixCurrent: boolean,
	read clientHandlerConfigured: boolean,
	read bodyQueueHandlerConfigured: boolean,
	read mapHandlerCount: number,
	read faultPhase: FaultPhase?,
	read faultCheckpoint: FaultCheckpoint?,
	read faultKind: string?,
	read faultSourceOrder: number?,
	read faultGeneration: number?,
	read faultFrameStep: number?,
}

type DynamicBindingStatus = "Pending" | "Active" | "Unbound" | "Aborted" | "Faulted"

type DynamicBindingCapability = {
	binding: DynamicBinding,
	status: DynamicBindingStatus,
	registration: EntitySlotService.Registration,
	sourceOrder: number,
	generation: number,
	bodyId: string,
	declaredKind: DynamicKind,
	handler: DynamicHandler?,
}

type RunCounters = {
	client: number,
	bodyQueue: number,
	map: number,
	dynamic: number,
}

type BindingMutation = {
	capability: DynamicBindingCapability,
	expectedStatus: DynamicBindingStatus,
	expectedHandler: DynamicHandler?,
	nextStatus: DynamicBindingStatus,
	nextHandler: DynamicHandler?,
	newBinding: boolean,
}

type PreparedStatus = "Prepared" | "Applied" | "Aborted"
type DynamicBatchReceiptStatus = "Pending" | "Applied" | "Aborted" | "Retired"

type DynamicBatchReceiptCapability = {
	receipt: DynamicBatchReceipt,
	status: DynamicBatchReceiptStatus,
	summary: PreparedDynamicBatchSummary,
	entityReceipt: EntitySlotService.CommitReceipt,
	appliedBindings: { [number]: DynamicBinding }?,
	appliedRevision: number?,
}

type PreparedCapability = {
	prepared: PreparedDynamicBatch,
	status: PreparedStatus,
	applyValidated: boolean,
	preflightPassCount: number,
	baseRevision: number,
	nextRevision: number,
	baseBindings: { [number]: DynamicBinding },
	nextBindings: { [number]: DynamicBinding },
	mutations: { BindingMutation },
	entityPrepared: EntitySlotService.PreparedCommit,
	entitySummary: EntitySlotService.PreparedCommitSummary,
	entityReceipt: EntitySlotService.CommitReceipt,
	summary: PreparedDynamicBatchSummary,
	receipt: DynamicBatchReceipt,
}

local MAXIMUM_DYNAMIC_KIND_LENGTH = 32
local MAXIMUM_DYNAMIC_BATCH_OPERATIONS = 256
local MAXIMUM_DYNAMIC_BINDING_REVISION = 2_147_483_647
local FIRST_WORLD_SOURCE_ORDER = 65
local FIRST_MAP_SOURCE_ORDER = 73

assert(
	FIRST_MAP_SOURCE_ORDER
		== EntitySpawnPlanRules.FirstWorldSourceOrder + EntitySpawnPlanRules.BodyQueueSize,
	"dynamic-tail first map source order drifted"
)

local started = false
local faulted = false
local running = false
local configurationSealed = false
local executionMode: ExecutionMode = "Unclaimed"
local dynamicTailOwner: DynamicTailOwner? = nil
local dynamicTailMapPrefix: { EntitySlotService.MapRegistration }? = nil
local dynamicTailMapPrefixEndSourceOrder: number? = nil
local dynamicTailFirstSourceOrder: number? = nil
local dynamicTailFirstMoverSourceOrder: number? = nil
local dynamicTailValidatedMapRegistrationRevision: number? = nil
local dynamicPrefixFrameSummary: AuthoritativeFrameService.Summary? = nil
local activeTraversalPhase: FaultPhase? = nil
local activeFaultCheckpoint: FaultCheckpoint? = nil
local activeDispatchKind: string? = nil
local activeDispatchSourceOrder: number? = nil
local activeDispatchGeneration: number? = nil
local activeFrameStep: number? = nil
local faultPhase: FaultPhase? = nil
local faultCheckpoint: FaultCheckpoint? = nil
local faultKind: string? = nil
local faultSourceOrder: number? = nil
local faultGeneration: number? = nil
local faultFrameStep: number? = nil

local clientHandler: ClientHandler? = nil
local bodyQueueHandler: BodyQueueHandler? = nil
local mapHandlers: { [EntitySpawnPlanRules.EntityKind]: MapHandler } = {}

local EMPTY_DYNAMIC_BINDINGS: { [number]: DynamicBinding } = table.freeze({})
local dynamicBindingsBySourceOrder: { [number]: DynamicBinding } = EMPTY_DYNAMIC_BINDINGS
local dynamicBindingRevision = 0
local dynamicBindingCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[DynamicBinding]: DynamicBindingCapability,
}
local activePreparedDynamicBatch: PreparedDynamicBatch? = nil
local preparedDynamicBatchCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedDynamicBatch]: PreparedCapability,
}
local dynamicBatchReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[DynamicBatchReceipt]: DynamicBatchReceiptCapability,
}
local currentAppliedDynamicBatchReceipt: DynamicBatchReceipt? = nil

local completedFrameCount = 0
local lastClockRevision = -1
local lastFrameStep = -1
local lastFrameLevelTimeMilliseconds = -1
local lastCoveredThrough = 0
local lastTraversalStartSourceOrder = 0
local lastVisitCount = 0
local lastSkipCount = 0
local lastUpperBoundReadCount = 0
local lastClientDispatchCount = 0
local lastBodyQueueDispatchCount = 0
local lastMapDispatchCount = 0
local lastDynamicDispatchCount = 0

local function validDynamicKind(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_DYNAMIC_KIND_LENGTH
		and string.match(value, "^[A-Z][A-Za-z0-9_]*$") ~= nil
end

local function isOpaqueEmptyCapability(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value) == nil
		and table.isfrozen(value :: table)
		and next(value :: { [unknown]: unknown }) == nil
end

local function currentDynamicBinding(value: unknown): DynamicBindingCapability?
	if not isOpaqueEmptyCapability(value) then
		return nil
	end
	local binding = value :: DynamicBinding
	local capability = dynamicBindingCapabilities[binding]
	local registration = if capability then capability.registration else nil
	if
		not capability
		or capability.binding ~= binding
		or capability.status ~= "Active"
		or dynamicBindingsBySourceOrder[capability.sourceOrder] ~= binding
		or not registration
		or registration.kind ~= "World"
		or registration.domain ~= "World"
		or registration.sourceOrder ~= capability.sourceOrder
		or registration.generation ~= capability.generation
		or registration.bodyId ~= capability.bodyId
		or not validDynamicKind(capability.declaredKind)
		or type(capability.handler) ~= "function"
	then
		return nil
	end
	return capability
end

local BIND_OPERATION_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	registration = true,
	declaredKind = true,
	handler = true,
})
local UNBIND_OPERATION_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	registration = true,
	binding = true,
})

local function hasExactRawKeys(
	value: unknown,
	allowedKeys: { [string]: boolean },
	expectedCount: number
): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local count = 0
	for key in next, value :: { [unknown]: unknown } do
		if type(key) ~= "string" or allowedKeys[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function denseOperationCount(value: unknown): number?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
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
		if
			count > MAXIMUM_DYNAMIC_BATCH_OPERATIONS
			or maximumIndex > MAXIMUM_DYNAMIC_BATCH_OPERATIONS
		then
			return nil
		end
	end
	return if count > 0 and maximumIndex == count then count else nil
end

local function isFrozenWorldRegistration(value: unknown): boolean
	if
		type(value) ~= "table"
		or getmetatable(value) ~= nil
		or not table.isfrozen(value :: table)
	then
		return false
	end
	local registration = value :: any
	return registration.kind == "World"
		and registration.domain == "World"
		and type(registration.sourceOrder) == "number"
		and registration.sourceOrder % 1 == 0
		and registration.sourceOrder >= FIRST_WORLD_SOURCE_ORDER
		and registration.sourceOrder <= EntityFrameTraversalRules.MaximumNormalSourceOrder
		and type(registration.generation) == "number"
		and registration.generation % 1 == 0
		and registration.generation >= 1
		and type(registration.bodyId) == "string"
		and registration.bodyId ~= ""
		and registration.bodyQueueIndex == nil
end

local function nextDynamicBindingRevision(): number
	assert(
		dynamicBindingRevision < MAXIMUM_DYNAMIC_BINDING_REVISION,
		"dynamic binding revision exhausted"
	)
	return dynamicBindingRevision + 1
end

local function retireAppliedDynamicBatchReceipt()
	local receipt = currentAppliedDynamicBatchReceipt
	if not receipt then
		return
	end
	local capability = dynamicBatchReceiptCapabilities[receipt]
	if capability and capability.status == "Applied" then
		capability.status = "Retired"
	end
	currentAppliedDynamicBatchReceipt = nil
end

local function currentPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if not isOpaqueEmptyCapability(preparedValue) then
		return nil, "invalid-prepared-dynamic-batch"
	end
	local prepared = preparedValue :: PreparedDynamicBatch
	local capability = preparedDynamicBatchCapabilities[prepared]
	if
		not capability
		or capability.prepared ~= prepared
		or capability.status ~= "Prepared"
		or activePreparedDynamicBatch ~= prepared
	then
		return nil, "invalid-prepared-dynamic-batch"
	end
	return capability, nil
end

local function preparedCurrentError(
	prepared: PreparedDynamicBatch,
	capability: PreparedCapability,
	validateEntitySlot: boolean
): string?
	if
		activePreparedDynamicBatch ~= prepared
		or capability.status ~= "Prepared"
		or capability.baseRevision ~= dynamicBindingRevision
		or capability.nextRevision ~= capability.baseRevision + 1
		or dynamicBindingsBySourceOrder ~= capability.baseBindings
		or not table.isfrozen(capability.baseBindings)
		or not table.isfrozen(capability.nextBindings)
		or not table.isfrozen(capability.prepared :: any)
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(capability.summary.outcomes)
		or not table.isfrozen(capability.receipt :: any)
		or capability.summary.revision ~= capability.nextRevision
		or capability.summary.entitySlotSummary ~= capability.entitySummary
	then
		return "stale-prepared-dynamic-batch"
	end
	for _, mutation in capability.mutations do
		local bindingCapability = mutation.capability
		if
			dynamicBindingCapabilities[bindingCapability.binding] ~= bindingCapability
			or bindingCapability.status ~= mutation.expectedStatus
			or bindingCapability.handler ~= mutation.expectedHandler
		then
			return "stale-prepared-dynamic-binding-mutation"
		end
	end
	if validateEntitySlot then
		local valid, dependencyError = EntitySlotService.ValidatePreparedCommitDependency(
			capability.entityPrepared,
			capability.entitySummary
		)
		if not valid then
			return dependencyError or "stale-prepared-dynamic-entity-slot-dependency"
		end
		if
			EntitySlotService.InspectPreparedCommitReceipt(capability.entityPrepared)
			~= capability.entityReceipt
		then
			return "stale-prepared-dynamic-entity-slot-receipt"
		end
	end
	return nil
end

local function mapRegistrationForExactWorld(
	registration: EntitySlotService.Registration
): (EntitySlotService.MapRegistration?, string?)
	-- Dynamic-tail execution captures the immutable retained map prefix when its
	-- owner is claimed. Source orders are contiguous, so classification during a
	-- frame is an O(1) indexed lookup. The phase-boundary prefix checks below
	-- still fail closed if an illegal mutation changes that captured generation.
	local capturedPrefix = dynamicTailMapPrefix
	if capturedPrefix then
		local index = registration.sourceOrder - FIRST_MAP_SOURCE_ORDER + 1
		if index >= 1 and index <= #capturedPrefix then
			local captured = capturedPrefix[index]
			if captured.registration == registration then
				return captured, nil
			end
			-- Q3 may reuse a released authored-map slot for a later dynamic
			-- generation. It is dynamic only after the captured event is an exact
			-- tombstone; a different active generation while the map event remains
			-- current is corruption.
			if EntitySlotService.GetMapRegistration(captured.eventId) == captured then
				return nil, "entity-slot-map-registration-mismatch"
			end
			return nil, nil
		end
		return nil, nil
	end
	local ordered = EntitySlotService.GetMapRegistrationsInSourceOrder()
	if not ordered then
		return nil, "entity-slot-map-registration-view-unavailable"
	end
	local found: EntitySlotService.MapRegistration? = nil
	for _, mapRegistration in ordered do
		if mapRegistration.registration.sourceOrder == registration.sourceOrder then
			if mapRegistration.registration ~= registration or found then
				return nil, "entity-slot-map-registration-mismatch"
			end
			found = mapRegistration
		elseif mapRegistration.registration == registration then
			return nil, "entity-slot-map-registration-source-order-mismatch"
		end
	end
	return found, nil
end

local function inspectInstalledContiguousMapPrefix(): (
	{ EntitySlotService.MapRegistration }?,
	number?,
	string?
)
	if not EntitySlotService.IsMapSpawnPlanInstalled() then
		return nil, nil, "entity-slot-map-spawn-plan-not-installed"
	end
	local ordered = EntitySlotService.GetMapRegistrationsInSourceOrder()
	if not ordered or not table.isfrozen(ordered) then
		return nil, nil, "entity-slot-map-registration-view-unavailable"
	end
	for bodyQueueIndex = 1, EntitySpawnPlanRules.BodyQueueSize do
		local expectedSourceOrder = FIRST_WORLD_SOURCE_ORDER + bodyQueueIndex - 1
		local registration = EntitySlotService.GetBodyQueueRegistration(bodyQueueIndex)
		if
			registration == nil
			or registration.kind ~= "BodyQueue"
			or registration.domain ~= "World"
			or registration.sourceOrder ~= expectedSourceOrder
			or EntitySlotService.InspectSlot(expectedSourceOrder) ~= registration
		then
			return nil, nil, "entity-slot-body-queue-prefix-not-exact"
		end
	end
	for index, mapRegistration in ordered do
		local registration = mapRegistration.registration
		local expectedSourceOrder = FIRST_MAP_SOURCE_ORDER + index - 1
		if
			not table.isfrozen(mapRegistration :: any)
			or EntitySlotService.GetMapRegistration(mapRegistration.eventId) ~= mapRegistration
			or registration.kind ~= "World"
			or registration.domain ~= "World"
			or registration.sourceOrder ~= expectedSourceOrder
			or EntitySlotService.InspectSlot(expectedSourceOrder) ~= registration
		then
			return nil, nil, "entity-slot-map-prefix-not-exact-contiguous"
		end
	end
	local firstDynamicSourceOrder = FIRST_MAP_SOURCE_ORDER + #ordered
	if firstDynamicSourceOrder > EntityFrameTraversalRules.MaximumStartSourceOrder then
		return nil, nil, "entity-slot-map-prefix-exceeds-entity-domain"
	end
	local upperBound = EntitySlotService.GetTraversalUpperBound()
	if not upperBound or upperBound < firstDynamicSourceOrder - 1 then
		return nil, nil, "entity-slot-map-prefix-upper-bound-mismatch"
	end
	return ordered, firstDynamicSourceOrder, nil
end

local function dynamicTailPrefixCurrentError(): string?
	local capturedPrefix = dynamicTailMapPrefix
	local capturedFirstDynamicSourceOrder = dynamicTailFirstSourceOrder
	if
		executionMode ~= "DynamicTail"
		or dynamicTailOwner == nil
		or capturedPrefix == nil
		or capturedFirstDynamicSourceOrder == nil
	then
		return "dynamic-tail-owner-not-claimed"
	end
	local currentMapRegistrationRevision = EntitySlotService.GetMapRegistrationRevision()
	if currentMapRegistrationRevision == nil then
		return "dynamic-tail-map-registration-view-unavailable"
	end
	if currentMapRegistrationRevision == dynamicTailValidatedMapRegistrationRevision then
		return nil
	end
	local currentMapRegistrations = EntitySlotService.GetMapRegistrationsInSourceOrder()
	if not currentMapRegistrations then
		return "dynamic-tail-map-registration-view-unavailable"
	end
	local capturedByEventId: { [string]: EntitySlotService.MapRegistration } = {}
	for index, captured in capturedPrefix do
		local expectedSourceOrder = FIRST_MAP_SOURCE_ORDER + index - 1
		if captured.registration.sourceOrder ~= expectedSourceOrder then
			return "dynamic-tail-captured-map-prefix-corrupt"
		end
		capturedByEventId[captured.eventId] = captured
		local current = EntitySlotService.GetMapRegistration(captured.eventId)
		if current ~= nil and current ~= captured then
			return "dynamic-tail-map-prefix-generation-changed"
		end
		if captured.kind == EntitySpawnPlanRules.EntityKinds.Mover and current ~= captured then
			return "dynamic-tail-retained-mover-generation-changed"
		end
		if current == captured then
			if EntitySlotService.InspectSlot(expectedSourceOrder) ~= captured.registration then
				return "dynamic-tail-retained-map-slot-changed"
			end
		elseif EntitySlotService.InspectSlot(expectedSourceOrder) == captured.registration then
			return "dynamic-tail-released-map-index-retained-slot"
		end
	end
	for _, current in currentMapRegistrations do
		if capturedByEventId[current.eventId] ~= current then
			return "dynamic-tail-map-prefix-membership-changed"
		end
	end
	dynamicTailValidatedMapRegistrationRevision = currentMapRegistrationRevision
	return nil
end

local function assertDynamicTailPrefixCurrent()
	local prefixError = dynamicTailPrefixCurrentError()
	assert(prefixError == nil, prefixError or "dynamic-tail-map-prefix-stale")
end

local function isCurrentDynamicTailOwner(ownerValue: unknown): boolean
	return isOpaqueEmptyCapability(ownerValue)
		and dynamicTailOwner ~= nil
		and ownerValue == dynamicTailOwner
end

local function exactOpenFrameSummary(frameValue: unknown): AuthoritativeFrameService.Summary?
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	if
		openFrame == nil
		or frameValue ~= openFrame
		or summary == nil
		or not AuthoritativeFrameService.ValidateFrameDependency(frameValue, summary)
	then
		return nil
	end
	return summary
end

local function assertHandlerPostconditions(
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary
)
	assert(not faulted, "entity-frame dispatcher faulted inside an entity handler")
	assert(
		activePreparedDynamicBatch == nil,
		"entity-frame handler left a prepared dynamic batch active"
	)
	assert(
		exactOpenFrameSummary(frame) == summary,
		"entity-frame handler invalidated the exact open frame"
	)
	assert(
		EntitySlotService.GetTraversalUpperBound() ~= nil,
		"entity-frame handler left an EntitySlot transaction open"
	)
end

local function discardCaughtDispatcherError(_errorValue: unknown)
	-- Do not retain, stringify, trace, publish, or replicate a caught handler
	-- value. The caller receives only the static terminal dispatcher signal.
	return nil
end

local function beginVisitSite(registration: EntitySlotService.Registration)
	assert(activeTraversalPhase ~= nil, "entity-frame dispatch site has no traversal phase")
	assert(activeDispatchKind == nil, "entity-frame dispatch sites cannot nest")
	assert(
		activeDispatchSourceOrder == nil
			or (
				activeDispatchSourceOrder == registration.sourceOrder
				and activeDispatchGeneration == registration.generation
			),
		"entity-frame visit sites cannot cross registrations"
	)
	activeFaultCheckpoint = "Traversal"
	activeDispatchSourceOrder = registration.sourceOrder
	activeDispatchGeneration = registration.generation
end

local function beginDispatchSite(kind: string, registration: EntitySlotService.Registration)
	beginVisitSite(registration)
	activeFaultCheckpoint = "Handler"
	activeDispatchKind = kind
end

local function beginDispatchPostconditions()
	assert(activeDispatchKind ~= nil, "entity-frame postconditions have no dispatch site")
	activeFaultCheckpoint = "Postconditions"
end

local function endDispatchSite()
	activeFaultCheckpoint = "Traversal"
	activeDispatchKind = nil
	activeDispatchSourceOrder = nil
	activeDispatchGeneration = nil
end

local function quarantineDynamicBindings()
	retireAppliedDynamicBatchReceipt()
	for _, capability in dynamicBindingCapabilities do
		if capability.status == "Active" or capability.status == "Pending" then
			capability.status = "Faulted"
			capability.handler = nil
		end
	end
	dynamicBindingsBySourceOrder = EMPTY_DYNAMIC_BINDINGS
	local prepared = activePreparedDynamicBatch
	if prepared then
		local capability = preparedDynamicBatchCapabilities[prepared]
		if capability then
			capability.status = "Aborted"
			capability.applyValidated = false
			local receiptCapability = dynamicBatchReceiptCapabilities[capability.receipt]
			if receiptCapability and receiptCapability.status == "Pending" then
				receiptCapability.status = "Aborted"
			end
		end
		preparedDynamicBatchCapabilities[prepared] = nil
		activePreparedDynamicBatch = nil
	end
end

local function latchTerminalFault()
	if faulted then
		return
	end
	faulted = true
	if activeTraversalPhase ~= nil then
		faultPhase = activeTraversalPhase
		faultCheckpoint = activeFaultCheckpoint
		faultKind = activeDispatchKind
		faultSourceOrder = activeDispatchSourceOrder
		faultGeneration = activeDispatchGeneration
		faultFrameStep = activeFrameStep
		warn(
			string.format(
				"[Q3EngineEntityFrameFault] phase=%s checkpoint=%s kind=%s sourceOrder=%d generation=%d frameStep=%d",
				faultPhase,
				faultCheckpoint or "Traversal",
				faultKind or "Traversal",
				faultSourceOrder or 0,
				faultGeneration or 0,
				faultFrameStep or 0
			)
		)
	end
	quarantineDynamicBindings()
end

local function assertConfigurable()
	assert(started, "EntityFrameDispatcherService must be started before configuration")
	assert(not faulted, "EntityFrameDispatcherService is permanently faulted")
	assert(not running, "EntityFrameDispatcherService cannot configure while running")
	assert(
		not configurationSealed,
		"EntityFrameDispatcherService configuration is sealed after an execution mode is claimed"
	)
end

local function setMapHandler(kind: EntitySpawnPlanRules.EntityKind, handler: MapHandler)
	assertConfigurable()
	assert(type(handler) == "function", "entity-frame map handler must be a function")
	assert(mapHandlers[kind] == nil, "entity-frame map handler may only be configured once")
	mapHandlers[kind] = handler
end

local function dispatchRegistration(
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration,
	counters: RunCounters
)
	beginVisitSite(registration)
	local sourceOrder = registration.sourceOrder
	assert(
		EntitySlotService.InspectSlot(sourceOrder) == registration,
		"entity-frame registration became stale before dispatch"
	)

	if registration.kind == "Player" then
		local player = EntitySlotService.GetPlayerForRegistration(registration)
		local handler = clientHandler
		assert(player ~= nil, "entity-frame client registration has no exact active Player")
		assert(handler ~= nil, "entity-frame client handler is missing")
		beginDispatchSite("Player", registration)
		handler(frame, summary, player, registration)
		beginDispatchPostconditions()
		assertHandlerPostconditions(frame, summary)
		endDispatchSite()
		counters.client += 1
		return
	end

	if registration.kind == "BodyQueue" then
		local bodyQueueIndex = registration.bodyQueueIndex
		local handler = bodyQueueHandler
		assert(bodyQueueIndex ~= nil, "entity-frame body-queue registration has no index")
		assert(
			EntitySlotService.GetBodyQueueRegistration(bodyQueueIndex) == registration,
			"entity-frame body-queue registration is mismatched"
		)
		assert(handler ~= nil, "entity-frame body-queue handler is missing")
		beginDispatchSite("BodyQueue", registration)
		handler(frame, summary, registration)
		beginDispatchPostconditions()
		assertHandlerPostconditions(frame, summary)
		endDispatchSite()
		counters.bodyQueue += 1
		return
	end

	assert(registration.kind == "World", "entity-frame registration kind is invalid")
	local mapRegistration, mapError = mapRegistrationForExactWorld(registration)
	assert(mapError == nil, "entity-frame map registration view is stale or unavailable")
	if mapRegistration then
		local handler = mapHandlers[mapRegistration.kind]
		assert(handler ~= nil, "entity-frame retained map-kind handler is missing")
		beginDispatchSite(mapRegistration.kind, registration)
		handler(frame, summary, mapRegistration)
		beginDispatchPostconditions()
		assertHandlerPostconditions(frame, summary)
		endDispatchSite()
		counters.map += 1
		return
	end

	local binding = dynamicBindingsBySourceOrder[sourceOrder]
	local capability = currentDynamicBinding(binding)
	assert(capability ~= nil, "active dynamic world registration has no exact binding")
	assert(
		capability.registration == registration
			and capability.sourceOrder == registration.sourceOrder
			and capability.generation == registration.generation,
		"active dynamic world registration generation is mismatched"
	)
	local handler = capability.handler
	assert(handler ~= nil, "active dynamic world registration handler is missing")
	beginDispatchSite(capability.declaredKind, registration)
	handler(frame, summary, registration, capability.binding, capability.declaredKind)
	beginDispatchPostconditions()
	assertHandlerPostconditions(frame, summary)
	endDispatchSite()
	counters.dynamic += 1
end

local function dispatchDynamicTailRegistration(
	frame: AuthoritativeFrameService.Frame,
	summary: AuthoritativeFrameService.Summary,
	registration: EntitySlotService.Registration,
	counters: RunCounters
)
	beginVisitSite(registration)
	assert(
		activePreparedDynamicBatch == nil,
		"prepared dynamic batch is active before a dynamic-tail handler"
	)
	assert(
		registration.kind == "World"
			and registration.domain == "World"
			and registration.sourceOrder >= FIRST_MAP_SOURCE_ORDER
			and EntitySlotService.InspectSlot(registration.sourceOrder) == registration,
		"dynamic-tail visit is not an exact dynamic World registration"
	)
	local mapRegistration, mapError = mapRegistrationForExactWorld(registration)
	assert(mapError == nil, "dynamic-tail map classification is unavailable")
	assert(mapRegistration == nil, "dynamic-tail dispatch reached a retained map registration")

	local binding = dynamicBindingsBySourceOrder[registration.sourceOrder]
	local capability = currentDynamicBinding(binding)
	assert(capability ~= nil, "dynamic-tail registration has no exact binding")
	assert(
		capability.registration == registration
			and capability.sourceOrder == registration.sourceOrder
			and capability.generation == registration.generation,
		"dynamic-tail registration generation is mismatched"
	)
	local handler = capability.handler
	assert(handler ~= nil, "dynamic-tail registration handler is missing")
	beginDispatchSite(capability.declaredKind, registration)
	handler(frame, summary, registration, capability.binding, capability.declaredKind)
	beginDispatchPostconditions()
	assert(
		activePreparedDynamicBatch == nil,
		"dynamic-tail handler left a prepared dynamic batch active"
	)
	assertHandlerPostconditions(frame, summary)
	endDispatchSite()
	counters.dynamic += 1
end

local function validateAllDynamicBindings()
	local upperBound = EntitySlotService.GetTraversalUpperBound()
	assert(upperBound ~= nil, "entity-slot transaction remained open after entity traversal")
	for sourceOrder, binding in dynamicBindingsBySourceOrder do
		local capability = currentDynamicBinding(binding)
		assert(capability ~= nil, "dynamic binding registry contains a stale capability")
		assert(
			capability.sourceOrder == sourceOrder
				and sourceOrder <= upperBound
				and EntitySlotService.InspectSlot(sourceOrder) == capability.registration,
			"dynamic binding no longer names its exact active generation"
		)
		local mapRegistration, mapError = mapRegistrationForExactWorld(capability.registration)
		assert(mapError == nil, "dynamic binding map classification is unavailable")
		assert(mapRegistration == nil, "dynamic binding aliases a retained map registration")
	end

	-- The live cursor intentionally does not revisit a lower source order reused
	-- by G_Spawn-equivalent work after that number was covered. It still must be
	-- bound before Run closes so the new generation cannot become an anonymous
	-- active world entity between frames.
	for sourceOrder = 1, upperBound do
		local registration = EntitySlotService.InspectSlot(sourceOrder)
		if registration and registration.kind == "World" then
			local mapRegistration, mapError = mapRegistrationForExactWorld(registration)
			assert(mapError == nil, "active world registration classification is unavailable")
			if mapRegistration == nil then
				local binding = dynamicBindingsBySourceOrder[sourceOrder]
				local capability = currentDynamicBinding(binding)
				assert(
					capability ~= nil and capability.registration == registration,
					"active dynamic world registration is not generation-bound"
				)
			end
		end
	end
end

function EntityFrameDispatcherService.Start(): (boolean, string?)
	if started then
		return false, "entity-frame-dispatcher-already-started"
	end
	if not AuthoritativeFrameService.IsStarted() then
		return false, "authoritative-frame-service-not-started"
	end
	if not EntitySlotService.IsStarted() then
		return false, "entity-slot-service-not-started"
	end
	started = true
	return true, nil
end

function EntityFrameDispatcherService.IsStarted(): boolean
	return started
end

function EntityFrameDispatcherService.IsFaulted(): boolean
	return faulted
end

function EntityFrameDispatcherService.ClaimDynamicTailOwner(): (DynamicTailOwner?, string?)
	if not started then
		return nil, "entity-frame-dispatcher-not-started"
	end
	if faulted then
		return nil, "entity-frame-dispatcher-faulted"
	end
	if running then
		return nil, "entity-frame-dispatcher-running"
	end
	if configurationSealed then
		return nil, "entity-frame-dispatcher-configuration-sealed"
	end
	if activePreparedDynamicBatch ~= nil then
		return nil, "prepared-dynamic-batch-active"
	end
	if dynamicBindingRevision ~= 0 or next(dynamicBindingsBySourceOrder) ~= nil then
		return nil, "dynamic-tail-owner-requires-pristine-bindings"
	end
	if executionMode ~= "Unclaimed" or dynamicTailOwner ~= nil then
		return nil, "entity-frame-dispatcher-execution-mode-locked"
	end
	local mapPrefix, firstDynamicSourceOrder, prefixError = inspectInstalledContiguousMapPrefix()
	if not mapPrefix or not firstDynamicSourceOrder then
		return nil, prefixError or "dynamic-tail-map-prefix-unavailable"
	end
	local mapRegistrationRevision = EntitySlotService.GetMapRegistrationRevision()
	if mapRegistrationRevision == nil then
		return nil, "dynamic-tail-map-registration-view-unavailable"
	end
	if EntitySlotService.GetTraversalUpperBound() ~= firstDynamicSourceOrder - 1 then
		return nil, "dynamic-tail-owner-requires-exact-map-prefix-upper-bound"
	end
	local cursor, cursorError = EntityFrameTraversalRules.BeginAt(firstDynamicSourceOrder)
	if not cursor then
		return nil, cursorError or "dynamic-tail-first-source-order-invalid"
	end
	assert(
		EntityFrameTraversalRules.Inspect(cursor) == cursor,
		"dynamic-tail first source order did not mint an exact traversal cursor"
	)

	local owner: DynamicTailOwner = table.freeze({})
	local capturedPrefix = table.clone(mapPrefix)
	table.freeze(capturedPrefix)
	local firstMoverSourceOrder = firstDynamicSourceOrder
	local foundMover = false
	for _, mapRegistration in capturedPrefix do
		if mapRegistration.kind == EntitySpawnPlanRules.EntityKinds.Mover then
			if not foundMover then
				firstMoverSourceOrder = mapRegistration.registration.sourceOrder
				foundMover = true
			end
		elseif foundMover then
			return nil, "dynamic-tail-map-movers-not-contiguous-tail"
		end
	end
	dynamicTailMapPrefix = capturedPrefix
	dynamicTailMapPrefixEndSourceOrder = firstDynamicSourceOrder - 1
	dynamicTailFirstSourceOrder = firstDynamicSourceOrder
	dynamicTailFirstMoverSourceOrder = firstMoverSourceOrder
	dynamicTailValidatedMapRegistrationRevision = mapRegistrationRevision
	dynamicTailOwner = owner
	executionMode = "DynamicTail"
	configurationSealed = true
	return owner, nil
end

function EntityFrameDispatcherService.HandleSimulationFault()
	if not started then
		return
	end
	latchTerminalFault()
end

function EntityFrameDispatcherService.SetClientHandler(handler: ClientHandler)
	assertConfigurable()
	assert(type(handler) == "function", "entity-frame client handler must be a function")
	assert(clientHandler == nil, "entity-frame client handler may only be configured once")
	clientHandler = handler
end

function EntityFrameDispatcherService.SetBodyQueueHandler(handler: BodyQueueHandler)
	assertConfigurable()
	assert(type(handler) == "function", "entity-frame body-queue handler must be a function")
	assert(bodyQueueHandler == nil, "entity-frame body-queue handler may only be configured once")
	bodyQueueHandler = handler
end

function EntityFrameDispatcherService.SetMapSpawnHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.Spawn, handler)
end

function EntityFrameDispatcherService.SetMapItemHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.Item, handler)
end

function EntityFrameDispatcherService.SetMapTeamFlagHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.TeamFlag, handler)
end

function EntityFrameDispatcherService.SetMapTargetHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.Target, handler)
end

function EntityFrameDispatcherService.SetMapTriggerHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.Trigger, handler)
end

function EntityFrameDispatcherService.SetMapMoverHandler(handler: MapHandler)
	setMapHandler(EntitySpawnPlanRules.EntityKinds.Mover, handler)
end

function EntityFrameDispatcherService.PrepareDynamicBatch(
	entityPreparedValue: unknown,
	entitySummaryValue: unknown,
	operationsValue: unknown
): (
	PreparedDynamicBatch?,
	PreparedDynamicBatchSummary?,
	string?
)
	if not started then
		return nil, nil, "entity-frame-dispatcher-not-started"
	end
	if faulted then
		return nil, nil, "entity-frame-dispatcher-faulted"
	end
	if activePreparedDynamicBatch ~= nil then
		return nil, nil, "prepared-dynamic-batch-active"
	end
	if dynamicBindingRevision >= MAXIMUM_DYNAMIC_BINDING_REVISION then
		return nil, nil, "dynamic-binding-revision-exhausted"
	end
	local operationCount = denseOperationCount(operationsValue)
	if not operationCount then
		return nil, nil, "invalid-dynamic-batch-operations"
	end
	local validEntityDependency, entityDependencyError =
		EntitySlotService.ValidatePreparedCommitDependency(entityPreparedValue, entitySummaryValue)
	if not validEntityDependency then
		return nil, nil, entityDependencyError or "invalid-dynamic-batch-entity-slot-dependency"
	end
	local entityReceipt = EntitySlotService.InspectPreparedCommitReceipt(entityPreparedValue)
	if not entityReceipt then
		return nil, nil, "dynamic-batch-entity-slot-receipt-unavailable"
	end
	local entityPrepared = entityPreparedValue :: EntitySlotService.PreparedCommit
	local entitySummary = entitySummaryValue :: EntitySlotService.PreparedCommitSummary

	if not table.isfrozen(dynamicBindingsBySourceOrder) then
		return nil, nil, "dynamic-binding-root-not-frozen"
	end
	for sourceOrder, binding in dynamicBindingsBySourceOrder do
		local capability = currentDynamicBinding(binding)
		if not capability or capability.sourceOrder ~= sourceOrder then
			return nil, nil, "stale-dynamic-binding-root"
		end
	end

	local baseBindings = dynamicBindingsBySourceOrder
	local nextBindings = table.clone(baseBindings)
	local mutations: { BindingMutation } = {}
	local outcomes: { DynamicOutcome } = {}
	local newCapabilities: { DynamicBindingCapability } = {}
	local observedBindSourceOrders: { [number]: boolean } = {}
	local observedUnbindSourceOrders: { [number]: boolean } = {}
	local observedUnbindBindings: { [DynamicBinding]: boolean } = {}

	local function fail(
		message: string
	): (PreparedDynamicBatch?, PreparedDynamicBatchSummary?, string?)
		for _, capability in newCapabilities do
			capability.status = "Aborted"
			capability.handler = nil
			dynamicBindingCapabilities[capability.binding] = nil
		end
		return nil, nil, message
	end
	local function validateWorldOutcome(
		registration: EntitySlotService.Registration,
		expectedStatus: "Retained" | "Released"
	): (boolean, string?)
		local foundLease = nil
		for _, outcome in entitySummary.worldOutcomes do
			if outcome.registration == registration then
				if foundLease ~= nil then
					return false, "duplicate-entity-slot-world-outcome"
				end
				foundLease = outcome.lease
			end
		end
		if foundLease == nil then
			return false, "entity-slot-world-outcome-missing"
		end
		return EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
			entityPrepared,
			entitySummary,
			registration,
			foundLease,
			expectedStatus
		)
	end

	for operationIndex = 1, operationCount do
		local operationValue = (operationsValue :: { unknown })[operationIndex]
		if type(operationValue) ~= "table" then
			return fail(string.format("dynamic-operation-%d:not-table", operationIndex))
		end
		local operation = operationValue :: { [unknown]: unknown }
		local kind = rawget(operation, "kind")
		local registrationValue = rawget(operation, "registration")
		if not isFrozenWorldRegistration(registrationValue) then
			return fail(string.format("dynamic-operation-%d:invalid-registration", operationIndex))
		end
		local registration = registrationValue :: EntitySlotService.Registration
		local sourceOrder = registration.sourceOrder

		if kind == "Bind" then
			if not hasExactRawKeys(operationValue, BIND_OPERATION_KEYS, 4) then
				return fail(
					string.format("dynamic-operation-%d:invalid-bind-shape", operationIndex)
				)
			end
			local declaredKindValue = rawget(operation, "declaredKind")
			local handlerValue = rawget(operation, "handler")
			if not validDynamicKind(declaredKindValue) or type(handlerValue) ~= "function" then
				return fail(string.format("dynamic-operation-%d:invalid-bind", operationIndex))
			end
			if observedBindSourceOrders[sourceOrder] or nextBindings[sourceOrder] ~= nil then
				return fail(
					string.format("dynamic-operation-%d:bind-source-collision", operationIndex)
				)
			end
			local retained, retainedError = validateWorldOutcome(registration, "Retained")
			if not retained then
				return fail(
					string.format(
						"dynamic-operation-%d:%s",
						operationIndex,
						retainedError or "bind-outcome-not-retained"
					)
				)
			end
			local binding: DynamicBinding = table.freeze({})
			local bindingCapability: DynamicBindingCapability = {
				binding = binding,
				status = "Pending",
				registration = registration,
				sourceOrder = sourceOrder,
				generation = registration.generation,
				bodyId = registration.bodyId,
				declaredKind = declaredKindValue :: string,
				handler = handlerValue :: DynamicHandler,
			}
			dynamicBindingCapabilities[binding] = bindingCapability
			table.insert(newCapabilities, bindingCapability)
			nextBindings[sourceOrder] = binding
			observedBindSourceOrders[sourceOrder] = true
			table.insert(mutations, {
				capability = bindingCapability,
				expectedStatus = "Pending",
				expectedHandler = bindingCapability.handler,
				nextStatus = "Active",
				nextHandler = bindingCapability.handler,
				newBinding = true,
			})
			local outcome: DynamicOutcome = {
				kind = "Bound",
				registration = registration,
				binding = binding,
				declaredKind = bindingCapability.declaredKind,
			}
			table.freeze(outcome)
			table.insert(outcomes, outcome)
		elseif kind == "Unbind" then
			if not hasExactRawKeys(operationValue, UNBIND_OPERATION_KEYS, 3) then
				return fail(
					string.format("dynamic-operation-%d:invalid-unbind-shape", operationIndex)
				)
			end
			local bindingValue = rawget(operation, "binding")
			local bindingCapability = currentDynamicBinding(bindingValue)
			if
				not bindingCapability
				or bindingCapability.registration ~= registration
				or bindingCapability.sourceOrder ~= sourceOrder
				or nextBindings[sourceOrder] ~= bindingCapability.binding
				or observedUnbindSourceOrders[sourceOrder]
				or observedUnbindBindings[bindingCapability.binding]
			then
				return fail(string.format("dynamic-operation-%d:invalid-unbind", operationIndex))
			end
			local released, releasedError = validateWorldOutcome(registration, "Released")
			if not released then
				return fail(
					string.format(
						"dynamic-operation-%d:%s",
						operationIndex,
						releasedError or "entity-slot-world-outcome-missing"
					)
				)
			end
			nextBindings[sourceOrder] = nil
			observedUnbindSourceOrders[sourceOrder] = true
			observedUnbindBindings[bindingCapability.binding] = true
			table.insert(mutations, {
				capability = bindingCapability,
				expectedStatus = "Active",
				expectedHandler = bindingCapability.handler,
				nextStatus = "Unbound",
				nextHandler = nil,
				newBinding = false,
			})
			local outcome: DynamicOutcome = {
				kind = "Unbound",
				registration = registration,
				binding = bindingCapability.binding,
				declaredKind = bindingCapability.declaredKind,
			}
			table.freeze(outcome)
			table.insert(outcomes, outcome)
		else
			return fail(string.format("dynamic-operation-%d:invalid-kind", operationIndex))
		end
	end

	for _, mutation in mutations do
		table.freeze(mutation)
	end
	table.freeze(mutations)
	table.freeze(nextBindings)
	table.sort(outcomes, function(left: DynamicOutcome, right: DynamicOutcome): boolean
		if left.registration.sourceOrder ~= right.registration.sourceOrder then
			return left.registration.sourceOrder < right.registration.sourceOrder
		end
		return left.kind == "Unbound" and right.kind == "Bound"
	end)
	table.freeze(outcomes)

	local nextRevision = nextDynamicBindingRevision()
	local summary: PreparedDynamicBatchSummary = {
		revision = nextRevision,
		entitySlotSummary = entitySummary,
		outcomes = outcomes,
	}
	table.freeze(summary)
	local prepared: PreparedDynamicBatch = table.freeze({})
	local receipt: DynamicBatchReceipt = table.freeze({})
	dynamicBatchReceiptCapabilities[receipt] = {
		receipt = receipt,
		status = "Pending",
		summary = summary,
		entityReceipt = entityReceipt,
		appliedBindings = nil,
		appliedRevision = nil,
	}
	preparedDynamicBatchCapabilities[prepared] = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		preflightPassCount = 0,
		baseRevision = dynamicBindingRevision,
		nextRevision = nextRevision,
		baseBindings = baseBindings,
		nextBindings = nextBindings,
		mutations = mutations,
		entityPrepared = entityPrepared,
		entitySummary = entitySummary,
		entityReceipt = entityReceipt,
		summary = summary,
		receipt = receipt,
	}
	-- A successfully prepared successor permanently retires the previous
	-- assignment-adjacency witness even if this successor is later aborted.
	retireAppliedDynamicBatchReceipt()
	activePreparedDynamicBatch = prepared
	return prepared, summary, nil
end

function EntityFrameDispatcherService.InspectPreparedDynamicBatch(
	preparedValue: unknown
): PreparedDynamicBatchSummary?
	local capability = select(1, currentPreparedCapability(preparedValue))
	if
		not capability
		or preparedCurrentError(preparedValue :: PreparedDynamicBatch, capability, true)
	then
		return nil
	end
	return capability.summary
end

function EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(
	preparedValue: unknown
): DynamicBatchReceipt?
	local capability = select(1, currentPreparedCapability(preparedValue))
	if
		not capability
		or preparedCurrentError(preparedValue :: PreparedDynamicBatch, capability, true)
	then
		return nil
	end
	return capability.receipt
end

function EntityFrameDispatcherService.ValidatePreparedDynamicBatchDependency(
	preparedValue: unknown,
	summaryValue: unknown
): boolean
	local summary = EntityFrameDispatcherService.InspectPreparedDynamicBatch(preparedValue)
	return summary ~= nil and summary == summaryValue
end

-- Exact assignment-adjacency witness for downstream prepared owners. The
-- receipt exists during Prepare, but its private applied root/revision are not
-- armed until the Dispatcher has consumed the exact applied EntitySlot commit.
-- A later prepared batch, direct binding mutation, or terminal fault retires it.
function EntityFrameDispatcherService.ValidateAppliedDynamicBatchDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-applied-dynamic-batch-dependency"
	end
	local receipt = receiptValue :: DynamicBatchReceipt
	local capability = dynamicBatchReceiptCapabilities[receipt]
	if not capability or capability.receipt ~= receipt then
		return false, "invalid-applied-dynamic-batch-receipt"
	end
	if capability.summary ~= summaryValue then
		return false, "forged-applied-dynamic-batch-summary"
	end
	local appliedBindings = capability.appliedBindings
	local appliedRevision = capability.appliedRevision
	if capability.status ~= "Applied" or not appliedBindings or not appliedRevision then
		return false, "dynamic-batch-dependency-not-applied"
	end
	if
		faulted
		or activePreparedDynamicBatch ~= nil
		or currentAppliedDynamicBatchReceipt ~= receipt
		or dynamicBindingsBySourceOrder ~= appliedBindings
		or dynamicBindingRevision ~= appliedRevision
		or capability.summary.revision ~= appliedRevision
		or not table.isfrozen(receipt :: any)
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(appliedBindings)
	then
		return false, "stale-applied-dynamic-batch-dependency"
	end
	local entityApplied, entityError = EntitySlotService.ValidateAppliedCommitDependency(
		capability.entityReceipt,
		capability.summary.entitySlotSummary
	)
	if not entityApplied then
		return false, entityError or "stale-applied-dynamic-batch-entity-slot-dependency"
	end
	return true, nil
end

function EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(
	preparedValue: unknown
): (boolean, string?)
	local capability, capabilityError = currentPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local prepared = preparedValue :: PreparedDynamicBatch
	local currentError = preparedCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	capability.applyValidated = true
	return true, nil
end

function EntityFrameDispatcherService.ApplyPreparedDynamicBatch(
	preparedValue: unknown
): DynamicBatchReceipt
	local capability, capabilityError = currentPreparedCapability(preparedValue)
	assert(capability, capabilityError or "invalid-prepared-dynamic-batch")
	assert(capability.applyValidated, "prepared dynamic batch was not preflighted")
	assert(
		capability.preflightPassCount >= 2,
		"prepared dynamic batch requires two complete preflight passes"
	)
	local prepared = preparedValue :: PreparedDynamicBatch
	assert(
		preparedCurrentError(prepared, capability, false) == nil,
		"stale prepared dynamic batch at apply"
	)
	local entityApplied, entityAppliedError = EntitySlotService.ValidateAppliedCommitDependency(
		capability.entityReceipt,
		capability.entitySummary
	)
	assert(
		entityApplied,
		entityAppliedError or "prepared dynamic batch EntitySlot dependency was not applied"
	)
	local receiptCapability = assert(
		dynamicBatchReceiptCapabilities[capability.receipt],
		"prepared dynamic batch receipt capability disappeared"
	)
	assert(
		receiptCapability.status == "Pending"
			and receiptCapability.summary == capability.summary
			and receiptCapability.entityReceipt == capability.entityReceipt,
		"prepared dynamic batch receipt capability drifted"
	)

	-- The exact applied EntitySlot witness is now consumed. Every operation below
	-- is an assignment into a root/capability allocated by Prepare; no further
	-- validation, allocation, callback, or external service call is permitted.
	dynamicBindingsBySourceOrder = capability.nextBindings
	dynamicBindingRevision = capability.nextRevision
	for _, mutation in capability.mutations do
		mutation.capability.status = mutation.nextStatus
		mutation.capability.handler = mutation.nextHandler
	end
	activePreparedDynamicBatch = nil
	capability.status = "Applied"
	capability.applyValidated = false
	receiptCapability.status = "Applied"
	receiptCapability.appliedBindings = capability.nextBindings
	receiptCapability.appliedRevision = capability.nextRevision
	currentAppliedDynamicBatchReceipt = capability.receipt
	preparedDynamicBatchCapabilities[prepared] = nil
	return capability.receipt
end

function EntityFrameDispatcherService.AbortPreparedDynamicBatch(preparedValue: unknown): boolean
	local capability = select(1, currentPreparedCapability(preparedValue))
	if not capability then
		return false
	end
	local prepared = preparedValue :: PreparedDynamicBatch
	if preparedCurrentError(prepared, capability, true) ~= nil then
		return false
	end
	for _, mutation in capability.mutations do
		if mutation.newBinding then
			local bindingCapability = mutation.capability
			bindingCapability.status = "Aborted"
			bindingCapability.handler = nil
			dynamicBindingCapabilities[bindingCapability.binding] = nil
		end
	end
	activePreparedDynamicBatch = nil
	capability.status = "Aborted"
	capability.applyValidated = false
	local receiptCapability = dynamicBatchReceiptCapabilities[capability.receipt]
	if receiptCapability and receiptCapability.status == "Pending" then
		receiptCapability.status = "Aborted"
	end
	preparedDynamicBatchCapabilities[prepared] = nil
	return true
end

function EntityFrameDispatcherService.BindDynamic(
	registrationValue: unknown,
	declaredKindValue: unknown,
	handlerValue: unknown
): (DynamicBinding?, string?)
	if not started then
		return nil, "entity-frame-dispatcher-not-started"
	end
	if faulted then
		return nil, "entity-frame-dispatcher-faulted"
	end
	if activePreparedDynamicBatch ~= nil then
		return nil, "prepared-dynamic-batch-active"
	end
	if dynamicBindingRevision >= MAXIMUM_DYNAMIC_BINDING_REVISION then
		return nil, "dynamic-binding-revision-exhausted"
	end
	if not validDynamicKind(declaredKindValue) then
		return nil, "invalid-dynamic-entity-kind"
	end
	if type(handlerValue) ~= "function" then
		return nil, "invalid-dynamic-entity-handler"
	end
	if type(registrationValue) ~= "table" then
		return nil, "invalid-dynamic-entity-registration"
	end
	if getmetatable(registrationValue) ~= nil or not table.isfrozen(registrationValue :: table) then
		return nil, "invalid-dynamic-entity-registration"
	end
	local registration = registrationValue :: EntitySlotService.Registration
	if
		registration.kind ~= "World"
		or registration.domain ~= "World"
		or EntitySlotService.InspectSlot(registration.sourceOrder) ~= registration
	then
		return nil, "dynamic-entity-registration-not-exact-active-world"
	end
	local mapRegistration, mapError = mapRegistrationForExactWorld(registration)
	if mapError then
		return nil, mapError
	end
	if mapRegistration then
		return nil, "retained-map-registration-cannot-bind-as-dynamic"
	end
	if dynamicBindingsBySourceOrder[registration.sourceOrder] then
		return nil, "dynamic-entity-source-order-already-bound"
	end

	local binding: DynamicBinding = table.freeze({})
	local capability: DynamicBindingCapability = {
		binding = binding,
		status = "Active",
		registration = registration,
		sourceOrder = registration.sourceOrder,
		generation = registration.generation,
		bodyId = registration.bodyId,
		declaredKind = declaredKindValue :: string,
		handler = handlerValue :: DynamicHandler,
	}
	local nextBindings = table.clone(dynamicBindingsBySourceOrder)
	nextBindings[capability.sourceOrder] = binding
	table.freeze(nextBindings)
	retireAppliedDynamicBatchReceipt()
	dynamicBindingCapabilities[binding] = capability
	dynamicBindingsBySourceOrder = nextBindings
	dynamicBindingRevision = nextDynamicBindingRevision()
	return binding, nil
end

function EntityFrameDispatcherService.UnbindDynamic(bindingValue: unknown): (boolean, string?)
	if not started then
		return false, "entity-frame-dispatcher-not-started"
	end
	if faulted then
		return false, "entity-frame-dispatcher-faulted"
	end
	if activePreparedDynamicBatch ~= nil then
		return false, "prepared-dynamic-batch-active"
	end
	if dynamicBindingRevision >= MAXIMUM_DYNAMIC_BINDING_REVISION then
		return false, "dynamic-binding-revision-exhausted"
	end
	if EntitySlotService.GetTraversalUpperBound() == nil then
		return false, "entity-slot-transaction-active-or-unavailable"
	end
	local capability = currentDynamicBinding(bindingValue)
	if not capability then
		return false, "dynamic-entity-binding-not-current"
	end
	if EntitySlotService.InspectSlot(capability.sourceOrder) == capability.registration then
		return false, "dynamic-entity-registration-still-active"
	end
	local nextBindings = table.clone(dynamicBindingsBySourceOrder)
	nextBindings[capability.sourceOrder] = nil
	table.freeze(nextBindings)
	retireAppliedDynamicBatchReceipt()
	dynamicBindingsBySourceOrder = nextBindings
	capability.status = "Unbound"
	capability.handler = nil
	dynamicBindingRevision = nextDynamicBindingRevision()
	return true, nil
end

function EntityFrameDispatcherService.Run(frameValue: unknown)
	assert(started, "EntityFrameDispatcherService must be started before Run")
	assert(not faulted, "EntityFrameDispatcherService is permanently faulted")
	if running then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	if executionMode == "DynamicTail" then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	if executionMode == "Unclaimed" then
		executionMode = "Full"
	end
	assert(executionMode == "Full", "entity frame dispatcher Full mode is unavailable")

	configurationSealed = true
	running = true
	activeTraversalPhase = "Full"
	activeFaultCheckpoint = "Traversal"
	local succeeded = xpcall(function()
		assert(
			activePreparedDynamicBatch == nil,
			"prepared dynamic batch is active before Full traversal"
		)
		local summary = exactOpenFrameSummary(frameValue)
		assert(summary ~= nil, "entity-frame dispatcher requires the exact open frame")
		activeFrameStep = summary.toStep
		if completedFrameCount > 0 then
			assert(
				summary.clockRevision >= lastClockRevision
					and summary.toStep > lastFrameStep
					and summary.previousTimeMilliseconds >= lastFrameLevelTimeMilliseconds
					and summary.currentTimeMilliseconds > lastFrameLevelTimeMilliseconds,
				"entity-frame dispatcher received a duplicate or non-monotonic frame"
			)
		end

		local frame = frameValue :: AuthoritativeFrameService.Frame
		local cursor = EntityFrameTraversalRules.Begin()
		local counters: RunCounters = {
			client = 0,
			bodyQueue = 0,
			map = 0,
			dynamic = 0,
		}

		while true do
			assert(not faulted, "entity-frame dispatcher faulted during traversal")
			assert(
				activePreparedDynamicBatch == nil,
				"prepared dynamic batch is active during Full traversal"
			)
			assert(
				exactOpenFrameSummary(frame) == summary,
				"entity-frame dispatcher open-frame dependency became stale"
			)
			assert(
				EntityFrameTraversalRules.Inspect(cursor) == cursor,
				"entity-frame traversal cursor became stale"
			)
			local upperBound = EntitySlotService.GetTraversalUpperBound()
			assert(upperBound ~= nil, "entity-slot transaction is open during entity traversal")
			local sourceOrder = cursor.nextSourceOrder
			local registration: EntitySlotService.Registration? = nil
			local occupied: boolean? = nil
			if sourceOrder <= upperBound then
				registration = EntitySlotService.InspectSlot(sourceOrder)
				occupied = registration ~= nil
			end

			local nextCursor, step, advanceError =
				EntityFrameTraversalRules.Advance(cursor, upperBound, occupied)
			assert(
				nextCursor ~= nil and step ~= nil and advanceError == nil,
				"entity-frame traversal did not advance monotonically"
			)
			cursor = nextCursor

			if step.kind == "Complete" then
				assert(
					registration == nil and step.sourceOrder == nil,
					"entity-frame traversal completion retained a registration"
				)
				break
			end
			assert(
				step.sourceOrder == sourceOrder,
				"entity-frame traversal visited a mismatched numeric slot"
			)
			if step.kind == "Skip" then
				assert(registration == nil, "entity-frame traversal skipped an active registration")
				assert(
					dynamicBindingsBySourceOrder[sourceOrder] == nil,
					"entity-frame traversal skipped a stale dynamic binding"
				)
			else
				assert(step.kind == "Visit", "entity-frame traversal emitted an invalid step")
				assert(registration ~= nil, "entity-frame visit has no exact registration")
				dispatchRegistration(frame, summary, registration, counters)
			end
		end

		assert(
			exactOpenFrameSummary(frame) == summary,
			"entity-frame dispatcher frame closed before traversal completed"
		)
		assert(
			activePreparedDynamicBatch == nil,
			"prepared dynamic batch is active after Full traversal"
		)
		local finalCursor = EntityFrameTraversalRules.Inspect(cursor)
		assert(
			finalCursor ~= nil
				and finalCursor.complete
				and finalCursor.visitCount + finalCursor.skipCount == finalCursor.coveredThrough,
			"entity-frame traversal coverage witness is invalid"
		)
		validateAllDynamicBindings()

		completedFrameCount += 1
		lastClockRevision = summary.clockRevision
		lastFrameStep = summary.toStep
		lastFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
		lastCoveredThrough = finalCursor.coveredThrough
		lastTraversalStartSourceOrder = finalCursor.rangeStartSourceOrder
		lastVisitCount = finalCursor.visitCount
		lastSkipCount = finalCursor.skipCount
		lastUpperBoundReadCount = finalCursor.upperBoundReadCount
		lastClientDispatchCount = counters.client
		lastBodyQueueDispatchCount = counters.bodyQueue
		lastMapDispatchCount = counters.map
		lastDynamicDispatchCount = counters.dynamic
	end, discardCaughtDispatcherError)

	running = false
	if not succeeded then
		latchTerminalFault()
		endDispatchSite()
		activeTraversalPhase = nil
		activeFaultCheckpoint = nil
		activeFrameStep = nil
		error("entity frame dispatcher faulted", 0)
	end
	activeTraversalPhase = nil
	activeFaultCheckpoint = nil
	activeFrameStep = nil
end

function EntityFrameDispatcherService.RunPreMoverWorld(ownerValue: unknown, frameValue: unknown)
	assert(started, "EntityFrameDispatcherService must be started before RunPreMoverWorld")
	assert(not faulted, "EntityFrameDispatcherService is permanently faulted")
	if running or dynamicPrefixFrameSummary ~= nil then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	if executionMode ~= "DynamicTail" or not isCurrentDynamicTailOwner(ownerValue) then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	local firstMoverSourceOrder = assert(
		dynamicTailFirstMoverSourceOrder,
		"dynamic-tail first mover source order is unavailable"
	)

	running = true
	activeTraversalPhase = "PreMoverWorld"
	activeFaultCheckpoint = "Traversal"
	local succeeded = xpcall(function()
		assert(
			activePreparedDynamicBatch == nil,
			"prepared dynamic batch is active before pre-mover traversal"
		)
		assertDynamicTailPrefixCurrent()
		local summary = exactOpenFrameSummary(frameValue)
		assert(summary ~= nil, "pre-mover dispatcher requires the exact open frame")
		activeFrameStep = summary.toStep
		if completedFrameCount > 0 then
			assert(
				summary.toStep > lastFrameStep
					and summary.currentTimeMilliseconds > lastFrameLevelTimeMilliseconds,
				"pre-mover dispatcher received a duplicate or regressed frame"
			)
		end
		local frame = frameValue :: AuthoritativeFrameService.Frame
		local rangeEnd = firstMoverSourceOrder - 1
		if rangeEnd >= FIRST_WORLD_SOURCE_ORDER then
			local cursor = assert(EntityFrameTraversalRules.BeginAt(FIRST_WORLD_SOURCE_ORDER))
			while true do
				assert(
					activePreparedDynamicBatch == nil,
					"prepared batch leaked during pre-mover traversal"
				)
				assert(
					exactOpenFrameSummary(frame) == summary,
					"pre-mover frame dependency became stale"
				)
				local sourceOrder = cursor.nextSourceOrder
				local registration = if sourceOrder <= rangeEnd
					then EntitySlotService.InspectSlot(sourceOrder)
					else nil
				local occupied = if sourceOrder <= rangeEnd then registration ~= nil else nil
				local nextCursor, step, advanceError =
					EntityFrameTraversalRules.Advance(cursor, rangeEnd, occupied)
				assert(nextCursor and step and not advanceError, "pre-mover cursor did not advance")
				cursor = nextCursor
				if step.kind == "Complete" then
					break
				elseif step.kind == "Skip" then
					assert(
						dynamicBindingsBySourceOrder[sourceOrder] == nil,
						"pre-mover gap retained a binding"
					)
				else
					local exactRegistration =
						assert(registration, "pre-mover visit lost registration")
					beginVisitSite(exactRegistration)
					if exactRegistration.kind == "BodyQueue" then
						local handler = bodyQueueHandler
						if handler then
							beginDispatchSite("BodyQueue", exactRegistration)
							handler(frame, summary, exactRegistration)
							beginDispatchPostconditions()
							assertHandlerPostconditions(frame, summary)
							endDispatchSite()
						else
							endDispatchSite()
						end
					else
						local mapRegistration, mapError =
							mapRegistrationForExactWorld(exactRegistration)
						assert(mapError == nil, "pre-mover map classification is unavailable")
						if mapRegistration then
							local handler = mapHandlers[mapRegistration.kind]
							if handler then
								beginDispatchSite(mapRegistration.kind, exactRegistration)
								handler(frame, summary, mapRegistration)
								beginDispatchPostconditions()
								assertHandlerPostconditions(frame, summary)
								endDispatchSite()
							else
								endDispatchSite()
							end
						else
							local counters: RunCounters = {
								client = 0,
								bodyQueue = 0,
								map = 0,
								dynamic = 0,
							}
							dispatchDynamicTailRegistration(
								frame,
								summary,
								exactRegistration,
								counters
							)
						end
					end
				end
			end
		end
		assertDynamicTailPrefixCurrent()
		assert(exactOpenFrameSummary(frame) == summary, "pre-mover frame closed early")
		dynamicPrefixFrameSummary = summary
	end, discardCaughtDispatcherError)
	running = false
	if not succeeded then
		latchTerminalFault()
		endDispatchSite()
		activeTraversalPhase = nil
		activeFaultCheckpoint = nil
		activeFrameStep = nil
		error("entity frame dispatcher faulted", 0)
	end
	activeTraversalPhase = nil
	activeFaultCheckpoint = nil
	activeFrameStep = nil
end

function EntityFrameDispatcherService.RunDynamicTail(ownerValue: unknown, frameValue: unknown)
	assert(started, "EntityFrameDispatcherService must be started before RunDynamicTail")
	assert(not faulted, "EntityFrameDispatcherService is permanently faulted")
	if running then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	if executionMode ~= "DynamicTail" or not isCurrentDynamicTailOwner(ownerValue) then
		latchTerminalFault()
		error("entity frame dispatcher faulted", 0)
	end
	local firstDynamicSourceOrder = dynamicTailFirstSourceOrder
	assert(firstDynamicSourceOrder ~= nil, "dynamic-tail first source order is unavailable")

	running = true
	activeTraversalPhase = "DynamicTail"
	activeFaultCheckpoint = "Traversal"
	local succeeded = xpcall(function()
		assert(
			activePreparedDynamicBatch == nil,
			"prepared dynamic batch is active before dynamic-tail traversal"
		)
		assertDynamicTailPrefixCurrent()
		local summary = exactOpenFrameSummary(frameValue)
		assert(summary ~= nil, "dynamic-tail dispatcher requires the exact open frame")
		activeFrameStep = summary.toStep
		assert(
			dynamicPrefixFrameSummary == summary,
			"dynamic-tail dispatcher requires this frame's pre-mover traversal"
		)
		if completedFrameCount > 0 then
			assert(
				summary.clockRevision >= lastClockRevision
					and summary.toStep > lastFrameStep
					and summary.previousTimeMilliseconds >= lastFrameLevelTimeMilliseconds
					and summary.currentTimeMilliseconds > lastFrameLevelTimeMilliseconds,
				"dynamic-tail dispatcher received a duplicate or non-monotonic frame"
			)
		end

		local frame = frameValue :: AuthoritativeFrameService.Frame
		local cursor, beginError = EntityFrameTraversalRules.BeginAt(firstDynamicSourceOrder)
		assert(cursor ~= nil, beginError or "dynamic-tail world traversal could not begin")
		local counters: RunCounters = {
			client = 0,
			bodyQueue = 0,
			map = 0,
			dynamic = 0,
		}

		while true do
			assert(not faulted, "entity-frame dispatcher faulted during dynamic-tail traversal")
			assert(
				activePreparedDynamicBatch == nil,
				"prepared dynamic batch is active during dynamic-tail traversal"
			)
			assert(
				exactOpenFrameSummary(frame) == summary,
				"dynamic-tail dispatcher open-frame dependency became stale"
			)
			assert(
				EntityFrameTraversalRules.Inspect(cursor) == cursor,
				"dynamic-tail traversal cursor became stale"
			)
			local upperBound = EntitySlotService.GetTraversalUpperBound()
			assert(
				upperBound ~= nil,
				"entity-slot transaction is open during dynamic-tail traversal"
			)
			local sourceOrder = cursor.nextSourceOrder
			local registration: EntitySlotService.Registration? = nil
			local occupied: boolean? = nil
			if sourceOrder <= upperBound then
				registration = EntitySlotService.InspectSlot(sourceOrder)
				occupied = registration ~= nil
			end

			local nextCursor, step, advanceError =
				EntityFrameTraversalRules.Advance(cursor, upperBound, occupied)
			assert(
				nextCursor ~= nil and step ~= nil and advanceError == nil,
				"dynamic-tail traversal did not advance monotonically"
			)
			cursor = nextCursor

			if step.kind == "Complete" then
				assert(
					registration == nil and step.sourceOrder == nil,
					"dynamic-tail traversal completion retained a registration"
				)
				break
			end
			assert(
				step.sourceOrder == sourceOrder and sourceOrder >= firstDynamicSourceOrder,
				"dynamic-tail world traversal visited a mismatched numeric slot"
			)
			if step.kind == "Skip" then
				assert(registration == nil, "dynamic-tail traversal skipped an active registration")
				assert(
					dynamicBindingsBySourceOrder[sourceOrder] == nil,
					"dynamic-tail traversal skipped a stale dynamic binding"
				)
			else
				assert(step.kind == "Visit", "dynamic-tail traversal emitted an invalid step")
				assert(registration ~= nil, "dynamic-tail visit has no exact registration")
				local mapRegistration, mapError = mapRegistrationForExactWorld(registration)
				assert(mapError == nil, "dynamic-tail map classification is unavailable")
				if mapRegistration == nil then
					dispatchDynamicTailRegistration(frame, summary, registration, counters)
				end
			end
		end

		assert(
			activePreparedDynamicBatch == nil,
			"prepared dynamic batch is active after dynamic-tail traversal"
		)
		assertDynamicTailPrefixCurrent()
		assert(
			exactOpenFrameSummary(frame) == summary,
			"dynamic-tail dispatcher frame closed before traversal completed"
		)
		local finalCursor = EntityFrameTraversalRules.Inspect(cursor)
		assert(
			finalCursor ~= nil
				and finalCursor.complete
				and finalCursor.rangeStartSourceOrder == firstDynamicSourceOrder
				and finalCursor.visitCount + finalCursor.skipCount
					== finalCursor.coveredThrough - finalCursor.rangeStartSourceOrder + 1,
			"dynamic-tail traversal suffix coverage witness is invalid"
		)
		assert(
			counters.client == 0 and counters.bodyQueue == 0 and counters.map == 0,
			"dynamic-tail traversal dispatched a non-dynamic entity"
		)
		validateAllDynamicBindings()

		completedFrameCount += 1
		lastClockRevision = summary.clockRevision
		lastFrameStep = summary.toStep
		lastFrameLevelTimeMilliseconds = summary.currentTimeMilliseconds
		lastCoveredThrough = finalCursor.coveredThrough
		lastTraversalStartSourceOrder = finalCursor.rangeStartSourceOrder
		lastVisitCount = finalCursor.visitCount
		lastSkipCount = finalCursor.skipCount
		lastUpperBoundReadCount = finalCursor.upperBoundReadCount
		lastClientDispatchCount = 0
		lastBodyQueueDispatchCount = 0
		lastMapDispatchCount = 0
		lastDynamicDispatchCount = counters.dynamic
		dynamicPrefixFrameSummary = nil
	end, discardCaughtDispatcherError)

	running = false
	if not succeeded then
		latchTerminalFault()
		endDispatchSite()
		activeTraversalPhase = nil
		activeFaultCheckpoint = nil
		activeFrameStep = nil
		error("entity frame dispatcher faulted", 0)
	end
	activeTraversalPhase = nil
	activeFaultCheckpoint = nil
	activeFrameStep = nil
end

function EntityFrameDispatcherService.GetDebugSnapshot(): DebugSnapshot
	local dynamicBindingCount = 0
	for _, binding in dynamicBindingsBySourceOrder do
		if currentDynamicBinding(binding) then
			dynamicBindingCount += 1
		end
	end
	local mapHandlerCount = 0
	for _ in mapHandlers do
		mapHandlerCount += 1
	end
	return table.freeze({
		started = started,
		faulted = faulted,
		running = running,
		configurationSealed = configurationSealed,
		completedFrameCount = completedFrameCount,
		lastClockRevision = lastClockRevision,
		lastFrameStep = lastFrameStep,
		lastFrameLevelTimeMilliseconds = lastFrameLevelTimeMilliseconds,
		lastCoveredThrough = lastCoveredThrough,
		lastTraversalStartSourceOrder = lastTraversalStartSourceOrder,
		lastVisitCount = lastVisitCount,
		lastSkipCount = lastSkipCount,
		lastUpperBoundReadCount = lastUpperBoundReadCount,
		lastClientDispatchCount = lastClientDispatchCount,
		lastBodyQueueDispatchCount = lastBodyQueueDispatchCount,
		lastMapDispatchCount = lastMapDispatchCount,
		lastDynamicDispatchCount = lastDynamicDispatchCount,
		dynamicBindingCount = dynamicBindingCount,
		dynamicBindingRevision = dynamicBindingRevision,
		activePreparedDynamicBatch = activePreparedDynamicBatch ~= nil,
		executionMode = executionMode,
		dynamicTailOwnerClaimed = dynamicTailOwner ~= nil,
		dynamicTailMapPrefixCount = if dynamicTailMapPrefix then #dynamicTailMapPrefix else 0,
		dynamicTailMapPrefixEndSourceOrder = dynamicTailMapPrefixEndSourceOrder,
		dynamicTailFirstSourceOrder = dynamicTailFirstSourceOrder,
		dynamicTailFirstMoverSourceOrder = dynamicTailFirstMoverSourceOrder,
		dynamicTailValidatedMapRegistrationRevision = dynamicTailValidatedMapRegistrationRevision,
		dynamicPrefixFrameOpen = dynamicPrefixFrameSummary ~= nil,
		dynamicTailPrefixCurrent = if executionMode == "DynamicTail"
			then dynamicTailPrefixCurrentError() == nil
			else false,
		clientHandlerConfigured = clientHandler ~= nil,
		bodyQueueHandlerConfigured = bodyQueueHandler ~= nil,
		mapHandlerCount = mapHandlerCount,
		faultPhase = faultPhase,
		faultCheckpoint = faultCheckpoint,
		faultKind = faultKind,
		faultSourceOrder = faultSourceOrder,
		faultGeneration = faultGeneration,
		faultFrameStep = faultFrameStep,
	})
end

EntityFrameDispatcherService.MaximumDynamicKindLength = MAXIMUM_DYNAMIC_KIND_LENGTH
EntityFrameDispatcherService.FirstDynamicSourceOrderWithEmptyMap = FIRST_MAP_SOURCE_ORDER

return table.freeze(EntityFrameDispatcherService)
