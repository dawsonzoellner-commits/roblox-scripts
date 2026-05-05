
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local Debris              = game:GetService("Debris")

-- Only runs in Bot Player mode
ServerScriptService:WaitForChild("BotPlayerStart", math.huge).Event:Wait()

--------------------------------------------------------------------------------
-- UNIT DEFINITIONS
-- attackAnim  = hardcoded animation ID
-- attackAttr  = attribute name on the cloned template (set by RegisterFarmerAnims)
-- redneck/riotGuard pick randomly at spawn time (handled in resolveAttackAnim)
--------------------------------------------------------------------------------
local UNITS = {
	{
		id = "redneck", template = "Redneck", cost = 10,
		speed = 10, health = 200, damage = 25, cooldown = 0.7,
		role = "melee",
		walkAnim = "rbxassetid://113807386984718",
		idleAnim = "rbxassetid://129843177790707",
		-- attack anims picked randomly in resolveAttackAnim
	},
	{
		id = "farmer", template = "FarmerUnit", cost = 15,
		speed = 4, health = 100, damage = 45, cooldown = 0.45,
		role = "ranged",
		walkAttr         = "FarmerWalkAnim",
		idleAttr         = "FarmerIdleAnim",
		attackAttr       = "FarmerShootAnim",
		reloadAttr       = "FarmerReloadAnim",
		shotsBeforeReload = 2,
	},
	{
		id = "builder", template = "BuilderUnit", cost = 20,
		speed = 6, health = 280, damage = 25, cooldown = 0.6,
		role = "tank",
		walkAnim   = "rbxassetid://119098340440076",
		idleAnim   = "rbxassetid://74182242424283",
		attackAnim = "rbxassetid://80080192712226",
	},
	{
		id = "policeman", template = "Policeman", cost = 15,
		speed = 5, health = 150, damage = 13, cooldown = 0.3,
		role = "ranged",
		walkAttr         = "PolicemanWalkAnim",
		idleAttr         = "PolicemanIdleAnim",
		attackAttr       = "PolicemanShootAnim",
		reloadAttr       = "PolicemanReloadAnim",
		shotsPerBurst    = 3,
		shotsBeforeReload = 4,
		pelletCount      = 1,
		skinColor        = Color3.fromRGB(255, 210, 160),
	},
	{
		id = "riotGuard", template = "Riot Guard", cost = 40,
		speed = 3, health = 500, damage = 25, cooldown = 1.0,
		role = "tank",
		walkAttr = "RiotWalkAnim",
		idleAttr = "RiotIdleAnim",
		-- attack anims picked randomly from RiotAttack1Anim/RiotAttack2Anim in resolveAttackAnim
	},
	{
		id = "shotgunner", template = "Shotgunner", cost = 20,
		speed = 4, health = 150, damage = 45, cooldown = 0.45,
		role = "ranged",
		walkAttr          = "ShotgunnerWalkAnim",
		idleAttr          = "ShotgunnerIdleAnim",
		attackAttr        = "ShotgunnerShootAnim",
		reloadAttr        = "ShotgunnerReloadAnim",
		shotsBeforeReload = 6,
	},
}

local MAX_MONEY   = 200
local MAX_UNITS   = 14
local FALL_KILL_Y = -50
local LINGER_TIME = 30

local botMoney = 0

local HUMAN_DEATH_ANIMS = {
	"rbxassetid://112646178864650",
	"rbxassetid://108008217888533",
	"rbxassetid://73764140122967",
}
do
	local policemanTmpl = ReplicatedStorage:FindFirstChild("Policeman")
	local policeDeathId = policemanTmpl and policemanTmpl:GetAttribute("PolicemanDeathAnim") or ""
	if policeDeathId ~= "" then table.insert(HUMAN_DEATH_ANIMS, policeDeathId) end
end

