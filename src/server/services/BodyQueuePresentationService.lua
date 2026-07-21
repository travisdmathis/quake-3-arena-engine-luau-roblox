--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-owned replicated presentation for Q3 CopyToBodyQue slots. This owner
clones only the already-loaded Roblox avatar, strips executable/interactive
descendants, freezes the death pose, and follows BodyQueue authority. It does
not own collision, damage, timing, slot reuse, or respawn acceptance.

Replicated creation, motion, reuse, and unlink are buffered behind the exact
authoritative-frame close barrier. No content assets are created or uploaded.

Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local BodyQueueFramePublicationService = require(script.Parent.BodyQueueFramePublicationService)
local BodyQueueService = require(script.Parent.BodyQueueService)

local BodyQueuePresentationService = {}

type Record = {
	queueIndex: number,
	occupantGeneration: number,
	model: Model,
	pivotOffset: CFrame,
	published: boolean,
}

local started = false
local folder: Folder? = nil
local records: { [number]: Record } = {}
local ownedModels: { [Model]: boolean } = {}

local function destroyOwned(model: Model)
	if not ownedModels[model] then
		return
	end
	ownedModels[model] = nil
	pcall(function()
		model:Destroy()
	end)
end

local function restoreVisual(instance: Instance)
	if instance:IsA("BasePart") then
		local original = instance:GetAttribute("ArenaOriginalTransparency")
		if type(original) == "number" then
			instance.Transparency = original
		end
		instance.Anchored = true
		instance.Massless = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
		instance.LocalTransparencyModifier = 0
	elseif instance:IsA("Decal") then
		local original = instance:GetAttribute("ArenaOriginalTransparency")
		if type(original) == "number" then
			instance.Transparency = original
		end
	elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") then
		local original = instance:GetAttribute("ArenaOriginalEnabled")
		instance.Enabled = type(original) == "boolean" and original or instance.Enabled
	end
end

local function sanitizeClone(model: Model)
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Tool")
			or descendant:IsA("Humanoid")
			or descendant:IsA("AnimationController")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("Sound")
		then
			descendant:Destroy()
		else
			restoreVisual(descendant)
		end
	end
	model.Archivable = false
	model:SetAttribute("ArenaBodyQueuePresentation", true)
end

local function cloneCharacter(character: Model): (Model?, string?)
	local wasArchivable = character.Archivable
	if not wasArchivable then
		character.Archivable = true
	end
	local succeeded, cloned = pcall(function()
		return character:Clone()
	end)
	if not wasArchivable then
		character.Archivable = false
	end
	if not succeeded or not cloned or not cloned:IsA("Model") then
		return nil, "body-queue-character-clone-failed"
	end
	sanitizeClone(cloned)
	return cloned, nil
end

local function targetPivot(record: Record, position: Vector3): CFrame
	return CFrame.new(position) * record.pivotOffset
end

function BodyQueuePresentationService.Start(parent: Instance): (boolean, string?)
	if started then
		return false, "body-queue-presentation-already-started"
	end
	if parent.Parent == nil then
		return false, "body-queue-presentation-parent-unavailable"
	end
	local presentationFolder = Instance.new("Folder")
	presentationFolder.Name = "BodyQueuePresentation"
	presentationFolder.Archivable = false
	presentationFolder:SetAttribute("ArenaBodyQueuePresentation", true)
	presentationFolder.Parent = parent
	folder = presentationFolder
	started = true
	return true, nil
end

function BodyQueuePresentationService.BeginAuthoritativeFrame(frame: unknown)
	assert(started, "BodyQueue presentation must start before its frame phase")
	BodyQueueFramePublicationService.Begin(frame)
end

function BodyQueuePresentationService.StageCopy(
	player: Player,
	sink: BodyQueueService.SinkDiagnostic
): (boolean, string?)
	assert(started and BodyQueueFramePublicationService.IsOpen(), "BodyQueue copy is outside a frame")
	if not sink.linked then
		return false, "body-queue-copy-sink-is-unlinked"
	end
	if not sink.visible then
		local previous = records[sink.queueIndex]
		records[sink.queueIndex] = nil
		BodyQueueFramePublicationService.Queue(function()
			if previous then
				destroyOwned(previous.model)
			end
		end)
		return true, nil
	end
	local character = player.Character
	if not character or character.Parent == nil then
		return false, "body-queue-copy-character-unavailable"
	end
	local model, cloneError = cloneCharacter(character)
	if not model then
		return false, cloneError
	end
	local queueIndex = sink.queueIndex
	local previous = records[queueIndex]
	local record: Record = {
		queueIndex = queueIndex,
		occupantGeneration = sink.occupantGeneration,
		model = model,
		pivotOffset = CFrame.new(sink.collisionPosition):ToObjectSpace(character:GetPivot()),
		published = false,
	}
	model.Name = string.format("BodyQueue_%d_G%d", queueIndex, sink.occupantGeneration)
	model:SetAttribute("ArenaBodyQueueIndex", queueIndex)
	model:SetAttribute("ArenaBodyQueueOccupantGeneration", sink.occupantGeneration)
	model:SetAttribute("ArenaBodyQueueSourceUserId", player.UserId)
	model:PivotTo(targetPivot(record, sink.collisionPosition))
	ownedModels[model] = true
	records[queueIndex] = record
	BodyQueueFramePublicationService.Queue(function()
		if records[queueIndex] ~= record then
			destroyOwned(model)
			return
		end
		if previous then
			destroyOwned(previous.model)
		end
		model.Parent = assert(folder, "BodyQueue presentation folder disappeared")
		record.published = true
	end)
	return true, nil
end

function BodyQueuePresentationService.StageSink(sink: BodyQueueService.SinkDiagnostic): boolean
	assert(started and BodyQueueFramePublicationService.IsOpen(), "BodyQueue sink is outside a frame")
	local record = records[sink.queueIndex]
	if not record or record.occupantGeneration ~= sink.occupantGeneration then
		return false
	end
	BodyQueueFramePublicationService.Queue(function()
		if records[sink.queueIndex] ~= record then
			return
		end
		if not sink.linked or not sink.visible then
			records[sink.queueIndex] = nil
			destroyOwned(record.model)
			return
		end
		record.model:PivotTo(targetPivot(record, sink.collisionPosition))
	end)
	return true
end

local adapter: BodyQueueService.PresentationAdapter = table.freeze({
	StageSink = BodyQueuePresentationService.StageSink,
})

function BodyQueuePresentationService.GetAdapter(): BodyQueueService.PresentationAdapter
	return adapter
end

function BodyQueuePresentationService.EndAuthoritativeFrame(frame: unknown): () -> ()
	return BodyQueueFramePublicationService.Seal(frame)
end

function BodyQueuePresentationService.HandleSimulationFault()
	BodyQueueFramePublicationService.Quarantine()
	for model in ownedModels do
		destroyOwned(model)
	end
	records = {}
end

return table.freeze(BodyQueuePresentationService)
