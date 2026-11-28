--[[
    STR Translator - MonetLoader Android (SA-MP)
    Port Android dari script MoonLoader PC.
    Target: MonetLoader 3.8.0 + libstd (SAMP.Lua, mimgui, encoding, ffi, effil, requests, ssl).
    Simpan file di folder monetloader/scripts.
    Penerjemah chat otomatis pakai AI: Gemini (utama) -> Groq (cadangan).

    Perintah:
      /str        buka / tutup menu
      /str on     nyalakan penerjemah
      /str off    matikan penerjemah  (/str of juga bisa)
]]

script_name('STR Translator')
script_author('bobwan-pixel')
script_version('1.1-android')
script_version_number(2)
script_description('Gemini -> Groq automatic fallback chat translator for MonetLoader Android')

-- MonetLoader provides MoonLoader-compatible globals; SAMP.Lua uses this module path.
local sampev   = require 'samp.events'
local imgui    = require 'mimgui'
local encoding = require 'encoding'
local effil    = require 'effil'
local ffi      = require 'ffi'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local new, ffistr, sizeof = imgui.new, ffi.string, ffi.sizeof

-- =========================================================================
-- Bahasa
-- =========================================================================
local LANGS = {
    { label = 'Indonesia',        name = 'Indonesian' },
    { label = 'Inggris',          name = 'English' },
    { label = 'Melayu',           name = 'Malay' },
    { label = 'Filipina',         name = 'Filipino (Tagalog)' },
    { label = 'Spanyol',          name = 'Spanish' },
    { label = 'Portugis',         name = 'Portuguese' },
    { label = 'Prancis',          name = 'French' },
    { label = 'Jerman',           name = 'German' },
    { label = 'Italia',           name = 'Italian' },
    { label = 'Belanda',          name = 'Dutch' },
    { label = 'Turki',            name = 'Turkish' },
    { label = 'Polandia',         name = 'Polish' },
    { label = 'Rusia',            name = 'Russian' },
    -- gaya bahasa (ditaruh di akhir supaya pilihan lama di config tidak bergeser)
    { label = 'Inggris slang jalanan US', name = 'English',
      style = 'Write it like casual American street slang / hood talk (words like bro, ain\'t, finna, y\'all, deadass, lowkey, fr, cuz), the way young people talk on the streets in the US. Keep it natural and easy to understand, do not overdo it.' },
    { label = 'Spanyol Meksiko (slang)', name = 'Mexican Spanish',
      style = 'Write it like casual Mexican street Spanish with Mexican slang (words like wey, neta, chido, que onda, orale, carnal, no manches), the way people talk on the streets in Mexico. Keep it natural, do not overdo it.' },
}
local langLabels = {}
for i, l in ipairs(LANGS) do langLabels[i] = l.label end

-- =========================================================================
-- Konfigurasi
-- =========================================================================
local CFG_DIR  = getWorkingDirectory() .. '/config'
local CFG_PATH = CFG_DIR .. '/str_translator.json'

local cfg = {
    enabled          = true,
    translate_out    = true,    -- terjemahkan pesan yang aku ketik
    translate_in     = true,    -- terjemahkan pesan lawan bicara
    translate_server = true,    -- baca chat dari pesan server (format "Nama says: ...")
    translate_cmds   = false,   -- terjemahkan juga perintah seperti /b /s /low
    cmd_list         = 'b,s,low,shout,me,do',
    out_lang         = 2,       -- index LANGS (1-based) -> Inggris
    in_lang          = 1,       -- index LANGS (1-based) -> Indonesia
    raw_prefix       = '.',     -- awali pesan dengan ini untuk kirim TANPA diterjemahkan
    min_letters      = 3,
    gemini_key       = '',
    gemini_model     = 'gemini-3.5-flash-lite',
    groq_key         = '',
    groq_model       = 'openai/gpt-oss-120b',
}

local function loadCfg()
    if not doesFileExist(CFG_PATH) then return end
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    local raw = f:read('*a')
    f:close()
    local ok, t = pcall(decodeJson, raw)
    if ok and type(t) == 'table' then
        for k, v in pairs(t) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    end
    cfg.gemini_key = cfg.gemini_key:gsub('%s', '')
    cfg.groq_key = cfg.groq_key:gsub('%s', '')
    -- model Groq lama yang sudah dimatikan -> ganti otomatis
    local deadGroq = { ['llama-3.3-70b-versatile'] = false, ['llama-3.1-8b-instant'] = true,
                       ['qwen/qwen3-32b'] = true, ['meta-llama/llama-4-scout-17b-16e-instruct'] = true }
    if deadGroq[cfg.groq_model] then cfg.groq_model = 'openai/gpt-oss-120b' end
    if not LANGS[cfg.out_lang] then cfg.out_lang = 2 end
    if not LANGS[cfg.in_lang] then cfg.in_lang = 1 end
