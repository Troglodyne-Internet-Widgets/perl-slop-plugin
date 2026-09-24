#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use re '/aa';

=head1 NAME

t/packaging-templates.t - the two perlcritic profiles the packaging-perl skill
scaffolds with, and what the skill says about them

=head1 DESCRIPTION

There are two profiles because the perl a distribution targets decides how
strict it can be.  What makes them a pair rather than two files is that one
leaves out exactly the policies the language enforces and the other names them,
so the only thing worth asserting is that relationship -- and that the skill,
the scaffold and dist.ini still agree with it.

Core-only on purpose: this asserts on the text of the templates, so it runs
wherever the plugin does rather than only where Perl::Critic and twenty policy
distributions are installed.

=cut

use Test::More;
use FindBin;

my $SKILL     = "$FindBin::Bin/../skills/packaging-perl";
my $TEMPLATES = "$SKILL/templates";

sub slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "$path: $!";
    local $/ = undef;
    my $text = <$fh>;
    close($fh);
    return $text;
}

# The policies a modern perl makes pointless, and the version that does it.
# Measured with the one-liners in the skill, not remembered.
my %ENFORCED_FROM = (
    'TestingAndDebugging::RequireUseStrict'    => '5.012',
    'Objects::ProhibitIndirectSyntax'          => '5.036',
    'InputOutput::ProhibitBarewordFileHandles' => '5.038',
    'InputOutput::ProhibitBarewordDirHandles'  => '5.038',
    'Modules::RequireEndWithOne'               => '5.038',
    'Variables::ProhibitPerl4PackageNames'     => '5.042',
    'CodeLayout::RequireASCII'                 => '5.042',
);

my $modern = slurp("$TEMPLATES/perlcriticrc");
my $compat = slurp("$TEMPLATES/perlcriticrc.compat");
my $skill  = slurp("$SKILL/packaging-perl.md");
my $dist   = slurp("$TEMPLATES/dist.ini");

# A policy is enabled by a [Name] line of its own, not by being talked about in
# a comment: both files discuss the policies they leave out.
sub enables {
    my ( $profile, $policy ) = @_;
    return $profile =~ m/^\[\Q$policy\E\]$/m ? 1 : 0;
}

subtest 'both profiles are profiles at all' => sub {
    foreach my $pair ( [ modern => $modern ], [ compat => $compat ] ) {
        my ( $which, $text ) = @$pair;

        like( $text, qr/^only\s*=\s*1$/m,     "$which loads nothing it does not name" );
        like( $text, qr/^severity\s*=\s*1$/m, "$which reports everything it names" );
        like( $text, qr/^\[CompileTime\]$/m,  "$which still compiles what it reads" );
    }
};

subtest 'the pair differs by the policies the language enforces' => sub {
    foreach my $policy ( sort keys %ENFORCED_FROM ) {
        my $from = $ENFORCED_FROM{$policy};

        # 5.042 is above what the modern profile assumes, so those two are in
        # both, and the profile says to delete them once the floor is 5.041.
        my $modern_should = $from eq '5.042' ? 1 : 0;

        is( enables( $modern, $policy ), $modern_should, "the modern profile " . ( $modern_should ? 'keeps' : 'leaves out' ) . " $policy" );
        is( enables( $compat, $policy ), 1,              "the compat profile names $policy, because 5.014 does not" );
    }
};

subtest 'everything else in the pair is the same set' => sub {
    my @modern_policies = $modern =~ m/^\[([^\]]+)\]$/gm;
    my @compat_policies = $compat =~ m/^\[([^\]]+)\]$/gm;

    my %in_compat = map { $_ => 1 } @compat_policies;
    my @only_modern = grep { !$in_compat{$_} } @modern_policies;

    # The whole argument for two files is that they differ by the version, so a
    # policy in one and not the other is either a version difference or a
    # mistake -- and a policy only the modern one has cannot be either.
    is_deeply( \@only_modern, [], 'the modern profile asks nothing the compat profile does not' );

    my %in_modern = map { $_ => 1 } @modern_policies;
    my @only_compat = grep { !$in_modern{$_} } @compat_policies;
    my @unexplained = grep { !exists $ENFORCED_FROM{$_} } @only_compat;

    is_deeply( \@unexplained, [], 'and the compat profile adds only what a newer perl would enforce' )
      or diag( 'unexplained in the compat profile: ' . join( ', ', @unexplained ) );
};

