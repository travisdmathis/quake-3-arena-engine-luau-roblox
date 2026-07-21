--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure dynamic point-trace rules translated from Quake III Arena:
  code/game/bg_public.h (MASK_SHOT and MASK_PLAYERSOLID)
  code/game/g_weapon.c (point traces against MASK_SHOT)
  code/game/g_missile.c (G_RunMissile and missile clipmask)
  code/server/sv_world.c (world trace followed by linked-entity clipping)
  code/qcommon/cm_trace.c (axis-aligned box trace fractions, startsolid, and allsolid)

The bounded immutable body input, explicit source-order tie break, ignored-body
set, and data-only result are the Roblox Luau port authority adaptations. Static world
geometry remains a separate server query; this kernel resolves only trusted
dynamic bodies so callers can merge its strictly nearer result with that world
trace without creating replicated query Parts.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverPushRules = require(script.Parent.MoverPushRules)
local Constants = require(script.Parent.Constants)

export type Contact = {
	read bodyId: string,
	read sourceOrder: number,
	read contents: number,
}

export type Result = {
	read hit: boolean,
	read fraction: number,
	read distance: number,
	read position: Vector3,
	read normal: Vector3,
	read startSolid: boolean,
	read allSolid: boolean,
	read contact: Contact?,
}

export type IgnoredBodyIds = { [string]: boolean }

local CombatShotTraceRules = {}

local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_DISPLACEMENT_COMPONENT = MAXIMUM_COORDINATE * 2
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MAXIMUM_IGNORED_BODY_IDS = 256
-- CM_TraceThroughBrush deliberately reports an entering contact this far on
-- the near side of a brush plane. Keep the source-unit constant visible here:
-- its sign is inverted for leaving planes below, exactly as in cm_trace.c.
local SURFACE_CLIP_EPSILON = 0.125 * Constants.UnitsToStuds

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.abs(vector.X) <= maximumComponent
		and math.abs(vector.Y) <= maximumComponent
		and math.abs(vector.Z) <= maximumComponent
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isValidBodyId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function validateIgnoredBodyIds(value: unknown): (IgnoredBodyIds?, string?)
	if value == nil then
		return {}, nil
	end
	if type(value) ~= "table" then
		return nil, "ignored-body-ids-not-table"
	end
	local ignored: IgnoredBodyIds = {}
	local count = 0
	for bodyId, excluded in value :: { [unknown]: unknown } do
		if not isValidBodyId(bodyId) or excluded ~= true then
			return nil, "invalid-ignored-body-id-entry"
		end
		count += 1
		if count > MAXIMUM_IGNORED_BODY_IDS then
			return nil, "too-many-ignored-body-ids"
		end
		ignored[bodyId :: string] = true
	end
	return ignored, nil
end

type BrushInterval = {
	entry: number,
	exit: number,
	normal: Vector3,
}

local function clipPlane(
	startDistance: number,
	endDistance: number,
	planeNormal: Vector3,
	entryFraction: number,
	exitFraction: number,
	entryNormal: Vector3
): BrushInterval?
	-- This is CM_TraceThroughBrush's plane loop, including its asymmetric
	-- epsilon signs. A segment wholly in front of any plane cannot touch the
	-- convex brush. The second condition also rejects motion away from it.
	if startDistance > 0 and (endDistance >= SURFACE_CLIP_EPSILON or endDistance >= startDistance) then
		return nil
	end
	if startDistance <= 0 and endDistance <= 0 then
		return {
			entry = entryFraction,
			exit = exitFraction,
			normal = entryNormal,
		}
	end

	local nextEntry = entryFraction
	local nextExit = exitFraction
	local nextNormal = entryNormal
	if startDistance > endDistance then
		-- Entering: place the reported impact epsilon units before the plane.
		local fraction = (startDistance - SURFACE_CLIP_EPSILON) / (startDistance - endDistance)
		if fraction < 0 then
			fraction = 0
		end
		if fraction > nextEntry then
			nextEntry = fraction
			nextNormal = planeNormal
		end
	else
		-- Leaving: use the corresponding positive epsilon numerator. Because
		-- the denominator is negative, this clips on the interior side.
		local fraction = (startDistance + SURFACE_CLIP_EPSILON) / (startDistance - endDistance)
		if fraction > 1 then
			fraction = 1
		end
		if fraction < nextExit then
			nextExit = fraction
		end
	end
	return {
		entry = nextEntry,
		exit = nextExit,
		normal = nextNormal,
	}
end

type BodyHit = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
}

local function pointInsideBox(point: Vector3, minimum: Vector3, maximum: Vector3): boolean
	return point.X >= minimum.X
		and point.X <= maximum.X
		and point.Y >= minimum.Y
		and point.Y <= maximum.Y
		and point.Z >= minimum.Z
		and point.Z <= maximum.Z
end

