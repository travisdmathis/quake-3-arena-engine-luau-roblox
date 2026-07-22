--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure mover-participant rules translated from Quake III Arena:
  code/game/bg_public.h (ITEM_RADIUS, MASK_SOLID, MASK_DEADSOLID,
    EVENT_VALID_MSEC)
  code/game/g_items.c (Touch_Item, RespawnItem, LaunchItem, G_RunItem)
  code/game/g_mover.c (G_TestEntityPosition, G_MoverPush, Blocked_Door)
  code/game/g_team.c (Team_ResetFlag, Team_FreeEntity,
    Team_DroppedFlagThink)
  code/game/g_utils.c (G_FreeEntity)

Quake keeps linked ET_ITEM entities in the mover domain even while their
CONTENTS_TRIGGER bit is cleared. That lets hidden respawnable items and hidden
base flags continue riding movers. Unlinked and freed entities do not
participate. This module models only that collision/lifecycle boundary; grants,
scores, flag ownership, presentation, events, Instances, and source-order lease
ownership remain server-service responsibilities.

The Q3 item runner and mover position test deliberately use different masks:
G_RunItem defaults to MASK_DEADSOLID, while G_TestEntityPosition defaults to
MASK_SOLID for a non-client ET_ITEM. Participant bodies therefore carry the
exact mover-test mask. CreateFromInsertion converts the combined death-drop
body contract into this mover-only representation.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type BindingKind = "Item" | "TeamFlag"
export type ItemBinding = {
	read kind: "Item",
	read bodyId: string,
	read itemId: string,
}
export type TeamFlagBinding = {
	read kind: "TeamFlag",
	read bodyId: string,
	read teamId: "Red" | "Blue" | "Neutral",
}
export type Binding = ItemBinding | TeamFlagBinding

export type Body = {
	read id: string,
	read sourceOrder: number,
	read position: Vector3,
	read size: Vector3,
	read centerOffset: Vector3,
	read velocity: Vector3,
	read groundMoverId: string?,
	read contents: number,
	read clipMask: number,
}

export type Lifecycle =
	"ActiveLinked"
	| "HiddenLinked"
	| "PendingUnlinkAfterEvent"
	| "PendingFreeAfterEvent"
	| "Unlinked"
	| "Freed"

export type Participant = {
	read binding: Binding,
	read body: Body,
	read lifecycle: Lifecycle,
	read dropped: boolean,
}

export type TouchIntent = "MapRespawn" | "MapNeverRespawn" | "BaseFlagTaken" | "DroppedTaken" | "DroppedFlagReturned"

export type AuthorityAction = "None" | "Free" | "PopAndFree" | "ReturnFlag"

export type BodyMutation =
	{ read kind: "Remove", read bodyId: string }
	| { read kind: "Replace", read body: Body }
	| { read kind: "Insert", read body: Body }

export type Transition = {
	read participant: Participant,
	read bodyMutation: BodyMutation?,
	read authorityAction: AuthorityAction,
	read releaseSourceOrder: boolean,
}

export type Collection = {
	read bodies: { Body },
	read bindingsByBodyId: { [string]: Binding },
}

export type Composition = {
	read participants: { Participant },
	read collection: Collection,
}

export type SynchronousCrushEffect = {
	read kind: "Retain",
	read insertedBodies: { Body },
}

local MoverItemFlagParticipantRules = {}

