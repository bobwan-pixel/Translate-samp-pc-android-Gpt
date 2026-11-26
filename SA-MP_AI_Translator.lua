script_name('SA-MP AI Translator')
script_author('Bobwan')
script_version('1.0.1')
script_description('Gemini -> Grok fallback translator with mimgui')

--[[
    SA-MP AI Translator - single-file MoonLoader script

    Required MoonLoader libraries:
      - mimgui
      - samp.events (SAMP.Lua)
      - encoding
      - requests (Lua HTTP client for MoonLoader)

    Uses MoonLoader's encodeJson/decodeJson helpers.
    Put this file in: GTA San Andreas/moonloader/SA-MP_AI_Translator.lua

    IMPORTANT:
      1. Set GEMINI_API_KEY and XAI_API_KEY below.
      2. Never share this file after adding your private API keys.
      3. API calls run in lua_thread so the game loop is not blocked.
]]

local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
local sampev = require 'samp.events'
local requests = require 'requests'

encoding.default = 'CP1252'
local u8 = encoding.UTF8

-- =========================
-- API CONFIGURATION
-- =========================
local GEMINI_API_KEY = '' -- Isi Google AI Studio API key di sini
local XAI_API_KEY = '' -- Isi xAI API key di sini

local GEMINI_MODEL = 'gemini-3.5-flash-lite'
local GROK_MODEL = 'grok-4.6'

local GEMINI_URL = 'https://generativelanguage.googleapis.com/v1beta/models/' ..
    GEMINI_MODEL .. ':generateContent?key='

local GROK_URL = 'https://api.x.ai/v1/chat/completions'

-- =========================
-- SETTINGS / UI STATE
-- =========================
local enabled = false
local windowOpen = imgui.new.bool(false)
local autoIncoming = imgui.new.bool(true)
local autoOutgoing = imgui.new.bool(true)
local targetIndex = imgui.new.int(0)

local targets = { 'English', 'Indonesian', 'Spanish', 'Portuguese', 'Japanese' }
local targetLanguages = { 'English', 'Indonesian', 'Spanish', 'Portuguese', 'Japanese' }

local inputBuffer = imgui.new.char[512]('')
local outputBuffer = imgui.new.char[1024]('')
local statusBuffer = imgui.new.char[256]('Belum ada tes.')
local testBusy = false
local sendingTranslatedMessage = false
local incomingBusy = {}

local function uiText(text)
    return u8(text or '')
end

local function gameText(text)
    return u8:decode(text or '')
end

local function setStatus(text)
    imgui.StrCopy(statusBuffer, uiText(text))
end

local function setOutput(text)
    -- API responses and ImGui buffers are already UTF-8.
    imgui.StrCopy(outputBuffer, tostring(text or ''))
end

local function chatMessage(text, color)
    if isSampAvailable() then
        sampAddChatMessage(gameText(text), color or 0xFFFFFFFF)
    end
end

local function getTargetLanguage()
    local index = tonumber(targetIndex[0]) or 0
    return targetLanguages[index + 1] or 'English'
end

