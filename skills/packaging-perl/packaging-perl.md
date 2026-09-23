---
name: packaging-perl
trigger: Starting a new perl distribution, or finding that an existing one cannot be released.
description: |
  Scaffold a Dist::Zilla distribution that can actually ship.
  The dist.ini, weaver.ini, critic and tidy config as templates, and the
  half-dozen things that quietly stop `dzil release` working.
---

I'm using the perl-slop:packaging-perl skill to set up a distribution.

Writing the module is the easy half. The half that goes wrong is everything
around it: a `dzil release` that stops on a changelog nobody wrote, a fresh
clone that cannot install its own author dependencies, two READMEs that disagree
because one was generated and one was typed.

Everything here is in `templates/` beside this file. Copy them, substitute, and
you have a distribution that builds, tests and releases. The rest of this
document is why each piece is there.

## Ask which perl before you copy anything

Ask the person what this has to run on. It is the first question, not a detail
to settle later: the answer picks the critic profile, the `use` line in every
module and every test, and `perl:` in `prereqs.yaml`, and changing it afterwards
means editing all of them at once.

Two answers, and they make genuinely different distributions.

**A perl you control.** One you build, or a machine you install onto, where 5.40
or later is your decision to make. Copy `templates/perlcriticrc` and declare
`use 5.040`, or higher. This is the strict profile, and it is strict *because*
of the version: the language itself now refuses indirect method calls, bareword
filehandles and code without `strict`, so the profile spends nothing on saying
so and names the rest of Perl::Critic instead.

**Whatever is already installed.** Anything that ships to somebody else's
machine, runs on a system perl, or lands in a container you do not build. Copy
`templates/perlcriticrc.compat` and declare `use 5.014`, and never lower --
`RegularExpressions::RequireDefault` wants `/aa` on every pattern and `/aa`
arrived in 5.14, so a lower declaration is one the code does not keep. Nothing
older is worth the effort either: a perl before 5.14 is a box somebody is paying
to keep alive, and supporting it is their bill.

"Already installed" is usually newer than it feels -- Ubuntu 24.04 ships 5.38
and 22.04 ships 5.34 -- so ask what the floor really is. The two profiles differ
by exactly the policies a newer perl makes pointless, each of which becomes dead
weight at a version you can look up:

| policy | dead weight from | because |
|---|---|---|
| `TestingAndDebugging::RequireUseStrict` | 5.012 | `use VERSION` turns on strict |
| `Objects::ProhibitIndirectSyntax` | 5.036 | the `indirect` feature is off |
| `InputOutput::ProhibitBarewordFileHandles` | 5.038 | `bareword_filehandles` is off |
| `InputOutput::ProhibitBarewordDirHandles` | 5.038 | the same |
| `Modules::RequireEndWithOne` | 5.038 | `module_true` |
| `Variables::ProhibitPerl4PackageNames` | 5.042 | the apostrophe package separator is gone |
| `CodeLayout::RequireASCII` | 5.042 | `source::encoding "ascii"`, which is stricter than the policy and not skippable |

So a floor of 5.038 wants the compat profile with its first five lines deleted,
and the strict profile still carries the last two because it assumes only 5.040.
Delete those two once the floor is 5.041 or later, which selects the 5.042
bundle.

Every row there was measured rather than remembered, and a new perl is a reason
to measure again rather than to trust the table:

```
perl -e 'use 5.038; open(FH, "<", "/dev/null")'   # bareword filehandle not allowed?
perl -e 'use 5.036; my $x = new Foo;'             # indirect object syntax still parsed?
printf 'use 5.042; my $s = "\xc3\xa9";' | perl   # non-ASCII character illegal?
```

## Scaffold it

```
SKILL=<this skill's directory>
mkdir -p newdist/lib newdist/t newdist/git-hooks && cd newdist && git init

cp $SKILL/templates/dist.ini              dist.ini
cp $SKILL/templates/weaver.ini            weaver.ini
cp $SKILL/templates/Changes               Changes
cp $SKILL/templates/LICENSE               LICENSE
cp $SKILL/templates/perlcriticrc          .perlcriticrc   # or perlcriticrc.compat
cp $SKILL/templates/perltidyrc            .perltidyrc
cp $SKILL/templates/preferred_modules.ini .preferred_modules.ini
cp $SKILL/templates/pod_stopwords         .pod_stopwords
cp $SKILL/templates/gitignore             .gitignore
cp $SKILL/templates/mailmap               .mailmap
cp $SKILL/templates/pre-commit            git-hooks/pre-commit
cp $SKILL/templates/CLAUDE.md             CLAUDE.md

chmod +x git-hooks/pre-commit
cp git-hooks/pre-commit .git/hooks/
```

Install the hook in every clone, including this first one -- git will not do it
for you, and a hook nobody installed is a tree that drifts.

