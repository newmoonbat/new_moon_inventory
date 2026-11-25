local COL_EMPTY  = Color(55, 55, 55, 255)
local COL_FULL   = Color(80, 180, 80, 255)
local COL_BG     = Color(80, 80, 80, 255)
local COL_TEXT   = Color(225, 225, 225, 255)

-- 背包名字体：沿用 DermaDefault 的字体文件（Tahoma），字号 = 屏幕高度 * 0.015
local NAME_FONT      = "NM_InventoryName"
local name_font_size = nil

local function GetNameFont()
    local size = math.max( 1, math.floor( ScrH() * 0.015 + 0.5 ) )
    if name_font_size ~= size then
        name_font_size = size
        surface.CreateFont( NAME_FONT, {
            font      = "Tahoma",
            size      = size,
            weight    = 500,
            antialias = true,
            additive  = false,
            shadow    = false,
        } )
    end
    return NAME_FONT
end

local function PanelH()
    return ScrH() * 0.8
end

local function CellMax()
    return PanelH() * 0.05
end

-- 每个容器面板左侧预留 2x2 格的背包图标区，网格整体右移这么多格
-- 图标下方再留 1 行显示背包名字
local ICON_COLS = 2
local ICON_ROWS = 2
local NAME_ROWS = 1

local icon_cache = {}

-- 容器现在是 ITEM 实例，类名在 .classname；这里兼容旧纯表的 .containerclassname
local function ContainerClass( grid )
    if type( grid ) ~= "table" then return end
    return grid.classname or grid.containerclassname
end

local function ContainerDef( grid )
    local classname = ContainerClass( grid )
    return classname and ITEM_LIST[ classname ]
end

local function GetIcon( path )
    if not path or path == "" then return end

    local mat = icon_cache[ path ]
    if mat == nil then
        mat = Material( path )
        icon_cache[ path ] = mat
    end

    if not mat or mat:IsError() then return end
    return mat
end

-- 网格里只有锚点格存 classname，true 是多格物品的占位格
-- 锚点索引按 grid 表缓存（弱键），避免每次右键都全表扫描。
-- 客户端预测会就地修改格子，所以预测后必须调用 inventory_cl_clear_anchor_cache()。
local anchor_cache = setmetatable( {}, { __mode = "k" } )

function inventory_cl_clear_anchor_cache()
    for grid in pairs( anchor_cache ) do
        anchor_cache[ grid ] = nil
    end
end

local function AnchorList( grid )
    local list = anchor_cache[ grid ]
    if list then return list end

    list = {}
    for ax = 1, #grid do
        local column = grid[ ax ]
        if column then
            for ay = 1, #column do
                local classname = column[ ay ]
                if type( classname ) == "string" then
                    local def = ITEM_LIST[ classname ]
                    list[ #list + 1 ] = {
                        x = ax, y = ay,
                        w = ( def and def.X ) or 1,
                        h = ( def and def.Y ) or 1,
                        classname = classname,
                        def = def,
                    }
                end
            end
        end
    end

    anchor_cache[ grid ] = list
    return list
end

-- 按坐标反查锚点，返回 锚点x, 锚点y, classname, 类定义
local function ItemAnchorAt( grid, x, y )
    local list = AnchorList( grid )
    for i = 1, #list do
        local a = list[ i ]
        if x >= a.x and x < a.x + a.w and y >= a.y and y < a.y + a.h then
            return a.x, a.y, a.classname, a.def
        end
    end
end

local DROP_METHOD = "drop"   -- D 键触发的 methon id（不是显示名）

