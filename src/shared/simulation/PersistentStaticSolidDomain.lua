--!strict

-- Roblox instance streaming is allowed to make the ordinary Workspace tree
-- spatially incomplete on clients. Production collision queries therefore
-- consume only a schema-verified ModelStreamingMode.Persistent model. The
-- opaque receipt below is local to this module instance and is invalidated if
-- any validated geometry or identity metadata changes after publication.

local Workspace = game:GetService("Workspace")

local MapNativeStyles = require(script.Parent.Parent.maps.MapNativeStyles)
local StaticWorldPartPolicy = require(script.Parent.StaticWorldPartPolicy)

local PersistentStaticSolidDomain = {}

export type Domain = {}

type DomainRecord = {
	model: Model,
	world: Folder,
	current: boolean,
	connections: { RBXScriptConnection },
}

local MODEL_NAME = "ArenaPersistentStaticSolidDomain"
local CFRAME_EPSILON = 1e-5

local Attributes = table.freeze({
	Marker = "ArenaPersistentStaticSolidDomain",
	MapId = "ArenaStaticMapId",
	MapRevision = "ArenaStaticMapRevision",
	SchemaVersion = "ArenaStaticMapSchemaVersion",
	ChunkCount = "ArenaStaticChunkCount",
})

local PartAttributes = table.freeze({
	EntityId = "ArenaMapEntityId",
	SurfaceKind = "ArenaSurfaceKind",
	SurfaceSlick = "ArenaSurfaceSlick",
	SurfaceNoDamage = "ArenaSurfaceNoDamage",
	SurfaceNoImpact = "ArenaSurfaceNoImpact",
})

local MODEL_ATTRIBUTE_SET: { [string]: boolean } = {}
for _, attributeName in Attributes do
	MODEL_ATTRIBUTE_SET[attributeName] = true
end
table.freeze(MODEL_ATTRIBUTE_SET)

local PART_ATTRIBUTE_SET: { [string]: boolean } = {}
for _, attributeName in PartAttributes do
	PART_ATTRIBUTE_SET[attributeName] = true
end
table.freeze(PART_ATTRIBUTE_SET)

local legacyChunkNames = table.freeze({
	floor = "Floor",
	north_wall = "NorthWall",
	south_wall = "SouthWall",
	west_wall = "WestWall",
	east_wall = "EastWall",
	central_dais = "CentralDais",
	upper_bridge = "UpperBridge",
	bridge_support_left = "BridgeSupportLeft",
	bridge_support_right = "BridgeSupportRight",
	movement_step_01 = "MovementStep01",
	movement_step_02 = "MovementStep02",
	movement_step_03 = "MovementStep03",
	movement_step_04 = "MovementStep04",
	movement_step_05 = "MovementStep05",
	movement_step_06 = "MovementStep06",
	strafe_ramp = "StrafeRamp",
	red_zone_trim = "RedZoneTrim",
	blue_zone_trim = "BlueZoneTrim",
})

local records: { [Domain]: DomainRecord } = setmetatable({}, { __mode = "k" }) :: any

local function freezeDiagnostics(diagnostics: { string }): { string }
	table.sort(diagnostics)
	table.freeze(diagnostics)
	return diagnostics
end

local function hasExactAttributes(instance: Instance, expected: { [string]: boolean }): boolean
	local attributes = instance:GetAttributes()
	local observedCount = 0
	local expectedCount = 0
	for attributeName in expected do
		expectedCount += 1
		if attributes[attributeName] == nil then
			return false
		end
	end
	for attributeName in attributes do
		observedCount += 1
		if expected[attributeName] ~= true then
			return false
		end
	end
	return observedCount == expectedCount
end

local function cframesNear(left: CFrame, right: CFrame): boolean
	local leftComponents = { left:GetComponents() }
	local rightComponents = { right:GetComponents() }
	for index, component in leftComponents do
		if math.abs(component - rightComponents[index]) > CFRAME_EPSILON then
			return false
		end
	end
	return true
end

local function chunkCFrame(chunk: any): CFrame
	local rotation = chunk.rotationDegrees
	return CFrame.new(chunk.position) * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
end

function PersistentStaticSolidDomain.RuntimePartName(chunkId: string): string
	return legacyChunkNames[chunkId] or chunkId
end

