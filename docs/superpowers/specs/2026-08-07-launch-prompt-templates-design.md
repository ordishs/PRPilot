# Launch Prompt Templates

**Date:** 2026-08-07
**Status:** Approved

## Problem

PR Pilot hard-codes the first prompt of every session: `/review <url>` for PRs,
`/start-issue <number>` for issues. What those commands *do* is decided upstream and keeps
moving. On 2026-08-06 Claude Code 2.1.223 removed the standalone `/review` PR command and
folded it into `/code-review`, which dispatches the review to a background workflow and
reports findings through `ReportFindings`. The result reads as verbose and no longer ends
with an explicit APPROVE / REQUEST CHANGES / COMMENT verdict.

That specific regression can be papered over with a prompt tweak, but the underlying
problem is structural: the launch prompt is upstream's to define and the user has no say.
This will happen again.

## Goals

- Let the user own the exact first prompt of a review session and an issue session.
- Keep today's behaviour as the default, so nothing changes until the user edits it.
- Make the text safe to type — quotes, apostrophes and newlines must not break the launch.

## Non-Goals (YAGNI)

- A separate "system prompt" field. `--append-system-prompt` remains available through the
  existing **Claude arguments** setting for anyone who wants it.
- Per-repository or per-item templates.
- Validating that the template names a real slash command. If it does not, Claude receives
  it as ordinary text, which is a legitimate thing to want.

## Verified mechanics

Two facts were confirmed against Claude Code 2.1.223 before designing this, because the
whole approach rests on them:

1. A multi-line first prompt still resolves as a slash command, and `$ARGUMENTS` receives
   everything after the command name, newlines included. Probed with a throwaway
   `/echo-args` command:
   `ARGS=[https://github.com/o/r/pull/1\n\nAlways end with VERDICT: APPROVE]`
2. The built-in `/code-review` forwards trailing instructions into the workflow: *"Everything
   after the level in the args string is passed to the workflow as the review target /
   instructions."* So user text reaches the finders, not merely the closing summary.

## Architecture

### Settings (`PRPilotModels`)

```swift
public var reviewPromptTemplate: String  // default "/review {url}"
public var issuePromptTemplate: String   // default "/start-issue {number}"
```

Both decode with `decodeIfPresent ?? default`, so existing stores migrate silently and a
user who never touches the fields keeps exactly today's behaviour.

### `LaunchPrompt` (`ClaudeSessionKit`)

A pure renderer beside `ClaudeLaunchBuilder`:

```swift
public enum LaunchPrompt {
    public static func render(_ template: String, for item: WorkItem, url: URL?) -> String
}
```

Placeholders: `{url}`, `{number}`, `{owner}`, `{repo}`, `{title}`.

Rules:

- Every occurrence of a known placeholder is substituted, not just the first.
- An unknown placeholder is left verbatim. Blanking it would turn a typo into a subtly
  different prompt that still looks plausible in the transcript; leaving `{urls}` visible
  makes the mistake obvious at a glance.
- A placeholder with no value for this item (`{url}` on an item with no URL) renders empty.
- A template that is empty or whitespace-only renders to `""`, and the builder then appends
  no prompt argument at all — the session opens interactively. That is already what happens
  today for an item with neither a PR nor an issue number.

### `ClaudeLaunchBuilder`

The two hard-coded strings become renders, under the same guards as today:

```swift
if review.prRef != nil, let url = review.url {
    let prompt = LaunchPrompt.render(settings.reviewPromptTemplate, for: review, url: url)
    if !prompt.isEmpty { args.append(prompt) }
} else if review.issueNumber != nil {
    let prompt = LaunchPrompt.render(settings.issuePromptTemplate, for: review, url: review.url)
    if !prompt.isEmpty { args.append(prompt) }
}
```

The resume path is untouched: `--resume` sends no prompt, exactly as now.

### Safety

The rendered prompt is one element of `ClaudeLaunchSpec.arguments`, and `ClaudeSession`
shell-escapes each argument. Apostrophes, quotes and newlines in the template are therefore
safe. This is the concrete advantage over hand-writing `--append-system-prompt '...'` into
the **Claude arguments** field, which is spliced into the command line raw
(`ClaudeSession.swift:110`) and breaks on a single apostrophe.

### Settings UI (`App/SettingsView.swift`)

A "Launch prompts" section in the Claude tab: two multi-line monospaced `TextEditor`s
(review, issue), a caption naming the available placeholders, and a Reset button per field
that restores the default. Commits follow the tab's existing `.onChange` pattern.

## Example

The verdict problem this was raised for is solved by editing the review template to:

```
/review {url}

End with a single line: VERDICT: APPROVE | REQUEST CHANGES | COMMENT.
Keep the summary under 10 lines.
```

Whether a given wording produces the desired result is a prompting question the user tunes
against a real PR. The point of this design is that tuning it no longer requires an app
change.

## Testing

**`LaunchPrompt`**: each placeholder substituted; a placeholder repeated twice; unknown
placeholder left intact; whitespace-only template → empty; multi-line template preserved
verbatim; a template with no placeholders passed through; missing value renders empty.

**`ClaudeLaunchBuilder`**: default settings still emit exactly `/review <url>` and
`/start-issue <number>` (the existing assertions stay green and unmodified); a custom review
template is used; a custom issue template is used; a blank template appends no prompt
argument; the resume path still appends none.

**`Settings`**: a stored payload without the two keys decodes to the defaults.
