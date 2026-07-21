--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only immediate client-corpse authority translated from Quake III Arena:
  code/game/g_combat.c (G_Damage, player_die, body_die, GibEntity)
  code/game/g_client.c (respawn calls CopyToBodyQue later, not on death)
  code/game/g_mover.c (synchronous Sine and Blocked_Door consequences)

This owner deliberately models only the client entity that becomes a corpse in
player_die. It does not consume the eight-entry body queue; Q3 advances that
queue later in respawn(), immediately before ClientSpawn. Movement may inspect
only immutable bodies while one opaque transaction is open. The same prepared
root can retain an opaque, data-only CopyToBodyQue tombstone with exact current
Match/player-slot lease/source-order lineage and a life value consistent with
the same death binding. Its final corpse body and linked-but-invisible
GibEntity state survive collision removal; the prepared respawn coordinator
consumes both immediate corpse and tombstone before accepted avatar replacement.
Corpse deliberately leaves exact ground classification and Q3's distinct
trajectory/player velocity fields to Movement's live post-Pmove composition.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local EntitySourceOrderRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntitySourceOrderRules"))
local MoverConsequenceRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverConsequenceRules"))
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))
local EntitySlotService = require(script.Parent.EntitySlotService)
local MatchService = require(script.Parent.MatchService)

local CorpseService = {}

export type TransactionToken = {}
export type PreparedCommit = {}
export type RespawnCopyTombstone = {}
export type PreparedRespawnCopyTombstoneConsume = {}
export type DepartureCleanupOwner = {}
export type MatchTransitionCleanupOwner = {}
export type RespawnCopyTombstoneData = {
	read matchId: string,
	read matchLineage: MatchService.MatchLineage,
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read playerUserId: number,
	read lifeSequence: number,
	read body: MoverPushRules.Body,
	read sourceLinked: boolean,
	read entityType: "Player" | "Invisible",
	read visible: boolean,
	read sourceHealth: number,
	-- Corpse owns the latest collision pose/velocity/ground-mover identity. It
	-- cannot distinguish world-ground from airborne, nor entity trajectory
	-- delta from player-state velocity, until Movement joins the respawn plan.
	read exactGroundStateAvailable: false,
	read exactTrajectoryDeltaAvailable: false,
	read exactPlayerStateVelocityAvailable: false,
}
export type PreparedRespawnCopyTombstoneSummary = {
	read corpseBaseRevision: number,
	read corpseCommitRevision: number,
	read player: Player,
	read tombstone: RespawnCopyTombstone,
	read source: RespawnCopyTombstoneData,
}
export type CommitReceipt = {
	read revision: number,
	read committedCorpseCount: number,
	read committedTombstoneCount: number,
}
export type RespawnCopyTombstoneConsumeReceipt = {
	read revision: number,
	read committedCorpseCount: number,
	read committedTombstoneCount: number,
	read source: RespawnCopyTombstoneData,
}
export type Collection = {
	read bodies: { MoverPushRules.Body },
	read playersByBodyId: { [string]: Player },
}
export type DebugSnapshot = {
	read revision: number,
	read committedCorpseCount: number,
	read transactionActive: boolean,
	read transactionStatus: string?,
	read transactionCorpseCount: number,
	read transactionFinalBodiesApplied: boolean,
	read transactionApplyValidated: boolean,
	read transactionPreparedRevision: number?,
	read committedTombstoneCount: number,
	read transactionTombstoneCount: number,
	read tombstoneConsumeActive: boolean,
	read tombstoneConsumeApplyValidated: boolean,
}

type PlayerBinding = MoverConsequenceRules.PlayerBinding
type Entry = {
	player: Player,
	binding: PlayerBinding,
	body: MoverPushRules.Body,
	health: number,
}
type TombstoneCapability = {
	handle: RespawnCopyTombstone,
	player: Player,
	registration: EntitySlotService.Registration,
	current: boolean,
	consumed: boolean,
	data: RespawnCopyTombstoneData,
}
type TombstoneDraft = {
	capability: TombstoneCapability,
	previousCapability: TombstoneCapability?,
	data: RespawnCopyTombstoneData,
	isNew: boolean,
	deathResolved: boolean,
}
type TombstoneMutation = {
	capability: TombstoneCapability,
	beforeCurrent: boolean,
	afterCurrent: boolean,
	beforeConsumed: boolean,
	afterConsumed: boolean,
	beforeData: RespawnCopyTombstoneData,
	afterData: RespawnCopyTombstoneData,
}
type Status = "Open" | "Sealed" | "Prepared" | "Applied" | "Aborted"
type Transaction = {
	token: TransactionToken,
	status: Status,
	baseRevision: number,
	baseEntries: { [Player]: Entry },
	baseTombstones: { [Player]: TombstoneCapability },
	entriesByPlayer: { [Player]: Entry },
	tombstoneDraftsByPlayer: { [Player]: TombstoneDraft },
	newTombstones: { TombstoneCapability },
	postPmovePoseStagedByPlayer: { [Player]: boolean },
	touchedBodyIds: { [string]: boolean },
	finalBodiesApplied: boolean,
	prepared: PreparedCommit?,
}
type PreparedStatus = "Prepared" | "Applied" | "Aborted"
type PreparedCapability = {
	transaction: Transaction,
	status: PreparedStatus,
	entriesByPlayer: { [Player]: Entry },
	tombstonesByPlayer: { [Player]: TombstoneCapability },
	tombstoneMutations: { TombstoneMutation },
	tombstoneSummariesByHandle: {
		[RespawnCopyTombstone]: PreparedRespawnCopyTombstoneSummary,
	},
	receipt: CommitReceipt,
	applyValidated: boolean,
}

type TombstoneConsumeStatus = "Prepared" | "Applied" | "Aborted"
type TombstoneConsumeCapability = {
	prepared: PreparedRespawnCopyTombstoneConsume,
	status: TombstoneConsumeStatus,
	applyValidated: boolean,
	tombstone: TombstoneCapability,
	baseRevision: number,
	baseEntries: { [Player]: Entry },
	baseTombstones: { [Player]: TombstoneCapability },
	nextEntries: { [Player]: Entry },
	nextTombstones: { [Player]: TombstoneCapability },
	receipt: RespawnCopyTombstoneConsumeReceipt,
}

local committedEntriesByPlayer: { [Player]: Entry } = table.freeze({})
local committedTombstonesByPlayer: { [Player]: TombstoneCapability } = table.freeze({})
local activeTransaction: Transaction? = nil
local activeTombstoneConsume: TombstoneConsumeCapability? = nil
local departureCleanupOwner: DepartureCleanupOwner? = nil
local matchTransitionCleanupOwner: MatchTransitionCleanupOwner? = nil
local revision = 0
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedCommit]: PreparedCapability,
}
local tombstoneCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[RespawnCopyTombstone]: TombstoneCapability,
}
local preparedTombstoneConsumeCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedRespawnCopyTombstoneConsume]: TombstoneConsumeCapability,
}
local preparedRespawnCopyTombstoneSummaries = setmetatable({}, { __mode = "k" }) :: {
	[PreparedRespawnCopyTombstoneSummary]: PreparedCommit,
}

