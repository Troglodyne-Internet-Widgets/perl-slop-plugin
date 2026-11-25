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

Everything here is in `templates/` beside this file, and `conformance/` says
which of them a distribution gets, under which names. The `conformance` program
from Dist::Conformance reads those flavors, writes the templates with their
placeholders filled in, and installs the hooks. The result is a distribution
that builds, tests and releases. The rest of this document is why each piece is
there.

## Ask which perl before you copy anything

Ask the person what this has to run on. It is the first question, not a detail
to settle later: the answer picks the critic profile, the `use` line in every
module and every test, and `perl:` in `prereqs.yml`, and changing it afterwards
means editing all of them at once.

Two answers, and they make genuinely different distributions.

**A perl you control.** One you build, or a machine you install onto, where 5.40
or later is your decision to make. Use the flavor `troglodyne-5.040`, which
writes `templates/perlcriticrc`. Declare `use 5.040`, or higher. This is the
strict profile, and it is strict *because* of the version: the language itself now refuses indirect method calls, bareword
filehandles and code without `strict`, so the profile spends nothing on saying
so and names the rest of Perl::Critic instead.

**Whatever is already installed.** Anything that ships to somebody else's
machine, runs on a system perl, or lands in a container you do not build. Use
the flavor `troglodyne-compat`, which writes `templates/perlcriticrc.compat`.
Declare `use 5.014`, and never lower.
`RegularExpressions::RequireDefault` wants `/aa` on every pattern and `/aa`
arrived in 5.14, so a lower declaration is one the code does not keep. Nothing
older is worth the effort either: a perl before 5.14 is a box somebody is paying
to keep alive, and supporting it is their bill.

If the person does not know, decide by what the distribution is. An application
or a service usually runs where its owner controls the perl, so it takes the
modern flavor. Development tooling takes the compat flavor. Examples are a
Perl::Critic policy, a Dist::Zilla plugin, or a program that checks or builds
other distributions. Such a tool runs inside somebody else's project, on the
perl that the project already has. The more projects can run it, the more
useful it is.

"Already installed" is usually newer than it feels. Ubuntu 24.04 ships 5.38,
and 22.04 ships 5.34, so ask what the floor really is. The two profiles differ
by the policies that a newer perl makes pointless. Each becomes dead weight at
the version in this table:

| policy | dead weight from | because |
|---|---|---|
| `TestingAndDebugging::RequireUseStrict` | 5.012 | `use VERSION` turns on strict |
| `Objects::ProhibitIndirectSyntax` | 5.036 | the `indirect` feature is off |
| `InputOutput::ProhibitBarewordFileHandles` | 5.038 | `bareword_filehandles` is off |
| `InputOutput::ProhibitBarewordDirHandles` | 5.038 | the same |
| `Modules::RequireEndWithOne` | 5.038 | `module_true` |
| `Variables::ProhibitPerl4PackageNames` | 5.042 | the apostrophe package separator is gone |
| `CodeLayout::RequireASCII` | 5.042 | `source::encoding "ascii"`, which is stricter than the policy and not skippable |

The floor picks the flavor and nothing else. A floor below 5.040 takes
`troglodyne-compat`, and a floor of 5.040 or later takes `troglodyne-5.040`.
At a higher floor, a policy in the table reports nothing, so it costs nothing.
Leave the profile as `conformance` writes it, and do not tune it to the floor.

Every row there was measured rather than remembered, and a new perl is a reason
to measure again rather than to trust the table:

```
perl -e 'use 5.038; open(FH, "<", "/dev/null")'   # bareword filehandle not allowed?
perl -e 'use 5.036; my $x = new Foo;'             # indirect object syntax still parsed?
printf 'use 5.042; my $s = "\xc3\xa9";' | perl   # non-ASCII character illegal?
```

## Scaffold it

The scaffold needs the `conformance` program, from the CPAN distribution
Dist::Conformance. Make the directory and its repository, and write a
`.conformance.yml` at its root:

