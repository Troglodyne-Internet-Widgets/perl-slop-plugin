# perl-slop-plugin

LARTs clod into making less cracked edits to perl code

In general I am positively disposed toward perigrin's [perl skills](https://github.com/perigrin/perl-development-plugin),
but this being perl, TIMTOWTDI.

To prefer any of my skills to others, you'll need to slap something like this in your `~/.claude/settings.json`:

```
"SkillOverrides": {
    "PluginYouWannaOverride:skillname": "name-only"
}
```


## Hooks that ask for the skills

A CLAUDE.md can say "load this skill before you do that", and the model can
forget.  So the plugin also has hooks, in `hooks/hooks.json`, which refuse an
action until the skill that it needs is loaded.  A refusal names the skills
that are missing, and the model loads them and tries again.

`perl-slop:information-security` is for prose in any language, so its gates
apply to every project, Perl or not.

- Before an edit to any file, `perl-slop:information-security`, because an
  edit can add comments.  This covers the Edit and Write tools.  For a Bash
  command that writes a file, the gate applies only to a Perl file, as in the
  next item.  The hook finds the files that a command writes by their Perl
  names.  A gate on every redirect also refuses `2>&1`, so there is none.
- Before an edit to a Perl file, `perl-slop:reading-perl` too.  This covers
  the Edit and Write tools, and a Bash command that writes a Perl file with
  `sed -i`, `perl -i`, `python3`, a redirect, `tee`, `cp`, `mv`, `install` or
  `patch`.  A Perl file is a `.pm`, `.pl`, `.t` or `.psgi` file, or a file
  with a `perl` shebang.
- Before any `git commit`, `perl-slop:information-security`, for the commit
  message.  When any changed file is Perl, also `perl-slop:data-perl`,
  `perl-slop:testing-perl` and `perl-slop:reviewing-perl`.  Each must be
  loaded since the last commit in the session.  The changed files are what
  `git status` shows, staged or not, because a command that adds and commits
  has not added anything yet when the hook runs.
- Before a post to an issue, a pull request, a review, a release or a gist,
  `perl-slop:information-security`.  This covers `gh` and `glab` commands
  that write, and `gh api` with a field or a write method.  It also covers MCP
  tools whose names say that they create, add, update, post, submit, reply to
  or merge one of those.
- On every prompt until it is loaded, a reminder of
  `perl-slop:information-security`, because a reply to the user is prose too.
  When a prompt is about speed in a Perl project, a reminder of
  `perl-slop:profiling-perl`.  Reminders do not refuse anything.

A `git commit`, `gh` or `glab` in the body of a heredoc is data, and does not
count as a command.

A skill counts when it is loaded after the last compaction, because a
compaction takes it out of the model's context.

A repository can ask for more skills in a `.perl-slop.json` at its root.  Each
gate maps a path glob to skills: `**` is any path, `*` is any name, and `?`
is one character of a name.

```json
{
  "before_edit":   { "lib/My/Recipe/**": ["writing-recipes"] },
  "before_commit": { "templates/**":     ["provisioning-recipes"] }
}
```

A `before_commit` entry applies to any changed file that matches it, Perl or
not.

The hooks read the session transcript to learn which skills are loaded.
Claude Code does not document the format of that file.  If a new version of
Claude Code changes it, the hooks can stop seeing a skill that was loaded,
and refuse every edit to Perl.  If a refusal names a skill that you know is
loaded, turn the gates off as below, and report it.

The hook is `hooks/skill-gates.pl`.  It runs on the perl on your `PATH`, with
core modules only, and uses `Cpanel::JSON::XS` when it is installed, to read
a long transcript faster.  If the hook fails, the action is allowed.  To turn
the gates off, set `PERL_SLOP_GATES=0` in the environment that starts Claude
Code.  Its tests are `prove t/`.
