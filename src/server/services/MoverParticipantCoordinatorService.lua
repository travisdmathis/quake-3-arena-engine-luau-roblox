--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only composition boundary for independently owned Q3 mover
participants. Child owners retain their logical roots and publication; this
coordinator supplies MovementService one exact collection/prepare/apply seam.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local ReleaseBroker = require(script.Parent.MoverParticipantReleaseBrokerService)

local MoverParticipantCoordinatorService = {}

type ChildAdapter = {
	Collect: () -> MoverItemFlagParticipantRules.Collection,
	ResolveSine: (bodyId: string) -> MoverItemFlagParticipantRules.SynchronousCrushEffect,
	ResolveBlockedDoor: (bodyId: string) -> MoverItemFlagParticipantRules.Transition,
	Prepare: (finalBodies: unknown) -> (unknown?, string?),
	CanApply: (prepared: unknown) -> (boolean, string?),
	Apply: (prepared: unknown) -> unknown,
	Flush: (receipt: unknown) -> boolean,
	Abort: (prepared: unknown) -> boolean,
	BindSharedMutation: ((
		prepared: unknown,
		sharedPrepared: ReleaseBroker.Prepared
	) -> (boolean, string?))?,
}

type CoordinatorAdapter = ChildAdapter & {
	BeginFrame: (stepTimeMilliseconds: number) -> (boolean, string?),
	AbortFrame: () -> boolean,
}

type ChildPrepared = {
	adapter: ChildAdapter,
	prepared: unknown,
	receipt: unknown?,
	applied: boolean,
	flushed: boolean,
	aborted: boolean,
}

type Status = "Prepared" | "Applied" | "Flushed" | "Aborted"
type Capability = {
	status: Status,
	children: { ChildPrepared },
	receipt: {},
	releaseToken: ReleaseBroker.Token,
	releasePrepared: ReleaseBroker.Prepared,
	releaseReceipt: ReleaseBroker.Receipt?,
}

local function validateAdapter(value: unknown): ChildAdapter
	assert(type(value) == "table", "mover participant child adapter must be a table")
	for _, methodName in
		{
			"Collect",
			"ResolveSine",
			"ResolveBlockedDoor",
			"Prepare",
			"CanApply",
			"Apply",
			"Flush",
			"Abort",
		}
	do
		assert(
			type((value :: any)[methodName]) == "function",
			string.format("mover participant child adapter requires %s", methodName)
		)
	end
	return value :: ChildAdapter
end

