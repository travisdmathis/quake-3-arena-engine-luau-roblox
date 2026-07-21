--[[
SPDX-License-Identifier: GPL-2.0-or-later

Shared owner-snapshot phase invariants translated from playerState_t pm_type
and viewheight handling in code/game/bg_pmove.c and code/game/bg_public.h.

This module validates only the phase envelope. The complete Movement.State and
mover snapshot retain their existing validators.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type PmoveType = "Normal" | "Dead"
export type Phase = {
	read pmType: PmoveType,
	read viewHeight: number,
	read deadLifeSequence: number?,
	read deadYawDegrees: number?,
}
export type DeadEntryContract = {
	-- player_die selects PM_DEAD without changing ps.viewheight. The next
	-- PmoveSingle samples water once through this retained alive height before
	-- PM_CheckDuck installs DEAD_VIEWHEIGHT.
	read initialViewHeight: number,
	read firstStepPhase: Phase,
}

local MovementPhaseRules = {}

local MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991
local MAXIMUM_ENTITY_ANGLE = 1_000_000

local PmoveType = table.freeze({
	Normal = "Normal" :: "Normal",
	Dead = "Dead" :: "Dead",
})

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

function MovementPhaseRules.Validate(
	pmTypeValue: unknown,
	viewHeightValue: unknown,
	crouchedValue: unknown,
	deadLifeSequenceValue: unknown,
	deadYawDegreesValue: unknown
): (Phase?, string?)
	if pmTypeValue ~= PmoveType.Normal and pmTypeValue ~= PmoveType.Dead then
		return nil, "invalid-movement-pm-type"
	end
	if type(crouchedValue) ~= "boolean" then
		return nil, "invalid-movement-phase-crouched"
	end
	if type(viewHeightValue) ~= "number" or viewHeightValue ~= viewHeightValue then
		return nil, "invalid-movement-viewheight"
	end

	if pmTypeValue == PmoveType.Normal then
		if
			viewHeightValue ~= Constants.ViewHeightFor(crouchedValue)
			or deadLifeSequenceValue ~= nil
			or deadYawDegreesValue ~= nil
		then
			return nil, "invalid-normal-movement-phase"
		end
	else
		if
			viewHeightValue ~= Constants.DeadViewHeight
			or not isInteger(deadLifeSequenceValue, 1, MAXIMUM_SAFE_INTEGER)
			or not isInteger(deadYawDegreesValue, -MAXIMUM_ENTITY_ANGLE, MAXIMUM_ENTITY_ANGLE)
		then
			return nil, "invalid-dead-movement-phase"
		end
	end

	local phase: Phase = {
		pmType = pmTypeValue :: PmoveType,
		viewHeight = viewHeightValue,
		deadLifeSequence = deadLifeSequenceValue :: number?,
		deadYawDegrees = deadYawDegreesValue :: number?,
	}
	table.freeze(phase)
	return phase, nil
end

function MovementPhaseRules.CreateDeadEntryContract(
	crouchedValue: unknown,
	deadLifeSequenceValue: unknown,
	deadYawDegreesValue: unknown
): (DeadEntryContract?, string?)
	if type(crouchedValue) ~= "boolean" then
		return nil, "invalid-dead-entry-crouched"
	end
	local firstStepPhase, phaseError = MovementPhaseRules.Validate(
		PmoveType.Dead,
		Constants.DeadViewHeight,
		crouchedValue,
		deadLifeSequenceValue,
		deadYawDegreesValue
	)
	if not firstStepPhase then
		return nil, phaseError or "invalid-dead-entry-phase"
	end
	local contract: DeadEntryContract = {
		initialViewHeight = Constants.ViewHeightFor(crouchedValue),
		firstStepPhase = firstStepPhase,
	}
	table.freeze(contract)
	return contract, nil
end

MovementPhaseRules.PmoveType = PmoveType
MovementPhaseRules.MaximumDeadYawMagnitude = MAXIMUM_ENTITY_ANGLE

return table.freeze(MovementPhaseRules)
