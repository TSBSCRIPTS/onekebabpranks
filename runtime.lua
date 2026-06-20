print("1")-- placeholder: moderation bot source goes here later


shiftlock disable task.wait(5)  -- wait for UI to fully load

local Players = game:GetService("Players")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")

local FUDGE_Y = 2   -- small extra offset downwards; tweak if needed
local FUDGE_X = 0

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

-- Get the ShiftLock button and make it visible
local touchGui = gui:WaitForChild("TouchGui")
local touchControlFrame = touchGui:WaitForChild("TouchControlFrame")
local jumpButton = touchControlFrame:WaitForChild("JumpButton")
local shiftLockButton = jumpButton:WaitForChild("ShiftLockButton")

shiftLockButton.Visible = true

task.wait(0.1) -- tiny delay so layout updates

-- Center of the button in GUI space
local absPos = shiftLockButton.AbsolutePosition
local absSize = shiftLockButton.AbsoluteSize

local guiX = absPos.X + absSize.X * 0.5
local guiY = absPos.Y + absSize.Y * 0.5

-- Convert GUI coords → real screen coords using inset
local inset = GuiService:GetGuiInset()  -- Vector2
local x = guiX + inset.X + FUDGE_X
local y = guiY + inset.Y + FUDGE_Y

-- Click it once
VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
task.wait(0.05)
VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)

print(string.format("Clicked ShiftLockButton at (%.0f, %.0f)", x, y))


---this file above is to prepare the bot it is essential dont delete
