local _, ns = ...

local category

local SIZES = { { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" } }

local function Check(panel, anchor, label, desc, get, set)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
    local d = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    d:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 30, 2)
    d:SetWidth(520)
    d:SetJustifyH("LEFT")
    d:SetText(desc)
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return d
end

ns:On("INIT", function()
    local panel = CreateFrame("Frame")
    panel.name = "QuestPact"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("QuestPact " .. ns.VERSION)

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetText("/qp - party quests     /qp catchup - catch up with a partner     /qp status - sync status")

    local sizeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -20)
    sizeLabel:SetText("Text size:")

    local sizeButtons = {}
    local prev = sizeLabel
    for _, s in ipairs(SIZES) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(80, 22)
        b:SetPoint("LEFT", prev, "RIGHT", 8, 0)
        b:SetText(s[2])
        b:SetScript("OnClick", function()
            ns.SetSetting("textSize", s[1])
            for key, btn in pairs(sizeButtons) do btn:SetEnabled(key ~= s[1]) end
        end)
        sizeButtons[s[1]] = b
        prev = b
    end
    panel:SetScript("OnShow", function()
        for key, btn in pairs(sizeButtons) do btn:SetEnabled(key ~= ns.GetSetting("textSize")) end
    end)

    local a = Check(panel, sizeLabel, "Always be the QuestPact leader",
        "The leader's skip list applies to the whole group. If several people tick this, the alphabetically first name leads; otherwise the group leader does.",
        function() return ns.GetSetting("alwaysLeader") end,
        function(v)
            ns.SetSetting("alwaysLeader", v)
            ns.BroadcastLeaderPref()
        end)
    a = Check(panel, a, "Auto-track quests the whole group shares",
        "Adds shared quests to the objective tracker while grouped. Only quests QuestPact tracked are ever untracked again.",
        function() return ns.GetSetting("autoTrackShared") end,
        function(v) ns.SetSetting("autoTrackShared", v) end)
    a = Check(panel, a, "Show minimap button",
        "The addon compartment entry (minimap addon dropdown) is always available.",
        function() return not ns.db.hideMinimap end,
        function(v)
            ns.db.hideMinimap = not v
            if ns.minimapButton then ns.minimapButton:SetShown(v) end
        end)

    local syncHead = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    syncHead:SetPoint("TOPLEFT", a, "BOTTOMLEFT", -30, -24)
    syncHead:SetText("Offline sync")
    local syncText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    syncText:SetPoint("TOPLEFT", syncHead, "BOTTOMLEFT", 0, -6)
    syncText:SetWidth(560)
    syncText:SetJustifyH("LEFT")
    syncText:SetText("Every character's quest log, completed quests and turn-in history are saved when you log out. "
        .. "The QuestPact sync app copies them to a shared folder and writes your partner's characters into "
        .. "Interface\\AddOns\\QuestPact\\PartnerData.lua. Type /reload after a sync to load new partner data.")

    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
end)

function ns:OpenOptions()
    if category then Settings.OpenToCategory(category:GetID()) end
end
