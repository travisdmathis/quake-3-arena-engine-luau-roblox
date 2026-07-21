--[[
SPDX-License-Identifier: GPL-2.0-or-later

BodyQueue-owned exact-frame publication buffer. Corpse collision and lifecycle
remain private authority; replicated rig creation, movement, and retirement are
released only after the authoritative frame closes successfully.

Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local BodyQueueFramePublicationService = {}

local activeFrame: unknown = nil
local pendingOwner: unknown = nil
local callbacks: { () -> () } = {}
local quarantined = false

function BodyQueueFramePublicationService.IsOpen(): boolean
	return activeFrame ~= nil
end

function BodyQueueFramePublicationService.Queue(callback: () -> ())
	assert(not quarantined, "BodyQueue outward publication is permanently quarantined")
	if activeFrame ~= nil then
		table.insert(callbacks, callback)
	else
		callback()
	end
end

function BodyQueueFramePublicationService.Begin(frame: unknown)
	assert(not quarantined, "BodyQueue outward publication is permanently quarantined")
	assert(frame ~= nil and activeFrame == nil, "BodyQueue publication frame is invalid")
	assert(pendingOwner == nil and #callbacks == 0, "BodyQueue publication callbacks survived their owning frame")
	activeFrame = frame
end

function BodyQueueFramePublicationService.Seal(frame: unknown): () -> ()
	assert(activeFrame == frame, "BodyQueue publication owner changed during frame")
	pendingOwner = frame
	activeFrame = nil
	return function()
		BodyQueueFramePublicationService.Flush(frame)
	end
end

function BodyQueueFramePublicationService.Flush(frame: unknown)
	assert(not quarantined, "BodyQueue outward publication is permanently quarantined")
	assert(pendingOwner ~= nil and pendingOwner == frame, "stale BodyQueue publication flush")
	local queued = callbacks
	callbacks = {}
	pendingOwner = nil
	local failed = false
	for _, callback in queued do
		if not pcall(callback) then
			failed = true
		end
	end
	assert(not failed, "BodyQueue outward publication failed")
end

function BodyQueueFramePublicationService.Quarantine()
	if quarantined then
		return
	end
	quarantined = true
	activeFrame = nil
	pendingOwner = nil
	callbacks = {}
end

return table.freeze(BodyQueueFramePublicationService)
