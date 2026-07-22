--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MoverPushRules = require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverPushRules"))

local MovementMoverPresentationRuntime = {}

export type Operation =
	{
		kind: "BasePart",
		instance: BasePart,
		target: CFrame,
	}
	| {
		kind: "Model",
		instance: Model,
		target: CFrame,
	}

local function cframeIsFinite(value: CFrame): boolean
	for _, component in { value:GetComponents() } do
		if component ~= component or math.abs(component) == math.huge then
			return false
		end
	end
	return true
end

local function validatePart(part: BasePart)
	assert(
		part.Anchored and not part.CanCollide and not part.CanQuery and not part.CanTouch,
		"mover presentation parts cannot enter gameplay collision"
	)
end

function MovementMoverPresentationRuntime.Plan(
	folder: Folder?,
	poses: { MoverPushRules.Pose }
): { Operation }
	local operations: { Operation } = {}
	if not folder then
		table.freeze(operations)
		return operations
	end
	assert(
		folder:GetAttribute("Q3EngineMoverPresentationOnly") == true,
		"mover presentation folder lost its presentation-only boundary"
	)
	local posesById: { [string]: MoverPushRules.Pose } = {}
	for _, pose in poses do
		posesById[pose.id] = pose
	end
	for _, child in folder:GetChildren() do
		local moverId = child:GetAttribute("Q3EngineMoverId")
		assert(
			type(moverId) == "string" and posesById[moverId] ~= nil,
			"mover presentation has no authoritative definition"
		)
		local offsetValue = child:GetAttribute("Q3EngineMoverPresentationOffset")
		assert(
			offsetValue == nil or (typeof(offsetValue) == "CFrame" and cframeIsFinite(offsetValue)),
			"mover presentation offset must be a CFrame"
		)
		local offset = if typeof(offsetValue) == "CFrame" then offsetValue else CFrame.identity
		local pose = posesById[moverId]
		local target = CFrame.new(pose.position)
			* CFrame.Angles(
				math.rad(pose.angles.X),
				math.rad(pose.angles.Y),
				math.rad(pose.angles.Z)
			)
			* offset
		assert(cframeIsFinite(target), "mover presentation target must be finite")
		if child:IsA("BasePart") then
			validatePart(child)
			for _, descendant in child:GetDescendants() do
				if descendant:IsA("BasePart") then
					validatePart(descendant)
				end
			end
			local operation: Operation = { kind = "BasePart", instance = child, target = target }
			table.freeze(operation)
			table.insert(operations, operation)
		elseif child:IsA("Model") then
			for _, descendant in child:GetDescendants() do
				if descendant:IsA("BasePart") then
					validatePart(descendant)
				end
			end
			local operation: Operation = { kind = "Model", instance = child, target = target }
			table.freeze(operation)
			table.insert(operations, operation)
		else
			error("mover presentation children must be BaseParts or Models")
		end
	end
	table.freeze(operations)
	return operations
end

function MovementMoverPresentationRuntime.Apply(operation: Operation)
	if operation.kind == "BasePart" then
		operation.instance.CFrame = operation.target
	else
		operation.instance:PivotTo(operation.target)
	end
end

function MovementMoverPresentationRuntime.Render(folder: Folder?, poses: { MoverPushRules.Pose })
	for _, operation in MovementMoverPresentationRuntime.Plan(folder, poses) do
		MovementMoverPresentationRuntime.Apply(operation)
	end
end

return table.freeze(MovementMoverPresentationRuntime)
