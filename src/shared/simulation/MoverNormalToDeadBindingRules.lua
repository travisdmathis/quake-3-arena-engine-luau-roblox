--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure mover-lethal binding plan translated from Quake III Arena:
  code/game/g_main.c (G_RunFrame numeric/source-order traversal)
  code/game/g_mover.c (G_MoverPush, G_TryPushingEntity, Blocked_Door)
  code/game/g_combat.c (G_Damage, player_die, LookAtKiller)
  code/game/g_active.c (ClientEndFrame player-state projection)
  code/game/g_items.c (Drop_Item, LaunchItem)

Quake restores a pushed client's precise origin before synchronous mover
damage, while the later ClientEndFrame pass projects every client in source
order. This module only joins those two already-authoritative data streams by
exact player identity. Opaque identity fields, immutable bounded records, and
an explicit 64-client limit are the Roblox Luau port adaptations; capability, life,
damage, and transition authority remain with the composing server services.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local EntityStateConversionRules = require(script.Parent.EntityStateConversionRules)

export type Lethal = {
	read player: unknown,
	read source: unknown,
	read body: unknown,
	read operationIndex: number,
	read callbackTraversalOrder: number,
	read callbackEntityTrajectoryBase: Vector3,
	read moverEntityTrajectoryBase: Vector3,
}

export type Assignment = {
	read player: unknown,
	read assignment: unknown,
	read playerSourceOrder: number,
	read prospectiveState: unknown,
	read nextEntityTrajectoryBase: Vector3,
	read nextEntityTrajectoryDelta: Vector3,
	read callbackEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
}

export type PlanEntry = {
	read player: unknown,
	read source: unknown,
	read body: unknown,
	read operationIndex: number,
	read callbackTraversalOrder: number,
	read callbackEntityTrajectoryBase: Vector3,
	read moverEntityTrajectoryBase: Vector3,
	read matchedAssignment: Assignment,
	read assignment: unknown,
	read playerSourceOrder: number,
	read prospectiveState: unknown,
	read nextEntityTrajectoryBase: Vector3,
	read nextEntityTrajectoryDelta: Vector3,
	read callbackEntityAngularTrajectoryBase: EntityStateConversionRules.Angles,
}

export type Plan = {
	read operationCount: number,
	read entries: { PlanEntry },
}

local MoverNormalToDeadBindingRules = {}

-- q_shared.h fixes MAX_CLIENTS at 64. Both input streams are bounded by that
-- domain even when only a subset of callbacks became lethal.
local MAXIMUM_OPERATIONS = 64
local MAXIMUM_ORDER = 2_147_483_647
local MAXIMUM_COMPONENT = EntityStateConversionRules.MaximumComponent

local LETHAL_KEYS: { [string]: boolean } = table.freeze({
	player = true,
	source = true,
	body = true,
	operationIndex = true,
	callbackTraversalOrder = true,
	callbackEntityTrajectoryBase = true,
	moverEntityTrajectoryBase = true,
})

local ASSIGNMENT_KEYS: { [string]: boolean } = table.freeze({
	player = true,
	assignment = true,
	playerSourceOrder = true,
	prospectiveState = true,
	nextEntityTrajectoryBase = true,
	nextEntityTrajectoryDelta = true,
	callbackEntityAngularTrajectoryBase = true,
})

local EMPTY_ENTRIES: { PlanEntry } = table.freeze({})
local EMPTY_PLAN: Plan = table.freeze({
	operationCount = 0,
	entries = EMPTY_ENTRIES,
})

local function isIdentity(value: unknown): boolean
	local valueType = type(value)
	return valueType == "table" or valueType == "userdata"
end

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isFiniteVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)
end

local function isBoundedVector(value: unknown): boolean
	if not isFiniteVector(value) then
		return false
	end
	local vector = value :: Vector3
	return math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= MAXIMUM_COMPONENT
end

