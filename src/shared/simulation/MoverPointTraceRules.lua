--[[
SPDX-License-Identifier: GPL-2.0-or-later

Exact point trace against oriented mover convex planes translated from:
  code/qcommon/cm_trace.c (CM_TraceThroughBrush and SURFACE_CLIP_EPSILON)
  code/server/sv_world.c (source-ordered entity clipping)
  code/game/g_weapon.c (MASK_SHOT point traces)

Block planes and the measured Roblox Wedge triangular-prism planes are original
the Roblox Luau port geometry adapters. Inputs are bounded, immutable, source ordered,
and server/prediction safe; no Instance or presentation geometry is queried.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type ShapeKind = "Block" | "Wedge"
export type Shape = {
	id: string,
	sourceOrder: number,
	shape: ShapeKind,
	cframe: CFrame,
	size: Vector3,
	contents: number,
	active: boolean,
}

export type Contact = {
	id: string,
	sourceOrder: number,
	contents: number,
}

export type Result = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	contact: Contact?,
}

type Plane = {
	normal: Vector3,
	distance: number,
}

type Interval = {
	entry: number,
	exit: number,
	normal: Vector3,
}

local MoverPointTraceRules = {}

local SURFACE_CLIP_EPSILON = 0.125 * Constants.UnitsToStuds
local MAXIMUM_SHAPES = 512
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MAXIMUM_SOURCE_ORDER = 2_147_483_647
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MINIMUM_GEOMETRY_SIZE = 0.001

local SHAPE_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	sourceOrder = true,
	shape = true,
	cframe = true,
	size = true,
	contents = true,
	active = true,
})

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isBoundedVector(value: unknown, maximum: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= maximum
		and math.abs(vector.Y) <= maximum
		and math.abs(vector.Z) <= maximum
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_GEOMETRY_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_GEOMETRY_SIZE and size.Y >= MINIMUM_GEOMETRY_SIZE and size.Z >= MINIMUM_GEOMETRY_SIZE
end

local function isFiniteCFrame(value: unknown): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end
	for _, component in { (value :: CFrame):GetComponents() } do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return isBoundedVector((value :: CFrame).Position, MAXIMUM_COORDINATE)
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or SHAPE_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 7
end

local function denseArrayLength(value: { [unknown]: unknown }): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "shapes-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_SHAPES or maximumIndex > MAXIMUM_SHAPES then
			return nil, "too-many-shapes"
		end
	end
	if maximumIndex ~= count then
		return nil, "shapes-not-dense-array"
	end
	return count, nil
end

local function validateShape(value: unknown): (Shape?, string?)
	if type(value) ~= "table" then
		return nil, "shape-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source) then
		return nil, "invalid-shape-record"
	end
	if not isValidId(source.id) then
		return nil, "invalid-shape-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-shape-source-order"
	end
	if source.shape ~= "Block" and source.shape ~= "Wedge" then
		return nil, "invalid-shape-kind"
	end
	if not isFiniteCFrame(source.cframe) then
		return nil, "invalid-shape-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-shape-size"
	end
	if not isIntegerInRange(source.contents, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-shape-contents"
	end
	if type(source.active) ~= "boolean" then
		return nil, "invalid-shape-active"
	end
	local center = (source.cframe :: CFrame).Position
	local radius = ((source.size :: Vector3) * 0.5).Magnitude
	if
		math.abs(center.X) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Z) + radius > MAXIMUM_COORDINATE
	then
		return nil, "shape-out-of-bounds"
	end
	local shape: Shape = {
		id = source.id :: string,
		sourceOrder = source.sourceOrder :: number,
		shape = source.shape :: ShapeKind,
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		contents = source.contents :: number,
		active = source.active :: boolean,
	}
	table.freeze(shape)
	return shape, nil
end

function MoverPointTraceRules.ValidateAndOrderShapes(value: unknown): ({ Shape }?, string?)
	if type(value) ~= "table" then
		return nil, "shapes-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source)
	if not count then
		return nil, countError
	end
	local shapes: { Shape } = {}
	local ids: { [string]: boolean } = {}
	local sourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local shape, shapeError = validateShape(source[index])
		if not shape then
			return nil, string.format("shape-%d:%s", index, shapeError or "invalid")
		end
		if ids[shape.id] then
			return nil, string.format("shape-%d:duplicate-shape-id", index)
		end
		if sourceOrders[shape.sourceOrder] then
			return nil, string.format("shape-%d:duplicate-source-order", index)
		end
		ids[shape.id] = true
		sourceOrders[shape.sourceOrder] = true
		table.insert(shapes, shape)
	end
	table.sort(shapes, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(shapes)
	return shapes, nil
end

local function plane(normal: Vector3, point: Vector3): Plane
	return {
		normal = normal,
		distance = normal:Dot(point),
	}
end

local function blockPlanes(shape: Shape): { Plane }
	local center = shape.cframe.Position
	local half = shape.size * 0.5
	local x = shape.cframe.XVector
	local y = shape.cframe.YVector
	local z = shape.cframe.ZVector
	return {
		plane(-x, center - x * half.X),
		plane(x, center + x * half.X),
		plane(-y, center - y * half.Y),
		plane(y, center + y * half.Y),
		plane(-z, center - z * half.Z),
		plane(z, center + z * half.Z),
	}
end

local function wedgePlanes(shape: Shape): { Plane }
	local center = shape.cframe.Position
	local half = shape.size * 0.5
	local x = shape.cframe.XVector
	local y = shape.cframe.YVector
	local z = shape.cframe.ZVector
	local slope = shape.cframe:VectorToWorldSpace(Vector3.new(0, 1 / half.Y, -1 / half.Z).Unit)
	return {
		plane(-x, center - x * half.X),
		plane(x, center + x * half.X),
		plane(-y, center - y * half.Y),
		plane(z, center + z * half.Z),
		plane(slope, center),
	}
end

local function clipPlane(
	startDistance: number,
	endDistance: number,
	planeNormal: Vector3,
	interval: Interval
): Interval?
	if startDistance > 0 and (endDistance >= SURFACE_CLIP_EPSILON or endDistance >= startDistance) then
		return nil
	end
	if startDistance <= 0 and endDistance <= 0 then
		return interval
	end
	local entry = interval.entry
	local exit = interval.exit
	local normal = interval.normal
	if startDistance > endDistance then
		local fraction = math.max((startDistance - SURFACE_CLIP_EPSILON) / (startDistance - endDistance), 0)
		if fraction > entry then
			entry = fraction
			normal = planeNormal
		end
	else
		local fraction = math.min((startDistance + SURFACE_CLIP_EPSILON) / (startDistance - endDistance), 1)
		if fraction < exit then
			exit = fraction
		end
	end
	return {
		entry = entry,
		exit = exit,
		normal = normal,
	}
end

local function inside(point: Vector3, planes: { Plane }): boolean
	for _, brushPlane in planes do
		if point:Dot(brushPlane.normal) - brushPlane.distance > 0 then
			return false
		end
	end
	return true
end

local function contactFor(shape: Shape): Contact
	return table.freeze({
		id = shape.id,
		sourceOrder = shape.sourceOrder,
		contents = shape.contents,
	})
end

local function traceShape(origin: Vector3, displacement: Vector3, shape: Shape): Result?
	local planes = if shape.shape == "Block" then blockPlanes(shape) else wedgePlanes(shape)
	if inside(origin, planes) then
		local allSolid = inside(origin + displacement, planes)
		return {
			hit = allSolid,
			fraction = if allSolid then 0 else 1,
			normal = Vector3.zero,
			startSolid = true,
			allSolid = allSolid,
			contact = contactFor(shape),
		}
	end
	local endpoint = origin + displacement
	local interval: Interval = { entry = -1, exit = 1, normal = Vector3.zero }
	for _, brushPlane in planes do
		interval = clipPlane(
			origin:Dot(brushPlane.normal) - brushPlane.distance,
			endpoint:Dot(brushPlane.normal) - brushPlane.distance,
			brushPlane.normal,
			interval
		)
		if not interval then
			return nil
		end
	end
	if interval.entry >= interval.exit or interval.entry <= -1 or interval.entry >= 1 then
		return nil
	end
	return {
		hit = true,
		fraction = interval.entry,
		normal = interval.normal,
		startSolid = false,
		allSolid = false,
		contact = contactFor(shape),
	}
end

local function frozenResult(result: Result): Result
	if result.contact and not table.isfrozen(result.contact) then
		table.freeze(result.contact)
	end
	table.freeze(result)
	return result
end

function MoverPointTraceRules.Trace(
	shapesValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	clipMaskValue: unknown
): (Result?, string?)
	if not isBoundedVector(originValue, MAXIMUM_COORDINATE) then
		return nil, "invalid-trace-origin"
	end
	if not isBoundedVector(displacementValue, MAXIMUM_COORDINATE * 2) then
		return nil, "invalid-trace-displacement"
	end
	if not isIntegerInRange(clipMaskValue, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-trace-clip-mask"
	end
	local origin = originValue :: Vector3
	local displacement = displacementValue :: Vector3
	if not isBoundedVector(origin + displacement, MAXIMUM_COORDINATE) then
		return nil, "trace-out-of-bounds"
	end
	local shapes, shapesError = MoverPointTraceRules.ValidateAndOrderShapes(shapesValue)
	if not shapes then
		return nil, shapesError
	end
	local best: Result = {
		hit = false,
		fraction = 1,
		normal = Vector3.zero,
		startSolid = false,
		allSolid = false,
		contact = nil,
	}
	local startSolid = false
	for _, shape in shapes do
		if not shape.active or bit32.band(clipMaskValue :: number, shape.contents) == 0 then
			continue
		end
		local candidate = traceShape(origin, displacement, shape)
		if not candidate then
			continue
		end
		startSolid = startSolid or candidate.startSolid
		if candidate.allSolid then
			return frozenResult(candidate), nil
		end
		if candidate.hit and candidate.fraction < best.fraction then
			best = candidate
		end
	end
	best.startSolid = startSolid
	return frozenResult(best), nil
end

MoverPointTraceRules.SurfaceClipEpsilon = SURFACE_CLIP_EPSILON
MoverPointTraceRules.MaximumShapes = MAXIMUM_SHAPES

return table.freeze(MoverPointTraceRules)
