<h1 align="center">Devbox</h1>

<p align="center">
  <b>The developer's toolbox in the Windows tray.</b><br>
  Clipboard history, text expander, Gmail and Calendar, containers, cleanup, network, scheduler, AI and more, in one app.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows" alt="Windows 10 and 11">
  <img src="https://img.shields.io/badge/Delphi-VCL%20%2B%20Skia-E62431" alt="Delphi VCL + Skia">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/clipboard.png" width="820" alt="Devbox clipboard">
</p>

> The app UI is in Brazilian Portuguese for now.

---

## What's inside

**Daily use**
- **Clipboard:** history of text, images and files, searchable, with pinned snippets. Win+Alt+B opens it from any program and Enter pastes where you were.
- **Converters:** pretty or one-line JSON, Base64, URL, JWT, timestamp, SHA-256, MD5, upper/lower case, sort and dedupe lines, GUID.
- **Copied images and files:** OCR (text from the image, using Windows itself), save PNG, SHA-256 and zip.
- **Text expander:** type `;shortcut` in any program and it becomes the snippet. `{{name}}` fields are asked before pasting. Built-ins: `;data`, `;hora`, `;agora`, `;guid`, `;ts`.
- **Focus and meetings:** clipboard paused and alerts held until the end. On for 25 or 50 minutes, until you turn it off, or automatically while the camera or mic is in use. Shows focus time per day.
- **Tools:** screenshot for bug reports (arrow, rectangle, text, step number and blur), compare `.env` files and a live log viewer with errors in red.

**Mail and calendar**
- **Mail:** the inbox of your accounts in one list, colored by account. Gmail through Google sign-in; Yahoo, iCloud and company IMAP with an app password. Instant alert for important unread mail.
- **Organize with AI:** the AI reads your mail and suggests a label (a folder, on IMAP), archive or mark as read. Nothing changes until you click Apply.
- **Calendar:** day, week, month or list view of your primary calendar. Alert before each meeting and a button to join the Meet. Also takes any iCal link (no sign-in).
- **Daily summary:** at a set time, the AI turns today's agenda and important mail into a short text.

**Voice**
- **Wake phrase:** say your phrase (default "Oi Java") and your request (in Portuguese), together or after a pause: summarize important mail, next meeting, focus mode, open a screen. A HUD with an audio visualizer shows up in the screen corner and Devbox answers out loud.
- The phrase is checked on your machine (Vosk). The request is transcribed by the engine you pick: local whisper (CPU or NVIDIA GPU) or cloud (Groq or OpenAI).

**Environment**
- **Services:** Docker containers on Windows and Podman/Docker inside running WSL distros, with start, stop, restart and logs. WSL distros. Listening ports with the owning process.
- **Cleanup:** build leftovers of idle projects (`node_modules`, `bin/obj`, `dcu`, `target`...), temp files and caches, large files with a chart by type, empty folders, dangling container images and startup programs.
- **Network:** URL monitor with response time and certificate expiry, VPN alert and a local webhook receiver to test integrations.
- **System:** live CPU, memory, disks and processes. User PATH editor that finds missing and duplicate folders.

**Automation**
- **Project environments:** a step script starts distro, containers, terminal, editor and browser in one click.
- **AI command:** say what you want; the AI writes the command, you check it and decide whether to run it.
- **Scheduler:** commands every N minutes, daily or on weekdays, with history and failure alerts.
- **Done alerts:** tells you when a process ends, a port closes or a container stops.

<p align="center">
  <img src="docs/images/rede.png" width="410" alt="Network">
  <img src="docs/images/foco.png" width="410" alt="Focus">
</p>

## Keys

| Key | Does |
|---|---|
| Win+Alt+B | Opens or hides the clipboard search |
| Win+Alt+S | Screenshot for a bug report |
| ↑ ↓ and Enter | Pick and paste into the previous window |
| Esc | Hides the window |

Closing the window only hides it. To quit, use **Sair** (Exit) in the tray menu.

## Privacy and safety

- Everything lives in `%LOCALAPPDATA%\Devbox\devbox.db` (SQLite), on your machine only.
- Passwords flagged by password managers and text that looks like a token or key are kept out of the history.
- The AI key lives in the Windows Credential Manager. Text only goes to the AI when you click.
- Google access (refresh token), IMAP app passwords, iCal links and the OAuth client secret also live in the Credential Manager. Organize with AI and the daily summary send the full mail text to the AI you configured.
- Anything that deletes or ends a process asks for confirmation. Build leftovers are deleted for good; large files and empty folders go to the Recycle Bin.
- The text expander and the screenshot run in a separate exe, `DevboxHelper.exe`, which Devbox starts and closes.

