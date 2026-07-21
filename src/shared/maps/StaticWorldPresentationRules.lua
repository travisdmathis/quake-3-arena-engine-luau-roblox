--!strict

-- Presentation-only policy for large static worlds. Authoritative geometry is
-- left untouched; managed Texture children may be created and removed locally
-- without changing collision, query, or surface metadata.

local ArenaKitCatalog = require(script.Parent.ArenaKitCatalog)
local ArenaMaterialTextureCatalog = require(script.Parent.ArenaMaterialTextureCatalog)
local MapSchema = require(script.Parent.MapSchema)
local StaticWorldPartPolicy = require(script.Parent.Parent.simulation.StaticWorldPartPolicy)

local StaticWorldPresentationRules = {}

export type TexturePlan = {
	face: MapSchema.TextureFace,
	materialRole: ArenaKitCatalog.FaceRole,
}

local TEXTURE_CREATE_RADIUS_STUDS = 96
local TEXTURE_RETAIN_RADIUS_STUDS = 112
local TEXTURE_FORWARD_PREFETCH_OFFSET_STUDS = 96
local TEXTURE_FORWARD_PREFETCH_CREATE_RADIUS_STUDS = 80
local TEXTURE_FORWARD_PREFETCH_RETAIN_RADIUS_STUDS = 96
local TEXTURE_URGENT_NEAR_RADIUS_STUDS = 64
local MAXIMUM_TEXTURE_MUTATIONS_PER_FRAME = 192

local MANAGED_TEXTURE_ATTRIBUTE = StaticWorldPartPolicy.ManagedTextureAttribute
local MANAGED_TEXTURE_FACE_ATTRIBUTE = StaticWorldPartPolicy.ManagedTextureFaceAttribute
local MANAGED_TEXTURE_NAME_PREFIX = StaticWorldPartPolicy.ManagedTextureNamePrefix
local TEXTURE_STUDS_PER_TILE: { [ArenaKitCatalog.FaceRole]: number } = StaticWorldPartPolicy.TextureStudsPerTile :: any

local TEXTURE_FACE_NORMALS: { [MapSchema.TextureFace]: Enum.NormalId } = table.freeze({
	[MapSchema.TextureFaces.Left] = Enum.NormalId.Left,
	[MapSchema.TextureFaces.Right] = Enum.NormalId.Right,
	[MapSchema.TextureFaces.Front] = Enum.NormalId.Front,
	[MapSchema.TextureFaces.Back] = Enum.NormalId.Back,
	[MapSchema.TextureFaces.Top] = Enum.NormalId.Top,
	[MapSchema.TextureFaces.Bottom] = Enum.NormalId.Bottom,
})

local EMPTY_TEXTURE_PLANS: { TexturePlan } = table.freeze({})

local function texturePlan(face: MapSchema.TextureFace, materialRole: ArenaKitCatalog.FaceRole): TexturePlan
	return table.freeze({
		face = face,
		materialRole = materialRole,
	})
end

local function dominantTextureFacePlans(size: Vector3, role: ArenaKitCatalog.FaceRole): { TexturePlan }
	local plans: { TexturePlan }
	if size.X <= size.Y and size.X <= size.Z then
		plans = {
			texturePlan(MapSchema.TextureFaces.Left, role),
			texturePlan(MapSchema.TextureFaces.Right, role),
		}
	elseif size.Y <= size.X and size.Y <= size.Z then
		plans = {
			texturePlan(MapSchema.TextureFaces.Top, role),
			texturePlan(MapSchema.TextureFaces.Bottom, role),
		}
	else
		plans = {
			texturePlan(MapSchema.TextureFaces.Front, role),
			texturePlan(MapSchema.TextureFaces.Back, role),
		}
	end
	table.freeze(plans)
	return plans
end

function StaticWorldPresentationRules.TexturePlansForChunk(chunk: MapSchema.StaticChunk): { TexturePlan }
	if not chunk.visual or chunk.skinId == nil or chunk.materialRole == nil then
		return EMPTY_TEXTURE_PLANS
	end
	if chunk.textureFaceRoles then
		-- MapSchema's StaticTextureFaceRole is structurally identical to
		-- TexturePlan. The validated map already owns this frozen plan, so
		-- reuse it instead of cloning tens of thousands of records per client.
		return chunk.textureFaceRoles :: { TexturePlan }
	end

	local role = chunk.materialRole
	if role == ArenaKitCatalog.Roles.Wall then
		return dominantTextureFacePlans(chunk.size, role)
	elseif role == ArenaKitCatalog.Roles.Ceiling then
		return table.freeze({ texturePlan(MapSchema.TextureFaces.Bottom, role) })
	end
	return table.freeze({ texturePlan(MapSchema.TextureFaces.Top, role) })
end

function StaticWorldPresentationRules.IsManagedTexture(value: Instance): boolean
	return StaticWorldPartPolicy.IsManagedTexture(value)
end

function StaticWorldPresentationRules.ManagedTextureMatches(value: Instance, skinId: string, plan: TexturePlan): boolean
	if not StaticWorldPresentationRules.IsManagedTexture(value) then
		return false
	end
	local texture = value :: Texture
	local binding = ArenaMaterialTextureCatalog.Resolve(skinId, plan.materialRole)
	return texture.Face == TEXTURE_FACE_NORMALS[plan.face]
		and texture:GetAttribute("ArenaMaterialRole") == plan.materialRole
		and texture:GetAttribute("ArenaTextureAssetKey") == binding.textureAssetKey
		and texture.Texture == "rbxassetid://" .. tostring(binding.textureRobloxAssetId)
end

