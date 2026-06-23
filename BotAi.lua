-- Discord: dcz1012       Roblox: dcz1012

-- this is the ghost/replay system for time loop
-- each time you die a new ghost instance gets created from your recorded frames
-- it replays your exact movement using anchored cframes driven by wall clock time
-- so it stays perfectly synced with the traps no matter what the server framerate is
-- when a ghost gets killed or finishes it ragdolls using its own joint system we build from scratch

-- signal and ghost are both OOP classes using metatables
-- signal is a lightweight custom event system with no engine dependencies
-- ghost handles building the model, running playback, sword wiring, health, blood, and retirement

local Config    = require(script.Parent.Config)
local BloodFX   = require(script.Parent.BloodFX)
local HealthBar = require(script.Parent.HealthBar)
local ServerStorage = game:GetService("ServerStorage")

local RECORD_RATE = Config.RECORD_RATE

-- signal class, basically a stripped down version of RBXScriptSignal
-- needed a custom one so we have full control over the event lifecycle
-- each ghost fires .Killed when playback ends and .Retired after the ragdoll finishes
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	table.insert(self._handlers, fn)
	-- returns a disconnect handle so callers can clean up their own listeners
	return {
		Disconnect = function()
			for i, f in ipairs(self._handlers) do
				if f == fn then table.remove(self._handlers, i); break end
			end
		end,
	}
end

function Signal:Fire(...)
	for _, fn in ipairs(self._handlers) do
		-- task.spawn so one broken listener cant crash the others
		task.spawn(fn, ...)
	end
end

-- applies a recorded frame directly to the model by driving each part's cframe
-- acc_ prefix means its an accessory handle, everything else is a regular basepart
local function applyFrame(model, frame)
	for key, cf in pairs(frame) do
		if key:sub(1, 4) == "ACC_" then
			local acc = model:FindFirstChild(key:sub(5))
			local handle = acc and acc:FindFirstChild("Handle")
			if handle then handle.CFrame = cf end
		else
			local part = model:FindFirstChild(key)
			if part and part:IsA("BasePart") then part.CFrame = cf end
		end
	end
end

-- same as applyFrame but lerps between two keyframes using alpha
-- the recording runs at 10fps but this makes it look smooth at any render rate
local function applyFrameLerp(model, frameA, frameB, alpha)
	for key, cfA in pairs(frameA) do
		local target = cfA:Lerp(frameB[key] or cfA, alpha)
		if key:sub(1, 4) == "ACC_" then
			local acc = model:FindFirstChild(key:sub(5))
			local handle = acc and acc:FindFirstChild("Handle")
			if handle then handle.CFrame = target end
		else
			local part = model:FindFirstChild(key)
			if part and part:IsA("BasePart") then part.CFrame = target end
		end
	end
end

-- ghost class, one instance per past self replay
local Ghost = {}
Ghost.__index = Ghost

function Ghost.new(loopNum, rec, ctx)
	local self = setmetatable({}, Ghost)
	self.loopNum = loopNum
	self.rec     = rec
	self.ctx     = ctx
	self.frames  = rec.frames
	self.alive   = true
	self.model   = nil
	self.car     = nil
	self.rocketStartFrame = nil
	self.Killed  = Signal.new()
	self.Retired = Signal.new()
	return self
end

