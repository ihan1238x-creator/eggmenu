local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")

local FOLDER_NAME = "RenderedEggs"
local TELEPORT_HEIGHT_OFFSET = 5 -- studs above the model to land on top of it

-- If this script is loaded via loadstring(game:HttpGet(SCRIPT_URL))(), setting this lets
-- Server Hop automatically requeue it so it re-runs right after joining the new server.
-- Leave blank if you're loading it another way (then it just won't auto re-execute).
local SCRIPT_URL = "https://raw.githubusercontent.com/ihan1238x-creator/eggmenu/refs/heads/main/premiumegg.lua"

local eggFolder = Workspace:WaitForChild(FOLDER_NAME)
local plotsFolder = Workspace:WaitForChild("Plots")
local player = Players.LocalPlayer

local eggEntries = {}         -- model -> {label} (view-only row in the Egg tab)
local luckEntries = {}        -- model -> {label} (view-only row, Top Luck section)
local playerEntries = {}      -- Player -> {button, square, nameLabel} (selectable row)
local selectedPlayer = nil
local selectedEggTypes = {}   -- eggName -> true if enabled for auto farm
local autoFarmEnabled = false

----------------------------------------------------------------
-- Theme (space palette)
----------------------------------------------------------------

local THEME_BG = Color3.fromRGB(8, 8, 20)          -- near-black navy background
local THEME_PANEL = Color3.fromRGB(15, 15, 28)      -- bars/buttons
local THEME_PANEL_LIGHT = Color3.fromRGB(22, 22, 40) -- scroll frames / secondary buttons
local THEME_ACCENT = Color3.fromRGB(140, 110, 255)   -- space-purple accent
local THEME_SUCCESS = Color3.fromRGB(80, 200, 140)   -- "ON" states
local THEME_TEXT = Color3.fromRGB(235, 235, 245)

local function addStroke(guiObject, color, thickness, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or THEME_ACCENT
    stroke.Thickness = thickness or 1
    stroke.Transparency = transparency or 0.4
    stroke.Parent = guiObject
    return stroke
end

----------------------------------------------------------------
-- Misc helpers
----------------------------------------------------------------

local function getModelSize(model)
    local ok, cf, size = pcall(function()
        return model:GetBoundingBox()
    end)
    if ok then
        return cf, size
    end
    return model:GetPivot(), Vector3.new(4, 4, 4)
end

----------------------------------------------------------------
-- Egg luck detection
----------------------------------------------------------------

local LUCK_BILLBOARD_NAME = "EggLuck"
local LUCK_LABEL_NAME = "Luck"

local LUCK_SUFFIX_MULTIPLIERS = {
    K = 1e3,
    M = 1e6,
    B = 1e9,
    T = 1e12,
}

-- Turns "12.5K", "3M", "1,250", "42" etc into a plain number
local function parseLuckValue(text)
    if not text then return 0 end
    local numberPart, suffix = text:match("([%d,%.]+)%s*([KMBTkmbt]?)")
    if not numberPart then return 0 end
    numberPart = numberPart:gsub(",", "")
    local value = tonumber(numberPart)
    if not value then return 0 end
    suffix = suffix ~= "" and suffix:upper() or nil
    if suffix then
        value = value * (LUCK_SUFFIX_MULTIPLIERS[suffix] or 1)
    end
    return value
end

-- Recursively searches `root` for the first descendant matching className+name
local function findDescendant(root, className, name)
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant.Name == name and descendant:IsA(className) then
            return descendant
        end
    end
    return nil
end

-- Returns numericLuckValue, rawLuckText for a model, or nil if it has no luck tag
local function getEggLuck(model)
    local billboard = findDescendant(model, "BillboardGui", LUCK_BILLBOARD_NAME)
    if not billboard then return nil end

    local luckLabel = findDescendant(billboard, "TextLabel", LUCK_LABEL_NAME)
    if not luckLabel then return nil end

    return parseLuckValue(luckLabel.Text), luckLabel.Text
end

----------------------------------------------------------------
-- Basket watcher (each picked-up egg spawns a Configuration with random name)
----------------------------------------------------------------

local basketFolder = player:WaitForChild("Basket")
local basketDropRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Game"):WaitForChild("BasketDrop")

local latestBasketEggName = nil -- most recent "Egg" attribute value seen in the basket

local function handleBasketChild(child)
    if not child:IsA("Configuration") then return end -- ignore anything that isn't a Configuration (GUIs, etc.)

    local eggName = child:GetAttribute("Egg")
    print("Basket Egg attribute detected: " .. tostring(eggName))

    if eggName then
        latestBasketEggName = eggName
    end
end

for _, existingChild in ipairs(basketFolder:GetChildren()) do
    handleBasketChild(existingChild)
end

basketFolder.ChildAdded:Connect(handleBasketChild)

----------------------------------------------------------------
-- Teleport helpers
----------------------------------------------------------------

local teleportToPlayer -- forward declaration (defined below, used inside teleportToModel)
local teleportToMyPlot -- forward declaration (defined below, used inside teleportToModel)

local function findProximityPrompt(model)
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") then
            return descendant
        end
    end
    return nil
end

local function teleportCharacterTo(position)
    local character = player.Character or player.CharacterAdded:Wait()
    local hrp = character:WaitForChild("HumanoidRootPart", 5)
    if not hrp then return end
    hrp.CFrame = CFrame.new(position)
end

local function teleportToModel(model)
    local cf, size = getModelSize(model)
    local targetPosition = cf.Position + Vector3.new(0, (size.Y / 2) + TELEPORT_HEIGHT_OFFSET, 0)
    teleportCharacterTo(targetPosition)
    wait(1)
    print("Selected: " .. model.Name)

    local prompt = findProximityPrompt(model)
    if prompt then
        if fireproximityprompt then
            local connection
            connection = prompt.Triggered:Connect(function(triggeringPlayer)
                if triggeringPlayer ~= player then return end
                connection:Disconnect()

                wait(1)
                if selectedPlayer then
                    teleportToPlayer(selectedPlayer)
                    print("Teleported to selected player: " .. selectedPlayer.Name)
                else
                    teleportToMyPlot()
                end

                task.wait(2) -- give the basket a couple seconds to update
                if latestBasketEggName then
                    local args = { latestBasketEggName }
                    local unpackFn = table.unpack or unpack -- newer Luau dropped the global `unpack`

                    local ok, err = pcall(function()
                        basketDropRemote:FireServer(unpackFn(args))
                    end)

                    if ok then
                        print("Dropped egg via BasketDrop: " .. latestBasketEggName)
                    else
                        warn("BasketDrop FireServer failed for '" .. latestBasketEggName .. "': " .. tostring(err))
                    end
                else
                    warn("No egg detected in Basket to drop")
                end
            end)

            fireproximityprompt(prompt)
            print("Fired prompt: " .. prompt.Name)

            -- safety timeout in case Triggered never fires (e.g. prompt got disabled/destroyed)
            task.delay(5, function()
                if connection.Connected then
                    connection:Disconnect()
                    warn("Prompt never triggered within timeout: " .. prompt.Name)
                end
            end)
        else
            warn("fireproximityprompt not supported on this executor")
        end
    else
        warn("No ProximityPrompt found on " .. model.Name)
    end
end

teleportToPlayer = function(targetPlayer)
    local targetCharacter = targetPlayer.Character
    if not targetCharacter then return end
    local targetHrp = targetCharacter:FindFirstChild("HumanoidRootPart")
    if not targetHrp then return end

    local offset = targetHrp.CFrame.RightVector * 4
    teleportCharacterTo(targetHrp.Position + offset + Vector3.new(0, 2, 0))
end

----------------------------------------------------------------
-- Plot ownership helpers
----------------------------------------------------------------

local function getPlotOwner(plotModel)
    local data = plotModel:FindFirstChild("Data")
    if not data then return nil end

    local ownerValue = data:FindFirstChild("Owner")
    if not ownerValue or not ownerValue:IsA("ObjectValue") then return nil end

    return ownerValue.Value
end

local function findMyPlot()
    for _, plotModel in ipairs(plotsFolder:GetChildren()) do
        if plotModel:IsA("Model") then
            local owner = getPlotOwner(plotModel)
            if owner then
                if owner == player or (owner.Name == player.Name) then
                    return plotModel
                end
            end
        end
    end
    return nil
end

teleportToMyPlot = function()
    local plotModel = findMyPlot()
    if not plotModel then
        warn("Could not find a plot owned by " .. player.Name)
        return
    end

    local cf, size = getModelSize(plotModel)
    local targetPosition = cf.Position + Vector3.new(0, (size.Y / 2) + TELEPORT_HEIGHT_OFFSET, 0)
    teleportCharacterTo(targetPosition)
    print("Teleported to your plot: " .. plotModel.Name)
end

----------------------------------------------------------------
-- Server hop
----------------------------------------------------------------

local function serverHop()
    if queue_on_teleport then
        if SCRIPT_URL ~= "" then
            local ok, err = pcall(function()
                queue_on_teleport(string.format("loadstring(game:HttpGet(%q))()", SCRIPT_URL))
            end)
            if ok then
                print("Queued script to re-execute after server hop")
            else
                warn("Failed to queue script for re-execution: " .. tostring(err))
            end
        else
            warn("SCRIPT_URL is blank — set it at the top of the script so it can requeue itself")
        end
    else
        warn("queue_on_teleport not supported on this executor — script won't auto re-run after hopping")
    end

    print("Server hopping...")
    local ok, err = pcall(function()
        TeleportService:Teleport(game.PlaceId, player)
    end)
    if not ok then
        warn("Server hop failed: " .. tostring(err))
    end
end

----------------------------------------------------------------
-- Draggable helper (drag by a given handle)
----------------------------------------------------------------

local function makeDraggable(frame, dragHandle)
    dragHandle.Active = true

    local dragging = false
    local dragInput, startInputPos, startFramePos

    dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInputPos = input.Position
            startFramePos = frame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    dragHandle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input == dragInput then
            local delta = input.Position - startInputPos
            frame.Position = UDim2.new(
                startFramePos.X.Scale,
                startFramePos.X.Offset + delta.X,
                startFramePos.Y.Scale,
                startFramePos.Y.Offset + delta.Y
            )
        end
    end)
