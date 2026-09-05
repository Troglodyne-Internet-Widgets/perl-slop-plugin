---
name: reviewing-perl
trigger: A patchset is finished and about to be committed, pushed or turned into a PR.
description: |
  Read your own diff back before anyone else has to.
  Catch the repetition, the leaked abstractions, the shelling out and the
  undocumented assumptions that a human reviewer would otherwise have to.
---

I'm using the perl-slop:reviewing-perl skill to review a finished patchset.

Run this on your own work once the patchset is finished and the tests pass, but
before you commit or open a PR. It is a self-review pass: read the whole diff
back, check it against everything below, and fix what it turns up rather than
reporting it.

Start with `git diff` (or `git diff <base>...HEAD` for a branch) and read every
hunk. Then check each of the following. Every one of these came out of a real
review comment on real perl, so treat a hit as something to fix, not something
to justify.

Don't get into a loop executing this skill.

If the diff changed code you did not write, check it against
[perl-slop:reading-perl](../reading-perl/reading-perl.md) as well: the question
there is whether you understood what you were changing before you changed it.

## Don't repeat yourself

- **No per-script copies of shared state.** If two scripts each declare
  `our $thing;` and a `sub thing { $thing //= Build->new(); }` accessor, the
  memoization belongs in the class, not in the scripts. Make the constructor a
  singleton and let every caller just say `Class->new()` and fetch what it needs
  from that object.
- **No re-deriving what an object already knows.** If a script computes a path
  from an object's fields, that computation is a method on the object.
- **Look for the same block twice.** Two scripts with a near-identical sub is a
  class method or library function that hasn't been written yet.

## Encapsulate

- **Ask what owns the data.** Free subs in a script that take an object as their
  first argument (`sub tf_dir_for { my ($hv, $override) = @_; ... }`) are methods
  wearing a disguise. Move them.
- **Package globals are a smell.** `our $domain_dir` threaded through eight subs
  is a field on the object those subs already have in hand.
- **Push knowledge down, not up.** A script should say *what* it wants
  (`$hv->annihilate_domain($name)`), never *how* to get it
  (`system(qw{virsh destroy}, $name)`).

## Use the library, not the shell

- **Prefer a real API over shelling out.** `Sys::Virt` over `virsh`, `Net::DNS`
  over `dig`, `DBI` over `mysql -e`, and the same reasoning everywhere else.
  Shelling out means parsing human-readable output, quoting by hand, losing the
  error and suffering a performance hit to boot.
- When you genuinely have to shell out, say in a comment *why* the API can't do
  it. (Example: libvirt exposes DHCP leases read-only, so releasing one means
  the lease helper.) That comment is also what an explicit `## no critic` is
  asking you for.

## Perl style

- **No ternaries that pick between two spellings of the same call.**
  `$hv->is_local ? unlink($f) : $hv->system_hv(qw{rm -f}, $f)` means the
  abstraction is leaking; make the one call do both.

Run the house policies over the diff:

    perlcritic --profile .perlcriticrc bin/ lib/ t/

Try to install them if perlcritic says it has no such policy.
If the user needs to assist with this, flag them down.

## Comments and POD

The reader's attention is the scarce resource. Every line of prose in the file
spends some of it, so each one has to earn its place.

- **Why a change was made belongs in the commit message, not in the code.** The
  commit is not a worse place for it -- it is the right one, and `git blame` on
  the line reaches it from inside the editor. A comment saying what this used to
  do, what was wrong with it, or which bug it fixes is describing an event, and
  events go in history. The code has to make sense to somebody who has never
  heard of the bug.
- **A comment earns its place by explaining something the code cannot.** Two
  kinds do: the non-obvious -- why this order, why this constant, why the
  seemingly redundant call is load-bearing, why the API can't do it -- and the
  orienting, the sentence at the top of a hairy block telling the reader what
  role it plays in the design so they can follow the rest. Both are about the
  code as it stands, not about how it got there.
- **Cut the comment that restates the line under it.** If it only says what the
  code says, delete it; if the code needs it, the code needs better names.
- **POD is a contract, not a diary.** It tells a caller what to pass, what comes
  back, what it dies on, and anything they must know and cannot see. It is not
  the place for implementation detail they cannot act on, for the history of the
  interface, or for narrating what the reader is about to read anyway. Somebody
  is reading it to use this; give them that and stop.
- **Reread your own prose as a stranger.** Fresh from writing the change, you
  cannot tell what is obvious from what merely feels obvious to you today. Ask of
  each comment: would this still be worth reading a year from now, by somebody
  who was not here for the argument?

## Unstated dependencies

- **Ask what else has to be true.** Any time you encounter evidence that
  there is a dependency on or relationship to another system or repository,
  ask yourself if we are forgetting to handle something important to the
  external system. Don't hesitate to ask the user about it.
- Anything you assume but can't enforce goes in a comment, the POD, or the
  Readme — whichever the next person will actually read.

## Tests

- Every behavior the patchset added or changed has a test.
- If you moved a sub between packages, its tests moved with it.
- Coverage per file is no worse than it was before the patchset.
- Consult the relevant testing skills available to you; see
  [perl-slop:testing-perl](../testing-perl/testing-perl.md).

## Finally

Run the suite (`prove -lm -j8`) and make sure every changed file still compiles
(`perl -c`) and its POD still parses (`podchecker`) before you call it done.
