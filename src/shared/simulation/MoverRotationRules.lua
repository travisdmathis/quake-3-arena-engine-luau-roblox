--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure angular mover primitives translated from Quake III Arena:
  code/game/g_mover.c (G_CreateRotationMatrix, G_TransposeMatrix,
  G_RotatePoint, G_TryPushingEntity, G_MoverPush, G_MoverTeam)
  code/game/bg_misc.c (BG_EvaluateTrajectory)
  code/game/q_shared.h (ANGLE2SHORT)

Q3's Z-up pitch/yaw/roll tuple is represented in the existing the Roblox Luau port
Y-up adapter as X/Y/Z rotation degrees. The immutable validation boundary and
data-only broadphase record are original the Roblox Luau port adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local CommandQuantization = require(script.Parent.CommandQuantization)
local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type AngularTrajectory = MoverTrajectory.Trajectory
export type Broadphase = {
	radius: number,
	destinationMinimum: Vector3,
	destinationMaximum: Vector3,
	totalMinimum: Vector3,
	totalMaximum: Vector3,
}

local MoverRotationRules = {}

local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_SIZE = 10_000
local MAXIMUM_ANGLE_COMPONENT = 1_000_000

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
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

local function componentMinimum(left: Vector3, right: Vector3): Vector3
	return Vector3.new(math.min(left.X, right.X), math.min(left.Y, right.Y), math.min(left.Z, right.Z))
end

local function componentMaximum(left: Vector3, right: Vector3): Vector3
	return Vector3.new(math.max(left.X, right.X), math.max(left.Y, right.Y), math.max(left.Z, right.Z))
end

function MoverRotationRules.ValidateAngularTrajectory(value: unknown): (AngularTrajectory?, string?)
	local trajectory, trajectoryError = MoverTrajectory.Validate(value)
	if not trajectory then
		return nil, trajectoryError
	end
	if trajectory.kind == MoverTrajectory.Kinds.Gravity then
		return nil, "unsupported-angular-gravity"
	end
	return trajectory, nil
end

function MoverRotationRules.EvaluateDegrees(trajectory: AngularTrajectory, atTimeMilliseconds: number): Vector3
	return MoverTrajectory.Evaluate(trajectory, atTimeMilliseconds)
end

function MoverRotationRules.EvaluateMoveDegrees(
	trajectory: AngularTrajectory,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number
): Vector3
	return MoverTrajectory.Evaluate(trajectory, toTimeMilliseconds)
		- MoverTrajectory.Evaluate(trajectory, fromTimeMilliseconds)
end

function MoverRotationRules.RotateOffset(offsetValue: unknown, angularMoveValue: unknown): Vector3?
	if
		not isBoundedVector(offsetValue, MAXIMUM_COORDINATE * 2)
		or not isBoundedVector(angularMoveValue, MAXIMUM_ANGLE_COMPONENT)
	then
		return nil
	end
	local offset = offsetValue :: Vector3
	local angularMove = angularMoveValue :: Vector3
	local rotation = CFrame.Angles(math.rad(angularMove.X), math.rad(angularMove.Y), math.rad(angularMove.Z))
	return rotation:VectorToWorldSpace(offset)
end

function MoverRotationRules.PushDisplacement(
	bodyPositionValue: unknown,
	finalMoverOriginValue: unknown,
	linearMoveValue: unknown,
	angularMoveValue: unknown
): Vector3?
	if
		not isBoundedVector(bodyPositionValue, MAXIMUM_COORDINATE)
		or not isBoundedVector(finalMoverOriginValue, MAXIMUM_COORDINATE)
		or not isBoundedVector(linearMoveValue, MAXIMUM_COORDINATE * 2)
	then
		return nil
	end
	local offset = (bodyPositionValue :: Vector3) - (finalMoverOriginValue :: Vector3)
	local rotatedOffset = MoverRotationRules.RotateOffset(offset, angularMoveValue)
	if not rotatedOffset then
		return nil
	end
	return (linearMoveValue :: Vector3) + rotatedOffset - offset
end

function MoverRotationRules.YawDeltaShort(angularMoveValue: unknown): number?
	if not isBoundedVector(angularMoveValue, MAXIMUM_ANGLE_COMPONENT) then
		return nil
	end
	return CommandQuantization.Angle2Short((angularMoveValue :: Vector3).Y)
end

function MoverRotationRules.RadiusBroadphase(
	currentOriginValue: unknown,
	linearMoveValue: unknown,
	sizeValue: unknown
): Broadphase?
	if
		not isBoundedVector(currentOriginValue, MAXIMUM_COORDINATE)
		or not isBoundedVector(linearMoveValue, MAXIMUM_COORDINATE * 2)
		or not isBoundedVector(sizeValue, MAXIMUM_SIZE)
	then
		return nil
	end
	local size = sizeValue :: Vector3
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return nil
	end
	local currentOrigin = currentOriginValue :: Vector3
	local finalOrigin = currentOrigin + (linearMoveValue :: Vector3)
	local radius = (size * 0.5).Magnitude
	local radiusVector = Vector3.one * radius
	local currentMinimum = currentOrigin - radiusVector
	local currentMaximum = currentOrigin + radiusVector
	local destinationMinimum = finalOrigin - radiusVector
	local destinationMaximum = finalOrigin + radiusVector
	local result: Broadphase = {
		radius = radius,
		destinationMinimum = destinationMinimum,
		destinationMaximum = destinationMaximum,
		totalMinimum = componentMinimum(currentMinimum, destinationMinimum),
		totalMaximum = componentMaximum(currentMaximum, destinationMaximum),
	}
	table.freeze(result)
	return result
end

return table.freeze(MoverRotationRules)
