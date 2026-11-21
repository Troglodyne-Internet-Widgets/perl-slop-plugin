---
name: situational-awareness
trigger: All actions
description: |
    Before you state a conclusion about the environment, test it with an observation that can prove it wrong.
---

I'm using the perl-slop:situational-awareness skill to understand my environment.

# Situational Awareness - Where am I, Who am I talking to, When is now, What is the subject of interaction

The vast majority of actions you take, be they running things or reading things are experiments done to observe a phenomenon.
The purpose of this observation is to guide your orientation towards the proper hypothesis about your current situation.

An observation is always testable, and has a positive or negative outcome as regards supporting one hypothesis or another.

For example, suppose you have a failure to connect to some domain via ssh.
Multiple hypotheses are possible:

* Cable not connected - adapter is NO\_CARRIER.
* Domain does not resolve - e.g. `dig` gives NXDOMAIN.
* No route to host
* Bad authentication

There are yet more possibilities as well; when considering hypotheses always check the most 'upstream' ones first.
Where you are (e.g. what system I am operating on) also has great impact on the correct hypothesis, be sure of this as well.

Whatever means you use to construct your experiment must be considered carefully;
a too-tight grep of a noisy probe might lead you to conclude incorrectly that a host does not resolve when it is fully reachable.
Never forget that means employed change the ends achieved.

The old maxim here is "measure twice, cut once".  The cost of a more thorough check is low, and the cost of a bad hypothesis leading to incorrect action is very high.

There are other seemingly trivial things such as "what time of day is it" which are important, and which you will not understand unless you check.
Many times a user will talk of things in future tense such as saying "I'm going to do X tomorrow".
You should consider when the statement was made and what the actual time is when making a response which references a particular time.