```
mkdir -p Foo-Bar/lib Foo-Bar/t && cd Foo-Bar && git init
cat > .conformance.yml <<'YAML'
flavor: troglodyne-5.040        # or troglodyne-compat
source:
  git: https://github.com/Troglodyne-Internet-Widgets/perl-slop-plugin.git
  path: skills/packaging-perl
variables:
  DIST: Foo-Bar
  AUTHOR_NAME: A. Tester
  AUTHOR_EMAIL: tester@test.test
  COPYRIGHT_HOLDER: Test Co
  YEAR: '2026'
  CPAN_ID: TESTER
YAML
```

The flavor is the answer to the question above. The variables fill the
placeholders of the templates:

| | |
|---|---|
| `DIST` | the distribution name, as `dist.ini`'s `name =`, for example `Configd` or `Foo-Bar` |
| `AUTHOR_NAME`, `AUTHOR_EMAIL` | as they must appear in POD and metadata |
| `COPYRIGHT_HOLDER`, `YEAR` | for the licence and the generated POD |
| `CPAN_ID` | your PAUSE id, for the header of each entry in `Changes` |

The flavor sets two more. `VERSION` is `0.001`, the version of the first
release, and `PERL_FLOOR` is `5.040` or
`5.014`. If the floor is another version, for example `5.038`, set
`PERL_FLOOR` in `variables` too. Quote each value that looks like a number.

Then write the files:

```
conformance update --standards <the root of this plugin>
conformance check  --standards <the root of this plugin>
```

`--standards` reads the flavors from this copy of the plugin, the version whose
skill you are reading, and fetches nothing. Without it, `conformance` fetches
the repository that `source` names. `update` writes each template under its
name, with its placeholders filled in. It makes the hooks executable and
installs them into `.git/hooks`. If no variable fills a placeholder of a
template, `update` does not write that file, and it says which variable to add.
`check` must report a pass for each check.

`update` never overwrites a file that exists, with two exceptions.
`.perlcriticrc` is one, as the next paragraph says. `metamerge.yml` is the
other: if it does not declare the packages of its template, `update` adds
them, as the section on that file says. So you can run `update` again in a
clone, which then gets the hooks that git does not install for it. You can also run it in an older
distribution, which then gets the files that it lacks. So the procedure is the
same for a new distribution and an old one. Run `update`, then `check`, and do
what each one says until `check` passes. `check` reports `info` for a hook that
differs from its template. Merge such a hook by hand.

Do not edit `.perlcriticrc`. `update` writes it from the template of the
flavor, with the overrides of the distribution applied, and replaces anything
else. Declare each departure from the template in `.conformance.yml`, with a
comment that says why:

```yaml
checks:
  CriticProfile:
    overrides:
      # The programs run from the checkout until the first release.
      logicLAB::RequireSheBang:
        formats: '#!/usr/bin/env perl'
      Subroutines::ProhibitExcessComplexity:
        max_mccabe: 30
      ValuesAndExpressions::ProhibitMagicNumbers: off
      Some::Policy::OfItsOwn: {}
    settings:
      severity: 3
```

A mapping sets parameters over those of the template, and `~` removes one.
`off` turns a policy off. An empty mapping enables a policy with the
parameters of the template, so it adds a policy that the template lacks, or
turns on one that the template turns off. `settings` does the same for the
global keys, such as `severity`. Each policy of your own also needs an
authordep line in `dist.ini`. `check` fails a profile that differs from the
template with the overrides in any policy, parameter or setting, and names
each difference.

In a distribution whose `.perlcriticrc` already has changes of its own, run
`conformance adopt` before the first such `update`. It prints the overrides
that keep what the profile has now. Merge them into `.conformance.yml`, and
delete each one that is drift rather than a choice.

