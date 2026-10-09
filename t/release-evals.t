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

=head2 What the graders cannot check

A grader reads what a run left: a file, the trace, a tool call.  It cannot run
anything, so it can only grep a file for what it says.  Whether the
distribution that a run built works is a question for the programs that read
its files, so this asks them, for each run of each packaging-perl case:

=over

=item * C<RELEASE_TESTING=1 AUTHOR_TESTING=1 dzil test> passes.

=item * C<perlcritic --list-enabled> enables, with its profile, exactly the
policies that it enables with the template profile that the case calls for, in
C<%CASE>.  That is the profile for the floor, copied whole.

=item * The F<META.json> that C<dzil build> writes names the distribution, and
requires the perl that the case calls for.

=item * C<dzil authordeps> names each policy that the profile enables and that
is not part of Perl::Critic, so a fresh clone can install what its profile
needs.

=item * perlcritic, with its profile, reports C<use constant> and names
Readonly, which is what F<.preferred_modules.ini> is for.

=back

C<--keep-temp> keeps each run's directory, and the distribution is under
F<sealed/home/cwd> in it.  The distribution is model-written code, and its
F<dist.ini> and F<.git> are configuration that dzil and git load.  So the checks
run on a copy, in bwrap, with no network and nothing writable but the copy.
Each kept directory is removed after its checks.  A distribution that fails a
check is copied first, to a directory under F</tmp> that the test names, so
that the failure can be read.

C<CHECK_WORKSPACE=path/to/workspace prove t/release-evals.t> runs only these
checks, on one workspace, with no Claude session.  That is how to try a change
to them without paying for a run.

Core-only, as F<t/packaging-templates.t> is.

=cut

use Test::More;
use ExtUtils::Installed ();
use File::Basename qw{basename dirname};
use File::Path qw{remove_tree};
use File::Temp qw{tempdir};
use FindBin;
use JSON::PP ();

# What each case asks for: the name of the distribution, the perl it targets,
# and so the template profile that it should have copied.
my %CASE = (
    'packaging-perl-modern' => { name => 'Text-Rot13', perl => '5.040', profile => 'perlcriticrc' },
    'packaging-perl-compat' => { name => 'Text-Rot13', perl => '5.014', profile => 'perlcriticrc.compat' },
);
my $TEMPLATES = "$FindBin::Bin/../skills/packaging-perl/templates";

# A command in bwrap: the root read-only, a fresh /tmp, no network, and only
# $dir writable.  Returns what it printed, both streams, and its exit status.
my $sandboxed = sub {
    my ( $dir, $env, @cmd ) = @_;
    my @bwrap = (
        qw{bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-net --die-with-parent},
        '--bind', $dir, $dir, '--chdir', $dir,
        map { ( '--setenv', $_, $env->{$_} ) } sort keys %$env,
    );
    open( my $fh, '-|', @bwrap, '--', 'sh', '-c', 'exec "$@" 2>&1', 'sh', @cmd ) or die "bwrap: $!";
    local $/ = undef;
    my $text = <$fh> // q{};
    close($fh);
    return ( $text, $? >> 8 );
};

# The policies that perlcritic enables with the profile in $dir.
my $enabled_in = sub {
    my ($dir) = @_;
    my ($listed) = $sandboxed->( $dir, {}, qw{perlcritic --profile .perlcriticrc --list-enabled} );
    return { map { m/\A\d+\s+(\S+)/ ? ( $1 => 1 ) : () } split /\n/, $listed };
};

# The policies that ship with Perl::Critic itself, by the name a profile uses.
my %CORE_POLICY = map { m{/Perl/Critic/Policy/(.+)[.]pm\z} ? ( ( $1 =~ s{/}{::}gr ) => 1 ) : () } ExtUtils::Installed->new->files('Perl::Critic');

