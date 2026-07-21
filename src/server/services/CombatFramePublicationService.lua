--[[
SPDX-License-Identifier: GPL-2.0-or-later

Combat-owned post-close publication buffer. CombatService retains authority;
this module owns only immutable outward snapshots, exact-frame flush identity,
and uncommitted projectile presentation Parts.

Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local CombatFramePublicationService = {}

local activeFrame: unknown = nil
local pendingOwner: unknown = nil
local pendingCallbacks: { () -> () } = {}
local quarantined = false
local pendingProjectileParts: { [Part]: boolean } = {}
local pendingProjectileRetirements: { [Part]: boolean } = {}

local function cloneFrozen(value: any, seen: { [table]: table }?): any
	if type(value) ~= "table" then
		return value
	end
	local copies = seen or {}
	local existing = copies[value]
	if existing then
		return existing
	end
	local copy = {}
	copies[value] = copy
	for key, child in value do
		copy[cloneFrozen(key, copies)] = cloneFrozen(child, copies)
	end
	return table.freeze(copy)
end

function CombatFramePublicationService.IsOpen(): boolean
	return activeFrame ~= nil
end

function CombatFramePublicationService.Snapshot(value: any): any
	return cloneFrozen(value)
end

function CombatFramePublicationService.Queue(callback: () -> ())
	assert(not quarantined, "Combat outward publication is permanently quarantined")
	if activeFrame ~= nil then
		table.insert(pendingCallbacks, callback)
	else
		callback()
	end
end

function CombatFramePublicationService.Begin(frame: unknown)
	assert(not quarantined, "Combat outward publication is permanently quarantined")
	assert(frame ~= nil, "Combat publication frame is unavailable")
	assert(activeFrame == nil, "Combat publication frame is already active")
	assert(pendingOwner == nil and #pendingCallbacks == 0, "Combat publication callbacks survived their owning frame")
	activeFrame = frame
end

function CombatFramePublicationService.Seal(frame: unknown): () -> ()
	assert(activeFrame == frame, "Combat publication owner changed during frame")
	pendingOwner = frame
	activeFrame = nil
	return function()
		CombatFramePublicationService.Flush(frame)
	end
end

function CombatFramePublicationService.Flush(frame: unknown)
	assert(not quarantined, "Combat outward publication is permanently quarantined")
	assert(
		pendingOwner ~= nil and frame == pendingOwner,
		"Combat publication flush received a stale authoritative frame"
	)
	local callbacks = pendingCallbacks
	pendingCallbacks = {}
	pendingOwner = nil

	local allSucceeded = true
	for _, callback in callbacks do
		if not pcall(callback) then
			allSucceeded = false
		end
	end
	assert(allSucceeded, "Combat outward publication failed")
end

function CombatFramePublicationService.TrackProjectilePart(part: Part, folder: Folder)
	if activeFrame == nil then
		part.Parent = folder
		return
	end
	pendingProjectileParts[part] = true
	CombatFramePublicationService.Queue(function()
		if pendingProjectileParts[part] then
			pendingProjectileParts[part] = nil
			part.Parent = folder
		end
	end)
end

function CombatFramePublicationService.IsProjectilePartPending(part: Part): boolean
	return pendingProjectileParts[part] == true
end

function CombatFramePublicationService.ForgetProjectilePart(part: Part)
	pendingProjectileParts[part] = nil
	pendingProjectileRetirements[part] = nil
end

function CombatFramePublicationService.RetireProjectilePart(part: Part)
	pendingProjectileParts[part] = nil
	if activeFrame ~= nil and part.Parent ~= nil then
		pendingProjectileRetirements[part] = true
		CombatFramePublicationService.Queue(function()
			if pendingProjectileRetirements[part] then
				pendingProjectileRetirements[part] = nil
				part:Destroy()
			end
		end)
	else
		pendingProjectileRetirements[part] = nil
		part:Destroy()
	end
end

function CombatFramePublicationService.Quarantine()
	if quarantined then
		return
	end
	quarantined = true
	activeFrame = nil
	pendingOwner = nil
	pendingCallbacks = {}
	for part in pendingProjectileParts do
		pendingProjectileParts[part] = nil
		pcall(function()
			part:Destroy()
		end)
	end
	for part in pendingProjectileRetirements do
		pendingProjectileRetirements[part] = nil
		pcall(function()
			part:Destroy()
		end)
	end
end

return table.freeze(CombatFramePublicationService)
