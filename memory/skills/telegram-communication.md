# Skill: Telegram Communication

**Status:** promoted
**Created by:** foundation (evolved by CoS per Captain directive 2026-04-01)
**Date:** 2026-04-01
**Validated against:** message formatting, file delivery, image generation, reactions
**Usage count:** 0

## When to Use

Every time an Officer sends a message via Telegram — whether through scripts (send-to-group.sh) or the Channels plugin reply tool.

## Core Rules

### React to every incoming message

On **every** incoming Telegram message from the Captain, immediately react with an appropriate emoji as read-acknowledgment **before** processing or replying. Use the `react` tool from the Channels plugin:

```
react(chat_id="123", message_id="456", emoji="👀")
```

Pick an emoji that matches the message — vary your choices. The Telegram Bot API only accepts a fixed whitelist (👍 👎 ❤ 🔥 👀 🎉 🤔 😢 😁 🤯 🤬 🥰 🎃 💯 🏆 🙏 🤝 👨‍💻 ✍ 👏 🤣 🤓 💩 😡 🥱 😈 🙈 😐 😍 🤗 🕊 etc); anything outside it returns `REACTION_INVALID`. React FIRST, then process/reply.

### Always reply to the specific message

When replying to the Captain via the Channels plugin, **always** pass `reply_to` with the Captain's `message_id` from the incoming `<channel>` block. This creates a threaded quote-reply in Telegram so the Captain can see which message you are responding to.

```
# Incoming message arrives as:
# <channel source="telegram" chat_id="123" message_id="456" user="Nate" ts="...">

# When replying, pass the message_id:
reply(chat_id="123", text="Your response", reply_to="456")
```

Do this for every reply, not just replies to older messages.

### The Captain cannot access the server filesystem

The Captain does NOT have access to any files on the server. Keep this in mind for ALL Telegram communication:

- **When you tell the Captain to read a file** (e.g., "check the spec at shared/interfaces/..."), you MUST attach it using `reply(files=["/path/to/file.md"])`. Otherwise the Captain can't read it.
- **Don't attach files every time unprompted** — only when you're asking or suggesting the Captain read something specific.
- **Summaries are fine** — if you're just reporting findings, summarize in the message. Only attach when the Captain needs the full document.

**Rule of thumb:** If your message says "read this", "check this", "see the file at", or "the brief is at" — ATTACH IT. If you're just reporting status or results, summarize inline.

Using the Channels plugin reply tool:
```
reply(chat_id="123", text="Here's the spec for your review", files=["/opt/founders-cabinet/shared/interfaces/product-specs/016-pattern-insights.md"])
```

If the file is very long, summarize the key points in your message AND attach the file so the Captain has both.

## Message Formatting

### Scripts (send-to-group.sh, direct API calls) — Use HTML

Scripts use `parse_mode=HTML`. Available formatting:

```
<b>bold</b>
<i>italic</i>
<u>underline</u>
<s>strikethrough</s>
<code>inline code</code>
<pre>code block</pre>
<pre><code class="language-python">syntax highlighted code</code></pre>
<a href="https://example.com">link text</a>
<blockquote>block quote</blockquote>
```

Structure messages with clear visual hierarchy:
- Use `<b>bold</b>` for section headers
- Use bullet points (• or -) for lists with line breaks
- Use `<code>inline code</code>` for technical references (file paths, commands, issue IDs)
- Use `<pre>code blocks</pre>` for multi-line code or logs
- Use `<blockquote>quotes</blockquote>` for quoting specs or decisions
- Separate sections with blank lines

Example well-formatted message:
```
<b>🛠️ Sprint 1 — Day 2 Update</b>

<b>Completed:</b>
• SEN-403: Report/block system — <a href="https://github.com/...">PR #334</a>
• SEN-404: Account deletion — <a href="https://github.com/...">PR #335</a>

<b>In Progress:</b>
• SEN-405: Push notifications setup

<b>Blocked:</b>
• Apple Developer account needed for TestFlight

<i>Next: Starting SEN-406 after lunch</i>
```

### Replies via Channels Plugin — Plain Text

The Channels plugin currently sends plain text (no parse_mode support). Structure replies with:
- ALL CAPS for emphasis (sparingly)
- Dashes (-) for bullet lists
- Blank lines between sections
- Backtick-style code references won't render but are still readable

## Sending Files

Officers can send files through the Telegram Bot API:

