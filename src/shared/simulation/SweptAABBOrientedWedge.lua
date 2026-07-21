--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only non-Block mover collision boundary derived from:
  code/qcommon/cm_trace.c (box trace against convex brush planes)
  code/game/g_mover.c (bmodel linking and G_TestEntityPosition)
  code/server/sv_world.c (source-ordered dynamic trace composition)

The Roblox WedgePart adapter uses its measured local triangular-prism solid:
for half extents hx/hy/hz, the YZ triangle is
(-hy,-hz), (-hy,+hz), (+hy,+hz), so the sloped face is y/hy=z/hz
with solid below it. Continuous SAT uses body and wedge face normals plus every
body-edge/wedge-edge cross axis. Stable ordering, strict contact, bounded
immutable validation, and explicit source identities are original adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type OrderedWedge = {
	id: string,
	sourceOrder: number,
	cframe: CFrame,
	size: Vector3,
	contents: number,
	active: boolean,
}

export type OrderedContact = {
	id: string,
	sourceOrder: number,
	contents: number,
}

export type OrderedResult = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	contact: OrderedContact?,
}

local SweptAABBOrientedWedge = {}

local EPSILON = 1e-7
local AXIS_EPSILON = 1e-10
local MAXIMUM_WEDGES = 512
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MAXIMUM_SOURCE_ORDER = 2_147_483_647
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MINIMUM_GEOMETRY_SIZE = 0.001

local WEDGE_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	sourceOrder = true,
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
		if type(key) ~= "string" or WEDGE_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 6
end

local function denseArrayLength(value: { [unknown]: unknown }): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "wedges-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_WEDGES or maximumIndex > MAXIMUM_WEDGES then
			return nil, "too-many-wedges"
		end
	end
	if maximumIndex ~= count then
		return nil, "wedges-not-dense-array"
	end
	return count, nil
end

local function validateWedge(value: unknown): (OrderedWedge?, string?)
	if type(value) ~= "table" then
		return nil, "wedge-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source) then
		return nil, "invalid-wedge-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-wedge-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-wedge-source-order"
	end
	if not isFiniteCFrame(source.cframe) then
		return nil, "invalid-wedge-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-wedge-size"
	end
	if not isIntegerInRange(source.contents, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-wedge-contents"
	end
	if type(source.active) ~= "boolean" then
		return nil, "invalid-wedge-active"
	end
	local center = (source.cframe :: CFrame).Position
	local radius = ((source.size :: Vector3) * 0.5).Magnitude
	if
		math.abs(center.X) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Z) + radius > MAXIMUM_COORDINATE
	then
		return nil, "wedge-out-of-bounds"
	end
	local wedge: OrderedWedge = {
		id = source.id :: string,
		sourceOrder = source.sourceOrder :: number,
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		contents = source.contents :: number,
		active = source.active :: boolean,
	}
	table.freeze(wedge)
	return wedge, nil
end