Then substitute. The placeholders are the same in every file:

| | |
|---|---|
| `{{DIST}}` | the distribution name, as `dist.ini`'s `name =` — `Configd`, `Foo-Bar` |
| `{{VERSION}}` | `0.001` for something new |
| `{{PERL_FLOOR}}` | the perl you settled on above — `5.040` or `5.014` |
| `{{AUTHOR_NAME}}`, `{{AUTHOR_EMAIL}}` | as they should appear in POD and metadata |
| `{{COPYRIGHT_HOLDER}}`, `{{YEAR}}` | for the licence and the generated POD |
| `{{GITHUB_USER}}` | the account the repository lives under, for `[GithubMeta]` |
| `{{CPAN_ID}}` | your PAUSE id, for the `Changes` entry |
| `{{DATE}}` | today, `YYYY-MM-DD` |

```
sed -i 's/{{DIST}}/Configd/; s/{{VERSION}}/0.001/; s/{{PERL_FLOOR}}/5.040/; ...' dist.ini weaver.ini Changes LICENSE .gitignore .mailmap CLAUDE.md
grep -rn '{{' . && echo 'still some to fill in'
```

Check it before writing any code:

```
dzil authordeps --missing | cpanm --notest
dzil build && dzil test
```

## What each file is doing

**`dist.ini`** is the build. Two parts of it are not obvious:

- The `[Run::Test]` block copies the dotfiles into the build and appends them to
  `MANIFEST` by hand. Dist::Zilla does not gather dotfiles, and the author tests
  it generates need `.perlcriticrc` to be *in* the build to run against it. It
  reads like a hack because it is one.
- The `; authordep` comment lines are load-bearing. `dzil authordeps` finds
  dependencies by reading plugin names out of `dist.ini`, so it cannot see what
  Pod::Weaver pulls in, and it certainly cannot see which Perl::Critic policies
  `.perlcriticrc` names. Without those comments a fresh clone cannot install
  what it needs to build, and the error it gives is about a missing policy
  rather than about a missing list. **Add a line whenever you add a policy.**

**`CLAUDE.md`** is the procedure an agent follows here, and it is mostly a list
of which of these skills to invoke when.  It is a starting point rather than a
finished file: two of its sections are prose gaps in angle brackets -- what the
distribution is, and the documents it actually has -- and a CLAUDE.md still
describing a generic distribution is one nobody will trust the rest of.  Fill
them in with the first commit.

Whatever else you add to it, keep three things: the reading pass before the
first edit, the three review skills in that order before a commit, and the note
that the *why* belongs in the commit message rather than in a comment.  Those
are what stop an agent writing a second copy of something you already have and
then explaining it in a comment nobody asked for.

**`weaver.ini`** generates the POD boilerplate — `NAME`, `VERSION`, `AUTHORS`,
`COPYRIGHT AND LICENSE` — from what `dist.ini` already knows, and collects
`=method` and `=attr` into sections. Write the interesting POD; let it write the
rest.

**`.perlcriticrc`** is the house policy set, whichever of the two profiles the
question above picked, and it names a good number of policies that are not in
core Perl::Critic. That is what the second block of authordeps is for. Each
profile's own header says what it assumes about the perl and which policies that
assumption pays for, so read the top of the one you copied before editing it.

One policy ships commented out in both profiles. `ProhibitUnusedDefinitions`
counts calls from `bin/` and `lib/`, so in a distribution that is only a library
it reports every sub the library exists to offer -- the policy working correctly
and telling you nothing. Turn it on in a distribution that ships programs too,
and put its authordep line back when you do.

`.preferred_modules.ini` is read by the `PreferredModules` policy and is where
"use this rather than that" lives — `Cpanel::JSON::XS` over `JSON::PP`,
`YAML::XS` over `YAML::PP`, `Crypt::PRNG` over `rand`. `.pod_stopwords` is read
by `Documentation::PodSpelling`, which runs aspell over your POD: it holds the
vocabulary no dictionary has, and your own surname, which appears in the AUTHORS
section Pod::Weaver generates. A misspelling does not belong in it.

**`Changes`** exists because `[CheckChangesHasContent]` refuses to release
without it. See below.

**`.mailmap`** is for `[Git::Contributors]`, which otherwise lists the same
person once per address they have ever committed from.

**`git-hooks/pre-commit`** runs perltidy over the Perl you staged and restages
it. Tracked in the repository rather than only in `.git/hooks`, because git does
not version or clone hooks, so an untracked one exists on exactly one machine.

It is there because a `.perltidyrc` on its own does not keep a tree tidy.
Tidying a file you are changing three lines of buries the change in a hundred
lines of reformatting, so the reasonable thing is to skip it -- and then the next
person has the same reason, and the tree drifts until a mass tidy is the only way
back. A mass tidy is a diff nobody can review, and it lands on top of whatever
else is in flight. One commit's worth at a time is small enough that the question
never comes up.

