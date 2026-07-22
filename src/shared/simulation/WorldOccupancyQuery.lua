--!strict

local Workspace = game:GetService("Workspace")

local Constants = require(script.Parent.Constants)
local PersistentStaticSolidDomain = require(script.Parent.PersistentStaticSolidDomain)
local PlayerClipDomain = require(script.Parent.PlayerClipDomain)

local WorldOccupancyQuery = {}

export type Occupant = BasePart | PlayerClipDomain.Occupant
export type QueryFunction = (origin: Vector3, crouched: boolean) -> { Occupant }
export type BodyQueryFunction = (
	position: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	includePlayerClip: boolean?
) -> { Occupant }

type ExactBoxQuery = (center: Vector3, size: Vector3) -> { BasePart }

-- Blockcast deliberately ignores shapes that overlap its starting hull, while
-- GetPartBoundsInBox is only an AABB broad phase and produces false positives
-- in the empty half of wedges. GetPartsInPart performs the exact geometric
-- overlap required for Q3 trace_t startsolid/allsolid emulation.
--
-- Current Roblox engine builds accept an unparented query Part. Keeping the
-- probe outside Workspace prevents a server query helper from replicating or
-- entering any gameplay query. The availability flag lets authoritative and
-- prediction startup fail closed if that capability changes; callers must not
-- silently fall back to an inexact query that can freeze or free valid movement.
local function createExactBoxQuery(
	staticRoot: Instance,
	probeName: string,
	currentCheck: (() -> boolean)?
): (ExactBoxQuery, boolean)
	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = { staticRoot }
	parameters.RespectCanCollide = true
	parameters.MaxParts = 0

	local probe = Instance.new("Part")
	probe.Name = probeName
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.CastShadow = false
	probe.Transparency = 1
	probe.Size = Constants.StandingColliderSize

	local exactGeometryAvailable = staticRoot:IsDescendantOf(Workspace)
		and (currentCheck == nil or currentCheck())
		and pcall(function()
			Workspace:GetPartsInPart(probe, parameters)
		end)

	local function query(center: Vector3, size: Vector3): { BasePart }
		if not exactGeometryAvailable then
			return {}
		end
		assert(currentCheck == nil or currentCheck(), "validated persistent static-solid domain was invalidated")
		local skin = Constants.CollisionSkin * 2
		probe.Size =
			Vector3.new(math.max(size.X - skin, 0.001), math.max(size.Y - skin, 0.001), math.max(size.Z - skin, 0.001))
		probe.CFrame = CFrame.new(center)
		return Workspace:GetPartsInPart(probe, parameters)
	end

	return query, exactGeometryAvailable
end

function WorldOccupancyQuery.Create(staticSolidDomain: PersistentStaticSolidDomain.Domain): (QueryFunction, boolean)
	local staticRoot = PersistentStaticSolidDomain.Resolve(staticSolidDomain)
	if not staticRoot then
		return function(_origin: Vector3, _crouched: boolean): { Occupant }
			return {}
		end, false
	end
	local queryBox, exactGeometryAvailable = createExactBoxQuery(
		staticRoot,
		"Q3EngineUnparentedOccupancyProbe",
		function(): boolean
			return PersistentStaticSolidDomain.IsCurrent(staticSolidDomain)
		end
	)
	local function query(origin: Vector3, crouched: boolean): { Occupant }
		return queryBox(
				origin + Constants.ColliderCenterOffsetFor(crouched),
				Constants.ColliderSizeFor(crouched)
			) :: any
	end
	return query, exactGeometryAvailable
end

-- Explicit MASK_PLAYERSOLID adapter. The ordinary Create path above remains
-- SOLID-only, so weapon/world callers cannot acquire PlayerClip by accident.
-- PlayerClip occupants are opaque data tokens, never Workspace Instances.
function WorldOccupancyQuery.CreatePlayerMovement(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain
): (QueryFunction, boolean)
	local staticQuery, exactStaticGeometryAvailable = WorldOccupancyQuery.Create(staticSolidDomain)
	if not exactStaticGeometryAvailable or not PlayerClipDomain.IsCurrent(playerClipDomain) then
		return function(_origin: Vector3, _crouched: boolean): { Occupant }
			return {}
		end, false
	end
	local function query(origin: Vector3, crouched: boolean): { Occupant }
		assert(PlayerClipDomain.IsCurrent(playerClipDomain), "playerclip domain was invalidated")
		local occupants: { Occupant } = {}
		for _, occupant in staticQuery(origin, crouched) do
			table.insert(occupants, occupant)
		end
		local clipOccupants, clipError = PlayerClipDomain.QueryBody(
			playerClipDomain,
			origin,
			Constants.ColliderSizeFor(crouched),
			Constants.ColliderCenterOffsetFor(crouched)
		)
		assert(clipOccupants, clipError or "playerclip occupancy query failed")
		for _, occupant in clipOccupants do
			table.insert(occupants, occupant)
		end
		return occupants
	end
	return query, true
