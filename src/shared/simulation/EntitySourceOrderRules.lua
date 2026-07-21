--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure entity-slot ordering translated from Quake III Arena:
  code/game/q_shared.h (MAX_CLIENTS, MAX_GENTITIES, ENTITYNUM_* limits)
  code/game/g_local.h (BODY_QUEUE_SIZE)
  code/game/g_client.c (InitBodyQue)
  code/game/g_utils.c (G_InitGentity, G_Spawn, G_FreeEntity)
  code/game/g_main.c (G_InitGame ordering and G_RunFrame traversal)

Luau arrays are one-based, so sourceOrder is entityNum + 1. Opaque immutable
lineages, explicit generations, active-lease validation, and staged allocator
transactions are the Roblox Luau port authority adaptations. They prevent a stale,
released, forged, or cross-match entity lease from entering a mover
consequence transaction when a Q3 entity slot is reused.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type Domain = "Client" | "World"

export type Lease = {
	read domain: Domain,
	read sourceOrder: number,
	read generation: number,
}

export type State = {
	read revision: number,
	read maximumClients: number,
	read highestWorldSourceOrder: number,
	read activeClientCount: number,
	read activeWorldCount: number,
	read levelTimeMilliseconds: number,
}

export type Transaction = {
	read baseRevision: number,
	read generation: number,
	read highestWorldSourceOrder: number,
	read activeClientCount: number,
	read activeWorldCount: number,
	read levelTimeMilliseconds: number,
}

export type PreparedCommit = {}

export type Operation =
	{ read kind: "AllocateClient" }
	| { read kind: "ReleaseClient", read lease: Lease }
	| { read kind: "AllocateWorld", read nowMilliseconds: number }
	| { read kind: "ReleaseWorld", read lease: Lease, read nowMilliseconds: number }

type Slot = {
	inUse: boolean,
	generation: number,
	freeTimeMilliseconds: number,
}

type StateData = {
	lineage: unknown,
	revision: number,
	maximumClients: number,
	levelStartTimeMilliseconds: number,
	levelTimeMilliseconds: number,
	highestWorldSourceOrder: number,
	activeClientCount: number,
	activeWorldCount: number,
	clientSlots: { [number]: Slot },
	worldSlots: { [number]: Slot },
}

type StateCapability = {
	current: boolean,
	data: StateData,
}

type LeaseStatus = "Active" | "Pending" | "Released" | "Aborted"

type LeaseCapability = {
	lineage: unknown,
	domain: Domain,
	sourceOrder: number,
	generation: number,
	status: LeaseStatus,
	transactionIdentity: unknown?,
}

type TransactionRoot = {
	identity: unknown,
	baseState: State,
	baseCapability: StateCapability,
	pendingLeases: { LeaseCapability },
	open: boolean,
	prepared: PreparedCommit?,
}

type TransactionData = {
	root: TransactionRoot,
	generation: number,
	working: StateData,
	releasedActiveLeases: { [table]: LeaseCapability },
}

type TransactionCapability = {
	current: boolean,
	data: TransactionData,
}

type PreparedStatus = "Prepared" | "Applied" | "Aborted"
type LeaseMutation = {
	lease: LeaseCapability,
	expectedStatus: LeaseStatus,
	expectedTransactionIdentity: unknown?,
	nextStatus: LeaseStatus,
	nextTransactionIdentity: unknown?,
}
type PreparedCapability = {
	transaction: Transaction,
	transactionCapability: TransactionCapability,
	nextState: State,
	nextStateCapability: StateCapability,
	leaseMutations: { LeaseMutation },
	status: PreparedStatus,
	applyValidated: boolean,
}

local EntitySourceOrderRules = {}

local MAXIMUM_CLIENTS = 64
local MAXIMUM_GENTITIES = 1024
local ENTITYNUM_NONE = MAXIMUM_GENTITIES - 1
local ENTITYNUM_WORLD = MAXIMUM_GENTITIES - 2
local ENTITYNUM_MAX_NORMAL = ENTITYNUM_WORLD
local FIRST_WORLD_ENTITY_NUMBER = MAXIMUM_CLIENTS
local FIRST_WORLD_SOURCE_ORDER = FIRST_WORLD_ENTITY_NUMBER + 1
local MAXIMUM_NORMAL_SOURCE_ORDER = ENTITYNUM_MAX_NORMAL
local BODY_QUEUE_SIZE = 8
local RECENT_FREE_REUSE_DELAY_MILLISECONDS = 1000
local STARTUP_REUSE_GRACE_MILLISECONDS = 2000
local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_GENERATION = 2_147_483_647
local MAXIMUM_REVISION = 2_147_483_647
local MAXIMUM_TRANSACTION_GENERATION = 2_147_483_647
local MAXIMUM_BODY_PREFIX_LENGTH = 32

local stateCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: StateCapability }
local leaseCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: LeaseCapability }
local transactionCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: TransactionCapability }
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedCommit]: PreparedCapability,
}

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function denseArrayLength(value: unknown): (number?, string?)
	if type(value) ~= "table" then
		return nil, "authored-orders-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "authored-orders-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_NORMAL_SOURCE_ORDER or maximumIndex > MAXIMUM_NORMAL_SOURCE_ORDER then
			return nil, "too-many-authored-orders"
		end
	end
	if maximumIndex ~= count then
		return nil, "authored-orders-not-dense-array"
	end
	return count, nil
end

local function copySlots(source: { [number]: Slot }): { [number]: Slot }
	local output: { [number]: Slot } = {}
	for sourceOrder, slot in source do
		output[sourceOrder] = {
			inUse = slot.inUse,
			generation = slot.generation,
			freeTimeMilliseconds = slot.freeTimeMilliseconds,
		}
	end
	return output
end

local function copyData(source: StateData): StateData
	return {
		lineage = source.lineage,
		revision = source.revision,
		maximumClients = source.maximumClients,
		levelStartTimeMilliseconds = source.levelStartTimeMilliseconds,
		levelTimeMilliseconds = source.levelTimeMilliseconds,
		highestWorldSourceOrder = source.highestWorldSourceOrder,
		activeClientCount = source.activeClientCount,
		activeWorldCount = source.activeWorldCount,
		clientSlots = copySlots(source.clientSlots),
		worldSlots = copySlots(source.worldSlots),
	}
end

local function copyReleasedLeases(source: { [table]: LeaseCapability }): { [table]: LeaseCapability }
	return table.clone(source)
end

local function countActive(slots: { [number]: Slot }): number
	local count = 0
	for _, slot in slots do
		if slot.inUse then
			count += 1
		end
	end
	return count
end

local function countCertificatesWithinBounds(data: StateData): boolean
	local worldCapacity = math.max(0, data.highestWorldSourceOrder - FIRST_WORLD_SOURCE_ORDER + 1)
	return isIntegerInRange(data.activeClientCount, 0, data.maximumClients)
		and isIntegerInRange(data.activeWorldCount, 0, worldCapacity)
end

local function nextRevision(revision: number): number
	assert(revision < MAXIMUM_REVISION, "entity source-order revision exhausted")
	return revision + 1
end

local function makeState(data: StateData): State
	assert(countCertificatesWithinBounds(data), "entity source-order count certificate out of bounds")
	assert(
		data.activeClientCount == countActive(data.clientSlots),
		"entity source-order client count certificate drifted"
	)
	assert(data.activeWorldCount == countActive(data.worldSlots), "entity source-order world count certificate drifted")
	local state: State = table.freeze({
		revision = data.revision,
		maximumClients = data.maximumClients,
		highestWorldSourceOrder = data.highestWorldSourceOrder,
		activeClientCount = data.activeClientCount,
		activeWorldCount = data.activeWorldCount,
		levelTimeMilliseconds = data.levelTimeMilliseconds,
	})
	stateCapabilities[state :: table] = {
		current = true,
		data = data,
	}
	return state
end

local function currentState(value: unknown): (StateCapability?, string?)
	if type(value) ~= "table" then
		return nil, "state-not-capability"
	end
	local capability = stateCapabilities[value :: table]
	if not capability then
		return nil, "state-not-capability"
	end
	if not capability.current then
		return nil, "state-not-current"
	end
	local exposed = value :: { [unknown]: unknown }
	local data = capability.data
	if
		not countCertificatesWithinBounds(data)
		or exposed.revision ~= data.revision
		or exposed.maximumClients ~= data.maximumClients
		or exposed.highestWorldSourceOrder ~= data.highestWorldSourceOrder
		or exposed.activeClientCount ~= data.activeClientCount
		or exposed.activeWorldCount ~= data.activeWorldCount
		or exposed.levelTimeMilliseconds ~= data.levelTimeMilliseconds
	then
		return nil, "state-capability-mismatch"
	end
	return capability, nil
end

local function makeLease(
	lineage: unknown,
	domain: Domain,
	sourceOrder: number,
	generation: number,
	status: LeaseStatus,
	transactionIdentity: unknown?
): (Lease, LeaseCapability)
	local lease: Lease = table.freeze({
		domain = domain,
		sourceOrder = sourceOrder,
		generation = generation,
	})
	local capability: LeaseCapability = {
		lineage = lineage,
		domain = domain,
		sourceOrder = sourceOrder,
		generation = generation,
		status = status,
		transactionIdentity = transactionIdentity,
	}
	leaseCapabilities[lease :: table] = capability
	return lease, capability
end

