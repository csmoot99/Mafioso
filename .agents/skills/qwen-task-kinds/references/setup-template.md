# Setup-file template

A project's `ai-map/qwen/<kind>.md` follows this shape, with the same headings in every project.
The qwen worker reads it at the start of every task of that kind, so keep it under about 40 lines, give only facts it acts on, and name exact paths, characters, and commands rather than process.
Replace each `<...>` with the project's own facts, and keep a section's bullets only when they hold for that project.

```markdown
# <Kind, in words> in <project>

You are making a <kind, in words>: <one line naming what changes>, exactly as your brief lists it.
Your brief lists every file you may write and every edit; this file only tells you how this project's <text or data> looks.

## Where the <text or data> is

- <What kind of content>: `<glob>`.

## How the <text or data> looks

- <The wrapping, quoting, number, date, or ordering rule the files follow, with an example copied from the project.>
- The brief quotes whole lines; copy each one character for character, including <the project's unusual characters>.

## How to edit

- `read_file` a listed file once, then change it with `edit`, using the brief's quoted lines as `old_string`.
- An edit that adds lines quotes the line they go after; keep that line in `new_string` and put the new lines under it.
- If `edit` says the text was not found, `read_file` the file once and retry with the exact text the brief quotes; never change a different line in its place.

## Never edit

`AGENTS.md`, `CLAUDE.md`, <the project's frozen or generated files>, or any file the brief does not list.

## Check

Your brief's publish command runs `<the project's check command>` after the brief's own text checks; never run it yourself.
```

The Check line's command is the one firstmate passes as `--done-command`.
It must run in a fresh copy of the project with no install step, because the helper runs it in the worker's copy before every commit.