end

----------------------------------------------------------------
-- Generic row builders
----------------------------------------------------------------

-- Clickable row (used for the Players list and the Auto Farm checklist)
local function createRow(scroll, name, onClick)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Size = UDim2.new(1, 0, 0, 24)
    button.BackgroundColor3 = THEME_ACCENT
    button.BackgroundTransparency = 1
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Font = Enum.Font.Gotham
    button.TextSize = 14
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Text = ""
    button.Parent = scroll

    local rowCorner = Instance.new("UICorner")
    rowCorner.CornerRadius = UDim.new(0, 4)
    rowCorner.Parent = button

    local square = Instance.new("Frame")
    square.Name = "SelectSquare"
    square.Size = UDim2.new(0, 12, 0, 12)
    square.Position = UDim2.new(0, 6, 0.5, -6)
    square.BackgroundColor3 = THEME_ACCENT
    square.BackgroundTransparency = 1
    square.BorderSizePixel = 0
    square.Parent = button

    local squareCorner = Instance.new("UICorner")
    squareCorner.CornerRadius = UDim.new(0, 3)
    squareCorner.Parent = square

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NameText"
    nameLabel.Size = UDim2.new(1, -26, 1, 0)
    nameLabel.Position = UDim2.new(0, 24, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.Gotham
    nameLabel.TextSize = 14
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Text = name
    nameLabel.Parent = button

    button.MouseButton1Click:Connect(onClick)

    return {button = button, square = square, nameLabel = nameLabel}
end

-- Non-interactive row (used for the view-only Eggs list and Top Luck list)
local function createViewRow(scroll, text)
    local label = Instance.new("TextLabel")
    label.Name = "Row"
    label.Size = UDim2.new(1, 0, 0, 22)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text
    label.Parent = scroll
    return {label = label}
end

-- Toggleable checklist row (used for the Auto Farm egg-type selector)
local function createCheckRow(scroll, name)
    local entry
    local isChecked = false

    entry = createRow(scroll, name, function()
        isChecked = not isChecked
        selectedEggTypes[name] = isChecked or nil
        entry.square.BackgroundTransparency = isChecked and 0 or 1
        entry.button.BackgroundTransparency = isChecked and 0.85 or 1
        print((isChecked and "Enabled" or "Disabled") .. " auto-farm for: " .. name)
    end)

    return entry
end

-- Builds a small title label + scrolling list under it, at an absolute position/size
local function createSection(parent, titleText, x, y, width, height)
    local title = Instance.new("TextLabel")
    title.Name = "SectionTitle"
    title.Size = UDim2.new(0, width, 0, 18)
    title.Position = UDim2.new(0, x, 0, y)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = titleText
    title.Parent = parent

    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "SectionScroll"
    scroll.Position = UDim2.new(0, x, 0, y + 20)
    scroll.Size = UDim2.new(0, width, 0, height - 20)
    scroll.BackgroundColor3 = THEME_PANEL_LIGHT
    scroll.BackgroundTransparency = 0.3
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 6
    scroll.ScrollBarImageColor3 = THEME_ACCENT
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = parent

    local scrollCorner = Instance.new("UICorner")
    scrollCorner.CornerRadius = UDim.new(0, 6)
    scrollCorner.Parent = scroll

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 2)
    layout.Parent = scroll

    return title, scroll
