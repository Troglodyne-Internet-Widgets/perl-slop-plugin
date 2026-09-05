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

## Scaffold it

```
SKILL=<this skill's directory>
mkdir -p newdist/lib newdist/t && cd newdist && git init

cp $SKILL/templates/dist.ini              dist.ini
cp $SKILL/templates/weaver.ini            weaver.ini
cp $SKILL/templates/Changes               Changes
cp $SKILL/templates/LICENSE               LICENSE
cp $SKILL/templates/perlcriticrc          .perlcriticrc
cp $SKILL/templates/perltidyrc            .perltidyrc
cp $SKILL/templates/preferred_modules.ini .preferred_modules.ini
cp $SKILL/templates/gitignore             .gitignore
cp $SKILL/templates/mailmap               .mailmap
```

Then substitute. The placeholders are the same in every file:

| | |
|---|---|
| `{{DIST}}` | the distribution name, as `dist.ini`'s `name =` — `Configd`, `Foo-Bar` |
| `{{VERSION}}` | `0.001` for something new |
| `{{AUTHOR_NAME}}`, `{{AUTHOR_EMAIL}}` | as they should appear in POD and metadata |
| `{{COPYRIGHT_HOLDER}}`, `{{YEAR}}` | for the licence and the generated POD |
| `{{GITHUB_USER}}` | the account the repository lives under, for `[GithubMeta]` |
| `{{CPAN_ID}}` | your PAUSE id, for the `Changes` entry |
| `{{DATE}}` | today, `YYYY-MM-DD` |

```
sed -i 's/{{DIST}}/Configd/; s/{{VERSION}}/0.001/; ...' dist.ini weaver.ini Changes LICENSE .gitignore .mailmap
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

**`weaver.ini`** generates the POD boilerplate — `NAME`, `VERSION`, `AUTHORS`,
`COPYRIGHT AND LICENSE` — from what `dist.ini` already knows, and collects
`=method` and `=attr` into sections. Write the interesting POD; let it write the
rest.

**`.perlcriticrc`** is the house policy set, and it names a good number of
policies that are not in core Perl::Critic. That is what the second block of
authordeps is for. `.preferred_modules.ini` is read by the `PreferredModules`
policy and is where "use this rather than that" lives — `Cpanel::JSON::XS` over
`JSON::PP`, `YAML::XS` over `YAML::PP`, `Crypt::PRNG` over `rand`.

**`Changes`** exists because `[CheckChangesHasContent]` refuses to release
without it. See below.

**`.mailmap`** is for `[Git::Contributors]`, which otherwise lists the same
person once per address they have ever committed from.

## The things that stop a release

Each of these has bitten a real distribution here.

**A `Changes` with nothing under the version you are releasing.** The template
has an entry for `{{VERSION}}`; keep adding one per release, above the last.
`[CheckChangesHasContent]` reads the top entry and stops if it is empty, which
is the correct behaviour and an annoying surprise at the end of a release.

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

**A perl version requirement copied without thinking.** The house style is
`use 5.041`, which is right for code running on machines you control and wrong
for anything that has to run on whatever perl is already installed. Decide which
you are writing, and if it is the second, say so where somebody will see it:
Ubuntu 24.04 ships 5.38, 22.04 ships 5.34.

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
