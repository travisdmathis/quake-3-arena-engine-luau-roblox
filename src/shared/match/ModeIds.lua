--!strict

export type ModeId = "Deathmatch" | "OneShot" | "Duel" | "TeamDeathmatch" | "CaptureTheFlag" | "ArenaElimination"

-- These values are persistence/network identifiers. Display names may change; these must not.
local ModeIds = {
	Deathmatch = "Deathmatch" :: ModeId,
	OneShot = "OneShot" :: ModeId,
	Duel = "Duel" :: ModeId,
	TeamDeathmatch = "TeamDeathmatch" :: ModeId,
	CaptureTheFlag = "CaptureTheFlag" :: ModeId,
	ArenaElimination = "ArenaElimination" :: ModeId,
}
table.freeze(ModeIds)

return ModeIds
