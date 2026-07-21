--[[
SPDX-License-Identifier: GPL-2.0-or-later

Static-world arbitrary-hull trace adapter for Quake III trace_t semantics:
  code/qcommon/cm_trace.c (box trace, startsolid, allsolid)
  code/server/sv_world.c (world trace before linked entities)

This capability sees only the validated static collision domain. Dynamic
movers are composed separately and player/corpse bodies are deliberately not
accepted as an input, which makes it suitable for MASK_DEADSOLID Pmove.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Constants)
local Movement = require(script.Parent.Movement)
local PersistentStaticSolidDomain = require(script.Parent.PersistentStaticSolidDomain)
local PlayerClipDomain = require(script.Parent.PlayerClipDomain)
local SurfaceContact = require(script.Parent.SurfaceContact)
local TraceClipRules = require(script.Parent.TraceClipRules)
local WorldOccupancyQuery = require(script.Parent.WorldOccupancyQuery)

export type Domain = {}
export type FixtureDomain = {}

type TraceFunction = (
	origin: Vector3,
	displacement: Vector3,
	size: Vector3,
	centerOffset: Vector3
) -> Movement.TraceResult

local WorldBodyTrace = {}

local MAXIMUM_COMPONENT = 100_000
local MINIMUM_CAST_COMPONENT = 0.001
-- Workspace shapecasts reject a displacement longer than 1,024 studs. Keep a
-- margin below that platform boundary so float32 reconstruction cannot round a
-- nominally valid segment above the engine limit.
local MAXIMUM_BLOCKCAST_DISTANCE = 1_000

type DomainCapability = {
	handle: Domain | FixtureDomain,
	kind: "Production" | "Fixture",
	trace: TraceFunction,
	currentCheck: (() -> boolean)?,
}

local domains = setmetatable({}, { __mode = "k" }) :: {
	[Domain | FixtureDomain]: DomainCapability,
}

local function isFinite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function isBoundedVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= MAXIMUM_COMPONENT
end

local function isValidSize(value: unknown): boolean
	return isBoundedVector(value)
		and (value :: Vector3).X > Constants.CollisionSkin * 2
		and (value :: Vector3).Y > Constants.CollisionSkin * 2
		and (value :: Vector3).Z > Constants.CollisionSkin * 2
end

local function failClosed(originValue: unknown): Movement.TraceResult
	local origin = if isBoundedVector(originValue) then originValue :: Vector3 else Vector3.zero
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

local function sharesOccupant(
	first: { WorldOccupancyQuery.Occupant },
	second: { WorldOccupancyQuery.Occupant }
): boolean
	local firstSet: { [WorldOccupancyQuery.Occupant]: boolean } = {}
	for _, part in first do
		firstSet[part] = true
	end
	for _, part in second do
		if firstSet[part] then
			return true
		end
	end
	return false
end

local function createTrace(
	staticRoot: Instance,
	bodyOccupants: WorldOccupancyQuery.BodyQueryFunction,
	currentCheck: (() -> boolean)?,
	playerClipDomain: PlayerClipDomain.Domain?
): TraceFunction
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = { staticRoot }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true

	local function blockcastInSegments(
		origin: Vector3,
		displacement: Vector3,
		castSize: Vector3,
		centerOffset: Vector3
	): (RaycastResult?, number)
		local distance = displacement.Magnitude
		if distance <= 1e-6 then
			return nil, 0
		end
		local direction = displacement.Unit
		local traversed = 0
		while traversed < distance do
			local segmentDistance = math.min(distance - traversed, MAXIMUM_BLOCKCAST_DISTANCE)
			local segmentOrigin = origin + direction * traversed
			local result = Workspace:Blockcast(
				CFrame.new(segmentOrigin + centerOffset),
				castSize,
				direction * segmentDistance,
				parameters
			)
			if result then
				return result, traversed
			end
			traversed += segmentDistance
		end
		return nil, 0
	end

	return function(origin: Vector3, displacement: Vector3, size: Vector3, centerOffset: Vector3): Movement.TraceResult
		if
			not isBoundedVector(origin)
			or not isBoundedVector(displacement)
			or not isValidSize(size)
			or not isBoundedVector(centerOffset)
		then
			return failClosed(origin)
		end
		assert(currentCheck == nil or currentCheck(), "static body-trace domain was invalidated")

		local distance = displacement.Magnitude
		if not isFinite(distance) or distance > MAXIMUM_COMPONENT then
			return failClosed(origin)
		end
		-- Q3 box traces use the exact requested hull. The separate overlap query
		-- retains its Roblox boundary guard only for startsolid/allsolid sampling.
		local castSize = Vector3.new(
			math.max(size.X - Constants.StaticWorldSweepInset * 2, MINIMUM_CAST_COMPONENT),
			math.max(size.Y - Constants.StaticWorldSweepInset * 2, MINIMUM_CAST_COMPONENT),
			math.max(size.Z - Constants.StaticWorldSweepInset * 2, MINIMUM_CAST_COMPONENT)
		)
		local worldResult, worldResultBaseDistance = blockcastInSegments(origin, displacement, castSize, centerOffset)
		local clipResult: PlayerClipDomain.TraceResult? = nil
		if playerClipDomain then
			local resolvedClipResult, clipError =
				PlayerClipDomain.Trace(playerClipDomain, origin, displacement, size, centerOffset)
			assert(resolvedClipResult, clipError or "playerclip body trace failed")
			clipResult = resolvedClipResult
		end
		local startOccupants = bodyOccupants(origin, size, centerOffset)
		local endOccupants = if #startOccupants > 0
			then bodyOccupants(origin + displacement, size, centerOffset)
			else {}
		local allSolid = sharesOccupant(startOccupants, endOccupants)
		if allSolid or (clipResult and clipResult.allSolid) then
			return failClosed(origin)
		end

		local startSolid = #startOccupants > 0
		if distance <= 1e-6 then
			local result: Movement.TraceResult = {
				hit = false,
				fraction = 1,
				position = origin + displacement,
				normal = Vector3.yAxis,
				moverId = nil,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
			table.freeze(result)
			return result
		end

		local worldClipResolution = if worldResult
			then assert(
				TraceClipRules.Resolve(
					worldResultBaseDistance + worldResult.Distance,
					displacement,
					worldResult.Normal,
					Constants.StaticWorldSweepInset
				)
			)
			else nil
		local playerClipResolution = if clipResult and clipResult.hit
			then assert(
				TraceClipRules.Resolve(
					distance * clipResult.fraction,
					displacement,
					clipResult.normal,
					Constants.StaticWorldSweepInset
				)
			)
			else nil
		if
			playerClipResolution
			and (not worldClipResolution or playerClipResolution.travelDistance < worldClipResolution.travelDistance)
		then
			local travel = playerClipResolution.travelDistance
			local result: Movement.TraceResult = {
				hit = true,
				fraction = travel / distance,
				position = origin + displacement.Unit * travel,
				normal = assert(clipResult).normal,
				moverId = nil,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
			table.freeze(result)
			return result
		end
		if not worldResult or not worldClipResolution then
			local result: Movement.TraceResult = {
				hit = false,
				fraction = 1,
				position = origin + displacement,
				normal = Vector3.yAxis,
				moverId = nil,
				startSolid = startSolid,
				allSolid = false,
				surfaceSlick = false,
				surfaceNoDamage = false,
			}
			table.freeze(result)
			return result
		end

		local travel = worldClipResolution.travelDistance
		local surfaceSlick, surfaceNoDamage = SurfaceContact.Read(worldResult.Instance)
		local result: Movement.TraceResult = {
			hit = true,
			fraction = travel / distance,
			position = origin + displacement.Unit * travel,
			normal = worldResult.Normal,
			moverId = nil,
			startSolid = startSolid,
			allSolid = false,
			surfaceSlick = surfaceSlick,
			surfaceNoDamage = surfaceNoDamage,
		}
		table.freeze(result)
		return result
	end
end

local function makeDomain(
	kind: "Production" | "Fixture",
	trace: TraceFunction,
	currentCheck: (() -> boolean)?
): Domain | FixtureDomain
	local handle: Domain | FixtureDomain = table.freeze({})
	domains[handle] = {
		handle = handle,
		kind = kind,
		trace = trace,
		currentCheck = currentCheck,
	}
	return handle
end

function WorldBodyTrace.IsCurrent(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local capability = domains[value :: Domain | FixtureDomain]
	return capability ~= nil
		and capability.handle == value
		and table.isfrozen(capability.handle)
		and (capability.currentCheck == nil or capability.currentCheck())
end

function WorldBodyTrace.IsProductionCurrent(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local capability = domains[value :: Domain | FixtureDomain]
	return capability ~= nil and capability.kind == "Production" and WorldBodyTrace.IsCurrent(value)
end

function WorldBodyTrace.IsFixtureCurrent(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local capability = domains[value :: Domain | FixtureDomain]
	return capability ~= nil and capability.kind == "Fixture" and WorldBodyTrace.IsCurrent(value)
end

function WorldBodyTrace.Trace(
	domainValue: unknown,
	origin: Vector3,
	displacement: Vector3,
	size: Vector3,
	centerOffset: Vector3
): Movement.TraceResult
	if type(domainValue) ~= "table" then
		return failClosed(origin)
	end
	local capability = domains[domainValue :: Domain | FixtureDomain]
	if not capability or capability.handle ~= domainValue or not WorldBodyTrace.IsCurrent(domainValue) then
		return failClosed(origin)
	end
	return capability.trace(origin, displacement, size, centerOffset)
end

function WorldBodyTrace.Create(staticSolidDomain: PersistentStaticSolidDomain.Domain): (Domain?, boolean)
	local staticRoot = PersistentStaticSolidDomain.Resolve(staticSolidDomain)
	if not staticRoot then
		return nil, false
	end
	local bodyOccupants, exactGeometryAvailable = WorldOccupancyQuery.CreateBody(staticSolidDomain)
	if not exactGeometryAvailable then
		return nil, false
	end
	local function currentCheck(): boolean
		return PersistentStaticSolidDomain.IsCurrent(staticSolidDomain)
	end
	return makeDomain("Production", createTrace(staticRoot, bodyOccupants, currentCheck, nil), currentCheck) :: Domain,
		true
end

-- Explicit MASK_PLAYERSOLID body trace for PM_DEAD and other player hulls.
-- Create remains the SOLID-only world query used by cameras and weapon-adjacent
-- systems.
function WorldBodyTrace.CreatePlayerMovement(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain
): (Domain?, boolean)
	local staticRoot = PersistentStaticSolidDomain.Resolve(staticSolidDomain)
	if not staticRoot or not PlayerClipDomain.IsCurrent(playerClipDomain) then
		return nil, false
	end
	local bodyOccupants, exactGeometryAvailable =
		WorldOccupancyQuery.CreateBodyPlayerMovement(staticSolidDomain, playerClipDomain)
	if not exactGeometryAvailable then
		return nil, false
	end
	local function currentCheck(): boolean
		return PersistentStaticSolidDomain.IsCurrent(staticSolidDomain) and PlayerClipDomain.IsCurrent(playerClipDomain)
	end
	return makeDomain(
		"Production",
		createTrace(staticRoot, bodyOccupants, currentCheck, playerClipDomain),
		currentCheck
	) :: Domain,
		true
end

-- Explicit fixture seam for isolated Studio geometry tests. Production callers
-- must use Create so a Workspace result cannot masquerade as streaming proof.
function WorldBodyTrace.CreateFixture(staticRoot: Instance): (FixtureDomain?, boolean)
	if not RunService:IsStudio() then
		return nil, false
	end
	local bodyOccupants, exactGeometryAvailable = WorldOccupancyQuery.CreateBodyFixture(staticRoot)
	if not exactGeometryAvailable then
		return nil, false
	end
	local function currentCheck(): boolean
		return staticRoot:IsDescendantOf(Workspace)
	end
	return makeDomain(
			"Fixture",
			createTrace(staticRoot, bodyOccupants, currentCheck, nil),
			currentCheck
		) :: FixtureDomain,
		true
end

return table.freeze(WorldBodyTrace)
