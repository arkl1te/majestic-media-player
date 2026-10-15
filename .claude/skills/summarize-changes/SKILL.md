---
name: summarize-changes
description: Summarize all uncommitted (unstaged) changes in the working tree, skipping the .claude directory. Use when asked to summarize, review or describe the current unstaged changes / diff / working tree, e.g. "summarize all unstaged changes", "what changed?", "what about now?" after a previous summary.
---

# Summarize unstaged changes

Always re-read the repository state; never reuse an earlier summary from the conversation,
since the working tree may have changed (or been committed) since.

## 1. Gather the state

Run in one call:

```bash
git status --short && git log --oneline -3 && git diff --stat -- . ':!.claude'
```

- If changes summarized earlier in the conversation now appear in a commit, say so in one line
  (give the commit hash).
- Untracked files outside `.claude/` count as changes: read them and include them.

## 2. Read the full diff

```bash
git diff -- . ':!.claude'
```

If the output is too large and gets persisted to a file, Read that file in full. Don't
summarize from the preview alone.

## 3. Write the summary

- Open with one line giving the totals (files, lines added and removed).
- Group changes by **feature or purpose**, not by file. Give each group a heading, and say *why*
  when the code or its comments make that clear.
- Under each group, list what changed per file using clickable links like
  [file.nim](src/file.nim), and name the new or changed procs, types, fields and config files.
- Mention user-visible behavior (menus, shortcuts, buttons, OSD messages, saved files) in plain
  terms before internals.
- Don't list patch/diff noise (whitespace, reordering) unless that's all there is.
- Don't include `.claude/` in the summary.
