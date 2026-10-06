<h1 align="center">Devbox</h1>

<p align="center">
  <b>Clipboard history, snippets and your local services in the Windows tray.</b><br>
  Win+Alt+B, type, Enter: the text lands in the window you were using.
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

## What it does

- **Clipboard history.** The last 200 copied texts, searchable. A repeated text moves to the top instead of duplicating.
- **Snippets.** Pin what you use all the time. Snippets never leave the history.
- **Pastes where you were.** Win+Alt+B opens the search from any program. Enter pastes into the previous window.
- **Keeps no secrets.** Passwords flagged by password managers (1Password, Bitwarden, KeePass) are skipped. So is text that looks like a token, a private key or a JWT.
- **Containers.** Docker Desktop on Windows, plus Podman or Docker inside running WSL distros. Start, stop, restart and read the logs.
- **WSL.** Which distros are running. Open a terminal, shut one down or shut down WSL entirely.
- **Ports.** Who listens on each TCP port and which container publishes it. Open it in the browser or end the process.

## How to use

1. Run `Devbox.exe`. It stays in the tray.
2. Copy text as usual. It shows up on the **Clipboard** tab.
3. In any program, press **Win+Alt+B**, type part of the text and press **Enter**.
4. On the **Serviços** (Services) tab, pick a row and use the buttons above it.

| Key | Does |
|---|---|
| Win+Alt+B | Opens or hides the clipboard search |
| ↑ ↓ | Pick the item |
| Enter | Pastes into the previous window |
| Esc | Hides the window |

Closing the window only hides it. To quit, use **Sair** (Exit) in the tray menu.

## Where data lives

Everything is in `%LOCALAPPDATA%\Devbox\devbox.db` (SQLite), on your machine only. Nothing goes to the network.

## Build from source

> **Note:** Devbox uses the [ComponentesUI](https://github.com/herlondf/componentesui) component suite, which is currently **private**. Without access to it you cannot build.

You need RAD Studio 12 (Studio 22.0) and ComponentesUI at `..\Delphi\ComponentesUI`. For another location, change the project's `CUI` property.

In the IDE: open `src\Devbox.dproj`. The self-check is `tests\DevboxTests.dproj` and ends with `TUDO OK`.

## Built with ComponentesUI

Devbox is also a showcase for the suite. It uses `TUITabs`, `TUIInput`, `TUIFilterChip`, `TUIVirtualList`, `TUICode`, `TUIScrollArea`, `TUIStat`, `TUIDataTable` (with colored badges), `TUIProgressBar`, `TUIToggle`, `TUISwap` (light and dark theme), `TUIEmptyState` and `TUIToastManager` (with a confirm action right in the toast).

## License

[MIT](LICENSE).

> 🇧🇷 Versão em português: [README.md](README.md)
