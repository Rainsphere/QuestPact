local _, ns = ...

-- Live party comms. Wire format (prefix "QuestPact", '|' separated):
--   HI|ver|lead           hello; anyone hearing it replies with their state
--   LEAD|0|1              "always lead" preference
--   INFO|lvl|class|zone
--   LOG|seq|i|n|entries   quest log in n parts; entry = id:r:h/n.h/n:title  (r: 0 open, 1 ready, 2 failed)
--   SKIP|id,id,...        leader's skip list
--   DONE|id|title         turned in a quest

local PREFIX = "QuestPact"
local MAX_PAYLOAD = 230

ns.party = {}      -- [charKey] = { lead, info = {level, class, zone}, log = {...}, parts = {} }
ns.recentDone = {} -- [questID] = { title, by, t }
local receivedSkip = {}

---------------------------------------------------------------------------
-- Group roster
---------------------------------------------------------------------------

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    name, realm = ns.Safe(name), ns.Safe(realm)
    if not name or name == UNKNOWNOBJECT then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm:gsub("[%s%-]", "") end
    return name .. "-" .. ns.Realm()
end

-- Other group members: { {unit, key}, ... }
function ns.GroupMembers()
    local out = {}
    if not IsInGroup() then return out end
    local me = ns.MyKey()
    local raid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local unit = (raid and "raid" or "party") .. i
        if UnitExists(unit) then
            local key = UnitKey(unit)
            if key and key ~= me then table.insert(out, { unit = unit, key = key }) end
        end
    end
    return out
end

local function GroupLeaderKey()
    if not IsInGroup() then return ns.MyKey() end
    if UnitIsGroupLeader("player") then return ns.MyKey() end
    for _, m in ipairs(ns.GroupMembers()) do
        if UnitIsGroupLeader(m.unit) then return m.key end
    end
    return ns.MyKey()
end

-- Anyone with "always lead" wins (alphabetically first); otherwise the group leader
function ns.GetLeader()
    local candidates = {}
    if ns.GetSetting("alwaysLeader") then table.insert(candidates, ns.MyKey()) end
    for key, p in pairs(ns.party) do
        if p.lead then table.insert(candidates, key) end
    end
    if #candidates == 0 then return GroupLeaderKey() end
    table.sort(candidates)
    return candidates[1]
end

function ns.IsLeader()
    return ns.GetLeader() == ns.MyKey()
end

function ns.EffectiveSkip()
    if ns.IsLeader() then return ns.db.skip end
    return receivedSkip
end

---------------------------------------------------------------------------
-- Send queue: coalesces by key, respects throttle and lockdown
---------------------------------------------------------------------------

local queue = {}
local ticking = false

local function Blocked()
    if InCombatLockdown() then return true end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return true end
    return false
end

local function Channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then return "INSTANCE_CHAT" end
    return "PARTY"
end

local function Sent(ret)
    -- Older builds return a boolean, newer ones an Enum.SendAddonMessageResult (0 = Success)
    return ret == nil or ret == true or ret == 0
end

local Tick
Tick = function()
    if #queue == 0 or not IsInGroup() then
        wipe(queue)
        ticking = false
        return
    end
    if Blocked() then
        ticking = false -- resumed on PLAYER_REGEN_ENABLED
        return
    end
    local item = queue[1]
    local ok, ret = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.msg, Channel())
    if ok and Sent(ret) then
        table.remove(queue, 1)
        C_Timer.After(0.3, Tick)
    else
        item.tries = (item.tries or 0) + 1
        if item.tries > 5 then table.remove(queue, 1) end
        C_Timer.After(1.5, Tick)
    end
end

local function Kick()
    if ticking then return end
    ticking = true
    C_Timer.After(0.1, Tick)
end

-- key: messages with the same key replace each other while queued
local function Send(key, msg)
    if not IsInGroup() then return end
    for i = #queue, 1, -1 do
        if queue[i].key == key then table.remove(queue, i) end
    end
    table.insert(queue, { key = key, msg = msg })
    Kick()
