--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure trace-contact positioning translated from Quake III Arena:
	code/qcommon/cm_trace.c (CM_TraceThroughBrush and SURFACE_CLIP_EPSILON)

The support-inset term can convert a platform query inset back into plane
distance before applying Q3's near-side clip epsilon. Static-world movement
uses the exact Q3 hull (zero inset); zero-length Roblox overlap classification
keeps its separate platform guard. Plane distances are converted to distance
along the trace, preserving the source behavior at glancing incidence.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-16.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type Resolution = {
	read travelDistance: number,
	read pathRetreat: number,
	read supportInset: number,
	read incidence: number,
}

local TraceClipRules = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isFiniteVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)
end

function TraceClipRules.Resolve(
	rawHitDistanceValue: unknown,
	displacementValue: unknown,
	normalValue: unknown,
	perAxisInsetValue: unknown
): (Resolution?, string?)
	if not isFinite(rawHitDistanceValue) or (rawHitDistanceValue :: number) < 0 then
		return nil, "invalid-trace-clip-hit-distance"
	end
	if not isFiniteVector(displacementValue) then
		return nil, "invalid-trace-clip-displacement"
	end
	if not isFiniteVector(normalValue) then
		return nil, "invalid-trace-clip-normal"
	end
	if not isFinite(perAxisInsetValue) or (perAxisInsetValue :: number) < 0 then
		return nil, "invalid-trace-clip-per-axis-inset"
	end

	local rawHitDistance = rawHitDistanceValue :: number
	local displacement = displacementValue :: Vector3
	local normal = normalValue :: Vector3
	local perAxisInset = perAxisInsetValue :: number
	local displacementDistance = displacement.Magnitude
	local normalMagnitude = normal.Magnitude
	if displacementDistance <= 0 then
		return nil, "zero-trace-clip-displacement"
	end
	if normalMagnitude <= 0 then
		return nil, "zero-trace-clip-normal"
	end
	if rawHitDistance > displacementDistance then
		return nil, "trace-clip-hit-beyond-displacement"
	end

	local unitDisplacement = displacement / displacementDistance
	local unitNormal = normal / normalMagnitude
	local incidence = math.clamp(-unitDisplacement:Dot(unitNormal), 0, 1)
	if incidence <= 0 then
		return nil, "non-entering-trace-clip-normal"
	end

	-- Shrinking every local axis by the same amount reduces an AABB's support
	-- radius along an arbitrary unit plane normal by inset * ||normal||_1.
	local supportInset = perAxisInset * (math.abs(unitNormal.X) + math.abs(unitNormal.Y) + math.abs(unitNormal.Z))
	local unclampedPathRetreat = (supportInset + Constants.SurfaceClipEpsilon) / incidence
	-- CM_TraceThroughBrush clamps a negative entering fraction back to zero.
	-- Clamping the retreat to the raw contact distance is the distance-domain
	-- equivalent and cannot move the trace behind its starting origin.
	local pathRetreat = math.min(unclampedPathRetreat, rawHitDistance)
	local resolution: Resolution = {
		travelDistance = math.clamp(rawHitDistance - pathRetreat, 0, displacementDistance),
		pathRetreat = pathRetreat,
		supportInset = supportInset,
		incidence = incidence,
	}
	table.freeze(resolution)
	return resolution, nil
end

return table.freeze(TraceClipRules)
