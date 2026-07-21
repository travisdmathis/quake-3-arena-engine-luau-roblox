--!strict

-- Reversible static-render proxy rollout. This module owns geometry-only rules;
-- it never mutates authoritative collision Parts. Every registered production
-- map is explicitly listed so a future map cannot silently enter the required
-- presentation path without geometry and device-budget certification.

local ArenaMaterialTextureCatalog = require(script.Parent.ArenaMaterialTextureCatalog)
local MapSchema = require(script.Parent.MapSchema)
local StaticWorldPresentationRules = require(script.Parent.StaticWorldPresentationRules)

local StaticWorldRenderProxyRules = {}

export type FaceGeometry = {
	vertices: { Vector3 },
	uvs: { Vector2 },
	normal: Vector3,
}

export type GroupIdentity = {
	key: string,
	origin: Vector3,
	textureAssetKey: string,
	textureRobloxAssetId: number,
	styleId: string,
}

local ROLLOUT_MAP_IDS = table.freeze({
	"achromatic_layout_v1",
	"aerowalk_layout_v1",
	"all_the_aces_ra3_v1",
	"bad_ball_ctf_v1",
	"blood_covenant_layout_v1",
	"blood_run_layout_v1",
	"corrosion_layout_v1",
	"dm17_duel_layout_v1",
	"evil_gemini_ctf_v1",
	"foundry_divide_v1",
	"in_perfect_harmony_ra3_v1",
	"terminatria_layout_v1",
	"theatre_of_pain_ra3_v1",
	"trespass_layout_v1",
	"xtreme_force_ctf_v1",
})
local rolloutMapSet: { [string]: boolean } = {}
for _, mapId in ROLLOUT_MAP_IDS do
	assert(not rolloutMapSet[mapId], "duplicate static render proxy rollout map " .. mapId)
	rolloutMapSet[mapId] = true
end
table.freeze(rolloutMapSet)
local CELL_SIZE_STUDS = 192
local MAXIMUM_FACES_PER_MESH = 768
local FACES_PER_BUILD_YIELD = MAXIMUM_FACES_PER_MESH
local SURFACE_OFFSET_STUDS = 0.01

local DISABLE_ATTRIBUTE = "Q3EngineDisableStaticRenderProxy"
local STATUS_ATTRIBUTE = "ArenaStaticRenderProxyStatus"
local READINESS_ATTRIBUTE = "Q3EngineMapPresentationReadiness"
local REQUIRED_ATTRIBUTE = "Q3EngineStaticRenderProxyRequired"
local DECISION_MAP_ID_ATTRIBUTE = "Q3EngineStaticRenderProxyDecisionMapId"
local PROXY_MODEL_NAME = "ArenaStaticRenderProxy"

local Status = table.freeze({
	Fallback = "Fallback",
	Building = "Building",
	Active = "Active",
	Compromised = "Compromised",
	Failed = "Failed",
})

local Readiness = table.freeze({
	WaitingForWorld = "WaitingForWorld",
	Building = "Building",
	SuppressingLegacyTextures = "SuppressingLegacyTextures",
	Active = "Active",
	NotRequired = "NotRequired",
	Failed = "Failed",
})

local function chunkCFrame(chunk: MapSchema.StaticChunk): CFrame
	local rotation = chunk.rotationDegrees
	return CFrame.new(chunk.position) * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
end

local function faceFrame(face: MapSchema.TextureFace, halfSize: Vector3): (Vector3, Vector3, Vector3, number, number)
	if face == MapSchema.TextureFaces.Right then
		return Vector3.xAxis * halfSize.X, -Vector3.zAxis, Vector3.yAxis, halfSize.Z, halfSize.Y
	elseif face == MapSchema.TextureFaces.Left then
		return -Vector3.xAxis * halfSize.X, Vector3.zAxis, Vector3.yAxis, halfSize.Z, halfSize.Y
	elseif face == MapSchema.TextureFaces.Front then
		return -Vector3.zAxis * halfSize.Z, -Vector3.xAxis, Vector3.yAxis, halfSize.X, halfSize.Y
	elseif face == MapSchema.TextureFaces.Back then
		return Vector3.zAxis * halfSize.Z, Vector3.xAxis, Vector3.yAxis, halfSize.X, halfSize.Y
	elseif face == MapSchema.TextureFaces.Top then
		return Vector3.yAxis * halfSize.Y, Vector3.xAxis, -Vector3.zAxis, halfSize.X, halfSize.Z
	elseif face == MapSchema.TextureFaces.Bottom then
		return -Vector3.yAxis * halfSize.Y, Vector3.xAxis, Vector3.zAxis, halfSize.X, halfSize.Z
	end
	error("unsupported static render proxy face " .. tostring(face))
end

