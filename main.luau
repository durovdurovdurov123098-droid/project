--[[
    EduESP — учебный скрипт на Luau: GUI + ESP через Instance.
    Блоки: Services → Config → Utils → ESP → GUI → Init → Unload
]]

--==================================================================
-- 1. SERVICES
--==================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

--==================================================================
-- 2. CONFIG
--==================================================================
local Config = {
    Marker = "EduESP_Marker",              -- атрибут для поиска старых экземпляров
    ToggleKey = Enum.KeyCode.RightShift,   -- хоткей для ПК
    WindowSize = Vector2.new(300, 260),
    HeaderHeight = 32,
    BubbleSize = 44,
    ScreenMargin = 10,                     -- отступ окна от краёв экрана
    TapThreshold = 6,                      -- px: меньше — тап, больше — drag
    AnimTime = 0.2,
    SlowInterval = 0.1,                    -- период обновления текста/подсветки
    MaxHighlights = 30,                    -- лимит Roblox ~31, оставляем запас
    HighlightFill = 0.5,
    DistanceMin = 100,
    DistanceMax = 2000,
    BillboardSize = Vector2.new(120, 56),

    Defaults = {
        ESP = false,
        Highlight = true,
        Name = true,
        Distance = true,
        Health = true,
        Tracers = false,
        TeamCheck = false,
        TeamColor = false,
        MaxDistance = 1000,
    },

    Colors = {
        Background = Color3.fromRGB(24, 24, 29),
        Header = Color3.fromRGB(32, 32, 39),
        Element = Color3.fromRGB(40, 40, 49),
        Stroke = Color3.fromRGB(62, 62, 76),
        Accent = Color3.fromRGB(88, 130, 255),
        Danger = Color3.fromRGB(220, 70, 80),
        Off = Color3.fromRGB(78, 78, 90),
        Text = Color3.fromRGB(235, 235, 242),
        SubText = Color3.fromRGB(150, 150, 165),
        Enemy = Color3.fromRGB(255, 75, 75),
        Ally = Color3.fromRGB(75, 255, 125),
        HealthHigh = Color3.fromRGB(70, 255, 100),
        HealthLow = Color3.fromRGB(255, 60, 60),
    },
}

-- Текущее состояние опций (копия дефолтов)
local State = {}
for key, value in pairs(Config.Defaults) do
    State[key] = value
end

--==================================================================
-- 3. UTILS
--==================================================================
local connections = {}      -- все глобальные соединения (GUI, ввод)
local Unload                -- объявляется заранее, определяется в блоке Unload
local screenGui, espFolder, guiParent

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        warn("[EduESP] ошибка:", err)
    end
end

