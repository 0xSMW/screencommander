# MAIL Skill: AppleScript + Apple Mail

Use this guide to read recent mail, filter out newsletters/spam/sales, and summarize important items from Terminal.

## What this skill covers

- Fetch emails from Apple Mail using AppleScript (`osascript`).
- Limit to today or last N messages.
- Filter non-important categories (newsletters, promos, spam-like content).
- Surface likely important messages.
- Extract unsubscribe URLs when available.
- Aggregate unsubscribe-heavy senders from the last N messages.

## Common use cases

1. Daily triage:
- "Read my emails from today and tell me what is important."
- Pull today's messages, suppress newsletter/spam/sales patterns, summarize only actionable/personal items.

2. Newsletter pressure check:
- "Search last 100 emails that have unsubscribe and report sender/newsletter."
- Scan latest 100 messages for `List-Unsubscribe`/`unsubscribe` markers and group by sender count.

3. Unsubscribe prep:
- "Get unsubscribe links for likely newsletters."
- Extract candidate unsubscribe URLs for trusted senders only.

4. Inbox hygiene audit:
- Identify recurring marketing sources and build block/filter rules from sender domains.

## Prerequisites

- macOS with Apple Mail configured and synced.
- Terminal access to run `osascript`.
- Mail permission prompts approved if macOS asks.

## Read today’s messages (Inbox)

```bash
osascript <<'APPLESCRIPT'
tell application "Mail"
  set todayStart to (current date)
  set time of todayStart to 0
  set msgs to (every message of inbox whose date received ≥ todayStart)
  set n to (count of msgs)
  if n is 0 then return "__NONE__"
  set limitN to 10
  if n < limitN then set limitN to n
  set outLines to {}
  repeat with i from 1 to limitN
    set m to item i of msgs
    set end of outLines to (i as string) & tab & (date received of m as string) & tab & (sender of m) & tab & (subject of m)
  end repeat
  set AppleScript's text item delimiters to linefeed
  set outText to outLines as string
  set AppleScript's text item delimiters to ""
  return outText
end tell
APPLESCRIPT
```

## Add lightweight importance filtering

Pattern-based filtering is fastest and usually good enough:

- Ignore likely promo/newsletter senders/domains (e.g., `substack`, `no-reply`, `news`, `updates`).
- Ignore subject keywords (e.g., `live`, `weekly`, `digest`, `% off`, `sale`).
- Keep personal/reply-like messages and direct invitations.

```bash
osascript <<'APPLESCRIPT'
on containsAny(t, needles)
  set s to (t as string)
  repeat with k in needles
    if s contains (k as string) then return true
  end repeat
  return false
end containsAny

tell application "Mail"
  set todayStart to (current date)
  set time of todayStart to 0
  set msgs to (every message of inbox whose date received ≥ todayStart)
  set blocked to {"substack", "no-reply", "newsletter", "digest", "sale", "promo", "marketing", "nextdoor local news"}
  set outLines to {}
  repeat with m in msgs
    set sdr to (sender of m as string)
    set sub to (subject of m as string)
    set hay to (sdr & " " & sub)
    if my containsAny((do shell script "printf %s " & quoted form of hay & " | tr '[:upper:]' '[:lower:]'"), blocked) is false then
      set end of outLines to (date received of m as string) & tab & sdr & tab & sub
    end if
  end repeat
  if (count of outLines) = 0 then return "__NONE_IMPORTANT__"
  set AppleScript's text item delimiters to linefeed
  set outText to outLines as string
  set AppleScript's text item delimiters to ""
  return outText
end tell
APPLESCRIPT
```

## Get short preview text for important candidates

Use message `content` to inspect intent before deciding what matters:

```applescript
set preview to content of m
if (length of preview) > 500 then set preview to text 1 thru 500 of preview
```

## Unsubscribe links: can AppleScript get them?

Yes, sometimes.

What works:
- Parse message body (`content of m`) and extract `http...` links containing `unsubscribe`.
- Parse raw RFC source (`source of m`) for `List-Unsubscribe` headers.