end

local function saveCfg()
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    local f = io.open(CFG_PATH, 'w')
    if f then
        f:write(encodeJson(cfg))
        f:close()
    end
end

local dirty = false
local function markDirty() dirty = true end

-- =========================================================================
-- Utilitas
-- =========================================================================
local TAG = '{66CCFF}[STR]{FFFFFF} '

local function notify(text)
    sampAddChatMessage(TAG .. text, -1)
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function countLetters(s)
    local n = 0
    for _ in s:gmatch('%a') do n = n + 1 end
    return n
end

-- Ubah teks UTF-8 dari AI menjadi teks yang aman untuk chat SA-MP (CP1251)
local UNICODE_FIX = {
    ['\226\128\152'] = "'", ['\226\128\153'] = "'",
    ['\226\128\156'] = '"', ['\226\128\157'] = '"',
    ['\226\128\166'] = '...',
    ['\226\128\147'] = '-', ['\226\128\148'] = '-',
    ['\194\160'] = ' ',
}
-- huruf beraksen Latin (U+00C0..U+00FF) -> huruf biasa, karena chat SA-MP (CP1251) tidak punya
local LATIN1 = {
    'A','A','A','A','A','A','AE','C','E','E','E','E','I','I','I','I',
    'D','N','O','O','O','O','O','x','O','U','U','U','U','Y','Th','ss',
    'a','a','a','a','a','a','ae','c','e','e','e','e','i','i','i','i',
    'd','n','o','o','o','o','o','/','o','u','u','u','u','y','th','y',
}
local function toGame(s)
    s = s:gsub('[\r\n]+', ' ')
    for k, v in pairs(UNICODE_FIX) do s = s:gsub(k, v) end
    s = s:gsub('\195([\128-\191])', function(c) return LATIN1[c:byte() - 127] end) -- ñ -> n, á -> a, dst
    s = s:gsub('\194[\161\191\176\170\186]', '') -- buang ¡ ¿ ° ª º
    s = s:gsub('[\240-\244][\128-\191][\128-\191][\128-\191]', '') -- buang emoji
    s = s:gsub('\239\184[\128-\143]', ''):gsub('\226\128[\139-\143]', '') -- variation selector / zero-width
    s = s:gsub('[%z\1-\31\127]', '') -- karakter kontrol
    s = s:gsub('%s%s+', ' ')
    s = trim(s)
    -- buang tanda kutip pembungkus kalau AI menambahkannya
    if #s >= 2 and s:sub(1, 1) == '"' and s:sub(-1) == '"' then s = trim(s:sub(2, -2)) end
    local ok, r = pcall(u8.decode, u8, s)
    if ok and type(r) == 'string' and r ~= '' then return r end
    return (s:gsub('[\128-\255]', ''))
end

local function toUtf8(s)
    local ok, r = pcall(u8, s)
    if ok and type(r) == 'string' then return r end
    return s
end

local function myName()
    local ok, res, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if ok and res then
        local ok2, nick = pcall(sampGetPlayerNickname, id)
        if ok2 then return nick end
    end
    return nil
end

local function isConnectedPlayer(name)
    name = name:gsub(' ', '_'):lower()
    for i = 0, 1003 do
        if sampIsPlayerConnected(i) then
            local nick = sampGetPlayerNickname(i)
            if nick and nick:lower() == name then return true end
        end
    end
    local me = myName()
    return me ~= nil and me:lower() == name
end

-- =========================================================================
-- HTTP async (effil thread + lua-requests)
-- =========================================================================
local function httpRequest(method, url, body, headerName, headerValue, cb)
    local runner = effil.thread(function(method, url, body, headerName, headerValue)
        local requests = require 'requests'
        local headers = { ['Content-Type'] = 'application/json' }
        headers[headerName] = headerValue
        local args = { headers = headers, timeout = 25 }
        if body ~= '' then args.data = body end
        local ok, res = pcall(requests.request, method, url, args)
        if not ok then return false, 0, tostring(res) end
        return true, tonumber(res.status_code) or 0, tostring(res.text or '')
    end)(method, url, body or '', headerName, headerValue)

    lua_thread.create(function()
        while true do
            local status, err = runner:status()
            if err then return cb(false, 0, 'thread error: ' .. tostring(err)) end
            if status == 'completed' then
                local ok, code, text = runner:get()
                return cb(ok, code, text)
            elseif status == 'canceled' or status == 'failed' then
                return cb(false, 0, 'thread ' .. tostring(status))
            end
            wait(0)
        end
    end)
end

local function httpPost(url, body, headerName, headerValue, cb)
    httpRequest('POST', url, body, headerName, headerValue, cb)
end