-- Подключение события с защитой pcall и учётом в таблице connections
local function connect(signal, fn)
    local conn = signal:Connect(function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            warn("[EduESP] ошибка в обработчике:", err)
        end
    end)
    connections[#connections + 1] = conn
    return conn
end

local function disconnectList(list)
    for _, conn in ipairs(list) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(list)
end

local function destroyInstance(inst)
    if inst then
        pcall(function() inst:Destroy() end)
    end
end

local CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local function randomName(len)
    len = len or 12
    local parts = table.create(len)
    for i = 1, len do
        local n = math.random(1, #CHARS)
        parts[i] = CHARS:sub(n, n)
    end
    return table.concat(parts)
end

-- Создание Instance со свойствами; Parent выставляется последним
local function new(className, props, parent)
    local inst = Instance.new(className)
    if props then
        for key, value in pairs(props) do
            inst[key] = value
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local function addCorner(parent, radius)
    return new("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function addStroke(parent, color, thickness)
    return new("UIStroke", { Color = color, Thickness = thickness or 1 }, parent)
end

local function tween(inst, time, props, style, direction)
    local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
    local t = TweenService:Create(inst, info, props)
    t:Play()
    return t
end

-- Глобальное окружение executor'а (getgenv) с запасным вариантом _G
local function getEnv()
    local ok, env = pcall(function() return getgenv() end)
    if ok and type(env) == "table" then
        return env
    end
    return _G
end

-- Поиск родителя для GUI: gethui() → CoreGui → PlayerGui
local function getGuiParent()
    local candidates = {
        function()
            if typeof(gethui) == "function" then
                return gethui()
            end
        end,
        function() return CoreGui end,
        function()
            return LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5)
        end,
    }
    for _, getter in ipairs(candidates) do
        local ok, result = pcall(getter)
        if ok and typeof(result) == "Instance" then
            -- проверяем, что в этот контейнер реально можно положить объект
            local canParent = pcall(function()
                local probe = Instance.new("Folder")
                probe.Parent = result
                probe:Destroy()
            end)
            if canParent then
                return result
            end
        end
    end
    return nil
end

-- Защита от дубликатов: вызываем прошлый Unload и ищем остатки по маркеру
local function cleanupPrevious()
    local env = getEnv()
    local previous = env.__EduESP_Unload
    if type(previous) == "function" then
        pcall(previous)
    end
    env.__EduESP_Unload = nil

    local roots = {}
    pcall(function()
        if typeof(gethui) == "function" then
            roots[#roots + 1] = gethui()
        end
    end)
    roots[#roots + 1] = CoreGui
    pcall(function()
        roots[#roots + 1] = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end)
    for _, root in ipairs(roots) do
        pcall(function()
            for _, child in ipairs(root:GetChildren()) do
                if child:GetAttribute(Config.Marker) then
                    child:Destroy()
                end
            end
        end)
    end
end

-- Контейнеры: ScreenGui для меню и Folder для ESP-объектов
local function createContainers()
    guiParent = getGuiParent()
    if not guiParent then
        warn("[EduESP] не найден контейнер для GUI")
        return false
    end
    screenGui = new("ScreenGui", {
        Name = randomName(),
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        DisplayOrder = 1000,
    })
    screenGui:SetAttribute(Config.Marker, true)
    screenGui.Parent = guiParent

    espFolder = new("Folder", { Name = randomName() })
    espFolder:SetAttribute(Config.Marker, true)
    espFolder.Parent = guiParent
    return true
end

local function getScreenSize()
    if screenGui then
        local size = screenGui.AbsoluteSize
        if size.X > 0 and size.Y > 0 then
            return size
        end
    end
    local cam = Workspace.CurrentCamera
    return cam and cam.ViewportSize or Vector2.new(800, 600)
end

-- Drawing API: проверка поддержки и безопасные обёртки
local drawingSupported = pcall(function()
    assert(Drawing ~= nil and typeof(Drawing.new) == "function")
    local probe = Drawing.new("Line")
    probe.Visible = false
    probe:Remove()
end)

local function createLine()
    local ok, line = pcall(function()
        local l = Drawing.new("Line")
        l.Thickness = 1.5
        l.Transparency = 1
        l.Visible = false
        return l
    end)
    if ok then return line end
    return nil
end

local function removeDrawing(obj)
    if not obj then return end
    if not pcall(function() obj:Remove() end) then
        pcall(function() obj:Destroy() end)
    end
end

--==================================================================
-- 4. ESP
--==================================================================
local espObjects = {}        -- [player] = data
local espConnections = {}    -- соединения самого ESP (отключаются при выключении)
local espEnabled = false
local Hooks = {}             -- хуки для GUI (например, ошибка трассеров)
local tracerErrors = 0

local function isAlly(player)
    local myTeam = LocalPlayer.Team
    return myTeam ~= nil and player.Team == myTeam
end

local function getEspColor(player)
    if State.TeamColor then
        local team = player.Team
        if team then
            return team.TeamColor.Color
        end
    end
    return isAlly(player) and Config.Colors.Ally or Config.Colors.Enemy
end

local function createHighlight(character)
    local hl = new("Highlight", {
        Name = randomName(),
        FillTransparency = Config.HighlightFill,
        OutlineTransparency = 0,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        Adornee = character,
        Enabled = false,
    })
    hl.Parent = espFolder
    return hl
end

-- BillboardGui: имя, расстояние, здоровье
local function createBillboard(data, adornee)
    local C = Config.Colors
    local bb = new("BillboardGui", {
        Name = randomName(),
        Adornee = adornee,
        AlwaysOnTop = true,
        Enabled = false,
        ResetOnSpawn = false,
        Size = UDim2.fromOffset(Config.BillboardSize.X, Config.BillboardSize.Y),
        StudsOffset = Vector3.new(0, 2.8, 0),
    })
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        Padding = UDim.new(0, 1),
    }, bb)

    local function makeText(order, size, font)
        return new("TextLabel", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, size + 2),
            Font = font,
            TextSize = size,
            TextColor3 = C.Text,
            TextStrokeTransparency = 0.4,
            TextStrokeColor3 = Color3.new(0, 0, 0),
            Text = "",
            LayoutOrder = order,
        }, bb)
    end

    local nameLabel = makeText(1, 13, Enum.Font.GothamBold)
    local distLabel = makeText(2, 11, Enum.Font.Gotham)
    local hpText = makeText(3, 11, Enum.Font.Gotham)
    local hpBack = new("Frame", {
        Size = UDim2.fromOffset(56, 5),
        BackgroundColor3 = Color3.fromRGB(20, 20, 20),
        BorderSizePixel = 0,
        LayoutOrder = 4,
    }, bb)
    local hpFill = new("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = C.HealthHigh,
        BorderSizePixel = 0,
    }, hpBack)

    nameLabel.Text = data.player.DisplayName
    bb.Parent = espFolder

    data.ui = {
        name = nameLabel,
        dist = distLabel,
        hpText = hpText,
        hpBack = hpBack,
        hpFill = hpFill,
    }
    return bb
end

-- Очистка визуалов персонажа (сам игрок и его tracer остаются)
local function clearCharacter(data)
    data.token += 1  -- отменяет ожидающие потоки построения
    destroyInstance(data.highlight)
    destroyInstance(data.billboard)
    data.highlight, data.billboard, data.ui = nil, nil, nil
    data.character, data.root, data.humanoid = nil, nil, nil
    data.visible = false
    if data.tracer then
        pcall(function() data.tracer.Visible = false end)
    end
end

local function buildCharacter(data, character)
    clearCharacter(data)
    local token = data.token
    data.character = character
    task.spawn(function()
        local root = character:WaitForChild("HumanoidRootPart", 5)
        local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
        if not root or not hum then return end
        if data.token ~= token or espObjects[data.player] ~= data then return end
        data.root = root
        data.humanoid = hum
        data.billboard = createBillboard(data, character:FindFirstChild("Head") or root)
    end)
end

local function setupPlayer(player)
    if player == LocalPlayer or espObjects[player] then return end
    local data = {
        player = player,
        conns = {},
        token = 0,
        visible = false,
        allowHL = false,
        dist = 0,
        color = Config.Colors.Enemy,
    }
    espObjects[player] = data

    data.conns[#data.conns + 1] = player.CharacterAdded:Connect(function(character)
        pcall(buildCharacter, data, character)
    end)
    data.conns[#data.conns + 1] = player.CharacterRemoving:Connect(function()
        pcall(clearCharacter, data)
    end)
    if player.Character then
        buildCharacter(data, player.Character)
    end
end

local function removePlayer(player)
    local data = espObjects[player]
    if not data then return end
    espObjects[player] = nil
    for _, conn in ipairs(data.conns) do
        pcall(function() conn:Disconnect() end)
    end
    clearCharacter(data)
    removeDrawing(data.tracer)
    data.tracer = nil
end

-- Определяем, нужно ли показывать игрока, и считаем дистанцию
local function computeVisible(player, data, origin)
    local root, hum = data.root, data.humanoid
    if not (root and root.Parent and hum and hum.Parent) then return false end
    if hum.Health <= 0 then return false end
    if State.TeamCheck and isAlly(player) then return false end
    data.dist = (root.Position - origin).Magnitude
    return data.dist <= State.MaxDistance
end

local function applyVisuals(data)
    local vis = data.visible

    -- Highlight (только для ближайших, чтобы не упереться в лимит)
    if vis and State.Highlight and data.allowHL and data.character then
        local hl = data.highlight
        if not hl or not hl.Parent then
            hl = createHighlight(data.character)
            data.highlight = hl
        end
        hl.FillColor = data.color
        hl.OutlineColor = data.color
        hl.Enabled = true
    elseif data.highlight then
        data.highlight.Enabled = false
    end

    -- Billboard: имя / дистанция / здоровье
    local bb, ui = data.billboard, data.ui
    if not bb or not ui then return end
    local showAny = vis and (State.Name or State.Distance or State.Health)
    bb.Enabled = showAny and true or false
    if not showAny then return end

    ui.name.Visible = State.Name
    ui.name.TextColor3 = data.color

    ui.dist.Visible = State.Distance
    if State.Distance then
        ui.dist.Text = string.format("%d studs", math.floor(data.dist + 0.5))
    end

    ui.hpText.Visible = State.Health
    ui.hpBack.Visible = State.Health
    if State.Health and data.humanoid then
        local hum = data.humanoid
        local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        local color = Config.Colors.HealthLow:Lerp(Config.Colors.HealthHigh, ratio)
        ui.hpText.Text = "HP " .. math.ceil(hum.Health)
        ui.hpText.TextColor3 = color
        ui.hpFill.Size = UDim2.fromScale(ratio, 1)
        ui.hpFill.BackgroundColor3 = color
    end
end

-- Медленный проход (раз в SlowInterval): видимость, текст, выбор Highlight
local function updateSlow()
    local cam = Workspace.CurrentCamera
    local lchar = LocalPlayer.Character
    local lroot = lchar and lchar:FindFirstChild("HumanoidRootPart")
    local origin
    if lroot then
        origin = lroot.Position
    elseif cam then
        origin = cam.CFrame.Position
    else
        return
    end

    local candidates = {}
    for player, data in pairs(espObjects) do
        data.visible = computeVisible(player, data, origin)
        data.allowHL = false
        if data.visible then
            data.color = getEspColor(player)
            candidates[#candidates + 1] = data
        end
    end

    -- Подсвечиваем только ближайших (лимит ~31 Highlight)
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    for i = 1, math.min(#candidates, Config.MaxHighlights) do
        candidates[i].allowHL = true
    end

    for _, data in pairs(espObjects) do
        applyVisuals(data)
    end
end

-- Быстрый проход (каждый кадр): линии Tracers
local function updateTracers()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local viewport = cam.ViewportSize
    local from = Vector2.new(viewport.X / 2, viewport.Y)
    for _, data in pairs(espObjects) do
        local line = data.tracer
        if data.visible and data.root and data.root.Parent then
            if not line then
                line = createLine()
                data.tracer = line
            end
            if line then
                local pos, onScreen = cam:WorldToViewportPoint(data.root.Position)
                if onScreen then
                    line.From = from
                    line.To = Vector2.new(pos.X, pos.Y)
                    line.Color = data.color
                    line.Visible = true
                else
                    line.Visible = false
                end
            end
        elseif line then
            line.Visible = false
        end
    end
end

local function clearTracers()
    for _, data in pairs(espObjects) do
        removeDrawing(data.tracer)
        data.tracer = nil
    end
end

local slowTimer = 0
local lastError
local function onRender(dt)
    slowTimer += dt
    if slowTimer >= Config.SlowInterval then
        slowTimer = 0
        local ok, err = pcall(updateSlow)
        if not ok and err ~= lastError then
            lastError = err
            warn("[EduESP] ESP:", err)
        end
    end

    if State.Tracers and drawingSupported then
        if pcall(updateTracers) then
            tracerErrors = 0
        else
            tracerErrors += 1
            if tracerErrors >= 5 then
                -- Drawing сломался на лету: отключаем трассеры
                State.Tracers = false
                drawingSupported = false
                pcall(clearTracers)
                if Hooks.onTracersFailed then
                    pcall(Hooks.onTracersFailed)
                end
            end
        end
    end
end

local function enableESP()
    if espEnabled then return end
    espEnabled = true
    for _, player in ipairs(Players:GetPlayers()) do
        pcall(setupPlayer, player)
    end
    espConnections[#espConnections + 1] = Players.PlayerAdded:Connect(function(player)
        pcall(setupPlayer, player)
    end)
    espConnections[#espConnections + 1] = Players.PlayerRemoving:Connect(function(player)
        pcall(removePlayer, player)
    end)
    espConnections[#espConnections + 1] = RunService.RenderStepped:Connect(onRender)
end

local function disableESP()
    espEnabled = false
    disconnectList(espConnections)
    for player in pairs(espObjects) do
        pcall(removePlayer, player)
    end
    table.clear(espObjects)
    slowTimer = 0
end

--==================================================================
-- 5. GUI
--==================================================================
local window, bubble, windowScale, bubbleScale
local menuVisible = true
local animToken = 0
local layoutCounter = 0

local function nextOrder()
    layoutCounter += 1
    return layoutCounter
end

-- Масштаб окна, чтобы оно помещалось на экране телефона
local function fitScale()
    local screen = getScreenSize()
    local margin = Config.ScreenMargin * 2
    local scale = math.min(
        (screen.X - margin) / Config.WindowSize.X,
        (screen.Y - margin) / Config.WindowSize.Y,
        1
    )
    return math.clamp(scale, 0.4, 1)
end

local function clampToScreen(frame)
    local screen = getScreenSize()
    local size = frame.AbsoluteSize
    local x = math.clamp(frame.Position.X.Offset, 0, math.max(0, screen.X - size.X))
    local y = math.clamp(frame.Position.Y.Offset, 0, math.max(0, screen.Y - size.Y))
    frame.Position = UDim2.fromOffset(x, y)
end

-- Перетаскивание мышью и тачем; onTap вызывается, если сдвиг меньше порога
local function makeDraggable(handle, target, onTap)
    local dragging = false
    local dragInput, startMouse, startPos
    local moved = 0

    connect(handle.InputBegan, function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging = true
            moved = 0
            dragInput = input
            startMouse = input.Position
            startPos = Vector2.new(target.Position.X.Offset, target.Position.Y.Offset)
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if not dragging then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == dragInput) then
            local delta = input.Position - startMouse
            local dist = Vector2.new(delta.X, delta.Y).Magnitude
            moved = math.max(moved, dist)
            if moved >= Config.TapThreshold then
                target.Position = UDim2.fromOffset(startPos.X + delta.X, startPos.Y + delta.Y)
            end
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if not dragging then return end
        local t = input.UserInputType
        local isMouse = t == Enum.UserInputType.MouseButton1
        local isTouch = t == Enum.UserInputType.Touch and input == dragInput
        if isMouse or isTouch then
            dragging = false
            clampToScreen(target)
            if moved < Config.TapThreshold and onTap then
                safeCall(onTap)
            end
        end
    end)
end

-- Показ/скрытие меню с анимацией (fade + scale)
local function setMenuVisible(visible)
    if not window or not bubble then return end
    menuVisible = visible and true or false
    animToken += 1
    local token = animToken
    local full = fitScale()

    if menuVisible then
        bubble.Visible = false
        window.Visible = true
        tween(window, Config.AnimTime, { GroupTransparency = 0 })
        tween(windowScale, Config.AnimTime, { Scale = full }, Enum.EasingStyle.Back)
    else
        tween(window, Config.AnimTime, { GroupTransparency = 1 })
        tween(windowScale, Config.AnimTime, { Scale = full * 0.85 })
        bubble.Visible = true
        bubbleScale.Scale = 0.5
        tween(bubbleScale, Config.AnimTime, { Scale = 1 }, Enum.EasingStyle.Back)
        task.delay(Config.AnimTime, function()
            if token == animToken and not menuVisible and window and window.Parent then
                window.Visible = false
            end
        end)
    end
end

-------------------------- Хелперы элементов --------------------------

local function createLabel(parent, text)
    return new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = text,
        TextColor3 = Config.Colors.SubText,
        TextSize = 12,
        TextWrapped = true,
        LayoutOrder = nextOrder(),
    }, parent)
end

local function createToggle(parent, text, default, callback)
    local C = Config.Colors
    local value = default and true or false
    local locked = false

    local row = new("Frame", {
        Name = "Toggle",
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = C.Element,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, parent)
    addCorner(row, 6)

    local label = new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -62, 1, 0),
        Font = Enum.Font.Gotham,
        Text = text,
        TextColor3 = C.Text,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    local switch = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(40, 20),
        BackgroundColor3 = value and C.Accent or C.Off,
        BorderSizePixel = 0,
    }, row)
    addCorner(switch, 10)

    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, switch)
    addCorner(knob, 8)

    local button = new("TextButton", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Text = "",
        AutoButtonColor = false,
    }, row)

    local function render(animate)
        local pos = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
        local col = value and C.Accent or C.Off
        if animate then
            tween(knob, 0.15, { Position = pos })
            tween(switch, 0.15, { BackgroundColor3 = col })
        else
            knob.Position = pos
            switch.BackgroundColor3 = col
        end
    end

    local api = { Instance = row }
    function api.Set(v, silent)
        v = v and true or false
        if v == value then return end
        value = v
        render(true)
        if not silent then
            safeCall(callback, value)
        end
    end
    function api.Get()
        return value
    end
    -- Блокировка опции (например, если Drawing не поддерживается)
    function api.Lock(note)
        locked = true
        value = false
        label.Text = text .. " (" .. note .. ")"
        label.TextColor3 = C.SubText
        render(false)
    end

    connect(button.Activated, function()
        if locked then return end
        api.Set(not value)
    end)
    return api
