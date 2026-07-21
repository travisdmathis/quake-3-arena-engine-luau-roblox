--[[
SPDX-License-Identifier: GPL-2.0-or-later

Translated from Quake III Arena code/game/g_combat.c (CanDamage).

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local Constants = require(script.Parent.Parent.simulation.Constants)

local CORNER_OFFSET = 15 * Constants.UnitsToStuds
local SAMPLE_OFFSETS = table.freeze({
	Vector3.zero,
	Vector3.new(CORNER_OFFSET, 0, CORNER_OFFSET),
	Vector3.new(CORNER_OFFSET, 0, -CORNER_OFFSET),
	Vector3.new(-CORNER_OFFSET, 0, CORNER_OFFSET),
	Vector3.new(-CORNER_OFFSET, 0, -CORNER_OFFSET),
})

local function canReach(
	targetCenter: Vector3,
	isSampleClear: (samplePosition: Vector3, sampleIndex: number) -> boolean
): boolean
	for sampleIndex, offset in SAMPLE_OFFSETS do
		if isSampleClear(targetCenter + offset, sampleIndex) then
			return true
		end
	end
	return false
end

return table.freeze({
	CornerOffset = CORNER_OFFSET,
	SampleOffsets = SAMPLE_OFFSETS,
	CanReach = canReach,
})
