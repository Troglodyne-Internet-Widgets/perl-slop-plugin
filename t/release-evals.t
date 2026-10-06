#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use re '/aa';

=head1 NAME

t/release-evals.t - run the eval suite of each skill that changed since the
last release, when a release is being cut

=head1 DESCRIPTION

A skill is a document that Claude follows, so whether it works is a question
about what Claude does with it.  The cases under F<evals/> give Claude a
request that a skill should handle, with this plugin loaded, and grade what it
produced.  For packaging-perl, that is whether the defaults it installs reach
the new distribution intact.

A run is a full Claude session for each case and each run, which costs money,
so this runs only when C<RELEASE_TESTING> is set, and only for the skills
whose files, or whose cases, changed since the last C<perl-slop--v*> tag.  A
case belongs to the skill whose name it starts with, as
F<evals/packaging-perl-compat> belongs to F<skills/packaging-perl>.

It needs C<claude> on the C<PATH>, logged in, and C<bubblewrap> and C<socat>
for the sandbox that a run's shell commands use.  It checks that bwrap can
make its namespaces before any run starts, because a run without them still
completes and scores what the Write tool alone could do.  Where it cannot, the
user runs F<scripts/setup-eval-sandbox>, which changes the AppArmor policy of
the host.  Each run is capped by
C<--max-cost-usd>.  The report is left local.

Core-only, as F<t/packaging-templates.t> is.

=cut

use Test::More;
use File::Temp qw{tempdir};
use FindBin;
use JSON::PP ();

plan skip_all => 'Set RELEASE_TESTING to run the evals; each run is a paid Claude session' unless $ENV{RELEASE_TESTING};

my $ROOT = "$FindBin::Bin/..";
chdir $ROOT or die "$ROOT: $!";

# Three runs of each case, with no baseline arm: what is checked is what the
# skill produced, not how much it adds over no plugin at all.
my $RUNS      = 3;
my $THRESHOLD = '0.9';
my $COST_CAP  = 20;
my @TOOLS     = qw{Write Edit Bash};

my $have_claude = grep { -x "$_/claude" } split /:/, $ENV{PATH} // q{};
plan skip_all => 'claude is not on the PATH' unless $have_claude;

my $output = sub {
    my (@cmd) = @_;
    open( my $fh, '-|', @cmd ) or die "@cmd: $!";
    local $/ = undef;
    my $text = <$fh>;
    close($fh);
    return ( $text // q{}, $? >> 8 );
};

my ($tag) = $output->( qw{git describe --tags --match}, 'perl-slop--v*', '--abbrev=0' );
chomp $tag;

opendir( my $dh, 'skills' ) or die "skills: $!";
my @skills = sort { length $b <=> length $a } grep { !m/\A[.]/ && -d "skills/$_" } readdir $dh;
closedir $dh;

# Each case, by the skill that it belongs to.
my %cases_of;
opendir( my $eh, 'evals' ) or die "evals: $!";
foreach my $case ( sort grep { -f "evals/$_/prompt.md" } readdir $eh ) {
    my ($skill) = grep { index( $case, "$_-" ) == 0 } @skills;
    ok( defined $skill, "evals/$case is named after the skill it tests" ) or next;
    push @{ $cases_of{$skill} }, $case;
}
closedir $eh;

my @changed = grep {
    my $skill = $_;
    !length $tag || ( $output->( qw{git diff --quiet}, $tag, '--', "skills/$skill", map { "evals/$_" } @{ $cases_of{$skill} } ) )[1] != 0
} sort keys %cases_of;

if ( !@changed ) {
    note( "No skill with evals changed since $tag" );
    done_testing();
    exit 0;
}
note( 'Changed since ' . ( length $tag ? $tag : 'the start' ) . ": @changed" );

# The same namespaces that the sandbox of a run asks for.  Without them every
# shell command of a run fails, and the case is graded on what Write could do.
my $sandbox = system(qw{bwrap --ro-bind / / --dev /dev --unshare-net true}) == 0;
ok( $sandbox, 'bwrap can make the namespaces that the sandbox of a run needs' ) or do {
    diag('Run scripts/setup-eval-sandbox, then run this again.');
    done_testing();
    exit 1;
};

foreach my $skill (@changed) {
    my $json = tempdir( CLEANUP => 1 ) . '/result.json';

    # Standard input closed: a claude child that can read a terminal can wait
    # on it.  Each argument is its own word, so no shell sees the glob.
    my $status = do {
        open( my $saved, '<&', \*STDIN ) or die "dup STDIN: $!";
        open( STDIN, '<', '/dev/null' ) or die "/dev/null: $!";
        system(
            qw{claude plugin eval .}, '--case', "$skill-*",
            '--runs', $RUNS, '--ablation', 'none', '--threshold', $THRESHOLD,
            '--max-cost-usd', $COST_CAP, '--trust-plugin', '--no-publish',
            '--json', $json, '--allow-tools', @TOOLS,
        );
        open( STDIN, '<&', $saved ) or die "restore STDIN: $!";
        $? >> 8;
    };

    my $result = eval {
        open( my $fh, '<', $json ) or die "$json: $!";
        local $/ = undef;
        JSON::PP->new->decode(<$fh>);
    };
    ok( $result, "$skill: the eval wrote its result" ) or do { diag $@; next };

    foreach my $case ( @{ $result->{cases} // [] } ) {
        my $score = $case->{aggregates}{score} // 0;
        cmp_ok( $score, '>=', $THRESHOLD, "$skill: $case->{name} scores at least $THRESHOLD" ) or do {
            foreach my $run ( @{ $case->{arms}{with} // [] } ) {
                diag( "run error: $run->{error}" ) if $run->{error};
                diag( "failed: $_->{name}" ) foreach grep { !$_->{passed} } @{ $run->{graders} // [] };
            }
        };
    }
    is( $status, 0, "$skill: claude plugin eval passed, and no run was cut short" )
      or diag( $result->{partial} ? "partial: $result->{partialReason}" : 'see the cases above' );
}

done_testing();