end

local function createSlider(parent, text, min, max, default, callback)
    local C = Config.Colors
    local value = math.clamp(math.floor(default + 0.5), min, max)
    local alpha0 = (value - min) / (max - min)

    local row = new("Frame", {
        Name = "Slider",
        Size = UDim2.new(1, 0, 0, 50),
        BackgroundColor3 = C.Element,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, parent)
    addCorner(row, 6)

    new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(10, 4),
        Size = UDim2.new(0.6, 0, 0, 20),
        Font = Enum.Font.Gotham,
        Text = text,
        TextColor3 = C.Text,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = new("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -10, 0, 4),
        Size = UDim2.new(0.4, -10, 0, 20),
        Font = Enum.Font.GothamBold,
        Text = tostring(value),
        TextColor3 = C.Accent,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)

    -- Увеличенная зона касания для телефона
    local hit = new("Frame", {
        Position = UDim2.new(0, 10, 0, 26),
        Size = UDim2.new(1, -20, 0, 20),
        BackgroundTransparency = 1,
        Active = true,
    }, row)
    local track = new("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.new(1, 0, 0, 6),
        BackgroundColor3 = C.Off,
        BorderSizePixel = 0,
    }, hit)
    addCorner(track, 3)
    local fill = new("Frame", {
        Size = UDim2.fromScale(alpha0, 1),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
    }, track)
    addCorner(fill, 3)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(alpha0, 0, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, track)
    addCorner(knob, 7)

    local function setValue(v)
        v = math.clamp(math.floor(v + 0.5), min, max)
        if v == value then return end
        value = v
        local a = (v - min) / (max - min)
        fill.Size = UDim2.fromScale(a, 1)
        knob.Position = UDim2.new(a, 0, 0.5, 0)
        valueLabel.Text = tostring(v)
        safeCall(callback, v)
    end

    local function fromInput(input)
        local width = hit.AbsoluteSize.X
        if width <= 0 then return end
        local a = math.clamp((input.Position.X - hit.AbsolutePosition.X) / width, 0, 1)
        setValue(min + a * (max - min))
    end

    local scroller = parent:IsA("ScrollingFrame") and parent or nil
    local dragging = false
    local dragInput

    connect(hit.InputBegan, function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging = true
            dragInput = input
            if scroller then scroller.ScrollingEnabled = false end
            fromInput(input)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if not dragging then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == dragInput) then
            fromInput(input)
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if not dragging then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or (t == Enum.UserInputType.Touch and input == dragInput) then
            dragging = false
            if scroller then scroller.ScrollingEnabled = true end
        end
    end)

    return { Instance = row, Get = function() return value end }
