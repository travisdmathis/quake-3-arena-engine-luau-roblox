--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure mover-to-player assignment planning translated from:
  code/game/g_mover.c (G_TryPushingEntity, G_MoverPush, pushed_t rollback)
  code/game/g_active.c (ClientEndFrame after all mover entities)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local Movement = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Movement"))
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))

local MovementMoverPlayerRuntime = {}

export type AssignmentFactory = (
	player: Player,
	baseline: any,
	nextState: Movement.State,
	removedCallbackBody: MoverPushRules.Body?
) -> any

local function stateAfterMoverPush(
	state: Movement.State,
	position: Vector3,
	groundMoverId: string?,
	forceAirborne: boolean,
	yawDeltaShort: number
): Movement.State
	assert(
		groundMoverId == nil or Movement.ValidateMoverId(groundMoverId) ~= nil,
		"mover push returned an invalid ground identity"
	)
	local grounded = if forceAirborne then false else state.grounded
	local groundPlane = if forceAirborne then false else state.groundPlane
	return {
		frame = state.frame,
		position = position,
		velocity = state.velocity,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = (state.deltaYaw + yawDeltaShort) % 65_536,
		deltaRoll = state.deltaRoll,
		grounded = grounded,
		groundPlane = groundPlane,
		groundNormal = if groundPlane then state.groundNormal else Vector3.yAxis,
		groundSlick = if groundPlane then state.groundSlick else false,
		groundNoDamage = if groundPlane then state.groundNoDamage else false,
		groundMoverId = if grounded then groundMoverId else nil,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
		jumpHeld = state.jumpHeld,
		crouched = state.crouched,
		movementTime = state.movementTime,
		timeLand = state.timeLand,
		timeKnockback = state.timeKnockback,
		timeWaterJump = state.timeWaterJump,
		respawned = state.respawned,
	}
end

function MovementMoverPlayerRuntime.Plan(
	result: MoverPushRules.Result,
	bindings: { [string]: any },
	recordBaselines: { [Player]: any },
	removedCallbackBodiesByPlayer: { [Player]: MoverPushRules.Body },
	buildAssignment: AssignmentFactory
): ({ any }, { [Player]: boolean })
	local forceAirborne: { [string]: boolean } = {}
	local yawDeltaShortByBodyId: { [string]: number } = {}
	local changedPlayers: { [Player]: boolean } = {}
	local nextStatesByPlayer: { [Player]: Movement.State } = {}
	local finalBodyIds: { [string]: boolean } = {}
	local assignments: { any } = {}
	for _, push in result.pushes do
		if push.kind ~= "Carried" then
			forceAirborne[push.bodyId] = true
		end
	end
	for _, rotation in result.viewRotations do
		yawDeltaShortByBodyId[rotation.bodyId] = (
			(yawDeltaShortByBodyId[rotation.bodyId] or 0) + rotation.yawDeltaShort
		) % 65_536
	end
	for _, detach in result.detaches do
		forceAirborne[detach.bodyId] = true
	end

	for _, body in result.bodies do
		finalBodyIds[body.id] = true
		local binding = bindings[body.id]
		if binding and binding.kind == "LivePlayer" then
			local state = binding.record.state
			if state then
				local yawDeltaShort = yawDeltaShortByBodyId[body.id] or 0
				if
					body.position ~= state.position
					or body.groundMoverId ~= state.groundMoverId
					or forceAirborne[body.id] == true
					or yawDeltaShort ~= 0
				then
					changedPlayers[binding.player] = true
				end
				nextStatesByPlayer[binding.player] = stateAfterMoverPush(
					state,
					body.position,
					body.groundMoverId,
					forceAirborne[body.id] == true,
					yawDeltaShort
				)
			end
		end
	end

	-- A callback Remove loses the body from the final kernel result. Preserve the
	-- exact pushed_t callback origin used synchronously by G_Damage/player_die.
	for player, callbackBody in removedCallbackBodiesByPlayer do
		local binding = bindings[callbackBody.id]
		if
			finalBodyIds[callbackBody.id] ~= true
			and binding
			and binding.kind == "LivePlayer"
			and binding.player == player
		then
			local state = binding.record.state
			if state then
				local callbackForceAirborne = forceAirborne[callbackBody.id] == true
				local yawDeltaShort = yawDeltaShortByBodyId[callbackBody.id] or 0
				if
					callbackBody.position ~= state.position
					or callbackBody.groundMoverId ~= state.groundMoverId
					or callbackForceAirborne
					or yawDeltaShort ~= 0
				then
					changedPlayers[binding.player] = true
				end
				nextStatesByPlayer[binding.player] = stateAfterMoverPush(
					state,
					callbackBody.position,
					callbackBody.groundMoverId,
					callbackForceAirborne,
					yawDeltaShort
				)
			end
		end
	end

	for player, baseline in recordBaselines do
		local state = baseline.state
		if state then
			table.insert(
				assignments,
				buildAssignment(
					player,
					baseline,
					nextStatesByPlayer[player] or state,
					removedCallbackBodiesByPlayer[player]
				)
			)
		end
	end
	table.sort(assignments, function(left: any, right: any): boolean
		return left.record.moverBodySourceOrder < right.record.moverBodySourceOrder
	end)
	table.freeze(assignments)
	table.freeze(changedPlayers)
	return assignments, changedPlayers
end

return table.freeze(MovementMoverPlayerRuntime)
