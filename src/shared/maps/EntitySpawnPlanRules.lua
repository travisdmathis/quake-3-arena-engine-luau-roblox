--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure original-map entity spawn replay translated from Quake III Arena:
  code/game/g_main.c (G_InitGame ordering)
  code/game/g_local.h (BODY_QUEUE_SIZE)
  code/game/g_client.c (InitBodyQue)
  code/game/g_spawn.c (G_SpawnGEntityFromSpawnVars,
    G_SpawnEntitiesFromString)
  code/game/g_utils.c (G_Spawn, G_FreeEntity)

The input is an original the Roblox Luau port map plan, not a Quake entstring. Each
event represents one non-world gentity allocation in parse order. Worldspawn
is deliberately absent because Q3 calls SP_worldspawn without G_Spawn. Every
event allocates before its Retain/Free disposition is known; Free therefore
releases the just-created slot immediately and a later parse event may reuse
that slot with a new generation during startup grace.

EntitySourceOrderRules is supplied explicitly so this same dependency-free
module can execute under Lune and later beneath the server EntitySlotService.
The replay accepts only the pinned allocator constants and context-bound opaque
lease API. It owns a fresh allocator and publishes only one committed result.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type EntityKind = "Spawn" | "Item" | "TeamFlag" | "Target" | "Trigger" | "Mover"
export type Disposition = "Retain" | "Free"

export type SpawnEvent = {
	read id: string,
	read kind: EntityKind,
	read disposition: Disposition,
}

export type WorldLease = {
	read domain: "World",
	read sourceOrder: number,
	read generation: number,
}

export type BodyQueueRegistration = {
	read ordinal: number,
	read sourceOrder: number,
	read bodyId: string,
	read lease: WorldLease,
}

export type ActiveRegistration = {
	read eventId: string,
	read kind: EntityKind,
	read sourceOrder: number,
	read bodyId: string,
	read lease: WorldLease,
}

export type Result = {
	read state: any,
	read bodyQueue: { BodyQueueRegistration },
	read active: { ActiveRegistration },
}

local EntitySpawnPlanRules = {}

local MAXIMUM_EVENTS = 1024
local MAXIMUM_IDENTIFIER_LENGTH = 64
local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local EXPECTED_MAXIMUM_CLIENTS = 64
local EXPECTED_MAXIMUM_ENTITIES = 1024
local EXPECTED_FIRST_WORLD_SOURCE_ORDER = 65
local EXPECTED_MAXIMUM_NORMAL_SOURCE_ORDER = 1022
local EXPECTED_BODY_QUEUE_SIZE = 8

local EntityKinds = table.freeze({
	Spawn = "Spawn" :: "Spawn",
	Item = "Item" :: "Item",
	TeamFlag = "TeamFlag" :: "TeamFlag",
	Target = "Target" :: "Target",
	Trigger = "Trigger" :: "Trigger",
	Mover = "Mover" :: "Mover",
})

local Dispositions = table.freeze({
	Retain = "Retain" :: "Retain",
	Free = "Free" :: "Free",
})

local BODY_PREFIX_BY_KIND: { [EntityKind]: string } = table.freeze({
	[EntityKinds.Spawn] = "map_spawn",
	[EntityKinds.Item] = "map_item",
	[EntityKinds.TeamFlag] = "map_flag",
	[EntityKinds.Target] = "map_target",
	[EntityKinds.Trigger] = "map_trigger",
	[EntityKinds.Mover] = "map_mover",
})

local EVENT_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	kind = true,
	disposition = true,
})

local REQUIRED_ALLOCATOR_FUNCTIONS = table.freeze({
	"Create",
	"Begin",
	"Stage",
	"Commit",
	"Abort",
	"InspectLease",
	"MakeBodyId",
})

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
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
		and #value <= MAXIMUM_IDENTIFIER_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactEventKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or EVENT_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 3
end

