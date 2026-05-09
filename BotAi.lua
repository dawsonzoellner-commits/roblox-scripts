-- Discord: dcz1012 | Roblox: dcz1012
 
-- BotPlayerAI.lua
-- Handles all logic for the AI-controlled opponent in Bot Player mode.
-- The bot earns money over time, picks units based on a shifting strategy,
-- spawns them into the world, manages their animations and death behavior,
-- and makes dead units rise as zombies to attack the player's side.
 
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")
local Debris              = game:GetService("Debris")
 
-- This script is only relevant in Bot Player mode.
-- We wait for a BindableEvent signal from the game manager before doing anything,
-- so that this script stays dormant during Zombie mode.
ServerScriptService:WaitForChild("BotPlayerStart", math.huge).Event:Wait()
 
-- UNIT DEFINITIONS
-- Each entry describes a deployable unit the bot can spawn.
-- Fields:
-- id            = unique string key used for tracking and attributes
-- template      = name of the NPC model in ReplicatedStorage to clone
-- cost          = how much bot money is spent to deploy this unit
-- speed         = WalkSpeed assigned to the Humanoid
-- health        = MaxHealth assigned to the Humanoid
-- damage        = base attack damage stamped as an attribute on the unit
-- cooldown      = seconds between attacks
-- role          = "melee" | "ranged" | "tank" — drives AI script selection
-- walkAnim/idleAnim   = hardcoded rbxassetid strings for units with fixed anims
-- walkAttr/idleAttr   = attribute names read from the cloned template at runtime
-- (used when anims are registered externally, e.g. RegisterFarmerAnims)
-- attackAnim    = hardcoded attack animation ID
-- attackAttr    = attribute name on the template for the attack animation
-- reloadAttr    = attribute name for reload animation (ranged units only)
-- shotsBeforeReload = how many shots fire before a reload animation plays
-- shotsPerBurst = how many shots fire in one burst (policeman burst-fire behavior)
-- pelletCount   = projectiles per shot (reserved for future shotgun spread logic)
-- skinColor     = Color3 override applied to all body parts on spawn
local UNITS = {
	{
		-- Redneck: fast melee unit, low cost, good for early pressure
		id = "redneck", template = "Redneck", cost = 10,
		speed = 10, health = 200, damage = 25, cooldown = 0.7,
		role = "melee",
		walkAnim = "rbxassetid://113807386984718",
		idleAnim = "rbxassetid://129843177790707",
		-- Attack animations are chosen randomly per-swing; see resolveAttackAnim and REDNECK_ATTACKS
	},
	{
		-- Farmer: cheap ranged unit with high damage but low health and slow speed
		-- Requires reload after 2 shots; animations stored as template attributes
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
		-- Builder: mid-cost melee tank with high health; good frontline unit
		id = "builder", template = "BuilderUnit", cost = 20,
		speed = 6, health = 280, damage = 25, cooldown = 0.6,
		role = "tank",
		walkAnim   = "rbxassetid://119098340440076",
		idleAnim   = "rbxassetid://74182242424283",
		attackAnim = "rbxassetid://80080192712226",
	},
	{
		-- Policeman: fast-firing ranged unit with burst fire behavior (3 shots per burst)
		-- Reloads after 4 shots; skin color applied at spawn to distinguish from player police
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
		-- Riot Guard: expensive heavy tank with very high health and a 2-phase shield mechanic
		-- Uses its own RiotGuardAI script; attack anims are picked randomly from two options
		id = "riotGuard", template = "Riot Guard", cost = 40,
		speed = 3, health = 500, damage = 25, cooldown = 1.0,
		role = "tank",
		walkAttr = "RiotWalkAnim",
		idleAttr = "RiotIdleAnim",
		-- Attack anims resolved at runtime from RiotAttack1Anim / RiotAttack2Anim attributes
	},
	{
		-- Shotgunner: ranged unit with a high shot count before reload (6 shots)
		-- Good sustained damage output at range
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
 
-- Global caps and constants
local MAX_MONEY   = 200   -- Bot money never exceeds this value
local MAX_UNITS   = 14    -- Hard cap on simultaneous bot units (enforced in pickUnit)
local FALL_KILL_Y = -50   -- Y position below which a unit is considered fallen off the map
local LINGER_TIME = 30    -- Seconds a dead unit's corpse stays before rising as a zombie
 
-- Bot's current coin balance; incremented by 1 per second in the money tick loop
local botMoney = 0
 
-- Death animations pool for humanoid bot units
-- A random one is played when any non-zombie bot unit dies
local HUMAN_DEATH_ANIMS = {
	"rbxassetid://112646178864650",
	"rbxassetid://108008217888533",
	"rbxassetid://73764140122967",
}
do
	-- Also include the Policeman's custom death animation if it has one defined as an attribute,
	-- so all policeman deaths use a consistent animation set
	local policemanTmpl = ReplicatedStorage:FindFirstChild("Policeman")
	local policeDeathId = policemanTmpl and policemanTmpl:GetAttribute("PolicemanDeathAnim") or ""
	if policeDeathId ~= "" then table.insert(HUMAN_DEATH_ANIMS, policeDeathId) end
end
 
-- STRATEGY STATE
-- These variables control the bot's decision-making behavior and shift over time.
-- preference = which unit type the bot currently favors when picking
-- aggression = probability (0–1) that the bot attempts to spawn a unit each tick
-- rushMode   = when true, the bot saves up to a threshold then deploys a burst
-- rushGoal   = the money threshold the bot must reach before executing a rush
-- burstSize  = how many units to deploy during a rush
local preference = "mixed"  -- Starting preference; shifts every 20–50 seconds
local aggression = 0.55     -- Starting spawn probability per decision tick
local rushMode   = false    -- Whether the bot is currently saving for a rush
local rushGoal   = 0        -- Money target for the current rush
local burstSize  = 2        -- Units to deploy in one rush burst
 
-- HELPERS
-- Utility functions for counting units in the workspace.
-- These are called frequently in the decision loop and unit picker,
-- so they iterate Workspace children directly for up-to-date results.
 
-- Returns the total number of living bot-controlled units in the workspace.
-- Bot units are identified by the "BotUnit" attribute set during spawnBotUnit.
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
 
-- Returns a table mapping each unit id to how many of that type are currently alive.
-- Used by pickUnit to apply variety caps and role-balance weights.
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
 
-- Returns the total number of living player-deployed units in the workspace.
-- Player unit names are hardcoded here since they follow a consistent naming convention.
local function countPlayerUnits()
	local n = 0
	local names = { CustomNPC=true, FarmerNPC=true, BuilderNPC=true,
	                PolicemanNPC=true, ["Riot Guard"]=true, ShotgunnerNPC=true, SWATNPC=true }
	for _, obj in Workspace:GetChildren() do
		if obj:IsA("Model") and names[obj.Name] then n += 1 end
	end
	return n
end
 
-- Returns true if the player currently has only ranged/bullet units alive (no melee or tanks).
-- Used to heavily favor armored bot units (builder, riotGuard) as a counter strategy,
-- since bullet damage is less effective against high-health armored targets in the game's combat model.
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
	-- Only returns true if there are bullet units AND no melee units alive
	return hasBullet and not hasMelee
end
 
-- RESOLVE ATTACK ANIMATION
-- Some units (redneck, riotGuard) have multiple attack animations chosen randomly
-- per attack to add visual variety. This function centralizes that logic so
-- spawnBotUnit and the attack scripts always get a consistent animation ID.
-- Called AFTER cloning the template so attribute values are already set on the model.
local REDNECK_ATTACKS = {
	"rbxassetid://127576285148293",  -- Swing 1
	"rbxassetid://79902482773923",   -- Swing 2
	"rbxassetid://136273491855743",  -- Swing 3
}
 
local function resolveAttackAnim(unitDef, unit)
	if unitDef.id == "redneck" then
		-- Redneck picks a random attack from the pool each time it spawns
		return REDNECK_ATTACKS[math.random(#REDNECK_ATTACKS)]
	elseif unitDef.id == "riotGuard" then
		-- Riot Guard reads two attack animation IDs from its template attributes,
		-- then picks one randomly to stamp on the unit
		local a1 = unit:GetAttribute("RiotAttack1Anim") or ""
		local a2 = unit:GetAttribute("RiotAttack2Anim") or ""
		local choices = {}
		if a1 ~= "" then table.insert(choices, a1) end
		if a2 ~= "" then table.insert(choices, a2) end
		return #choices > 0 and choices[math.random(#choices)] or ""
	elseif unitDef.attackAnim then
		-- Units with a hardcoded animation ID (e.g. builder)
		return unitDef.attackAnim
	elseif unitDef.attackAttr then
		-- Units whose animation is stored as a template attribute (e.g. farmer, policeman)
		return unit:GetAttribute(unitDef.attackAttr) or ""
	end
	return ""
end
 
-- DEATH HANDLER
-- Attached to every bot unit on spawn. Handles three things when a unit dies:
-- 1. Drops weapons and hats as physics objects for visual flair
-- 2. Plays a death animation and freezes the corpse in its final pose
-- 3. After LINGER_TIME seconds, spawns a zombie at the corpse's position
-- that then walks toward and attacks the player's side
local function setupBotDeath(unit)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end
 
	-- Pre-save the riot guard's helmet accessory before death.
	-- dropHat() destroys the Accessory from the unit, so we need to clone it
	-- beforehand so riseAsZombie can re-attach it to the zombie model later.
	local savedHelmet
	if unit:GetAttribute("UnitId") == "riotGuard" then
		for _, child in unit:GetChildren() do
			if child:IsA("Accessory") then
				savedHelmet = child:Clone()
				break
			end
		end
	end
 
	-- Detaches the unit's weapon from its body and tosses it into the world
	-- with a small random velocity so it looks like it was dropped on death.
	-- We identify the weapon as any Accessory whose Handle does NOT have a HatAttachment.
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
		-- Remove the weld that keeps the weapon attached to the character
		local weld = handle:FindFirstChild("AccessoryWeld")
		if weld then weld:Destroy() end
		-- Reparent to workspace and enable physics so it falls naturally
		handle.Parent     = Workspace
		handle.Anchored   = false
		handle.CanCollide = true
		handle.AssemblyLinearVelocity = Vector3.new(math.random(-4,4), 5, math.random(-4,4))
		Debris:AddItem(handle, 20) -- Auto-clean after 20 seconds
	end
 
	-- Detaches the unit's hat and tosses it with randomized spin.
	-- Hat is identified as an Accessory whose Handle HAS a HatAttachment,
	-- distinguishing it from weapon accessories.
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
		-- Remove all welds connecting the hat to the head before reparenting
		for _, obj in handle:GetChildren() do
			if obj:IsA("Weld") or obj:IsA("WeldConstraint") or obj:IsA("Motor6D") then
				obj:Destroy()
			end
		end
		-- Also clean up any weld on the Head part itself that references the hat handle
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
		-- Apply upward velocity and random spin so the hat tumbles realistically
		handle.AssemblyLinearVelocity  = Vector3.new(math.random(-4,4), 8, math.random(-4,4))
		handle.AssemblyAngularVelocity = Vector3.new(math.random(-6,6), math.random(-6,6), math.random(-6,6))
		Debris:AddItem(handle, 20)
		hat:Destroy()
	end
 
	-- Spawns a zombie at the position where this bot unit died.
	-- The zombie inherits the unit's clothing (shirt/pants) and, for riot guards, the helmet.
	-- It is then flagged as a "FarmerSpawned" zombie so the existing zombie AI
	-- treats it as an enemy of the player's side and pathfinds toward the player bus.
	local function riseAsZombie()
		local isRiotGuard = unit:GetAttribute("UnitId") == "riotGuard"
		-- Try to find a zombie template; support both flat and nested folder structures
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
 
		-- Unanchor all parts so the zombie can move freely
		for _, desc in zombieModel:GetDescendants() do
			if desc:IsA("BasePart") then desc.Anchored = false end
		end
 
		-- Disable the default Animate script since we manage animations separately
		local animScript = zombieModel:FindFirstChild("Animate")
		if animScript then animScript.Disabled = true end
 
		-- Mark this zombie as bot-spawned so the game manager and attack scripts handle it correctly
		zombieModel:SetAttribute("FarmerSpawned", true)
		-- ZombieType affects HP and visual treatment; riot guards get a beefier zombie version
		zombieModel:SetAttribute("ZombieType",    isRiotGuard and "RiotGuard" or "Normal")
		zombieModel:SetAttribute("AttackDamage",  10)
 
		local zombieHum = zombieModel:FindFirstChildOfClass("Humanoid")
		if zombieHum then
			-- Riot guard zombies are tougher to reflect the heavy unit they came from
			local hp = isRiotGuard and 250 or 100
			zombieHum.MaxHealth = hp
			zombieHum.Health    = hp
			zombieHum.WalkSpeed = 5
		end
 
		-- Apply a uniform zombie skin tone by spreading the head color to all body parts.
		-- This gives the risen zombie its green/undead appearance regardless of
		-- what the original unit's skin color was.
		local tgtColors = zombieModel:FindFirstChildOfClass("BodyColors")
		if tgtColors then
			local g = tgtColors.HeadColor3
			tgtColors.TorsoColor3    = g
			tgtColors.LeftArmColor3  = g
			tgtColors.RightArmColor3 = g
			tgtColors.LeftLegColor3  = g
			tgtColors.RightLegColor3 = g
		end
 
		-- Strip any accessories or clothes already on the zombie template,
		-- then copy the original unit's shirt/pants onto it so the zombie
		-- visually matches what the bot unit was wearing when it died
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
 
		-- Re-attach the riot guard's pre-saved helmet to the zombie model
		if isRiotGuard and savedHelmet then
			savedHelmet:Clone().Parent = zombieModel
		end
 
		-- Position the zombie at the dead unit's location, facing the same direction
		local zombieRoot = zombieModel:FindFirstChild("HumanoidRootPart") or zombieModel:FindFirstChild("Torso")
		if zombieRoot then
			zombieModel.PrimaryPart = zombieRoot
			local pos  = rootPart.Position
			local look = rootPart.CFrame.LookVector
			-- Flatten the look vector to the XZ plane so the zombie spawns upright
			zombieModel:PivotTo(CFrame.new(pos, pos + Vector3.new(look.X, 0, look.Z)))
		end
		zombieModel.Parent = Workspace
	end
 
	-- Wire up the death sequence to fire when this unit's Humanoid health reaches zero
	hum.Died:Connect(function()
		-- Anchor the root part immediately on death to stop the ragdoll from sliding
		local rootPart = unit:FindFirstChild("HumanoidRootPart")
		if rootPart then rootPart.Anchored = true end
 
		local isRiotGuardUnit = unit:GetAttribute("UnitId") == "riotGuard"
		if isRiotGuardUnit then
			-- Riot guards drop their baton as a separate model with physics applied to each part
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
			-- All other units drop their weapon and hat separately
			dropWeapon()
			dropHat()
		end
 
		-- Stop all currently playing animations and play a random death animation
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
 
		-- Wait for the animation to load (Length is 0 until the asset is fetched),
		-- with a 2-second timeout to avoid hanging indefinitely on slow connections
		local t0 = tick()
		while deathTrack.Length == 0 and tick() - t0 < 2 do task.wait() end
 
		local animLen = deathTrack.Length
		if animLen > 0 then
			-- Wait until just before the animation ends, then freeze it on the last frame
			task.wait(math.max(0, animLen - 0.07))
			deathTrack:AdjustSpeed(0)
			task.wait()
		else
			-- Fallback if animation length never loaded; wait a fixed 4 seconds
			task.wait(4)
			deathTrack:AdjustSpeed(0)
			task.wait()
		end
 
		-- Freeze the entire corpse in place so it doesn't fall through the floor or shift
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.Anchored = true end
		end
		-- Disable all Motor6D joints so the corpse stays in its death pose rather than collapsing
		for _, desc in unit:GetDescendants() do
			if desc:IsA("Motor6D") then desc.Enabled = false end
		end
		-- Disable collision on the corpse so living units can walk through it
		for _, desc in unit:GetDescendants() do
			if desc:IsA("BasePart") then desc.CanCollide = false end
		end
 
		-- Wait the configured linger time, then rise as a zombie and destroy the original model
		task.wait(LINGER_TIME)
		riseAsZombie()
		unit:Destroy()
	end)
end
 
-- ANIMATION CONTROLLER
-- Manages walk/idle animation blending for bot units during gameplay.
-- The default Roblox "Animate" script is disabled on all bot units because
-- it conflicts with server-side animation control, so we handle it manually.
-- Every 0.2 seconds, we check the unit's horizontal velocity to decide
-- whether to play the walk or idle animation.
local function startAnimations(unit, unitDef)
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if not hum then return end
 
	-- Disable any existing Animate scripts on the unit to prevent conflicts
	for _, s in unit:GetDescendants() do
		if s.Name == "Animate" and (s:IsA("LocalScript") or s:IsA("Script")) then
			s.Disabled = true
		end
	end
 
	-- Ensure an Animator exists; the Humanoid needs one to load and play animations
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
 
	-- Resolve animation IDs: prefer hardcoded values, fall back to template attributes
	local walkId = unitDef.walkAnim or (unitDef.walkAttr and unit:GetAttribute(unitDef.walkAttr))
	local idleId = unitDef.idleAnim or (unitDef.idleAttr and unit:GetAttribute(unitDef.idleAttr))
	if not walkId or not idleId then
		warn("BotPlayerAI: missing anim IDs for", unitDef.id, "walk=", walkId, "idle=", idleId)
		return
	end
 
	-- Helper to create and configure an AnimationTrack from an rbxassetid string
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
	idleTrack:Play(0.1) -- Start in idle immediately
 
	local root = unit:FindFirstChild("HumanoidRootPart")
 
	-- Spawn a loop that checks speed every 0.2 seconds and blends between walk/idle.
	-- We use horizontal speed only (ignoring Y) so jumping doesn't trigger the walk anim.
	task.spawn(function()
		local walking = false
		while unit.Parent and hum.Health > 0 do
			task.wait(0.2)
			local vel   = root and root.AssemblyLinearVelocity or Vector3.zero
			local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			if speed > 0.5 and not walking then
				-- Unit started moving; cross-fade from idle to walk
				walking = true
				idleTrack:Stop(0.2)
				walkTrack:Play(0.2)
			elseif speed <= 0.5 and walking then
				-- Unit stopped; cross-fade from walk to idle
				walking = false
				walkTrack:Stop(0.2)
				idleTrack:Play(0.2)
			end
		end
		-- Clean up both tracks when the unit dies or is removed
		walkTrack:Stop(0)
		idleTrack:Stop(0)
	end)
end
 
-- SPAWN
-- Clones a unit template, configures all of its attributes and scripts,
-- positions it at the bot's spawn point, and registers its death handler.
-- isReinforcement = true means this is a free respawn (no money deducted).
local function spawnBotUnit(unitDef, isReinforcement)
	-- Find the NPC template and a zombie template (used to copy movement/attack scripts)
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
	unit.Name = "Zombie" -- Named "Zombie" so existing zombie-handling systems recognize it
 
	-- Stamp identity attributes so other scripts and counter functions can identify this unit
	unit:SetAttribute("BotUnit",           true)
	unit:SetAttribute("UnitId",            unitDef.id)
	unit:SetAttribute("ZombieType",        "BotUnit")
	unit:SetAttribute("AttackDamage",      unitDef.damage)
 
	-- Stamp reload animation and combat configuration for ranged units.
	-- Attack scripts read these attributes at runtime instead of being hardcoded,
	-- which lets us reuse the same BotRangedAttack script across all ranged unit types.
	if unitDef.reloadAttr then
		local reloadId = unit:GetAttribute(unitDef.reloadAttr) or ""
		if reloadId ~= "" then unit:SetAttribute("BotReloadAnimId", reloadId) end
	end
	if unitDef.shotsPerBurst    then unit:SetAttribute("BotShotsPerBurst",     unitDef.shotsPerBurst)    end
	if unitDef.shotsBeforeReload then unit:SetAttribute("BotShotsBeforeReload", unitDef.shotsBeforeReload) end
	if unitDef.pelletCount      then unit:SetAttribute("BotPelletCount",       unitDef.pelletCount)      end
	unit:SetAttribute("BotAttackCooldown", unitDef.cooldown)
 
	-- Resolve and stamp the attack animation ID onto the unit as an attribute.
	-- The attack script reads this attribute to play the correct animation,
	-- allowing per-unit attack anims without modifying the attack script itself.
	local attackAnimId = resolveAttackAnim(unitDef, unit)
	if attackAnimId ~= "" then
		unit:SetAttribute("BotAttackAnimId", attackAnimId)
	end
 
	-- Redneck has 3 distinct attacks with different damage values per swing.
	-- We stamp each attack's animation ID and damage separately so the attack script
	-- can cycle through them in sequence (attack 1 → 2 → 3 → repeat).
	if unitDef.id == "redneck" then
		unit:SetAttribute("BotAttackCount",   3)
		unit:SetAttribute("BotAttack1AnimId", "rbxassetid://127576285148293")
		unit:SetAttribute("BotAttack1Damage", 40)
		unit:SetAttribute("BotAttack2AnimId", "rbxassetid://79902482773923")
		unit:SetAttribute("BotAttack2Damage", 25)
		unit:SetAttribute("BotAttack3AnimId", "rbxassetid://136273491855743")
		unit:SetAttribute("BotAttack3Damage", 15)
	end
 
	-- Disable all scripts on the cloned template first; we re-enable only what this unit needs.
	-- This prevents the original NPC scripts from running when they shouldn't.
	for _, s in unit:GetDescendants() do
		if s:IsA("Script") then s.Disabled = true end
	end
 
	if unitDef.id == "riotGuard" then
		-- Riot Guard uses its own built-in AI script that handles its 2-phase shield mechanic.
		-- We re-enable it here instead of copying generic movement/attack scripts.
		local rgAI = unit:FindFirstChild("RiotGuardAI")
		if rgAI then rgAI.Disabled = false end
	else
		-- For melee/tank units, copy ZombieMover (pathfinding) and ZombieAttackBus (bus damage) scripts
		-- from the zombie template. Ranged units use BotRangedAttack which has its own pathfinding.
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
		-- Select the correct attack script based on role:
		-- ranged units get BotRangedAttack, melee/tank units get ZombieAttackShovelUnit
		local attackScriptName = unitDef.role == "ranged" and "BotRangedAttack" or "ZombieAttackShovelUnit"
		local attackScript = zombieTmpl:FindFirstChild(attackScriptName)
		if attackScript then
			local cloned = attackScript:Clone()
			cloned.Disabled = false
			cloned.Parent = unit
		end
	end
 
	-- Configure the Humanoid with this unit's stats
	local hum = unit:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.MaxHealth          = unitDef.health
		hum.Health             = unitDef.health
		hum.WalkSpeed          = unitDef.speed
		hum.BreakJointsOnDeath = false -- We handle joints manually in the death handler
	end
 
	-- Unanchor all parts so the unit can move; templates are often stored anchored
	for _, desc in unit:GetDescendants() do
		if desc:IsA("BasePart") then desc.Anchored = false end
	end
 
	-- Apply a custom skin color to all body parts if the unit definition specifies one.
	-- This is used for policeman bots to visually distinguish them from player police units.
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
 
	-- Find the designated bot spawn pad in the workspace and position the unit on it.
	-- The spawn area uses a Part's CFrame and Size to randomize the exact spawn position
	-- so units don't all stack on the exact same point.
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
 
	-- Deduct cost from bot money unless this is a free reinforcement spawn
	if not isReinforcement then botMoney -= unitDef.cost end
 
	-- Attach death handler and start walk/idle animations
	setupBotDeath(unit)
	if unitDef.id ~= "riotGuard" then startAnimations(unit, unitDef) end
 
	-- Reinforcement mechanic: when certain premium units die, there is a 50% chance
	-- the bot spawns a free replacement unit from the same pool (policeman, riotGuard, shotgunner).
	-- This creates a comeback mechanic that makes the bot feel more reactive.
	-- isReinforcement flag prevents chaining (a reinforcement cannot spawn another reinforcement).
	if not isReinforcement and (unitDef.id == "policeman" or unitDef.id == "riotGuard" or unitDef.id == "shotgunner") then
		local hum2 = unit:FindFirstChildOfClass("Humanoid")
		if hum2 then
			hum2.Died:Connect(function()
				if math.random() > 0.5 then return end -- 50% chance to trigger
				task.wait(2) -- Brief delay before reinforcement appears
				-- Only reinforce if the bot is currently outnumbered
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
 
	-- Fallback kill zone: if a unit somehow falls below the map (Y < FALL_KILL_Y),
	-- destroy it to prevent it from getting stuck in an unreachable state
	task.spawn(function()
		while unit.Parent do
			task.wait(2)
			local r = unit:FindFirstChild("HumanoidRootPart")
			if r and r.Position.Y < FALL_KILL_Y then unit:Destroy(); break end
		end
	end)
end
 
-- UNIT PICKER
-- Decides which unit the bot should deploy next based on:
-- 1. Current preference (cheap / tank / fast / mixed) — shifts every 20–50s
-- 2. Role balance — actively tries to maintain a healthy mix of tanks and ranged
-- 3. Variety cap — penalizes deploying too many of the same unit type
-- 4. Counter strategy — heavily favors armored units when player has only bullet units
-- 5. Weighted random selection — ensures some unpredictability in every decision
-- Returns nil if no affordable unit exists or the bot should save its money.
local function pickUnit()
	local typeCounts  = countBotUnitsByType()
	local playerCount = countPlayerUnits()
 
	-- Summarize the current bot army composition by role
	local tanksAlive  = (typeCounts["builder"] or 0) + (typeCounts["riotGuard"] or 0)
	local rangedAlive = (typeCounts["farmer"]  or 0) + (typeCounts["policeman"] or 0) + (typeCounts["shotgunner"] or 0)
	local meleeAlive  = typeCounts["redneck"] or 0
	local totalAlive  = tanksAlive + rangedAlive + meleeAlive
 
	-- The bot is "dominant" if it has 3+ units and is at least matching the player's count.
	-- Dominance unlocks additional bias toward expensive units like the riot guard.
	local botDominant = totalAlive >= 3 and totalAlive >= playerCount
 
	-- Build a weighted pool of all units the bot can currently afford
	local pool = {}
 
	for _, u in UNITS do
		if botMoney >= u.cost then
			local w = 10 -- Default base weight
 
			-- Apply preference-based weight adjustments:
			-- "cheap" heavily favors low-cost units; "tank" favors high-health; "fast" favors speed
			if preference == "cheap" then
				w = math.max(1, 36 - u.cost * 2)
			elseif preference == "tank" then
				w = u.health >= 200 and 30 or (u.health >= 100 and 14 or 5)
			elseif preference == "fast" then
				w = u.speed >= 8 and 30 or (u.speed >= 5 and 14 or 5)
			else
				-- Mixed: add random variance so no two "mixed" decisions are the same
				w = 10 + math.random(0, 8)
			end
 
			-- Role balance adjustments:
			-- If no tanks exist, strongly bias toward buying one before anything else
			-- If ranged units outnumber tanks, push toward buying a tank
			-- Avoid buying ranged units when there's no tank frontline to protect them
			if u.role == "tank" then
				if tanksAlive == 0 then
					w += 35
				elseif rangedAlive > tanksAlive then
					w += 20
				end
			elseif u.role == "ranged" then
				if tanksAlive == 0 then
					w = math.max(1, w - 15) -- Penalize ranged without a tank
				elseif tanksAlive >= rangedAlive then
					w += 22 -- Good time to add ranged support behind existing tanks
				end
			elseif u.role == "melee" then
				if totalAlive == 0 then
					w += 8  -- First unit; melee is a fine opener
				elseif meleeAlive >= 2 then
					w = math.max(1, w - 25) -- Heavily penalize stacking too many melee
				elseif meleeAlive >= 1 then
					w = math.max(1, w - 12)
				end
			end
 
			-- Variety cap: each duplicate beyond 1 receives an increasing weight penalty.
			-- This prevents the bot from spamming a single cheap unit (e.g. all rednecks).
			local myCount = typeCounts[u.id] or 0
			if myCount >= 2 then
				w = math.max(1, w - (myCount - 1) * 18)
			end
 
			-- When the player has a large army (5+ units), scale toward tankier options
			if playerCount >= 5 then w += u.health // 25 end
 
			-- Extra riot guard weighting: high cost but game-changing if the bot is winning
			if u.id == "riotGuard" then
				if botDominant then
					w += 50 -- If winning, buy the biggest threat available
				elseif botMoney >= 60 then
					w += 20 -- Flush with money; a riot guard is a good investment
				else
					w += 8  -- Still a mild preference even when barely affordable
				end
			end
 
			-- Counter-pick: if the player only has bullet units, armored units are much harder to kill.
			-- Heavily bias toward builder and riot guard in this scenario.
			if (u.id == "builder" or u.id == "riotGuard") and playerOnlyHasBulletUnits() then
				w += 50
			end
 
			table.insert(pool, { unit = u, weight = w })
		end
	end
 
	if #pool == 0 then return nil end -- Nothing affordable; wait for more money
 
	-- Save up for riot guard if the bot is dominant and close to being able to afford it.
	-- Spending 20 on a builder now would delay the riot guard by several seconds.
	if botDominant and totalAlive >= 2 and botMoney >= 28 and botMoney < 40 then
		return nil
	end
 
	-- If the only affordable unit is a redneck but we already have 2+, save up for variety.
	-- This prevents the bot from getting locked into spamming rednecks early game.
	if #pool == 1 and pool[1].unit.id == "redneck" and (typeCounts["redneck"] or 0) >= 2 then
		return nil
	end
 
	-- Weighted random selection: roll a number in [0, totalWeight] and walk the pool
	local total, cum = 0, 0
	for _, e in pool do total += e.weight end
	local roll = math.random() * total
	for _, e in pool do
		cum += e.weight
		if roll <= cum then return e.unit end
	end
	return pool[#pool].unit -- Fallback to last entry if floating point causes roll to exceed total
end
 
-- MONEY TICK
-- The bot earns 1 coin per second, capped at MAX_MONEY.
-- This runs in a background thread independent of the decision loop.
task.spawn(function()
	while true do
		task.wait(1)
		botMoney = math.min(MAX_MONEY, botMoney + 1)
	end
end)
 
-- STRATEGY SHIFT
-- Every 20–50 seconds, the bot randomly picks a new preference and aggression level.
-- This simulates an adaptive opponent that changes tactics mid-game rather than
-- using one fixed strategy throughout. A 40% chance to enter rush mode means
-- the bot will occasionally save up and deploy multiple units at once.
task.spawn(function()
	-- "cheap" appears twice and "mixed" three times to weight the distribution:
	-- the bot is most likely to play mixed, followed by cheap, then tank or fast
	local prefs = { "cheap","cheap","tank","fast","mixed","mixed","mixed" }
	while true do
		task.wait(math.random(20, 50)) -- Random interval between strategy shifts
		preference = prefs[math.random(#prefs)]
		aggression = math.random(35, 92) / 100 -- Re-roll spawn probability (0.35–0.92)
		burstSize  = math.random(2, 4)          -- Re-roll how many units to deploy in a rush
		-- 40% chance to enter rush mode; the bot saves until it hits rushGoal then bursts
		if not rushMode and math.random() < 0.40 then
			rushMode = true
			rushGoal = math.random(45, 130)
		end
	end
end)
 
-- MAIN DECISION LOOP
-- Runs continuously throughout the game, firing every 0.6–2.2 seconds.
-- On each tick, the bot decides whether to deploy a unit based on:
-- Whether the player has deployed their first unit yet (bot waits to save up)
-- Whether the bot is already at or above the player's unit count
-- Whether rush mode is active and the money threshold has been reached
-- A random roll against the current aggression value
local playerDeployed = false
 
while true do
	task.wait(math.random(6, 22) / 10) -- Random tick interval: 0.6s to 2.2s
 
	-- Don't act until the player has deployed at least one unit.
	-- This gives the bot time to save up money before the match really begins,
	-- and prevents it from deploying into an empty field at the start.
	if not playerDeployed then
		if countPlayerUnits() == 0 then continue end
		playerDeployed = true
	end
 
	-- If the bot already has at least as many units as the player, hold off.
	-- This prevents the bot from overwhelming the player with a numbers advantage
	-- and keeps the match feeling fair and competitive.
	if countBotUnits() >= countPlayerUnits() then continue end
 
	-- Rush mode: when the bot has saved enough money, spend it in a rapid burst
	if rushMode and botMoney >= rushGoal then
		rushMode = false
		for _ = 1, burstSize do
			local u = pickUnit()
			if u and botMoney >= u.cost then
				spawnBotUnit(u)
				task.wait(math.random(2, 7) / 10) -- Small stagger between burst deploys
			end
		end
		continue
	end
 
	-- Normal spawn: roll against aggression probability.
	-- urgency is a small bonus added when the player has 6+ units,
	-- making the bot more likely to respond aggressively to a large army.
	local urgency = countPlayerUnits() >= 6 and 0.20 or 0
	if math.random() < (aggression + urgency) and botMoney >= 10 then
		local u = pickUnit()
		if u then spawnBotUnit(u) end
	end
end
