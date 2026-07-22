--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of:
  code/game/g_misc.c (TeleportPlayer)
  code/game/g_utils.c (G_KillBox)
  code/game/g_client.c (SelectSpawnPoint)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local Constants = require(sharedRoot.simulation.Constants)
local EntityStateConversionRules = require(sharedRoot.simulation.EntityStateConversionRules)
local Movement = require(sharedRoot.simulation.Movement)
local SpawnSelection = require(sharedRoot.simulation.SpawnSelection)
local WorldTriggerRules = require(sharedRoot.simulation.WorldTriggerRules)

export type Config = {
	records: { [Player]: any },
	applyTelefrags: (Player, { number }, unknown?) -> boolean,
	invalidateAuthority: (any) -> (),
	applyProjection: (any, Movement.State, EntityStateConversionRules.Angles?) -> (),
}

export type Runtime = {
	ApplyAuthored: (
		self: Runtime,
		player: Player,
		record: any,
		position: Vector3,
		look: Vector3,
		velocity: Vector3,
		movementTime: number,
		triggerId: number?
	) -> boolean,
	Prepare: (
		self: Runtime,
		player: Player,
		record: any,
		position: Vector3,
		look: Vector3,
		velocity: Vector3,
		movementTime: number,
		lifeBinding: unknown
	) -> (Prepared?, PreparedSummary?, string?),
	InspectPrepared: (self: Runtime, value: unknown) -> PreparedSummary?,
	CanApplyPrepared: (self: Runtime, value: unknown) -> (boolean, string?),
	ApplyPrepared: (self: Runtime, value: unknown) -> ApplyReceipt?,
	AbortPrepared: (self: Runtime, value: unknown) -> boolean,
}

export type Prepared = {}
export type PreparedSummary = {
	read player: Player,
	read baseRevision: number,
	read lifeBinding: unknown,
	read position: Vector3,
	read look: Vector3,
	read velocity: Vector3,
	read movementTime: number,
}
export type ApplyReceipt = {
	read player: Player,
	read baseRevision: number,
	read nextRevision: number,
}

local MovementTeleportRuntime = {}