local function inspectLeaseCapability(value: unknown): (LeaseCapability?, string?)
	if type(value) ~= "table" then
		return nil, "lease-not-capability"
	end
	local capability = leaseCapabilities[value :: table]
	if not capability then
		return nil, "lease-not-capability"
	end
	local exposed = value :: { [unknown]: unknown }
	if
		exposed.domain ~= capability.domain
		or exposed.sourceOrder ~= capability.sourceOrder
		or exposed.generation ~= capability.generation
	then
		return nil, "lease-capability-mismatch"
	end
	return capability, nil
end

local function slotForLease(data: StateData, lease: LeaseCapability): Slot?
	if lease.domain == "Client" then
		return data.clientSlots[lease.sourceOrder]
	end
	return data.worldSlots[lease.sourceOrder]
end

local function validateLeaseForData(
	data: StateData,
	lease: LeaseCapability,
	expectedDomain: Domain?,
	transactionIdentity: unknown?
): string?
	if lease.lineage ~= data.lineage then
		return "lease-lineage-mismatch"
	end
	if expectedDomain and lease.domain ~= expectedDomain then
		return "lease-domain-mismatch"
	end
	if lease.status == "Pending" then
		if transactionIdentity == nil or lease.transactionIdentity ~= transactionIdentity then
			return "lease-transaction-mismatch"
		end
	elseif lease.status ~= "Active" then
		return "lease-not-active"
	end
	local slot = slotForLease(data, lease)
	if not slot or not slot.inUse or slot.generation ~= lease.generation then
		return if lease.domain == "Client" then "client-lease-not-current" else "world-lease-not-current"
	end
	return nil
end

local function makeTransaction(data: TransactionData): Transaction
	local working = data.working
	assert(countCertificatesWithinBounds(working), "entity source-order transaction count certificate out of bounds")
	assert(
		working.activeClientCount == countActive(working.clientSlots),
		"entity source-order transaction client count certificate drifted"
	)
	assert(
		working.activeWorldCount == countActive(working.worldSlots),
		"entity source-order transaction world count certificate drifted"
	)
	local transaction: Transaction = table.freeze({
		baseRevision = data.root.baseCapability.data.revision,
		generation = data.generation,
		highestWorldSourceOrder = working.highestWorldSourceOrder,
		activeClientCount = working.activeClientCount,
		activeWorldCount = working.activeWorldCount,
		levelTimeMilliseconds = working.levelTimeMilliseconds,
	})
	transactionCapabilities[transaction :: table] = {
		current = true,
		data = data,
	}
	return transaction
end

local function inspectCurrentTransaction(value: unknown, allowPrepared: boolean): (TransactionCapability?, string?)
	if type(value) ~= "table" then
		return nil, "transaction-not-capability"
	end
	local capability = transactionCapabilities[value :: table]
	if not capability then
		return nil, "transaction-not-capability"
	end
	if
		not capability.current
		or not capability.data.root.open
		or (not allowPrepared and capability.data.root.prepared ~= nil)
	then
		return nil, "transaction-not-current"
	end
	local exposed = value :: { [unknown]: unknown }
	local data = capability.data
	local working = data.working
	if
		not countCertificatesWithinBounds(working)
		or exposed.baseRevision ~= data.root.baseCapability.data.revision
		or exposed.generation ~= data.generation
		or exposed.highestWorldSourceOrder ~= working.highestWorldSourceOrder
		or exposed.activeClientCount ~= working.activeClientCount
		or exposed.activeWorldCount ~= working.activeWorldCount
		or exposed.levelTimeMilliseconds ~= working.levelTimeMilliseconds
	then
		return nil, "transaction-capability-mismatch"
	end
	return capability, nil
end

local function currentTransaction(value: unknown): (TransactionCapability?, string?)
	return inspectCurrentTransaction(value, false)
end

local function currentTransactionWithBase(value: unknown): (TransactionCapability?, string?)
	local capability, transactionError = currentTransaction(value)
	if not capability then
		return nil, transactionError
	end
	if not capability.data.root.baseCapability.current then
		return nil, "transaction-base-state-not-current"
	end
	return capability, nil
end

local function validTime(value: unknown, minimum: number): boolean
	return isIntegerInRange(value, minimum, MAXIMUM_TIME_MILLISECONDS)
end

local function operationTime(data: StateData, value: unknown, invalidError: string): (number?, string?)
	if not validTime(value, data.levelStartTimeMilliseconds) then
		return nil, invalidError
	end
	local milliseconds = value :: number
	if milliseconds < data.levelTimeMilliseconds then
		return nil, "non-monotonic-level-time"
	end
	return milliseconds, nil
end

local function allocateSlot(slot: Slot): number
	assert(not slot.inUse, "entity source-order allocated an occupied slot")
	assert(slot.generation < MAXIMUM_GENERATION, "entity source-order generation exhausted")
	slot.inUse = true
	slot.generation += 1
	return slot.generation
end

