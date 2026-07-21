--!strict

local ModeIds = require(script.Parent.ModeIds)

export type ModeId = ModeIds.ModeId

local validModeIds: { [string]: boolean } = {
	[ModeIds.Deathmatch] = true,
	[ModeIds.OneShot] = true,
	[ModeIds.Duel] = true,
	[ModeIds.TeamDeathmatch] = true,
	[ModeIds.CaptureTheFlag] = true,
	[ModeIds.ArenaElimination] = true,
}
table.freeze(validModeIds)

local safeStates: { [string]: boolean } = {
	Waiting = true,
	Warmup = true,
	Intermission = true,
}
table.freeze(safeStates)

local ResponseCodes = table.freeze({
	Changed = "Changed",
	VoteRecorded = "VoteRecorded",
	AlreadySelected = "AlreadySelected",
	InvalidRequest = "InvalidRequest",
	InvalidSequence = "InvalidSequence",
	UnknownMode = "UnknownMode",
	Unauthorized = "Unauthorized",
	UnsafePhase = "UnsafePhase",
	RateLimited = "RateLimited",
	GlobalCooldown = "GlobalCooldown",
	SelectionFailed = "SelectionFailed",
})

local function isModeId(value: unknown): boolean
	return type(value) == "string" and validModeIds[value] == true
end

local function isSafeState(value: unknown): boolean
	return type(value) == "string" and safeStates[value] == true
end

return table.freeze({
	RequestRemoteName = "ModeSelectionRequest",
	ToggleActionName = "Q3EngineToggleModeMenu",
	NavigationActionName = "Q3EngineNavigateModeMenu",
	MaximumSequence = 2_147_483_647,
	MinimumRequestIntervalSeconds = 0.75,
	RateWindowSeconds = 10,
	MaximumRequestsPerWindow = 5,
	GlobalChangeCooldownSeconds = 2.5,
	ModeOrder = table.freeze({
		ModeIds.Deathmatch,
		ModeIds.OneShot,
		ModeIds.Duel,
		ModeIds.TeamDeathmatch,
		ModeIds.CaptureTheFlag,
		ModeIds.ArenaElimination,
	}),
	ValidModeIds = validModeIds,
	SafeStates = safeStates,
	ResponseCodes = ResponseCodes,
	IsModeId = isModeId,
	IsSafeState = isSafeState,
})
