--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-authoritative Q3 dropped-team-flag entity owner translated from:
  code/game/g_items.c (Drop_Item, LaunchItem, G_RunItem, G_BounceItem)
  code/game/g_team.c (Team_DroppedFlagThink, Team_FreeEntity)
  code/game/g_main.c (numeric entity traversal and strict think deadlines)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local FlagDefinitions = require(sharedRoot:WaitForChild("ctf"):WaitForChild("FlagDefinitions"))
local DroppedWeaponRules =
	require(sharedRoot:WaitForChild("items"):WaitForChild("DroppedWeaponRules"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local MoverConsequenceRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverConsequenceRules"))
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))
local WorldPointContents =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldPointContents"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local ReleaseBroker = require(script.Parent.MoverParticipantReleaseBrokerService)

local DroppedFlagService = {}

type TeamId = FlagDefinitions.TeamId
type Hooks = {
	GetPointContents: (position: Vector3) -> number,
	OnPosition: (teamId: TeamId, position: Vector3) -> (),
	OnReturn: (teamId: TeamId, reason: string) -> (),
	OnStagedAbort: (teamId: TeamId, dropId: string, reason: "Removed" | "Abort") -> (),
}

type Record = {
	teamId: TeamId,
	dropId: string,
	registration: EntitySlotService.Registration,
	binding: EntityFrameDispatcherService.DynamicBinding,
	participant: MoverItemFlagParticipantRules.Participant,
	spawnTimeMilliseconds: number,
	trajectoryTimeMilliseconds: number,
	eventStartedAtMilliseconds: number?,
	expiresAtMilliseconds: number,
	settled: boolean,
	pendingReturnReason: string?,
	revision: number,
}
type PendingMoverInsertion = {
	teamId: TeamId,
	dropId: string,
	registration: EntitySlotService.Registration,
	participant: MoverItemFlagParticipantRules.Participant,
	spawnTimeMilliseconds: number,
}

type Authority = {
	revision: number,
	recordsById: { [string]: Record },
	activeByTeamId: { [string]: Record },
	order: { Record },
}

export type PreparedMoverUpdate = {}
export type MoverUpdateReceipt = {}
export type MoverAdapter = {
	read Collect: () -> MoverItemFlagParticipantRules.Collection,
	read ResolveSine: (bodyId: string) -> MoverItemFlagParticipantRules.SynchronousCrushEffect,
	read ResolveBlockedDoor: (bodyId: string) -> MoverItemFlagParticipantRules.Transition,
	read Prepare: (finalBodies: unknown) -> (PreparedMoverUpdate?, string?),
	read CanApply: (prepared: unknown) -> (boolean, string?),
	read Apply: (prepared: unknown) -> MoverUpdateReceipt,
	read Flush: (receipt: unknown) -> boolean,
	read Abort: (prepared: unknown) -> boolean,
	read BindSharedMutation: (
		prepared: unknown,
		sharedPrepared: ReleaseBroker.Prepared
	) -> (boolean, string?),
}
type PreparedPendingInsertion = {
	pending: PendingMoverInsertion,
	participant: MoverItemFlagParticipantRules.Participant,
}

type PreparedCapability = {
	status: "Prepared" | "Applied" | "Flushed" | "Aborted",
	preflightPassCount: number,
	baseAuthority: Authority,
	nextAuthority: Authority,
	changedRecords: { Record },
	removedRecords: { Record },
	returnReasons: { [string]: string },
	pendingInsertions: { PreparedPendingInsertion },
	insertedRecords: { Record },
	prepared: PreparedMoverUpdate,
	receipt: MoverUpdateReceipt,
}

local EMPTY_RECORDS: { [string]: Record } = table.freeze({})
local EMPTY_ORDER: { Record } = table.freeze({})
local authority: Authority = table.freeze({
	revision = 0,
	recordsById = EMPTY_RECORDS,
	activeByTeamId = EMPTY_RECORDS,
	order = EMPTY_ORDER,
})
local started = false
local hooks: Hooks? = nil
local castParameters: RaycastParams? = nil
local activePrepared: PreparedMoverUpdate? = nil
local pendingMoverInsertions: { PendingMoverInsertion } = {}
local preparedCapabilities: { [PreparedMoverUpdate]: PreparedCapability } = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local receiptCapabilities: { [MoverUpdateReceipt]: PreparedCapability } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