end

----------------------------------------------------------------
-- Main GUI shell
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggMenu_GUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Intro splash (black screen + "T" logo, fades out on load)
----------------------------------------------------------------

local introOverlay = Instance.new("Frame")
introOverlay.Name = "IntroOverlay"
introOverlay.Size = UDim2.new(1, 0, 1, 0)
introOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
introOverlay.BackgroundTransparency = 0
introOverlay.BorderSizePixel = 0
introOverlay.ZIndex = 1000
introOverlay.Parent = screenGui

local introLogo = Instance.new("TextLabel")
introLogo.Name = "IntroLogo"
introLogo.Size = UDim2.new(0, 220, 0, 220)
introLogo.AnchorPoint = Vector2.new(0.5, 0.5)
introLogo.Position = UDim2.new(0.5, 0, 0.5, 0)
introLogo.BackgroundTransparency = 1
introLogo.Font = Enum.Font.GothamBold
introLogo.TextSize = 96
introLogo.TextColor3 = Color3.fromRGB(140, 110, 255)
introLogo.Text = "T"
introLogo.ZIndex = 1001
introLogo.Parent = introOverlay

local INTRO_HOLD_TIME = 0.8
local INTRO_FADE_TIME = 0.6

task.delay(INTRO_HOLD_TIME, function()
    local overlayFadeTween = TweenService:Create(
        introOverlay,
        TweenInfo.new(INTRO_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {BackgroundTransparency = 1}
    )
    local logoFadeTween = TweenService:Create(
        introLogo,
        TweenInfo.new(INTRO_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {TextTransparency = 1}
    )

    overlayFadeTween.Completed:Connect(function()
        introOverlay:Destroy()
    end)

    overlayFadeTween:Play()
    logoFadeTween:Play()
end)

----------------------------------------------------------------
-- Fullscreen backdrop (blacks out the game view while the menu is open)
----------------------------------------------------------------

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.new(1, 0, 1, 0)
backdrop.Position = UDim2.new(0, 0, 0, 0)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 0
backdrop.BorderSizePixel = 0
backdrop.ZIndex = 0
backdrop.Parent = screenGui

-- Snowfall lives on the backdrop (outside the menu), not inside mainFrame
local snowLayer = Instance.new("Frame")
snowLayer.Name = "SnowLayer"
snowLayer.Size = UDim2.new(1, 0, 1, 0)
snowLayer.BackgroundTransparency = 1
snowLayer.ZIndex = 1
snowLayer.Parent = backdrop

local SNOWFLAKE_COUNT = 60
local snowflakes = {}

for _ = 1, SNOWFLAKE_COUNT do
    local size = math.random(2, 5)
    local flake = Instance.new("Frame")
    flake.Size = UDim2.new(0, size, 0, size)
    flake.Position = UDim2.new(math.random(), 0, math.random(), 0)
    flake.BackgroundColor3 = Color3.new(1, 1, 1)
    flake.BackgroundTransparency = math.random(20, 60) / 100
    flake.BorderSizePixel = 0
    flake.ZIndex = 1
    flake.Parent = snowLayer

    local flakeCorner = Instance.new("UICorner")
    flakeCorner.CornerRadius = UDim.new(1, 0)
    flakeCorner.Parent = flake

    table.insert(snowflakes, {
        instance = flake,
        fallSpeed = math.random(8, 20) / 100,   -- fraction of height per second
        driftSpeed = math.random(-15, 15) / 1000, -- fraction of width per tick
    })
end

local snowAnimationRunning = false

local function startSnowAnimation()
    if snowAnimationRunning then return end
    snowAnimationRunning = true

    task.spawn(function()
        while snowAnimationRunning do
            local dt = task.wait(0.03)

            for _, flake in ipairs(snowflakes) do
                local pos = flake.instance.Position
                local newY = pos.Y.Scale + flake.fallSpeed * dt
                local newX = pos.X.Scale + flake.driftSpeed

                if newY > 1.05 then
                    newY = -0.05
                    newX = math.random()
                end

                if newX < -0.05 then
                    newX = 1.05
                elseif newX > 1.05 then
                    newX = -0.05
                end

                flake.instance.Position = UDim2.new(newX, 0, newY, 0)
            end
        end
    end)
end

local function stopSnowAnimation()
    snowAnimationRunning = false
end

local mainFrame = Instance.new("CanvasGroup")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 520, 0, 420)
mainFrame.Position = UDim2.new(0, 40, 0, 40)
mainFrame.BackgroundColor3 = THEME_BG
mainFrame.BackgroundTransparency = 0
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.ZIndex = 1 -- draw above the backdrop + snow
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

addStroke(mainFrame, THEME_ACCENT, 1, 0.5)

local mainGradient = Instance.new("UIGradient")
mainGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(14, 12, 30)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 6, 16)),
})
mainGradient.Rotation = 60
mainGradient.Parent = mainFrame

-- Scattered "stars" decoration, sits behind everything else
local starField = Instance.new("Frame")
starField.Name = "StarField"
starField.Size = UDim2.new(1, 0, 1, 0)
starField.BackgroundTransparency = 1
starField.ZIndex = 0
starField.Parent = mainFrame

for _ = 1, 35 do
    local star = Instance.new("Frame")
    star.Size = UDim2.new(0, math.random(1, 2), 0, math.random(1, 2))
    star.Position = UDim2.new(math.random(), 0, math.random(), 0)
    star.BackgroundColor3 = Color3.new(1, 1, 1)
    star.BackgroundTransparency = math.random(30, 80) / 100
    star.BorderSizePixel = 0
    star.ZIndex = 0
    star.Parent = starField

    local starCorner = Instance.new("UICorner")
    starCorner.CornerRadius = UDim.new(1, 0)
    starCorner.Parent = star
end

local guiScale = Instance.new("UIScale")
guiScale.Scale = 1
guiScale.Parent = mainFrame

----------------------------------------------------------------
-- Fade helpers (whole-menu open/close, and per-tab crossfade)
----------------------------------------------------------------

local FADE_DURATION = 0.25
local fadeTweenInfo = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

mainFrame.GroupTransparency = 0
backdrop.BackgroundTransparency = 0 -- menu starts open, so the backdrop starts opaque