local function hasExactFrozenShape(value: unknown, allowed: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value :: table) then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in next, raw do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function denseArrayLength(value: unknown, label: string): (number?, string?)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil, label .. "-not-plain-array"
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	local maximumIndex = 0
	for key in next, raw do
		if
			type(key) ~= "number"
			or key ~= key
			or math.abs(key :: number) == math.huge
			or (key :: number) % 1 ~= 0
			or (key :: number) < 1
			or (key :: number) > MAXIMUM_OPERATIONS
		then
			return nil, label .. "-not-dense-bounded-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key :: number)
	end
	if count ~= maximumIndex then
		return nil, label .. "-not-dense-bounded-array"
	end
	return count, nil
end

local function inspectAssignment(value: unknown): (Assignment?, string?)
	if not hasExactFrozenShape(value, ASSIGNMENT_KEYS, 7) then
		return nil, "invalid-mover-normal-to-dead-assignment-shape"
	end
	local raw = value :: { [unknown]: unknown }
	local player = rawget(raw, "player")
	local assignment = rawget(raw, "assignment")
	local prospectiveState = rawget(raw, "prospectiveState")
	local nextEntityTrajectoryBase = rawget(raw, "nextEntityTrajectoryBase")
	local nextEntityTrajectoryDelta = rawget(raw, "nextEntityTrajectoryDelta")
	local callbackEntityAngularTrajectoryBase = rawget(raw, "callbackEntityAngularTrajectoryBase")
	if
		not isIdentity(player)
		or not isIdentity(assignment)
		or not isIdentity(prospectiveState)
		or not isIntegerInRange(rawget(raw, "playerSourceOrder"), 1, MAXIMUM_OPERATIONS)
		or not isBoundedVector(nextEntityTrajectoryBase)
		or EntityStateConversionRules.SnapTrajectoryBase(nextEntityTrajectoryBase) ~= nextEntityTrajectoryBase
		or not isFiniteVector(nextEntityTrajectoryDelta)
		or type(callbackEntityAngularTrajectoryBase) ~= "table"
		or not table.isfrozen(callbackEntityAngularTrajectoryBase :: table)
		or EntityStateConversionRules.InspectAngles(callbackEntityAngularTrajectoryBase)
			~= callbackEntityAngularTrajectoryBase
	then
		return nil, "invalid-mover-normal-to-dead-assignment"
	end
	return value :: Assignment, nil
end

local function inspectLethal(value: unknown): (Lethal?, string?)
	if not hasExactFrozenShape(value, LETHAL_KEYS, 7) then
		return nil, "invalid-mover-normal-to-dead-lethal-shape"
	end
	local raw = value :: { [unknown]: unknown }
	if
		not isIdentity(rawget(raw, "player"))
		or not isIdentity(rawget(raw, "source"))
		or not isIdentity(rawget(raw, "body"))
		or not isIntegerInRange(rawget(raw, "operationIndex"), 1, MAXIMUM_ORDER)
		or not isIntegerInRange(rawget(raw, "callbackTraversalOrder"), 1, MAXIMUM_ORDER)
		or not isBoundedVector(rawget(raw, "callbackEntityTrajectoryBase"))
		or not isBoundedVector(rawget(raw, "moverEntityTrajectoryBase"))
	then
		return nil, "invalid-mover-normal-to-dead-lethal"
	end
	return value :: Lethal, nil
end