local function isEntityKind(value: unknown): boolean
	return value == EntityKinds.Spawn
		or value == EntityKinds.Item
		or value == EntityKinds.TeamFlag
		or value == EntityKinds.Target
		or value == EntityKinds.Trigger
		or value == EntityKinds.Mover
end

local function isDisposition(value: unknown): boolean
	return value == Dispositions.Retain or value == Dispositions.Free
end

local function denseArrayLength(value: unknown): (number?, string?)
	if type(value) ~= "table" then
		return nil, "events-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "events-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_EVENTS or maximumIndex > MAXIMUM_EVENTS then
			return nil, "too-many-events"
		end
	end
	if maximumIndex ~= count then
		return nil, "events-not-dense-array"
	end
	return count, nil
end

local function validateEvents(value: unknown): ({ SpawnEvent }?, string?)
	local count, countError = denseArrayLength(value)
	if not count then
		return nil, countError
	end
	local canonical: { SpawnEvent } = table.create(count)
	local observedIds: { [string]: boolean } = {}
	for index = 1, count do
		local eventValue = (value :: { unknown })[index]
		if type(eventValue) ~= "table" then
			return nil, string.format("event-%d:not-table", index)
		end
		local raw = eventValue :: { [unknown]: unknown }
		if not hasExactEventKeys(raw) then
			return nil, string.format("event-%d:invalid-shape", index)
		end
		if not isStableId(raw.id) then
			return nil, string.format("event-%d:invalid-id", index)
		end
		local eventId = raw.id :: string
		if observedIds[eventId] then
			return nil, string.format("event-%d:duplicate-id", index)
		end
		if not isEntityKind(raw.kind) then
			return nil, string.format("event-%d:invalid-kind", index)
		end
		if not isDisposition(raw.disposition) then
			return nil, string.format("event-%d:invalid-disposition", index)
		end
		observedIds[eventId] = true
		local event: SpawnEvent = {
			id = eventId,
			kind = raw.kind :: EntityKind,
			disposition = raw.disposition :: Disposition,
		}
		table.freeze(event)
		table.insert(canonical, event)
	end
	table.freeze(canonical)
	return canonical, nil
end

local function validateAllocator(value: unknown): (any?, string?)
	if type(value) ~= "table" then
		return nil, "allocator-not-table"
	end
	local allocator = value :: any
	if
		allocator.MaximumClients ~= EXPECTED_MAXIMUM_CLIENTS
		or allocator.MaximumEntities ~= EXPECTED_MAXIMUM_ENTITIES
		or allocator.FirstWorldSourceOrder ~= EXPECTED_FIRST_WORLD_SOURCE_ORDER
		or allocator.MaximumNormalSourceOrder ~= EXPECTED_MAXIMUM_NORMAL_SOURCE_ORDER
		or allocator.BodyQueueSize ~= EXPECTED_BODY_QUEUE_SIZE
	then
		return nil, "allocator-q3-domain-mismatch"
	end
	for _, functionName in REQUIRED_ALLOCATOR_FUNCTIONS do
		if type(allocator[functionName]) ~= "function" then
			return nil, "allocator-missing-" .. functionName
		end
	end
	return allocator, nil
end