end

local function createButton(parent, text, callback)
    local btn = new("TextButton", {
        Name = "Button",
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Config.Colors.Accent,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        LayoutOrder = nextOrder(),
    }, parent)
    addCorner(btn, 6)
    connect(btn.Activated, function()
        btn.BackgroundTransparency = 0.35
        tween(btn, 0.2, { BackgroundTransparency = 0 })
        safeCall(callback)
    end)
    return btn
end

-------------------------- Сборка окна --------------------------

local function buildMenu(content)
    createToggle(content, "ESP", State.ESP, function(v)
        State.ESP = v
        if v then enableESP() else disableESP() end
    end)
    createToggle(content, "Highlight / Box", State.Highlight, function(v) State.Highlight = v end)
    createToggle(content, "Name", State.Name, function(v) State.Name = v end)
    createToggle(content, "Distance", State.Distance, function(v) State.Distance = v end)
    createToggle(content, "Health", State.Health, function(v) State.Health = v end)

    local tracersToggle = createToggle(content, "Tracers", State.Tracers, function(v)
        State.Tracers = v
        if not v then pcall(clearTracers) end
    end)
    if not drawingSupported then
        State.Tracers = false
        tracersToggle.Lock("не поддерживается")
    end
    Hooks.onTracersFailed = function() tracersToggle.Lock("ошибка Drawing") end

    createToggle(content, "Team Check", State.TeamCheck, function(v) State.TeamCheck = v end)
    createToggle(content, "Team Color", State.TeamColor, function(v) State.TeamColor = v end)
    createSlider(content, "Max Distance", Config.DistanceMin, Config.DistanceMax, State.MaxDistance, function(v)
        State.MaxDistance = v
    end)

    createLabel(content, "RightShift — скрыть / показать меню")
    local unloadBtn = createButton(content, "Unload", function()
        if Unload then Unload() end
    end)
    unloadBtn.BackgroundColor3 = Config.Colors.Danger
