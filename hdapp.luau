-- connected discord github
-- Discord: .emrr. 
-- Roblox: emrr4dt


-- this script is an advanced ai npc system runing on roblox using the gemini api
-- strict type checking is enabled to prevent errors and keep data safe
-- the system has dynamic pathfinding maid stuff and player memory tracking

-- http service to decode json and handle web stuff
local HttpService = game:GetService("HttpService")

-- players service for tracking active players and data
local Players = game:GetService("Players")

-- chat service so the npc can talk above its head
local Chat = game:GetService("Chat")

-- run service that fires every frame to do precise loops and stuff
local RunService = game:GetService("RunService")

-- pathfinding service to keep the npc from walking into walls
local PathfindingService = game:GetService("PathfindingService")

-- config table that has the setup keys and stuff
local Config = {
	ApiKey = "GEMINI_API_KEY", -- secret token for the gemini dev platform
	Model = "gemini-2.5-flash", -- the model that does all the thinking
	NpcName = "Rig", -- name of the model in workspace
	MaxFollowDistance = 6, -- distance that makes character start moving to target
	StopDistance = 4, -- distance where character stops moving so it dont bump u
	RequestCooldown = 4, -- cooldown between api calls so we dont get banned
	MaxHistoryLength = 10, -- max logs saved so we dont waste tokens
	PathColor = Color3.fromRGB(0, 255, 128) -- color for the debug path nodes
}

-- making the url for requests
local API_URL = string.format(
	"https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
	Config.Model,
	Config.ApiKey
)

-- getting the model from workspace and typing it
local NpcModel = workspace:WaitForChild(Config.NpcName) :: Model

-- tracking humanoid for stats and physics
local Humanoid = NpcModel:WaitForChild("Humanoid") :: Humanoid

-- getting head part for math and chatting
local Head = NpcModel:WaitForChild("Head") :: BasePart

-- getting root part which is the base of the model
local RootPart = NpcModel:WaitForChild("HumanoidRootPart") :: BasePart

-- finding the neck joint to move the head
local NeckMotor: Motor6D? = NpcModel:FindFirstChild("Neck", true) :: Motor6D?

-- saving the original neck formula so it dont break
local OriginalNeckC0 = NeckMotor and NeckMotor.C0 or CFrame.new()

-- making type stuff to enforce safety
type MaidTask = RBXScriptConnection | Instance | (() -> ()) | { Destroy: (any) -> () }
type MessagePart = { text: string }
type ChatMessage = { role: string, parts: { MessagePart } }
type NpcState = "Idle" | "Following" | "MovingToWaypoint" | "Talking"

-- main type of the npc controller
type AI_NPC_Type = {
	State: NpcState,
	TargetPlayer: Player?,
	LookTarget: Vector3?,
	LastRequestTime: number,
	IsProcessing: boolean,
	PlayerHistories: { [number]: { ChatMessage } },
	ActiveMaid: typeof(setmetatable({} :: { _tasks: { MaidTask } }, {} :: any)),
	NeckMaid: typeof(setmetatable({} :: { _tasks: { MaidTask } }, {} :: any)),
	InitializeHeadLook: (any) -> (),
	GetHistory: (any, Player) -> { ChatMessage },
	AddHistory: (any, Player, string, string) -> (),
	MoveTo: (any, Vector3) -> (),
	FollowPlayer: (any, Player) -> (),
	Stop: (any) -> (),
	ProcessPlayerMessage: (any, Player, string) -> ()
}

-- maid obj that cleans memory leaks and overhangs
local Maid = {}
Maid.__index = Maid

-- makes a new maid container
function Maid.new()
	-- returns the maid table or whatever
	return setmetatable({ _tasks = {} }, Maid)
end

-- saves connection so maid can clean later
function Maid:GiveTask(task: MaidTask): number
	local self = self :: any -- makes it any type so rbx dont yell at me
	local id = #self._tasks + 1 -- gets next number for the table
	self._tasks[id] = task -- puts connection into the maid table
	return id -- returns the unique id
end

-- cleans up all connections and things
function Maid:Clean()
	local self = self :: any -- type losening thingy
	-- goes backwards so it dont break things
	for i = #self._tasks, 1, -1 do
		local t = self._tasks[i]
		if typeof(t) == "RBXScriptConnection" then
			t:Disconnect() -- stops events
		elseif typeof(t) == "Instance" then
			t:Destroy() -- destroys the part
		elseif typeof(t) == "function" then
			task.spawn(t) -- runs the clean func in new thread
		elseif typeof(t) == "table" and typeof(t.Destroy) == "function" then
			t:Destroy() -- calls the destroy func
		end
	end
	table.clear(self._tasks) -- clears the table