local function preparedMoverUpdateBlocksAuthority(): boolean
	local prepared = activePrepared
	if not prepared then
		return false
	end
	for _, capability in receiptCapabilities do
		if capability.prepared == prepared then
			return capability.status ~= "Applied"
		end
	end
	return true
end

local function cloneRecord(
	record: Record,
	participant: MoverItemFlagParticipantRules.Participant,
	trajectoryTimeMilliseconds: number,
	eventStartedAtMilliseconds: number?,
	settled: boolean,
	pendingReturnReason: string?
): Record
	return table.freeze({
		teamId = record.teamId,
		dropId = record.dropId,
		registration = record.registration,
		binding = record.binding,
		participant = participant,
		spawnTimeMilliseconds = record.spawnTimeMilliseconds,
		trajectoryTimeMilliseconds = trajectoryTimeMilliseconds,
		eventStartedAtMilliseconds = eventStartedAtMilliseconds,
		expiresAtMilliseconds = record.expiresAtMilliseconds,
		settled = settled,
		pendingReturnReason = pendingReturnReason,
		revision = record.revision + 1,
	})
end

local function replaceRecord(record: Record, nextRecord: Record)
	assert(not preparedMoverUpdateBlocksAuthority(), "dropped flag changed during mover prepare")
	local base = authority
	assert(base.recordsById[record.dropId] == record, "dropped flag record is stale")
	local recordsById = table.clone(base.recordsById)
	recordsById[record.dropId] = nextRecord
	table.freeze(recordsById)
	local activeByTeamId = table.clone(base.activeByTeamId)
	if activeByTeamId[record.teamId] == record then
		activeByTeamId[record.teamId] = if nextRecord.participant.lifecycle == "ActiveLinked"
			then nextRecord
			else nil
	end
	table.freeze(activeByTeamId)
	local order = table.clone(base.order)
	local index = assert(table.find(order, record), "dropped flag order is stale")
	order[index] = nextRecord
	table.freeze(order)
	authority = table.freeze({
		revision = base.revision + 1,
		recordsById = recordsById,
		activeByTeamId = activeByTeamId,
		order = order,
	})
end

local function removeRecordRoot(record: Record)
	local base = authority
	assert(base.recordsById[record.dropId] == record, "dropped flag removal is stale")
	local recordsById = table.clone(base.recordsById)
	recordsById[record.dropId] = nil
	table.freeze(recordsById)
	local activeByTeamId = table.clone(base.activeByTeamId)
	if activeByTeamId[record.teamId] == record then
		activeByTeamId[record.teamId] = nil
	end
	table.freeze(activeByTeamId)
	local order = table.clone(base.order)
	local index = assert(table.find(order, record), "dropped flag removal order is stale")
	table.remove(order, index)
	table.freeze(order)
	authority = table.freeze({
		revision = base.revision + 1,
		recordsById = recordsById,
		activeByTeamId = activeByTeamId,
		order = order,
	})
end

local function pointHasNoDrop(position: Vector3): boolean
	local callback = assert(hooks, "DroppedFlagService hooks are unavailable").GetPointContents
	local ok, contents = pcall(callback, position)
	return not ok or type(contents) ~= "number" or WorldPointContents.IsNoDrop(contents)
end

local function releaseDynamic(record: Record, reason: string?, returnFlag: boolean)
	local frame =
		assert(AuthoritativeFrameService.GetOpenFrame(), "dropped flag release outside frame")
	local summary =
		assert(AuthoritativeFrameService.InspectFrame(frame), "dropped flag frame missing")
	local token = assert(EntitySlotService.Begin(summary.currentTimeMilliseconds))
	assert(EntitySlotService.ReleaseWorld(token, record.registration))
	local entityPrepared = assert(EntitySlotService.Prepare(token))
	local entitySummary = assert(EntitySlotService.InspectPreparedCommitSummary(entityPrepared))
	local entityReceipt = assert(EntitySlotService.InspectPreparedCommitReceipt(entityPrepared))
	local dispatcherPrepared =
		assert(EntityFrameDispatcherService.PrepareDynamicBatch(entityPrepared, entitySummary, {
			{
				kind = "Unbind",
				registration = record.registration,
				binding = record.binding,
			},
		}))
	local dispatcherReceipt =
		assert(EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared))
	for _pass = 1, 2 do
		assert(EntitySlotService.CanApplyPrepared(entityPrepared))
		assert(EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(dispatcherPrepared))
	end
	assert(
		EntitySlotService.ApplyPrepared(entityPrepared) == entityReceipt,
		"dropped flag release EntitySlot receipt drifted"
	)
	assert(
		EntityFrameDispatcherService.ApplyPreparedDynamicBatch(dispatcherPrepared)
			== dispatcherReceipt,
		"dropped flag release Dispatcher receipt drifted"
	)
	removeRecordRoot(record)
	if returnFlag then
		assert(hooks, "DroppedFlagService hooks are unavailable").OnReturn(
			record.teamId,
			reason or "Return"
		)
	end