end

local function SendLog()
    -- A new log replaces every queued part of the old one
    for i = #queue, 1, -1 do
        if queue[i].key:match("^LOG%d") then table.remove(queue, i) end
    end
    local log = ns.ReadQuestLog()
    local entries = {}
    for id, q in pairs(log) do
        local objs = {}
        for _, o in ipairs(q.obj or {}) do
            table.insert(objs, (o.have or 0) .. "/" .. (o.need or 0))
        end
        local r = q.failed and 2 or (q.ready and 1 or 0)
        -- Title included: the receiver's client usually hasn't cached quests it's never seen
        local title = (q.title or ""):gsub("[:;|]", ""):sub(1, 60)
        table.insert(entries, id .. ":" .. r .. ":" .. table.concat(objs, ".") .. ":" .. title)
    end
    local parts, cur = {}, {}
    local len = 0
    for _, e in ipairs(entries) do
        if len + #e + 1 > MAX_PAYLOAD and #cur > 0 then
            table.insert(parts, table.concat(cur, ";"))
            cur, len = {}, 0
        end
        table.insert(cur, e)
        len = len + #e + 1
    end
    table.insert(parts, table.concat(cur, ";"))
    local seq = math.random(1000, 9999)
    for i, p in ipairs(parts) do
        Send("LOG" .. i, string.format("LOG|%d|%d|%d|%s", seq, i, #parts, p))
    end
end

local function SendInfo()
    local zone = (GetRealZoneText and GetRealZoneText() or ""):gsub("|", "")
    local _, class = UnitClass("player")
    Send("INFO", string.format("INFO|%d|%s|%s", UnitLevel("player"), class or "", zone))
end

local function SendLead()
    Send("LEAD", "LEAD|" .. (ns.GetSetting("alwaysLeader") and "1" or "0"))
end

function ns.BroadcastSkip()
    if not ns.IsLeader() then return end
    local ids = {}
    for id in pairs(ns.db.skip) do table.insert(ids, tostring(id)) end
    Send("SKIP", "SKIP|" .. table.concat(ids, ","))
end

function ns.BroadcastState()
    if not IsInGroup() then return end
    SendLead()
    SendInfo()
    SendLog()
    ns.BroadcastSkip()
end

ns.BroadcastLeaderPref = SendLead

local broadcastSoon = ns.Debounce(2, ns.BroadcastState)

---------------------------------------------------------------------------
-- Receive
---------------------------------------------------------------------------

local function Live(key)
    local l = ns.db.live[key]
    if not l then
        l = { completed = {}, history = {}, log = {} }
        ns.db.live[key] = l
        local name, realm = key:match("^([^%-]+)%-(.+)$")
        l.name, l.realm = name or key, realm
    end
    return l
end

local lastReply = {}
local handlers = {}

handlers.HI = function(key, _, lead)
    ns.party[key] = ns.party[key] or {}
    ns.party[key].lead = lead == "1"
    if (lastReply[key] or 0) + 10 < GetTime() then
        lastReply[key] = GetTime()
        broadcastSoon()
    end
end

handlers.LEAD = function(key, v)
    ns.party[key] = ns.party[key] or {}
    ns.party[key].lead = v == "1"
    C_Timer.After(0.5, ns.BroadcastSkip)
end

handlers.INFO = function(key, lvl, class, zone)
    local p = ns.party[key] or {}
    ns.party[key] = p
    p.info = { level = tonumber(lvl), class = class, zone = zone }
    local l = Live(key)
    l.level, l.class, l.zone = tonumber(lvl), class, zone
    l.updated = time()
end

handlers.LOG = function(key, seq, i, n, payload)
    local p = ns.party[key] or {}
    ns.party[key] = p
    i, n = tonumber(i), tonumber(n)
    if not i or not n then return end
    if p.seq ~= seq then
        p.seq, p.parts = seq, {}
    end
    p.parts[i] = payload or ""
    for k = 1, n do
        if not p.parts[k] then return end -- wait for the rest
    end
    local log = {}
    for k = 1, n do
        for entry in p.parts[k]:gmatch("[^;]+") do
            local id, r, objs, title = entry:match("^(%d+):(%d):([^:]*):?(.*)$")
            id = tonumber(id)
            if id then
                local q = { ready = r == "1", failed = r == "2", obj = {} }
                for have, need in (objs or ""):gmatch("(%d+)/(%d+)") do
                    have, need = tonumber(have), tonumber(need)
                    table.insert(q.obj, { have = have, need = need, done = have >= need })
                end
                if title == "" then title = nil end
                local t = C_QuestLog.GetTitleForQuestID and ns.Safe(C_QuestLog.GetTitleForQuestID(id))
                q.title = title or t or ns.Questie.Name(id)
                log[id] = q
            end
        end
    end
    p.log, p.parts = log, {}
    local l = Live(key)
    l.log = log
    l.updated = time()
end

handlers.SKIP = function(key, list)
    if key ~= ns.GetLeader() then return end
    wipe(receivedSkip)
    for id in (list or ""):gmatch("%d+") do
        receivedSkip[tonumber(id)] = true
    end
end

handlers.DONE = function(key, id, title)
    id = tonumber(id)
    if not id then return end
    local l = Live(key)
    l.completed[id] = true
    table.insert(l.history, { id = id, title = title ~= "" and title or nil, zone = l.zone, t = time(), lvl = l.level })
    while #l.history > ns.HISTORY_CAP do table.remove(l.history, 1) end
    if ns.party[key] and ns.party[key].log then ns.party[key].log[id] = nil end
    -- Grace period: if we hand it in too, it never shows as "they finished without you"
    C_Timer.After(10, function()
        local mine = C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id)
        if not mine then
            ns.recentDone[id] = { title = title, by = ns.ShortName(key), t = time() }
            ns:Fire("PARTY_CHANGED")
        end
    end)
end

ns:On("CHAT_MSG_ADDON", function(prefix, msg, _, sender)
    prefix, msg, sender = ns.Safe(prefix), ns.Safe(msg), ns.Safe(sender)
    if prefix ~= PREFIX or not msg or not sender then return end
    local key = ns.FullName(sender)
    if key == ns.MyKey() then return end
    local args = { strsplit("|", msg) }
    local h = handlers[args[1]]
    if not h then return end
    h(key, select(2, unpack(args)))
    ns:Fire("PARTY_CHANGED")
end)

---------------------------------------------------------------------------
-- Triggers
---------------------------------------------------------------------------

local function Hello()
    if not IsInGroup() then return end
    Send("HI", string.format("HI|%s|%s", ns.VERSION, ns.GetSetting("alwaysLeader") and "1" or "0"))
    broadcastSoon()
end

ns:On("INIT", function()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(4, Hello)
end)

ns:On("GROUP_ROSTER_UPDATE", function()
    local present = {}
    for _, m in ipairs(ns.GroupMembers()) do present[m.key] = true end
    for key in pairs(ns.party) do
        if not present[key] then ns.party[key] = nil end
    end
    if not IsInGroup() then wipe(receivedSkip) end
    C_Timer.After(1, Hello)
    ns:Fire("PARTY_CHANGED")
end)

ns:On("QUEST_LOG_UPDATE", broadcastSoon)
ns:On("PLAYER_REGEN_ENABLED", Kick)

ns:On("QUEST_DONE", function(questID, title)
    ns.recentDone[questID] = nil
    Send("DONE" .. questID, string.format("DONE|%d|%s", questID, (title or ""):gsub("|", "")))
    ns:Fire("PARTY_CHANGED")
end)

-- Prune live entries nobody has heard from in 60 days
ns:On("DB_READY", function()
    local cutoff = time() - 60 * 86400
    for key, l in pairs(ns.db.live) do
        if (l.updated or 0) < cutoff then ns.db.live[key] = nil end
    end
end)
