--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure original-map adapter for Quake III Arena's non-world gentity bootstrap:
  code/game/g_main.c (G_InitGame)
  code/game/g_client.c (InitBodyQue)
  code/game/g_spawn.c (G_SpawnEntitiesFromString,
    G_SpawnGEntityFromSpawnVars)
  code/game/g_utils.c (G_Spawn)
  code/game/g_items.c (G_SpawnItem)
  code/game/g_trigger.c (trigger spawn functions)
  code/game/g_mover.c (mover spawn functions)

Q3 consumes one entstring in parse order after worldspawn and after the eight
body-queue entities. the Roblox Luau port's original map schema separates those
entities into arrays, so this adapter defines one explicit canonical parse
order: targets, player spawn points, flag bases, pickups, jump-pad triggers,
teleporter triggers, kill-volume triggers, and finally all legacy and binary
mover parts merged by authored sourceOrder. Array order is retained inside each
non-mover category. Worldspawn/static BSP-like chunks and non-entity water or
no-drop contents do not allocate gentities and are deliberately omitted.

AppendStudioRuntimeMoverFixtures is a separate, explicit test-fixture adapter.
It may retain inert placeholder reservations to reach trusted Studio/runtime
mover source orders. Shippable authored maps must use Build and may not depend
on those placeholders.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type EntityKind = "Spawn" | "Item" | "TeamFlag" | "Target" | "Trigger" | "Mover"
export type SpawnEvent = {
	read id: string,
	read kind: EntityKind,
	read disposition: "Retain",
}

type Category = {
	read field: string,
	read kind: EntityKind?,
}

type MoverPart = {
	read id: string,
	read sourceOrder: number,
}

local MapEntitySpawnPlanRules = {}

local MAXIMUM_IDENTIFIER_LENGTH = 64
local MAXIMUM_DEFINITION_ARRAY_ENTRIES = 1024
-- Static world chunks are worldspawn/BSP-like collision, not gentity_t rows.
-- Keep their authoring budget bounded independently so the Q3 entity ceiling
-- cannot reject a detailed native collision domain that allocates no entity.
-- The 32K ceiling is required by reviewed r8 collision domains whose lossless,
-- disjoint cover cannot fit the former 16K budget. This remains a finite,
-- worldspawn-only limit; PlayerClip and Q3 gentity budgets stay independent.
-- Raising it is preferable to coarsening geometry or introducing overlapping
-- Parts, and every map above 16K requires its own count/overlap/runtime evidence.
local MAXIMUM_STATIC_CHUNK_ENTRIES = 32768
local FIRST_WORLD_SOURCE_ORDER = 65
local BODY_QUEUE_SIZE = 8
local LAST_BODY_QUEUE_SOURCE_ORDER = FIRST_WORLD_SOURCE_ORDER + BODY_QUEUE_SIZE - 1
local MAXIMUM_NORMAL_SOURCE_ORDER = 1022
local MAXIMUM_RETAINED_EVENTS = MAXIMUM_NORMAL_SOURCE_ORDER - LAST_BODY_QUEUE_SOURCE_ORDER
local STUDIO_RESERVATION_PREFIX = "studio_runtime_reservation_so_"

local EntityKinds = table.freeze({
	Spawn = "Spawn" :: "Spawn",
	Item = "Item" :: "Item",
	TeamFlag = "TeamFlag" :: "TeamFlag",
	Target = "Target" :: "Target",
	Trigger = "Trigger" :: "Trigger",
	Mover = "Mover" :: "Mover",
})

-- Static chunks and point-contents volumes participate in global authored-ID
-- validation but have nil kinds because they do not allocate Q3 gentities.
local CATEGORY_ORDER: { Category } = {
	{ field = "targets", kind = EntityKinds.Target },
	{ field = "spawns", kind = EntityKinds.Spawn },
	{ field = "flagBases", kind = EntityKinds.TeamFlag },
	{ field = "pickups", kind = EntityKinds.Item },
	{ field = "jumpPads", kind = EntityKinds.Trigger },
	{ field = "teleporters", kind = EntityKinds.Trigger },
	{ field = "killVolumes", kind = EntityKinds.Trigger },
	{ field = "movers", kind = EntityKinds.Mover },
	{ field = "binaryMovers", kind = EntityKinds.Mover },
	{ field = "staticChunks", kind = nil },
	{ field = "waterVolumes", kind = nil },
	{ field = "noDropVolumes", kind = nil },
}
for _, category in CATEGORY_ORDER do
	table.freeze(category)
