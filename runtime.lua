-- ===============================================================
--  runtime.draft.lua   (bot account executor script — WORK IN PROGRESS)
--  Combat: 4 connected M1s ragdoll a target (auto-target melee).
--  Model: reads a STATE doc from GitHub { mode, target } and engages
--  the target until mode flips to "idle" (Stop). Publishes the player
--  list LIVE to a Discord webhook (on start, on join/leave, + 15s
--  heartbeat) so the panel always has a fresh list to show as buttons.
--  JOIN is native (admin open-joins; bot joins via Roblox "Join").
-- ===============================================================

local Players      = game:GetService("Players")
local VIM          = game:GetService("VirtualInputManager")
local GuiService   = game:GetService("GuiService")
local HttpService  = game:GetService("HttpService")

local LP = Players.LocalPlayer

-- ===== STEP 0: ENABLE SHIFT LOCK (REQUIRED FOR M1) ============
-- MUST run before anything else or the bot can't punch at all.
-- Waits for the UI, reveals the ShiftLock button, and clicks it once.
do
	task.wait(5) -- wait for UI to fully load
	local FUDGE_X, FUDGE_Y = 0, 2
	local ok, err = pcall(function()
		local gui              = LP:WaitForChild("PlayerGui")
		local touchGui         = gui:WaitForChild("TouchGui")
		local touchControlFrame = touchGui:WaitForChild("TouchControlFrame")
		local jumpButton       = touchControlFrame:WaitForChild("JumpButton")
		local shiftLockButton  = jumpButton:WaitForChild("ShiftLockButton")

		shiftLockButton.Visible = true
		task.wait(0.1) -- let layout update

		local absPos = shiftLockButton.AbsolutePosition
		local absSize = shiftLockButton.AbsoluteSize
		local inset = GuiService:GetGuiInset()
		local x = absPos.X + absSize.X * 0.5 + inset.X + FUDGE_X
		local y = absPos.Y + absSize.Y * 0.5 + inset.Y + FUDGE_Y

		VIM:SendMouseButtonEvent(x, y, 0, true,  game, 0)
		task.wait(0.05)
		VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
		print(string.format("[bot] shift lock enabled — clicked (%.0f, %.0f)", x, y))
	end)
	if not ok then warn("[bot] shift lock enable FAILED (M1 may not work):", err) end
end

-- ===== CONFIG ==================================================
local PUNCH_OFFSET_X  = 0
local PUNCH_OFFSET_Y  = 8        -- your tuned value
local HITS_TO_RAGDOLL = 4        -- 4 M1s = ragdoll
local COMBO_INTERVAL  = 0.35     -- delay between M1s (combo timing)
-- hit-and-run positioning:
local SAFE_DEPTH      = 25       -- studs BELOW the target to hide (safe spot)
local BEHIND_DIST     = 3.5      -- studs behind the target when striking
local SAFE_TIME       = 1.0      -- seconds hidden under between combos

-- Admins (so only the bot in the admin's server answers list requests)
local ADMIN_IDS = {
	[2539358647] = true,
}

-- Webhook URL lives in a LOCAL file on the bot's machine (NOT in this
-- public script). Create a file with this name next to your executor and
-- put the webhook URL as its only contents:
-- Hardcoded webhook (write-only to one channel). Optional file override.
local WEBHOOK_URL_DEFAULT = "https://discord.com/api/webhooks/1518588825897795766/XJRbY8y200_JPzct3aKMPNLdac33SqtlZjzfTYq-3JmS4xatK3Gty4yboHUzxh5WeQB5"
local WEBHOOK_FILE = "kebab_webhook.txt"
local function loadWebhookUrl()
	local url = ""
	pcall(function()
		if isfile and isfile(WEBHOOK_FILE) then url = readfile(WEBHOOK_FILE) end
	end)
	url = (url or ""):gsub("%s+", "")          -- strip newline/whitespace
	if url == "" then url = WEBHOOK_URL_DEFAULT end -- fall back to hardcoded
	return url
end

-- GitHub state doc (raw CDN + cache-buster)
local OWNER, REPO, FILE = "TSBSCRIPTS", "onekebabpranks", "commands.json"
local RAW = string.format("https://raw.githubusercontent.com/%s/%s/main/%s", OWNER, REPO, FILE)
local POLL_INTERVAL = 1   -- lower = snappier (raw CDN has no strict rate limit)

-- ===== EXECUTOR HTTP (for webhook POST) =======================
local httpRequest = http_request or request
	or (syn and syn.request) or (http and http.request)

-- ===== M1 / PUNCH (your method, cached) ========================
local punchBtn
local function resolvePunchButton()
	local gui      = LP:WaitForChild("PlayerGui")
	local touchGui = gui:FindFirstChild("TouchGui")
	if not touchGui then return nil end
	local frame = touchGui:FindFirstChild("TouchControlFrame")
	local jump  = frame and frame:FindFirstChild("JumpButton")
	punchBtn = jump and jump:FindFirstChild("PunchButton")
	return punchBtn
end

