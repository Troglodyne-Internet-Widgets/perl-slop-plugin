---
name: killing-processes
trigger: A command is about to send a signal with kill, pkill, killall or timeout -s.  Or a command is about to find processes by pattern with pgrep or pkill.  Or a test is about to check how a program handles SIGHUP or SIGTERM.
description: |
  Send a signal only to a process that you can name by its PID.  pkill -f and
  pgrep -f match the whole command line.  The command line of the shell that
  the Bash tool runs is your whole command, and the pattern is in it.  So a
  pattern matches the shell that runs it.  A session ended this way once, in
  the middle of a test of how bash handles a hangup.
---

# Killing processes without killing yourself

The hooks of this plugin ask for this skill before a Bash command that runs
`kill`, `pkill`, `killall` or `pgrep`.

The Bash tool runs each command as `bash -c '<your whole command>'`.  The
command line of that shell holds every word that you wrote, so it holds the
pattern that you give to `pkill -f` or `pgrep -f`.  The pattern matches its own
shell.

This happened in one session, in three steps:

1. `pgrep -f -n 'bash --login -i'` was meant to find a test shell.  `-n`
   picks the newest match, and the newest match was the shell of the Bash
   tool.  `kill -HUP` went to that shell, not to the test shell.
2. The next test got its PID from a file that the test shell wrote, and that
   test was sound.
3. The cleanup ran `pkill -f 'tail -f /dev/null'`.  That string was in the
   command line of the shell that ran it.  The command ended with exit 144,
   and the session ended with it, with nothing written after that result.

It is not certain which signal ended the session itself.  It is certain that
each of those patterns matched the command that sent it.

## The rule

Signal a PID that the process gave you.  These sources are good:

- `$!` right after you start the process in the background.
- A PID file that the process writes itself, for example
  `printf 'echo $$ > %s\n' "$pidfile" > "$HOME/.bash_profile"` in a scratch
  home.
- The output of the program, for example `SSH_AGENT_PID=` from `ssh-agent`.
- `systemctl show -p MainPID --value <unit>` for a service.

Before you send the signal, make sure that the PID is the process that you
mean:

```sh
ps -o pid,ppid,args -p "$pid"
```

After you send it, make sure that it is gone, with `ps -p "$pid"`, and not with
a new search by pattern.

## What not to do

- Do not use `pkill -f`, `killall`, or `kill $(pgrep -f ...)` with a pattern
  that is in your own command.  The pattern is always in your own command.
- Do not use `pgrep -n` or `pgrep -o` to choose one process.  Newest and
  oldest are decided among all matches, and your own shell is one of them.
- Do not send a signal to `0`, `-1`, or a negative PID.  `kill 0` signals your
  own process group, and `kill -1` signals every process that you own.
- Do not send a signal to `$$`, `$PPID`, or anything above them.  The Claude
  Code process is up there.

## If you must find a process by pattern

First list the matches, and read them:

```sh
pgrep -a -f '[t]ail -f /dev/null'
```

The brackets make a pattern that matches `tail` and does not match its own
text, because the text has `[t]` in it.  Leave out `$$` and every ancestor of
it, then kill by the PIDs that are left, in a separate call.

## Testing how a program handles a signal

Start the program under test in a new session, and record its PID from the
program itself:

```sh
( HOME=$scratch setsid script -qfc "bash --login -i" /dev/null \
    < <(sleep 30) > /dev/null 2>&1 & )
until [ -s "$scratch/bash.pid" ]; do sleep 0.2; done
pid=$(cat "$scratch/bash.pid")
kill -HUP "$pid"
```

`setsid` puts the test in a process group of its own, so no signal that you
send to it reaches your own group.  Give it input that stays open and idle,
such as `sleep 30`.  A shell that reads `/dev/zero` reads a stream of NUL
bytes, and it acts differently.  The idle input also ends by itself, so
nothing needs a pattern to clean it up.
