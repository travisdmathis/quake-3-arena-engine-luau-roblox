--[[
SPDX-License-Identifier: GPL-2.0-or-later

Dead-player collision composition translated from:
  code/game/g_active.c (PM_DEAD clears CONTENTS_BODY from MASK_PLAYERSOLID)
  code/game/bg_public.h (MASK_DEADSOLID)
  code/server/sv_world.c (world first, then linked mover entities)

The static capability contains only the validated world model and the dynamic
capability contains only the immutable mover frame. No live-player or corpse
body collection is accepted by this API.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)
local Movement = require(script.Parent.Movement)
local MoverCollisionFrame = require(script.Parent.MoverCollisionFrame)
local MoverPushRules = require(script.Parent.MoverPushRules)
local MoverTraceComposition = require(script.Parent.MoverTraceComposition)
local WorldBodyTrace = require(script.Parent.WorldBodyTrace)
local WorldPointContents = require(script.Parent.WorldPointContents)
local RunService = game:GetService("RunService")

export type Queries = {
	read frame: MoverCollisionFrame.Frame,
	read staticBodyTraceDomain: WorldBodyTrace.Domain,
	read trace: Movement.DeadTraceFunction,
	read pointContents: Movement.PointContentsFunction,
}

local DeadPmoveTraceComposition = {}

local function failClosedTrace(origin: Vector3): Movement.TraceResult
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

local function isExactDeadQuery(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	if not table.isfrozen(value) or getmetatable(value) ~= nil then
		return false
	end
	local query = value :: { [unknown]: unknown }
	local keyCount = 0
	for key in next, query do
		if
			key ~= "collisionMode"
			and key ~= "excludesBodies"
			and key ~= "colliderSize"
			and key ~= "colliderCenterOffset"
		then
			return false
		end
		keyCount += 1
	end
	return keyCount == 4
		and rawget(query, "collisionMode") == "PlayerSolidWithoutBodies"
		and rawget(query, "excludesBodies") == true
		and rawget(query, "colliderSize") == Constants.DeadColliderSize
		and rawget(query, "colliderCenterOffset") == Constants.DeadColliderCenterOffset
end

local function createQueries(
	frameValue: unknown,
	staticBodyTraceDomainValue: unknown,
	staticPointContentsValue: unknown,
	fixture: boolean
): (Queries?, string?)
	local staticDomainCurrent = if fixture
		then WorldBodyTrace.IsFixtureCurrent(staticBodyTraceDomainValue)
		else WorldBodyTrace.IsProductionCurrent(staticBodyTraceDomainValue)
	if not staticDomainCurrent then
		return nil, "dead-static-body-trace-domain-invalid"
	end
	if type(staticPointContentsValue) ~= "function" then
		return nil, "dead-static-point-contents-not-function"
	end
	local _, frameError = MoverCollisionFrame.PointContents(frameValue, Vector3.zero)
	if frameError then
		return nil, "dead-mover-frame:" .. frameError
	end

	local frame = frameValue :: MoverCollisionFrame.Frame
	local staticBodyTraceDomain = staticBodyTraceDomainValue :: WorldBodyTrace.Domain
	local staticPointContents = staticPointContentsValue :: Movement.PointContentsFunction
	local function trace(
		origin: Vector3,
		displacement: Vector3,
		queryValue: Movement.DeadTraceQuery
	): Movement.TraceResult
		if not isExactDeadQuery(queryValue) then
			return failClosedTrace(origin)
		end
		local result = MoverTraceComposition.Trace(
			frame,
			WorldBodyTrace.Trace(
				staticBodyTraceDomain,
				origin,
				displacement,
				Constants.DeadColliderSize,
				Constants.DeadColliderCenterOffset
			),
			origin,
			displacement,
			Constants.DeadColliderSize,
			Constants.DeadColliderCenterOffset,
			MoverPushRules.Masks.DeadSolid
		)
		return result or failClosedTrace(origin)
	end
	local function pointContents(point: Vector3): number
		if not WorldBodyTrace.IsCurrent(staticBodyTraceDomain) then
			return WorldPointContents.Contents.Solid
		end
		local result = MoverTraceComposition.PointContents(frame, staticPointContents(point), point)
		return result or WorldPointContents.Contents.Solid
	end
	local queries: Queries = {
		frame = frame,
		staticBodyTraceDomain = staticBodyTraceDomain,
		trace = trace,
		pointContents = pointContents,
	}
	table.freeze(queries)
	return queries, nil
end

function DeadPmoveTraceComposition.Create(
	frameValue: unknown,
	staticBodyTraceDomainValue: unknown,
	staticPointContentsValue: unknown
): (Queries?, string?)
	return createQueries(frameValue, staticBodyTraceDomainValue, staticPointContentsValue, false)
end

-- Studio-only seam whose provenance cannot be admitted by the production
-- constructor. This keeps test geometry from weakening MASK_DEADSOLID.
function DeadPmoveTraceComposition.CreateFixture(
	frameValue: unknown,
	staticBodyTraceDomainValue: unknown,
	staticPointContentsValue: unknown
): (Queries?, string?)
	if not RunService:IsStudio() then
		return nil, "dead-static-body-trace-fixture-outside-studio"
	end
	return createQueries(frameValue, staticBodyTraceDomainValue, staticPointContentsValue, true)
end

return table.freeze(DeadPmoveTraceComposition)
