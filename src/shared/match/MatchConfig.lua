--!strict

local WeaponDefinitions = require(script.Parent.Parent.combat.WeaponDefinitions)
local MapRuntimeContract = require(script.Parent.Parent.maps.MapRuntimeContract)
local ModeIds = require(script.Parent.ModeIds)

export type State = "Waiting" | "Warmup" | "Countdown" | "Live" | "Intermission"
export type ModeId = ModeIds.ModeId
export type ModeKind = "Deathmatch" | "TeamDeathmatch" | "CaptureTheFlag" | "RoundElimination"
export type ScoreType = "PlayerFrags" | "TeamFrags" | "Captures" | "RoundWins"
export type TeamId = "Red" | "Blue"

export type Rules = {
	read ModeId: ModeId,
	read RulesetId: ModeId,
	read DisplayName: string,
	read ModeKind: ModeKind,
	read ScoreType: ScoreType,
	read MinimumPlayers: number,
	read ActivePlayerLimit: number,
	read AllowSoloInStudio: boolean,
	read WarmupSeconds: number,
	read CountdownSeconds: number,
	read RoundBreakSeconds: number,
	read RoundCountdownSeconds: number,
	read TimeLimitSeconds: number,
	read ScoreLimit: number,
	read RoundWinLimit: number,
	read IntermissionSeconds: number,
	read RespawnDelaySeconds: number,
	read ForcedRespawnSeconds: number,
	read SnapshotIntervalSeconds: number,
	read CombatStates: { [State]: boolean },
	read ScoringStates: { [State]: boolean },
	read OneShot: boolean,
	read Deathmatch: boolean,
	read Duel: boolean,
	read CaptureTheFlag: boolean,
	read TeamMode: boolean,
	read RoundBased: boolean,
	read FriendlyFire: boolean,
	read ImmediateRespawn: boolean,
	read RespawnDuringLive: boolean,
	read ArmorEnabled: boolean,
	read PickupsEnabled: boolean,
	read DeathWeaponDrops: boolean,
	read InfiniteAmmo: boolean,
	read SelfHealthDamageProtected: boolean,
	read MaximumHealth: number,
	read SpawnHealth: number,
	read SpawnArmor: number,
	read SpawnWeaponId: number,
	read AllowedWeaponIds: { [number]: boolean },
	read SpawnAmmoByWeaponId: { [number]: number },
	read RequiredMapCapabilities: { MapRuntimeContract.Capability },
}

local States = table.freeze({
	Waiting = "Waiting" :: State,
	Warmup = "Warmup" :: State,
	Countdown = "Countdown" :: State,
	Live = "Live" :: State,
	Intermission = "Intermission" :: State,
})

local TeamIds = table.freeze({
	Red = "Red" :: TeamId,
	Blue = "Blue" :: TeamId,
})

local Teams = table.freeze({
	[TeamIds.Red] = table.freeze({
		Id = TeamIds.Red,
		DisplayName = "RED",
	}),
	[TeamIds.Blue] = table.freeze({
		Id = TeamIds.Blue,
		DisplayName = "BLUE",
	}),
})

local function makeStateMap(combatInWarmup: boolean): { [State]: boolean }
	local stateMap: { [State]: boolean } = {
		[States.Waiting] = false,
		[States.Warmup] = combatInWarmup,
		[States.Countdown] = false,
		[States.Live] = true,
		[States.Intermission] = false,
	}
	table.freeze(stateMap)
	return stateMap
end

local function makeScoringMap(): { [State]: boolean }
	local stateMap: { [State]: boolean } = {
		[States.Waiting] = false,
		[States.Warmup] = false,
		[States.Countdown] = false,
		[States.Live] = true,
		[States.Intermission] = false,
	}
	table.freeze(stateMap)
	return stateMap
end

local function makeWeaponMap(weaponIds: { number }): { [number]: boolean }
	local allowed: { [number]: boolean } = {}
	for _, weaponId in weaponIds do
		allowed[weaponId] = true
	end
	table.freeze(allowed)
	return allowed
end

local function makeAmmoMap(entries: { [number]: number }): { [number]: number }
	local ammoByWeaponId: { [number]: number } = table.clone(entries)
	table.freeze(ammoByWeaponId)
	return ammoByWeaponId
end

local function makeRules(definition: Rules): Rules
	table.freeze(definition)
	return definition
end

