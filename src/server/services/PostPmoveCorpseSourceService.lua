--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only post-Pmove CopyToBodyQue source owner translated from:
  code/game/g_active.c (ClientThink_real post-Pmove entity-state conversion,
  respawn gate ordering, and current player-state velocity)
  code/game/bg_misc.c (BG_PlayerStateToEntityState snapped trBase, trDelta,
  and groundEntityNum)
  code/game/g_client.c (CopyToBodyQue CONTENTS_NODROP sample and grounded versus
  airborne trajectory selection)

Q3 refreshes s.pos.trBase after Pmove but CopyToBodyQue samples the unrelated
generic s.origin field. For player entities that field is not refreshed by
BG_PlayerStateToEntityState. This narrow compatibility repair retains the
post-Pmove snapped trajectory base and uses that exact position for the later
no-drop sample and body-copy trajectory. Collision/body lineage still comes
from CorpseService's exact prepared tombstone source.

This isolated owner is live. Movement captures immediately after stepDead; the
respawn composite prepares the exact Corpse tombstone consume and calls
PrepareRespawnGate before any end-frame entity trajectory refresh. This module
never reads MovementService's GetPlayerEntityTrajectoryDiagnostic.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "PostPmoveCorpseSourceService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local simulation = sharedRoot:WaitForChild("simulation")
local BodyQueueRules = require(simulation:WaitForChild("BodyQueueRules"))
local CommandSequence = require(simulation:WaitForChild("CommandSequence"))
local EntityStateConversionRules = require(simulation:WaitForChild("EntityStateConversionRules"))
local Movement = require(simulation:WaitForChild("Movement"))
local MoverClock = require(simulation:WaitForChild("MoverClock"))
local MoverPushRules = require(simulation:WaitForChild("MoverPushRules"))
local WorldPointContents = require(simulation:WaitForChild("WorldPointContents"))
local CorpseService = require(script.Parent.CorpseService)
local EntitySlotService = require(script.Parent.EntitySlotService)

local PostPmoveCorpseSourceService = {}

export type PostPmoveCapture = {}
export type PreparedRespawnSource = {}

export type GroundState = BodyQueueRules.GroundState
export type CommandLineage = {
	read movementRevision: number,
	read commandSequence: number,
}
export type PostPmoveCaptureSummary = {
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read playerUserId: number,
	read lifeSequence: number,
	read commandLineage: CommandLineage,
	read moverClockRevision: number,
	read moverClockStep: number,
	read moverTimeMilliseconds: number,
	read snappedTrajectoryBase: Vector3,
	read entityTrajectoryDelta: Vector3,
	read groundState: GroundState,
	read groundMoverId: string?,
}
export type PreparedRespawnSourceData = {
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read playerUserId: number,
	read lifeSequence: number,
	read commandLineage: CommandLineage,
	read moverClockRevision: number,
	read moverClockStep: number,
	read moverTimeMilliseconds: number,
	read snappedTrajectoryBase: Vector3,
	read entityTrajectoryDelta: Vector3,
	read groundState: GroundState,
	read groundMoverId: string?,
	read playerStateVelocity: Vector3,
	read sampledPointContents: number,
	read noDrop: boolean,
	read corpseTombstoneSource: CorpseService.RespawnCopyTombstoneData,
	read copySource: BodyQueueRules.CopySource?,
}
export type CommitReceipt = {
	read outcome: "Committed",
	read source: PreparedRespawnSourceData,
}
export type AbortReceipt = {
	read outcome: "Aborted",
	read commandLineage: CommandLineage,
	read moverTimeMilliseconds: number,
}

type PostPmoveCaptureStatus = "Current" | "Consumed" | "Replaced" | "Discarded"
type PostPmoveCaptureCapability = {
	handle: PostPmoveCapture,
	status: PostPmoveCaptureStatus,
	player: Player,
	registration: EntitySlotService.Registration,
	summary: PostPmoveCaptureSummary,
}
type PreparedRespawnStatus = "Prepared" | "Applied" | "Aborted"
type PreparedRespawnCapability = {
	prepared: PreparedRespawnSource,
	status: PreparedRespawnStatus,
	applyValidated: boolean,
	player: Player,
	registration: EntitySlotService.Registration,
	capture: PostPmoveCapture,
	captureCapability: PostPmoveCaptureCapability,
	corpsePrepared: CorpseService.PreparedRespawnCopyTombstoneConsume,
	corpseSource: CorpseService.RespawnCopyTombstoneData,
	source: PreparedRespawnSourceData,
	commitReceipt: CommitReceipt,
	abortReceipt: AbortReceipt,
}

local MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991
local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_VELOCITY = 100_000
local KNOWN_POINT_CONTENTS_MASK = bit32.bor(
	WorldPointContents.Contents.Solid,
	WorldPointContents.Contents.Lava,
	WorldPointContents.Contents.Slime,
	WorldPointContents.Contents.Water,
	WorldPointContents.Contents.NoDrop
)

local CAPTURE_REQUEST_KEYS = table.freeze({
	movementRevision = true,
	commandSequence = true,
	moverClockRevision = true,
	moverClockStep = true,
	moverTimeMilliseconds = true,
	position = true,
	entityTrajectoryDelta = true,
	grounded = true,
	groundMoverId = true,
	lifeSequence = true,
})

local capturesByHandle = setmetatable({}, { __mode = "k" }) :: {
	[PostPmoveCapture]: PostPmoveCaptureCapability,
}
local capturesBySummary = setmetatable({}, { __mode = "k" }) :: {
	[PostPmoveCaptureSummary]: PostPmoveCapture,
}
local currentCaptureByPlayer = setmetatable({}, { __mode = "k" }) :: {
	[Player]: PostPmoveCaptureCapability,
}
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedRespawnSource]: PreparedRespawnCapability,
}
local preparedSources = setmetatable({}, { __mode = "k" }) :: {
	[PreparedRespawnSourceData]: PreparedRespawnSource,
}
local activePreparedByPlayer = setmetatable({}, { __mode = "k" }) :: {
	[Player]: PreparedRespawnCapability,
}
local preparingByPlayer = setmetatable({}, { __mode = "k" }) :: {
	[Player]: boolean,
}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
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

local function snapTrajectoryBase(position: Vector3): Vector3
	return assert(
		EntityStateConversionRules.SnapTrajectoryBase(position),
		"validated post-Pmove position did not convert to entity state"
	)
end

local function validPointContents(value: unknown): boolean
	return isInteger(value, 0, 4_294_967_295) and value == bit32.band(value :: number, KNOWN_POINT_CONTENTS_MASK)
end