function StaticWorldRenderProxyRules.IsEnabledMap(mapId: string): boolean
	return rolloutMapSet[mapId] == true
end

function StaticWorldRenderProxyRules.GroupIdentity(
	chunk: MapSchema.StaticChunk,
	plan: StaticWorldPresentationRules.TexturePlan
): GroupIdentity
	local skinId = assert(chunk.skinId, "proxy-eligible chunk is missing its skin")
	local binding = ArenaMaterialTextureCatalog.Resolve(skinId, plan.materialRole)
	local cellX = math.floor(chunk.position.X / CELL_SIZE_STUDS)
	local cellY = math.floor(chunk.position.Y / CELL_SIZE_STUDS)
	local cellZ = math.floor(chunk.position.Z / CELL_SIZE_STUDS)
	local origin =
		Vector3.new((cellX + 0.5) * CELL_SIZE_STUDS, (cellY + 0.5) * CELL_SIZE_STUDS, (cellZ + 0.5) * CELL_SIZE_STUDS)
	local key = string.format("%d:%d:%d:%s:%s", cellX, cellY, cellZ, binding.textureAssetKey, chunk.styleId)
	return {
		key = key,
		origin = origin,
		textureAssetKey = binding.textureAssetKey,
		textureRobloxAssetId = binding.textureRobloxAssetId,
		styleId = chunk.styleId,
	}
end

function StaticWorldRenderProxyRules.FaceGeometry(
	chunk: MapSchema.StaticChunk,
	plan: StaticWorldPresentationRules.TexturePlan,
	origin: Vector3
): FaceGeometry
	assert(chunk.shape == MapSchema.ChunkShapes.Block, "static render proxy accepts Block chunks only")
	local studsPerTile = assert(
		StaticWorldPresentationRules.TextureStudsPerTile[plan.materialRole],
		"render proxy material role is missing its texture scale"
	)
	local halfSize = chunk.size * 0.5
	local center, uAxis, vAxis, uHalf, vHalf = faceFrame(plan.face, halfSize)
	local localNormal = uAxis:Cross(vAxis)
	-- Keep the render plane just above the unchanged collision Part, matching
	-- the role previously served by a Texture child without creating coplanar
	-- MeshPart/Part z-fighting.
	center += localNormal * SURFACE_OFFSET_STUDS
	local cframe = chunkCFrame(chunk)
	local localVertices = {
		center - uAxis * uHalf - vAxis * vHalf,
		center + uAxis * uHalf - vAxis * vHalf,
		center + uAxis * uHalf + vAxis * vHalf,
		center - uAxis * uHalf + vAxis * vHalf,
	}
	local vertices = table.create(4)
	for index, localVertex in localVertices do
		vertices[index] = cframe:PointToWorldSpace(localVertex) - origin
	end
	local uTiles = (uHalf * 2) / studsPerTile
	local vTiles = (vHalf * 2) / studsPerTile
	-- Roblox image V=0 is the top edge. Geometric +V is the visible top for
	-- vertical faces, so the lower two vertices receive the larger V value.
	local uvs = {
		Vector2.new(0, vTiles),
		Vector2.new(uTiles, vTiles),
		Vector2.new(uTiles, 0),
		Vector2.zero,
	}
	return {
		vertices = vertices,
		uvs = uvs,
		normal = cframe:VectorToWorldSpace(localNormal),
	}
end

StaticWorldRenderProxyRules.RolloutMapIds = ROLLOUT_MAP_IDS
StaticWorldRenderProxyRules.RolloutMapCount = #ROLLOUT_MAP_IDS
StaticWorldRenderProxyRules.CellSizeStuds = CELL_SIZE_STUDS
StaticWorldRenderProxyRules.MaximumFacesPerMesh = MAXIMUM_FACES_PER_MESH
StaticWorldRenderProxyRules.FacesPerBuildYield = FACES_PER_BUILD_YIELD
StaticWorldRenderProxyRules.SurfaceOffsetStuds = SURFACE_OFFSET_STUDS
StaticWorldRenderProxyRules.DisableAttribute = DISABLE_ATTRIBUTE
StaticWorldRenderProxyRules.StatusAttribute = STATUS_ATTRIBUTE
StaticWorldRenderProxyRules.ReadinessAttribute = READINESS_ATTRIBUTE
StaticWorldRenderProxyRules.RequiredAttribute = REQUIRED_ATTRIBUTE
StaticWorldRenderProxyRules.DecisionMapIdAttribute = DECISION_MAP_ID_ATTRIBUTE
StaticWorldRenderProxyRules.ProxyModelName = PROXY_MODEL_NAME
StaticWorldRenderProxyRules.Status = Status
StaticWorldRenderProxyRules.Readiness = Readiness

return table.freeze(StaticWorldRenderProxyRules)