local EMPTY_INSERTED_BODIES: { MoverPushRules.Body } = table.freeze({})
local MAXIMUM_GENERATION = 2_147_483_647
local MAXIMUM_USER_ID = 9_007_199_254_740_991
local TOMBSTONE_STAGE_KEYS = table.freeze({
	matchId = true,
	matchLineage = true,
	playerBodyId = true,
	playerSourceOrder = true,
	playerLeaseGeneration = true,
	playerUserId = true,
	lifeSequence = true,
	body = true,
})
local TOMBSTONE_LINEAGE_KEYS = table.freeze({
	matchId = true,
	matchLineage = true,
	playerBodyId = true,
	playerSourceOrder = true,
	playerLeaseGeneration = true,
	playerUserId = true,
	lifeSequence = true,
})
local PLAYER_BINDING_KEYS = table.freeze({
	kind = true,
	bodyId = true,
	playerUserId = true,
	lifeSequence = true,
})
local BODY_KEYS = table.freeze({
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

local function isPlayer(value: unknown): boolean
	return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

local function cloneEntry(entry: Entry): Entry
	return {
		player = entry.player,
		binding = entry.binding,
		body = entry.body,
		health = entry.health,
	}
end

local function cloneEntries(source: { [Player]: Entry }): { [Player]: Entry }
	local result: { [Player]: Entry } = {}
	for player, entry in source do
		result[player] = cloneEntry(entry)
	end
	return result
end

local function isFiniteInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

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

-- Post-Pmove bodies cross the live Movement -> Corpse authority boundary.
-- Inspect only raw keys so a proxy cannot execute or synthesize lineage while
-- Corpse is deciding whether to mutate its open transaction.
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
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function makeTombstoneData(
	source: RespawnCopyTombstoneData?,
	matchId: string,
	matchLineage: MatchService.MatchLineage,
	playerBodyId: string,
	playerSourceOrder: number,
	playerLeaseGeneration: number,
	playerUserId: number,
	lifeSequence: number,
	body: MoverPushRules.Body,
	sourceLinked: boolean,
	entityType: "Player" | "Invisible",
	sourceHealth: number
): RespawnCopyTombstoneData
	local data: RespawnCopyTombstoneData = {
		matchId = matchId,
		matchLineage = matchLineage,
		playerBodyId = playerBodyId,
		playerSourceOrder = playerSourceOrder,
		playerLeaseGeneration = playerLeaseGeneration,
		playerUserId = playerUserId,
		lifeSequence = lifeSequence,
		body = body,
		sourceLinked = sourceLinked,
		entityType = entityType,
		visible = entityType == "Player",
		sourceHealth = sourceHealth,
		exactGroundStateAvailable = false,
		exactTrajectoryDeltaAvailable = false,
		exactPlayerStateVelocityAvailable = false,
	}
	if source then
		assert(source.matchId == matchId, "tombstone match id drifted")
		assert(source.matchLineage == matchLineage, "tombstone match lineage drifted")
		assert(source.playerBodyId == playerBodyId, "tombstone body identity drifted")
		assert(source.playerSourceOrder == playerSourceOrder, "tombstone source order drifted")
		assert(source.playerLeaseGeneration == playerLeaseGeneration, "tombstone lease generation drifted")
		assert(source.playerUserId == playerUserId, "tombstone player identity drifted")
		assert(source.lifeSequence == lifeSequence, "tombstone life lineage drifted")
	end
	table.freeze(data)
	return data
end

local function tombstoneMatchesPlayerBinding(
	data: RespawnCopyTombstoneData,
	player: Player,
	binding: PlayerBinding,
	body: MoverPushRules.Body
): boolean
	return data.playerUserId == player.UserId
		and data.playerUserId == binding.playerUserId
		and data.lifeSequence == binding.lifeSequence
		and data.playerBodyId == binding.bodyId
		and data.playerBodyId == body.id
		and data.playerSourceOrder == body.sourceOrder
end

local function validateTombstoneData(data: RespawnCopyTombstoneData, player: Player): string?
	if
		type(data.matchId) ~= "string"
		or data.matchId == ""
		or type(data.matchLineage) ~= "table"
		or not table.isfrozen(data.matchLineage :: table)
		or not MatchService.ValidateMatchLineage(data.matchLineage, data.matchId)
		or player.Parent ~= Players
		or data.playerUserId ~= player.UserId
		or not isFiniteInteger(data.playerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or not isFiniteInteger(data.playerSourceOrder, 1, EntitySourceOrderRules.MaximumClients)
		or not isFiniteInteger(data.playerLeaseGeneration, 1, MAXIMUM_GENERATION)
		or not isFiniteInteger(data.lifeSequence, 1, MAXIMUM_GENERATION)
		or not isFiniteInteger(data.sourceHealth, MoverConsequenceRules.MinimumRawPostDamageHealth, 0)
		or data.visible ~= (data.entityType == "Player")
		or data.sourceLinked ~= true
		or data.exactGroundStateAvailable ~= false
		or data.exactTrajectoryDeltaAvailable ~= false
		or data.exactPlayerStateVelocityAvailable ~= false
	then
		return "invalid-respawn-copy-tombstone-state"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ data.body })
	if not bodies then
		return bodyError or "invalid-respawn-copy-tombstone-body"
	end
	local body = bodies[1]
	if
		not table.isfrozen(data.body)
		or body.id ~= data.playerBodyId
		or body.sourceOrder ~= data.playerSourceOrder
		or body.size ~= MoverConsequenceRules.ClientCorpseSize
		or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
		or body.contents ~= MoverPushRules.Contents.Corpse
		or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
	then
		return "invalid-respawn-copy-tombstone-lineage"
	end
	return nil
end

-- Prepare already canonicalizes and freezes the record/body. This exact
-- identity/field recheck allocates nothing and is safe in the final preflight
-- repeated inside ApplyPrepared.
local function tombstoneDataCurrentError(
	data: RespawnCopyTombstoneData,
	player: Player,
	validateExternalDependencies: boolean?
): string?
	local body = data.body
	if
		not table.isfrozen(data)
		or type(data.matchId) ~= "string"
		or data.matchId == ""
		or type(data.matchLineage) ~= "table"
		or not table.isfrozen(data.matchLineage :: table)
		or (validateExternalDependencies ~= false and not MatchService.ValidateMatchLineage(
			data.matchLineage,
			data.matchId
		))
		or player.Parent ~= Players
		or not table.isfrozen(body)
		or data.playerUserId ~= player.UserId
		or not isFiniteInteger(data.playerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or not isFiniteInteger(data.playerSourceOrder, 1, EntitySourceOrderRules.MaximumClients)
		or not isFiniteInteger(data.playerLeaseGeneration, 1, MAXIMUM_GENERATION)
		or not isFiniteInteger(data.lifeSequence, 1, MAXIMUM_GENERATION)
		or not isFiniteInteger(data.sourceHealth, MoverConsequenceRules.MinimumRawPostDamageHealth, 0)
		or data.visible ~= (data.entityType == "Player")
		or data.sourceLinked ~= true
		or data.exactGroundStateAvailable ~= false
		or data.exactTrajectoryDeltaAvailable ~= false
		or data.exactPlayerStateVelocityAvailable ~= false
		or body.id ~= data.playerBodyId
		or body.sourceOrder ~= data.playerSourceOrder
		or body.size ~= MoverConsequenceRules.ClientCorpseSize
		or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
		or body.contents ~= MoverPushRules.Contents.Corpse
		or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
	then
		return "stale-respawn-copy-tombstone-data"
	end
	return nil
end

local function tombstoneCapabilityCurrentError(
	tombstone: TombstoneCapability,
	validateExternalDependencies: boolean?
): string?
	local dataError = tombstoneDataCurrentError(tombstone.data, tombstone.player, validateExternalDependencies)
	if dataError then
		return dataError
	end
	if validateExternalDependencies == false then
		return nil
	end
	local registration = EntitySlotService.GetPlayerRegistration(tombstone.player)
	if
		registration ~= tombstone.registration
		or registration.bodyId ~= tombstone.data.playerBodyId
		or registration.sourceOrder ~= tombstone.data.playerSourceOrder
		or registration.generation ~= tombstone.data.playerLeaseGeneration
	then
		return "stale-respawn-copy-tombstone-entity-slot-lineage"
	end
	return nil
end

local function ensureCommittedTombstoneDraft(
	transaction: Transaction,
	player: Player,
	binding: PlayerBinding,
	body: MoverPushRules.Body
): (TombstoneDraft?, string?)
	local draft = transaction.tombstoneDraftsByPlayer[player]
	if draft then
		if not tombstoneMatchesPlayerBinding(draft.data, player, binding, body) then
			return nil, "stale-respawn-copy-tombstone-lineage"
		end
		return draft, nil
	end
	local capability = transaction.baseTombstones[player]
	if not capability then
		return nil, nil
	end
	if
		not capability.current
		or capability.consumed
		or committedTombstonesByPlayer[player] ~= capability
		or tombstoneCapabilities[capability.handle] ~= capability
		or not tombstoneMatchesPlayerBinding(capability.data, player, binding, body)
	then
		return nil, "stale-respawn-copy-tombstone-lineage"
	end
	draft = {
		capability = capability,
		previousCapability = nil,
		data = capability.data,
		isNew = false,
		deathResolved = true,
	}
	transaction.tombstoneDraftsByPlayer[player] = draft
	return draft, nil
end

local function prepareCommittedTombstones(transaction: Transaction): (
	{ [Player]: TombstoneCapability }?,
	{ TombstoneMutation }?,
	number?,
	string?
)
	if transaction.baseTombstones ~= committedTombstonesByPlayer then
		return nil, nil, nil, "stale-corpse-tombstone-transaction-base"
	end
	local nextTombstones: { [Player]: TombstoneCapability } = {}
	for player, capability in transaction.baseTombstones do
		if
			capability.player ~= player
			or not capability.current
			or capability.consumed
			or tombstoneCapabilities[capability.handle] ~= capability
			or tombstoneCapabilityCurrentError(capability) ~= nil
		then
			return nil, nil, nil, "stale-committed-respawn-copy-tombstone"
		end
		nextTombstones[player] = capability
	end
	local mutations: { TombstoneMutation } = {}
	for player, draft in transaction.tombstoneDraftsByPlayer do
		local capability = draft.capability
		local dataError = validateTombstoneData(draft.data, player)
		if dataError or not draft.deathResolved or capability.player ~= player then
			return nil, nil, nil, dataError or "unresolved-respawn-copy-tombstone"
		end
		if draft.isNew then
			if capability.current or capability.consumed or tombstoneCapabilities[capability.handle] ~= capability then
				return nil, nil, nil, "stale-pending-respawn-copy-tombstone"
			end
			local previous = draft.previousCapability
			if previous then
				if nextTombstones[player] ~= previous or not previous.current or previous.consumed then
					return nil, nil, nil, "stale-replaced-respawn-copy-tombstone"
				end
				local deactivate: TombstoneMutation = {
					capability = previous,
					beforeCurrent = true,
					afterCurrent = false,
					beforeConsumed = false,
					afterConsumed = true,
					beforeData = previous.data,
					afterData = previous.data,
				}
				table.freeze(deactivate)
				table.insert(mutations, deactivate)
			elseif nextTombstones[player] ~= nil then
				return nil, nil, nil, "unexpected-respawn-copy-tombstone-replacement"
			end
			local activate: TombstoneMutation = {
				capability = capability,
				beforeCurrent = false,
				afterCurrent = true,
				beforeConsumed = false,
				afterConsumed = false,
				beforeData = capability.data,
				afterData = draft.data,
			}
			table.freeze(activate)
			table.insert(mutations, activate)
			nextTombstones[player] = capability
		else
			if nextTombstones[player] ~= capability or not capability.current or capability.consumed then
				return nil, nil, nil, "stale-updated-respawn-copy-tombstone"
			end
			local update: TombstoneMutation = {
				capability = capability,
				beforeCurrent = true,
				afterCurrent = true,
				beforeConsumed = false,
				afterConsumed = false,
				beforeData = capability.data,
				afterData = draft.data,
			}
			table.freeze(update)
			table.insert(mutations, update)
		end
	end
	table.sort(mutations, function(left: TombstoneMutation, right: TombstoneMutation): boolean
		local leftData = left.afterData
		local rightData = right.afterData
		if leftData.playerSourceOrder ~= rightData.playerSourceOrder then
			return leftData.playerSourceOrder < rightData.playerSourceOrder
		end
		if left.afterCurrent ~= right.afterCurrent then
			return not left.afterCurrent
		end
		return leftData.lifeSequence < rightData.lifeSequence
	end)
	local tombstoneCount = 0
	for _ in nextTombstones do
		tombstoneCount += 1
	end
	table.freeze(nextTombstones)
	table.freeze(mutations)
	return nextTombstones, mutations, tombstoneCount, nil
end

local function prepareCommittedEntries(transaction: Transaction): ({ [Player]: Entry }?, number?, string?)
	if transaction.baseRevision ~= revision or transaction.baseEntries ~= committedEntriesByPlayer then
		return nil, nil, "stale-corpse-transaction-base"
	end
	local preparedEntries: { [Player]: Entry } = {}
	local seenBodyIds: { [string]: boolean } = {}
	local seenSourceOrders: { [number]: boolean } = {}
	local count = 0
	for player, entry in transaction.entriesByPlayer do
		if entry.player ~= player or player.Parent ~= Players then
			return nil, nil, "stale-prepared-corpse-player"
		end
		local binding, bindingError = MoverConsequenceRules.ValidateBinding(entry.binding)
		if not binding then
			return nil, nil, bindingError or "invalid-prepared-corpse-binding"
		end
		if
			binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
			or binding.playerUserId ~= player.UserId
			or binding.lifeSequence < 1
		then
			return nil, nil, "stale-prepared-corpse-binding"
		end
		local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ entry.body })
		if not bodies then
			return nil, nil, bodyError or "invalid-prepared-corpse-body"
		end
		local body = bodies[1]
		if
			body.id ~= binding.bodyId
			or body.size ~= MoverConsequenceRules.ClientCorpseSize
			or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
			or body.contents ~= MoverPushRules.Contents.Corpse
			or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
			or seenBodyIds[body.id] == true
			or seenSourceOrders[body.sourceOrder] == true
		then
			return nil, nil, "invalid-prepared-corpse-lineage"
		end
		if not isFiniteInteger(entry.health, MoverConsequenceRules.MinimumRawPostDamageHealth, 0) then
			return nil, nil, "invalid-prepared-corpse-health"
		end
		seenBodyIds[body.id] = true
		seenSourceOrders[body.sourceOrder] = true
		local preparedEntry: Entry = {
			player = player,
			binding = binding :: PlayerBinding,
			body = body,
			health = entry.health,
		}
		table.freeze(preparedEntry)
		preparedEntries[player] = preparedEntry
		count += 1
	end
	table.freeze(preparedEntries)
	return preparedEntries, count, nil
