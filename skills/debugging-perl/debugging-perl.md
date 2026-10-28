---
name: debugging-perl
trigger: A program did something that its code says it cannot do, and reading the code did not show how.  Or a command is about to run perl -d, or an edit adds $DB::single.
description: |
  Sometimes the code says that a perl program cannot do what it did.  Then
  find out with the perl debugger what it did.  A check that must refuse
  passed, or a value that nothing writes is there.  Run the program to the
  branch under perl -d, with the commands on standard input, and look at
  the data there.  A watch expression finds the statement that changes it.
---

# Debugging perl

The hooks of this plugin ask for this skill before a command that runs
`perl -d`, and before an edit that adds `$DB::single`.  They also remind you of
it in two cases.  One is a prompt that says that a program did what it cannot
do.  The other is a turn that reads the code many times with no edit.

Reading the code tells you what the code can do.  The debugger tells you what
it did.  If the two disagree, the program is right and your reading is wrong.
So stop reading and run the program.

This happened in one session.  If the configuration has no key for a domain,
`bin/new_config` dies.  `bin/provision` built such a domain anyway.  Ten
searches of the code and the configuration found no way past the check.  The
debugger found it in five runs.

## 1. Find a run that changes nothing

The debugger runs the real program.  So before you run it, find out what the
run does up to the branch that you want to see.

- Read what the dry run of the program does.  A dry run can still write files
  or reserve resources.
- If standard input has no more lines, a prompt for a password stops the run.
  Then nothing after the prompt happens.  Do not answer the prompt.
- Do not run it against a production configuration with a mode that builds,
  sends or deletes.

## 2. Compare two ways in

Run the same check from two entry points.  In the session, `new_config` alone
refused the domain, and `new_config` under `bin/provision` let it through.  So
the cause was in the code that `bin/provision` runs first.  The difference
between two runs is a smaller search than the whole program.

## 3. Give the debugger its commands on standard input

The source debugger is `-d`.  `-D` sets the internal flags of a perl that was
built with `-DDEBUGGING`, and does not start the debugger.

With no terminal, the debugger reads its commands from standard input:

```sh
printf '%s\n' 'b Some::Package::some_sub' 'c' 'p $x' 'T' 'q' \
  | timeout 120 perl -d bin/program --dryrun ARGS 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g'
```

- Do not set `PERLDB_OPTS='TTY=/dev/stdout'`.  `TTY` names the input too, so
  the debugger reads nothing and stops at the first statement.
- The `sed` takes out the escape codes of the prompt.
- The output of the program and of the debugger come out in the wrong order.
  Put a label in each `p`, such as `p "exists=" . ...`, so that you can find
  each answer.
- Give every run a `timeout`.  A command that the debugger did not get leaves
  it waiting.

The commands that did the work:

| | |
|---|---|
| `b Pkg::sub` | stop at the first line of a sub |
| `b LINE` | stop at a line of the current file |
| `c` | continue to the next stop |
| `n` | the next statement, over sub calls |
| `s` | the next statement, into sub calls |
| `r` | run to the end of this sub, and print what it returns |
| `p EXPR` | print an expression |
| `x EXPR` | dump a data structure |
| `T` | the stack, with the arguments of each call |
| `w EXPR` | stop at a change in the value of an expression |

`perldoc perldebug` has the rest.

## 4. Stop where the code is

A breakpoint on a sub is better than one on a line.

- `Line 667 not breakable` means that no statement starts on that line.  The
  `unless` of a statement modifier is on its own line, for example.  Use the
  line that the statement starts on, or the sub.
- A breakpoint on a line of another file needs the file loaded first.  A
  module that a sub loads with `require` is not there at the start.  Stop at
  the line that calls it, then set `b Its::sub`, then `c`.
- In code that has no name, such as an anonymous sub or a string eval, put
  `$DB::single = 1;` on the line before the one to see.  The debugger stops
  there.  Take it out before you commit.

## 5. Watch the data, not the code

If a value is wrong and you do not know which statement made it, watch it.
`w EXPR` stops at the statement after the one that changed the value.  It
prints the old value and the new value.  Then `T` names the sub, and `l`
shows the code there.

A watch expression cannot name a lexical of another sub.  So stop where the
data is in scope, and copy a reference to it into a package variable:

```
b Some::Package::where_it_is_in_scope
c
n
$main::C = $conf
w exists $main::C->{'the.key'}
c
T
```

The line that the watch shows is the next one to run.  Look at the statements
just above it for the change.

## 6. What the session found

The watch stopped in a sub that only read the configuration:

```perl
my $own = clone( ( defined $domain ? $conf->{$domain}{_global} : undef ) // {} );
```

`$conf->{$domain}{_global}` reads, but to reach `{_global}` perl makes
`$conf->{$domain}` as an empty hash.  This is autovivification.  `$conf` was
the copy of the configuration that every caller shares.  So the domain was
then in the configuration, and `exists` passed.

If a key exists that nothing writes, look for this first.  A nested read, a
`foreach` over `@{ $h->{list} }`, and a reference taken with `\$h->{key}`
each make the key.  Read one level at a time:

```perl
my $mine = $conf->{$domain};
my $own  = ( $mine // {} )->{_global};
```

## 7. Read exit statuses from the program, not from a wrapper

- If its caller leads a process group, `setsid` forks.  Then it returns 0 at
  once, unless you give it `--wait`.  In the session, a run that died seemed to exit
  0 for that reason.
- After a pipe, `$?` is the status of the last command.  Use `set -o pipefail`,
  or `${PIPESTATUS[0]}`.

## 8. Then pin it with a test

Write the test from what the debugger showed, and see it fail before the fix.
The test asks the same subs, in the same order, that the program did.  Then
say in the commit message what you ran and what it printed: the breakpoint,
the watch, and the line that it stopped at.

See [perl-slop:testing-perl](../testing-perl/testing-perl.md) for the test, and
[perl-slop:reading-perl](../reading-perl/reading-perl.md) for the history of
the line that you found.
