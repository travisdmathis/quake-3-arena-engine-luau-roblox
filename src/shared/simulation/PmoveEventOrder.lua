--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau translation of predictable event drain ordering from:
  code/game/bg_pmove.c (PM_GroundTrace, PM_Weapon, PmoveSingle)
  code/game/g_active.c (ClientEvents before G_TouchTriggers)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

export type PreparedAttack = () -> ()
export type LandingHandler = (contactIndex: number, contact: any) -> ()

local PmoveEventOrder = {}

function PmoveEventOrder.DrainLandingThenAttack(
	landingContacts: { any },
	onLanding: LandingHandler,
	preparedAttack: PreparedAttack?
)
	-- Both ground traces can queue PM_CrashLand before PM_Weapon queues fire.
	-- ClientEvents drains the resulting order before world triggers run.
	for contactIndex, contact in landingContacts do
		onLanding(contactIndex, contact)
	end
	if preparedAttack then
		preparedAttack()
	end
end

return table.freeze(PmoveEventOrder)