subtest 'the skill tells the same story as the files' => sub {
    like( $skill, qr/^##\s+Ask\s+which\s+perl/m, 'it asks before it copies' );

    foreach my $policy ( sort keys %ENFORCED_FROM ) {
        my $from = $ENFORCED_FROM{$policy};

        like( $skill, qr/\Q$policy\E/, "the table names $policy" );
        like( $skill, qr/\Q$policy\E[^\n]*\Q$from\E/, "and gives $from as the version that retires it" );
    }

    like( $skill, qr/perlcriticrc\.compat/, 'and names the second profile so it can be copied' );
};

subtest 'the hook judges what it tidied, with the profile that was copied' => sub {
    my $hook = slurp("$TEMPLATES/pre-commit");

    like( $hook, qr/perlcritic\s+--profile\s+\.perlcriticrc/, 'the hook runs critic against the one profile the scaffold writes' );
    unlike( $hook, qr/perlcriticrc\.compat/, 'and has no opinion about which profile that is, because the scaffold decided' );

    # Order matters: the tidy pass rewrites the files and stages what it wrote,
    # so critic has to read those bytes rather than the ones the author saved.
    my $tidy_at   = index( $hook, 'perltidy -b' );
    my $critic_at = index( $hook, 'perlcritic --profile' );
    ok( $tidy_at > 0 && $critic_at > $tidy_at, 'and runs it after the tidy pass rather than before' );

    like( $hook, qr/exit\s+1/, 'a refusal stops the commit' );

    # A test is not a module, and a release does not judge t/ at all, so the one
    # policy that asks a test for a page nobody will read is dropped there.
    my ($test_pass) = $hook =~ m/^([^\n]*perlcritic[^\n]*\$test_files[^\n]*)$/m;
    my ($lib_pass)  = $hook =~ m/^([^\n]*perlcritic[^\n]*\$lib_files[^\n]*)$/m;

    # Named, so that a pattern that stops matching fails here rather than
    # passing an undef to unlike() and reporting nothing.
    ok( defined $test_pass && defined $lib_pass, 'the hook runs one pass over t/ and one over everything else' )
      or diag('no perlcritic line found for one of the two lists');

    like( $test_pass, qr/--exclude\s+Documentation::RequirePod/, 't/ is judged without the POD requirement' );
    like( $test_pass, qr/--profile\s+\.perlcriticrc/,            'and by the same profile as everything else' );
    unlike( $lib_pass, qr/--exclude/,                            'while a module is still asked for its POD' );
};

subtest 'what the profiles read is scaffolded and shipped' => sub {

    # PodSpelling reads a stopword list, and the author tests run critic inside
    # the build, so a file nobody copied is a release that fails on the author's
    # own machine and nowhere else.
    foreach my $wanted (qw{.pod_stopwords .preferred_modules.ini .perlcriticrc}) {
        like( $dist, qr/cp[^\n]*\Q$wanted\E/,     "dist.ini copies $wanted into the build" );
        like( $dist, qr/echo\s+\Q$wanted\E\s*>>/, "and appends $wanted to the MANIFEST" );
    }

    ok( length slurp("$TEMPLATES/pod_stopwords"), 'the stopword list is a template with something in it, so there is something to copy' );

    # weaver.ini's licence text is in every built module, and aspell knows none
    # of these, so a stopword list without them fails every new distribution.
    my %stop = map { $_ => 1 } grep { length && !m/^#/ } split /\n/, slurp("$TEMPLATES/pod_stopwords");
    ok( $stop{$_}, "the stopword list has $_, from the generated licence text" ) foreach qw{MERCHANTABILITY NONINFRINGEMENT sublicense};
    ok( $stop{bugtracker}, 'and bugtracker, which no dictionary has' );

    # Sorted without regard to case and once each, as the file's header says, so
    # that adding a word is a one-line diff.
    my @words = grep { length && !m/^#/ } split /\n/, slurp("$TEMPLATES/pod_stopwords");
    my @sorted = sort { lc $a cmp lc $b or $a cmp $b } @words;
    is_deeply( \@words, \@sorted, 'the stopword list is sorted' );
    is( scalar( keys %stop ), scalar @words, 'and has each word once' );
    like( $skill, qr/cp[^\n]*pod_stopwords/, 'and the scaffold copies it' );

    # Every policy outside Perl::Critic's own distribution needs a line, or a
    # fresh clone cannot install what the profile names.
    foreach my $policy ( 'ProhibitPrintSTDERR', 'Variables::ProhibitUnusedVarsStricter', 'RegularExpressions::PreventUselessMetacharacterEscapes' ) {
        like( $dist, qr/authordep\s+Perl::Critic::Policy::\Q$policy\E/, "dist.ini declares the authordep for $policy" );
    }

    # A policy the profiles ship commented out must not bring a dependency with
    # it: dzil reads authordeps out of comments, so the line would install a
    # distribution nothing here uses.
    foreach my $profile ( $modern, $compat ) {
        unlike( $profile, qr/^\[ProhibitUnusedDefinitions\]$/m, 'a library scaffold does not enable ProhibitUnusedDefinitions' );
    }
    unlike( $dist, qr/authordep[^\n]*ProhibitUnusedDefinitions/, 'and does not ask for it to be installed' );
};

subtest 'the version dzil stamps is not code above use strict' => sub {

    # PkgVersion inserts a $VERSION line after the package line unless it is told
    # to write it into the package line, and RequireUseStrict reports that line
    # in the built module.  So a profile that names the policy needs the option.
    my ($pkgversion) = $dist =~ m/^\[PkgVersion\]\n((?:[^\[\n][^\n]*\n)*)/m;
    ok( defined $pkgversion, 'dist.ini has a [PkgVersion] section' ) or return;

    ok( enables( $compat, 'TestingAndDebugging::RequireUseStrict' ), 'the compat profile names RequireUseStrict' );
    like( $pkgversion, qr/^use_package\s*=\s*1$/m, 'so PkgVersion writes the version into the package line' );
};

subtest 'the perl floor is written where PrereqsFile reads it' => sub {

    # PrereqsFile reads prereqs.yml and prereqs.json, and its filename option
    # cannot name one file from dist.ini, so any other name is ignored silently.
    like( $dist, qr/^\[PrereqsFile\]$/m, 'dist.ini reads a prereqs file' );

    my $prereqs = slurp("$TEMPLATES/prereqs.yml");
    like( $prereqs, qr/^\s+perl:\s*'\{\{PERL_FLOOR\}\}'$/m, 'the template declares the perl floor' );
    like( $skill, qr/cp[^\n]*templates\/prereqs\.yml\s+prereqs\.yml/, 'the scaffold copies it under the name PrereqsFile reads' );
    like( $skill, qr/sed[^\n]*\bprereqs\.yml\b/,                        'and fills in its placeholder' );

    foreach my $file ( "$SKILL/packaging-perl.md", map {"$TEMPLATES/$_"} qw{CLAUDE.md perlcriticrc perlcriticrc.compat} ) {
        my $text = slurp($file);
        my @told = $text =~ m/(prereqs\.yaml)(?![^\n]*not an alternative)/g;
        is( scalar @told, 0, "$file tells nobody to write prereqs.yaml" );
    }
};

done_testing();
