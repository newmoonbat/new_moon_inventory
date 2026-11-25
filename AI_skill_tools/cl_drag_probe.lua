--[[ ==========================================================================
    cl_drag_probe.lua —— 客户端拖拽几何探针
    覆盖 lua/inventory/cl_ui.lua：
      · AnchorCellAtCursor / DragFootprint 的锚点换算（含旋转）
      · 拖动图标中心是否严格等于鼠标位置
      · 容器 Paint 里的蓝/红预览位置与颜色
      · 松手后 Move2 的 item / target / r 与预览是否一致
      · 原地不动 / 目标被占 / 面板外松手 / ESC 取消 的分支

    运行： C:\LuaJIT\luajit.exe cl_drag_probe.lua
   ========================================================================== ]]

local here = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
if here ~= "" then package.path = here .. "?.lua;" .. package.path end
local T = require("nm_test")

local log = { tex = {}, rect = {}, color = nil, net = nil }

-- ==================== GMod API 桩 ====================
KEY_R, KEY_ESCAPE, KEY_D = 45, 11, 32
MOUSE_LEFT, MOUSE_RIGHT = 1, 2
TOP, LEFT = 5, 3

function ScrW() return 1920 end
function ScrH() return 1080 end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function IsValid(p) return p ~= nil end
function Material(p) return { IsError = function() return false end, path = p } end

