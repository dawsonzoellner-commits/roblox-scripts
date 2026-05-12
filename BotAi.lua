-- Discord: dcz1012 Roblox: dcz1012

-- bot player ai, handles everything for the enemy side in bot mode
-- earns money over time, picks units, spawns them, handles death stuff
-- dead units come back as zombies that attack the player

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local Debris              = game:GetService("Debris")

-- only runs in bot player mode, waits for the game to signal before doing anything
ServerScriptService:WaitForChild("BotPlayerStart", math.huge).Event:Wait()

-- all the units the bot can buy and deploy
-- each one has its stats, what template to clone, and how to find its animations
-- some use hardcoded anim ids, others read them from attributes on the template
local UNITS = {
	{
		-- redneck is cheap and fast, good for early game pressure
		id = "redneck", template = "Redneck", cost = 10,
		speed = 10, health = 200, damage = 25, cooldown = 0.7,
		role = "melee",
		walkAnim = "rbxassetid://113807386984718",
		idleAnim = "rbxassetid://129843177790707",
		-- attack anim gets picked randomly in resolveAttackAnim
	},
	{
		-- farmer hits hard but dies easy and moves slow, needs to reload after 2 shots
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
		-- builder is a tanky melee unit, good for soaking damage up front
		id = "builder", template = "BuilderUnit", cost = 20,
		speed = 6, health = 280, damage = 25, cooldown = 0.6,
		role = "tank",
		walkAnim   = "rbxassetid://119098340440076",
		idleAnim   = "rbxassetid://74182242424283",
		attackAnim = "rbxassetid://80080192712226",
	},
	{
		-- policeman fires in bursts of 3 and reloads after 4 shots
		-- skin color is set on spawn so it looks different from the player's police
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
		-- riot guard is the most expensive unit, super tanky with a shield phase
		-- has its own ai script so we dont touch it much here
		id = "riotGuard", template = "Riot Guard", cost = 40,
		speed = 3, health = 500, damage = 25, cooldown = 1.0,
		role = "tank",
		walkAttr = "RiotWalkAnim",
		idleAttr = "RiotIdleAnim",
		-- picks between RiotAttack1Anim and RiotAttack2Anim randomly
	},
	{
		-- shotgunner has a lot of shots before reloading, good sustained ranged damage
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

local MAX_MONEY   = 200  -- bot money cap
local MAX_UNITS   = 14   -- max units alive at once
local FALL_KILL_Y = -50  -- if a unit falls below this y pos just kill it
local LINGER_TIME = 30   -- seconds before a dead unit rises as a zombie

local botMoney = 0  -- current bot coin balance, ticks up 1/sec

-- random death anims, one gets picked when any bot unit dies
local HUMAN_DEATH_ANIMS = {
	"rbxassetid://112646178864650",
	"rbxassetid://108008217888533",
	"rbxassetid://73764140122967",
}
do
	-- grab policemans custom death anim from its template if it has one
	local policemanTmpl = ReplicatedStorage:FindFirstChild("Policeman")
	local policeDeathId = policemanTmpl and policemanTmpl:GetAttribute("PolicemanDeathAnim") or ""
	if policeDeathId ~= "" then table.insert(HUMAN_DEATH_ANIMS, policeDeathId) end
end

-- strategy variables, these shift over time to make the bot feel less predictable
local preference = "mixed"  -- what unit type the bot is currently trying to buy
local aggression = 0.55     -- chance per tick that the bot tries to spawn something
local rushMode   = false    -- when true the bot saves up then dumps units all at once
local rushGoal   = 0        -- how much money to save before doing the rush
local burstSize  = 2        -- how many units to spawn during a rush

-- counts how many bot units are alive right now
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

-- returns a table of how many of each unit type the bot has alive
-- used in pickUnit to avoid spamming the same unit
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

-- counts how many units the player has alive
local function countPlayerUnits()
	local n = 0
	local names = { CustomNPC=true, FarmerNPC=true, BuilderNPC=true,
	                PolicemanNPC=true, ["Riot Guard"]=true, ShotgunnerNPC=true, SWATNPC=true }
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") and names[obj.Name] then n += 1 end
	end
	return n
end

-- returns true if the player only has ranged units and no melee or tanks
-- if thats the case we want to spam armored units since they tank bullets well
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

-- figures out which attack anim to use for a unit
-- redneck and riot guard pick randomly, others just have one set anim
local REDNECK_ATTACKS = {
	"rbxassetid://127576285148293",
	"rbxassetid://79902482773923",
	"rbxassetid://136273491855743",
}

local function resolveAttackAnim(unitDef, unit)
	if unitDef.id == "redneck" then
		return REDNECK_ATTACKS[math.random(#REDNECK_ATTACKS)]
	elseif unitDef.id == "riotGuard" then
		-- riot guard has two possible attack anims stored as attributes
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

-- handles everything that happens when a bot unit dies
-- drops its weapon and hat, plays death anim, freezes the corpse, then spawns a zombie
local function setupBotDeath(unit)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- save the riot guards helmet before anything else
	-- dropHat destroys it so we need to grab it now so the zombie can wear it later
	local savedHelmet
	if unit:GetAttribute("UnitId") == "riotGuard" then
		for _, child in unit:GetChildren() do
			if child:IsA("Accessory") then
				savedHelmet = child:Clone()
				break
			end
		end
	end

	-- detaches and drops the weapon with some random velocity so it looks like it got thrown
	-- weapon is any accessory whose handle doesnt have a HatAttachment
	local function dropWeapon()
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

	-- same thing but for hats, tosses it with spin so it looks good
	-- hat is any accessory whose handle HAS a HatAttachment
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
		-- remove all the welds holding it to the head
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

	-- spawns a zombie where the unit died
	-- copies the clothing over and flags it so the zombie ai attacks the player side
	local function riseAsZombie()
		local isRiotGuard = unit:GetAttribute("UnitId") == "riotGuard"
		-- supports both flat and nested folder layouts in replicated storage
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

		-- disable the default animate script, we handle anims ourselves
		local animScript = zombieModel:FindFirstChild("Animate")
		if animScript then animScript.Disabled = true end

		-- mark as a bot spawned zombie so existing systems treat it correctly
		zombieModel:SetAttribute("FarmerSpawned", true)
		zombieModel:SetAttribute("ZombieType",    isRiotGuard and "RiotGuard" or "Normal")
		zombieModel:SetAttribute("AttackDamage",  10)

		local zombieHum = zombieModel:FindFirstChildOfClass("Humanoid")
		if zombieHum then
			-- riot guard zombies get more hp since they were a heavy unit
			local hp = isRiotGuard and 250 or 100
			zombieHum.MaxHealth = hp
			zombieHum.Health    = hp
			zombieHum.WalkSpeed = 5
		end

		-- spread the head color to the whole body to give it the zombie look
		local tgtColors = zombieModel:FindFirstChildOfClass("BodyColors")
		if tgtColors then
			local g = tgtColors.HeadColor3
			tgtColors.TorsoColor3    = g
			tgtColors.LeftArmColor3  = g
			tgtColors.RightArmColor3 = g
			tgtColors.LeftLegColor3  = g
			tgtColors.RightLegColor3 = g
		end

		-- strip the template clothes and accessories then copy the original units outfit
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

		-- reattach the saved helmet for riot guards
		if isRiotGuard and savedHelmet then
			savedHelmet:Clone().Parent = zombieModel
		end

		-- place the zombie where the unit died, facing the same direction
		local zombieRoot = zombieModel:FindFirstChild("HumanoidRootPart") or zombieModel:FindFirstChild("Torso")
		if zombieRoot then
			zombieModel.PrimaryPart = zombieRoot
			local pos  = rootPart.Position
			local look = rootPart.CFrame.LookVector
			-- flatten y so it spawns standing upright
			zombieModel:PivotTo(CFrame.new(pos, pos + Vector3.new(look.X, 0, look.Z)))
		end
		zombieModel.Parent = Workspace
	end

	hum.Died:Connect(function()
		-- anchor root immediately so the corpse doesnt slide around
		local rootPart = unit:FindFirstChild("HumanoidRootPart")
		if rootPart then rootPart.Anchored = true end

		local isRiotGuardUnit = unit:GetAttribute("UnitId") == "riotGuard"
		if isRiotGuardUnit then
			-- riot guard drops its baton differently since its a full model not just a handle
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

		-- stop whatever was playing and play a random death anim
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

		-- length starts at 0 until the asset loads, wait up to 2 seconds
		local t0 = tick()
		while deathTrack.Length == 0 and tick() - t0 < 2 do task.wait() end

		local animLen = deathTrack.Length
		if animLen > 0 then
			-- wait til near the end then freeze on the last frame
			task.wait(math.max(0, animLen - 0.07))
			deathTrack:AdjustSpeed(0)
			task.wait()
		else
			-- anim never loaded so just wait 4 seconds as a fallback
			task.wait(4)
			deathTrack:AdjustSpeed(0)
			task.wait()
		end

		-- anchor the whole corpse so it stays put
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.Anchored = true end
		end
		-- disable joints so the pose holds instead of collapsing
		for _, desc in unit:GetDescendants() do
			if desc:IsA("Motor6D") then desc.Enabled = false end
		end
		-- no collision so living units can walk through the corpse
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.CanCollide = false end
		end

		task.wait(LINGER_TIME)
		riseAsZombie()
		unit:Destroy()
	end)
end

-- handles walk and idle animation blending for bot units
-- the default animate script is disabled on all bots so we do it here manually
-- checks speed every 0.2 seconds and swaps between walk and idle accordingly
local function startAnimations(unit, unitDef)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- kill any existing animate scripts to avoid conflicts
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

	-- try the hardcoded id first, fall back to reading from template attributes
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

	-- loop that blends between walk and idle based on horizontal speed
	-- ignores y velocity so jumping doesnt trigger the walk anim
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

-- clones a unit, sets up all its attributes and scripts, places it at the spawn, registers death
-- isReinforcement means its a free respawn so we dont charge money for it
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
	unit.Name = "Zombie" -- named zombie so the rest of the game systems pick it up correctly

	-- stamp who this unit is so other scripts know what they're dealing with
	unit:SetAttribute("BotUnit",           true)
	unit:SetAttribute("UnitId",            unitDef.id)
	unit:SetAttribute("ZombieType",        "BotUnit")
	unit:SetAttribute("AttackDamage",      unitDef.damage)

	-- stamp reload and combat config for ranged units
	-- the attack scripts read these at runtime so we can reuse the same script for all ranged types
	if unitDef.reloadAttr then
		local reloadId = unit:GetAttribute(unitDef.reloadAttr) or ""
		if reloadId ~= "" then unit:SetAttribute("BotReloadAnimId", reloadId) end
	end
	if unitDef.shotsPerBurst    then unit:SetAttribute("BotShotsPerBurst",     unitDef.shotsPerBurst)    end
	if unitDef.shotsBeforeReload then unit:SetAttribute("BotShotsBeforeReload", unitDef.shotsBeforeReload) end
	if unitDef.pelletCount      then unit:SetAttribute("BotPelletCount",       unitDef.pelletCount)      end
	unit:SetAttribute("BotAttackCooldown", unitDef.cooldown)

	-- stamp the attack anim so the attack script doesnt have to figure it out itself
	local attackAnimId = resolveAttackAnim(unitDef, unit)
	if attackAnimId ~= "" then
		unit:SetAttribute("BotAttackAnimId", attackAnimId)
	end

	-- redneck has 3 different attacks with different damage per swing
	-- stamp each one so the attack script can cycle through them
	if unitDef.id == "redneck" then
		unit:SetAttribute("BotAttackCount",   3)
		unit:SetAttribute("BotAttack1AnimId", "rbxassetid://127576285148293")
		unit:SetAttribute("BotAttack1Damage", 40)
		unit:SetAttribute("BotAttack2AnimId", "rbxassetid://79902482773923")
		unit:SetAttribute("BotAttack2Damage", 25)
		unit:SetAttribute("BotAttack3AnimId", "rbxassetid://136273491855743")
		unit:SetAttribute("BotAttack3Damage", 15)
	end

	-- disable everything first, then only re-enable what this unit actually needs
	for _, s in unit:GetDescendants() do
		if s:IsA("Script") then s.Disabled = true end
	end

	if unitDef.id == "riotGuard" then
		-- riot guard has its own ai that handles the shield phase, just turn it on
		local rgAI = unit:FindFirstChild("RiotGuardAI")
		if rgAI then rgAI.Disabled = false end
	else
		-- melee and tank units need ZombieMover for pathfinding and ZombieAttackBus for bus damage
		-- ranged units have their own pathfinding built into BotRangedAttack
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
		-- ranged units use BotRangedAttack, melee and tanks use ZombieAttackShovelUnit
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
		hum.BreakJointsOnDeath = false -- we handle joints in the death handler ourselves
	end

	-- templates are usually stored anchored so unanchor everything
	for _, desc in unit:GetDescendants() do
		if desc:IsA("BasePart") then desc.Anchored = false end
	end

	-- apply a skin color if the unit has one defined
	-- used for policeman so it looks different from the player version
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

	-- find the spawn pad and place the unit somewhere random on it so they dont all stack
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

	-- when certain units die theres a 50% chance a free one respawns
	-- only works on policeman, riot guard, and shotgunner, and cant chain
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

	-- if a unit somehow falls off the map just destroy it
	task.spawn(function()
		while unit.Parent do
			task.wait(2)
			local r = unit:FindFirstChild("HumanoidRootPart")
			if r and r.Position.Y < FALL_KILL_Y then unit:Destroy(); break end
		end
	end)
end

-- picks which unit to buy next based on current strategy, army composition, and what we can afford
-- returns nil if nothing should be bought right now
local function pickUnit()
	local typeCounts  = countBotUnitsByType()
	local playerCount = countPlayerUnits()

	local tanksAlive  = (typeCounts["builder"] or 0) + (typeCounts["riotGuard"] or 0)
	local rangedAlive = (typeCounts["farmer"]  or 0) + (typeCounts["policeman"] or 0) + (typeCounts["shotgunner"] or 0)
	local meleeAlive  = typeCounts["redneck"] or 0
	local totalAlive  = tanksAlive + rangedAlive + meleeAlive

	-- bot is dominant if it has 3+ units and matches or beats the player count
	-- being dominant unlocks riot guard bias
	local botDominant = totalAlive >= 3 and totalAlive >= playerCount

	local pool = {}

	for _, u in UNITS do
		if botMoney >= u.cost then
			local w = 10 -- base weight

			-- shift weight based on current preference
			if preference == "cheap" then
				w = math.max(1, 36 - u.cost * 2)
			elseif preference == "tank" then
				w = u.health >= 200 and 30 or (u.health >= 100 and 14 or 5)
			elseif preference == "fast" then
				w = u.speed >= 8 and 30 or (u.speed >= 5 and 14 or 5)
			else
				w = 10 + math.random(0, 8) -- mixed gets some randomness
			end

			-- push toward tanks if we have none, push toward ranged if we already have tanks
			-- penalize ranged if theres nothing up front to protect them
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
					w = math.max(1, w - 25) -- dont stack too many melee
				elseif meleeAlive >= 1 then
					w = math.max(1, w - 12)
				end
			end

			-- penalize duplicates so we dont just buy the same unit over and over
			local myCount = typeCounts[u.id] or 0
			if myCount >= 2 then
				w = math.max(1, w - (myCount - 1) * 18)
			end

			-- if player has a big army start favoring tankier units
			if playerCount >= 5 then w += u.health // 25 end

			-- riot guard gets extra weight when the bot is winning or has a lot of money
			if u.id == "riotGuard" then
				if botDominant then
					w += 50
				elseif botMoney >= 60 then
					w += 20
				else
					w += 8
				end
			end

			-- if player only has ranged units favor armored ones since they tank bullets
			if (u.id == "builder" or u.id == "riotGuard") and playerOnlyHasBulletUnits() then
				w += 50
			end

			table.insert(pool, { unit = u, weight = w })
		end
	end

	if #pool == 0 then return nil end

	-- save up for riot guard if we're close to affording it and already winning
	if botDominant and totalAlive >= 2 and botMoney >= 28 and botMoney < 40 then
		return nil
	end

	-- if redneck is the only thing we can afford but we already have 2, just wait
	if #pool == 1 and pool[1].unit.id == "redneck" and (typeCounts["redneck"] or 0) >= 2 then
		return nil
	end

	-- weighted random pick
	local total, cum = 0, 0
	for _, e in pool do total += e.weight end
	local roll = math.random() * total
	for _, e in pool do
		cum += e.weight
		if roll <= cum then return e.unit end
	end
	return pool[#pool].unit
end

-- gives the bot 1 coin per second up to the cap
task.spawn(function()
	while true do
		task.wait(1)
		botMoney = math.min(MAX_MONEY, botMoney + 1)
	end
end)

-- randomly shifts the bots strategy every 20 to 50 seconds
-- changes what unit type it prefers, how aggressive it is, and whether its in rush mode
task.spawn(function()
	local prefs = { "cheap","cheap","tank","fast","mixed","mixed","mixed" }
	while true do
		task.wait(math.random(20, 50))
		preference = prefs[math.random(#prefs)]
		aggression = math.random(35, 92) / 100
		burstSize  = math.random(2, 4)
		-- 40% chance to go into rush mode where it saves up then dumps units
		if not rushMode and math.random() < 0.40 then
			rushMode = true
			rushGoal = math.random(45, 130)
		end
	end
end)

-- main loop, runs every 0.6 to 2.2 seconds and decides if the bot should spawn something
local playerDeployed = false

while true do
	task.wait(math.random(6, 22) / 10)

	-- wait until the player deploys their first unit so the bot has time to save up
	if not playerDeployed then
		if countPlayerUnits() == 0 then continue end
		playerDeployed = true
	end

	-- dont spawn if the bot already has as many units as the player
	if countBotUnits() >= countPlayerUnits() then continue end

	-- if in rush mode and we hit the goal, dump the burst
	if rushMode and botMoney >= rushGoal then
		rushMode = false
		for _ = 1, burstSize do
			local u = pickUnit()
			if u and botMoney >= u.cost then
				spawnBotUnit(u)
				task.wait(math.random(2, 7) / 10) -- slight stagger so they dont all spawn at the same time
			end
		end
		continue
	end

	-- normal spawn, roll against aggression value
	-- urgency bumps up the chance if the player has 6 or more units
	local urgency = countPlayerUnits() >= 6 and 0.20 or 0
	if math.random() < (aggression + urgency) and botMoney >= 10 then
		local u = pickUnit()
		if u then spawnBotUnit(u) end
	end
end