`update` also writes two files that Claude Code reads, and `check` fails a
distribution without them. `.claude/settings.json` enables this plugin and
simple-english, and it names their marketplaces. So Claude Code offers to
install both plugins in a new clone. `.perl-slop.json` requires the skill
`simple-english:simple-english` before an edit of a Markdown file, a POD file
or `Changes`. The hooks of this plugin ignore a key in `.perl-slop.json` that
they do not read, so `check` fails such a key. Commit both files.

Commit `.conformance.yml` with the rest. It records which flavor the
distribution follows, so that `conformance check` can find a file that drifts
from the standard later.

Commit the scaffold, with a `Changelog:` trailer. A trailer is a `Key: value`
line in the last paragraph of a commit message. `Changes` gets its entries from
these trailers, and a `Changes` with no entry fails the release tests:

```
git add -A
git commit -m 'Scaffold Foo-Bar' --trailer 'Changelog: Initial release'
```

Then check it before writing any code:

```
dzil authordeps --missing | cpanm --notest
dzil build && dzil test --release
```

Plain `dzil test` runs the author tests and not the release tests.
`[@TestingMania]` makes some of its tests release tests, unused variables among
them, and `dzil release` runs them.  So check with `--release`, or the first
release finds what the checks did not.

## What each file is doing

**`dist.ini`** is the build. Two parts of it are not obvious:

- The `[Run::Test]` block copies the dotfiles into the build and appends them to
  `MANIFEST` by hand. Dist::Zilla does not gather dotfiles, and the author tests
  it generates need `.perlcriticrc` to be *in* the build to run against it. It
  reads like a hack because it is one.
- The `; authordep` comment lines are load-bearing. `dzil authordeps` finds
  dependencies by reading plugin names out of `dist.ini`. So it cannot see the
  sections that `weaver.ini` names, such as `[Blurbs]` from Pod::Coverage::More.
  It cannot see the Perl::Critic policies that `.perlcriticrc` names either.
  Without those comments a fresh clone cannot install
  what it needs to build, and the error it gives is about a missing policy
  rather than about a missing list. **Add a line whenever you add a policy.**

Two parts of it replace work that a release used to need by hand:

- No line says the version. `[Git::NextVersion]` takes the highest release tag
  that `[Git::Tag]` wrote, and adds one to it. With no tag, the version is
  `first_version`. To choose a version yourself, run `V=1.000 dzil release`.
- `[Git::ChangelogFromTrailers]` writes the entry for the release at the top of
  `Changes`, from the `Changelog:` trailers of the commits since the last
  release tag. A commit with no trailer adds nothing. It must be above
  `[Git::Commit]`, which commits the new `Changes` with the release. If it is
  below, the release stops before it starts.

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
rest. It does not write the abstract in `NAME`. You write that, as an
`# ABSTRACT:` comment in each module. See below.

`[Blurbs]` writes the POD of each sub from its blurb. A blurb is the block of
comment lines directly above a sub:

```perl
# Triple a number.
# @param   count  Num  what to triple
# @returns Num  three times the count
# @example my $nine = triple(3);
sub triple {
```

The section reads the arguments, the types and the return values that the code
of the sub shows, and takes the rest from the blurb. `perldoc Pod::Coverage::More::Blurb` lists the tags. Write a
blurb above each public sub, in place of a `=head2` or `=method` for it. A sub
with POD of its own keeps that POD. So you can convert an old distribution one
sub at a time.

Pod::Coverage::More needs perl 5.36 or later on the machine that builds the
distribution, whatever floor the distribution declares. The section loads each
module in a child perl, so a module must compile and its prerequisites must be
installed. Only the build has the POD of a blurb, so `perldoc` on a source file
does not show it. Run `dzil podchecker` to read it.

`[Test::Pod::Coverage::More]` in `dist.ini` adds the author test that reads
that POD. It fails for each public sub without POD. It also fails for each sub
whose POD does not give these facts:

