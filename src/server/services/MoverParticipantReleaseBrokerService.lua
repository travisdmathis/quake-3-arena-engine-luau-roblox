--[[
SPDX-License-Identifier: GPL-2.0-or-later

One-frame shared EntitySlot/Dispatcher mutation owner for independently
prepared Q3 mover participant roots. It can reserve a G_Spawn identity during
a synchronous mover callback, then combine that retained registration and any
later frees into one prepared transaction. Frames with no mutations remain
lazy and revise neither child authority.
]]

--!strict

local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)

local Broker = {}

export type Token = {}
export type Prepared = {}
export type Receipt = {}

type Release = {
	registration: EntitySlotService.Registration,
	binding: EntityFrameDispatcherService.DynamicBinding?,
}

type Allocation = {
	registration: EntitySlotService.Registration,
	declaredKind: EntityFrameDispatcherService.DynamicKind,
	handler: EntityFrameDispatcherService.DynamicHandler,
}

type Capability = {
	status: "Open" | "Prepared" | "Applied" | "Retired" | "Aborted",
	stepTimeMilliseconds: number,
	releases: { Release },
	allocations: { Allocation },
	observedSourceOrders: { [number]: boolean },
	entityToken: EntitySlotService.TransactionToken?,
	entityPrepared: EntitySlotService.PreparedCommit?,
	entityReceipt: EntitySlotService.CommitReceipt?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?,
	dispatcherSummary: EntityFrameDispatcherService.PreparedDynamicBatchSummary?,
	dispatcherReceipt: EntityFrameDispatcherService.DynamicBatchReceipt?,
	dispatcherAborted: boolean,
	entityAborted: boolean,
	prepared: Prepared?,
	receipt: Receipt?,
}

local activeToken: Token? = nil
local capabilities: { [Token]: Capability } = setmetatable({}, { __mode = "k" }) :: any
local preparedCapabilities: { [Prepared]: Capability } = setmetatable({}, { __mode = "k" }) :: any
local receiptCapabilities: { [Receipt]: Capability } = setmetatable({}, { __mode = "k" }) :: any

function Broker.Begin(stepTimeMilliseconds: number): Token
	assert(activeToken == nil, "mover participant release broker is already active")
	assert(
		type(stepTimeMilliseconds) == "number"
			and stepTimeMilliseconds % 1 == 0
			and stepTimeMilliseconds >= 0,
		"mover participant release broker requires integer level time"
	)
	local token: Token = table.freeze({})
	capabilities[token] = {
		status = "Open",
		stepTimeMilliseconds = stepTimeMilliseconds,
		releases = {},
		allocations = {},
		observedSourceOrders = {},
		entityToken = nil,
		entityPrepared = nil,
		entityReceipt = nil,
		dispatcherPrepared = nil,
		dispatcherSummary = nil,
		dispatcherReceipt = nil,
		dispatcherAborted = false,
		entityAborted = false,
		prepared = nil,
		receipt = nil,
	}
	activeToken = token
	return token
end

local function ensureEntityToken(
	capability: Capability
): (EntitySlotService.TransactionToken?, string?)
	if capability.entityToken then
		return capability.entityToken, nil
	end
	local token, beginError = EntitySlotService.Begin(capability.stepTimeMilliseconds)
	if not token then
		return nil, beginError or "mover-participant-mutation-begin-failed"
	end
	capability.entityToken = token
	return token, nil
end

function Broker.AllocateWorld(
	tokenValue: unknown,
	prefixValue: unknown,
	declaredKindValue: unknown,
	handlerValue: unknown
): (EntitySlotService.Registration?, string?)
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	if not capability or capability.status ~= "Open" or activeToken ~= tokenValue then
		return nil, "stale-mover-participant-mutation-broker"
	end
	if type(declaredKindValue) ~= "string" or type(handlerValue) ~= "function" then
		return nil, "invalid-mover-participant-allocation-binding"
	end
	local entityToken, beginError = ensureEntityToken(capability)
	if not entityToken then
		return nil, beginError
	end
	local registration, allocationError = EntitySlotService.AllocateWorld(entityToken, prefixValue)
	if not registration then
		return nil, allocationError or "mover-participant-allocation-failed"
	end
	if capability.observedSourceOrders[registration.sourceOrder] then
		return nil, "duplicate-mover-participant-allocation-source-order"
	end
	capability.observedSourceOrders[registration.sourceOrder] = true
	table.insert(capability.allocations, {
		registration = registration,
		declaredKind = declaredKindValue,
		handler = handlerValue,
	})
	return registration, nil
