#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use re '/aa';

=head1 NAME

t/packaging-templates.t - the templates the packaging-perl skill scaffolds
with, and the hooks among them

=head1 DESCRIPTION

There are two profiles because the perl a distribution targets decides how
strict it can be.  What makes them a pair rather than two files is that one
leaves out exactly the policies the language enforces and the other names them,
so the thing worth asserting is that relationship -- and that dist.ini and the
evals still agree with it.

Whether Claude, following the skill, puts these templates into a distribution
intact is a question about what Claude does, and F<t/release-evals.t> asks it.
Nothing here reads the skill's own prose.

Core-only on purpose: this asserts on the text of the templates, so it runs
wherever the plugin does rather than only where Perl::Critic and twenty policy
distributions are installed.  The exceptions run the pre-commit hook, with git
and sh, on commits that give perltidy and perlcritic nothing to judge.

=cut

use Test::More;
use File::Temp qw{tempdir};
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

# A PATH that holds only the tools the hooks use, so that whether tests-covering
# is there is the test's choice rather than the machine's.  With a fake
# tests-covering when $covering is given: its body, as sh.
sub hook_path {
    my ($covering) = @_;
    my $bin = tempdir( CLEANUP => 1 );
    foreach my $tool (qw{git sh sed env prove perl head grep nproc tr}) {
        my ($found) = grep { -x "$_/$tool" } split /:/, $ENV{PATH};
        symlink( "$found/$tool", "$bin/$tool" ) or die "$tool: $!" if defined $found;
    }
    if ( defined $covering ) {
        open( my $fh, '>', "$bin/tests-covering" ) or die $!;
        print {$fh} "#!/bin/sh\n$covering";
        close($fh) or die $!;
        chmod 0755, "$bin/tests-covering";
    }
    return $bin;
}

# Runs the pre-commit hook the way git runs it, on a commit of a README, so that
# neither Perl pass has anything to do and what decides is the tests alone.
# The tests are not staged: they are what the hook runs, not what it judges.
sub commit_readme {
    my ( $bin, %tests ) = @_;
    my $root = tempdir( CLEANUP => 1 );
    mkdir "$root/t" or die $!;
    foreach my $name ( keys %tests, '../README' ) {
        open( my $fh, '>', "$root/t/$name" ) or die $!;
        print {$fh} $tests{$name} // "words\n";
        close($fh) or die $!;
    }
    system( 'git', '-C', $root, 'init', '-q' ) == 0 or die 'git init';      ## no critic (ProhibitShellDispatch) -- the hook reads a real index
    system( 'git', '-C', $root, 'add', 'README' ) == 0 or die 'git add';    ## no critic (ProhibitShellDispatch)
    local $ENV{PATH} = $bin;
    my $out = `cd $root && sh $TEMPLATES/pre-commit 2>&1`;                    ## no critic (ProhibitShellDispatch) -- run the way git runs it
    return ( $? >> 8, $out );
}

my $PASS = "use Test::More;\nok(1);\ndone_testing;\n";
my $FAIL = "use Test::More;\nok(0, 'broken');\ndone_testing;\n";

subtest 'the hook runs the tests last, and a failing test stops the commit' => sub {
    my $hook = slurp("$TEMPLATES/pre-commit");
    ok( index( $hook, 'prove -lm -j8' ) > index( $hook, 'perlcritic --profile' ), 'the tests run after the critic pass, on the files it judged' );

    my $bin = hook_path();
    my ( $exit, $out ) = commit_readme( $bin, 'pass.t' => $PASS );
    is( $exit, 0, 'a suite that passes lets the commit through' ) or diag $out;

    ( $exit, $out ) = commit_readme( $bin, 'pass.t' => $PASS, 'fail.t' => $FAIL );
    is( $exit, 1, 'a failing test stops it' ) or diag $out;
    like( $out, qr{prove[ ]-lv[ ]t/<file>[.]t}, 'and the hook says how to see why' );
};

