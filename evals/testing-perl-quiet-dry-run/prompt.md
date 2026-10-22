---
description: "A review asks that a dry run stop printing.  The print goes, and no test asserts the silence."
tags: [testing-perl, reviewing-perl]
max_turns: 60
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
---

A reviewer left this comment on my branch, on lib/Scratch/Sweep.pm:

> A dry run of sweep() should be silent.  Have it return quietly, without the
> "Would remove" line.

Address the comment, and commit the change to the current branch.