end

local runDynamic: EntityFrameDispatcherService.DynamicHandler

function DroppedFlagService.StageSynchronousMoverInsertion(
	teamId: TeamId,
	position: Vector3,
	velocity: Vector3,
	levelTimeMilliseconds: number,
	operationOrder: number,
	dropId: string
): (
	MoverItemFlagParticipantRules.Body?,
	string?
)
	local brokerToken = ReleaseBroker.GetActiveToken()
	if
		not started
		or not brokerToken
		or authority.activeByTeamId[teamId] ~= nil
		or not DroppedWeaponRules.IsValidPosition(position)
		or not DroppedWeaponRules.IsValidLaunchVelocity(velocity)
	then
		return nil, "synchronous-mover-flag-insertion-unavailable"
	end
	for _, pending in pendingMoverInsertions do
		if pending.teamId == teamId or pending.dropId == dropId then
			return nil, "synchronous-mover-flag-insertion-duplicate"
		end
	end
	local registration, allocationError =
		ReleaseBroker.AllocateWorld(brokerToken, "dropped_flag", "DroppedFlag", runDynamic)
	if not registration then
		return nil, allocationError
	end
	local insertion, insertionError = MoverConsequenceRules.BuildTeamFlagInsertion({
		bodyId = registration.bodyId,
		sourceOrder = registration.sourceOrder,
		position = position,
		velocity = velocity,
		teamId = teamId,
		operationOrder = operationOrder,
	})
	local participant, participantError =
		if insertion then MoverItemFlagParticipantRules.CreateFromInsertion(insertion) else nil,
		insertionError
	if not participant then
		ReleaseBroker.CancelAllocation(brokerToken, registration)
		return nil, participantError
	end
	table.insert(pendingMoverInsertions, {
		teamId = teamId,
		dropId = dropId,
		registration = registration,
		participant = participant,
		spawnTimeMilliseconds = levelTimeMilliseconds,
	})
	return participant.body, nil
end

