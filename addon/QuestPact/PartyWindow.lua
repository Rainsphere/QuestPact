local _, ns = ...

local CLASS_COLORS = RAID_CLASS_COLORS or {}
local window, leaderLabel

local function Colored(key, class)
    local c = class and CLASS_COLORS[class]
    local name = ns.ShortName(key)
    if c and c.colorStr then return "|c" .. c.colorStr .. name .. "|r" end
    return name
end

local function IsWatched(questID)
    return C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil
end

-- Does this member have questID? Uses their broadcast log, else the server's IsUnitOnQuest.
local function MemberHas(m, questID)
    local p = ns.party[m.key]
    if p and p.log then return p.log[questID] ~= nil, p.log[questID] end
    if C_QuestLog.IsUnitOnQuest then
        local ok, has = pcall(C_QuestLog.IsUnitOnQuest, m.unit, questID)
        if ok and ns.Safe(has) then return true, nil end
    end
    return false
end

---------------------------------------------------------------------------
-- Auto-track quests everyone shares; only ever untrack what we tracked
---------------------------------------------------------------------------

local autoTracked = {}

local function AutoTrack()
    if not ns.db or InCombatLockdown() then return end
    if not ns.GetSetting("autoTrackShared") then return end
    local members = ns.GroupMembers()
    if #members == 0 then
        wipe(autoTracked)
        return
    end
    local skip = ns.EffectiveSkip()
    for id in pairs(ns.ReadQuestLog()) do
        local shared = true
        for _, m in ipairs(members) do
            if not MemberHas(m, id) then shared = false break end
        end
        local watched = IsWatched(id)
        if skip[id] then
            if watched then C_QuestLog.RemoveQuestWatch(id) end
            autoTracked[id] = nil
        elseif shared and not watched then
            C_QuestLog.AddQuestWatch(id)
            autoTracked[id] = true
        elseif not shared and watched and autoTracked[id] then
            C_QuestLog.RemoveQuestWatch(id)
            autoTracked[id] = nil
        end
    end
end

local autoTrackSoon = ns.Debounce(1.5, AutoTrack)
ns:On("PARTY_CHANGED", autoTrackSoon)
ns:On("QUEST_LOG_UPDATE", autoTrackSoon)
ns:On("PLAYER_REGEN_ENABLED", autoTrackSoon)

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function QuestRow(id, title, progress, color, isLeader, skip, tooltip)
    return {
        kind = "quest",
        id = id,
        text = title,
        right = progress,
        color = color,
        indent = 6,
        check = {
            checked = skip[id],
            enabled = isLeader,
            onClick = function(checked)
                ns.db.skip[id] = checked or nil
                if checked and IsWatched(id) then C_QuestLog.RemoveQuestWatch(id) end
                ns.BroadcastSkip()
                ns:RefreshPartyWindow()
            end,
        },
        tooltip = tooltip,
        onClick = function(button)
            if button == "RightButton" then ns.QuestMenu(id, title) end
        end,
    }
end

local function ByHeader(ids, log)
    local groups, order = {}, {}
    for _, id in ipairs(ids) do
        local h = (log[id] and log[id].header) or "Other"
        if not groups[h] then
            groups[h] = {}
            table.insert(order, h)
        end
        table.insert(groups[h], id)
    end
    table.sort(order)
    return groups, order
end