subtest 'without tests-covering, the hook runs every test' => sub {
    my ( $exit, $out ) = commit_readme( hook_path(), 'pass.t' => $PASS, 'fail.t' => $FAIL );
    is( $exit, 1, 'so a failing test that the commit does not reach still stops it' ) or diag $out;
    like( $out, qr/tests-covering[ ]is[ ]not[ ]on[ ]PATH/, 'and the hook says why it ran them all' );
};

subtest 'with tests-covering, the hook runs the tests it chooses' => sub {
    my ( $exit, $out ) = commit_readme( hook_path("echo t/pass.t\n"), 'pass.t' => $PASS, 'fail.t' => $FAIL );
    is( $exit, 0, 'so a failing test it did not choose does not stop the commit' ) or diag $out;
    like( $out, qr/tests[ ]that[ ]ran[ ]what[ ]this[ ]commit[ ]changes/, 'and the hook says which tests it ran' );

    ( $exit, $out ) = commit_readme( hook_path("echo t/fail.t\n"), 'pass.t' => $PASS, 'fail.t' => $FAIL );
    is( $exit, 1, 'while a failing test it chose does' ) or diag $out;

    ( $exit, $out ) = commit_readme( hook_path(''), 'fail.t' => $FAIL );
    is( $exit, 0, 'and a commit that reaches no test runs none' ) or diag $out;
    like( $out, qr/No[ ]test[ ]ran[ ]a[ ]line/, 'saying so' );

    ( $exit, $out ) = commit_readme( hook_path("exit 3\n"), 'pass.t' => $PASS );
    is( $exit, 1, 'and a tests-covering that fails stops the commit, rather than choosing nothing' ) or diag $out;
};

subtest 'the map says which files no test reads, and leaves the rest to the records' => sub {
    my $map = do "$TEMPLATES/tests-covering-map.pl";
    is( ref $map, 'CODE', 'it returns the map' ) or return diag( $@ || $! );

    foreach my $path (
        qw{
        Changes LICENSE README.md CLAUDE.md docs/guide.md docs/guide.pod
        dist.ini weaver.ini prereqs.yml
        .perlcriticrc .perltidyrc .pod_stopwords .preferred_modules.ini .mailmap .gitignore .tests-covering-map.pl
        git-hooks/pre-commit git-hooks/post-commit .github/workflows/test.yml xt/author/critic.t
        }
      )
    {
        is_deeply( [ $map->($path) ], [q{}], "$path reaches no test" );
    }

    # A module that no test loads yet, a test library, a fixture, a script and
    # POD beside the code are for the records, or for every test.
    foreach my $path (qw{lib/Some/Module.pm lib/Some/Module.pod t/lib/Helper.pm t/data/fixture.json share/table.csv bin/tool}) {
        is_deeply( [ $map->($path) ], [], "$path is left to the records" );
    }
};

