--[[
SPDX-License-Identifier: GPL-2.0-or-later

Deterministic mover-body collection translated from Quake III Arena:
  code/game/g_main.c (G_RunFrame entity-number traversal)
  code/game/g_combat.c (player_die PM_DEAD/CONTENTS_CORPSE transition)
  code/game/g_active.c (ClientThink_real dead-client collision state)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local Constants = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Constants"))
local Movement = require(sharedRoot:WaitForChild("simulation"):WaitForChild("Movement"))
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))

local MovementMoverBodyRuntime = {}

export type Record = {
	state: Movement.State?,
	character: Model?,
	lifeBinding: unknown?,
	deadState: Movement.DeadState?,
	moverBodySourceOrder: number,
	moverBodyId: string,
}

export type Binding =
	{
		kind: "LivePlayer",
		player: Player,
		record: Record,
	}
	| {
		kind: "ClientCorpse",
		player: Player,
	}
	| {
		kind: "Item",
		bodyId: string,
	}
	| {
		kind: "BodyQueue",
		bodyId: string,
		queueIndex: number,
	}

export type CorpseCollector = (
	token: unknown
) -> ({ MoverPushRules.Body }?, { [string]: Player }?, string?)
export type BodyQueueCollector = () -> ({ MoverPushRules.Body }, { [string]: number })
export type ParticipantCollector = () -> MoverItemFlagParticipantRules.Collection

function MovementMoverBodyRuntime.LivePlayerBody(record: Record): MoverPushRules.Body?
	local state = record.state
	local character = record.character
	if not state or not character or not character.Parent then
		return nil
	end
	local body: MoverPushRules.Body = {
		id = record.moverBodyId,
		sourceOrder = record.moverBodySourceOrder,
		position = state.position,
		size = Constants.ColliderSizeFor(state.crouched),
		centerOffset = Constants.ColliderCenterOffsetFor(state.crouched),
		velocity = state.velocity,
		groundMoverId = state.groundMoverId,
		contents = MoverPushRules.Contents.Body,
		clipMask = MoverPushRules.Masks.PlayerSolid,
	}
	table.freeze(body)
	return body
end

function MovementMoverBodyRuntime.Collect(
	records: { [Player]: Record },
	corpseCollector: CorpseCollector?,
	damageToken: unknown?,
	bodyQueueCollector: BodyQueueCollector?,
	participantCollector: ParticipantCollector?
): ({ MoverPushRules.Body }, { [string]: Binding })
	local bodies: { MoverPushRules.Body } = {}
	local bindings: { [string]: Binding } = {}
	for player, record in records do
		local body = MovementMoverBodyRuntime.LivePlayerBody(record)
		-- player_die changes the one client entity to PM_DEAD/CONTENTS_CORPSE
		-- before later entities run. ArenaAlive is post-close presentation and can
		-- still say true inside that death frame, so only Movement's private exact-
		-- life state may decide whether the client contributes a live mover body.
		if body and record.lifeBinding ~= nil and record.deadState == nil then
			local id = body.id
			table.insert(bodies, body)
			bindings[id] = { kind = "LivePlayer", player = player, record = record }
		end
	end
	if corpseCollector and damageToken ~= nil then
		local corpseBodies, corpsePlayersByBodyId, corpseError = corpseCollector(damageToken)
		assert(corpseBodies, corpseError or "mover corpse collection failed")
		assert(corpsePlayersByBodyId, corpseError or "mover corpse bindings failed")
		for _, body in corpseBodies do
			assert(bindings[body.id] == nil, "mover corpse duplicated a live body identity")
			local player = corpsePlayersByBodyId[body.id]
			assert(player, "mover corpse body has no trusted player binding")
			table.insert(bodies, body)
			bindings[body.id] = { kind = "ClientCorpse", player = player }
		end
	end
	if bodyQueueCollector then
		local bodyQueueBodies, queueIndexByBodyId = bodyQueueCollector()
		for _, body in bodyQueueBodies do
			assert(bindings[body.id] == nil, "BodyQueue mover body identity collided")
			local queueIndex =
				assert(queueIndexByBodyId[body.id], "BodyQueue mover body omitted its queue index")
			table.insert(bodies, body)
			bindings[body.id] = { kind = "BodyQueue", bodyId = body.id, queueIndex = queueIndex }
		end
	end
	if participantCollector then
		local collection = participantCollector()
		for _, body in collection.bodies do
			assert(bindings[body.id] == nil, "Item mover participant duplicated a body identity")
			table.insert(bodies, body :: any)
			bindings[body.id] = { kind = "Item", bodyId = body.id }
		end
	end
	return bodies, bindings
end

return MovementMoverBodyRuntime