end

-- main class that does the npc stuff
local AI_NPC = {}
AI_NPC.__index = AI_NPC

-- new npc constructor
function AI_NPC.new(): AI_NPC_Type
	-- setups the npc stats and maids
	local self = setmetatable({
		State = "Idle" :: NpcState, -- it just stands there first
		TargetPlayer = nil :: Player?, -- no target yet
		LookTarget = nil :: Vector3?, -- nothing to look at yet
		LastRequestTime = 0, -- time of last request
		IsProcessing = false, -- is it doing somethng right now
		PlayerHistories = {}, -- saves what players say
		ActiveMaid = Maid.new(), -- maid for moving around
		NeckMaid = Maid.new() -- maid for the neck moving
	}, AI_NPC) :: any
	
	self:InitializeHeadLook() -- starts moving the head
	return self -- returns the obj
end

-- gets or makes player history
function AI_NPC:GetHistory(player: Player): { ChatMessage }
	local self = self :: AI_NPC_Type -- make sure it is the right type
	local userId = player.UserId -- saves the id to use this
	-- if no history now make new table
	if not self.PlayerHistories[userId] then
		self.PlayerHistories[userId] = {}
	end
	return self.PlayerHistories[userId]
end

-- adds new chat to the table
function AI_NPC:AddHistory(player: Player, role: string, text: string)
	local self = self :: AI_NPC_Type -- fix the types
	local history = self:GetHistory(player) -- gets the history
	-- puts the msg to the table format
	table.insert(history, {
		role = role,
		parts = { { text = text } }
	})
	
	-- if table too big delete the oldest msg
	if #history > Config.MaxHistoryLength then
		table.remove(history, 1)
	end
end

-- makes the head look at the target
function AI_NPC:InitializeHeadLook()
	local self = self :: AI_NPC_Type -- make sure type is ok
	self.NeckMaid:Clean() -- cleans the old neck stuff
	if not NeckMotor then return end -- if no neck then skip and stop
	
	-- runs on very heartbeat
	local connection = RunService.Heartbeat:Connect(function()
		local targetPos = self.LookTarget
		-- find where to look if there is a player
		if not targetPos and self.TargetPlayer and self.TargetPlayer.Character then
			local char = self.TargetPlayer.Character
			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then targetPos = root.Position end
		end
		
		local neck = NeckMotor
		if targetPos and neck and neck.Part0 then
			local part0 = neck.Part0 :: BasePart
			-- make global look into local space
			local localTarget = part0.CFrame:PointToObjectSpace(targetPos)
			local lookAtCFrame = CFrame.lookAt(Vector3.new(0, 0, 0), localTarget)
			
			-- limit the angles so neck dont break looking away
			local rx, ry, rz = lookAtCFrame:ToEulerAnglesYXZ()
			rx = math.clamp(rx, math.rad(-30), math.rad(30))
			ry = math.clamp(ry, math.rad(-55), math.rad(55))
			rz = math.clamp(rz, math.rad(-10), math.rad(10))
			
			local clampedRotation = CFrame.fromEulerAnglesYXZ(rx, ry, rz)
			local neckAny: any = neck -- cast to any or somthing
			
			-- try to set transform with pcall
			local transformSuccess = pcall(function()
				neckAny.Transform = clampedRotation
			end)
			
			-- if transform fails use c0 instead
			if not transformSuccess then
				pcall(function()
					neckAny.C0 = OriginalNeckC0 * clampedRotation
				end)
			end
		else
			-- if nothing to look at snap head back
			if neck then
				local neckAny: any = neck
				local transformSuccess = pcall(function()
					local current = neckAny.Transform
					neckAny.Transform = current:Lerp(CFrame.new(), 0.1)
				end)
				if not transformSuccess then
					pcall(function()
						neckAny.C0 = neckAny.C0:Lerp(OriginalNeckC0, 0.1)
					end)
				end
			end
		end
	end)
	
	-- give to maid
	self.NeckMaid:GiveTask(connection)
end

