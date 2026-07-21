--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure base-Quake-III CTF score/assist mapping from:
  code/game/g_team.h (non-MISSIONPACK CTF_* bonuses/timeouts)
  code/game/g_team.c (Team_FragBonuses, Team_TouchOurFlag)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local CtfBonusRules = {}

local Bonuses = table.freeze({
	Capture = 5,
	TeamCapture = 0,
	Recovery = 1,
	EnemyFlagPickup = 0,
	FragCarrier = 2,
	CarrierDangerProtect = 2,
	CarrierProtect = 1,
	FlagDefense = 1,
	ReturnAssist = 1,
	FragCarrierAssist = 2,
})

local RETURN_ASSIST_TIMEOUT_MILLISECONDS = 10_000
local FRAG_CARRIER_ASSIST_TIMEOUT_MILLISECONDS = 10_000
local CARRIER_DANGER_TIMEOUT_MILLISECONDS = 8_000
local PROTECT_RADIUS_STUDS = 1_000 * 0.1
local REWARD_SPRITE_MILLISECONDS = 2_000

local function validTime(value: unknown): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 0
end

function CtfBonusRules.AssistKind(
	lastReturnedFlagMilliseconds: unknown,
	lastFraggedCarrierMilliseconds: unknown,
	levelTimeMilliseconds: unknown
): ("Return" | "FragCarrier")?
	if not validTime(levelTimeMilliseconds) then
		return nil
	end
	if
		validTime(lastReturnedFlagMilliseconds)
		and (lastReturnedFlagMilliseconds :: number) + RETURN_ASSIST_TIMEOUT_MILLISECONDS
			> (levelTimeMilliseconds :: number)
	then
		return "Return"
	end
	if
		validTime(lastFraggedCarrierMilliseconds)
		and lastFraggedCarrierMilliseconds :: number + FRAG_CARRIER_ASSIST_TIMEOUT_MILLISECONDS
			> (levelTimeMilliseconds :: number)
	then
		return "FragCarrier"
	end
	return nil
end

function CtfBonusRules.DefenseKind(
	fraggedCarrier: unknown,
	carrierDanger: unknown,
	baseProtected: unknown,
	carrierProtected: unknown
): ("FragCarrier" | "CarrierDanger" | "Base" | "Carrier")?
	if
		type(fraggedCarrier) ~= "boolean"
		or type(carrierDanger) ~= "boolean"
		or type(baseProtected) ~= "boolean"
		or type(carrierProtected) ~= "boolean"
	then
		return nil
	end
	if fraggedCarrier then
		return "FragCarrier"
	elseif carrierDanger then
		return "CarrierDanger"
	elseif baseProtected then
		return "Base"
	elseif carrierProtected then
		return "Carrier"
	end
	return nil
end

CtfBonusRules.Bonuses = Bonuses
CtfBonusRules.ReturnAssistTimeoutMilliseconds = RETURN_ASSIST_TIMEOUT_MILLISECONDS
CtfBonusRules.FragCarrierAssistTimeoutMilliseconds = FRAG_CARRIER_ASSIST_TIMEOUT_MILLISECONDS
CtfBonusRules.CarrierDangerTimeoutMilliseconds = CARRIER_DANGER_TIMEOUT_MILLISECONDS
CtfBonusRules.ProtectRadiusStuds = PROTECT_RADIUS_STUDS
CtfBonusRules.RewardSpriteMilliseconds = REWARD_SPRITE_MILLISECONDS

return table.freeze(CtfBonusRules)