What does not always work:
- Some senders hide unsubscribe behind tracking redirects or one-click tokens that expire.
- Some content is MIME/HTML encoded in ways AppleScript text extraction misses.
- Some spam has no valid unsubscribe mechanism.

## Correct workflow for "last 100 with unsubscribe -> sender report"

Use raw message source for detection (more reliable than `content`).

```bash
osascript <<'APPLESCRIPT' > /tmp/mail_unsub_100.tsv
on joinLines(linesList)
  set AppleScript's text item delimiters to linefeed
  set outText to linesList as string
  set AppleScript's text item delimiters to ""
  return outText
end joinLines

tell application "Mail"
  set msgs to messages of inbox
  set n to (count of msgs)
  if n is 0 then return ""
  set limitN to 100
  if n < limitN then set limitN to n
  set outLines to {}
  repeat with i from 1 to limitN
    set m to item i of msgs
    set src to ""
    try
      set src to source of m
    end try
    if src is not "" then
      set hasUnsub to false
      ignoring case
        if src contains "list-unsubscribe" then set hasUnsub to true
        if src contains "unsubscribe" then set hasUnsub to true
      end ignoring
      if hasUnsub then
        set end of outLines to (date received of m as string) & tab & (sender of m as string) & tab & (subject of m as string)
      end if
    end if
  end repeat
  if (count of outLines) = 0 then return ""
  return my joinLines(outLines)
end tell
APPLESCRIPT

echo "MATCHES=$(awk 'END{print NR+0}' /tmp/mail_unsub_100.tsv)"
awk -F '\t' '{c[$2]++} END {for (s in c) printf "%d\t%s\n", c[s], s}' /tmp/mail_unsub_100.tsv | sort -rn
```

Interpretation notes:
- `has unsubscribe marker` is not equal to `newsletter`.
- Transactional senders (billing/security/account updates) may also include unsubscribe headers.
- Always review subject context before bulk-unsubscribing.

## Practical unsubscribe extraction (body scan)

```bash
osascript <<'APPLESCRIPT'
on replaceText(theText, searchString, replacementString)
  set AppleScript's text item delimiters to searchString
  set textItems to every text item of theText
  set AppleScript's text item delimiters to replacementString
  set newText to textItems as string
  set AppleScript's text item delimiters to ""
  return newText
end replaceText

tell application "Mail"
  set msgs to (messages of inbox)
  set limitN to 20
  set n to (count of msgs)
  if n < limitN then set limitN to n
  set outLines to {}
  repeat with i from 1 to limitN
    set m to item i of msgs
    set bodyText to content of m
    set compact to my replaceText(bodyText, return, " ")
    set compact to my replaceText(compact, linefeed, " ")
    set urls to do shell script "printf %s " & quoted form of compact & " | grep -Eo 'https?://[^ >\")\\]]+' | grep -i unsubscribe | head -n 3 || true"
    if urls is not "" then
      set end of outLines to (subject of m as string) & linefeed & urls
    end if
  end repeat
  if (count of outLines) = 0 then return "__NO_UNSUB_LINKS_FOUND__"
  set AppleScript's text item delimiters to (linefeed & "----" & linefeed)
  set outText to outLines as string
  set AppleScript's text item delimiters to ""
  return outText
end tell
APPLESCRIPT
```

## Safety guidance for spam

- Prefer `Block Sender` + move to Junk over clicking unknown unsubscribe links.
- Use unsubscribe links only from reputable senders you recognize.
- For obvious phishing, do not click links; mark as junk/phishing instead.

## Recommended operating sequence

1. Run a metadata pass:
- list sender, subject, date for scope (today or last N).

2. Run filtering pass:
- exclude obvious promo/newsletter terms.

3. Run unsubscribe-marker pass:
- use `source of m` for higher hit rate.

4. Aggregate and review:
- group by sender count, then inspect top senders manually.

5. Act safely:
- unsubscribe trusted senders; block/junk suspicious sources.