local railgunId: number = WeaponDefinitions.WeaponId.Railgun
local rocketLauncherId: number = WeaponDefinitions.WeaponId.RocketLauncher
local machinegunId: number = WeaponDefinitions.WeaponId.Machinegun
local gauntletId: number = WeaponDefinitions.WeaponId.Gauntlet
local oneShotWeapons = makeWeaponMap({
	gauntletId,
	railgunId,
})
local coreWeapons = makeWeaponMap(WeaponDefinitions.CoreWeaponIds)
local rocketArenaWeapons = makeWeaponMap({
	WeaponDefinitions.WeaponId.Gauntlet,
	WeaponDefinitions.WeaponId.Machinegun,
	WeaponDefinitions.WeaponId.Shotgun,
	WeaponDefinitions.WeaponId.GrenadeLauncher,
	WeaponDefinitions.WeaponId.RocketLauncher,
	WeaponDefinitions.WeaponId.LightningGun,
	WeaponDefinitions.WeaponId.Railgun,
	WeaponDefinitions.WeaponId.PlasmaGun,
})
local defaultSpawnAmmo = makeAmmoMap({})
-- q3ra3-server arena/arena.cfg plus ra3_176_decomp arena.c::give_weapons.
-- The Gauntlet remains ammo-free; the seven finite-ammo weapons use the
-- server's live-round defaults instead of the warmup-only -1 sentinel.
local rocketArenaSpawnAmmo = makeAmmoMap({
	[WeaponDefinitions.WeaponId.Machinegun] = 200,
	[WeaponDefinitions.WeaponId.Shotgun] = 100,
	[WeaponDefinitions.WeaponId.GrenadeLauncher] = 20,
	[WeaponDefinitions.WeaponId.RocketLauncher] = 50,
	[WeaponDefinitions.WeaponId.LightningGun] = 150,
	[WeaponDefinitions.WeaponId.Railgun] = 50,
	[WeaponDefinitions.WeaponId.PlasmaGun] = 100,
})
local combatMapCapabilities = table.freeze({
	MapRuntimeContract.Capabilities.CombatSpawns,
})
local teamMapCapabilities = table.freeze({
	MapRuntimeContract.Capabilities.CombatSpawns,
	MapRuntimeContract.Capabilities.TeamSpawns,
})
local ctfMapCapabilities = table.freeze({
	MapRuntimeContract.Capabilities.CombatSpawns,
	MapRuntimeContract.Capabilities.TeamSpawns,
	MapRuntimeContract.Capabilities.FlagBases,
})

-- Q3 GT_FFA: every active client is a distinct scoring side, ordinary combat
-- spawns remain available to late joins and respawns, and no Duel rotation or
-- team/objective state participates. Eight is this engine's active-player cap.
local Deathmatch = makeRules({
	ModeId = ModeIds.Deathmatch,
	RulesetId = ModeIds.Deathmatch,
	DisplayName = "DEATHMATCH",
	ModeKind = "Deathmatch",
	ScoreType = "PlayerFrags",
	MinimumPlayers = 2,
	ActivePlayerLimit = 8,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 3,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 3,
	TimeLimitSeconds = 600,
	ScoreLimit = 20,
	RoundWinLimit = 0,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = false,
	Deathmatch = true,
	Duel = false,
	CaptureTheFlag = false,
	TeamMode = false,
	RoundBased = false,
	FriendlyFire = true,
	ImmediateRespawn = true,
	RespawnDuringLive = true,
	ArmorEnabled = true,
	PickupsEnabled = true,
	DeathWeaponDrops = true,
	InfiniteAmmo = false,
	SelfHealthDamageProtected = false,
	MaximumHealth = 100,
	SpawnHealth = 125,
	SpawnArmor = 0,
	SpawnWeaponId = machinegunId,
	AllowedWeaponIds = coreWeapons,
	SpawnAmmoByWeaponId = defaultSpawnAmmo,
	RequiredMapCapabilities = combatMapCapabilities,
})

