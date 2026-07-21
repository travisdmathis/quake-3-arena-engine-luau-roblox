--[[
SPDX-License-Identifier: GPL-2.0-or-later

Q3 ordered usercmd processing is mapped from:
  code/server/sv_client.c (SV_UserMove executes every newer command in order)
  code/game/g_active.c (ClientThink_real consumes one complete atomic usercmd)
  code/game/bg_pmove.c (each command advances playerState commandTime)

Roblox reliable remotes preserve delivery order; server-owned fixed-step time
replaces client-authored serverTime so commands cannot accelerate simulation.
Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local UserCommandButtonRules = require(script.Parent.UserCommandButtonRules)

export type Entry = {
	command: {
		buttons: number,
	},
}

local CommandQueueRules = {}

function CommandQueueRules.SelectIndex(queue: { Entry }, head: number): number?
	if type(head) ~= "number" or head % 1 ~= 0 or head < 1 or head > #queue then
		return nil
	end

	-- SV_UserMove discards only commands whose time was already executed. Every
	-- accepted newer command—including an otherwise identical one—reaches
	-- SV_ClientThink in packet order. Sequence validation performs the duplicate
	-- rejection before insertion; selection must therefore return exactly head.
	assert(
		UserCommandButtonRules.Validate(queue[head].command.buttons) ~= nil,
		"CommandQueueRules received unsupported Q3 button bits"
	)
	return head
end

return table.freeze(CommandQueueRules)
