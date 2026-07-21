--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only Roblox/Luau adaptation of world-trigger behavior from:
  code/game/g_trigger.c (trigger_push_touch, AimAtTarget,
  trigger_teleporter_touch)
  code/game/bg_misc.c (BG_TouchJumpPad)
  code/game/g_misc.c (TeleportPlayer)
  code/game/g_active.c (G_TouchTriggers jump-pad contact reset)

The bounded definition boundary, positive integer trigger IDs, stable ordering,
oriented-box overlap, and explicit entry-event state are original the Roblox Luau port
adaptations shared by server authority and client prediction.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type TriggerKind = "JumpPad" | "Teleporter"

export type JumpPadDefinition = {
	id: number,
	kind: "JumpPad",
	cframe: CFrame,
	size: Vector3,
	launchVelocity: Vector3,
}

export type TeleporterDefinition = {
	id: number,
	kind: "Teleporter",
	cframe: CFrame,
	size: Vector3,
	destinationPosition: Vector3,
	destinationLook: Vector3,
}

export type Definition = JumpPadDefinition | TeleporterDefinition

export type JumpPadEntryState = {
	activeTriggerId: number?,
}

export type JumpPadResult = {
	velocity: Vector3,
	touchedTriggerId: number?,
	emitEntryEvent: boolean,
	entryState: JumpPadEntryState,
}

export type TeleporterResult = {
	triggerId: number,
	position: Vector3,
	velocity: Vector3,
	look: Vector3,
	movementTime: number,
}

local WorldTriggerRules = {}

local MAXIMUM_DEFINITIONS = 256
local MAXIMUM_TRIGGER_ID = 2_147_483_647
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_TRIGGER_SIZE = 10_000
local MAXIMUM_LAUNCH_SPEED = 2_000
local MINIMUM_TRIGGER_SIZE = 0.001
local TELEPORT_VERTICAL_OFFSET = 0.1
local TELEPORT_EXIT_SPEED = 40
local TELEPORT_KNOCKBACK_SECONDS = 0.16
local OVERLAP_EPSILON = 1e-6

local JUMP_PAD_KEYS: { [string]: boolean } = {
	id = true,
	kind = true,
	cframe = true,
	size = true,
	launchVelocity = true,
}
table.freeze(JUMP_PAD_KEYS)

local TELEPORTER_KEYS: { [string]: boolean } = {
	id = true,
	kind = true,
	cframe = true,
	size = true,
	destinationPosition = true,
	destinationLook = true,
}
table.freeze(TELEPORTER_KEYS)

-- Validation normalizes teleporter look vectors exactly once. This private
-- registry makes canonical frozen arrays opaque capabilities: server authority
-- and owner prediction can verify the same object idempotently without applying
-- Vector3.Unit a second time and introducing a divergent diagonal direction.
local canonicalDefinitionArrays: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.abs(vector.X) <= maximumComponent
		and math.abs(vector.Y) <= maximumComponent
		and math.abs(vector.Z) <= maximumComponent
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_TRIGGER_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_TRIGGER_SIZE and size.Y >= MINIMUM_TRIGGER_SIZE and size.Z >= MINIMUM_TRIGGER_SIZE
end

local function isValidCFrame(value: unknown): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end
	local components = { (value :: CFrame):GetComponents() }
	for index, component in components do
		if not isFinite(component) then
			return false
		end
		if index <= 3 and math.abs(component :: number) > MAXIMUM_COORDINATE then
			return false
		end
		if index > 3 and math.abs(component :: number) > 1 + OVERLAP_EPSILON then
			return false
		end
	end
	return true
end

local function hasExactKeys(value: { [unknown]: unknown }, allowed: { [string]: boolean }): boolean
	local observed = 0
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		observed += 1
	end

	local expected = 0
	for _ in allowed do
		expected += 1
	end
	return observed == expected
end

local function isValidId(value: unknown): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= 1
		and (value :: number) <= MAXIMUM_TRIGGER_ID
end

