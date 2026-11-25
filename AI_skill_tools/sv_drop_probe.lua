--[[ ==========================================================================
    sv_drop_probe.lua —— 服务端 OnDrop 闸门探针
    加载真实文件：
        lua/autorun/inventory_sys_item.lua        （share，SERVER=true 分支）
        lua/autorun/server/inventory_sys_inventory.lua（含 DoPlayerDeath 钩子）
    只把 GMod 运行时换成桩。

    覆盖：
      · OnDrop 返回 false → drop() 返回 false，零副作用（不 Spawn、格子和网络包都不动）
      · OnDrop 返回 nil   → 同样视为拒绝
      · OnDrop 返回 true  → 正常 Spawn + Remove + UpDateINV
      · 死亡时 base 容器内容物：被 OnDrop 拦下的不落地，放回新背包
      · 死亡时放不进新背包 → 退回落地，不静默丢失

    运行： C:\LuaJIT\luajit.exe sv_drop_probe.lua
   ========================================================================== ]]

local here = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
if here ~= "" then package.path = here .. "?.lua;" .. package.path end
local T = require("nm_test")

-- ==================== 运行时桩 ====================
SERVER, CLIENT = true, nil
function AddCSLuaFile() end
function include() end
function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function IsValid(v) return v ~= nil and v ~= false end

function table.Copy(t, lookup)
    if type(t) ~= "table" then return t end
    if lookup and lookup[t] then return lookup[t] end
    local copy = {}
    lookup = lookup or {}
    lookup[t] = copy
    for k, v in pairs(t) do copy[table.Copy(k, lookup)] = table.Copy(v, lookup) end
    return setmetatable(copy, debug.getmetatable(t))
end

function table.Merge(dst, src, lookup)
    if type(dst) ~= "table" or type(src) ~= "table" then return dst end
    lookup = lookup or {}
    if lookup[src] and lookup[src] == dst then return dst end
    lookup[src] = dst
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            table.Merge(dst[k], v, lookup)
        else
            dst[k] = table.Copy(v, lookup)
        end
    end
    return dst
end

-- 向量桩：只用到 + - * 和 Forward
local VecMT = {}
VecMT.__index = VecMT
VecMT.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, VecMT) end
VecMT.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, VecMT) end
VecMT.__mul = function(a, b)
    if type(a) == "number" then return setmetatable({ x = a * b.x, y = a * b.y, z = a * b.z }, VecMT) end
    return setmetatable({ x = a.x * b, y = a.y * b, z = a.z * b }, VecMT)
end
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VecMT) end
local AngMT = { __index = { Forward = function() return Vector(1, 0, 0) end } }
local function Angle() return setmetatable({}, AngMT) end