end

-- Mover consequences may replace a live player hull with a corpse or insert an
-- ET_ITEM-sized death drop before a later pusher runs. Those bodies use the
-- same exact static-world test as Pmove, but their Q3 mins/maxs cannot be
-- represented by the standing/crouched boolean adapter above.
function WorldOccupancyQuery.CreateBody(
	staticSolidDomain: PersistentStaticSolidDomain.Domain
): (BodyQueryFunction, boolean)
	local staticRoot = PersistentStaticSolidDomain.Resolve(staticSolidDomain)
	if not staticRoot then
		return function(
			_position: Vector3,
			_size: Vector3,
			_centerOffset: Vector3,
			_includePlayerClip: boolean?
		): { Occupant }
			return {}
		end,
			false
	end
	local queryBox, exactGeometryAvailable = createExactBoxQuery(
		staticRoot,
		"Q3EngineUnparentedBodyOccupancyProbe",
		function(): boolean
			return PersistentStaticSolidDomain.IsCurrent(staticSolidDomain)
		end
	)
	local function query(
		position: Vector3,
		size: Vector3,
		centerOffset: Vector3,
		_includePlayerClip: boolean?
	): { Occupant }
		return queryBox(position + centerOffset, size) :: any
	end
	return query, exactGeometryAvailable
end

function WorldOccupancyQuery.CreateBodyPlayerMovement(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain
): (BodyQueryFunction, boolean)
	local staticQuery, exactStaticGeometryAvailable = WorldOccupancyQuery.CreateBody(staticSolidDomain)
	if not exactStaticGeometryAvailable or not PlayerClipDomain.IsCurrent(playerClipDomain) then
		return function(
			_position: Vector3,
			_size: Vector3,
			_centerOffset: Vector3,
			_includePlayerClip: boolean?
		): { Occupant }
			return {}
		end,
			false
	end
	local function query(
		position: Vector3,
		size: Vector3,
		centerOffset: Vector3,
		includePlayerClip: boolean?
	): { Occupant }
		assert(PlayerClipDomain.IsCurrent(playerClipDomain), "playerclip domain was invalidated")
		local occupants: { Occupant } = {}
		for _, occupant in staticQuery(position, size, centerOffset) do
			table.insert(occupants, occupant)
		end
		if includePlayerClip == false then
			return occupants
		end
		local clipOccupants, clipError = PlayerClipDomain.QueryBody(playerClipDomain, position, size, centerOffset)
		assert(clipOccupants, clipError or "playerclip body occupancy query failed")
		for _, occupant in clipOccupants do
			table.insert(occupants, occupant)
		end
		return occupants
	end
	return query, true
end

-- Isolated Studio fixtures deliberately bypass the production streaming
-- completeness receipt. Their names prevent a local overlap capability probe
-- from being mistaken for an authoritative complete-world proof.
function WorldOccupancyQuery.CreateFixture(staticRoot: Instance): (QueryFunction, boolean)
	local queryBox, exactGeometryAvailable = createExactBoxQuery(staticRoot, "Q3EngineUnparentedOccupancyProbe", nil)
	local function query(origin: Vector3, crouched: boolean): { Occupant }
		return queryBox(
				origin + Constants.ColliderCenterOffsetFor(crouched),
				Constants.ColliderSizeFor(crouched)
			) :: any
	end
	return query, exactGeometryAvailable
end

function WorldOccupancyQuery.CreateBodyFixture(staticRoot: Instance): (BodyQueryFunction, boolean)
	local queryBox, exactGeometryAvailable =
		createExactBoxQuery(staticRoot, "Q3EngineUnparentedBodyOccupancyProbe", nil)
	local function query(
		position: Vector3,
		size: Vector3,
		centerOffset: Vector3,
		_includePlayerClip: boolean?
	): { Occupant }
		return queryBox(position + centerOffset, size) :: any
	end
	return query, exactGeometryAvailable
end

return table.freeze(WorldOccupancyQuery)
