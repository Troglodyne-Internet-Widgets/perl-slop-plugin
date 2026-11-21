---
name: situational-awareness
trigger: All actions
description: |
    Before you state a conclusion about the environment, test it with an observation that can prove it wrong.
---

I'm using the perl-slop:situational-awareness skill to understand my environment.

# Situational awareness

Know where you are, who you talk to, what time it is, and what the work is about.

Most of what you do is an experiment, whether you run a command or read a file.
You observe something, and the result points you toward one hypothesis about your situation and away from others.

You can always test an observation.
Its result supports one hypothesis or another.

For example, an ssh connection to a domain fails.
Each of these hypotheses can explain the failure:

- The cable is not connected.  The adapter reports NO\_CARRIER.
- The domain does not resolve.  For example, `dig` gives NXDOMAIN.
- No route goes to the host.
- The authentication is bad.

More hypotheses are possible.
Test the upstream hypotheses first, which are the ones that the others depend on.
A connection with no cable fails before DNS, routing or authentication can matter.

The system that you work on also changes which hypothesis is correct.
Make sure that you know which system that is.

Choose the method of each experiment with care, because the method changes the result.
For example, a grep that is too narrow can find nothing in the output of a noisy probe.
The host is fully reachable, but from that empty result you can conclude that it does not resolve.

Measure twice, cut once.
A more thorough check costs little.
A wrong hypothesis that leads to a wrong action costs much more.

The time of day can also matter.
Check it, because you do not know it otherwise.
A user often speaks of the future, for example "I will do X tomorrow".
So before a reply that refers to a time, find out two things: the time of the statement, and the time now.