local function captureCurrentError(capability: PostPmoveCaptureCapability): string?
	local summary = capability.summary
	local registration = EntitySlotService.GetPlayerRegistration(capability.player)
	if
		capability.status ~= "Current"
		or capturesByHandle[capability.handle] ~= capability
		or capturesBySummary[summary] ~= capability.handle
		or currentCaptureByPlayer[capability.player] ~= capability
	then
		return "stale-post-pmove-corpse-capture-ownership"
	end
	if
		capability.player.Parent ~= Players
		or capability.player.UserId ~= summary.playerUserId
		or registration ~= capability.registration
		or registration.bodyId ~= summary.playerBodyId
		or registration.sourceOrder ~= summary.playerSourceOrder
		or registration.generation ~= summary.playerLeaseGeneration
	then
		return "stale-post-pmove-corpse-capture-player-lease"
	end
	if
		not isInteger(summary.lifeSequence, 1, 2_147_483_647)
		or not table.isfrozen(summary.commandLineage)
		or not isInteger(summary.commandLineage.movementRevision, 1, MAXIMUM_SAFE_INTEGER)
		or not isInteger(summary.commandLineage.commandSequence, -1, CommandSequence.Maximum)
		or not isInteger(summary.moverClockRevision, 1, MoverClock.MaximumRevision)
		or not isInteger(summary.moverClockStep, 0, MoverClock.MaximumStep)
		or MoverClock.TimeForStep(summary.moverClockStep) ~= summary.moverTimeMilliseconds
	then
		return "stale-post-pmove-corpse-capture-command-clock"
	end
	if not table.isfrozen(capability.handle) or not table.isfrozen(summary) then
		return "stale-post-pmove-corpse-capture-immutability"
	end
	if
		not isBoundedVector(summary.snappedTrajectoryBase, MAXIMUM_COORDINATE)
		or not EntityStateConversionRules.IsSnappedTrajectoryBase(summary.snappedTrajectoryBase)
	then
		return "stale-post-pmove-corpse-capture-trajectory-base"
	end
	if not isBoundedVector(summary.entityTrajectoryDelta, MAXIMUM_VELOCITY) then
		return "stale-post-pmove-corpse-capture-trajectory-delta"
	end
	if
		(summary.groundState ~= "Grounded" and summary.groundState ~= "Airborne")
		or (summary.groundMoverId ~= nil and Movement.ValidateMoverId(summary.groundMoverId) == nil)
		or (summary.groundState == "Airborne" and summary.groundMoverId ~= nil)
	then
		return "stale-post-pmove-corpse-capture-ground"
	end
	if
		capability.status ~= "Current"
		or capturesByHandle[capability.handle] ~= capability
		or capturesBySummary[summary] ~= capability.handle
		or currentCaptureByPlayer[capability.player] ~= capability
		or capability.player.Parent ~= Players
		or capability.player.UserId ~= summary.playerUserId
		or not isInteger(summary.lifeSequence, 1, 2_147_483_647)
		or registration ~= capability.registration
		or registration.bodyId ~= summary.playerBodyId
		or registration.sourceOrder ~= summary.playerSourceOrder
		or registration.generation ~= summary.playerLeaseGeneration
		or not table.isfrozen(capability.handle)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.commandLineage)
		or not isInteger(summary.commandLineage.movementRevision, 1, MAXIMUM_SAFE_INTEGER)
		or not isInteger(summary.commandLineage.commandSequence, -1, CommandSequence.Maximum)
		or not isInteger(summary.moverClockRevision, 1, MoverClock.MaximumRevision)
		or not isInteger(summary.moverClockStep, 0, MoverClock.MaximumStep)
		or MoverClock.TimeForStep(summary.moverClockStep) ~= summary.moverTimeMilliseconds
		or not isBoundedVector(summary.snappedTrajectoryBase, MAXIMUM_COORDINATE)
		or not EntityStateConversionRules.IsSnappedTrajectoryBase(summary.snappedTrajectoryBase)
		or not isBoundedVector(summary.entityTrajectoryDelta, MAXIMUM_VELOCITY)
		or (summary.groundState ~= "Grounded" and summary.groundState ~= "Airborne")
		or (summary.groundMoverId ~= nil and Movement.ValidateMoverId(summary.groundMoverId) == nil)
		or (summary.groundState == "Airborne" and summary.groundMoverId ~= nil)
	then
		return "stale-post-pmove-corpse-capture"
	end
	return nil
end

local function getCaptureCapability(captureValue: unknown): (PostPmoveCaptureCapability?, string?)
	if type(captureValue) ~= "table" then
		return nil, "invalid-post-pmove-corpse-capture"
	end
	local capability = capturesByHandle[captureValue :: PostPmoveCapture]
	if not capability or capability.handle ~= captureValue then
		return nil, "invalid-post-pmove-corpse-capture"
	end
	local currentError = captureCurrentError(capability)
	if currentError then
		return nil, currentError
	end
	return capability, nil
end

local function translatedCopyBody(
	corpseBody: MoverPushRules.Body,
	capture: PostPmoveCaptureSummary
): (MoverPushRules.Body?, string?)
	-- The raw corpse origin and converted entity-state base must occupy the exact
	-- same SnapVector cell. A distance-only check is insufficient near a cell
	-- boundary: two origins can be less than one source unit apart but truncate
	-- to adjacent entity-state bases.
	if snapTrajectoryBase(corpseBody.position) ~= capture.snappedTrajectoryBase then
		return nil, "post-pmove-corpse-body-position-mismatch"
	end
	if corpseBody.groundMoverId ~= capture.groundMoverId then
		return nil, "post-pmove-corpse-ground-mover-mismatch"
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies({
		{
			id = corpseBody.id,
			sourceOrder = corpseBody.sourceOrder,
			position = capture.snappedTrajectoryBase,
			size = corpseBody.size,
			centerOffset = corpseBody.centerOffset,
			velocity = capture.entityTrajectoryDelta,
			groundMoverId = capture.groundMoverId,
			contents = corpseBody.contents,
			clipMask = corpseBody.clipMask,
		},
	})
	if not bodies then
		return nil, bodyError or "invalid-post-pmove-copy-body"
	end
	return bodies[1], nil
end

