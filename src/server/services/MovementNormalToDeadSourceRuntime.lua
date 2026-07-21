--!strict

local MovementNormalToDeadSourceRuntime = {}

export type Source = {}
export type Summary = {
	read kind: "World" | "Player" | "Projectile",
	read player: Player?,
	read lifeBinding: unknown?,
	read lifeSummary: unknown?,
	read entityTrajectoryBase: Vector3,
}
export type Capability = {
	source: Source,
	summary: Summary,
	player: Player?,
	record: unknown?,
	lifeBinding: unknown?,
	lifeSummary: unknown?,
	entityTrajectoryBase: Vector3,
	projectileInflictor: unknown?,
	projectileInflictorSummary: unknown?,
}
export type ProjectileAdapter = {
	Capture: (unknown) -> (unknown?, unknown?, string?),
	Validate: (unknown, unknown) -> (boolean, string?),
}
export type PlayerCapture = {
	player: Player,
	record: unknown,
	lifeBinding: unknown,
	lifeSummary: unknown,
	entityTrajectoryBase: Vector3,
}
export type PlayerValidator = (Capability, boolean) -> (boolean, string?)
export type Runtime = {
	SetProjectileAdapter: (self: Runtime, unknown) -> (),
	GetWorld: (self: Runtime) -> (Source, Summary),
	CapturePlayer: (self: Runtime, PlayerCapture) -> (Source, Summary),
	CaptureProjectile: (self: Runtime, unknown) -> (Source?, Summary?, string?),
	Current: (self: Runtime, unknown, unknown, boolean, PlayerValidator) -> (Capability?, string?),
	Inspect: (self: Runtime, unknown, PlayerValidator) -> Summary?,
}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function validateProjectileAdapter(value: unknown): ProjectileAdapter
	assert(
		type(value) == "table" and getmetatable(value) == nil and table.isfrozen(value :: table),
		"projectile death-source adapter must be a frozen plain table"
	)
	local raw = value :: { [unknown]: unknown }
	local observed = 0
	for key in next, raw do
		assert(key == "Capture" or key == "Validate", "projectile adapter has an unknown member")
		observed += 1
	end
	assert(
		observed == 2 and type(rawget(raw, "Capture")) == "function" and type(rawget(raw, "Validate")) == "function",
		"projectile death-source adapter is incomplete"
	)
	return value :: ProjectileAdapter
end