local function validateDefinition(value: unknown): (Definition?, string?)
	if type(value) ~= "table" then
		return nil, "definition-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not isValidId(source.id) then
		return nil, "invalid-trigger-id"
	end
	if not isValidCFrame(source.cframe) then
		return nil, "invalid-trigger-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-trigger-size"
	end

	if source.kind == "JumpPad" then
		if not hasExactKeys(source, JUMP_PAD_KEYS) then
			return nil, "invalid-jump-pad-shape"
		end
		if not isBoundedVector(source.launchVelocity, MAXIMUM_LAUNCH_SPEED) then
			return nil, "invalid-launch-velocity"
		end
		local launchVelocity = source.launchVelocity :: Vector3
		if launchVelocity.Magnitude <= OVERLAP_EPSILON or launchVelocity.Magnitude > MAXIMUM_LAUNCH_SPEED then
			return nil, "invalid-launch-velocity"
		end
		local definition: JumpPadDefinition = {
			id = source.id :: number,
			kind = "JumpPad",
			cframe = source.cframe :: CFrame,
			size = source.size :: Vector3,
			launchVelocity = launchVelocity,
		}
		table.freeze(definition)
		return definition, nil
	end

	if source.kind == "Teleporter" then
		if not hasExactKeys(source, TELEPORTER_KEYS) then
			return nil, "invalid-teleporter-shape"
		end
		if not isBoundedVector(source.destinationPosition, MAXIMUM_COORDINATE) then
			return nil, "invalid-teleporter-destination"
		end
		if not isBoundedVector(source.destinationLook, 1) then
			return nil, "invalid-teleporter-look"
		end
		local destinationLook = source.destinationLook :: Vector3
		if destinationLook.Magnitude <= OVERLAP_EPSILON then
			return nil, "invalid-teleporter-look"
		end
		local definition: TeleporterDefinition = {
			id = source.id :: number,
			kind = "Teleporter",
			cframe = source.cframe :: CFrame,
			size = source.size :: Vector3,
			destinationPosition = source.destinationPosition :: Vector3,
			destinationLook = destinationLook.Unit,
		}
		table.freeze(definition)
		return definition, nil
	end

	return nil, "invalid-trigger-kind"
end

local function arrayLength(value: { [unknown]: unknown }): (number?, string?)
	local count = 0
	local largestIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "definitions-not-dense-array"
		end
		count += 1
		largestIndex = math.max(largestIndex, key)
		if count > MAXIMUM_DEFINITIONS or largestIndex > MAXIMUM_DEFINITIONS then
			return nil, "too-many-definitions"
		end
	end
	if largestIndex ~= count then
		return nil, "definitions-not-dense-array"
	end
	return count, nil
end

local function overlaps(definition: Definition, origin: Vector3, colliderSize: Vector3, centerOffset: Vector3): boolean
	local colliderCenter = origin + centerOffset
	local centerDelta = colliderCenter - definition.cframe.Position
	local colliderHalf = colliderSize * 0.5
	local triggerHalf = definition.size * 0.5
	local right = definition.cframe.RightVector
	local up = definition.cframe.UpVector
	local back = -definition.cframe.LookVector
	local worldAxes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local triggerAxes = { right, up, back }
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, right, up, back }
	for _, worldAxis in worldAxes do
		for _, triggerAxis in triggerAxes do
			table.insert(axes, worldAxis:Cross(triggerAxis))
		end
	end

	-- Separating-axis test for the axis-aligned player hull against the
	-- oriented trigger box. Near-zero cross axes are parallel duplicates.
	for _, axis in axes do
		if axis:Dot(axis) <= OVERLAP_EPSILON * OVERLAP_EPSILON then
			continue
		end
		local colliderRadius = colliderHalf.X * math.abs(axis.X)
			+ colliderHalf.Y * math.abs(axis.Y)
			+ colliderHalf.Z * math.abs(axis.Z)
		local triggerRadius = triggerHalf.X * math.abs(right:Dot(axis))
			+ triggerHalf.Y * math.abs(up:Dot(axis))
			+ triggerHalf.Z * math.abs(back:Dot(axis))
		if math.abs(centerDelta:Dot(axis)) > colliderRadius + triggerRadius + OVERLAP_EPSILON then
			return false
		end
	end
	return true
