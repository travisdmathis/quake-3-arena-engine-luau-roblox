--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only projectile entity identity translated from:
  code/game/g_utils.c (G_Spawn, G_FreeEntity, world entity slots)
  code/game/g_missile.c (missile spawn, bounce, impact, fuse, no-impact)
  code/game/g_main.c (source-ordered entities and freeAfterEvent lifetime)

This live identity/lifecycle owner composes each projectile with an exact world
slot and generation-bound Dispatcher binding. CombatService owns collision,
damage, presentation, and publication, but its dynamic handler must resolve the
same frame, source, registration, binding, and Combat mirror before acting. A
projectile source proves only the exact missile inflictor entity and trajectory
base. It never proves the attacker's current player trajectory base; that is
resolved separately at damage time, including when a projectile outlives its
firing life.

Before one-way dynamic activation, spawn and release retain their isolated
EntitySlot-only probe compatibility. After activation, they compose exact
EntitySlot Retained/Released outcomes with dispatcher Projectile Bind/Unbind
outcomes and the projectile root. CommitPrepared performs two complete
preflight passes, applies EntitySlot, then the dispatcher, then immediately
enters a private assignment-only local apply. Bounce and Event transitions
retain the exact slot and dynamic binding without opening either transaction.

After activation, every mutation requires the exact opaque OPEN frame minted
from the Movement/Mover clock. Exact committed-current frames remain accepted
only by the pre-activation compatibility probes. Callers cannot author or
fast-forward level milliseconds. ServerMain's dynamic suffix scheduler now
runs Projectile Missile/Event generations in numeric EntitySlot order.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "ProjectileEntityService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local combatRoot = sharedRoot:WaitForChild("combat")
local simulationRoot = sharedRoot:WaitForChild("simulation")
local ProjectileEntityLifecycleRules = require(combatRoot:WaitForChild("ProjectileEntityLifecycleRules"))
local ProjectileTrajectory = require(combatRoot:WaitForChild("ProjectileTrajectory"))
local EntitySourceOrderRules = require(simulationRoot:WaitForChild("EntitySourceOrderRules"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)

local ProjectileEntityService = {}

export type ProjectileSource = {}
export type PreparedMutation = {}
export type DeathInflictor = {}

export type SourceSummary = {
	read owner: Player,
	read ownerUserId: number,
	read ownerRegistration: EntitySlotService.Registration,
	read registration: EntitySlotService.Registration,
	read lease: EntitySourceOrderRules.Lease,
	read bodyId: string,
	read sourceOrder: number,
	read generation: number,
	read shotId: string,
	read phase: "Missile" | "Event",
	read lifecycle: ProjectileEntityLifecycleRules.State,
	read trajectoryState: ProjectileTrajectory.State,
	read trajectoryBase: Vector3,
	read dynamicBinding: EntityFrameDispatcherService.DynamicBinding?,
	read sourceRevision: number,
}

export type DeathInflictorSummary = {
	read source: ProjectileSource,
	read sourceSummary: SourceSummary,
	read registration: EntitySlotService.Registration,
	read lease: EntitySourceOrderRules.Lease,
	read dynamicBinding: EntityFrameDispatcherService.DynamicBinding?,
	read shotId: string,
	read sourceRevision: number,
	read phase: "Missile",
	read trajectoryBase: Vector3,
}

export type DeathInflictorAdapter = {
	read Capture: (sourceValue: unknown) -> (DeathInflictor?, DeathInflictorSummary?, string?),
	read Validate: (inflictorValue: unknown, summaryValue: unknown) -> (boolean, string?),
}

export type MutationKind =
	"Spawn"
	| "Bounce"
	| "Impact"
	| "Fuse"
	| "NoImpact"
	| "EventExpired"
	| "OwnerDisconnected"
	| "MatchCleanup"

export type ApplyReceipt = {
	read kind: MutationKind,
	read source: ProjectileSource,
	read summary: SourceSummary?,
	read lifecycle: ProjectileEntityLifecycleRules.State,
	read authorityRevision: number,
}

export type DebugSnapshot = {
	read revision: number,
	read levelTimeMilliseconds: number,
	read count: number,
	read activePrepared: boolean,
	read dynamicBindingActivated: boolean,
	read dynamicBindingCount: number,
	read sourceOrders: { number },
}

export type SpawnRequest = {
	owner: Player,
	shotId: string,
	trajectoryState: ProjectileTrajectory.State,
	frame: AuthoritativeFrameService.Frame,
}

export type TrajectoryTransitionRequest = {
	source: ProjectileSource,
	trajectoryState: ProjectileTrajectory.State,
	frame: AuthoritativeFrameService.Frame,
}

export type ReleaseRequest = {
	source: ProjectileSource,
	frame: AuthoritativeFrameService.Frame,
}

export type AdministrativeReleaseRequest = {
	source: ProjectileSource,
	frame: AuthoritativeFrameService.Frame,
	reason: ProjectileEntityLifecycleRules.AdministrativeReleaseReason,
}

type SourceStatus = "Pending" | "Current" | "Released" | "Aborted"
type ReleasePreparationKind = "NoImpact" | "EventExpired" | "AdministrativeRelease"

type SourceCapability = {
	source: ProjectileSource,
	lineage: {},
	status: SourceStatus,
	record: ProjectileRecord?,
}

type DeathInflictorCapability = {
	inflictor: DeathInflictor,
	summary: DeathInflictorSummary,
	source: ProjectileSource,
	sourceCapability: SourceCapability,
	record: ProjectileRecord,
	sourceSummary: SourceSummary,
}

type ProjectileRecord = {
	source: ProjectileSource,
	lineage: {},
	owner: Player,
	ownerRegistration: EntitySlotService.Registration,
	registration: EntitySlotService.Registration,
	lease: EntitySourceOrderRules.Lease,
	shotId: string,
	lifecycle: ProjectileEntityLifecycleRules.State,
	dynamicBinding: EntityFrameDispatcherService.DynamicBinding?,
	summary: SourceSummary,
}

type Authority = {
	revision: number,
	levelTimeMilliseconds: number,
	order: { ProjectileRecord },
	bySource: { [ProjectileSource]: ProjectileRecord },
	byShotId: { [string]: ProjectileRecord },
	byRegistration: { [EntitySlotService.Registration]: ProjectileRecord },
}

type PreparedStatus = "Prepared" | "Applied" | "Aborted"

type PreparedCapability = {
	prepared: PreparedMutation,
	status: PreparedStatus,
	applyValidated: boolean,
	kind: MutationKind,
	baseAuthority: Authority,
	nextAuthority: Authority,
	source: ProjectileSource,
	sourceCapability: SourceCapability,
	baseRecord: ProjectileRecord?,
	nextRecord: ProjectileRecord?,
	nextLifecycle: ProjectileEntityLifecycleRules.State,
	receipt: ApplyReceipt,
	entitySlotToken: EntitySlotService.TransactionToken?,
	entitySlotPrepared: EntitySlotService.PreparedCommit?,
	entitySlotSummary: EntitySlotService.PreparedCommitSummary?,
	entitySlotReceipt: EntitySlotService.CommitReceipt?,
	entitySlotExpectedStatus: "Retained" | "Released"?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary?,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt?,
	dispatcherOutcome: EntityFrameDispatcherService.DynamicOutcome?,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
}

local MAXIMUM_AUTHORITY_REVISION = 9_007_199_254_740_991
local MAXIMUM_SHOT_ID_LENGTH = 128
local DYNAMIC_DECLARED_KIND = "Projectile"
local SPAWN_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	owner = true,
	shotId = true,
	trajectoryState = true,
	frame = true,
})
local TRAJECTORY_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	source = true,
	trajectoryState = true,
	frame = true,
})
local RELEASE_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	source = true,
	frame = true,
})
local ADMINISTRATIVE_RELEASE_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	source = true,
	frame = true,
	reason = true,
})

