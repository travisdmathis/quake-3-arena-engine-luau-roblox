--!strict

-- Q3 jump-pad trigger brushes can extend far above or through the authored
-- support geometry. The gameplay trigger keeps those exact bounds. Angled
-- presentation instead uses one separately audited support/draw face because a
-- trigger AABB cannot recover an authored plane. The horizontal AABB-bottom
-- path remains only as a compatibility fallback for legacy flat pads.

local JumpPadPresentationRules = {}

export type VisualSurface = {
	position: Vector3,
	normal: Vector3,
	right: Vector3,
	width: number,
	depth: number,
	reconstructionLift: number,
}

export type SurfacePlan = {
	position: Vector3,
	size: Vector3,
	cframe: CFrame,
	supportPosition: Vector3,
	normal: Vector3,
	right: Vector3,
	reconstructionLift: number,
	baseClearance: number,
	insetX: number,
	insetZ: number,
}

local EPSILON = 0.0001
local UNIT_EPSILON = 0.001
local ORTHOGONAL_EPSILON = 0.001
local MINIMUM_UPWARD_NORMAL = 0.15
local MAXIMUM_RECONSTRUCTION_LIFT = 2
local MAXIMUM_SURFACE_EXTENT = 64
local MAXIMUM_SURFACE_THICKNESS = 0.12
local BASE_CLEARANCE = 0.04
local MAXIMUM_EDGE_INSET = 0.04

local function finiteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function finiteVector3(value: Vector3): boolean
	return finiteNumber(value.X) and finiteNumber(value.Y) and finiteNumber(value.Z)
end

local function positiveVector3(value: Vector3): boolean
	return finiteVector3(value) and value.X > 0 and value.Y > 0 and value.Z > 0
end

function JumpPadPresentationRules.ValidateVisualSurface(value: unknown): (boolean, string?)
	if type(value) ~= "table" then
		return false, "MustBeTable"
	end
	local surface = value :: any
	if typeof(surface.position) ~= "Vector3" or not finiteVector3(surface.position) then
		return false, "PositionInvalid"
	end
	if typeof(surface.normal) ~= "Vector3" or not finiteVector3(surface.normal) then
		return false, "NormalInvalid"
	end
	if typeof(surface.right) ~= "Vector3" or not finiteVector3(surface.right) then
		return false, "RightInvalid"
	end
	if
		type(surface.width) ~= "number"
		or not finiteNumber(surface.width)
		or surface.width <= EPSILON
		or surface.width > MAXIMUM_SURFACE_EXTENT
	then
		return false, "WidthInvalid"
	end
	if
		type(surface.depth) ~= "number"
		or not finiteNumber(surface.depth)
		or surface.depth <= EPSILON
		or surface.depth > MAXIMUM_SURFACE_EXTENT
	then
		return false, "DepthInvalid"
	end
	if
		type(surface.reconstructionLift) ~= "number"
		or not finiteNumber(surface.reconstructionLift)
		or surface.reconstructionLift < 0
		or surface.reconstructionLift > MAXIMUM_RECONSTRUCTION_LIFT
	then
		return false, "ReconstructionLiftInvalid"
	end

	local normal = surface.normal :: Vector3
	local right = surface.right :: Vector3
	if math.abs(normal.Magnitude - 1) > UNIT_EPSILON then
		return false, "NormalMustBeUnit"
	end
	if math.abs(right.Magnitude - 1) > UNIT_EPSILON then
		return false, "RightMustBeUnit"
	end
	if math.abs(normal:Dot(right)) > ORTHOGONAL_EPSILON then
		return false, "RightMustBeOrthogonal"
	end
	if normal.Y < MINIMUM_UPWARD_NORMAL then
		return false, "NormalMustFaceUpward"
	end
	return true, nil
end

function JumpPadPresentationRules.BuildSurfacePlan(
	triggerPosition: Vector3,
	triggerSize: Vector3,
	visualSurface: VisualSurface?
): (SurfacePlan?, string?)
	if not finiteVector3(triggerPosition) then
		return nil, "TriggerPositionInvalid"
	end
	if not positiveVector3(triggerSize) then
		return nil, "TriggerSizeInvalid"
	end

	local supportPosition: Vector3
	local normal: Vector3
	local right: Vector3
	local sourceWidth: number
	local sourceDepth: number
	local thickness: number
	local reconstructionLift: number
	if visualSurface then
		local valid, validationError = JumpPadPresentationRules.ValidateVisualSurface(visualSurface)
		if not valid then
			return nil, validationError
		end
		supportPosition = visualSurface.position
		normal = visualSurface.normal.Unit
		right = visualSurface.right.Unit
		sourceWidth = visualSurface.width
		sourceDepth = visualSurface.depth
		thickness = MAXIMUM_SURFACE_THICKNESS
		reconstructionLift = visualSurface.reconstructionLift
	else
		local triggerBottom = triggerPosition.Y - triggerSize.Y * 0.5
		supportPosition = Vector3.new(triggerPosition.X, triggerBottom, triggerPosition.Z)
		normal = Vector3.yAxis
		right = Vector3.xAxis
		sourceWidth = triggerSize.X
		sourceDepth = triggerSize.Z
		thickness = math.min(triggerSize.Y, MAXIMUM_SURFACE_THICKNESS)
		reconstructionLift = 0
	end

	local insetX = math.min(MAXIMUM_EDGE_INSET, sourceWidth * 0.1)
	local insetZ = math.min(MAXIMUM_EDGE_INSET, sourceDepth * 0.1)
	local position = supportPosition + normal * (reconstructionLift + BASE_CLEARANCE + thickness * 0.5)
	local back = right:Cross(normal).Unit
	return table.freeze({
		position = position,
		size = Vector3.new(sourceWidth - insetX * 2, thickness, sourceDepth - insetZ * 2),
		cframe = CFrame.fromMatrix(position, right, normal, back),
		supportPosition = supportPosition,
		normal = normal,
		right = right,
		reconstructionLift = reconstructionLift,
		baseClearance = BASE_CLEARANCE,
		insetX = insetX,
		insetZ = insetZ,
	}),
		nil
end

JumpPadPresentationRules.SurfaceName = "JumpPadSurface"
JumpPadPresentationRules.SurfaceColor = Color3.fromRGB(28, 125, 176)
JumpPadPresentationRules.SurfaceTransparency = 0.2
JumpPadPresentationRules.MaximumSurfaceThickness = MAXIMUM_SURFACE_THICKNESS
JumpPadPresentationRules.BaseClearance = BASE_CLEARANCE
JumpPadPresentationRules.MaximumEdgeInset = MAXIMUM_EDGE_INSET
JumpPadPresentationRules.MinimumUpwardNormal = MINIMUM_UPWARD_NORMAL
JumpPadPresentationRules.MaximumReconstructionLift = MAXIMUM_RECONSTRUCTION_LIFT
JumpPadPresentationRules.MaximumSurfaceExtent = MAXIMUM_SURFACE_EXTENT

return table.freeze(JumpPadPresentationRules)