function DroppedFlagService.Spawn(
	teamId: TeamId,
	position: Vector3,
	velocity: Vector3,
	levelTimeMilliseconds: number,
	operationOrder: number,
	dropId: string
): (boolean, string?)
	if
		not started
		or activePrepared ~= nil
		or authority.activeByTeamId[teamId] ~= nil
		or authority.recordsById[dropId] ~= nil
		or not DroppedWeaponRules.IsValidPosition(position)
		or not DroppedWeaponRules.IsValidLaunchVelocity(velocity)
	then
		return false, "dropped-flag-spawn-unavailable"
	end
	local token, beginError = EntitySlotService.Begin(levelTimeMilliseconds)
	if not token then
		return false, beginError
	end
	local registration, allocationError = EntitySlotService.AllocateWorld(token, "dropped_flag")
	if not registration then
		EntitySlotService.Abort(token)
		return false, allocationError
	end
	local insertion, insertionError = MoverConsequenceRules.BuildTeamFlagInsertion({
		bodyId = registration.bodyId,
		sourceOrder = registration.sourceOrder,
		position = position,
		velocity = velocity,
		teamId = teamId,
		operationOrder = operationOrder,
	})
	local participant, participantError =
		if insertion then MoverItemFlagParticipantRules.CreateFromInsertion(insertion) else nil,
		insertionError
	if not participant then
		EntitySlotService.Abort(token)
		return false, participantError
	end
	local entityPrepared, entityPrepareError = EntitySlotService.Prepare(token)
	if not entityPrepared then
		EntitySlotService.Abort(token)
		return false, entityPrepareError
	end
	local entitySummary = assert(EntitySlotService.InspectPreparedCommitSummary(entityPrepared))
	local entityReceipt = assert(EntitySlotService.InspectPreparedCommitReceipt(entityPrepared))
	local dispatcherPrepared, dispatcherSummary, dispatcherError =
		EntityFrameDispatcherService.PrepareDynamicBatch(entityPrepared, entitySummary, {
			{
				kind = "Bind",
				registration = registration,
				declaredKind = "DroppedFlag",
				handler = runDynamic,
			},
		})
	if not dispatcherPrepared or not dispatcherSummary then
		EntitySlotService.Abort(token)
		return false, dispatcherError
	end
	local dispatcherReceipt =
		assert(EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared))
	local outcome = dispatcherSummary.outcomes[1]
	local binding = outcome.binding
	local record: Record = table.freeze({
		teamId = teamId,
		dropId = dropId,
		registration = registration,
		binding = binding,
		participant = participant,
		spawnTimeMilliseconds = levelTimeMilliseconds,
		trajectoryTimeMilliseconds = levelTimeMilliseconds,
		eventStartedAtMilliseconds = nil,
		expiresAtMilliseconds = levelTimeMilliseconds + 30_000,
		settled = false,
		pendingReturnReason = nil,
		revision = 1,
	})
	local recordsById = table.clone(authority.recordsById)
	recordsById[dropId] = record
	table.freeze(recordsById)
	local activeByTeamId = table.clone(authority.activeByTeamId)
	activeByTeamId[teamId] = record
	table.freeze(activeByTeamId)
	local order = table.clone(authority.order)
	table.insert(order, record)
	table.sort(order, function(left, right)
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(order)
	local nextAuthority: Authority = table.freeze({
		revision = authority.revision + 1,
		recordsById = recordsById,
		activeByTeamId = activeByTeamId,
		order = order,
	})
	for _pass = 1, 2 do
		assert(EntitySlotService.CanApplyPrepared(entityPrepared))
		assert(EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(dispatcherPrepared))
	end
	assert(
		EntitySlotService.ApplyPrepared(entityPrepared) == entityReceipt,
		"dropped flag insertion EntitySlot receipt drifted"
	)
	assert(
		EntityFrameDispatcherService.ApplyPreparedDynamicBatch(dispatcherPrepared)
			== dispatcherReceipt,
		"dropped flag insertion Dispatcher receipt drifted"
	)
	authority = nextAuthority
	assert(hooks, "DroppedFlagService hooks are unavailable").OnPosition(teamId, position)
	return true, nil
end

function DroppedFlagService.GetPosition(teamId: TeamId): Vector3?
	local record = authority.activeByTeamId[teamId]
	return if record then record.participant.body.position else nil
end

function DroppedFlagService.GetDebugRecords(): { { dropId: string, sourceOrder: number, teamId: TeamId } }
	local records = {}
	for _, record in authority.order do
		table.insert(
			records,
			table.freeze({
				dropId = record.dropId,
				sourceOrder = record.registration.sourceOrder,
				teamId = record.teamId,
			})
		)
	end
	table.freeze(records)
	return records
end

function DroppedFlagService.MarkTaken(teamId: TeamId, levelTimeMilliseconds: number): boolean
	local record = authority.activeByTeamId[teamId]
	if not record or record.participant.lifecycle ~= "ActiveLinked" then
		return false
	end
	local transition =
		assert(MoverItemFlagParticipantRules.ResolveTouch(record.participant, "DroppedTaken"))
	replaceRecord(
		record,
		cloneRecord(
			record,
			transition.participant,
			record.trajectoryTimeMilliseconds,
			levelTimeMilliseconds,
			record.settled,
			nil
		)
	)
	return true
end

function DroppedFlagService.MarkReturn(teamId: TeamId, reason: string): boolean
	local record = authority.activeByTeamId[teamId]
	if not record then
		return false
	end
	local transition =
		assert(MoverItemFlagParticipantRules.ResolveDroppedTimeout(record.participant, 30_000))
	replaceRecord(
		record,
		cloneRecord(
			record,
			transition.participant,
			record.trajectoryTimeMilliseconds,
			record.eventStartedAtMilliseconds,
			record.settled,
			reason
		)
	)
	return true
end

runDynamic = function(_frame, summary, registration, binding, declaredKind)
	assert(declaredKind == "DroppedFlag", "dropped flag Dispatcher kind drifted")
	local record: Record? = nil
	for _, candidate in authority.order do
		if candidate.registration == registration then
			record = candidate
			break
		end
	end
	record = assert(record, "dropped flag Dispatcher record is unavailable")
	assert(record.binding == binding, "dropped flag Dispatcher binding drifted")
	local currentMilliseconds = summary.currentTimeMilliseconds
	if record.participant.lifecycle == "PendingFreeAfterEvent" then
		local eventStart = assert(
			record.eventStartedAtMilliseconds,
			"dropped flag pending event lost its start time"
		)
		local elapsed = currentMilliseconds - eventStart
		if elapsed <= 300 then
			return
		end
		assert(MoverItemFlagParticipantRules.FinishEvent(record.participant, elapsed))
		releaseDynamic(record, nil, false)
		return
	elseif record.participant.lifecycle == "Freed" then
		releaseDynamic(record, record.pendingReturnReason, true)
		return
	elseif currentMilliseconds >= record.expiresAtMilliseconds then
		assert(
			MoverItemFlagParticipantRules.ResolveDroppedTimeout(
				record.participant,
				currentMilliseconds - record.spawnTimeMilliseconds
			)
		)
		releaseDynamic(record, "Timeout", true)
		return
	end
	assert(
		record.trajectoryTimeMilliseconds >= record.spawnTimeMilliseconds
			and record.trajectoryTimeMilliseconds <= currentMilliseconds,
		"dropped-flag trajectory clock is corrupt"
	)
	if record.settled then
		return
	end
	local deltaMilliseconds = currentMilliseconds - record.trajectoryTimeMilliseconds
	-- Q3 G_RunItem evaluates at absolute level.time and traces from the last
	-- linked origin. A delayed dynamic visit therefore advances the complete
	-- monotonic interval instead of requiring exactly one fixed step.
	if deltaMilliseconds == 0 then
		return
	end
	local deltaTime = deltaMilliseconds / MatchFrameRules.MillisecondsPerSecond
	local start = record.participant.body.position
	local velocity = record.participant.body.velocity
	local target, nextVelocity = DroppedWeaponRules.Integrate(start, velocity, deltaTime)
	local displacement = target - start
	local distance = displacement.Magnitude
	local result = if distance > 1e-6
		then Workspace:Blockcast(
			CFrame.new(start),
			DroppedWeaponRules.ItemHullSize,
			displacement,
			assert(castParameters, "dropped flag cast parameters are unavailable")
		)
		else nil
	local nextPosition = target
	local settled = false
	if result then
		local fraction = math.clamp(result.Distance / math.max(distance, 1e-6), 0, 1)
		local _, impactVelocity =
			DroppedWeaponRules.Integrate(start, velocity, deltaTime * fraction)
		nextPosition = start + displacement.Unit * result.Distance
		if pointHasNoDrop(nextPosition) then
			assert(MoverItemFlagParticipantRules.ResolveNoDropCollision(record.participant))
			releaseDynamic(record, "NoDrop", true)
			return
		end
		nextVelocity, settled = DroppedWeaponRules.Bounce(impactVelocity, result.Normal)
		if settled then
			nextPosition += Vector3.yAxis * DroppedWeaponRules.SurfaceNudge
			nextPosition = Vector3.new(
				DroppedWeaponRules.SnapSourceUnit(nextPosition.X),
				DroppedWeaponRules.SnapSourceUnit(nextPosition.Y),
				DroppedWeaponRules.SnapSourceUnit(nextPosition.Z)
			)
		else
			nextPosition += result.Normal * DroppedWeaponRules.SurfaceNudge
		end
	end
	local participant = assert(
		MoverItemFlagParticipantRules.ApplyRunItemBody(
			record.participant,
			nextPosition,
			nextVelocity,
			nil
		)
	)
	local nextRecord = cloneRecord(record, participant, currentMilliseconds, nil, settled, nil)
	replaceRecord(record, nextRecord)
	assert(hooks, "DroppedFlagService hooks are unavailable").OnPosition(
		record.teamId,
		nextPosition
	)
end

function DroppedFlagService.CollectMoverParticipants(): MoverItemFlagParticipantRules.Collection
	assert(activePrepared == nil, "dropped flag collection crossed prepare")
	local participants: { MoverItemFlagParticipantRules.Participant } = {}
	for _, record in authority.order do
		table.insert(participants, record.participant)
	end
	for _, pending in pendingMoverInsertions do
		table.insert(participants, pending.participant)
	end
	return assert(MoverItemFlagParticipantRules.Collect(participants))
end

local function recordForBodyId(bodyId: string): Record
	for _, record in authority.order do
		if record.participant.body.id == bodyId then
			return record
		end
	end
	for _, pending in pendingMoverInsertions do
		if pending.participant.body.id == bodyId then
			return pending :: any
		end
	end
	error("dropped flag mover body is stale")
end

function DroppedFlagService.ResolveMoverSine(bodyId: string)
	return assert(
		MoverItemFlagParticipantRules.ResolveSineCrush(recordForBodyId(bodyId).participant)
	)
end

function DroppedFlagService.ResolveMoverBlockedDoor(bodyId: string)
	return assert(
		MoverItemFlagParticipantRules.ResolveBlockedDoor(recordForBodyId(bodyId).participant)
	)
end

function DroppedFlagService.PrepareMoverUpdate(
	finalBodiesValue: unknown
): (PreparedMoverUpdate?, string?)
	if activePrepared ~= nil or type(finalBodiesValue) ~= "table" then
		return nil, "dropped-flag-mover-owner-unavailable"
	end
	local finalBodiesById: { [string]: unknown } = {}
	for _, body in finalBodiesValue :: { any } do
		if type(body) == "table" and type(body.id) == "string" then
			finalBodiesById[body.id] = body
		end
	end
	local base = authority
	local recordsById = table.clone(base.recordsById)
	local activeByTeamId = table.clone(base.activeByTeamId)
	local order: { Record } = {}
	local changedRecords: { Record } = {}
	local removedRecords: { Record } = {}
	local returnReasons: { [string]: string } = {}
	local preparedPendingInsertions: { PreparedPendingInsertion } = {}
	for _, record in base.order do
		local finalBody = finalBodiesById[record.participant.body.id]
		if finalBody == nil then
			recordsById[record.dropId] = nil
			if activeByTeamId[record.teamId] == record then
				activeByTeamId[record.teamId] = nil
			end
			table.insert(removedRecords, record)
			returnReasons[record.teamId] = record.pendingReturnReason or "BlockedDoor"
			local brokerToken = assert(ReleaseBroker.GetActiveToken())
			local staged, stageError =
				ReleaseBroker.StageRelease(brokerToken, record.registration, record.binding)
			if not staged then
				return nil, stageError
			end
			continue
		end
		local participant, participantError =
			MoverItemFlagParticipantRules.ApplyMoverBody(record.participant, finalBody)
		if not participant then
			return nil, participantError
		end
		local nextRecord = record
		if
			participant.body.position ~= record.participant.body.position
			or participant.body.groundMoverId ~= record.participant.body.groundMoverId
		then
			nextRecord = cloneRecord(
				record,
				participant,
				record.trajectoryTimeMilliseconds,
				record.eventStartedAtMilliseconds,
				record.settled,
				record.pendingReturnReason
			)
			recordsById[record.dropId] = nextRecord
			if activeByTeamId[record.teamId] == record then
				activeByTeamId[record.teamId] = nextRecord
			end
			table.insert(changedRecords, nextRecord)
		end
		table.insert(order, nextRecord)
	end
	local brokerToken = ReleaseBroker.GetActiveToken()
	for index = #pendingMoverInsertions, 1, -1 do
		local pending = pendingMoverInsertions[index]
		local finalBody = finalBodiesById[pending.participant.body.id]
		if finalBody == nil then
			if not brokerToken then
				return nil, "removed-pending-flag-lost-shared-broker"
			end
			local canceled, cancelError =
				ReleaseBroker.CancelAllocation(brokerToken, pending.registration)
			if not canceled then
				return nil, cancelError
			end
			assert(hooks, "DroppedFlagService hooks are unavailable").OnStagedAbort(
				pending.teamId,
				pending.dropId,
				"Removed"
			)
			table.remove(pendingMoverInsertions, index)
			continue
		end
		local participant, participantError =
			MoverItemFlagParticipantRules.ApplyMoverBody(pending.participant, finalBody)
		if not participant then
			return nil, participantError
		end
		table.insert(preparedPendingInsertions, 1, {
			pending = pending,
			participant = participant,
		})
	end
	table.freeze(recordsById)
	table.freeze(activeByTeamId)
	table.freeze(order)
	table.freeze(changedRecords)
	table.freeze(removedRecords)
	table.freeze(returnReasons)
	table.freeze(preparedPendingInsertions)
	local nextAuthority: Authority = base
	if #changedRecords > 0 or #removedRecords > 0 then
		nextAuthority = table.freeze({
			revision = base.revision + 1,
			recordsById = recordsById,
			activeByTeamId = activeByTeamId,
			order = order,
		})
	end
	local prepared: PreparedMoverUpdate = table.freeze({})
	local receipt: MoverUpdateReceipt = table.freeze({})
	local capability: PreparedCapability = {
		status = "Prepared",
		preflightPassCount = 0,
		baseAuthority = base,
		nextAuthority = nextAuthority,
		changedRecords = changedRecords,
		removedRecords = removedRecords,
		returnReasons = returnReasons,
		pendingInsertions = preparedPendingInsertions,
		insertedRecords = {},
		prepared = prepared,
		receipt = receipt,
	}
	preparedCapabilities[prepared] = capability
	receiptCapabilities[receipt] = capability
	activePrepared = prepared
	return prepared, nil
end

function DroppedFlagService.CanApplyMoverUpdate(preparedValue: unknown): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: PreparedMoverUpdate]
		else nil
	if
		not capability
		or capability.status ~= "Prepared"
		or authority ~= capability.baseAuthority
	then
		return false, "stale-prepared-dropped-flag-mover-update"
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	return true, nil
end