local emptyOrder: { ProjectileRecord } = {}
local emptyBySource: { [ProjectileSource]: ProjectileRecord } = {}
local emptyByShotId: { [string]: ProjectileRecord } = {}
local emptyByRegistration: { [EntitySlotService.Registration]: ProjectileRecord } = {}
table.freeze(emptyOrder)
table.freeze(emptyBySource)
table.freeze(emptyByShotId)
table.freeze(emptyByRegistration)

local authority: Authority = table.freeze({
	revision = 0,
	levelTimeMilliseconds = 0,
	order = emptyOrder,
	bySource = emptyBySource,
	byShotId = emptyByShotId,
	byRegistration = emptyByRegistration,
})
local activePrepared: PreparedMutation? = nil
local dynamicBindingActivated = false
local dynamicHandler: EntityFrameDispatcherService.DynamicHandler? = nil
local sourceCapabilities: { [ProjectileSource]: SourceCapability } = setmetatable({}, { __mode = "k" })
local preparedCapabilities: { [PreparedMutation]: PreparedCapability } = setmetatable({}, { __mode = "k" })
local deathInflictorCapabilities: { [DeathInflictor]: DeathInflictorCapability } = setmetatable({}, { __mode = "k" })

local function hasExactRawKeys(value: unknown, allowed: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
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

local function currentFrameTime(
	frameValue: unknown
): (AuthoritativeFrameService.Frame?, AuthoritativeFrameService.Summary?, number?)
	if type(frameValue) ~= "table" then
		return nil, nil, nil
	end
	if
		dynamicBindingActivated
		and (not EntityFrameDispatcherService.IsStarted() or EntityFrameDispatcherService.IsFaulted())
	then
		return nil, nil, nil
	end
	local frame = frameValue :: AuthoritativeFrameService.Frame
	local summary: AuthoritativeFrameService.Summary?
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	if dynamicBindingActivated then
		if openFrame == nil or frame ~= openFrame then
			return nil, nil, nil
		end
		summary = AuthoritativeFrameService.InspectFrame(openFrame)
	elseif openFrame ~= nil then
		-- Once a newer frame is open, the previously committed frame is no
		-- longer a legal mutation clock. Live gameplay must bind the exact OPEN
		-- witness; the committed-current compatibility seam exists only between
		-- frames for isolated trusted probes.
		if frame ~= openFrame then
			return nil, nil, nil
		end
		summary = AuthoritativeFrameService.InspectFrame(openFrame)
	else
		local currentFrame = AuthoritativeFrameService.GetCurrentFrame()
		if currentFrame == nil or frame ~= currentFrame then
			return nil, nil, nil
		end
		summary = AuthoritativeFrameService.InspectCurrentFrame(frame)
	end
	if not summary then
		return nil, nil, nil
	end
	local levelTimeMilliseconds = summary.currentTimeMilliseconds
	if
		levelTimeMilliseconds < authority.levelTimeMilliseconds
		or levelTimeMilliseconds > ProjectileEntityLifecycleRules.MaximumLevelTimeMilliseconds
	then
		return nil, nil, nil
	end
	local entitySlotSnapshot = EntitySlotService.GetDebugSnapshot()
	if not entitySlotSnapshot.started or levelTimeMilliseconds < entitySlotSnapshot.levelTimeMilliseconds then
		return nil, nil, nil
	end
	return frame, summary, levelTimeMilliseconds
end

local function isShotId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_SHOT_ID_LENGTH
		and string.match(value, "^[%w_:%-%.]+$") ~= nil
end

local function canonicalTrajectoryBinding(
	trajectoryStateValue: unknown
): (ProjectileEntityLifecycleRules.TrajectoryBinding?, string?)
	if type(trajectoryStateValue) ~= "table" or not table.isfrozen(trajectoryStateValue :: table) then
		return nil, "projectile-trajectory-state-not-frozen"
	end
	local trajectoryState = trajectoryStateValue :: ProjectileTrajectory.State
	return ProjectileEntityLifecycleRules.BindTrajectory(trajectoryState, trajectoryState.base)
end

local function currentWorldRegistration(record: ProjectileRecord): boolean
	return EntitySlotService.GetWorldRegistrationBySourceOrder(record.registration.sourceOrder) == record.registration
		and EntitySlotService.GetWorldRegistrationByBodyId(record.registration.bodyId) == record.registration
		and EntitySlotService.GetWorldLease(record.registration) == record.lease
end

local function isOpaqueDynamicBinding(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value) == nil
		and table.isfrozen(value :: table)
		and next(value :: { [unknown]: unknown }) == nil
end

local function recordHasExpectedDynamicBinding(record: ProjectileRecord): boolean
	local binding = record.dynamicBinding
	return record.summary.dynamicBinding == binding
		and (if dynamicBindingActivated then binding ~= nil and isOpaqueDynamicBinding(binding) else binding == nil)
end

local function makeSourceSummary(recordData: {
	owner: Player,
	ownerRegistration: EntitySlotService.Registration,
	registration: EntitySlotService.Registration,
	lease: EntitySourceOrderRules.Lease,
	shotId: string,
	lifecycle: ProjectileEntityLifecycleRules.State,
	dynamicBinding: EntityFrameDispatcherService.DynamicBinding?,
}): SourceSummary
	local lifecycle = recordData.lifecycle
	assert(
		lifecycle.phase ~= ProjectileEntityLifecycleRules.Phase.Released,
		"released projectile cannot produce a current source summary"
	)
	local trajectory = lifecycle.trajectory
	local summary: SourceSummary = {
		owner = recordData.owner,
		ownerUserId = recordData.owner.UserId,
		ownerRegistration = recordData.ownerRegistration,
		registration = recordData.registration,
		lease = recordData.lease,
		bodyId = recordData.registration.bodyId,
		sourceOrder = recordData.registration.sourceOrder,
		generation = recordData.registration.generation,
		shotId = recordData.shotId,
		phase = lifecycle.phase,
		lifecycle = lifecycle,
		trajectoryState = trajectory.state,
		-- This is exact missile-inflictor data. Never reuse it as attacker base.
		trajectoryBase = trajectory.base,
		-- A dynamic handler must compare its callback binding to this exact
		-- generation-bound capability before consuming the source summary.
		dynamicBinding = recordData.dynamicBinding,
		sourceRevision = lifecycle.revision,
	}
	table.freeze(summary)
	return summary
end

local function makeRecord(
	source: ProjectileSource,
	lineage: {},
	owner: Player,
	ownerRegistration: EntitySlotService.Registration,
	registration: EntitySlotService.Registration,
	lease: EntitySourceOrderRules.Lease,
	shotId: string,
	lifecycle: ProjectileEntityLifecycleRules.State,
	dynamicBinding: EntityFrameDispatcherService.DynamicBinding?
): ProjectileRecord
	local summary = makeSourceSummary({
		owner = owner,
		ownerRegistration = ownerRegistration,
		registration = registration,
		lease = lease,
		shotId = shotId,
		lifecycle = lifecycle,
		dynamicBinding = dynamicBinding,
	})
	local record: ProjectileRecord = {
		source = source,
		lineage = lineage,
		owner = owner,
		ownerRegistration = ownerRegistration,
		registration = registration,
		lease = lease,
		shotId = shotId,
		lifecycle = lifecycle,
		dynamicBinding = dynamicBinding,
		summary = summary,
	}
	table.freeze(record)
	return record
end

local function nextAuthorityWith(
	base: Authority,
	baseRecord: ProjectileRecord?,
	nextRecord: ProjectileRecord?,
	levelTimeMilliseconds: number
): Authority
	assert(base.revision < MAXIMUM_AUTHORITY_REVISION, "projectile authority revision exhausted")
	assert(levelTimeMilliseconds >= base.levelTimeMilliseconds, "projectile authority level time regressed")
	local order: { ProjectileRecord } = {}
	local bySource: { [ProjectileSource]: ProjectileRecord } = {}
	local byShotId: { [string]: ProjectileRecord } = {}
	local byRegistration: { [EntitySlotService.Registration]: ProjectileRecord } = {}
	local replaced = baseRecord == nil
	for _, record in base.order do
		local selected = record
		if record == baseRecord then
			replaced = true
			selected = nextRecord
		end
		if selected then
			assert(recordHasExpectedDynamicBinding(selected), "projectile record has an invalid dynamic binding")
			assert(bySource[selected.source] == nil, "duplicate projectile source")
			assert(byShotId[selected.shotId] == nil, "duplicate projectile shot identity")
			assert(byRegistration[selected.registration] == nil, "duplicate projectile registration")
			bySource[selected.source] = selected
			byShotId[selected.shotId] = selected
			byRegistration[selected.registration] = selected
			table.insert(order, selected)
		end
	end
	assert(replaced, "projectile authority replacement record missing")
	if baseRecord == nil and nextRecord then
		assert(recordHasExpectedDynamicBinding(nextRecord), "spawn projectile record has an invalid dynamic binding")
		assert(bySource[nextRecord.source] == nil, "duplicate projectile source")
		assert(byShotId[nextRecord.shotId] == nil, "duplicate projectile shot identity")
		assert(byRegistration[nextRecord.registration] == nil, "duplicate projectile registration")
		bySource[nextRecord.source] = nextRecord
		byShotId[nextRecord.shotId] = nextRecord
		byRegistration[nextRecord.registration] = nextRecord
		table.insert(order, nextRecord)
	end
	table.sort(order, function(left: ProjectileRecord, right: ProjectileRecord): boolean
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	local previousSourceOrder = 0
	for _, record in order do
		assert(
			record.registration.sourceOrder > previousSourceOrder,
			"projectile authority source order is not strictly increasing"
		)
		previousSourceOrder = record.registration.sourceOrder
	end
	table.freeze(order)
	table.freeze(bySource)
	table.freeze(byShotId)
	table.freeze(byRegistration)
	return table.freeze({
		revision = base.revision + 1,
		levelTimeMilliseconds = levelTimeMilliseconds,
		order = order,
		bySource = bySource,
		byShotId = byShotId,
		byRegistration = byRegistration,
	})
end

local function prepareCapability(
	kind: MutationKind,
	frame: AuthoritativeFrameService.Frame,
	frameSummary: AuthoritativeFrameService.Summary,
	baseRecord: ProjectileRecord?,
	nextRecord: ProjectileRecord?,
	nextLifecycle: ProjectileEntityLifecycleRules.State,
	source: ProjectileSource,
	sourceCapability: SourceCapability,
	entitySlotToken: EntitySlotService.TransactionToken?,
	entitySlotPrepared: EntitySlotService.PreparedCommit?,
	entitySlotSummary: EntitySlotService.PreparedCommitSummary?,
	entitySlotReceipt: EntitySlotService.CommitReceipt?,
	entitySlotExpectedStatus: "Retained" | "Released"?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary?,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt?,
	dispatcherOutcome: EntityFrameDispatcherService.DynamicOutcome?
): PreparedMutation
	local baseAuthority = authority
	local nextAuthority = nextAuthorityWith(baseAuthority, baseRecord, nextRecord, nextLifecycle.levelTimeMilliseconds)
	local prepared: PreparedMutation = table.freeze({})
	local receipt: ApplyReceipt = table.freeze({
		kind = kind,
		source = source,
		summary = if nextRecord then nextRecord.summary else nil,
		lifecycle = nextLifecycle,
		authorityRevision = nextAuthority.revision,
	})
	preparedCapabilities[prepared] = {
		prepared = prepared,
		status = "Prepared",
		applyValidated = false,
		kind = kind,
		baseAuthority = baseAuthority,
		nextAuthority = nextAuthority,
		source = source,
		sourceCapability = sourceCapability,
		baseRecord = baseRecord,
		nextRecord = nextRecord,
		nextLifecycle = nextLifecycle,
		receipt = receipt,
		entitySlotToken = entitySlotToken,
		entitySlotPrepared = entitySlotPrepared,
		entitySlotSummary = entitySlotSummary,
		entitySlotReceipt = entitySlotReceipt,
		entitySlotExpectedStatus = entitySlotExpectedStatus,
		dispatcherPrepared = dispatcherPrepared,
		dispatcherSummary = dispatcherSummary,
		dispatcherReceipt = dispatcherReceipt,
		dispatcherOutcome = dispatcherOutcome,
		frame = frame,
		frameSummary = frameSummary,
	}
	activePrepared = prepared
	return prepared
end

local function abortEntitySlotToken(token: EntitySlotService.TransactionToken?): boolean
	if not token then
		return true
	end
	local aborted = select(1, EntitySlotService.Abort(token))
	return aborted
end

local function prepareEntitySlotOutcome(
	token: EntitySlotService.TransactionToken,
	registration: EntitySlotService.Registration,
	lease: EntitySourceOrderRules.Lease,
	expectedStatus: "Retained" | "Released"
): (
	EntitySlotService.PreparedCommit?,
	EntitySlotService.PreparedCommitSummary?,
	EntitySlotService.CommitReceipt?,
	string?
)
	local prepared, prepareError = EntitySlotService.Prepare(token)
	if not prepared then
		return nil, nil, nil, prepareError
	end
	local summary = EntitySlotService.InspectPreparedCommitSummary(prepared)
	local receipt = EntitySlotService.InspectPreparedCommitReceipt(prepared)
	if not summary or not receipt then
		return nil, nil, nil, "projectile-entity-slot-prepared-proof-unavailable"
	end
	local valid, validationError = EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
		prepared,
		summary,
		registration,
		lease,
		expectedStatus
	)
	if not valid then
		return nil, nil, nil, validationError
	end
	return prepared, summary, receipt, nil
end

local function dispatcherOutcomeMatches(
	outcome: EntityFrameDispatcherService.DynamicOutcome,
	expectedKind: "Bound" | "Unbound",
	registration: EntitySlotService.Registration,
	expectedBinding: EntityFrameDispatcherService.DynamicBinding?
): boolean
	return table.isfrozen(outcome)
		and outcome.kind == expectedKind
		and outcome.registration == registration
		and outcome.declaredKind == DYNAMIC_DECLARED_KIND
		and isOpaqueDynamicBinding(outcome.binding)
		and (expectedBinding == nil or outcome.binding == expectedBinding)
end

local function prepareDispatcherOutcome(
	entityPrepared: EntitySlotService.PreparedCommit,
	entitySummary: EntitySlotService.PreparedCommitSummary,
	registration: EntitySlotService.Registration,
	expectedKind: "Bound" | "Unbound",
	expectedBinding: EntityFrameDispatcherService.DynamicBinding?
): (
	EntityFrameDispatcherService.PreparedDynamicBatch?,
	EntityFrameDispatcherService.PreparedDynamicBatchSummary?,
	EntityFrameDispatcherService.DynamicBatchReceipt?,
	EntityFrameDispatcherService.DynamicOutcome?,
	string?
)
	local handler = dynamicHandler
	if not dynamicBindingActivated or not handler then
		return nil, nil, nil, nil, "projectile-dynamic-binding-not-activated"
	end
	local operations: { EntityFrameDispatcherService.DynamicOperation }
	if expectedKind == "Bound" then
		if expectedBinding ~= nil then
			return nil, nil, nil, nil, "invalid-projectile-dynamic-bind-expectation"
		end
		operations = {
			{
				kind = "Bind",
				registration = registration,
				declaredKind = DYNAMIC_DECLARED_KIND,
				handler = handler,
			},
		}
	else
		if expectedBinding == nil or not isOpaqueDynamicBinding(expectedBinding) then
			return nil, nil, nil, nil, "invalid-projectile-dynamic-unbind-expectation"
		end
		operations = {
			{
				kind = "Unbind",
				registration = registration,
				binding = expectedBinding,
			},
		}
	end
	local prepared, summary, prepareError =
		EntityFrameDispatcherService.PrepareDynamicBatch(entityPrepared, entitySummary, operations)
	if not prepared or not summary then
		return nil, nil, nil, nil, prepareError
	end
	local inspectedSummary = EntityFrameDispatcherService.InspectPreparedDynamicBatch(prepared)
	local receipt = EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(prepared)
	local outcome = summary.outcomes[1]
	if
		inspectedSummary ~= summary
		or not receipt
		or #summary.outcomes ~= 1
		or not outcome
		or not dispatcherOutcomeMatches(outcome, expectedKind, registration, expectedBinding)
	then
		EntityFrameDispatcherService.AbortPreparedDynamicBatch(prepared)
		return nil, nil, nil, nil, "projectile-dispatcher-prepared-proof-invalid"
	end
	return prepared, summary, receipt, outcome, nil
end

local function abortPreparedDependencies(
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	entitySlotToken: EntitySlotService.TransactionToken?
): boolean
	if dispatcherPrepared then
		local dispatcherAborted = EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared)
		if not dispatcherAborted and not EntityFrameDispatcherService.IsFaulted() then
			return false
		end
	end
	return abortEntitySlotToken(entitySlotToken)