local function trim(text)
    return (tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function jsonEncode(value)
    if type(encodeJson) ~= 'function' then
        error('encodeJson tidak tersedia di MoonLoader.')
    end
    return encodeJson(value)
end

local function jsonDecode(value)
    if type(decodeJson) ~= 'function' then
        error('decodeJson tidak tersedia di MoonLoader.')
    end
    return decodeJson(value)
end

local function httpPost(url, headers, body)
    -- requests.post is synchronous, so it MUST only run inside lua_thread.
    local response = requests.post(url, {
        headers = headers,
        data = body,
        timeout = 35
    })

    if not response then
        return nil, 'Tidak ada respons HTTP.'
    end

    local status = tonumber(response.status_code or response.status or 0) or 0
    local responseBody = response.text or response.content or ''

    if status < 200 or status >= 300 then
        return nil, 'HTTP ' .. tostring(status) .. ': ' .. tostring(responseBody):sub(1, 240), status
    end

    local ok, decoded = pcall(jsonDecode, responseBody)
    if not ok or type(decoded) ~= 'table' then
        return nil, 'Respons API bukan JSON yang valid.'
    end

    return decoded
end

local function extractGeminiText(data)
    if type(data) ~= 'table' or type(data.candidates) ~= 'table' then
        return nil
    end
    local candidate = data.candidates[1]
    local content = candidate and candidate.content
    local parts = content and content.parts
    local first = parts and parts[1]
    return first and first.text or nil
end

local function extractGrokText(data)
    local choices = type(data) == 'table' and data.choices or nil
    local choice = choices and choices[1]
    local message = choice and choice.message
    return message and message.content or nil
end

local function requestGemini(prompt)
    if trim(GEMINI_API_KEY) == '' then
        return nil, 'Gemini API key belum diisi.', 401
    end

    local body = jsonEncode({
        contents = {
            {
                role = 'user',
                parts = { { text = prompt } }
            }
        },
        generationConfig = {
            maxOutputTokens = 160
        }
    })

    local data, err, status = httpPost(
        GEMINI_URL .. GEMINI_API_KEY,
        { ['Content-Type'] = 'application/json' },
        body
    )

    if not data then
        return nil, err, status
    end

    local result = trim(extractGeminiText(data))
    if result == '' then
        return nil, 'Gemini mengembalikan hasil kosong.'
    end
    return result
end

local function requestGrok(prompt)
    if trim(XAI_API_KEY) == '' then
        return nil, 'Grok API key belum diisi.', 401
    end

    local body = jsonEncode({
        model = GROK_MODEL,
        messages = {
            {
                role = 'system',
                content = 'You are a translation engine. Return only the translated text. Do not add quotes, explanations, labels, or commentary.'
            },
            { role = 'user', content = prompt }
        },
        temperature = 0.1,
        max_tokens = 160
    })

    local data, err, status = httpPost(
        GROK_URL,
        {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bearer ' .. XAI_API_KEY
        },
        body
    )

    if not data then
        return nil, err, status
    end

    local result = trim(extractGrokText(data))
    if result == '' then
        return nil, 'Grok mengembalikan hasil kosong.'
    end
    return result
end

local function translateText(text, direction)
    local source = trim(text)
    if source == '' then
        return nil, 'Teks kosong.'
    end

    local prompt
    if direction == 'incoming' then
        prompt = 'Detect the language of the following SA-MP player chat. ' ..
            'If it is Indonesian, reply exactly with __SKIP__. ' ..
            'Otherwise translate it naturally into Indonesian. ' ..
            'Preserve the original meaning, slang, names, numbers, and roleplay context. ' ..
            'Return only the result, with no explanation.\n\nText: ' .. source
    else
        prompt = 'Translate the following Indonesian SA-MP chat message into ' ..
            getTargetLanguage() .. '. Keep it short, natural, and suitable for multiplayer roleplay chat. ' ..
            'Preserve names, numbers, commands, and meaning. Return only the translation.\n\nText: ' .. source
    end

    local result, geminiError = requestGemini(prompt)
    if result then
        return result, 'Gemini'
    end

    -- Automatic fallback: try Grok if Gemini is exhausted, unavailable, or errors.
    local grokResult, grokError = requestGrok(prompt)
    if grokResult then
        return grokResult, 'Grok (fallback)'
    end

    return nil, 'Gemini: ' .. tostring(geminiError) .. ' | Grok: ' .. tostring(grokError)
end

local function runTranslation(text, direction, callback)
    lua_thread.create(function()
        local result, source = translateText(text, direction)
        callback(result, source)
    end)
end

local function isCommand(text)
    return tostring(text or ''):sub(1, 1) == '/'
end

local function toggleTranslator(state)
    enabled = state
    chatMessage('[STR] Translator ' .. (enabled and 'ON' or 'OFF'), enabled and 0xFF55DD88 or 0xFFFF7777)
end

-- =========================
-- CHAT COMMANDS
-- =========================
function main()
    repeat wait(100) until isSampAvailable()

    sampRegisterChatCommand('str', function(param)
        local value = string.lower(trim(param))
        if value == 'on' then
            toggleTranslator(true)
        elseif value == 'off' or value == 'of' then
            toggleTranslator(false)
        else
            windowOpen[0] = not windowOpen[0]
        end
    end)

    chatMessage('[STR] AI Translator loaded. Type /str to open menu.', 0xFF77CCFF)

    while true do
        wait(0)
    end
end

-- =========================
-- OUTGOING CHAT TRANSLATION
-- =========================
function sampev.onSendChat(message)
    if not enabled or not autoOutgoing[0] or sendingTranslatedMessage then
        return
    end

    local original = trim(message)
    if original == '' or isCommand(original) then
        return
    end

    -- Cancel the original Indonesian message; send its translation after API response.
    runTranslation(u8(original), 'outgoing', function(result, source)
        if result and result ~= '' then
            sendingTranslatedMessage = true
            sampSendChat(gameText(result))
            sendingTranslatedMessage = false
            setStatus('Terkirim via ' .. tostring(source))
        else
            chatMessage('[STR] Gagal menerjemahkan: ' .. tostring(source), 0xFFFF7777)
        end
    end)

    return false
end

-- =========================
-- INCOMING PLAYER CHAT
-- =========================
function sampev.onChatMessage(playerId, text)
    if not enabled or not autoIncoming[0] then
        return
    end

    local original = trim(text)
    if original == '' then
        return
    end

    local key = tostring(playerId) .. ':' .. original
    if incomingBusy[key] then
        return
    end
    incomingBusy[key] = true

    local nickname = 'Player ' .. tostring(playerId)
    if sampIsPlayerConnected(playerId) then
        nickname = u8(sampGetPlayerNickname(playerId))
    end

    runTranslation(u8(original), 'incoming', function(result, source)
        incomingBusy[key] = nil
        if result and result ~= '' and result ~= '__SKIP__' then
            chatMessage('{AAAAAA}[TR] ' .. nickname .. ': {FFFFFF}' .. result, 0xFFFFFFFF)
        end
    end)
end

-- =========================
-- IMGUI WINDOW
-- =========================
imgui.OnFrame(
    function()
        return windowOpen[0]
    end,
    function()
        imgui.SetNextWindowSize(imgui.ImVec2(440, 390), imgui.Cond.FirstUseEver)
        imgui.Begin('SA-MP AI Translator', windowOpen)

        imgui.Text('Status: ' .. (enabled and 'ON' or 'OFF'))
        imgui.SameLine()
        if imgui.Button(enabled and 'Turn OFF' or 'Turn ON') then
            toggleTranslator(not enabled)
        end

        imgui.Separator()
        imgui.Text('Bahasa tujuan untuk chat yang kamu kirim:')
        if imgui.BeginCombo('Target language', targets[targetIndex[0] + 1] or 'English') then
            for i, language in ipairs(targets) do
                local selected = (targetIndex[0] == i - 1)
                if imgui.Selectable(language, selected) then
                    targetIndex[0] = i - 1
                end
                if selected then imgui.SetItemDefaultFocus() end
            end
            imgui.EndCombo()
        end

        imgui.Checkbox('Terjemahkan chat keluar', autoOutgoing)
        imgui.Checkbox('Terjemahkan chat pemain masuk ke Indonesia', autoIncoming)

        imgui.Separator()
        imgui.Text('Tes translator')
        imgui.InputText('Teks', inputBuffer, ffi.sizeof(inputBuffer))
        if imgui.Button('Test translate') and not testBusy then
            local testText = trim(ffi.string(inputBuffer))
            if testText == '' then
                setStatus('Isi teks tes terlebih dahulu.')
            else
                testBusy = true
                setStatus('Menghubungi Gemini...')
                runTranslation(testText, 'outgoing', function(result, source)
                    testBusy = false
                    if result then
                        setOutput(result)
                        setStatus('Berhasil: ' .. tostring(source))
                    else
                        setOutput('')
                        setStatus('Gagal: ' .. tostring(source))
                    end
                end)
            end
        end

        imgui.SameLine()
        if imgui.Button('Tes script lokal') then
            setOutput('SCRIPT OK - ImGui, command handler, dan UI aktif.')
            setStatus('Tes lokal berhasil. Ini belum mengetes API.')
        end

        imgui.Text('Hasil:')
        imgui.InputTextMultiline('##translation_output', outputBuffer, ffi.sizeof(outputBuffer), imgui.ImVec2(-1, 62), imgui.InputTextFlags.ReadOnly)

        imgui.Separator()
        imgui.TextWrapped('Gemini dipakai lebih dulu. Jika gagal / kuota habis, script mencoba Grok.')
        imgui.TextWrapped('Perintah: /str (menu), /str on, /str off')
        imgui.TextWrapped('API key disimpan di bagian atas file Lua. Jangan bagikan key.')
        imgui.End()
    end
)

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        enabled = false
    end
end
