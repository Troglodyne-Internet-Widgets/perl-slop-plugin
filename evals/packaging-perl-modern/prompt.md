---
description: "A distribution for a perl we build gets the strict profile and a 5.040 floor everywhere."
tags: [packaging-perl]
max_turns: 120
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
---

Start a new CPAN distribution for me, in a directory named Text-Rot13 here.  It has
one module, Text::Rot13, with a function rot13() that rotates the letters of a
string by thirteen, and one test, t/rot13.t.  It only ever runs on a perl that we build ourselves, 5.40 or newer.

The author is Jane Doe <jane@test.test>, PAUSE id JDOE, and it lives under the
GitHub account jdoe.  The copyright holder is Example Co, 2026.

Set up everything a distribution of mine starts with: the build, the critic and
tidy configuration, the git hooks and so on.  Do not run dzil or cpanm, or
install anything: I will build it myself on another machine.  When you are
done, say which perl it targets and list the files you created.