local ITEM_HULL_EDGE = 3
local CONTENTS_NONE = 0
local CONTENTS_SOLID = 0x1
local CONTENTS_PLAYERCLIP = 0x10000
local CONTENTS_TRIGGER = 0x40000000
local MOVER_POSITION_CLIP_MASK = CONTENTS_SOLID
local RUN_ITEM_CLIP_MASK = bit32.bor(CONTENTS_SOLID, CONTENTS_PLAYERCLIP)
-- q_shared.h reserves entity numbers 0..63 for clients. Luau sourceOrder is
-- entityNum + 1, so every ET_ITEM/flag begins at world source order 65.
local FIRST_WORLD_SOURCE_ORDER = 65
local MAXIMUM_NORMAL_SOURCE_ORDER = 1022
local MAXIMUM_PARTICIPANTS = 256
local MAXIMUM_STABLE_ID_LENGTH = 64
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_VELOCITY_COMPONENT = 100_000
local MAXIMUM_OPERATION_ORDER = 2_147_483_647
local MAXIMUM_ELAPSED_MILLISECONDS = 2_147_483_647
local LAUNCH_HORIZONTAL_SPEED = 15
local LAUNCH_MINIMUM_VERTICAL_SPEED = 15
local LAUNCH_MAXIMUM_VERTICAL_SPEED = 25
local VECTOR_TOLERANCE = 1e-4
local EVENT_VALID_MILLISECONDS = 300
local LAUNCH_TIMEOUT_MILLISECONDS = 30_000
local DECLARED_CTF_FLAG_RETURN_MILLISECONDS = 40_000

local Lifecycle = table.freeze({
	ActiveLinked = "ActiveLinked" :: "ActiveLinked",
	HiddenLinked = "HiddenLinked" :: "HiddenLinked",
	PendingUnlinkAfterEvent = "PendingUnlinkAfterEvent" :: "PendingUnlinkAfterEvent",
	PendingFreeAfterEvent = "PendingFreeAfterEvent" :: "PendingFreeAfterEvent",
	Unlinked = "Unlinked" :: "Unlinked",
	Freed = "Freed" :: "Freed",
})

local TouchIntent = table.freeze({
	MapRespawn = "MapRespawn" :: "MapRespawn",
	MapNeverRespawn = "MapNeverRespawn" :: "MapNeverRespawn",
	BaseFlagTaken = "BaseFlagTaken" :: "BaseFlagTaken",
	DroppedTaken = "DroppedTaken" :: "DroppedTaken",
	DroppedFlagReturned = "DroppedFlagReturned" :: "DroppedFlagReturned",
})

local BindingKinds = table.freeze({
	Item = "Item" :: "Item",
	TeamFlag = "TeamFlag" :: "TeamFlag",
})

