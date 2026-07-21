--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of:
  code/client/cl_input.c (IN_KeyDown, IN_KeyUp, CL_KeyState)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type State = {
	read active: boolean,
	read downAtSeconds: number?,
	read accumulatedSeconds: number,
	read engagedSinceSample: boolean,
}

local CommandKeyStateRules = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function makeState(
	active: boolean,
	downAtSeconds: number?,
	accumulatedSeconds: number,
	engagedSinceSample: boolean
): State
	return table.freeze({
		active = active,
		downAtSeconds = downAtSeconds,
		accumulatedSeconds = accumulatedSeconds,
		engagedSinceSample = engagedSinceSample,
	})
end

function CommandKeyStateRules.New(): State
	return makeState(false, nil, 0, false)
end

function CommandKeyStateRules.SetActive(state: State, activeValue: unknown, nowSecondsValue: unknown): State?
	if
		type(state) ~= "table"
		or not table.isfrozen(state)
		or type(activeValue) ~= "boolean"
		or not isFinite(nowSecondsValue)
		or (nowSecondsValue :: number) < 0
	then
		return nil
	end
	local nowSeconds = nowSecondsValue :: number
	local active = activeValue :: boolean
	if active == state.active then
		return state
	end
	if active then
		return makeState(true, nowSeconds, state.accumulatedSeconds, true)
	end
	local downAtSeconds = state.downAtSeconds
	if downAtSeconds == nil or nowSeconds < downAtSeconds then
		return nil
	end
	return makeState(false, nil, state.accumulatedSeconds + (nowSeconds - downAtSeconds), true)
end

function CommandKeyStateRules.Sample(
	state: State,
	nowSecondsValue: unknown,
	frameSecondsValue: unknown
): (State?, number?, boolean?)
	if
		type(state) ~= "table"
		or not table.isfrozen(state)
		or not isFinite(nowSecondsValue)
		or (nowSecondsValue :: number) < 0
		or not isFinite(frameSecondsValue)
		or (frameSecondsValue :: number) <= 0
	then
		return nil, nil, nil
	end
	local nowSeconds = nowSecondsValue :: number
	local accumulatedSeconds = state.accumulatedSeconds
	local nextDownAtSeconds: number? = nil
	if state.active then
		local downAtSeconds = state.downAtSeconds
		if downAtSeconds == nil or nowSeconds < downAtSeconds then
			return nil, nil, nil
		end
		accumulatedSeconds += nowSeconds - downAtSeconds
		nextDownAtSeconds = nowSeconds
	end
	local fraction = math.clamp(accumulatedSeconds / (frameSecondsValue :: number), 0, 1)
	return makeState(state.active, nextDownAtSeconds, 0, state.active), fraction, state.engagedSinceSample
end

return table.freeze(CommandKeyStateRules)