end

function Broker.GetActiveToken(): Token?
	return activeToken
end

function Broker.GetStepTime(tokenValue: unknown): number?
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	return if capability
			and capability.status == "Open"
			and activeToken == tokenValue
		then capability.stepTimeMilliseconds
		else nil
end

function Broker.GetOpenEntitySlotToken(tokenValue: unknown): EntitySlotService.TransactionToken?
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	if not capability or capability.status ~= "Open" or activeToken ~= tokenValue then
		return nil
	end
	return capability.entityToken
end

function Broker.GetProvisionalWorldLease(
	tokenValue: unknown,
	registrationValue: unknown
): EntitySlotService.WorldLease?
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	if
		not capability
		or capability.status ~= "Open"
		or activeToken ~= tokenValue
		or not capability.entityToken
		or type(registrationValue) ~= "table"
	then
		return nil
	end
	local registration = registrationValue :: EntitySlotService.Registration
	if
		registration.kind ~= "World"
		or not capability.observedSourceOrders[registration.sourceOrder]
	then
		return nil
	end
	for _, allocation in capability.allocations do
		if allocation.registration == registration then
			return EntitySlotService.GetWorldLease(registration, capability.entityToken)
		end
	end
	return nil
end

function Broker.CancelAllocation(
	tokenValue: unknown,
	registrationValue: unknown
): (boolean, string?)
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	if
		not capability
		or capability.status ~= "Open"
		or activeToken ~= tokenValue
		or not capability.entityToken
		or type(registrationValue) ~= "table"
	then
		return false, "stale-mover-participant-allocation-cancel"
	end
	local registration = registrationValue :: EntitySlotService.Registration
	local allocationIndex: number? = nil
	for index, allocation in capability.allocations do
		if allocation.registration == registration then
			allocationIndex = index
			break
		end
	end
	if not allocationIndex then
		return false, "mover-participant-allocation-not-pending"
	end
	local released, releaseError =
		EntitySlotService.ReleaseWorld(capability.entityToken, registration)
	if not released then
		return false, releaseError or "mover-participant-allocation-cancel-failed"
	end
	table.remove(capability.allocations, allocationIndex)
	return true, nil
end

function Broker.StageRelease(
	tokenValue: unknown,
	registrationValue: unknown,
	bindingValue: unknown?
): (boolean, string?)
	local capability = if type(tokenValue) == "table"
		then capabilities[tokenValue :: Token]
		else nil
	if not capability or capability.status ~= "Open" or activeToken ~= tokenValue then
		return false, "stale-mover-participant-release-broker"
	end
	if type(registrationValue) ~= "table" then
		return false, "invalid-mover-participant-release-registration"
	end
	local registration = registrationValue :: EntitySlotService.Registration
	if
		registration.kind ~= "World"
		or EntitySlotService.InspectSlot(registration.sourceOrder) ~= registration
		or capability.observedSourceOrders[registration.sourceOrder]
	then
		return false, "stale-or-duplicate-mover-participant-release-registration"
	end
	local binding = if type(bindingValue) == "table"
		then bindingValue :: EntityFrameDispatcherService.DynamicBinding
		else nil
	capability.observedSourceOrders[registration.sourceOrder] = true
	table.insert(capability.releases, {
		registration = registration,
		binding = binding,
	})
	return true, nil
end