end

local function currentPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-prepared-projectile-mutation"
	end
	local prepared = preparedValue :: PreparedMutation
	local capability = preparedCapabilities[prepared]
	if
		not capability
		or capability.prepared ~= prepared
		or capability.status ~= "Prepared"
		or activePrepared ~= prepared
	then
		return nil, "invalid-prepared-projectile-mutation"
	end
	return capability, nil
end

local function preparedCurrentError(
	prepared: PreparedMutation,
	capability: PreparedCapability,
	validateExternal: boolean
): string?
	if
		activePrepared ~= prepared
		or capability.status ~= "Prepared"
		or authority ~= capability.baseAuthority
		or capability.baseAuthority.revision >= capability.nextAuthority.revision
	then
		return "stale-prepared-projectile-mutation"
	end
	local sourceCapability = sourceCapabilities[capability.source]
	if sourceCapability ~= capability.sourceCapability then
		return "stale-projectile-source-capability"
	end
	if capability.kind == "Spawn" then
		local nextRecord = capability.nextRecord
		if
			sourceCapability.status ~= "Pending"
			or sourceCapability.record ~= nil
			or capability.baseRecord ~= nil
			or not nextRecord
			or capability.baseAuthority.bySource[capability.source] ~= nil
			or not recordHasExpectedDynamicBinding(nextRecord)
		then
			return "stale-prepared-projectile-spawn"
		end
		if
			capability.baseAuthority.byShotId[nextRecord.shotId] ~= nil
			or capability.baseAuthority.byRegistration[nextRecord.registration] ~= nil
		then
			return "stale-prepared-projectile-spawn"
		end
	else
		local baseRecord = capability.baseRecord
		if
			not baseRecord
			or sourceCapability.status ~= "Current"
			or sourceCapability.record ~= baseRecord
			or capability.baseAuthority.bySource[capability.source] ~= baseRecord
			or capability.baseAuthority.byShotId[baseRecord.shotId] ~= baseRecord
			or capability.baseAuthority.byRegistration[baseRecord.registration] ~= baseRecord
			or not recordHasExpectedDynamicBinding(baseRecord)
		then
			return "stale-prepared-projectile-source"
		end
	end
	local nextRecord = capability.nextRecord
	if nextRecord then
		if
			capability.nextAuthority.bySource[capability.source] ~= nextRecord
			or capability.nextAuthority.byShotId[nextRecord.shotId] ~= nextRecord
			or capability.nextAuthority.byRegistration[nextRecord.registration] ~= nextRecord
			or not recordHasExpectedDynamicBinding(nextRecord)
		then
			return "invalid-prepared-projectile-next-authority"
		end
		local baseRecord = capability.baseRecord
		if baseRecord and nextRecord.dynamicBinding ~= baseRecord.dynamicBinding then
			return "projectile-transition-replaced-dynamic-binding"
		end
	else
		local baseRecord = capability.baseRecord
		if
			not baseRecord
			or capability.nextAuthority.bySource[capability.source] ~= nil
			or capability.nextAuthority.byShotId[baseRecord.shotId] ~= nil
			or capability.nextAuthority.byRegistration[baseRecord.registration] ~= nil
		then
			return "invalid-prepared-projectile-next-authority"
		end
	end
	local dispatcherPrepared = capability.dispatcherPrepared
	local dispatcherSummary = capability.dispatcherSummary
	local dispatcherReceipt = capability.dispatcherReceipt
	local dispatcherOutcome = capability.dispatcherOutcome
	local expectsDispatcher = dynamicBindingActivated and capability.entitySlotPrepared ~= nil
	if
		expectsDispatcher
		~= (
			dispatcherPrepared ~= nil
			and dispatcherSummary ~= nil
			and dispatcherReceipt ~= nil
			and dispatcherOutcome ~= nil
		)
	then
		return "incomplete-projectile-dispatcher-dependency"
	end
	if dispatcherPrepared and dispatcherSummary and dispatcherReceipt and dispatcherOutcome then
		if dispatcherSummary.outcomes[1] ~= dispatcherOutcome or #dispatcherSummary.outcomes ~= 1 then
			return "stale-projectile-dispatcher-outcome"
		end
		local baseRecord = capability.baseRecord
		if capability.nextRecord and not baseRecord then
			if
				not dispatcherOutcomeMatches(dispatcherOutcome, "Bound", capability.nextRecord.registration, nil)
				or capability.nextRecord.dynamicBinding ~= dispatcherOutcome.binding
			then
				return "stale-projectile-dispatcher-bind-outcome"
			end
		elseif not capability.nextRecord and baseRecord then
			if
				not dispatcherOutcomeMatches(
					dispatcherOutcome,
					"Unbound",
					baseRecord.registration,
					baseRecord.dynamicBinding
				)
			then
				return "stale-projectile-dispatcher-unbind-outcome"
			end
		else
			return "invalid-projectile-dispatcher-transition"
		end
	end
	if not validateExternal then
		return nil
	end
	if
		dynamicBindingActivated
		and (not EntityFrameDispatcherService.IsStarted() or EntityFrameDispatcherService.IsFaulted())
	then
		return "stale-projectile-dynamic-dispatcher"
	end
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local activeFrame = if dynamicBindingActivated
		then openFrame
		else openFrame or AuthoritativeFrameService.GetCurrentFrame()
	if
		activeFrame ~= capability.frame
		or not AuthoritativeFrameService.ValidateFrameDependency(capability.frame, capability.frameSummary)
		or capability.nextLifecycle.levelTimeMilliseconds ~= capability.frameSummary.currentTimeMilliseconds
	then
		return "stale-projectile-authoritative-frame"
	end
	local entitySlotPrepared = capability.entitySlotPrepared
	if entitySlotPrepared then
		local summary = capability.entitySlotSummary
		local receipt = capability.entitySlotReceipt
		local expectedStatus = capability.entitySlotExpectedStatus
		local record = capability.nextRecord or capability.baseRecord
		if not summary or not receipt or not expectedStatus or not record then
			return "incomplete-projectile-entity-slot-dependency"
		end
		if EntitySlotService.InspectPreparedCommitReceipt(entitySlotPrepared) ~= receipt then
			return "stale-projectile-entity-slot-receipt"
		end
		local valid, validationError = EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
			entitySlotPrepared,
			summary,
			record.registration,
			record.lease,
			expectedStatus
		)
		if not valid then
			return validationError or "stale-projectile-entity-slot-outcome"
		end
	else
		local baseRecord = capability.baseRecord
		if not baseRecord or not currentWorldRegistration(baseRecord) then
			return "stale-projectile-world-registration"
		end
	end
	if dispatcherPrepared then
		if
			not dispatcherSummary
			or not dispatcherReceipt
			or not EntityFrameDispatcherService.ValidatePreparedDynamicBatchDependency(
				dispatcherPrepared,
				dispatcherSummary
			)
			or EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared)
				~= dispatcherReceipt
		then
			return "stale-projectile-dispatcher-dependency"
		end
	end
	return nil