function MoverParticipantCoordinatorService.Create(adaptersValue: unknown): CoordinatorAdapter
	assert(type(adaptersValue) == "table", "mover participant adapters must be an array")
	local adapters: { ChildAdapter } = {}
	for index, value in adaptersValue :: { unknown } do
		assert(index == #adapters + 1, "mover participant adapters must be dense")
		table.insert(adapters, validateAdapter(value))
	end
	assert(#adapters > 0, "mover participant coordinator requires a child")
	table.freeze(adapters)

	local preparedCapabilities: { [{}]: Capability } = setmetatable({}, { __mode = "k" }) :: any
	local receiptCapabilities: { [{}]: Capability } = setmetatable({}, { __mode = "k" }) :: any
	local activePrepared: {}? = nil
	local activeFrameToken: ReleaseBroker.Token? = nil

	local function beginFrame(stepTimeMilliseconds: number): (boolean, string?)
		if activePrepared ~= nil or activeFrameToken ~= nil then
			return false, "mover-participant-frame-already-active"
		end
		activeFrameToken = ReleaseBroker.Begin(stepTimeMilliseconds)
		return true, nil
	end

	local function abortFrame(): boolean
		local token = activeFrameToken
		if not token or activePrepared ~= nil then
			return false
		end
		if not ReleaseBroker.Abort(token) then
			return false
		end
		activeFrameToken = nil
		return true
	end

	local function collect(): MoverItemFlagParticipantRules.Collection
		assert(activePrepared == nil, "mover participant collection crossed an active prepare")
		assert(activeFrameToken ~= nil, "mover participant collection occurred outside its frame")
		local bodies: { MoverItemFlagParticipantRules.Body } = {}
		local bindingsByBodyId: { [string]: MoverItemFlagParticipantRules.Binding } = {}
		local sourceOrders: { [number]: boolean } = {}
		for _, adapter in adapters do
			local collection = adapter.Collect()
			for _, body in collection.bodies do
				assert(bindingsByBodyId[body.id] == nil, "mover participant body identity collided")
				assert(
					not sourceOrders[body.sourceOrder],
					"mover participant source order collided"
				)
				local binding = assert(
					collection.bindingsByBodyId[body.id],
					"mover participant body omitted its binding"
				)
				bindingsByBodyId[body.id] = binding
				sourceOrders[body.sourceOrder] = true
				table.insert(bodies, body)
			end
		end
		table.sort(bodies, function(left, right)
			return left.sourceOrder < right.sourceOrder
		end)
		table.freeze(bodies)
		table.freeze(bindingsByBodyId)
		return table.freeze({
			bodies = bodies,
			bindingsByBodyId = bindingsByBodyId,
		})
	end

	local function ownerForBodyId(bodyId: string): ChildAdapter
		local owner: ChildAdapter? = nil
		for _, adapter in adapters do
			if adapter.Collect().bindingsByBodyId[bodyId] ~= nil then
				assert(owner == nil, "mover participant body has multiple owners")
				owner = adapter
			end
		end
		return assert(owner, "mover participant body owner is stale")
	end

	local function prepare(finalBodies: unknown): (unknown?, string?)
		if activePrepared ~= nil then
			return nil, "mover-participant-coordinator-busy"
		end
		local frame = AuthoritativeFrameService.GetOpenFrame()
		local frameSummary = if frame then AuthoritativeFrameService.InspectFrame(frame) else nil
		if not frameSummary then
			return nil, "mover-participant-coordinator-outside-frame"
		end
		local releaseToken = activeFrameToken
		if not releaseToken then
			return nil, "mover-participant-frame-not-open"
		end
		if frameSummary.currentTimeMilliseconds ~= ReleaseBroker.GetStepTime(releaseToken) then
			return nil, "mover-participant-frame-time-drifted"
		end
		local children: { ChildPrepared } = {}
		for _, adapter in adapters do
			local childPrepared, childError = adapter.Prepare(finalBodies)
			if childPrepared == nil then
				for index = #children, 1, -1 do
					local child = children[index]
					if not child.aborted and not child.adapter.Abort(child.prepared) then
						return nil, "mover-participant-child-prepare-abort-failed"
					end
					child.aborted = true
				end
				if not ReleaseBroker.Abort(releaseToken) then
					return nil, "mover-participant-release-broker-abort-failed"
				end
				activeFrameToken = nil
				return nil, childError or "mover-participant-child-prepare-failed"
			end
			table.insert(children, {
				adapter = adapter,
				prepared = childPrepared,
				receipt = nil,
				applied = false,
				flushed = false,
				aborted = false,
			})
		end
		table.freeze(children)
		local releasePrepared, releaseError = ReleaseBroker.Prepare(releaseToken)
		if not releasePrepared then
			for index = #children, 1, -1 do
				local child = children[index]
				if not child.adapter.Abort(child.prepared) then
					return nil, "mover-participant-child-release-prepare-abort-failed"
				end
				child.aborted = true
			end
			if ReleaseBroker.Abort(releaseToken) then
				activeFrameToken = nil
			end
			return nil, releaseError or "mover-participant-release-prepare-failed"
		end
		for _, child in children do
			local bindSharedMutation = child.adapter.BindSharedMutation
			if bindSharedMutation then
				local bound, bindError = bindSharedMutation(child.prepared, releasePrepared)
				if not bound then
					for index = #children, 1, -1 do
						local abortChild = children[index]
						if
							not abortChild.aborted
							and not abortChild.adapter.Abort(abortChild.prepared)
						then
							return nil, "mover-participant-child-shared-bind-abort-failed"
						end
						abortChild.aborted = true
					end
					if ReleaseBroker.Abort(releaseToken) then
						activeFrameToken = nil
					end
					return nil, bindError or "mover-participant-child-shared-bind-failed"
				end
			end
		end
		local prepared = table.freeze({})
		local receipt = table.freeze({})
		local capability: Capability = {
			status = "Prepared",
			children = children,
			receipt = receipt,
			releaseToken = releaseToken,
			releasePrepared = releasePrepared,
			releaseReceipt = nil,
		}
		preparedCapabilities[prepared] = capability
		receiptCapabilities[receipt] = capability
		activePrepared = prepared
		return prepared, nil
	end

	local function canApply(preparedValue: unknown): (boolean, string?)
		local capability = if type(preparedValue) == "table"
			then preparedCapabilities[preparedValue :: {}]
			else nil
		if not capability or capability.status ~= "Prepared" or activePrepared ~= preparedValue then
			return false, "stale-mover-participant-coordinator-prepare"
		end
		local releaseCanApply, releaseError = ReleaseBroker.CanApply(capability.releasePrepared)
		if not releaseCanApply then
			return false, releaseError or "mover-participant-release-preflight-failed"
		end
		for _, child in capability.children do
			local childCanApply, childError = child.adapter.CanApply(child.prepared)
			if not childCanApply then
				return false, childError or "mover-participant-child-preflight-failed"
			end
		end
		return true, nil
	end

	local function apply(preparedValue: unknown): unknown
		local prepared = preparedValue :: {}
		local capability = assert(preparedCapabilities[prepared], "invalid coordinator prepare")
		assert(
			capability.status == "Prepared" and activePrepared == prepared,
			"stale coordinator apply"
		)
		capability.releaseReceipt = ReleaseBroker.Apply(capability.releasePrepared)
		for _, child in capability.children do
			child.receipt = child.adapter.Apply(child.prepared)
			child.applied = true
		end
		capability.status = "Applied"
		preparedCapabilities[prepared] = nil
		activeFrameToken = nil
		return capability.receipt
	end

	local function flush(receiptValue: unknown): boolean
		local capability = if type(receiptValue) == "table"
			then receiptCapabilities[receiptValue :: {}]
			else nil
		if not capability or capability.status ~= "Applied" then
			return false
		end
		for _, child in capability.children do
			if not child.flushed then
				if not child.adapter.Flush(child.receipt) then
					return false
				end
				child.flushed = true
			end
		end
		if not ReleaseBroker.Retire(capability.releaseReceipt) then
			return false
		end
		capability.status = "Flushed"
		receiptCapabilities[capability.receipt] = nil
		activePrepared = nil
		activeFrameToken = nil
		return true
	end

	local function abort(preparedValue: unknown): boolean
		local prepared = if type(preparedValue) == "table" then preparedValue :: {} else nil
		local capability = if prepared then preparedCapabilities[prepared] else nil
		if not capability or capability.status ~= "Prepared" or activePrepared ~= prepared then
			return false
		end
		for index = #capability.children, 1, -1 do
			local child = capability.children[index]
			if not child.aborted then
				if not child.adapter.Abort(child.prepared) then
					return false
				end
				child.aborted = true
			end
		end
		if not ReleaseBroker.Abort(capability.releaseToken) then
			return false
		end
		capability.status = "Aborted"
		preparedCapabilities[prepared :: {}] = nil
		receiptCapabilities[capability.receipt] = nil
		activePrepared = nil
		activeFrameToken = nil
		return true
	end

	return table.freeze({
		BeginFrame = beginFrame,
		AbortFrame = abortFrame,
		Collect = collect,
		ResolveSine = function(bodyId: string)
			return ownerForBodyId(bodyId).ResolveSine(bodyId)
		end,
		ResolveBlockedDoor = function(bodyId: string)
			return ownerForBodyId(bodyId).ResolveBlockedDoor(bodyId)
		end,
		Prepare = prepare,
		CanApply = canApply,
		Apply = apply,
		Flush = flush,
		Abort = abort,
	})
end

return table.freeze(MoverParticipantCoordinatorService)