local function allocateClientData(data: StateData): (number?, number?, string?)
	local selected: number? = nil
	for sourceOrder = 1, data.maximumClients do
		if not data.clientSlots[sourceOrder].inUse then
			selected = sourceOrder
			break
		end
	end
	if not selected then
		return nil, nil, "client-slots-exhausted"
	end
	assert(data.activeClientCount < data.maximumClients, "client count certificate overflow")
	local generation = allocateSlot(data.clientSlots[selected])
	data.activeClientCount += 1
	return selected, generation, nil
end

local function recentlyFreed(data: StateData, slot: Slot, nowMilliseconds: number): boolean
	return slot.freeTimeMilliseconds > data.levelStartTimeMilliseconds + STARTUP_REUSE_GRACE_MILLISECONDS
		and nowMilliseconds - slot.freeTimeMilliseconds < RECENT_FREE_REUSE_DELAY_MILLISECONDS
end

local function allocateWorldData(data: StateData, nowMillisecondsValue: unknown): (number?, number?, string?)
	local nowMilliseconds, timeError = operationTime(data, nowMillisecondsValue, "invalid-allocation-time")
	if not nowMilliseconds then
		return nil, nil, timeError
	end
	local selected: number? = nil
	for sourceOrder = FIRST_WORLD_SOURCE_ORDER, data.highestWorldSourceOrder do
		local slot = data.worldSlots[sourceOrder]
		if slot and not slot.inUse and not recentlyFreed(data, slot, nowMilliseconds) then
			selected = sourceOrder
			break
		end
	end
	if not selected and data.highestWorldSourceOrder < MAXIMUM_NORMAL_SOURCE_ORDER then
		selected = data.highestWorldSourceOrder + 1
		data.highestWorldSourceOrder = selected
		data.worldSlots[selected] = {
			inUse = false,
			generation = 0,
			freeTimeMilliseconds = 0,
		}
	end
	-- G_Spawn has a nominal two-pass `force` loop, but its second pass is gated
	-- on i == MAX_GENTITIES while normal allocation errors at
	-- ENTITYNUM_MAX_NORMAL. With the pinned constants (1024 and 1022), a full
	-- normal domain containing only recently freed slots therefore fails.
	if not selected then
		return nil, nil, "world-slots-exhausted"
	end
	local worldCapacity = data.highestWorldSourceOrder - FIRST_WORLD_SOURCE_ORDER + 1
	assert(data.activeWorldCount < worldCapacity, "world count certificate overflow")
	data.levelTimeMilliseconds = nowMilliseconds
	local generation = allocateSlot(data.worldSlots[selected])
	data.activeWorldCount += 1
	return selected, generation, nil
end

local function releaseClientData(data: StateData, lease: LeaseCapability): string?
	local validationError = validateLeaseForData(data, lease, "Client", nil)
	if validationError then
		return validationError
	end
	assert(data.activeClientCount > 0, "client count certificate underflow")
	data.clientSlots[lease.sourceOrder].inUse = false
	data.activeClientCount -= 1
	return nil
end

local function releaseWorldData(
	data: StateData,
	lease: LeaseCapability,
	nowMillisecondsValue: unknown,
	transactionIdentity: unknown?
): string?
	local nowMilliseconds, timeError = operationTime(data, nowMillisecondsValue, "invalid-free-time")
	if not nowMilliseconds then
		return timeError
	end
	local validationError = validateLeaseForData(data, lease, "World", transactionIdentity)
	if validationError then
		return validationError
	end
	assert(data.activeWorldCount > 0, "world count certificate underflow")
	local slot = data.worldSlots[lease.sourceOrder]
	slot.inUse = false
	data.activeWorldCount -= 1
	slot.freeTimeMilliseconds = nowMilliseconds
	data.levelTimeMilliseconds = nowMilliseconds
	return nil
end

local function finishDirectMutation(
	capability: StateCapability,
	data: StateData,
	releasedLease: LeaseCapability?
): State
	data.revision = nextRevision(data.revision)
	local nextState = makeState(data)
	capability.current = false
	if releasedLease then
		releasedLease.status = "Released"
	end
	return nextState
end

local function exactOperationKeys(operation: { [unknown]: unknown }, allowed: { [string]: boolean }): boolean
	for key in operation do
		if type(key) ~= "string" or not allowed[key] then
			return false
		end
	end
	for key in allowed do
		if operation[key] == nil then
			return false
		end
	end
	return true
end