subtest 'the post-commit hook refreshes the records after a commit, and not during a rebase' => sub {
    my $root = tempdir( CLEANUP => 1 );
    my $repo = "$root/repo";
    my $log  = "$root/refreshes";
    mkdir $repo or die $!;

    my @local = split /\n/, `git rev-parse --local-env-vars`;    ## no critic (ProhibitShellDispatch) -- git is what names them
    local @ENV{@local};
    delete @ENV{@local};

    # Records the commit it ran for, and each GIT_ variable that reached it.
    my $bin = hook_path(qq{echo "\$(git rev-parse HEAD) \$(env | sed -n 's/^\\(GIT_[A-Za-z0-9_]*\\)=.*/\\1/p' | tr '\\n' ' ')" >> '$log'\n});
    local $ENV{PATH} = $bin;

    my $git = sub {
        my (@args) = @_;
        my $said = `git -C $repo -c user.name=Tester -c user.email=tester\@test.test @args 2>&1`;    ## no critic (ProhibitShellDispatch) -- git runs the hook, which is what is under test
        die "git @args: $said" if $?;
        return $said;
    };
    my $commit = sub {
        my ($file) = @_;
        open( my $fh, '>', "$repo/$file" ) or die $!;
        print {$fh} "$file\n";
        close($fh) or die $!;
        $git->("add $file");
        $git->("commit -q -m $file");
        return;
    };

    # The hook refreshes in the background, so this waits for the line for the
    # commit at HEAD, and returns every line, which it then clears.
    my $refreshed = sub {
        chomp( my $head = $git->('rev-parse HEAD') );
        my @lines;
        foreach ( 1 .. 200 ) {
            @lines = -e $log ? split /\n/, slurp($log) : ();
            last if grep { index( $_, $head ) == 0 } @lines;
            select( undef, undef, undef, 0.05 );    ## no critic (ProhibitSleepViaSelect) -- core-only, and Time::HiRes is not needed for a poll
        }
        unlink $log;
        return @lines;
    };

    $git->('init -q');
    mkdir "$repo/.git/hooks";
    open( my $fh, '>', "$repo/.git/hooks/post-commit" ) or die $!;
    print {$fh} slurp("$TEMPLATES/post-commit");
    close($fh) or die $!;
    chmod 0755, "$repo/.git/hooks/post-commit";

    $commit->('a');
    my @lines = $refreshed->();
    is( scalar @lines, 1, 'a commit is refreshed once' );
    unlike( $lines[0] // q{}, qr/GIT_/, 'and hands the refresh none of the variables that git set for the hook' );

    my ($main) = $git->('branch --show-current') =~ m/(\S+)/;
    $git->('switch -q -c topic');
    $commit->($_) for qw{t1 t2 t3};
    $refreshed->();
    $git->("switch -q $main");
    $commit->('b');
    $refreshed->();

    $git->("rebase -q $main topic");
    $commit->('c');
    is( scalar( () = $refreshed->() ), 1, 'three commits rebased, and only the commit after them is refreshed' );
};

subtest 'the tests the hook runs get none of the variables that point git at the repository' => sub {

    # git sets GIT_INDEX_FILE for the hook, and GIT_DIR as well in a worktree,
    # and obeys them over -C.  This test may itself be run by such a hook, so
    # its own git must not see them either.
    my @local = split /\n/, `git rev-parse --local-env-vars`;    ## no critic (ProhibitShellDispatch) -- git is what names them
    ok( scalar @local, 'git names them' ) or return;
    local @ENV{@local};
    delete @ENV{@local};

    my $git = sub {
        my ( $dir, @args ) = @_;
        return system( 'git', '-C', $dir, '-c', 'user.name=Tester', '-c', 'user.email=tester@test.test', @args );    ## no critic (ProhibitShellDispatch) -- git runs the hook, which is what is under test
    };

    # Fails on any of those variables, and commits in a repository of its own,
    # which is what the variables would redirect.
    my $probe = join( "\n",
        'use strict; use warnings; use Test::More; use File::Temp qw{tempdir};',
        'my @set = grep { exists $ENV{$_} } split /\n/, `git rev-parse --local-env-vars`;',
        q{is( "@set", '', 'no variable points git at the repository being committed to' );},
        'my $inner = tempdir( CLEANUP => 1 );',
        q{system("git -C $inner init -q && echo x > $inner/x && git -C $inner add x && git -C $inner -c user.name=t -c user.email=t\@test.test commit -q -m inner");},
        'done_testing;', q{} );

    my $write = sub {
        my ( $path, $text ) = @_;
        open( my $fh, '>', $path ) or die "$path: $!";
        print {$fh} $text;
        close($fh) or die "$path: $!";
        return;
    };

    my $root = tempdir( CLEANUP => 1 );
    my $repo = "$root/repo";
    mkdir $repo or die $!;
    $git->( $repo, 'init', '-q' ) == 0 or die 'git init';
    mkdir "$repo/t" or die $!;
    $write->( "$repo/t/env.t", $probe );
    $write->( "$repo/.git/hooks/pre-commit", slurp("$TEMPLATES/pre-commit") );
    chmod 0755, "$repo/.git/hooks/pre-commit";

    # A README, so that what decides the commit is the suite alone.
    $write->( "$repo/README", "words\n" );
    $git->( $repo, 'add', 'README' ) == 0 or die 'git add';
    is( $git->( $repo, 'commit', '-q', '-m', 'in the checkout' ), 0, 'a commit in the checkout passes' );

    $git->( $repo, 'worktree', 'add', '-q', "$root/wt", '-b', 'wt' ) == 0 or die 'git worktree add';
    mkdir "$root/wt/t" or die $!;
    $write->( "$root/wt/t/env.t", $probe );
    $write->( "$root/wt/README",   "more words\n" );
    $git->( "$root/wt", 'add', 'README' ) == 0 or die 'git add';
    is( $git->( "$root/wt", 'commit', '-q', '-m', 'in a worktree' ), 0, 'and so does a commit in a worktree' );

    my @inner = grep { index( $_, q{inner} ) >= 0 } `git -C $repo log --all --format=%s`;    ## no critic (ProhibitShellDispatch)
    is( scalar @inner, 0, 'and what the test committed stayed in its own repository' );
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

    # PodSpelling accepts a word whose lowercase form is a stopword, so a
    # capitalized copy of a lowercase entry does nothing.
    my @redundant = grep { $_ ne lc $_ && ucfirst( lc $_ ) eq $_ && $stop{ lc $_ } } @words;
    is_deeply( \@redundant, [], 'no capitalized copy of a word it has in lowercase' );

    # aspell is asked for American English, so a British spelling is one the
    # POD should not be using in the first place.
    my @british = grep { m/is(?:e|es|ed|ing|ation)$/ && $stop{ ( my $us = $_ ) =~ s/is(e|es|ed|ing|ation)$/iz$1/r } } @words;
    is_deeply( \@british, [], 'and no British spelling of a word it has in American' );

    # Every policy outside Perl::Critic's own distribution needs a line, or a
    # fresh clone cannot install what the profile names.
    foreach my $policy ( 'ProhibitPrintSTDERR', 'Variables::ProhibitUnusedVarsStricter', 'RegularExpressions::PreventUselessMetacharacterEscapes', 'ValuesAndExpressions::ProhibitLiteralArithmetic' ) {
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

# PreferredModules reads use constant as a use of the module constant, so a
# [constant] section is all it takes.  A constant from use constant is a
# bareword that does not interpolate and cannot be searched for by a sigil.
subtest 'the preferred modules prefer Readonly to use constant' => sub {
    my $ini = slurp("$TEMPLATES/preferred_modules.ini");
    my ($section) = $ini =~ m/^\[constant\]\n((?:[^\[\n][^\n]*\n)*)/m;
    ok( defined $section, 'the template has a [constant] section' ) or return;
    like( $section, qr/^prefer\s*=\s*Readonly\s*$/m, 'and it prefers Readonly' );
    like( $section, qr/^reason\s*=/m,                  'and says why' );
};

# Each packaging-perl eval counts the policy sections of the .perlcriticrc that
# Claude wrote, against the profile its floor picks.  A template that gains or
# loses a policy has to move that count too, or the eval fails at release time.
subtest 'the evals count the sections that the templates have' => sub {
    my $count = sub { my @sections = $_[0] =~ m/^\[[^\]\n]+\]$/mg; return scalar @sections };
    foreach my $case ( [ 'packaging-perl-compat', $compat ], [ 'packaging-perl-modern', $modern ] ) {
        my ( $name, $profile ) = @$case;
        my $grader = slurp("$FindBin::Bin/../evals/$name/graders/profile-copied-whole.md");
        my ($expected) = $grader =~ m/^match:\s*"count:(\d+)"$/m;
        is( $expected, $count->($profile), "evals/$name counts the sections of its profile" );
    }
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

    foreach my $file ( map {"$TEMPLATES/$_"} qw{CLAUDE.md perlcriticrc perlcriticrc.compat} ) {
        my $text = slurp($file);
        my @told = $text =~ m/(prereqs\.yaml)(?![^\n]*not an alternative)/g;
        is( scalar @told, 0, "$file tells nobody to write prereqs.yaml" );
    }
};

done_testing();
