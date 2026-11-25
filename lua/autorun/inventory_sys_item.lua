--这是一个share的文件
if SERVER then AddCSLuaFile( "inventory/cl_ui.lua" ) end
ITEM = ITEM or {}
ITEM.__index = ITEM
ITEM_LIST = ITEM_LIST or {}

function ITEM:new(A,base)
    if A.classname == nil then error("ITEM CLASSNAME IS NIL!") return end
    --同名项覆盖，不同命则写入，包括次级的table
    local newItem = table.Copy(ITEM_LIST[base] or ITEM_LIST["item_base"]) or {}
    table.Merge(newItem, A)

    ITEM_LIST[newItem.classname] = newItem

    local obj = setmetatable(newItem, ITEM)
    return obj
end
-- class 可以是 classname 字符串，也可以是 ITEM 对象（从它取 classname）
function ITEM:Spawn(class,pos,angle,vel)
    if CLIENT then error("ITEM:Spawn() is a sv only function") end
    local classname = istable( class ) and class.classname or class
    if type( classname ) ~= "string" or not ITEM_LIST[classname] then
        error("unknow item class "..tostring(classname))
    end

    local ent = ents.Create( "prop_item" )
    if not IsValid( ent ) then
        print("can't spawn item entity "..tostring( classname ))
        return
    end

    ent:SetKeyValue( "ITEMclass", classname )
    ent:SetPos( pos )
    ent:SetAngles( angle )
    ent:SetVelocity( vel )

    ent:Spawn()
    ent:Activate()

    local phys = ent:GetPhysicsObject()
    if IsValid( phys ) then phys:Wake() end
    return ent
end
-- 客户端格子里存的是 classname 字符串、且预测用的实例是临时表，
-- 所以身份校验在 CLIENT 上按 classname 比较；服务端仍是严格引用相等
local function CellIsSelf( cell, self )
    if cell == self then return true end
    if CLIENT then
        if type( cell ) == "string" then return cell == self.classname end
        return istable( cell ) and cell.classname == self.classname
    end
    return false
end