-- One-Shot is the original-IP-safe public identity for the project's
-- Instagib rules translation: eight-player FFA, Railgun + Gauntlet, no world
-- pickups/armor, and a 50-frag or ten-minute finish.
local OneShot = makeRules({
	ModeId = ModeIds.OneShot,
	RulesetId = ModeIds.OneShot,
	DisplayName = "ONE-SHOT",
	ModeKind = "Deathmatch",
	ScoreType = "PlayerFrags",
	MinimumPlayers = 2,
	ActivePlayerLimit = 8,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 3,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 3,
	TimeLimitSeconds = 600,
	ScoreLimit = 50,
	RoundWinLimit = 0,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = true,
	Deathmatch = false,
	Duel = false,
	CaptureTheFlag = false,
	TeamMode = false,
	RoundBased = false,
	FriendlyFire = true,
	ImmediateRespawn = true,
	RespawnDuringLive = true,
	ArmorEnabled = false,
	PickupsEnabled = false,
	DeathWeaponDrops = false,
	InfiniteAmmo = true,
	SelfHealthDamageProtected = false,
	MaximumHealth = 100,
	SpawnHealth = 100,
	SpawnArmor = 0,
	SpawnWeaponId = railgunId,
	AllowedWeaponIds = oneShotWeapons,
	SpawnAmmoByWeaponId = defaultSpawnAmmo,
	RequiredMapCapabilities = combatMapCapabilities,
})

local Duel = makeRules({
	ModeId = ModeIds.Duel,
	RulesetId = ModeIds.Duel,
	DisplayName = "DUEL",
	ModeKind = "Deathmatch",
	ScoreType = "PlayerFrags",
	MinimumPlayers = 2,
	ActivePlayerLimit = 2,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 3,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 3,
	TimeLimitSeconds = 600,
	ScoreLimit = 10,
	RoundWinLimit = 0,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = false,
	Deathmatch = false,
	Duel = true,
	CaptureTheFlag = false,
	TeamMode = false,
	RoundBased = false,
	FriendlyFire = true,
	ImmediateRespawn = true,
	RespawnDuringLive = true,
	ArmorEnabled = true,
	PickupsEnabled = true,
	DeathWeaponDrops = true,
	InfiniteAmmo = false,
	SelfHealthDamageProtected = false,
	MaximumHealth = 100,
	SpawnHealth = 125,
	SpawnArmor = 0,
	SpawnWeaponId = machinegunId,
	AllowedWeaponIds = coreWeapons,
	SpawnAmmoByWeaponId = defaultSpawnAmmo,
	RequiredMapCapabilities = combatMapCapabilities,
})

local TeamDeathmatch = makeRules({
	ModeId = ModeIds.TeamDeathmatch,
	RulesetId = ModeIds.TeamDeathmatch,
	DisplayName = "TEAM DEATHMATCH",
	ModeKind = "TeamDeathmatch",
	ScoreType = "TeamFrags",
	MinimumPlayers = 2,
	ActivePlayerLimit = 0,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 3,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 3,
	TimeLimitSeconds = 600,
	ScoreLimit = 25,
	RoundWinLimit = 0,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = false,
	Deathmatch = false,
	Duel = false,
	CaptureTheFlag = false,
	TeamMode = true,
	RoundBased = false,
	FriendlyFire = false,
	ImmediateRespawn = true,
	RespawnDuringLive = true,
	ArmorEnabled = true,
	PickupsEnabled = true,
	DeathWeaponDrops = true,
	InfiniteAmmo = false,
	SelfHealthDamageProtected = false,
	MaximumHealth = 100,
	SpawnHealth = 125,
	SpawnArmor = 0,
	SpawnWeaponId = machinegunId,
	AllowedWeaponIds = coreWeapons,
	SpawnAmmoByWeaponId = defaultSpawnAmmo,
	RequiredMapCapabilities = combatMapCapabilities,
})

local CaptureTheFlag = makeRules({
	ModeId = ModeIds.CaptureTheFlag,
	RulesetId = ModeIds.CaptureTheFlag,
	DisplayName = "CAPTURE THE FLAG",
	ModeKind = "CaptureTheFlag",
	ScoreType = "Captures",
	MinimumPlayers = 2,
	ActivePlayerLimit = 0,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 3,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 3,
	TimeLimitSeconds = 900,
	ScoreLimit = 8,
	RoundWinLimit = 0,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = false,
	Deathmatch = false,
	Duel = false,
	CaptureTheFlag = true,
	TeamMode = true,
	RoundBased = false,
	FriendlyFire = false,
	ImmediateRespawn = true,
	RespawnDuringLive = true,
	ArmorEnabled = true,
	PickupsEnabled = true,
	DeathWeaponDrops = true,
	InfiniteAmmo = false,
	SelfHealthDamageProtected = false,
	MaximumHealth = 100,
	SpawnHealth = 125,
	SpawnArmor = 0,
	SpawnWeaponId = machinegunId,
	AllowedWeaponIds = coreWeapons,
	SpawnAmmoByWeaponId = defaultSpawnAmmo,
	RequiredMapCapabilities = ctfMapCapabilities,
})

