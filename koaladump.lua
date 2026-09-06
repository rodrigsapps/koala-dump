--[[
	██╗  ██╗ ██████╗  █████╗ ██╗      █████╗     ██████╗ ██╗   ██╗███╗   ███╗██████╗
	██║ ██╔╝██╔═══██╗██╔══██╗██║     ██╔══██╗    ██╔══██╗██║   ██║████╗ ████║██╔══██╗
	█████╔╝ ██║   ██║███████║██║     ███████║    ██║  ██║██║   ██║██╔████╔██║██████╔╝
	██╔═██╗ ██║   ██║██╔══██║██║     ██╔══██║    ██║  ██║██║   ██║██║╚██╔╝██║██╔═══╝
	██║  ██╗╚██████╔╝██║  ██║███████╗██║  ██║    ██████╔╝╚██████╔╝██║ ╚═╝ ██║██║
	╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝

	KOALA DUMP — Remote Scanner + Spy + Webhook
	UI: WindUI (Footagesus)

	O que ele faz:
	  1. SCAN  — varre o jogo inteiro atras de RemoteEvent / RemoteFunction /
	     BindableEvent / BindableFunction / UnreliableRemoteEvent e lista tudo.
	  2. SPY   — hook em __namecall + __index + firesignal: registra TODA
	     chamada de remote (nome, caminho, argumentos, origem) em tempo real.
	  3. DUMP  — gera um arquivo .lua com todo o resultado e envia pro seu
	     Discord via webhook (como anexo de arquivo). Tambem copia pro
	     clipboard e salva com writefile() quando disponivel.

	Privacidade: o webhook fica salvo so na SUA sessao/arquivo local.
	O dump vai para o webhook que VOCE configurar na aba Webhook.
]]

----------------------------------------------------------------------
-- BOOT / SINGLETON
----------------------------------------------------------------------
if _G.KOALA_DUMP_LOADED and _G.KOALA_DUMP_DESTROY then
	pcall(_G.KOALA_DUMP_DESTROY)
end
_G.KOALA_DUMP_LOADED = true

local function try(f, ...)
	local ok, r = pcall(f, ...)
	if ok then return r end
	return nil
end

----------------------------------------------------------------------
-- SERVICOS
----------------------------------------------------------------------
local cloneref = (cloneref or clonereference or function(i) return i end)

