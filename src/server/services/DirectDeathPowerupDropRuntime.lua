--[[
SPDX-License-Identifier: GPL-2.0-or-later

Synchronous ordinary-death timed-powerup drop adapter for:
  code/game/g_combat.c (TossClientItems)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-19.

This pure builder snapshots every timed-powerup request from the pre-death
Combat root in PW_QUAD..PW_FLIGHT order. Combat then combines those immutable
requests with the optional weapon and gives ItemService one prepared batch.
]]

--!strict

local DirectDeathPowerupDropRuntime = {}

export type DeathDropRequest = {
	dropId: string,
	matchId: string,
	itemId: string,
	quantity: number,
	position: Vector3,
	velocity: Vector3,
}

type ResolvedPowerupDrop = {
	read powerupId: number,
	read remainingSeconds: number,
	read yawOffsetDegrees: number,
}

export type BuildRequest = {
	read targetUserId: number,
	read lifeSequence: number,
	read matchId: string,
	read position: Vector3,
	read look: Vector3,
	read powerupExpiries: { [number]: number },
	read levelTimeMilliseconds: number,
	read suppressForTeamDeathmatch: boolean,
	read suppressForNoDrop: boolean,
}

export type Dependencies = {
	read ResolveDeathDrops: (
		expiriesValue: unknown,
		levelTimeMilliseconds: unknown,
		suppressForTeamDeathmatch: unknown
	) -> { ResolvedPowerupDrop }?,
	read ItemIdByPowerupId: { [number]: string },
	read MakeSeed: (matchId: string, userId: number, lifeSequence: number) -> number,
	read LaunchVelocity: (look: Vector3, seed: number) -> Vector3,
}

export type Runtime = {
	read BuildRequests: (request: BuildRequest) -> ({ DeathDropRequest }?, string?),
}

local function frozenEmptyRequests(): { DeathDropRequest }
	local requests: { DeathDropRequest } = {}
	table.freeze(requests)
	return requests
end

function DirectDeathPowerupDropRuntime.new(dependencies: Dependencies): Runtime
	local function buildRequests(request: BuildRequest): ({ DeathDropRequest }?, string?)
		if request.suppressForNoDrop then
			return frozenEmptyRequests(), nil
		end
		local resolved = dependencies.ResolveDeathDrops(
			request.powerupExpiries,
			request.levelTimeMilliseconds,
			request.suppressForTeamDeathmatch
		)
		if not resolved then
			return nil, "direct-death-powerup-state-invalid"
		end

		local horizontal = Vector3.new(request.look.X, 0, request.look.Z)
		if horizontal.Magnitude <= 1e-6 then
			horizontal = Vector3.zAxis
		else
			horizontal = horizontal.Unit
		end

		local requests: { DeathDropRequest } = {}
		for _, drop in resolved do
			local itemId = dependencies.ItemIdByPowerupId[drop.powerupId]
			if not itemId then
				return nil, "direct-death-powerup-item-definition-missing"
			end
			local yaw = math.rad(drop.yawOffsetDegrees)
			local look = Vector3.new(
				horizontal.X * math.cos(yaw) - horizontal.Z * math.sin(yaw),
				0,
				horizontal.X * math.sin(yaw) + horizontal.Z * math.cos(yaw)
			)
			local seed = dependencies.MakeSeed(
				string.format("%s:powerup:%d", request.matchId, drop.powerupId),
				request.targetUserId,
				request.lifeSequence
			)
			local powerupRequest: DeathDropRequest = {
				dropId = string.format(
					"powerup:%s:%d:%d:%d",
					request.matchId,
					request.targetUserId,
					request.lifeSequence,
					drop.powerupId
				),
				matchId = request.matchId,
				itemId = itemId,
				quantity = drop.remainingSeconds,
				position = request.position,
				velocity = dependencies.LaunchVelocity(look, seed),
			}
			table.freeze(powerupRequest)
			table.insert(requests, powerupRequest)
		end
		table.freeze(requests)
		return requests, nil
	end

	local runtime: Runtime = {
		BuildRequests = buildRequests,
	}
	table.freeze(runtime)
	return runtime
end

return table.freeze(DirectDeathPowerupDropRuntime)
