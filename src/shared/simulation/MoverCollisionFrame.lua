--[[
SPDX-License-Identifier: GPL-2.0-or-later

Immutable snapshot-time collision frames for the oriented Block-mover
foundation, derived from Quake III Arena:
  code/server/sv_world.c (world-first trace composition and strict fraction ties)
  code/cgame/cg_predict.c (snapshot physicsTime mover collision)
  code/cgame/cg_ents.c (CG_AdjustPositionForMover)
  code/game/bg_pmove.c (ground-entity trace consumption)

This module deliberately returns mover-only results. A future consumer must
trace static world geometry first, retain it on equal fractions, then merge
these source-ordered dynamic results. Presentation parts are not collision
inputs. Block and the measured Roblox Wedge triangular prism share one numeric
result domain; unsupported shapes remain rejected by MoverPushRules.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.MoverClock)
local MoverPushRules = require(script.Parent.MoverPushRules)
local MoverPointTraceRules = require(script.Parent.MoverPointTraceRules)
local MoverTrajectory = require(script.Parent.MoverTrajectory)
local SweptAABBOrientedBlock = require(script.Parent.SweptAABBOrientedBlock)
local SweptAABBOrientedWedge = require(script.Parent.SweptAABBOrientedWedge)

export type TraceResult = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	moverId: string?,
	sourceOrder: number?,
	contents: number,
	surfaceSlick: boolean,
	surfaceNoDamage: boolean,
}

export type Frame = {
	clock: MoverClock.Snapshot,
	timeMilliseconds: number,
	definitions: { MoverPushRules.Definition },
	poses: { MoverPushRules.Pose },
	blocks: { SweptAABBOrientedBlock.OrderedBlock },
	wedges: { SweptAABBOrientedWedge.OrderedWedge },
	pointShapes: { MoverPointTraceRules.Shape },
	definitionsById: { [string]: MoverPushRules.Definition },
	_token: unknown,
}

local MoverCollisionFrame = {}