-- clones the recorded appearance, strips the rig, anchors everything, and poses to frame 1
-- we strip motor6ds because playback drives cframes directly so joints are useless
-- anchoring every part means physics cant fight the playback positions
function Ghost:_build()
	local model = self.rec.clone:Clone()
	model.Name = "PastSelf_" .. self.loopNum

	for _, motor in ipairs(model:GetDescendants()) do
		if motor:IsA("Motor6D") then motor:Destroy() end
	end

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup          = "Ghost"
			part.CanCollide              = (part.Name ~= "HumanoidRootPart")
			part.Anchored                = true
			part.AssemblyLinearVelocity  = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end

	applyFrame(model, self.frames[1])
	model.Parent = workspace

	-- roblox sometimes rebuilds motor6ds when a humanoid model enters workspace
	-- disable the state machine and strip them again after a defer to catch that
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true) end)
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
	end
	task.defer(function()
		for _, motor in ipairs(model:GetDescendants()) do
			if motor:IsA("Motor6D") then motor:Destroy() end
		end
	end)

	model:SetAttribute("GhostHealth",    Config.GHOST_HEALTH)
	model:SetAttribute("GhostMaxHealth", Config.GHOST_HEALTH)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp then HealthBar.create(hrp) end

	self.model = model
end

-- spawns a visual ghost car and drives it with lerped cframes from the recording
-- lazy init so we dont clone anything if the player never drove a car that run
function Ghost:_moveCar(pivotCF)
	if not self.car then
		local template = self.rec.carName and workspace:FindFirstChild(self.rec.carName)
		if not template then return end
		local car = template:Clone()
		car.Name = "GhostCar_" .. self.loopNum
		for _, d in ipairs(car:GetDescendants()) do
			if d:IsA("BaseScript") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = true
				pcall(function() d.CollisionGroup = "Ghost" end)
				if d:IsA("Seat") or d:IsA("VehicleSeat") then d.Disabled = true end
			end
		end
		car.Parent = self.ctx.fxFolder
		self.car = car
	end
	self.car:PivotTo(pivotCF)
end

-- delays until the frame where the player equipped the sword then welds a copy to the ghost hand
-- blade has a touched connection that damages swat npcs so the ghost actually fights like the player did
function Ghost:_wireSword()
	local rec = self.rec
	if type(rec.swordEquipFrame) ~= "number" or rec.swordEquipFrame <= 0 then return end
	task.delay((rec.swordEquipFrame - 1) * RECORD_RATE, function()
		if not self.alive or not self.model.Parent then return end
		local giver = workspace:FindFirstChild("Sword Giver", true)
		local tool  = ServerStorage:FindFirstChild("ClassicSword")
			or (giver and giver:FindFirstChild("ClassicSword"))
		local handleT = tool and tool:FindFirstChild("Handle")
		if not handleT then return end

		-- r15 and r6 have different hand part names so we handle both
		local hand, c0 = self.model:FindFirstChild("RightHand"), nil
		if hand then
			local att = hand:FindFirstChild("RightGripAttachment")
			c0 = att and att.CFrame or CFrame.new(0, -1, 0) * CFrame.Angles(-math.pi/2, 0, 0)
		else
			hand = self.model:FindFirstChild("Right Arm")
			c0   = CFrame.new(0, -1, 0) * CFrame.Angles(-math.pi/2, 0, 0)
		end
		if not hand then return end

		local blade      = handleT:Clone()
		blade.Name       = "GhostSword"
		blade.Anchored   = false
		blade.CanCollide = false
		blade.Massless   = true
		pcall(function() blade.CollisionGroup = "Ghost" end)
		local grip = (tool and tool:IsA("Tool")) and tool.Grip or CFrame.new()
		blade.CFrame = hand.CFrame * c0 * grip:Inverse()
		blade.Parent = self.model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hand; weld.Part1 = blade; weld.Parent = blade

		-- cooldown table prevents the same enemy from getting hit multiple times per swing
		local hitCD = {}
		blade.Touched:Connect(function(hit)
			if not self.alive then return end
			local m = hit and hit:FindFirstAncestorOfClass("Model")
			if not m then return end
			local hum = m:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then return end
			local isSwat = m.Name:sub(1, 4) == "SWAT" or (m.Parent and m.Parent.Name == "Enemies")
			if not isSwat then return end
			if hitCD[m] and (os.clock() - hitCD[m]) < Config.SWORD_COOLDOWN then return end
			hitCD[m] = os.clock()
			hum:TakeDamage(Config.SWORD_DAMAGE)
		end)
	end)