end

function ProjectileEntityService.PrepareSpawn(requestValue: unknown): (PreparedMutation?, ProjectileSource?, string?)
	if activePrepared ~= nil then
		return nil, nil, "projectile-mutation-active"
	end
	if authority.revision >= MAXIMUM_AUTHORITY_REVISION then
		return nil, nil, "projectile-authority-revision-exhausted"
	end
	if not hasExactRawKeys(requestValue, SPAWN_REQUEST_KEYS, 4) then
		return nil, nil, "invalid-projectile-spawn-request-shape"
	end
	local request = requestValue :: { [unknown]: unknown }
	local ownerValue = rawget(request, "owner")
	local shotIdValue = rawget(request, "shotId")
	local trajectoryStateValue = rawget(request, "trajectoryState")
	local frame, frameSummary, levelTimeValue = currentFrameTime(rawget(request, "frame"))
	if
		typeof(ownerValue) ~= "Instance"
		or not (ownerValue :: Instance):IsA("Player")
		or (ownerValue :: Player).Parent ~= Players
		or not isShotId(shotIdValue)
		or not frame
		or not frameSummary
		or not levelTimeValue
		or authority.byShotId[shotIdValue :: string] ~= nil
	then
		return nil, nil, "invalid-projectile-spawn-request"
	end
	local trajectory, trajectoryError = canonicalTrajectoryBinding(trajectoryStateValue)
	if not trajectory then
		return nil, nil, trajectoryError
	end
	local lifecycle, lifecycleError = ProjectileEntityLifecycleRules.Create(trajectory, levelTimeValue :: number)
	if not lifecycle then
		return nil, nil, lifecycleError
	end
	local owner = ownerValue :: Player
	local ownerRegistration = EntitySlotService.GetPlayerRegistration(owner)
	if not ownerRegistration then
		return nil, nil, "projectile-owner-registration-unavailable"
	end
	local token, beginError = EntitySlotService.Begin(levelTimeValue :: number)
	if not token then
		return nil, nil, beginError
	end
	local registration, allocationError = EntitySlotService.AllocateWorld(token, "missile")
	if not registration then
		abortEntitySlotToken(token)
		return nil, nil, allocationError
	end
	local lease = EntitySlotService.GetWorldLease(registration, token)
	if not lease then
		abortEntitySlotToken(token)
		return nil, nil, "projectile-world-lease-unavailable"
	end
	local entityPrepared, entitySummary, entityReceipt, entityError =
		prepareEntitySlotOutcome(token, registration, lease, "Retained")
	if not entityPrepared or not entitySummary or not entityReceipt then
		abortEntitySlotToken(token)
		return nil, nil, entityError
	end
	local dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch? = nil
	local dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary? = nil
	local dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt? = nil
	local dispatcherOutcome: EntityFrameDispatcherService.DynamicOutcome? = nil
	local dynamicBinding: EntityFrameDispatcherService.DynamicBinding? = nil
	if dynamicBindingActivated then
		local dispatcherError: string?
		dispatcherPrepared, dispatcherSummary, dispatcherReceipt, dispatcherOutcome, dispatcherError =
			prepareDispatcherOutcome(entityPrepared, entitySummary, registration, "Bound", nil)
		if not dispatcherPrepared or not dispatcherSummary or not dispatcherReceipt or not dispatcherOutcome then
			abortEntitySlotToken(token)
			return nil, nil, dispatcherError
		end
		dynamicBinding = dispatcherOutcome.binding
	end
	local source: ProjectileSource = table.freeze({})
	local lineage = table.freeze({})
	local sourceCapability: SourceCapability = {
		source = source,
		lineage = lineage,
		status = "Pending",
		record = nil,
	}
	sourceCapabilities[source] = sourceCapability
	local record = makeRecord(
		source,
		lineage,
		owner,
		ownerRegistration,
		registration,
		lease,
		shotIdValue :: string,
		lifecycle,
		dynamicBinding
	)
	local prepared = prepareCapability(
		"Spawn",
		frame,
		frameSummary,
		nil,
		record,
		lifecycle,
		source,
		sourceCapability,
		token,
		entityPrepared,
		entitySummary,
		entityReceipt,
		"Retained",
		dispatcherPrepared,
		dispatcherSummary,
		dispatcherReceipt,
		dispatcherOutcome
	)
	return prepared, source, nil
