--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure numeric entity-frame cursor translated from Quake III Arena:
  code/game/g_main.c (G_RunFrame)
  code/game/g_utils.c (G_Spawn)

G_RunFrame tests `i < level.num_entities` on every loop iteration. It does not
snapshot the upper bound before the loop. An entity allocated by an earlier
visit can therefore extend the live numeric range and be visited later in the
same frame. Every numeric slot in the covered range is inspected exactly once;
inactive slots are skipped without collapsing the range.

Luau sourceOrder is entityNum + 1. Opaque immutable linear cursors are a Roblox
Arena authority adaptation: consuming one cursor retires it so a dispatcher
cannot accidentally fork or replay part of the authoritative entity pass.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type StepKind = "Visit" | "Skip" | "Complete"

export type Cursor = {
	read rangeStartSourceOrder: number,
	read nextSourceOrder: number,
	read coveredThrough: number,
	read visitCount: number,
	read skipCount: number,
	read upperBoundReadCount: number,
	read lastUpperBound: number,
	read complete: boolean,
}

export type Step = {
	read kind: StepKind,
	read sourceOrder: number?,
	read upperBound: number,
	read coveredThrough: number,
}

type CursorData = {
	rangeStartSourceOrder: number,
	nextSourceOrder: number,
	coveredThrough: number,
	visitCount: number,
	skipCount: number,
	upperBoundReadCount: number,
	lastUpperBound: number,
	complete: boolean,
}

type CursorCapability = {
	current: boolean,
	data: CursorData,
}

local EntityFrameTraversalRules = {}

-- q_shared.h: ENTITYNUM_WORLD is 1022, so normal gentities end at entityNum
-- 1021. One-based source order therefore ends at 1022.
local MAXIMUM_NORMAL_SOURCE_ORDER = 1022
local FIRST_SOURCE_ORDER = 1
local MAXIMUM_START_SOURCE_ORDER = MAXIMUM_NORMAL_SOURCE_ORDER + 1

local cursorCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[table]: CursorCapability,
}

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function makeCursor(data: CursorData): Cursor
	local cursor: Cursor = table.freeze({
		rangeStartSourceOrder = data.rangeStartSourceOrder,
		nextSourceOrder = data.nextSourceOrder,
		coveredThrough = data.coveredThrough,
		visitCount = data.visitCount,
		skipCount = data.skipCount,
		upperBoundReadCount = data.upperBoundReadCount,
		lastUpperBound = data.lastUpperBound,
		complete = data.complete,
	})
	cursorCapabilities[cursor :: table] = {
		current = true,
		data = data,
	}
	return cursor
end

local function currentCursor(value: unknown): (CursorCapability?, string?)
	if type(value) ~= "table" then
		return nil, "entity-frame-cursor-not-capability"
	end
	local capability = cursorCapabilities[value :: table]
	if not capability then
		return nil, "entity-frame-cursor-not-capability"
	end
	if not capability.current then
		return nil, "entity-frame-cursor-not-current"
	end
	local cursor = value :: Cursor
	local data = capability.data
	if
		not table.isfrozen(value :: any)
		or cursor.rangeStartSourceOrder ~= data.rangeStartSourceOrder
		or cursor.nextSourceOrder ~= data.nextSourceOrder
		or cursor.coveredThrough ~= data.coveredThrough
		or cursor.visitCount ~= data.visitCount
		or cursor.skipCount ~= data.skipCount
		or cursor.upperBoundReadCount ~= data.upperBoundReadCount
		or cursor.lastUpperBound ~= data.lastUpperBound
		or cursor.complete ~= data.complete
	then
		return nil, "entity-frame-cursor-capability-mismatch"
	end
	return capability, nil
end

local function makeStep(kind: StepKind, sourceOrder: number?, upperBound: number, coveredThrough: number): Step
	return table.freeze({
		kind = kind,
		sourceOrder = sourceOrder,
		upperBound = upperBound,
		coveredThrough = coveredThrough,
	})
end

local function beginAt(firstSourceOrder: number): Cursor
	return makeCursor({
		rangeStartSourceOrder = firstSourceOrder,
		nextSourceOrder = firstSourceOrder,
		coveredThrough = firstSourceOrder - 1,
		visitCount = 0,
		skipCount = 0,
		upperBoundReadCount = 0,
		lastUpperBound = firstSourceOrder - 1,
		complete = false,
	})