local function httpGet(url, headerName, headerValue, cb)
    httpRequest('GET', url, '', headerName, headerValue, cb)
end

local function apiErrorText(code, text)
    local ok, j = pcall(decodeJson, text)
    if ok and type(j) == 'table' then
        if type(j.error) == 'table' and j.error.message then
            return ('HTTP %d: %s'):format(code, tostring(j.error.message))
        elseif type(j.error) == 'string' then
            return ('HTTP %d: %s'):format(code, j.error)
        end
    end
    return ('HTTP %d: %s'):format(code, (text or ''):sub(1, 150))
end

-- =========================================================================
-- Provider AI
-- =========================================================================
local state = {
    lastProvider = '-',
    lastError = '',
    outQueue = {},
    inQueue = {},
    busyOut = false,
    busyIn = false,
    recent = {},
    libs = {},
}

local function callGemini(system, text, cb)
    local url = 'https://generativelanguage.googleapis.com/v1beta/models/' .. cfg.gemini_model .. ':generateContent'
    local body = encodeJson({
        systemInstruction = { parts = { { text = system } } },
        contents = { { role = 'user', parts = { { text = text } } } },
    })
    local function handle(ok, code, resp)
        if not ok then return cb(false, resp, code) end
        if code ~= 200 then return cb(false, apiErrorText(code, resp), code) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' then return cb(false, 'respon Gemini tidak valid', code) end
        local cand = j.candidates and j.candidates[1]
        local parts = cand and cand.content and cand.content.parts
        if type(parts) ~= 'table' then
            local reason = (j.promptFeedback and j.promptFeedback.blockReason) or (cand and cand.finishReason) or 'kosong'
            return cb(false, 'Gemini tidak memberi jawaban (' .. tostring(reason) .. ')', code)
        end
        local out = {}
        for _, p in ipairs(parts) do
            if p.text and not p.thought then out[#out + 1] = p.text end
        end
        local result = trim(table.concat(out, ' '))
        if result == '' then return cb(false, 'jawaban Gemini kosong', code) end
        cb(true, result, code)
    end
    -- cara 1: key lewat header x-goog-api-key (cara resmi, juga untuk key format baru "AQ.")
    httpPost(url, body, 'x-goog-api-key', cfg.gemini_key, function(ok, code, resp)
        if ok and code == 401 then
            -- cara 2: coba sekali lagi dengan key di URL (?key=)
            local key = cfg.gemini_key:gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end)
            return httpPost(url .. '?key=' .. key, body, 'Accept', 'application/json', handle)
        end
        handle(ok, code, resp)
    end)
end

-- dipanggil saat model Groq diganti otomatis (diisi di bagian menu)
local onGroqModelChanged = function() end

-- urutan model yang disukai; kalau tidak ada, ambil model chat aktif apa saja
local GROQ_PREFER = { 'openai/gpt-oss-120b', 'openai/gpt-oss-20b', 'qwen', 'llama', 'kimi', 'gemma', 'mistral' }
local GROQ_SKIP = { 'whisper', 'guard', 'tts', 'playai', 'orpheus', 'compound', 'safeguard', 'distil', 'vision', 'allam' }

