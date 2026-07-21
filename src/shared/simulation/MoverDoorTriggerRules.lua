--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure door-trigger geometry and touch decisions translated from Quake III Arena:
  code/game/g_mover.c (Think_SpawnNewDoorTrigger, Touch_DoorTrigger,
  Touch_DoorTriggerSpectator)

Entity allocation is intentionally external: Q3 creates door_trigger through
G_Spawn after map spawn, so the server owner must supply the committed world
entity identity before this module can materialize a trigger.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Constants = require(script.Parent.Constants)
local MoverBinaryPolicy = require(script.Parent.MoverBinaryPolicy)
local MoverBinaryState = require(script.Parent.MoverBinaryState)
local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type Policy = MoverBinaryPolicy.Policy
export type Identity = {
	teamId: string,
	bodyId: string,
	sourceOrder: number,
	generation: number,
}
export type Definition = {
	kind: "Door" | "Plat",
	teamId: string,
	captainMoverId: string,
	bodyId: string,
	sourceOrder: number,
	generation: number,
	cframe: CFrame,
	size: Vector3,
	expandedAxis: number,
}
export type TouchDisposition = "None" | "Use" | "SpectatorTeleport"
export type TouchResult = {
	disposition: TouchDisposition,
	captainMoverId: string?,
	position: Vector3?,
	look: Vector3?,
}

local MoverDoorTriggerRules = {}

local CANONICAL_DEFINITIONS: { [{ Definition }]: boolean } = setmetatable({}, { __mode = "k" })

local EXPANSION = 120 * Constants.UnitsToStuds
local PLAT_INSET = 33 * Constants.UnitsToStuds
local PLAT_TOP_EXTENSION = 8 * Constants.UnitsToStuds
local PLAT_MINIMUM_THICKNESS = Constants.UnitsToStuds
local SPECTATOR_OFFSET = 10 * Constants.UnitsToStuds
local MAXIMUM_SOURCE_ORDER = 1022
local MAXIMUM_GENERATION = 9_007_199_254_740_991

local IDENTITY_KEYS = table.freeze({
	teamId = true,
	bodyId = true,
	sourceOrder = true,
	generation = true,
})

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function exactKeys(value: { [unknown]: unknown }, keys: { [string]: boolean }, count: number): boolean
	local observed = 0
	for key in value do
		if type(key) ~= "string" or keys[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == count
end

local function denseLength(value: unknown, maximum: number, label: string): (number?, string?)
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
		if maximumIndex > maximum or count > maximum then
			return nil, "too-many-" .. label
		end
	end
	if maximumIndex ~= count then
		return nil, label .. "-not-dense-array"
	end
	return count, nil
end

local function orientedHalfExtents(cframe: CFrame, size: Vector3): Vector3
	local half = size * 0.5
	local right = cframe.RightVector
	local up = cframe.UpVector
	local back = cframe.ZVector
	return Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
	)
end

function MoverDoorTriggerRules.ValidateAndOrderPolicies(
	programsValue: unknown,
	policiesValue: unknown
): ({ Policy }?, string?)
	return MoverBinaryPolicy.ValidateAndOrder(programsValue, policiesValue)
end

