--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox adaptation of the two-flag state machine and executed return timing from:
  code/game/g_items.c (LaunchItem hardcoded 30000 ms dropped-item think)
  code/game/g_team.c
  code/game/g_team.h (unused CTF_FLAG_RETURN_TIME declaration)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

export type TeamId = "Red" | "Blue"
export type FlagState = "AtBase" | "Carried" | "Dropped"
export type EventKind = "PickedUp" | "Dropped" | "Returned" | "Captured" | "Reset"

export type FlagSnapshotEntry = {
	teamId: TeamId,
	state: FlagState,
	revision: number,
	carrierUserId: number?,
	position: Vector3,
	basePosition: Vector3,
	returnAt: number?,
}

export type Snapshot = {
	protocolVersion: number,
	sequence: number,
	session: number,
	active: boolean,
	modeId: string,
	matchState: string,
	serverTime: number,
	flags: { [string]: FlagSnapshotEntry },
}

export type Event = {
	protocolVersion: number,
	sequence: number,
	eventId: string,
	kind: EventKind,
	flagTeamId: TeamId?,
	scoringTeamId: TeamId?,
	actorUserId: number?,
	position: Vector3?,
	reason: string?,
	teamScore: number?,
	matchEnded: boolean?,
	serverTime: number,
}

local FlagDefinitions = {}

FlagDefinitions.ProtocolVersion = 1
FlagDefinitions.ModeId = "CaptureTheFlag"
FlagDefinitions.LiveState = "Live"

FlagDefinitions.TeamIds = table.freeze({
	Red = "Red" :: TeamId,
	Blue = "Blue" :: TeamId,
})

FlagDefinitions.TeamOrder = table.freeze({
	FlagDefinitions.TeamIds.Red,
	FlagDefinitions.TeamIds.Blue,
})

FlagDefinitions.TeamColors = table.freeze({
	[FlagDefinitions.TeamIds.Red] = Color3.fromRGB(255, 72, 67),
	[FlagDefinitions.TeamIds.Blue] = Color3.fromRGB(64, 176, 255),
})

FlagDefinitions.States = table.freeze({
	AtBase = "AtBase" :: FlagState,
	Carried = "Carried" :: FlagState,
	Dropped = "Dropped" :: FlagState,
})

FlagDefinitions.Events = table.freeze({
	PickedUp = "PickedUp" :: EventKind,
	Dropped = "Dropped" :: EventKind,
	Returned = "Returned" :: EventKind,
	Captured = "Captured" :: EventKind,
	Reset = "Reset" :: EventKind,
})

-- CTF flag markers are invisible/anchored BaseParts authored into the arena world.
-- ArenaFlagTeam is authoritative; the canonical names are a convenient fallback.
FlagDefinitions.MarkerTeamAttribute = "ArenaFlagTeam"
FlagDefinitions.MarkerNames = table.freeze({
	[FlagDefinitions.TeamIds.Red] = "RedFlagBase",
	[FlagDefinitions.TeamIds.Blue] = "BlueFlagBase",
})

FlagDefinitions.NetworkFolderName = "Network"
FlagDefinitions.SnapshotRemoteName = "FlagSnapshot"
FlagDefinitions.EventRemoteName = "FlagEvent"

FlagDefinitions.ScanIntervalSeconds = 1 / 20
FlagDefinitions.SnapshotIntervalSeconds = 0.25
-- LaunchItem schedules Team_DroppedFlagThink at level.time + 30000. The
-- CTF_FLAG_RETURN_TIME 40000 declaration in g_team.h is not consumed here.
FlagDefinitions.DroppedReturnSeconds = 30
FlagDefinitions.FlagTouchRadius = 4.5
FlagDefinitions.BaseTouchPadding = 3.5

FlagDefinitions.FlagAtBaseOffset = Vector3.new(0, 2.25, 0)
FlagDefinitions.FlagDroppedOffset = Vector3.new(0, 1.9, 0)
FlagDefinitions.FlagCarrierOffset = Vector3.new(0, 2.4, 1.4)

function FlagDefinitions.IsTeamId(value: unknown): boolean
	return value == FlagDefinitions.TeamIds.Red or value == FlagDefinitions.TeamIds.Blue
end

function FlagDefinitions.OtherTeam(teamId: TeamId): TeamId
	if teamId == FlagDefinitions.TeamIds.Red then
		return FlagDefinitions.TeamIds.Blue
	end
	return FlagDefinitions.TeamIds.Red
end

function FlagDefinitions.IsFlagState(value: unknown): boolean
	return value == FlagDefinitions.States.AtBase
		or value == FlagDefinitions.States.Carried
		or value == FlagDefinitions.States.Dropped
end

function FlagDefinitions.IsEventKind(value: unknown): boolean
	return value == FlagDefinitions.Events.PickedUp
		or value == FlagDefinitions.Events.Dropped
		or value == FlagDefinitions.Events.Returned
		or value == FlagDefinitions.Events.Captured
		or value == FlagDefinitions.Events.Reset
end

function FlagDefinitions.IsActiveFlow(modeId: unknown, matchState: unknown): boolean
	return modeId == FlagDefinitions.ModeId and matchState == FlagDefinitions.LiveState
end

function FlagDefinitions.IsFiniteVector3(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return vector.X == vector.X
		and vector.Y == vector.Y
		and vector.Z == vector.Z
		and math.abs(vector.X) < math.huge
		and math.abs(vector.Y) < math.huge
		and math.abs(vector.Z) < math.huge
end

function FlagDefinitions.IsWithinRadius(left: Vector3, right: Vector3, radius: number): boolean
	local offset = left - right
	return offset:Dot(offset) <= radius * radius
end

return table.freeze(FlagDefinitions)