-- methon 条目格式：{ name = "显示名", share = fn, sv = fn, cl = fn }
-- 返回按显示名排序的 { id, name } 列表；兼容旧的 "key = function" 写法
local function MethodList( methods )
    local list = {}
    for id, entry in pairs( methods ) do
        local label = id
        if type( entry ) == "table" and entry.name then label = entry.name end
        list[ #list + 1 ] = { id = id, name = label }
    end
    table.sort( list, function( a, b ) return a.name < b.name end )
    return list
end

-- 统一的格子尺寸来源：PerformLayout 算一次并缓存到面板上，
-- Paint（用 w 参数）与鼠标命中（GetWide）都读同一份，避免滚动条出现时错位
local function GridCell( pnl, w, gw )
    local cell = pnl.NMCell
    if cell and cell > 0 then return cell, pnl.NMOffsetX end

    cell = math.min( CellMax(), ( w - 4 ) / ( gw + ICON_COLS ) )
    if cell <= 0 then return end
    return cell, ICON_COLS * cell
end

-- 客户端预测：直接交给 ITEM:CallMethod（内部按 pos 自动选 methon / DATA.container.methon，
-- 并分发 share + cl；sv 只在服务端执行）
local function PredictCall( self, name )
    if not self then return end
    self:CallMethod( name )
    inventory_cl_clear_anchor_cache()      -- 预测会就地改格子，锚点索引必须失效
end

-- 从鼠标所在面板向上找容器面板（面板上带 ContainerIndex）
local function HoveredContainerPanel()
    local pnl = vgui.GetHoveredPanel()
    while IsValid(pnl) do
        if pnl.ContainerIndex and INVENTORY[pnl.ContainerIndex] then
            return pnl
        end
        pnl = pnl:GetParent()
    end
end

-- 返回鼠标当前指向的物品：{ kind = "item", n, x, y, cell, offsetX, classname, def }
-- 左侧背包图标是独立子面板，不会走到这里
local function ItemUnderCursor( pnl )
    local n = pnl.ContainerIndex
    local grid = n and INVENTORY[n]
    if not grid or not grid[1] then return end

    local cell, offsetX = GridCell( pnl, pnl:GetWide(), #grid )
    if not cell then return end

    local mx, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
    local cx = math.floor((mx - 2 - offsetX) / cell) + 1
    local cy = math.floor((my - 2) / cell) + 1

    if cx < 1 then return end      -- 落在左侧图标区

    local ax, ay, classname, def = ItemAnchorAt(grid, cx, cy)
    if not classname then return end

    return { kind = "item", n = n, x = ax, y = ay, cell = cell,
             offsetX = offsetX, classname = classname, def = def }
end

local function SendItemMethod( classname, id, n, x, y )
    -- 客户端预测：share / cl 分支在本地跑一遍（sv 只由服务端执行）
    if ITEM_LIST[ classname ] then
        local inst = ITEM( classname )
        if inst then
            inst.pos = { n = n, x = x, y = y }
            PredictCall( inst, id )
        end
    end

    local pack2sv = {["n"] = n,["x"] = x,["y"] = y,["methon"] = id}
    --配置服务器操作数据并发送
    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString("DoItemMethon")
    net.WriteTable(pack2sv)
    net.SendToServer()
end

-- 先 Open 再取宽：DMenu 未显示时布局没算完，GetWide 往往是默认值，
-- 会导致右侧翻边判断失准。Open 之后 SetPos 才是最终位置。
local function OpenMenuBeside( menu, rightX, leftX, topY )
    menu:InvalidateLayout( true )
    menu:Open( 0, 0 )

    local mw = menu:GetWide()
    local mx = rightX
    if mx + mw > ScrW() - 4 then
        mx = leftX - mw - 4
    end
    if mx < 4 then mx = 4 end

    menu:SetPos( mx, topY )
end

-- rightX / leftX / topY 是物品图标在屏幕上的右边缘、左边缘与顶部
local function OpenItemMenu( classname, n, x, y, rightX, leftX, topY )
    local def = ITEM_LIST[ classname ]
    if not def or type( def.methon ) ~= "table" then return end

    local list = MethodList( def.methon )
    if #list == 0 then return end

    local menu = vgui.Create( "DMenu" )
    for _, m in ipairs( list ) do
        local opt = menu:AddOption( m.name, function()
            SendItemMethod( classname, m.id, n, x, y )
        end )
        opt:SetFont( GetNameFont() )
    end

    -- 贴在物品图标右侧；右边放不下时翻到图标左侧
    OpenMenuBeside( menu, rightX, leftX, topY )
end

--[[
背包图标（容器）自己的右键菜单：方法来自 DATA.container.methon
（CallMethod 会因 pos = {n, 0, 0} 自动路由到这里），格式与物品相同：
{ name = "显示名", share = fn, sv = fn, cl = fn }

ITEM:new({
    classname = "container_test",
    DATA = { container = { methon = {
        ["disequip"] = { name = "解除装备", share = function(self) ... end },
    } } },
})
--]]
local function SendContainerMethod( classname, id, n )
    -- CLIENT 分支：预测执行（pos 的 x/y 为 0 即"容器本身"，CallMethod 会自动选容器方法）
    if ITEM_LIST[ classname ] then
        local inst = ITEM( classname )
        if inst then
            inst.pos = { n = n, x = 0, y = 0 }
            PredictCall( inst, id )
        end
    end

    -- SERVER 分支：x = 0, y = 0 表示"容器本身"
    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString("DoItemMethon")
    net.WriteTable( {["n"] = n,["x"] = 0,["y"] = 0,["methon"] = id} )
    net.SendToServer()

    -- 容器方法可能让本地 INVENTORY 减少一个容器（如解除装备），
    -- 面板按编号索引，必须同步一次才能删掉多出来的面板
    inventory_cl_sync_containers()
end

local function OpenContainerMenu( n, rightX, leftX, topY )
    local grid = INVENTORY[n]
    if not grid then return end

    local classname = ContainerClass( grid )

    -- GetMethods 会按 grid 的 pos 自动选 DATA.container.methon
    local methods = grid.GetMethods and grid:GetMethods()
    if type( methods ) ~= "table" then
        local def = ContainerDef( grid )     -- 兜底：纯表或未注册类
        methods = def and def.DATA and def.DATA.container and def.DATA.container.methon
    end
    if type( methods ) ~= "table" then return end

    local list = MethodList( methods )
    if #list == 0 then return end

    local menu = vgui.Create( "DMenu" )
    for _, m in ipairs( list ) do
        local opt = menu:AddOption( m.name, function()
            SendContainerMethod( classname, m.id, n )
        end )
        opt:SetFont( GetNameFont() )
    end

    OpenMenuBeside( menu, rightX, leftX, topY )
end

local inv_frame
local inv_scroll
local inv_panels = {}          -- 容器编号 -> DPanel

local function CreateContainerPanel( n )
    local pnl = vgui.Create("DPanel")
    pnl:Dock(TOP)
    pnl:DockMargin(0, 0, 0, PanelH() * 0.01)

    -- 背包图标：独立子面板（DImageButton），不走物品的图标渲染路径
    local icon = vgui.Create("DImageButton", pnl)
    icon:SetMouseInputEnabled(true)
    icon:SetDepressImage(false)   -- 按下时不位移
    icon:SetCursor("arrow")       -- 不用手型光标
    icon.Paint = function() end   -- 只由内部 DImage 画图，按钮自身不画任何东西
    icon.DoRightClick = function(self)
        local rightX, topY = self:LocalToScreen(self:GetWide() + 4, 0)
        local leftX = self:LocalToScreen(0, 0)
        OpenContainerMenu(n, rightX, leftX, topY)
    end

    -- ① 每帧现取，不捕获旧表 → 拾取后立刻刷新
    pnl.Paint = function(self, w, h)
        local grid = INVENTORY[n]
        if not grid or not grid[1] then return end

        local gw, gh = #grid, #grid[1]

        -- 总列数 = 图标区 ICON_COLS 列 + 背包列数：面板宽度不变，网格整体右移
        local cell, offsetX = GridCell( self, w, gw )
        if not cell then return end

        local iconH = ICON_ROWS * cell
        local pad = math.min(4, cell * 0.5)      -- 小尺寸时避免出现负宽高
        local inner = math.max(1, cell - pad)

        draw.RoundedBox(2, 0, 0, w, h, COL_BG)

        -- 左侧：背包图标槽（2 行）+ 名字槽（1 行）
        draw.RoundedBox(2, 2, 2, math.max(1, offsetX - 4), math.max(1, iconH - 4), COL_EMPTY)

        local nameX, nameY = 2, iconH + 2
        local nameW, nameH = math.max(1, offsetX - 4), inner
        draw.RoundedBox(2, nameX, nameY, nameW, nameH, COL_EMPTY)

        local label = grid.name or ( ContainerDef( grid ) or {} ).name
        if label and label ~= "" then
            -- 用裁剪防止长名字溢出到背包格上
            local sx, sy = self:LocalToScreen(nameX, nameY)
            render.SetScissorRect(sx, sy, sx + nameW, sy + nameH, true)
            draw.SimpleText(label, GetNameFont(), nameX + nameW * 0.5, nameY + nameH * 0.5,
                COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            render.SetScissorRect(0, 0, 0, 0, false)
        end

        -- ② 背包格子
        for x = 1, gw do
            for y = 1, gh do
                surface.SetDrawColor(grid[x][y] and COL_FULL or COL_EMPTY)
                surface.DrawRect(
                    offsetX + (x - 1) * cell + 2,
                    (y - 1) * cell + 2,
                    inner, inner
                )
            end
        end

        -- 物品图标：只在锚点格画一次，按 X/Y 撑满整块区域
        for x = 1, gw do
            local column = grid[x]
            for y = 1, gh do
                local classname = column and column[y]
                if type(classname) == "string" then
                    local idef = ITEM_LIST[classname]
                    local mat = idef and GetIcon(idef.icon)
                    if mat then
                        surface.SetMaterial(mat)
                        surface.SetDrawColor(255, 255, 255, 255)
                        surface.DrawTexturedRect(
                            offsetX + (x - 1) * cell + 2,
                            (y - 1) * cell + 2,
                            math.max(1, (idef.X or 1) * cell - 4),
                            math.max(1, (idef.Y or 1) * cell - 4)
                        )
                    end
                end
            end
        end

        -- 左侧背包图标由 icon 子面板自己绘制，这里只画槽位底板
    end

    -- ③ 高度、图标尺寸都跟着 cell 走，所以放到 Layout 里算
    pnl.PerformLayout = function(self, w, h)
        local grid = INVENTORY[n]
        if not grid or not grid[1] then return end

        local gw, gh = #grid, #grid[1]
        local cell = math.min(CellMax(), (w - 4) / (gw + ICON_COLS))
        if cell <= 0 then return end

        local offsetX = ICON_COLS * cell
        local iconH = ICON_ROWS * cell          -- 图标固定 2x2 格

        -- 缓存给 Paint / 鼠标命中用，保证三处尺寸完全一致
        self.NMCell, self.NMOffsetX = cell, offsetX

        -- 左侧高度 = 图标 2 行 + 名字 1 行
        -- 在 PerformLayout 里改自身尺寸会再次触发布局，只在真的变了时才 SetTall，
        -- 否则每帧都会重排一次（DScrollPanel 的 Dock 布局会跟着抖动）
        local tall = math.max(gh, ICON_ROWS + NAME_ROWS) * cell
        if math.abs(self:GetTall() - tall) >= 1 then
            self:SetTall(tall)
        end

        icon:SetPos(2, 2)
        icon:SetSize(math.max(1, offsetX - 4), math.max(1, iconH - 4))

        -- 容器类变化时才重新设图
        local classname = ContainerClass( grid )
        if icon.NMClassname ~= classname then
            icon.NMClassname = classname
            local path = grid.icon or ( ContainerDef( grid ) or {} ).icon
            if path and path ~= "" then
                icon:SetImage(path)
                icon:SetVisible(true)
            else
                icon:SetVisible(false)
            end
        end
    end

    -- ④ 右键：只处理物品格；背包图标由 icon 子面板负责
    pnl.ContainerIndex = n
    pnl:SetMouseInputEnabled(true)
    pnl.OnMousePressed = function(self, key)
        if key ~= MOUSE_RIGHT then return end

        local hit = ItemUnderCursor(self)
        if not hit then return end

        local left = hit.offsetX + (hit.x - 1) * hit.cell + 2
        local top  = (hit.y - 1) * hit.cell + 2
        local iw   = ((hit.def and hit.def.X) or 1) * hit.cell

        local rightX, topY = self:LocalToScreen(left + iw + 2, top)
        local leftX = self:LocalToScreen(left, top)

        OpenItemMenu(hit.classname, hit.n, hit.x, hit.y, rightX, leftX, topY)
    end

    inv_scroll:AddItem(pnl)
    inv_panels[n] = pnl
    return pnl
end

-- 容器增删后同步界面：缺的补上，多的删掉（界面没开时直接返回）
function inventory_cl_sync_containers()
    if not IsValid(inv_scroll) then return end

    local maxIndex = 0
    for k in pairs(INVENTORY) do
        if type(k) == "number" and k > maxIndex then maxIndex = k end
    end

    for n = 1, maxIndex do
        if INVENTORY[n] and not IsValid(inv_panels[n]) then
            CreateContainerPanel(n)
        end
    end

    for n, pnl in pairs(inv_panels) do
        if not INVENTORY[n] then
            if IsValid(pnl) then pnl:Remove() end
            inv_panels[n] = nil
        end
    end
end

function inventory_cl_inventory_ui()
    if IsValid(inv_frame) then inv_frame:Close() end

    local PANEL_W, PANEL_H = ScrW() * 0.95, ScrH() * 0.8

    local DermaPanel = vgui.Create("DFrame")
    inv_frame = DermaPanel
    DermaPanel:SetSize(PANEL_W, PANEL_H)
    DermaPanel:Center()
    DermaPanel:SetTitle("")
    DermaPanel:SetDraggable(false)
    DermaPanel:ShowCloseButton(false)
    DermaPanel:MakePopup()
    DermaPanel.Paint = function(self, w, h)
        draw.RoundedBox(2, 0, 0, w, h, Color(0, 0, 0, 200))
    end

    local quit = DermaPanel:Add("DButton")
    quit:SetText("exit")
    quit:SetFont(GetNameFont())
    quit:SetSize(PANEL_W * 0.05, PANEL_H * 0.03)
    quit:SetPos(DermaPanel:GetWide() - quit:GetWide() - 8, 8)
    quit.DoClick = function() DermaPanel:Close() end

    local RESERVE_RIGHT  = 0.35    -- 右侧预留空白区域，占整个面板宽度的比例
    local INVENTORY_LEFT = 0.35   -- 背包区左边界（与加入 40% 空白之前的左端对齐）

    local inventories = vgui.Create("DScrollPanel", DermaPanel)
    inventories:SetWide(PANEL_W * (1 - INVENTORY_LEFT - RESERVE_RIGHT))
    inventories:Dock(LEFT)
    inventories:DockMargin(PANEL_W * INVENTORY_LEFT, PANEL_H * 0.02, 0, PANEL_H * 0.009)

    -- ⑤ D 键：对指针指向的物品执行它的"丢弃"方法
    DermaPanel.OnKeyCodePressed = function(self, key)
        if key ~= KEY_D then return end

        local pnl = HoveredContainerPanel()
        if not pnl then return end

        local hit = ItemUnderCursor(pnl)
        if not hit or hit.kind ~= "item" then return end

        local def = ITEM_LIST[hit.classname]
        if not def or type(def.methon) ~= "table" or def.methon[DROP_METHOD] == nil then return end

        SendItemMethod(hit.classname, DROP_METHOD, hit.n, hit.x, hit.y)
    end

    inv_scroll = inventories
    inv_panels = {}

    inventory_cl_sync_containers()
end