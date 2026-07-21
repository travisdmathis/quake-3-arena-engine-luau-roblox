--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure prediction-basis reconciliation policy translated from:
  code/cgame/cg_predict.c (snapshot discontinuities and command-backup replay)
  code/game/bg_public.h (pmtype_t Normal/Dead branch identity)

A mover-clock revision is an independent Roblox authoritative discontinuity:
command history encoded against the old collision frame cannot be retained or
replayed even when the player movement revision itself is unchanged.
Likewise, incomplete command history cannot retain a predicted state across a
Normal/Dead Pmove branch change.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.MoverClock)

export type Action = "Reconcile" | "RetainIncompleteHistory" | "HardReset"
export type PmoveType = "Normal" | "Dead"
export type Reason =
	"CompleteHistory"
	| "IncompleteHistory"
	| "InitialBasis"
	| "MovementRevisionChanged"
	| "MoverRevisionChanged"
	| "PmoveTypeChanged"

export type Decision = {
	action: Action,
	reason: Reason,
	clearCommandHistory: boolean,
	resetMoverBasis: boolean,
	retainPredictedState: boolean,
	retainMoverBasis: boolean,
	preserveCommandSequence: boolean,
}

local PredictionReconciliationRules = {}

local MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991

local Action = table.freeze({
	Reconcile = "Reconcile" :: "Reconcile",
	RetainIncompleteHistory = "RetainIncompleteHistory" :: "RetainIncompleteHistory",
	HardReset = "HardReset" :: "HardReset",
})

local Reason = table.freeze({
	CompleteHistory = "CompleteHistory" :: "CompleteHistory",
	IncompleteHistory = "IncompleteHistory" :: "IncompleteHistory",
	InitialBasis = "InitialBasis" :: "InitialBasis",
	MovementRevisionChanged = "MovementRevisionChanged" :: "MovementRevisionChanged",
	MoverRevisionChanged = "MoverRevisionChanged" :: "MoverRevisionChanged",
	PmoveTypeChanged = "PmoveTypeChanged" :: "PmoveTypeChanged",
})

local PmoveType = table.freeze({
	Normal = "Normal" :: "Normal",
	Dead = "Dead" :: "Dead",
})

local function isBoundedInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isMovementRevision(value: unknown): boolean
	return isBoundedInteger(value, 1, MAXIMUM_SAFE_INTEGER)
end

local function isMoverRevision(value: unknown): boolean
	return isBoundedInteger(value, 1, MoverClock.MaximumRevision)
end

local function isPmoveType(value: unknown): boolean
	return value == PmoveType.Normal or value == PmoveType.Dead
end

local function hardReset(reason: Reason): Decision
	local decision: Decision = {
		action = Action.HardReset,
		reason = reason,
		clearCommandHistory = true,
		resetMoverBasis = true,
		retainPredictedState = false,
		retainMoverBasis = false,
		-- Snapshot discontinuities never rewind the outbound serial number. The
		-- next locally generated command remains CommandSequence.Next(previous).
		preserveCommandSequence = true,
	}
	table.freeze(decision)
	return decision
end

function PredictionReconciliationRules.Resolve(
	currentMovementRevisionValue: unknown,
	incomingMovementRevisionValue: unknown,
	activeMoverRevisionValue: unknown,
	incomingMoverRevisionValue: unknown,
	hasIncompleteHistoryValue: unknown,
	currentPmoveTypeValue: unknown,
	incomingPmoveTypeValue: unknown
): (Decision?, string?)
	if currentMovementRevisionValue ~= nil and not isMovementRevision(currentMovementRevisionValue) then
		return nil, "invalid-current-movement-revision"
	end
	if not isMovementRevision(incomingMovementRevisionValue) then
		return nil, "invalid-incoming-movement-revision"
	end
	if activeMoverRevisionValue ~= nil and not isMoverRevision(activeMoverRevisionValue) then
		return nil, "invalid-active-mover-revision"
	end
	if not isMoverRevision(incomingMoverRevisionValue) then
		return nil, "invalid-incoming-mover-revision"
	end
	if type(hasIncompleteHistoryValue) ~= "boolean" then
		return nil, "invalid-incomplete-history"
	end
	if not isPmoveType(currentPmoveTypeValue) then
		return nil, "invalid-current-pmove-type"
	end
	if not isPmoveType(incomingPmoveTypeValue) then
		return nil, "invalid-incoming-pmove-type"
	end

	if currentMovementRevisionValue == nil or activeMoverRevisionValue == nil then
		return hardReset(Reason.InitialBasis), nil
	elseif currentMovementRevisionValue ~= incomingMovementRevisionValue then
		return hardReset(Reason.MovementRevisionChanged), nil
	elseif activeMoverRevisionValue ~= incomingMoverRevisionValue then
		return hardReset(Reason.MoverRevisionChanged), nil
	elseif currentPmoveTypeValue ~= incomingPmoveTypeValue then
		if hasIncompleteHistoryValue then
			-- The retained prediction belongs to the previous Pmove branch. In
			-- particular, an alive state must never survive a Normal -> Dead
			-- snapshot just because its replay prefix has already fallen out of
			-- the command backup window.
			return hardReset(Reason.PmoveTypeChanged), nil
		end

		local decision: Decision = {
			action = Action.Reconcile,
			reason = Reason.PmoveTypeChanged,
			clearCommandHistory = false,
			resetMoverBasis = false,
			retainPredictedState = false,
			retainMoverBasis = false,
			preserveCommandSequence = true,
		}
		table.freeze(decision)
		return decision, nil
	elseif hasIncompleteHistoryValue then
		local decision: Decision = {
			action = Action.RetainIncompleteHistory,
			reason = Reason.IncompleteHistory,
			clearCommandHistory = false,
			resetMoverBasis = false,
			retainPredictedState = true,
			retainMoverBasis = true,
			preserveCommandSequence = true,
		}
		table.freeze(decision)
		return decision, nil
	end

	local decision: Decision = {
		action = Action.Reconcile,
		reason = Reason.CompleteHistory,
		clearCommandHistory = false,
		resetMoverBasis = false,
		retainPredictedState = false,
		retainMoverBasis = false,
		preserveCommandSequence = true,
	}
	table.freeze(decision)
	return decision, nil
end

PredictionReconciliationRules.Action = Action
PredictionReconciliationRules.Reason = Reason
PredictionReconciliationRules.PmoveType = PmoveType
PredictionReconciliationRules.MaximumMovementRevision = MAXIMUM_SAFE_INTEGER

return table.freeze(PredictionReconciliationRules)
