local _, ns = ...

-- "What did my partner do that I haven't?" built from synced, live and same-account snapshots.

local window, partnerDropdown, partnerCycle, hideDoneCheck, hideUnavailCheck

local SOURCE_LABEL = { sync = "sync app", live = "playing together", account = "this account" }

local function Done(id)
    return C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) or false
end

local function MyLogIndex(id)
    return C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
end

local function ClassName(key, c)
    local col = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    local name = ns.ShortName(key)
    if col and col.colorStr then return "|c" .. col.colorStr .. name .. "|r" end
    return name
end

-- Sorted candidate partners: everyone but me, other accounts first, newest first
local function Candidates(chars)
    local me = ns.MyKey()
    local list = {}
    for key, c in pairs(chars) do
        if key ~= me then table.insert(list, key) end
    end
    table.sort(list, function(a, b)
        local ea = chars[a].sources and not chars[a].sources.account and 1 or 0
        local eb = chars[b].sources and not chars[b].sources.account and 1 or 0
        if ea ~= eb then return ea > eb end
        return (chars[a].updated or 0) > (chars[b].updated or 0)
    end)
    return list
end

local function SelectedPartner(chars)
    local me = ns.MyKey()
    local key = ns.db.settings.partnerFor[me]
    if key and chars[key] then return key end
    return Candidates(chars)[1]
end

local function SetPartner(key)
    ns.db.settings.partnerFor[ns.MyKey()] = key
    ns:RefreshCatchUp()
end

-- Status of a quest on *my* character, for the right-hand column and colouring
local function MyStatus(id, myLog)
    if Done(id) then return "|cff888888done|r", { 0.5, 0.5, 0.5 }, "You've already turned this in." end
    local q = myLog[id]
    if q then
        if q.ready then return "|cff40ff40ready|r", { 0.4, 1, 0.4 }, "In your log and ready to turn in." end
        return "|cffffd100" .. (ns.ProgressText(q) ~= "" and ns.ProgressText(q) or "in log") .. "|r", { 1, 0.85, 0.3 }, "In your log."
    end
    return "", nil, "You haven't picked this up."
end

local function Include(id, hideDone, hideUnavail)
    if hideDone and Done(id) then return false end
    if hideUnavail and not ns.Questie.AvailableToMe(id) then return false end
    if ns.Questie.IsRepeatable(id) then return false end
    return true
end

local function Row(id, title, myLog, extraTooltip, theirProgress)
    local status, color, statusText = MyStatus(id, myLog)
    return {
        kind = "quest",
        id = id,
        text = title,
        right = theirProgress or status,
        color = color,
        indent = 6,
        tooltip = function(tt)
            tt:AddLine(title, 1, 1, 1, true)
            tt:AddLine("Quest ID: " .. id, 0.7, 0.7, 0.7)
            if extraTooltip then extraTooltip(tt) end
            tt:AddLine(statusText, 0.6, 0.9, 1, true)
            if myLog[id] then ns.ObjectiveLines(tt, myLog[id].obj) end
            tt:AddLine(MyLogIndex(id) and "Click to track/untrack - right-click for options" or "Right-click for options", 0.5, 0.5, 0.5)
        end,
        onClick = function(button)
            if button == "RightButton" then
                ns.QuestMenu(id, title)
            elseif MyLogIndex(id) then
                if C_QuestLog.GetQuestWatchType(id) ~= nil then C_QuestLog.RemoveQuestWatch(id) else C_QuestLog.AddQuestWatch(id) end
            end
        end,
    }
end

local function ZoneForQuest(id)
    local z = ns.Questie.Query(id, "zoneOrSort")
    if type(z) == "number" and z > 0 and C_Map.GetAreaInfo then
        local name = C_Map.GetAreaInfo(z)
        if name and name ~= "" then return name end
    end
    return "Other"
end

