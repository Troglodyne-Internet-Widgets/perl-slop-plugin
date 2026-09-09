---
name: testing-perl
trigger: When writing or running perl tests
description: How to write and run perl tests.
---

I'm using the perl-slop:testing-perl skill to write or run Perl tests.

## Definitions

The purpose of a test is to formalize the system under test's *functional* and *non-functional* characteristics.

1. Functional characteristics are *cardinal*.     There exists a closed form solution to this problem; a definitive answer.
2. Non-Functional characteristics are *ordinal*.  There isn't a *wrong* answer, simply better or worse.  Ex. Performance, Accuracy of Approximations, Matters of Taste

A test is one of three types:

1. Structural / Unit : mocks or fakes all *direct* dependencies of the subroutine under test.
2. Integration : mocks or fakes all *indirect* dependencies of the subroutine under test; dependencies of our direct dependencies.
3. Acceptance : uses no mocks of any kind, but fakes of external systems are acceptable.  Only for testing non-functional characteristics.

Mocks are redefined variables or subroutines in particular perl packages we depend on directly or indirectly.
Fakes are generally things external to our program which we nevertheless interact with dummied up for testing purposes.

Fakes of things external to the system under test are mandatory for unit and acceptance tests.

Acceptance tests must not run without sandboxing of some kind; be it VMs, containers or jails.

It is preferrable that acceptance tests are *data-driven*, which is to say they accept some kind of data and feed it into the system under test.
It is preferrable for data driven tests to accept input on STDIN, but fall back to a `__DATA__` section when not provided.

In the perl context we are going to be testing 4 types of systems:

1. Modules      - these generally live in lib/ and have a .pm file extension. They must exit 1.
2. Plugins      - these are modules, but that are not intended to be used directly. Instead they are included dynamically, and are a subclass of other modules.
3. Modulinos    - these generally live in bin/ and are chmod +x,  declare a package and only execute `main()` when `caller()` is defined.
4. Scripts      - these generally live in scripts/, and have a .pl extension.
5. Applications - usually PSGI, these are intended to be run as a part or plugin of other perl applications.

Going forward we will abbreviate "system under test" as SUT.

## Implications on design of SUT

Most globals should be declared with `our` rather than `my` so that they can be locally overridden in tests.
Execution of external programs via `system` or `qx` and other builtins should be wrapped in a subroutine, so that it can be easily mocked.
In general "shelling out" should be avoided in favor of library and builtin equivalents for testing and performance reasons.
Code re-use (modularity) cuts down on unnecessary testing as it means less lines to cover.  DRY (Do not repeat yourself).

## Structure

Every test of modules MUST be named in the following form:

```
My-Module.t
```

Where lib/My/Module.pm is the system under test.

It is important to keep unit tests associated with the module that they test.

In the case of plugins (such as Provisioner::Recipe subclasses), it is better to iterate over these in one test file.
Name said tests as seems appropriate.
The idea is that we want to automatically get test coverage for most new plugins that we add.

It is important to test each subroutine in its own subtest / closure,
so as much local state and mocks as are possible can expire with the test of the particular sub.

All tests belong in `t/`
Integration tests must skip unless the `RELEASE_TESTING` env var = 1
Acceptance tests must skip unless  the `AUTHOR_TESTING` env var = 1

## Approach to writing tests

Load the system under test with either `use_ok()` for modules, or require\_ok() for modulino binaries. Only use `ok do ...` when testing nonmodlino scripts.

Make no assertions verifying that dependencies are present in tests, ensure they are in Makefile.PL (or dist.ini if using Dist::Zilla) instead.

The only acceptable means of mocking subroutines is Test::MockModule in strict mode; use redefine() or define() as appropriate.

Whenever possible fake files using Test::MockFile.
Any deps of the SUT which do file access in BEGIN blocks will have to be `use`d in the test itself.
Any deps which use bareword filehandles will also require this treatment; any files they access cannot be mocked via MockFiles and should use File::Temp instead.
Test::Mockfile must be the last dependency loaded in the test before the SUT.

Prefer `Test2::V1 -i` over using Test::More where possible, but don't convert existing tests from one idiom to the other.

Use FindBin::libs to enable testing libdirs.

Use Test::NoWarnings or Test2::Plugin::NoWarnings as appropriate.
This may be omitted for scripts and modulinos, as it is expected that they may emit warnings.

It is acceptable for the system under test to `die()` during tests; in general we want negative results as fast as is possible.

When you are specifically testing for a termination condition, use Test::Fatal or Test2::Tools::Exception as appropriate.

When DB calls have to be faked, use DBIX::QuickDB.

When a piece of code is removed, don't assert that it isn't there - testing undefined behavior is a waste of time.

## Assert on the behaviour, not on the artifact

The commonest way a test passes while the thing it is named after is broken: it
checks that a configuration you generated *contains* something, instead of
checking that the system which reads that configuration *does* something.

You wrote the artifact. Of course it contains what you put in it. An assertion
over it can only fail when the interpolation broke -- never when the value was
wrong, and never when the thing consuming it reads it differently than you
assumed.

Three that got through review this way, in one patchset:

- An exclusion pattern was asserted by matching it against a path in Perl. The
  pattern was handed to `rsync`, which has its own rules about what a pattern
  means, so one that read exactly right and excluded nothing passed.
- A firewall exemption was asserted by grepping the generated rules file for the
  rule. It was there. It was also in a chain where `RETURN` skipped the accept
  rules below it, so the "exemption" dropped every packet from the network it
  named.
- The address in that exemption was asserted by grepping for the value the test
  itself had supplied. It passed while the value was wrong, and passed again
  while it was wrong in the opposite direction.

So **ask the thing that will act on it**. Run `rsync` over a scratch tree and
see which files arrive. Ask `iptables -S` which chain the rule landed in, rather
than asking the file what it says. Hand the config to the parser that will read
it in anger. That is usually a few lines and a `File::Temp` directory, and it is
the difference between testing your templating and testing your feature.

Two smells that say you are asserting on the artifact:

- **The expected value came from the test.** If the test supplies `$net` and then
  greps the output for `$net`, the only thing it can detect is a template that
  dropped it. A wrong `$net` sails through.
- **The assertion would still pass if the consumer changed its mind.** Glob
  syntax, regex flavour, chain semantics, quoting rules -- an assertion that does
  not go through the real implementation is pinned to your belief about that
  implementation rather than to the implementation.

The check that catches all of it: **make the assertion fail on purpose.** Break
the value, the pattern or the ordering, and confirm the test goes red before you
call it done. An assertion you have never seen fail is one you are guessing
about, and all three above stayed green against deliberately broken input.

# Running tests

Run tests with `prove -lm -j8`

Re-run with `-v $testfile` option if you need details on why a specific test failed

# Test coverage

To discern coverage information run `cover -test -report json`.
It will output coverage information per test and total in `cover\_db/cover.json`

We want coverage per file to be greater than or equal to what it was before a patchset.

# Test performance

Structural test files should not ever take more than 30 seconds to run, and we should aim for substantially less than that.
If the runtime of a test increases by 3 standard deviations versus what it previously took, profiling should be done; there is likely room for improvement.

`prove -MDevel::NYTProf -lmv $testfile && nytprofhtml` will produce the profiling information you need to read in `nytprof/`

See the [perl-slop:profiling-perl](../profiling-perl/profiling-perl.md) skill for more details.

# Nature of fake data

When you need a domain name, use `test.test` or a subdomain thereof.  Never use `example.com`.

Avoid any remotely plausible file path names where possible (example: /bogus).
If a test results in unintended system modifications this helps make them obvious.
