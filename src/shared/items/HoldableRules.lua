--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of:
  code/game/bg_public.h (holdable_t, PMF_USE_ITEM_HELD)
  code/game/bg_pmove.c (PM_Weapon holdable branch)
  code/game/g_active.c (EV_USE_ITEM2 medkit)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local HoldableRules = {}

local HoldableId = table.freeze({
	None = 0,
	Teleporter = 1,
	Medkit = 2,
})

export type Decision = {
	read held: boolean,
	read holdableId: number,
	read consumedHoldableId: number?,
	read blocksWeapon: boolean,
}

function HoldableRules.ResolveCommand(
	usePressed: unknown,
	wasHeld: unknown,
	holdableId: unknown,
	health: unknown,
	maxHealth: unknown
): Decision?
	if
		type(usePressed) ~= "boolean"
		or type(wasHeld) ~= "boolean"
		or type(holdableId) ~= "number"
		or holdableId % 1 ~= 0
		or (holdableId ~= HoldableId.None and holdableId ~= HoldableId.Teleporter and holdableId ~= HoldableId.Medkit)
		or type(health) ~= "number"
		or health % 1 ~= 0
		or type(maxHealth) ~= "number"
		or maxHealth % 1 ~= 0
		or maxHealth < 1
	then
		return nil
	end
	if not usePressed then
		return table.freeze({
			held = false,
			holdableId = holdableId,
			consumedHoldableId = nil,
			blocksWeapon = false,
		})
	end
	if wasHeld then
		return table.freeze({
			held = true,
			holdableId = holdableId,
			consumedHoldableId = nil,
			blocksWeapon = true,
		})
	end
	if holdableId == HoldableId.Medkit and health >= maxHealth + 25 then
		-- Q3 does not set PMF_USE_ITEM_HELD for this rejection, so a held button
		-- retries each command and continues to block the weapon branch.
		return table.freeze({
			held = false,
			holdableId = holdableId,
			consumedHoldableId = nil,
			blocksWeapon = true,
		})
	end
	return table.freeze({
		held = true,
		holdableId = HoldableId.None,
		consumedHoldableId = if holdableId == HoldableId.None then nil else holdableId,
		blocksWeapon = true,
	})
end

function HoldableRules.ApplyMedkit(health: unknown, maxHealth: unknown, consumedHoldableId: unknown): number?
	if
		type(health) ~= "number"
		or health % 1 ~= 0
		or type(maxHealth) ~= "number"
		or maxHealth % 1 ~= 0
		or maxHealth < 1
		or consumedHoldableId ~= HoldableId.Medkit
	then
		return nil
	end
	return maxHealth + 25
end

HoldableRules.HoldableId = HoldableId

return table.freeze(HoldableRules)