end

local function teleporterExitOverlaps(source: TeleporterDefinition, target: TeleporterDefinition): boolean
	local exitOrigin = source.destinationPosition + Vector3.yAxis * TELEPORT_VERTICAL_OFFSET
	return overlaps(target, exitOrigin, Constants.StandingColliderSize, Constants.StandingColliderCenterOffset)
		or overlaps(target, exitOrigin, Constants.CrouchedColliderSize, Constants.CrouchedColliderCenterOffset)
end

local function validateTeleporterExits(definitions: { Definition }): string?
	local teleporters: { TeleporterDefinition } = {}
	for _, definition in definitions do
		if definition.kind == "Teleporter" then
			table.insert(teleporters, definition)
		end
	end

	for _, source in teleporters do
		local exitOrigin = source.destinationPosition + Vector3.yAxis * TELEPORT_VERTICAL_OFFSET
		if not isBoundedVector(exitOrigin, MAXIMUM_COORDINATE) then
			return string.format("teleporter-%d:exit-out-of-bounds", source.id)
		end
		for _, target in teleporters do
			if teleporterExitOverlaps(source, target) then
				if source.id == target.id then
					return string.format("teleporter-%d:destination-overlaps-self", source.id)
				end
				return string.format("teleporter-%d:destination-overlaps-teleporter-%d", source.id, target.id)
			end
		end
	end
	return nil
end

function WorldTriggerRules.ValidateAndOrderDefinitions(value: unknown): ({ Definition }?, string?)
	if type(value) ~= "table" then
		return nil, "definitions-not-array"
	end
	local source = value :: { [unknown]: unknown }
	if canonicalDefinitionArrays[source :: any] then
		return source :: any, nil
	end
	local count, arrayError = arrayLength(source)
	if not count then
		return nil, arrayError
	end

	local definitions: { Definition } = {}
	local observedIds: { [number]: boolean } = {}
	for index = 1, count do
		local definition, definitionError = validateDefinition(source[index])
		if not definition then
			return nil, string.format("definition-%d:%s", index, definitionError or "invalid")
		end
		if observedIds[definition.id] then
			return nil, string.format("definition-%d:duplicate-trigger-id", index)
		end
		observedIds[definition.id] = true
		table.insert(definitions, definition)
	end

	table.sort(definitions, function(left, right): boolean
		return left.id < right.id
	end)
	local exitError = validateTeleporterExits(definitions)
	if exitError then
		return nil, exitError
	end
	table.freeze(definitions)
	canonicalDefinitionArrays[definitions] = true
	return definitions, nil
end

function WorldTriggerRules.IsCanonicalDefinitions(value: unknown): boolean
	return type(value) == "table" and canonicalDefinitionArrays[value :: any] == true
end

function WorldTriggerRules.AimAtTarget(triggerCenter: Vector3, targetPosition: Vector3, gravity: number): Vector3?
	if
		not isBoundedVector(triggerCenter, MAXIMUM_COORDINATE)
		or not isBoundedVector(targetPosition, MAXIMUM_COORDINATE)
		or not isFinite(gravity)
		or gravity <= 0
	then
		return nil
	end

	local height = targetPosition.Y - triggerCenter.Y
	if height <= 0 then
		return nil
	end
	local flightTime = math.sqrt(height / (0.5 * gravity))
	if not isFinite(flightTime) or flightTime <= OVERLAP_EPSILON then
		return nil
	end

	local horizontal = Vector3.new(targetPosition.X - triggerCenter.X, 0, targetPosition.Z - triggerCenter.Z)
	local velocity = horizontal / flightTime + Vector3.yAxis * (flightTime * gravity)
	if not isBoundedVector(velocity, MAXIMUM_LAUNCH_SPEED) or velocity.Magnitude > MAXIMUM_LAUNCH_SPEED then
		return nil
	end
	return velocity
