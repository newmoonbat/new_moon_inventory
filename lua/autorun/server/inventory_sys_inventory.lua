INVENTORY = INVENTORY or {}
--INVENTORY[引索值(steamid64)][第N个容器][X][Y] = 物品 
local meta = FindMetaTable( "Player" )

util.AddNetworkString("inventory_sys_inventory_send")
util.AddNetworkString("inventory_sys_inventory_oprations")
util.AddNetworkString("inventory_sys_inventory_full")


function meta:GetInventory()
    local inv = INVENTORY[self:SteamID64()]
    if not inv or #inv == 0 then return false end
    return inv
end

-- 不传 n/x/y：扫描整个背包，返回第一个可放置的位置 n, x, y
-- 传了 n/x/y：只检测该位置，可放返回 n, x, y，不可放返回 false
function meta:InventoryValid(IN, n, x, y)
    if istable(IN) then IN = IN.classname end
    local def = ITEM_LIST[IN]
    if type(def) ~= "table" then return false end

    local inv = self:GetInventory()
    if not inv then return false end     -- 纯查询：不建容器，由调用方负责

    local w, h = def.X or 1, def.Y or 1

    -- 指定位置模式：只测 (n, x, y) 这一块矩形
    if n and x and y then
        local grid = inv[n]
        if type(grid) ~= "table" or not grid[1] then return false end

        local gw, gh = #grid, #grid[1]
        if x < 1 or y < 1 or x + w - 1 > gw or y + h - 1 > gh then return false end

        for cy = y, y + h - 1 do
            for cx = x, x + w - 1 do
                if grid[cx] and grid[cx][cy] then return false end
            end
        end

        return n, x, y
    end

    -- 自动找位模式
    for i = 1, #inv do
        local grid = inv[i]
        if type(grid) == "table" and grid[1] then
            local gw, gh = #grid, #grid[1]
            if gw >= w and gh >= h then
                for py = 1, gh - h + 1 do          -- 逐行
                    for px = 1, gw - w + 1 do      -- 逐列
                        local free = true
                        for yy = py, py + h - 1 do  -- 矩形
                            for xx = px, px + w - 1 do
                                if grid[xx][yy] then free = false break end
                            end
                            if not free then break end
                        end
                        if free then
                            return i, px, py       -- 同一层拿到 3 个值
                        end
                    end
                end
            end
        end
        -- 这个容器放不下：不 break，继续看下一个容器
    end

    return false
end

function meta:RemoveItem( n, x, y )
    local inv = self:GetInventory()
    if not inv or type( inv[n] ) ~= "table" or not inv[n][x] then return end
    local cell = inv[n][x][y]
    if not istable(cell) then return end
    cell:Remove()
end
function meta:DropItem( n, x, y )
    local inv = self:GetInventory()
    if not inv or type( inv[n] ) ~= "table" or not inv[n][x] then return end
    local cell = inv[n][x][y]
    if not istable(cell) then return end
    cell:drop()
end

function meta:UpDateINV(inv_id)
    local inv = self:GetInventory() or {}
    local inv_start , inv_end
    local clean = false
    if inv_id == -1 then--负一则更新所有容器
        inv_start = 1
        inv_end = #inv
        clean = true
    else
        inv_end , inv_start = inv_id , inv_id
    end

    local INVENTORY_CAHE = {}
    local update_list = {}
    for n = inv_start , inv_end do
        local grid = inv[n]
        if type( grid ) == "table" and grid[1] then
            local inv_classonly = { classname = grid.classname }
            
            for x = 1, #grid do
                inv_classonly[x] = {}
                for y = 1, #grid[1] do
                    local cell = grid[x][y]
                    if type( cell ) == "table" then
                        inv_classonly[x][y] = cell.classname
                    elseif cell == true then
                        inv_classonly[x][y] = true
                    else
                        inv_classonly[x][y] = false
                    end
                end
            end
            INVENTORY_CAHE[n] = inv_classonly
            table.insert(update_list,n)
        end
    end
    if not clean and #update_list == 0 then return false end   -- 单容器更新失败
    net.Start("inventory_sys_inventory_send")
    net.WriteBool(clean)
    net.WriteTable(update_list)
    net.WriteTable(INVENTORY_CAHE)
    net.Send(self)
    return true
end

function meta:message_inventory_full()
    net.Start("inventory_sys_inventory_full")
    net.Send(self)
end    

