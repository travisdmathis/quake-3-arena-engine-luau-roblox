--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure collision-state consequences translated from Quake III Arena:
  code/game/g_combat.c (player_die, body_die, GibEntity, TossClientItems)
  code/game/g_client.c (CopyToBodyQue)
  code/game/g_items.c (LaunchItem, Drop_Item)
  code/game/g_mover.c (G_MoverPush, Blocked_Door)

This module classifies collision bodies only. It deliberately produces no gore,
presentation, Instance, remote, score, or gameplay-service side effect. Stable
string identities, explicit operation ordering, strict table validation, and
bounded immutable outputs are the Roblox Luau port adaptations for a future composite
mover-consequence transaction.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)
local MoverPushRules = require(script.Parent.MoverPushRules)
local DroppedWeaponRules = require(script.Parent.Parent.items.DroppedWeaponRules)

export type BindingKind = "LivePlayer" | "ClientCorpse" | "BodyQueueCorpse" | "Item" | "TeamFlag"
export type PlayerBinding = {
	kind: "LivePlayer" | "ClientCorpse" | "BodyQueueCorpse",
	bodyId: string,
	playerUserId: number,
	lifeSequence: number,
}
export type ItemBinding = {
	kind: "Item",
	bodyId: string,
	itemId: string,
}
export type TeamFlagBinding = {
	kind: "TeamFlag",
	bodyId: string,
	teamId: "Red" | "Blue" | "Neutral",
}
export type Binding = PlayerBinding | ItemBinding | TeamFlagBinding

export type MeansOfDeath = "Ordinary" | "MOD_SUICIDE"
export type PlayerCollisionRequest = {
	binding: Binding,
	body: MoverPushRules.Body,
	postDamageHealth: number,
	meansOfDeath: MeansOfDeath,
	bloodEnabled: boolean,
	noDrop: boolean,
}
export type RemoveResolution = {
	disposition: "Remove",
	cause: "Suicide" | "Overkill",
	resolvedHealth: number,
	removedBodyId: string,
	bindingKind: "LivePlayer" | "ClientCorpse" | "BodyQueueCorpse",
}
export type ReplaceResolution = {
	disposition: "Replace",
	cause: "ClientCorpse",
	resolvedHealth: number,
	body: MoverPushRules.Body,
	binding: PlayerBinding,
}
export type RetainResolution = {
	disposition: "Retain",
	cause: "CorpseSurvived",
	resolvedHealth: number,
	body: MoverPushRules.Body,
	binding: PlayerBinding,
}
export type PlayerCollisionResolution = RemoveResolution | ReplaceResolution | RetainResolution

export type InsertionOrder = {
	operationOrder: number,
	phase: number,
	ordinal: number,
}
export type InsertionDescriptor = {
	kind: "Insert",
	order: InsertionOrder,
	body: MoverPushRules.Body,
	binding: ItemBinding | TeamFlagBinding,
}

local MoverConsequenceRules = {}

local GIB_HEALTH = -40
local MINIMUM_CLAMPED_Q3_HEALTH = -999
local MINIMUM_RAW_POST_DAMAGE_HEALTH = -100_000
local ITEM_RADIUS = 15
local ITEM_HULL_SIZE = Vector3.one * ITEM_RADIUS * 2 * Constants.UnitsToStuds
local CLIENT_CORPSE_SIZE = Vector3.new(30, 16, 30) * Constants.UnitsToStuds
local CLIENT_CORPSE_CENTER_OFFSET = Vector3.new(0, -16, 0) * Constants.UnitsToStuds
local MAXIMUM_STABLE_ID_LENGTH = 64
local MAXIMUM_USER_ID = 9_007_199_254_740_991
local MAXIMUM_LIFE_SEQUENCE = 2_147_483_647
local MAXIMUM_OPERATION_ORDER = 2_147_483_647

local BindingKinds = table.freeze({
	LivePlayer = "LivePlayer" :: "LivePlayer",
	ClientCorpse = "ClientCorpse" :: "ClientCorpse",
	BodyQueueCorpse = "BodyQueueCorpse" :: "BodyQueueCorpse",
	Item = "Item" :: "Item",
	TeamFlag = "TeamFlag" :: "TeamFlag",
})