--------------------------------------------------------------------------------
-- STRATEGY STATE
--------------------------------------------------------------------------------
local preference = "mixed"
local aggression = 0.55
local rushMode   = false
local rushGoal   = 0
local burstSize  = 2

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local function countBotUnits()
	local n = 0
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") and obj.Name == "Zombie" and obj:GetAttribute("BotUnit") then
			local hum = obj:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then n += 1 end
		end
	end
	return n
end

local function countBotUnitsByType()
	local counts = {}
	for _, u in UNITS do counts[u.id] = 0 end
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") and obj.Name == "Zombie" and obj:GetAttribute("BotUnit") then
			local hum = obj:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local id = obj:GetAttribute("UnitId")
				if id and counts[id] then counts[id] += 1 end
			end
		end
	end
	return counts
end

local function countPlayerUnits()
	local n = 0
	local names = { CustomNPC=true, FarmerNPC=true, BuilderNPC=true,
	                PolicemanNPC=true, ["Riot Guard"]=true, ShotgunnerNPC=true, SWATNPC=true }
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") and names[obj.Name] then n += 1 end
	end
	return n
end

-- Returns true if every living player unit deals only bullet damage
-- Returns true if every living player unit deals only bullet damage
local function playerOnlyHasBulletUnits()
	local bulletNames = { FarmerNPC = true, PolicemanNPC = true, ShotgunnerNPC = true, SWATNPC = true }
	local meleeNames  = { CustomNPC = true, BuilderNPC = true, ["Riot Guard"] = true }
	local hasBullet, hasMelee = false, false
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") then
			local hum = obj:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				if bulletNames[obj.Name] then hasBullet = true
				elseif meleeNames[obj.Name] then hasMelee = true end
			end
		end
	end
	return hasBullet and not hasMelee
end

--------------------------------------------------------------------------------
-- RESOLVE ATTACK ANIMATION
-- Called after cloning the template so attribute values are available.
--------------------------------------------------------------------------------
local REDNECK_ATTACKS = {
	"rbxassetid://127576285148293",
	"rbxassetid://79902482773923",
	"rbxassetid://136273491855743",
}