local function traceBody(origin: Vector3, displacement: Vector3, body: MoverPushRules.Body): BodyHit?
	local center = body.position + body.centerOffset
	local halfSize = body.size * 0.5
	local minimum = center - halfSize
	local maximum = center + halfSize
	if pointInsideBox(origin, minimum, maximum) then
		-- CM_TraceThroughBrush keeps fraction 1 when the trace starts in a
		-- convex brush but gets out by the endpoint. SV_ClipMoveToEntities
		-- preserves that startsolid bit while still allowing a later entity's
		-- strictly nearer impact to become the contact. Only a segment that
		-- remains inside for its full length is allsolid/fraction zero.
		local allSolid = pointInsideBox(origin + displacement, minimum, maximum)
		return {
			hit = allSolid,
			fraction = if allSolid then 0 else 1,
			normal = Vector3.zero,
			startSolid = true,
			allSolid = allSolid,
		}
	end

	local endpoint = origin + displacement
	local interval = clipPlane(minimum.X - origin.X, minimum.X - endpoint.X, -Vector3.xAxis, -1, 1, Vector3.zero)
	if not interval then
		return nil
	end
	interval = clipPlane(
		origin.X - maximum.X,
		endpoint.X - maximum.X,
		Vector3.xAxis,
		interval.entry,
		interval.exit,
		interval.normal
	)
	if not interval then
		return nil
	end
	interval = clipPlane(
		minimum.Y - origin.Y,
		minimum.Y - endpoint.Y,
		-Vector3.yAxis,
		interval.entry,
		interval.exit,
		interval.normal
	)
	if not interval then
		return nil
	end
	interval = clipPlane(
		origin.Y - maximum.Y,
		endpoint.Y - maximum.Y,
		Vector3.yAxis,
		interval.entry,
		interval.exit,
		interval.normal
	)
	if not interval then
		return nil
	end
	interval = clipPlane(
		minimum.Z - origin.Z,
		minimum.Z - endpoint.Z,
		-Vector3.zAxis,
		interval.entry,
		interval.exit,
		interval.normal
	)
	if not interval then
		return nil
	end
	interval = clipPlane(
		origin.Z - maximum.Z,
		endpoint.Z - maximum.Z,
		Vector3.zAxis,
		interval.entry,
		interval.exit,
		interval.normal
	)
	-- CM_TraceThroughBrush accepts only enterFrac < leaveFrac, and the shared
	-- trace replaces fraction 1 only with a strictly smaller entering fraction.
	if not interval or interval.entry >= interval.exit or interval.entry <= -1 or interval.entry >= 1 then
		return nil
	end
	return {
		hit = true,
		fraction = interval.entry,
		normal = interval.normal,
		startSolid = false,
		allSolid = false,
	}
end

local function frozenContact(body: MoverPushRules.Body): Contact
	local contact: Contact = {
		bodyId = body.id,
		sourceOrder = body.sourceOrder,
		contents = body.contents,
	}
	return table.freeze(contact)
end

local function frozenResult(
	hit: boolean,
	fraction: number,
	distance: number,
	position: Vector3,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	contact: Contact?
): Result
	local result: Result = {
		hit = hit,
		fraction = fraction,
		distance = distance,
		position = position,
		normal = normal,
		startSolid = startSolid,
		allSolid = allSolid,
		contact = contact,
	}
	return table.freeze(result)
end

function CombatShotTraceRules.Trace(
	bodiesValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	maskValue: unknown,
	ignoredBodyIdsValue: unknown?
): (Result?, string?)
	local bodies, bodiesError = MoverPushRules.ValidateAndOrderBodies(bodiesValue)
	if not bodies then
		return nil, bodiesError or "invalid-shot-trace-bodies"
	end
	if not isBoundedVector(originValue, MAXIMUM_COORDINATE) then
		return nil, "invalid-shot-trace-origin"
	end
	if not isBoundedVector(displacementValue, MAXIMUM_DISPLACEMENT_COMPONENT) then
		return nil, "invalid-shot-trace-displacement"
	end
	local origin = originValue :: Vector3
	local displacement = displacementValue :: Vector3
	if not isBoundedVector(origin + displacement, MAXIMUM_COORDINATE) then
		return nil, "shot-trace-endpoint-out-of-bounds"
	end
	if not isIntegerInRange(maskValue, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-shot-trace-mask"
	end
	local ignoredBodyIds, ignoredError = validateIgnoredBodyIds(ignoredBodyIdsValue)
	if not ignoredBodyIds then
		return nil, ignoredError
	end

	local mask = maskValue :: number
	local displacementLength = displacement.Magnitude
	local bestBody: MoverPushRules.Body? = nil
	local bestHit: BodyHit? = nil
	local startSolid = false
	for _, body in bodies do
		if ignoredBodyIds[body.id] or bit32.band(mask, body.contents) == 0 then
			continue
		end
		local candidate = traceBody(origin, displacement, body)
		if not candidate then
			continue
		end
		startSolid = startSolid or candidate.startSolid
		if candidate.allSolid then
			-- Q3 stops entity clipping once the aggregate trace is allsolid.
			-- Bodies are source ordered, so the first allsolid body is stable.
			bestBody = body
			bestHit = candidate
			break
		end
		if not candidate.hit then
			-- A startsolid trace that exits this convex body has no impact
			-- fraction/contact of its own. Keep only the aggregate bit.
			continue
		end
		if not bestHit or candidate.fraction < bestHit.fraction then
			-- Q3 replaces a dynamic trace only for a strictly smaller fraction.
			-- Equal fractions therefore retain the first source entity.
			bestBody = body
			bestHit = candidate
		end
	end

	if not bestBody or not bestHit then
		return frozenResult(false, 1, displacementLength, origin + displacement, Vector3.zero, startSolid, false, nil),
			nil
	end

	local fraction = bestHit.fraction
	return frozenResult(
		true,
		fraction,
		displacementLength * fraction,
		origin + displacement * fraction,
		bestHit.normal,
		startSolid,
		bestHit.allSolid,
		frozenContact(bestBody)
	),
		nil
end

CombatShotTraceRules.MaximumCoordinate = MAXIMUM_COORDINATE
CombatShotTraceRules.MaximumIgnoredBodyIds = MAXIMUM_IGNORED_BODY_IDS
CombatShotTraceRules.SurfaceClipEpsilon = SURFACE_CLIP_EPSILON

return table.freeze(CombatShotTraceRules)
