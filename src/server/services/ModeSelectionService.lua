--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local RemoteNames = require(sharedRoot:WaitForChild("RemoteNames"))
local ModeSelectionProtocol =
	require(sharedRoot:WaitForChild("match"):WaitForChild("ModeSelectionProtocol"))
local MatchRulesCore = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchRulesCore"))
local MatchService = require(script.Parent.MatchService)

local ModeSelectionService = {}

type RequestRecord = {
	windowStartedAt: number,
	windowCount: number,
	lastRequestAt: number,
	lastSequence: number,
}

type Response = {
	requestId: number,
	accepted: boolean,
	changed: boolean,
	code: string,
	message: string,
	modeId: string,
	state: string,
	snapshotSequence: number,
	serverTime: number,
	retryAfterSeconds: number,
}

local requestRecords: { [Player]: RequestRecord } = {}
local explicitlyAuthorizedUserIds: { [number]: boolean } = {}
local votesByUserId: { [number]: string } = {}
local started = false
local lastGlobalChangeAt = -math.huge
local REQUEST_PAYLOAD_KEYS = table.freeze({ sequence = true, modeId = true })

local function ensureNetworkFolder(): Folder
	local existing = sharedRoot:FindFirstChild(RemoteNames.Folder)
	if existing then
		assert(existing:IsA("Folder"), string.format("%s must be a Folder", RemoteNames.Folder))
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = RemoteNames.Folder
	folder.Parent = sharedRoot
	return folder
end

