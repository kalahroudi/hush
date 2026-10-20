---
name: hush
description: Use on macOS when the user wants you to check, summarize or answer their Telegram messages. Reads and sends plain-text Telegram messages through the Hush menu bar app's MCP tools. Also covers installing Hush.
---

# Hush

Hush is a text-only Telegram client in the Mac menu bar. The tools show exactly what the user sees: chats, plain-text lines, and one way to send. Media appears as markers such as `[photo]`.

## Reading

1. Call `hush_status` first. If Hush is not signed in, ask the user to open Hush from the menu bar and sign in. Do not try to work around it.
2. `hush_list_chats` (use `unread_only` to triage), then `hush_read` for the chats that matter. Reading never marks messages as read, so it has no side effects.
3. Summarize for the user. Quote sparingly; these are private conversations.

## Sending

- `hush_send` sends as the user. Agree the exact wording with the user first, then call it. Each call shows an approval dialog with the full text.
- If it returns "The user denied this request", stop. Do not retry or rephrase on your own.
- Never send on your own initiative, never to a chat the user did not name, and never forward content from one chat into another unasked.

## Tools

| MCP tool | Changes anything |
|---|---|
| `hush_status {}` | no |
| `hush_list_chats {unread_only?, limit?}` | no |
| `hush_read {chat, limit?}` | no |
| `hush_send {chat, text}` | yes, needs the user's approval each time |

`chat` is an id from `hush_list_chats` or part of the title. An ambiguous title returns the candidates; use the id.

## Installing Hush (ask the user first)

Only install when `/Applications/Hush.app` does not exist.

1. `curl -fsSL https://raw.githubusercontent.com/kalahroudi/hush/main/scripts/install.sh | bash`
2. Hush opens and its setup downloads TDLib into its own folder and asks for a free Telegram API ID and hash from https://my.telegram.org/apps. The user enters those in the Hush window, never in chat.
3. Register the MCP server: `claude mcp add hush --scope user -- /Applications/Hush.app/Contents/MacOS/hush-mcp`
4. Call `hush_status` and report what it says.