end

local function prepareTrajectoryTransition(
	kind: "Bounce" | "Impact" | "Fuse",
	requestValue: unknown
): (PreparedMutation?, string?)
	if activePrepared ~= nil then
		return nil, "projectile-mutation-active"
	end
	if authority.revision >= MAXIMUM_AUTHORITY_REVISION then
		return nil, "projectile-authority-revision-exhausted"
	end
	if not hasExactRawKeys(requestValue, TRAJECTORY_REQUEST_KEYS, 3) then
		return nil, "invalid-projectile-transition-request-shape"
	end
	local request = requestValue :: { [unknown]: unknown }
	local sourceValue = rawget(request, "source")
	local trajectoryStateValue = rawget(request, "trajectoryState")
	local frame, frameSummary, levelTimeValue = currentFrameTime(rawget(request, "frame"))
	if type(sourceValue) ~= "table" or not frame or not frameSummary or not levelTimeValue then
		return nil, "invalid-projectile-transition-request"
	end
	local source = sourceValue :: ProjectileSource
	local sourceCapability = sourceCapabilities[source]
	local baseRecord = authority.bySource[source]
	if
		not sourceCapability
		or sourceCapability.status ~= "Current"
		or sourceCapability.record ~= baseRecord
		or not baseRecord
		or not currentWorldRegistration(baseRecord)
		or not recordHasExpectedDynamicBinding(baseRecord)
		or (dynamicBindingActivated and EntityFrameDispatcherService.IsFaulted())
	then
		return nil, "invalid-projectile-source"
	end
	local trajectory, trajectoryError = canonicalTrajectoryBinding(trajectoryStateValue)
	if not trajectory then
		return nil, trajectoryError
	end
	local nextLifecycle: ProjectileEntityLifecycleRules.State?
	local transitionError: string?
	if kind == "Bounce" then
		nextLifecycle, transitionError =
			ProjectileEntityLifecycleRules.Bounce(baseRecord.lifecycle, trajectory, levelTimeValue :: number)
	elseif kind == "Impact" then
		nextLifecycle, transitionError =
			ProjectileEntityLifecycleRules.Impact(baseRecord.lifecycle, trajectory, levelTimeValue :: number)
	else
		nextLifecycle, transitionError =
			ProjectileEntityLifecycleRules.Fuse(baseRecord.lifecycle, trajectory, levelTimeValue :: number)
	end
	if not nextLifecycle then
		return nil, transitionError
	end
	local nextRecord = makeRecord(
		source,
		baseRecord.lineage,
		baseRecord.owner,
		baseRecord.ownerRegistration,
		baseRecord.registration,
		baseRecord.lease,
		baseRecord.shotId,
		nextLifecycle,
		baseRecord.dynamicBinding
	)
	return prepareCapability(
		kind,
		frame,
		frameSummary,
		baseRecord,
		nextRecord,
		nextLifecycle,
		source,
		sourceCapability,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil
	),
		nil
