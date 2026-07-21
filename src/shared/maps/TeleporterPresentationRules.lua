--!strict

-- Teleporter gameplay volumes remain exact authority. Axis-aligned fallback
-- presentation sits outside a thin trigger; an independently audited source
-- plane may cross an invisible square trigger but remains visual-only and is
-- offset from opaque Arena Kit or measured structural geometry.

local TeleporterPresentationRules = {}

export type VisualSurface = {
	position: Vector3,
	normal: Vector3,
	width: number,
	height: number,
}

export type SurfacePlan = {
	position: Vector3,
	size: Vector3,
	cframe: CFrame,
	normal: Vector3,
}

local EPSILON = 0.0001
local UNIT_EPSILON = 0.001
local NORMAL_MATCH_EPSILON = 0.001
local MAXIMUM_SURFACE_EXTENT = 64
local SURFACE_WIDTH_SCALE = 0.52
local SURFACE_HEIGHT_SCALE = 0.62
local SURFACE_DEPTH = 0.04
local SURFACE_BACK_CLEARANCE = 0.06

-- teleporter_housing placements use two studs of depth. Its textured backing
-- occupies local Z [0, 0.16], so a thin Q3 trigger needs this minimum front
-- distance even when its own half-depth is only 0.1 studs.
local MINIMUM_BACKING_FRONT_DISTANCE = 0.16

local BACKING_POSITION_SCALE = Vector3.new(0, 0, 0.04)
local BACKING_SIZE_SCALE = Vector3.new(0.55, 0.66, 0.08)