end

local function getPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-corpse-prepared-commit"
	end
	local capability = preparedCapabilities[preparedValue :: PreparedCommit]
	if not capability then
		return nil, "invalid-corpse-prepared-commit"
	end
	return capability, nil
end

-- This recheck is deliberately allocation- and callback-free so ApplyPrepared
-- can reject a preflight that became stale across an accidental yield without
-- exposing any authority assignment. Prepare already canonicalized and froze
-- every binding/body; this verifies that immutable lineage plus the mutable
-- owner/player roots immediately before capability consumption.
local function preparedCommitCurrentError(
	preparedValue: unknown,
	capability: PreparedCapability,
	validateExternalDependencies: boolean
): string?
	local transaction = capability.transaction
	if
		capability.status ~= "Prepared"
		or activeTransaction ~= transaction
		or transaction.status ~= "Prepared"
		or transaction.prepared ~= preparedValue
		or transaction.baseRevision ~= revision
		or transaction.baseEntries ~= committedEntriesByPlayer
		or transaction.baseTombstones ~= committedTombstonesByPlayer
		or capability.receipt.revision ~= revision + 1
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.entriesByPlayer)
		or not table.isfrozen(capability.tombstonesByPlayer)
		or not table.isfrozen(capability.tombstoneMutations)
		or not table.isfrozen(capability.tombstoneSummariesByHandle)
		or not table.isfrozen(capability.receipt)
	then
		return "stale-corpse-prepared-commit"
	end
	local corpseCount = 0
	for player, entry in capability.entriesByPlayer do
		local binding = entry.binding
		local body = entry.body
		if
			player.Parent ~= Players
			or entry.player ~= player
			or not table.isfrozen(entry)
			or not table.isfrozen(binding)
			or not table.isfrozen(body)
			or binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
			or binding.playerUserId ~= player.UserId
			or binding.lifeSequence < 1
			or binding.bodyId ~= body.id
			or not isFiniteInteger(body.sourceOrder, 1, MoverPushRules.MaximumSourceOrder)
			or body.size ~= MoverConsequenceRules.ClientCorpseSize
			or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
			or body.contents ~= MoverPushRules.Contents.Corpse
			or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
			or not isFiniteInteger(entry.health, MoverConsequenceRules.MinimumRawPostDamageHealth, 0)
		then
			return "stale-corpse-prepared-lineage"
		end
		corpseCount += 1
	end
	if corpseCount ~= capability.receipt.committedCorpseCount then
		return "stale-corpse-prepared-commit"
	end
	local tombstoneCount = 0
	for player, tombstone in capability.tombstonesByPlayer do
		local plannedMutation: TombstoneMutation? = nil
		for _, mutation in capability.tombstoneMutations do
			if mutation.capability == tombstone then
				plannedMutation = mutation
				break
			end
		end
		local expectedSource = if plannedMutation then plannedMutation.afterData else tombstone.data
		local summary = capability.tombstoneSummariesByHandle[tombstone.handle]
		if
			tombstone.player ~= player
			or tombstoneCapabilities[tombstone.handle] ~= tombstone
			or tombstoneCapabilityCurrentError(tombstone, validateExternalDependencies) ~= nil
			or (plannedMutation == nil and (committedTombstonesByPlayer[player] ~= tombstone or not tombstone.current or tombstone.consumed))
			or (plannedMutation ~= nil and (not plannedMutation.afterCurrent or plannedMutation.afterConsumed))
			or summary == nil
			or not table.isfrozen(summary)
			or summary.corpseBaseRevision ~= transaction.baseRevision
			or summary.corpseCommitRevision ~= capability.receipt.revision
			or summary.player ~= player
			or summary.tombstone ~= tombstone.handle
			or summary.source ~= expectedSource
			or preparedRespawnCopyTombstoneSummaries[summary] ~= preparedValue
		then
			return "stale-corpse-prepared-tombstone-lineage"
		end
		tombstoneCount += 1
	end
	if tombstoneCount ~= capability.receipt.committedTombstoneCount then
		return "stale-corpse-prepared-commit"
	end
	local tombstoneSummaryCount = 0
	for handle, summary in capability.tombstoneSummariesByHandle do
		if summary.tombstone ~= handle then
			return "stale-corpse-prepared-tombstone-summary"
		end
		tombstoneSummaryCount += 1
	end
	if tombstoneSummaryCount ~= tombstoneCount then
		return "stale-corpse-prepared-tombstone-summary"
	end
	for _, mutation in capability.tombstoneMutations do
		local tombstone = mutation.capability
		if
			not table.isfrozen(mutation)
			or tombstone.current ~= mutation.beforeCurrent
			or tombstone.consumed ~= mutation.beforeConsumed
			or tombstone.data ~= mutation.beforeData
			or tombstoneCapabilities[tombstone.handle] ~= tombstone
			or not table.isfrozen(mutation.afterData)
			or tombstoneDataCurrentError(mutation.afterData, tombstone.player, validateExternalDependencies) ~= nil
			or (
				validateExternalDependencies
				and EntitySlotService.GetPlayerRegistration(tombstone.player) ~= tombstone.registration
			)
		then
			return "stale-corpse-prepared-tombstone-mutation"
		end
	end
	return nil
end

local function getTransaction(tokenValue: unknown, requiredStatus: Status?): (Transaction?, string?)
	local transaction = activeTransaction
	if type(tokenValue) ~= "table" or not transaction or transaction.token ~= tokenValue then
		return nil, "invalid-corpse-transaction-token"
	end
	if requiredStatus and transaction.status ~= requiredStatus then
		return nil, "invalid-corpse-transaction-state"
	end
	return transaction, nil
end

local function validatePlayerBinding(
	playerValue: unknown,
	bindingValue: unknown,
	expectedKind: "LivePlayer" | "ClientCorpse"
): (Player?, PlayerBinding?, string?)
	if not isPlayer(playerValue) then
		return nil, nil, "invalid-corpse-player"
	end
	local player = playerValue :: Player
	if player.Parent ~= Players then
		return nil, nil, "stale-corpse-player"
	end
	local binding, bindingError = MoverConsequenceRules.ValidateBinding(bindingValue)
	if not binding then
		return nil, nil, bindingError or "invalid-corpse-binding"
	end
	if binding.kind ~= expectedKind or binding.playerUserId ~= player.UserId or binding.lifeSequence < 1 then
		return nil, nil, "stale-corpse-player-binding"
	end
	return player, binding :: PlayerBinding, nil
end

local function sameCorpseLineage(left: MoverPushRules.Body, rightValue: unknown): boolean
	if type(rightValue) ~= "table" then
		return false
	end
	local right = rightValue :: { [unknown]: unknown }
	return right.id == left.id
		and right.sourceOrder == left.sourceOrder
		and right.size == left.size
		and right.centerOffset == left.centerOffset
		and right.velocity == left.velocity
		and right.contents == left.contents
		and right.clipMask == left.clipMask
end