If you are installing this in a distribution that has already drifted, tidy
everything in one commit of its own first, so the hook has nothing left to do and
the next diff is the change rather than the reformatting. Check that mass tidy
rather than trusting it: comparing each file's PPI token stream before and after
tells you whether anything but whitespace moved, and perltidy does occasionally
find a construct it reads differently from perl.

## The things that stop a release

Each of these has bitten a real distribution here.

**A `Changes` with nothing under the version you are releasing.** The template
has an entry for `{{VERSION}}`; keep adding one per release, above the last.
`[CheckChangesHasContent]` reads the top entry and stops if it is empty, which
is the correct behaviour and an annoying surprise at the end of a release.

**A prereq pinned to a version CPAN has not indexed yet.**
`[CheckPrereqsIndexed]` refuses the release, which is right, and lands at the
worst moment: you have just cut the dependency yourself, and PAUSE can take the
better part of an hour to index it. Wait for the index, or install the
dependency from its own checkout and release afterwards.

The same fact bites harder from the other side, where nothing stops you at all.
`[AutoPrereqs]` declares everything it finds with no version, so an install
resolves whatever the index is serving -- which, in the hour after you release
something, is the version before it. `cpanm` installs that and reports success.
If the release you just cut is the one your distribution actually needs, you now
have the old one: an option it does not recognise is merged into its own opts
and never acted on, so the call succeeds, changes nothing, and neither
distribution can show you why. Pin the version whenever a particular release is
what matters, and take the held-up release above as the price of it.

**A hand-written `README.md`.** `[ReadmeAnyFromPod]` generates one from the main
module's POD, into the repository root. Write one yourself and you have two
sources for the same text that will drift apart -- and if the hand-written one is
`Readme.md`, a case-insensitive checkout has only one of them and it is a
coin toss which. Put the prose in the module's POD, where `perldoc` finds it too.

**Author dependencies that `dzil authordeps` cannot see.** Covered above, and
worth repeating because the symptom appears on somebody else's machine rather
than yours: yours has them installed already.

**`our $VERSION` written by hand.** `[PkgVersion]` stamps every module from
`dist.ini` at build time. A version in the source is a second answer to the same
question, and it is the one that goes stale.

**Nothing in `t/`.** `[@TestingMania]` generates a pile of author and release
tests -- compile, POD syntax, POD coverage, kwalitee, unused variables -- but
none of them test what your code does. `dzil test` passing on a distribution
with an empty `t/` means the packaging is fine and says nothing else. See
[perl-slop:testing-perl](../testing-perl/testing-perl.md).

**A perl version said in one place and not the others.** Which version you are
targeting is the question at the top of this document; this is what happens when
the answer is written down inconsistently. Say it in three places and keep them
equal: the `use` line in every module, the `use` line in every test, and `perl:`
in `prereqs.yaml`.

`[@TestingMania]` includes `Test::MinimumVersion`, which reads the syntax rather
than the declaration, so a declaration lower than the code fails `dzil test`
rather than shipping. `use 5.010` over a `use re '/aa'` gives "requires 5.014
due to syntax", which is how the floor in the compat profile was found in the
first place. It does not catch the opposite mistake: declaring 5.040 in a
distribution whose code would run anywhere costs you nothing at build and costs
your users an upgrade.

## When one distribution needs both

A distribution can hold code of both kinds at once: modules that run on the perl
you build, and helper scripts that ship to a machine and run on whatever is
there. Keep both profiles, and key them to a directory rather than trying to
make one profile serve both, which ends as a set of exclusions nobody can read.

The arrangement that works is `.perlcriticrc` for the tree, `.perlcriticrc.<the
other thing>` beside it, and a pre-commit hook that sorts the staged files by
path and runs each profile over its own list. Two rules earn their keep there:
decide whether a file is perl at all before deciding which profile judges it, or
a `scripts/*.pl` lands in whichever arm of the case statement it reaches first;
and run both passes even when the first has failed, so one commit shows every
objection rather than one profile's worth at a time.

Say the split in the second profile's header, in the terms above -- which perl
that directory runs on, which policies come back because of it, and which ones
are dropped because they do not fit what those files do. A second profile whose
header says only "for scripts" is one that will drift into a copy of the first.

## Releasing

```
dzil test          # author tests as well as yours
dzil build         # look in the tarball; the MANIFEST is a common surprise
dzil release       # tags, pushes, uploads
```

`dzil release` runs `[Git::Check]` first and refuses on a dirty tree — with
`dist.ini` and `Changes` excepted, since a release edits both. It then commits,
tags `%v`, pushes and uploads to CPAN. If you do not want the upload, take
`[UploadToCPAN]` out before you find out at the end.