local FRAME_TOKEN = table.freeze({})
local EMPTY_CONTENTS = 0

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedPosition(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local position = value :: Vector3
	return isFiniteNumber(position.X)
		and isFiniteNumber(position.Y)
		and isFiniteNumber(position.Z)
		and math.abs(position.X) <= SweptAABBOrientedBlock.MaximumCoordinate
		and math.abs(position.Y) <= SweptAABBOrientedBlock.MaximumCoordinate
		and math.abs(position.Z) <= SweptAABBOrientedBlock.MaximumCoordinate
end

local function validatedFrame(value: unknown): (Frame?, string?)
	if type(value) ~= "table" then
		return nil, "frame-not-table"
	end
	local frame = value :: Frame
	if frame._token ~= FRAME_TOKEN or not table.isfrozen(frame) then
		return nil, "invalid-frame"
	end
	return frame, nil
end

local function frozenTraceResult(result: any, startSolidOverride: boolean?): TraceResult
	local contact = result.contact
	local converted: TraceResult = {
		hit = result.hit,
		fraction = result.fraction,
		normal = result.normal,
		startSolid = if startSolidOverride == nil then result.startSolid else startSolidOverride,
		allSolid = result.allSolid,
		moverId = if contact then contact.id else nil,
		sourceOrder = if contact then contact.sourceOrder else nil,
		contents = if contact then contact.contents else EMPTY_CONTENTS,
		surfaceSlick = false,
		surfaceNoDamage = false,
	}
	table.freeze(converted)
	return converted
end

function MoverCollisionFrame.Build(definitionsValue: unknown, clockValue: unknown): (Frame?, string?)
	local clock, clockError = MoverClock.ValidateSnapshot(clockValue)
	if not clock then
		return nil, "invalid-clock:" .. (clockError or "invalid")
	end
	local definitions, definitionError = MoverPushRules.ValidateAndOrderDefinitions(definitionsValue)
	if not definitions then
		return nil, "invalid-definitions:" .. (definitionError or "invalid")
	end
	local timeMilliseconds = MoverClock.TimeForStep(clock.step)
	if timeMilliseconds == nil then
		return nil, "invalid-clock-time"
	end
	local poses, poseError = MoverPushRules.EvaluatePoses(definitions, timeMilliseconds)
	if not poses then
		return nil, "invalid-poses:" .. (poseError or "invalid")
	end

	local rawBlocks: { SweptAABBOrientedBlock.OrderedBlock } = {}
	local rawWedges: { SweptAABBOrientedWedge.OrderedWedge } = {}
	local rawPointShapes: { MoverPointTraceRules.Shape } = {}
	for _, pose in poses do
		local shape = {
			id = pose.id,
			sourceOrder = pose.sourceOrder,
			cframe = CFrame.new(pose.position)
				* CFrame.Angles(math.rad(pose.angles.X), math.rad(pose.angles.Y), math.rad(pose.angles.Z)),
			size = pose.size,
			contents = MoverPushRules.Contents.Solid,
			active = true,
		}
		if pose.shape == "Block" then
			table.insert(rawBlocks, shape)
		else
			table.insert(rawWedges, shape)
		end
		table.insert(rawPointShapes, {
			id = pose.id,
			sourceOrder = pose.sourceOrder,
			shape = pose.shape,
			cframe = shape.cframe,
			size = pose.size,
			contents = MoverPushRules.Contents.Solid,
			active = true,
		})
	end
	local blocks, blocksError = SweptAABBOrientedBlock.ValidateAndOrderBlocks(rawBlocks)
	if not blocks then
		return nil, "invalid-blocks:" .. (blocksError or "invalid")
	end
	local wedges, wedgesError = SweptAABBOrientedWedge.ValidateAndOrderWedges(rawWedges)
	if not wedges then
		return nil, "invalid-wedges:" .. (wedgesError or "invalid")
	end
	local pointShapes, pointShapesError = MoverPointTraceRules.ValidateAndOrderShapes(rawPointShapes)
	if not pointShapes then
		return nil, "invalid-point-shapes:" .. (pointShapesError or "invalid")
	end

	local definitionsById: { [string]: MoverPushRules.Definition } = {}
	for _, definition in definitions do
		definitionsById[definition.id] = definition
	end
	table.freeze(definitionsById)

	local frame: Frame = {
		clock = clock,
		timeMilliseconds = timeMilliseconds,
		definitions = definitions,
		poses = poses,
		blocks = blocks,
		wedges = wedges,
		pointShapes = pointShapes,
		definitionsById = definitionsById,
		_token = FRAME_TOKEN,
	}
	table.freeze(frame)
	return frame, nil
end

function MoverCollisionFrame.TracePoint(
	frameValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	clipMaskValue: unknown
): (TraceResult?, string?)
	local frame, frameError = validatedFrame(frameValue)
	if not frame then
		return nil, frameError
	end
	local result, traceError =
		MoverPointTraceRules.Trace(frame.pointShapes, originValue, displacementValue, clipMaskValue)
	if not result then
		return nil, traceError
	end
	return frozenTraceResult(result), nil
end

function MoverCollisionFrame.Trace(
	frameValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (TraceResult?, string?)
	local frame, frameError = validatedFrame(frameValue)
	if not frame then
		return nil, frameError
	end
	local blockResult, blockError = SweptAABBOrientedBlock.TraceOrderedBlocks(
		originValue,
		displacementValue,
		movingSizeValue,
		movingCenterOffsetValue,
		frame.blocks,
		clipMaskValue
	)
	if not blockResult then
		return nil, blockError
	end
	local wedgeResult, wedgeError = SweptAABBOrientedWedge.TraceOrderedWedges(
		originValue,
		displacementValue,
		movingSizeValue,
		movingCenterOffsetValue,
		frame.wedges,
		clipMaskValue
	)
	if not wedgeResult then
		return nil, wedgeError
	end
	local function sourceOrder(result: any): number
		return if result.contact then result.contact.sourceOrder else math.huge
	end
	local selected = blockResult
	if wedgeResult.allSolid then
		if not blockResult.allSolid or sourceOrder(wedgeResult) < sourceOrder(blockResult) then
			selected = wedgeResult
		end
	elseif not blockResult.allSolid then
		if
			wedgeResult.hit
			and (
				not blockResult.hit
				or wedgeResult.fraction < blockResult.fraction
				or (
					wedgeResult.fraction == blockResult.fraction
					and sourceOrder(wedgeResult) < sourceOrder(blockResult)
				)
			)
		then
			selected = wedgeResult
		end
	end
	return frozenTraceResult(selected, blockResult.startSolid or wedgeResult.startSolid), nil
end

function MoverCollisionFrame.CanOccupy(
	frameValue: unknown,
	originValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (boolean?, string?)
	local result, traceError = MoverCollisionFrame.Trace(
		frameValue,
		originValue,
		Vector3.zero,
		movingSizeValue,
		movingCenterOffsetValue,
		clipMaskValue
	)
	if not result then
		return nil, traceError
	end
	return not result.allSolid, nil
end

function MoverCollisionFrame.PointContents(frameValue: unknown, pointValue: unknown): (number?, string?)
	local frame, frameError = validatedFrame(frameValue)
	if not frame then
		return nil, frameError
	end
	local blockContents, blockError = SweptAABBOrientedBlock.PointContentsOrderedBlocks(frame.blocks, pointValue)
	if blockContents == nil then
		return nil, blockError
	end
	local wedgeContents, wedgeError = SweptAABBOrientedWedge.PointContentsOrderedWedges(frame.wedges, pointValue)
	if wedgeContents == nil then
		return nil, wedgeError
	end
	return bit32.bor(blockContents, wedgeContents), nil
end

function MoverCollisionFrame.AdjustGroundPosition(
	frameValue: unknown,
	groundMoverIdValue: unknown,
	targetStepValue: unknown,
	positionValue: unknown
): (Vector3?, string?)
	local frame, frameError = validatedFrame(frameValue)
	if not frame then
		return nil, frameError
	end
	if not isBoundedPosition(positionValue) then
		return nil, "invalid-position"
	end
	local targetTimeMilliseconds = MoverClock.TimeForStep(targetStepValue)
	if targetTimeMilliseconds == nil then
		return nil, "invalid-target-step"
	end
	local targetStep = targetStepValue :: number
	if targetStep < frame.clock.step then
		return nil, "target-step-before-frame"
	end
	if groundMoverIdValue == nil then
		return positionValue :: Vector3, nil
	end
	if type(groundMoverIdValue) ~= "string" then
		return nil, "invalid-ground-mover-id"
	end
	local definition = frame.definitionsById[groundMoverIdValue]
	if not definition then
		return nil, "unknown-ground-mover-id"
	end

	local adjusted = MoverTrajectory.AdjustPositionForMover(
		positionValue :: Vector3,
		definition.trajectory,
		frame.timeMilliseconds,
		targetTimeMilliseconds
	)
	if not isBoundedPosition(adjusted) then
		return nil, "adjusted-position-out-of-bounds"
	end
	return adjusted, nil
end

MoverCollisionFrame.EmptyContents = EMPTY_CONTENTS

return table.freeze(MoverCollisionFrame)