local PARTICIPANT_KEYS: { [string]: boolean } = table.freeze({
	binding = true,
	body = true,
	lifecycle = true,
	dropped = true,
})
local ITEM_BINDING_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	bodyId = true,
	itemId = true,
})
local TEAM_FLAG_BINDING_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	bodyId = true,
	teamId = true,
})
local BODY_KEYS: { [string]: boolean } = table.freeze({
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
local INSERTION_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	order = true,
	body = true,
	binding = true,
})
local INSERTION_ORDER_KEYS: { [string]: boolean } = table.freeze({
	operationOrder = true,
	phase = true,
	ordinal = true,
})
local TEAM_FLAG_ORDINAL: { [string]: number } = table.freeze({
	Red = 7,
	Blue = 8,
	Neutral = 9,
})
local POWERUP_ITEM_ORDINAL: { [string]: number } = table.freeze({
	item_quad = 1,
	item_enviro = 2,
	item_haste = 3,
	item_invis = 4,
	item_regen = 5,
	item_flight = 6,
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

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= maximumComponent
end

local function isItemHullSize(value: unknown): boolean
	return typeof(value) == "Vector3"
		and (value :: Vector3).X == ITEM_HULL_EDGE
		and (value :: Vector3).Y == ITEM_HULL_EDGE
		and (value :: Vector3).Z == ITEM_HULL_EDGE
end

local function isZeroVector(value: unknown): boolean
	return typeof(value) == "Vector3"
		and (value :: Vector3).X == 0
		and (value :: Vector3).Y == 0
		and (value :: Vector3).Z == 0
end

local function isStableId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_STABLE_ID_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function isLifecycle(value: unknown): boolean
	return value == Lifecycle.ActiveLinked
		or value == Lifecycle.HiddenLinked
		or value == Lifecycle.PendingUnlinkAfterEvent
		or value == Lifecycle.PendingFreeAfterEvent
		or value == Lifecycle.Unlinked
		or value == Lifecycle.Freed
end

local function isLinked(lifecycle: Lifecycle): boolean
	return lifecycle == Lifecycle.ActiveLinked
		or lifecycle == Lifecycle.HiddenLinked
		or lifecycle == Lifecycle.PendingUnlinkAfterEvent
		or lifecycle == Lifecycle.PendingFreeAfterEvent
end

local function contentsForLifecycle(lifecycle: Lifecycle): number
	return if lifecycle == Lifecycle.ActiveLinked then CONTENTS_TRIGGER else CONTENTS_NONE
end

local function validateBinding(value: unknown): (Binding?, string?)
	if type(value) ~= "table" then
		return nil, "binding-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if raw.kind == BindingKinds.Item then
		if not hasExactKeys(raw, ITEM_BINDING_KEYS, 3) then
			return nil, "invalid-item-binding-shape"
		end
		if not isStableId(raw.bodyId) or not isStableId(raw.itemId) then
			return nil, "invalid-item-binding"
		end
		local binding: ItemBinding = {
			kind = BindingKinds.Item,
			bodyId = raw.bodyId :: string,
			itemId = raw.itemId :: string,
		}
		table.freeze(binding)
		return binding, nil
	elseif raw.kind == BindingKinds.TeamFlag then
		if not hasExactKeys(raw, TEAM_FLAG_BINDING_KEYS, 3) then
			return nil, "invalid-team-flag-binding-shape"
		end
		if not isStableId(raw.bodyId) or (raw.teamId ~= "Red" and raw.teamId ~= "Blue" and raw.teamId ~= "Neutral") then
			return nil, "invalid-team-flag-binding"
		end
		local binding: TeamFlagBinding = {
			kind = BindingKinds.TeamFlag,
			bodyId = raw.bodyId :: string,
			teamId = raw.teamId :: "Red" | "Blue" | "Neutral",
		}
		table.freeze(binding)
		return binding, nil
	end
	return nil, "invalid-binding-kind"
end

local function validateBody(value: unknown, expectedContents: number, expectedClipMask: number): (Body?, string?)
	if type(value) ~= "table" then
		return nil, "body-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	local expectedCount = if raw.groundMoverId == nil then 8 else 9
	if not hasExactKeys(raw, BODY_KEYS, expectedCount) then
		return nil, "invalid-body-shape"
	end
	if
		not isStableId(raw.id)
		or not isIntegerInRange(raw.sourceOrder, FIRST_WORLD_SOURCE_ORDER, MAXIMUM_NORMAL_SOURCE_ORDER)
		or not isBoundedVector(raw.position, MAXIMUM_COORDINATE)
		or not isItemHullSize(raw.size)
		or not isZeroVector(raw.centerOffset)
		or not isBoundedVector(raw.velocity, MAXIMUM_VELOCITY_COMPONENT)
		or (raw.groundMoverId ~= nil and not isStableId(raw.groundMoverId))
		or raw.contents ~= expectedContents
		or raw.clipMask ~= expectedClipMask
	then
		return nil, "invalid-q3-item-body"
	end
	local body: Body = {
		id = raw.id :: string,
		sourceOrder = raw.sourceOrder :: number,
		position = raw.position :: Vector3,
		size = raw.size :: Vector3,
		centerOffset = raw.centerOffset :: Vector3,
		velocity = raw.velocity :: Vector3,
		groundMoverId = raw.groundMoverId :: string?,
		contents = expectedContents,
		clipMask = expectedClipMask,
	}
	table.freeze(body)
	return body, nil
end

local function validateParticipant(value: unknown): (Participant?, string?)
	if type(value) ~= "table" then
		return nil, "participant-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, PARTICIPANT_KEYS, 4) then
		return nil, "invalid-participant-shape"
	end
	if not isLifecycle(raw.lifecycle) or type(raw.dropped) ~= "boolean" then
		return nil, "invalid-participant-lifecycle"
	end
	local lifecycle = raw.lifecycle :: Lifecycle
	local binding, bindingError = validateBinding(raw.binding)
	if not binding then
		return nil, bindingError
	end
	local body, bodyError = validateBody(raw.body, contentsForLifecycle(lifecycle), MOVER_POSITION_CLIP_MASK)
	if not body then
		return nil, bodyError
	end
	if binding.bodyId ~= body.id then
		return nil, "participant-body-binding-mismatch"
	end
	local participant: Participant = {
		binding = binding,
		body = body,
		lifecycle = lifecycle,
		dropped = raw.dropped :: boolean,
	}
	table.freeze(participant)
	return participant, nil
end

local function cloneBodyWith(body: Body, contents: number, position: Vector3?, groundMoverId: string?): Body
	local nextBody: Body = {
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = position or body.position,
		size = body.size,
		centerOffset = body.centerOffset,
		velocity = body.velocity,
		groundMoverId = groundMoverId,
		contents = contents,
		clipMask = MOVER_POSITION_CLIP_MASK,
	}
	table.freeze(nextBody)
	return nextBody
end

local function cloneParticipant(participant: Participant, lifecycle: Lifecycle, body: Body): Participant
	local nextParticipant: Participant = {
		binding = participant.binding,
		body = body,
		lifecycle = lifecycle,
		dropped = participant.dropped,
	}
	table.freeze(nextParticipant)
	return nextParticipant
end

local function bodiesEqual(left: Body, right: Body): boolean
	return left.id == right.id
		and left.sourceOrder == right.sourceOrder
		and left.position == right.position
		and left.size == right.size
		and left.centerOffset == right.centerOffset
		and left.velocity == right.velocity
		and left.groundMoverId == right.groundMoverId
		and left.contents == right.contents
		and left.clipMask == right.clipMask
end

local function makeMutation(previous: Participant, nextParticipant: Participant): BodyMutation?
	local wasLinked = isLinked(previous.lifecycle)
	local nowLinked = isLinked(nextParticipant.lifecycle)
	if wasLinked and not nowLinked then
		local mutation: BodyMutation = {
			kind = "Remove",
			bodyId = previous.body.id,
		}
		table.freeze(mutation)
		return mutation
	elseif not wasLinked and nowLinked then
		local mutation: BodyMutation = {
			kind = "Insert",
			body = nextParticipant.body,
		}
		table.freeze(mutation)
		return mutation
	elseif wasLinked and nowLinked and not bodiesEqual(previous.body, nextParticipant.body) then
		local mutation: BodyMutation = {
			kind = "Replace",
			body = nextParticipant.body,
		}
		table.freeze(mutation)
		return mutation
	end
	return nil
end

local function makeTransition(
	previous: Participant,
	lifecycle: Lifecycle,
	authorityAction: AuthorityAction,
	releaseSourceOrder: boolean
): Transition
	local body = cloneBodyWith(previous.body, contentsForLifecycle(lifecycle), nil, previous.body.groundMoverId)
	local nextParticipant = cloneParticipant(previous, lifecycle, body)
	local transition: Transition = {
		participant = nextParticipant,
		bodyMutation = makeMutation(previous, nextParticipant),
		authorityAction = authorityAction,
		releaseSourceOrder = releaseSourceOrder,
	}
	table.freeze(transition)
	return transition
end

local function isValidLaunchVelocity(velocity: Vector3): boolean
	local horizontal = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	return math.abs(horizontal - LAUNCH_HORIZONTAL_SPEED) <= VECTOR_TOLERANCE
		and velocity.Y >= LAUNCH_MINIMUM_VERTICAL_SPEED - VECTOR_TOLERANCE
		and velocity.Y <= LAUNCH_MAXIMUM_VERTICAL_SPEED + VECTOR_TOLERANCE
end

local function denseArrayLength(value: unknown): (number?, string?)
	if type(value) ~= "table" then
		return nil, "participants-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "participants-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_PARTICIPANTS or maximumIndex > MAXIMUM_PARTICIPANTS then
			return nil, "too-many-participants"
		end
	end
	if maximumIndex ~= count then
		return nil, "participants-not-dense-array"
	end
	return count, nil
end

function MoverItemFlagParticipantRules.Create(value: unknown): (Participant?, string?)
	return validateParticipant(value)
end

function MoverItemFlagParticipantRules.CreateFromInsertion(value: unknown): (Participant?, string?)
	if type(value) ~= "table" then
		return nil, "insertion-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, INSERTION_KEYS, 4) or raw.kind ~= "Insert" then
		return nil, "invalid-insertion-shape"
	end
	local binding, bindingError = validateBinding(raw.binding)
	if not binding then
		return nil, bindingError
	end
	if type(raw.order) ~= "table" then
		return nil, "insertion-order-not-table"
	end
	local rawOrder = raw.order :: { [unknown]: unknown }
	if
		not hasExactKeys(rawOrder, INSERTION_ORDER_KEYS, 3)
		or not isIntegerInRange(rawOrder.operationOrder, 1, MAXIMUM_OPERATION_ORDER)
	then
		return nil, "invalid-insertion-order"
	end
	local powerupOrdinal = if binding.kind == BindingKinds.Item
		then POWERUP_ITEM_ORDINAL[(binding :: ItemBinding).itemId]
		else nil
	local expectedPhase = if binding.kind == BindingKinds.Item and not powerupOrdinal then 1 else 2
	local expectedOrdinal = if binding.kind == BindingKinds.Item
		then powerupOrdinal or 0
		else TEAM_FLAG_ORDINAL[(binding :: TeamFlagBinding).teamId]
	if rawOrder.phase ~= expectedPhase or rawOrder.ordinal ~= expectedOrdinal then
		return nil, "noncanonical-insertion-order"
	end
	local insertionBody, bodyError = validateBody(raw.body, CONTENTS_TRIGGER, RUN_ITEM_CLIP_MASK)
	if not insertionBody then
		return nil, bodyError
	end
	if
		binding.bodyId ~= insertionBody.id
		or insertionBody.groundMoverId ~= nil
		or not isValidLaunchVelocity(insertionBody.velocity)
	then
		return nil, "invalid-launch-insertion"
	end
	local moverBody = cloneBodyWith(insertionBody, CONTENTS_TRIGGER, nil, nil)
	return validateParticipant({
		binding = binding,
		body = moverBody,
		lifecycle = Lifecycle.ActiveLinked,
		dropped = true,
	})
end

-- LaunchItem's linked ET_ITEM body participates in two distinct Q3 queries.
-- G_RunItem traces with MASK_DEADSOLID, while G_TestEntityPosition uses
-- MASK_SOLID when a mover pushes the item. CreateFromInsertion therefore must
-- reconstruct the body with a different clip mask; reference identity (and a
-- whole-body equality check) can never prove that conversion. This validator
-- admits only the exact value-preserving, mask-changing representation pair.
function MoverItemFlagParticipantRules.InsertionBodyMatchesParticipant(
	insertionBodyValue: unknown,
	participantBodyValue: unknown
): boolean
	local insertionBody = validateBody(insertionBodyValue, CONTENTS_TRIGGER, RUN_ITEM_CLIP_MASK)
	local participantBody = validateBody(participantBodyValue, CONTENTS_TRIGGER, MOVER_POSITION_CLIP_MASK)
	if not insertionBody or not participantBody then
		return false
	end
	return insertionBody.groundMoverId == nil
		and participantBody.groundMoverId == nil
		and insertionBody.id == participantBody.id
		and insertionBody.sourceOrder == participantBody.sourceOrder
		and insertionBody.position == participantBody.position
		and insertionBody.size == participantBody.size
		and insertionBody.centerOffset == participantBody.centerOffset
		and insertionBody.velocity == participantBody.velocity
end

function MoverItemFlagParticipantRules.Collect(value: unknown): (Collection?, string?)
	local count, countError = denseArrayLength(value)
	if not count then
		return nil, countError
	end
	local bodies: { Body } = {}
	local bindingsByBodyId: { [string]: Binding } = {}
	local observedBodyIds: { [string]: boolean } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local participant, participantError = validateParticipant((value :: { [unknown]: unknown })[index])
		if not participant then
			return nil, string.format("participant-%d:%s", index, participantError or "invalid")
		end
		if observedBodyIds[participant.body.id] then
			return nil, string.format("participant-%d:duplicate-body-id", index)
		end
		if observedSourceOrders[participant.body.sourceOrder] then
			return nil, string.format("participant-%d:duplicate-source-order", index)
		end
		observedBodyIds[participant.body.id] = true
		observedSourceOrders[participant.body.sourceOrder] = true
		if isLinked(participant.lifecycle) then
			bindingsByBodyId[participant.body.id] = participant.binding
			table.insert(bodies, participant.body)
		end
	end
	table.sort(bodies, function(left: Body, right: Body): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(bodies)
	table.freeze(bindingsByBodyId)
	local collection: Collection = {
		bodies = bodies,
		bindingsByBodyId = bindingsByBodyId,
	}
	table.freeze(collection)
	return collection, nil
end

function MoverItemFlagParticipantRules.ComposeInsertions(
	baseParticipantsValue: unknown,
	insertionsValue: unknown
): (Composition?, string?)
	local baseCount, baseCountError = denseArrayLength(baseParticipantsValue)
	if not baseCount then
		return nil, baseCountError
	end
	local insertionCount, insertionCountError = denseArrayLength(insertionsValue)
	if not insertionCount then
		return nil, insertionCountError
	end
	if baseCount + insertionCount > MAXIMUM_PARTICIPANTS then
		return nil, "too-many-composed-participants"
	end

	local participants: { Participant } = {}
	for index = 1, baseCount do
		local participant, participantError =
			validateParticipant((baseParticipantsValue :: { [unknown]: unknown })[index])
		if not participant then
			return nil, string.format("base-participant-%d:%s", index, participantError or "invalid")
		end
		table.insert(participants, participant)
	end

	local previousOperationOrder = 0
	local previousPhase = 0
	local previousOrdinal = -1
	for index = 1, insertionCount do
		local rawInsertion = (insertionsValue :: { [unknown]: unknown })[index]
		local participant, participantError = MoverItemFlagParticipantRules.CreateFromInsertion(rawInsertion)
		if not participant then
			return nil, string.format("insertion-%d:%s", index, participantError or "invalid")
		end
		local order = (rawInsertion :: any).order :: any
		local operationOrder = order.operationOrder :: number
		local phase = order.phase :: number
		local ordinal = order.ordinal :: number
		local ordered = operationOrder > previousOperationOrder
			or (operationOrder == previousOperationOrder and phase > previousPhase)
			or (operationOrder == previousOperationOrder and phase == previousPhase and ordinal > previousOrdinal)
		if not ordered then
			return nil, "noncanonical-composed-insertion-order"
		end
		previousOperationOrder = operationOrder
		previousPhase = phase
		previousOrdinal = ordinal
		table.insert(participants, participant)
	end

	local collection, collectionError = MoverItemFlagParticipantRules.Collect(participants)
	if not collection then
		return nil, collectionError
	end
	table.freeze(participants)
	local composition: Composition = {
		participants = participants,
		collection = collection,
	}
	table.freeze(composition)
	return composition, nil
end

function MoverItemFlagParticipantRules.ApplyMoverBody(
	participantValue: unknown,
	bodyValue: unknown
): (Participant?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isLinked(participant.lifecycle) then
		return nil, "participant-not-linked"
	end
	local body, bodyError =
		validateBody(bodyValue, contentsForLifecycle(participant.lifecycle), MOVER_POSITION_CLIP_MASK)
	if not body then
		return nil, bodyError
	end
	if
		body.id ~= participant.body.id
		or body.sourceOrder ~= participant.body.sourceOrder
		or body.velocity ~= participant.body.velocity
	then
		return nil, "mover-body-identity-or-velocity-drift"
	end
	return cloneParticipant(participant, participant.lifecycle, body), nil
end

-- G_RunItem owns trajectory position/velocity independently of mover pushes.
-- This transition keeps the exact item identity and lifecycle contents while
-- admitting only a validated replacement trajectory body.
function MoverItemFlagParticipantRules.ApplyRunItemBody(
	participantValue: unknown,
	positionValue: unknown,
	velocityValue: unknown,
	groundMoverIdValue: unknown?
): (Participant?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isLinked(participant.lifecycle) then
		return nil, "run-item-participant-not-linked"
	end
	if groundMoverIdValue ~= nil and not isStableId(groundMoverIdValue) then
		return nil, "invalid-run-item-ground-mover-id"
	end
	local body, bodyError = validateBody({
		id = participant.body.id,
		sourceOrder = participant.body.sourceOrder,
		position = positionValue,
		size = participant.body.size,
		centerOffset = participant.body.centerOffset,
		velocity = velocityValue,
		groundMoverId = groundMoverIdValue,
		contents = contentsForLifecycle(participant.lifecycle),
		clipMask = MOVER_POSITION_CLIP_MASK,
	}, contentsForLifecycle(participant.lifecycle), MOVER_POSITION_CLIP_MASK)
	if not body then
		return nil, bodyError
	end
	return cloneParticipant(participant, participant.lifecycle, body), nil
end

function MoverItemFlagParticipantRules.ResolveTouch(
	participantValue: unknown,
	intentValue: unknown
): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if participant.lifecycle ~= Lifecycle.ActiveLinked then
		return nil, "touch-participant-not-active"
	end
	if intentValue == TouchIntent.MapRespawn then
		if participant.dropped or participant.binding.kind ~= BindingKinds.Item then
			return nil, "map-respawn-touch-domain-mismatch"
		end
		return makeTransition(participant, Lifecycle.HiddenLinked, "None", false), nil
	elseif intentValue == TouchIntent.MapNeverRespawn then
		if participant.dropped or participant.binding.kind ~= BindingKinds.Item then
			return nil, "map-never-respawn-touch-domain-mismatch"
		end
		return makeTransition(participant, Lifecycle.PendingUnlinkAfterEvent, "None", false), nil
	elseif intentValue == TouchIntent.BaseFlagTaken then
		if participant.dropped or participant.binding.kind ~= BindingKinds.TeamFlag then
			return nil, "base-flag-touch-domain-mismatch"
		end
		return makeTransition(participant, Lifecycle.HiddenLinked, "None", false), nil
	elseif intentValue == TouchIntent.DroppedTaken then
		if not participant.dropped then
			return nil, "dropped-touch-domain-mismatch"
		end
		return makeTransition(participant, Lifecycle.PendingFreeAfterEvent, "None", false), nil
	elseif intentValue == TouchIntent.DroppedFlagReturned then
		if not participant.dropped or participant.binding.kind ~= BindingKinds.TeamFlag then
			return nil, "dropped-flag-return-domain-mismatch"
		end
		return makeTransition(participant, Lifecycle.Freed, "ReturnFlag", true), nil
	end
	return nil, "invalid-touch-intent"
end

function MoverItemFlagParticipantRules.FinishEvent(
	participantValue: unknown,
	elapsedMillisecondsValue: unknown
): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isIntegerInRange(elapsedMillisecondsValue, 0, MAXIMUM_ELAPSED_MILLISECONDS) then
		return nil, "invalid-event-elapsed-time"
	end
	-- G_RunFrame clears the event only when elapsed time is strictly greater
	-- than EVENT_VALID_MSEC, not when it is exactly equal.
	if (elapsedMillisecondsValue :: number) <= EVENT_VALID_MILLISECONDS then
		return nil, "event-still-valid"
	end
	if participant.lifecycle == Lifecycle.PendingUnlinkAfterEvent then
		return makeTransition(participant, Lifecycle.Unlinked, "None", false), nil
	elseif participant.lifecycle == Lifecycle.PendingFreeAfterEvent then
		return makeTransition(participant, Lifecycle.Freed, "Free", true), nil
	end
	return nil, "participant-has-no-pending-event"
end

function MoverItemFlagParticipantRules.Respawn(participantValue: unknown): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if participant.lifecycle ~= Lifecycle.HiddenLinked and participant.lifecycle ~= Lifecycle.Unlinked then
		return nil, "participant-not-respawnable"
	end
	return makeTransition(participant, Lifecycle.ActiveLinked, "None", false), nil
end

function MoverItemFlagParticipantRules.ResolveSineCrush(participantValue: unknown): (SynchronousCrushEffect?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isLinked(participant.lifecycle) then
		return nil, "sine-crush-participant-not-linked"
	end
	local insertedBodies: { Body } = {}
	table.freeze(insertedBodies)
	local effect: SynchronousCrushEffect = {
		kind = "Retain",
		insertedBodies = insertedBodies,
	}
	table.freeze(effect)
	return effect, nil
end

local function resetOrFreeTeamFlag(participant: Participant): Transition
	if participant.dropped then
		return makeTransition(participant, Lifecycle.Freed, "ReturnFlag", true)
	end
	return makeTransition(participant, Lifecycle.ActiveLinked, "ReturnFlag", false)
end

function MoverItemFlagParticipantRules.ResolveBlockedDoor(participantValue: unknown): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isLinked(participant.lifecycle) then
		return nil, "blocked-door-participant-not-linked"
	end
	if participant.binding.kind == BindingKinds.TeamFlag then
		return resetOrFreeTeamFlag(participant), nil
	end
	return makeTransition(participant, Lifecycle.Freed, "PopAndFree", true), nil
end

function MoverItemFlagParticipantRules.ResolveNoDropCollision(participantValue: unknown): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isLinked(participant.lifecycle) then
		return nil, "no-drop-participant-not-linked"
	end
	if participant.binding.kind == BindingKinds.TeamFlag then
		return resetOrFreeTeamFlag(participant), nil
	end
	return makeTransition(participant, Lifecycle.Freed, "Free", true), nil
end

function MoverItemFlagParticipantRules.ResolveDroppedTimeout(
	participantValue: unknown,
	elapsedMillisecondsValue: unknown
): (Transition?, string?)
	local participant, participantError = validateParticipant(participantValue)
	if not participant then
		return nil, participantError
	end
	if not isIntegerInRange(elapsedMillisecondsValue, 0, MAXIMUM_ELAPSED_MILLISECONDS) then
		return nil, "invalid-drop-elapsed-time"
	end
	if (elapsedMillisecondsValue :: number) < LAUNCH_TIMEOUT_MILLISECONDS then
		return nil, "drop-think-not-due"
	end
	if not participant.dropped or participant.lifecycle ~= Lifecycle.ActiveLinked then
		return nil, "timeout-participant-not-active-drop"
	end
	if participant.binding.kind == BindingKinds.TeamFlag then
		return makeTransition(participant, Lifecycle.Freed, "ReturnFlag", true), nil
	end
	return makeTransition(participant, Lifecycle.Freed, "Free", true), nil
end

MoverItemFlagParticipantRules.BindingKinds = BindingKinds
MoverItemFlagParticipantRules.Lifecycle = Lifecycle
MoverItemFlagParticipantRules.TouchIntent = TouchIntent
MoverItemFlagParticipantRules.ItemHullEdge = ITEM_HULL_EDGE
MoverItemFlagParticipantRules.ContentsNone = CONTENTS_NONE
MoverItemFlagParticipantRules.ContentsTrigger = CONTENTS_TRIGGER
MoverItemFlagParticipantRules.MoverPositionClipMask = MOVER_POSITION_CLIP_MASK
MoverItemFlagParticipantRules.RunItemClipMask = RUN_ITEM_CLIP_MASK
MoverItemFlagParticipantRules.FirstWorldSourceOrder = FIRST_WORLD_SOURCE_ORDER
MoverItemFlagParticipantRules.MaximumNormalSourceOrder = MAXIMUM_NORMAL_SOURCE_ORDER
MoverItemFlagParticipantRules.EventValidMilliseconds = EVENT_VALID_MILLISECONDS
MoverItemFlagParticipantRules.LaunchTimeoutMilliseconds = LAUNCH_TIMEOUT_MILLISECONDS
MoverItemFlagParticipantRules.DeclaredCtfFlagReturnMilliseconds = DECLARED_CTF_FLAG_RETURN_MILLISECONDS

return table.freeze(MoverItemFlagParticipantRules)