end

local function buildGui()
    local C = Config.Colors
    local screen = getScreenSize()
    local scale = fitScale()

    -- Главное окно (CanvasGroup — чтобы работал fade всего содержимого)
    window = new("CanvasGroup", {
        Name = randomName(),
        Size = UDim2.fromOffset(Config.WindowSize.X, Config.WindowSize.Y),
        Position = UDim2.fromOffset(
            math.floor((screen.X - Config.WindowSize.X * scale) / 2),
            math.floor((screen.Y - Config.WindowSize.Y * scale) / 2)
        ),
        BackgroundColor3 = C.Background,
        BorderSizePixel = 0,
        Active = true,
    }, screenGui)
    addCorner(window, 10)
    addStroke(window, C.Stroke, 1)
    windowScale = new("UIScale", { Scale = scale }, window)

    -- Заголовок
    local header = new("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, Config.HeaderHeight),
        BackgroundColor3 = C.Header,
        BorderSizePixel = 0,
        Active = true,
    }, window)
    new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(1, -52, 1, 0),
        Font = Enum.Font.GothamBold,
        Text = "Edu ESP",
        TextColor3 = C.Text,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)
    local minBtn = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -6, 0.5, 0),
        Size = UDim2.fromOffset(30, 22),
        BackgroundColor3 = C.Element,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "—",
        TextColor3 = C.Text,
        TextSize = 14,
    }, header)
    addCorner(minBtn, 5)
    connect(minBtn.Activated, function() setMenuVisible(false) end)

    -- Контент: ScrollingFrame + UIListLayout
    local content = new("ScrollingFrame", {
        Name = "Content",
        Position = UDim2.fromOffset(0, Config.HeaderHeight),
        Size = UDim2.new(1, 0, 1, -Config.HeaderHeight),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.Accent,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, window)
    new("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, content)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 10),
    }, content)

    buildMenu(content)

    -- Плавающая круглая кнопка (показывается, когда меню скрыто)
    bubble = new("TextButton", {
        Name = randomName(),
        Size = UDim2.fromOffset(Config.BubbleSize, Config.BubbleSize),
        Position = UDim2.fromOffset(screen.X - Config.BubbleSize - 12, math.floor(screen.Y * 0.35)),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "ESP",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 13,
        Visible = false,
        Active = true,
        ZIndex = 10,
    }, screenGui)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, bubble)
    addStroke(bubble, C.Stroke, 1)
    bubbleScale = new("UIScale", { Scale = 1 }, bubble)

    -- Перетаскивание: окно за заголовок, кнопка целиком (тап возвращает меню)
    makeDraggable(header, window)
    makeDraggable(bubble, bubble, function() setMenuVisible(true) end)

    -- Хоткей для ПК
    connect(UserInputService.InputBegan, function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Config.ToggleKey then
            setMenuVisible(not menuVisible)
        end
    end)

    -- Адаптация при смене размера экрана / поворота телефона
    connect(screenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
        local f = fitScale()
        windowScale.Scale = menuVisible and f or f * 0.85
        clampToScreen(window)
        clampToScreen(bubble)
    end)
