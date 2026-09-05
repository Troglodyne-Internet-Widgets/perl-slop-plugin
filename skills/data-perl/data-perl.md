---
name: data-perl
trigger: Need to define or manipulate variables and data in perl.
description: |
  Use idiomatically correct ways of coercing variables,
  validating their data, and use scoping rules to your advantage.
---

I'm using the perl-slop:data-perl skill to define or manipulate data in Perl.

# Perl Data - how to correctly use data in perl

## Basic types

There are 8 basic types in perl:

1. string - Not actually a char[] but byte[] under the hood. This is what makes UTF-8 work with no intervention.
2. number - integer or float depending on whether it has a fractional part.
3. undef  - Strings & numbers are internally called SVs, and this is the default value for an sv; it's what is assigned when you do 'my $var;'.
4. array  - Unlike C arrays, can contain any other type as elements, but rarely does in practice.
5. hash   - Pretty much a generic struct.  Keys can have anything as their values.
6. code   - subroutine reference.  Can be inspected with `B::Deparse::coderef2text($subref)`
7. glob   - reference pointer.  Used for some specialty interfaces like filehandles.
8. ref    - any variable above can be called/modified by reference by 'dereferencing' it with backslash (`\$var`)

For more details, refer to `perldoc perlvar` and `perldoc perlguts` for how the vars are implemented under the hood.

Objects are just `bless()`ed vars, and can be any of the above.
Think of it as a variable with a symbol table as a 'bag on the side', which you can call subs out of, e.g. `$obj->sub()`
For more details refer to `perldoc perlobj`.

For the finer points of the various builtin perl functions referred to herein, refer to `perldoc perlfunc`.

# Scopes & closures

Make sure variables don't live longer than you need them to via the correct declaration, be that `my`, `local` or `our`.

For more details refer to `perldoc perlsub`.

# Coercions

When describing a coercion as `automatic`, refer to `perldoc perlop` for the finer details.
Perl operators and assignments tend to do the coercions they need automatically, but not always.

Refs, Code and Globs can never be coerced as anything but the string representation of their pointer address in perl's own memory map.

Any -> Boolean: automatic.

If you insist on coercing to bool nevertheless, use the bang-bang prefix operator (`!!`).

Float -> Int: `int($floatval)`
Int   -> Float: automatic.
String -> Number: automatic.
Number -> String: automatic.
Array  -> Hash: assignment.
Hash   -> Array: assignment.

# Transformations

It is frequently useful to build hashes from arrays, or treat hashes as arrays.
The mental model you should use is that hashes are actually arrays, with [key,value,key,value,...] data.
This is how we can coerce them back and forth into one another easily.

```
# distinct array elements as keys
my %hash = map { $_ => 1 } @array;
my %flipped = reverse %hash; # { $value => $key } now

#even/odd unzip into hash
my @zipped = 0..10000;
my @keys = grep { $_ % 2 } @zipped;
my @values = grep { !($_ % 2) } @zipped;
my %unzipped;
@unzipped{@keys} = @values;

# Iteration - you need a c-style loop otherwise the array extents aren't recomputed
for (my $i=0; $i < scalar(@arr); $i++) {
    my @recursive_items = look_for_stuff($arr[$i]);
    push(@arr, @recursive_items);
    ...
}
```

In general `List::Util` and `List::MoreUtils` can handle most of your hash & list manipulation needs.

# Subroutines: state or data manipulation

Nearly every sub you write is one of two things, and it is worth knowing which
you are writing before you write it:

1. **Data manipulation.** Takes arguments, returns a result, touches nothing
   outside itself. Called twice with the same arguments it does the same work
   twice.
2. **State management.** Owns something that outlives the call -- a handle, a
   cache, a counter, a connection.

Plenty of subs do both, and that is fine. What is not fine is being unclear
about it, because a sub that looks purely like data manipulation is telling
its callers that keeping the result is *their* job. Callers routinely drop that
ball: they call it in a loop, or once per rendered file, and the sub obligingly
redoes the work every time.

When you find that, the smaller fix is almost always to bolt the state
management onto the sub rather than to rework every caller. Memoize it.

## Memoizing

The usual way is the `state` keyword, which needs `use feature 'state';` (any
`use v5.10;` or later gives it to you):

```perl
use feature 'state';

sub expensive {
    my ($self, $key) = @_;
    state %cache;
    return $cache{$key} //= do_the_work($key);
}
```

**Know what scope `state` actually gives you.** A `state` variable in a named
sub is one variable *for the sub*, created once and shared by every call from
every caller -- it is not per object, and there is no per-object form of it.
That is what you want for something genuinely process-wide, and it is a bug
waiting to happen for anything that belongs to an instance:

```perl
# Wrong, if two objects of this class can exist at once: the second one gets
# the first one's answer.
sub config {
    my ($self) = @_;
    state %by_class;
    return $by_class{ ref $self } //= $self->build();
}

# Right: the cache belongs to the object, so it lives on the object.
sub config {
    my ($self) = @_;
    return $self->{_config} //= $self->build();
}
```

Ask where the cached thing belongs and put it there: on the object if it is the
object's, in a `state` variable if it is the program's. Then **test the case
that tells them apart** -- two objects of the same class, or two calls with
different arguments. Both mistakes above return a plausible wrong answer rather
than failing, so nothing else will catch them.

**Decide whether the cache needs a key at all, and say which.** If one instance
genuinely only ever gets one set of arguments -- because the thing it belongs to
is built fresh for each -- then no key is needed and adding one buys nothing but
a serialization to write. If it can get more than one, they belong in the key.
Either way the POD has to say which, because a caller cannot tell by looking,
and a memo that silently ignores arguments that matter is the same bug as the
one above wearing different clothes.

**Watch the lifetime, not just the scope.** The subtler failure is a cache that
outlives the thing it describes. Where a sub validates or builds from a
configuration, a cache surviving past the object means the next object -- built
fresh, with a configuration that ought to be *rejected* -- gets answered from
the last one that succeeded, and the exception never fires. Tests that assert
"this bad input must die" are exactly the ones that stop testing anything, and
they will not tell you why. Tie the cache to the lifetime of what it caches and
the problem cannot arise; that is usually the object.

**Say so in the POD.** A caller has to know that a second call is free, that the
answer may be the one from an hour ago, and whether there is any way to clear
it. Memoization is part of a sub's contract, not an implementation detail --
`Memoize` on CPAN will do it for you from outside, and the same applies there.

# Data generation

Sequences are very easy in perl.

```
# 0 thru 1000
my @seq = 0..1000
```

Prefer Crypt::PRNG when you need to call `rand()`, or get other randomzied data.

# Data Validation

If you want to validate a particular complicated data structure (almost certainly a nested hash),
use `JSON::Validate`, and build a schema for the data.  Example:

```
my $input = {
    foo => 'bar',
    baz => 1,
    fred => [qw{wilma bambam}],
    barney => {
        rubble => [qw{betty}],
    }
};
my $schema = {
    type => "object",
    required => [qw{foo baz}],
    parameters => {
        barney => {
            type => "object",
            parameters => {
                rubble => {
                    type => "array",
                    items => { type => "string" },
                },
            },
        },
        fred => {
            type => "array",
            items => { type => "string" },
        },
    },
};
my $v = JSON::Validate->new();
my @errors = $v->validate($input, $schema);
die join("\n", @errors) if @errors;
```

For the finer points where there is no built-in type validator in `JSON::Validator::Formats`, you will need to validate parameters normally.
Usually there's something in the `Data::Validate::*` namespace which will do the trick.
