--[[
One-Shot is the original-IP-safe public identity for this project's Instagib
rules translation.

The gameplay contract is mapped from:
  .reference/instagib/README.md at
    9ad7ffd5c40e1452a00e08343977cd3329030f00
    (one-hit opponents, environment suppression, independent rail-jump
    cooldown, and rail cooldown reset after a resolved kill)
  code/game/g_combat.c (opponent damage, knockback, and player_die ordering)
  code/game/g_weapon.c (Railgun trace and surface endpoint)

The referenced repository describes the intended rules but does not contain a
finished alternate-fire implementation. The bounded values below are this
project's reviewed server-authoritative translation.
]]

--!strict

local OneShotRules = {}

local RAIL_JUMP_COOLDOWN_MILLISECONDS = 800
local RAIL_JUMP_RANGE_Q3 = 64
local RAIL_JUMP_VERTICAL_BIAS_Q3 = 24
local RAIL_JUMP_KNOCKBACK_DAMAGE = 100

local function finiteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

function OneShotRules.ResolveHealthDamage(
	enabled: unknown,
	areOpponents: unknown,
	currentHealth: unknown,
	resolvedHealthDamage: unknown
): number?
	if
		type(enabled) ~= "boolean"
		or type(areOpponents) ~= "boolean"
		or not finiteNumber(currentHealth)
		or not finiteNumber(resolvedHealthDamage)
		or (currentHealth :: number) <= 0
		or (resolvedHealthDamage :: number) < 0
	then
		return nil
	end
	if enabled and areOpponents and (resolvedHealthDamage :: number) > 0 then
		return currentHealth :: number
	end
	return resolvedHealthDamage :: number
end

function OneShotRules.AllowsWorldDamage(enabled: unknown): boolean?
	if type(enabled) ~= "boolean" then
		return nil
	end
	return not (enabled :: boolean)
end

function OneShotRules.AllowsForcedEnvironmentElimination(enabled: unknown, means: unknown): boolean?
	if type(enabled) ~= "boolean" or type(means) ~= "string" then
		return nil
	end
	return not (enabled :: boolean) or means == "Void"
end

function OneShotRules.ResolveCrushHealthDamage(
	enabled: unknown,
	currentHealth: unknown,
	resolvedHealthDamage: unknown
): number?
	if
		type(enabled) ~= "boolean"
		or not finiteNumber(currentHealth)
		or not finiteNumber(resolvedHealthDamage)
		or (currentHealth :: number) <= 0
		or (resolvedHealthDamage :: number) < 0
	then
		return nil
	end
	-- The One-Shot reference treats crushing as a killswitch while forbidding
	-- partial damage. Any positive source-authored mover damage is therefore
	-- promoted to the victim's remaining health; zero-damage blockers stay inert.
	if enabled and (resolvedHealthDamage :: number) > 0 then
		return currentHealth :: number
	end
	return resolvedHealthDamage :: number
end

function OneShotRules.ShouldResetRailCooldown(
	enabled: unknown,
	attackerUserId: unknown,
	targetUserId: unknown,
	scoringUserId: unknown,
	weaponId: unknown,
	railgunId: unknown
): boolean?
	if
		type(enabled) ~= "boolean"
		or not finiteNumber(attackerUserId)
		or not finiteNumber(targetUserId)
		or not finiteNumber(scoringUserId)
		or not finiteNumber(weaponId)
		or not finiteNumber(railgunId)
	then
		return nil
	end
	for _, value in
		{
			attackerUserId :: number,
			targetUserId :: number,
			scoringUserId :: number,
			weaponId :: number,
			railgunId :: number,
		}
	do
		if value % 1 ~= 0 then
			return nil
		end
	end
	return (enabled :: boolean)
		and attackerUserId ~= targetUserId
		and scoringUserId == attackerUserId
		and weaponId == railgunId
end

function OneShotRules.CanAttemptRailJump(
	enabled: unknown,
	alive: unknown,
	useHeld: unknown,
	previousUseHeld: unknown,
	activeWeaponId: unknown,
	railgunId: unknown,
	levelTimeMilliseconds: unknown,
	readyAtMilliseconds: unknown
): boolean?
	if
		type(enabled) ~= "boolean"
		or type(alive) ~= "boolean"
		or type(useHeld) ~= "boolean"
		or type(previousUseHeld) ~= "boolean"
		or not finiteNumber(activeWeaponId)
		or not finiteNumber(railgunId)
		or not finiteNumber(levelTimeMilliseconds)
		or not finiteNumber(readyAtMilliseconds)
	then
		return nil
	end
	for _, value in
		{
			activeWeaponId :: number,
			railgunId :: number,
			levelTimeMilliseconds :: number,
			readyAtMilliseconds :: number,
		}
	do
		if value % 1 ~= 0 then
			return nil
		end
	end
	return (enabled :: boolean)
		and (alive :: boolean)
		and (useHeld :: boolean)
		and not (previousUseHeld :: boolean)
		and activeWeaponId == railgunId
		and levelTimeMilliseconds >= readyAtMilliseconds
end

function OneShotRules.RailJumpReadyAt(levelTimeMilliseconds: unknown): number?
	if
		not finiteNumber(levelTimeMilliseconds)
		or (levelTimeMilliseconds :: number) % 1 ~= 0
		or (levelTimeMilliseconds :: number) < 0
	then
		return nil
	end
	return (levelTimeMilliseconds :: number) + RAIL_JUMP_COOLDOWN_MILLISECONDS
end

function OneShotRules.RailJumpRangeStuds(unitsToStuds: unknown): number?
	if not finiteNumber(unitsToStuds) or (unitsToStuds :: number) <= 0 then
		return nil
	end
	return RAIL_JUMP_RANGE_Q3 * (unitsToStuds :: number)
end

function OneShotRules.ResolveRailJumpDirection(
	playerOrigin: unknown,
	surfacePosition: unknown,
	unitsToStuds: unknown
): Vector3?
	if
		typeof(playerOrigin) ~= "Vector3"
		or typeof(surfacePosition) ~= "Vector3"
		or not finiteNumber(unitsToStuds)
		or (unitsToStuds :: number) <= 0
	then
		return nil
	end
	local direction = (playerOrigin :: Vector3)
		- (surfacePosition :: Vector3)
		+ Vector3.new(0, RAIL_JUMP_VERTICAL_BIAS_Q3 * (unitsToStuds :: number), 0)
	if direction.Magnitude <= 1e-6 then
		return nil
	end
	return direction.Unit
end

OneShotRules.RailJumpCooldownMilliseconds = RAIL_JUMP_COOLDOWN_MILLISECONDS
OneShotRules.RailJumpRangeQ3 = RAIL_JUMP_RANGE_Q3
OneShotRules.RailJumpVerticalBiasQ3 = RAIL_JUMP_VERTICAL_BIAS_Q3
OneShotRules.RailJumpKnockbackDamage = RAIL_JUMP_KNOCKBACK_DAMAGE

return table.freeze(OneShotRules)
