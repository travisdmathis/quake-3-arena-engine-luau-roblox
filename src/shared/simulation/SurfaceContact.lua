--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox surface-metadata adapter for Quake III trace behavior from:
  code/game/q_shared.h (trace_t.surfaceFlags)
  code/game/surfaceflags.h (SURF_NODAMAGE, SURF_SLICK, SURF_NOIMPACT)

The Roblox attributes are an original map-runtime representation shared by
server authority and owner prediction.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local SLICK_ATTRIBUTE = "Q3EngineSurfaceSlick"
local NO_DAMAGE_ATTRIBUTE = "Q3EngineSurfaceNoDamage"
local NO_IMPACT_ATTRIBUTE = "Q3EngineSurfaceNoImpact"

local SurfaceContact = {}

function SurfaceContact.Read(instance: Instance?): (boolean, boolean)
	if not instance or not instance:IsA("BasePart") then
		return false, false
	end
	return instance:GetAttribute(SLICK_ATTRIBUTE) == true, instance:GetAttribute(NO_DAMAGE_ATTRIBUTE) == true
end

-- Keep Read's two-result contract stable for existing movement callers. Combat
-- traces opt into SURF_NOIMPACT explicitly because it does not affect movement.
function SurfaceContact.IsNoImpact(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("BasePart") and instance:GetAttribute(NO_IMPACT_ATTRIBUTE) == true
end

SurfaceContact.SlickAttribute = SLICK_ATTRIBUTE
SurfaceContact.NoDamageAttribute = NO_DAMAGE_ATTRIBUTE
SurfaceContact.NoImpactAttribute = NO_IMPACT_ATTRIBUTE

return table.freeze(SurfaceContact)