local function finiteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function finiteVector3(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return finiteNumber(vector.X) and finiteNumber(vector.Y) and finiteNumber(vector.Z)
end

local function positiveVector3(value: unknown): boolean
	if not finiteVector3(value) then
		return false
	end
	local vector = value :: Vector3
	return vector.X > 0 and vector.Y > 0 and vector.Z > 0
end

local function horizontalUnitNormal(value: unknown): (Vector3?, string?)
	if typeof(value) ~= "Vector3" or not finiteVector3(value :: Vector3) then
		return nil, "MustBeFiniteVector3"
	end
	local normal = value :: Vector3
	if math.abs(normal.Y) > EPSILON or math.abs(normal.Magnitude - 1) > UNIT_EPSILON then
		return nil, "MustBeHorizontalUnit"
	end
	local horizontal = Vector3.new(normal.X, 0, normal.Z)
	if horizontal.Magnitude <= EPSILON then
		return nil, "MustBeHorizontalUnit"
	end
	return horizontal.Unit, nil
end

local function isAxisNormal(normal: Vector3): boolean
	return math.abs(math.abs(normal.X) - 1) <= EPSILON or math.abs(math.abs(normal.Z) - 1) <= EPSILON
end

function TeleporterPresentationRules.ValidateVisualSurface(value: unknown): (boolean, string?)
	if type(value) ~= "table" then
		return false, "MustBeTable"
	end
	local surface = value :: any
	if typeof(surface.position) ~= "Vector3" or not finiteVector3(surface.position) then
		return false, "PositionInvalid"
	end
	local normal, normalError = horizontalUnitNormal(surface.normal)
	if not normal then
		return false, "Normal" .. (normalError or "Invalid")
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
		type(surface.height) ~= "number"
		or not finiteNumber(surface.height)
		or surface.height <= EPSILON
		or surface.height > MAXIMUM_SURFACE_EXTENT
	then
		return false, "HeightInvalid"
	end
	return true, nil
end

function TeleporterPresentationRules.ValidateVisualNormal(
	value: unknown,
	triggerSize: unknown,
	visualSurface: VisualSurface?
): (boolean, string?)
	local normal, normalError = horizontalUnitNormal(value)
	if not normal then
		return false, normalError
	end
	if typeof(triggerSize) ~= "Vector3" or not positiveVector3(triggerSize :: Vector3) then
		return false, "TriggerSizeInvalid"
	end
	local size = triggerSize :: Vector3
	-- A separately measured source plane is stronger presentation evidence than
	-- a trigger AABB's thin axis. BuildSurfacePlan validates that plane and its
	-- agreement with this normal before producing any runtime geometry.
	if visualSurface ~= nil then
		return true, nil
	end
	if not isAxisNormal(normal) then
		return true, nil
	end
	if size.X + EPSILON < size.Z and math.abs(normal.X) < 1 - EPSILON then
		return false, "MustMatchThinHorizontalAxis"
	end
	if size.Z + EPSILON < size.X and math.abs(normal.Z) < 1 - EPSILON then
		return false, "MustMatchThinHorizontalAxis"
	end
	return true, nil
end

function TeleporterPresentationRules.BuildSurfacePlan(
	triggerPosition: Vector3,
	triggerSize: Vector3,
	visualNormal: Vector3,
	visualSurface: VisualSurface?
): (SurfacePlan?, string?)
	if not finiteVector3(triggerPosition) then
		return nil, "TriggerPositionInvalid"
	end
	local valid, validationError =
		TeleporterPresentationRules.ValidateVisualNormal(visualNormal, triggerSize, visualSurface)
	if not valid then
		return nil, validationError
	end
	local normal = assert(horizontalUnitNormal(visualNormal))
	if visualSurface then
		local surfaceValid, surfaceError = TeleporterPresentationRules.ValidateVisualSurface(visualSurface)
		if not surfaceValid then
			return nil, surfaceError
		end
		local surfaceNormal = assert(horizontalUnitNormal(visualSurface.normal))
		if surfaceNormal:Dot(normal) < 1 - NORMAL_MATCH_EPSILON then
			return nil, "VisualSurfaceNormalMismatch"
		end
		local position = visualSurface.position + normal * (SURFACE_BACK_CLEARANCE + SURFACE_DEPTH * 0.5)
		local back = normal:Cross(Vector3.yAxis).Unit
		return table.freeze({
			position = position,
			size = Vector3.new(
				SURFACE_DEPTH,
				visualSurface.height * SURFACE_HEIGHT_SCALE,
				visualSurface.width * SURFACE_WIDTH_SCALE
			),
			cframe = CFrame.fromMatrix(position, normal, Vector3.yAxis, back),
			normal = normal,
		}),
			nil
	end
	if not isAxisNormal(normal) then
		return nil, "DiagonalNormalRequiresVisualSurface"
	end
	local xNormal = math.abs(normal.X) > 0.5
	local triggerDepth = if xNormal then triggerSize.X else triggerSize.Z
	local apertureWidth = if xNormal then triggerSize.Z else triggerSize.X
	local frontDistance = math.max(triggerDepth * 0.5, MINIMUM_BACKING_FRONT_DISTANCE)
		+ SURFACE_BACK_CLEARANCE
		+ SURFACE_DEPTH * 0.5
	local surfaceSize = if xNormal
		then Vector3.new(SURFACE_DEPTH, triggerSize.Y * SURFACE_HEIGHT_SCALE, apertureWidth * SURFACE_WIDTH_SCALE)
		else Vector3.new(apertureWidth * SURFACE_WIDTH_SCALE, triggerSize.Y * SURFACE_HEIGHT_SCALE, SURFACE_DEPTH)
	return table.freeze({
		position = triggerPosition + normal * frontDistance,
		size = surfaceSize,
		cframe = CFrame.new(triggerPosition + normal * frontDistance),
		normal = normal,
	}),
		nil
end

function TeleporterPresentationRules.HousingRotationDegrees(visualNormal: Vector3): Vector3
	local normal = assert(horizontalUnitNormal(visualNormal))
	return Vector3.new(0, math.deg(math.atan2(normal.X, normal.Z)), 0)
end

TeleporterPresentationRules.SurfaceName = "PortalSurface"
TeleporterPresentationRules.SurfaceColor = Color3.fromRGB(165, 78, 224)
TeleporterPresentationRules.SurfaceTransparency = 0.35
TeleporterPresentationRules.SurfaceWidthScale = SURFACE_WIDTH_SCALE
TeleporterPresentationRules.SurfaceHeightScale = SURFACE_HEIGHT_SCALE
TeleporterPresentationRules.SurfaceDepth = SURFACE_DEPTH
TeleporterPresentationRules.SurfaceBackClearance = SURFACE_BACK_CLEARANCE
TeleporterPresentationRules.MinimumBackingFrontDistance = MINIMUM_BACKING_FRONT_DISTANCE
TeleporterPresentationRules.MaximumSurfaceExtent = MAXIMUM_SURFACE_EXTENT
TeleporterPresentationRules.BackingPositionScale = BACKING_POSITION_SCALE
TeleporterPresentationRules.BackingSizeScale = BACKING_SIZE_SCALE

return table.freeze(TeleporterPresentationRules)
