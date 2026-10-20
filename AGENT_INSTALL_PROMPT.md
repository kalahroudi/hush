## Install with an AI agent

Paste this into an AI coding agent such as Claude Code. Hush checks and installs its own prerequisites on first launch, so the agent does not have to:

```text
Install Hush on this Mac.
1. Run: curl -fsSL https://raw.githubusercontent.com/kalahroudi/hush/main/scripts/install.sh | bash
2. Hush opens and its setup checks what it needs. Tell me to click "Set everything up" if it is waiting.
   It also asks for a free Telegram API ID and hash from https://my.telegram.org/apps. I will enter them
   myself in the Hush window. Do not ask me to paste them into this chat.
3. Tell me to sign in with my phone number in the Hush popover (menu bar dot), then wait until it shows my chats.
4. Register its MCP server: claude mcp add hush --scope user -- /Applications/Hush.app/Contents/MacOS/hush-mcp
5. Call hush_status and tell me what it reports.
Only send a message with hush_send after I tell you what to say. Every send also needs my approval in a dialog.
```
