---
name: information-security
trigger: Prose needs to be emitted in POD, comments, commits, issues or directly to the user.  A file that can hold a secret is about to be shown.
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

## Keep a secret out of the output

You can take a name out after you read it, because you know what to replace.
You cannot do the same with a secret.
When a command prints a secret, the secret is in the transcript.
Nothing that you write after that takes it back.
So decide before you read the file, not after.

Some files can hold a secret, for example a credentials file, an environment file or a configuration with a token.
Show such a file only through a command that cannot print a value.
The command must be safe for any content of the file.

### Bad
    sed -E 's/(TOKEN|token)([=: ]+)[^ "'"'"']+/\1\2<redacted>/' credentials.sh

This filter prints each line that it does not match, with no change.
The pattern expects the value directly after the `=`.
In the line `export EXAMPLE_TOKEN="..."`, a quote comes after the `=`.
So the line does not match, and sed prints the token.
A filter of this kind leaks when the file is different from your guess.
You must guess, because you did not see the file.

### Good
    grep -o '^export [A-Za-z0-9_]*' credentials.sh      # the names only
    sed 's/=.*/=<redacted>/' credentials.sh             # every value cut

These commands print no secret on a line that they do not expect.
Usually you need less than this.
The question is where the credential comes from, or what it can do.
Neither answer is the value.

To find out what a credential can do, load it without printing it.
Then print only the response:

    eval "$(grep '^export EXAMPLE_TOKEN=' credentials.sh)"
    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $EXAMPLE_TOKEN" "$api/profile"

The profile answers 200, and the endpoint that you want answers 401.
That tells you that the token is valid but does not have the scope.
Nobody saw the token.

If a secret gets into the output, tell the user at once.
Tell them that the secret must be rotated.
The owner of the secret decides what to do, and the owner can decide only with this information.

## Think abstractly - right thinking begets right doing

Specific data is rarely important to programs.
The important thing is what set of possible inputs/outputs a particular datum was a member of.
Regard *input/output domains* rather than specifics as the important detail that needs to be communicated,
rather than a specific piece of text.

Reasoning thusly also leads to more comprehensive solutions when writing code to deal with the situations
which brought up site-specific details.