function StaticWorldPresentationRules.CreateManagedTexture(parent: BasePart, skinId: string, plan: TexturePlan): Texture
	local binding = ArenaMaterialTextureCatalog.Resolve(skinId, plan.materialRole)
	local studsPerTile = assert(
		TEXTURE_STUDS_PER_TILE[plan.materialRole],
		"Arena material role lacks a managed texture scale: " .. plan.materialRole
	)
	local face = assert(TEXTURE_FACE_NORMALS[plan.face], "managed static texture face disappeared")
	local texture = Instance.new("Texture")
	texture.Name = MANAGED_TEXTURE_NAME_PREFIX .. plan.face
	texture.Texture = "rbxassetid://" .. tostring(binding.textureRobloxAssetId)
	texture.Face = face
	texture.StudsPerTileU = studsPerTile
	texture.StudsPerTileV = studsPerTile
	texture.Color3 = Color3.new(1, 1, 1)
	texture.Transparency = 0
	texture:SetAttribute("ArenaVisualOnly", true)
	texture:SetAttribute("ArenaTextureAssetKey", binding.textureAssetKey)
	texture:SetAttribute("ArenaMaterialRole", plan.materialRole)
	texture:SetAttribute(MANAGED_TEXTURE_ATTRIBUTE, true)
	texture:SetAttribute(MANAGED_TEXTURE_FACE_ATTRIBUTE, plan.face)
	texture.Parent = parent
	return texture
end

function StaticWorldPresentationRules.TextureCount(chunk: MapSchema.StaticChunk): number
	return #StaticWorldPresentationRules.TexturePlansForChunk(chunk)
end

function StaticWorldPresentationRules.CreateManagedTextures(parent: BasePart, chunk: MapSchema.StaticChunk): number
	local skinId = chunk.skinId
	if skinId == nil then
		return 0
	end
	local created = 0
	for _, plan in StaticWorldPresentationRules.TexturePlansForChunk(chunk) do
		StaticWorldPresentationRules.CreateManagedTexture(parent, skinId, plan)
		created += 1
	end
	return created
end

function StaticWorldPresentationRules.RemoveManagedTexture(value: Instance): boolean
	if not StaticWorldPresentationRules.IsManagedTexture(value) then
		return false
	end
	value:Destroy()
	return true
end

function StaticWorldPresentationRules.RemoveManagedTextures(root: Instance): number
	local removed = 0
	if StaticWorldPresentationRules.IsManagedTexture(root) then
		root:Destroy()
		return 1
	end
	for _, descendant in root:GetDescendants() do
		if StaticWorldPresentationRules.IsManagedTexture(descendant) then
			descendant:Destroy()
			removed += 1
		end
	end
	return removed
end

function StaticWorldPresentationRules.CountManagedTextures(root: Instance): number
	local count = if StaticWorldPresentationRules.IsManagedTexture(root) then 1 else 0
	for _, descendant in root:GetDescendants() do
		if StaticWorldPresentationRules.IsManagedTexture(descendant) then
			count += 1
		end
	end
	return count
end

function StaticWorldPresentationRules.DistanceSquaredToOrientedBox(
	point: Vector3,
	boxCFrame: CFrame,
	boxSize: Vector3
): number
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local halfSize = boxSize * 0.5
	local deltaX = math.max(math.abs(localPoint.X) - halfSize.X, 0)
	local deltaY = math.max(math.abs(localPoint.Y) - halfSize.Y, 0)
	local deltaZ = math.max(math.abs(localPoint.Z) - halfSize.Z, 0)
	return deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
end

function StaticWorldPresentationRules.ShouldCastShadow(chunk: MapSchema.StaticChunk, staticChunkCount: number): boolean
	return StaticWorldPartPolicy.ShouldCastShadow(chunk, staticChunkCount)
end

StaticWorldPresentationRules.TextureCreateRadiusStuds = TEXTURE_CREATE_RADIUS_STUDS
StaticWorldPresentationRules.TextureRetainRadiusStuds = TEXTURE_RETAIN_RADIUS_STUDS
StaticWorldPresentationRules.TextureForwardPrefetchOffsetStuds = TEXTURE_FORWARD_PREFETCH_OFFSET_STUDS
StaticWorldPresentationRules.TextureForwardPrefetchCreateRadiusStuds = TEXTURE_FORWARD_PREFETCH_CREATE_RADIUS_STUDS
StaticWorldPresentationRules.TextureForwardPrefetchRetainRadiusStuds = TEXTURE_FORWARD_PREFETCH_RETAIN_RADIUS_STUDS
StaticWorldPresentationRules.TextureUrgentNearRadiusStuds = TEXTURE_URGENT_NEAR_RADIUS_STUDS
StaticWorldPresentationRules.MaximumTextureMutationsPerFrame = MAXIMUM_TEXTURE_MUTATIONS_PER_FRAME
StaticWorldPresentationRules.LargeMapChunkThreshold = StaticWorldPartPolicy.LargeMapChunkThreshold
StaticWorldPresentationRules.LargeMapMinimumShadowFaceArea = StaticWorldPartPolicy.LargeMapMinimumShadowFaceArea
StaticWorldPresentationRules.ManagedTextureAttribute = MANAGED_TEXTURE_ATTRIBUTE
StaticWorldPresentationRules.ManagedTextureFaceAttribute = MANAGED_TEXTURE_FACE_ATTRIBUTE
StaticWorldPresentationRules.TextureStudsPerTile = TEXTURE_STUDS_PER_TILE
StaticWorldPresentationRules.TextureFaceNormals = TEXTURE_FACE_NORMALS

return table.freeze(StaticWorldPresentationRules)