function MoverDoorTriggerRules.Build(
	programsValue: unknown,
	policiesValue: unknown,
	identitiesValue: unknown
): ({ Definition }?, string?)
	local programs, programError = MoverBinaryState.ValidateAndOrderPrograms(programsValue)
	if not programs then
		return nil, "programs-invalid:" .. (programError or "invalid")
	end
	local policies, policyError = MoverDoorTriggerRules.ValidateAndOrderPolicies(programs, policiesValue)
	if not policies then
		return nil, policyError
	end
	local triggerCount = 0
	for _, policy in policies do
		if policy.activationBehavior ~= MoverBinaryPolicy.ActivationBehavior.None then
			triggerCount += 1
		end
	end
	local identityCount, identityError = denseLength(identitiesValue, triggerCount, "identities")
	if not identityCount then
		return nil, identityError
	end
	if identityCount ~= triggerCount then
		return nil, "mover-trigger-identity-count-mismatch"
	end
	local identityByTeam: { [string]: Identity } = {}
	local sourceOrders: { [number]: boolean } = {}
	local bodyIds: { [string]: boolean } = {}
	for index = 1, identityCount do
		local rawValue = (identitiesValue :: { [unknown]: unknown })[index]
		if type(rawValue) ~= "table" or not exactKeys(rawValue :: any, IDENTITY_KEYS, 4) then
			return nil, string.format("identity-%d:invalid-shape", index)
		end
		local raw = rawValue :: any
		if not isId(raw.teamId) or identityByTeam[raw.teamId] then
			return nil, string.format("identity-%d:invalid-team", index)
		end
		if not isId(raw.bodyId) or bodyIds[raw.bodyId] then
			return nil, string.format("identity-%d:invalid-body-id", index)
		end
		if not isInteger(raw.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) or sourceOrders[raw.sourceOrder] then
			return nil, string.format("identity-%d:invalid-source-order", index)
		end
		if not isInteger(raw.generation, 1, MAXIMUM_GENERATION) then
			return nil, string.format("identity-%d:invalid-generation", index)
		end
		local identity: Identity = {
			teamId = raw.teamId,
			bodyId = raw.bodyId,
			sourceOrder = raw.sourceOrder,
			generation = raw.generation,
		}
		table.freeze(identity)
		identityByTeam[identity.teamId] = identity
		bodyIds[identity.bodyId] = true
		sourceOrders[identity.sourceOrder] = true
	end

	local programsByTeam: { [string]: { MoverBinaryState.Program } } = {}
	for _, program in programs do
		local members = programsByTeam[program.teamId]
		if not members then
			members = {}
			programsByTeam[program.teamId] = members
		end
		table.insert(members, program)
	end
	local definitions: { Definition } = {}
	for _, policy in policies do
		if policy.activationBehavior == MoverBinaryPolicy.ActivationBehavior.None then
			continue
		end
		local identity = identityByTeam[policy.teamId]
		if not identity then
			return nil, "missing-door-identity:" .. policy.teamId
		end
		local minimum = Vector3.new(math.huge, math.huge, math.huge)
		local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, program in assert(programsByTeam[policy.teamId], "validated team lost programs") do
			local pose = CFrame.new(program.position1) * program.cframe.Rotation
			local half = orientedHalfExtents(pose, program.size)
			minimum = minimum:Min(program.position1 - half)
			maximum = maximum:Max(program.position1 + half)
		end
		local kind: "Door" | "Plat" = if policy.activationBehavior
				== MoverBinaryPolicy.ActivationBehavior.PlatTouch
			then "Plat"
			else "Door"
		local expandedAxis = 3
		if kind == "Door" then
			local dimensions = maximum - minimum
			expandedAxis = 1
			if dimensions.Y < dimensions.X then
				expandedAxis = 2
			end
			local thinnest = if expandedAxis == 1 then dimensions.X else dimensions.Y
			if dimensions.Z < thinnest then
				expandedAxis = 3
			end
			local expansion = if expandedAxis == 1
				then Vector3.xAxis * EXPANSION
				elseif expandedAxis == 2 then Vector3.yAxis * EXPANSION
				else Vector3.zAxis * EXPANSION
			minimum -= expansion
			maximum += expansion
		else
			local captain: MoverBinaryState.Program? = nil
			for _, program in assert(programsByTeam[policy.teamId], "validated platform team lost programs") do
				if program.id == policy.captainMoverId then
					captain = program
					break
				end
			end
			if not captain or captain.cframe.Rotation ~= CFrame.identity then
				return nil, "plat-trigger-requires-axis-aligned-captain:" .. policy.teamId
			end
			local half = captain.size * 0.5
			minimum = captain.position1 - half + Vector3.new(PLAT_INSET, PLAT_INSET, 0)
			maximum = captain.position1 + half + Vector3.new(-PLAT_INSET, -PLAT_INSET, PLAT_TOP_EXTENSION)
			if maximum.X <= minimum.X then
				minimum = Vector3.new(captain.position1.X, minimum.Y, minimum.Z)
				maximum = Vector3.new(captain.position1.X + PLAT_MINIMUM_THICKNESS, maximum.Y, maximum.Z)
			end
			if maximum.Y <= minimum.Y then
				minimum = Vector3.new(minimum.X, captain.position1.Y, minimum.Z)
				maximum = Vector3.new(maximum.X, captain.position1.Y + PLAT_MINIMUM_THICKNESS, maximum.Z)
			end
		end
		local definition: Definition = {
			kind = kind,
			teamId = policy.teamId,
			captainMoverId = policy.captainMoverId,
			bodyId = identity.bodyId,
			sourceOrder = identity.sourceOrder,
			generation = identity.generation,
			cframe = CFrame.new((minimum + maximum) * 0.5),
			size = maximum - minimum,
			expandedAxis = expandedAxis,
		}
		table.freeze(definition)
		table.insert(definitions, definition)
	end
	table.sort(definitions, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(definitions)
	CANONICAL_DEFINITIONS[definitions] = true
	return definitions, nil
end

function MoverDoorTriggerRules.FindTouching(
	definitionsValue: unknown,
	positionValue: unknown,
	sizeValue: unknown,
	centerOffsetValue: unknown
): ({ Definition }?, string?)
	if type(definitionsValue) ~= "table" or CANONICAL_DEFINITIONS[definitionsValue :: any] ~= true then
		return nil, "definitions-not-canonical"
	end
	if
		typeof(positionValue) ~= "Vector3"
		or typeof(sizeValue) ~= "Vector3"
		or typeof(centerOffsetValue) ~= "Vector3"
	then
		return nil, "invalid-touch-hull"
	end
	local position = positionValue :: Vector3
	local size = sizeValue :: Vector3
	local centerOffset = centerOffsetValue :: Vector3
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return nil, "invalid-touch-size"
	end
	local center = position + centerOffset
	local half = size * 0.5
	local touching: { Definition } = {}
	for _, definition in definitionsValue :: { Definition } do
		local triggerHalf = definition.size * 0.5
		local delta = center - definition.cframe.Position
		if
			math.abs(delta.X) <= half.X + triggerHalf.X
			and math.abs(delta.Y) <= half.Y + triggerHalf.Y
			and math.abs(delta.Z) <= half.Z + triggerHalf.Z
		then
			table.insert(touching, definition)
		end
	end
	table.freeze(touching)
	return touching, nil
end

function MoverDoorTriggerRules.ResolveTouch(
	definition: Definition,
	moverStateValue: unknown,
	positionValue: unknown,
	isSpectatorValue: unknown
): (TouchResult?, string?)
	if typeof(positionValue) ~= "Vector3" or type(isSpectatorValue) ~= "boolean" then
		return nil, "invalid-touch-input"
	end
	local moverState = moverStateValue
	if
		moverState ~= MoverTrajectory.BinaryStates.Pos1
		and moverState ~= MoverTrajectory.BinaryStates.Pos2
		and moverState ~= MoverTrajectory.BinaryStates.OneToTwo
		and moverState ~= MoverTrajectory.BinaryStates.TwoToOne
	then
		return nil, "invalid-mover-state"
	end
	if isSpectatorValue then
		if definition.kind == "Plat" then
			return table.freeze({ disposition = "None" }), nil
		end
		if moverState == MoverTrajectory.BinaryStates.OneToTwo or moverState == MoverTrajectory.BinaryStates.Pos2 then
			return table.freeze({ disposition = "None" }), nil
		end
		local position = positionValue :: Vector3
		local center = definition.cframe.Position
		local half = definition.size * 0.5
		local axis = definition.expandedAxis
		local component = if axis == 1 then position.X elseif axis == 2 then position.Y else position.Z
		local centerComponent = if axis == 1 then center.X elseif axis == 2 then center.Y else center.Z
		local sign = if component >= centerComponent then 1 else -1
		local direction = if axis == 1
			then Vector3.xAxis * sign
			elseif axis == 2 then Vector3.yAxis * sign
			else Vector3.zAxis * sign
		local destination = center
			+ direction * ((if axis == 1 then half.X elseif axis == 2 then half.Y else half.Z) + SPECTATOR_OFFSET)
		return table.freeze({
			disposition = "SpectatorTeleport",
			position = destination,
			look = direction,
		}),
			nil
	end
	if definition.kind == "Plat" and moverState ~= MoverTrajectory.BinaryStates.Pos1 then
		return table.freeze({ disposition = "None" }), nil
	elseif definition.kind == "Door" and moverState == MoverTrajectory.BinaryStates.OneToTwo then
		return table.freeze({ disposition = "None" }), nil
	end
	return table.freeze({
		disposition = "Use",
		captainMoverId = definition.captainMoverId,
	}), nil
end

MoverDoorTriggerRules.Expansion = EXPANSION
MoverDoorTriggerRules.PlatInset = PLAT_INSET
MoverDoorTriggerRules.PlatTopExtension = PLAT_TOP_EXTENSION
MoverDoorTriggerRules.SpectatorOffset = SPECTATOR_OFFSET

return table.freeze(MoverDoorTriggerRules)