```bash
# Send a document
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
  -F chat_id="$CHAT_ID" \
  -F document=@"/path/to/file.pdf" \
  -F caption="<b>Description here</b>" \
  -F parse_mode="HTML"

# Send a photo
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
  -F chat_id="$CHAT_ID" \
  -F photo=@"/path/to/image.png" \
  -F caption="<b>Description here</b>" \
  -F parse_mode="HTML"

# Send audio
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendAudio" \
  -F chat_id="$CHAT_ID" \
  -F audio=@"/path/to/audio.mp3" \
  -F caption="Description"
```

Use the Captain's chat ID from environment for DMs, or `$TELEGRAM_HQ_CHAT_ID` for the group.

## Sending Generated Images (logos, screenshots, AI art)

**Always send generated images as DOCUMENTS, not photos.** The Channels plugin reply tool and `sendPhoto` API compress images to ~158KB thumbnails. Use `sendDocument` to preserve full quality.

```bash
# CORRECT — full quality via sendDocument
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
  -F chat_id="$CHAT_ID" \
  -F document=@"/path/to/generated-image.png" \
  -F caption="<b>Description here</b>" \
  -F parse_mode="HTML"
```

**Do NOT use:**
- `reply(files=["/path/to/image.png"])` — compresses to thumbnail
- `sendPhoto` API — compresses to thumbnail

This applies to: AI-generated images (Gemini), screenshots, logos, mockups, diagrams — any image where quality matters. Regular photos (camera shots, memes) can still use `sendPhoto`.

## Voice Messages (optional — disabled by default)

When enabled in `instance/config/product.yml`, officers send a voice message alongside text replies. Each officer has their own voice (configured by voice_id).

```bash
# Send a voice message to the Captain or group
bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$CHAT_ID" "Your message text"
```

The script:
1. Checks if voice is enabled in config
2. Reads the officer's voice_id from config
3. Generates audio via ElevenLabs API
4. Sends via Telegram's sendVoice API

**Config in `instance/config/product.yml`:**
```yaml
voice:
  enabled: false              # Set to true to activate
  provider: elevenlabs
  model: eleven_flash_v2_5    # Fastest model
  mode: all                   # all | captain-dm | group | briefings
  voices:
    cos: "voice_id_here"
    cto: "voice_id_here"
    cpo: "voice_id_here"
    cro: "voice_id_here"
```

**Mode options:**
- `all` — every message gets a voice version
- `captain-dm` — only DM replies to Captain
- `group` — only warroom messages
- `briefings` — only scheduled briefings (morning/evening)

**When to send voice:** Check the `mode` config. If mode matches the current context (DM, group, briefing), call `send-voice.sh` after sending the text message. The voice message is supplementary — always send text first.

## Generating Images (via Google Gemini API)

Officers with `GOOGLE_API_KEY` can generate images using Nano Banana 2:

```bash
# Generate an image with Gemini Nano Banana 2
curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent" \
  -H "x-goog-api-key: $GOOGLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{"parts": [{"text": "Generate an image of: YOUR PROMPT HERE"}]}],
    "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]}
  }'
```

The response contains base64-encoded image data. Save it to a file, then send via `sendPhoto`.

Use cases: competitive landscape visuals, UI mockups, architecture diagrams, data visualizations for briefings.

## Expected Outcome

Messages are visually structured, easy to scan, and professional. The Captain can quickly parse updates without reading walls of text. Files, images, and voice messages are delivered directly in-chat. Every incoming message gets an instant emoji reaction as read-acknowledgment.

## Known Pitfalls

- HTML tags in script messages must be properly closed — unclosed `<b>` breaks the whole message
- Channels plugin replies are plain text — don't use HTML tags in replies (they'll show as raw text)
- Special HTML characters (`<`, `>`, `&`) in message content must be escaped: `&lt;`, `&gt;`, `&amp;`
- Large files may fail silently — Telegram has a 50MB bot upload limit
- Image generation costs ~$0.07 per image (Nano Banana 2 at 1K) — use judiciously
- Voice generation costs per character (ElevenLabs) — keep voice messages concise
- Always send text FIRST, voice SECOND — text is the record, voice is the supplement
- Only listed emoji work for reactions — others return REACTION_INVALID from Bot API
- Don't use the same reaction emoji every time — vary based on message content

## Validation Scenarios

- Scenario 1: Officer sends formatted group message via send-to-group.sh → renders with bold headers and bullet points
- Scenario 2: Voice enabled + mode=all → officer sends text reply then voice message to Captain
- Scenario 3: Voice disabled → send-voice.sh exits silently, no error
- Scenario 4: CRO generates competitive landscape image → sends to Captain via sendPhoto
- Scenario 5: Captain sends a message → Officer reacts with appropriate emoji within seconds, then processes and replies

## Origin

Foundation skill — evolved per Captain directive 2026-04-01. Added: Reactions section (react to every incoming message), Core Rules restructured, file sending rule added.