local function punch()
	if not punchBtn or not punchBtn.Parent then
		if not resolvePunchButton() then
			warn("[bot] PunchButton missing — touch controls not active?")
			return
		end
	end
	local pos   = punchBtn.AbsolutePosition
	local size  = punchBtn.AbsoluteSize
	local inset = GuiService:GetGuiInset()
	local x = pos.X + size.X * 0.5 + inset.X + PUNCH_OFFSET_X
	local y = pos.Y + size.Y * 0.5 + inset.Y + PUNCH_OFFSET_Y
	VIM:SendMouseButtonEvent(x, y, 0, true,  game, 0)
	task.wait(0.05)
	VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
end

-- ===== HELPERS =================================================
local function rig(plr)
	local c = plr and plr.Character
	if not c then return nil end
	local hrp = c:FindFirstChild("HumanoidRootPart")
	local hum = c:FindFirstChildOfClass("Humanoid")
	if hrp and hum then return c, hrp, hum end
	return nil
end

local function adminHere()
	for _, p in ipairs(Players:GetPlayers()) do
		if ADMIN_IDS[p.UserId] then return true end
	end
	return false
end

-- ===== STATE (driven by GitHub) ===============================
local currentMode   = "idle"   -- "idle" | "kill" | "guardian"
local currentTarget = nil

-- ===== COMBAT (hit-and-run) ===================================
-- Hide UNDER the target (can't be hit), then snap BEHIND for the M1
-- burst, then the loop drops us back under. Bails if state changes.
local function stillOn(name)
	return currentMode == "kill" and currentTarget == name
end

local function engageOnce(name)
	local target = Players:FindFirstChild(name)
	if not target then return end
	local _, tHRP  = rig(target)
	local _, myHRP = rig(LP)
	if not (tHRP and myHRP) then return end

	-- 1) hide under the target (safe spot)
	myHRP.CFrame = tHRP.CFrame * CFrame.new(0, -SAFE_DEPTH, 0)
	task.wait(SAFE_TIME)

	-- 2) strike: pop behind for each M1, tracking the target as it moves
	for _ = 1, HITS_TO_RAGDOLL do
		if not stillOn(name) then break end
		local _, tH  = rig(target)
		local _, myH = rig(LP)
		if not (tH and myH) then break end
		local behindPos = (tH.CFrame * CFrame.new(0, 0, BEHIND_DIST)).Position
		myH.CFrame = CFrame.lookAt(behindPos, tH.Position)  -- behind + facing them
		punch()
		task.wait(COMBO_INTERVAL)
	end
end

-- Persistent engage loop: keeps the target ragdolled until Stop.
task.spawn(function()
	while true do
		if currentMode == "kill" and currentTarget then
			if Players:FindFirstChild(currentTarget) then
				engageOnce(currentTarget)        -- repeats -> perma-ragdoll
			end
		end
		task.wait(0.15)
	end
end)

-- ===== PLAYER LIST -> WEBHOOK ==================================
local function postWebhook(contentStr)
	if not httpRequest then warn("[bot] NO executor HTTP function (http_request/request) found!") return end
	local url = loadWebhookUrl()
	if url == "" then warn("[bot] empty webhook url") return end
	local body = HttpService:JSONEncode({ content = contentStr })
	local ok, resp = pcall(httpRequest, {
		Url = url, Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
	})
	if not ok then
		warn("[bot] webhook call ERRORED:", resp)
		return
	end
	local code = (type(resp) == "table" and (resp.StatusCode or resp.Status)) or "?"
	print("[bot] webhook POST StatusCode=" .. tostring(code))
	if type(resp) == "table" and resp.Body and tostring(code) ~= "204" then
		print("[bot] webhook response body:", tostring(resp.Body))
	end
end

-- Publish the current player list to the webhook (LIVE cache).
-- Only the bot in the admin's server publishes (so the panel's list is
-- always for the right server).
local function publishPlayers()
	if not adminHere() then return end
	local names = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then names[#names + 1] = p.Name end
	end
	postWebhook(HttpService:JSONEncode({ type = "players", players = names, ts = os.time() }))
	print("[bot] published " .. #names .. " players")
end

-- Publish on join/leave (debounced so a burst doesn't spam), plus a heartbeat.
local pendingPublish = false
local function schedulePublish()
	if pendingPublish then return end
	pendingPublish = true
	task.delay(1, function()
		pendingPublish = false
		publishPlayers()
	end)
end
Players.PlayerAdded:Connect(schedulePublish)
Players.PlayerRemoving:Connect(schedulePublish)

task.spawn(function()
	while true do
		publishPlayers()   -- heartbeat (also the first publish at startup)
		task.wait(15)
	end
end)

-- ===== POLL THE STATE DOC (kill / stop target) ================
local lastStateId = 0

local function poll()
	local url = RAW .. "?cb=" .. os.time() .. "_" .. tostring(math.random(1, 1000000))
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then warn("[bot] poll failed:", body) return end

	local good, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not good or type(data) ~= "table" then return end

	local sId = tonumber(data.stateId) or 0
	if sId > lastStateId then
		lastStateId   = sId
		currentMode   = data.mode or "idle"
		currentTarget = data.target
		print("[bot] state ->", currentMode, currentTarget or "-")
	end
end

task.spawn(function()
	print("[bot] runtime online — watching", OWNER .. "/" .. REPO)
	while true do
		pcall(poll)
		task.wait(POLL_INTERVAL)
	end
end)
