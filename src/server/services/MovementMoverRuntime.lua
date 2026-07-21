--[[
SPDX-License-Identifier: GPL-2.0-or-later

Mutable mover simulation and presentation state extracted from MovementService.
The owner remains server-authoritative; this module only establishes the mover
subsystem boundary and constructs its private state.

Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local simulationRoot = sharedRoot:WaitForChild("simulation")
local MoverBinaryPolicy = require(simulationRoot:WaitForChild("MoverBinaryPolicy"))
local MoverBinaryState = require(simulationRoot:WaitForChild("MoverBinaryState"))
local MoverClock = require(simulationRoot:WaitForChild("MoverClock"))
local MoverCollisionFrame = require(simulationRoot:WaitForChild("MoverCollisionFrame"))
local MoverPushRules = require(simulationRoot:WaitForChild("MoverPushRules"))
local MoverSnapshotContract = require(simulationRoot:WaitForChild("MoverSnapshotContract"))

export type State = {
	authoredLegacyDefinitions: { MoverPushRules.Definition },
	runtimeLegacyDefinitions: { MoverPushRules.Definition },
	binaryPrograms: { MoverBinaryState.Program },
	binaryRuntime: MoverBinaryState.Runtime?,
	binaryPolicies: { MoverBinaryPolicy.Policy },
	binaryPolicyByTeam: { [string]: MoverBinaryPolicy.Policy },
	binaryTeamIds: { [string]: boolean },
	binaryIds: { [string]: boolean },
	legacyIds: { [string]: boolean },
	definitions: { MoverPushRules.Definition },
	clock: MoverClock.Snapshot,
	collisionFrame: MoverCollisionFrame.Frame,
	snapshotWire: MoverSnapshotContract.WireSnapshot?,
	presentationFolder: Folder?,
	crushTransitionCount: number,
	crushRemovedCount: number,
	crushRetainedCount: number,
	lastCrushMoverId: string?,
	lastCrushBodyId: string?,
	lastCrushClockStep: number?,
	pendingBinaryUses: { string },
	binaryUseTransitionCount: number,
	lastBinaryUseMoverId: string?,
	lastBinaryUseOutcome: MoverBinaryState.UseOutcome?,
	lastBinaryUseTimeMilliseconds: number?,
	lastBinaryUseClockStep: number?,
	binaryBlockedCallbackCount: number,
	binaryBlockedDamageCount: number,
	binaryBlockedReversalCount: number,
	binaryBlockedRemovalCount: number,
	lastBinaryBlockedMoverId: string?,
	lastBinaryBlockedBodyId: string?,
	lastBinaryBlockedTimeMilliseconds: number?,
	pendingStudioCrushBatch: { players: { Player }, moverIds: { string } }?,
	studioNoDropPointFixture: { cframe: CFrame, size: Vector3 }?,
	pendingStudioParticipantFrameCallback: ((number) -> ())?,
	activeDamageToken: unknown?,
	activeDeathSourceSession: unknown?,
	deathSourceCapabilities: { [table]: unknown },
}

local MovementMoverRuntime = {}

function MovementMoverRuntime.new(): State
	local definitions = table.freeze({}) :: { MoverPushRules.Definition }
	local clock = assert(MoverClock.Create(1, 0))
	return {
		authoredLegacyDefinitions = definitions,
		runtimeLegacyDefinitions = definitions,
		binaryPrograms = table.freeze({}) :: { MoverBinaryState.Program },
		binaryRuntime = nil,
		binaryPolicies = table.freeze({}) :: { MoverBinaryPolicy.Policy },
		binaryPolicyByTeam = table.freeze({}) :: { [string]: MoverBinaryPolicy.Policy },
		binaryTeamIds = table.freeze({}) :: { [string]: boolean },
		binaryIds = table.freeze({}) :: { [string]: boolean },
		legacyIds = table.freeze({}) :: { [string]: boolean },
		definitions = definitions,
		clock = clock,
		collisionFrame = assert(MoverCollisionFrame.Build(definitions, clock)),
		snapshotWire = nil,
		presentationFolder = nil,
		crushTransitionCount = 0,
		crushRemovedCount = 0,
		crushRetainedCount = 0,
		lastCrushMoverId = nil,
		lastCrushBodyId = nil,
		lastCrushClockStep = nil,
		pendingBinaryUses = {},
		binaryUseTransitionCount = 0,
		lastBinaryUseMoverId = nil,
		lastBinaryUseOutcome = nil,
		lastBinaryUseTimeMilliseconds = nil,
		lastBinaryUseClockStep = nil,
		binaryBlockedCallbackCount = 0,
		binaryBlockedDamageCount = 0,
		binaryBlockedReversalCount = 0,
		binaryBlockedRemovalCount = 0,
		lastBinaryBlockedMoverId = nil,
		lastBinaryBlockedBodyId = nil,
		lastBinaryBlockedTimeMilliseconds = nil,
		pendingStudioCrushBatch = nil,
		studioNoDropPointFixture = nil,
		pendingStudioParticipantFrameCallback = nil,
		activeDamageToken = nil,
		activeDeathSourceSession = nil,
		deathSourceCapabilities = setmetatable({}, { __mode = "k" }),
	}
end

function MovementMoverRuntime.GetDeathSourceSession(state: State): unknown?
	return state.activeDeathSourceSession
end

function MovementMoverRuntime.SetDeathSourceSession(state: State, session: unknown?)
	assert(session == nil or type(session) == "table", "mover death-source session must be opaque")
	state.activeDeathSourceSession = session
end

function MovementMoverRuntime.GetDeathSourceCapability(state: State, source: unknown): unknown?
	return if type(source) == "table" then state.deathSourceCapabilities[source :: table] else nil
end

function MovementMoverRuntime.SetDeathSourceCapability(state: State, source: unknown, capability: unknown?)
	assert(type(source) == "table", "mover death-source handle must be opaque")
	assert(capability == nil or type(capability) == "table", "mover death-source capability must be table")
	state.deathSourceCapabilities[source :: table] = capability
end

function MovementMoverRuntime.BeginDeathSourceSession(state: State, request: any): any
	assert(state.activeDeathSourceSession == nil, "mover death-source session is already active")
	local expectedWindow = assert(MoverClock.WindowFor(request.baseClock))
	local window = request.clockWindow
	local frameSummary = request.frameSummary
	assert(
		state.clock == request.baseClock
			and request.currentMoverAuthorityGeneration == request.baseMoverAuthorityGeneration
			and window.revision == expectedWindow.revision
			and window.fromStep == expectedWindow.fromStep
			and window.toStep == expectedWindow.toStep
			and window.fromTimeMilliseconds == expectedWindow.fromTimeMilliseconds
			and window.toTimeMilliseconds == expectedWindow.toTimeMilliseconds
			and frameSummary.clockRevision == window.revision
			and frameSummary.fromStep == window.fromStep
			and frameSummary.toStep == window.toStep
			and frameSummary.previousTimeMilliseconds == window.fromTimeMilliseconds
			and frameSummary.currentTimeMilliseconds == window.toTimeMilliseconds
			and frameSummary.msec == window.toTimeMilliseconds - window.fromTimeMilliseconds,
		"mover death-source session requires the exact mover clock window"
	)
	local session = {
		status = "Preparing",
		frame = request.frame,
		frameSummary = frameSummary,
		clockWindow = window,
		baseClock = request.baseClock,
		baseMoverAuthorityGeneration = request.baseMoverAuthorityGeneration,
		baseDefinitions = request.baseDefinitions,
		damageAdapter = request.damageAdapter,
		damageToken = request.damageToken,
		nextCallbackTraversalOrder = 0,
		sources = {},
		preparedHandle = nil,
	}
	state.activeDeathSourceSession = session
	return session
end

function MovementMoverRuntime.MintDeathSource(state: State, request: any): (table, table)
	local session = request.session
	assert(state.activeDeathSourceSession == session, "mover death-source session is stale at mint")
	local definition = request.definition
	local mapRegistration = request.mapRegistration
	local source = table.freeze({})
	local summary = table.freeze({
		kind = "Mover",
		victim = request.player,
		victimUserId = request.player.UserId,
		victimLifeBinding = request.lifeBinding,
		victimLifeSummary = request.lifeSummary,
		victimBody = request.body,
		callbackKind = request.callbackKind,
		callbackTraversalOrder = request.callbackTraversalOrder,
		frame = session.frame,
		frameSummary = session.frameSummary,
		clockWindow = session.clockWindow,
		baseMoverAuthorityGeneration = session.baseMoverAuthorityGeneration,
		moverId = definition.id,
		teamId = definition.teamId,
		moverSourceOrder = definition.sourceOrder,
		mapRegistration = mapRegistration,
		registration = mapRegistration.registration,
		lease = request.lease,
		definition = definition,
		entityTrajectoryBase = definition.trajectory.base,
	})
	local capability = {
		source = source,
		summary = summary,
		status = "Minted",
		session = session,
		record = request.record,
		lifeBinding = request.lifeBinding,
		lifeSummary = request.lifeSummary,
		body = request.body,
		definitionSet = request.definitionSet,
		definition = definition,
		mapRegistration = mapRegistration,
		lease = request.lease,
		stageReceipt = nil,
		appliedNormalToDeadReceipt = nil,
	}
	state.deathSourceCapabilities[source] = capability
	table.insert(session.sources, capability)
	return source, summary
end

function MovementMoverRuntime.CurrentDeathSource(
	state: State,
	sourceValue: unknown,
	summaryValue: unknown,
	validateExternal: (any) -> (boolean, string?)
): (any?, string?)
	if type(sourceValue) ~= "table" or type(summaryValue) ~= "table" then
		return nil, "invalid-mover-death-source-dependency"
	end
	local source = sourceValue :: table
	local capability = state.deathSourceCapabilities[source]
	if not capability or capability.source ~= source then
		return nil, "invalid-mover-death-source"
	end
	if capability.summary ~= summaryValue then
		return nil, "forged-mover-death-source-summary"
	end
	local summary = capability.summary
	local session = capability.session
	if
		capability.status == "Retired"
		or session.status == "Retired"
		or state.activeDeathSourceSession ~= session
		or state.clock ~= session.baseClock
		or summary.kind ~= "Mover"
		or summary.victimLifeBinding ~= capability.lifeBinding
		or summary.victimLifeSummary ~= capability.lifeSummary
		or summary.victimBody ~= capability.body
		or summary.frame ~= session.frame
		or summary.frameSummary ~= session.frameSummary
		or summary.clockWindow ~= session.clockWindow
		or summary.baseMoverAuthorityGeneration ~= session.baseMoverAuthorityGeneration
		or summary.moverId ~= capability.definition.id
		or summary.teamId ~= capability.definition.teamId
		or summary.moverSourceOrder ~= capability.definition.sourceOrder
		or summary.mapRegistration ~= capability.mapRegistration
		or summary.registration ~= capability.mapRegistration.registration
		or summary.lease ~= capability.lease
		or summary.definition ~= capability.definition
		or summary.entityTrajectoryBase ~= capability.definition.trajectory.base
		or summary.callbackTraversalOrder < 1
		or summary.callbackTraversalOrder > session.nextCallbackTraversalOrder
		or capability.appliedNormalToDeadReceipt ~= nil
		or not table.isfrozen(source)
		or not table.isfrozen(summary)
		or not table.isfrozen(summary.clockWindow)
		or not table.isfrozen(summary.definition)
		or not table.isfrozen(summary.victimBody)
	then
		return nil, "stale-mover-death-source"
	end
	if capability.status == "Minted" and capability.stageReceipt ~= nil then
		return nil, "stale-unclaimed-mover-death-source"
	elseif capability.status ~= "Minted" and capability.stageReceipt == nil then
		return nil, "stale-claimed-mover-death-source"
	end
	local valid, validationError = validateExternal(capability)
	if not valid then
		return nil, validationError or "stale-mover-death-source-external"
	end
	return capability, nil
end

function MovementMoverRuntime.AssembleNormalToDeadMember(state: State, request: any): any
	local assignment = request.assignment
	local sourceCapability = request.sourceCapability
	assert(
		state.deathSourceCapabilities[sourceCapability.source] == sourceCapability,
		"mover normal-to-dead member requires an owned death source"
	)
	local sourceSummary = sourceCapability.summary
	local record = sourceCapability.record
	local lifeSummary = sourceCapability.lifeSummary
	local summary = {
		mode = "MoverPushed",
		player = assignment.player,
		playerUserId = lifeSummary.playerUserId,
		lifeBinding = sourceCapability.lifeBinding,
		lifeSummary = lifeSummary,
		baseState = request.baseStateSnapshot,
		nextState = request.nextStateSnapshot,
		prospectiveState = request.prospectiveStateSnapshot,
		deathTrajectoryBase = sourceSummary.victimBody.position,
		baseEntityTrajectoryBase = assignment.baseEntityTrajectoryBase,
		baseEntityTrajectoryDelta = assignment.baseEntityTrajectoryDelta,
		baseEntityAngularTrajectoryBase = assignment.baseEntityAngularTrajectoryBase,
		nextEntityTrajectoryBase = assignment.nextEntityTrajectoryBase,
		nextEntityTrajectoryDelta = assignment.nextEntityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = request.nextEntityAngularTrajectoryBase,
		baseEntityGenericAngles = assignment.baseEntityGenericAngles,
		basePlayerStateViewAngles = assignment.basePlayerStateViewAngles,
		callbackEntityTrajectoryBase = sourceSummary.victimBody.position,
		callbackEntityAngularTrajectoryBase = assignment.baseEntityAngularTrajectoryBase,
		baseSpawnReserved = record.spawnReserved,
		nextSpawnReserved = false,
		lethalVelocityDelta = Vector3.zero,
		lethalKnockbackSeconds = nil,
		attackerSource = sourceSummary,
		inflictorSource = sourceSummary,
		deathTransition = request.deathTransition,
		deadEntry = request.deadEntry,
	}
	table.freeze(summary)
	local prepared = table.freeze({})
	local receipt = table.freeze({})
	local witness = {
		source = sourceCapability.source,
		sourceSummary = sourceSummary,
		sourceCapability = sourceCapability,
		stageReceipt = sourceCapability.stageReceipt,
		assignment = assignment,
		outerPrepared = request.outerCapability.preparedHandle,
		outerCapability = request.outerCapability,
	}
	table.freeze(witness)
	local receiptCapability = {
		receipt = receipt,
		status = "Pending",
		mode = "MoverPushed",
		summary = summary,
		player = assignment.player,
		record = record,
		lifeBinding = sourceCapability.lifeBinding,
		baseSpawnReserved = record.spawnReserved,
		baseState = assignment.baseState,
		nextState = request.nextState,
		prospectiveState = assignment.nextState,
		deathTrajectoryBase = sourceSummary.victimBody.position,
		nextEntityTrajectoryBase = assignment.nextEntityTrajectoryBase,
		nextEntityTrajectoryDelta = assignment.nextEntityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = request.nextEntityAngularTrajectoryBase,
		deadState = request.deadState,
		deathTransition = request.deathTransition,
		firstDeadStepPhase = request.deadEntry.firstStepPhase,
		attackerSource = sourceCapability.source,
		attackerSourceSummary = sourceSummary,
		inflictorSource = sourceCapability.source,
		inflictorSourceSummary = sourceSummary,
		moverWitness = witness,
		outerBatchReceipt = nil,
		outerBatchIndex = nil,
	}
	return {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		batchOwner = nil,
		mode = "MoverPushed",
		player = assignment.player,
		record = record,
		lifeBinding = sourceCapability.lifeBinding,
		lifeSummary = lifeSummary,
		baseState = assignment.baseState,
		baseStateSnapshot = request.baseStateSnapshot,
		nextState = request.nextState,
		nextStateSnapshot = request.nextStateSnapshot,
		prospectiveState = assignment.nextState,
		prospectiveStateSnapshot = request.prospectiveStateSnapshot,
		deathTrajectoryBase = sourceSummary.victimBody.position,
		baseEntityTrajectoryBase = assignment.baseEntityTrajectoryBase,
		baseEntityTrajectoryDelta = assignment.baseEntityTrajectoryDelta,
		baseEntityAngularTrajectoryBase = assignment.baseEntityAngularTrajectoryBase,
		nextEntityTrajectoryBase = assignment.nextEntityTrajectoryBase,
		nextEntityTrajectoryDelta = assignment.nextEntityTrajectoryDelta,
		nextEntityAngularTrajectoryBase = request.nextEntityAngularTrajectoryBase,
		baseEntityGenericAngles = assignment.baseEntityGenericAngles,
		basePlayerStateViewAngles = assignment.basePlayerStateViewAngles,
		callbackEntityTrajectoryBase = sourceSummary.victimBody.position,
		callbackEntityAngularTrajectoryBase = assignment.baseEntityAngularTrajectoryBase,
		baseSpawnReserved = record.spawnReserved,
		attackerSource = sourceCapability.source,
		attackerSourceSummary = sourceSummary,
		inflictorSource = sourceCapability.source,
		inflictorSourceSummary = sourceSummary,
		moverWitness = witness,
		deathTransition = request.deathTransition,
		deadState = request.deadState,
		firstDeadStepPhase = request.deadEntry.firstStepPhase,
		summary = summary,
		receipt = receipt,
		receiptCapability = receiptCapability,
	}
end

function MovementMoverRuntime.AssembleNormalToDeadBundle(
	state: State,
	outerCapability: any,
	memberCapabilities: { any }
): any
	local operationCount = #memberCapabilities
	local entries = {}
	local recordsInOrder = {}
	local receiptsInOrder = {}
	local lethalRecords = {}
	local lethalAssignments = {}
	local applyEntries = {}
	for index = 1, operationCount do
		local member = memberCapabilities[index]
		local witness = member.moverWitness
		assert(
			witness.outerCapability == outerCapability
				and state.deathSourceCapabilities[witness.source] == witness.sourceCapability,
			"mover normal-to-dead batch requires owned members"
		)
		local entry = {
			prepared = member.prepared,
			preparedCapability = member,
			summary = member.summary,
			receipt = member.receipt,
			player = member.player,
			record = member.record,
			lifeBinding = member.lifeBinding,
			registration = member.lifeSummary.registration,
		}
		table.freeze(entry)
		entries[index] = entry
		recordsInOrder[index] = member.summary
		receiptsInOrder[index] = member.receipt
		lethalRecords[member.record] = true
		lethalAssignments[member.record] = witness.assignment
		local applyEntry = {
			member = member,
			sourceCapability = witness.sourceCapability,
		}
		table.freeze(applyEntry)
		applyEntries[index] = applyEntry
	end
	table.freeze(entries)
	table.freeze(recordsInOrder)
	table.freeze(receiptsInOrder)
	table.freeze(lethalRecords)
	table.freeze(lethalAssignments)
	table.freeze(applyEntries)
	local summary = {
		operationCount = operationCount,
		records = recordsInOrder,
	}
	table.freeze(summary)
	local prepared = table.freeze({})
	local receipt = table.freeze({})
	local receiptCapability = {
		receipt = receipt,
		status = "Pending",
		summary = summary,
		receipts = receiptsInOrder,
		entries = entries,
	}
	local batchCapability = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		outerMoverOwner = outerCapability.preparedHandle,
		entries = entries,
		summary = summary,
		receipts = receiptsInOrder,
		receipt = receipt,
		receiptCapability = receiptCapability,
	}
	local dependency = {
		operationCount = operationCount,
		batch = prepared,
		batchSummary = summary,
		batchReceipt = receipt,
		memberReceipts = receiptsInOrder,
	}
	table.freeze(dependency)
	for index = 1, operationCount do
		local member = memberCapabilities[index]
		member.batchOwner = prepared
		member.receiptCapability.outerBatchReceipt = receipt
		member.receiptCapability.outerBatchIndex = index
	end
	table.freeze(memberCapabilities)
	return {
		memberCapabilities = memberCapabilities,
		batchCapability = batchCapability,
		dependency = dependency,
		lethalRecords = lethalRecords,
		lethalAssignments = lethalAssignments,
		applyEntries = applyEntries,
	}
end

function MovementMoverRuntime.NextDeathSourceCallbackOrder(state: State, session: any, maximumOrder: number): number
	assert(
		state.activeDeathSourceSession == session
			and session.status == "Preparing"
			and session.nextCallbackTraversalOrder < maximumOrder,
		"stale mover death-source callback session"
	)
	session.nextCallbackTraversalOrder += 1
	return session.nextCallbackTraversalOrder
end

function MovementMoverRuntime.PrepareDeathSourceSession(state: State, session: any, prepared: unknown)
	assert(
		state.activeDeathSourceSession == session and session.status == "Preparing" and session.preparedHandle == nil,
		"stale mover death-source session at prepare"
	)
	table.freeze(session.sources)
	session.preparedHandle = prepared
	session.status = "Prepared"
end

function MovementMoverRuntime.RetireDeathSourceSession(state: State, session: any?)
	if not session or session.status == "Retired" then
		return
	end
	for _, capability in session.sources do
		capability.status = "Retired"
		capability.stageReceipt = nil
	end
	session.status = "Retired"
	if state.activeDeathSourceSession == session then
		state.activeDeathSourceSession = nil
	end
end

return table.freeze(MovementMoverRuntime)
