---
name: http-perl
trigger: Fetching something over HTTP from perl -- picking a client, or working out why a request that looks right comes back wrong.
description: |
  Which HTTP client for which job, and the failures that do not announce
  themselves: a response that says it failed when nothing was ever sent, a 403
  that is really a 404, a timeout you did not set, and a fetch nobody checked.
---

I'm using the perl-slop:http-perl skill to make HTTP requests from perl.

There are three clients worth having, and the question that picks between them
is not which is nicest to write.

| what you are doing | what to reach for |
|---|---|
| one request, or a handful in a row | `HTTP::Tiny` |
| many at once, where the wall clock is the sum | `Net::Curl::Multi` |
| the answer only exists after JavaScript has run | `Playwright` |

Pick on that axis before you write anything. Reaching for the parallel one for a
single GET buys a socket callback and an event loop; reaching for the serial one
for forty fetches buys forty round trips end to end.

**And look at what the codebase already uses.** One existing caller settles it,
and consistency beats a marginally better client. If the existing one is wrong
for what you are about to do -- it is serial and you are fanning out -- that is
the moment to say so, not to quietly introduce a second client beside it.

## HTTP::Tiny, unless you can say why not

Core since perl 5.13.9, so it is already there. Two of its defaults are worth
knowing before you rely on them:

- **`timeout` is 60 seconds.** That is a long time to hold up a build, a
  preflight, or anything with somebody watching. Set it.
- **`verify_SSL` has been true since 0.083** and was false before that. If you
  support an older perl than you test on, you are one box away from a client
  that does not check certificates. Do not assume; the module's own POD says
  which version you have.

`https` needs `IO::Socket::SSL` and `Net::SSLeay`, which are not core.
`HTTP::Tiny->can_ssl` answers whether this perl has them, and is what to check
before a fetch rather than after.

```perl
use HTTP::Tiny();

my $res = HTTP::Tiny->new( timeout => 10 )->get($url);
```

## Net::Curl::Multi when you are fetching many

Real parallelism, one process, no forking. It is fiddlier than it looks, and it
has a trap that costs an afternoon -- see below.

**The loop below runs, and is not yet known to be the right shape.** It was
arrived at by bisecting a failure rather than from the idiom, and issue #3 is
open on replacing it with one somebody wrote on purpose. Take the trap as
established and the surrounding shape as provisional.

```perl
use Net::Curl::Multi qw(:constants);
use Net::Curl::Easy  qw(:constants);

my $multi = Net::Curl::Multi->new( {} );

# Net::Curl 0.58 aborts every transfer with "callback function is not set"
# unless these two exist, even though its own POD says they are only used by
# socket_action().  Empty ones are enough on the fdset/perform path.
$multi->setopt( CURLMOPT_SOCKETFUNCTION, sub { return 0 } );
$multi->setopt( CURLMOPT_TIMERFUNCTION,  sub { return 0 } );

my @handles;
foreach my $url (@urls) {
    my $easy = Net::Curl::Easy->new( { url => $url, body => q{} } );
    $easy->setopt( CURLOPT_URL,     $url );
    $easy->setopt( CURLOPT_TIMEOUT, 15 );
    $easy->setopt( CURLOPT_WRITEFUNCTION, sub { my ( $h, $chunk ) = @_; $h->{body} .= $chunk; return length $chunk } );
    $multi->add_handle($easy);
    push( @handles, $easy );
}

my $running = 1;
while ($running) {
    my ( $r, $w, $e ) = $multi->fdset();
    my $timeout = $multi->timeout();
    select( $r, $w, $e, $timeout > 0 ? $timeout / 1000 : 0.05 );
    $running = $multi->perform();
}

while ( my ( $msg, $easy, $result ) = $multi->info_read() ) {
    $multi->remove_handle($easy);

    # $result is false when the transfer happened.  It says nothing about what
    # the server said -- see "two different failures" below.
    ...
}
```

Three things about that which are not obvious:

- **The socket and timer callbacks are not optional.** Without them every
  transfer aborts, whether or not you set any callbacks of your own, with a
  message that points at the wrong thing entirely. The POD says they are for
  `socket_action()`; the implementation wants them regardless.