-- Arena Elimination is the original-IP-safe Rocket Arena rules translation:
-- full finite-ammo loadout, one life per Live round, and best-of-nine scoring.
local ArenaElimination = makeRules({
	ModeId = ModeIds.ArenaElimination,
	RulesetId = ModeIds.ArenaElimination,
	DisplayName = "ARENA ELIMINATION",
	ModeKind = "RoundElimination",
	ScoreType = "RoundWins",
	MinimumPlayers = 2,
	-- The reference server defaults to one player per team but permits each
	-- arena/profile to override that value. Matchmaking owns the team-size cap;
	-- the shared combat rules therefore remain valid for 1v1 and 2v2 servers.
	ActivePlayerLimit = 0,
	AllowSoloInStudio = true,
	WarmupSeconds = 8,
	CountdownSeconds = 10,
	RoundBreakSeconds = 3,
	RoundCountdownSeconds = 5,
	TimeLimitSeconds = 1800,
	ScoreLimit = 0,
	RoundWinLimit = 5,
	IntermissionSeconds = 8,
	RespawnDelaySeconds = 1.7,
	ForcedRespawnSeconds = 20,
	SnapshotIntervalSeconds = 0.25,
	CombatStates = makeStateMap(true),
	ScoringStates = makeScoringMap(),
	OneShot = false,
	Deathmatch = false,
	Duel = false,
	CaptureTheFlag = false,
	TeamMode = true,
	RoundBased = true,
	FriendlyFire = false,
	ImmediateRespawn = false,
	RespawnDuringLive = false,
	ArmorEnabled = true,
	PickupsEnabled = false,
	DeathWeaponDrops = false,
	InfiniteAmmo = false,
	-- q3ra3-server healthprotect=1 / PM_SELF_AND_TEAM. CheckArmor still
	-- consumes self-damage armor first because armorprotect=2 protects only a
	-- teammate, then the remaining self health damage is discarded.
	SelfHealthDamageProtected = true,
	MaximumHealth = 100,
	SpawnHealth = 100,
	SpawnArmor = 100,
	SpawnWeaponId = rocketLauncherId,
	AllowedWeaponIds = rocketArenaWeapons,
	SpawnAmmoByWeaponId = rocketArenaSpawnAmmo,
	RequiredMapCapabilities = teamMapCapabilities,
})

local ModeOrder: { ModeId } = {
	ModeIds.Deathmatch,
	ModeIds.OneShot,
	ModeIds.Duel,
	ModeIds.TeamDeathmatch,
	ModeIds.CaptureTheFlag,
	ModeIds.ArenaElimination,
}
table.freeze(ModeOrder)

local ById: { [string]: Rules } = {
	[ModeIds.Deathmatch] = Deathmatch,
	[ModeIds.OneShot] = OneShot,
	[ModeIds.Duel] = Duel,
	[ModeIds.TeamDeathmatch] = TeamDeathmatch,
	[ModeIds.CaptureTheFlag] = CaptureTheFlag,
	[ModeIds.ArenaElimination] = ArenaElimination,
}
table.freeze(ById)

