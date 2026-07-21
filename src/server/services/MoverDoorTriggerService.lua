--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server owner for Q3 func_door's post-map door_trigger entity. Geometry/touch
decisions live in MoverDoorTriggerRules; this service supplies exact G_Spawn
identity, Dispatcher binding, and the client G_TouchTriggers consumer.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "MoverDoorTriggerService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local Constants = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Constants"))
local MoverBinaryPolicy = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverBinaryPolicy"))
local MoverDoorTriggerRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverDoorTriggerRules"))

local EntityFrameDispatcherService = require(script.Parent.EntityFrameDispatcherService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local MovementService = require(script.Parent.MovementService)

local MoverDoorTriggerService = {}

local DECLARED_KIND = "DoorTrigger"
local started = false
local definitions: { MoverDoorTriggerRules.Definition } = table.freeze({})
local definitionByRegistration: { [EntitySlotService.Registration]: MoverDoorTriggerRules.Definition } =
	table.freeze({})

local function dynamicHandler(
	_frame: unknown,
	_summary: unknown,
	registration: EntitySlotService.Registration,
	_binding: EntityFrameDispatcherService.DynamicBinding,
	declaredKind: EntityFrameDispatcherService.DynamicKind
)
	assert(declaredKind == DECLARED_KIND, "door trigger dispatcher kind drifted")
	local definition = definitionByRegistration[registration]
	assert(definition ~= nil, "door trigger dispatcher registration lost its definition")
	assert(
		definition.sourceOrder == registration.sourceOrder
			and definition.bodyId == registration.bodyId
			and definition.generation == registration.generation,
		"door trigger dispatcher identity drifted"
	)
end

local function abortStartup(
	token: EntitySlotService.TransactionToken?,
	dispatcherPrepared: EntityFrameDispatcherService.PreparedDynamicBatch?
)
	if dispatcherPrepared then
		EntityFrameDispatcherService.AbortPreparedDynamicBatch(dispatcherPrepared)
	end
	if token then
		EntitySlotService.Abort(token)
	end
end

function MoverDoorTriggerService.Start(programsValue: unknown, policiesValue: unknown): (boolean, string?)
	if started then
		return false, "mover-door-trigger-service-already-started"
	end
	local policies, policyError = MoverDoorTriggerRules.ValidateAndOrderPolicies(programsValue, policiesValue)
	if not policies then
		return false, policyError
	end
	local triggerCount = 0
	for _, policy in policies do
		if policy.activationBehavior ~= MoverBinaryPolicy.ActivationBehavior.None then
			triggerCount += 1
		end
	end
	if triggerCount == 0 then
		definitions = table.freeze({})
		definitionByRegistration = table.freeze({})
		started = true
		return true, nil
	end

	local token, beginError = EntitySlotService.Begin(0)
	if not token then
		return false, beginError
	end
	local registrations: { EntitySlotService.Registration } = {}
	local identities: { MoverDoorTriggerRules.Identity } = {}
	for _, policy in policies do
		if policy.activationBehavior == MoverBinaryPolicy.ActivationBehavior.None then
			continue
		end
		local entityKind = if policy.activationBehavior == MoverBinaryPolicy.ActivationBehavior.PlatTouch
			then "plat_trigger"
			else "door_trigger"
		local registration, allocationError = EntitySlotService.AllocateWorld(token, entityKind)
		if not registration then
			abortStartup(token, nil)
			return false, allocationError
		end
		table.insert(registrations, registration)
		table.insert(identities, {
			teamId = policy.teamId,
			bodyId = registration.bodyId,
			sourceOrder = registration.sourceOrder,
			generation = registration.generation,
		})
	end
	local nextDefinitions, definitionError = MoverDoorTriggerRules.Build(programsValue, policies, identities)
	if not nextDefinitions then
		abortStartup(token, nil)
		return false, definitionError
	end
	local entityPrepared, entityPrepareError = EntitySlotService.Prepare(token)
	if not entityPrepared then
		abortStartup(token, nil)
		return false, entityPrepareError
	end
	local entitySummary = EntitySlotService.InspectPreparedCommitSummary(entityPrepared)
	if not entitySummary then
		abortStartup(token, nil)
		return false, "door-trigger-entity-summary-unavailable"
	end
	local operations: { EntityFrameDispatcherService.DynamicOperation } = {}
	for _, registration in registrations do
		table.insert(operations, {
			kind = "Bind",
			registration = registration,
			declaredKind = DECLARED_KIND,
			handler = dynamicHandler,
		})
	end
	local dispatcherPrepared, dispatcherSummary, dispatcherError =
		EntityFrameDispatcherService.PrepareDynamicBatch(entityPrepared, entitySummary, operations)
	if not dispatcherPrepared or not dispatcherSummary then
		abortStartup(token, dispatcherPrepared)
		return false, dispatcherError
	end
	for _ = 1, 2 do
		local entityReady, entityError = EntitySlotService.CanApplyPrepared(entityPrepared)
		local dispatcherReady, dispatcherReadyError =
			EntityFrameDispatcherService.CanApplyPreparedDynamicBatch(dispatcherPrepared)
		if not entityReady or not dispatcherReady then
			abortStartup(token, dispatcherPrepared)
			return false, entityError or dispatcherReadyError
		end
	end
	EntitySlotService.ApplyPrepared(entityPrepared)
	local dispatcherReceipt = EntityFrameDispatcherService.ApplyPreparedDynamicBatch(dispatcherPrepared)
	local applied, appliedError =
		EntityFrameDispatcherService.ValidateAppliedDynamicBatchDependency(dispatcherReceipt, dispatcherSummary)
	if not applied then
		return false, appliedError
	end

	local nextByRegistration: { [EntitySlotService.Registration]: MoverDoorTriggerRules.Definition } = {}
	for index, registration in registrations do
		local definition = nextDefinitions[index]
		if not definition or definition.sourceOrder ~= registration.sourceOrder then
			return false, "door-trigger-definition-registration-order-mismatch"
		end
		nextByRegistration[registration] = definition
	end
	table.freeze(nextByRegistration)
	definitions = nextDefinitions
	definitionByRegistration = nextByRegistration
	started = true
	return true, nil
end

function MoverDoorTriggerService.HandleClientTriggerFrame(_frame: unknown, player: Player)
	assert(started, "MoverDoorTriggerService must be started before client trigger visits")
	assert(player.Parent == Players, "door trigger client is not active")
	if #definitions == 0 or player:GetAttribute("ArenaAlive") ~= true then
		return
	end
	local state = MovementService.GetState(player)
	if not state then
		return
	end
	if state.groundMoverId then
		for _, definition in definitions do
			if definition.kind == "Plat" and definition.captainMoverId == state.groundMoverId then
				local mover = MovementService.GetBinaryMoverState(definition.captainMoverId)
				assert(mover, "platform top-contact parent mover state is unavailable")
				if mover.state == "Pos2" then
					local queued, queueError = MovementService.QueueBinaryDoorTriggerUse(definition.captainMoverId)
					assert(queued or queueError == "DoorAlreadyOpening", queueError or "platform wait refresh failed")
				end
				break
			end
		end
	end
	local touching, touchingError = MoverDoorTriggerRules.FindTouching(
		definitions,
		state.position,
		Constants.ColliderSizeFor(state.crouched),
		Constants.ColliderCenterOffsetFor(state.crouched)
	)
	assert(touching, touchingError or "door trigger touch query failed")
	for _, definition in touching do
		local mover = MovementService.GetBinaryMoverState(definition.captainMoverId)
		assert(mover, "door trigger parent mover state is unavailable")
		local touch, touchError = MoverDoorTriggerRules.ResolveTouch(definition, mover.state, state.position, false)
		assert(touch, touchError or "door trigger touch resolution failed")
		if touch.disposition == "Use" then
			local captainMoverId = assert(touch.captainMoverId, "door-trigger Use disposition lost its captain")
			local queued, queueError = MovementService.QueueBinaryDoorTriggerUse(captainMoverId)
			assert(queued or queueError == "DoorAlreadyOpening", queueError or "door use failed")
		end
	end
end

function MoverDoorTriggerService.GetDefinitions(): { MoverDoorTriggerRules.Definition }
	return definitions
end

return table.freeze(MoverDoorTriggerService)
