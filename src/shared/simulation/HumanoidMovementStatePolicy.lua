--!strict

-- Arena movement is authored by the shared Q3 movement kernel. Disable only
-- the Roblox locomotion states that can compete for jump or climb intent; the
-- remaining Humanoid states stay available for presentation and death flow.
local DISABLED_STATES: { Enum.HumanoidStateType } = table.freeze({
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Climbing,
})

local HumanoidMovementStatePolicy = {}

function HumanoidMovementStatePolicy.Apply(humanoid: Humanoid)
	for _, state in DISABLED_STATES do
		humanoid:SetStateEnabled(state, false)
	end
end

function HumanoidMovementStatePolicy.IsApplied(humanoid: Humanoid): boolean
	for _, state in DISABLED_STATES do
		if humanoid:GetStateEnabled(state) then
			return false
		end
	end
	return true
end

HumanoidMovementStatePolicy.DisabledStates = DISABLED_STATES

return table.freeze(HumanoidMovementStatePolicy)
