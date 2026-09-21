---
name: information-security
trigger: Prose needs to be emitted in POD, comments, commits, issues or directly to the user.
description: |
  Anything you say can and will be used against you by e-detectives in a court of lol.
  Don't reveal information about site-specific things if you don't have to.
  Thinking abstractly leads to better solutions anyways.
---

I'm using the perl-slop:information-security to prevent information disclosure.

# Information Security - Prose Skill

Any time you are dealing with a software system there is information which is not quite secret
but that nevertheless represents an information disclosure risk.

The classic example of this is DNS Zones.
While any given record may be queried publicly,
dumping the zonefile (such as can happen due to promiscuously allowing AXFR)
gives an attacker a map of your entire attack surface.

The same applies to configuration files, databases and the information contained therein.

Any time you need to refer to site-specific details, such as when describing the cause of an issue,
instead use a metasyntactic variable name and describe the *characteristics* of the data that caused it to be relevant.

Example:

### Bad
Your domain wegotussomemedicalwaste.biz exceeded the character limit...

### Good
When `$domain` exceeded the character limit...

## Evidence is quoted with the names taken out

Saying what you ran and what it said is how a claim gets believed,
and it is the likeliest way site-specific detail gets out:
a log line is full of hostnames, paths and account names,
and pasting it verbatim is less work than deciding which parts were somebody else's.

Substitute them anyway.

### Bad
    ok 3 - somebox.customer.tld trusts the host keys of git.internal.customer.tld

### Good
    ok 3 - $domain trusts the host keys of $forge

The second one proves what the first one proved.
What made the line evidence was its *shape* -- that the assertion ran, and passed, and which assertion it was --
and not which installation produced it.
Whoever needs the literal string has the machine it came from;
a reader of the issue does not, and is not owed a map of somebody's estate as the price of a passing test.

## Think abstractly - right thinking begets right doing

Specific data is rarely important to programs.
The important thing is what set of possible inputs/outputs a particular datum was a member of.
Regard *input/output domains* rather than specifics as the important detail that needs to be communicated,
rather than a specific piece of text.

Reasoning thusly also leads to more comprehensive solutions when writing code to deal with the situations
which brought up site-specific details.