local function buildCopySource(
	corpseSource: CorpseService.RespawnCopyTombstoneData,
	capture: PostPmoveCaptureSummary,
	playerStateVelocity: Vector3
): (BodyQueueRules.CopySource?, string?)
	local body, bodyError = translatedCopyBody(corpseSource.body, capture)
	if not body then
		return nil, bodyError
	end
	local source: BodyQueueRules.CopySource = {
		matchLineage = corpseSource.matchLineage,
		playerBodyId = corpseSource.playerBodyId,
		playerSourceOrder = corpseSource.playerSourceOrder,
		playerLeaseGeneration = corpseSource.playerLeaseGeneration,
		playerUserId = corpseSource.playerUserId,
		lifeSequence = corpseSource.lifeSequence,
		body = body,
		sourceLinked = corpseSource.sourceLinked,
		entityType = corpseSource.entityType,
		visible = corpseSource.visible,
		groundState = capture.groundState,
		entityTrajectoryDelta = capture.entityTrajectoryDelta,
		playerStateVelocity = playerStateVelocity,
		sourceHealth = corpseSource.sourceHealth,
	}
	table.freeze(source)
	return source, nil
end

local function normalCopySourceCurrentError(
	source: PreparedRespawnSourceData,
	summary: PostPmoveCaptureSummary,
	corpseSource: CorpseService.RespawnCopyTombstoneData
): string?
	local copySource = source.copySource
	if copySource == nil then
		return "stale-prepared-post-pmove-corpse-source"
	end
	local body = copySource.body
	if
		not table.isfrozen(copySource)
		or not table.isfrozen(body)
		or copySource.matchLineage ~= corpseSource.matchLineage
		or copySource.playerBodyId ~= summary.playerBodyId
		or copySource.playerSourceOrder ~= summary.playerSourceOrder
		or copySource.playerLeaseGeneration ~= summary.playerLeaseGeneration
		or copySource.playerUserId ~= summary.playerUserId
		or copySource.lifeSequence ~= summary.lifeSequence
		or copySource.sourceLinked ~= corpseSource.sourceLinked
		or copySource.entityType ~= corpseSource.entityType
		or copySource.visible ~= corpseSource.visible
		or copySource.groundState ~= summary.groundState
		or copySource.entityTrajectoryDelta ~= summary.entityTrajectoryDelta
		or copySource.playerStateVelocity ~= source.playerStateVelocity
		or copySource.sourceHealth ~= corpseSource.sourceHealth
		or body.id ~= corpseSource.body.id
		or body.sourceOrder ~= corpseSource.body.sourceOrder
		or body.position ~= summary.snappedTrajectoryBase
		or body.size ~= corpseSource.body.size
		or body.centerOffset ~= corpseSource.body.centerOffset
		or body.velocity ~= summary.entityTrajectoryDelta
		or body.groundMoverId ~= summary.groundMoverId
		or body.contents ~= corpseSource.body.contents
		or body.clipMask ~= corpseSource.body.clipMask
		or snapTrajectoryBase(corpseSource.body.position) ~= summary.snappedTrajectoryBase
	then
		return "stale-prepared-post-pmove-corpse-source"
	end
	return nil
end

