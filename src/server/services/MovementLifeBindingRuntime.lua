--!strict

local MovementLifeBindingRuntime = {}

export type Binding = {}
export type Summary = {
	read player: Player,
	read playerUserId: number,
	read character: Model,
	read recordLineage: {},
	read registration: any,
	read playerBodyId: string,
	read playerSourceOrder: number,
	read playerLeaseGeneration: number,
	read lifeSequence: number,
}
export type Capability = {
	handle: Binding,
	status: "Current" | "Invalidated",
	player: Player,
	record: unknown,
	character: Model,
	registration: any,
	summary: Summary,
}
export type MintRequest = {
	player: Player,
	record: unknown,
	character: Model,
	recordLineage: {},
	registration: any,
	lifeSequence: number,
}
export type Runtime = {
	Mint: (self: Runtime, MintRequest) -> (Binding, Summary, Capability),
	Get: (self: Runtime, unknown) -> Capability?,
	SummaryMatches: (self: Runtime, Capability, unknown) -> boolean,
	Invalidate: (self: Runtime, unknown, unknown) -> boolean,
}

function MovementLifeBindingRuntime.new(): Runtime
	local capabilities = setmetatable({}, { __mode = "k" }) :: { [Binding]: Capability }
	local bindingsBySummary = setmetatable({}, { __mode = "k" }) :: { [Summary]: Binding }
	local runtime = {} :: Runtime

	function runtime:Mint(request: MintRequest): (Binding, Summary, Capability)
		local registration = request.registration
		local summary = table.freeze({
			player = request.player,
			playerUserId = request.player.UserId,
			character = request.character,
			recordLineage = request.recordLineage,
			registration = registration,
			playerBodyId = registration.bodyId,
			playerSourceOrder = registration.sourceOrder,
			playerLeaseGeneration = registration.generation,
			lifeSequence = request.lifeSequence,
		}) :: Summary
		local handle = table.freeze({}) :: Binding
		local capability: Capability = {
			handle = handle,
			status = "Current",
			player = request.player,
			record = request.record,
			character = request.character,
			registration = registration,
			summary = summary,
		}
		capabilities[handle] = capability
		bindingsBySummary[summary] = handle
		return handle, summary, capability
	end

	function runtime:Get(value: unknown): Capability?
		if type(value) ~= "table" then
			return nil
		end
		local handle = value :: Binding
		local capability = capabilities[handle]
		return if capability and capability.handle == value then capability else nil
	end

	function runtime:SummaryMatches(capability: Capability, value: unknown): boolean
		return type(value) == "table"
			and value == capability.summary
			and bindingsBySummary[capability.summary] == capability.handle
	end

	function runtime:Invalidate(value: unknown, record: unknown): boolean
		local capability = runtime:Get(value)
		if not capability or capability.record ~= record then
			return false
		end
		capability.status = "Invalidated"
		bindingsBySummary[capability.summary] = nil
		capabilities[capability.handle] = nil
		return true
	end

	return runtime
end

return table.freeze(MovementLifeBindingRuntime)