local function validateRules(definition: Rules)
	assert(definition.ModeId == definition.RulesetId, "ModeId and RulesetId must remain identical")
	assert(definition.MinimumPlayers >= 2, "Production modes require at least two players")
	assert(
		definition.CountdownSeconds >= 0 and definition.RoundBreakSeconds >= 0 and definition.RoundCountdownSeconds >= 0,
		"Match countdown durations must remain nonnegative"
	)
	assert(
		definition.ActivePlayerLimit == 0 or definition.ActivePlayerLimit >= definition.MinimumPlayers,
		"An active-player limit cannot be smaller than the production minimum"
	)
	assert(
		definition.AllowedWeaponIds[definition.SpawnWeaponId] == true,
		"A mode's spawn weapon must be allowed by that mode"
	)
	assert(
		type(definition.SpawnAmmoByWeaponId) == "table" and table.isfrozen(definition.SpawnAmmoByWeaponId),
		"Spawn ammo overrides must be a frozen table"
	)
	for weaponId, ammo in definition.SpawnAmmoByWeaponId do
		local weapon = WeaponDefinitions.ById[weaponId]
		assert(
			definition.AllowedWeaponIds[weaponId] == true and weapon ~= nil,
			"Spawn ammo overrides require an allowed weapon"
		)
		assert(
			ammo % 1 == 0 and ammo >= 0 and ammo <= weapon.MaximumAmmo,
			"Spawn ammo overrides must be bounded nonnegative integers"
		)
	end
	assert(
		definition.MaximumHealth > 0 and definition.SpawnHealth >= definition.MaximumHealth,
		"Spawn health must be at least the positive maximum health"
	)
	assert(
		definition.ForcedRespawnSeconds >= definition.RespawnDelaySeconds,
		"Forced respawn cannot precede the minimum respawn delay"
	)
	assert(#definition.RequiredMapCapabilities > 0, "Every mode must declare at least one map capability")
	local seenCapabilities: { [string]: boolean } = {}
	for _, capability in definition.RequiredMapCapabilities do
		assert(
			MapRuntimeContract.IsCapability(capability),
			string.format("Unknown map capability %s", tostring(capability))
		)
		assert(not seenCapabilities[capability], "Map capabilities cannot be duplicated")
		seenCapabilities[capability] = true
	end
	if definition.RoundBased then
		assert(definition.RoundWinLimit > 0, "Round modes require a positive win limit")
		assert(not definition.RespawnDuringLive, "Round elimination cannot respawn during Live")
	else
		assert(definition.ScoreLimit > 0, "Frag modes require a positive score limit")
	end
	if definition.DeathWeaponDrops then
		assert(definition.PickupsEnabled, "Death weapon drops require pickups")
		assert(not definition.OneShot, "One-Shot cannot create finite-ammo weapon drops")
		assert(not definition.RoundBased, "Round elimination does not create weapon drops")
	end
	if definition.Duel then
		assert(definition.ActivePlayerLimit == 2, "Duel must reserve exactly two active slots")
		assert(not definition.TeamMode, "Duel players cannot share teams")
	end
	if definition.Deathmatch then
		assert(definition.ModeKind == "Deathmatch", "FFA must use Deathmatch rules")
		assert(definition.ScoreType == "PlayerFrags", "FFA must score individual frags")
		assert(definition.ActivePlayerLimit == 8, "FFA must reserve exactly eight active slots")
		assert(not definition.TeamMode, "FFA players cannot share teams")
		assert(not definition.Duel, "FFA cannot inherit Duel roster rotation")
		assert(not definition.OneShot, "FFA cannot inherit One-Shot weapon rules")
	end
	if definition.OneShot then
		assert(definition.ModeKind == "Deathmatch", "One-Shot must use Deathmatch rules")
		assert(definition.ScoreType == "PlayerFrags", "One-Shot must score individual frags")
		assert(definition.ActivePlayerLimit == 8, "One-Shot must reserve exactly eight active slots")
		assert(definition.TimeLimitSeconds == 600, "One-Shot must retain its ten-minute limit")
		assert(definition.ScoreLimit == 50, "One-Shot must retain its fifty-frag limit")
		assert(not definition.TeamMode, "One-Shot players cannot share teams")
		assert(not definition.ArmorEnabled, "One-Shot cannot enable armor")
		assert(not definition.PickupsEnabled, "One-Shot cannot enable pickups")
		assert(definition.InfiniteAmmo, "One-Shot must use infinite ammo")
		assert(
			definition.AllowedWeaponIds[gauntletId] and definition.AllowedWeaponIds[railgunId],
			"One-Shot must allow the Gauntlet and Railgun"
		)
	end
	if definition.CaptureTheFlag then
		assert(definition.TeamMode, "Capture the Flag requires teams")
		assert(definition.ScoreType == "Captures", "Capture the Flag must score captures")
	end
end

for _, modeId in ModeOrder do
	local definition = ById[modeId]
	assert(definition ~= nil, string.format("Missing rules for immutable mode %s", modeId))
	assert(definition.ModeId == modeId, string.format("Mode registry mismatch for %s", modeId))
	validateRules(definition)
end

local function getMode(modeId: string): Rules?
	return ById[modeId]
end

return table.freeze({
	States = States,
	ModeIds = ModeIds,
	ModeOrder = ModeOrder,
	TeamIds = TeamIds,
	Teams = Teams,
	Deathmatch = Deathmatch,
	OneShot = OneShot,
	Duel = Duel,
	TeamDeathmatch = TeamDeathmatch,
	CaptureTheFlag = CaptureTheFlag,
	ArenaElimination = ArenaElimination,
	ById = ById,
	GetMode = getMode,
	DefaultRuleset = OneShot,
})