function EntitySourceOrderRules.Create(
	maximumClientsValue: unknown,
	authoredWorldSourceOrdersValue: unknown,
	levelStartTimeMillisecondsValue: unknown
): (State?, string?)
	if not isIntegerInRange(maximumClientsValue, 1, MAXIMUM_CLIENTS) then
		return nil, "invalid-maximum-clients"
	end
	if not validTime(levelStartTimeMillisecondsValue, 0) then
		return nil, "invalid-level-start-time"
	end
	local authoredCount, authoredError = denseArrayLength(authoredWorldSourceOrdersValue)
	if not authoredCount then
		return nil, authoredError
	end
	local authored = authoredWorldSourceOrdersValue :: { unknown }
	local observed: { [number]: boolean } = {}
	local previous = FIRST_WORLD_SOURCE_ORDER - 1
	local highest = FIRST_WORLD_SOURCE_ORDER - 1
	for index = 1, authoredCount do
		local sourceOrder = authored[index]
		if not isIntegerInRange(sourceOrder, FIRST_WORLD_SOURCE_ORDER, MAXIMUM_NORMAL_SOURCE_ORDER) then
			return nil, string.format("authored-order-%d:out-of-world-domain", index)
		end
		local order = sourceOrder :: number
		if order <= previous then
			return nil, string.format("authored-order-%d:not-strictly-ordered", index)
		end
		if observed[order] then
			return nil, string.format("authored-order-%d:duplicate", index)
		end
		observed[order] = true
		previous = order
		highest = order
	end

	local clientSlots: { [number]: Slot } = {}
	for sourceOrder = 1, maximumClientsValue :: number do
		clientSlots[sourceOrder] = {
			inUse = false,
			generation = 0,
			freeTimeMilliseconds = 0,
		}
	end
	local worldSlots: { [number]: Slot } = {}
	for sourceOrder = FIRST_WORLD_SOURCE_ORDER, highest do
		worldSlots[sourceOrder] = {
			inUse = observed[sourceOrder] == true,
			generation = if observed[sourceOrder] then 1 else 0,
			freeTimeMilliseconds = 0,
		}
	end
	local startTime = levelStartTimeMillisecondsValue :: number
	return makeState({
		lineage = table.freeze({}),
		revision = 1,
		maximumClients = maximumClientsValue :: number,
		levelStartTimeMilliseconds = startTime,
		levelTimeMilliseconds = startTime,
		highestWorldSourceOrder = highest,
		activeClientCount = 0,
		activeWorldCount = authoredCount,
		clientSlots = clientSlots,
		worldSlots = worldSlots,
	}),
		nil
end