end

function EntityFrameTraversalRules.Begin(): Cursor
	return beginAt(FIRST_SOURCE_ORDER)
end

-- Begins a suffix traversal after an earlier coordinator has authoritatively
-- handled every source order below firstSourceOrder. coveredThrough therefore
-- starts at firstSourceOrder - 1, while visit/skip counts describe only this
-- cursor's suffix. MAXIMUM_NORMAL_SOURCE_ORDER + 1 is a valid empty suffix.
function EntityFrameTraversalRules.BeginAt(firstSourceOrderValue: unknown): (Cursor?, string?)
	if not isIntegerInRange(firstSourceOrderValue, FIRST_SOURCE_ORDER, MAXIMUM_START_SOURCE_ORDER) then
		return nil, "invalid-entity-frame-first-source-order"
	end
	return beginAt(firstSourceOrderValue :: number), nil
end

function EntityFrameTraversalRules.Inspect(cursorValue: unknown): (Cursor?, string?)
	local _, cursorError = currentCursor(cursorValue)
	if cursorError then
		return nil, cursorError
	end
	return cursorValue :: Cursor, nil
end

-- The caller must reread its committed EntitySlot upper bound immediately
-- before every call. When nextSourceOrder is inside that range it must inspect
-- that exact slot and pass whether a live registration was found. Passing nil
-- is reserved for the terminating condition, matching the loop condition that
-- runs before Q3 dereferences the next gentity.
function EntityFrameTraversalRules.Advance(
	cursorValue: unknown,
	upperBoundValue: unknown,
	occupiedValue: unknown
): (Cursor?, Step?, string?)
	local capability, cursorError = currentCursor(cursorValue)
	if not capability then
		return nil, nil, cursorError
	end
	local data = capability.data
	if data.complete then
		return nil, nil, "entity-frame-traversal-complete"
	end
	if not isIntegerInRange(upperBoundValue, 0, MAXIMUM_NORMAL_SOURCE_ORDER) then
		return nil, nil, "invalid-entity-frame-upper-bound"
	end
	local upperBound = upperBoundValue :: number
	if upperBound < data.lastUpperBound or upperBound < data.coveredThrough then
		return nil, nil, "regressing-entity-frame-upper-bound"
	end

	local nextData: CursorData = {
		rangeStartSourceOrder = data.rangeStartSourceOrder,
		nextSourceOrder = data.nextSourceOrder,
		coveredThrough = data.coveredThrough,
		visitCount = data.visitCount,
		skipCount = data.skipCount,
		upperBoundReadCount = data.upperBoundReadCount + 1,
		lastUpperBound = upperBound,
		complete = false,
	}
	local step: Step
	if data.nextSourceOrder > upperBound then
		if occupiedValue ~= nil then
			return nil, nil, "completed-range-has-slot-observation"
		end
		nextData.complete = true
		step = makeStep("Complete", nil, upperBound, data.coveredThrough)
	else
		if type(occupiedValue) ~= "boolean" then
			return nil, nil, "invalid-entity-frame-slot-observation"
		end
		local sourceOrder = data.nextSourceOrder
		nextData.nextSourceOrder = sourceOrder + 1
		nextData.coveredThrough = sourceOrder
		if occupiedValue :: boolean then
			nextData.visitCount += 1
			step = makeStep("Visit", sourceOrder, upperBound, sourceOrder)
		else
			nextData.skipCount += 1
			step = makeStep("Skip", sourceOrder, upperBound, sourceOrder)
		end
	end

	local nextCursor = makeCursor(nextData)
	capability.current = false
	return nextCursor, step, nil
end

EntityFrameTraversalRules.FirstSourceOrder = FIRST_SOURCE_ORDER
EntityFrameTraversalRules.MaximumNormalSourceOrder = MAXIMUM_NORMAL_SOURCE_ORDER
EntityFrameTraversalRules.MaximumStartSourceOrder = MAXIMUM_START_SOURCE_ORDER

return table.freeze(EntityFrameTraversalRules)