local function setMenuVisible(shouldShow)
    if shouldShow then
        if mainFrame.Visible then return end
        mainFrame.Visible = true
        mainFrame.GroupTransparency = 1
        TweenService:Create(mainFrame, fadeTweenInfo, {GroupTransparency = 0}):Play()

        backdrop.Visible = true
        TweenService:Create(backdrop, fadeTweenInfo, {BackgroundTransparency = 0}):Play()
        startSnowAnimation()
    else
        if not mainFrame.Visible then return end
        local tween = TweenService:Create(mainFrame, fadeTweenInfo, {GroupTransparency = 1})
        tween.Completed:Connect(function()
            mainFrame.Visible = false
        end)
        tween:Play()

        local backdropTween = TweenService:Create(backdrop, fadeTweenInfo, {BackgroundTransparency = 1})
        backdropTween.Completed:Connect(function()
            backdrop.Visible = false
        end)
        backdropTween:Play()
        stopSnowAnimation()
    end
end

local function toggleMenu()
    setMenuVisible(not mainFrame.Visible)
end

startSnowAnimation() -- menu starts open, so start the snow right away

-- Top bar (drag handle)
local topBar = Instance.new("TextLabel")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 34)
topBar.BackgroundColor3 = THEME_PANEL
topBar.BackgroundTransparency = 0.1
topBar.BorderSizePixel = 0
topBar.Font = Enum.Font.GothamBold
topBar.TextSize = 16
topBar.TextColor3 = THEME_TEXT
topBar.Text = "  Egg Menu"
topBar.TextXAlignment = Enum.TextXAlignment.Left
topBar.Parent = mainFrame

local topBarCorner = Instance.new("UICorner")
topBarCorner.TopLeftRadius = UDim.new(0, 10)
topBarCorner.TopRightRadius = UDim.new(0, 10)
topBarCorner.BottomLeftRadius = UDim.new(0, 0)
topBarCorner.BottomRightRadius = UDim.new(0, 0)
topBarCorner.Parent = topBar

makeDraggable(mainFrame, topBar)

-- Vertical tab bar
local tabBar = Instance.new("Frame")
tabBar.Name = "TabBar"
tabBar.Size = UDim2.new(0, 110, 1, -34)
tabBar.Position = UDim2.new(0, 0, 0, 34)
tabBar.BackgroundColor3 = THEME_PANEL
tabBar.BackgroundTransparency = 0.2
tabBar.BorderSizePixel = 0
tabBar.Parent = mainFrame

local tabBarLayout = Instance.new("UIListLayout")
tabBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabBarLayout.Padding = UDim.new(0, 4)
tabBarLayout.Parent = tabBar

local tabBarPadding = Instance.new("UIPadding")
tabBarPadding.PaddingTop = UDim.new(0, 6)
tabBarPadding.PaddingLeft = UDim.new(0, 4)
tabBarPadding.PaddingRight = UDim.new(0, 4)
tabBarPadding.Parent = tabBar

-- Content area (holds one frame per tab; only one Visible at a time)
local contentArea = Instance.new("Frame")
contentArea.Name = "ContentArea"
contentArea.Size = UDim2.new(1, -110, 1, -34)
contentArea.Position = UDim2.new(0, 110, 0, 34)
contentArea.BackgroundTransparency = 1
contentArea.Parent = mainFrame

local function createTabButton(labelText)
    local button = Instance.new("TextButton")
    button.Name = labelText .. "TabButton"
    button.Size = UDim2.new(1, 0, 0, 36)
    button.BackgroundColor3 = THEME_PANEL_LIGHT
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.TextSize = 14
    button.TextColor3 = THEME_TEXT
    button.Text = labelText
    button.Parent = tabBar

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = button

    addStroke(button, THEME_ACCENT, 1, 0.7)

    return button
end

local function createTabContent()
    local frame = Instance.new("CanvasGroup")
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundColor3 = THEME_BG
    frame.BackgroundTransparency = 0
    frame.GroupTransparency = 1
    frame.Visible = false
    frame.Parent = contentArea
    return frame
end

local eggTabButton = createTabButton("Egg")
local playersTabButton = createTabButton("Players")
local teleportsTabButton = createTabButton("Teleports")
local settingsTabButton = createTabButton("Settings")
local exploitsTabButton = createTabButton("Exploits")

local eggTabContent = createTabContent()
local playersTabContent = createTabContent()
local teleportsTabContent = createTabContent()
local settingsTabContent = createTabContent()
local exploitsTabContent = createTabContent()

local TAB_ACTIVE_COLOR = THEME_ACCENT
local TAB_INACTIVE_COLOR = THEME_PANEL_LIGHT

local tabs = {
    {button = eggTabButton, content = eggTabContent},
    {button = playersTabButton, content = playersTabContent},
    {button = teleportsTabButton, content = teleportsTabContent},
    {button = settingsTabButton, content = settingsTabContent},
    {button = exploitsTabButton, content = exploitsTabContent},
}

local function selectTab(chosenContent)
    for _, tab in ipairs(tabs) do
        local isActive = (tab.content == chosenContent)
        tab.content.Visible = isActive
        tab.content.GroupTransparency = 0
        tab.button.BackgroundColor3 = isActive and TAB_ACTIVE_COLOR or TAB_INACTIVE_COLOR
    end
end

for _, tab in ipairs(tabs) do
    tab.button.MouseButton1Click:Connect(function()
        selectTab(tab.content)
    end)
end
---------UICORNERS FOR TABS BELOW HERE
local tabbaruicorner = Instance.new("UICorner")
tabbaruicorner.BottomRightRadius = UDim.new(0, 0)
tabbaruicorner.BottomLeftRadius = UDim.new(0, 10)
tabbaruicorner.TopRightRadius = UDim.new(0, 0)
tabbaruicorner.TopLeftRadius = UDim.new(0, 0)
tabbaruicorner.Parent = tabBar

local eggcornerui = Instance.new("UICorner")
eggcornerui.BottomRightRadius = UDim.new(0, 10)
eggcornerui.BottomLeftRadius = UDim.new(0, 0)
eggcornerui.TopRightRadius = UDim.new(0, 0)
eggcornerui.TopLeftRadius = UDim.new(0, 0)
eggcornerui.Parent = eggTabContent

local playerscorner = Instance.new("UICorner")
playerscorner.BottomRightRadius = UDim.new(0, 10)
playerscorner.BottomLeftRadius = UDim.new(0, 0)
playerscorner.TopRightRadius = UDim.new(0, 0)
playerscorner.TopLeftRadius = UDim.new(0, 0)
playerscorner.Parent = playersTabContent

local teleportscorner = Instance.new("UICorner")
teleportscorner.BottomRightRadius = UDim.new(0, 10)
teleportscorner.BottomLeftRadius = UDim.new(0, 0)
teleportscorner.TopRightRadius = UDim.new(0, 0)
teleportscorner.TopLeftRadius = UDim.new(0, 0)
teleportscorner.Parent = teleportsTabContent

