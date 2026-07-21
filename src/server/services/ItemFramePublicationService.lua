--[[
SPDX-License-Identifier: GPL-2.0-or-later

Item-owned exact-frame publication buffer. Item authority remains private in
ItemService; this owner holds immutable outward callbacks and uncommitted Parts.

Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local ItemFramePublicationService = {}

local activeFrame: unknown = nil
local pendingOwner: unknown = nil
local callbacks: { () -> () } = {}
local quarantined = false
local pendingParts: { [BasePart]: boolean } = {}
local pendingRetirements: { [BasePart]: boolean } = {}

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

function ItemFramePublicationService.IsOpen(): boolean
	return activeFrame ~= nil
end

function ItemFramePublicationService.Snapshot(value: any): any
	return cloneFrozen(value)
end

function ItemFramePublicationService.Queue(callback: () -> ())
	assert(not quarantined, "Item outward publication is permanently quarantined")
	if activeFrame ~= nil then
		table.insert(callbacks, callback)
	else
		callback()
	end
end

function ItemFramePublicationService.Begin(frame: unknown)
	assert(not quarantined, "Item outward publication is permanently quarantined")
	assert(frame ~= nil and activeFrame == nil, "Item publication frame is invalid")
	assert(pendingOwner == nil and #callbacks == 0, "Item publication callbacks survived")
	activeFrame = frame
end

function ItemFramePublicationService.Seal(frame: unknown): () -> ()
	assert(activeFrame == frame, "Item publication owner changed during frame")
	pendingOwner = frame
	activeFrame = nil
	return function()
		ItemFramePublicationService.Flush(frame)
	end
end

function ItemFramePublicationService.Flush(frame: unknown)
	assert(not quarantined, "Item outward publication is permanently quarantined")
	assert(pendingOwner ~= nil and pendingOwner == frame, "stale Item publication flush")
	local queued = callbacks
	callbacks = {}
	pendingOwner = nil
	local failed = false
	for _, callback in queued do
		if not pcall(callback) then
			failed = true
		end
	end
	assert(not failed, "Item outward publication failed")
end

function ItemFramePublicationService.TrackPart(part: BasePart, parent: Instance)
	if activeFrame == nil then
		part.Parent = parent
		return
	end
	pendingParts[part] = true
	ItemFramePublicationService.Queue(function()
		if pendingParts[part] then
			pendingParts[part] = nil
			part.Parent = parent
		end
	end)
end

function ItemFramePublicationService.RetirePart(part: BasePart)
	pendingParts[part] = nil
	if activeFrame ~= nil and part.Parent ~= nil then
		pendingRetirements[part] = true
		ItemFramePublicationService.Queue(function()
			if pendingRetirements[part] then
				pendingRetirements[part] = nil
				part:Destroy()
			end
		end)
	else
		pendingRetirements[part] = nil
		part:Destroy()
	end
end

function ItemFramePublicationService.Quarantine()
	if quarantined then
		return
	end
	quarantined = true
	activeFrame = nil
	pendingOwner = nil
	callbacks = {}
	for part in pendingParts do
		pendingParts[part] = nil
		pcall(function()
			part:Destroy()
		end)
	end
	for part in pendingRetirements do
		pendingRetirements[part] = nil
		pcall(function()
			part:Destroy()
		end)
	end
end

return table.freeze(ItemFramePublicationService)
