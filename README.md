# Break It Down

A calm, native macOS to-do app. Describe a task and an on-device model breaks it into small steps. Steps that are still big get collapsible sub-steps. Nothing leaves your machine.

## Run it

```bash
./build.sh --run
```

This builds `build/Break It Down.app` and opens it. You can drag the app into `/Applications`.

Requirements: macOS 14 or later and Xcode or the Command Line Tools (`xcode-select --install`). The default engine needs macOS 26 with Apple Intelligence turned on.

## Engines

Pick one in **Settings (⌘,) → Model → Engine**:

- **Apple Intelligence (default).** Uses Apple's on-device Foundation Model through the `FoundationModels` framework, with guided generation so the steps always come back in the right shape. There's nothing to install or start. If Apple Intelligence is off, still downloading, or this Mac doesn't support it, the sidebar says so and gives the fix.
- **LM Studio (optional).** Runs an MLX model folder from `~/.lmstudio/models` with LM Studio's headless server. The app runs `~/.lmstudio/bin/lms server start`, loads the model under the name `break-it-down`, and stops both when you quit, but only if the app started them.
- **Ollama (optional).** Uses any model you have pulled. The app runs `ollama serve` for you if it isn't already running.

## Change the model or the prompt

- **Model:** open **Settings (⌘,) → Model**. Choose the engine (and for LM Studio or Ollama, the model), then press **Restart model**. Temperature is set to 0.3 by default.
- **Prompt:** open **Settings → Prompt** and edit the rules there. You can also edit `~/Library/Application Support/BreakItDown/prompts.json` directly. **Reset to defaults** restores the original rules.

## Your data

Your lists are saved to `~/Library/Application Support/BreakItDown/data.json` on every change. Each save writes a temp file first, then renames it over the old one. Use **File → Export… / Import…** to make JSON backups.

## Keyboard

Click a step first, then use these keys:

| Key | Action |
|---|---|
| `N` | New list |
| `Enter` | Add a step |
| `Tab` / `Shift-Tab` | Indent / outdent |
| `Space` | Check or uncheck |
| `F` | Focus mode |
| `B` | Break it down (or break the selected step down further) |
| `E` | Edit |
| `↑` / `↓` | Move the selection |
| `⌥↑` / `⌥↓` | Move the step |
| `Delete` | Delete (undo is offered) |
| `Esc` | Close or cancel |
| `?` | Cheat sheet |

The **Steps** menu has ⌘ versions of these shortcuts that work anywhere.