end

-- updates the floating health bar and spawns blood whenever the ghost takes damage
-- capped to 4 bursts per second because under heavy fire this fires way too often otherwise
function Ghost:_wireBlood()
	local model = self.model
	local lastBlood = 0
	model:GetAttributeChangedSignal("GhostHealth"):Connect(function()
		if not self.alive then return end
		local hp    = model:GetAttribute("GhostHealth") or 100
		local maxhp = model:GetAttribute("GhostMaxHealth") or 100
		local bar  = model:FindFirstChild("HumanoidRootPart")
		bar = bar and bar:FindFirstChild("GhostHealthBar")
		local fill = bar and bar:FindFirstChild("BG") and bar.BG:FindFirstChild("Fill")
		if fill then
			fill.Size = UDim2.new(math.clamp(hp / math.max(maxhp, 1), 0, 1), 0, 1, 0)
		end
		if hp < maxhp and (os.clock() - lastBlood) >= 0.25 then
			lastBlood = os.clock()
			local hrp = model:FindFirstChild("HumanoidRootPart")
			if hrp then
				local n = math.clamp(math.floor(40 * (maxhp - hp) / maxhp) + 12, 12, 50)
				BloodFX.spawnBloodBurst(hrp.Position, n)
			end
		end
	end)
end

-- builds the model then kicks off playback
function Ghost:start()
	self:_build()
	self:_wireSword()
	self:_wireBlood()
	if self.rec.rocket and #self.rec.rocket > 0 then
		self.rocketStartFrame = math.max(1, #self.frames - #self.rec.rocket + 1)
	end
	task.spawn(function() self:_run() end)
end

-- the main playback loop
-- fpos is a fractional frame index calculated from real elapsed time since the loop started
-- this keeps the ghost perfectly in sync with trap timings regardless of server frame rate
-- lerps between floor(fpos) and floor(fpos)+1 so motion is smooth even at 10fps recording rate
function Ghost:_run()
	local rec    = self.rec
	local model  = self.model
	local frames = self.frames
	local total  = #frames
	local playStart   = self.ctx.loopStartClock or os.clock()
	local rocketFired = false

	while true do
		if not self.alive then return end
		if model:GetAttribute("GhostKilled") then break end
		local fpos = (os.clock() - playStart) / RECORD_RATE + 1
		local i = math.floor(fpos)
		if i >= total then
			applyFrame(model, frames[total])
			local carLast = rec.carFrames and rec.carFrames[total]
			if carLast then self:_moveCar(carLast) end
			break
		end
		if self.rocketStartFrame and not rocketFired and i >= self.rocketStartFrame and self.ctx.playReplayRocket then
			rocketFired = true
			task.spawn(self.ctx.playReplayRocket, rec.rocket)
		end
		local alpha = fpos - i
		applyFrameLerp(model, frames[i], frames[i + 1], alpha)
		local carA = rec.carFrames and rec.carFrames[i]
		local carB = rec.carFrames and rec.carFrames[i + 1]
		if carA and carB then self:_moveCar(carA:Lerp(carB, alpha))
		elseif carA then self:_moveCar(carA) end
		task.wait()
	end

	if not self.alive then return end
	self.alive = false
	self.Killed:Fire(self)
	self:_retire()
	self.Retired:Fire(self)
end

-- builds a proper floppy ragdoll from scratch using the rig's attachment pairs
-- we cant use roblox's built in ragdoll because it adds stiff constraints that lock the pose
-- so we strip everything and put in our own ballsocketconstraints with loose angle limits
-- then fling each part either away from the blast position or with a random pop
function Ghost:_retire()
	local model = self.model

	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end

	-- snapshot all world cframes before unanchoring so nothing shifts
	local worldCFs = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then worldCFs[part] = part.CFrame end
	end
	for _, part in ipairs(model:GetDescendants()) do
		if not part:IsA("BasePart") then continue end
		if worldCFs[part] then part.CFrame = worldCFs[part] end
		part.Anchored                = false
		pcall(function() part:SetNetworkOwner(nil) end)
		part.AssemblyLinearVelocity  = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
		if part.Name == "HumanoidRootPart" then
			part.CanCollide = false; part.Transparency = 1
		else
			part.CanCollide = true
		end
	end

	-- strip all motor6ds and constraints, then build our own joints from matching rig attachment names
	for _, motor in ipairs(model:GetDescendants()) do
		if motor:IsA("Motor6D") then motor:Destroy() end
	end
	for _, c in ipairs(model:GetDescendants()) do
		if c:IsA("Constraint") then c:Destroy() end
	end

	-- group attachments by name, any pair of matching rig attachments becomes a ball socket joint
	local byName = {}
	for _, att in ipairs(model:GetDescendants()) do
		if att:IsA("Attachment") and att.Name:match("RigAttachment$") and att.Parent:IsA("BasePart") then
			byName[att.Name] = byName[att.Name] or {}
			table.insert(byName[att.Name], att)
		end
	end
	for _, pair in pairs(byName) do
		if #pair == 2 then
			local bsc = Instance.new("BallSocketConstraint")
			bsc.Name = "GhostRagdollJoint"
			bsc.Attachment0 = pair[1]; bsc.Attachment1 = pair[2]
			bsc.LimitsEnabled = true; bsc.TwistLimitsEnabled = true
			bsc.UpperAngle = 90; bsc.TwistUpperAngle = 80; bsc.TwistLowerAngle = -80
			bsc.MaxFrictionTorque = 0; bsc.Restitution = 0
			bsc.Parent = pair[1].Parent
		end
	end

	-- roblox sometimes re-adds constraints after we destroy them so we keep cleaning for a bit
	task.spawn(function()
		for _ = 1, 24 do
			if not model.Parent then return end
			for _, c in ipairs(model:GetDescendants()) do
				if c:IsA("Constraint") and c.Name ~= "GhostRagdollJoint" then c:Destroy() end
			end
			task.wait(0.05)
		end
	end)

	-- if a rocket killed it, fling parts away from the blast with distance falloff
	-- otherwise just give it a random upward pop so it doesnt just fall straight down
	local blastPos   = model:GetAttribute("GhostBlastPos")
	local blastForce = model:GetAttribute("GhostBlastForce") or 0
	local rangle = math.random() * math.pi * 2
	local vx, vz = math.cos(rangle) * 8, math.sin(rangle) * 8
	for _, part in ipairs(model:GetDescendants()) do
		if not part:IsA("BasePart") or part.Name == "HumanoidRootPart" then continue end
		if blastPos then
			local off     = part.Position - blastPos
			local d       = off.Magnitude
			local dir     = (d > 0.05) and off.Unit or Vector3.new(0, 1, 0)
			local falloff = math.clamp(1 - (d / 16) * 0.6, 0.2, 1)
			part.AssemblyLinearVelocity = (dir + Vector3.new(0, 0.9, 0)).Unit * blastForce * falloff
		else
			part.AssemblyLinearVelocity = Vector3.new(vx+(math.random()-.5)*3, 6+math.random()*5, vz+(math.random()-.5)*3)
		end
		part.AssemblyAngularVelocity = Vector3.new((math.random()-.5)*8, (math.random()-.5)*8, (math.random()-.5)*8)
	end

	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp then
		BloodFX.spawnBloodBurst(hrp.Position, 55)
		BloodFX.spawnBloodPool(hrp.Position, model)
	end
	BloodFX.attachBloodDrips(model)
end

-- stops playback and removes the model immediately, called when the loop resets
function Ghost:stop()
	self.alive = false
	if self.model and self.model.Parent then self.model:Destroy() end
end

return { Ghost = Ghost, Signal = Signal }