function DroppedFlagService.BindMoverUpdateSharedMutation(
	preparedValue: unknown,
	sharedPreparedValue: ReleaseBroker.Prepared
): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: PreparedMoverUpdate]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-prepared-dropped-flag-mover-update"
	end
	if #capability.pendingInsertions == 0 then
		return true, nil
	end
	local recordsById = table.clone(capability.nextAuthority.recordsById)
	local activeByTeamId = table.clone(capability.nextAuthority.activeByTeamId)
	local order = table.clone(capability.nextAuthority.order)
	for _, preparedPending in capability.pendingInsertions do
		local pending = preparedPending.pending
		local binding = ReleaseBroker.InspectPreparedAllocationBinding(
			sharedPreparedValue,
			pending.registration
		)
		if
			not binding
			or recordsById[pending.dropId] ~= nil
			or activeByTeamId[pending.teamId] ~= nil
		then
			return false, "pending-dropped-flag-shared-binding-invalid"
		end
		local record: Record = table.freeze({
			teamId = pending.teamId,
			dropId = pending.dropId,
			registration = pending.registration,
			binding = binding,
			participant = preparedPending.participant,
			spawnTimeMilliseconds = pending.spawnTimeMilliseconds,
			trajectoryTimeMilliseconds = pending.spawnTimeMilliseconds,
			eventStartedAtMilliseconds = nil,
			expiresAtMilliseconds = pending.spawnTimeMilliseconds + 30_000,
			settled = false,
			pendingReturnReason = nil,
			revision = 1,
		})
		recordsById[record.dropId] = record
		activeByTeamId[record.teamId] = record
		table.insert(order, record)
		table.insert(capability.insertedRecords, record)
	end
	table.sort(order, function(left, right)
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(recordsById)
	table.freeze(activeByTeamId)
	table.freeze(order)
	table.freeze(capability.insertedRecords)
	capability.nextAuthority = table.freeze({
		revision = capability.nextAuthority.revision + 1,
		recordsById = recordsById,
		activeByTeamId = activeByTeamId,
		order = order,
	})
	return true, nil
end

function DroppedFlagService.ApplyMoverUpdate(preparedValue: unknown): MoverUpdateReceipt
	local prepared = preparedValue :: PreparedMoverUpdate
	local capability =
		assert(preparedCapabilities[prepared], "invalid prepared dropped flag mover update")
	assert(
		capability.status == "Prepared" and capability.preflightPassCount >= 2,
		"stale prepared dropped flag mover apply"
	)
	authority = capability.nextAuthority
	capability.status = "Applied"
	preparedCapabilities[prepared] = nil
	-- Apply commits the dropped-flag authority. Deferred publication owns the
	-- receipt, not this global prepare slot; carrier deaths can insert a new flag
	-- after the mover phase and before the spool flushes.
	if activePrepared == prepared then
		activePrepared = nil
	end
	return capability.receipt
end

function DroppedFlagService.FlushMoverUpdate(receiptValue: unknown): boolean
	local capability = if type(receiptValue) == "table"
		then receiptCapabilities[receiptValue :: MoverUpdateReceipt]
		else nil
	if not capability or capability.status ~= "Applied" then
		return false
	end
	capability.status = "Flushed"
	receiptCapabilities[capability.receipt] = nil
	if activePrepared == capability.prepared then
		activePrepared = nil
	end
	for _, record in capability.changedRecords do
		if authority.recordsById[record.dropId] == record then
			assert(hooks, "DroppedFlagService hooks are unavailable").OnPosition(
				record.teamId,
				record.participant.body.position
			)
		end
	end
	for _, record in capability.insertedRecords do
		local current = authority.recordsById[record.dropId]
		if current and current.registration == record.registration then
			assert(hooks, "DroppedFlagService hooks are unavailable").OnPosition(
				current.teamId,
				current.participant.body.position
			)
		end
		local pendingIndex: number? = nil
		for index, pending in pendingMoverInsertions do
			if pending.registration == record.registration then
				pendingIndex = index
				break
			end
		end
		if pendingIndex then
			table.remove(pendingMoverInsertions, pendingIndex)
		end
	end
	for teamId, reason in capability.returnReasons do
		-- Do not let an older removal publication return a newer same-team drop.
		if authority.activeByTeamId[teamId] == nil then
			assert(hooks, "DroppedFlagService hooks are unavailable").OnReturn(
				teamId :: TeamId,
				reason
			)
		end
	end
	return true
end

function DroppedFlagService.AbortMoverUpdate(preparedValue: unknown): boolean
	local prepared = if type(preparedValue) == "table"
		then preparedValue :: PreparedMoverUpdate
		else nil
	local capability = if prepared then preparedCapabilities[prepared] else nil
	if not capability or capability.status ~= "Prepared" then
		return false
	end
	for _, preparedPending in capability.pendingInsertions do
		assert(hooks, "DroppedFlagService hooks are unavailable").OnStagedAbort(
			preparedPending.pending.teamId,
			preparedPending.pending.dropId,
			"Abort"
		)
		local index = table.find(pendingMoverInsertions, preparedPending.pending)
		if index then
			table.remove(pendingMoverInsertions, index)
		end
	end
	capability.status = "Aborted"
	preparedCapabilities[prepared :: PreparedMoverUpdate] = nil
	receiptCapabilities[capability.receipt] = nil
	activePrepared = nil
	return true
end

local moverAdapter: MoverAdapter = table.freeze({
	Collect = DroppedFlagService.CollectMoverParticipants,
	ResolveSine = DroppedFlagService.ResolveMoverSine,
	ResolveBlockedDoor = DroppedFlagService.ResolveMoverBlockedDoor,
	Prepare = DroppedFlagService.PrepareMoverUpdate,
	CanApply = DroppedFlagService.CanApplyMoverUpdate,
	Apply = DroppedFlagService.ApplyMoverUpdate,
	Flush = DroppedFlagService.FlushMoverUpdate,
	Abort = DroppedFlagService.AbortMoverUpdate,
	BindSharedMutation = DroppedFlagService.BindMoverUpdateSharedMutation,
})

function DroppedFlagService.GetMoverAdapter(): MoverAdapter
	return moverAdapter
end

function DroppedFlagService.Start(worldRoot: Instance, serviceHooks: Hooks)
	assert(not started, "DroppedFlagService.Start may only run once")
	assert(type(serviceHooks) == "table", "DroppedFlagService.Start requires hooks")
	hooks = serviceHooks
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = { worldRoot }
	parameters.IgnoreWater = true
	castParameters = parameters
	started = true
end

return table.freeze(DroppedFlagService)