local function makeEffect(
	resolution: MoverConsequenceRules.PlayerCollisionResolution
): MoverPushRules.SynchronousCrushEffect
	local effect: MoverPushRules.SynchronousCrushEffect
	if resolution.disposition == "Replace" then
		effect = {
			kind = "Replace",
			replacementBody = resolution.body,
			insertedBodies = EMPTY_INSERTED_BODIES,
		}
	elseif resolution.disposition == "Remove" then
		effect = {
			kind = "Remove",
			insertedBodies = EMPTY_INSERTED_BODIES,
		}
	else
		effect = {
			kind = "Retain",
			insertedBodies = EMPTY_INSERTED_BODIES,
		}
	end
	table.freeze(effect)
	return effect
end

local function collectionFromEntries(entries: { [Player]: Entry }): Collection
	local bodies: { MoverPushRules.Body } = {}
	local playersByBodyId: { [string]: Player } = {}
	for player, entry in entries do
		assert(playersByBodyId[entry.body.id] == nil, "committed corpse body identity duplicated")
		table.insert(bodies, entry.body)
		playersByBodyId[entry.body.id] = player
	end
	table.sort(bodies, function(left: MoverPushRules.Body, right: MoverPushRules.Body): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(bodies)
	table.freeze(playersByBodyId)
	local collection: Collection = {
		bodies = bodies,
		playersByBodyId = playersByBodyId,
	}
	table.freeze(collection)
	return collection
end

function CorpseService.Begin(): (TransactionToken?, string?)
	if activeTransaction then
		return nil, "corpse-transaction-active"
	end
	if activeTombstoneConsume then
		return nil, "corpse-tombstone-consume-active"
	end
	local token: TransactionToken = table.freeze({})
	local entries = cloneEntries(committedEntriesByPlayer)
	local touchedBodyIds: { [string]: boolean } = {}
	for _, entry in entries do
		touchedBodyIds[entry.body.id] = true
	end
	activeTransaction = {
		token = token,
		status = "Open",
		baseRevision = revision,
		baseEntries = committedEntriesByPlayer,
		baseTombstones = committedTombstonesByPlayer,
		entriesByPlayer = entries,
		tombstoneDraftsByPlayer = {},
		newTombstones = {},
		postPmovePoseStagedByPlayer = {},
		touchedBodyIds = touchedBodyIds,
		finalBodiesApplied = false,
		prepared = nil,
	}
	return token, nil
end

function CorpseService.Collect(tokenValue: unknown): (Collection?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return nil, transactionError
	end
	return collectionFromEntries(transaction.entriesByPlayer), nil
end

function CorpseService.GetBinding(tokenValue: unknown, playerValue: unknown, bodyIdValue: unknown): PlayerBinding?
	local transaction = select(1, getTransaction(tokenValue, "Open"))
	if not transaction or not isPlayer(playerValue) or type(bodyIdValue) ~= "string" then
		return nil
	end
	local entry = transaction.entriesByPlayer[playerValue :: Player]
	if not entry or entry.body.id ~= bodyIdValue then
		return nil
	end
	return entry.binding
end

function CorpseService.GetHealth(tokenValue: unknown, playerValue: unknown, bodyIdValue: unknown): number?
	local transaction = select(1, getTransaction(tokenValue, "Open"))
	if not transaction or not isPlayer(playerValue) or type(bodyIdValue) ~= "string" then
		return nil
	end
	local entry = transaction.entriesByPlayer[playerValue :: Player]
	if not entry or entry.body.id ~= bodyIdValue then
		return nil
	end
	return entry.health
end

-- Live PM_DEAD composition calls this after Movement has produced the
-- authoritative dead-player collision pose and before movers consume the
-- transaction collection. Only pose, velocity, and ground-mover identity may
-- differ from the existing immediate client corpse. The exact opaque binding,
-- entity-slot identity/source order, life, dead hull, contents, and clip mask
-- remain owned by the already committed Corpse/tombstone roots.
--
-- This narrow seam does not step Movement, authorize a respawn, consume a
-- tombstone, or publish an avatar.
function CorpseService.StagePostPmoveCorpsePose(
	tokenValue: unknown,
	playerValue: unknown,
	bindingValue: unknown,
	bodyValue: unknown
): (MoverPushRules.Body?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return nil, transactionError
	end
	if not isPlayer(playerValue) then
		return nil, "invalid-post-pmove-corpse-player"
	end
	local player = playerValue :: Player
	if player.Parent ~= Players then
		return nil, "stale-post-pmove-corpse-player"
	end
	if transaction.postPmovePoseStagedByPlayer[player] then
		return nil, "duplicate-post-pmove-corpse-pose"
	end
	if type(bindingValue) ~= "table" then
		return nil, "invalid-post-pmove-corpse-binding"
	end
	local rawBinding = bindingValue :: { [unknown]: unknown }
	if not hasExactRawKeys(rawBinding, PLAYER_BINDING_KEYS, 4) then
		return nil, "invalid-post-pmove-corpse-binding-shape"
	end
	local binding, bindingError = MoverConsequenceRules.ValidateBinding(bindingValue)
	if not binding then
		return nil, bindingError or "invalid-post-pmove-corpse-binding"
	end
	local existing = transaction.entriesByPlayer[player]
	local baseEntry = transaction.baseEntries[player]
	if
		binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
		or not existing
		or existing.player ~= player
		or existing.binding ~= bindingValue
		or binding.playerUserId ~= player.UserId
		or binding.bodyId ~= existing.body.id
	then
		return nil, "stale-post-pmove-corpse-binding"
	end

	if type(bodyValue) ~= "table" then
		return nil, "invalid-post-pmove-corpse-body"
	end
	local rawBody = bodyValue :: { [unknown]: unknown }
	local expectedBodyKeys = if rawget(rawBody, "groundMoverId") == nil then 8 else 9
	if not hasExactRawKeys(rawBody, BODY_KEYS, expectedBodyKeys) then
		return nil, "invalid-post-pmove-corpse-body-shape"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ bodyValue })
	if not bodies then
		return nil, bodyError or "invalid-post-pmove-corpse-body"
	end
	local body = bodies[1]
	if
		body.id ~= existing.body.id
		or body.id ~= binding.bodyId
		or body.sourceOrder ~= existing.body.sourceOrder
		or body.size ~= MoverConsequenceRules.ClientCorpseSize
		or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
		or body.contents ~= MoverPushRules.Contents.Corpse
		or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
	then
		return nil, "post-pmove-corpse-body-lineage-mismatch"
	end

	local committedTombstone = transaction.baseTombstones[player]
	if
		not committedTombstone
		or committedTombstonesByPlayer[player] ~= committedTombstone
		or not committedTombstone.current
		or committedTombstone.consumed
		or tombstoneCapabilities[committedTombstone.handle] ~= committedTombstone
		or tombstoneCapabilityCurrentError(committedTombstone) ~= nil
		or not tombstoneMatchesPlayerBinding(committedTombstone.data, player, existing.binding, existing.body)
	then
		return nil, "post-pmove-corpse-tombstone-not-current"
	end
	if
		not baseEntry
		or transaction.baseEntries ~= committedEntriesByPlayer
		or baseEntry.player ~= player
		or existing.binding ~= baseEntry.binding
		or baseEntry.body.id ~= existing.body.id
		or baseEntry.body.sourceOrder ~= existing.body.sourceOrder
	then
		return nil, "stale-post-pmove-corpse-binding"
	end
	local tombstoneDraft, tombstoneError =
		ensureCommittedTombstoneDraft(transaction, player, existing.binding, existing.body)
	if not tombstoneDraft then
		return nil, tombstoneError or "post-pmove-corpse-tombstone-not-current"
	end
	if
		tombstoneDraft.capability ~= committedTombstone
		or tombstoneDraft.isNew
		or not tombstoneDraft.deathResolved
		or tombstoneDraft.data.lifeSequence ~= binding.lifeSequence
	then
		return nil, "stale-post-pmove-corpse-tombstone-draft"
	end

	local prior = tombstoneDraft.data
	tombstoneDraft.data = makeTombstoneData(
		prior,
		prior.matchId,
		prior.matchLineage,
		prior.playerBodyId,
		prior.playerSourceOrder,
		prior.playerLeaseGeneration,
		prior.playerUserId,
		prior.lifeSequence,
		body,
		prior.sourceLinked,
		prior.entityType,
		existing.health
	)
	transaction.entriesByPlayer[player] = {
		player = player,
		binding = existing.binding,
		body = body,
		health = existing.health,
	}
	transaction.postPmovePoseStagedByPlayer[player] = true
	transaction.touchedBodyIds[body.id] = true
	transaction.finalBodiesApplied = false
	return body, nil
end

function CorpseService.StagePostPmoveInvisiblePose(
	tokenValue: unknown,
	playerValue: unknown,
	bodyValue: unknown
): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return false, transactionError
	end
	if not isPlayer(playerValue) or type(bodyValue) ~= "table" then
		return false, "invalid-invisible-post-pmove-pose"
	end
	local player = playerValue :: Player
	if transaction.entriesByPlayer[player] ~= nil then
		return false, "invisible-post-pmove-client-has-collision-corpse"
	end
	local capability = transaction.baseTombstones[player]
	if
		not capability
		or not capability.current
		or capability.consumed
		or capability.data.entityType ~= "Invisible"
		or tombstoneCapabilities[capability.handle] ~= capability
	then
		return false, "invisible-post-pmove-tombstone-unavailable"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ bodyValue })
	if not bodies then
		return false, bodyError
	end
	local body = bodies[1]
	local prior = capability.data
	if
		body.id ~= prior.body.id
		or body.sourceOrder ~= prior.body.sourceOrder
		or body.size ~= prior.body.size
		or body.centerOffset ~= prior.body.centerOffset
		or body.contents ~= prior.body.contents
		or body.clipMask ~= prior.body.clipMask
	then
		return false, "invisible-post-pmove-body-identity-drifted"
	end
	transaction.tombstoneDraftsByPlayer[player] = {
		capability = capability,
		previousCapability = nil,
		data = makeTombstoneData(
			prior,
			prior.matchId,
			prior.matchLineage,
			prior.playerBodyId,
			prior.playerSourceOrder,
			prior.playerLeaseGeneration,
			prior.playerUserId,
			prior.lifeSequence,
			body,
			prior.sourceLinked,
			prior.entityType,
			prior.sourceHealth
		),
		isNew = false,
		deathResolved = true,
	}
	transaction.touchedBodyIds[body.id] = true
	transaction.finalBodiesApplied = false
	return true, nil