function Broker.Prepare(tokenValue: unknown): (Prepared?, string?)
	local token = if type(tokenValue) == "table" then tokenValue :: Token else nil
	local capability = if token then capabilities[token] else nil
	if not capability or capability.status ~= "Open" or activeToken ~= token then
		return nil, "stale-open-mover-participant-release-broker"
	end
	table.sort(capability.releases, function(left, right)
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.sort(capability.allocations, function(left, right)
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(capability.releases)
	table.freeze(capability.allocations)
	if #capability.releases > 0 or #capability.allocations > 0 then
		local entityToken, beginError = ensureEntityToken(capability)
		if not entityToken then
			return nil, beginError
		end
		local function abortEntityAfterPrepareFailure()
			if not capability.entityAborted then
				assert(
					EntitySlotService.Abort(entityToken),
					"release broker could not abort its failed EntitySlot prepare"
				)
				capability.entityAborted = true
			end
		end
		local operations: { EntityFrameDispatcherService.DynamicOperation } = {}
		for _, allocation in capability.allocations do
			table.insert(operations, {
				kind = "Bind",
				registration = allocation.registration,
				declaredKind = allocation.declaredKind,
				handler = allocation.handler,
			})
		end
		for _, release in capability.releases do
			local released, releaseError =
				EntitySlotService.ReleaseWorld(entityToken, release.registration)
			if not released then
				abortEntityAfterPrepareFailure()
				return nil, releaseError or "mover-participant-release-stage-failed"
			end
			if release.binding then
				table.insert(operations, {
					kind = "Unbind",
					registration = release.registration,
					binding = release.binding,
				})
			end
		end
		table.sort(operations, function(left, right): boolean
			return left.registration.sourceOrder < right.registration.sourceOrder
		end)
		local entityPrepared, entityPrepareError = EntitySlotService.Prepare(entityToken)
		if not entityPrepared then
			abortEntityAfterPrepareFailure()
			return nil, entityPrepareError or "mover-participant-release-prepare-failed"
		end
		capability.entityPrepared = entityPrepared
		capability.entityReceipt = EntitySlotService.InspectPreparedCommitReceipt(entityPrepared)
		local entitySummary = EntitySlotService.InspectPreparedCommitSummary(entityPrepared)
		if not capability.entityReceipt or not entitySummary then
			abortEntityAfterPrepareFailure()
			return nil, "mover-participant-release-entity-witness-missing"
		end
		if #operations > 0 then
			local dispatcherPrepared, dispatcherSummary, dispatcherError =
				EntityFrameDispatcherService.PrepareDynamicBatch(
					entityPrepared,
					entitySummary,
					operations
				)
			if not dispatcherPrepared then
				abortEntityAfterPrepareFailure()
				return nil, dispatcherError or "mover-participant-release-unbind-prepare-failed"
			end
			capability.dispatcherPrepared = dispatcherPrepared
			capability.dispatcherSummary = dispatcherSummary
			capability.dispatcherReceipt =
				EntityFrameDispatcherService.InspectPreparedDynamicBatchReceipt(dispatcherPrepared)
			if not capability.dispatcherReceipt then
				assert(
					EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared),
					"release broker could not abort its failed Dispatcher prepare"
				)
				capability.dispatcherAborted = true
				abortEntityAfterPrepareFailure()
				return nil, "mover-participant-release-dispatcher-witness-missing"
			end
		end
	end
	local prepared: Prepared = table.freeze({})
	local receipt: Receipt = table.freeze({})
	capability.prepared = prepared
	capability.receipt = receipt
	capability.status = "Prepared"
	preparedCapabilities[prepared] = capability
	receiptCapabilities[receipt] = capability
	return prepared, nil
end

function Broker.InspectPreparedAllocationBinding(
	preparedValue: unknown,
	registrationValue: unknown
): EntityFrameDispatcherService.DynamicBinding?
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: Prepared]
		else nil
	if not capability or capability.status ~= "Prepared" or type(registrationValue) ~= "table" then
		return nil
	end
	local summary = capability.dispatcherSummary
	if not summary then
		return nil
	end
	local found: EntityFrameDispatcherService.DynamicBinding? = nil
	for _, outcome in summary.outcomes do
		if outcome.kind == "Bound" and outcome.registration == registrationValue then
			if found ~= nil then
				return nil
			end
			found = outcome.binding
		end
	end
	return found