-- calc the path and moves there
function AI_NPC:MoveTo(targetPosition: Vector3)
	local self = self :: AI_NPC_Type -- makes sure is the right type
	self.ActiveMaid:Clean() -- cleans old move stuff
	self.State = "MovingToWaypoint" -- sets state to moving
	self.LookTarget = targetPosition -- makes head look at destination
	
	-- path setings for the agent
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4
	})
	
	-- computes the waypoints wth pcall
	local success, errorMessage = pcall(function()
		path:ComputeAsync(RootPart.Position, targetPosition)
	end)
	
	-- if path fails just walk straight there
	if not (success and path.Status == Enum.PathStatus.Success) then
		Humanoid:MoveTo(targetPosition)
		return
	end
	
	-- gets the waypoints
	local waypoints = path:GetWaypoints()
	local currentWaypointIndex = 2 -- we dont need first point
	
	-- makes glowing parts so u can see path
	local visualParts = {}
	for i = 2, #waypoints do
		local wp = waypoints[i]
		local part = Instance.new("Part")
		part.Size = Vector3.new(0.6, 0.6, 0.6)
		part.Position = wp.Position
		part.Color = Config.PathColor
		part.Material = Enum.Material.Neon
		part.Anchored = true
		part.CanCollide = false
		part.Parent = workspace
		table.insert(visualParts, part)
		self.ActiveMaid:GiveTask(part) -- puts the visual parts to maid
	end
	
	-- func to destroy old waypoints
	local function cleanWaypointVisuals(index: number)
		for i = 1, index - 1 do
			if visualParts[i] then
				visualParts[i]:Destroy()
				visualParts[i] = nil
			end
		end
	end
	
	-- connection when reached the point
	local reachedConnection: RBXScriptConnection? = nil
	reachedConnection = Humanoid.MoveToFinished:Connect(function(reached)
		-- if hit stop calucalte again
		if not reached then
			if reachedConnection then
				reachedConnection:Disconnect()
			end
			self:MoveTo(targetPosition)
			return
		end
		
		-- cleans visuals for passd points
		cleanWaypointVisuals(currentWaypointIndex)
		
		-- if more point s then move there
		if currentWaypointIndex < #waypoints then
			currentWaypointIndex += 1
			local nextWp = waypoints[currentWaypointIndex]
			
			-- if pnt says jump then jump
			if nextWp.Action == Enum.PathWaypointAction.Jump then
				Humanoid.Jump = true
			end
			
			-- walk to nxt pnt
			Humanoid:MoveTo(nextWp.Position)
		else
			-- when done movig disconnct and idle
			if reachedConnection then
				reachedConnection:Disconnect()
			end
			self.State = "Idle"
		end
	end)
	
	-- give to maid
	self.ActiveMaid:GiveTask(reachedConnection :: RBXScriptConnection)
	
	-- starts moving to first point
	local initialWp = waypoints[currentWaypointIndex]
	if initialWp then
		if initialWp.Action == Enum.PathWaypointAction.Jump then
			Humanoid.Jump = true
		end
		Humanoid:MoveTo(initialWp.Position)
	end
end

-- starts makig npc follow the player arund
function AI_NPC:FollowPlayer(player: Player)
	local self = self :: AI_NPC_Type -- strict type
	self.ActiveMaid:Clean() -- stops path movment
	self.State = "Following" -- sets as follow
	self.TargetPlayer = player -- this is followig player
	
	-- update every fram wiht heartbeat
	local followConnection = RunService.Heartbeat:Connect(function()
		local character = player.Character
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		
		-- if player goes away jsut stop
		if not targetRoot then
			self:Stop()
			return
		end
		
		local targetPos = targetRoot.Position
		self.LookTarget = targetPos -- look at pleyer
		local distance = (RootPart.Position - targetPos).Magnitude -- calc distnace to them
		
		-- move if far stop if too close
		if distance > Config.MaxFollowDistance then
			Humanoid:MoveTo(targetPos)
		elseif distance < Config.StopDistance then
			Humanoid:MoveTo(RootPart.Position)
		end
	end)
	
	-- maid cleans this
	self.ActiveMaid:GiveTask(followConnection)
end

-- stop the npc movement
function AI_NPC:Stop()
	local self = self :: AI_NPC_Type -- type stuff
	self.ActiveMaid:Clean() -- cleans everythng
	self.State = "Idle" -- go back to idle
	self.TargetPlayer = nil -- no target anymore
	self.LookTarget = nil -- no lookin nothing
	Humanoid:MoveTo(RootPart.Position) -- walk to curren pos to stop imedietly