function ns:RefreshCatchUp()
    if not window or not window:IsShown() then return end
    local chars = ns.GetCharacters()
    local partnerKey = SelectedPartner(chars)
    local hideDone = ns.GetSetting("hideDoneInCatchUp")
    local hideUnavail = ns.GetSetting("hideUnavailable")
    local myLog = ns.ReadQuestLog()

    -- Partner picker
    local label = partnerKey and ns.ShortName(partnerKey) or "No partner data"
    if partnerDropdown then
        partnerDropdown:SetupMenu(function(_, root)
            local list = Candidates(chars)
            if #list == 0 then root:CreateTitle("No characters found yet") end
            for _, key in ipairs(list) do
                local c = chars[key]
                root:CreateRadio(string.format("%s  (%s, %s)", ClassName(key, c), c.level and ("lvl " .. c.level) or "?", ns.Ago(c.updated)),
                    function() return key == partnerKey end,
                    function() SetPartner(key) end)
            end
        end)
        if partnerDropdown.OverrideText then partnerDropdown:OverrideText(label) end
    elseif partnerCycle then
        partnerCycle:SetText(label)
    end
    hideDoneCheck:SetChecked(hideDone)
    hideUnavailCheck:SetChecked(hideUnavail)
    hideUnavailCheck:SetEnabled(ns.Questie.Loaded())

    local rows = {}
    if not partnerKey then
        table.insert(rows, { kind = "note", text = "No partner data yet.\n\nRun the QuestPact sync app on both PCs (pointed at the same shared folder), then log in and out once on each character so it has something to export. After a sync, /reload or relog to load the new data.\n\nPlaying in a group together also records your partner's progress, no app needed." })
        window:SetRows(rows)
        return
    end

    local p = chars[partnerKey]
    local sources = {}
    for s in pairs(p.sources or {}) do table.insert(sources, SOURCE_LABEL[s] or s) end
    table.sort(sources)
    table.insert(rows, { kind = "heading", text = string.format("%s - level %s %s", ClassName(partnerKey, p), p.level or "?", p.zone and ("in " .. p.zone) or "") })
    table.insert(rows, { kind = "note", text = string.format("Updated %s via %s.  You are level %d.", ns.Ago(p.updated), table.concat(sources, ", "), UnitLevel("player")) })
    if p.faction and p.faction ~= UnitFactionGroup("player") then
        table.insert(rows, { kind = "note", text = "|cffff6060Heads up: " .. ns.ShortName(partnerKey) .. " is " .. p.faction .. ". Most quests won't line up.|r" })
    end
    table.insert(rows, { kind = "spacer", h = 6 })

    -- 1. Turn-ins with details, in the order they happened (follows their route)
    local seen = {}
    local route, count = {}, 0
    local lastZone
    for _, h in ipairs(p.history or {}) do
        if not seen[h.id] then
            seen[h.id] = true
            if Include(h.id, hideDone, hideUnavail) then
                local zone = h.zone or "Other"
                if zone ~= lastZone then
                    table.insert(route, { kind = "sub", text = zone })
                    lastZone = zone
                end
                local title = ns.QuestTitle(h.id, h.title)
                table.insert(route, Row(h.id, title, myLog, function(tt)
                    tt:AddLine(string.format("%s turned this in %s%s.", ns.ShortName(partnerKey), ns.Ago(h.t),
                        h.lvl and (" at level " .. h.lvl) or ""), 1, 0.82, 0, true)
                end))
                count = count + 1
            end
        end
    end
    table.insert(rows, { kind = "heading", text = string.format("Turned in, in order (%d)", count), color = { 1, 0.82, 0 } })
    if count == 0 then
        table.insert(rows, { kind = "note", text = hideDone and "Nothing to catch up on - you've done everything they've turned in since installing QuestPact." or "No recorded turn-ins yet." })
    else
        for _, r in ipairs(route) do table.insert(rows, r) end
    end
    table.insert(rows, { kind = "spacer", h = 10 })

    -- 2. Current quest log
    local logIds = {}
    for id in pairs(p.log or {}) do
        if Include(id, hideDone, hideUnavail) then table.insert(logIds, id) end
    end
    table.sort(logIds, function(a, b)
        local ha, hb = p.log[a].header or "", p.log[b].header or ""
        if ha ~= hb then return ha < hb end
        return a < b
    end)
    table.insert(rows, { kind = "heading", text = string.format("In %s's quest log (%d)", ns.ShortName(partnerKey), #logIds), color = { 0.5, 0.8, 1 } })
    local lastHeader
    for _, id in ipairs(logIds) do
        local q = p.log[id]
        if q.header and q.header ~= lastHeader then
            table.insert(rows, { kind = "sub", text = q.header })
            lastHeader = q.header
        end
        local title = ns.QuestTitle(id, q.title)
        local status = MyStatus(id, myLog)
        table.insert(rows, Row(id, title, myLog, function(tt)
            tt:AddLine(ns.ShortName(partnerKey) .. ": " .. ns.ProgressText(q), 1, 0.82, 0)
            ns.ObjectiveLines(tt, q.obj)
        end, "|cffcccccc" .. ns.ProgressText(q) .. "|r" .. (status ~= "" and ("  " .. status) or "")))
    end
    table.insert(rows, { kind = "spacer", h = 10 })

    -- 3. Completed before QuestPact recorded details (from the server's completed list)
    local older, groups, order = 0, {}, {}
    for id in pairs(p.completed or {}) do
        if not seen[id] and Include(id, true, hideUnavail) then
            local zone = ZoneForQuest(id)
            if not groups[zone] then
                groups[zone] = {}
                table.insert(order, zone)
            end
            table.insert(groups[zone], id)
            older = older + 1
        end
    end
    if older > 0 then
        table.sort(order)
        table.insert(rows, { kind = "heading", text = string.format("Other quests they've done that you haven't (%d)", older), color = { 0.8, 0.8, 0.8 } })
        if not ns.Questie.Loaded() then
            table.insert(rows, { kind = "note", text = "Install Questie to see names and zones for these." })
        end
        for _, zone in ipairs(order) do
            table.insert(rows, { kind = "sub", text = zone })
            table.sort(groups[zone])
            for _, id in ipairs(groups[zone]) do
                table.insert(rows, Row(id, ns.QuestTitle(id), myLog))
            end
        end
        table.insert(rows, { kind = "spacer", h = 10 })
    end

    -- 4. Where you're ahead
    if p.completed and next(p.completed) then
        local ahead = 0
        for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs and C_QuestLog.GetAllCompletedQuestIDs() or {}) do
            if not p.completed[id] then ahead = ahead + 1 end
        end
        table.insert(rows, { kind = "note", text = string.format("You've completed %d quests %s hasn't.", ahead, ns.ShortName(partnerKey)) })
    end

    window:SetRows(rows)
end

-- Longer delay than the party window: this walks the partner's whole completed list
local refreshSoon = ns.Debounce(1.5, function() ns:RefreshCatchUp() end)
ns:On("SNAPSHOT_UPDATED", refreshSoon)
ns:On("QUEST_LOG_UPDATE", refreshSoon)
ns:On("PARTY_CHANGED", refreshSoon)
ns:On("SETTINGS_CHANGED", refreshSoon)

local function MakeCheck(parent, label, settingKey)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 0, 1)
    text:SetText(label)
    cb.label = text
    cb:SetScript("OnClick", function(self) ns.SetSetting(settingKey, self:GetChecked() and true or false) end)
    return cb
end

function ns:ToggleCatchUp()
    if not window then
        window = ns.CreateListWindow({
            name = "QuestPactCatchUpWindow", title = "QuestPact - Catch Up", posKey = "catchup",
            width = 440, height = 460, toolbarHeight = 52, offsetX = 40, offsetY = -20,
        })
        local tb = window.toolbar
        local who = tb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        who:SetPoint("TOPLEFT", 2, -4)
        who:SetText("Partner:")

        local ok, dd = pcall(CreateFrame, "DropdownButton", nil, tb, "WowStyle1DropdownTemplate")
        if ok and dd and dd.SetupMenu then
            partnerDropdown = dd
            dd:SetPoint("LEFT", who, "RIGHT", 8, 0)
            dd:SetWidth(200)
        else
            -- Fallback: a button that cycles through characters
            partnerCycle = CreateFrame("Button", nil, tb, "UIPanelButtonTemplate")
            partnerCycle:SetSize(200, 22)
            partnerCycle:SetPoint("LEFT", who, "RIGHT", 8, 0)
            partnerCycle:SetScript("OnClick", function()
                local chars = ns.GetCharacters()
                local list = Candidates(chars)
                local cur = SelectedPartner(chars)
                for i, key in ipairs(list) do
                    if key == cur then SetPartner(list[i % #list + 1]) return end
                end
            end)
        end

        hideDoneCheck = MakeCheck(tb, "Hide what I've done", "hideDoneInCatchUp")
        hideDoneCheck:SetPoint("TOPLEFT", 0, -28)
        hideUnavailCheck = MakeCheck(tb, "Hide quests I can't take (Questie)", "hideUnavailable")
        hideUnavailCheck:SetPoint("LEFT", hideDoneCheck.label, "RIGHT", 12, -1)

        window.frame:HookScript("OnShow", function() ns:RefreshCatchUp() end)
    end
    if window:IsShown() then window:Hide() else window:Show() end
end