end

-- This is an unwired death-composite seam. It captures only lineage plus the
-- collision fields Corpse already owns. StageCollision must subsequently
-- resolve the exact death in the same transaction before Prepare may publish
-- the opaque handle. Grounded/airborne and the two Q3 velocity domains remain
-- intentionally absent until Movement supplies them at respawn time.
function CorpseService.StageRespawnCopyTombstone(
	tokenValue: unknown,
	playerValue: unknown,
	requestValue: unknown
): (RespawnCopyTombstone?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return nil, transactionError
	end
	if not isPlayer(playerValue) then
		return nil, "invalid-respawn-copy-tombstone-player"
	end
	local player = playerValue :: Player
	if player.Parent ~= Players then
		return nil, "stale-respawn-copy-tombstone-player"
	end
	if type(requestValue) ~= "table" then
		return nil, "respawn-copy-tombstone-request-not-table"
	end
	local raw = requestValue :: { [unknown]: unknown }
	if
		not hasExactKeys(raw, TOMBSTONE_STAGE_KEYS, 8)
		or type(raw.matchId) ~= "string"
		or raw.matchId == ""
		or type(raw.matchLineage) ~= "table"
		or not table.isfrozen(raw.matchLineage :: table)
		or not MatchService.ValidateMatchLineage(raw.matchLineage, raw.matchId)
		or raw.playerUserId ~= player.UserId
		or not isFiniteInteger(raw.playerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or not isFiniteInteger(raw.playerSourceOrder, 1, EntitySourceOrderRules.MaximumClients)
		or not isFiniteInteger(raw.playerLeaseGeneration, 1, MAXIMUM_GENERATION)
		or not isFiniteInteger(raw.lifeSequence, 1, MAXIMUM_GENERATION)
	then
		return nil, "invalid-respawn-copy-tombstone-lineage"
	end
	if transaction.tombstoneDraftsByPlayer[player] then
		return nil, "duplicate-respawn-copy-tombstone"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ raw.body })
	if not bodies then
		return nil, bodyError or "invalid-respawn-copy-tombstone-live-body"
	end
	local liveBody = bodies[1]
	local registration = EntitySlotService.GetPlayerRegistration(player)
	if
		not registration
		or registration.bodyId ~= raw.playerBodyId
		or registration.sourceOrder ~= raw.playerSourceOrder
		or registration.generation ~= raw.playerLeaseGeneration
	then
		return nil, "respawn-copy-tombstone-player-lease-mismatch"
	end
	if
		liveBody.id ~= raw.playerBodyId
		or liveBody.sourceOrder ~= raw.playerSourceOrder
		or liveBody.sourceOrder > EntitySourceOrderRules.MaximumClients
	then
		return nil, "respawn-copy-tombstone-live-body-lineage-mismatch"
	end
	local corpseBody, corpseBodyError = MoverConsequenceRules.BuildClientCorpseBody(liveBody)
	if not corpseBody then
		return nil, corpseBodyError or "respawn-copy-tombstone-live-body-invalid"
	end
	local previousCapability = transaction.baseTombstones[player]
	if previousCapability then
		return nil, "respawn-copy-tombstone-already-current"
	end
	local seed = makeTombstoneData(
		nil,
		raw.matchId :: string,
		raw.matchLineage :: MatchService.MatchLineage,
		raw.playerBodyId :: string,
		raw.playerSourceOrder :: number,
		raw.playerLeaseGeneration :: number,
		raw.playerUserId :: number,
		raw.lifeSequence :: number,
		corpseBody,
		true,
		"Player",
		0
	)
	local handle: RespawnCopyTombstone = table.freeze({})
	local capability: TombstoneCapability = {
		handle = handle,
		player = player,
		registration = registration,
		current = false,
		consumed = false,
		data = seed,
	}
	tombstoneCapabilities[handle] = capability
	table.insert(transaction.newTombstones, capability)
	transaction.tombstoneDraftsByPlayer[player] = {
		capability = capability,
		previousCapability = nil,
		data = seed,
		isNew = true,
		deathResolved = false,
	}
	return handle, nil
end

function CorpseService.StageCollision(
	tokenValue: unknown,
	playerValue: unknown,
	bindingValue: unknown,
	bodyValue: unknown,
	postDamageHealthValue: unknown,
	meansOfDeathValue: unknown,
	bloodEnabledValue: unknown,
	noDropValue: unknown
): (MoverPushRules.SynchronousCrushEffect?, number?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return nil, nil, transactionError
	end
	if type(bindingValue) ~= "table" then
		return nil, nil, "invalid-corpse-binding"
	end
	local requestedKind = (bindingValue :: { [unknown]: unknown }).kind
	if requestedKind ~= "LivePlayer" and requestedKind ~= "ClientCorpse" then
		return nil, nil, "unsupported-corpse-binding-kind"
	end
	local player, binding, bindingError =
		validatePlayerBinding(playerValue, bindingValue, requestedKind :: "LivePlayer" | "ClientCorpse")
	if not player or not binding then
		return nil, nil, bindingError
	end
	local existing = transaction.entriesByPlayer[player]
	if requestedKind == "LivePlayer" then
		if existing then
			return nil, nil, "live-player-already-has-corpse"
		end
	elseif
		not existing
		or existing.binding ~= bindingValue
		or existing.body.id ~= binding.bodyId
		or not sameCorpseLineage(existing.body, bodyValue)
	then
		return nil, nil, "stale-client-corpse-collision"
	end
	local tombstoneDraft: TombstoneDraft? = nil
	if requestedKind == "LivePlayer" then
		tombstoneDraft = transaction.tombstoneDraftsByPlayer[player]
		if tombstoneDraft then
			local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ bodyValue })
			if not bodies then
				return nil, nil, bodyError or "invalid-live-player-tombstone-body"
			end
			if not tombstoneMatchesPlayerBinding(tombstoneDraft.data, player, binding, bodies[1]) then
				return nil, nil, "stale-live-player-tombstone-lineage"
			end
		end
	else
		local resolvedDraft, draftError =
			ensureCommittedTombstoneDraft(transaction, player, binding, (existing :: Entry).body)
		if draftError then
			return nil, nil, draftError
		end
		tombstoneDraft = resolvedDraft
	end

	local resolution, resolutionError = MoverConsequenceRules.ResolvePlayerCollision({
		binding = binding,
		body = bodyValue,
		postDamageHealth = postDamageHealthValue,
		meansOfDeath = meansOfDeathValue,
		bloodEnabled = bloodEnabledValue,
		noDrop = noDropValue,
	})
	if not resolution then
		return nil, nil, resolutionError or "corpse-collision-resolution-failed"
	end
	if tombstoneDraft then
		local tombstoneBody: MoverPushRules.Body?
		if resolution.disposition == "Remove" then
			if requestedKind == "LivePlayer" then
				local builtBody, builtBodyError = MoverConsequenceRules.BuildClientCorpseBody(bodyValue)
				if not builtBody then
					return nil, nil, builtBodyError or "removed-live-player-tombstone-body-invalid"
				end
				tombstoneBody = builtBody
			else
				-- G_MoverPush may have already moved this linked corpse earlier in
				-- the same transaction. GibEntity clears contents/eType but does
				-- not restore the prior pose, so retain the collision input that
				-- actually reached body_die rather than the base entry. Canonicalize
				-- it separately because RemoveResolution intentionally carries only
				-- identity, while this public Stage API admits raw valid bodies.
				local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({ bodyValue })
				if not bodies then
					return nil, nil, bodyError or "removed-client-corpse-tombstone-body-invalid"
				end
				tombstoneBody = bodies[1]
			end
		else
			tombstoneBody = resolution.body
		end
		local prior = tombstoneDraft.data
		tombstoneDraft.data = makeTombstoneData(
			prior,
			prior.matchId,
			prior.matchLineage,
			prior.playerBodyId,
			prior.playerSourceOrder,
			prior.playerLeaseGeneration,
			prior.playerUserId,
			prior.lifeSequence,
			tombstoneBody :: MoverPushRules.Body,
			-- GibEntity clears contents and visibility but does not unlink. A
			-- direct player_die path links the client afterward, and later
			-- body_die leaves that existing link intact.
			true,
			if resolution.disposition == "Remove" then "Invisible" else "Player",
			resolution.resolvedHealth
		)
		tombstoneDraft.deathResolved = true
	end
	transaction.touchedBodyIds[binding.bodyId] = true
	if resolution.disposition == "Replace" then
		transaction.entriesByPlayer[player] = {
			player = player,
			binding = resolution.binding,
			body = resolution.body,
			health = resolution.resolvedHealth,
		}
	elseif resolution.disposition == "Retain" then
		assert(existing, "retained corpse collision lost its existing entry")
		transaction.entriesByPlayer[player] = {
			player = player,
			binding = resolution.binding,
			body = resolution.body,
			health = resolution.resolvedHealth,
		}
	else
		transaction.entriesByPlayer[player] = nil
	end
	transaction.finalBodiesApplied = false
	return makeEffect(resolution), resolution.resolvedHealth, nil
end