local function appendPartDiagnostics(diagnostics: { string }, part: BasePart, chunk: any, staticChunkCount: number)
	local id = chunk.id :: string
	local prefix = "StaticSolidPart:" .. id .. ":"
	local expectedClass = if chunk.shape == "Wedge" then "WedgePart" else "Part"
	if part.ClassName ~= expectedClass then
		table.insert(diagnostics, prefix .. "ClassMismatch")
	end
	if part.Name ~= PersistentStaticSolidDomain.RuntimePartName(id) then
		table.insert(diagnostics, prefix .. "NameMismatch")
	end
	if not hasExactAttributes(part, PART_ATTRIBUTE_SET) then
		table.insert(diagnostics, prefix .. "AttributeShapeMismatch")
	end
	if part:GetAttribute(PartAttributes.EntityId) ~= id then
		table.insert(diagnostics, prefix .. "EntityIdMismatch")
	end
	if not cframesNear(part.CFrame, chunkCFrame(chunk)) then
		table.insert(diagnostics, prefix .. "CFrameMismatch")
	end
	if part.Size ~= chunk.size then
		table.insert(diagnostics, prefix .. "SizeMismatch")
	end
	if not part.Anchored then
		table.insert(diagnostics, prefix .. "NotAnchored")
	end
	if part.CanCollide ~= chunk.collision or part.CanQuery ~= chunk.collision or part.CanTouch then
		table.insert(diagnostics, prefix .. "CollisionMismatch")
	end
	if part.CollisionGroup ~= "Default" then
		table.insert(diagnostics, prefix .. "CollisionGroupMismatch")
	end
	if part.Transparency ~= (if chunk.visual then 0 else 1) then
		table.insert(diagnostics, prefix .. "TransparencyMismatch")
	end
	if part.CastShadow ~= StaticWorldPartPolicy.ShouldCastShadow(chunk, staticChunkCount) then
		table.insert(diagnostics, prefix .. "CastShadowMismatch")
	end
	if part.TopSurface ~= Enum.SurfaceType.Smooth or part.BottomSurface ~= Enum.SurfaceType.Smooth then
		table.insert(diagnostics, prefix .. "SurfaceTypeMismatch")
	end
	if part:IsA("Part") and part.Shape ~= Enum.PartType.Block then
		table.insert(diagnostics, prefix .. "PartShapeMismatch")
	end

	local style = MapNativeStyles.Get(chunk.styleId)
	if not style or part.Material ~= style.material or part.Color ~= style.color then
		table.insert(diagnostics, prefix .. "StyleMismatch")
	end
	local surface = chunk.surface
	if part:GetAttribute(PartAttributes.SurfaceKind) ~= surface.kind then
		table.insert(diagnostics, prefix .. "SurfaceKindMismatch")
	end
	if part:GetAttribute(PartAttributes.SurfaceSlick) ~= (surface.kind == "Slick") then
		table.insert(diagnostics, prefix .. "SurfaceSlickMismatch")
	end
	if part:GetAttribute(PartAttributes.SurfaceNoDamage) ~= surface.noDamage then
		table.insert(diagnostics, prefix .. "SurfaceNoDamageMismatch")
	end
	if part:GetAttribute(PartAttributes.SurfaceNoImpact) ~= surface.noImpact then
		table.insert(diagnostics, prefix .. "SurfaceNoImpactMismatch")
	end
end