surface = {
    CreateFont = function() end,
    SetMaterial = function() end,
    SetFont = function() end,
    SetDrawColor = function(r, g, b, a) log.color = { r, g, b, a } end,
    DrawRect = function(x, y, w, h) log.rect[#log.rect + 1] = { x = x, y = y, w = w, h = h } end,
    DrawTexturedRect = function(x, y, w, h)
        log.tex[#log.tex + 1] = { kind = "rect", x = x, y = y, w = w, h = h }
    end,
    DrawTexturedRectRotated = function(cx, cy, w, h, a)
        log.tex[#log.tex + 1] = { kind = "rot", cx = cx, cy = cy, w = w, h = h, a = a }
    end,
    GetTextSize = function(t) return #t * 5, 10 end,
}
draw = { RoundedBox = function() end, SimpleText = function() end }
render = { SetScissorRect = function() end }

local keys, mouse = {}, false
input = {
    IsKeyDown = function(k) return keys[k] == true end,
    IsMouseDown = function() return mouse end,
}

net = {
    Start = function(n) log.net = { name = n } end,
    WriteString = function(s) log.net.op = s end,
    WriteTable = function(t) log.net.tbl = t end,
    SendToServer = function() log.net.sent = true end,
}

-- 最小 DPanel：只实现被测文件真正用到的几何/布局 API
local function NewPanel(kind, parent)
    local p = { _kind = kind, _parent = parent, _w = 0, _h = 0, _sx = 0, _sy = 0 }
    setmetatable(p, { __index = {
        GetWide = function(s) return s._w end,
        GetTall = function(s) return s._h end,
        SetWide = function(s, v) s._w = v end,
        SetTall = function(s, v) s._h = v end,
        SetSize = function(s, w, h) s._w, s._h = w, h end,
        GetParent = function(s) return s._parent end,
        SetParent = function(s, v) s._parent = v end,
        -- 关键：屏幕 <-> 面板局部坐标
        ScreenToLocal = function(s, mx, my) return mx - s._sx, my - s._sy end,
        LocalToScreen = function(s, lx, ly) return lx + s._sx, ly + s._sy end,
        SetPos = function() end, SetZPos = function() end,
        Dock = function() end, DockMargin = function() end,
        SetMouseInputEnabled = function() end, SetKeyboardInputEnabled = function() end,
        SetDepressImage = function() end, SetCursor = function() end,
        SetImage = function() end, SetVisible = function() end,
        SetText = function() end, SetFont = function() end,
        MakePopup = function() end, Remove = function() end,
        AddItem = function() end,
        Add = function(s, k) return NewPanel(k, s) end,
    } })
    return p
end

local hovered, created = nil, {}
vgui = {
    GetHoveredPanel = function() return hovered end,
    Create = function(kind, parent)
        local p = NewPanel(kind, parent)
        created[#created + 1] = p
        return p
    end,
}

-- hook.Add 的真实签名是 (event, name, fn)，这里取最后一个参数
local thinkFn
hook = { Add = function(name, _, fn) if name == "Think" then thinkFn = fn end end }

local mouseX, mouseY = 0, 0
gui = { MouseX = function() return mouseX end, MouseY = function() return mouseY end }

ITEM_LIST = {
    item_1x1 = { X = 1, Y = 1, icon = "1" },
    item_2x2 = { X = 2, Y = 2, icon = "2" },
    item_3x1 = { X = 3, Y = 1, icon = "3" },
}

local move2_calls = {}
function ITEM(classname)
    return {
        classname = classname, pos = nil,
        move2 = function(self, n, x, y, r)
            move2_calls[#move2_calls + 1] = { cn = self.classname, n = n, x = x, y = y, r = r }
            return true
        end,
    }
end

local GW, GH = 10, 8
local function EmptyGrid()
    local g = { classname = "container_test" }
    for x = 1, GW do
        g[x] = {}
        for y = 1, GH do g[x][y] = false end
    end
    return g
end
INVENTORY = { [1] = EmptyGrid() }

-- ==================== 加载被测文件 ====================
-- 拼在源码尾部的 export 段：借此拿到文件里的 local
T.load_with("inventory/cl_ui.lua", [[
_G.__PROBE = {
    StartDrag = StartDrag, RotateDrag = RotateDrag, FinishDrag = FinishDrag, CancelDrag = CancelDrag,
    AnchorCellAtCursor = AnchorCellAtCursor, DragFootprint = DragFootprint, CanDropAt = CanDropAt,
    ContainerPanelUnderCursor = ContainerPanelUnderCursor, GridCell = GridCell,
    get_drag = function() return drag end,
    set_frame = function(f) inv_frame = f end,
    set_scroll = function(s) inv_scroll = s end,
}
]])
local P = _G.__PROBE

-- 走真实的 CreateContainerPanel：Paint / PerformLayout / OnMousePressed 都是被测文件里的代码
P.set_scroll(NewPanel("DScrollPanel"))
inventory_cl_sync_containers()
local pnl
for _, p in ipairs(created) do
    if p.ContainerIndex == 1 then pnl = p end
end
assert(pnl, "容器面板没有创建")

-- 面板放在屏幕 (100,50)、宽 484 → cell = min(54, 480/12) = 40, offsetX = 80
pnl._w, pnl._h = 484, GH * 40
pnl._sx, pnl._sy = 100, 50
pnl.PerformLayout(pnl, pnl._w, pnl._h)
P.set_frame(pnl)

local cell, offsetX = P.GridCell(pnl, pnl:GetWide(), GW)
T.eq("cell", cell, 40)
T.eq("offsetX", offsetX, 80)

local function MouseToCell(cx, cy)   -- 鼠标放到第 cx,cy 格的格心（屏幕坐标）
    mouseX = 2 + offsetX + (cx - 1) * cell + cell * 0.5 + pnl._sx
    mouseY = 2 + (cy - 1) * cell + cell * 0.5 + pnl._sy
    hovered = pnl
end

local function DragOf(classname, x, y, rot)
    P.StartDrag({ n = 1, x = x, y = y, rot = rot, classname = classname, def = ITEM_LIST[classname] }, pnl)
    return P.get_drag()
end

-- ===== 1) 1x1：落点正好是鼠标所在格 =====
for _, c in ipairs({ { 1, 1 }, { 3, 5 }, { 10, 8 } }) do
    DragOf("item_1x1", 5, 5, false)
    MouseToCell(c[1], c[2])
    local ax, ay = P.AnchorCellAtCursor(pnl, 1, P.DragFootprint(P.get_drag()))
    T.eq(string.format("1x1 鼠标@(%d,%d) 锚点", c[1], c[2]), ax .. "," .. ay, c[1] .. "," .. c[2])
end

-- ===== 2) 3x1 / 旋转后 1x3 =====
local d = DragOf("item_3x1", 4, 4, false)
MouseToCell(6, 6)
local fw, fh = P.DragFootprint(d)
T.eq("3x1 占格(未旋转)", fw .. "x" .. fh, "3x1")
local ax, ay = P.AnchorCellAtCursor(pnl, 1, fw, fh)
T.eq("3x1 鼠标@(6,6) 锚点", ax .. "," .. ay, "5,6")
P.RotateDrag()
fw, fh = P.DragFootprint(P.get_drag())
T.eq("3x1 占格(旋转后)", fw .. "x" .. fh, "1x3")
ax, ay = P.AnchorCellAtCursor(pnl, 1, fw, fh)
T.eq("1x3 鼠标@(6,6) 锚点", ax .. "," .. ay, "6,5")

-- ===== 3) 图标中心始终 = 鼠标 =====
local function PaintDrag()
    hovered = pnl
    log.tex = {}
    inventory_cl_paint_drag(pnl)
    return log.tex[1]
end
DragOf("item_1x1", 1, 1, false); MouseToCell(8, 7)
local tex = PaintDrag()
T.near("1x1 图标中心X=鼠标X", tex.x + tex.w * 0.5, mouseX - pnl._sx)
T.near("1x1 图标中心Y=鼠标Y", tex.y + tex.h * 0.5, mouseY - pnl._sy)
T.eq("1x1 图标尺寸", tex.w .. "x" .. tex.h, "40x40")

DragOf("item_2x2", 1, 1, false); MouseToCell(8, 7)
tex = PaintDrag()
T.near("2x2 图标中心X=鼠标X", tex.x + tex.w * 0.5, mouseX - pnl._sx)
T.eq("2x2 图标尺寸", tex.w .. "x" .. tex.h, "80x80")

DragOf("item_3x1", 1, 1, false); MouseToCell(8, 7)
P.RotateDrag()
tex = PaintDrag()
T.eq("旋转后走旋转绘制", tex.kind, "rot")
T.near("旋转后中心X=鼠标X", tex.cx, mouseX - pnl._sx)
T.eq("旋转后包围盒", tex.w .. "x" .. tex.h, "120x40")

-- ===== 4) 真实 Paint 里的蓝/红预览 =====
local function RunPaint()
    log.rect, log.color, log.tex = {}, nil, {}
    pnl.Paint(pnl, pnl._w, pnl._h)
end

INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_1x1", r = false }
DragOf("item_1x1", 3, 3, false); MouseToCell(8, 7)
RunPaint()
local prev = log.rect[#log.rect]
T.eq("可放预览 X", prev.x, offsetX + 7 * cell + 2)
T.eq("可放预览 Y", prev.y, 6 * cell + 2)
T.eq("可放预览为蓝色", log.color[1], 120)

INVENTORY[1][8][7] = { classname = "item_1x1", r = false }
DragOf("item_1x1", 3, 3, false); MouseToCell(8, 7)
RunPaint()
prev = log.rect[#log.rect]
T.eq("不可放预览 X", prev.x, offsetX + 7 * cell + 2)
T.eq("不可放预览为红色", log.color[1], 230)
T.eq("容器 Paint 只画已有物品", #log.tex, 2)

-- ===== 5) 松手提交 Move2 =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][1][1] = { classname = "item_2x2", r = false }
INVENTORY[1][2][1], INVENTORY[1][1][2], INVENTORY[1][2][2] = true, true, true
move2_calls, log.net = {}, nil
DragOf("item_2x2", 1, 1, false); MouseToCell(7, 6)
local wantX, wantY = P.AnchorCellAtCursor(pnl, 1, P.DragFootprint(P.get_drag()))
mouse = false
thinkFn()                                    -- 模拟"松开左键"那一帧
T.eq("松手后 drag 清空", P.get_drag(), nil)
T.eq("Move2 已发送", log.net and log.net.sent, true)
T.eq("op", log.net and log.net.op, "Move2")
T.eq("item.n/x/y", log.net and (log.net.tbl.item.n .. "," .. log.net.tbl.item.x .. "," .. log.net.tbl.item.y), "1,1,1")
T.eq("target 与预览锚点一致", log.net and (log.net.tbl.target.x .. "," .. log.net.tbl.target.y), wantX .. "," .. wantY)
T.eq("客户端预测调用一次", #move2_calls, 1)

-- ===== 6) 原地不动 → 不发包 =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_1x1", r = false }
log.net = nil
DragOf("item_1x1", 3, 3, false); MouseToCell(3, 3)
mouse = false
thinkFn()
T.eq("原地不动不发包", log.net, nil)

-- ===== 7) 目标被占 → 不发包 =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_1x1", r = false }
INVENTORY[1][9][8] = { classname = "item_1x1", r = false }
log.net = nil
DragOf("item_1x1", 3, 3, false); MouseToCell(9, 8)
mouse = false
thinkFn()
T.eq("目标被占不发 Move2", log.net, nil)

-- ===== 8) 面板外松手 → 取消 =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_1x1", r = false }
log.net = nil
DragOf("item_1x1", 3, 3, false)
hovered = nil
mouseX, mouseY = 10, 10
mouse = false
thinkFn()
T.eq("面板外松手取消", log.net, nil)

-- ===== 9) 原地旋转 → 必须发包且带 r =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_3x1", r = false }
INVENTORY[1][4][3], INVENTORY[1][5][3] = true, true
log.net = nil
DragOf("item_3x1", 3, 3, false); MouseToCell(4, 3)
P.RotateDrag()
mouse = false
thinkFn()
T.eq("原地旋转必须发包", log.net and log.net.sent, true)
T.eq("旋转后 r 为 true", log.net and log.net.tbl.target.r, true)

-- ===== 10) ESC 取消 =====
INVENTORY[1] = EmptyGrid()
INVENTORY[1][3][3] = { classname = "item_1x1", r = false }
log.net = nil
DragOf("item_1x1", 3, 3, false); MouseToCell(6, 6)
keys[KEY_ESCAPE] = true
thinkFn()
T.eq("ESC 取消拖拽", P.get_drag(), nil)
T.eq("ESC 不发包", log.net, nil)

T.finish("cl_drag_probe")