function SweptAABBOrientedWedge.ValidateAndOrderWedges(value: unknown): ({ OrderedWedge }?, string?)
	if type(value) ~= "table" then
		return nil, "wedges-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source)
	if not count then
		return nil, countError
	end
	local wedges: { OrderedWedge } = {}
	local ids: { [string]: boolean } = {}
	local sourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local wedge, wedgeError = validateWedge(source[index])
		if not wedge then
			return nil, string.format("wedge-%d:%s", index, wedgeError or "invalid")
		end
		if ids[wedge.id] then
			return nil, string.format("wedge-%d:duplicate-wedge-id", index)
		end
		if sourceOrders[wedge.sourceOrder] then
			return nil, string.format("wedge-%d:duplicate-source-order", index)
		end
		ids[wedge.id] = true
		sourceOrders[wedge.sourceOrder] = true
		table.insert(wedges, wedge)
	end
	table.sort(wedges, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(wedges)
	return wedges, nil
end

local function localVertices(size: Vector3): { Vector3 }
	local half = size * 0.5
	local vertices: { Vector3 } = {}
	for _, x in { -half.X, half.X } do
		table.insert(vertices, Vector3.new(x, -half.Y, -half.Z))
		table.insert(vertices, Vector3.new(x, -half.Y, half.Z))
		table.insert(vertices, Vector3.new(x, half.Y, half.Z))
	end
	return vertices
end

local function worldVertices(wedge: OrderedWedge): { Vector3 }
	local vertices = localVertices(wedge.size)
	for index, vertex in vertices do
		vertices[index] = wedge.cframe:PointToWorldSpace(vertex)
	end
	return vertices
end

local function axesFor(wedge: OrderedWedge): { Vector3 }
	local half = wedge.size * 0.5
	local localSlopeNormal = Vector3.new(0, 1 / half.Y, -1 / half.Z).Unit
	local localDiagonal = Vector3.new(0, half.Y, half.Z).Unit
	local localFaceNormals = {
		Vector3.xAxis,
		-Vector3.xAxis,
		-Vector3.yAxis,
		Vector3.zAxis,
		localSlopeNormal,
	}
	local localEdges = {
		Vector3.xAxis,
		Vector3.yAxis,
		Vector3.zAxis,
		localDiagonal,
	}
	local worldAxes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local axes: { Vector3 } = table.create(20)
	for _, axis in worldAxes do
		table.insert(axes, axis)
	end
	for _, localNormal in localFaceNormals do
		table.insert(axes, wedge.cframe:VectorToWorldSpace(localNormal).Unit)
	end
	for _, worldAxis in worldAxes do
		for _, localEdge in localEdges do
			local edge = wedge.cframe:VectorToWorldSpace(localEdge)
			local cross = worldAxis:Cross(edge)
			if cross.Magnitude > AXIS_EPSILON then
				table.insert(axes, cross.Unit)
			end
		end
	end
	return axes
end

local function movingRadius(half: Vector3, axis: Vector3): number
	return half.X * math.abs(axis.X) + half.Y * math.abs(axis.Y) + half.Z * math.abs(axis.Z)
end

local function wedgeProjection(vertices: { Vector3 }, axis: Vector3): (number, number)
	local minimum = math.huge
	local maximum = -math.huge
	for _, vertex in vertices do
		local projection = vertex:Dot(axis)
		minimum = math.min(minimum, projection)
		maximum = math.max(maximum, projection)
	end
	return minimum, maximum
end

local function contactFor(wedge: OrderedWedge): OrderedContact
	return table.freeze({
		id = wedge.id,
		sourceOrder = wedge.sourceOrder,
		contents = wedge.contents,
	})
end

local function traceWedge(
	start: Vector3,
	displacement: Vector3,
	movingHalf: Vector3,
	wedge: OrderedWedge
): OrderedResult
	local vertices = worldVertices(wedge)
	local startSolid = true
	local endSolid = true
	local enter = 0
	local exit = 1
	local normal = Vector3.zero
	for _, axis in axesFor(wedge) do
		local wedgeMinimum, wedgeMaximum = wedgeProjection(vertices, axis)
		local radius = movingRadius(movingHalf, axis)
		local low = wedgeMinimum - radius
		local high = wedgeMaximum + radius
		local coordinate = start:Dot(axis)
		local delta = displacement:Dot(axis)
		if coordinate <= low + EPSILON or coordinate >= high - EPSILON then
			startSolid = false
		end
		local endCoordinate = coordinate + delta
		if endCoordinate <= low + EPSILON or endCoordinate >= high - EPSILON then
			endSolid = false
		end
		if math.abs(delta) <= EPSILON then
			if coordinate <= low + EPSILON or coordinate >= high - EPSILON then
				return {
					hit = false,
					fraction = 1,
					normal = Vector3.yAxis,
					startSolid = false,
					allSolid = false,
					contact = nil,
				}
			end
			continue
		end
		local first = (low - coordinate) / delta
		local second = (high - coordinate) / delta
		local entryNormal = -axis
		if first > second then
			first, second = second, first
			entryNormal = axis
		end
		if first > enter or (math.abs(first - enter) <= EPSILON and normal.Magnitude <= EPSILON) then
			enter = first
			normal = entryNormal
		end
		exit = math.min(exit, second)
		if enter > exit then
			return {
				hit = false,
				fraction = 1,
				normal = Vector3.yAxis,
				startSolid = false,
				allSolid = false,
				contact = nil,
			}
		end
	end
	if startSolid then
		return {
			hit = endSolid,
			fraction = if endSolid then 0 else 1,
			normal = Vector3.yAxis,
			startSolid = true,
			allSolid = endSolid,
			contact = contactFor(wedge),
		}
	end
	if enter < 0 or enter > 1 or normal.Magnitude <= EPSILON then
		return {
			hit = false,
			fraction = 1,
			normal = Vector3.yAxis,
			startSolid = false,
			allSolid = false,
			contact = nil,
		}
	end
	return {
		hit = true,
		fraction = math.clamp(enter, 0, 1),
		normal = normal,
		startSolid = false,
		allSolid = false,
		contact = contactFor(wedge),
	}
end

local function validateQuery(
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (Vector3?, Vector3?, Vector3?, Vector3?, number?, string?)
	if not isBoundedVector(originValue, MAXIMUM_COORDINATE) then
		return nil, nil, nil, nil, nil, "invalid-trace-origin"
	end
	if not isBoundedVector(displacementValue, MAXIMUM_COORDINATE * 2) then
		return nil, nil, nil, nil, nil, "invalid-trace-displacement"
	end
	if not isValidSize(movingSizeValue) then
		return nil, nil, nil, nil, nil, "invalid-trace-size"
	end
	if not isBoundedVector(movingCenterOffsetValue, MAXIMUM_GEOMETRY_SIZE) then
		return nil, nil, nil, nil, nil, "invalid-trace-center-offset"
	end
	if not isIntegerInRange(clipMaskValue, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, nil, nil, nil, nil, "invalid-trace-clip-mask"
	end
	local origin = originValue :: Vector3
	local displacement = displacementValue :: Vector3
	local size = movingSizeValue :: Vector3
	local centerOffset = movingCenterOffsetValue :: Vector3
	local start = origin + centerOffset
	local finish = start + displacement
	local radius = (size * 0.5).Magnitude
	if
		not isBoundedVector(start, MAXIMUM_COORDINATE)
		or not isBoundedVector(finish, MAXIMUM_COORDINATE)
		or math.abs(start.X) + radius > MAXIMUM_COORDINATE
		or math.abs(start.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(start.Z) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.X) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.Z) + radius > MAXIMUM_COORDINATE
	then
		return nil, nil, nil, nil, nil, "trace-out-of-bounds"
	end
	return origin, displacement, size, centerOffset, clipMaskValue :: number, nil
end

local function freezeResult(result: OrderedResult): OrderedResult
	if result.contact and not table.isfrozen(result.contact) then
		table.freeze(result.contact)
	end
	table.freeze(result)
	return result
end

function SweptAABBOrientedWedge.TraceOrderedWedges(
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	wedgesValue: unknown,
	clipMaskValue: unknown
): (OrderedResult?, string?)
	local origin, displacement, size, centerOffset, clipMask, queryError =
		validateQuery(originValue, displacementValue, movingSizeValue, movingCenterOffsetValue, clipMaskValue)
	if not origin then
		return nil, queryError
	end
	local wedges, wedgesError = SweptAABBOrientedWedge.ValidateAndOrderWedges(wedgesValue)
	if not wedges then
		return nil, wedgesError
	end
	local best: OrderedResult = {
		hit = false,
		fraction = 1,
		normal = Vector3.yAxis,
		startSolid = false,
		allSolid = false,
		contact = nil,
	}
	local startSolid = false
	for _, wedge in wedges do
		if not wedge.active or bit32.band(clipMask :: number, wedge.contents) == 0 then
			continue
		end
		local candidate = traceWedge(
			(origin :: Vector3) + (centerOffset :: Vector3),
			displacement :: Vector3,
			(size :: Vector3) * 0.5,
			wedge
		)
		startSolid = startSolid or candidate.startSolid
		if candidate.allSolid then
			return freezeResult(candidate), nil
		end
		if candidate.hit and candidate.fraction < best.fraction then
			best = candidate
		end
	end
	best.startSolid = startSolid
	return freezeResult(best), nil
end

function SweptAABBOrientedWedge.PointContentsOrderedWedges(
	wedgesValue: unknown,
	pointValue: unknown
): (number?, string?)
	if not isBoundedVector(pointValue, MAXIMUM_COORDINATE) then
		return nil, "invalid-point"
	end
	local wedges, wedgesError = SweptAABBOrientedWedge.ValidateAndOrderWedges(wedgesValue)
	if not wedges then
		return nil, wedgesError
	end
	local point = pointValue :: Vector3
	local contents = 0
	for _, wedge in wedges do
		if not wedge.active then
			continue
		end
		local localPoint = wedge.cframe:PointToObjectSpace(point)
		local half = wedge.size * 0.5
		local slope = localPoint.Y / half.Y - localPoint.Z / half.Z
		if
			math.abs(localPoint.X) < half.X - EPSILON
			and localPoint.Y > -half.Y + EPSILON
			and localPoint.Z > -half.Z + EPSILON
			and localPoint.Z < half.Z - EPSILON
			and slope < -EPSILON
		then
			contents = bit32.bor(contents, wedge.contents)
		end
	end
	return contents, nil
end

SweptAABBOrientedWedge.MaximumOrderedWedges = MAXIMUM_WEDGES
SweptAABBOrientedWedge.MaximumCoordinate = MAXIMUM_COORDINATE
SweptAABBOrientedWedge.MaximumGeometrySize = MAXIMUM_GEOMETRY_SIZE
SweptAABBOrientedWedge.MaximumSourceOrder = MAXIMUM_SOURCE_ORDER

return table.freeze(SweptAABBOrientedWedge)