local function resolveAttackAnim(unitDef, unit)
	if unitDef.id == "redneck" then
		return REDNECK_ATTACKS[math.random(#REDNECK_ATTACKS)]
	elseif unitDef.id == "riotGuard" then
		local a1 = unit:GetAttribute("RiotAttack1Anim") or ""
		local a2 = unit:GetAttribute("RiotAttack2Anim") or ""
		local choices = {}
		if a1 ~= "" then table.insert(choices, a1) end
		if a2 ~= "" then table.insert(choices, a2) end
		return #choices > 0 and choices[math.random(#choices)] or ""
	elseif unitDef.attackAnim then
		return unitDef.attackAnim
	elseif unitDef.attackAttr then
		return unit:GetAttribute(unitDef.attackAttr) or ""
	end
	return ""
end

--------------------------------------------------------------------------------
-- DEATH HANDLER
--------------------------------------------------------------------------------
local function setupBotDeath(unit)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- Pre-save riot guard helmet; dropHat() destroys the Accessory before riseAsZombie can copy it
	local savedHelmet
	if unit:GetAttribute("UnitId") == "riotGuard" then
		for _, child in unit:GetChildren() do
			if child:IsA("Accessory") then
				savedHelmet = child:Clone()
				break
			end
		end
	end

	local function dropWeapon()
		-- Find a non-hat Accessory (weapon) and drop its Handle part
		local handle
		for _, child in unit:GetChildren() do
			if child:IsA("Accessory") then
				local h = child:FindFirstChild("Handle")
				if h and not h:FindFirstChild("HatAttachment") then
					handle = h
					break
				end
			end
		end
		if not handle then return end
		local weld = handle:FindFirstChild("AccessoryWeld")
		if weld then weld:Destroy() end
		handle.Parent     = Workspace
		handle.Anchored   = false
		handle.CanCollide = true
		handle.AssemblyLinearVelocity = Vector3.new(math.random(-4,4), 5, math.random(-4,4))
		Debris:AddItem(handle, 20)
	end

	local function dropHat()
		local hat
		for _, child in unit:GetChildren() do
			if child:IsA("Hat") then
				hat = child; break
			elseif child:IsA("Accessory") then
				local h = child:FindFirstChild("Handle")
				if h and h:FindFirstChild("HatAttachment") then hat = child; break end
			end
		end
		if not hat then return end
		local handle = hat:FindFirstChild("Handle")
		if not handle then return end
		for _, obj in handle:GetChildren() do
			if obj:IsA("Weld") or obj:IsA("WeldConstraint") or obj:IsA("Motor6D") then
				obj:Destroy()
			end
		end
		local head = unit:FindFirstChild("Head")
		if head then
			for _, obj in head:GetChildren() do
				if (obj:IsA("Weld") or obj:IsA("WeldConstraint")) and
				   (obj.Part0 == handle or obj.Part1 == handle) then
					obj:Destroy()
				end
			end
		end
		handle.Parent     = Workspace
		handle.Anchored   = false
		handle.CanCollide = true
		handle.AssemblyLinearVelocity  = Vector3.new(math.random(-4,4), 8, math.random(-4,4))
		handle.AssemblyAngularVelocity = Vector3.new(math.random(-6,6), math.random(-6,6), math.random(-6,6))
		Debris:AddItem(handle, 20)
		hat:Destroy()
	end

	local function riseAsZombie()
		local isRiotGuard = unit:GetAttribute("UnitId") == "riotGuard"
		local template = ReplicatedStorage:FindFirstChild("ZombieTemplate")
		if not template then
			local zf = ReplicatedStorage:FindFirstChild("Zombies")
			local nf = zf and zf:FindFirstChild("NormalZombies")
			template = nf and nf:FindFirstChild("Zombie1")
		end
		if not template then return end
		local rootPart = unit:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local zombieModel = template:Clone()
		zombieModel.Name = "Zombie"
		for _, desc in zombieModel:GetDescendants() do
			if desc:IsA("BasePart") then desc.Anchored = false end
		end
		local animScript = zombieModel:FindFirstChild("Animate")
		if animScript then animScript.Disabled = true end
		zombieModel:SetAttribute("FarmerSpawned", true)
		zombieModel:SetAttribute("ZombieType",    isRiotGuard and "RiotGuard" or "Normal")
		zombieModel:SetAttribute("AttackDamage",  10)
		local zombieHum = zombieModel:FindFirstChildOfClass("Humanoid")
		if zombieHum then
			local hp = isRiotGuard and 250 or 100
			zombieHum.MaxHealth = hp
			zombieHum.Health    = hp
			zombieHum.WalkSpeed = 5
		end
		local tgtColors = zombieModel:FindFirstChildOfClass("BodyColors")
		if tgtColors then
			local g = tgtColors.HeadColor3
			tgtColors.TorsoColor3    = g
			tgtColors.LeftArmColor3  = g
			tgtColors.RightArmColor3 = g
			tgtColors.LeftLegColor3  = g
			tgtColors.RightLegColor3 = g
		end
		for _, desc in zombieModel:GetDescendants() do
			if desc:IsA("Shirt") or desc:IsA("Pants") or desc:IsA("Accessory") then
				desc:Destroy()
			end
		end
		for _, child in unit:GetChildren() do
			if child:IsA("Shirt") or child:IsA("Pants") then
				child:Clone().Parent = zombieModel
			end
		end
		if isRiotGuard and savedHelmet then
			savedHelmet:Clone().Parent = zombieModel
		end
		local zombieRoot = zombieModel:FindFirstChild("HumanoidRootPart") or zombieModel:FindFirstChild("Torso")
		if zombieRoot then
			zombieModel.PrimaryPart = zombieRoot
			local pos  = rootPart.Position
			local look = rootPart.CFrame.LookVector
			zombieModel:PivotTo(CFrame.new(pos, pos + Vector3.new(look.X, 0, look.Z)))
		end
		zombieModel.Parent = Workspace
	end

	hum.Died:Connect(function()
		local rootPart = unit:FindFirstChild("HumanoidRootPart")
		if rootPart then rootPart.Anchored = true end
		local isRiotGuardUnit = unit:GetAttribute("UnitId") == "riotGuard"
		if isRiotGuardUnit then
			local baton = unit:FindFirstChild("Police Baton")
			if baton then
				local handle = baton:FindFirstChild("Handle")
				if handle then
					for _, w in handle:GetChildren() do
						if w:IsA("Weld") or w:IsA("WeldConstraint") then w:Destroy() end
					end
				end
				baton.Parent = Workspace
				local vel    = Vector3.new(math.random(-5,5), math.random(6,10), math.random(-5,5))
				local angVel = Vector3.new(math.random(-8,8), math.random(-8,8), math.random(-8,8))
				for _, part in baton:GetDescendants() do
					if part:IsA("BasePart") then
						part.Anchored   = false
						part.CanCollide = true
						part.AssemblyLinearVelocity  = vel
						part.AssemblyAngularVelocity = angVel
					end
				end
				Debris:AddItem(baton, 20)
			end
		else
			dropWeapon()
			dropHat()
		end
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		for _, track in animator:GetPlayingAnimationTracks() do track:Stop(0) end
		local deathAnim = Instance.new("Animation")
		deathAnim.AnimationId = HUMAN_DEATH_ANIMS[math.random(#HUMAN_DEATH_ANIMS)]
		local deathTrack = animator:LoadAnimation(deathAnim)
		deathTrack.Looped   = false
		deathTrack.Priority = Enum.AnimationPriority.Action4
		deathTrack:Play(0)
		local t0 = tick()
		while deathTrack.Length == 0 and tick() - t0 < 2 do task.wait() end
		local animLen = deathTrack.Length
		if animLen > 0 then
			task.wait(math.max(0, animLen - 0.07))
			deathTrack:AdjustSpeed(0)
			task.wait()
		else
			task.wait(4)
			deathTrack:AdjustSpeed(0)
			task.wait()
		end
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.Anchored = true end
		end
		for _, desc in unit:GetDescendants() do
			if desc:IsA("Motor6D") then desc.Enabled = false end
		end
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.CanCollide = false end
		end
		task.wait(LINGER_TIME)
		riseAsZombie()
		unit:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- ANIMATION CONTROLLER
--------------------------------------------------------------------------------
local function startAnimations(unit, unitDef)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	for _, s in unit:GetDescendants() do
		if s.Name == "Animate" and (s:IsA("LocalScript") or s:IsA("Script")) then
			s.Disabled = true
		end
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	local walkId = unitDef.walkAnim or (unitDef.walkAttr and unit:GetAttribute(unitDef.walkAttr))
	local idleId = unitDef.idleAnim or (unitDef.idleAttr and unit:GetAttribute(unitDef.idleAttr))
	if not walkId or not idleId then
		warn("BotPlayerAI: missing anim IDs for", unitDef.id, "walk=", walkId, "idle=", idleId)
		return
	end
	local function makeTrack(id, looped, priority)
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local track = animator:LoadAnimation(anim)
		track.Looped = looped
		if priority then track.Priority = priority end
		return track
	end
	local walkTrack = makeTrack(walkId, true, Enum.AnimationPriority.Movement)
	local idleTrack = makeTrack(idleId, true, Enum.AnimationPriority.Idle)
	idleTrack:Play(0.1)
	local root = unit:FindFirstChild("HumanoidRootPart")
	task.spawn(function()
		local walking = false
		while unit.Parent and hum.Health > 0 do
			task.wait(0.2)
			local vel   = root and root.AssemblyLinearVelocity or Vector3.zero
			local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			if speed > 0.5 and not walking then
				walking = true
				idleTrack:Stop(0.2)
				walkTrack:Play(0.2)
			elseif speed <= 0.5 and walking then
				walking = false
				walkTrack:Stop(0.2)
				idleTrack:Play(0.2)
			end
		end
		walkTrack:Stop(0)
		idleTrack:Stop(0)
	end)
end

--------------------------------------------------------------------------------
-- SPAWN
--------------------------------------------------------------------------------
local function spawnBotUnit(unitDef, isReinforcement)
	local npcTemplate = ReplicatedStorage:FindFirstChild(unitDef.template)
	local zombieTmpl  = ReplicatedStorage:FindFirstChild("ZombieTemplate")
	if not zombieTmpl then
		local zf = ReplicatedStorage:FindFirstChild("Zombies")
		local nf = zf and zf:FindFirstChild("NormalZombies")
		zombieTmpl = nf and nf:FindFirstChild("Zombie1")
	end
	if not npcTemplate or not zombieTmpl then
		warn("BotPlayerAI: missing template for", unitDef.template)
		return
	end

	local unit = npcTemplate:Clone()
	unit.Name = "Zombie"
	unit:SetAttribute("BotUnit",           true)
	unit:SetAttribute("UnitId",            unitDef.id)
	unit:SetAttribute("ZombieType",        "BotUnit")
	unit:SetAttribute("AttackDamage",      unitDef.damage)

	-- Stamp reload anim and burst/reload config for ranged units
	if unitDef.reloadAttr then
		local reloadId = unit:GetAttribute(unitDef.reloadAttr) or ""
		if reloadId ~= "" then unit:SetAttribute("BotReloadAnimId", reloadId) end
	end
	if unitDef.shotsPerBurst    then unit:SetAttribute("BotShotsPerBurst",     unitDef.shotsPerBurst)    end
	if unitDef.shotsBeforeReload then unit:SetAttribute("BotShotsBeforeReload", unitDef.shotsBeforeReload) end
	if unitDef.pelletCount      then unit:SetAttribute("BotPelletCount",       unitDef.pelletCount)      end
	unit:SetAttribute("BotAttackCooldown", unitDef.cooldown)

	-- Resolve and stamp per-unit attack animation
	local attackAnimId = resolveAttackAnim(unitDef, unit)
	if attackAnimId ~= "" then
		unit:SetAttribute("BotAttackAnimId", attackAnimId)
	end
	-- Stamp multi-attack data for redneck (3 attacks with varying damage)
	if unitDef.id == "redneck" then
		unit:SetAttribute("BotAttackCount",   3)
		unit:SetAttribute("BotAttack1AnimId", "rbxassetid://127576285148293")
		unit:SetAttribute("BotAttack1Damage", 40)
		unit:SetAttribute("BotAttack2AnimId", "rbxassetid://79902482773923")
		unit:SetAttribute("BotAttack2Damage", 25)
		unit:SetAttribute("BotAttack3AnimId", "rbxassetid://136273491855743")
		unit:SetAttribute("BotAttack3Damage", 15)
	end

	for _, s in unit:GetDescendants() do
		if s:IsA("Script") then s.Disabled = true end
	end
	if unitDef.id == "riotGuard" then
		-- Enable built-in RiotGuardAI for full 2-phase shield behavior
		local rgAI = unit:FindFirstChild("RiotGuardAI")
		if rgAI then rgAI.Disabled = false end
	else
		-- ZombieMover: melee/tank units need it for pathfinding; ranged units use BotRangedAttack's own pathfinding
		if unitDef.role ~= "ranged" then
			local mover = zombieTmpl:FindFirstChild("ZombieMover")
			if mover then mover:Clone().Parent = unit end
			local busAtk = zombieTmpl:FindFirstChild("ZombieAttackBus")
			if busAtk then
				local clonedBus = busAtk:Clone()
				clonedBus.Disabled = false
				clonedBus.Parent = unit
			end
		end
		local attackScriptName = unitDef.role == "ranged" and "BotRangedAttack" or "ZombieAttackShovelUnit"
		local attackScript = zombieTmpl:FindFirstChild(attackScriptName)
		if attackScript then
			local cloned = attackScript:Clone()
			cloned.Disabled = false
			cloned.Parent = unit
		end
	end

	local hum = unit:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.MaxHealth          = unitDef.health
		hum.Health             = unitDef.health
		hum.WalkSpeed          = unitDef.speed
		hum.BreakJointsOnDeath = false
	end
	for _, desc in unit:GetDescendants() do
		if desc:IsA("BasePart") then desc.Anchored = false end
	end

	-- Apply unit skin color if defined
	if unitDef.skinColor then
		local bc = unit:FindFirstChildOfClass("BodyColors")
		if bc then
			bc.HeadColor3     = unitDef.skinColor
			bc.TorsoColor3    = unitDef.skinColor
			bc.LeftArmColor3  = unitDef.skinColor
			bc.RightArmColor3 = unitDef.skinColor
			bc.LeftLegColor3  = unitDef.skinColor
			bc.RightLegColor3 = unitDef.skinColor
		end
		for _, pName in {"Head","Left Arm","Right Arm","Left Leg","Right Leg"} do
			local part = unit:FindFirstChild(pName)
			if part and part:IsA("BasePart") then part.Color = unitDef.skinColor end
		end
	end

	local spawnPart = Workspace:FindFirstChild("EnemyUnitSpawn", true)
	if not spawnPart then return end
	local sz  = spawnPart.Size
	local cf  = spawnPart.CFrame
	local pos = cf:PointToWorldSpace(Vector3.new(
		(math.random() - 0.5) * sz.X,
		sz.Y / 2 + 2,
		(math.random() - 0.5) * sz.Z
	))
	local root = unit:FindFirstChild("HumanoidRootPart") or unit:FindFirstChild("Torso")
	if root then
		unit.PrimaryPart = root
		unit:PivotTo(CFrame.new(pos, pos + cf.LookVector))
	end

	unit.Parent = Workspace
	if not isReinforcement then botMoney -= unitDef.cost end

	setupBotDeath(unit)
	if unitDef.id ~= "riotGuard" then startAnimations(unit, unitDef) end

	-- 50% free reinforcement when a policeman, riotGuard, or shotgunner bot unit dies (no chaining)
	if not isReinforcement and (unitDef.id == "policeman" or unitDef.id == "riotGuard" or unitDef.id == "shotgunner") then
		local hum2 = unit:FindFirstChildOfClass("Humanoid")
		if hum2 then
			hum2.Died:Connect(function()
				if math.random() > 0.5 then return end
				task.wait(2)
				if countBotUnits() >= countPlayerUnits() then return end
				local choices = {}
				for _, u in UNITS do
					if u.id == "policeman" or u.id == "riotGuard" or u.id == "shotgunner" then
						table.insert(choices, u)
					end
				end
				if #choices > 0 then
					spawnBotUnit(choices[math.random(#choices)], true)
				end
			end)
		end
	end

	task.spawn(function()
		while unit.Parent do
			task.wait(2)
			local r = unit:FindFirstChild("HumanoidRootPart")
			if r and r.Position.Y < FALL_KILL_Y then unit:Destroy(); break end
		end
	end)
end

--------------------------------------------------------------------------------
-- UNIT PICKER
--------------------------------------------------------------------------------
local function pickUnit()
	local typeCounts  = countBotUnitsByType()
	local playerCount = countPlayerUnits()

	local tanksAlive  = (typeCounts["builder"] or 0) + (typeCounts["riotGuard"] or 0)
	local rangedAlive = (typeCounts["farmer"]  or 0) + (typeCounts["policeman"] or 0) + (typeCounts["shotgunner"] or 0)
	local meleeAlive  = typeCounts["redneck"] or 0
	local totalAlive  = tanksAlive + rangedAlive + meleeAlive
	local botDominant = totalAlive >= 3 and totalAlive >= playerCount

	local pool = {}

	for _, u in UNITS do
		if botMoney >= u.cost then
			local w = 10
			if preference == "cheap" then
				w = math.max(1, 36 - u.cost * 2)
			elseif preference == "tank" then
				w = u.health >= 200 and 30 or (u.health >= 100 and 14 or 5)
			elseif preference == "fast" then
				w = u.speed >= 8 and 30 or (u.speed >= 5 and 14 or 5)
			else
				w = 10 + math.random(0, 8)
			end

			if u.role == "tank" then
				if tanksAlive == 0 then
					w += 35
				elseif rangedAlive > tanksAlive then
					w += 20
				end
			elseif u.role == "ranged" then
				if tanksAlive == 0 then
					w = math.max(1, w - 15)
				elseif tanksAlive >= rangedAlive then
					w += 22
				end
			elseif u.role == "melee" then
				if totalAlive == 0 then
					w += 8
				elseif meleeAlive >= 2 then
					w = math.max(1, w - 25)
				elseif meleeAlive >= 1 then
					w = math.max(1, w - 12)
				end
			end

			-- Variety cap: penalise duplicates starting at 2nd copy
			local myCount = typeCounts[u.id] or 0
			if myCount >= 2 then
				w = math.max(1, w - (myCount - 1) * 18)
			end

			if playerCount >= 5 then w += u.health // 25 end
			if u.id == "riotGuard" then
				if botDominant then
					w += 50
				elseif botMoney >= 60 then
					w += 20
				else
					w += 8
				end
			end

			-- Counter bullet-only players: heavily favour armoured units
			if (u.id == "builder" or u.id == "riotGuard") and playerOnlyHasBulletUnits() then
				w += 50
			end

			table.insert(pool, { unit = u, weight = w })
		end
	end

	if #pool == 0 then return nil end

	-- Save up for riot guard when bot is dominant and close to cost
	if botDominant and totalAlive >= 2 and botMoney >= 28 and botMoney < 40 then
		return nil
	end

	-- If redneck is the only affordable option but we already have 2+, save up
	if #pool == 1 and pool[1].unit.id == "redneck" and (typeCounts["redneck"] or 0) >= 2 then
		return nil
	end

	local total, cum = 0, 0
	for _, e in pool do total += e.weight end
	local roll = math.random() * total
	for _, e in pool do
		cum += e.weight
		if roll <= cum then return e.unit end
	end
	return pool[#pool].unit
end

--------------------------------------------------------------------------------
-- MONEY TICK
--------------------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(1)
		botMoney = math.min(MAX_MONEY, botMoney + 1)
	end
end)

--------------------------------------------------------------------------------
-- STRATEGY SHIFT
--------------------------------------------------------------------------------
task.spawn(function()
	local prefs = { "cheap","cheap","tank","fast","mixed","mixed","mixed" }
	while true do
		task.wait(math.random(20, 50))
		preference = prefs[math.random(#prefs)]
		aggression = math.random(35, 92) / 100
		burstSize  = math.random(2, 4)
		if not rushMode and math.random() < 0.40 then
			rushMode = true
			rushGoal = math.random(45, 130)
		end
	end
end)

--------------------------------------------------------------------------------
-- MAIN DECISION LOOP
--------------------------------------------------------------------------------
local playerDeployed = false

while true do
	task.wait(math.random(6, 22) / 10)
	-- Hold off until the player deploys their first unit so the bot can save up
	if not playerDeployed then
		if countPlayerUnits() == 0 then continue end
		playerDeployed = true
	end
	if countBotUnits() >= countPlayerUnits() then continue end

	if rushMode and botMoney >= rushGoal then
		rushMode = false
		for _ = 1, burstSize do
			local u = pickUnit()
			if u and botMoney >= u.cost then
				spawnBotUnit(u)
				task.wait(math.random(2, 7) / 10)
			end
		end
		continue
	end

	-- Normal spawn
	local urgency = countPlayerUnits() >= 6 and 0.20 or 0
	if math.random() < (aggression + urgency) and botMoney >= 10 then
		local u = pickUnit()
		if u then spawnBotUnit(u) end
	end
end
