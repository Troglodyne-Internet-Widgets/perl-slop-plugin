---
name: reviewing-perl
trigger: A patchset is finished and about to be committed, pushed or turned into a PR.
description: |
  Read your own diff back before anyone else has to.
  Catch the repetition, the leaked abstractions, the shelling out and the
  undocumented assumptions that a human reviewer would otherwise have to.
---

I'm using the perl:review skill to review a finished patchset.

This is a self-review pass, not a report. Run it once the patchset is complete
and the tests pass, but before committing. Anything it turns up, fix — don't
hand the list back.

Start with `git diff` (or `git diff <base>...HEAD` for a branch) and read every
hunk. Then check the patchset against each section below.

## Don't repeat yourself

Repetition in a patch is the cheapest thing to spot and the most expensive to
leave in, because every future change has to find all the copies.

**No per-script copies of shared state.** Two modulinos that each declare
`our $thing;` and a `sub thing { $thing //= Build->new(); }` accessor have
written the same memoization twice. It belongs in the class:

```perl
# In every script -- twice the code, twice the places to fix it
our $hv;
sub hv { $hv //= Trog::HV->new(); return $hv }

# In the class, once
my $INSTANCE;
sub new {
    my ($class, %opts) = @_;
    my %given = grep { defined $opts{$_} && length $opts{$_} } keys %opts;
    return $INSTANCE if $INSTANCE && !%given;
    ...
    return $INSTANCE = $self;
}
```

Now every caller anywhere says `Class->new()` and gets the configured object.

**No re-deriving what an object already knows.** A script computing a path out
of an object's fields is a method that hasn't been written yet.

**Look for the same block twice.** A near-identical sub in two files is the
strongest signal there is that something wants extracting.

## Encapsulate

**Free subs taking an object first are methods in disguise.**

```perl
sub tf_dir_for { my ($hv, $override) = @_; ... }   # move it
$hv->tf_dir                                        # there
```

**Package globals threaded through half a file are fields.** `our $domain_dir`
read by eight subs that all already have the object in hand is state living in
the wrong place.

**Push knowledge down, not up.** A script says *what* it wants; the class knows
*how*:

```perl
system( qw{virsh destroy}, $name );   # the script knows too much
$hv->annihilate_domain($name);        # better
```

**A ternary picking between two spellings of one call means the abstraction is
leaking.** Make the one call handle both cases:

```perl
$hv->is_local ? unlink($f) : $hv->system_hv( qw{rm -f}, $f );   # leak
$hv->unlink_hv($f);                                            # sealed
```

## Use the library, not the shell

Prefer a real API to shelling out — `Sys::Virt` over `virsh`, `Net::DNS` over
`dig`, `DBI` over `mysql -e`. Shelling out means parsing output meant for
humans, quoting by hand, and throwing the error away. See the
[perl:test](../testing-perl/testing-perl.md) skill on why this matters for
testability too.

When you genuinely must shell out, say in a comment *why* the API can't do it,
so the next person doesn't have to rediscover the dead end:

```perl
# libvirt exposes DHCP leases read-only -- virNetworkGetDHCPLeases has no
# counterpart that deletes one -- so releasing a lease means the lease helper.
```

That comment is also what an explicit `## no critic (ProhibitPipeOpen)` is
asking you for.

## Perl style

These three are enforced by policies from
[Troglodyne-Internet-Widgets](https://github.com/Troglodyne-Internet-Widgets),
so if the repo has them in its `.perlcriticrc` the linter will find them. Look
anyway; a patch is easier to fix than a lint failure is to argue with.

- **`use FindBin::libs`, never `use lib "$FindBin::Bin/../lib"`.** The
  hardcoded path is wrong the moment a script moves.
  (`Perl::Critic::Policy::ProhibitUseLib`)
- **POD and `Pod::Usage`, never a `usage()` sub.** A hand-rolled usage is a
  second copy of the interface that goes stale.
  (`Perl::Critic::Policy::ProhibitUsageSubs`)
- **`qw{}` for runs of literals.** `system_hv( qw{sudo rm -f}, $conf )`, not
  `system_hv( 'sudo', 'rm', '-f', $conf )`.
  (`Perl::Critic::Policy::RequireQwForLiteralLists`)

Run whatever the repo configures:

```
perlcritic --profile .perlcriticrc bin/ lib/ t/
```

## Unstated dependencies

The bugs that survive review are the ones nothing in the diff mentions.

Ask what else has to be true for the patch to work. A change that copies one
file to another machine should make you ask what else on that machine the far
side reads. Anything provisioned outside this repository is the easiest thing
in the world to miss, precisely because nothing here names it.

Whatever you assume but cannot enforce goes in a comment, the POD, or the
README — whichever the next person will actually read.

## Tests

- Every behavior the patchset added or changed has a test.
- Tests need no live service, no network and no root.
- A sub that moved between packages took its tests with it.
- Coverage per file is no worse than before the patchset.

## Finally

```
prove -lm -j8              # the suite still passes
perl -c $changed_file      # everything still compiles
podchecker $changed_file   # the POD you just wrote is valid
```

Then commit.
