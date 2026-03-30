# Skill: Telegram Communication

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** message formatting, file delivery, image generation
**Usage count:** 0

## When to Use

Every time an Officer sends a message via Telegram — whether through scripts (send-to-group.sh) or the Channels plugin reply tool.

## Acknowledging Captain Messages

When you receive a Captain DM, your VERY FIRST reply must be a single relevant emoji — nothing else. This signals that the message was received and is being worked on. Send the full response after.

Choose the emoji based on context:
- 👍 — General acknowledgment
- 🔍 — Investigating / researching
- 🛠️ — Building / implementing
- 📖 — Reading / reviewing
- 🚀 — Deploying / shipping
- ⚠️ — Noted concern / will address
- ✅ — Already done / confirming completion

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

## Generating Images (via Google Gemini API)

Officers with `GOOGLE_API_KEY` can generate images:

```bash
# Generate an image with Gemini (Nano Banana 2)
curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent" \
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

Messages are visually structured, easy to scan, and professional. The Captain can quickly parse updates without reading walls of text. Files and images are delivered directly in-chat.

## Known Pitfalls

- HTML tags in script messages must be properly closed — unclosed `<b>` breaks the whole message
- Channels plugin replies are plain text — don't use HTML tags in replies (they'll show as raw text)
- Special HTML characters (`<`, `>`, `&`) in message content must be escaped: `&lt;`, `&gt;`, `&amp;`
- Large files may fail silently — Telegram has a 50MB bot upload limit
- Image generation costs money ($0.04-0.13 per image) — use judiciously

## Validation Scenarios

- Scenario 1: Officer sends formatted group message via send-to-group.sh → renders with bold headers and bullet points
- Scenario 2: Officer receives Captain DM → immediately replies with single emoji → then sends full response
- Scenario 3: CRO generates competitive landscape image → sends to Captain via sendPhoto

## Origin

Foundation skill — ships with the Founder's Cabinet.