function MoverNormalToDeadBindingRules.Plan(lethalsValue: unknown, assignmentsValue: unknown): (Plan?, string?)
	local lethalCount, lethalArrayError = denseArrayLength(lethalsValue, "lethals")
	if lethalCount == nil then
		return nil, lethalArrayError
	end
	local assignmentCount, assignmentArrayError = denseArrayLength(assignmentsValue, "assignments")
	if assignmentCount == nil then
		return nil, assignmentArrayError
	end

	local rawAssignments = assignmentsValue :: { [number]: unknown }
	local assignmentByPlayer: { [any]: Assignment } = {}
	local seenAssignments: { [any]: boolean } = {}
	local previousPlayerSourceOrder = 0
	for index = 1, assignmentCount do
		local assignment, assignmentError = inspectAssignment(rawAssignments[index])
		if not assignment then
			return nil,
				string.format("assignment-%d:%s", index, assignmentError or "invalid-mover-normal-to-dead-assignment")
		end
		if assignment.playerSourceOrder <= previousPlayerSourceOrder then
			return nil, "non-increasing-mover-normal-to-dead-assignment-source-order"
		end
		if assignmentByPlayer[assignment.player] ~= nil then
			return nil, "duplicate-mover-normal-to-dead-assignment-player"
		end
		if seenAssignments[assignment.assignment] then
			return nil, "duplicate-mover-normal-to-dead-assignment-identity"
		end
		previousPlayerSourceOrder = assignment.playerSourceOrder
		assignmentByPlayer[assignment.player] = assignment
		seenAssignments[assignment.assignment] = true
	end

	-- A frame can project live players without producing a lethal callback. The
	-- canonical singleton makes that no-op explicit without retaining unrelated
	-- assignment identities in a death plan.
	if lethalCount == 0 then
		return EMPTY_PLAN, nil
	end

	local rawLethals = lethalsValue :: { [number]: unknown }
	local entries: { PlanEntry } = {}
	local seenPlayers: { [any]: boolean } = {}
	local seenSources: { [any]: boolean } = {}
	local seenBodies: { [any]: boolean } = {}
	local previousOperationIndex = 0
	local previousCallbackTraversalOrder = 0
	for index = 1, lethalCount do
		local lethal, lethalError = inspectLethal(rawLethals[index])
		if not lethal then
			return nil, string.format("lethal-%d:%s", index, lethalError or "invalid-mover-normal-to-dead-lethal")
		end
		if lethal.operationIndex <= previousOperationIndex then
			return nil, "non-increasing-mover-normal-to-dead-operation-index"
		end
		if lethal.callbackTraversalOrder <= previousCallbackTraversalOrder then
			return nil, "non-increasing-mover-normal-to-dead-callback-order"
		end
		if seenPlayers[lethal.player] then
			return nil, "duplicate-mover-normal-to-dead-lethal-player"
		end
		if seenSources[lethal.source] then
			return nil, "duplicate-mover-normal-to-dead-lethal-source"
		end
		if seenBodies[lethal.body] then
			return nil, "duplicate-mover-normal-to-dead-lethal-body"
		end
		local assignment = assignmentByPlayer[lethal.player]
		if not assignment then
			return nil, "missing-mover-normal-to-dead-player-assignment"
		end

		previousOperationIndex = lethal.operationIndex
		previousCallbackTraversalOrder = lethal.callbackTraversalOrder
		seenPlayers[lethal.player] = true
		seenSources[lethal.source] = true
		seenBodies[lethal.body] = true

		local entry: PlanEntry = {
			player = lethal.player,
			source = lethal.source,
			body = lethal.body,
			operationIndex = lethal.operationIndex,
			callbackTraversalOrder = lethal.callbackTraversalOrder,
			callbackEntityTrajectoryBase = lethal.callbackEntityTrajectoryBase,
			moverEntityTrajectoryBase = lethal.moverEntityTrajectoryBase,
			matchedAssignment = assignment,
			assignment = assignment.assignment,
			playerSourceOrder = assignment.playerSourceOrder,
			prospectiveState = assignment.prospectiveState,
			nextEntityTrajectoryBase = assignment.nextEntityTrajectoryBase,
			nextEntityTrajectoryDelta = assignment.nextEntityTrajectoryDelta,
			callbackEntityAngularTrajectoryBase = assignment.callbackEntityAngularTrajectoryBase,
		}
		table.freeze(entry)
		entries[index] = entry
	end
	table.freeze(entries)
	local plan: Plan = {
		operationCount = lethalCount,
		entries = entries,
	}
	table.freeze(plan)
	return plan, nil
end

MoverNormalToDeadBindingRules.EmptyPlan = EMPTY_PLAN
MoverNormalToDeadBindingRules.MaximumOperations = MAXIMUM_OPERATIONS

return table.freeze(MoverNormalToDeadBindingRules)