function EntitySourceOrderRules.AllocateClient(stateValue: unknown): (State?, Lease?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, nil, stateError
	end
	local data = copyData(capability.data)
	local sourceOrder, generation, allocationError = allocateClientData(data)
	if not sourceOrder or not generation then
		return nil, nil, allocationError
	end
	local lease = makeLease(data.lineage, "Client", sourceOrder, generation, "Active", nil)
	return finishDirectMutation(capability, data, nil), lease, nil
end

function EntitySourceOrderRules.ReleaseClient(stateValue: unknown, leaseValue: unknown): (State?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, stateError
	end
	local lease, leaseError = inspectLeaseCapability(leaseValue)
	if not lease then
		return nil, leaseError
	end
	local data = copyData(capability.data)
	local releaseError = releaseClientData(data, lease)
	if releaseError then
		return nil, releaseError
	end
	return finishDirectMutation(capability, data, lease), nil
end

function EntitySourceOrderRules.AllocateWorld(
	stateValue: unknown,
	nowMillisecondsValue: unknown
): (State?, Lease?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, nil, stateError
	end
	local data = copyData(capability.data)
	local sourceOrder, generation, allocationError = allocateWorldData(data, nowMillisecondsValue)
	if not sourceOrder or not generation then
		return nil, nil, allocationError
	end
	local lease = makeLease(data.lineage, "World", sourceOrder, generation, "Active", nil)
	return finishDirectMutation(capability, data, nil), lease, nil
end

function EntitySourceOrderRules.ReleaseWorld(
	stateValue: unknown,
	leaseValue: unknown,
	nowMillisecondsValue: unknown
): (State?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, stateError
	end
	local lease, leaseError = inspectLeaseCapability(leaseValue)
	if not lease then
		return nil, leaseError
	end
	local data = copyData(capability.data)
	local releaseError = releaseWorldData(data, lease, nowMillisecondsValue, nil)
	if releaseError then
		return nil, releaseError
	end
	return finishDirectMutation(capability, data, lease), nil
end

function EntitySourceOrderRules.Begin(stateValue: unknown): (Transaction?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, stateError
	end
	local root: TransactionRoot = {
		identity = table.freeze({}),
		baseState = stateValue :: State,
		baseCapability = capability,
		pendingLeases = {},
		open = true,
		prepared = nil,
	}
	return makeTransaction({
		root = root,
		generation = 1,
		working = copyData(capability.data),
		releasedActiveLeases = {},
	}),
		nil
end

function EntitySourceOrderRules.Stage(
	transactionValue: unknown,
	operationValue: unknown
): (Transaction?, Lease?, string?)
	local capability, transactionError = currentTransactionWithBase(transactionValue)
	if not capability then
		return nil, nil, transactionError
	end
	if capability.data.generation >= MAXIMUM_TRANSACTION_GENERATION then
		return nil, nil, "transaction-generation-exhausted"
	end
	if type(operationValue) ~= "table" then
		return nil, nil, "operation-not-table"
	end
	local operation = operationValue :: { [unknown]: unknown }
	local kind = operation.kind
	local data = copyData(capability.data.working)
	local releasedActiveLeases = copyReleasedLeases(capability.data.releasedActiveLeases)
	local producedLease: Lease? = nil

	if kind == "AllocateClient" then
		if not exactOperationKeys(operation, { kind = true }) then
			return nil, nil, "allocate-client-operation-malformed"
		end
		local sourceOrder, generation, allocationError = allocateClientData(data)
		if not sourceOrder or not generation then
			return nil, nil, allocationError
		end
		local lease, leaseCapability =
			makeLease(data.lineage, "Client", sourceOrder, generation, "Pending", capability.data.root.identity)
		producedLease = lease
		table.insert(capability.data.root.pendingLeases, leaseCapability)
	elseif kind == "ReleaseClient" then
		if not exactOperationKeys(operation, { kind = true, lease = true }) then
			return nil, nil, "release-client-operation-malformed"
		end
		local lease, leaseError = inspectLeaseCapability(operation.lease)
		if not lease then
			return nil, nil, leaseError
		end
		local validationError = validateLeaseForData(data, lease, "Client", capability.data.root.identity)
		if validationError then
			return nil, nil, validationError
		end
		assert(data.activeClientCount > 0, "client count certificate underflow")
		data.clientSlots[lease.sourceOrder].inUse = false
		data.activeClientCount -= 1
		if lease.status == "Active" then
			releasedActiveLeases[lease :: any] = lease
		end
	elseif kind == "AllocateWorld" then
		if not exactOperationKeys(operation, { kind = true, nowMilliseconds = true }) then
			return nil, nil, "allocate-world-operation-malformed"
		end
		local sourceOrder, generation, allocationError = allocateWorldData(data, operation.nowMilliseconds)
		if not sourceOrder or not generation then
			return nil, nil, allocationError
		end
		local lease, leaseCapability =
			makeLease(data.lineage, "World", sourceOrder, generation, "Pending", capability.data.root.identity)
		producedLease = lease
		table.insert(capability.data.root.pendingLeases, leaseCapability)
	elseif kind == "ReleaseWorld" then
		if not exactOperationKeys(operation, {
			kind = true,
			lease = true,
			nowMilliseconds = true,
		}) then
			return nil, nil, "release-world-operation-malformed"
		end
		local lease, leaseError = inspectLeaseCapability(operation.lease)
		if not lease then
			return nil, nil, leaseError
		end
		local releaseError = releaseWorldData(data, lease, operation.nowMilliseconds, capability.data.root.identity)
		if releaseError then
			return nil, nil, releaseError
		end
		if lease.status == "Active" then
			releasedActiveLeases[lease :: any] = lease
		end
	else
		return nil, nil, "operation-kind-invalid"
	end

	local nextTransaction = makeTransaction({
		root = capability.data.root,
		generation = capability.data.generation + 1,
		working = data,
		releasedActiveLeases = releasedActiveLeases,
	})
	capability.current = false
	return nextTransaction, producedLease, nil
end

local function getPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "prepared-commit-not-capability"
	end
	local capability = preparedCapabilities[preparedValue :: PreparedCommit]
	if not capability then
		return nil, "prepared-commit-not-capability"
	end
	return capability, nil
end

-- This check performs no cloning, freezing, callbacks, or publication. It is
-- repeated by ApplyPrepared so a caller that accidentally yields after its
-- composite preflight cannot consume a stale allocator root.
local function preparedCommitCurrentError(preparedValue: unknown, capability: PreparedCapability): string?
	local transaction = capability.transaction
	local transactionCapability = capability.transactionCapability
	local transactionData = transactionCapability.data
	local root = transactionData.root
	if
		capability.status ~= "Prepared"
		or not transactionCapability.current
		or not root.open
		or root.prepared ~= preparedValue
		or transactionCapabilities[transaction :: table] ~= transactionCapability
		or not root.baseCapability.current
		or stateCapabilities[root.baseState :: table] ~= root.baseCapability
		or stateCapabilities[capability.nextState :: table] ~= capability.nextStateCapability
		or not capability.nextStateCapability.current
		or capability.nextStateCapability.data ~= transactionData.working
		or transactionData.working.revision ~= root.baseCapability.data.revision + 1
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(transaction :: any)
		or not table.isfrozen(capability.nextState :: any)
	then
		return "stale-prepared-commit"
	end
	local exposed = transaction :: { [unknown]: unknown }
	local working = transactionData.working
	if
		not countCertificatesWithinBounds(working)
		or exposed.baseRevision ~= root.baseCapability.data.revision
		or exposed.generation ~= transactionData.generation
		or exposed.highestWorldSourceOrder ~= working.highestWorldSourceOrder
		or exposed.activeClientCount ~= working.activeClientCount
		or exposed.activeWorldCount ~= working.activeWorldCount
		or exposed.levelTimeMilliseconds ~= working.levelTimeMilliseconds
	then
		return "stale-prepared-commit"
	end
	for _, mutation in capability.leaseMutations do
		local lease = mutation.lease
		if
			lease.status ~= mutation.expectedStatus
			or lease.transactionIdentity ~= mutation.expectedTransactionIdentity
			or lease.lineage ~= working.lineage
			or not table.isfrozen(mutation)
		then
			return "stale-prepared-commit"
		end
	end
	return nil
end

function EntitySourceOrderRules.Prepare(transactionValue: unknown): (PreparedCommit?, string?)
	local capability, transactionError = currentTransactionWithBase(transactionValue)
	if not capability then
		return nil, transactionError
	end
	local transactionData = capability.data
	local working = transactionData.working
	working.revision = nextRevision(transactionData.root.baseCapability.data.revision)
	local nextState = makeState(working)
	local nextStateCapability = stateCapabilities[nextState :: table]
	assert(nextStateCapability, "prepared state capability was not installed")
	local leaseMutations: { LeaseMutation } = {}
	for _, lease in transactionData.root.pendingLeases do
		local slot = slotForLease(working, lease)
		local mutation: LeaseMutation = {
			lease = lease,
			expectedStatus = "Pending",
			expectedTransactionIdentity = transactionData.root.identity,
			nextStatus = if slot and slot.inUse and slot.generation == lease.generation then "Active" else "Released",
			nextTransactionIdentity = nil,
		}
		table.insert(leaseMutations, mutation)
		table.freeze(mutation)
	end
	for _, lease in transactionData.releasedActiveLeases do
		local mutation: LeaseMutation = {
			lease = lease,
			expectedStatus = "Active",
			expectedTransactionIdentity = nil,
			nextStatus = "Released",
			nextTransactionIdentity = nil,
		}
		table.insert(leaseMutations, mutation)
		table.freeze(mutation)
	end
	table.freeze(leaseMutations)
	local prepared: PreparedCommit = table.freeze({})
	preparedCapabilities[prepared] = {
		transaction = transactionValue :: Transaction,
		transactionCapability = capability,
		nextState = nextState,
		nextStateCapability = nextStateCapability,
		leaseMutations = leaseMutations,
		status = "Prepared",
		applyValidated = false,
	}
	transactionData.root.prepared = prepared
	return prepared, nil
end

function EntitySourceOrderRules.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
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

-- Prepare constructs the next immutable state. Once CanApplyPrepared has
-- preflighted the mutable roots, this phase only assigns owner/capability
-- fields and returns that already-built state; it has no failure return path.
function EntitySourceOrderRules.ApplyPrepared(preparedValue: unknown): State
	local capability, capabilityError = getPreparedCapability(preparedValue)
	assert(capability, capabilityError or "prepared-commit-not-capability")
	assert(capability.applyValidated, "prepared-commit-not-validated")
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-prepared-commit")

	local transactionCapability = capability.transactionCapability
	local transactionData = transactionCapability.data
	local root = transactionData.root

	for _, mutation in capability.leaseMutations do
		mutation.lease.status = mutation.nextStatus
		mutation.lease.transactionIdentity = mutation.nextTransactionIdentity
	end

	root.baseCapability.current = false
	root.open = false
	root.prepared = nil
	transactionCapability.current = false
	capability.status = "Applied"
	capability.applyValidated = false
	preparedCapabilities[preparedValue :: PreparedCommit] = nil
	return capability.nextState
end

function EntitySourceOrderRules.Commit(transactionValue: unknown): (State?, string?)
	local prepared, prepareError = EntitySourceOrderRules.Prepare(transactionValue)
	if not prepared then
		return nil, prepareError
	end
	local canApply, canApplyError = EntitySourceOrderRules.CanApplyPrepared(prepared)
	if not canApply then
		return nil, canApplyError
	end
	return EntitySourceOrderRules.ApplyPrepared(prepared), nil
end

function EntitySourceOrderRules.Abort(transactionValue: unknown): (State?, string?)
	local capability, transactionError = inspectCurrentTransaction(transactionValue, true)
	if not capability then
		return nil, transactionError
	end
	local root = capability.data.root
	if not root.baseCapability.current then
		return nil, "transaction-base-state-not-current"
	end
	local prepared = root.prepared
	if prepared then
		local preparedCapability = preparedCapabilities[prepared]
		if not preparedCapability or preparedCapability.transactionCapability ~= capability then
			return nil, "stale-prepared-commit"
		end
		preparedCapability.nextStateCapability.current = false
		preparedCapability.status = "Aborted"
		preparedCapability.applyValidated = false
		preparedCapabilities[prepared] = nil
		root.prepared = nil
	end
	for _, lease in root.pendingLeases do
		if lease.status == "Pending" then
			lease.status = "Aborted"
			lease.transactionIdentity = nil
		end
	end
	root.open = false
	capability.current = false
	return root.baseState, nil
end

function EntitySourceOrderRules.Inspect(stateValue: unknown): (State?, string?)
	local capability, stateError = currentState(stateValue)
	if not capability then
		return nil, stateError
	end
	return stateValue :: State, nil
end

function EntitySourceOrderRules.InspectTransaction(transactionValue: unknown): (Transaction?, string?)
	local capability, transactionError = currentTransactionWithBase(transactionValue)
	if not capability then
		return nil, transactionError
	end
	return transactionValue :: Transaction, nil
end

function EntitySourceOrderRules.InspectLease(
	ownerValue: unknown,
	leaseValue: unknown,
	expectedDomainValue: unknown?
): (Lease?, string?)
	local expectedDomain: Domain? = nil
	if expectedDomainValue ~= nil then
		if expectedDomainValue ~= "Client" and expectedDomainValue ~= "World" then
			return nil, "expected-domain-invalid"
		end
		expectedDomain = expectedDomainValue :: Domain
	end
	local lease, leaseError = inspectLeaseCapability(leaseValue)
	if not lease then
		return nil, leaseError
	end
	if type(ownerValue) ~= "table" then
		return nil, "lease-owner-not-capability"
	end
	local stateCapability = stateCapabilities[ownerValue :: table]
	if stateCapability then
		local current, stateError = currentState(ownerValue)
		if not current then
			return nil, stateError
		end
		local validationError = validateLeaseForData(current.data, lease, expectedDomain, nil)
		if validationError then
			return nil, validationError
		end
		return leaseValue :: Lease, nil
	end
	local transactionCapability = transactionCapabilities[ownerValue :: table]
	if transactionCapability then
		local current, transactionError = currentTransactionWithBase(ownerValue)
		if not current then
			return nil, transactionError
		end
		local validationError =
			validateLeaseForData(current.data.working, lease, expectedDomain, current.data.root.identity)
		if validationError then
			return nil, validationError
		end
		return leaseValue :: Lease, nil
	end
	return nil, "lease-owner-not-capability"
end

function EntitySourceOrderRules.EntityNumberToSourceOrder(entityNumberValue: unknown): number?
	if not isIntegerInRange(entityNumberValue, 0, ENTITYNUM_MAX_NORMAL - 1) then
		return nil
	end
	return (entityNumberValue :: number) + 1
end

function EntitySourceOrderRules.SourceOrderToEntityNumber(sourceOrderValue: unknown): number?
	if not isIntegerInRange(sourceOrderValue, 1, MAXIMUM_NORMAL_SOURCE_ORDER) then
		return nil
	end
	return (sourceOrderValue :: number) - 1
end

function EntitySourceOrderRules.MakeBodyId(
	prefixValue: unknown,
	ownerValue: unknown,
	leaseValue: unknown
): (string?, string?)
	if
		type(prefixValue) ~= "string"
		or #prefixValue < 1
		or #prefixValue > MAXIMUM_BODY_PREFIX_LENGTH
		or string.match(prefixValue, "^[a-z][a-z0-9_]*$") == nil
	then
		return nil, "body-prefix-invalid"
	end
	local lease, leaseError = EntitySourceOrderRules.InspectLease(ownerValue, leaseValue, nil)
	if not lease then
		return nil, leaseError
	end
	return string.format("%s_e%d_g%d", prefixValue, lease.sourceOrder - 1, lease.generation), nil
end

EntitySourceOrderRules.MaximumClients = MAXIMUM_CLIENTS
EntitySourceOrderRules.MaximumEntities = MAXIMUM_GENTITIES
EntitySourceOrderRules.EntityNumNone = ENTITYNUM_NONE
EntitySourceOrderRules.EntityNumWorld = ENTITYNUM_WORLD
EntitySourceOrderRules.EntityNumMaxNormal = ENTITYNUM_MAX_NORMAL
EntitySourceOrderRules.FirstWorldEntityNumber = FIRST_WORLD_ENTITY_NUMBER
EntitySourceOrderRules.FirstWorldSourceOrder = FIRST_WORLD_SOURCE_ORDER
EntitySourceOrderRules.MaximumNormalSourceOrder = MAXIMUM_NORMAL_SOURCE_ORDER
EntitySourceOrderRules.BodyQueueSize = BODY_QUEUE_SIZE
EntitySourceOrderRules.RecentFreeReuseDelayMilliseconds = RECENT_FREE_REUSE_DELAY_MILLISECONDS
EntitySourceOrderRules.StartupReuseGraceMilliseconds = STARTUP_REUSE_GRACE_MILLISECONDS

return table.freeze(EntitySourceOrderRules)
