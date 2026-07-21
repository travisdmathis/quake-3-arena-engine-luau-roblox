--[[
SPDX-License-Identifier: GPL-2.0-or-later

Translated from Rocket Arena 3 round-state behavior in:
  ra3-sdk/code/game/arena.c (arena_think)

Upstream commit: 0693b7831ea303b2a93ec34c1802b33e684df046
Modified for the Roblox Luau port on 2026-07-19.
]]

--!strict

-- Rocket Arena 3 keeps three distinct timed phases:
--   ROUND_COUNTDOWN_MATCH = 10 seconds
--   ROUND_OVER = 3 seconds
--   ROUND_COUNTDOWN_ROUND = 5 seconds
-- Source: ra3_176_decomp/ra3-sdk/code/game/arena.c::arena_think.
--
-- the Roblox Luau port preserves the existing public MatchConfig.Countdown state and
-- distinguishes the two post-live phases with roundStatus:
--   Resolved  -> ROUND_OVER
--   Preparing -> ROUND_COUNTDOWN_ROUND

local RocketArenaRoundTimingRules = {}

export type TimingRules = {
	read CountdownSeconds: number,
	read RoundBreakSeconds: number,
	read RoundCountdownSeconds: number,
}

export type CountdownExpiryDisposition = "EnterLive" | "PrepareNextRound"

local function isDuration(value: unknown): boolean
	return type(value) == "number" and value == value and value < math.huge and value >= 0
end

function RocketArenaRoundTimingRules.GetCountdownDuration(rules: TimingRules, nextRound: boolean): number?
	local duration = if nextRound then rules.RoundCountdownSeconds else rules.CountdownSeconds
	return if isDuration(duration) then duration else nil
end

function RocketArenaRoundTimingRules.GetRoundOverDuration(rules: TimingRules): number?
	return if isDuration(rules.RoundBreakSeconds) then rules.RoundBreakSeconds else nil
end

function RocketArenaRoundTimingRules.GetCountdownExpiryDisposition(
	roundBased: boolean,
	roundStatus: string
): CountdownExpiryDisposition
	if roundBased and roundStatus == "Resolved" then
		return "PrepareNextRound"
	end
	return "EnterLive"
end

function RocketArenaRoundTimingRules.ShouldAdvanceRound(winnerTeamCount: number, winnerUserCount: number): boolean
	return winnerTeamCount == 1 or (winnerTeamCount == 0 and winnerUserCount == 1)
end

return table.freeze(RocketArenaRoundTimingRules)
