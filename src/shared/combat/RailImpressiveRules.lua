--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of:
  code/game/g_weapon.c (weapon_railgun_fire accurateCount / Impressive)
  code/game/g_local.h (REWARD_SPRITE_TIME)
  code/game/g_active.c (strict rewardTime expiry)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local RailImpressiveRules = {}

local REWARD_SPRITE_MILLISECONDS = 2_000
local MAXIMUM_RAIL_HITS = 4

function RailImpressiveRules.Advance(accurateCount: unknown, qualifyingHits: unknown): (number?, number?)
	if
		type(accurateCount) ~= "number"
		or accurateCount % 1 ~= 0
		or accurateCount < 0
		or accurateCount > 9_007_199_254_740_987
		or type(qualifyingHits) ~= "number"
		or qualifyingHits % 1 ~= 0
		or qualifyingHits < 0
		or qualifyingHits > MAXIMUM_RAIL_HITS
	then
		return nil, nil
	end
	if qualifyingHits == 0 then
		return 0, 0
	end
	local nextAccurateCount = accurateCount + qualifyingHits
	if nextAccurateCount >= 2 then
		-- Q3 uses one `if`, not a loop: a four-penetration rail can award at most
		-- one Impressive and retain the remaining streak count for the next shot.
		return nextAccurateCount - 2, 1
	end
	return nextAccurateCount, 0
end

function RailImpressiveRules.RewardDeadline(levelTimeMilliseconds: unknown): number?
	if
		type(levelTimeMilliseconds) ~= "number"
		or levelTimeMilliseconds % 1 ~= 0
		or levelTimeMilliseconds < 0
		or levelTimeMilliseconds > 9_007_199_254_738_991
	then
		return nil
	end
	return levelTimeMilliseconds + REWARD_SPRITE_MILLISECONDS
end

function RailImpressiveRules.IsRewardExpired(
	rewardDeadlineMilliseconds: unknown,
	levelTimeMilliseconds: unknown
): boolean?
	if
		type(rewardDeadlineMilliseconds) ~= "number"
		or rewardDeadlineMilliseconds % 1 ~= 0
		or rewardDeadlineMilliseconds < 0
		or type(levelTimeMilliseconds) ~= "number"
		or levelTimeMilliseconds % 1 ~= 0
		or levelTimeMilliseconds < 0
	then
		return nil
	end
	return levelTimeMilliseconds > rewardDeadlineMilliseconds
end

RailImpressiveRules.RewardSpriteMilliseconds = REWARD_SPRITE_MILLISECONDS
RailImpressiveRules.MaximumRailHits = MAXIMUM_RAIL_HITS

return table.freeze(RailImpressiveRules)