local MeansOfDeath = table.freeze({
	Ordinary = "Ordinary" :: "Ordinary",
	Suicide = "MOD_SUICIDE" :: "MOD_SUICIDE",
})

local InsertionPhase = table.freeze({
	DeathWeapon = 1,
	Powerup = 2,
})

local TeamFlagPowerupOrdinal = table.freeze({
	Red = 7,
	Blue = 8,
	Neutral = 9,
})

-- BG_FindItemForPowerup order in TossClientItems. Team flags follow the six
-- timed powerups in the shared phase so one death callback has a canonical
-- weapon -> powerups -> flags insertion order.
local PowerupItemOrdinal = table.freeze({
	item_quad = 1,
	item_enviro = 2,
	item_haste = 3,
	item_invis = 4,
	item_regen = 5,
	item_flight = 6,
})

local PLAYER_BINDING_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	bodyId = true,
	playerUserId = true,
	lifeSequence = true,
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
local PLAYER_COLLISION_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	binding = true,
	body = true,
	postDamageHealth = true,
	meansOfDeath = true,
	bloodEnabled = true,
	noDrop = true,
})
local BODY_QUEUE_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	sourceBody = true,
	bodyId = true,
	sourceOrder = true,
})
local DEATH_DROP_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	bodyId = true,
	sourceOrder = true,
	position = true,
	velocity = true,
	itemId = true,
	operationOrder = true,
})
local TEAM_FLAG_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	bodyId = true,
	sourceOrder = true,
	position = true,
	velocity = true,
	teamId = true,
	operationOrder = true,
})
local INSERTION_DESCRIPTOR_KEYS: { [string]: boolean } = table.freeze({
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

local function isFiniteInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function isStableId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_STABLE_ID_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function isValidLaunchVelocity(value: unknown): boolean
	return typeof(value) == "Vector3" and DroppedWeaponRules.IsValidLaunchVelocity(value :: Vector3)
end

local function validateSingleBody(value: unknown): (MoverPushRules.Body?, string?)
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ value })
	if not bodies then
		return nil, bodyError
	end
	return bodies[1], nil
end

local function isClientCorpseGeometry(body: MoverPushRules.Body): boolean
	return body.size == CLIENT_CORPSE_SIZE
		and body.centerOffset == CLIENT_CORPSE_CENTER_OFFSET
		and body.contents == MoverPushRules.Contents.Corpse
end

local function isCanonicalLivePlayerGeometry(body: MoverPushRules.Body): boolean
	return (body.size == Constants.StandingColliderSize and body.centerOffset == Constants.StandingColliderCenterOffset)
		or (body.size == Constants.CrouchedColliderSize and body.centerOffset == Constants.CrouchedColliderCenterOffset)
end

