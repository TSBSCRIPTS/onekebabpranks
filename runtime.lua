-- ===============================================================
--  runtime.draft.lua   (bot account executor script — WORK IN PROGRESS)
--  Combat: 4 connected M1s ragdoll a target (auto-target melee).
--  Model: reads a STATE doc from GitHub { mode, target } and engages
--  the target until mode flips to "idle" (Stop). Also answers
--  on-demand "listplayers" requests by posting the player list to a
--  Discord webhook (so the panel can show player buttons).
--  JOIN is native (admin open-joins; bot joins via Roblox "Join").
-- ===============================================================

local Players      = game:GetService("Players")
local VIM          = game:GetService("VirtualInputManager")
local GuiService   = game:GetService("GuiService")
local HttpService  = game:GetService("HttpService")

local LP = Players.LocalPlayer

-- ===== CONFIG ==================================================
local PUNCH_OFFSET_X  = 0
local PUNCH_OFFSET_Y  = 8        -- your tuned value
local APPROACH_DIST   = 6        -- studs: how close before we punch
local HITS_TO_RAGDOLL = 4        -- 4 M1s = ragdoll
local COMBO_INTERVAL  = 0.35     -- delay between M1s
local TICK            = 0.12     -- chase loop delay

-- Admins (so only the bot in the admin's server answers list requests)
local ADMIN_IDS = {
	[2539358647] = true,
}

-- Webhook URL lives in a LOCAL file on the bot's machine (NOT in this
-- public script). Create a file with this name next to your executor and
-- put the webhook URL as its only contents:
local WEBHOOK_FILE = "kebab_webhook.txt"
local function loadWebhookUrl()
	local url = ""
	pcall(function()
		if isfile and isfile(WEBHOOK_FILE) then url = readfile(WEBHOOK_FILE) end
	end)
	return (url or ""):gsub("%s+", "")   -- strip newline/whitespace
end

-- GitHub state doc (raw CDN + cache-buster)
local OWNER, REPO, FILE = "TSBSCRIPTS", "onekebabpranks", "commands.json"
local RAW = string.format("https://raw.githubusercontent.com/%s/%s/main/%s", OWNER, REPO, FILE)
local POLL_INTERVAL = 3

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

-- ===== COMBAT =================================================
-- One combo pass: chase + up to HITS_TO_RAGDOLL connected M1s.
-- Bails immediately if the state changed (target swapped / stopped).
local function engageOnce(name)
	local target = Players:FindFirstChild(name)
	if not target then return end
	local landed = 0
	while target.Parent and landed < HITS_TO_RAGDOLL
		and currentMode == "kill" and currentTarget == name do
		local _, myHRP, myHum = rig(LP)
		local _, tHRP         = rig(target)
		if not (myHRP and tHRP and myHum) then break end
		local dist = (myHRP.Position - tHRP.Position).Magnitude
		if dist <= APPROACH_DIST then
			punch()
			landed += 1
			task.wait(COMBO_INTERVAL)
		else
			myHum:MoveTo(tHRP.Position)   -- close gap (auto-faces target)
			task.wait(TICK)
		end
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
local function postPlayers(reqId)
	if not httpRequest then warn("[bot] no executor HTTP for webhook") return end
	local url = loadWebhookUrl()
	if url == "" then warn("[bot] no webhook url — create file:", WEBHOOK_FILE) return end
	local names = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then names[#names + 1] = p.Name end
	end
	local payload = HttpService:JSONEncode({ type = "players", players = names, reqId = reqId, ts = os.time() })
	local body    = HttpService:JSONEncode({ content = payload })
	local ok, resp = pcall(httpRequest, {
		Url = url, Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
	})
	if not ok then
		warn("[bot] webhook post failed:", resp)
	else
		print(string.format("[bot] posted %d players (req %d)", #names, reqId))
	end
end

-- ===== POLL THE STATE DOC =====================================
local lastStateId, lastReqId = 0, 0
local initialized = false

local function poll()
	local url = RAW .. "?cb=" .. os.time() .. "_" .. tostring(math.random(1, 1000000))
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then warn("[bot] poll failed:", body) return end

	local good, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not good or type(data) ~= "table" then return end

	-- persistent state (apply even on first boot, so we resume targeting)
	local sId = tonumber(data.stateId) or 0
	if sId > lastStateId then
		lastStateId   = sId
		currentMode   = data.mode or "idle"
		currentTarget = data.target
		print("[bot] state ->", currentMode, currentTarget or "-")
	end

	-- one-shot requests (skip stale ones on first boot)
	local rId = tonumber(data.reqId) or 0
	if rId > lastReqId then
		lastReqId = rId
		if initialized and data.req == "listplayers" and adminHere() then
			postPlayers(rId)
		end
	end

	initialized = true
end

task.spawn(function()
	print("[bot] runtime online — watching", OWNER .. "/" .. REPO)
	while true do
		pcall(poll)
		task.wait(POLL_INTERVAL)
	end
end)