function CorpseService.ApplyMoverBodies(tokenValue: unknown, bodiesValue: unknown): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return false, transactionError
	end
	local bodies, bodiesError = MoverPushRules.ValidateAndOrderBodies(bodiesValue)
	if not bodies then
		return false, bodiesError or "invalid-final-mover-bodies"
	end
	local bodiesById: { [string]: MoverPushRules.Body } = {}
	for _, body in bodies do
		bodiesById[body.id] = body
	end
	for player, entry in transaction.entriesByPlayer do
		local body = bodiesById[entry.body.id]
		if not body then
			return false, "final-corpse-body-missing"
		end
		if
			body.sourceOrder ~= entry.body.sourceOrder
			or body.size ~= MoverConsequenceRules.ClientCorpseSize
			or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
			or body.velocity ~= entry.body.velocity
			or body.contents ~= MoverPushRules.Contents.Corpse
			or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
		then
			return false, "final-corpse-body-drifted"
		end
		local tombstoneDraft, tombstoneError =
			ensureCommittedTombstoneDraft(transaction, player, entry.binding, entry.body)
		if tombstoneError then
			return false, tombstoneError
		end
		if tombstoneDraft then
			local prior = tombstoneDraft.data
			tombstoneDraft.data = makeTombstoneData(
				prior,
				prior.matchId,
				prior.matchLineage,
				prior.playerBodyId,
				prior.playerSourceOrder,
				prior.playerLeaseGeneration,
				prior.playerUserId,
				prior.lifeSequence,
				body,
				prior.sourceLinked,
				prior.entityType,
				entry.health
			)
		end
		transaction.entriesByPlayer[player] = {
			player = player,
			binding = entry.binding,
			body = body,
			health = entry.health,
		}
	end
	for bodyId in transaction.touchedBodyIds do
		local expected = false
		for _, entry in transaction.entriesByPlayer do
			if entry.body.id == bodyId then
				expected = true
				break
			end
		end
		if not expected and bodiesById[bodyId] ~= nil then
			return false, "removed-corpse-body-remained"
		end
	end
	transaction.finalBodiesApplied = true
	return true, nil
end

function CorpseService.Seal(tokenValue: unknown): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Open")
	if not transaction then
		return false, transactionError
	end
	if not transaction.finalBodiesApplied then
		return false, "corpse-final-bodies-not-applied"
	end
	transaction.status = "Sealed"
	return true, nil
end

function CorpseService.Prepare(tokenValue: unknown): (PreparedCommit?, string?)
	local transaction, transactionError = getTransaction(tokenValue, "Sealed")
	if not transaction then
		return nil, transactionError
	end
	if not transaction.finalBodiesApplied or transaction.prepared ~= nil then
		return nil, "invalid-corpse-transaction-state"
	end
	local preparedEntries, corpseCount, prepareError = prepareCommittedEntries(transaction)
	if not preparedEntries or corpseCount == nil then
		return nil, prepareError or "corpse-prepare-failed"
	end
	local preparedTombstones, tombstoneMutations, tombstoneCount, tombstonePrepareError =
		prepareCommittedTombstones(transaction)
	if not preparedTombstones or not tombstoneMutations or tombstoneCount == nil then
		return nil, tombstonePrepareError or "corpse-tombstone-prepare-failed"
	end
	local prepared: PreparedCommit = table.freeze({})
	local receipt: CommitReceipt = {
		revision = revision + 1,
		committedCorpseCount = corpseCount,
		committedTombstoneCount = tombstoneCount,
	}
	table.freeze(receipt)
	local tombstoneSourcesByHandle: {
		[RespawnCopyTombstone]: RespawnCopyTombstoneData,
	} = {}
	for _, mutation in tombstoneMutations do
		if mutation.afterCurrent and not mutation.afterConsumed then
			tombstoneSourcesByHandle[mutation.capability.handle] = mutation.afterData
		end
	end
	local tombstoneSummariesByHandle: {
		[RespawnCopyTombstone]: PreparedRespawnCopyTombstoneSummary,
	} = {}
	for player, tombstone in preparedTombstones do
		local summary: PreparedRespawnCopyTombstoneSummary = {
			corpseBaseRevision = revision,
			corpseCommitRevision = receipt.revision,
			player = player,
			tombstone = tombstone.handle,
			source = tombstoneSourcesByHandle[tombstone.handle] or tombstone.data,
		}
		table.freeze(summary)
		tombstoneSummariesByHandle[tombstone.handle] = summary
		preparedRespawnCopyTombstoneSummaries[summary] = prepared
	end
	table.freeze(tombstoneSummariesByHandle)
	preparedCapabilities[prepared] = {
		transaction = transaction,
		status = "Prepared",
		entriesByPlayer = preparedEntries,
		tombstonesByPlayer = preparedTombstones,
		tombstoneMutations = tombstoneMutations,
		tombstoneSummariesByHandle = tombstoneSummariesByHandle,
		receipt = receipt,
		applyValidated = false,
	}
	transaction.prepared = prepared
	transaction.status = "Prepared"
	return prepared, nil
end

-- A future direct-death coordinator must retain the exact tombstone staged in
-- this exact prepared Corpse transaction. The summary exposes only frozen
-- lineage/data; its private reverse capability prevents a look-alike record or
-- a handle crossed from another transaction from satisfying the dependency.
function CorpseService.InspectPreparedRespawnCopyTombstoneSummary(
	preparedValue: unknown,
	tombstoneValue: unknown
): PreparedRespawnCopyTombstoneSummary?
	if type(preparedValue) ~= "table" or type(tombstoneValue) ~= "table" then
		return nil
	end
	local prepared = preparedValue :: PreparedCommit
	local tombstone = tombstoneValue :: RespawnCopyTombstone
	local capability = preparedCapabilities[prepared]
	if not capability or preparedCommitCurrentError(prepared, capability, true) then
		return nil
	end
	return capability.tombstoneSummariesByHandle[tombstone]
end

function CorpseService.InspectPreparedCommitReceipt(preparedValue: unknown): CommitReceipt?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local prepared = preparedValue :: PreparedCommit
	local capability = preparedCapabilities[prepared]
	if not capability or preparedCommitCurrentError(prepared, capability, true) then
		return nil
	end
	return capability.receipt
end