- The type of each argument, with `@param`.
- The return value of a sub that returns one, with `@returns`.
- For a sub that can die, how it dies, with `@throws`.
- A call of the sub, with `@example`.

It takes the place of `[PodCoverageTests]`, so `[@TestingMania]` turns that
plugin off. A sub that needs no POD, such as `BUILD`, goes on a
`=for Pod::Coverage` line, as before.

A sub with a section of its own heads it with the call, such as
`=head2 name($arg)` or `=head2 Class->name($arg)`. A heading that assigns the
call, such as `=head2 $x = name($arg)`, fails: the test takes it for an
example, and an example goes in a verbatim block.

**`.perlcriticrc`** is the house policy set, whichever of the two profiles the
question above picked, and it names a good number of policies that are not in
core Perl::Critic. That is what the second block of authordeps is for. Each
profile's own header says what it assumes about the perl and which policies that
assumption pays for. Read the top of the one the flavor wrote before you
declare an override.

One policy ships commented out in both profiles. `ProhibitUnusedDefinitions`
counts calls from `bin/` and `lib/`, so in a distribution that is only a library
it reports every sub the library exists to offer -- the policy working correctly
and telling you nothing. Turn it on in a distribution that ships programs too,
with an override such as `ProhibitUnusedDefinitions: {}`, and put its authordep
line back when you do.

**The shebang line** of every Perl program is `#!perl`: the programs in
`bin/` and `script/`, the tests in `t/`, and `.tests-covering-map.pl`. When
ExtUtils::MakeMaker installs a program, it replaces a first line that names
`perl` with the path of the perl that installs it. Module::Build does the
same. That perl has the modules that the program needs, so the program runs
whatever is on the `PATH` of the person or service that starts it. The install
leaves `#!/usr/bin/env perl` alone, because its interpreter is `env`. Then the
program runs the first perl on that `PATH`. A service, a cron job or a task
that root runs at boot usually finds only the system perl there, which lacks
the modules.

`#!perl` names no interpreter until the install rewrites it. So a program with
it does not start from a checkout: run it as `perl -Ilib bin/foo`, or install
it. A distribution whose programs run from its checkout, such as one that is
not released yet, overrides the `formats` of `logicLAB::RequireSheBang` with
`#!/usr/bin/env perl`, as the example above does. Delete the override when the
programs run installed. `logicLAB::RequireSheBang` reports each file whose
first line differs, when the hook judges it.

`.preferred_modules.ini` is read by the `PreferredModules` policy and is where
"use this rather than that" lives.
`.pod_stopwords` is read by `Documentation::PodSpelling`, which runs aspell
over your POD: it holds the vocabulary no dictionary has, the licence words
from the COPYRIGHT section Pod::Weaver generates, and the names in that
section and in AUTHORS: yours and the copyright holder's, which you add.
Add each name with the Edit tool, one word to a line, in its sorted place.
Do not rewrite the file with `perl -i` or a script. A script that prints
after its read loop writes the file empty, and PodSpelling then fails on
the licence words.
A misspelling does not belong in it.

**`Changes`** has only its first line in the template. Do not edit it by hand.
If two branches each add a line to it, the second merge conflicts. Two commits
that each carry a `Changelog:` trailer do not conflict. The entries that are
in it stay as they are, and each release adds one above them.

**`MANIFEST.SKIP`** names the files that stay out of the tarball, and
`[ManifestSkip]` reads it. These are the files for the people who work on the
distribution: `CLAUDE.md`, `git-hooks/`, and the files that only `dzil` reads,
such as `dist.ini`. Each line is a regex that ExtUtils::Manifest matches against
the path from the root, so anchor it with `^`. A dotfile needs no line, because
`[GatherDir]` does not gather it. `LICENSE` is the one exclusion in
`[GatherDir]`: `[License]` writes it, and a second copy stops the build.
The file also skips itself. A copy in the build replaces the default list of
the release test of the `MANIFEST`, and that default covers what `make` leaves
there. To keep another file out, add a line here, not to `[GatherDir]`.

