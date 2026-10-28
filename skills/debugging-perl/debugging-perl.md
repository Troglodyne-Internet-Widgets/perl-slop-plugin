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

Reading the code tells you what the code can do.  The debugger tells you what
it did.  If the two disagree, the program is right and your reading is wrong.
So stop reading and run the program.

The usual case looks like this.  A program looks for a key in a hash.  If the
key is not there, the program must die.  The key is not in the file that the hash
comes from, and the program does not die.  Each search of the code finds no
statement that writes the key.  A watch expression in the debugger finds that
statement in one run.

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

Run the same check from two entry points.  For example, one program calls a
module, and the module refuses an input.  Another program calls the same
module with the same input, and the module accepts it.  Then the cause is in
the code that the second program runs before the call.  The difference between two runs is a smaller search than the
whole program.

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

The commands that do most of the work:

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

- `Line N not breakable` means that no statement starts on that line.  The
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
$main::W = $data
w exists $main::W->{$key}
c
T
```

The line that the watch shows is the next one to run.  Look at the statements
just above it for the change.

## 6. Look for autovivification first

If a key exists that nothing writes, look for this first.  A read that goes
through a missing level makes that level:

```perl
my $value = $hash->{$outer}{$inner};    # $hash->{$outer} now exists
```

The read returns undef, as you expect, and `$hash->{$outer}` is now an empty
hash.  A `foreach` over `@{ $hash->{list} }`, and a reference taken with
`\$hash->{key}`, make the key too.  It does the most harm in a hash that many
callers share, such as a cache or a configuration that a module remembers.
One caller reads, and every later caller finds the key.

Read one level at a time, and ask `exists` before you go down:

```perl
my $level = exists $hash->{$outer} ? $hash->{$outer} : {};
my $value = $level->{$inner};
```

## 7. Read exit statuses from the program, not from a wrapper

- If its caller leads a process group, `setsid` forks.  Then it returns 0 at
  once, unless you give it `--wait`.  A run that died can then seem to
  succeed.
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
