--[[
SPDX-License-Identifier: GPL-2.0-or-later

Shared usercmd quantization primitives translated from:
  code/game/q_shared.h (ANGLE2SHORT, SHORT2ANGLE, packed angles, signed axes,
    BUTTON_ATTACK, BUTTON_USE_HOLDABLE, BUTTON_WALKING)
  code/game/q_math.c (ClampChar, vectoangles, AngleVectors)
  code/game/bg_pmove.c (PM_UpdateViewAngles signed pitch clamp)
  code/client/cl_input.c (CL_KeyMove, CL_FinishMove)

ANGLE2SHORT preserves C's truncation-toward-zero followed by the 16-bit mask.
SHORT2ANGLE accepts the signed-short value that Q3 observes after storing or
reading that mask. Inputs whose C conversion would be undefined are rejected.

Roblox movement axes are normalized floats rather than Q3 key totals. The
adapter uses CL_KeyMove's exact run scale 127 or walk scale 64 with C
truncation. Decoding remains over the complete Q3 signed-char domain by /127;
consequently legacy -128 remains decodable as -128/127 but is never authored.

For look vectors, Q3 +X maps to Roblox -Z, Q3 +Y maps to Roblox -X, and Q3 +Z
maps to Roblox +Y. This keeps Q3 yaw 0 facing Roblox -Z, positive Q3 yaw turning
left, and positive Q3 pitch looking down.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local UserCommandButtonRules = require(script.Parent.UserCommandButtonRules)

export type EncodedAxes = {
	forward: number,
	right: number,
	upMove: number,
}

export type DecodedAxes = {
	forward: number,
	right: number,
	upMove: number,
}

export type LookShorts = {
	pitch: number,
	yaw: number,
}

export type LookBits = {
	pitch: number,
	yaw: number,
}

export type PackedAngles = {
	pitch: number,
	yaw: number,
	roll: number,
}

export type DeltaAngles = {
	pitch: number,
	yaw: number,
	roll: number,
}

export type ResolvedViewAngles = {
	pitch: number,
	yaw: number,
	roll: number,
	look: Vector3,
	deltaPitch: number,
	deltaYaw: number,
	deltaRoll: number,
}

local SIGNED_INT_MINIMUM = -2_147_483_648
local SIGNED_INT_MAXIMUM = 2_147_483_647
local SIGNED_CHAR_MINIMUM = -128
local SIGNED_CHAR_MAXIMUM = 127
local SIGNED_SHORT_MINIMUM = -32_768
local SIGNED_SHORT_MAXIMUM = 32_767
local VIEW_PITCH_MINIMUM_SHORT = -16_000
local VIEW_PITCH_MAXIMUM_SHORT = 16_000
local SHORT_MODULUS = 65_536
local SHORT_SIGN_BIT = 32_768
local BUTTON_BITS_MAXIMUM = 65_535
local WEAPON_BYTE_MAXIMUM = 255
local FULL_TURN_DEGREES = 360
local NORMALIZED_AXIS_SCALE = 127
local WALKING_AXIS_SCALE = 64
local DEGREES_PER_SHORT = FULL_TURN_DEGREES / SHORT_MODULUS

local AXIS_KEYS = table.freeze({
	forward = true,
	right = true,
	upMove = true,
})
local LOOK_SHORT_KEYS = table.freeze({
	pitch = true,
	yaw = true,
})
local PACKED_ANGLE_KEYS = table.freeze({
	pitch = true,
	yaw = true,
	roll = true,
})

local CommandQuantization = {
	SignedCharMinimum = SIGNED_CHAR_MINIMUM,
	SignedCharMaximum = SIGNED_CHAR_MAXIMUM,
	SignedShortMinimum = SIGNED_SHORT_MINIMUM,
	SignedShortMaximum = SIGNED_SHORT_MAXIMUM,
	ViewPitchMinimumShort = VIEW_PITCH_MINIMUM_SHORT,
	ViewPitchMaximumShort = VIEW_PITCH_MAXIMUM_SHORT,
	ShortModulus = SHORT_MODULUS,
	-- Retained as the q_shared.h network storage bound. ValidateButtonBits is
	-- deliberately narrower and admits only the translated supported mask.
	ButtonBitsMaximum = BUTTON_BITS_MAXIMUM,
	WeaponByteMaximum = WEAPON_BYTE_MAXIMUM,
	ButtonAttack = UserCommandButtonRules.ButtonAttack,
	ButtonUseHoldable = UserCommandButtonRules.ButtonUseHoldable,
	ButtonWalking = UserCommandButtonRules.ButtonWalking,
	ButtonRespawnReleaseMask = UserCommandButtonRules.RespawnReleaseMask,
	ButtonSupportedMask = UserCommandButtonRules.SupportedMask,
	NormalizedAxisScale = NORMALIZED_AXIS_SCALE,
	RunAxisScale = NORMALIZED_AXIS_SCALE,
	WalkingAxisScale = WALKING_AXIS_SCALE,
	DegreesPerShort = DEGREES_PER_SHORT,
}

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function hasExactKeys(value: unknown, allowed: { [string]: boolean }, count: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local observed = 0
	for key in value :: { [any]: any } do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == count
end

local function normalizedFiniteVector(value: unknown): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local vector = value :: Vector3
	if not isFiniteNumber(vector.X) or not isFiniteNumber(vector.Y) or not isFiniteNumber(vector.Z) then
		return nil
	end

	-- Scale before taking Magnitude so any finite Vector3 remains safe even if
	-- squaring its largest component would overflow a floating-point accumulator.
	local largest = math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z))
	if largest == 0 then
		return nil
	end
	local scaled = vector / largest
	local magnitude = scaled.Magnitude
	if not isFiniteNumber(magnitude) or magnitude == 0 then
		return nil
	end
	return scaled / magnitude
end

function CommandQuantization.TruncateTowardZero(value: unknown): number?
	if not isFiniteNumber(value) then
		return nil
	end
	local numberValue = value :: number
	return if numberValue < 0 then math.ceil(numberValue) else math.floor(numberValue)
end

function CommandQuantization.ClampChar(value: unknown): number?
	if not isIntegerInRange(value, SIGNED_INT_MINIMUM, SIGNED_INT_MAXIMUM) then
		return nil
	end
	return math.clamp(value :: number, SIGNED_CHAR_MINIMUM, SIGNED_CHAR_MAXIMUM)
end

function CommandQuantization.Angle2Short(degrees: unknown): number?
	if not isFiniteNumber(degrees) then
		return nil
	end
	-- Preserve the macro's multiply-then-divide order before the C integer cast.
	local scaled = ((degrees :: number) * SHORT_MODULUS) / FULL_TURN_DEGREES
	if scaled < SIGNED_INT_MINIMUM or scaled > SIGNED_INT_MAXIMUM then
		return nil
	end
	local truncated = CommandQuantization.TruncateTowardZero(scaled) :: number
	-- Lua's positive modulo is the mathematical equivalent of C's two's-complement
	-- `& 65535` for every accepted signed integer.
	return truncated % SHORT_MODULUS
end

function CommandQuantization.ShortBitsToSigned(bits: unknown): number?
	if not isIntegerInRange(bits, 0, SHORT_MODULUS - 1) then
		return nil
	end
	local value = bits :: number
	return if value >= SHORT_SIGN_BIT then value - SHORT_MODULUS else value
end

function CommandQuantization.ValidateAngleBits(bits: unknown): number?
	return if isIntegerInRange(bits, 0, SHORT_MODULUS - 1) then bits :: number else nil
end

function CommandQuantization.SignedShortToBits(value: unknown): number?
	if not isIntegerInRange(value, SIGNED_SHORT_MINIMUM, SIGNED_SHORT_MAXIMUM) then
		return nil
	end
	return (value :: number) % SHORT_MODULUS
end

function CommandQuantization.AngleToSignedShort(degrees: unknown): number?
	local bits = CommandQuantization.Angle2Short(degrees)
	return if bits == nil then nil else CommandQuantization.ShortBitsToSigned(bits)
end

function CommandQuantization.Short2Angle(value: unknown): number?
	if not isIntegerInRange(value, SIGNED_SHORT_MINIMUM, SIGNED_SHORT_MAXIMUM) then
		return nil
	end
	return (value :: number) * DEGREES_PER_SHORT
end

function CommandQuantization.ClampViewPitchShort(value: unknown): number?
	if not isIntegerInRange(value, SIGNED_SHORT_MINIMUM, SIGNED_SHORT_MAXIMUM) then
		return nil
	end
	-- bg_pmove.c PM_UpdateViewAngles clamps the signed temporary command angle
	-- after delta_angles have been added. This primitive represents that exact
	-- final clamp; consumer integration will remain responsible for circular
	-- signed-short addition and authoritative delta-angle mutation.
	return math.clamp(value :: number, VIEW_PITCH_MINIMUM_SHORT, VIEW_PITCH_MAXIMUM_SHORT)
end

function CommandQuantization.ValidateButtonBits(value: unknown): number?
	return UserCommandButtonRules.Validate(value)
end

function CommandQuantization.DecodeButtonBits(value: unknown): UserCommandButtonRules.Levels?
	return UserCommandButtonRules.Decode(value)
end

function CommandQuantization.AttackFromButtonBits(value: unknown): boolean?
	local levels = UserCommandButtonRules.Decode(value)
	return if levels == nil then nil else levels.attack
end

function CommandQuantization.UseHoldableFromButtonBits(value: unknown): boolean?
	local levels = UserCommandButtonRules.Decode(value)
	return if levels == nil then nil else levels.useHoldable
end

function CommandQuantization.WalkingFromButtonBits(value: unknown): boolean?
	local levels = UserCommandButtonRules.Decode(value)
	return if levels == nil then nil else levels.walking
end

function CommandQuantization.ButtonBitsFromLevels(attack: unknown, useHoldable: unknown, walking: unknown): number?
	return UserCommandButtonRules.Encode(attack, useHoldable, walking)
end

function CommandQuantization.ButtonBitsFromAttack(attack: unknown): number?
	-- Compatibility wrapper for call sites that have not yet exposed Use/Walk.
	return UserCommandButtonRules.Encode(attack, false, false)
end

function CommandQuantization.ValidateWeaponByte(value: unknown): number?
	return if isIntegerInRange(value, 0, WEAPON_BYTE_MAXIMUM) then value :: number else nil
end

function CommandQuantization.CanonicalizeAngle(degrees: unknown): (number?, number?)
	local encoded = CommandQuantization.AngleToSignedShort(degrees)
	if encoded == nil then
		return nil, nil
	end
	return CommandQuantization.Short2Angle(encoded), encoded
end

function CommandQuantization.EncodeNormalizedAxisAtScale(value: unknown, scaleValue: unknown): number?
	if not isFiniteNumber(value) or not isIntegerInRange(scaleValue, 1, NORMALIZED_AXIS_SCALE) then
		return nil
	end
	local normalized = value :: number
	if normalized < -1 or normalized > 1 then
		return nil
	end
	local integer = CommandQuantization.TruncateTowardZero(normalized * (scaleValue :: number))
	return CommandQuantization.ClampChar(integer)
end

function CommandQuantization.EncodeNormalizedAxis(value: unknown): number?
	return CommandQuantization.EncodeNormalizedAxisAtScale(value, NORMALIZED_AXIS_SCALE)
end

function CommandQuantization.DecodeNormalizedAxis(value: unknown): number?
	if not isIntegerInRange(value, SIGNED_CHAR_MINIMUM, SIGNED_CHAR_MAXIMUM) then
		return nil
	end
	return (value :: number) / NORMALIZED_AXIS_SCALE
end

function CommandQuantization.CanonicalizeNormalizedAxis(value: unknown): (number?, number?)
	local encoded = CommandQuantization.EncodeNormalizedAxis(value)
	if encoded == nil then
		return nil, nil
	end
	return CommandQuantization.DecodeNormalizedAxis(encoded), encoded
end

function CommandQuantization.EncodeAxesAtScale(value: unknown, scaleValue: unknown): EncodedAxes?
	if not hasExactKeys(value, AXIS_KEYS, 3) then
		return nil
	end
	local source = value :: any
	local forward = CommandQuantization.EncodeNormalizedAxisAtScale(source.forward, scaleValue)
	local right = CommandQuantization.EncodeNormalizedAxisAtScale(source.right, scaleValue)
	local upMove = CommandQuantization.EncodeNormalizedAxisAtScale(source.upMove, scaleValue)
	if forward == nil or right == nil or upMove == nil then
		return nil
	end
	return table.freeze({
		forward = forward,
		right = right,
		upMove = upMove,
	})
end

function CommandQuantization.EncodeAxes(value: unknown): EncodedAxes?
	return CommandQuantization.EncodeAxesAtScale(value, NORMALIZED_AXIS_SCALE)
end

function CommandQuantization.DecodeAxes(value: unknown): DecodedAxes?
	if not hasExactKeys(value, AXIS_KEYS, 3) then
		return nil
	end
	local source = value :: any
	local forward = CommandQuantization.DecodeNormalizedAxis(source.forward)
	local right = CommandQuantization.DecodeNormalizedAxis(source.right)
	local upMove = CommandQuantization.DecodeNormalizedAxis(source.upMove)
	if forward == nil or right == nil or upMove == nil then
		return nil
	end
	return table.freeze({
		forward = forward,
		right = right,
		upMove = upMove,
	})
end

-- Returns the signed-short interpretation used by PM_UpdateViewAngles after
-- command angle bits have been stored/read and circularly combined with deltas.
function CommandQuantization.EncodeSignedLook(look: unknown): LookShorts?
	local normalized = normalizedFiniteVector(look)
	if not normalized then
		return nil
	end

	-- Inverse of the documented Q3-to-Roblox basis mapping.
	local q3X = -normalized.Z
	local q3Y = -normalized.X
	local q3Z = normalized.Y
	local yaw: number
	local pitch: number
	if q3Y == 0 and q3X == 0 then
		yaw = 0
		pitch = if q3Z > 0 then 90 else 270
	else
		if q3X ~= 0 then
			yaw = math.deg(math.atan2(q3Y, q3X))
		elseif q3Y > 0 then
			yaw = 90
		else
			yaw = 270
		end
		if yaw < 0 then
			yaw += FULL_TURN_DEGREES
		end
		local horizontal = math.sqrt(q3X * q3X + q3Y * q3Y)
		pitch = math.deg(math.atan2(q3Z, horizontal))
		if pitch < 0 then
			pitch += FULL_TURN_DEGREES
		end
	end

	local encodedPitch = CommandQuantization.AngleToSignedShort(-pitch)
	local encodedYaw = CommandQuantization.AngleToSignedShort(yaw)
	if encodedPitch == nil or encodedYaw == nil then
		return nil
	end
	return table.freeze({
		pitch = encodedPitch,
		yaw = encodedYaw,
	})
end

-- Returns the raw 0..65535 ANGLE2SHORT bit patterns authored into usercmd_t.
function CommandQuantization.EncodeLook(look: unknown): LookBits?
	local signed = CommandQuantization.EncodeSignedLook(look)
	if not signed then
		return nil
	end
	return table.freeze({
		pitch = CommandQuantization.SignedShortToBits(signed.pitch) :: number,
		yaw = CommandQuantization.SignedShortToBits(signed.yaw) :: number,
	})
end

function CommandQuantization.DecodeSignedLook(value: unknown): Vector3?
	if not hasExactKeys(value, LOOK_SHORT_KEYS, 2) then
		return nil
	end
	local source = value :: any
	local pitchDegrees = CommandQuantization.Short2Angle(source.pitch)
	local yawDegrees = CommandQuantization.Short2Angle(source.yaw)
	if pitchDegrees == nil or yawDegrees == nil then
		return nil
	end

	local pitch = math.rad(pitchDegrees)
	local yaw = math.rad(yawDegrees)
	local sinPitch = math.sin(pitch)
	local cosPitch = math.cos(pitch)
	local sinYaw = math.sin(yaw)
	local cosYaw = math.cos(yaw)
	-- Q3 AngleVectors forward mapped into Roblox's Y-up basis.
	return Vector3.new(-cosPitch * sinYaw, -sinPitch, -cosPitch * cosYaw).Unit
end

-- Decodes raw usercmd angle bit patterns through signed-short interpretation.
function CommandQuantization.DecodeLook(value: unknown): Vector3?
	if not hasExactKeys(value, LOOK_SHORT_KEYS, 2) then
		return nil
	end
	local source = value :: any
	local pitch = CommandQuantization.ShortBitsToSigned(source.pitch)
	local yaw = CommandQuantization.ShortBitsToSigned(source.yaw)
	if pitch == nil or yaw == nil then
		return nil
	end
	return CommandQuantization.DecodeSignedLook({
		pitch = pitch,
		yaw = yaw,
	})
end

function CommandQuantization.ClampViewShorts(value: unknown): LookShorts?
	if not hasExactKeys(value, LOOK_SHORT_KEYS, 2) then
		return nil
	end
	local source = value :: any
	local pitch = CommandQuantization.ClampViewPitchShort(source.pitch)
	if pitch == nil or not isIntegerInRange(source.yaw, SIGNED_SHORT_MINIMUM, SIGNED_SHORT_MAXIMUM) then
		return nil
	end
	return table.freeze({
		pitch = pitch,
		yaw = source.yaw,
	})
end

function CommandQuantization.CanonicalizeLook(look: unknown): (Vector3?, LookBits?)
	local encoded = CommandQuantization.EncodeLook(look)
	if not encoded then
		return nil, nil
	end
	return CommandQuantization.DecodeLook(encoded), encoded
end

function CommandQuantization.CanonicalizeViewLook(look: unknown): (Vector3?, LookShorts?)
	local encoded = CommandQuantization.EncodeSignedLook(look)
	if not encoded then
		return nil, nil
	end
	local clamped = CommandQuantization.ClampViewShorts(encoded) :: LookShorts
	return CommandQuantization.DecodeSignedLook(clamped), clamped
end

function CommandQuantization.EncodeViewLook(look: unknown): LookBits?
	local _canonical, signed = CommandQuantization.CanonicalizeViewLook(look)
	if not signed then
		return nil
	end
	return table.freeze({
		pitch = CommandQuantization.SignedShortToBits(signed.pitch) :: number,
		yaw = CommandQuantization.SignedShortToBits(signed.yaw) :: number,
	})
end

function CommandQuantization.DecodeViewLook(value: unknown): Vector3?
	if not hasExactKeys(value, LOOK_SHORT_KEYS, 2) then
		return nil
	end
	local source = value :: any
	local pitch = CommandQuantization.ShortBitsToSigned(source.pitch)
	local yaw = CommandQuantization.ShortBitsToSigned(source.yaw)
	if pitch == nil or yaw == nil then
		return nil
	end
	local clamped = CommandQuantization.ClampViewShorts({
		pitch = pitch,
		yaw = yaw,
	})
	return if clamped then CommandQuantization.DecodeSignedLook(clamped) else nil
end

local function packedAngles(value: unknown): PackedAngles?
	if not hasExactKeys(value, PACKED_ANGLE_KEYS, 3) then
		return nil
	end
	local source = value :: any
	local pitch = CommandQuantization.ValidateAngleBits(source.pitch)
	local yaw = CommandQuantization.ValidateAngleBits(source.yaw)
	local roll = CommandQuantization.ValidateAngleBits(source.roll)
	if pitch == nil or yaw == nil or roll == nil then
		return nil
	end
	return {
		pitch = pitch,
		yaw = yaw,
		roll = roll,
	}
end

local function signedAngleFromSum(commandBits: number, deltaBits: number): number
	return CommandQuantization.ShortBitsToSigned((commandBits + deltaBits) % SHORT_MODULUS) :: number
end

-- Exact PM_UpdateViewAngles arithmetic in the bounded network domain. Q3 stores
-- delta_angles as ints but communicates only their low 16 bits; preserving
-- those raw bits is sufficient for circular signed-short addition and for the
-- pitch correction written when the effective value exceeds +/-16000.
function CommandQuantization.ResolveViewAngles(commandValue: unknown, deltaValue: unknown): ResolvedViewAngles?
	local command = packedAngles(commandValue)
	local delta = packedAngles(deltaValue)
	if not command or not delta then
		return nil
	end

	local pitch = signedAngleFromSum(command.pitch, delta.pitch)
	local yaw = signedAngleFromSum(command.yaw, delta.yaw)
	local roll = signedAngleFromSum(command.roll, delta.roll)
	local clampedPitch = CommandQuantization.ClampViewPitchShort(pitch) :: number
	local deltaPitch = delta.pitch
	if clampedPitch ~= pitch then
		-- Equivalent low 16 bits to `+/-16000 - cmd->angles[PITCH]`.
		deltaPitch = (clampedPitch - command.pitch) % SHORT_MODULUS
		pitch = clampedPitch
	end
	local look = CommandQuantization.DecodeSignedLook({
		pitch = pitch,
		yaw = yaw,
	})
	if not look then
		return nil
	end
	return table.freeze({
		pitch = pitch,
		yaw = yaw,
		roll = roll,
		look = look,
		deltaPitch = deltaPitch,
		deltaYaw = delta.yaw,
		deltaRoll = delta.roll,
	})
end

-- Roblox exposes the effective camera vector, while Q3 usercmd_t contains raw
-- view angles before playerState.delta_angles. Subtract the authoritative delta
-- modulo 16 bits so adding it again in PM_UpdateViewAngles reconstructs the
-- intended effective view exactly. Do not pre-clamp pitch here: cl_input.c
-- authors the raw cl.viewangles bits, and PM_UpdateViewAngles owns both the
-- +/-16000 clamp and its required delta_angles correction.
function CommandQuantization.EncodeViewLookWithDelta(look: unknown, deltaValue: unknown): PackedAngles?
	local delta = packedAngles(deltaValue)
	local target = CommandQuantization.EncodeLook(look)
	if not delta or not target then
		return nil
	end
	return table.freeze({
		pitch = (target.pitch - delta.pitch) % SHORT_MODULUS,
		yaw = (target.yaw - delta.yaw) % SHORT_MODULUS,
		roll = (0 - delta.roll) % SHORT_MODULUS,
	})
end

-- SetClientViewAngle sets delta_angles to target command bits minus the most
-- recently received command bits, then publishes the target view immediately.
-- A Vector3 has no roll, so the Roblox adapter authors source roll zero.
function CommandQuantization.DeltaAnglesForViewLook(
	commandValue: unknown,
	look: unknown
): (DeltaAngles?, ResolvedViewAngles?)
	local command = packedAngles(commandValue)
	local target = CommandQuantization.EncodeLook(look)
	if not command or not target then
		return nil, nil
	end
	local delta = table.freeze({
		pitch = (target.pitch - command.pitch) % SHORT_MODULUS,
		yaw = (target.yaw - command.yaw) % SHORT_MODULUS,
		roll = (0 - command.roll) % SHORT_MODULUS,
	})
	local pitch = CommandQuantization.ShortBitsToSigned(target.pitch) :: number
	local yaw = CommandQuantization.ShortBitsToSigned(target.yaw) :: number
	local targetLook = CommandQuantization.DecodeLook(target)
	if not targetLook then
		return nil, nil
	end
	return delta,
		table.freeze({
			pitch = pitch,
			yaw = yaw,
			roll = 0,
			look = targetLook,
			deltaPitch = delta.pitch,
			deltaYaw = delta.yaw,
			deltaRoll = delta.roll,
		})
end

return table.freeze(CommandQuantization)