local function findGroqModel(cb)
    httpGet('https://api.groq.com/openai/v1/models', 'Authorization', 'Bearer ' .. cfg.groq_key, function(ok, code, resp)
        if not ok then return cb(false, resp) end
        if code ~= 200 then return cb(false, apiErrorText(code, resp)) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' or type(j.data) ~= 'table' then return cb(false, 'daftar model tidak valid') end
        local list = {}
        for _, m in ipairs(j.data) do
            local id = tostring(m.id or '')
            local skip = (m.active == false) or id == ''
            for _, s in ipairs(GROQ_SKIP) do if id:lower():find(s, 1, true) then skip = true end end
            if not skip then list[#list + 1] = id end
        end
        table.sort(list)
        state.groqModels = list
        for _, want in ipairs(GROQ_PREFER) do
            for _, id in ipairs(list) do
                if id == want or id:lower():find(want, 1, true) then return cb(true, id) end
            end
        end
        if list[1] then return cb(true, list[1]) end
        cb(false, 'tidak ada model chat aktif di akun Groq ini')
    end)
end

local function callGroq(system, text, cb, retried)
    local req = {
        model = cfg.groq_model,
        messages = {
            { role = 'system', content = system },
            { role = 'user', content = text },
        },
    }
    -- model gpt-oss "berpikir" dulu; dibuat singkat supaya terjemahan cepat
    if cfg.groq_model:find('gpt%-oss') then req.reasoning_effort = 'low' end
    local body = encodeJson(req)
    httpPost('https://api.groq.com/openai/v1/chat/completions', body, 'Authorization', 'Bearer ' .. cfg.groq_key, function(ok, code, resp)
        if not ok then return cb(false, resp, code) end
        -- model tidak ada / sudah dimatikan -> cari model aktif lalu coba sekali lagi
        if (code == 404 or (code == 400 and resp:find('decommission'))) and not retried then
            return findGroqModel(function(okm, model)
                if okm and model ~= cfg.groq_model then
                    cfg.groq_model = model
                    onGroqModelChanged()
                    markDirty()
                    return callGroq(system, text, cb, true)
                end
                cb(false, apiErrorText(code, resp) .. (okm and '' or (' | cari model: ' .. tostring(model))), code)
            end)
        end
        if code ~= 200 then return cb(false, apiErrorText(code, resp), code) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' then return cb(false, 'respon Groq tidak valid', code) end
        local msg = j.choices and j.choices[1] and j.choices[1].message
        local result = msg and msg.content and trim(tostring(msg.content)) or ''
        if result == '' then return cb(false, 'jawaban Groq kosong', code) end
        cb(true, result, code)
    end)
end

local function callProvider(name, system, text, cb)
    if name == 'gemini' then
        if cfg.gemini_key == '' then return cb(false, 'API key Gemini kosong', 0) end
        callGemini(system, text, cb)
    else
        if cfg.groq_key == '' then return cb(false, 'API key Groq kosong', 0) end
        callGroq(system, text, cb)
    end
end

-- Gemini dulu; kalau gagal/limit -> langsung Groq pada pesan itu juga (tanpa jeda cooldown)
local function translate(system, text, cb)
    local order = {}
    if cfg.gemini_key ~= '' then order[#order + 1] = 'gemini' end
    if cfg.groq_key ~= '' then order[#order + 1] = 'groq' end
    if #order == 0 then return cb(false, 'belum ada API key (isi di /str > API)') end

    local i, errors = 0, {}
    local function try()
        i = i + 1
        local p = order[i]
        if not p then
            state.lastError = table.concat(errors, ' | ')
            return cb(false, state.lastError)
        end
        callProvider(p, system, text, function(ok, result, code)
            if ok then
                state.lastProvider = p
                return cb(true, result, p)
            end
            errors[#errors + 1] = p .. ': ' .. tostring(result)
            try()
        end)
    end
    try()
end

-- =========================================================================
-- Prompt
-- =========================================================================
local SAME = '__SAME__'

local function promptOut()
    local L = LANGS[cfg.out_lang]
    local p = 'You translate chat messages for an online GTA San Andreas Multiplayer (SA-MP) roleplay server. '
        .. 'Translate the user message into ' .. L.name .. '. Keep the meaning and player names. '
    if L.style then
        p = p .. L.style .. ' If the message is already in ' .. L.name .. ', rewrite it in that style. '
    else
        p = p .. 'Keep the casual tone and slang. If the message is already in ' .. L.name .. ', return it unchanged. '
    end
    return p .. 'Reply with ONLY the translated text on a single line: no quotes, no notes, no explanations.'
end

local function promptIn()
    local L = LANGS[cfg.in_lang]
    local p = 'You translate chat messages from other players on an online GTA San Andreas Multiplayer (SA-MP) roleplay server. '
        .. 'Other players may use street slang from any country (American, Mexican, etc.); understand the slang and translate its real meaning. '
        .. 'If the message is already written in ' .. L.name .. ', or it has no real words to translate, reply with exactly ' .. SAME .. '. '
        .. 'Otherwise translate it into ' .. L.name .. ' with a casual, natural tone, keeping player names. '
    if L.style then p = p .. L.style .. ' ' end
    return p .. 'Reply with ONLY the translation on a single line: no quotes, no notes, no explanations.'
end

-- =========================================================================
-- Kirim chat tanpa dicegat ulang
-- =========================================================================
local bypass = false
local function sendRaw(text)
    if #text > 143 then text = text:sub(1, 143) end
    bypass = true
    sampSendChat(text)
    bypass = false
end

-- =========================================================================
-- Antrian pesan keluar (berurutan supaya urutan chat tidak acak)
-- =========================================================================
local QUEUE_TIMEOUT = 22 -- detik; lewat dari ini pesan asli dikirim supaya antrian tidak macet

local function safeGame(s)
    local ok, r = pcall(toGame, tostring(s))
    return ok and r or '?'
end

local function processOut()
    if state.busyOut or #state.outQueue == 0 then return end
    state.busyOut = true
    local item = table.remove(state.outQueue, 1)
    local original = item.prefix .. item.text
    local done = false

    -- apa pun yang terjadi, fungsi ini SELALU membuka antrian lagi
    local function finish(text, warn)
        if done then return end
        done = true
        if warn then pcall(notify, warn) end
        local okSend, errSend = pcall(sendRaw, text)
        if not okSend then pcall(notify, '{FF6666}Gagal kirim chat: ' .. tostring(errSend)) end
        state.busyOut = false
        processOut()
    end

    -- pengaman: AI terlalu lama / tidak menjawab -> kirim pesan asli
    lua_thread.create(function()
        wait(QUEUE_TIMEOUT * 1000)
        finish(original, '{FF6666}AI terlalu lama menjawab, pesan asli dikirim.')
    end)

    local okCall, errCall = pcall(translate, promptOut(), toUtf8(item.text), function(ok, result)
        if done then return end
        if not ok then
            return finish(original, '{FF6666}Gagal menerjemahkan, pesan asli dikirim. {AAAAAA}' .. safeGame(result):sub(1, 90))
        end
        if cfg.debug then pcall(notify, '{AAAAAA}AI: ' .. safeGame(result):sub(1, 110)) end
        local okConv, out = pcall(toGame, result)
        if not okConv then
            return finish(original, '{FF6666}Error script: ' .. tostring(out):sub(1, 90) .. ' - pesan asli dikirim.')
        end
        if countLetters(out) == 0 then
            return finish(original, '{FF6666}Jawaban AI kosong setelah dibersihkan, pesan asli dikirim.')
        end
        finish(item.prefix .. out)
    end)
    if not okCall then
        finish(original, '{FF6666}Error script: ' .. tostring(errCall):sub(1, 90) .. ' - pesan asli dikirim.')
    end
end

local function queueOut(prefix, text)
    state.outQueue[#state.outQueue + 1] = { prefix = prefix, text = text }
    processOut()
end

-- =========================================================================
-- Antrian pesan masuk
-- =========================================================================
local function processIn()
    if state.busyIn or #state.inQueue == 0 then return end
    state.busyIn = true
    local item = table.remove(state.inQueue, 1)
    local done = false
    local function finish()
        if done then return end
        done = true
        state.busyIn = false
        processIn()
    end
    lua_thread.create(function()
        wait(QUEUE_TIMEOUT * 1000)
        finish()
    end)
    local okCall = pcall(translate, promptIn(), toUtf8(item.text), function(ok, result)
        if done then return end
        if ok and not result:find(SAME, 1, true) then
            pcall(function()
                sampAddChatMessage(('{66CCFF}[STR] {FFFF99}%s{FFFFFF}: %s'):format(item.name, toGame(result)), -1)
            end)
        elseif not ok and cfg.debug then
            pcall(notify, '{AAAAAA}Gagal terjemah pesan masuk: ' .. safeGame(result):sub(1, 90))
        end
        finish()
    end)
    if not okCall then finish() end
end

local function queueIn(name, text)
    text = trim(text)
    if countLetters(text) < cfg.min_letters then return end
    local key = name .. '|' .. text
    local now = os.clock()
    if state.recent[key] and now - state.recent[key] < 3 then return end
    state.recent[key] = now
    if #state.inQueue >= 10 then table.remove(state.inQueue, 1) end -- buang yang terlalu lama
    state.inQueue[#state.inQueue + 1] = { name = name, text = text }
    processIn()
end

-- =========================================================================
-- Hook SA-MP
-- =========================================================================
function sampev.onSendChat(msg)
    if bypass or not cfg.enabled or not cfg.translate_out then return end
    local p = cfg.raw_prefix
    if p ~= '' and msg:sub(1, #p) == p then
        local rest = trim(msg:sub(#p + 1))
        if rest == '' then return false end
        return { rest } -- kirim apa adanya tanpa diterjemahkan
    end
    if countLetters(msg) < 1 then return end
    queueOut('', msg)
    return false
end

local function cmdAllowed(cmd)
    for c in cfg.cmd_list:gmatch('[^,%s]+') do
        if c:lower() == cmd:lower() then return true end
    end
    return false
end

function sampev.onSendCommand(command)
    if bypass or not cfg.enabled or not cfg.translate_out or not cfg.translate_cmds then return end
    local cmd, rest = command:match('^/(%S+)%s+(.+)$')
    if not cmd or not cmdAllowed(cmd) then return end
    if countLetters(rest) < 1 then return end
    queueOut('/' .. cmd .. ' ', rest)
    return false
end

function sampev.onChatMessage(playerId, text)
    if not cfg.enabled or not cfg.translate_in then return end
    local ok, name = pcall(sampGetPlayerNickname, playerId)
    queueIn(ok and name or ('ID ' .. playerId), text)
end

local CHAT_PATTERNS = {
    '^(.-) says %b(): (.+)$',
    '^(.-) says: (.+)$',
    '^(.-) shouts: (.+)$',
    '^(.-) whispers: (.+)$',
    '^(.-) %(phone%): (.+)$',
    '^%(%(%s*(.-): (.-)%s*%)%)$',
    '^(.-)%s*%[%d+%]: (.+)$',
    '^(.-)%s*%(%d+%): (.+)$',
    '^(.-): (.+)$',
}

function sampev.onServerMessage(color, text)
    if not cfg.enabled or not cfg.translate_in or not cfg.translate_server then return end
    local clean = text:gsub('{%x%x%x%x%x%x}', '')
    for _, pat in ipairs(CHAT_PATTERNS) do
        local name, msg = clean:match(pat)
        if name then
            name = trim(name:gsub('^%[.-%]%s*', '')) -- buang tag seperti [Admin]
            if name ~= '' and #name <= 24 and isConnectedPlayer(name) then
                local me = myName()
                if not (me and me:lower() == name:gsub(' ', '_'):lower()) then
                    queueIn(name, msg)
                end
            end
            return
        end
    end
end

-- =========================================================================
-- Menu ImGui (mimgui)
-- =========================================================================
local ui = {
    show            = new.bool(false),
    enabled         = new.bool(cfg.enabled),
    translate_out   = new.bool(cfg.translate_out),
    translate_in    = new.bool(cfg.translate_in),
    translate_server= new.bool(cfg.translate_server),
    translate_cmds  = new.bool(cfg.translate_cmds),
    out_lang        = new.int(cfg.out_lang - 1),
    in_lang         = new.int(cfg.in_lang - 1),
    min_letters     = new.int(cfg.min_letters),
    raw_prefix      = new.char[8](cfg.raw_prefix),
    cmd_list        = new.char[128](cfg.cmd_list),
    gemini_key      = new.char[256](cfg.gemini_key),
    gemini_model    = new.char[96](cfg.gemini_model),
    groq_key        = new.char[256](cfg.groq_key),
    groq_model      = new.char[96](cfg.groq_model),
    show_keys       = new.bool(false),
    test_text       = new.char[256]('di sana ada polisi'),
    test_in_text    = new.char[256]("Just relax, there's only one police officer there"),
    test_log        = {},
}
local langItems = new['const char*'][#langLabels](langLabels)

onGroqModelChanged = function()
    ffi.copy(ui.groq_model, cfg.groq_model:sub(1, sizeof(ui.groq_model) - 1))
end

local function syncUiFromCfg()
    ui.enabled[0] = cfg.enabled
end

local function testLog(line)
    table.insert(ui.test_log, 1, os.date('[%H:%M:%S] ') .. line)
    while #ui.test_log > 30 do table.remove(ui.test_log) end
end

local function wrapped(text)
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(text)
    imgui.PopTextWrapPos()
end

local function colored(r, g, b, text)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(r, g, b, 1))
    imgui.TextUnformatted(text)
    imgui.PopStyleColor()
end

local function runTest(label, fn)
    local started = os.clock()
    testLog(label .. ' ... menunggu')
    fn(function(ok, result, provider)
        local ms = math.floor((os.clock() - started) * 1000)
        if ok then
            testLog(('%s OK (%s, %d ms): %s'):format(label, provider or '-', ms, result))
        else
            testLog(('%s GAGAL (%d ms): %s'):format(label, ms, tostring(result)))
        end
    end)
end

local function checkbox(label, key)
    if imgui.Checkbox(label, ui[key]) then
        cfg[key] = ui[key][0]
        markDirty()
    end
end

local function inputText(label, key, flags)
    if imgui.InputText(label, ui[key], sizeof(ui[key]), flags or 0) then
        local v = ffistr(ui[key])
        if key:find('_key$') then v = v:gsub('%s', '') end -- buang spasi/enter yang ikut tercopy
        cfg[key] = v
        markDirty()
    end
end

-- info singkat agar mudah cek key tanpa menampilkan isinya
local function keyInfo(key, expectPrefix)
    local k = cfg[key]
    if k == '' then
        colored(1, 0.6, 0.3, '  Key kosong')
        return
    end
    local info = ('  %d karakter, awalan "%s..."'):format(#k, k:sub(1, 4))
    local okPrefix = not expectPrefix
    for p in (expectPrefix or ''):gmatch('[^|]+') do
        if k:sub(1, #p) == p then okPrefix = true end
    end
    if not okPrefix then
        colored(1, 0.6, 0.3, info .. '  -> biasanya diawali ' .. expectPrefix:gsub('|', ' / '))
    else
        colored(0.6, 0.9, 0.6, info)
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
end)

imgui.OnFrame(function() return ui.show[0] end, function()
    imgui.SetNextWindowSize(imgui.ImVec2(560, 500), imgui.Cond.FirstUseEver)
    imgui.Begin('STR Translator  (Gemini -> Groq)', ui.show)

    -- status singkat
    if cfg.enabled then colored(0.4, 1, 0.4, 'Status: AKTIF') else colored(1, 0.4, 0.4, 'Status: MATI') end
    imgui.SameLine()
    imgui.TextUnformatted('  |  Terakhir dipakai: ' .. state.lastProvider)
    imgui.Separator()

    if imgui.BeginTabBar('str_tabs') then
        -- ---------------------------------------------------------------- Umum
        if imgui.BeginTabItem('Umum') then
            checkbox('Penerjemah aktif', 'enabled')
            imgui.Spacing()
            checkbox('Terjemahkan pesan yang aku ketik', 'translate_out')
            imgui.SetNextItemWidth(200)
            if imgui.Combo('Bahasa pesanku', ui.out_lang, langItems, #langLabels) then
                cfg.out_lang = ui.out_lang[0] + 1
                markDirty()
            end
            imgui.Spacing()
            checkbox('Terjemahkan pesan lawan bicara', 'translate_in')
            imgui.SetNextItemWidth(200)
            if imgui.Combo('Bahasa terjemahan lawan', ui.in_lang, langItems, #langLabels) then
                cfg.in_lang = ui.in_lang[0] + 1
                markDirty()
            end
            checkbox('Baca chat dari pesan server (format "Nama says: ...")', 'translate_server')
            imgui.SetNextItemWidth(120)
            if imgui.InputInt('Minimal huruf pesan lawan', ui.min_letters) then
                if ui.min_letters[0] < 1 then ui.min_letters[0] = 1 end
                cfg.min_letters = ui.min_letters[0]
                markDirty()
            end
            imgui.Separator()
            imgui.SetNextItemWidth(60)
            inputText('Awalan kirim tanpa terjemah', 'raw_prefix')
            wrapped('Contoh: ketik ".halo" -> terkirim "halo" tanpa diterjemahkan.')
            imgui.Spacing()
            checkbox('Terjemahkan juga perintah ini:', 'translate_cmds')
            imgui.SetNextItemWidth(250)
            inputText('##cmdlist', 'cmd_list')
            wrapped('Pisahkan dengan koma, tanpa garis miring. Contoh: b,s,low,me,do')
            imgui.EndTabItem()
        end

        -- ---------------------------------------------------------------- API
        if imgui.BeginTabItem('API') then
            local keyFlags = ui.show_keys[0] and 0 or imgui.InputTextFlags.Password
            colored(0.5, 0.8, 1, 'Gemini (utama)')
            imgui.SetNextItemWidth(380)
            inputText('API key Gemini', 'gemini_key', keyFlags)
            keyInfo('gemini_key', 'AIza|AQ.')
            imgui.SetNextItemWidth(250)
            inputText('Model Gemini', 'gemini_model')
            imgui.Spacing()
            colored(0.5, 0.8, 1, 'Groq (cadangan saat Gemini habis/gagal)')
            imgui.SetNextItemWidth(380)
            inputText('API key Groq', 'groq_key', keyFlags)
            keyInfo('groq_key', 'gsk_')
            imgui.SetNextItemWidth(250)
            inputText('Model Groq', 'groq_model')
            if imgui.Button('Cari model Groq otomatis') then
                if cfg.groq_key == '' then
                    state.groqFind = 'Isi API key Groq dulu.'
                else
                    state.groqFind = 'Mencari...'
                    findGroqModel(function(ok, model)
                        if ok then
                            cfg.groq_model = model
                            onGroqModelChanged()
                            markDirty()
                            state.groqFind = 'Dipakai: ' .. model
                        else
                            state.groqFind = 'Gagal: ' .. tostring(model)
                        end
                    end)
                end
            end
            if state.groqFind then
                imgui.SameLine()
                imgui.TextUnformatted(state.groqFind)
            end
            if state.groqModels and #state.groqModels > 0 then
                wrapped('Model aktif di akunmu: ' .. table.concat(state.groqModels, ', '))
            end
            imgui.Spacing()
            imgui.Checkbox('Tampilkan API key', ui.show_keys)
            imgui.Separator()
            wrapped('Kalau Gemini kena limit/gagal, pesan itu langsung dikirim lewat Groq. Tidak ada jeda istirahat.')
            wrapped('Key disimpan di monetloader/config/str_translator.json (teks biasa). Jangan bagikan file itu.')
            imgui.EndTabItem()
        end

        -- ---------------------------------------------------------------- Test
        if imgui.BeginTabItem('Test') then
            colored(0.5, 0.8, 1, 'Cek library')
            for _, name in ipairs({ 'effil', 'requests', 'ssl', 'mimgui', 'encoding', 'samp.events' }) do
                local ok = state.libs[name]
                if ok then colored(0.4, 1, 0.4, '  [OK] ' .. name) else colored(1, 0.4, 0.4, '  [TIDAK ADA] ' .. name) end
            end
            imgui.Separator()

            imgui.SetNextItemWidth(380)
            imgui.InputText('Teks pesanku', ui.test_text, sizeof(ui.test_text))
            if imgui.Button('Test Gemini') then
                local t = ffistr(ui.test_text)
                runTest('Gemini', function(done)
                    callProvider('gemini', promptOut(), t, function(ok, r) done(ok, r, 'gemini') end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Test Groq') then
                local t = ffistr(ui.test_text)
                runTest('Groq (' .. cfg.groq_model .. ')', function(done)
                    callProvider('groq', promptOut(), t, function(ok, r) done(ok, r, 'groq') end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Test otomatis (Gemini -> Groq)') then
                local t = ffistr(ui.test_text)
                runTest('Keluar -> ' .. LANGS[cfg.out_lang].label, function(done) translate(promptOut(), t, done) end)
            end

            imgui.Spacing()
            imgui.SetNextItemWidth(380)
            imgui.InputText('Pesan lawan', ui.test_in_text, sizeof(ui.test_in_text))
            if imgui.Button('Simulasi pesan masuk (muncul di chat)') then
                local t = ffistr(ui.test_in_text)
                runTest('Masuk -> ' .. LANGS[cfg.in_lang].label, function(done)
                    translate(promptIn(), t, function(ok, r, p)
                        if ok and not r:find(SAME, 1, true) then
                            sampAddChatMessage('{66CCFF}[STR] {FFFF99}Test{FFFFFF}: ' .. toGame(r), -1)
                        elseif ok then
                            r = '(sudah ' .. LANGS[cfg.in_lang].label .. ', tidak diterjemahkan)'
                        end
                        done(ok, r, p)
                    end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Bersihkan log') then ui.test_log = {} end

            imgui.Separator()
            if state.lastError ~= '' then
                colored(1, 0.5, 0.5, 'Error terakhir:')
                wrapped(state.lastError)
                imgui.Separator()
            end
            imgui.BeginChild('testlog', imgui.ImVec2(0, 0), true)
            for _, line in ipairs(ui.test_log) do wrapped(line) end
            imgui.EndChild()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
    imgui.End()
end)

-- =========================================================================
-- Main
-- =========================================================================
function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(0) end

    loadCfg()
    ui.enabled[0]          = cfg.enabled
    ui.translate_out[0]    = cfg.translate_out
    ui.translate_in[0]     = cfg.translate_in
    ui.translate_server[0] = cfg.translate_server
    ui.translate_cmds[0]   = cfg.translate_cmds
    ui.out_lang[0]         = cfg.out_lang - 1
    ui.in_lang[0]          = cfg.in_lang - 1
    ui.min_letters[0]      = cfg.min_letters
    for _, k in ipairs({ 'raw_prefix', 'cmd_list', 'gemini_key', 'gemini_model', 'groq_key', 'groq_model' }) do
        ffi.copy(ui[k], cfg[k]:sub(1, sizeof(ui[k]) - 1))
    end

    for _, name in ipairs({ 'effil', 'requests', 'ssl', 'mimgui', 'encoding' }) do
        state.libs[name] = (pcall(require, name))
    end

    sampRegisterChatCommand('str', function(arg)
        arg = trim((arg or ''):lower())
        if arg == 'on' then
            cfg.enabled = true
            syncUiFromCfg()
            markDirty()
            notify('Penerjemah {66FF66}AKTIF{FFFFFF}. Pesanku -> ' .. LANGS[cfg.out_lang].label
                .. ', pesan lawan -> ' .. LANGS[cfg.in_lang].label)
        elseif arg == 'off' or arg == 'of' then
            cfg.enabled = false
            syncUiFromCfg()
            markDirty()
            notify('Penerjemah {FF6666}MATI{FFFFFF}.')
        else
            ui.show[0] = not ui.show[0]
        end
    end)

    notify('Loaded. Ketik {FFFF99}/str{FFFFFF} untuk menu, {FFFF99}/str on{FFFFFF} / {FFFF99}/str off{FFFFFF} CopyRight By:Bobwan.')
    if not state.libs.requests or not state.libs.ssl or not state.libs.effil then
        notify('{FF6666}Library kurang (effil / requests / ssl). Pasang paket libstd MonetLoader yang sesuai, lalu cek tab Test.')
    end
    if cfg.gemini_key == '' and cfg.groq_key == '' then
        notify('Belum ada API key. Isi dulu di {FFFF99}/str{FFFFFF} > tab API.')
    end

    while true do
        wait(1000)
        if dirty then
            dirty = false
            saveCfg()
        end
        -- bersihkan cache anti-duplikat
        local now = os.clock()
        for k, t in pairs(state.recent) do
            if now - t > 10 then state.recent[k] = nil end
        end
    end
end