end
table.freeze(CATEGORY_ORDER)

local CanonicalParseOrder = table.freeze({
	"targets",
	"spawns",
	"flagBases",
	"pickups",
	"jumpPads",
	"teleporters",
	"killVolumes",
	"movers+binaryMovers:ascending-sourceOrder",
})

local EVENT_KEYS = table.freeze({
	id = true,
	kind = true,
	disposition = true,
})

local VALID_ENTITY_KINDS = table.freeze({
	[EntityKinds.Spawn] = true,
	[EntityKinds.Item] = true,
	[EntityKinds.TeamFlag] = true,
	[EntityKinds.Target] = true,
	[EntityKinds.Trigger] = true,
	[EntityKinds.Mover] = true,
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

local function denseArrayLength(value: unknown, label: string, maximumEntries: number): (number?, string?)
	if type(value) ~= "table" then
		return nil, label .. "-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, label .. "-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximumEntries or maximumIndex > maximumEntries then
			return nil, label .. "-too-many-entries"
		end
	end
	if maximumIndex ~= count then
		return nil, label .. "-not-dense-array"
	end
	return count, nil
end

local function makeEvent(id: string, kind: EntityKind): SpawnEvent
	local event: SpawnEvent = {
		id = id,
		kind = kind,
		disposition = "Retain",
	}
	table.freeze(event)
	return event
end

local function registerStableId(observedIds: { [string]: string }, idValue: unknown, path: string): (string?, string?)
	if not isStableId(idValue) then
		return nil, path .. ":invalid-id"
	end
	local id = idValue :: string
	local priorPath = observedIds[id]
	if priorPath then
		return nil, string.format("%s:duplicate-id:%s", path, priorPath)
	end
	observedIds[id] = path
	return id, nil
end

local function collectDefinitionArrays(
	definitionValue: unknown
): ({ [string]: { unknown } }?, { [string]: string }?, string?)
	if type(definitionValue) ~= "table" then
		return nil, nil, "definition-not-table"
	end
	local definition = definitionValue :: { [unknown]: unknown }
	local arrays: { [string]: { unknown } } = {}
	local observedIds: { [string]: string } = {}
	for _, category in CATEGORY_ORDER do
		local fieldValue = definition[category.field]
		local maximumEntries = if category.field == "staticChunks"
			then MAXIMUM_STATIC_CHUNK_ENTRIES
			else MAXIMUM_DEFINITION_ARRAY_ENTRIES
		local count, countError = denseArrayLength(fieldValue, category.field, maximumEntries)
		if not count then
			return nil, nil, countError
		end
		local values = fieldValue :: { unknown }
		arrays[category.field] = values
		for index = 1, count do
			local value = values[index]
			if type(value) ~= "table" then
				return nil, nil, string.format("%s-%d:not-table", category.field, index)
			end
			local path = string.format("%s[%d]", category.field, index)
			local _, idError = registerStableId(observedIds, (value :: { [unknown]: unknown }).id, path)
			if idError then
				return nil, nil, idError
			end
		end
	end
	return arrays, observedIds, nil
end

local function collectMoverParts(legacyValues: { unknown }, binaryValues: { unknown }): ({ MoverPart }?, string?)
	local parts: { MoverPart } = table.create(#legacyValues + #binaryValues)
	local observedSourceOrders: { [number]: string } = {}
	local function appendDomain(values: { unknown }, domain: string): string?
		for index, value in values do
			local raw = value :: { [unknown]: unknown }
			local sourceOrder = raw.sourceOrder
			if not isIntegerInRange(sourceOrder, FIRST_WORLD_SOURCE_ORDER, MAXIMUM_NORMAL_SOURCE_ORDER) then
				return string.format("%s-%d:invalid-source-order", domain, index)
			end
			local numericSourceOrder = sourceOrder :: number
			local priorPath = observedSourceOrders[numericSourceOrder]
			if priorPath then
				return string.format("%s-%d:duplicate-source-order:%s", domain, index, priorPath)
			end
			observedSourceOrders[numericSourceOrder] = string.format("%s[%d]", domain, index)
			local part: MoverPart = {
				id = raw.id :: string,
				sourceOrder = numericSourceOrder,
			}
			table.freeze(part)
			table.insert(parts, part)
		end
		return nil
	end
	local legacyError = appendDomain(legacyValues, "movers")
	if legacyError then
		return nil, legacyError
	end
	local binaryError = appendDomain(binaryValues, "binaryMovers")
	if binaryError then
		return nil, binaryError
	end
	table.sort(parts, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	return parts, nil
end

function MapEntitySpawnPlanRules.Build(definitionValue: unknown): ({ SpawnEvent }?, string?)
	local arrays, _, arraysError = collectDefinitionArrays(definitionValue)
	if not arrays then
		return nil, arraysError
	end

	local nonMoverCount = #arrays.targets
		+ #arrays.spawns
		+ #arrays.flagBases
		+ #arrays.pickups
		+ #arrays.jumpPads
		+ #arrays.teleporters
		+ #arrays.killVolumes
	local moverCount = #arrays.movers + #arrays.binaryMovers
	if nonMoverCount + moverCount > MAXIMUM_RETAINED_EVENTS then
		return nil, "too-many-retained-entity-events"
	end

	local events: { SpawnEvent } = table.create(nonMoverCount + moverCount)
	local function appendCategory(field: string, kind: EntityKind)
		for _, value in arrays[field] do
			local id = (value :: { [unknown]: unknown }).id :: string
			table.insert(events, makeEvent(id, kind))
		end
	end
	appendCategory("targets", EntityKinds.Target)
	appendCategory("spawns", EntityKinds.Spawn)
	appendCategory("flagBases", EntityKinds.TeamFlag)
	appendCategory("pickups", EntityKinds.Item)
	appendCategory("jumpPads", EntityKinds.Trigger)
	appendCategory("teleporters", EntityKinds.Trigger)
	appendCategory("killVolumes", EntityKinds.Trigger)

	local moverParts, moverError = collectMoverParts(arrays.movers, arrays.binaryMovers)
	if not moverParts then
		return nil, moverError
	end
	for _, part in moverParts do
		local expectedSourceOrder = LAST_BODY_QUEUE_SOURCE_ORDER + #events + 1
		if part.sourceOrder ~= expectedSourceOrder then
			return nil,
				string.format(
					"mover-%s:source-order-%d-does-not-match-plan-%d",
					part.id,
					part.sourceOrder,
					expectedSourceOrder
				)
		end
		table.insert(events, makeEvent(part.id, EntityKinds.Mover))
	end
	table.freeze(events)
	return events, nil
end

local function hasExactEventShape(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or EVENT_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 3
end

local function copyRetainedPlan(eventsValue: unknown): ({ SpawnEvent }?, { [string]: string }?, string?)
	local count, countError = denseArrayLength(eventsValue, "base-events", MAXIMUM_RETAINED_EVENTS)
	if not count then
		return nil, nil, countError
	end
	if count > MAXIMUM_RETAINED_EVENTS then
		return nil, nil, "base-events-too-many-retained-events"
	end
	local events: { SpawnEvent } = table.create(count)
	local observedIds: { [string]: string } = {}
	for index = 1, count do
		local value = (eventsValue :: { unknown })[index]
		if type(value) ~= "table" then
			return nil, nil, string.format("base-event-%d:not-table", index)
		end
		local raw = value :: { [unknown]: unknown }
		if not hasExactEventShape(raw) then
			return nil, nil, string.format("base-event-%d:invalid-shape", index)
		end
		local id, idError = registerStableId(observedIds, raw.id, string.format("base-events[%d]", index))
		if not id then
			return nil, nil, idError
		end
		if type(raw.kind) ~= "string" or VALID_ENTITY_KINDS[raw.kind :: string] ~= true then
			return nil, nil, string.format("base-event-%d:invalid-kind", index)
		end
		if raw.disposition ~= "Retain" then
			return nil, nil, string.format("base-event-%d:not-retained", index)
		end
		table.insert(events, makeEvent(id, raw.kind :: EntityKind))
	end
	return events, observedIds, nil
end

-- TEST FIXTURES ONLY. This function exists for Studio runtime mover fixtures
-- whose trusted source orders intentionally leave gaps after the authored map.
-- Each gap is represented by a retained inert Target reservation so the normal
-- EntitySpawnPlanRules replay reaches the same Q3 source order without hiding
-- an allocation-order mismatch in shippable map data.
function MapEntitySpawnPlanRules.AppendStudioRuntimeMoverFixtures(
	baseEventsValue: unknown,
	runtimeMoversValue: unknown
): ({ SpawnEvent }?, string?)
	local events, observedIds, baseError = copyRetainedPlan(baseEventsValue)
	if not events or not observedIds then
		return nil, baseError
	end
	local moverCount, moverCountError = denseArrayLength(runtimeMoversValue, "runtime-movers", MAXIMUM_RETAINED_EVENTS)
	if not moverCount then
		return nil, moverCountError
	end

	local priorRuntimeSourceOrder = LAST_BODY_QUEUE_SOURCE_ORDER + #events
	for index = 1, moverCount do
		local value = (runtimeMoversValue :: { unknown })[index]
		if type(value) ~= "table" then
			return nil, string.format("runtime-mover-%d:not-table", index)
		end
		local raw = value :: { [unknown]: unknown }
		local path = string.format("runtime-movers[%d]", index)
		local id, idError = registerStableId(observedIds, raw.id, path)
		if not id then
			return nil, idError
		end
		if not isIntegerInRange(raw.sourceOrder, FIRST_WORLD_SOURCE_ORDER, MAXIMUM_NORMAL_SOURCE_ORDER) then
			return nil, string.format("runtime-mover-%d:invalid-source-order", index)
		end
		local sourceOrder = raw.sourceOrder :: number
		local nextSourceOrder = LAST_BODY_QUEUE_SOURCE_ORDER + #events + 1
		if sourceOrder <= priorRuntimeSourceOrder then
			return nil, string.format("runtime-mover-%d:backward-or-colliding-source-order", index)
		end
		if sourceOrder < nextSourceOrder then
			return nil, string.format("runtime-mover-%d:source-order-collides-with-base", index)
		end
		while nextSourceOrder < sourceOrder do
			if #events >= MAXIMUM_RETAINED_EVENTS then
				return nil, "studio-runtime-extension-exhausted-normal-entities"
			end
			local reservationId = STUDIO_RESERVATION_PREFIX .. tostring(nextSourceOrder)
			local _, reservationError = registerStableId(observedIds, reservationId, "generated-reservation")
			if reservationError then
				return nil, "studio-reservation-id-collision:" .. reservationId
			end
			table.insert(events, makeEvent(reservationId, EntityKinds.Target))
			nextSourceOrder += 1
		end
		if #events >= MAXIMUM_RETAINED_EVENTS then
			return nil, "studio-runtime-extension-exhausted-normal-entities"
		end
		table.insert(events, makeEvent(id, EntityKinds.Mover))
		priorRuntimeSourceOrder = sourceOrder
	end
	table.freeze(events)
	return events, nil
end

MapEntitySpawnPlanRules.EntityKinds = EntityKinds
MapEntitySpawnPlanRules.CanonicalParseOrder = CanonicalParseOrder
MapEntitySpawnPlanRules.MaximumIdentifierLength = MAXIMUM_IDENTIFIER_LENGTH
MapEntitySpawnPlanRules.MaximumDefinitionArrayEntries = MAXIMUM_DEFINITION_ARRAY_ENTRIES
MapEntitySpawnPlanRules.FirstWorldSourceOrder = FIRST_WORLD_SOURCE_ORDER
MapEntitySpawnPlanRules.BodyQueueSize = BODY_QUEUE_SIZE
MapEntitySpawnPlanRules.LastBodyQueueSourceOrder = LAST_BODY_QUEUE_SOURCE_ORDER
MapEntitySpawnPlanRules.MaximumNormalSourceOrder = MAXIMUM_NORMAL_SOURCE_ORDER
MapEntitySpawnPlanRules.MaximumRetainedEvents = MAXIMUM_RETAINED_EVENTS
MapEntitySpawnPlanRules.MaximumStaticChunks = MAXIMUM_STATIC_CHUNK_ENTRIES
MapEntitySpawnPlanRules.StudioReservationPrefix = STUDIO_RESERVATION_PREFIX

return table.freeze(MapEntitySpawnPlanRules)
