--[[
SPDX-License-Identifier: GPL-2.0-or-later

Typed presentation-only remote movement batching extracted from
MovementService. Authority remains in the caller's immutable fixed-step state;
this owner only orders, chunks, sequences, and publishes validated rows.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local CommandSequence = require(sharedRoot.simulation.CommandSequence)
local Constants = require(sharedRoot.simulation.Constants)
local RemoteInterpolationRules = require(sharedRoot.simulation.RemoteInterpolationRules)

export type Config = {
	records: { [Player]: any },
	isFaulted: () -> boolean,
	isFinite: (unknown) -> boolean,
	saturatedAdd: (number, number) -> number,
}

export type Metrics = {
	read batchCount: number,
	read packetCount: number,
	read rowCount: number,
}

export type Runtime = {
	SetRemote: (self: Runtime, remote: UnreliableRemoteEvent) -> (),
	Broadcast: (self: Runtime) -> (),
	AdvanceStepShouldBroadcast: (self: Runtime, requested: boolean) -> boolean,
	GetMetrics: (self: Runtime) -> Metrics,
}

local MovementRemoteRuntime = {}

local function horizontalLook(state: any): Vector3
	local look = Vector3.new(state.look.X, 0, state.look.Z)
	return if look.Magnitude < 1e-6 then Vector3.new(0, 0, -1) else look.Unit
end

local function aimPitchRadians(state: any): number
	local look = state.look
	local magnitude = look.Magnitude
	if magnitude < 1e-6 then
		return 0
	end
	return math.clamp(math.asin(math.clamp(look.Y / magnitude, -1, 1)), -math.pi / 2, math.pi / 2)
end

function MovementRemoteRuntime.new(config: Config): Runtime
	local remote: UnreliableRemoteEvent? = nil
	local batchSequence = 0
	local packetSequence = 0
	local step = 0
	local batchCount = 0
	local packetCount = 0
	local rowCount = 0
	local runtime = ({} :: any) :: Runtime

	function runtime:SetRemote(value: UnreliableRemoteEvent)
		remote = value
	end

	function runtime:Broadcast()
		if config.isFaulted() or not remote then
			return
		end
		local orderedPlayers = Players:GetPlayers()
		table.sort(orderedPlayers, function(left: Player, right: Player): boolean
			return if left.UserId == right.UserId
				then left.Name < right.Name
				else left.UserId < right.UserId
		end)
		local rows: { { any } } = {}
		for _, player in orderedPlayers do
			if #rows >= RemoteInterpolationRules.MaximumPlayersPerBatch then
				break
			end
			local record = config.records[player]
			local state = record and record.state
			local character = record and record.character
			local lifeSequence = player:GetAttribute("Q3EngineLifeSequence")
			if
				record
				and state
				and character
				and character.Parent
				and type(lifeSequence) == "number"
				and config.isFinite(lifeSequence)
				and lifeSequence % 1 == 0
				and lifeSequence >= 1
			then
				table.insert(rows, {
					player.UserId,
					character,
					lifeSequence,
					record.revision,
					state.frame,
					state.position,
					state.velocity,
					horizontalLook(state),
					state.crouched,
					player:GetAttribute("Q3EngineAlive") == true,
					state.grounded,
					aimPitchRadians(state),
				})
			end
		end
		if #rows == 0 then
			return
		end
		batchSequence = CommandSequence.Next(batchSequence)
		local serverTime = Workspace:GetServerTimeNow()
		local rawMatchId = sharedRoot:GetAttribute("Q3EngineMatchId")
		local matchId = if type(rawMatchId) == "string" then rawMatchId else ""
		local chunkSize = RemoteInterpolationRules.PacketChunkSize
		local chunkCount = math.ceil(#rows / chunkSize)
		batchCount = config.saturatedAdd(batchCount, 1)
		rowCount = config.saturatedAdd(rowCount, #rows)
		for chunkIndex = 1, chunkCount do
			local chunk: { { any } } = {}
			local firstIndex = (chunkIndex - 1) * chunkSize + 1
			local lastIndex = math.min(firstIndex + chunkSize - 1, #rows)
			for index = firstIndex, lastIndex do
				table.insert(chunk, rows[index])
			end
			packetSequence = CommandSequence.Next(packetSequence)
			remote:FireAllClients({
				RemoteInterpolationRules.ProtocolVersion,
				packetSequence,
				batchSequence,
				serverTime,
				matchId,
				chunkIndex,
				chunkCount,
				chunk,
			})
			packetCount = config.saturatedAdd(packetCount, 1)
		end
	end

	function runtime:AdvanceStepShouldBroadcast(requested: boolean): boolean
		step += 1
		return requested or step % Constants.SnapshotStepFrames == 0
	end

	function runtime:GetMetrics(): Metrics
		return table.freeze({
			batchCount = batchCount,
			packetCount = packetCount,
			rowCount = rowCount,
		})
	end

	return runtime
end

return table.freeze(MovementRemoteRuntime)
