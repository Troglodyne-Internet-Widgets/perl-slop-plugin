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