end

-- sends the text to the api and does what it says
function AI_NPC:ProcessPlayerMessage(player: Player, message: string)
	local self = self :: AI_NPC_Type -- type verifcation
	if self.IsProcessing then return end -- dont do it if alredy bussy
	
	-- check cooldown
	local now = os.clock()
	if now - self.LastRequestTime < Config.RequestCooldown then
		Chat:Chat(Head, "...", Enum.ChatColor.White)
		return
	end
	
	self.IsProcessing = true -- makes sure we is procesing
	self.LastRequestTime = now -- save time
	
	self:AddHistory(player, "user", message) -- save plyers text
	local history = self:GetHistory(player) -- gets history
	
	-- match the api format
	local contentsArray = {}
	for _, log in ipairs(history) do
		table.insert(contentsArray, {
			role = log.role,
			parts = log.parts
		})
	end
	
	-- system prompt which tells it how to behav
	local systemPrompt = [[
You are an interactive AI NPC in Roblox. Analyze the conversation.
Rules:
1. If the player asks you to follow, stay close, or come here, set "action" to "FOLLOW".
2. If the player asks you to stop, stay there, wait, or freeze, set "action" to "STOP".
3. For general talk or questions, set "action" to "TALK".
4. You MUST reply in the exact language the user used. Keep it concise.
5. You MUST output ONLY pure JSON. No markdown, no extra characters.
Format: {"action": "FOLLOW|STOP|TALK", "reply": "Your response here"}
]]
	
	-- maks the request body
	local requestBody = {
		systemInstruction = {
			parts = { { text = systemPrompt } }
		},
		contents = contentsArray,
		generationConfig = {
			responseMimeType = "application/json" -- json only so it dont break
		}
	}
	
	-- the setings for sending the api reqest
	local requestOptions = {
		Url = API_URL,
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json"
		},
		Body = HttpService:JSONEncode(requestBody) -- encode to json
	}
	
	-- spawns task so it dont halt game
	task.spawn(function()
		print("[AI_NPC] Sending request to Gemini API...")
		-- pcall it just incase it fails
		local success, response = pcall(function()
			return HttpService:RequestAsync(requestOptions)
		end)
		
		self.IsProcessing = false -- not busy aymore
		
		-- if it fails tell erro
		if not success then
			warn("[AI_NPC] HTTP Request failed with error:", response)
			Chat:Chat(Head, "Bağlantı hatası oluştu.", Enum.ChatColor.Red)
			return
		end
		
		-- check if is sucesss
		if not response.Success then
			warn("[AI_NPC] API returned HTTP error status:", response.StatusCode)
			warn("[AI_NPC] Response body:", response.Body)
			Chat:Chat(Head, "API hatası: " .. tostring(response.StatusCode), Enum.ChatColor.Red)
			return
		end
		
		print("[AI_NPC] API Response received successfully. Decoding...")
		-- decod json bak to table
		local decodeSuccess, decodedBody = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		
		-- check if it has stuff in it
		if decodeSuccess and decodedBody.candidates and decodedBody.candidates[1] then
			local rawText = decodedBody.candidates[1].content.parts[1].text
			-- parse the inner json
			local parseSuccess, parsedData = pcall(function()
				return HttpService:JSONDecode(rawText)
			end)
			
			-- if it workd update the stats
			if parseSuccess and parsedData.action and parsedData.reply then
				self:AddHistory(player, "model", parsedData.reply) -- add to bot reply
				Chat:Chat(Head, parsedData.reply, Enum.ChatColor.White) -- make the bubbles
				
				-- decids wat to do on action
				if parsedData.action == "FOLLOW" then
					self:FollowPlayer(player)
				elseif parsedData.action == "STOP" then
					self:Stop()
				end
				return
			end
		end
		-- if fails say nothing
		Chat:Chat(Head, "Anlayamadım.", Enum.ChatColor.Blue)
	end)
end

-- makes main systm
local npcInstance = AI_NPC.new()

-- when plyer joins
Players.PlayerAdded:Connect(function(player)
	-- whn pleyer chats
	player.Chatted:Connect(function(message)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		-- look at plyer who chats
		if root then
			npcInstance.LookTarget = root.Position
		end
		
		-- send ths msg to th api
		npcInstance:ProcessPlayerMessage(player, message)
	end)
end)
