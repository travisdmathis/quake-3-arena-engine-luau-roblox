--[[
SPDX-License-Identifier: GPL-2.0-or-later

Deterministic static-world plus mover collision composition translated from
Quake III Arena:
  code/server/sv_world.c (SV_Trace, SV_ClipMoveToEntities, SV_PointContents)
  code/game/bg_pmove.c (trace_t and pointcontents consumers)

Q3 traces the world first and replaces that result with a dynamic entity only
when the entity fraction is strictly smaller. The earlier result therefore
wins equal-time contacts. startsolid is accumulated independently, while the
decisive result owns allsolid and contact identity. This adapter applies those
rules to one immutable MoverCollisionFrame shared by Trace, CanOccupy, and
PointContents. Presentation geometry is never an input.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)
local Movement = require(script.Parent.Movement)
local MoverCollisionFrame = require(script.Parent.MoverCollisionFrame)
local MoverPushRules = require(script.Parent.MoverPushRules)
local WorldPointContents = require(script.Parent.WorldPointContents)

export type Queries = {
	frame: MoverCollisionFrame.Frame,
	trace: Movement.TraceFunction,
	canOccupy: Movement.CanOccupyFunction,
	pointContents: Movement.PointContentsFunction,
}

local MoverTraceComposition = {}

local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_CONTENTS_MASK = 4_294_967_295

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= MAXIMUM_COORDINATE
		and math.abs(vector.Y) <= MAXIMUM_COORDINATE
		and math.abs(vector.Z) <= MAXIMUM_COORDINATE
end

local function isContentsMask(value: unknown): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= 0
		and (value :: number) <= MAXIMUM_CONTENTS_MASK
end

local function optionalBoolean(value: unknown): boolean
	return value == nil or type(value) == "boolean"
end

local function validateStaticTrace(value: unknown): (Movement.TraceResult?, string?)
	if type(value) ~= "table" then
		return nil, "static-trace-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if type(source.hit) ~= "boolean" then
		return nil, "invalid-static-hit"
	end
	if not isFiniteNumber(source.fraction) or (source.fraction :: number) < 0 or (source.fraction :: number) > 1 then
		return nil, "invalid-static-fraction"
	end
	if not isBoundedVector(source.position) then
		return nil, "invalid-static-position"
	end
	if not isBoundedVector(source.normal) then
		return nil, "invalid-static-normal"
	end
	if source.moverId ~= nil then
		return nil, "static-trace-has-mover-id"
	end
	if not optionalBoolean(source.startSolid) then
		return nil, "invalid-static-start-solid"
	end
	if not optionalBoolean(source.allSolid) then
		return nil, "invalid-static-all-solid"
	end
	if not optionalBoolean(source.surfaceSlick) then
		return nil, "invalid-static-surface-slick"
	end
	if not optionalBoolean(source.surfaceNoDamage) then
		return nil, "invalid-static-surface-no-damage"
	end

	local hit = source.hit :: boolean
	local fraction = source.fraction :: number
	local startSolid = source.startSolid == true
	local allSolid = source.allSolid == true
	if not hit and fraction ~= 1 then
		return nil, "static-miss-fraction-not-one"
	end
	if allSolid and (not hit or not startSolid or fraction ~= 0) then
		return nil, "invalid-static-all-solid-invariants"
	end

	local result: Movement.TraceResult = {
		hit = hit,
		fraction = fraction,
		position = source.position :: Vector3,
		normal = source.normal :: Vector3,
		moverId = nil,
		startSolid = startSolid,
		allSolid = allSolid,
		surfaceSlick = source.surfaceSlick == true,
		surfaceNoDamage = source.surfaceNoDamage == true,
	}
	table.freeze(result)
	return result, nil
end

local function frozenFailClosedTrace(origin: Vector3): Movement.TraceResult
	local result: Movement.TraceResult = {
		hit = true,
		fraction = 0,
		position = origin,
		normal = Vector3.yAxis,
		moverId = nil,
		startSolid = true,
		allSolid = true,
		surfaceSlick = false,
		surfaceNoDamage = false,
	}
	table.freeze(result)
	return result
end

function MoverTraceComposition.Trace(
	frameValue: unknown,
	staticResultValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (Movement.TraceResult?, string?)
	local staticResult, staticError = validateStaticTrace(staticResultValue)
	if not staticResult then
		return nil, staticError
	end
	local moverResult, moverError = MoverCollisionFrame.Trace(
		frameValue,
		originValue,
		displacementValue,
		movingSizeValue,
		movingCenterOffsetValue,
		clipMaskValue
	)
	if not moverResult then
		return nil, "mover-trace:" .. (moverError or "invalid")
	end

	local startSolid = staticResult.startSolid == true or moverResult.startSolid
	if moverResult.hit and moverResult.fraction < staticResult.fraction then
		if typeof(originValue) ~= "Vector3" or typeof(displacementValue) ~= "Vector3" then
			return nil, "invalid-composed-position-input"
		end
		local result: Movement.TraceResult = {
			hit = true,
			fraction = moverResult.fraction,
			position = (originValue :: Vector3) + (displacementValue :: Vector3) * moverResult.fraction,
			normal = moverResult.normal,
			moverId = moverResult.moverId,
			startSolid = startSolid,
			allSolid = moverResult.allSolid,
			surfaceSlick = false,
			surfaceNoDamage = false,
		}
		table.freeze(result)
		return result, nil
	end

	-- Static/world was evaluated first. Retain it for equal fractions, clear any
	-- dynamic identity, and only accumulate startsolid from the mover frame.
	local result: Movement.TraceResult = {
		hit = staticResult.hit,
		fraction = staticResult.fraction,
		position = staticResult.position,
		normal = staticResult.normal,
		moverId = nil,
		startSolid = startSolid,
		allSolid = staticResult.allSolid,
		surfaceSlick = staticResult.surfaceSlick,
		surfaceNoDamage = staticResult.surfaceNoDamage,
	}
	table.freeze(result)
	return result, nil
end

function MoverTraceComposition.CanOccupy(
	frameValue: unknown,
	staticCanOccupyValue: unknown,
	originValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (boolean?, string?)
	if type(staticCanOccupyValue) ~= "boolean" then
		return nil, "invalid-static-can-occupy"
	end
	local moverCanOccupy, moverError =
		MoverCollisionFrame.CanOccupy(frameValue, originValue, movingSizeValue, movingCenterOffsetValue, clipMaskValue)
	if moverCanOccupy == nil then
		return nil, "mover-can-occupy:" .. (moverError or "invalid")
	end
	return (staticCanOccupyValue :: boolean) and moverCanOccupy, nil
end

function MoverTraceComposition.PointContents(
	frameValue: unknown,
	staticContentsValue: unknown,
	pointValue: unknown
): (number?, string?)
	if not isContentsMask(staticContentsValue) then
		return nil, "invalid-static-point-contents"
	end
	local moverContents, moverError = MoverCollisionFrame.PointContents(frameValue, pointValue)
	if moverContents == nil then
		return nil, "mover-point-contents:" .. (moverError or "invalid")
	end
	return bit32.bor(staticContentsValue :: number, moverContents), nil
end

function MoverTraceComposition.CreatePlayerQueries(
	frameValue: unknown,
	staticTraceValue: unknown,
	staticCanOccupyValue: unknown,
	staticPointContentsValue: unknown
): (Queries?, string?)
	if type(staticTraceValue) ~= "function" then
		return nil, "static-trace-not-function"
	end
	if type(staticCanOccupyValue) ~= "function" then
		return nil, "static-can-occupy-not-function"
	end
	if type(staticPointContentsValue) ~= "function" then
		return nil, "static-point-contents-not-function"
	end
	local _, frameError = MoverCollisionFrame.PointContents(frameValue, Vector3.zero)
	if frameError then
		return nil, "invalid-frame:" .. frameError
	end

	local frame = frameValue :: MoverCollisionFrame.Frame
	local staticTrace = staticTraceValue :: Movement.TraceFunction
	local staticCanOccupy = staticCanOccupyValue :: Movement.CanOccupyFunction
	local staticPointContents = staticPointContentsValue :: Movement.PointContentsFunction

	local function trace(origin: Vector3, displacement: Vector3, crouched: boolean): Movement.TraceResult
		local result = MoverTraceComposition.Trace(
			frame,
			staticTrace(origin, displacement, crouched),
			origin,
			displacement,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched),
			MoverPushRules.Masks.PlayerSolid
		)
		return result or frozenFailClosedTrace(origin)
	end

	local function canOccupy(origin: Vector3, crouched: boolean): boolean
		local result = MoverTraceComposition.CanOccupy(
			frame,
			staticCanOccupy(origin, crouched),
			origin,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched),
			MoverPushRules.Masks.PlayerSolid
		)
		return result == true
	end

	local function pointContents(point: Vector3): number
		local result = MoverTraceComposition.PointContents(frame, staticPointContents(point), point)
		return result or WorldPointContents.Contents.Solid
	end

	local queries: Queries = {
		frame = frame,
		trace = trace,
		canOccupy = canOccupy,
		pointContents = pointContents,
	}
	table.freeze(queries)
	return queries, nil
end

return table.freeze(MoverTraceComposition)