function MovementNormalToDeadSourceRuntime.new(): Runtime
	local worldSource = table.freeze({}) :: Source
	local worldSummary = table.freeze({
		kind = "World",
		player = nil,
		lifeBinding = nil,
		lifeSummary = nil,
		entityTrajectoryBase = Vector3.zero,
	}) :: Summary
	local capabilities = setmetatable({}, { __mode = "k" }) :: { [Source]: Capability }
	local projectileAdapter: ProjectileAdapter? = nil
	capabilities[worldSource] = {
		source = worldSource,
		summary = worldSummary,
		player = nil,
		record = nil,
		lifeBinding = nil,
		lifeSummary = nil,
		entityTrajectoryBase = Vector3.zero,
		projectileInflictor = nil,
		projectileInflictorSummary = nil,
	}
	local runtime = {} :: Runtime

	function runtime:SetProjectileAdapter(value: unknown)
		assert(projectileAdapter == nil, "projectile death-source adapter is already configured")
		projectileAdapter = validateProjectileAdapter(value)
	end

	function runtime:GetWorld(): (Source, Summary)
		return worldSource, worldSummary
	end

	function runtime:CapturePlayer(capture: PlayerCapture): (Source, Summary)
		local source = table.freeze({}) :: Source
		local summary = table.freeze({
			kind = "Player",
			player = capture.player,
			lifeBinding = capture.lifeBinding,
			lifeSummary = capture.lifeSummary,
			entityTrajectoryBase = capture.entityTrajectoryBase,
		}) :: Summary
		capabilities[source] = {
			source = source,
			summary = summary,
			player = capture.player,
			record = capture.record,
			lifeBinding = capture.lifeBinding,
			lifeSummary = capture.lifeSummary,
			entityTrajectoryBase = capture.entityTrajectoryBase,
			projectileInflictor = nil,
			projectileInflictorSummary = nil,
		}
		return source, summary
	end

	function runtime:CaptureProjectile(value: unknown): (Source?, Summary?, string?)
		local adapter = projectileAdapter
		if not adapter then
			return nil, nil, "normal-to-dead-projectile-source-adapter-unavailable"
		end
		local inflictor, inflictorSummary, captureError = adapter.Capture(value)
		if not inflictor or not inflictorSummary then
			return nil, nil, captureError or "invalid-normal-to-dead-projectile-source"
		end
		if
			type(inflictor) ~= "table"
			or type(inflictorSummary) ~= "table"
			or getmetatable(inflictor) ~= nil
			or getmetatable(inflictorSummary) ~= nil
			or not table.isfrozen(inflictor :: table)
			or not table.isfrozen(inflictorSummary :: table)
		then
			return nil, nil, "invalid-normal-to-dead-projectile-provider-proof"
		end
		local valid, validationError = adapter.Validate(inflictor, inflictorSummary)
		if not valid then
			return nil, nil, validationError or "stale-normal-to-dead-projectile-provider-proof"
		end
		local rawSummary = inflictorSummary :: { [unknown]: unknown }
		local trajectoryValue = rawget(rawSummary, "trajectoryBase")
		if rawget(rawSummary, "phase") ~= "Missile" or typeof(trajectoryValue) ~= "Vector3" then
			return nil, nil, "invalid-normal-to-dead-projectile-provider-summary"
		end
		local trajectory = trajectoryValue :: Vector3
		if not isFinite(trajectory.X) or not isFinite(trajectory.Y) or not isFinite(trajectory.Z) then
			return nil, nil, "invalid-normal-to-dead-projectile-trajectory-base"
		end
		local source = table.freeze({}) :: Source
		local summary = table.freeze({
			kind = "Projectile",
			player = nil,
			lifeBinding = nil,
			lifeSummary = nil,
			entityTrajectoryBase = trajectory,
		}) :: Summary
		capabilities[source] = {
			source = source,
			summary = summary,
			player = nil,
			record = nil,
			lifeBinding = nil,
			lifeSummary = nil,
			entityTrajectoryBase = trajectory,
			projectileInflictor = inflictor,
			projectileInflictorSummary = inflictorSummary,
		}
		return source, summary, nil
	end

	function runtime:Current(
		sourceValue: unknown,
		summaryValue: unknown,
		validateExternalLife: boolean,
		validatePlayer: PlayerValidator
	): (Capability?, string?)
		if type(sourceValue) ~= "table" or type(summaryValue) ~= "table" then
			return nil, "invalid-normal-to-dead-source-dependency"
		end
		local source = sourceValue :: Source
		local capability = capabilities[source]
		if not capability or capability.source ~= source then
			return nil, "invalid-normal-to-dead-source"
		end
		if capability.summary ~= summaryValue then
			return nil, "forged-normal-to-dead-source-summary"
		end
		local summary = summaryValue :: Summary
		if
			not table.isfrozen(source)
			or not table.isfrozen(summary)
			or summary.entityTrajectoryBase ~= capability.entityTrajectoryBase
		then
			return nil, "stale-normal-to-dead-source"
		end
		if summary.kind == "Projectile" then
			local adapter = projectileAdapter
			if
				capability.player ~= nil
				or capability.record ~= nil
				or capability.lifeBinding ~= nil
				or capability.lifeSummary ~= nil
				or capability.projectileInflictor == nil
				or capability.projectileInflictorSummary == nil
				or summary.player ~= nil
				or summary.lifeBinding ~= nil
				or summary.lifeSummary ~= nil
				or not adapter
			then
				return nil, "stale-normal-to-dead-projectile-source"
			end
			if validateExternalLife then
				local valid =
					select(1, adapter.Validate(capability.projectileInflictor, capability.projectileInflictorSummary))
				if not valid then
					return nil, "stale-normal-to-dead-projectile-source-provider"
				end
			end
			return capability, nil
		end
		if capability.player == nil then
			if source ~= worldSource or summary ~= worldSummary or summary.kind ~= "World" then
				return nil, "stale-normal-to-dead-world-source"
			end
			return capability, nil
		end
		local valid, validationError = validatePlayer(capability, validateExternalLife)
		if not valid then
			return nil, validationError or "stale-normal-to-dead-player-source"
		end
		return capability, nil
	end

	function runtime:Inspect(sourceValue: unknown, validatePlayer: PlayerValidator): Summary?
		if type(sourceValue) ~= "table" then
			return nil
		end
		local capability = capabilities[sourceValue :: Source]
		if not capability then
			return nil
		end
		local current = select(1, runtime:Current(sourceValue, capability.summary, true, validatePlayer))
		return if current then capability.summary else nil
	end

	return runtime
end

return table.freeze(MovementNormalToDeadSourceRuntime)