function CorpseService.ValidatePreparedRespawnCopyTombstoneDependency(
	preparedValue: unknown,
	tombstoneValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(preparedValue) ~= "table" or type(tombstoneValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-prepared-respawn-copy-tombstone-dependency"
	end
	local prepared = preparedValue :: PreparedCommit
	local tombstone = tombstoneValue :: RespawnCopyTombstone
	local summary = summaryValue :: PreparedRespawnCopyTombstoneSummary
	local capability = preparedCapabilities[prepared]
	if
		not capability
		or capability.tombstoneSummariesByHandle[tombstone] ~= summary
		or preparedRespawnCopyTombstoneSummaries[summary] ~= prepared
	then
		return false, "forged-prepared-respawn-copy-tombstone-dependency"
	end
	local currentError = preparedCommitCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function CorpseService.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedCommitCurrentError(preparedValue, capability, true)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

-- Prepare performs every allocating/canonicalizing operation, while
-- CanApplyPrepared offers a fallible composite preflight. ApplyPrepared repeats
-- the owner-local mutable-root and frozen-lineage checks without allocating or
-- invoking a callback. Match/EntitySlot lineage was checked in each composite
-- preflight and must not be re-entered after an earlier owner swaps its root.
-- The function then enters an assignment-only authority block with no failure
-- return channel.
function CorpseService.ApplyPrepared(preparedValue: unknown): CommitReceipt
	local capability, capabilityError = getPreparedCapability(preparedValue)
	assert(capability, capabilityError or "invalid-corpse-prepared-commit")
	local transaction = capability.transaction
	assert(capability.applyValidated, "corpse-prepared-commit-not-validated")
	local currentError = preparedCommitCurrentError(preparedValue, capability, false)
	assert(currentError == nil, currentError or "stale-corpse-prepared-commit")

	local receipt = capability.receipt
	for _, mutation in capability.tombstoneMutations do
		local tombstone = mutation.capability
		tombstone.data = mutation.afterData
		tombstone.current = mutation.afterCurrent
		tombstone.consumed = mutation.afterConsumed
	end
	committedEntriesByPlayer = capability.entriesByPlayer
	committedTombstonesByPlayer = capability.tombstonesByPlayer
	revision = receipt.revision
	transaction.status = "Applied"
	transaction.prepared = nil
	activeTransaction = nil
	capability.status = "Applied"
	capability.applyValidated = false
	for _, summary in capability.tombstoneSummariesByHandle do
		preparedRespawnCopyTombstoneSummaries[summary] = nil
	end
	preparedCapabilities[preparedValue :: PreparedCommit] = nil
	return receipt
end

function CorpseService.Commit(tokenValue: unknown): (boolean, string?)
	local prepared, prepareError = CorpseService.Prepare(tokenValue)
	if not prepared then
		CorpseService.Abort(tokenValue)
		return false, prepareError
	end
	local canApply, canApplyError = CorpseService.CanApplyPrepared(prepared)
	if not canApply then
		CorpseService.Abort(tokenValue)
		return false, canApplyError
	end
	CorpseService.ApplyPrepared(prepared)
	return true, nil
end

function CorpseService.Abort(tokenValue: unknown): boolean
	local transaction = select(1, getTransaction(tokenValue, nil))
	if not transaction then
		return false
	end
	if transaction.status ~= "Open" and transaction.status ~= "Sealed" and transaction.status ~= "Prepared" then
		return false
	end
	local prepared = transaction.prepared
	if prepared then
		local capability = preparedCapabilities[prepared]
		if capability then
			capability.status = "Aborted"
			capability.applyValidated = false
			for _, summary in capability.tombstoneSummariesByHandle do
				preparedRespawnCopyTombstoneSummaries[summary] = nil
			end
		end
		preparedCapabilities[prepared] = nil
		transaction.prepared = nil
	end
	for _, tombstone in transaction.newTombstones do
		tombstone.current = false
		tombstone.consumed = true
		tombstoneCapabilities[tombstone.handle] = nil
	end
	transaction.status = "Aborted"
	activeTransaction = nil
	return true
end

function CorpseService.GetCommittedCollection(): Collection
	return collectionFromEntries(committedEntriesByPlayer)
end

function CorpseService.IsCurrentInvisibleClient(playerValue: unknown): boolean
	if not isPlayer(playerValue) then
		return false
	end
	local player = playerValue :: Player
	local tombstone = committedTombstonesByPlayer[player]
	return tombstone ~= nil
		and tombstoneCapabilityCurrentError(tombstone) == nil
		and tombstone.data.entityType == "Invisible"
		and tombstone.data.visible == false
		and committedEntriesByPlayer[player] == nil
end

local function getCurrentTombstoneCapability(tombstoneValue: unknown): (TombstoneCapability?, string?)
	if type(tombstoneValue) ~= "table" then
		return nil, "invalid-respawn-copy-tombstone"
	end
	local tombstone = tombstoneCapabilities[tombstoneValue :: RespawnCopyTombstone]
	if
		not tombstone
		or not tombstone.current
		or tombstone.consumed
		or committedTombstonesByPlayer[tombstone.player] ~= tombstone
		or tombstone.handle ~= tombstoneValue
	then
		return nil, "stale-or-unknown-respawn-copy-tombstone"
	end
	if tombstoneCapabilityCurrentError(tombstone) then
		return nil, "stale-or-unknown-respawn-copy-tombstone"
	end
	return tombstone, nil
end

-- The opaque handle never exposes a mutable owner/root. Consumers receive the
-- exact frozen data record only; it is intentionally insufficient to fabricate
-- BodyQueueRules.CopySource until Movement contributes its three missing fields.
function CorpseService.InspectRespawnCopyTombstone(tombstoneValue: unknown): (RespawnCopyTombstoneData?, string?)
	local tombstone, tombstoneError = getCurrentTombstoneCapability(tombstoneValue)
	if not tombstone then
		return nil, tombstoneError
	end
	local dataError = validateTombstoneData(tombstone.data, tombstone.player)
	if dataError then
		return nil, dataError
	end
	return tombstone.data, nil
end

local function validateTombstoneLineageRequest(value: unknown, data: RespawnCopyTombstoneData): string?
	if type(value) ~= "table" then
		return "respawn-copy-tombstone-lineage-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, TOMBSTONE_LINEAGE_KEYS, 7) then
		return "invalid-respawn-copy-tombstone-lineage-shape"
	end
	if
		raw.matchId ~= data.matchId
		or raw.matchLineage ~= data.matchLineage
		or raw.playerBodyId ~= data.playerBodyId
		or raw.playerSourceOrder ~= data.playerSourceOrder
		or raw.playerLeaseGeneration ~= data.playerLeaseGeneration
		or raw.playerUserId ~= data.playerUserId
		or raw.lifeSequence ~= data.lifeSequence
	then
		return "stale-respawn-copy-tombstone-lineage"
	end
	return nil
end

local function preparedTombstoneConsumeCurrentError(
	preparedValue: unknown,
	capability: TombstoneConsumeCapability
): string?
	local tombstone = capability.tombstone
	if
		capability.status ~= "Prepared"
		or activeTombstoneConsume ~= capability
		or capability.prepared ~= preparedValue
		or capability.baseRevision ~= revision
		or capability.baseEntries ~= committedEntriesByPlayer
		or capability.baseTombstones ~= committedTombstonesByPlayer
		or committedTombstonesByPlayer[tombstone.player] ~= tombstone
		or tombstoneCapabilities[tombstone.handle] ~= tombstone
		or not tombstone.current
		or tombstone.consumed
		or tombstone.data ~= capability.receipt.source
		or tombstone.player.Parent ~= Players
		or capability.receipt.revision ~= revision + 1
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.nextEntries)
		or not table.isfrozen(capability.nextTombstones)
		or not table.isfrozen(capability.receipt)
	then
		return "stale-respawn-copy-tombstone-consume"
	end
	local targetError = tombstoneCapabilityCurrentError(tombstone)
	if targetError then
		return targetError
	end
	local retainedCorpseCount = 0
	for player, entry in capability.nextEntries do
		local binding = entry.binding
		local body = entry.body
		if
			player == tombstone.player
			or capability.baseEntries[player] ~= entry
			or player.Parent ~= Players
			or entry.player ~= player
			or not table.isfrozen(entry)
			or not table.isfrozen(binding)
			or not table.isfrozen(body)
			or binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
			or binding.playerUserId ~= player.UserId
			or binding.bodyId ~= body.id
			or body.size ~= MoverConsequenceRules.ClientCorpseSize
			or body.centerOffset ~= MoverConsequenceRules.ClientCorpseCenterOffset
			or body.contents ~= MoverPushRules.Contents.Corpse
			or body.clipMask ~= MoverPushRules.Masks.PlayerSolid
		then
			return "stale-respawn-copy-tombstone-retained-corpse"
		end
		retainedCorpseCount += 1
	end
	if retainedCorpseCount ~= capability.receipt.committedCorpseCount then
		return "stale-respawn-copy-tombstone-retained-corpse-count"
	end
	local retainedTombstoneCount = 0
	for player, retained in capability.nextTombstones do
		if
			player == tombstone.player
			or capability.baseTombstones[player] ~= retained
			or committedTombstonesByPlayer[player] ~= retained
			or not retained.current
			or retained.consumed
			or tombstoneCapabilities[retained.handle] ~= retained
			or tombstoneCapabilityCurrentError(retained) ~= nil
		then
			return "stale-respawn-copy-tombstone-retained-lineage"
		end
		retainedTombstoneCount += 1
	end
	if retainedTombstoneCount ~= capability.receipt.committedTombstoneCount then
		return "stale-respawn-copy-tombstone-retained-count"
	end
	return nil
end

-- Respawn must remove the immediate client-corpse owner only after every other
-- participant has prepared. This isolated seam prebuilds that root removal and
-- tombstone consumption but is deliberately not wired to avatar callbacks yet.
function CorpseService.PrepareRespawnCopyTombstoneConsume(
	tombstoneValue: unknown,
	lineageValue: unknown
): (PreparedRespawnCopyTombstoneConsume?, string?)
	if activeTransaction then
		return nil, "corpse-transaction-active"
	end
	if activeTombstoneConsume then
		return nil, "corpse-tombstone-consume-active"
	end
	if revision >= MAXIMUM_GENERATION then
		return nil, "corpse-revision-exhausted"
	end
	local tombstone, tombstoneError = getCurrentTombstoneCapability(tombstoneValue)
	if not tombstone then
		return nil, tombstoneError
	end
	local lineageError = validateTombstoneLineageRequest(lineageValue, tombstone.data)
	if lineageError then
		return nil, lineageError
	end
	local player = tombstone.player
	local registration = EntitySlotService.GetPlayerRegistration(player)
	if
		not registration
		or registration.bodyId ~= tombstone.data.playerBodyId
		or registration.sourceOrder ~= tombstone.data.playerSourceOrder
		or registration.generation ~= tombstone.data.playerLeaseGeneration
	then
		return nil, "respawn-copy-tombstone-player-lease-mismatch"
	end
	local currentEntry = committedEntriesByPlayer[player]
	if currentEntry then
		if
			currentEntry.player ~= player
			or currentEntry.binding.kind ~= MoverConsequenceRules.BindingKinds.ClientCorpse
			or currentEntry.binding.playerUserId ~= tombstone.data.playerUserId
			or currentEntry.binding.lifeSequence ~= tombstone.data.lifeSequence
			or currentEntry.body.id ~= tombstone.data.playerBodyId
			or currentEntry.body.sourceOrder ~= tombstone.data.playerSourceOrder
		then
			return nil, "respawn-copy-tombstone-corpse-lineage-mismatch"
		end
	end
	local nextEntries: { [Player]: Entry } = {}
	local committedCorpseCount = 0
	for committedPlayer, entry in committedEntriesByPlayer do
		if committedPlayer ~= player then
			nextEntries[committedPlayer] = entry
			committedCorpseCount += 1
		end
	end
	local nextTombstones: { [Player]: TombstoneCapability } = {}
	local committedTombstoneCount = 0
	for committedPlayer, committedTombstone in committedTombstonesByPlayer do
		if committedPlayer ~= player then
			nextTombstones[committedPlayer] = committedTombstone
			committedTombstoneCount += 1
		end
	end
	table.freeze(nextEntries)
	table.freeze(nextTombstones)
	local receipt: RespawnCopyTombstoneConsumeReceipt = {
		revision = revision + 1,
		committedCorpseCount = committedCorpseCount,
		committedTombstoneCount = committedTombstoneCount,
		source = tombstone.data,
	}
	table.freeze(receipt)
	local prepared: PreparedRespawnCopyTombstoneConsume = table.freeze({})
	local capability: TombstoneConsumeCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		tombstone = tombstone,
		baseRevision = revision,
		baseEntries = committedEntriesByPlayer,
		baseTombstones = committedTombstonesByPlayer,
		nextEntries = nextEntries,
		nextTombstones = nextTombstones,
		receipt = receipt,
	}
	preparedTombstoneConsumeCapabilities[prepared] = capability
	activeTombstoneConsume = capability
	return prepared, nil
end