end

function Broker.InspectPreparedEntitySlotDependency(preparedValue: unknown): (
	EntitySlotService.PreparedCommit?,
	EntitySlotService.PreparedCommitSummary?
)
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: Prepared]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return nil, nil
	end
	if capability.entityPrepared == nil then
		return nil, nil
	end
	return capability.entityPrepared,
		EntitySlotService.InspectPreparedCommitSummary(capability.entityPrepared)
end

function Broker.InspectPreparedDispatcherDependency(preparedValue: unknown): (
	EntityFrameDispatcherService.PreparedDynamicBatch?,
	EntityFrameDispatcherService.PreparedDynamicBatchSummary?
)
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: Prepared]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return nil, nil
	end
	return capability.dispatcherPrepared, capability.dispatcherSummary
end

function Broker.CanApply(preparedValue: unknown): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedCapabilities[preparedValue :: Prepared]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return false, "stale-prepared-mover-participant-release-broker"
	end
	if capability.entityPrepared then
		local entityCanApply, entityError =
			EntitySlotService.CanApplyPrepared(capability.entityPrepared)
		if not entityCanApply then
			return false, entityError
		end
	end
	if capability.dispatcherPrepared then
		local dispatcherCanApply, dispatcherError =
			EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(capability.dispatcherPrepared)
		if not dispatcherCanApply then
			return false, dispatcherError
		end
	end
	return true, nil
end

function Broker.Apply(preparedValue: unknown): Receipt
	local prepared = preparedValue :: Prepared
	local capability = assert(preparedCapabilities[prepared], "invalid prepared release broker")
	assert(capability.status == "Prepared", "stale prepared release broker apply")
	if capability.entityPrepared then
		assert(
			EntitySlotService.ApplyPrepared(capability.entityPrepared) == capability.entityReceipt,
			"release broker EntitySlot receipt drifted"
		)
	end
	if capability.dispatcherPrepared then
		assert(
			EntityFrameDispatcherService.ApplyPreparedDynamicBatch(capability.dispatcherPrepared)
				== capability.dispatcherReceipt,
			"release broker Dispatcher receipt drifted"
		)
	end
	capability.status = "Applied"
	preparedCapabilities[prepared] = nil
	activeToken = nil
	return assert(capability.receipt, "release broker receipt is unavailable")
end

function Broker.Retire(receiptValue: unknown): boolean
	local receipt = if type(receiptValue) == "table" then receiptValue :: Receipt else nil
	local capability = if receipt then receiptCapabilities[receipt] else nil
	if not capability or capability.status ~= "Applied" then
		return false
	end
	capability.status = "Retired"
	receiptCapabilities[receipt :: Receipt] = nil
	return true
end

function Broker.Abort(tokenValue: unknown): boolean
	local token = if type(tokenValue) == "table" then tokenValue :: Token else nil
	local capability = if token then capabilities[token] else nil
	if not capability or (capability.status ~= "Open" and capability.status ~= "Prepared") then
		return false
	end
	if capability.dispatcherPrepared and not capability.dispatcherAborted then
		if
			not EntityFrameDispatcherService.AbortPreparedDynamicBatch(
				capability.dispatcherPrepared
			)
		then
			return false
		end
		capability.dispatcherAborted = true
	end
	if capability.entityToken and not capability.entityAborted then
		if not EntitySlotService.Abort(capability.entityToken) then
			return false
		end
		capability.entityAborted = true
	end
	capability.status = "Aborted"
	if capability.prepared then
		preparedCapabilities[capability.prepared] = nil
	end
	if capability.receipt then
		receiptCapabilities[capability.receipt] = nil
	end
	activeToken = nil
	return true
end

return table.freeze(Broker)