**`.mailmap`** is for `[Git::Contributors]`, which otherwise lists the same
person once per address they have ever committed from.

**`metamerge.yml`** declares the packages of the operating system that the
distribution needs. CPAN has no field for such a package, so this file is the
only place that the requirement is written. `[MetaMergeFile]` merges the file
into `META.json`, so the declaration also goes to CPAN. A tool that sets up a
host reads the declaration, and installs the packages before it installs the
distribution.

Every distribution needs `aspell` and its English dictionary, `aspell-en`.
`Documentation::PodSpelling` runs aspell over the POD. If aspell is not
installed, the policy turns itself off, and nothing checks the spelling. So the
template declares both, and the check `SystemPackages` of the flavor fails a
distribution that does not declare each one. If `metamerge.yml` does not exist,
`update` writes the template. If it exists and lacks a package of the template,
`update` adds that package. It keeps the other keys, the comments and the
order of the file. If the distribution declares `aspell` already, `update`
keeps its entry.

The template names each package once for each packager, and nothing else. If
the archives of a host do not have one of them, the install fails, and the
person who runs the host adds the archive that has it. For example, on RHEL,
`aspell-en` is in EPEL, so enable EPEL on that host first.

A distribution that needs more packages, such as `ffmpeg`, adds them to the
file:

```yaml
x_system_packages:
  aspell: { deb: aspell, rpm: aspell, test: aspell --version }
  aspell-en: { deb: aspell-en, rpm: aspell-en, test: aspell --lang=en_US -a }
  FooLib:
    deb:
      name: libfoo-devel
      ubuntu/24.04: libfoo-dev
    rpm: libfoo-devel
  ffmpeg:
    deb: { name: ffmpeg, source: jellyfin }
    test: ffmpeg -version
x_system_sources:
  deb:
    - name: jellyfin
      uri: https://repo.test.test/ubuntu
      suites: ['{codename}']
      components: [main]
      key: https://repo.test.test/key.gpg
      fingerprint: 0123456789ABCDEF0123456789ABCDEF01234567
```

Each key of `x_system_packages` is a name that you choose for one dependency.
Under it, each packager gives the package name. If the name is different on one
distro or release, use a mapping, as for `FooLib`. A null value for a release
means that the release needs no package. `test` is optional. It is a command
that must exit 0 after the package is installed. `x_system_sources` holds the
third-party archives, each with the full fingerprint of its signing key. If a
dependency has no package for a host, the build of that host fails. The check
`SystemPackages` of the flavor refuses a name that is not a plain package
name, and a source without a fingerprint. `perldoc
Dist::Conformance::Check::SystemPackages` gives the rules.

**`git-hooks/pre-commit`** runs perltidy over the Perl you staged, restages it,
runs `perlcritic --profile .perlcriticrc` over the same files, and then runs the
tests. It needs
no opinion about which profile that is: the question at the top of this document
already decided, and the flavor wrote the answer to that name. Tracked in the
repository rather than only in `.git/hooks`, because git does not version or
clone hooks, so an untracked one exists on exactly one machine.

Critic runs after the tidy pass, never before, because the tidy pass rewrites
those files and stages what it wrote -- so the bytes critic has to judge are the
ones that will land, not the ones you saved. Files under `t/` are judged by the
same profile less `Documentation::RequirePod`: a test is not a module, nobody
runs `perldoc` on one, and asking it for POD asks for a page no reader will
open. Every other policy still applies there, which is more than a release does.
A machine with no perlcritic skips the pass and says so, the way it already does
for perltidy; `dzil test` runs the same profile over `lib/`, so nothing reaches
CPAN unjudged.

The tests run last, with `prove -lm -j8`, so they read the files that the tidy
pass wrote. They run for every commit, not only a commit of Perl. A change to
`dist.ini`, a `share/` file or a fixture can break a test as a module can. If a
test fails, the hook stops the commit and prints the command that shows why:
`prove -lv t/<file>.t`.