end

function ProjectileEntityService.PrepareBounce(requestValue: unknown): (PreparedMutation?, string?)
	return prepareTrajectoryTransition("Bounce", requestValue)
end

function ProjectileEntityService.PrepareImpact(requestValue: unknown): (PreparedMutation?, string?)
	return prepareTrajectoryTransition("Impact", requestValue)
end

function ProjectileEntityService.PrepareFuse(requestValue: unknown): (PreparedMutation?, string?)
	return prepareTrajectoryTransition("Fuse", requestValue)
end

local function prepareRelease(kind: ReleasePreparationKind, requestValue: unknown): (PreparedMutation?, string?)
	if activePrepared ~= nil then
		return nil, "projectile-mutation-active"
	end
	if authority.revision >= MAXIMUM_AUTHORITY_REVISION then
		return nil, "projectile-authority-revision-exhausted"
	end
	if kind == "AdministrativeRelease" then
		if not hasExactRawKeys(requestValue, ADMINISTRATIVE_RELEASE_REQUEST_KEYS, 3) then
			return nil, "invalid-projectile-administrative-release-request-shape"
		end
	elseif not hasExactRawKeys(requestValue, RELEASE_REQUEST_KEYS, 2) then
		return nil, "invalid-projectile-release-request-shape"
	end
	local request = requestValue :: { [unknown]: unknown }
	local sourceValue = rawget(request, "source")
	local reasonValue = rawget(request, "reason")
	local frame, frameSummary, levelTimeValue = currentFrameTime(rawget(request, "frame"))
	if type(sourceValue) ~= "table" or not frame or not frameSummary or not levelTimeValue then
		return nil,
			if kind == "AdministrativeRelease"
				then "invalid-projectile-administrative-release-request"
				else "invalid-projectile-release-request"
	end
	local source = sourceValue :: ProjectileSource
	local sourceCapability = sourceCapabilities[source]
	local baseRecord = authority.bySource[source]
	if
		not sourceCapability
		or sourceCapability.status ~= "Current"
		or sourceCapability.record ~= baseRecord
		or not baseRecord
		or not currentWorldRegistration(baseRecord)
		or not recordHasExpectedDynamicBinding(baseRecord)
		or (dynamicBindingActivated and EntityFrameDispatcherService.IsFaulted())
	then
		return nil, "invalid-projectile-source"
	end
	local nextLifecycle: ProjectileEntityLifecycleRules.State?
	local lifecycleError: string?
	if kind == "NoImpact" then
		nextLifecycle, lifecycleError =
			ProjectileEntityLifecycleRules.NoImpact(baseRecord.lifecycle, levelTimeValue :: number)
	elseif kind == "EventExpired" then
		nextLifecycle, lifecycleError =
			ProjectileEntityLifecycleRules.Advance(baseRecord.lifecycle, levelTimeValue :: number)
		if nextLifecycle and nextLifecycle.phase ~= ProjectileEntityLifecycleRules.Phase.Released then
			return nil, "projectile-event-not-expired"
		end
	else
		nextLifecycle, lifecycleError = ProjectileEntityLifecycleRules.AdministrativeRelease(
			baseRecord.lifecycle,
			levelTimeValue :: number,
			reasonValue
		)
	end
	if not nextLifecycle then
		return nil, lifecycleError
	end
	local mutationKind: MutationKind = if kind == "AdministrativeRelease"
		then reasonValue :: ProjectileEntityLifecycleRules.AdministrativeReleaseReason
		else kind
	local token, beginError = EntitySlotService.Begin(levelTimeValue :: number)
	if not token then
		return nil, beginError
	end
	local released, releaseError = EntitySlotService.ReleaseWorld(token, baseRecord.registration)
	if not released then
		abortEntitySlotToken(token)
		return nil, releaseError
	end
	local entityPrepared, entitySummary, entityReceipt, entityError =
		prepareEntitySlotOutcome(token, baseRecord.registration, baseRecord.lease, "Released")
	if not entityPrepared or not entitySummary or not entityReceipt then
		abortEntitySlotToken(token)
		return nil, entityError
	end
	local dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch? = nil
	local dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary? = nil
	local dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt? = nil
	local dispatcherOutcome: EntityFrameDispatcherService.DynamicOutcome? = nil
	if dynamicBindingActivated then
		local dispatcherError: string?
		dispatcherPrepared, dispatcherSummary, dispatcherReceipt, dispatcherOutcome, dispatcherError =
			prepareDispatcherOutcome(
				entityPrepared,
				entitySummary,
				baseRecord.registration,
				"Unbound",
				baseRecord.dynamicBinding
			)
		if not dispatcherPrepared or not dispatcherSummary or not dispatcherReceipt or not dispatcherOutcome then
			abortEntitySlotToken(token)
			return nil, dispatcherError
		end
	end
	return prepareCapability(
		mutationKind,
		frame,
		frameSummary,
		baseRecord,
		nil,
		nextLifecycle,
		source,
		sourceCapability,
		token,
		entityPrepared,
		entitySummary,
		entityReceipt,
		"Released",
		dispatcherPrepared,
		dispatcherSummary,
		dispatcherReceipt,
		dispatcherOutcome
	),
		nil