function MovementTeleportRuntime.new(config: Config): Runtime
	local runtime = ({} :: any) :: Runtime
	local capabilities: { [Prepared]: any } = setmetatable({}, { __mode = "k" })

	function runtime:ApplyAuthored(
		player: Player,
		record: any,
		position: Vector3,
		look: Vector3,
		velocity: Vector3,
		movementTime: number,
		triggerId: number?
	): boolean
		local state = record.state
		if not state then
			return false
		end
		local occupants = {}
		for otherPlayer, otherRecord in config.records do
			local otherState = otherRecord.state
			if
				otherPlayer ~= player
				and otherPlayer:GetAttribute("Q3EngineAlive") == true
				and otherState
			then
				table.insert(occupants, {
					userId = otherPlayer.UserId,
					origin = otherState.position,
					size = Constants.ColliderSizeFor(otherState.crouched),
					centerOffset = Constants.ColliderCenterOffsetFor(otherState.crouched),
					active = true,
				})
			end
		end
		local victims = SpawnSelection.OccupantUserIdsAt(
			position,
			Constants.ColliderSizeFor(state.crouched),
			Constants.ColliderCenterOffsetFor(state.crouched),
			occupants
		)
		if not config.applyTelefrags(player, victims, nil) then
			return false
		end

		local viewState = assert(
			Movement.SetViewAngle(state, record.command, look),
			"authored teleporter look must produce a valid Q3 view angle"
		)
		config.invalidateAuthority(record)
		record.state = {
			frame = state.frame,
			position = position,
			velocity = velocity,
			look = viewState.look,
			viewPitch = viewState.viewPitch,
			viewYaw = viewState.viewYaw,
			viewRoll = viewState.viewRoll,
			deltaPitch = viewState.deltaPitch,
			deltaYaw = viewState.deltaYaw,
			deltaRoll = viewState.deltaRoll,
			grounded = false,
			groundPlane = false,
			groundNormal = Vector3.yAxis,
			groundSlick = false,
			groundNoDamage = false,
			groundMoverId = nil,
			waterLevel = state.waterLevel,
			waterType = state.waterType,
			jumpHeld = state.jumpHeld,
			crouched = state.crouched,
			movementTime = movementTime,
			timeLand = state.timeLand,
			timeKnockback = true,
			timeWaterJump = state.timeWaterJump,
			respawned = state.respawned,
		}
		local angles = assert(
			EntityStateConversionRules.AnglesForLook(look),
			"authored teleporter look did not produce generic entity angles"
		)
		record.entityGenericAngles = angles
		record.playerStateViewAngles = angles
		config.applyProjection(record, record.state, angles)
		record.commandQueue = {}
		record.commandQueueHead = 1
		record.lastProcessedSequence = record.lastReceivedSequence
		record.revision += 1
		record.awaitingViewCommand = true
		record.jumpPadEntryState = WorldTriggerRules.EmptyJumpPadEntryState()
		record.pendingSpawnLook = nil
		record.pendingTeleportLook = look
		record.pendingTeleportTriggerId = triggerId
		return true
	end

	function runtime:Prepare(
		player: Player,
		record: any,
		position: Vector3,
		look: Vector3,
		velocity: Vector3,
		movementTime: number,
		lifeBinding: unknown
	): (Prepared?, PreparedSummary?, string?)
		if
			config.records[player] ~= record
			or player:GetAttribute("Q3EngineAlive") ~= true
			or record.state == nil
			or record.lifeBinding ~= lifeBinding
			or type(record.revision) ~= "number"
			or movementTime ~= WorldTriggerRules.TeleportKnockbackSeconds
			or look.Magnitude < 1e-6
			or math.abs(velocity.Magnitude - WorldTriggerRules.TeleportExitSpeed) > 1e-6
		then
			return nil, nil, "invalid-personal-teleporter-prepare"
		end
		local summary: PreparedSummary = table.freeze({
			player = player,
			baseRevision = record.revision,
			lifeBinding = lifeBinding,
			position = position,
			look = look.Unit,
			velocity = velocity,
			movementTime = movementTime,
		})
		local prepared: Prepared = table.freeze({})
		capabilities[prepared] = {
			status = "Prepared",
			record = record,
			baseState = record.state,
			summary = summary,
		}
		return prepared, summary, nil
	end

	function runtime:InspectPrepared(value: unknown): PreparedSummary?
		local capability = if type(value) == "table" then capabilities[value :: Prepared] else nil
		return if capability and capability.status == "Prepared" then capability.summary else nil
	end

	function runtime:CanApplyPrepared(value: unknown): (boolean, string?)
		local capability = if type(value) == "table" then capabilities[value :: Prepared] else nil
		if not capability or capability.status ~= "Prepared" then
			return false, "invalid-personal-teleporter-prepared"
		end
		local summary = capability.summary
		local record = capability.record
		if
			config.records[summary.player] ~= record
			or summary.player:GetAttribute("Q3EngineAlive") ~= true
			or record.state ~= capability.baseState
			or record.revision ~= summary.baseRevision
			or record.lifeBinding ~= summary.lifeBinding
		then
			return false, "stale-personal-teleporter-prepared"
		end
		return true, nil
	end

	function runtime:ApplyPrepared(value: unknown): ApplyReceipt?
		local prepared = if type(value) == "table" then value :: Prepared else nil
		local capability = if prepared then capabilities[prepared] else nil
		if not capability or select(1, self:CanApplyPrepared(prepared)) ~= true then
			return nil
		end
		local summary = capability.summary
		if
			not self:ApplyAuthored(
				summary.player,
				capability.record,
				summary.position,
				summary.look,
				summary.velocity,
				summary.movementTime,
				nil
			)
		then
			return nil
		end
		capability.status = "Applied"
		capabilities[prepared] = nil
		return table.freeze({
			player = summary.player,
			baseRevision = summary.baseRevision,
			nextRevision = capability.record.revision,
		})
	end

	function runtime:AbortPrepared(value: unknown): boolean
		local prepared = if type(value) == "table" then value :: Prepared else nil
		local capability = if prepared then capabilities[prepared] else nil
		if not capability or capability.status ~= "Prepared" then
			return false
		end
		capability.status = "Aborted"
		capabilities[prepared] = nil
		return true
	end

	return runtime
end

return table.freeze(MovementTeleportRuntime)