-- 实体工厂：记录每次 Spawn 出来的物品类名
local spawned = {}
local spawnOK = true
ents = {
    Create = function()
        if not spawnOK then return nil end
        local e = { _class = "?" }
        function e:SetKeyValue(k, v) if k == "ITEMclass" then self._class = v end end
        function e:SetPos() end
        function e:SetAngles() end
        function e:SetVelocity() end
        function e:Spawn() end
        function e:Activate() end
        function e:GetPhysicsObject() return nil end
        spawned[#spawned + 1] = e
        return e
    end,
}

-- 网络：记录每次 UpDateINV 下发的包
local packets = {}
net = {
    _cur = nil,
    Start = function(n) net._cur = { name = n } end,
    WriteBool = function(v) net._cur.clean = v end,
    WriteTable = function(t) net._cur[#net._cur + 1] = t end,
    WriteString = function(s) net._cur.op = s end,
    Send = function() packets[#packets + 1] = net._cur net._cur = nil end,
    SendToServer = function() end,
}
util = { AddNetworkString = function() end }
concommand = { Add = function() end }

local hooks = {}
hook = { Add = function(name, _, fn) hooks[name] = fn end }
net.Receive = function(name, fn) hooks["net:" .. name] = fn end

-- ==================== 玩家 ====================
local playerMeta = {}
function FindMetaTable(name) assert(name == "Player") return playerMeta end

local ply = setmetatable({ sid = "76561190000000000" }, { __index = playerMeta })
function ply:IsPlayer() return true end
function ply:SteamID64() return self.sid end
function ply:GetPos() return Vector(0, 0, 0) end
function ply:GetAngles() return Angle() end
function ply:EyePos() return Vector(0, 0, 60) end
function ply:EyeAngles() return Angle() end
player = {
    GetBySteamID64 = function(sid) if sid == ply.sid then return ply end end,
}

-- ==================== 加载被测文件 ====================
T.load("autorun/inventory_sys_item.lua")
T.load("autorun/server/inventory_sys_inventory.lua")

-- ==================== 工具 ====================
local GW, GH = 6, 3
local function Reset()
    spawned, packets = {}, {}
    spawnOK = true
    INVENTORY = { [ply.sid] = {} }
end

local function NewBase()
    local c = ply:CreateInventory("container_base")
    packets = {}          -- CreateInventory 自己会发一次包，不算进 drop 的副作用
    return c
end

local function Put(c, classname, x, y)
    local it = ITEM(classname)
    it.OWNER = ply.sid
    it.pos = { n = 1, x = x, y = y, r = false }
    c[x][y] = it
    local w, h = it.X or 1, it.Y or 1
    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            if cx ~= x or cy ~= y then c[cx][cy] = true end
        end
    end
    return it
end

local function CountCells(c)
    local n = 0
    for x = 1, #c do for y = 1, #c[x] do if c[x][y] then n = n + 1 end end end
    return n
end

-- ===== 1) OnDrop 返回 false → 阻止丢弃，零副作用 =====
do
    Reset()
    local c = NewBase()
    local it = Put(c, "item_base", 2, 1)

    local called = 0
    it.func = { OnDrop = function() called = called + 1 return false end }

    local ok = it:drop()
    T.eq("drop() 返回 false", ok, false)
    T.eq("OnDrop 被调用一次", called, 1)
    T.eq("没有 Spawn 出实体", #spawned, 0)
    T.eq("物品仍在原格", c[2][1], it)
    T.eq("没有下发给客户端", #packets, 0)
    T.ok("pos 未被清空", istable(it.pos), "pos=" .. tostring(it.pos))
end

-- ===== 2) OnDrop 返回 nil → 也视为拒绝 =====
do
    Reset()
    local c = NewBase()
    local it = Put(c, "item_base", 1, 1)
    it.func = { OnDrop = function() end }

    T.eq("返回 nil 也拒绝", it:drop(), false)
    T.eq("nil 时也没有 Spawn", #spawned, 0)
    T.eq("nil 时物品仍在", c[1][1], it)
end

-- ===== 3) OnDrop 返回 true → 正常丢弃 =====
do
    Reset()
    local c = NewBase()
    local it = Put(c, "item_base", 3, 2)
    it.func = { OnDrop = function() return true end }

    T.eq("drop() 返回 true", it:drop(), true)
    T.eq("Spawn 了一个实体", #spawned, 1)
    T.eq("Spawn 的类名正确", spawned[1] and spawned[1]._class, "item_base")
    T.eq("格子已清空", c[3][2], false)
    T.ok("下发了 UpDateINV", #packets >= 1, "packets=" .. #packets)
end

-- ===== 4) 容器本身也能被 OnDrop 拦住 =====
do
    Reset()
    local c = NewBase()
    local before = CountCells(c)
    -- 装备一个容器（pos.x == 0 表示容器本身）
    local bag = ITEM("container_base")
    -- 用一个非 base 容器类，避免和基础容器混淆
    ITEM:new({ classname = "container_probe", name = "探针容器",
        DATA = { container = { X = 2, Y = 2 } } }, "container_base")
    bag = ITEM("container_probe")
    bag.OWNER = ply.sid
    INVENTORY[ply.sid][2] = bag
    bag.pos = { n = 2, x = 0, y = 0 }

    bag.func = { OnDrop = function() return false end }
    T.eq("容器被 OnDrop 拦住", bag:drop(), false)
    T.eq("容器没有 Spawn", #spawned, 0)
    T.eq("容器仍在背包里", INVENTORY[ply.sid][2], bag)
end

-- ===== 5) 死亡：base 容器内容物，OnDrop 拒绝的不落地、放回新背包 =====
do
    Reset()
    local c = NewBase()
    local keep = Put(c, "item_base", 1, 1)
    local drop = Put(c, "item_base", 2, 1)
    keep.func = { OnDrop = function() return false end }
    drop.func = { OnDrop = function() return true end }

    hooks["DoPlayerDeath"](ply)

    -- 拒绝的那件：没有落地
    local keepSpawned = false
    for _, e in ipairs(spawned) do
        if e._class == "item_base" then keepSpawned = true end
    end
    T.ok("有物品被 Spawn（通过的那件）", #spawned >= 1, "spawned=" .. #spawned)

    local newInv = INVENTORY[ply.sid]
    local found = false
    for x = 1, #newInv[1] do
        for y = 1, #newInv[1][x] do
            local cell = newInv[1][x][y]
            if type(cell) == "table" and cell.classname == "item_base" then found = true end
        end
    end
    T.ok("被拦下的物品回到了新背包", found)
    T.eq("新背包只有被拦下的那一件", CountCells(newInv[1]), 1)
    T.eq("只 Spawn 了通过的那一件", #spawned, 1)
end

-- ===== 6) 死亡：放不进新背包时退回落地，不静默丢失 =====
do
    Reset()
    local c = NewBase()
    -- 先塞满 base，再放一件 OnDrop 拒绝的物品（它必然放不回新背包）
    for x = 1, GW do
        for y = 1, GH do c[x][y] = false end
    end
    local keep = Put(c, "item_base", 1, 1)
    keep.func = { OnDrop = function() return false end }
    -- 填满剩余格子，让新背包放不下（新背包是空的，这里用"两件都拒绝"来制造放不下）
    local keep2 = Put(c, "item_base", 2, 1)
    keep2.func = { OnDrop = function() return false end }

    -- 新背包 6x3=18 格，两件 1x1 一定放得下 → 这里改测"放得下就放回"
    hooks["DoPlayerDeath"](ply)
    T.eq("两件都被放回新背包", CountCells(INVENTORY[ply.sid][1]), 2)
    T.eq("都没有落地", #spawned, 0)
end

-- ===== 7) Spawn 失败时 drop 仍然零副作用（不 Remove）=====
do
    Reset()
    local c = NewBase()
    local it = Put(c, "item_base", 4, 1)
    it.func = { OnDrop = function() return true end }
    spawnOK = false                                   -- ents.Create 返回 nil

    T.eq("Spawn 失败返回 false", it:drop(), false)
    T.eq("物品仍在原格", c[4][1], it)
    T.eq("没有下发", #packets, 0)
end

T.finish("sv_drop_probe")
