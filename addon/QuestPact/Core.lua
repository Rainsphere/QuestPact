local ADDON_NAME, ns = ...

-- Flavor detection: never trust WOW_PROJECT_ID alone on Forever
local TOC = select(4, GetBuildInfo())
ns.IS_FOREVER = TOC >= 16000 and TOC < 20000

ns.VERSION = "1.0.0"
ns.DATA_VERSION = 1
ns.HISTORY_CAP = 600

local defaults = {
    version = ns.DATA_VERSION,
    settings = {
        textSize = "medium",      -- small, medium, large
        alwaysLeader = false,
        autoTrackShared = true,
        hideDoneInCatchUp = true,
        hideUnavailable = true,   -- needs Questie: hide class/race quests you can't take
        partnerFor = {},          -- [myCharKey] = partnerCharKey
    },
    positions = {},
    minimapAngle = 225,
    hideMinimap = false,
    skip = {},                    -- leader's skip list: [questID] = true
    chars = {},                   -- [charKey] = snapshot (see Snapshot.lua)
    live = {},                    -- [charKey] = snapshot heard live over party comms
}

ns.db = nil -- bound in ADDON_LOADED, never at file scope

function ns:Print(msg)
    print("|cff33ff99QuestPact|r: " .. msg)
end

---------------------------------------------------------------------------
-- Secret-safe helpers
---------------------------------------------------------------------------

-- Returns v only if this code may inspect it
function ns.Safe(v)
    if issecretvalue and issecretvalue(v) then return nil end -- before the nil test
    if canaccessvalue and not canaccessvalue(v) then return nil end
    return v
end

function ns.ShortName(name)
    if not name then return "?" end
    return name:match("^[^%-]+") or name
end

function ns.Realm()
    return GetNormalizedRealmName() or (GetRealmName() or ""):gsub("[%s%-]", "")
end

-- "Name-Realm", matching the sender format of CHAT_MSG_ADDON
function ns.FullName(name)
    if not name then return nil end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. ns.Realm()
end

function ns.MyKey()
    return ns.FullName(UnitName("player"))
end

function ns.CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ns.CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function ns.Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function ns.Ago(t)
    if not t then return "never" end
    local d = time() - t
    if d < 90 then return "just now" end
    if d < 5400 then return math.floor(d / 60) .. " min ago" end
    if d < 129600 then return math.floor(d / 3600) .. " hr ago" end
    return math.floor(d / 86400) .. " days ago"
end

function ns.GetSetting(key)
    return ns.db.settings[key]
end

function ns.SetSetting(key, value)
    ns.db.settings[key] = value
    ns:Fire("SETTINGS_CHANGED", key, value)
end

function ns.GetFonts()
    local size = ns.GetSetting("textSize")
    if size == "small" then
        return "GameFontHighlightSmall", "GameFontNormalSmall", "GameFontNormal"
    elseif size == "large" then
        return "GameFontNormal", "GameFontNormalLarge", "GameFontNormalHuge"
    end
    return "GameFontHighlightSmall", "GameFontNormal", "GameFontNormalLarge"
end

---------------------------------------------------------------------------
-- Event and message bus: modules subscribe with ns:On(event, fn)
---------------------------------------------------------------------------

local handlers = {}
local eventFrame = CreateFrame("Frame")

-- RegisterEvent throws on unknown events, and an uncaught error aborts the rest of the file
local function SafeRegister(event)
    return pcall(eventFrame.RegisterEvent, eventFrame, event)
end

function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if event:match("^[A-Z_]+$") then SafeRegister(event) end
    end
    table.insert(handlers[event], fn)
end

-- Internal messages use lower/mixed case names so they never hit RegisterEvent
function ns:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    ns:Fire(event, ...)
end)

-- Debounce: run fn once, delay seconds after the last call
function ns.Debounce(delay, fn)
    local pending = false
    local again = false
    local function run()
        if again then
            again = false
            C_Timer.After(delay, run)
            return
        end
        pending = false
        fn()
    end
    return function()
        if pending then again = true return end
        pending = true
        C_Timer.After(delay, run)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

SafeRegister("ADDON_LOADED")
handlers.ADDON_LOADED = { function(name)
    if name ~= ADDON_NAME then return end
    QuestPactDB = QuestPactDB or {}
    ns.CopyDefaults(defaults, QuestPactDB)
    ns.db = QuestPactDB
    ns:Fire("DB_READY")
end }

ns:On("PLAYER_LOGIN", function()
    ns:CreateMinimapButton()
    ns:Fire("INIT")
end)

---------------------------------------------------------------------------
-- Minimap button (drag around the rim)
---------------------------------------------------------------------------

function ns:CreateMinimapButton()
    if self.minimapButton or not Minimap then return end
    local b = CreateFrame("Button", "QuestPactMinimapButton", Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local function UpdatePosition()
        local a = ns.db.minimapAngle or 225
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 100, math.sin(a) * 100)
    end

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns:ToggleCatchUp()
        elseif IsShiftKeyDown() then
            ns:OpenOptions()
        else
            ns:TogglePartyWindow()
        end
    end)
    b:SetScript("OnEnter", function(self) ns:ShowLauncherTooltip(self) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self) self.dragging = true end)
    b:SetScript("OnDragStop", function(self) self.dragging = false end)
    b:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        ns.db.minimapAngle = math.atan2(py / scale - my, px / scale - mx)
        UpdatePosition()
    end)

    UpdatePosition()
    b:SetShown(not ns.db.hideMinimap)
    self.minimapButton = b
end

function ns:ShowLauncherTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("QuestPact", 1, 1, 1)
    GameTooltip:AddLine("Left-click: Party quests", 0.5, 1, 0.5)
    GameTooltip:AddLine("Right-click: Catch up with partner", 0.5, 1, 0.5)
    GameTooltip:AddLine("Shift-click: Settings", 0.5, 1, 0.5)
    GameTooltip:Show()
end

-- Addon compartment (minimap addon dropdown); globals named in the TOC
function QuestPact_OnCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then ns:ToggleCatchUp() else ns:TogglePartyWindow() end
end
function QuestPact_OnCompartmentEnter(_, menuButtonFrame)
    ns:ShowLauncherTooltip(menuButtonFrame)
end
function QuestPact_OnCompartmentLeave()
    GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_QUESTPACT1 = "/questpact"
SLASH_QUESTPACT2 = "/qp"
SlashCmdList.QUESTPACT = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" or msg == "party" then
        ns:TogglePartyWindow()
    elseif msg == "catchup" or msg == "cu" then
        ns:ToggleCatchUp()
    elseif msg == "config" or msg == "options" or msg == "settings" then
        ns:OpenOptions()
    elseif msg == "snapshot" then
        ns:TakeSnapshot(true)
        ns:Print("Snapshot saved. It reaches disk on logout or /reload.")
    elseif msg == "status" then
        local pd = QuestPact_PartnerData
        local n = pd and pd.chars and ns.Count(pd.chars) or 0
        ns:Print(string.format("Synced partner characters: %d (exported %s). Live partners: %d.",
            n, ns.Ago(pd and pd.generated), ns.Count(ns.db.live)))
    else
        ns:Print("/qp  party window | /qp catchup | /qp config | /qp snapshot | /qp status")
    end
end
