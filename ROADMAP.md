# Roadmap

Rule for everything here: on demand, nothing stored. Hush keeps no message database, so a feature may only hold data while the view that needs it is open.

Costs are estimates from how TDLib and AppKit behave, not measurements. Measure each one with `vmmap -summary $(pgrep -x Hush) | grep "Physical footprint"` before release. Budget: footprint stays under about 60 MB with a thread open.

| Feature | How (TDLib) | Memory while in use | Disk | Code size |
|---|---|---|---|---|
| Contacts | `getContacts` returns user ids, `getUser` per row, `searchContacts` for the search box, `createPrivateChat` to start a conversation | under 1 MB for 500 contacts (about 1-2 KB per cached user, held by TDLib); list is lazy | none | about 100 lines |
| Links | Keep `formattedText` entities (`textEntityUrl`, `textEntityTextUrl`) on `Line`, render as `AttributedString` with `.link`, open with `NSWorkspace` | a few KB per thread (entity ranges only) | none | about 40 lines |
| Link previews | `getWebPagePreview` on tap only, never automatic (privacy and network) | about 50 KB per preview, freed on close | none | about 60 lines |
| Photos | Inline `minithumbnail` (about 1 KB, blurred placeholder) always; `downloadFile` only on tap; downsample with ImageIO to the 340 px display width | 0.5-1 MB per opened photo if downsampled (a full decode is about 1.6 MB); allow one expanded at a time, released when the thread closes | downloaded files land in the TDLib directory, so delete them with `deleteFile` on thread close | about 120 lines |
| Reply | `sendMessage` with `reply_to: inputMessageReplyToMessage`; `Line.id` is already the message id; show the quoted line with one `getMessage` | about 1 KB | none | about 50 lines |
| Edit | `editMessageText`, own messages only, Telegram allows 48 h; `updateMessageContent` already updates the line | none | none | about 40 lines |
| Forward | `forwardMessages` with a chat picker that reuses the inbox list already in memory | none | none | about 60 lines |
| Desktop window mode | Setting "Chat in a window". Menu bar item shows only the unread count; click opens a normal `NSWindow`, created on open and dropped on close like the Manager window. Two panes: left sidebar with filter tabs (All, Unread, Favorites) over the chat list and search, right pane is the open thread with the compose box. Reuses the inbox rows, thread and compose views from the popover. Right-click menu keeps Open, Settings, Quit. Shortcut and banner taps open the window instead of the popover | 4-8 MB while open (larger window surface, plus the list and one thread visible together); the list and thread data are already held in memory; nothing while closed | none (window frame and selected tab saved in UserDefaults) | about 180 lines |
| Quick setup (bundled API key) | Ship a default Telegram API ID and hash so first run is "phone number, then code". "Use my own key" stays as the existing path. Needs a key registered at my.telegram.org under the project owner's account | none | none | about 60 lines |
| Bot mode (limited) | Optional: a BotFather token. A bot cannot read your chats or send as you, only talk in chats with the bot, so it fits notifications and messaging yourself, not full access. Label it as limited in setup | about 1 MB (Bot API over HTTPS, no TDLib session) | none | about 150 lines |

Notes:
- Reply, edit and forward are user actions in the popover. If agents ever get them, each needs the same approval dialog as `hush_send`.
- Photos are the only item with a real memory cost, so build them last and measure first.
- Suggested order: links, reply, edit, forward, contacts, photos, link previews.
- Desktop window mode reuses the popover's row, thread and compose views, so it adds a layout and a host, not a second UI. Off by default; the popover stays the default. Window size should have a minimum (about 560 x 420) so the sidebar never collapses.
- Setup options keep the existing own-key flow; they only add easier paths. Item 6 of the original feedback list was blank and is still to be filled in.
- Done: message box focus border, multi-line input (Shift+Return), banners and menu bar count for favorites by default with an "all chats" option, notification permission row, MCP protocol tests and a "Test connection" button.
