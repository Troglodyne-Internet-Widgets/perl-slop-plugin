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
- **The other copy is often not in the diff.** This pass reads hunks, so a new
  sub duplicating one that already existed and was not touched is invisible
  here, however carefully you read. That check belongs before the code was
  written -- see *Before you add, look for what already does it* in
  [perl-slop:reading-perl](../reading-perl/reading-perl.md). If you skipped it,
  do it now, and do it the way the next section says rather than the way that
  feels sufficient.

### The search that finds it, and the one that does not

Every new sub in the diff gets one of these, and it takes a minute each. It is
worth spelling out because the search everybody runs is the one that cannot
work.

**You will search for the thing you reached for. Search for what the sub does
instead.** Somebody who shells out to `ssh-keygen` greps `ssh-keygen`, finds the
one other call, concludes there is no library way, and writes their own -- while
the library sub that does exactly it sits three directories away, never
mentioning `ssh-keygen` anywhere except in a line of POD saying it is
*equivalent to* it. The name you have in your head is the name the existing code
had no reason to use.

So grep the **noun the sub returns** and the **verb it performs**, two or three
spellings of each:

    git grep -in 'sub .*\(pubkey\|public_key\|ssh_key\)'   # what it returns
    git grep -in 'Crypt::\|Digest::\|MIME::Base64'          # what it would use
    git grep -in 'sub .*\(readdir\|opendir\|find\)'        # what it touches

**And read the registries before you write, not after.** A `.preferred_modules.ini`,
a `.perlcriticrc`, a `CLAUDE.md`, a `Makefile.PL` prereq list: each is somebody
having already answered "what do we use for this", and each is faster to read
than the tree is to grep. They are described elsewhere as places to record an
answer; they are also the first place to look for one.

Say what you searched for, in the commit message or the PR, when the answer was
"nothing". A search nobody can see is one nobody can tell you was the wrong
search -- which is the only way this gets caught, since by definition the code
you missed is not in the diff a reviewer is reading either.

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
- **`use` at the top, unless you can name what breaks.** A deferred `require`
  buried in a sub costs the reader the dependency list the top of the file is
  supposed to be, so it needs a reason -- and "it is heavy", "it pulls in a lot"
  or "it brings an SSH stack with it" are not reasons. Loading a module that
  declares subs and nothing else costs a compile, which is what `use` is for.

  The reason it is ever right is **work at load time**: a `BEGIN` block, or code
  outside a sub, that touches the filesystem, the network or the environment.
  That is a property you can check rather than assert:

      grep -n 'BEGIN' $(perldoc -l Some::Module)

  and follow it down, because the culprit is usually not the module you named.
  A worked example: `Trog::Guest` has no `BEGIN` block and neither does its
  parent, so it looks like a plain `use` -- but the parent loads
  `Net::OpenSSH::More`, which loads `File::HomeDir` in a `BEGIN` block, which
  stats the filesystem looking for `xdg-user-dir`. Under `Test::MockFile` in
  strict mode an unmocked stat is fatal, so a top-level `use` stops the test
  loading the file at all.

  When you do defer, the comment names **that** -- the module four levels down
  and the thing it does -- not a feeling about weight. A reader who cannot check
  your reason cannot maintain your code, and the next person deletes a `require`
  that was load-bearing or keeps one that never was.

  **And check whether the test is the thing that needs fixing.** Load-time work
  that only breaks under `Test::MockFile` is a test-ordering problem, not a
  reason to contort the module: MockFile has to be the last thing loaded before
  the SUT, so a dependency that opens or stats a file while compiling gets
  `use`d in the test file ahead of it. Deferring the load in the *source* to
  keep a test happy is the tail wagging the dog, and it is only the right answer
  when the module doing the work is the system under test itself.

  Name the offender exactly when you do that. Loading a parent or a wrapper
  instead can drag in more than you meant and break the mocking you still need
  -- pulling in something that uses `File::Slurper` compiles its `open` before
  MockFile can replace it, and every read the SUT makes then goes to the real
  filesystem.

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
- **The POD for a sub goes directly above that sub.** Not gathered into a block
  at the top of the file describing four subs that appear three screens later.
  Two things go wrong with the gathered version and both are silent: the reader
  editing one of those subs has no documentation in front of them, and the
  documentation drifts from the code because nothing puts the two on the same
  screen. A sub whose contract changed is one you are already looking at -- so
  is its POD, if the POD is where it belongs.

  The `=head1` that groups them is fine where it is. It is the per-sub `=head2`
  that has to move down to the thing it describes.
- **Reread your own prose as a stranger.** Fresh from writing the change, you
  cannot tell what is obvious from what merely feels obvious to you today. Ask of
  each comment: would this still be worth reading a year from now, by somebody
  who was not here for the argument?
- **A reason you have not checked is worse than no reason at all.** A comment
  asserting why something is done is read as established fact, and it outlives
  the person who guessed it. Two questions settle it: is this claim true, and
  did I verify it or infer it? If you inferred it, either check it -- most of
  these are one command -- or write down what you actually know, including that
  you do not know why. "No history explains the second call; removing it, tests
  pass" is a good comment. A confident sentence nobody can reproduce is not, and
  it is the kind a reviewer is entitled to be rude about.
- **Don't document something twice.**  If the same thing is described in comments
  *And* POD, drop the comments.
- **Unless the second place cannot see the first -- then leave a pointer, not a
  copy.** The rule above is about two copies of an argument drifting apart. It is
  not about a reader who has no way to reach the one copy from where they are
  standing. A template, a generated fragment, a shell script that ends up on a
  machine: each is read on its own, and a line whose reason lives in a module's
  POD three directories away reads as arbitrary from inside one. Deleting the
  local note there does not remove a duplicate, it removes the only explanation
  that reader will ever see, and the line gets "tidied away" by the next person.

  So keep the constraint in a clause and name where the argument lives:

      # /etc, not /root: some builds of rsync will not read a config out of
      # /root.  Provisioner::Recipe::backup has the whole account.

  The test is whether the note *restates* the reasoning or *reaches* it. One
  clause and a name is a pointer: it cannot drift far from what it points at,
  because there is not enough of it to drift. A second paragraph is a copy, and
  will. When this pass turns up the same explanation in two places, ask which
  one the reader can get to before you decide which one to cut -- the answer is
  usually that the far copy becomes a pointer and the near one stays whole.
- ** Use the precise word always** Your audience has a large vocabulary.
  Don't use a word like 'shape' to describe a function when 'interface' is more precise.
  Words have specific meanings, and you must choose the best match with the least
  ambiguity of meaning, not the one in widest parlance.

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