local function preparedCurrentError(preparedValue: unknown, capability: PreparedRespawnCapability): string?
	local captureError = captureCurrentError(capability.captureCapability)
	if captureError then
		return captureError
	end
	local registration = EntitySlotService.GetPlayerRegistration(capability.player)
	local source = capability.source
	local summary = capability.captureCapability.summary
	if
		capability.status ~= "Prepared"
		or capability.prepared ~= preparedValue
		or preparedCapabilities[capability.prepared] ~= capability
		or preparedSources[source] ~= capability.prepared
		or activePreparedByPlayer[capability.player] ~= capability
		or capability.player.Parent ~= Players
		or registration ~= capability.registration
		or registration.bodyId ~= source.playerBodyId
		or registration.sourceOrder ~= source.playerSourceOrder
		or registration.generation ~= source.playerLeaseGeneration
		or capability.player.UserId ~= source.playerUserId
		or source.lifeSequence ~= summary.lifeSequence
		or capability.captureCapability.handle ~= capability.capture
		or not table.isfrozen(capability.prepared)
		or not table.isfrozen(source)
		or not table.isfrozen(capability.commitReceipt)
		or not table.isfrozen(capability.abortReceipt)
		or capability.commitReceipt.source ~= source
		or capability.commitReceipt.outcome ~= "Committed"
		or capability.abortReceipt.outcome ~= "Aborted"
		or source.commandLineage ~= summary.commandLineage
		or source.moverClockRevision ~= summary.moverClockRevision
		or source.moverClockStep ~= summary.moverClockStep
		or source.moverTimeMilliseconds ~= summary.moverTimeMilliseconds
		or source.snappedTrajectoryBase ~= summary.snappedTrajectoryBase
		or source.entityTrajectoryDelta ~= summary.entityTrajectoryDelta
		or source.groundState ~= summary.groundState
		or source.groundMoverId ~= summary.groundMoverId
		or not isBoundedVector(source.playerStateVelocity, MAXIMUM_VELOCITY)
		or source.corpseTombstoneSource ~= capability.corpseSource
		or not validPointContents(source.sampledPointContents)
		or source.noDrop ~= WorldPointContents.IsNoDrop(source.sampledPointContents)
		or (source.noDrop and source.copySource ~= nil)
		or (not source.noDrop and source.copySource == nil)
	then
		return "stale-prepared-post-pmove-corpse-source"
	end
	if not source.noDrop then
		local copySourceError = normalCopySourceCurrentError(source, summary, capability.corpseSource)
		if copySourceError then
			return copySourceError
		end
	end
	local validCorpseDependency = CorpseService.ValidatePreparedRespawnCopyTombstoneConsumeDependency(
		capability.corpsePrepared,
		capability.corpseSource
	)
	if not validCorpseDependency then
		return "stale-prepared-post-pmove-corpse-dependency"
	end
	if
		CorpseService.InspectPreparedRespawnCopyTombstoneConsumeSource(capability.corpsePrepared)
		~= capability.corpseSource
	then
		return "stale-prepared-post-pmove-corpse-dependency"
	end
	return nil
end

