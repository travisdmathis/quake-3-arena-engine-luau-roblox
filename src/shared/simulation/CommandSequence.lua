--[[
SPDX-License-Identifier: GPL-2.0-or-later

Shared bounded serial-number arithmetic for client command protocols.
]]

--!strict

local MAXIMUM_SEQUENCE = 2_147_483_647
local MODULUS = MAXIMUM_SEQUENCE + 1
local HALF_RANGE = MODULUS / 2

local CommandSequence = {
	Maximum = MAXIMUM_SEQUENCE,
	Modulus = MODULUS,
	HalfRange = HALF_RANGE,
}

function CommandSequence.IsInRange(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= 0
		and value <= MAXIMUM_SEQUENCE
end

function CommandSequence.IsNewer(value: unknown, previous: number): boolean
	if not CommandSequence.IsInRange(value) or not CommandSequence.IsInRange(previous) then
		return false
	end
	local delta = ((value :: number) - previous) % MODULUS
	return delta > 0 and delta < HALF_RANGE
end

function CommandSequence.IsAtOrBefore(value: unknown, latest: unknown): boolean
	return CommandSequence.IsInRange(value)
		and CommandSequence.IsInRange(latest)
		and (value == latest or CommandSequence.IsNewer(latest, value :: number))
end

function CommandSequence.Next(value: number): number
	assert(CommandSequence.IsInRange(value), "command sequence must be in range")
	return (value + 1) % MODULUS
end

return table.freeze(CommandSequence)