end

function WorldTriggerRules.Overlaps(
	definition: Definition,
	origin: Vector3,
	colliderSize: Vector3,
	centerOffset: Vector3
): boolean
	if
		not isBoundedVector(origin, MAXIMUM_COORDINATE)
		or not isValidSize(colliderSize)
		or not isBoundedVector(centerOffset, MAXIMUM_TRIGGER_SIZE)
	then
		return false
	end
	return overlaps(definition, origin, colliderSize, centerOffset)
end

function WorldTriggerRules.FindTouching(
	definitions: { Definition },
	origin: Vector3,
	colliderSize: Vector3,
	centerOffset: Vector3
): { Definition }
	if
		not isBoundedVector(origin, MAXIMUM_COORDINATE)
		or not isValidSize(colliderSize)
		or not isBoundedVector(centerOffset, MAXIMUM_TRIGGER_SIZE)
	then
		return {}
	end

	local touching: { Definition } = {}
	for _, definition in definitions do
		if overlaps(definition, origin, colliderSize, centerOffset) then
			table.insert(touching, definition)
		end
	end
	table.sort(touching, function(left, right): boolean
		return left.id < right.id
	end)
	return touching
end

function WorldTriggerRules.EmptyJumpPadEntryState(): JumpPadEntryState
	local state: JumpPadEntryState = {
		activeTriggerId = nil,
	}
	table.freeze(state)
	return state
end

function WorldTriggerRules.ResolveJumpPad(
	touching: { Definition },
	currentVelocity: Vector3,
	previousState: JumpPadEntryState
): JumpPadResult
	local selected: JumpPadDefinition? = nil
	for _, definition in touching do
		if definition.kind == "JumpPad" and (not selected or definition.id < selected.id) then
			selected = definition
		end
	end

	if not selected then
		return {
			velocity = currentVelocity,
			touchedTriggerId = nil,
			emitEntryEvent = false,
			entryState = WorldTriggerRules.EmptyJumpPadEntryState(),
		}
	end

	local triggerId = selected.id
	local entryState: JumpPadEntryState = {
		activeTriggerId = triggerId,
	}
	table.freeze(entryState)
	return {
		-- BG_TouchJumpPad uses VectorCopy: all three components are replaced on
		-- every touched frame, even if the entry event was already emitted.
		velocity = selected.launchVelocity,
		touchedTriggerId = triggerId,
		emitEntryEvent = previousState.activeTriggerId ~= triggerId,
		entryState = entryState,
	}
end

function WorldTriggerRules.ResolveTeleporter(touching: { Definition }): TeleporterResult?
	local selected: TeleporterDefinition? = nil
	for _, definition in touching do
		if definition.kind == "Teleporter" and (not selected or definition.id < selected.id) then
			selected = definition
		end
	end
	if not selected then
		return nil
	end

	local look = selected.destinationLook
	return {
		triggerId = selected.id,
		position = selected.destinationPosition + Vector3.yAxis * TELEPORT_VERTICAL_OFFSET,
		velocity = look * TELEPORT_EXIT_SPEED,
		look = look,
		movementTime = TELEPORT_KNOCKBACK_SECONDS,
	}
end

WorldTriggerRules.MaximumDefinitions = MAXIMUM_DEFINITIONS
WorldTriggerRules.MaximumTriggerId = MAXIMUM_TRIGGER_ID
WorldTriggerRules.MaximumCoordinate = MAXIMUM_COORDINATE
WorldTriggerRules.MaximumTriggerSize = MAXIMUM_TRIGGER_SIZE
WorldTriggerRules.MaximumLaunchSpeed = MAXIMUM_LAUNCH_SPEED
WorldTriggerRules.TeleportVerticalOffset = TELEPORT_VERTICAL_OFFSET
WorldTriggerRules.TeleportExitSpeed = TELEPORT_EXIT_SPEED
WorldTriggerRules.TeleportKnockbackSeconds = TELEPORT_KNOCKBACK_SECONDS

return table.freeze(WorldTriggerRules)