end

function ProjectileEntityService.PrepareNoImpact(requestValue: unknown): (PreparedMutation?, string?)
	return prepareRelease("NoImpact", requestValue)
end

function ProjectileEntityService.PrepareEventExpired(requestValue: unknown): (PreparedMutation?, string?)
	return prepareRelease("EventExpired", requestValue)
end

function ProjectileEntityService.PrepareAdministrativeRelease(requestValue: unknown): (PreparedMutation?, string?)
	return prepareRelease("AdministrativeRelease", requestValue)
end

function ProjectileEntityService.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = currentPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local prepared = preparedValue :: PreparedMutation
	local currentError = preparedCurrentError(prepared, capability, true)
	if currentError then
		return false, currentError
	end
	if capability.entitySlotPrepared then
		local canApply, canApplyError = EntitySlotService.CanApplyPrepared(capability.entitySlotPrepared)
		if not canApply then
			return false, canApplyError
		end
	end
	if capability.dispatcherPrepared then
		local canApply, canApplyError =
			EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(capability.dispatcherPrepared)
		if not canApply then
			return false, canApplyError
		end
	end
	capability.applyValidated = true
	return true, nil
end

local function applyPreparedLocal(prepared: PreparedMutation, capability: PreparedCapability): ApplyReceipt
	assert(capability.applyValidated, "prepared projectile mutation was not validated")
	assert(
		preparedCurrentError(prepared, capability, false) == nil,
		"stale prepared projectile mutation at local apply"
	)
	authority = capability.nextAuthority
	local sourceCapability = capability.sourceCapability
	if capability.nextRecord then
		sourceCapability.status = "Current"
		sourceCapability.record = capability.nextRecord
	else
		sourceCapability.status = "Released"
		sourceCapability.record = nil
	end
	capability.status = "Applied"
	capability.applyValidated = false
	activePrepared = nil
	preparedCapabilities[prepared] = nil
	return capability.receipt
end

function ProjectileEntityService.CommitPrepared(preparedValue: unknown): (ApplyReceipt?, string?)
	local capability, capabilityError = currentPreparedCapability(preparedValue)
	if not capability then
		return nil, capabilityError
	end
	local prepared = preparedValue :: PreparedMutation
	for _preflightPass = 1, 2 do
		local canApply, canApplyError = ProjectileEntityService.CanApplyPrepared(prepared)
		if not canApply then
			ProjectileEntityService.AbortPrepared(prepared)
			return nil, canApplyError
		end
	end
	local entitySlotPrepared = capability.entitySlotPrepared
	if entitySlotPrepared then
		local entityReceipt = EntitySlotService.ApplyPrepared(entitySlotPrepared)
		assert(
			entityReceipt == capability.entitySlotReceipt,
			"EntitySlot returned a different prebuilt projectile receipt"
		)
	end
	local dispatcherPrepared = capability.dispatcherPrepared
	if dispatcherPrepared then
		local dispatcherReceipt = EntityFrameDispatcherService.ApplyPreparedDynamicBatch(dispatcherPrepared)
		assert(
			dispatcherReceipt == capability.dispatcherReceipt,
			"dispatcher returned a different prebuilt projectile receipt"
		)
	end
	-- Composite adjacency is EntitySlot -> dispatcher -> this private
	-- assignment-only owner apply. No callback, yield, validation, allocation,
	-- or external lookup is permitted after the dispatcher root swap.
	local receipt = applyPreparedLocal(prepared, capability)
	if entitySlotPrepared then
		local drained, drainError = EntitySlotService.DrainPendingPlayerReleases()
		if not drained then
			warn(drainError or "post-projectile-commit player release drain failed")
		end
	end
	return receipt, nil
end

function ProjectileEntityService.AbortPrepared(preparedValue: unknown): boolean
	local capability = select(1, currentPreparedCapability(preparedValue))
	if not capability then
		return false
	end
	local prepared = preparedValue :: PreparedMutation
	if not abortPreparedDependencies(capability.dispatcherPrepared, capability.entitySlotToken) then
		return false
	end
	if capability.kind == "Spawn" then
		capability.sourceCapability.status = "Aborted"
		capability.sourceCapability.record = nil
		sourceCapabilities[capability.source] = nil
	end
	capability.status = "Aborted"
	capability.applyValidated = false
	activePrepared = nil
	preparedCapabilities[prepared] = nil
	return true
end

function ProjectileEntityService.ActivateDynamicBinding(handlerValue: unknown): (boolean, string?)
	if dynamicBindingActivated then
		return false, "projectile-dynamic-binding-already-activated"
	end
	if
		activePrepared ~= nil
		or #authority.order ~= 0
		or next(authority.bySource) ~= nil
		or next(authority.byShotId) ~= nil
		or next(authority.byRegistration) ~= nil
	then
		return false, "projectile-dynamic-binding-requires-empty-owner"
	end
	if type(handlerValue) ~= "function" then
		return false, "invalid-projectile-dynamic-handler"
	end
	if not EntityFrameDispatcherService.IsStarted() then
		return false, "projectile-dynamic-dispatcher-not-started"
	end
	if EntityFrameDispatcherService.IsFaulted() then
		return false, "projectile-dynamic-dispatcher-faulted"
	end
	local dispatcherSnapshot = EntityFrameDispatcherService.GetDebugSnapshot()
	if
		not dispatcherSnapshot.started
		or dispatcherSnapshot.faulted
		or dispatcherSnapshot.running
		or dispatcherSnapshot.activePreparedDynamicBatch
	then
		return false, "projectile-dynamic-dispatcher-not-healthy"
	end
	dynamicHandler = handlerValue :: EntityFrameDispatcherService.DynamicHandler
	dynamicBindingActivated = true
	return true, nil
