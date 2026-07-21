--[[
SPDX-License-Identifier: GPL-2.0-or-later

Remote snapshot presentation adapted from selected behavior in:
  code/cgame/cg_snapshot.c (CG_ProcessSnapshots)
  code/cgame/cg_ents.c (CG_CalcEntityLerpPositions, CG_InterpolateEntityPosition)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local CommandSequence = require(script.Parent.CommandSequence)

export type Snapshot = {
	sequence: number,
	serverTime: number,
	frame: number,
	matchId: string,
	userId: number,
	character: Model,
	lifeSequence: number,
	revision: number,
	position: Vector3,
	velocity: Vector3,
	look: Vector3,
	crouched: boolean,
	grounded: boolean,
	aimPitchRadians: number,
}

export type Buffer = {
	snapshots: { Snapshot },
}

export type InsertDisposition =
	"Inserted"
	| "ResetIdentity"
	| "ResetGap"
	| "ResetTeleport"
	| "RejectedSequence"
	| "RejectedTime"

export type PoseMode = "Snapshot" | "Interpolated" | "Extrapolated" | "Frozen"

export type Pose = {
	position: Vector3,
	velocity: Vector3,
	look: Vector3,
	crouched: boolean,
	grounded: boolean,
	aimPitchRadians: number,
	serverTime: number,
	sequence: number,
	frame: number,
	revision: number,
	lifeSequence: number,
	matchId: string,
	userId: number,
	character: Model,
	mode: PoseMode,
	extrapolationSeconds: number,
	frozen: boolean,
}

local PROTOCOL_VERSION = 2
local INTERPOLATION_DELAY_SECONDS = 0.1
local MAXIMUM_EXTRAPOLATION_SECONDS = 0.1
local STALE_SNAPSHOT_SECONDS = 0.5
local MAXIMUM_SNAPSHOTS_PER_PLAYER = 32
local MAXIMUM_PLAYERS_PER_BATCH = 32
local MAXIMUM_SNAPSHOT_GAP_SECONDS = 0.25
local PACKET_CHUNK_SIZE = 4
local TELEPORT_SNAP_DISTANCE_STUDS = 128

local EPSILON = 1e-6
local TWO_PI = math.pi * 2
local DEFAULT_LOOK = Vector3.new(0, 0, -1)

local InsertDisposition = table.freeze({
	Inserted = "Inserted" :: "Inserted",
	ResetIdentity = "ResetIdentity" :: "ResetIdentity",
	ResetGap = "ResetGap" :: "ResetGap",
	ResetTeleport = "ResetTeleport" :: "ResetTeleport",
	RejectedSequence = "RejectedSequence" :: "RejectedSequence",
	RejectedTime = "RejectedTime" :: "RejectedTime",
})

local PoseMode = table.freeze({
	Snapshot = "Snapshot" :: "Snapshot",
	Interpolated = "Interpolated" :: "Interpolated",
	Extrapolated = "Extrapolated" :: "Extrapolated",
	Frozen = "Frozen" :: "Frozen",
})

local RemoteInterpolationRules = {
	ProtocolVersion = PROTOCOL_VERSION,
	InterpolationDelaySeconds = INTERPOLATION_DELAY_SECONDS,
	MaximumExtrapolationSeconds = MAXIMUM_EXTRAPOLATION_SECONDS,
	StaleSnapshotSeconds = STALE_SNAPSHOT_SECONDS,
	MaximumSnapshotsPerPlayer = MAXIMUM_SNAPSHOTS_PER_PLAYER,
	MaximumPlayersPerBatch = MAXIMUM_PLAYERS_PER_BATCH,
	MaximumSnapshotGapSeconds = MAXIMUM_SNAPSHOT_GAP_SECONDS,
	PacketChunkSize = PACKET_CHUNK_SIZE,
	TeleportSnapDistanceStuds = TELEPORT_SNAP_DISTANCE_STUDS,
	InsertDisposition = InsertDisposition,
	PoseMode = PoseMode,
}

local function isFiniteNumber(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function horizontalUnit(value: Vector3): Vector3
	local horizontal = Vector3.new(value.X, 0, value.Z)
	local magnitude = horizontal.Magnitude
	return if magnitude > EPSILON then horizontal / magnitude else DEFAULT_LOOK
end

local function interpolateHorizontalLook(left: Vector3, right: Vector3, alpha: number): Vector3
	local leftLook = horizontalUnit(left)
	local rightLook = horizontalUnit(right)
	local leftYaw = math.atan2(leftLook.X, leftLook.Z)
	local rightYaw = math.atan2(rightLook.X, rightLook.Z)
	local yawDelta = (rightYaw - leftYaw + math.pi) % TWO_PI - math.pi
	local yaw = leftYaw + yawDelta * alpha
	return Vector3.new(math.sin(yaw), 0, math.cos(yaw))
end

local function sameIdentity(left: Snapshot, right: Snapshot): boolean
	return left.matchId == right.matchId
		and left.userId == right.userId
		and left.character == right.character
		and left.lifeSequence == right.lifeSequence
		and left.revision == right.revision
end

local function clear(buffer: Buffer)
	table.clear(buffer.snapshots)
end

local function resetTo(buffer: Buffer, snapshot: Snapshot)
	clear(buffer)
	table.insert(buffer.snapshots, snapshot)
end

local function poseFromSnapshot(snapshot: Snapshot, mode: PoseMode): Pose
	return {
		position = snapshot.position,
		velocity = snapshot.velocity,
		look = horizontalUnit(snapshot.look),
		crouched = snapshot.crouched,
		grounded = snapshot.grounded,
		aimPitchRadians = snapshot.aimPitchRadians,
		serverTime = snapshot.serverTime,
		sequence = snapshot.sequence,
		frame = snapshot.frame,
		revision = snapshot.revision,
		lifeSequence = snapshot.lifeSequence,
		matchId = snapshot.matchId,
		userId = snapshot.userId,
		character = snapshot.character,
		mode = mode,
		extrapolationSeconds = 0,
		frozen = false,
	}
end

function RemoteInterpolationRules.NewBuffer(): Buffer
	return {
		snapshots = {},
	}
end

function RemoteInterpolationRules.Clear(buffer: Buffer)
	clear(buffer)
end

function RemoteInterpolationRules.Latest(buffer: Buffer): Snapshot?
	return buffer.snapshots[#buffer.snapshots]
end

function RemoteInterpolationRules.SameIdentity(left: Snapshot, right: Snapshot): boolean
	return sameIdentity(left, right)
end

function RemoteInterpolationRules.Insert(buffer: Buffer, snapshot: Snapshot): (boolean, InsertDisposition)
	if not CommandSequence.IsInRange(snapshot.sequence) then
		return false, InsertDisposition.RejectedSequence
	end
	if not isFiniteNumber(snapshot.serverTime) then
		return false, InsertDisposition.RejectedTime
	end

	local latest = RemoteInterpolationRules.Latest(buffer)
	if not latest then
		table.insert(buffer.snapshots, snapshot)
		return true, InsertDisposition.Inserted
	end
	if not CommandSequence.IsNewer(snapshot.sequence, latest.sequence) then
		return false, InsertDisposition.RejectedSequence
	end
	if snapshot.serverTime <= latest.serverTime then
		return false, InsertDisposition.RejectedTime
	end
	if not sameIdentity(latest, snapshot) then
		resetTo(buffer, snapshot)
		return true, InsertDisposition.ResetIdentity
	end
	if snapshot.serverTime - latest.serverTime > MAXIMUM_SNAPSHOT_GAP_SECONDS then
		resetTo(buffer, snapshot)
		return true, InsertDisposition.ResetGap
	end
	if (snapshot.position - latest.position).Magnitude >= TELEPORT_SNAP_DISTANCE_STUDS then
		resetTo(buffer, snapshot)
		return true, InsertDisposition.ResetTeleport
	end

	table.insert(buffer.snapshots, snapshot)
	while #buffer.snapshots > MAXIMUM_SNAPSHOTS_PER_PLAYER do
		table.remove(buffer.snapshots, 1)
	end
	return true, InsertDisposition.Inserted
end

function RemoteInterpolationRules.IsStale(buffer: Buffer, serverNow: number): boolean
	local latest = RemoteInterpolationRules.Latest(buffer)
	return latest == nil or not isFiniteNumber(serverNow) or serverNow - latest.serverTime >= STALE_SNAPSHOT_SECONDS
end

function RemoteInterpolationRules.Resolve(buffer: Buffer, serverNow: number): Pose?
	if not isFiniteNumber(serverNow) then
		return nil
	end

	local snapshots = buffer.snapshots
	local snapshotCount = #snapshots
	if snapshotCount == 0 then
		return nil
	end

	local targetServerTime = serverNow - INTERPOLATION_DELAY_SECONDS
	local oldest = snapshots[1]
	if targetServerTime <= oldest.serverTime then
		return poseFromSnapshot(oldest, PoseMode.Snapshot)
	end

	for index = 2, snapshotCount do
		local following = snapshots[index]
		if targetServerTime <= following.serverTime then
			local previous = snapshots[index - 1]
			local duration = following.serverTime - previous.serverTime
			if duration <= EPSILON then
				return poseFromSnapshot(following, PoseMode.Snapshot)
			end

			local alpha = math.clamp((targetServerTime - previous.serverTime) / duration, 0, 1)
			if alpha <= EPSILON then
				return poseFromSnapshot(previous, PoseMode.Snapshot)
			end
			if alpha >= 1 - EPSILON then
				return poseFromSnapshot(following, PoseMode.Snapshot)
			end
			return {
				position = previous.position:Lerp(following.position, alpha),
				velocity = previous.velocity:Lerp(following.velocity, alpha),
				look = interpolateHorizontalLook(previous.look, following.look, alpha),
				crouched = if alpha >= 0.5 then following.crouched else previous.crouched,
				grounded = if alpha >= 0.5 then following.grounded else previous.grounded,
				aimPitchRadians = previous.aimPitchRadians
					+ (following.aimPitchRadians - previous.aimPitchRadians) * alpha,
				serverTime = targetServerTime,
				sequence = previous.sequence,
				frame = previous.frame,
				revision = previous.revision,
				lifeSequence = previous.lifeSequence,
				matchId = previous.matchId,
				userId = previous.userId,
				character = previous.character,
				mode = PoseMode.Interpolated,
				extrapolationSeconds = 0,
				frozen = false,
			}
		end
	end

	local latest = snapshots[snapshotCount]
	local requestedExtrapolation = math.max(targetServerTime - latest.serverTime, 0)
	local extrapolationSeconds = math.min(requestedExtrapolation, MAXIMUM_EXTRAPOLATION_SECONDS)
	local frozen = requestedExtrapolation > MAXIMUM_EXTRAPOLATION_SECONDS
	return {
		position = latest.position + latest.velocity * extrapolationSeconds,
		velocity = latest.velocity,
		look = horizontalUnit(latest.look),
		crouched = latest.crouched,
		grounded = latest.grounded,
		aimPitchRadians = latest.aimPitchRadians,
		serverTime = latest.serverTime + extrapolationSeconds,
		sequence = latest.sequence,
		frame = latest.frame,
		revision = latest.revision,
		lifeSequence = latest.lifeSequence,
		matchId = latest.matchId,
		userId = latest.userId,
		character = latest.character,
		mode = if frozen then PoseMode.Frozen else PoseMode.Extrapolated,
		extrapolationSeconds = extrapolationSeconds,
		frozen = frozen,
	}
end

return table.freeze(RemoteInterpolationRules)
