
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )

include( "shared.lua" )
include( "outputs.lua" )

function ENT:Initialize()
end

function ENT:KeyValue( key, value )
	if key == "ITEMclass" then 
		if ITEM_LIST[value] == nil then print("ITEM CLASSNAME IS NIL!") return end
		self:SetNWString("ITEMclass",value)
		self:SetModel(ITEM_LIST[value].model)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)

		local phys = self:GetPhysicsObject()
	
		if phys:IsValid() then phys:Wake() end
	end
end

function ENT:Use( activator, caller )
	if activator:IsPlayer() then
		if activator:InventoryAddItem(self:GetNWString("ITEMclass")) then
			self:Remove()
		else
			return
		end
		--PrintTable(activator:GetInventory())
	else
	print(	tostring(activator).." try to pick up "..self.." ITEM "..self:GetNWString("ITEMclass")..")"	) 
	end
end

function ENT:OnRestore()
end

function ENT:AcceptInput( name, activator, caller, data )
	return false
end

--[[---------------------------------------------------------
	Name: UpdateTransmitState
	Desc: Set the transmit state
-----------------------------------------------------------]]
function ENT:UpdateTransmitState()
	return TRANSMIT_PVS
end

function ENT:Think()
end

function ENT:SpawnFunction( ply, tr, ClassName )

	local SpawnPos = tr.HitPos + tr.HitNormal * 10
	local SpawnAng = ply:EyeAngles()
	SpawnAng.p = 0
	SpawnAng.y = SpawnAng.y + 180

	local ent = ents.Create( ClassName )
	if ( !IsValid( ent ) ) then return end

	ent:SetCreator( ply )
	ent:SetPos( SpawnPos )
	ent:SetAngles( SpawnAng )
	ent:Spawn()
	ent:Activate()

	ent:DropToFloor()

	return ent

end