end

function ProjectileEntityService.InspectSource(sourceValue: unknown): SourceSummary?
	if type(sourceValue) ~= "table" then
		return nil
	end
	local source = sourceValue :: ProjectileSource
	local capability = sourceCapabilities[source]
	local record = authority.bySource[source]
	if
		not capability
		or capability.status ~= "Current"
		or capability.record ~= record
		or not record
		or activePrepared ~= nil
		or not currentWorldRegistration(record)
		or not recordHasExpectedDynamicBinding(record)
		or (dynamicBindingActivated and EntityFrameDispatcherService.IsFaulted())
	then
		return nil
	end
	return record.summary
end

-- Missile-only inflictor proof for g_missile.c's direct G_Damage call. The
-- exact immutable projectile record is retained privately so an Event
-- transition, bounce generation, release, or active prepared mutation makes
-- the proof fail closed without accepting a caller-authored trajectory base.
function ProjectileEntityService.CaptureDeathInflictor(
	sourceValue: unknown
): (DeathInflictor?, DeathInflictorSummary?, string?)
	local sourceSummary = ProjectileEntityService.InspectSource(sourceValue)
	if not sourceSummary then
		return nil, nil, "invalid-projectile-death-inflictor-source"
	end
	if sourceSummary.phase ~= ProjectileEntityLifecycleRules.Phase.Missile then
		return nil, nil, "projectile-death-inflictor-requires-missile"
	end
	local source = sourceValue :: ProjectileSource
	local sourceCapability = sourceCapabilities[source]
	local record = authority.bySource[source]
	if not sourceCapability or not record or sourceCapability.record ~= record or record.summary ~= sourceSummary then
		return nil, nil, "stale-projectile-death-inflictor-source"
	end
	local inflictor: DeathInflictor = table.freeze({})
	local summary: DeathInflictorSummary = {
		source = source,
		sourceSummary = sourceSummary,
		registration = sourceSummary.registration,
		lease = sourceSummary.lease,
		dynamicBinding = sourceSummary.dynamicBinding,
		shotId = sourceSummary.shotId,
		sourceRevision = sourceSummary.sourceRevision,
		phase = "Missile",
		trajectoryBase = sourceSummary.trajectoryBase,
	}
	table.freeze(summary)
	deathInflictorCapabilities[inflictor] = {
		inflictor = inflictor,
		summary = summary,
		source = source,
		sourceCapability = sourceCapability,
		record = record,
		sourceSummary = sourceSummary,
	}
	return inflictor, summary, nil
end

function ProjectileEntityService.InspectDeathInflictor(inflictorValue: unknown): DeathInflictorSummary?
	if type(inflictorValue) ~= "table" then
		return nil
	end
	local inflictor = inflictorValue :: DeathInflictor
	local capability = deathInflictorCapabilities[inflictor]
	if not capability or capability.inflictor ~= inflictor or not table.isfrozen(inflictor) then
		return nil
	end
	local sourceSummary = ProjectileEntityService.InspectSource(capability.source)
	local summary = capability.summary
	if
		not sourceSummary
		or sourceSummary ~= capability.sourceSummary
		or sourceSummary.phase ~= ProjectileEntityLifecycleRules.Phase.Missile
		or sourceCapabilities[capability.source] ~= capability.sourceCapability
		or capability.sourceCapability.record ~= capability.record
		or authority.bySource[capability.source] ~= capability.record
		or capability.record.summary ~= capability.sourceSummary
		or summary.source ~= capability.source
		or summary.sourceSummary ~= capability.sourceSummary
		or summary.registration ~= sourceSummary.registration
		or summary.lease ~= sourceSummary.lease
		or summary.dynamicBinding ~= sourceSummary.dynamicBinding
		or summary.shotId ~= sourceSummary.shotId
		or summary.sourceRevision ~= sourceSummary.sourceRevision
		or summary.phase ~= "Missile"
		or summary.trajectoryBase ~= sourceSummary.trajectoryBase
		or not table.isfrozen(summary)
	then
		return nil
	end
	return summary
end

function ProjectileEntityService.ValidateDeathInflictorDependency(
	inflictorValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(inflictorValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-projectile-death-inflictor-dependency"
	end
	local capability = deathInflictorCapabilities[inflictorValue :: DeathInflictor]
	if not capability then
		return false, "invalid-projectile-death-inflictor"
	end
	if capability.summary ~= summaryValue then
		return false, "forged-projectile-death-inflictor-summary"
	end
	if ProjectileEntityService.InspectDeathInflictor(inflictorValue) ~= capability.summary then
		return false, "stale-projectile-death-inflictor"
	end
	return true, nil
end

function ProjectileEntityService.GetDeathInflictorAdapter(): DeathInflictorAdapter
	local adapter: DeathInflictorAdapter = {
		Capture = ProjectileEntityService.CaptureDeathInflictor,
		Validate = ProjectileEntityService.ValidateDeathInflictorDependency,
	}
	return table.freeze(adapter)
end

function ProjectileEntityService.InspectSourceForRegistration(
	registrationValue: unknown
): (ProjectileSource?, SourceSummary?)
	if type(registrationValue) ~= "table" or activePrepared ~= nil then
		return nil, nil
	end
	local registration = registrationValue :: EntitySlotService.Registration
	local record = authority.byRegistration[registration]
	if not record or record.registration ~= registration then
		return nil, nil
	end
	local source = record.source
	local capability = sourceCapabilities[source]
	if
		not capability
		or capability.status ~= "Current"
		or capability.record ~= record
		or authority.bySource[source] ~= record
		or authority.byShotId[record.shotId] ~= record
		or not currentWorldRegistration(record)
		or not recordHasExpectedDynamicBinding(record)
		or (dynamicBindingActivated and EntityFrameDispatcherService.IsFaulted())
	then
		return nil, nil
	end
	return source, record.summary
end

function ProjectileEntityService.ValidateSourceDependency(sourceValue: unknown, summaryValue: unknown): boolean
	local summary = ProjectileEntityService.InspectSource(sourceValue)
	return summary ~= nil and summary == summaryValue
end

function ProjectileEntityService.GetDebugSnapshot(): DebugSnapshot
	local sourceOrders: { number } = table.create(#authority.order)
	local dynamicBindingCount = 0
	for _, record in authority.order do
		table.insert(sourceOrders, record.registration.sourceOrder)
		if recordHasExpectedDynamicBinding(record) and record.dynamicBinding ~= nil then
			dynamicBindingCount += 1
		end
	end
	table.freeze(sourceOrders)
	return table.freeze({
		revision = authority.revision,
		levelTimeMilliseconds = authority.levelTimeMilliseconds,
		count = #authority.order,
		activePrepared = activePrepared ~= nil,
		dynamicBindingActivated = dynamicBindingActivated,
		dynamicBindingCount = dynamicBindingCount,
		sourceOrders = sourceOrders,
	})
end

return table.freeze(ProjectileEntityService)
