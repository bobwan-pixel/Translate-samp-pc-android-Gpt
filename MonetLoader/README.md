# STR Translator for MonetLoader (Android)

Port of the original MoonLoader PC STR Translator to SA-MP Android.

## Target

- MonetLoader 3.8.0 (MoonLoader-compatibility runtime)
- A compatible MonetLoader `libstd` package providing:
  - `samp.events` / SAMP.Lua
  - `mimgui`
  - `encoding`
  - `ffi`
  - `effil`
  - `requests`
  - `ssl`

The script intentionally uses the MonetLoader module path `require 'samp.events'`, Android-style forward-slash paths, and does not require the PC-only SAMPFUNCS-loaded check.

## Install

1. Install MonetLoader and a matching library bundle.
2. Copy `STR_Translator.lua` into:
   `Android/media/<GTA package>/monetloader/scripts/`
3. Start SA-MP Android.
4. Run `/str` to open the menu.
5. Open the **API** tab and enter your Gemini and/or Groq API key.
6. Use `/str on` or `/str off` to toggle translation.

## Features retained

- Gemini primary provider with Groq automatic fallback.
- Outgoing and incoming chat translation.
- Optional server chat parsing (`says`, `shouts`, `whispers`, phone and common RP formats).
- Optional command translation with an allow-list.
- US street slang and Mexican Spanish style presets.
- Queueing, timeout fallback to the original outgoing message, and duplicate suppression.
- Language selection, API/model settings, model discovery, and built-in provider tests.

## Configuration and API keys

The script saves settings to:

`monetloader/config/str_translator.json`

API keys are stored as plain text in that local config file. Do not share or commit it. The repository does not contain API keys.

## Compatibility notes

This is an initial Android port, not a claim of device-level verification. MonetLoader aims for MoonLoader compatibility, but available libraries and supported SA-MP hooks depend on the exact Android client and installed library bundle. In particular, verify `samp.events`, `effil`, `requests`, and TLS support on the target setup before relying on live translation.

The original PC script is kept separate and is not overwritten by this Android port.