local settingscorner = Instance.new("UICorner")
settingscorner.BottomRightRadius = UDim.new(0, 10)
settingscorner.BottomLeftRadius = UDim.new(0, 0)
settingscorner.TopRightRadius = UDim.new(0, 0)
settingscorner.TopLeftRadius = UDim.new(0, 0)
settingscorner.Parent = settingsTabContent

local exploitscorner = Instance.new("UICorner")
exploitscorner.BottomRightRadius = UDim.new(0, 10)
exploitscorner.BottomLeftRadius = UDim.new(0, 0)
exploitscorner.TopRightRadius = UDim.new(0, 0)
exploitscorner.TopLeftRadius = UDim.new(0, 0)
exploitscorner.Parent = exploitsTabContent
---------
----------------------------------------------------------------
-- Egg tab: Auto Farm toggle + view-only Eggs list + Top Luck + checklist
----------------------------------------------------------------
local autoFarmButton = Instance.new("TextButton")
autoFarmButton.Name = "AutoFarmButton"
autoFarmButton.Size = UDim2.new(1, -20, 0, 36)
autoFarmButton.Position = UDim2.new(0, 10, 0, 10)
autoFarmButton.BackgroundColor3 = THEME_PANEL_LIGHT
autoFarmButton.BorderSizePixel = 0
autoFarmButton.Font = Enum.Font.GothamBold
autoFarmButton.TextSize = 16
autoFarmButton.TextColor3 = THEME_TEXT
autoFarmButton.Text = "Auto Farm: OFF"
autoFarmButton.Parent = eggTabContent

local autoFarmButtonCorner = Instance.new("UICorner")
autoFarmButtonCorner.CornerRadius = UDim.new(0, 8)
autoFarmButtonCorner.Parent = autoFarmButton

addStroke(autoFarmButton, THEME_ACCENT, 1, 0.6)

autoFarmButton.MouseButton1Click:Connect(function()
    autoFarmEnabled = not autoFarmEnabled
    autoFarmButton.Text = autoFarmEnabled and "Auto Farm: ON" or "Auto Farm: OFF"
    autoFarmButton.BackgroundColor3 = autoFarmEnabled
        and THEME_SUCCESS
        or THEME_PANEL_LIGHT
end)

-- Two view-only lists side by side: currently spawned Eggs, and Top Luck
local eggListTitle, eggListScroll = createSection(eggTabContent, "Eggs (0)", 10, 56, 190, 130)
local luckListTitle, luckListScroll = createSection(eggTabContent, "Top Luck (0)", 210, 56, 190, 130)

-- Auto Farm egg-type checklist, full width, fills the rest of the tab
local _, autoFarmChecklistScroll = createSection(eggTabContent, "Auto Farm Eggs (select types)", 10, 196, 390, 180)

local EGG_NAMES = {
    "White Egg", "Brown Egg", "Cracked Egg", "Easter Egg", "Stone Egg",
    "Leaf Egg", "Mushroom Egg", "Flower Egg", "Slime Egg", "Ice Egg",
    "Glass Egg", "Golden Egg", "Diamond Egg", "Crystal Egg", "Skull Egg","Asteroid Egg",
    "Dominus Egg", "Flaming Egg", "Sinister Egg", "Soul Egg","Tidal Egg", "Aurora Egg",
    "Galaxy Egg","Bloom Egg", "Blackhole Egg", "Solaris Egg", "Cherub Egg","Volcanic Egg",
}

for _, eggName in ipairs(EGG_NAMES) do
    createCheckRow(autoFarmChecklistScroll, eggName)
end

local function updateEggListTitle()
    local count = 0
    for _ in pairs(eggEntries) do count += 1 end
    eggListTitle.Text = "Eggs (" .. count .. ")"
end

local function addEggEntry(model)
    if not model:IsA("Model") then return end
    if eggEntries[model] then return end
    eggEntries[model] = createViewRow(eggListScroll, model.Name)
    updateEggListTitle()
end

local function removeEggEntry(model)
    local entry = eggEntries[model]
    if not entry then return end
    entry.label:Destroy()
    eggEntries[model] = nil
    updateEggListTitle()

    local luckEntry = luckEntries[model]
    if luckEntry then
        luckEntry.label:Destroy()
        luckEntries[model] = nil
    end
end

----------------------------------------------------------------
-- Top Luck (view-only, top 5 luckiest currently spawned eggs)
----------------------------------------------------------------

local TOP_LUCK_COUNT = 5
local LUCK_REFRESH_INTERVAL = 5 -- seconds; luck labels can change/animate, so rescan periodically

local previousTopLuckModels = {} -- model -> true, from the last refresh (used to detect new entries)
local hasDoneInitialLuckScan = false

local function clearLuckEntries()
    for _, entry in pairs(luckEntries) do
        entry.label:Destroy()
    end
    luckEntries = {}
end