- **A base hashref is how you carry per-request state.** `new({ url => ... })`
  makes the handle that hashref, so `info_read` hands you back something that
  knows which request it was. Otherwise you are matching responses to requests
  by `CURLINFO_EFFECTIVE_URL` and hoping nothing redirected.
- **Keep the handles.** `add_handle` does not take a reference to the perl
  object for you.

## Playwright when the page is a program

`Playwright` drives a real browser, so it is the answer when what you want is
not in the response body -- a single-page app, a login that runs JS, anything
where `curl` gets you a `<div id="root">` and nothing else.

```perl
use Playwright;

my $handle  = Playwright->new();
my $browser = $handle->launch( headless => 1, type => 'chrome' );
my $page    = $browser->newPage();
$page->goto( $url, { waitUntil => 'networkidle' } );
my $text = $page->select('body')->textContent();
```

It needs node and the playwright server alongside it, so it is a real
dependency rather than a module -- do not reach for it because a page was
awkward to parse. Reach for it because the content genuinely is not in the HTTP
response.

# What goes wrong

Every one of these is quiet. None of them throws.

## Two different failures wearing one face

`HTTP::Tiny` reports a request that never left the machine the same way it
reports one the server refused: `success` is false for both.

```
status=599 reason=Internal Exception success=0
content: Could not connect to '127.0.0.1:1': Connection refused

status=404 success=0
```

**599 means we never got an answer** -- DNS, connection refused, TLS, or the
timeout -- and the reason is in `content` where a body would otherwise be.
Anything else is the server talking.

So `unless $res->{success}` is not enough to act on. Code that retries should
retry a 599 and a 503 and not a 404; code that reports should say which of the
two happened, because "the fetch failed" sends somebody to the wrong machine.
`Net::Curl` splits them for you -- the `$result` from `info_read` is the
transport, `CURLINFO_RESPONSE_CODE` is the server -- which is worth a moment's
envy when you are writing the `HTTP::Tiny` version.

## A 403 is not always a refusal

S3 answers `403 AccessDenied` rather than `404` for a key that is not there,
when listing is denied. Every path under a prefix answering 403, over v4 and
v6, reads as the far end blocking you and is not.

**Ask for something you know is missing on the same host** before concluding
anything: if `host/definitely-not-there` also 403s while a real key returns 200,
the 403 is a missing object and your URL is wrong.

## A URL nothing has fetched

A literal URL in a template, a config default or a comment is a claim nobody has
checked. Fetching every one of them takes a minute and is worth doing whenever
you touch the file: upstreams retire hosts, rename release assets, and move
repositories to mirrors that never cut a release.

Two shapes to be alert to, both of which look like success:

- **A 200 that is not the thing.** A mirror serving an index page, or a
  redirect to a "this has moved" landing page. Check the size or the content
  type, not just the status.
- **A version default resolved at runtime.** A recipe asking an API for "the
  latest release" and falling back to a constant when the request fails is a
  recipe that pins itself to that constant the day the API changes shape, and
  says nothing.

## The timeout you did not set

Sixty seconds is the `HTTP::Tiny` default and it is almost never what you want.
Set one, and set it against what the caller can stand rather than what the
server usually takes.

Watch for layered timeouts, too. If something fails at a suspiciously round
interval and raising your setting changes nothing, the number doing the killing
is not the number you are configuring -- look for the outer one before
concluding anything about the far end.

## Testing it

Mock the client, not the network. `Test::MockModule` in strict mode over
`HTTP::Tiny::get` gives you the response hash to hand back, and lets you write
the cases that matter and are otherwise unreachable: the 599, the 403, the
body that is valid and means something unexpected.

```perl
my $http = Test::MockModule->new('HTTP::Tiny');
$http->redefine( get => sub { return { success => 0, status => 599 } } );
```

A test that makes a real request is a test that fails when somebody else's
mirror is down, and passes for the wrong reason when a redirect is added. If
what you are testing is the parsing, the fetch is not the system under test.

**Assert on the case you cannot reproduce on demand.** The interesting bug is
rarely the happy path: it is the file that lists a release before it ships, the
key that 403s, the timeout. Those only ever appear in a test you wrote for them.