-- Structural verification is available before publication so the builder can
-- prove it will never expose a partially constructed or schema-drifted model.
-- It intentionally does not issue a production query receipt.
function PersistentStaticSolidDomain.Verify(modelValue: unknown, trustedMapValue: unknown): (boolean, { string })
	local diagnostics: { string } = {}
	if typeof(modelValue) ~= "Instance" or not (modelValue :: Instance):IsA("Model") then
		table.insert(diagnostics, "StaticSolidDomain:NotModel")
		return false, freezeDiagnostics(diagnostics)
	end
	local model = modelValue :: Model
	if type(trustedMapValue) ~= "table" then
		table.insert(diagnostics, "StaticSolidDomain:TrustedMapMissing")
		return false, freezeDiagnostics(diagnostics)
	end
	local trustedMap = trustedMapValue :: any
	if
		type(trustedMap.MapId) ~= "string"
		or type(trustedMap.Revision) ~= "number"
		or type(trustedMap.Definition) ~= "table"
		or type(trustedMap.Definition.schemaVersion) ~= "number"
		or type(trustedMap.Definition.staticChunks) ~= "table"
	then
		table.insert(diagnostics, "StaticSolidDomain:TrustedMapMalformed")
		return false, freezeDiagnostics(diagnostics)
	end
	local definition = trustedMap.Definition
	local chunks = definition.staticChunks

	if model.Name ~= MODEL_NAME then
		table.insert(diagnostics, "StaticSolidDomain:NameMismatch")
	end
	if model.ModelStreamingMode ~= Enum.ModelStreamingMode.Persistent then
		table.insert(diagnostics, "StaticSolidDomain:NotPersistent")
	end
	if not hasExactAttributes(model, MODEL_ATTRIBUTE_SET) then
		table.insert(diagnostics, "StaticSolidDomain:AttributeShapeMismatch")
	end
	if model:GetAttribute(Attributes.Marker) ~= true then
		table.insert(diagnostics, "StaticSolidDomain:MarkerMismatch")
	end
	if model:GetAttribute(Attributes.MapId) ~= trustedMap.MapId then
		table.insert(diagnostics, "StaticSolidDomain:MapIdMismatch")
	end
	if model:GetAttribute(Attributes.MapRevision) ~= trustedMap.Revision then
		table.insert(diagnostics, "StaticSolidDomain:MapRevisionMismatch")
	end
	if model:GetAttribute(Attributes.SchemaVersion) ~= definition.schemaVersion then
		table.insert(diagnostics, "StaticSolidDomain:SchemaVersionMismatch")
	end
	if model:GetAttribute(Attributes.ChunkCount) ~= #chunks then
		table.insert(diagnostics, "StaticSolidDomain:DeclaredChunkCountMismatch")
	end

	local world = model.Parent
	if not world or not world:IsA("Folder") then
		table.insert(diagnostics, "StaticSolidDomain:WorldParentMismatch")
	else
		if world:GetAttribute("ArenaMapId") ~= trustedMap.MapId then
			table.insert(diagnostics, "StaticSolidDomain:WorldMapIdMismatch")
		end
		if world:GetAttribute("ArenaMapRevision") ~= trustedMap.Revision then
			table.insert(diagnostics, "StaticSolidDomain:WorldMapRevisionMismatch")
		end
		if world:GetAttribute("ArenaMapSchemaVersion") ~= definition.schemaVersion then
			table.insert(diagnostics, "StaticSolidDomain:WorldSchemaVersionMismatch")
		end
	end

	local children = model:GetChildren()
	local descendants = model:GetDescendants()
	if #children ~= #chunks then
		table.insert(diagnostics, "StaticSolidDomain:ChildCountMismatch")
	end
	-- Managed Texture instances are camera-near, nonspatial presentation
	-- attached directly to an already verified authoritative part. Every extra
	-- spatial or unknown descendant still fails.
	local descendantPartCount = 0
	for _, descendant in descendants do
		if descendant:IsA("BasePart") then
			descendantPartCount += 1
		elseif
			not StaticWorldPartPolicy.IsManagedTexture(descendant)
			or not descendant.Parent
			or not descendant.Parent:IsA("BasePart")
			or descendant.Parent.Parent ~= model
		then
			table.insert(diagnostics, "StaticSolidDomain:UnexpectedNonSpatialDescendant:" .. descendant:GetFullName())
		end
	end
	if descendantPartCount ~= #chunks then
		table.insert(diagnostics, "StaticSolidDomain:DescendantCountMismatch")
	end

	local expectedById: { [string]: any } = {}
	for _, chunk in chunks do
		expectedById[chunk.id] = chunk
	end
	local observedIds: { [string]: boolean } = {}
	for _, child in children do
		if not child:IsA("BasePart") then
			table.insert(diagnostics, "StaticSolidDomain:NonPartChild:" .. child.Name)
			continue
		end
		local entityId = child:GetAttribute(PartAttributes.EntityId)
		if type(entityId) ~= "string" then
			table.insert(diagnostics, "StaticSolidDomain:PartMissingEntityId:" .. child.Name)
			continue
		end
		if observedIds[entityId] then
			table.insert(diagnostics, "StaticSolidDomain:DuplicateEntityId:" .. entityId)
			continue
		end
		observedIds[entityId] = true
		local chunk = expectedById[entityId]
		if not chunk then
			table.insert(diagnostics, "StaticSolidDomain:ExtraEntityId:" .. entityId)
			continue
		end
		appendPartDiagnostics(diagnostics, child, chunk, #chunks)
	end
	for entityId in expectedById do
		if not observedIds[entityId] then
			table.insert(diagnostics, "StaticSolidDomain:MissingEntityId:" .. entityId)
		end
	end

	return #diagnostics == 0, freezeDiagnostics(diagnostics)
end

local function connectInvalidation(record: DomainRecord, signal: RBXScriptSignal)
	table.insert(
		record.connections,
		signal:Connect(function()
			record.current = false
		end)
	)
end

local function isManagedTextureDescendant(model: Model, descendant: Instance): boolean
	local parent = descendant.Parent
	return StaticWorldPartPolicy.IsManagedTexture(descendant)
		and parent ~= nil
		and parent:IsA("BasePart")
		and parent.Parent == model
end

local function connectDescendantAdditionInvalidation(record: DomainRecord, signal: RBXScriptSignal)
	table.insert(
		record.connections,
		signal:Connect(function(descendant: Instance)
			if not isManagedTextureDescendant(record.model, descendant) then
				record.current = false
			end
		end)
	)
end

local function connectDescendantRemovalInvalidation(record: DomainRecord, signal: RBXScriptSignal)
	table.insert(
		record.connections,
		signal:Connect(function(descendant: Instance)
			-- Workspace.SignalBehavior is Deferred. By the time a
			-- DescendantRemoving callback resumes, Roblox may already have
			-- cleared descendant.Parent. A strictly shaped managed Texture is
			-- nonspatial presentation, so its removal is safe regardless of
			-- that stale ancestry; every BasePart or unknown removal still
			-- revokes the exact collision receipt.
			if not StaticWorldPartPolicy.IsManagedTexture(descendant) then
				record.current = false
			end
		end)
	)
end

-- A production receipt is issued only after the complete Persistent model is
-- present under Workspace. WaitForChild on this model root is sufficient on a
-- client because Roblox sends a Persistent model's initial descendants as one
-- complete atomic unit.
function PersistentStaticSolidDomain.ValidatePublished(
	modelValue: unknown,
	trustedMapValue: unknown
): (Domain?, { string })
	local verified, diagnostics = PersistentStaticSolidDomain.Verify(modelValue, trustedMapValue)
	if not verified then
		return nil, diagnostics
	end
	local model = modelValue :: Model
	local world = model.Parent :: Folder
	if not world:IsDescendantOf(Workspace) then
		return nil, freezeDiagnostics({ "StaticSolidDomain:NotPublished" })
	end

	local token: Domain = table.freeze({})
	local record: DomainRecord = {
		model = model,
		world = world,
		current = true,
		connections = {},
	}
	records[token] = record

	connectInvalidation(record, model.Changed)
	connectInvalidation(record, model.AttributeChanged)
	connectDescendantAdditionInvalidation(record, model.DescendantAdded)
	connectDescendantRemovalInvalidation(record, model.DescendantRemoving)
	connectInvalidation(record, model.AncestryChanged)
	for _, child in model:GetChildren() do
		connectInvalidation(record, child.Changed)
		connectInvalidation(record, child.AttributeChanged)
	end
	connectInvalidation(record, world:GetAttributeChangedSignal("ArenaMapId"))
	connectInvalidation(record, world:GetAttributeChangedSignal("ArenaMapRevision"))
	connectInvalidation(record, world:GetAttributeChangedSignal("ArenaMapSchemaVersion"))
	connectInvalidation(record, world.AncestryChanged)

	return token, diagnostics
end

function PersistentStaticSolidDomain.Resolve(value: unknown): Model?
	if type(value) ~= "table" then
		return nil
	end
	local record = records[value :: Domain]
	if
		not record
		or not record.current
		or record.model.Parent ~= record.world
		or not record.world:IsDescendantOf(Workspace)
	then
		return nil
	end
	return record.model
end

function PersistentStaticSolidDomain.IsCurrent(value: unknown): boolean
	return PersistentStaticSolidDomain.Resolve(value) ~= nil
end

function PersistentStaticSolidDomain.RequireCurrent(value: unknown): Model
	return assert(
		PersistentStaticSolidDomain.Resolve(value),
		"persistent static-solid domain is absent, forged, or invalidated"
	)
end

PersistentStaticSolidDomain.ModelName = MODEL_NAME
PersistentStaticSolidDomain.Attributes = Attributes
PersistentStaticSolidDomain.PartAttributes = PartAttributes

return table.freeze(PersistentStaticSolidDomain)