local Players           = cloneref(game:GetService("Players"))
local RunService        = cloneref(game:GetService("RunService"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local StarterGui        = cloneref(game:GetService("StarterGui"))
local HttpService       = cloneref(game:GetService("HttpService"))
local Workspace         = cloneref(game:GetService("Workspace"))

local LP = Players.LocalPlayer

local setclipboard = (setclipboard or toclipboard or function() end)
local writefile    = (writefile or function() end)
local readfile     = (readfile or function() return nil end)
local isfile       = (isfile or function() return false end)

----------------------------------------------------------------------
-- CARREGAR WINDUI
----------------------------------------------------------------------
local WindUI
do
	local sources = {
		"https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
		"https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",
	}
	for _, url in ipairs(sources) do
		local src = try(function() return game:HttpGet(url) end)
		if type(src) == "string" and #src > 5000 then
			local fn = (loadstring or load)(src)
			if fn then
				local ok, lib = pcall(fn)
				if ok and type(lib) == "table" and lib.CreateWindow then
					WindUI = lib
					break
				end
			end
		end
	end
end

if not WindUI then
	try(function()
		StarterGui:SetCore("SendNotification", {
			Title = "KOALA DUMP",
			Text = "Falha ao baixar a WindUI. Verifique sua internet.",
			Duration = 8,
		})
	end)
	warn("[KOALA DUMP] WindUI nao carregou.")
	return
end

----------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------
local CFG = {
	Webhook      = "",
	ScanOnStart  = true,
	SpyOnStart   = false,    -- spy NAO liga sozinho: hook em __namecall pode causar kick
	MaxLog       = 2000,     -- max de eventos guardados
	SpyUIUpdate  = 0.5,      -- s entre updates da UI do spy (throttle)
	MaxArgLen    = 400,      -- corta argumento gigante
	LogBindables = false,    -- bindables sao locais; off por padrao
	IgnoreList   = {         -- padroes ignorados no spy (anti-spam)
		"CharacterSound",
		"DefaultServerSoundEvent",
		"SayMessageRequest",
	},
}

-- webhook salvo localmente (persiste entre sessoes no executor)
local CFG_FILE = "koala_dump_webhook.txt"
try(function()
	if isfile(CFG_FILE) then
		local w = readfile(CFG_FILE)
		if type(w) == "string" and w:match("^https://") then
			CFG.Webhook = w:gsub("%s+", "")
		end
	end
end)

----------------------------------------------------------------------
-- CORES
----------------------------------------------------------------------
local ACCENT = Color3.fromHex("#22D3EE")
local GREEN  = Color3.fromHex("#22C55E")
local RED    = Color3.fromHex("#EF4444")
local YELLOW = Color3.fromHex("#EAB308")
local PURPLE = Color3.fromHex("#A78BFA")
local GRAY   = Color3.fromHex("#9CA3AF")

----------------------------------------------------------------------
-- ESTADO
----------------------------------------------------------------------
local Remotes = {}      -- [path] = {class, path, name}
local SpyLog  = {}      -- lista de strings (eventos)
local SpyCount = 0
local RemoteCount = 0
local SpyOn = false
local ScanDone = false

local StatusFn = function() end
local LogFn    = function() end

----------------------------------------------------------------------
-- SERIALIZADOR (valor -> lua legivel)
----------------------------------------------------------------------
local function isIdent(s)
	return type(s) == "string" and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local ser
ser = function(v, depth)
	depth = depth or 0
	if depth > 6 then return "..." end

	local t = typeof(v)

	if t == "string" then
		if #v > CFG.MaxArgLen then
			v = v:sub(1, CFG.MaxArgLen) .. "...<" .. #v .. " chars>"
		end
		return string.format("%q", v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "nil" then
		return "nil"
	elseif t == "Instance" then
		return 'game:GetService("' .. v:GetFullName():gsub('"', '\\"') .. '")'
	elseif t == "Vector3" then
		return ("Vector3.new(%s, %s, %s)"):format(v.X, v.Y, v.Z)
	elseif t == "Vector2" then
		return ("Vector2.new(%s, %s)"):format(v.X, v.Y)
	elseif t == "CFrame" then
		local c = {v:GetComponents()}
		local parts = {}
		for i = 1, #c do parts[i] = tostring(math.floor(c[i] * 1000 + 0.5) / 1000) end
		return ("CFrame.new(%s)"):format(table.concat(parts, ", "))
	elseif t == "Color3" then
		return ("Color3.new(%s, %s, %s)"):format(
			math.floor(v.R * 1000 + 0.5) / 1000,
			math.floor(v.G * 1000 + 0.5) / 1000,
			math.floor(v.B * 1000 + 0.5) / 1000)
	elseif t == "BrickColor" then
		return ('BrickColor.new("%s")'):format(tostring(v))
	elseif t == "EnumItem" then
		return tostring(v)
	elseif t == "UDim2" then
		return ("UDim2.new(%s, %s, %s, %s)"):format(
			v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
	elseif t == "UDim" then
		return ("UDim.new(%s, %s)"):format(v.Scale, v.Offset)
	elseif t == "NumberRange" then
		return ("NumberRange.new(%s, %s)"):format(v.Min, v.Max)
	elseif t == "NumberSequence" then
		return "NumberSequence.new(...)"
	elseif t == "ColorSequence" then
		return "ColorSequence.new(...)"
	elseif t == "Rect" then
		return ("Rect.new(%s, %s, %s, %s)"):format(v.Min.X, v.Min.Y, v.Max.X, v.Max.Y)
	elseif t == "table" then
		local n = 0
		for _ in pairs(v) do n = n + 1 end
		if n == 0 then return "{}" end
		if n > 60 then return "{ --[[" .. n .. " itens]] }" end

		local isArr = true
		for k in pairs(v) do
			if type(k) ~= "number" then isArr = false break end
		end

		local parts = {}
		if isArr then
			for i = 1, n do
				parts[#parts + 1] = ser(v[i], depth + 1)
			end
		else
			for k, val in pairs(v) do
				local key
				if isIdent(k) then
					key = k .. " = "
				elseif type(k) == "number" then
					key = "[" .. k .. "] = "
				else
					key = "[" .. ser(k, depth + 1) .. "] = "
				end
				parts[#parts + 1] = key .. ser(val, depth + 1)
			end
			table.sort(parts)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif t == "function" then
		return "function() --[[?]] end"
	else
		return "--[[" .. t .. "]]"
	end
end

local function fmtArgs(args)
	local n = #args
	if n == 0 then return "" end
	local parts = {}
	for i = 1, n do
		parts[i] = try(function() return ser(args[i]) end) or "--[[erro]]"
	end
	return table.concat(parts, ", ")
end

----------------------------------------------------------------------
-- HELPERS DE REMOTE
----------------------------------------------------------------------
local REMOTE_CLASSES = {
	RemoteEvent = true,
	RemoteFunction = true,
	UnreliableRemoteEvent = true,
	BindableEvent = true,
	BindableFunction = true,
}

local function isRemote(inst)
	return inst and REMOTE_CLASSES[inst.ClassName] == true
end

local function fullPath(inst)
	local ok, p = pcall(function() return inst:GetFullName() end)
	if ok then return p end
	return tostring(inst)
end

local function ignored(name)
	for _, pat in ipairs(CFG.IgnoreList) do
		if name:find(pat, 1, true) then return true end
	end
	return false
end

----------------------------------------------------------------------
-- SCAN
----------------------------------------------------------------------
local scanning = false
local function scanRemotes()
	if scanning then return RemoteCount end
	scanning = true
	Remotes = {}
	RemoteCount = 0

	-- em lotes: varrer o jogo inteiro de uma vez trava o cliente (kick)
	local desc = try(function() return game:GetDescendants() end) or {}
	local total = #desc
	for i, inst in ipairs(desc) do
		if isRemote(inst) then
			local p = fullPath(inst)
			if not Remotes[p] then
				Remotes[p] = {
					Class = inst.ClassName,
					Path = p,
					Name = inst.Name,
				}
				RemoteCount = RemoteCount + 1
			end
		end
		if i % 3000 == 0 then
			StatusFn(("Escaneando... %d/%d (%d remotes)"):format(i, total, RemoteCount), YELLOW)
			task.wait()
		end
	end

	ScanDone = true
	scanning = false
	StatusFn(("Scan: %d remotes encontrados"):format(RemoteCount), GREEN)
	return RemoteCount
end

-- pega remotes que nascem depois (streaming / load tardio)
local addedConn
local function watchNewRemotes()
	if addedConn then pcall(function() addedConn:Disconnect() end) end
	addedConn = try(function()
		return game.DescendantAdded:Connect(function(inst)
			if isRemote(inst) then
				local p = fullPath(inst)
				if not Remotes[p] then
					Remotes[p] = { Class = inst.ClassName, Path = p, Name = inst.Name }
					RemoteCount = RemoteCount + 1
					if ScanDone then
						StatusFn(("Scan: %d remotes (+%s)"):format(RemoteCount, inst.Name), GREEN)
					end
				end
			end
		end)
	end)
end

----------------------------------------------------------------------
-- SPY
----------------------------------------------------------------------
-- throttle da UI: serializar argumentos e atualizar Paragraph a cada
-- chamada de remote trava o cliente. Loga direto, UI atualiza em lote.
local uiDirty = false
local lastUI = 0

local function pushLog(line)
	SpyCount = SpyCount + 1
	SpyLog[#SpyLog + 1] = line
	if #SpyLog > CFG.MaxLog then
		table.remove(SpyLog, 1)
	end
	uiDirty = true
	local now = os.clock()
	if now - lastUI >= CFG.SpyUIUpdate then
		lastUI = now
		uiDirty = false
		try(LogFn, line)
	end
end

-- loop que garante flush do restante do log pra UI
task.spawn(function()
	while true do
		task.wait(CFG.SpyUIUpdate)
		if uiDirty and SpyOn then
			uiDirty = false
			lastUI = os.clock()
			try(LogFn, SpyLog[#SpyLog] or "")
		end
	end
end)

local function logRemoteCall(kind, inst, args, origin)
	if not SpyOn then return end
	if not inst then return end
	if not CFG.LogBindables and (inst.ClassName == "BindableEvent" or inst.ClassName == "BindableFunction") then
		return
	end
	if ignored(inst.Name) then return end

	local path = fullPath(inst)
	local argStr = try(fmtArgs, args) or "--[[erro ao serializar]]"
	local line = ("-- [%s] %s\n%s:%s(%s)"):format(
		kind,
		origin or "?",
		path,
		(inst.ClassName == "RemoteFunction" and "InvokeServer")
			or (inst.ClassName == "BindableFunction" and "Invoke")
			or (inst.ClassName == "BindableEvent" and "Fire")
			or "FireServer",
		argStr
	)
	pushLog(line)
end

-- hook __namecall
local hooked = false
local oldNamecall

-- dentro do hook: rapido e sem falhar. SEM task.spawn — uma thread por
-- chamada de remote derruba o cliente.
local function hookSpy()
	if hooked then return true end

	-- caminho 1 (preferido): hookmetamethod — mais seguro e estavel
	if hookmetamethod then
		oldNamecall = try(function()
			return hookmetamethod(game, "__namecall", newcclosure and newcclosure(function(self, ...)
				if SpyOn and not checkcaller() and isRemote(self) then
					local method = try(getnamecallmethod) or ""
					if method == "FireServer" or method == "InvokeServer"
						or method == "Fire" or method == "Invoke" then
						try(logRemoteCall, "namecall", self, { ... }, method)
					end
				end
				return oldNamecall(self, ...)
			end) or function(self, ...)
				if SpyOn and not checkcaller() and isRemote(self) then
					local method = try(getnamecallmethod) or ""
					if method == "FireServer" or method == "InvokeServer"
						or method == "Fire" or method == "Invoke" then
						try(logRemoteCall, "namecall", self, { ... }, method)
					end
				end
				return oldNamecall(self, ...)
			end)
		end)
		if oldNamecall then
			hooked = true
			return true
		end
	end

	-- caminho 2 (fallback): getrawmetatable + setreadonly
	local mt = try(function() return getrawmetatable(game) end)
	if not mt then
		StatusFn("Spy: executor sem hookmetamethod/getrawmetatable", RED)
		return false
	end

	try(function() setreadonly(mt, false) end)
	oldNamecall = mt.__namecall
	if not oldNamecall then
		StatusFn("Spy: __namecall nao encontrado", RED)
		return false
	end

	local function handler(self, ...)
		if SpyOn and isRemote(self) then
			local method = try(getnamecallmethod) or ""
			if method == "FireServer" or method == "InvokeServer"
				or method == "Fire" or method == "Invoke" then
				try(logRemoteCall, "namecall", self, { ... }, method)
			end
		end
		return oldNamecall(self, ...)
	end

	mt.__namecall = newcclosure and newcclosure(handler) or handler
	try(function() setreadonly(mt, true) end)
	hooked = true
	return true
end

local function setSpy(on)
	SpyOn = on
	if on then
		local ok = hookSpy()
		if ok then
			StatusFn("Spy LIGADO — registrando chamadas", GREEN)
		else
			SpyOn = false
			StatusFn("Spy FALHOU — executor sem suporte a hook", RED)
		end
	else
		StatusFn("Spy DESLIGADO", YELLOW)
	end
end

----------------------------------------------------------------------
-- GERAR DUMP (arquivo .lua)
----------------------------------------------------------------------
local function buildDump()
	local L = {}
	local function w(s) L[#L + 1] = s end

	w("--[[")
	w("\tKOALA DUMP")
	w(("\tJogo: %s"):format(try(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name end) or "PlaceId " .. game.PlaceId))
	w(("\tPlaceId: %d  |  JobId: %s"):format(game.PlaceId, tostring(game.JobId)))
	w(("\tPlayer: %s (%d)"):format(LP.Name, LP.UserId))
	w(("\tData: %s"):format(os.date("!%Y-%m-%d %H:%M:%S UTC")))
	w(("\tRemotes: %d  |  Eventos de spy: %d"):format(RemoteCount, SpyCount))
	w("]]")
	w("")
	w("local dump = {")
	w("\tRemotes = {")

	-- remotes ordenados por caminho
	local paths = {}
	for p in pairs(Remotes) do paths[#paths + 1] = p end
	table.sort(paths)

	for _, p in ipairs(paths) do
		local r = Remotes[p]
		w(("\t\t[%s] = { Class = %q, Name = %q },"):format(
			string.format("%q", r.Path), r.Class, r.Name))
	end
	w("\t},")
	w("")
	w("\tSpyLog = {")
	for _, line in ipairs(SpyLog) do
		w(("\t\t%s,"):format(string.format("%q", line)))
	end
	w("\t},")
	w("}")
	w("")
	w("return dump")
	w("")
	w("--[[")
	w("\t================ SPY LOG (legivel) ================")
	for _, line in ipairs(SpyLog) do
		for l in tostring(line):gmatch("[^\n]+") do
			w("\t" .. l)
		end
	end
	w("]]")

	return table.concat(L, "\n")
end

----------------------------------------------------------------------
-- ENVIAR PRO WEBHOOK (arquivo anexo)
----------------------------------------------------------------------
local httpRequest = (syn and syn.request)
	or (http and http.request)
	or http_request
	or (fluxus and fluxus.request)
	or request

local function sendToWebhook(content, filename)
	if CFG.Webhook == "" or not CFG.Webhook:match("^https://") then
		StatusFn("Configure o webhook primeiro!", RED)
		try(function()
			WindUI:Notify({
				Title = "KOALA DUMP",
				Content = "Webhook nao configurado. Va na aba Webhook.",
				Icon = "alert-triangle",
				Duration = 5,
			})
		end)
		return false
	end

	if not httpRequest then
		StatusFn("Executor sem funcao de request HTTP", RED)
		return false
	end

	StatusFn("Enviando pro Discord...", YELLOW)

	local boundary = "----KOALA" .. tostring(math.random(1e8, 1e9))
	local payloadJson = HttpService:JSONEncode({
		username = "KOALA DUMP",
		content = ("**Dump pronto** — %d remotes, %d eventos de spy"):format(RemoteCount, SpyCount),
	})

	local body = table.concat({
		"--" .. boundary,
		'Content-Disposition: form-data; name="payload_json"',
		"Content-Type: application/json",
		"",
		payloadJson,
		"--" .. boundary,
		'Content-Disposition: form-data; name="file"; filename="' .. filename .. '"',
		"Content-Type: text/plain",
		"",
		content,
		"--" .. boundary .. "--",
		"",
	}, "\r\n")

	local ok, res = pcall(function()
		return httpRequest({
			Url = CFG.Webhook,
			Method = "POST",
			Headers = {
				["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
			},
			Body = body,
		})
	end)

	if ok and res and (res.StatusCode == 200 or res.StatusCode == 204) then
		StatusFn("Enviado pro Discord!", GREEN)
		try(function()
			WindUI:Notify({
				Title = "KOALA DUMP",
				Content = "Dump enviado pro webhook.",
				Icon = "check",
				Duration = 4,
			})
		end)
		return true
	else
		local code = (res and res.StatusCode) or "?"
		StatusFn("Falha no envio (HTTP " .. tostring(code) .. ")", RED)
		return false
	end
end

----------------------------------------------------------------------
-- ACOES
----------------------------------------------------------------------
local function doDump()
	if not ScanDone then scanRemotes() end
	StatusFn("Gerando dump...", YELLOW)

	local content = buildDump()
	local filename = ("koala_dump_%d_%s.lua"):format(
		game.PlaceId, os.date("!%Y%m%d_%H%M%S"))

	-- salva local
	try(function() writefile(filename, content) end)

	-- copia
	try(function() setclipboard(content) end)

	-- manda pro webhook
	task.spawn(function()
		local ok = sendToWebhook(content, filename)
		if ok then
			StatusFn(("Dump enviado (%d remotes, %d eventos)"):format(RemoteCount, SpyCount), GREEN)
		end
	end)
end

----------------------------------------------------------------------
-- UI (WindUI)
----------------------------------------------------------------------
local Window = WindUI:CreateWindow({
	Title = "KOALA DUMP",
	Icon = "radar",
	Author = "Remote Scanner + Spy",
	Folder = "KoalaDump",
	Size = UDim2.fromOffset(600, 420),
	Theme = "Dark",
	Transparent = true,
	NewElements = true,
	HideSearchBar = false,
	Resizable = true,
	SideBarWidth = 190,
	Background = "",
	OpenButton = {
		Title = "KOALA",
		Enabled = true,
		Draggable = true,
		OnlyMobile = false,
		CornerRadius = UDim.new(1, 0),
		StrokeThickness = 2,
		Color = ColorSequence.new(Color3.fromHex("#22D3EE"), Color3.fromHex("#A78BFA")),
	},
	Topbar = { Height = 44, ButtonsType = "Mac" },
})

try(function()
	Window:Tag({ Title = "v1.0", Icon = "github", Color = Color3.fromHex("#1c1c1c"), Border = true })
	Window:Tag({ Title = "SPY", Icon = "radar", Color = PURPLE, Border = true })
end)

local SecMain = Window:Section({ Title = "Principal" })
local SecCfg  = Window:Section({ Title = "Config" })

----------------------------------------------------------------------
-- TAB: SCAN
----------------------------------------------------------------------
local TabScan = SecMain:Tab({
	Title = "Scan",
	Desc = "Varre o jogo atras de remotes",
	Icon = "search",
	IconColor = ACCENT,
	IconShape = "Square",
	Border = true,
})

local StatusPar = TabScan:Paragraph({
	Title = "Status",
	Desc = "Aguardando...",
	Icon = "info",
})

StatusFn = function(text, color)
	try(function() StatusPar:SetDesc(text) end)
end

TabScan:Button({
	Title = "Escanear agora",
	Desc = "Procura todos os RemoteEvent / RemoteFunction / Bindable do jogo",
	Icon = "radar",
	Callback = function()
		StatusFn("Escaneando...", YELLOW)
		task.spawn(function()
			local n = scanRemotes()
			try(function()
				WindUI:Notify({
					Title = "KOALA DUMP",
					Content = ("%d remotes encontrados"):format(n),
					Icon = "check",
					Duration = 4,
				})
			end)
		end)
	end,
})

TabScan:Toggle({
	Title = "Scan ao iniciar",
	Desc = "Roda o scan automaticamente quando o script carrega",
	Value = CFG.ScanOnStart,
	Callback = function(v) CFG.ScanOnStart = v end,
})

local RemoteListPar = TabScan:Paragraph({
	Title = "Remotes",
	Desc = "Rode o scan para listar",
	Icon = "list",
})

TabScan:Button({
	Title = "Listar remotes",
	Desc = "Mostra os remotes encontrados (no console F9)",
	Icon = "terminal",
	Callback = function()
		if not ScanDone then scanRemotes() end
		local paths = {}
		for p in pairs(Remotes) do paths[#paths + 1] = p end
		table.sort(paths)
		print("===== KOALA DUMP — REMOTES (" .. #paths .. ") =====")
		for _, p in ipairs(paths) do
			print(("[%s] %s"):format(Remotes[p].Class, p))
		end
		print("==================================================")
		RemoteListPar:SetDesc(("%d remotes — veja o console (F9)"):format(#paths))
	end,
})

----------------------------------------------------------------------
-- TAB: SPY
----------------------------------------------------------------------
local TabSpy = SecMain:Tab({
	Title = "Spy",
	Desc = "Registra chamadas de remote em tempo real",
	Icon = "eye",
	IconColor = PURPLE,
	IconShape = "Square",
	Border = true,
})

local SpyStatusPar = TabSpy:Paragraph({
	Title = "Spy",
	Desc = "Desligado",
	Icon = "eye-off",
})

local lastLines = {}
LogFn = function(line)
	lastLines[#lastLines + 1] = line
	if #lastLines > 8 then table.remove(lastLines, 1) end
	try(function()
		SpyStatusPar:SetDesc(("Eventos: %d\n\n%s"):format(SpyCount, table.concat(lastLines, "\n\n")))
	end)
end

TabSpy:Toggle({
	Title = "Spy ligado",
	Desc = "Registra FireServer / InvokeServer. ATENCAO: hook pode causar kick em jogos com anti-cheat — ligue so quando for usar",
	Value = CFG.SpyOnStart,
	Callback = function(v) setSpy(v) end,
})

TabSpy:Toggle({
	Title = "Spy ao iniciar",
	Desc = "Liga o spy automaticamente quando o script carrega",
	Value = CFG.SpyOnStart,
	Callback = function(v) CFG.SpyOnStart = v end,
})

TabSpy:Toggle({
	Title = "Incluir Bindables",
	Desc = "BindableEvent/Function sao locais (nao vao pro servidor). Off = menos spam",
	Value = CFG.LogBindables,
	Callback = function(v) CFG.LogBindables = v end,
})

TabSpy:Button({
	Title = "Limpar log do spy",
	Desc = "Apaga todos os eventos registrados",
	Icon = "trash-2",
	Callback = function()
		SpyLog = {}
		SpyCount = 0
		lastLines = {}
		SpyStatusPar:SetDesc("Log limpo. Eventos: 0")
		StatusFn("Log do spy limpo", GRAY)
	end,
})

TabSpy:Button({
	Title = "Copiar log do spy",
	Desc = "Copia todos os eventos pro clipboard",
	Icon = "copy",
	Callback = function()
		local txt = table.concat(SpyLog, "\n\n")
		try(function() setclipboard(txt) end)
		StatusFn(("Copiado (%d eventos)"):format(SpyCount), GREEN)
	end,
})

----------------------------------------------------------------------
-- TAB: DUMP
----------------------------------------------------------------------
local TabDump = SecMain:Tab({
	Title = "Dump",
	Desc = "Gera o arquivo e manda pro Discord",
	Icon = "download",
	IconColor = GREEN,
	IconShape = "Square",
	Border = true,
})

TabDump:Paragraph({
	Title = "Como funciona",
	Desc = "1) Rode o Scan\n2) Deixe o Spy ligado enquanto joga (ele registra tudo)\n3) Clique em 'Gerar e enviar' — o arquivo .lua vai pro seu Discord",
	Icon = "help-circle",
})

TabDump:Button({
	Title = "Gerar e enviar dump",
	Desc = "Cria o .lua com remotes + spy log e manda pro webhook",
	Icon = "send",
	Callback = function() doDump() end,
})

TabDump:Button({
	Title = "So salvar local",
	Desc = "Gera o arquivo mas NAO envia (salva com writefile + clipboard)",
	Icon = "save",
	Callback = function()
		if not ScanDone then scanRemotes() end
		local content = buildDump()
		local filename = ("koala_dump_%d_%s.lua"):format(game.PlaceId, os.date("!%Y%m%d_%H%M%S"))
		try(function() writefile(filename, content) end)
		try(function() setclipboard(content) end)
		StatusFn(("Salvo local: %s"):format(filename), GREEN)
	end,
})

----------------------------------------------------------------------
-- TAB: WEBHOOK
----------------------------------------------------------------------
local TabHook = SecCfg:Tab({
	Title = "Webhook",
	Desc = "Configura o Discord",
	Icon = "link",
	IconColor = YELLOW,
	IconShape = "Square",
	Border = true,
})

local HookStatusPar = TabHook:Paragraph({
	Title = "Webhook atual",
	Desc = (CFG.Webhook ~= "" and ("Configurado: " .. CFG.Webhook:sub(1, 48) .. "...")) or "Nao configurado",
	Icon = "webhook",
})

TabHook:Input({
	Title = "URL do webhook",
	Desc = "Cole a URL do webhook do seu canal do Discord",
	Placeholder = "https://discord.com/api/webhooks/...",
	Value = CFG.Webhook,
	ClearTextOnFocus = false,
	Callback = function(v)
		v = tostring(v or ""):gsub("%s+", "")
		CFG.Webhook = v
		try(function() writefile(CFG_FILE, v) end)
		if v:match("^https://") then
			HookStatusPar:SetDesc("Configurado: " .. v:sub(1, 48) .. "...")
			StatusFn("Webhook salvo", GREEN)
		else
			HookStatusPar:SetDesc("URL invalida")
			StatusFn("URL invalida", RED)
		end
	end,
})

TabHook:Button({
	Title = "Testar webhook",
	Desc = "Manda uma mensagem de teste pro canal",
	Icon = "zap",
	Callback = function()
		task.spawn(function()
			local ok = sendToWebhook("-- KOALA DUMP teste de webhook\n-- Se voce recebeu isso, esta funcionando.", "koala_teste.txt")
			if ok then StatusFn("Webhook OK!", GREEN) end
		end)
	end,
})

----------------------------------------------------------------------
-- TAB: SOBRE
----------------------------------------------------------------------
local TabAbout = SecCfg:Tab({
	Title = "Sobre",
	Desc = "Info e diagnostico",
	Icon = "info",
	IconColor = GRAY,
	IconShape = "Square",
	Border = true,
})

TabAbout:Paragraph({
	Title = "KOALA DUMP v1.0",
	Desc = "Scanner de remotes + spy + export via webhook.\n\nO spy usa hook em __namecall (getrawmetatable). Se o seu executor nao tiver essa funcao, o scan ainda funciona, mas o spy nao registra chamadas.",
	Icon = "radar",
})

TabAbout:Button({
	Title = "Diagnostico",
	Desc = "Testa as funcoes do executor (console F9)",
	Icon = "stethoscope",
	Callback = function()
		print("===== KOALA DUMP — DIAGNOSTICO =====")
		print("getrawmetatable:", getrawmetatable ~= nil)
		print("getnamecallmethod:", getnamecallmethod ~= nil)
		print("newcclosure:", newcclosure ~= nil)
		print("setclipboard:", setclipboard ~= nil)
		print("writefile:", writefile ~= nil)
		print("httpRequest:", httpRequest ~= nil)
		print("hookmetamethod:", hookmetamethod ~= nil)
		print("getconnections:", getconnections ~= nil)
		print("firesignal:", firesignal ~= nil)
		print("Remotes:", RemoteCount)
		print("Spy eventos:", SpyCount)
		print("====================================")
		StatusFn("Diagnostico no console (F9)", ACCENT)
	end,
})

TabAbout:Button({
	Title = "Fechar KOALA DUMP",
	Desc = "Remove a UI e desliga o spy",
	Icon = "power",
	Callback = function()
		if _G.KOALA_DUMP_DESTROY then _G.KOALA_DUMP_DESTROY() end
	end,
})

----------------------------------------------------------------------
-- DESTROY
----------------------------------------------------------------------
_G.KOALA_DUMP_DESTROY = function()
	SpyOn = false
	if addedConn then pcall(function() addedConn:Disconnect() end) end
	-- desfaz o hook so se foi feito via getrawmetatable (hookmetamethod
	-- nao precisa: o handler checa SpyOn, que ja esta false)
	if oldNamecall and getrawmetatable and not hookmetamethod then
		pcall(function()
			local mt = getrawmetatable(game)
			setreadonly(mt, false)
			mt.__namecall = oldNamecall
			setreadonly(mt, true)
		end)
	end
	pcall(function() Window:Destroy() end)
	_G.KOALA_DUMP_LOADED = false
	_G.KOALA_DUMP_DESTROY = nil
end

----------------------------------------------------------------------
-- START
----------------------------------------------------------------------
watchNewRemotes()

if CFG.ScanOnStart then
	task.spawn(function()
		task.wait(0.5)
		scanRemotes()
	end)
end

if CFG.SpyOnStart then
	task.spawn(function()
		task.wait(0.8)
		setSpy(true)
	end)
end

try(function()
	WindUI:Notify({
		Title = "KOALA DUMP",
		Content = "Carregado. Scan rodando. Ligue o Spy na aba Spy quando quiser.",
		Icon = "radar",
		Duration = 4,
	})
end)

StatusFn("KOALA DUMP pronto", GREEN)
