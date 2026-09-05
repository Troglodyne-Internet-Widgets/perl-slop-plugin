---
name: reading-perl
trigger: About to change a block of code somebody else wrote, or that you no longer remember writing.
description: |
  Find out why a line is the way it is before you change it.
  git blame, the commit behind it, and the questions to ask of code whose
  reasons are not in front of you.
---

I'm using the perl-slop:reading-perl skill to understand code before changing it.

Most of the code you touch is older than the conversation you are having about
it. The line that looks pointless usually is not; it is the scar left by
something that went wrong once, and the reason is written down somewhere other
than the file. Find it before you take the line out.

This is a reading pass, not an editing one. Do it before the first edit to a
block, not after the tests fail.

## Start with blame

    git blame -L <start>,<end> path/to/File.pm

That gives you a commit per line. For the one that put the odd line there:

    git show <sha>

Read the message, not just the diff. A good message says what was wrong and why
this was the fix -- which is exactly the thing the code cannot tell you. Then
read the rest of that commit: the line you are looking at is often one of
several that only make sense together, and changing one of them alone is how you
half-undo somebody's fix.

Two flags earn their keep:

- `git blame -w` ignores whitespace, so a reindent does not hide the real author.
- `git blame -C -C` follows a block that moved between files, which is what you
  want when blame says the whole function arrived in one "move X to Y" commit.
  Keep adding `-C` until the history stops being a move.

`git log -L <start>,<end>:path` gives you the same region's whole history in one
go, oldest change last. Reach for it when the top commit turns out to be a move
or a reformat.

## What you are looking for

- **Is this line load-bearing?** Something that reads as redundant -- a second
  call, an explicit sort, a sleep, a seemingly no-op assignment -- is the usual
  shape of a bug fix. If the commit says so, leave it alone and say why in your
  own commit.
- **What did the previous version look like?** Knowing what was tried and
  abandoned stops you proposing it again. This is the single most common way a
  fix gets reverted by accident.
- **Is there a test pinning this?** `git show` usually tells you. If a test came
  in with the line, that test is the specification for the behavior you are about
  to change; read it before deciding your change is safe.
- **Does the comment still match the code?** When blame shows the comment and the
  code beneath it arriving in different commits, distrust the comment. Check the
  later one and fix the drift while you are here.
- **Who else calls this?** Grep for it. Blame tells you why it exists; callers
  tell you what breaks. Both, before you change a signature.

## When the history does not answer

Sometimes the commit says `wip` and the author is gone. Then:

- Say so. A change made without knowing the reason is a guess, and the commit
  message should admit it: "no history explains the second call; removing it,
  tests pass."
- Look for the reason outside the repo -- an issue number, a ticket, a comment in
  a related file, the upstream project's own changelog if the line is working
  around somebody else's bug.
- If it is genuinely load-bearing and nobody knows why, that is a question for
  the user, not a thing to resolve on your own judgement.

## Then write it down

What you learned reading is what the next person will need, and the place for it
depends on which kind it is:

- The reason *your* change is being made goes in your commit message, where
  blame will find it. That is this whole loop closing.
- A non-obvious fact about the code as it now stands -- why this order, why this
  constant is load-bearing -- goes in a comment, because blame is a thing people
  reach for after they are already confused.

See [perl-slop:reviewing-perl](../reviewing-perl/reviewing-perl.md) for where
the line between those two falls.
