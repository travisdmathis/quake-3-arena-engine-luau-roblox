--[[
SPDX-License-Identifier: GPL-2.0-or-later

Shared Q3 usercmd button-domain rules translated from:
  code/game/q_shared.h (BUTTON_ATTACK, BUTTON_USE_HOLDABLE, BUTTON_WALKING)
  code/game/g_active.c (oldbuttons/buttons swap and rising-edge latch)
  code/game/g_client.c (ClientSpawn clears the complete gclient before play)
  code/game/bg_pmove.c (PMF_RESPAWNED release mask)

Only Attack, Use Holdable, and Walking are admitted by this button-domain
slice. Other Q3 button bits remain closed until their owning behavior is
translated.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type Levels = {
	read attack: boolean,
	read useHoldable: boolean,
	read walking: boolean,
}

export type History = {
	read buttons: number,
	read oldbuttons: number,
	read latched_buttons: number,
}

local BUTTON_ATTACK = 1
local BUTTON_USE_HOLDABLE = 4
local BUTTON_WALKING = 16
local RESPAWN_RELEASE_MASK = bit32.bor(BUTTON_ATTACK, BUTTON_USE_HOLDABLE)
-- Walking belongs to the supported usercmd domain but never joins the exact
-- PMF_RESPAWNED release mask.
local SUPPORTED_MASK = bit32.bor(RESPAWN_RELEASE_MASK, BUTTON_WALKING)

local HISTORY_KEYS: { [string]: boolean } = {
	buttons = true,
	oldbuttons = true,
	latched_buttons = true,
}
table.freeze(HISTORY_KEYS)

local UserCommandButtonRules = {
	ButtonAttack = BUTTON_ATTACK,
	ButtonUseHoldable = BUTTON_USE_HOLDABLE,
	ButtonWalking = BUTTON_WALKING,
	-- bg_pmove.c uses this exact union when clearing PMF_RESPAWNED.
	RespawnReleaseMask = RESPAWN_RELEASE_MASK,
	SupportedMask = SUPPORTED_MASK,
}

local function hasExactHistoryKeys(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value :: { [any]: any } do
		if type(key) ~= "string" or HISTORY_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 3
end

function UserCommandButtonRules.Validate(value: unknown): number?
	if
		type(value) ~= "number"
		or value ~= value
		or math.abs(value :: number) == math.huge
		or (value :: number) % 1 ~= 0
		or (value :: number) < 0
		or (value :: number) > SUPPORTED_MASK
		or bit32.band(value :: number, bit32.bnot(SUPPORTED_MASK)) ~= 0
	then
		return nil
	end
	return value :: number
end

function UserCommandButtonRules.Decode(value: unknown): Levels?
	local buttons = UserCommandButtonRules.Validate(value)
	if buttons == nil then
		return nil
	end
	return table.freeze({
		attack = bit32.band(buttons, BUTTON_ATTACK) ~= 0,
		useHoldable = bit32.band(buttons, BUTTON_USE_HOLDABLE) ~= 0,
		walking = bit32.band(buttons, BUTTON_WALKING) ~= 0,
	})
end

function UserCommandButtonRules.Encode(attack: unknown, useHoldable: unknown, walking: unknown): number?
	if type(attack) ~= "boolean" or type(useHoldable) ~= "boolean" or type(walking) ~= "boolean" then
		return nil
	end
	local buttons = 0
	if attack then
		buttons = bit32.bor(buttons, BUTTON_ATTACK)
	end
	if useHoldable then
		buttons = bit32.bor(buttons, BUTTON_USE_HOLDABLE)
	end
	if walking then
		buttons = bit32.bor(buttons, BUTTON_WALKING)
	end
	return buttons
end

function UserCommandButtonRules.ValidateHistory(value: unknown): History?
	if not hasExactHistoryKeys(value) then
		return nil
	end
	local history = value :: any
	if
		UserCommandButtonRules.Validate(history.buttons) == nil
		or UserCommandButtonRules.Validate(history.oldbuttons) == nil
		or UserCommandButtonRules.Validate(history.latched_buttons) == nil
	then
		return nil
	end
	return value :: History
end

function UserCommandButtonRules.Reset(): History
	-- ClientSpawn first zeroes the complete gclient_t, including buttons,
	-- oldbuttons, and latched_buttons. Its later explicit latch clear is therefore
	-- idempotent. This is the complete spawn reset, not a latch-only helper.
	return table.freeze({
		buttons = 0,
		oldbuttons = 0,
		latched_buttons = 0,
	})
end

function UserCommandButtonRules.Advance(historyValue: unknown, nextButtonsValue: unknown): History?
	local history = UserCommandButtonRules.ValidateHistory(historyValue)
	local nextButtons = UserCommandButtonRules.Validate(nextButtonsValue)
	if history == nil or nextButtons == nil then
		return nil
	end

	-- g_active.c performs this exact swap, then OR-latches buttons that rose in
	-- the new usercmd. A held level does not create a second edge.
	local rising = bit32.band(nextButtons, bit32.bnot(history.buttons), SUPPORTED_MASK)
	return table.freeze({
		oldbuttons = history.buttons,
		buttons = nextButtons,
		latched_buttons = bit32.bor(history.latched_buttons, rising),
	})
end

return table.freeze(UserCommandButtonRules)