## AI

Works with Anthropic (Claude) or any OpenAI-compatible endpoint, such as Ollama or your own gateway. Set it up in **Configurações › IA** (Settings › AI).

## Google

In **Contas › Google** (Accounts › Google), click **Adicionar conta** (Add account) and sign in with Google in the browser. Devbox talks to Google directly, no server in between. The app is not verified by Google, so sign-in shows a warning; continue through **Advanced**. Scopes: read and organize Gmail (`gmail.modify`) and read Calendar (`calendar.readonly`). The sign-in callback uses port 4083 on this machine.

Calendar only, no sign-in: in Google Calendar settings, copy the **Secret address in iCal format** and paste it under **Contas › Agenda por link** (calendar link). Any `.ics` link works.

Other mail: under **Contas › Outro e-mail (IMAP)**, enter the address and an **app password** (created in the account's security settings, with 2-step verification). The server is suggested from the domain. The connection uses Windows' own TLS (SChannel). Outlook and Hotmail do not accept passwords over IMAP.

### OAuth client

Official builds ship an OAuth client. When building from source you can use your own: the build reads `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` (environment variables, or a file outside the repo set in `DEVBOX_VAULT`) and writes the include into the `dcu` folder, which is not tracked. Without them the app asks for a client on screen. To create one (about 10 minutes):

1. At [console.cloud.google.com](https://console.cloud.google.com), create a project.
2. In **APIs & Services › Library**, enable the **Gmail API** and the **Google Calendar API**.
3. In **OAuth consent screen**, pick "External", fill in name and email and set publishing to **In production**. In "Testing", Google drops access every 7 days.
4. In **Credentials › Create credentials › OAuth client ID**, choose **Desktop app**.
5. Pass the ID and secret to the build (above) or paste them under **Contas › Google › Cliente OAuth próprio** (own OAuth client).

## Voice

In **Configurações › Voz** (Settings › Voice), turn on "Ouvir a frase de ativação", type your phrase and pick the request engine: local whisper base (CPU, ~1.2 s), local whisper large-v3-turbo (NVIDIA GPU, ~0.7 to 1.5 s on an RTX 3050), Groq or OpenAI (cloud: the request audio leaves the PC).

Voice files are not in the repository. Run `tools\voice-deps.ps1`: it downloads Vosk (~100 MB), echo cancellation (WebRTC AEC3, ~25 MB) and whisper base (~75 MB) to the `voice` folder next to the exe. `-Gpu` also downloads CUDA whisper and the large model (~1.8 GB). The cloud key goes to the Windows Credential Manager. With voice on, Windows shows the microphone as in use all the time.

## Build from source

> **Note:** Devbox uses the [ComponentesUI](https://github.com/herlondf/componentesui) component suite, which is currently **private**. Without access to it you cannot build.

You need RAD Studio 12 (Studio 22.0) and ComponentesUI at `..\Delphi\ComponentesUI`. For another location, change the project's `CUI` property.

In the IDE: open `src\Devbox.dproj` and `src\DevboxHelper.dproj` (**Win64** platform; both build to `bin\Win64\<config>`). The self-check is `tests\DevboxTests.dproj` and ends with `TUDO OK`.

## Built with ComponentesUI

Devbox is also a showcase for the suite: sidebar (`TUISidebar`), mail list (`TUIMailList`), calendar (`TUIScheduler`), audio visualizer (`TUIAudioVisualizer`, with `TUIAudioCapture`), tables with badges and sparklines (`TUIDataTable`), charts (`TUIChart`: treemap, bars), `TUIStat`, `TUISparkline`, `TUITimeline`, `TUISteps`, `TUICountdown`, `TUIRadialProgress`, `TUIVirtualList`, `TUICode`, `TUIImage`, `TUIDropdown`, `TUITabs`, `TUIFilterChip`, `TUIToggle`, `TUICheckbox`, `TUISelect`, `TUIInput`, `TUITextArea`, `TUIBadge`, `TUIStatus`, `TUIEmptyState`, `TUISwap` and `TUIToastManager`.

## License

[MIT](LICENSE).

> 🇧🇷 Versão em português: [README.md](README.md)