-- BodyQueue must prepare from this exact frozen source, not from an earlier
-- tombstone inspection that shares only match/player/life scalar lineage.
function CorpseService.InspectPreparedRespawnCopyTombstoneConsumeSource(
	preparedValue: unknown
): RespawnCopyTombstoneData?
	if type(preparedValue) ~= "table" then
		return nil
	end
	local capability = preparedTombstoneConsumeCapabilities[preparedValue :: PreparedRespawnCopyTombstoneConsume]
	if not capability or preparedTombstoneConsumeCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.receipt.source
end

function CorpseService.ValidatePreparedRespawnCopyTombstoneConsumeDependency(
	preparedValue: unknown,
	sourceValue: unknown
): (boolean, string?)
	local source = CorpseService.InspectPreparedRespawnCopyTombstoneConsumeSource(preparedValue)
	if not source then
		return false, "invalid-prepared-respawn-copy-tombstone-dependency"
	end
	if source ~= sourceValue then
		return false, "forged-prepared-respawn-copy-tombstone-source"
	end
	return true, nil
end

function CorpseService.CanApplyPreparedRespawnCopyTombstoneConsume(preparedValue: unknown): (boolean, string?)
	if type(preparedValue) ~= "table" then
		return false, "invalid-prepared-respawn-copy-tombstone-consume"
	end
	local capability = preparedTombstoneConsumeCapabilities[preparedValue :: PreparedRespawnCopyTombstoneConsume]
	if not capability then
		return false, "invalid-prepared-respawn-copy-tombstone-consume"
	end
	capability.applyValidated = false
	local currentError = preparedTombstoneConsumeCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

function CorpseService.ApplyPreparedRespawnCopyTombstoneConsume(
	preparedValue: unknown
): RespawnCopyTombstoneConsumeReceipt
	assert(type(preparedValue) == "table", "invalid-prepared-respawn-copy-tombstone-consume")
	local prepared = preparedValue :: PreparedRespawnCopyTombstoneConsume
	local capability = preparedTombstoneConsumeCapabilities[prepared]
	assert(capability, "invalid-prepared-respawn-copy-tombstone-consume")
	assert(capability.applyValidated, "prepared-respawn-copy-tombstone-consume-not-validated")
	local currentError = preparedTombstoneConsumeCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-respawn-copy-tombstone-consume")

	local tombstone = capability.tombstone
	committedEntriesByPlayer = capability.nextEntries
	committedTombstonesByPlayer = capability.nextTombstones
	revision = capability.receipt.revision
	tombstone.current = false
	tombstone.consumed = true
	capability.status = "Applied"
	capability.applyValidated = false
	activeTombstoneConsume = nil
	preparedTombstoneConsumeCapabilities[prepared] = nil
	return capability.receipt
end

function CorpseService.AbortPreparedRespawnCopyTombstoneConsume(preparedValue: unknown): boolean
	if type(preparedValue) ~= "table" then
		return false
	end
	local prepared = preparedValue :: PreparedRespawnCopyTombstoneConsume
	local capability = preparedTombstoneConsumeCapabilities[prepared]
	if not capability or capability.status ~= "Prepared" or activeTombstoneConsume ~= capability then
		return false
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	activeTombstoneConsume = nil
	preparedTombstoneConsumeCapabilities[prepared] = nil
	return true
end

local function clearPlayerAuthority(player: Player, allowCurrentTombstone: boolean): boolean
	if activeTransaction or activeTombstoneConsume then
		return false
	end
	local tombstone = committedTombstonesByPlayer[player]
	if tombstone and not allowCurrentTombstone then
		return false
	end
	if not committedEntriesByPlayer[player] and not tombstone then
		return true
	end
	local nextEntries: { [Player]: Entry } = {}
	for committedPlayer, entry in committedEntriesByPlayer do
		if committedPlayer ~= player then
			nextEntries[committedPlayer] = entry
		end
	end
	table.freeze(nextEntries)
	local nextTombstones: { [Player]: TombstoneCapability } = {}
	for committedPlayer, committedTombstone in committedTombstonesByPlayer do
		if committedPlayer ~= player then
			nextTombstones[committedPlayer] = committedTombstone
		end
	end
	table.freeze(nextTombstones)
	if tombstone then
		tombstone.current = false
		tombstone.consumed = true
	end
	committedEntriesByPlayer = nextEntries
	committedTombstonesByPlayer = nextTombstones
	revision += 1
	return true
end

-- CharacterAdded and same-character respawn may clear only legacy immediate
-- corpse state. Once a CopyToBodyQue tombstone exists, raw clearing must fail
-- closed until the prepared respawn consume is composed.
function CorpseService.ClearPlayer(playerValue: unknown): boolean
	if not isPlayer(playerValue) then
		return false
	end
	return clearPlayerAuthority(playerValue :: Player, false)
end

-- Disconnect is not a respawn and has no future body copy. Combat's deliberately
-- scoped PlayerRemoving path may retire both roots as departure cleanup.
function CorpseService.ClaimDepartureCleanupOwner(): (DepartureCleanupOwner?, string?)
	if departureCleanupOwner then
		return nil, "corpse-departure-cleanup-owner-already-claimed"
	end
	local owner: DepartureCleanupOwner = table.freeze({})
	departureCleanupOwner = owner
	return owner, nil
end

function CorpseService.ClearDepartingPlayer(playerValue: unknown, ownerValue: unknown): boolean
	if not isPlayer(playerValue) or type(ownerValue) ~= "table" or ownerValue ~= departureCleanupOwner then
		return false
	end
	return clearPlayerAuthority(playerValue :: Player, true)
end

-- A map/mode restart discards client corpse entities instead of carrying their
-- old Match lineage into the new G_RunFrame. Combat owns this narrow transition
-- capability and supplies the exact previous Match ID after Match publishes the
-- replacement identity but before it requests any new client bodies.
function CorpseService.ClaimMatchTransitionCleanupOwner(): (MatchTransitionCleanupOwner?, string?)
	if matchTransitionCleanupOwner then
		return nil, "corpse-match-transition-cleanup-owner-already-claimed"
	end
	local owner: MatchTransitionCleanupOwner = table.freeze({})
	matchTransitionCleanupOwner = owner
	return owner, nil
end

function CorpseService.ClearPlayerForMatchTransition(
	playerValue: unknown,
	ownerValue: unknown,
	previousMatchIdValue: unknown
): boolean
	if
		not isPlayer(playerValue)
		or type(ownerValue) ~= "table"
		or ownerValue ~= matchTransitionCleanupOwner
		or type(previousMatchIdValue) ~= "string"
		or previousMatchIdValue == ""
	then
		return false
	end
	local player = playerValue :: Player
	local tombstone = committedTombstonesByPlayer[player]
	if tombstone and tombstone.data.matchId ~= previousMatchIdValue then
		return false
	end
	return clearPlayerAuthority(player, true)
end

function CorpseService.ClearStaleMatchAuthority(
	ownerValue: unknown,
	currentMatchIdValue: unknown
): ({ Player }?, string?)
	if
		type(ownerValue) ~= "table"
		or ownerValue ~= matchTransitionCleanupOwner
		or type(currentMatchIdValue) ~= "string"
		or currentMatchIdValue == ""
	then
		return nil, "invalid-corpse-stale-Match-cleanup"
	end
	if activeTransaction or activeTombstoneConsume then
		return nil, "corpse-owner-active-during-stale-Match-cleanup"
	end
	local stalePlayers: { Player } = {}
	for player, tombstone in committedTombstonesByPlayer do
		if tombstone.data.matchId ~= currentMatchIdValue then
			table.insert(stalePlayers, player)
		end
	end
	table.sort(stalePlayers, function(left: Player, right: Player): boolean
		local leftRegistration = EntitySlotService.GetPlayerRegistration(left)
		local rightRegistration = EntitySlotService.GetPlayerRegistration(right)
		return assert(leftRegistration, "stale corpse player registration disappeared").sourceOrder
			< assert(rightRegistration, "stale corpse player registration disappeared").sourceOrder
	end)
	for _, player in stalePlayers do
		assert(clearPlayerAuthority(player, true), "stale Match corpse cleanup failed")
	end
	table.freeze(stalePlayers)
	return stalePlayers, nil
end

function CorpseService.GetDebugSnapshot(): DebugSnapshot
	local committedCount = 0
	for _ in committedEntriesByPlayer do
		committedCount += 1
	end
	local committedTombstoneCount = 0
	for _ in committedTombstonesByPlayer do
		committedTombstoneCount += 1
	end
	local transaction = activeTransaction
	local transactionCount = 0
	local transactionTombstoneCount = 0
	if transaction then
		for _ in transaction.entriesByPlayer do
			transactionCount += 1
		end
		for _ in transaction.tombstoneDraftsByPlayer do
			transactionTombstoneCount += 1
		end
	end
	local preparedCapability = if transaction and transaction.prepared
		then preparedCapabilities[transaction.prepared]
		else nil
	local snapshot: DebugSnapshot = {
		revision = revision,
		committedCorpseCount = committedCount,
		transactionActive = transaction ~= nil,
		transactionStatus = if transaction then transaction.status else nil,
		transactionCorpseCount = transactionCount,
		transactionFinalBodiesApplied = if transaction then transaction.finalBodiesApplied else false,
		transactionApplyValidated = if preparedCapability then preparedCapability.applyValidated else false,
		transactionPreparedRevision = if preparedCapability then preparedCapability.receipt.revision else nil,
		committedTombstoneCount = committedTombstoneCount,
		transactionTombstoneCount = transactionTombstoneCount,
		tombstoneConsumeActive = activeTombstoneConsume ~= nil,
		tombstoneConsumeApplyValidated = if activeTombstoneConsume
			then activeTombstoneConsume.applyValidated
			else false,
	}
	table.freeze(snapshot)
	return snapshot
end

return table.freeze(CorpseService)
