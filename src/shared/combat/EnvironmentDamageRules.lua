--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure base-Quake-III P_WorldEffects mapping from code/game/g_active.c:
  drowning airOutTime/damage escalation and lava/slime sizzle cadence.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local EnvironmentDamageRules = {}

export type State = {
	read airOutTimeMilliseconds: number,
	read drowningDamage: number,
	read painDebounceUntilMilliseconds: number,
}

export type Damage = {
	read amount: number,
	read means: "Water" | "Lava" | "Slime",
	read bypassArmor: boolean,
}

export type Result = {
	read state: State,
	read damages: { Damage },
}

local function integer(value: unknown): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 0
end

function EnvironmentDamageRules.SpawnState(levelTimeMilliseconds: unknown): State?
	if not integer(levelTimeMilliseconds) then
		return nil
	end
	return table.freeze({
		airOutTimeMilliseconds = (levelTimeMilliseconds :: number) + 12_000,
		drowningDamage = 2,
		painDebounceUntilMilliseconds = 0,
	})
end

function EnvironmentDamageRules.Step(
	state: State,
	levelTimeMilliseconds: unknown,
	waterLevel: unknown,
	waterType: unknown,
	battleSuitActive: unknown,
	alive: unknown
): Result?
	if
		type(state) ~= "table"
		or not integer(state.airOutTimeMilliseconds)
		or not integer(state.drowningDamage)
		or state.drowningDamage < 2
		or state.drowningDamage > 15
		or not integer(state.painDebounceUntilMilliseconds)
		or not integer(levelTimeMilliseconds)
		or not integer(waterLevel)
		or waterLevel > 3
		or not integer(waterType)
		or type(battleSuitActive) ~= "boolean"
		or type(alive) ~= "boolean"
	then
		return nil
	end
	local now = levelTimeMilliseconds :: number
	local airOut = state.airOutTimeMilliseconds
	local drowningDamage = state.drowningDamage
	local painDebounce = state.painDebounceUntilMilliseconds
	local damages: { Damage } = {}
	if waterLevel == 3 then
		if battleSuitActive then
			airOut = now + 10_000
		end
		if airOut < now then
			airOut += 1_000
			if alive then
				drowningDamage = math.min(drowningDamage + 2, 15)
				painDebounce = now + 200
				table.insert(
					damages,
					table.freeze({
						amount = drowningDamage,
						means = "Water",
						bypassArmor = true,
					})
				)
			end
		end
	else
		airOut = now + 12_000
		drowningDamage = 2
	end
	if waterLevel > 0 and painDebounce <= now and not battleSuitActive and alive then
		local sizzleCountBefore = #damages
		if bit32.band(waterType :: number, 8) ~= 0 then
			table.insert(
				damages,
				table.freeze({
					amount = 30 * (waterLevel :: number),
					means = "Lava",
					bypassArmor = false,
				})
			)
		end
		if bit32.band(waterType :: number, 16) ~= 0 then
			table.insert(
				damages,
				table.freeze({
					amount = 10 * (waterLevel :: number),
					means = "Slime",
					bypassArmor = false,
				})
			)
		end
		if #damages > sizzleCountBefore then
			-- P_DamageFeedback runs immediately after P_WorldEffects and advances
			-- the ordinary pain debounce after both overlapping contents.
			painDebounce = now + 700
		end
	end
	return table.freeze({
		state = table.freeze({
			airOutTimeMilliseconds = airOut,
			drowningDamage = drowningDamage,
			painDebounceUntilMilliseconds = painDebounce,
		}),
		damages = table.freeze(damages),
	})
end

return table.freeze(EnvironmentDamageRules)
