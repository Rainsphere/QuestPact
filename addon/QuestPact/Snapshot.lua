local _, ns = ...

-- Per-character snapshot, stored account-wide under QuestPactDB.chars[charKey]:
-- {
--   name, realm, class, race, faction, level, zone, updated,
--   log       = { [questID] = { title, header, level, ready, failed, obj = { {text, have, need, done} } } },
--   completed = { [questID] = true },
--   history   = { { id, title, zone, t, lvl }, ... }   -- turn-ins in order, capped at ns.HISTORY_CAP
-- }
-- The sync app reads this from WTF\Account\<ACCOUNT>\SavedVariables\QuestPact.lua.

local function IsHiddenQuest(questID)
    local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
    local name = tag and ns.Safe(tag.tagName)
    return name and name:lower() == "hidden quest"
end

local function ReadObjectives(questID)
    local out = {}
    local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
    for i, o in ipairs(objs or {}) do
        out[i] = {
            text = ns.Safe(o.text) or "",
            have = ns.Safe(o.numFulfilled) or 0,
            need = ns.Safe(o.numRequired) or 0,
            done = ns.Safe(o.finished) and true or false,
        }
    end
    return out
end

-- Returns { [questID] = entry }, plus an ordered list of IDs as they appear in the log
function ns.ReadQuestLog()
    local log, order = {}, {}
    local header
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info then
            local title = ns.Safe(info.title)
            local questID = ns.Safe(info.questID)
            if info.isHeader then
                header = title
            elseif questID and questID > 0 and not ns.Safe(info.isHidden) and not IsHiddenQuest(questID) then
                log[questID] = {
                    title = title,
                    header = header,
                    level = ns.Safe(info.level),
                    ready = C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID) or false,
                    failed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(questID) or false,
                    obj = ReadObjectives(questID),
                }
                table.insert(order, questID)
            end
        end
    end
    return log, order
end

local function ReadCompleted()
    local done = {}
    if C_QuestLog.GetAllCompletedQuestIDs then
        for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do
            done[id] = true
        end
    end
    return done
end

local function CurrentZone()
    local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or (GetRealZoneText and GetRealZoneText()) or nil
end

local function MyChar()
    local key = ns.MyKey()
    local c = ns.db.chars[key]
    if not c then
        c = { log = {}, completed = {}, history = {} }
        ns.db.chars[key] = c
    end
    c.history = c.history or {}
    c.completed = c.completed or {}
    return c, key
end

-- full = also re-read the (large) completed-quest list from the server
function ns:TakeSnapshot(full, force)
    if not ns.db then return end
    if InCombatLockdown() and not force then return end
    local c = MyChar()
    local name, realm = UnitName("player"), ns.Realm()
    local _, classFile = UnitClass("player")
    local _, raceFile = UnitRace("player")
    c.name = name
    c.realm = realm
    c.class = classFile
    c.race = raceFile
    c.faction = UnitFactionGroup("player")
    c.level = UnitLevel("player")
    c.zone = CurrentZone() or c.zone
    c.log = ns.ReadQuestLog()
    if full or not next(c.completed) then
        local done = ReadCompleted()
        if next(done) then c.completed = done end
    end
    c.updated = time()
    ns:Fire("SNAPSHOT_UPDATED")
end

local lastLog = {}
local snapshotSoon = ns.Debounce(2, function() ns:TakeSnapshot(false) end)

ns:On("INIT", function()
    C_Timer.After(3, function()
        ns:TakeSnapshot(true)
        lastLog = ns.ReadQuestLog()
    end)
end)

ns:On("QUEST_LOG_UPDATE", function()
    if not ns.db then return end
    -- Remember headers/titles so turn-ins can be labelled after the quest leaves the log
    if not InCombatLockdown() then
        local log = ns.ReadQuestLog()
        for id, q in pairs(log) do lastLog[id] = q end
    end
    snapshotSoon()
end)

ns:On("QUEST_TURNED_IN", function(questID)
    questID = ns.Safe(questID)
    if not questID or not ns.db then return end
    local c = MyChar()
    local known = lastLog[questID]
    local title = ns.QuestTitle(questID, known and known.title)
    c.completed[questID] = true
    table.insert(c.history, {
        id = questID,
        title = title,
        zone = known and known.header or CurrentZone(),
        t = time(),
        lvl = UnitLevel("player"),
    })
    while #c.history > ns.HISTORY_CAP do table.remove(c.history, 1) end
    ns:Fire("QUEST_DONE", questID, title)
    snapshotSoon()
end)

ns:On("PLAYER_LEVEL_UP", snapshotSoon)
ns:On("ZONE_CHANGED_NEW_AREA", snapshotSoon)
ns:On("PLAYER_LOGOUT", function()
    -- Last chance before SavedVariables are written. Skip the completed re-read; it's kept current on turn-in.
    pcall(ns.TakeSnapshot, ns, false, true)
end)

---------------------------------------------------------------------------
-- Character directory: own chars + synced partner file + live party data
---------------------------------------------------------------------------

local function MergeHistory(a, b)
    local seen, out = {}, {}
    for _, list in ipairs({ a or {}, b or {} }) do
        for _, h in ipairs(list) do
            local k = h.id .. ":" .. (h.t or 0)
            if not seen[k] then
                seen[k] = true
                table.insert(out, h)
            end
        end
    end
    table.sort(out, function(x, y) return (x.t or 0) < (y.t or 0) end)
    return out
end

local function Merge(a, b, source)
    if not a then
        local c = {}
        for k, v in pairs(b) do c[k] = v end
        c.sources = { [source] = true }
        return c
    end
    local newer = ((b.updated or 0) > (a.updated or 0)) and b or a
    local c = {}
    for k, v in pairs(newer) do c[k] = v end
    c.completed = {}
    for id in pairs(a.completed or {}) do c.completed[id] = true end
    for id in pairs(b.completed or {}) do c.completed[id] = true end
    c.history = MergeHistory(a.history, b.history)
    c.sources = a.sources or {}
    c.sources[source] = true
    return c
end

-- Returns { [charKey] = snapshot } with every character we know anything about
function ns.GetCharacters()
    local out = {}
    for key, c in pairs(ns.db.chars) do out[key] = Merge(out[key], c, "account") end
    local pd = QuestPact_PartnerData
    if type(pd) == "table" and type(pd.chars) == "table" then
        for key, c in pairs(pd.chars) do
            if type(c) == "table" then out[key] = Merge(out[key], c, "sync") end
        end
    end
    for key, c in pairs(ns.db.live) do out[key] = Merge(out[key], c, "live") end
    return out
end