Which tests run is the choice of `tests-covering`, from Perl::Tests::Covering.
It reads the staged diff, and names the tests that ran a line the diff
changes. A machine without `tests-covering` runs all of `t/`, and the hook
says so.

A change to a file that no test loads goes to **`.tests-covering-map.pl`**. The
template map says that no test reads the documentation, the files that only
`dzil` reads such as `dist.ini`, the configuration of the tools, the hooks, CI
and `xt/`. So a commit of those runs no test. A file that the map does not
place, such as a fixture, runs every test. When a test reads a file without
loading it, give the map a rule that names that test. `perldoc
Perl::Tests::Covering` has the interface, under THE MAP.

**`git-hooks/refresh-coverage`** keeps the records of `tests-covering` up to
date. It runs the tests that a change made stale under Devel::Cover, in the
background. Without it, the records describe older files, and the choice of the
pre-commit hook grows coarser with each change. Three hooks run it, each after
git changes the files:

- **`post-commit`** runs it after each commit. It does nothing while a rebase,
  or a cherry-pick or revert of several commits, applies commits. git runs the
  hook for each commit that it applies, and each run starts a refresh of its
  own.
- **`post-merge`** runs it after a pull or a merge that changes the tree. That
  includes a `pull --rebase` that only fast-forwards. A pull that changes
  nothing runs no hook, and needs no refresh.
- **`post-rewrite`**: when a rebase ends, including a `pull --rebase`, this
  hook runs it once. git runs this hook while the state of the rebase is still
  on disk. So it cannot go through `post-commit`, which does nothing at that
  time. It ignores `commit --amend`, which runs `post-commit` as well.

The records are kept under `~/.cache`, so the distribution gains no files. A new
worktree has no records of its own. Until its first refresh, `tests-covering`
0.003 and later reads the records of another checkout of the same repository.

The pre-commit hook and `refresh-coverage` run the tests without the `GIT_`
variables that git sets for a hook.
git sets `GIT_INDEX_FILE` for a hook, and `GIT_DIR` as well in a worktree, and
git obeys them over `-C`. So a test that runs git in a repository of its own
would otherwise add, commit and write config in the repository being committed
to.

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

**No `Changelog:` trailer since the last release.** Then there is no entry to
write, and `[Git::ChangelogFromTrailers]` stops the release. Put the trailer
on the commit that makes the change, with `git commit --trailer 'Changelog:
...'` or as the last line of the message. If you forgot, add it to an empty
commit, `git commit --allow-empty`. Do not rewrite a commit that you pushed.

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
It writes `README.md` at each build, and the version in it changes at each
release. So `README.md` is in `allow_dirty` of `[Git::Check]` and of
`[Git::Commit]`, and the release commit carries the new copy.

**Author dependencies that `dzil authordeps` cannot see.** Covered above, and
worth repeating because the symptom appears on somebody else's machine rather
than yours: yours has them installed already.

**A module with no `# ABSTRACT:` comment.** `NAME` in the woven POD is the
package and its abstract. The abstract of the main module is also the abstract
of the distribution. Both come from one comment below the `package` line:

```perl
package Text::Rot13;

# ABSTRACT: Rotate the letters of a string by thirteen
```

Without it, `dzil build` stops with "Unable to extract an abstract from
lib/Text/Rot13.pm". When you create a module, write one in it. In the release
evals, three of six new distributions had none, so none of them built.

**A SYNOPSIS that does not compile on its own.** `[@TestingMania]` generates
`t/author-synopsis.t`, which compiles the code of each SYNOPSIS by itself. The
`use` lines of the module do not reach that code. So a SYNOPSIS that calls `say`
stops `dzil test` with a syntax error "near say". Write the SYNOPSIS as a caller
writes it: `use` the module, and enable `say` before you call it, or call `print`.
In the release evals, three of six new distributions failed this way.