--客户端也drop，反正都是指向remove，在share drop更简明
--如果在容器中丢弃物品则不要更新
--最后统一在容器的函数中更新
--remove会自动更新背包
function ITEM:drop(UPDATE_dont,RETURN2BAG_dont)
    if SERVER then
        local pos = self.pos
        -- 没有坐标说明这个实例不属于任何背包；报错以追踪调用方问题
        assert( istable( pos ),
            "[new_moon_inventory] ITEM:drop() 调用时没有 pos, classname=" .. tostring( self.classname ) )

        local container = ( pos.x == 0 and pos.y == 0 )
        local owner = player.GetBySteamID64(self.OWNER)
        if not owner then return false end

        -- 归属校验：该位置必须还是自己。
        -- 否则先 Spawn 再 Remove 会失败，留下一个世界里多出来的实体（复制）
        local inv = INVENTORY[self.OWNER]
        if not inv or not inv[pos.n] then return false end
        if container then
            if inv[pos.n] ~= self then return false end
        else
            local col = inv[pos.n][pos.x]
            if not col or col[pos.y] ~= self then return false end
        end

        local eye   = owner:EyeAngles()
        local fwd   = eye:Forward()
        local ent   = ITEM:Spawn(
            self,
            owner:EyePos() + fwd * 10 - Vector( 0, 0, 15 ),
            eye,
            fwd * 5
        )
        -- 实体没建起来：背包状态一点没动，物品留在原处
        if not ent then return false end

        if not container then
            return self:Remove(UPDATE_dont) ~= false
        end

        -- 收集时取快照，避免依赖容器内的坐标
        local contents = {}
        for x = 1, #self do
            for y = 1, #self[1] do
                local cell = self[x][y]
                if ITEM:ISITEM( cell ) then
                    contents[#contents + 1] = table.Copy( cell )
                end
            end
        end

        self:Remove( true )

        local dropPos = owner:EyePos() + fwd * 10 - Vector( 0, 0, 15 )
        for i = 1, #contents do
            local data = contents[i]
            local rot = istable( data.pos ) and data.pos.r or false
            if RETURN2BAG_dont or ( not owner:InventoryAddItem( data, nil, nil, nil, rot, true ) ) then
                if not ITEM:Spawn( data, dropPos, eye, fwd * 5 ) then
                    print( "item " .. tostring( data.classname ) .. " on container ".. tostring( self.classname ) .. " now missing" )
                end
            end
        end

        if not UPDATE_dont then
            owner:UpDateINV(-1)
        end

        return true
    elseif CLIENT then
        self:Remove()
        return true
    end
end

function ITEM:Remove(UPDATE_dont)
    local pos = self.pos
    if not istable(pos) then return false end

    local container = false
    local sizeX,sizeY
    local posX,posY
    local inv
    local ply

    if pos.x == 0 and pos.y == 0 then
        posX,posY = 1 , 1
        container = true 
        sizeX , sizeY = self.DATA.container.X , self.DATA.container.Y
    else
        local w, h = self.X or 1, self.Y or 1
        if pos.r then w, h = h, w end      -- 旋转后宽高互换
        sizeX , sizeY = w , h
        posX , posY = self.pos.x , self.pos.y
    end

    if SERVER then 
        inv = INVENTORY[self.OWNER]
        ply = player.GetBySteamID64(self.OWNER)
    elseif CLIENT then 
        inv = INVENTORY
    end

    if not inv or not inv[pos.n] then return false end

    -- 身份校验：该位置必须还是自己，否则说明已被移除（或数组已移位指向别的对象）
    if container then
        if not CellIsSelf( inv[pos.n], self ) then return false end
    else
        local col = inv[pos.n][posX]
        if not col or not CellIsSelf( col[posY], self ) then return false end
    end

    -- 只清物品自己占的格子；容器自身的网格不在这里清（内容物由 drop 处理）
    if not container then
        for x = posX, posX + (sizeX or 1) - 1 do
            for y = posY, posY + (sizeY or 1) - 1 do
                if inv[pos.n][x] then inv[pos.n][x][y] = false end
            end
        end
    end

    if container then
        local N = pos.n
        inv[N] = nil
        for n = N + 1, #inv + 1 do inv[n-1] = inv[n] end
        inv[#inv + 1] = nil
        for n = N, #inv do inv[n].pos.n = n end     -- ← 关键
        if SERVER and IsValid( ply ) and not UPDATE_dont then ply:UpDateINV( -1 ) end
    else
        if SERVER and IsValid(ply) then
            if not(UPDATE_dont) then
                ply:UpDateINV(pos.n)
            end
        end
    end

    self.pos = nil      -- 移除成功：清掉坐标，避免旧对象再次操作到别人
    return true
end

function ITEM:ISITEM(IN)
    if istable(IN) and IN.classname and ITEM_LIST[IN.classname] then return true else return false end
end

-- 已装备的容器：容器级坐标 pos = { n, x = 0, y = 0 }。
-- 用它决定方法该从 DATA.container.methon 还是物品类的 methon 里取。
function ITEM:IsEquippedContainer()
    local pos = self.pos
    if type( pos ) ~= "table" then return false end
    if pos.x ~= 0 or pos.y ~= 0 then return false end
    return self.DATA ~= nil and self.DATA.container ~= nil
end

-- 当前该用的方法表：已装备容器 -> DATA.container.methon，其余 -> 物品类的 methon
function ITEM:GetMethods()
    local methods
    if self:IsEquippedContainer() then
        methods = self.DATA.container.methon
    else
        local def = ITEM_LIST[ self.classname ]
        methods = def and def.methon
    end
    if type( methods ) ~= "table" then return end
    return methods
end

-- 查找方法。条目格式：function(self) 或 { name = , share = , sv = , cl = }
function ITEM:GetMethod( name )
    local methods = self:GetMethods()
    if not methods then return end
    return methods[ name ]
end

function ITEM:CallMethod( name )
    local method = self:GetMethod( name )
    if not method then return false end

    if type( method ) == "function" then
        method( self )
        return true
    end

    if istable( method ) then
        -- share 两端都跑；sv/cl 各取其一。
        -- 不能写 method.sv or method.cl：sv 为 nil 时会串到 cl
        local ran = false

        if type( method.share ) == "function" then
            -- 只有显式 return false 才中止；返回 nil（无返回值）视为成功
            if method.share( self ) == false then return false end
            ran = true
        end
        --如果share return false会终止执行
        local fn = method[ SERVER and "sv" or "cl" ]
        if type( fn ) == "function" then
            fn( self )
            ran = true
        end

        return ran
    end

    return false
end

function ITEM:move2( n, x, y, r)
    local ply = SERVER and player.GetBySteamID64( self.OWNER ) or LocalPlayer()
    if not IsValid( ply ) then return false end

    local pos = self.pos
    if not istable( pos ) then return false end

    n, x, y = tonumber( n ), tonumber( x ), tonumber( y )
    if not n or not x or not y then return false end

    if r == nil then r = pos.r or false end     -- 不传朝向就保持原样
    r = r and true or false

    local old = { n = pos.n, x = pos.x, y = pos.y, r = pos.r and true or false }   -- 值拷贝
    if old.n == n and old.x == x and old.y == y and old.r == r then return true end   -- 原地且朝向未变

    local snapshot = table.Copy( self )               -- 保留实例数据
    snapshot.classname = self.classname
    snapshot.pos = nil

    -- 先腾出原位置：否则目标区域会被自己挡住，判定必然失败
    if self:Remove( true ) == false then return false end

    if ply:InventoryAddItem( snapshot, n, x, y, r, true ) then
        -- 跨容器移动时，源容器也要刷新，否则客户端会留着旧位置的图标
        if SERVER and old.n ~= n then ply:UpDateINV( old.n ) end
        return true
    end

    if not ply:InventoryAddItem( snapshot, old.n, old.x, old.y, old.r, false ) then
        print( "[new_moon_inventory] move2 回滚失败，物品 " .. tostring( self.classname ) .. " 丢失" )
    end
    return false
end

-- 拾取判定：显式返回 true / false。
-- 必须显式 return true：调用方（服务端与客户端的 InventoryAddItem）都用
-- `if not self:OnPickUp() then 拒绝 end`，返回 nil 会被当成拒绝。
function ITEM:OnPickUp()
    if self.func and self.func.OnPickUp then
        if not self.func.OnPickUp(self) then
            return false
        end
    end
    return true
end

--物品类不存在则ITEM()不会返回对象

setmetatable( ITEM, { __call = function( _, def, base )
    if type( def ) == "string" then def = { classname = def } end
    if type( def ) ~= "table" or def.classname == nil then return end

    local class = ITEM_LIST[def.classname]
    if not class then error("unknow item class "..def.classname) end

    local inst = table.Copy( class )
    for k, v in pairs( def ) do
        inst[k] = istable( v ) and table.Copy( v ) or v
    end
    return inst
end } )


--[[
使用ITEM:new()注册物品
ITEM(物品类名)返回物品对象
或者使用如下格式的table返回一个被修改了数据的物品对象
ITEM({
classname = "item_test",
其他数据,
})
其他数据的key对应下方的物品注册表
不要在ITEM()时修改物品X,Y大小
--]]
ITEM:new({
    classname = "item_base",
    name = "基类物品",
    X = 1,
    Y = 1,
    model = "models/props_junk/wood_crate001a.mdl",
    icon = "items/test.png",
    mass = 1,
    ITEM_TYPE = "ITEM",
    DATA = {},
    func = {--代码用
    OnPickUp = function(self) return true end,--这是一个share的函数
    },
    methon = {--ui中显示，左边是名称
    ["drop"] = {
        name = "丢弃",
        share = function(self) self:drop() return end
    },--不分sv cl则share
    ["test"] = {
        name = "test",
        share = function() print("function test on SHARE") end,
        sv = function() print("function test on SV") end,
        cl = function() print("function test on CL") end,
    }
    },
})

ITEM:new({
    classname = "container_base",
    name = "物品栏",
    X = 6,
    Y = 3,
    model = "models/props_junk/wood_crate001a.mdl",
    icon = "items/test.png",
    mass = 1,
    ITEM_TYPE = "CONTAINER",
    DATA = {
        container = {
            X = 6,
            Y = 3,
            massrate = 90,
        }
    },
})

ITEM:new({
    classname = "container_test",
    name = "测试容器",
    model = "models/props_collectables/backpack.mdl",
    DATA = {
        container = {
            X = 10,
            Y = 6,
            methon = {
                ["disequip"] = {
                    name = "解除装备",
                    share = function(self) self:drop() end,
                }
            },
        },
    },
    methon = {
    ["equip"] = {
        name = "装备",
        share = function(self)
                if not self:Remove(true) then
                    return false 
                end
            end,
        sv = function(self)
            local ply = player.GetBySteamID64(self.OWNER)
                if ply then
                    ply:CreateInventory(self.classname)
                end
            end,
        },
    },
},"container_base")

ITEM:new({
    classname = "item_test",
    name = "测试物品",
    model = "models/props_se/combine_cmb_citizen_cloth_pack.mdl",
    X = 2,
    Y = 2,
    func = {
    OnPickUp = function(self) return true end,
    },   
})