local function refreshLuckPanel()
    local luckList = {}
    for model in pairs(eggEntries) do
        local luckValue, luckText = getEggLuck(model)
        if luckValue then
            table.insert(luckList, {model = model, value = luckValue, text = luckText})
        end
    end

    table.sort(luckList, function(a, b)
        return a.value > b.value
    end)

    clearLuckEntries()

    local count = math.min(TOP_LUCK_COUNT, #luckList)
    local currentTopLuckModels = {}

    for i = 1, count do
        local data = luckList[i]
        local model = data.model
        local displayName = i .. ". " .. model.Name .. " - " .. data.text

        luckEntries[model] = createViewRow(luckListScroll, displayName)
        currentTopLuckModels[model] = true

        if hasDoneInitialLuckScan and not previousTopLuckModels[model] then
            print("New top 5 luckiest egg found: " .. model.Name .. " (" .. data.text .. ")")
        end
    end

    previousTopLuckModels = currentTopLuckModels
    hasDoneInitialLuckScan = true

    luckListTitle.Text = "Top Luck (" .. count .. ")"
end

----------------------------------------------------------------
-- Auto Farm loop
----------------------------------------------------------------

local AUTO_FARM_POLL_INTERVAL = 1 -- seconds between scans when nothing matches yet
local AUTO_FARM_CYCLE_DELAY = 6   -- seconds to wait after starting a cycle before picking the next target

local function findNextAutoFarmTarget()
    for model in pairs(eggEntries) do
        if selectedEggTypes[model.Name] then
            return model
        end
    end
    return nil
end

task.spawn(function()
    while true do
        if autoFarmEnabled then
            local target = findNextAutoFarmTarget()
            if target then
                teleportToModel(target)
                task.wait(AUTO_FARM_CYCLE_DELAY)
            else
                task.wait(AUTO_FARM_POLL_INTERVAL)
            end
        else
            task.wait(AUTO_FARM_POLL_INTERVAL)
        end
    end
end)

----------------------------------------------------------------
-- Players tab (select/unselect only, no teleport)
----------------------------------------------------------------

local playerListTitleLabel, playerListScroll = createSection(playersTabContent, "Players (0)", 10, 10, 390, 366)

local function updatePlayerTitle()
    local count = 0
    for _ in pairs(playerEntries) do count += 1 end
    playerListTitleLabel.Text = "Players (" .. count .. ")"
end

local function refreshPlayerRow(targetPlayer)
    local entry = playerEntries[targetPlayer]
    if not entry then return end
    local isSelected = (selectedPlayer == targetPlayer)
    entry.square.BackgroundTransparency = isSelected and 0 or 1
    entry.button.BackgroundTransparency = isSelected and 0.85 or 1
end

local function selectPlayer(targetPlayer)
    if selectedPlayer == targetPlayer then
        selectedPlayer = nil
        refreshPlayerRow(targetPlayer)
        print("Unselected player: " .. targetPlayer.Name)
        return
    end

    local previous = selectedPlayer
    selectedPlayer = targetPlayer
    if previous then refreshPlayerRow(previous) end
    refreshPlayerRow(targetPlayer)
    print("Selected player: " .. targetPlayer.Name)
end

local function addPlayerEntry(targetPlayer)
    if targetPlayer == player then return end
    if playerEntries[targetPlayer] then return end
    playerEntries[targetPlayer] = createRow(playerListScroll, targetPlayer.Name, function()
        selectPlayer(targetPlayer)
    end)
    updatePlayerTitle()
end

local function removePlayerEntry(targetPlayer)
    local entry = playerEntries[targetPlayer]
    if not entry then return end
    entry.button:Destroy()
    playerEntries[targetPlayer] = nil
    if selectedPlayer == targetPlayer then selectedPlayer = nil end
    updatePlayerTitle()
end

----------------------------------------------------------------
-- Teleports tab (just My Plot for now)
----------------------------------------------------------------

local plotButton = Instance.new("TextButton")
plotButton.Name = "MyPlotButton"
plotButton.Size = UDim2.new(0, 160, 0, 40)
plotButton.Position = UDim2.new(0, 10, 0, 10)
plotButton.BackgroundColor3 = THEME_PANEL_LIGHT
plotButton.BorderSizePixel = 0
plotButton.Font = Enum.Font.GothamBold
plotButton.TextSize = 16
plotButton.TextColor3 = THEME_TEXT
plotButton.Text = "My Plot"
plotButton.Parent = teleportsTabContent

local plotButtonCorner = Instance.new("UICorner")
plotButtonCorner.CornerRadius = UDim.new(0, 8)
plotButtonCorner.Parent = plotButton

addStroke(plotButton, THEME_ACCENT, 1, 0.6)

plotButton.MouseButton1Click:Connect(function()
    teleportToMyPlot()
end)

local serverHopButton = Instance.new("TextButton")
serverHopButton.Name = "ServerHopButton"
serverHopButton.Size = UDim2.new(0, 160, 0, 40)
serverHopButton.Position = UDim2.new(0, 180, 0, 10)
serverHopButton.BackgroundColor3 = THEME_PANEL_LIGHT
serverHopButton.BorderSizePixel = 0
serverHopButton.Font = Enum.Font.GothamBold
serverHopButton.TextSize = 16
serverHopButton.TextColor3 = THEME_TEXT
serverHopButton.Text = "Server Hop"
serverHopButton.Parent = teleportsTabContent

local serverHopButtonCorner = Instance.new("UICorner")
serverHopButtonCorner.CornerRadius = UDim.new(0, 8)
serverHopButtonCorner.Parent = serverHopButton

addStroke(serverHopButton, THEME_ACCENT, 1, 0.6)

serverHopButton.MouseButton1Click:Connect(function()
    serverHop()
end)

----------------------------------------------------------------
-- Settings tab (menu toggle keybind + GUI scale)
----------------------------------------------------------------

local toggleKeybind = Enum.KeyCode.LeftControl
local listeningForKeybind = false

local keybindLabel = Instance.new("TextLabel")
keybindLabel.Size = UDim2.new(0, 180, 0, 30)
keybindLabel.Position = UDim2.new(0, 10, 0, 10)
keybindLabel.BackgroundTransparency = 1
keybindLabel.Font = Enum.Font.Gotham
keybindLabel.TextSize = 14
keybindLabel.TextColor3 = THEME_TEXT
keybindLabel.TextXAlignment = Enum.TextXAlignment.Left
keybindLabel.Text = "Toggle Menu Key:"
keybindLabel.Parent = settingsTabContent

local keybindButton = Instance.new("TextButton")
keybindButton.Size = UDim2.new(0, 160, 0, 30)
keybindButton.Position = UDim2.new(0, 200, 0, 10)
keybindButton.BackgroundColor3 = THEME_PANEL_LIGHT
keybindButton.BorderSizePixel = 0
keybindButton.Font = Enum.Font.GothamBold
keybindButton.TextSize = 14
keybindButton.TextColor3 = THEME_TEXT
keybindButton.Text = toggleKeybind.Name
keybindButton.Parent = settingsTabContent

local keybindButtonCorner = Instance.new("UICorner")
keybindButtonCorner.CornerRadius = UDim.new(0, 6)
keybindButtonCorner.Parent = keybindButton

addStroke(keybindButton, THEME_ACCENT, 1, 0.6)

keybindButton.MouseButton1Click:Connect(function()
    listeningForKeybind = true
    keybindButton.Text = "Press any key..."
end)

local scaleLabel = Instance.new("TextLabel")
scaleLabel.Size = UDim2.new(0, 180, 0, 30)
scaleLabel.Position = UDim2.new(0, 10, 0, 54)
scaleLabel.BackgroundTransparency = 1
scaleLabel.Font = Enum.Font.Gotham
scaleLabel.TextSize = 14
scaleLabel.TextColor3 = THEME_TEXT
scaleLabel.TextXAlignment = Enum.TextXAlignment.Left
scaleLabel.Text = "GUI Scale:"
scaleLabel.Parent = settingsTabContent

local MIN_SCALE, MAX_SCALE = 0.5, 1.5

-- Slider track
local sliderTrack = Instance.new("Frame")
sliderTrack.Size = UDim2.new(0, 150, 0, 6)
sliderTrack.Position = UDim2.new(0, 200, 0, 68)
sliderTrack.BackgroundColor3 = THEME_PANEL_LIGHT
sliderTrack.BorderSizePixel = 0
sliderTrack.Parent = settingsTabContent

local sliderTrackCorner = Instance.new("UICorner")
sliderTrackCorner.CornerRadius = UDim.new(1, 0)
sliderTrackCorner.Parent = sliderTrack

addStroke(sliderTrack, THEME_ACCENT, 1, 0.6)

-- Filled portion of the track
local sliderFill = Instance.new("Frame")
sliderFill.Size = UDim2.new(0, 0, 1, 0)
sliderFill.BackgroundColor3 = THEME_ACCENT
sliderFill.BorderSizePixel = 0
sliderFill.Parent = sliderTrack

local sliderFillCorner = Instance.new("UICorner")
sliderFillCorner.CornerRadius = UDim.new(1, 0)
sliderFillCorner.Parent = sliderFill

-- Draggable handle
local sliderHandle = Instance.new("TextButton")
sliderHandle.Size = UDim2.new(0, 16, 0, 16)
sliderHandle.AnchorPoint = Vector2.new(0.5, 0.5)
sliderHandle.Position = UDim2.new(0, 0, 0.5, 0)
sliderHandle.BackgroundColor3 = THEME_TEXT
sliderHandle.BorderSizePixel = 0
sliderHandle.Text = ""
sliderHandle.AutoButtonColor = false
sliderHandle.Parent = sliderTrack

local sliderHandleCorner = Instance.new("UICorner")
sliderHandleCorner.CornerRadius = UDim.new(1, 0)
sliderHandleCorner.Parent = sliderHandle

addStroke(sliderHandle, THEME_ACCENT, 2, 0.2)

local scalePercentLabel = Instance.new("TextLabel")
scalePercentLabel.Size = UDim2.new(0, 60, 0, 30)
scalePercentLabel.Position = UDim2.new(0, 360, 0, 54)
scalePercentLabel.BackgroundTransparency = 1
scalePercentLabel.Font = Enum.Font.GothamBold
scalePercentLabel.TextSize = 14
scalePercentLabel.TextColor3 = THEME_TEXT
scalePercentLabel.TextXAlignment = Enum.TextXAlignment.Left
scalePercentLabel.Text = "100%"
scalePercentLabel.Parent = settingsTabContent

local function updateSliderVisual(value)
    local fraction = (value - MIN_SCALE) / (MAX_SCALE - MIN_SCALE)
    sliderFill.Size = UDim2.new(fraction, 0, 1, 0)
    sliderHandle.Position = UDim2.new(fraction, 0, 0.5, 0)
end

local previewScaleValue = 1

-- Updates the slider visuals + % label only; doesn't touch guiScale.Scale yet
local function updateScalePreview(value)
    value = math.clamp(value, MIN_SCALE, MAX_SCALE)
    previewScaleValue = value
    scalePercentLabel.Text = math.floor(value * 100) .. "%"
    updateSliderVisual(value)
end

-- Actually applies the previewed value to the GUI (called on release)
local function commitScale()
    guiScale.Scale = previewScaleValue
end

updateScalePreview(1)
commitScale() -- initialize handle/fill position and the actual scale

local draggingSlider = false

local function updateScaleFromInputX(inputX)
    local trackPos = sliderTrack.AbsolutePosition.X
    local trackSize = sliderTrack.AbsoluteSize.X
    local fraction = math.clamp((inputX - trackPos) / trackSize, 0, 1)
    updateScalePreview(MIN_SCALE + fraction * (MAX_SCALE - MIN_SCALE))
end

local function isPointerInput(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

sliderHandle.InputBegan:Connect(function(input)
    if isPointerInput(input) then
        draggingSlider = true
    end
end)

sliderTrack.InputBegan:Connect(function(input)
    if isPointerInput(input) then
        draggingSlider = true
        updateScaleFromInputX(input.Position.X)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if draggingSlider
        and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        updateScaleFromInputX(input.Position.X)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if isPointerInput(input) and draggingSlider then
        draggingSlider = false
        commitScale() -- only resize the GUI now that the drag has ended
    end
end)

-- Combined input handler: capture a rebind, otherwise toggle the menu
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
    if listeningForKeybind then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            toggleKeybind = input.KeyCode
            keybindButton.Text = toggleKeybind.Name
            listeningForKeybind = false
        end
        return
    end

    if gameProcessedEvent then return end

    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == toggleKeybind then
        toggleMenu()
    end
end)

----------------------------------------------------------------
-- Exploits tab (Auto Upgrade spam, rate controlled by slider)
----------------------------------------------------------------

local upgradesRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Game"):WaitForChild("Plot"):WaitForChild("Upgrades")

local autoUpgradeEnabled = false
local upgradeFireRate = 0 -- 0-100, how many times per second to fire Upgrades

local autoUpgradeButton = Instance.new("TextButton")
autoUpgradeButton.Name = "AutoUpgradeButton"
autoUpgradeButton.Size = UDim2.new(0, 160, 0, 40)
autoUpgradeButton.Position = UDim2.new(0, 10, 0, 10)
autoUpgradeButton.BackgroundColor3 = THEME_PANEL_LIGHT
autoUpgradeButton.BorderSizePixel = 0
autoUpgradeButton.Font = Enum.Font.GothamBold
autoUpgradeButton.TextSize = 16
autoUpgradeButton.TextColor3 = THEME_TEXT
autoUpgradeButton.Text = "Auto Upgrade: OFF"
autoUpgradeButton.Parent = exploitsTabContent

local autoUpgradeButtonCorner = Instance.new("UICorner")
autoUpgradeButtonCorner.CornerRadius = UDim.new(0, 8)
autoUpgradeButtonCorner.Parent = autoUpgradeButton

addStroke(autoUpgradeButton, THEME_ACCENT, 1, 0.6)

autoUpgradeButton.MouseButton1Click:Connect(function()
    autoUpgradeEnabled = not autoUpgradeEnabled
    autoUpgradeButton.Text = autoUpgradeEnabled and "Auto Upgrade: ON" or "Auto Upgrade: OFF"
    autoUpgradeButton.BackgroundColor3 = autoUpgradeEnabled and THEME_SUCCESS or THEME_PANEL_LIGHT
end)

-- Fire-rate slider (0-100 fires per second), sits to the right of the toggle button
local upgradeSliderTrack = Instance.new("Frame")
upgradeSliderTrack.Size = UDim2.new(0, 170, 0, 6)
upgradeSliderTrack.Position = UDim2.new(0, 190, 0, 27)
upgradeSliderTrack.BackgroundColor3 = THEME_PANEL_LIGHT
upgradeSliderTrack.BorderSizePixel = 0
upgradeSliderTrack.Parent = exploitsTabContent

local upgradeSliderTrackCorner = Instance.new("UICorner")
upgradeSliderTrackCorner.CornerRadius = UDim.new(1, 0)
upgradeSliderTrackCorner.Parent = upgradeSliderTrack

addStroke(upgradeSliderTrack, THEME_ACCENT, 1, 0.6)

local upgradeSliderFill = Instance.new("Frame")
upgradeSliderFill.Size = UDim2.new(0, 0, 1, 0)
upgradeSliderFill.BackgroundColor3 = THEME_ACCENT
upgradeSliderFill.BorderSizePixel = 0
upgradeSliderFill.Parent = upgradeSliderTrack

local upgradeSliderFillCorner = Instance.new("UICorner")
upgradeSliderFillCorner.CornerRadius = UDim.new(1, 0)
upgradeSliderFillCorner.Parent = upgradeSliderFill

local upgradeSliderHandle = Instance.new("TextButton")
upgradeSliderHandle.Size = UDim2.new(0, 16, 0, 16)
upgradeSliderHandle.AnchorPoint = Vector2.new(0.5, 0.5)
upgradeSliderHandle.Position = UDim2.new(0, 0, 0.5, 0)
upgradeSliderHandle.BackgroundColor3 = THEME_TEXT
upgradeSliderHandle.BorderSizePixel = 0
upgradeSliderHandle.Text = ""
upgradeSliderHandle.AutoButtonColor = false
upgradeSliderHandle.Parent = upgradeSliderTrack

local upgradeSliderHandleCorner = Instance.new("UICorner")
upgradeSliderHandleCorner.CornerRadius = UDim.new(1, 0)
upgradeSliderHandleCorner.Parent = upgradeSliderHandle

addStroke(upgradeSliderHandle, THEME_ACCENT, 2, 0.2)

local upgradeRateLabel = Instance.new("TextLabel")
upgradeRateLabel.Size = UDim2.new(0, 70, 0, 30)
upgradeRateLabel.Position = UDim2.new(0, 370, 0, 12)
upgradeRateLabel.BackgroundTransparency = 1
upgradeRateLabel.Font = Enum.Font.GothamBold
upgradeRateLabel.TextSize = 14
upgradeRateLabel.TextColor3 = THEME_TEXT
upgradeRateLabel.TextXAlignment = Enum.TextXAlignment.Left
upgradeRateLabel.Text = "0/100"
upgradeRateLabel.Parent = exploitsTabContent

local function updateUpgradeSliderVisual(value)
    local fraction = value / 100
    upgradeSliderFill.Size = UDim2.new(fraction, 0, 1, 0)
    upgradeSliderHandle.Position = UDim2.new(fraction, 0, 0.5, 0)
end

local function setUpgradeFireRate(value)
    value = math.clamp(math.floor(value + 0.5), 0, 100)
    upgradeFireRate = value
    upgradeRateLabel.Text = value .. "/100"
    updateUpgradeSliderVisual(value)
end

setUpgradeFireRate(0)

local draggingUpgradeSlider = false

local function updateUpgradeRateFromInputX(inputX)
    local trackPos = upgradeSliderTrack.AbsolutePosition.X
    local trackSize = upgradeSliderTrack.AbsoluteSize.X
    local fraction = math.clamp((inputX - trackPos) / trackSize, 0, 1)
    setUpgradeFireRate(fraction * 100)
end

upgradeSliderHandle.InputBegan:Connect(function(input)
    if isPointerInput(input) then
        draggingUpgradeSlider = true
    end
end)

upgradeSliderTrack.InputBegan:Connect(function(input)
    if isPointerInput(input) then
        draggingUpgradeSlider = true
        updateUpgradeRateFromInputX(input.Position.X)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if draggingUpgradeSlider
        and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        updateUpgradeRateFromInputX(input.Position.X)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if isPointerInput(input) and draggingUpgradeSlider then
        draggingUpgradeSlider = false
    end
end)

-- Background loop: while enabled, fires Upgrades `upgradeFireRate` times, spread across ~1 second, then repeats
task.spawn(function()
    while true do
        if autoUpgradeEnabled and upgradeFireRate > 0 then
            local count = upgradeFireRate
            local interval = 1 / count

            for _ = 1, count do
                if not autoUpgradeEnabled then break end

                local ok, err = pcall(function()
                    upgradesRemote:FireServer()
                end)
                if not ok then
                    warn("Upgrades FireServer failed: " .. tostring(err))
                end

                task.wait(interval)
            end
        else
            task.wait(0.1)
        end
    end
end)

-- Small always-visible toggle button (for mobile, where the keybind doesn't apply)
local mobileToggleButton = Instance.new("TextButton")
mobileToggleButton.Name = "MobileToggleButton"
mobileToggleButton.Size = UDim2.new(0, 50, 0, 50)
mobileToggleButton.Position = UDim2.new(0, 10, 0, 100)
mobileToggleButton.BackgroundColor3 = THEME_PANEL
mobileToggleButton.BackgroundTransparency = 0.1
mobileToggleButton.BorderSizePixel = 0
mobileToggleButton.Font = Enum.Font.GothamBold
mobileToggleButton.TextSize = 20
mobileToggleButton.TextColor3 = THEME_TEXT
mobileToggleButton.Text = "T"
mobileToggleButton.ZIndex = 10
mobileToggleButton.Parent = screenGui

local mobileToggleCorner = Instance.new("UICorner")
mobileToggleCorner.CornerRadius = UDim.new(0, 25)
mobileToggleCorner.Parent = mobileToggleButton

addStroke(mobileToggleButton, THEME_ACCENT, 1, 0.4)

makeDraggable(mobileToggleButton, mobileToggleButton) -- draggable so it can be moved out of the way

mobileToggleButton.MouseButton1Click:Connect(function()
    toggleMenu()
end)

----------------------------------------------------------------
-- Wire everything together
----------------------------------------------------------------

selectTab(eggTabContent) -- default to the Egg tab

for _, child in ipairs(eggFolder:GetChildren()) do
    addEggEntry(child)
end
refreshLuckPanel()

eggFolder.ChildAdded:Connect(function(child)
    addEggEntry(child)
    refreshLuckPanel()
end)

eggFolder.ChildRemoved:Connect(function(child)
    removeEggEntry(child)
    refreshLuckPanel()
end)

task.spawn(function()
    while true do
        task.wait(LUCK_REFRESH_INTERVAL)
        refreshLuckPanel()
    end
end)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
    addPlayerEntry(existingPlayer)
end

Players.PlayerAdded:Connect(addPlayerEntry)
Players.PlayerRemoving:Connect(removePlayerEntry)

print("[EggMenu] Loaded. Watching '" .. FOLDER_NAME .. "' and player list.")