**`our $VERSION` written by hand.** `[PkgVersion]` stamps every module with the
version of the release at build time. A version in the source is a second answer to the same
question, and it is the one that goes stale.

**A `$VERSION` line above `use strict`.** Left to its default, `[PkgVersion]`
inserts `$Foo::VERSION = ...` straight after the `package` line, and the compat
profile's `RequireUseStrict` reports it in the built module: the author tests
fail on a distribution that passed perlcritic in the tree. The template sets
`use_package = 1`, which writes `package Foo 0.001;` instead and adds no line.

**A prereqs file under a name nobody reads.** `[PrereqsFile]` reads
`prereqs.yml` and `prereqs.json`. Its `filename` option cannot be set to one
file from `dist.ini`, so `prereqs.yaml` is not an alternative spelling: it is
ignored, and nothing says so. The perl floor in it then reaches the metadata only
because `[AutoPrereqs]` also read the `use` line.

**Nothing in `t/`.** `[@TestingMania]` generates a pile of author and release
tests -- compile, POD syntax, POD coverage, kwalitee, unused variables -- but
none of them test what your code does. `dzil test` passing on a distribution
with an empty `t/` means the packaging is fine and says nothing else. See
[perl-slop:testing-perl](../testing-perl/testing-perl.md).

**Prose in `=head1 SEE ALSO`.** `[SeeAlso]` in `weaver.ini` rebuilds that
section as a list, with one item for each line. It wraps an item in
`L<...|...>` unless the whole line is one `L<>`. So the line
`L<perlop/"tr">, which does the work.` becomes a nested `L<>` in the build.
The POD tests of the build then fail on a source that `podchecker` passes. Put
one module name or one `L<>` on each line of that section, and nothing else.
Put the prose about it in the DESCRIPTION.

**A lexical whose only use is `tr///r`.** Test::Vars 0.017 does not count
`tr///r` as a use of the variable. `[@TestingMania]` runs it as the release
test `t/release-unused-vars.t`. So this sub fails with
`$string is used once in &Text::Rot13::rot13`:

```perl
sub rot13 ($string) { return $string =~ tr/A-Za-z/N-ZA-Mn-za-m/r }
```

It counts `s///r`, and it counts a copy that `tr///` then changes:

```perl
sub rot13 ($string) { ( my $rotated = $string ) =~ tr/A-Za-z/N-ZA-Mn-za-m/; return $rotated }
```

**A test file with POD and no shebang.**
`Documentation::RequirePackageMatchesPodName` reads a file without one as a
module, and then wants its POD `NAME` to match the package -- which in a `.t` is
`main`. The message is "Pod NAME on line 7 does not match the package
declaration", and it points nowhere near the cause. Start every test with
the shebang line of the profile, `#!perl` unless an override says otherwise,
and it reads it as the program it is.

Only the hook will tell you. `all_critic_ok()`, which is what `[@TestingMania]`
generates, reads `lib/` (or `blib/`) and never `t/`, so a release judges your
modules and not your tests.

**A perl version said in one place and not the others.** Which version you are
targeting is the question at the top of this document; this is what happens when
the answer is written down inconsistently. Say it in three places and keep them
equal: the `use` line in every module, the `use` line in every test, and `perl:`
in `prereqs.yml`.

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
dzil test --release  # release and author tests as well as yours
dzil build           # look in the tarball; the MANIFEST is a common surprise
dzil release         # tags, pushes, uploads
```

`dzil release` runs `[Git::Check]` first. It refuses a tree with uncommitted
changes, except to `README.md`, which the build writes. Then it writes the new
entry to `Changes`, commits `Changes` and `README.md`, tags `%v`, pushes and
uploads to CPAN. The next release gets the next version from that tag. If you
do not want the upload, take `[UploadToCPAN]` out before you find out at the
end.