local function ensureRemoteFunction(folder: Folder, name: string): RemoteFunction
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteFunction"), string.format("%s must be a RemoteFunction", name))
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function isFiniteInteger(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
end

local function hasExactRequestKeys(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local observed = 0
	for key in value do
		if type(key) ~= "string" or REQUEST_PAYLOAD_KEYS[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == 2
end

local function isPlayerAuthorized(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	-- Paid private servers are owner-only. Reserved servers have an owner ID of zero and,
	-- like public servers, require an explicit grant from server code.
	if game.PrivateServerId ~= "" and game.PrivateServerOwnerId > 0 then
		return player.UserId == game.PrivateServerOwnerId
	end
	return explicitlyAuthorizedUserIds[player.UserId] == true
end

local function isPublicServer(): boolean
	return not RunService:IsStudio() and game.PrivateServerId == ""
end

local function countVotes(modeId: string): (number, number)
	local userIds: { number } = {}
	for _, candidate in Players:GetPlayers() do
		table.insert(userIds, candidate.UserId)
	end
	return MatchRulesCore.CountModeVotes(votesByUserId, userIds, modeId)
end

local function authoritativeResponse(
	requestId: number,
	accepted: boolean,
	changed: boolean,
	code: string,
	message: string,
	retryAfterSeconds: number?
): Response
	local snapshot = MatchService.GetSnapshot()
	return {
		requestId = requestId,
		accepted = accepted,
		changed = changed,
		code = code,
		message = message,
		modeId = snapshot.modeId,
		state = snapshot.state,
		snapshotSequence = snapshot.sequence,
		serverTime = Workspace:GetServerTimeNow(),
		retryAfterSeconds = math.max(retryAfterSeconds or 0, 0),
	}
end

local function consumeRateLimit(player: Player, now: number): (boolean, number)
	local record = requestRecords[player]
	if not record then
		record = {
			windowStartedAt = now,
			windowCount = 0,
			lastRequestAt = -math.huge,
			lastSequence = -1,
		}
		requestRecords[player] = record
	end

	if now - record.windowStartedAt >= ModeSelectionProtocol.RateWindowSeconds then
		record.windowStartedAt = now
		record.windowCount = 0
	end

	local intervalRemaining = ModeSelectionProtocol.MinimumRequestIntervalSeconds
		- (now - record.lastRequestAt)
	if intervalRemaining > 0 then
		return false, intervalRemaining
	end
	if record.windowCount >= ModeSelectionProtocol.MaximumRequestsPerWindow then
		return false, ModeSelectionProtocol.RateWindowSeconds - (now - record.windowStartedAt)
	end

	record.lastRequestAt = now
	record.windowCount += 1
	return true, 0
end

local function handleRequest(player: Player, payload: unknown): Response
	local requestId = 0
	if type(payload) == "table" then
		local untrustedRequest = payload :: any
		if isFiniteInteger(untrustedRequest.sequence) then
			requestId = untrustedRequest.sequence
		end
	end
	local now = os.clock()
	local withinLimit, retryAfter = consumeRateLimit(player, now)
	if not withinLimit then
		return authoritativeResponse(
			requestId,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.RateLimited,
			"Please wait before sending another mode request.",
			retryAfter
		)
	end

	if not hasExactRequestKeys(payload) then
		return authoritativeResponse(
			0,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.InvalidRequest,
			"The mode request was malformed."
		)
	end

	local untrustedRequest = payload :: any
	local sequence = untrustedRequest.sequence
	local modeId = untrustedRequest.modeId
	local record = assert(requestRecords[player], "Rate-limit record must exist after consumption")
	if
		not isFiniteInteger(sequence)
		or sequence < 0
		or sequence > ModeSelectionProtocol.MaximumSequence
		or sequence <= record.lastSequence
	then
		return authoritativeResponse(
			0,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.InvalidSequence,
			"The request sequence was invalid."
		)
	end
	local requestSequence = sequence :: number
	record.lastSequence = requestSequence

	if type(modeId) ~= "string" or not ModeSelectionProtocol.IsModeId(modeId) then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.UnknownMode,
			"That mode is not available."
		)
	end
	local requestedModeId: string = modeId
	local mapSupportsMode, mapUnavailableReason = MatchService.IsModeAvailable(requestedModeId)
	if not mapSupportsMode then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.SelectionFailed,
			mapUnavailableReason or "This map does not support that mode."
		)
	end
	local directlyAuthorized = isPlayerAuthorized(player)
	if not directlyAuthorized and not isPublicServer() then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.Unauthorized,
			"Only the private-server owner or a server-authorized player can change modes."
		)
	end

	local snapshot = MatchService.GetSnapshot()
	if snapshot.modeId == requestedModeId then
		return authoritativeResponse(
			requestSequence,
			true,
			false,
			ModeSelectionProtocol.ResponseCodes.AlreadySelected,
			"That mode is already active."
		)
	end
	if not ModeSelectionProtocol.IsSafeState(snapshot.state) then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.UnsafePhase,
			"Modes can only change while waiting, warming up, or between matches."
		)
	end

	local globalRemaining = ModeSelectionProtocol.GlobalChangeCooldownSeconds
		- (now - lastGlobalChangeAt)
	if globalRemaining > 0 then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.GlobalCooldown,
			"Another mode change just completed. Please wait.",
			globalRemaining
		)
	end

	local voteCount = 0
	local votesRequired = 0
	if not directlyAuthorized then
		votesByUserId = MatchRulesCore.RecordModeVote(votesByUserId, player.UserId, requestedModeId)
		voteCount, votesRequired = countVotes(requestedModeId)
		if voteCount < votesRequired then
			return authoritativeResponse(
				requestSequence,
				true,
				false,
				ModeSelectionProtocol.ResponseCodes.VoteRecorded,
				string.format(
					"Vote recorded for %s (%d/%d).",
					requestedModeId,
					voteCount,
					votesRequired
				)
			)
		end
	end

	local callSucceeded, selected, selectError = pcall(function()
		return MatchService.SelectMode(requestedModeId, "ModeSelection")
	end)
	if not callSucceeded or not selected then
		return authoritativeResponse(
			requestSequence,
			false,
			false,
			ModeSelectionProtocol.ResponseCodes.SelectionFailed,
			if callSucceeded and type(selectError) == "string"
				then selectError
				else "The server could not change modes."
		)
	end

	lastGlobalChangeAt = now
	table.clear(votesByUserId)
	return authoritativeResponse(
		requestSequence,
		true,
		true,
		ModeSelectionProtocol.ResponseCodes.Changed,
		if directlyAuthorized
			then "Mode changed by the server."
			else string.format("Vote passed (%d/%d). Mode changed.", voteCount, votesRequired)
	)
end

function ModeSelectionService.SetUserAuthorized(userId: number, authorized: boolean)
	assert(isFiniteInteger(userId) and userId > 0, "userId must be a positive integer")
	assert(type(authorized) == "boolean", "authorized must be a boolean")
	explicitlyAuthorizedUserIds[userId] = if authorized then true else nil
end

function ModeSelectionService.SetPlayerAuthorized(player: Player, authorized: boolean)
	ModeSelectionService.SetUserAuthorized(player.UserId, authorized)
end

function ModeSelectionService.IsPlayerAuthorized(player: Player): boolean
	return isPlayerAuthorized(player)
end

function ModeSelectionService.Start()
	assert(not started, "ModeSelectionService.Start may only be called once")
	started = true

	local network = ensureNetworkFolder()
	local requestRemote = ensureRemoteFunction(network, ModeSelectionProtocol.RequestRemoteName)
	requestRemote.OnServerInvoke = handleRequest
	Players.PlayerRemoving:Connect(function(player: Player)
		requestRecords[player] = nil
		votesByUserId[player.UserId] = nil
	end)
	MatchService.OnAuthorityModeChanged(function()
		table.clear(votesByUserId)
	end)
end

return table.freeze(ModeSelectionService)