function ns:RefreshPartyWindow()
    if not window or not window:IsShown() then return end
    local members = ns.GroupMembers()
    local myLog, myOrder = ns.ReadQuestLog()
    local skip = ns.EffectiveSkip()
    local isLeader = ns.IsLeader()

    leaderLabel:SetText("Leader: " .. ns.ShortName(ns.GetLeader())
        .. (isLeader and "  |cff888888(tick a box to skip a quest for the group)|r" or ""))

    local function Tooltip(id, title)
        return function(tt)
            tt:AddLine(title, 1, 1, 1, true)
            tt:AddLine("Quest ID: " .. id, 0.7, 0.7, 0.7)
            if myLog[id] then
                tt:AddLine("You:", 0.5, 1, 0.5)
                ns.ObjectiveLines(tt, myLog[id].obj)
            end
            for _, m in ipairs(members) do
                local has, q = MemberHas(m, id)
                if has then
                    local p = ns.party[m.key]
                    tt:AddLine(Colored(m.key, p and p.info and p.info.class) .. ":  " .. ns.ProgressText(q), 0.5, 1, 0.5)
                    if q then ns.ObjectiveLines(tt, q.obj) end
                end
            end
            if skip[id] then tt:AddLine("Skipped by the leader", 1, 0.4, 0.4) end
            tt:AddLine("Right-click for options", 0.5, 0.5, 0.5)
        end
    end

    local rows = {}
    local shared, mine = {}, {}
    for _, id in ipairs(myOrder) do
        local all = #members > 0
        for _, m in ipairs(members) do
            if not MemberHas(m, id) then all = false break end
        end
        table.insert(all and shared or mine, id)
    end

    if #members == 0 then
        table.insert(rows, { kind = "note", text = "You're not in a group. Your quests are listed below; group up with another QuestPact user to compare logs live, or right-click the minimap button to catch up with a partner offline." })
    end

    if #shared > 0 then
        table.insert(rows, { kind = "heading", text = string.format("Shared by everyone (%d)", #shared), color = { 0.5, 0.8, 1 } })
        local groups, order = ByHeader(shared, myLog)
        for _, h in ipairs(order) do
            table.insert(rows, { kind = "sub", text = h })
            for _, id in ipairs(groups[h]) do
                local q = myLog[id]
                table.insert(rows, QuestRow(id, q.title or ns.QuestTitle(id), ns.ProgressText(q), skip[id] and { 0.5, 0.5, 0.5 }, isLeader, skip, Tooltip(id, q.title)))
            end
        end
        table.insert(rows, { kind = "spacer", h = 10 })
    end

    if #mine > 0 then
        table.insert(rows, { kind = "heading", text = string.format("%s (You) - %d", UnitName("player"), #mine) })
        local groups, order = ByHeader(mine, myLog)
        for _, h in ipairs(order) do
            table.insert(rows, { kind = "sub", text = h })
            for _, id in ipairs(groups[h]) do
                local q = myLog[id]
                table.insert(rows, QuestRow(id, q.title or ns.QuestTitle(id), ns.ProgressText(q), skip[id] and { 0.5, 0.5, 0.5 }, isLeader, skip, Tooltip(id, q.title)))
            end
        end
        table.insert(rows, { kind = "spacer", h = 10 })
    end

    -- Quests members have that you don't (only knowable from QuestPact users)
    for _, m in ipairs(members) do
        local p = ns.party[m.key]
        local theirs = {}
        if p and p.log then
            for id, q in pairs(p.log) do
                if not myLog[id] then table.insert(theirs, id) end
            end
        end
        table.sort(theirs)
        local label = Colored(m.key, p and p.info and p.info.class)
        if p and p.info and p.info.level then label = label .. string.format(" (%d)", p.info.level) end
        if not p or not p.log then
            table.insert(rows, { kind = "heading", text = label })
            table.insert(rows, { kind = "note", text = "Not running QuestPact. Only quests you both have can be detected." })
        elseif #theirs > 0 then
            table.insert(rows, { kind = "heading", text = string.format("%s - %d you don't have", label, #theirs) })
            for _, id in ipairs(theirs) do
                local q = p.log[id]
                local title = ns.QuestTitle(id, q.title)
                local done = C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id)
                table.insert(rows, QuestRow(id, title .. (done and " |cff888888(you've done it)|r" or ""), ns.ProgressText(q), { 0.85, 0.85, 0.85 }, isLeader, skip, Tooltip(id, title)))
            end
        end
        table.insert(rows, { kind = "spacer", h = 10 })
    end

    if next(ns.recentDone) then
        table.insert(rows, { kind = "heading", text = "Recently completed by party", color = { 1, 0.82, 0 } })
        for id, d in pairs(ns.recentDone) do
            table.insert(rows, {
                kind = "quest", id = id,
                text = ns.QuestTitle(id, d.title),
                right = "|cff90ee90" .. d.by .. "|r",
                tooltip = function(tt)
                    tt:AddLine(ns.QuestTitle(id, d.title), 1, 1, 1, true)
                    tt:AddLine(d.by .. " turned this in " .. ns.Ago(d.t) .. ".", 0.8, 0.8, 0.8, true)
                    tt:AddLine("Click to dismiss", 0.5, 0.5, 0.5)
                end,
                onClick = function()
                    ns.recentDone[id] = nil
                    ns:RefreshPartyWindow()
                end,
            })
        end
    end

    window:SetRows(rows)
end

local refreshSoon = ns.Debounce(0.5, function() ns:RefreshPartyWindow() end)
ns:On("PARTY_CHANGED", refreshSoon)
ns:On("QUEST_LOG_UPDATE", refreshSoon)
ns:On("QUEST_WATCH_LIST_CHANGED", refreshSoon)
ns:On("SETTINGS_CHANGED", refreshSoon)

function ns:TogglePartyWindow()
    if not window then
        window = ns.CreateListWindow({
            name = "QuestPactPartyWindow", title = "QuestPact - Party Quests", posKey = "party",
            width = 420, height = 380, toolbarHeight = 24,
        })
        leaderLabel = window.toolbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        leaderLabel:SetPoint("LEFT", 2, 0)
        leaderLabel:SetPoint("RIGHT", -96, 0)
        leaderLabel:SetJustifyH("LEFT")
        leaderLabel:SetTextColor(1, 0.85, 0)
        local btn = CreateFrame("Button", nil, window.toolbar, "UIPanelButtonTemplate")
        btn:SetSize(90, 20)
        btn:SetPoint("RIGHT", 0, 0)
        btn:SetText("Catch up")
        btn:SetScript("OnClick", function() ns:ToggleCatchUp() end)
        window.frame:HookScript("OnShow", function() ns:RefreshPartyWindow() end)
    end
    if window:IsShown() then window:Hide() else window:Show() end
end