local function validWorldLease(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	return raw.domain == "World"
		and isIntegerInRange(raw.sourceOrder, EXPECTED_FIRST_WORLD_SOURCE_ORDER, EXPECTED_MAXIMUM_NORMAL_SOURCE_ORDER)
		and isIntegerInRange(raw.generation, 1, MAXIMUM_TIME_MILLISECONDS)
end

local function abortAndReturn(allocator: any, transaction: any, message: string): (Result?, string?)
	pcall(allocator.Abort, transaction)
	return nil, message
end

local function validateLeaseInContext(allocator: any, owner: any, lease: any): string?
	if not validWorldLease(lease) then
		return "invalid-world-lease"
	end
	local inspected, inspectError = allocator.InspectLease(owner, lease, "World")
	if inspected ~= lease then
		return "context-bound-lease-invalid:" .. tostring(inspectError)
	end
	return nil
end

local function makeBodyId(allocator: any, owner: any, lease: any, prefix: string): (string?, string?)
	local bodyId, bodyIdError = allocator.MakeBodyId(prefix, owner, lease)
	if not isStableId(bodyId) then
		return nil, "body-id-invalid:" .. tostring(bodyIdError)
	end
	return bodyId :: string, nil
end

local function makeBodyQueueRegistration(ordinal: number, lease: any, bodyId: string): BodyQueueRegistration
	local registration: BodyQueueRegistration = {
		ordinal = ordinal,
		sourceOrder = lease.sourceOrder,
		bodyId = bodyId,
		lease = lease :: WorldLease,
	}
	table.freeze(registration)
	return registration
end

local function makeActiveRegistration(event: SpawnEvent, lease: any, bodyId: string): ActiveRegistration
	local registration: ActiveRegistration = {
		eventId = event.id,
		kind = event.kind,
		sourceOrder = lease.sourceOrder,
		bodyId = bodyId,
		lease = lease :: WorldLease,
	}
	table.freeze(registration)
	return registration
end

function EntitySpawnPlanRules.Replay(
	allocatorValue: unknown,
	eventsValue: unknown,
	levelStartTimeMillisecondsValue: unknown
): (Result?, string?)
	local allocator, allocatorError = validateAllocator(allocatorValue)
	if not allocator then
		return nil, allocatorError
	end
	if not isIntegerInRange(levelStartTimeMillisecondsValue, 0, MAXIMUM_TIME_MILLISECONDS) then
		return nil, "invalid-level-start-time"
	end
	local events, eventsError = validateEvents(eventsValue)
	if not events then
		return nil, eventsError
	end
	local levelStartTimeMilliseconds = levelStartTimeMillisecondsValue :: number
	local authoredOrders: { number } = {}
	table.freeze(authoredOrders)
	local baseState, createError =
		allocator.Create(EXPECTED_MAXIMUM_CLIENTS, authoredOrders, levelStartTimeMilliseconds)
	if baseState == nil then
		return nil, "allocator-create-failed:" .. tostring(createError)
	end
	local transaction, beginError = allocator.Begin(baseState)
	if transaction == nil then
		return nil, "allocator-begin-failed:" .. tostring(beginError)
	end

	local bodyQueue: { BodyQueueRegistration } = table.create(EXPECTED_BODY_QUEUE_SIZE)
	for ordinal = 1, EXPECTED_BODY_QUEUE_SIZE do
		local nextTransaction, lease, allocationError = allocator.Stage(transaction, {
			kind = "AllocateWorld",
			nowMilliseconds = levelStartTimeMilliseconds,
		})
		if nextTransaction == nil or lease == nil then
			return abortAndReturn(allocator, transaction, "body-queue-allocation-failed:" .. tostring(allocationError))
		end
		transaction = nextTransaction
		local leaseError = validateLeaseInContext(allocator, transaction, lease)
		if leaseError then
			return abortAndReturn(allocator, transaction, "body-queue-" .. leaseError)
		end
		local expectedSourceOrder = EXPECTED_FIRST_WORLD_SOURCE_ORDER + ordinal - 1
		if lease.sourceOrder ~= expectedSourceOrder or lease.generation ~= 1 then
			return abortAndReturn(allocator, transaction, "body-queue-allocation-order-drift")
		end
		local bodyId, bodyIdError = makeBodyId(allocator, transaction, lease, "bodyque")
		if not bodyId then
			return abortAndReturn(allocator, transaction, bodyIdError or "body-queue-id-failed")
		end
		table.insert(bodyQueue, makeBodyQueueRegistration(ordinal, lease, bodyId))
	end

	local active: { ActiveRegistration } = {}
	for index, event in events do
		local nextTransaction, lease, allocationError = allocator.Stage(transaction, {
			kind = "AllocateWorld",
			nowMilliseconds = levelStartTimeMilliseconds,
		})
		if nextTransaction == nil or lease == nil then
			return abortAndReturn(
				allocator,
				transaction,
				string.format("event-%d:allocation-failed:%s", index, tostring(allocationError))
			)
		end
		transaction = nextTransaction
		local leaseError = validateLeaseInContext(allocator, transaction, lease)
		if leaseError then
			return abortAndReturn(allocator, transaction, string.format("event-%d:%s", index, leaseError))
		end
		local bodyId, bodyIdError = makeBodyId(allocator, transaction, lease, BODY_PREFIX_BY_KIND[event.kind])
		if not bodyId then
			return abortAndReturn(
				allocator,
				transaction,
				string.format("event-%d:%s", index, bodyIdError or "body-id-failed")
			)
		end
		if event.disposition == Dispositions.Retain then
			table.insert(active, makeActiveRegistration(event, lease, bodyId))
		else
			local releaseTransaction, producedLease, releaseError = allocator.Stage(transaction, {
				kind = "ReleaseWorld",
				lease = lease,
				nowMilliseconds = levelStartTimeMilliseconds,
			})
			if releaseTransaction == nil or producedLease ~= nil then
				return abortAndReturn(
					allocator,
					transaction,
					string.format("event-%d:release-failed:%s", index, tostring(releaseError))
				)
			end
			transaction = releaseTransaction
			if allocator.InspectLease(transaction, lease, "World") ~= nil then
				return abortAndReturn(
					allocator,
					transaction,
					string.format("event-%d:released-lease-remained-active", index)
				)
			end
		end
	end

	local committedState, commitError = allocator.Commit(transaction)
	if committedState == nil then
		return abortAndReturn(allocator, transaction, "allocator-commit-failed:" .. tostring(commitError))
	end
	if
		committedState.activeWorldCount ~= EXPECTED_BODY_QUEUE_SIZE + #active
		or committedState.levelTimeMilliseconds ~= levelStartTimeMilliseconds
	then
		return nil, "committed-spawn-plan-state-drift"
	end
	for _, registration in bodyQueue do
		local leaseError = validateLeaseInContext(allocator, committedState, registration.lease)
		local bodyId = allocator.MakeBodyId("bodyque", committedState, registration.lease)
		if leaseError or bodyId ~= registration.bodyId then
			return nil, "committed-body-queue-registration-invalid"
		end
	end
	for _, registration in active do
		local leaseError = validateLeaseInContext(allocator, committedState, registration.lease)
		local bodyId = allocator.MakeBodyId(BODY_PREFIX_BY_KIND[registration.kind], committedState, registration.lease)
		if leaseError or bodyId ~= registration.bodyId then
			return nil, "committed-active-registration-invalid"
		end
	end

	table.freeze(bodyQueue)
	table.freeze(active)
	local result: Result = {
		state = committedState,
		bodyQueue = bodyQueue,
		active = active,
	}
	table.freeze(result)
	return result, nil
end

EntitySpawnPlanRules.EntityKinds = EntityKinds
EntitySpawnPlanRules.Dispositions = Dispositions
EntitySpawnPlanRules.MaximumEvents = MAXIMUM_EVENTS
EntitySpawnPlanRules.MaximumIdentifierLength = MAXIMUM_IDENTIFIER_LENGTH
EntitySpawnPlanRules.BodyQueueSize = EXPECTED_BODY_QUEUE_SIZE
EntitySpawnPlanRules.FirstWorldSourceOrder = EXPECTED_FIRST_WORLD_SOURCE_ORDER
EntitySpawnPlanRules.MaximumNormalSourceOrder = EXPECTED_MAXIMUM_NORMAL_SOURCE_ORDER

return table.freeze(EntitySpawnPlanRules)