function meta:InventoryAddItem(INPUT,n,x,y,UPDATE_dont)
    if not self:IsPlayer() then return false end

    -- ① 解析 classname：字符串或表
    local classname
    if type( INPUT ) == "string" then
        classname = INPUT
    elseif istable( INPUT ) then
        classname = INPUT.classname        -- 这一层只认 classname
    else
        return false                       -- 不再 error()
    end

    -- ② 类必须已注册，否则不建实例（避免 __call 顺手注册新类）
    local def = ITEM_LIST[classname]
    if not def then return false end

    -- ③ 建实例（软规则：尺寸/class 不允许被外部覆盖）
    local overrides = {}
    if istable( INPUT ) then
        for k, v in pairs( INPUT ) do
            if type( k ) ~= "number"
                and k ~= "X" and k ~= "Y" and k ~= "classname"
                and k ~= "OWNER" and k ~= "pos" then
                overrides[k] = istable( v ) and table.Copy( v ) or v
            end
        end
    end
    overrides.classname = classname

    local writeitem = ITEM( overrides )    -- __call 内部已对嵌套表 table.Copy
    if not writeitem then return false end
    writeitem.X, writeitem.Y = def.X or 1, def.Y or 1

    --测试inventory是否有效，否则创建物品栏
    local inv = self:GetInventory()
    if not inv then
        self:CreateInventory( "container_base" )
        inv = self:GetInventory()
        if not inv then return false end
    end

    -- ④ 找位置：传了 n/x/y 就只测那一处，否则自动找第一个空位
    local rn, rx, ry
    if n and x and y then
        rn, rx, ry = self:InventoryValid( classname, n, x, y )
    else
        rn, rx, ry = self:InventoryValid( classname )
    end

    if not rn then
        self:message_inventory_full()
        return false
    end
    n, x, y = rn, rx, ry

    -- ⑤ 写网格
    local grid = inv[n]
    for cx = x, x + writeitem.X - 1 do
        for cy = y, y + writeitem.Y - 1 do
            grid[cx][cy] = true
        end
    end
    writeitem.OWNER = self:SteamID64()
    writeitem.pos = {["n"] = n,["x"] = x,["y"] = y}
    grid[x][y] = writeitem

    -- ⑥ 同步；失败则回滚，保证「进背包」和「删实体」不会一半一半
    if not UPDATE_dont then 
        if not self:UpDateINV( n ) then
            for cx = x, x + writeitem.X - 1 do
                for cy = y, y + writeitem.Y - 1 do
                    grid[cx][cy] = false
                end
            end
            return false
        end
    end
    grid[x][y]:OnPickUp()
    return true
end

function meta:CreateInventory( containerClassName )
    local def = ITEM_LIST[containerClassName]
    if not def or not def.DATA or not def.DATA.container then return false end

    local id  = self:SteamID64()
    local inv = INVENTORY[id]
    if not inv then
        inv = {}
        INVENTORY[id] = inv
    end

    local gw, gh = def.DATA.container.X, def.DATA.container.Y
    local A = ITEM(containerClassName)
    for x = 1, gw do
        A[x] = {}
        for y = 1, gh do A[x][y] = false end
    end
    A.OWNER = self:SteamID64()
    inv[#inv + 1] = A
    inv[#inv].pos = {["n"] = #inv,["x"] = 0,["y"] = 0}
    self:UpDateINV( #inv )      -- 新容器立刻下发，否则客户端要等到往里面放东西才看得到
    return A
end

hook.Add("DoPlayerDeath", "inventory_sys_inventory_player_death", function( ply )
    local inv = INVENTORY[ply:SteamID64()]
    if not inv then return end

    local eye = ply:EyeAngles()
    local fwd = eye:Forward()
    local pos = ply:GetPos()
    local ang = ply:GetAngles()

    for n = 1, #inv do
        local container = inv[n]
        if container then
            if container.classname ~= "container_base" then
                container:drop( true )       -- 容器本体 + 内容物一起掉落
            else
                -- 基础容器只掉内容物，本体留着
                local contents = {}
                for x = 1, #container do
                    for y = 1, #container[x] do
                        local cell = container[x][y]
                        if type( cell ) == "table" then
                            contents[#contents + 1] = table.Copy( cell )
                        end
                    end
                end

                for i = 1, #contents do
                    if not ITEM:Spawn( contents[i], pos, ang, Vector( 0, 0, 0 ) ) then
                        print( "fail to spawn item entity " .. tostring( contents[i].classname ) )
                    end
                end
            end
        end
    end

    INVENTORY[ply:SteamID64()] = {}
    ply:CreateInventory("container_base")
    ply:UpDateINV(-1)
end)

hook.Add( "PlayerInitialSpawn", "inventory_sys_inventory_plyspawn", function( ply )
    if not ply:GetInventory() then
        ply:CreateInventory("container_base")
    end

    local inv = ply:GetInventory()
    for n = 1, ( inv and #inv or 0 ) do
        ply:UpDateINV( n )
    end
end )

local inventory_sys_oprations = {
    ["DoItemMethon"] = function(ply,tab)
        local n,x,y,name = tab.n,tab.x,tab.y,tab.methon
        local inv = ply:GetInventory()
        if not inv or type( inv[n] ) ~= "table" then return false end

        -- x == 0 且 y == 0：目标是这个容器本身（左侧背包图标）。
        -- 容器实例的 pos 为 { n, 0, 0 }，CallMethod 会自动用 DATA.container.methon
        if x == 0 and y == 0 then
            if not ITEM_LIST[ inv[n].classname ] then return false end
            return inv[n]:CallMethod( name )
        end

        local column = inv[n][x]
        local item = column and column[y]
        if type( item ) ~= "table" then return false end

        return item:CallMethod( name )
    end,
    ["Move2"] = function(ply,tab)
        local inv = ply:GetInventory()
        local item = inv[tab.item.n][tab.item.x][tab.item.y]
        local target = tab.target
        --target = {n = , x = , y =}
    end,
}

net.Receive("inventory_sys_inventory_oprations", function( _, ply )
    if not IsValid( ply ) then return end

    local opration = net.ReadString()
    local tab = net.ReadTable()

    local func = inventory_sys_oprations[opration]
    if type( func ) ~= "function" then
        print("unknow opration "..tostring(opration).." form "..tostring(ply))
        return
    end
    func( ply, tab )
end)

concommand.Add("inv_sv_prt",function()--测试用途
    PrintTable(INVENTORY)
end)