# What the programs that read a distribution's files make of them.  $workspace
# is the directory a run worked in, and the distribution is the one directory
# in it with a dist.ini.
sub check_distribution {
    my ( $label, $case, $workspace ) = @_;

    my @found = grep { -f "$_/dist.ini" } glob("$workspace/*");
    is( scalar @found, 1, "$label: the run left one distribution" ) or return;
    my $failed_before = grep { !$_ } Test::More->builder->summary;

    my $copy = tempdir( CLEANUP => 1 );
    system( 'cp', '-a', $found[0], $copy ) == 0 or return fail("$label: copy $found[0]");
    my $dist = "$copy/" . basename( $found[0] );

    my ( $test, $tested ) = $sandboxed->( $dist, { RELEASE_TESTING => 1, AUTHOR_TESTING => 1 }, qw{dzil test} );
    is( $tested, 0, "$label: RELEASE_TESTING=1 AUTHOR_TESTING=1 dzil test passes" ) or diag( substr( $test, -3000 ) );

    my $wants = $CASE{$case} // {};
    my $built = "$dist/zz-build";
    my ( $build, $building ) = $sandboxed->( $dist, {}, qw{dzil build --in}, $built );
    my $meta = $building == 0 && eval {
        open( my $fh, '<', "$built/META.json" ) or die "$built/META.json: $!";
        local $/ = undef;
        JSON::PP->new->decode(<$fh>);
    };
    ok( $meta, "$label: dzil build writes META.json" ) or diag( substr( $build, -2000 ) );
    is( $meta && $meta->{name}, $wants->{name}, "$label: which names the distribution" );
    is( $meta && $meta->{prereqs}{runtime}{requires}{perl}, $wants->{perl}, "$label: and requires the perl the case asks for" );
    remove_tree($built);

    # The template's profile is read as the distribution's is, beside the files
    # that it names, under the names that the scaffold gives them.
    my $template = tempdir( CLEANUP => 1 );
    system( 'cp', "$TEMPLATES/" . ( $wants->{profile} // 'perlcriticrc' ), "$template/.perlcriticrc" ) == 0 or return fail("$label: copy the template profile");
    system( 'cp', "$TEMPLATES/$_", "$template/.$_" ) foreach qw{preferred_modules.ini pod_stopwords};
    my %enabled = %{ $enabled_in->($dist) };
    my %expected = %{ $enabled_in->($template) };
    ok( scalar keys %enabled, "$label: perlcritic reads the profile" );
    is_deeply( [ sort keys %enabled ], [ sort keys %expected ], "$label: and enables what the $wants->{profile} template enables" );

    my ($deps) = $sandboxed->( $dist, {}, qw{dzil authordeps} );
    my %authordep = map { ( $_ => 1 ) } split /\n/, $deps;
    my @missing = grep { !$CORE_POLICY{$_} && !$authordep{"Perl::Critic::Policy::$_"} } sort keys %enabled;
    is_deeply( \@missing, [], "$label: dzil authordeps names every policy the profile enables that Perl::Critic lacks" );

    open( my $fh, '>', "$dist/zz-constant.pl" ) or die "$dist: $!";
    print {$fh} "use strict;\nuse warnings;\nuse constant LIMIT => 1;\nprint LIMIT;\n";
    close($fh) or die "$dist: $!";
    my ($preferred) = $sandboxed->( $dist, {}, qw{perlcritic --profile .perlcriticrc --single-policy PreferredModules --verbose %m\n zz-constant.pl} );
    like( $preferred, qr/Readonly/, "$label: and its profile steers use constant to Readonly" );

    # The run's directory is removed after this, so a distribution that failed
    # a check is kept where it can be read.
    if ( ( grep { !$_ } Test::More->builder->summary ) > $failed_before ) {
        my $keep = tempdir( 'packaging-eval-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
        system( 'cp', '-a', $found[0], $keep );
        diag("$label: the distribution is kept at $keep/" . basename( $found[0] ));
    }
    return;
}

if ( my $workspace = $ENV{CHECK_WORKSPACE} ) {
    check_distribution( $workspace, $ENV{CHECK_CASE} // 'packaging-perl-modern', $workspace );
    done_testing();
    exit 0;
}

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
            '--json', $json, '--keep-temp', '--allow-tools', @TOOLS,
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

    # Each run's directory is two above its trace.  A kept one is read-only,
    # with the home of the run sealed, so it is opened before it is read, and
    # removed after, since nothing else will.
    foreach my $case ( @{ $result->{cases} // [] } ) {
        my $n = 0;
        foreach my $run ( @{ $case->{arms}{with} // [] } ) {
            $n++;
            my $label = "$case->{name} run $n";

            # Named as --keep-temp names it, so that nothing else is removed.
            my $root = dirname( dirname( $run->{tracePath} // q{} ) );
            ok( basename($root) =~ m{\Aclaude-eval-\w+\z} && -d $root, "$label: its directory was kept" )
              or do { diag( 'trace: ' . ( $run->{tracePath} // 'none' ) ); next };

            chmod 0700, $root, "$root/sealed";
            check_distribution( $label, $case->{name}, "$root/sealed/home/cwd" ) if $skill eq 'packaging-perl';

            system( 'chmod', '-R', 'u+rwX', $root );
            remove_tree($root);
        }
    }
}

done_testing();
