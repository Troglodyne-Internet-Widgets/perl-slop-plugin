---
name: pull-requests
trigger: A command is about to run gh pr create, for any repository.  Or you are about to fix, or offer a fix for, a bug in a project that you do not maintain.
description: |
  Every pull request that fixes an issue says so with a closing keyword, or
  the issue stays open after the merge.  Before you send a fix to another
  project, find out three things.  Does it still need the fix?  Did somebody
  send it already?  What does the project enforce?  Then prepare the branch
  and the description.  The user opens that pull request.
---

# Pull requests

The hooks of this plugin ask for this skill before every `gh pr create`.

## Every pull request

If the pull request fixes an issue, end its description with a closing
keyword and the number of the issue:

    Closes #12

When the pull request merges into the default branch, GitHub closes the
issue.  A plain mention, such as "the fix for #12", only links the issue.
Nothing closes it, and it stays open until somebody notices.

- The keywords are `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`,
  `resolve`, `resolves` and `resolved`.  Use `Closes`.
- Give each issue its own keyword: `Closes #12, closes #14`.
- For an issue in another repository, name it in full:
  `Closes OWNER/NAME#12`.
- If the change only does part of the issue, or leaves a question of it open,
  do not close it.  Say what is left, and link the issue with "Part of #12".
  If the open question gets an issue of its own, close the old one and link
  the new one.

GitHub reads the keyword only when the pull request merges into the default
branch.  A pull request stacked on another branch closes nothing when it
merges.  So when the base is not the default branch, put the keyword in the
commit message too.  GitHub reads it there when the commit reaches the default
branch.

Before you open the pull request, read the description again, and make sure
that it names each issue that the change fixes.  After the merge, make sure
that each issue closed:

    gh issue view 12 --json state --jq .state

# A pull request to another project

Do steps 1 and 2 before you write the change.  So load this skill when that
work starts, not when you open the pull request.

Always pass `--repo OWNER/NAME` to `gh pr create`.  Without it, gh chooses the
repository, and in a clone of a fork it chooses the parent.

The section above applies here too, but the project decides how a pull request
links an issue.  Step 4 says how to find that out.

## 1. Make sure that the bug is still there

Read the code on the default branch of the upstream repository, as it is
now.  Do not read your clone.  A clone of a fork can be releases behind.

    git fetch upstream
    git show upstream/main:path/to/file

If the clone has no remote for upstream, add one, or read the file through
`gh api repos/OWNER/NAME/contents/PATH`.

Then find the last release tag, and list the commits after it that touch the
files of the fix:

    git log --oneline "vX.Y.Z..upstream/main" -- path/to/file

A fix there that is not released yet is a reason to stop.

## 2. Look for earlier work

Search the issues and the pull requests, open and closed.  Search for the
symptom, in the words that a user who hit it writes.  Do not search only for
the names of the functions that you changed.  The person who reported the bug
did not know those names.

    gh search issues --repo OWNER/NAME 'CNAME other domain' --limit 30
    gh api 'search/issues?q=repo:OWNER/NAME+CNAME&per_page=50' --jq '.items[]|"\(.number) \(.state) \(.title)"'

`gh search` returns few results for a phrase.  The search API with one word
returns more, and you read the titles.

A project can move to a new repository and leave its issues in the old one.
Read the README of the old repository, and search there too.  If an old issue
reports the bug, link it from the pull request.

## 3. Read what the project enforces

Read these, in this order:

1. The configuration that CI runs: the lint and test steps in `tox.ini`,
   `pyproject.toml`, `Makefile`, `.github/workflows`, `dist.ini` or the
   equivalent.
2. `CONTRIBUTING`, a pull request template, and a developer guide.
3. The changelog, and how an entry names its pull request.

When the prose and the configuration disagree, the configuration is correct,
because CI runs it.  A guide can name a linter that the project replaced.

Run the linters and the tests at the versions that the project pins, in its
lockfile or its configuration.  A newer linter has new rules, and its
findings on code that you did not change are not the project's findings.
Install the tools in a virtual environment or a local library in a scratch
directory, and not on the system.

## 4. Read how the project writes a pull request

Read five or more pull requests that the project merged from outside
contributors.  Leave out bots.  Note these things:

- how long a description is, and whether it has headings,
- how it links an issue,
- whether the changelog entry comes in the pull request, or from the
  maintainer.

## 5. Make the change

Branch from the upstream default branch, not from the default branch of the
fork:

    git switch -c NAME upstream/main

Write the test in the style of the tests of the project.  Make sure that the
test fails without the change, and quote that failure in the description.

Keep the change to the bug.  A cleanup that you noticed belongs in another
pull request, or in a sentence of the description.

## 6. Hand it to the user

A pull request is public, and it is posted under the account of the user.  So:

1. Push the branch to the fork of the user.
2. Write the description to a file in your scratch directory.  Say what was
   wrong, and what changes.  If there is an earlier issue, link it.  Say what
   you ran, and what it printed.  Follow `perl-slop:information-security`: the
   description names no host, account or customer of the user.
3. Give the user the command, with `--repo`, `--head OWNER:BRANCH`, `--base`,
   `--title`, `--body-file` and `--assignee @me`.  Do not run it yourself.

Your project can carry the same fix as a patch until the release.  If it does,
add the link to the pull request to the header of the patch.