local function getPreparedCapability(preparedValue: unknown): (PreparedRespawnCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-prepared-post-pmove-corpse-source"
	end
	local capability = preparedCapabilities[preparedValue :: PreparedRespawnSource]
	if not capability or capability.prepared ~= preparedValue then
		return nil, "invalid-prepared-post-pmove-corpse-source"
	end
	return capability, nil
end

-- This is the live hook immediately after Movement.stepDead and before the
-- event/trigger/respawn gates. It snapshots BG_PlayerStateToEntityState's
-- position, delta, and ground classification rather than an end-frame view.
function PostPmoveCorpseSourceService.CapturePostPmove(
	playerValue: unknown,
	requestValue: unknown
): (PostPmoveCapture?, PostPmoveCaptureSummary?, string?)
	if typeof(playerValue) ~= "Instance" or not (playerValue :: Instance):IsA("Player") then
		return nil, nil, "invalid-post-pmove-corpse-player"
	end
	local player = playerValue :: Player
	if player.Parent ~= Players then
		return nil, nil, "stale-post-pmove-corpse-player"
	end
	if activePreparedByPlayer[player] ~= nil or preparingByPlayer[player] == true then
		return nil, nil, "post-pmove-corpse-source-prepare-active"
	end
	if type(requestValue) ~= "table" then
		return nil, nil, "post-pmove-corpse-capture-request-not-table"
	end
	local raw = requestValue :: { [unknown]: unknown }
	if
		not hasExactKeys(raw, CAPTURE_REQUEST_KEYS, if raw.groundMoverId == nil then 9 else 10)
		or not isInteger(raw.movementRevision, 1, MAXIMUM_SAFE_INTEGER)
		or not isInteger(raw.commandSequence, -1, CommandSequence.Maximum)
		or not isInteger(raw.lifeSequence, 1, 2_147_483_647)
		or not isInteger(raw.moverClockRevision, 1, MoverClock.MaximumRevision)
		or not isInteger(raw.moverClockStep, 0, MoverClock.MaximumStep)
		or MoverClock.TimeForStep(raw.moverClockStep) ~= raw.moverTimeMilliseconds
		or not isInteger(raw.moverTimeMilliseconds, 0, MAXIMUM_TIME_MILLISECONDS)
		or not isBoundedVector(raw.position, MAXIMUM_COORDINATE)
		or not isBoundedVector(raw.entityTrajectoryDelta, MAXIMUM_VELOCITY)
		or type(raw.grounded) ~= "boolean"
		or (raw.groundMoverId ~= nil and Movement.ValidateMoverId(raw.groundMoverId) == nil)
		or (raw.grounded == false and raw.groundMoverId ~= nil)
	then
		return nil, nil, "invalid-post-pmove-corpse-capture-request"
	end
	local registration = EntitySlotService.GetPlayerRegistration(player)
	if not registration then
		return nil, nil, "post-pmove-corpse-player-registration-unavailable"
	end
	local previous = currentCaptureByPlayer[player]
	if previous then
		local previousError = captureCurrentError(previous)
		if previousError then
			return nil, nil, previousError
		end
		local previousSummary = previous.summary
		if
			(raw.lifeSequence :: number) < previousSummary.lifeSequence
			or (raw.lifeSequence == previousSummary.lifeSequence and (raw.movementRevision :: number) < previousSummary.commandLineage.movementRevision)
			or (raw.lifeSequence == previousSummary.lifeSequence and raw.movementRevision == previousSummary.commandLineage.movementRevision and previousSummary.commandLineage.commandSequence ~= -1 and (raw.commandSequence == -1 or (raw.commandSequence ~= previousSummary.commandLineage.commandSequence and not CommandSequence.IsNewer(
				raw.commandSequence,
				previousSummary.commandLineage.commandSequence
			))))
			or (raw.moverClockRevision :: number) < previousSummary.moverClockRevision
			or (
				raw.moverClockRevision == previousSummary.moverClockRevision
				and (raw.moverClockStep :: number) <= previousSummary.moverClockStep
			)
		then
			return nil, nil, "post-pmove-corpse-capture-lineage-not-newer"
		end
		previous.status = "Replaced"
		capturesByHandle[previous.handle] = nil
		capturesBySummary[previous.summary] = nil
	end
	local commandLineage: CommandLineage = {
		movementRevision = raw.movementRevision :: number,
		commandSequence = raw.commandSequence :: number,
	}
	table.freeze(commandLineage)
	local summary: PostPmoveCaptureSummary = {
		playerBodyId = registration.bodyId,
		playerSourceOrder = registration.sourceOrder,
		playerLeaseGeneration = registration.generation,
		playerUserId = player.UserId,
		lifeSequence = raw.lifeSequence :: number,
		commandLineage = commandLineage,
		moverClockRevision = raw.moverClockRevision :: number,
		moverClockStep = raw.moverClockStep :: number,
		moverTimeMilliseconds = raw.moverTimeMilliseconds :: number,
		snappedTrajectoryBase = snapTrajectoryBase(raw.position :: Vector3),
		entityTrajectoryDelta = raw.entityTrajectoryDelta :: Vector3,
		groundState = if raw.grounded then "Grounded" else "Airborne",
		groundMoverId = raw.groundMoverId :: string?,
	}
	table.freeze(summary)
	local handle: PostPmoveCapture = table.freeze({})
	local capability: PostPmoveCaptureCapability = {
		handle = handle,
		status = "Current",
		player = player,
		registration = registration,
		summary = summary,
	}
	capturesByHandle[handle] = capability
	capturesBySummary[summary] = handle
	currentCaptureByPlayer[player] = capability
	return handle, summary, nil
end

function PostPmoveCorpseSourceService.InspectPostPmoveCaptureSummary(captureValue: unknown): PostPmoveCaptureSummary?
	local capability = select(1, getCaptureCapability(captureValue))
	return if capability then capability.summary else nil
end

function PostPmoveCorpseSourceService.ValidatePostPmoveCaptureDependency(
	captureValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, capabilityError = getCaptureCapability(captureValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or type(summaryValue) ~= "table"
		or capturesBySummary[summaryValue :: PostPmoveCaptureSummary] ~= capability.handle
	then
		return false, "forged-post-pmove-corpse-capture-summary"
	end
	return true, nil
end

function PostPmoveCorpseSourceService.DiscardPostPmoveCapture(captureValue: unknown): boolean
	local capability = select(1, getCaptureCapability(captureValue))
	if
		not capability
		or activePreparedByPlayer[capability.player] ~= nil
		or preparingByPlayer[capability.player] == true
	then
		return false
	end
	capability.status = "Discarded"
	capturesByHandle[capability.handle] = nil
	capturesBySummary[capability.summary] = nil
	currentCaptureByPlayer[capability.player] = nil
	return true
end

-- The point-contents callback is invoked exactly once, here, with no caller-
-- supplied position. CanApply/Apply only verify the frozen sample and never
-- resample. The current player-state velocity is likewise captured at this
-- respawn gate rather than from the later end-frame entity conversion.
function PostPmoveCorpseSourceService.PrepareRespawnGate(
	captureValue: unknown,
	corpsePreparedValue: unknown,
	corpseSourceValue: unknown,
	playerStateVelocityValue: unknown,
	pointContentsValue: unknown
): (PreparedRespawnSource?, PreparedRespawnSourceData?, string?)
	local captureCapability, captureError = getCaptureCapability(captureValue)
	if not captureCapability then
		return nil, nil, captureError
	end
	local player = captureCapability.player
	if activePreparedByPlayer[player] ~= nil or preparingByPlayer[player] == true then
		return nil, nil, "post-pmove-corpse-source-prepare-active"
	end
	if not isBoundedVector(playerStateVelocityValue, MAXIMUM_VELOCITY) then
		return nil, nil, "invalid-post-pmove-player-state-velocity"
	end
	if type(pointContentsValue) ~= "function" then
		return nil, nil, "invalid-post-pmove-point-contents-sampler"
	end
	if type(corpsePreparedValue) ~= "table" or type(corpseSourceValue) ~= "table" then
		return nil, nil, "invalid-post-pmove-corpse-dependency"
	end
	local corpsePrepared = corpsePreparedValue :: CorpseService.PreparedRespawnCopyTombstoneConsume
	local corpseSource = corpseSourceValue :: CorpseService.RespawnCopyTombstoneData
	local validCorpseDependency, corpseDependencyError =
		CorpseService.ValidatePreparedRespawnCopyTombstoneConsumeDependency(corpsePrepared, corpseSource)
	if not validCorpseDependency then
		return nil, nil, corpseDependencyError or "invalid-post-pmove-corpse-dependency"
	end
	local summary = captureCapability.summary
	if
		corpseSource.playerBodyId ~= summary.playerBodyId
		or corpseSource.playerSourceOrder ~= summary.playerSourceOrder
		or corpseSource.playerLeaseGeneration ~= summary.playerLeaseGeneration
		or corpseSource.playerUserId ~= summary.playerUserId
		or corpseSource.lifeSequence ~= summary.lifeSequence
	then
		return nil, nil, "post-pmove-corpse-dependency-lineage-mismatch"
	end
	preparingByPlayer[player] = true
	local function failPreparing(errorMessage: string): (nil, nil, string)
		preparingByPlayer[player] = nil
		return nil, nil, errorMessage
	end
	local sampleSucceeded, sampledValue =
		pcall(pointContentsValue :: (Vector3) -> number, summary.snappedTrajectoryBase)
	if not sampleSucceeded then
		return failPreparing("post-pmove-no-drop-sample-failed")
	end
	local postSampleCaptureError = captureCurrentError(captureCapability)
	if postSampleCaptureError then
		return failPreparing(postSampleCaptureError)
	end
	local postSampleCorpseValid =
		CorpseService.ValidatePreparedRespawnCopyTombstoneConsumeDependency(corpsePrepared, corpseSource)
	if
		not postSampleCorpseValid
		or CorpseService.InspectPreparedRespawnCopyTombstoneConsumeSource(corpsePrepared) ~= corpseSource
	then
		return failPreparing("stale-prepared-post-pmove-corpse-dependency")
	end
	if not validPointContents(sampledValue) then
		return failPreparing("invalid-post-pmove-point-contents-sample")
	end
	local sampledPointContents = sampledValue :: number
	local noDrop = WorldPointContents.IsNoDrop(sampledPointContents)
	local playerStateVelocity = playerStateVelocityValue :: Vector3
	local copySource: BodyQueueRules.CopySource? = nil
	if not noDrop then
		local builtSource, sourceError = buildCopySource(corpseSource, summary, playerStateVelocity)
		if not builtSource then
			return failPreparing(sourceError or "post-pmove-copy-source-build-failed")
		end
		copySource = builtSource
	end
	local source: PreparedRespawnSourceData = {
		playerBodyId = summary.playerBodyId,
		playerSourceOrder = summary.playerSourceOrder,
		playerLeaseGeneration = summary.playerLeaseGeneration,
		playerUserId = summary.playerUserId,
		lifeSequence = summary.lifeSequence,
		commandLineage = summary.commandLineage,
		moverClockRevision = summary.moverClockRevision,
		moverClockStep = summary.moverClockStep,
		moverTimeMilliseconds = summary.moverTimeMilliseconds,
		snappedTrajectoryBase = summary.snappedTrajectoryBase,
		entityTrajectoryDelta = summary.entityTrajectoryDelta,
		groundState = summary.groundState,
		groundMoverId = summary.groundMoverId,
		playerStateVelocity = playerStateVelocity,
		sampledPointContents = sampledPointContents,
		noDrop = noDrop,
		corpseTombstoneSource = corpseSource,
		copySource = copySource,
	}
	table.freeze(source)
	local commitReceipt: CommitReceipt = {
		outcome = "Committed",
		source = source,
	}
	table.freeze(commitReceipt)
	local abortReceipt: AbortReceipt = {
		outcome = "Aborted",
		commandLineage = summary.commandLineage,
		moverTimeMilliseconds = summary.moverTimeMilliseconds,
	}
	table.freeze(abortReceipt)
	local prepared: PreparedRespawnSource = table.freeze({})
	local capability: PreparedRespawnCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		player = player,
		registration = captureCapability.registration,
		capture = captureCapability.handle,
		captureCapability = captureCapability,
		corpsePrepared = corpsePrepared,
		corpseSource = corpseSource,
		source = source,
		commitReceipt = commitReceipt,
		abortReceipt = abortReceipt,
	}
	preparedCapabilities[prepared] = capability
	preparedSources[source] = prepared
	activePreparedByPlayer[player] = capability
	preparingByPlayer[player] = nil
	return prepared, source, nil
end

function PostPmoveCorpseSourceService.InspectPreparedSource(preparedValue: unknown): PreparedRespawnSourceData?
	local capability = select(1, getPreparedCapability(preparedValue))
	if not capability or preparedCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.source
end

function PostPmoveCorpseSourceService.ValidatePreparedSourceDependency(
	preparedValue: unknown,
	sourceValue: unknown
): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.source ~= sourceValue
		or type(sourceValue) ~= "table"
		or preparedSources[sourceValue :: PreparedRespawnSourceData] ~= capability.prepared
	then
		return false, "forged-prepared-post-pmove-corpse-source"
	end
	local currentError = preparedCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function PostPmoveCorpseSourceService.ValidatePreparedCorpseDependency(
	preparedValue: unknown,
	corpsePreparedValue: unknown,
	corpseSourceValue: unknown
): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if capability.corpsePrepared ~= corpsePreparedValue or capability.corpseSource ~= corpseSourceValue then
		return false, "forged-prepared-post-pmove-corpse-dependency"
	end
	local currentError = preparedCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function PostPmoveCorpseSourceService.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	capability.applyValidated = true
	return true, nil
end

function PostPmoveCorpseSourceService.ApplyPrepared(preparedValue: unknown): CommitReceipt
	local capability, capabilityError = getPreparedCapability(preparedValue)
	assert(capability, capabilityError or "invalid-prepared-post-pmove-corpse-source")
	assert(capability.applyValidated, "prepared-post-pmove-corpse-source-not-validated")
	for _ = 1, 2 do
		local currentError = preparedCurrentError(preparedValue, capability)
		assert(currentError == nil, currentError or "stale-prepared-post-pmove-corpse-source")
	end

	capability.status = "Applied"
	capability.applyValidated = false
	capability.captureCapability.status = "Consumed"
	capturesByHandle[capability.capture] = nil
	capturesBySummary[capability.captureCapability.summary] = nil
	currentCaptureByPlayer[capability.player] = nil
	activePreparedByPlayer[capability.player] = nil
	preparedCapabilities[capability.prepared] = nil
	preparedSources[capability.source] = nil
	return capability.commitReceipt
end

function PostPmoveCorpseSourceService.AbortPrepared(preparedValue: unknown): (AbortReceipt?, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return nil, capabilityError
	end
	if capability.status ~= "Prepared" or activePreparedByPlayer[capability.player] ~= capability then
		return nil, "stale-prepared-post-pmove-corpse-source"
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	activePreparedByPlayer[capability.player] = nil
	preparedCapabilities[capability.prepared] = nil
	preparedSources[capability.source] = nil
	return capability.abortReceipt, nil
end

return table.freeze(PostPmoveCorpseSourceService)
