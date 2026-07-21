--[[
SPDX-License-Identifier: GPL-2.0-or-later

Device movement composition translated from:
  code/client/cl_input.c (CL_KeyMove, CL_JoystickMove, ClampChar)

Roblox PlayerModule supplies normalized controller/touch axes. They are added
to the fractional keyboard axes before the existing usercmd quantizer converts
the final normalized values into Q3's signed-char domain.
Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type MovementAxes = {
	read forward: number,
	read right: number,
}

local DeviceCommandComposition = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clampAxis(keyboardValue: unknown, deviceValue: unknown): number?
	if not isFinite(keyboardValue) or not isFinite(deviceValue) then
		return nil
	end
	return math.clamp((keyboardValue :: number) + (deviceValue :: number), -1, 1)
end

function DeviceCommandComposition.ComposeMovement(
	keyboardForward: unknown,
	keyboardRight: unknown,
	deviceForward: unknown,
	deviceRight: unknown
): MovementAxes?
	local forward = clampAxis(keyboardForward, deviceForward)
	local right = clampAxis(keyboardRight, deviceRight)
	if forward == nil or right == nil then
		return nil
	end
	return table.freeze({
		forward = forward,
		right = right,
	})
end

function DeviceCommandComposition.ComposeUp(jumpHeld: unknown, crouchHeld: unknown): number?
	if type(jumpHeld) ~= "boolean" or type(crouchHeld) ~= "boolean" then
		return nil
	end
	return (if jumpHeld then 1 else 0) - (if crouchHeld then 1 else 0)
end

return table.freeze(DeviceCommandComposition)