end

--==================================================================
-- 6. INIT
--==================================================================
local unloaded = false

local function init()
    cleanupPrevious()
    if not createContainers() then return end
    buildGui()
    getEnv().__EduESP_Unload = function()
        if Unload then Unload() end
    end
    if State.ESP then
        enableESP()
    end
end

--==================================================================
-- 7. UNLOAD
--==================================================================
Unload = function()
    if unloaded then return end
    unloaded = true
    pcall(disableESP)
    pcall(clearTracers)
    disconnectList(connections)
    destroyInstance(screenGui)
    destroyInstance(espFolder)
    screenGui, espFolder, window, bubble = nil, nil, nil, nil
    pcall(function() getEnv().__EduESP_Unload = nil end)
end

-- Запуск
local ok, err = pcall(init)
if not ok then
    warn("[EduESP] ошибка инициализации:", err)
    pcall(Unload)
end
Запуск: вставьте код в Delta и нажмите Execute, уже находясь в игре. Повторный запуск сам удаляет предыдущую копию.
Скрыть и вернуть: кнопка «—» в заголовке или RightShift на ПК. Меню превращается в круглую кнопку «ESP», тап по ней возвращает окно. И окно, и кнопка перетаскиваются.
Tracers: работает только при наличии Drawing API в Delta. Если его нет, переключатель блокируется с пометкой «не поддерживается».
Новая функция: в buildMenu добавьте createToggle(content, "Название", false, function(v) ... end). Слайдер и кнопка добавляются так же, через createSlider и createButton.
Настройки: цвета, размеры, значения по умолчанию и лимит Highlight лежат в Config.
Unload: удаляет GUI и ESP-объекты, отключает все соединения и очищает глобальную ссылку на себя.