local function validateBinding(value: unknown): (Binding?, string?)
	if type(value) ~= "table" then
		return nil, "binding-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	local kind = raw.kind
	if kind == BindingKinds.LivePlayer or kind == BindingKinds.ClientCorpse or kind == BindingKinds.BodyQueueCorpse then
		if not hasExactKeys(raw, PLAYER_BINDING_KEYS, 4) then
			return nil, "invalid-player-binding-shape"
		end
		if
			not isStableId(raw.bodyId)
			or not isFiniteInteger(raw.playerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
			or not isFiniteInteger(raw.lifeSequence, 1, MAXIMUM_LIFE_SEQUENCE)
		then
			return nil, "invalid-player-binding"
		end
		local binding: PlayerBinding = {
			kind = kind :: "LivePlayer" | "ClientCorpse" | "BodyQueueCorpse",
			bodyId = raw.bodyId :: string,
			playerUserId = raw.playerUserId :: number,
			lifeSequence = raw.lifeSequence :: number,
		}
		table.freeze(binding)
		return binding, nil
	elseif kind == BindingKinds.Item then
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
	elseif kind == BindingKinds.TeamFlag then
		if not hasExactKeys(raw, TEAM_FLAG_BINDING_KEYS, 3) then
			return nil, "invalid-team-flag-binding-shape"
		end
		if not isStableId(raw.bodyId) or TeamFlagPowerupOrdinal[raw.teamId :: any] == nil then
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

local function copyBodyWithCollision(
	body: MoverPushRules.Body,
	size: Vector3,
	centerOffset: Vector3,
	contents: number,
	clipMask: number
): (MoverPushRules.Body?, string?)
	return validateSingleBody({
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = body.position,
		size = size,
		centerOffset = centerOffset,
		velocity = body.velocity,
		groundMoverId = body.groundMoverId,
		contents = contents,
		clipMask = clipMask,
	})
end

local function buildClientCorpseBody(value: unknown): (MoverPushRules.Body?, string?)
	local body, bodyError = validateSingleBody(value)
	if not body then
		return nil, bodyError
	end
	if
		body.contents ~= MoverPushRules.Contents.Body
		or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
		or not isCanonicalLivePlayerGeometry(body)
	then
		return nil, "client-corpse-source-not-live-player"
	end
	return copyBodyWithCollision(
		body,
		CLIENT_CORPSE_SIZE,
		CLIENT_CORPSE_CENTER_OFFSET,
		MoverPushRules.Contents.Corpse,
		MoverPushRules.Masks.PlayerSolid
	)
end

local function buildBodyQueueCorpseBody(value: unknown): (MoverPushRules.Body?, string?)
	if type(value) ~= "table" then
		return nil, "body-queue-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, BODY_QUEUE_REQUEST_KEYS, 3) then
		return nil, "invalid-body-queue-request-shape"
	end
	local sourceBody, bodyError = validateSingleBody(raw.sourceBody)
	if not sourceBody then
		return nil, bodyError
	end
	if not isClientCorpseGeometry(sourceBody) or sourceBody.clipMask ~= MoverPushRules.Masks.PlayerSolid then
		return nil, "body-queue-source-not-corpse"
	end
	if raw.bodyId == sourceBody.id or raw.sourceOrder == sourceBody.sourceOrder then
		return nil, "body-queue-identity-not-distinct"
	end
	return validateSingleBody({
		id = raw.bodyId,
		sourceOrder = raw.sourceOrder,
		position = sourceBody.position,
		size = CLIENT_CORPSE_SIZE,
		centerOffset = CLIENT_CORPSE_CENTER_OFFSET,
		velocity = sourceBody.velocity,
		groundMoverId = sourceBody.groundMoverId,
		contents = MoverPushRules.Contents.Corpse,
		clipMask = MoverPushRules.Masks.DeadSolid,
	})
end

local function corpseHealth(postDamageHealth: number): number
	-- Both player_die's non-gib branch and body_die with blood disabled keep the
	-- body damageable by lifting an overkilled health value just above GIB_HEALTH.
	return if postDamageHealth <= GIB_HEALTH then GIB_HEALTH + 1 else postDamageHealth
end

local function replacementClientBinding(binding: PlayerBinding): PlayerBinding
	local replacement: PlayerBinding = {
		kind = BindingKinds.ClientCorpse,
		bodyId = binding.bodyId,
		playerUserId = binding.playerUserId,
		lifeSequence = binding.lifeSequence,
	}
	table.freeze(replacement)
	return replacement
end

local function resolvePlayerCollision(value: unknown): (PlayerCollisionResolution?, string?)
	if type(value) ~= "table" then
		return nil, "player-collision-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, PLAYER_COLLISION_REQUEST_KEYS, 6) then
		return nil, "invalid-player-collision-request-shape"
	end
	local binding, bindingError = validateBinding(raw.binding)
	if not binding then
		return nil, bindingError
	end
	if
		binding.kind ~= BindingKinds.LivePlayer
		and binding.kind ~= BindingKinds.ClientCorpse
		and binding.kind ~= BindingKinds.BodyQueueCorpse
	then
		return nil, "player-collision-binding-required"
	end
	local playerBinding = binding :: PlayerBinding
	local body, bodyError = validateSingleBody(raw.body)
	if not body then
		return nil, bodyError
	end
	if body.id ~= playerBinding.bodyId then
		return nil, "player-collision-body-binding-mismatch"
	end
	if not isFiniteInteger(raw.postDamageHealth, MINIMUM_RAW_POST_DAMAGE_HEALTH, 0) then
		return nil, "invalid-post-damage-health"
	end
	if raw.meansOfDeath ~= MeansOfDeath.Ordinary and raw.meansOfDeath ~= MeansOfDeath.Suicide then
		return nil, "invalid-means-of-death"
	end
	if type(raw.bloodEnabled) ~= "boolean" or type(raw.noDrop) ~= "boolean" then
		return nil, "invalid-player-collision-policy"
	end

	-- G_Damage computes the raw subtraction first, then clamps extreme overkill
	-- before calling player_die/body_die. Admit the bounded raw Sine result while
	-- exposing only the exact clamped Q3 health to collision classification.
	local health = math.max(raw.postDamageHealth :: number, MINIMUM_CLAMPED_Q3_HEALTH)
	local bloodEnabled = raw.bloodEnabled :: boolean
	local noDrop = raw.noDrop :: boolean
	if playerBinding.kind == BindingKinds.LivePlayer then
		if
			body.contents ~= MoverPushRules.Contents.Body
			or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
			or not isCanonicalLivePlayerGeometry(body)
		then
			return nil, "live-player-binding-body-mismatch"
		end
		local suicide = raw.meansOfDeath == MeansOfDeath.Suicide
		local overkill = health <= GIB_HEALTH and bloodEnabled and not noDrop
		if suicide or overkill then
			local resolution: RemoveResolution = {
				disposition = "Remove",
				cause = if suicide then "Suicide" else "Overkill",
				resolvedHealth = health,
				removedBodyId = body.id,
				bindingKind = BindingKinds.LivePlayer,
			}
			table.freeze(resolution)
			return resolution, nil
		end
		local corpse, corpseError = buildClientCorpseBody(body)
		if not corpse then
			return nil, corpseError
		end
		local resolution: ReplaceResolution = {
			disposition = "Replace",
			cause = "ClientCorpse",
			resolvedHealth = corpseHealth(health),
			body = corpse,
			binding = replacementClientBinding(playerBinding),
		}
		table.freeze(resolution)
		return resolution, nil
	end

	if
		not isClientCorpseGeometry(body)
		or (playerBinding.kind == BindingKinds.ClientCorpse and body.clipMask ~= MoverPushRules.Masks.PlayerSolid)
		or (playerBinding.kind == BindingKinds.BodyQueueCorpse and body.clipMask ~= MoverPushRules.Masks.DeadSolid)
	then
		return nil, "corpse-binding-body-mismatch"
	end
	-- body_die does not repeat player_die's no-drop or MOD_SUICIDE branches.
	-- Once a corpse exists, crossing GIB_HEALTH removes collision whenever blood
	-- is enabled, even if the corpse still occupies a no-drop volume.
	if health <= GIB_HEALTH and bloodEnabled then
		local resolution: RemoveResolution = {
			disposition = "Remove",
			cause = "Overkill",
			resolvedHealth = health,
			removedBodyId = body.id,
			bindingKind = playerBinding.kind,
		}
		table.freeze(resolution)
		return resolution, nil
	end
	local resolution: RetainResolution = {
		disposition = "Retain",
		cause = "CorpseSurvived",
		resolvedHealth = corpseHealth(health),
		body = body,
		binding = playerBinding,
	}
	table.freeze(resolution)
	return resolution, nil
end

local function buildItemBody(raw: { [unknown]: unknown }): (MoverPushRules.Body?, string?)
	return validateSingleBody({
		id = raw.bodyId,
		sourceOrder = raw.sourceOrder,
		position = raw.position,
		size = ITEM_HULL_SIZE,
		centerOffset = Vector3.zero,
		velocity = raw.velocity,
		contents = MoverPushRules.Contents.Trigger,
		clipMask = MoverPushRules.Masks.DeadSolid,
	})
end

local function insertionOrder(operationOrder: number, phase: number, ordinal: number): InsertionOrder
	local order: InsertionOrder = {
		operationOrder = operationOrder,
		phase = phase,
		ordinal = ordinal,
	}
	table.freeze(order)
	return order
end

local function buildDeathDropInsertion(value: unknown): (InsertionDescriptor?, string?)
	if type(value) ~= "table" then
		return nil, "death-drop-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, DEATH_DROP_REQUEST_KEYS, 6) then
		return nil, "invalid-death-drop-request-shape"
	end
	if
		not isStableId(raw.itemId)
		or not isFiniteInteger(raw.operationOrder, 1, MAXIMUM_OPERATION_ORDER)
		or not isValidLaunchVelocity(raw.velocity)
	then
		return nil, "invalid-death-drop-request"
	end
	local body, bodyError = buildItemBody(raw)
	if not body then
		return nil, bodyError
	end
	local binding, bindingError = validateBinding({
		kind = BindingKinds.Item,
		bodyId = body.id,
		itemId = raw.itemId,
	})
	if not binding then
		return nil, bindingError
	end
	local descriptor: InsertionDescriptor = {
		kind = "Insert",
		order = if PowerupItemOrdinal[raw.itemId :: any]
			then insertionOrder(
				raw.operationOrder :: number,
				InsertionPhase.Powerup,
				PowerupItemOrdinal[raw.itemId :: any]
			)
			else insertionOrder(raw.operationOrder :: number, InsertionPhase.DeathWeapon, 0),
		body = body,
		binding = binding :: ItemBinding,
	}
	table.freeze(descriptor)
	return descriptor, nil
end

local function buildTeamFlagInsertion(value: unknown): (InsertionDescriptor?, string?)
	if type(value) ~= "table" then
		return nil, "team-flag-request-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, TEAM_FLAG_REQUEST_KEYS, 6) then
		return nil, "invalid-team-flag-request-shape"
	end
	local flagOrdinal = TeamFlagPowerupOrdinal[raw.teamId :: any]
	if
		flagOrdinal == nil
		or not isFiniteInteger(raw.operationOrder, 1, MAXIMUM_OPERATION_ORDER)
		or not isValidLaunchVelocity(raw.velocity)
	then
		return nil, "invalid-team-flag-request"
	end
	local body, bodyError = buildItemBody(raw)
	if not body then
		return nil, bodyError
	end
	local binding, bindingError = validateBinding({
		kind = BindingKinds.TeamFlag,
		bodyId = body.id,
		teamId = raw.teamId,
	})
	if not binding then
		return nil, bindingError
	end
	local descriptor: InsertionDescriptor = {
		kind = "Insert",
		order = insertionOrder(raw.operationOrder :: number, InsertionPhase.Powerup, flagOrdinal),
		body = body,
		binding = binding :: TeamFlagBinding,
	}
	table.freeze(descriptor)
	return descriptor, nil
end

local function denseArrayLength(value: unknown): (number?, string?)
	if type(value) ~= "table" then
		return nil, "insertions-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "insertions-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MoverPushRules.MaximumBodies or maximumIndex > MoverPushRules.MaximumBodies then
			return nil, "too-many-insertions"
		end
	end
	if maximumIndex ~= count then
		return nil, "insertions-not-dense-array"
	end
	return count, nil
end

local function validateInsertion(value: unknown): (InsertionDescriptor?, string?)
	if type(value) ~= "table" then
		return nil, "insertion-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, INSERTION_DESCRIPTOR_KEYS, 4) or raw.kind ~= "Insert" then
		return nil, "invalid-insertion-shape"
	end
	if type(raw.order) ~= "table" then
		return nil, "insertion-order-not-table"
	end
	local rawOrder = raw.order :: { [unknown]: unknown }
	if
		not hasExactKeys(rawOrder, INSERTION_ORDER_KEYS, 3)
		or not isFiniteInteger(rawOrder.operationOrder, 1, MAXIMUM_OPERATION_ORDER)
	then
		return nil, "invalid-insertion-order"
	end
	local body, bodyError = validateSingleBody(raw.body)
	if not body then
		return nil, bodyError
	end
	if
		body.size ~= ITEM_HULL_SIZE
		or body.centerOffset ~= Vector3.zero
		or body.groundMoverId ~= nil
		or body.contents ~= MoverPushRules.Contents.Trigger
		or body.clipMask ~= MoverPushRules.Masks.DeadSolid
	then
		return nil, "insertion-body-not-q3-item"
	end
	local binding, bindingError = validateBinding(raw.binding)
	if not binding then
		return nil, bindingError
	end
	if binding.bodyId ~= body.id then
		return nil, "insertion-body-binding-mismatch"
	end
	local expectedPhase: number
	local expectedOrdinal: number
	if binding.kind == BindingKinds.Item then
		local powerupOrdinal = PowerupItemOrdinal[(binding :: ItemBinding).itemId]
		expectedPhase = if powerupOrdinal then InsertionPhase.Powerup else InsertionPhase.DeathWeapon
		expectedOrdinal = powerupOrdinal or 0
	elseif binding.kind == BindingKinds.TeamFlag then
		expectedPhase = InsertionPhase.Powerup
		expectedOrdinal = TeamFlagPowerupOrdinal[(binding :: TeamFlagBinding).teamId]
	else
		return nil, "insertion-binding-not-item"
	end
	if rawOrder.phase ~= expectedPhase or rawOrder.ordinal ~= expectedOrdinal then
		return nil, "noncanonical-insertion-order"
	end
	local order = insertionOrder(rawOrder.operationOrder :: number, expectedPhase, expectedOrdinal)
	local descriptor: InsertionDescriptor = {
		kind = "Insert",
		order = order,
		body = body,
		binding = binding :: ItemBinding | TeamFlagBinding,
	}
	table.freeze(descriptor)
	return descriptor, nil
end

local function validateAndOrderInsertions(value: unknown): ({ InsertionDescriptor }?, string?)
	local count, countError = denseArrayLength(value)
	if not count then
		return nil, countError
	end
	local descriptors: { InsertionDescriptor } = {}
	local observedBodyIds: { [string]: boolean } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local descriptor, descriptorError = validateInsertion((value :: { [unknown]: unknown })[index])
		if not descriptor then
			return nil, string.format("insertion-%d:%s", index, descriptorError or "invalid")
		end
		if observedBodyIds[descriptor.body.id] then
			return nil, string.format("insertion-%d:duplicate-body-id", index)
		end
		if observedSourceOrders[descriptor.body.sourceOrder] then
			return nil, string.format("insertion-%d:duplicate-source-order", index)
		end
		observedBodyIds[descriptor.body.id] = true
		observedSourceOrders[descriptor.body.sourceOrder] = true
		table.insert(descriptors, descriptor)
	end
	table.sort(descriptors, function(left, right): boolean
		if left.order.operationOrder ~= right.order.operationOrder then
			return left.order.operationOrder < right.order.operationOrder
		end
		if left.order.phase ~= right.order.phase then
			return left.order.phase < right.order.phase
		end
		if left.order.ordinal ~= right.order.ordinal then
			return left.order.ordinal < right.order.ordinal
		end
		return left.body.sourceOrder < right.body.sourceOrder
	end)
	table.freeze(descriptors)
	return descriptors, nil
end

MoverConsequenceRules.ValidateBinding = validateBinding
MoverConsequenceRules.BuildClientCorpseBody = buildClientCorpseBody
MoverConsequenceRules.BuildBodyQueueCorpseBody = buildBodyQueueCorpseBody
MoverConsequenceRules.ResolvePlayerCollision = resolvePlayerCollision
MoverConsequenceRules.BuildDeathDropInsertion = buildDeathDropInsertion
MoverConsequenceRules.BuildTeamFlagInsertion = buildTeamFlagInsertion
MoverConsequenceRules.ValidateAndOrderInsertions = validateAndOrderInsertions
MoverConsequenceRules.BindingKinds = BindingKinds
MoverConsequenceRules.MeansOfDeath = MeansOfDeath
MoverConsequenceRules.InsertionPhase = InsertionPhase
MoverConsequenceRules.TeamFlagPowerupOrdinal = TeamFlagPowerupOrdinal
MoverConsequenceRules.PowerupItemOrdinal = PowerupItemOrdinal
MoverConsequenceRules.GibHealth = GIB_HEALTH
MoverConsequenceRules.MinimumClampedQ3Health = MINIMUM_CLAMPED_Q3_HEALTH
MoverConsequenceRules.MinimumRawPostDamageHealth = MINIMUM_RAW_POST_DAMAGE_HEALTH
MoverConsequenceRules.ItemRadius = ITEM_RADIUS
MoverConsequenceRules.ItemHullSize = ITEM_HULL_SIZE
MoverConsequenceRules.ClientCorpseSize = CLIENT_CORPSE_SIZE
MoverConsequenceRules.ClientCorpseCenterOffset = CLIENT_CORPSE_CENTER_OFFSET

return table.freeze(MoverConsequenceRules)
