#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use re '/aa';

=head1 NAME

t/packaging-conformance.t - the flavors that scaffold a distribution from the
packaging-perl templates

=head1 DESCRIPTION

The skill scaffolds a distribution with C<conformance update>, which reads the
flavors in F<skills/packaging-perl/conformance>.  So this runs Dist::Conformance
on them, in an empty repository, and asserts on what it wrote: every template,
under the name the skill gives it, with every placeholder filled in, and the
hooks installed.

It skips where Dist::Conformance is not installed.

=cut

use Test::More;
use File::Temp qw{tempdir};
use FindBin;

BEGIN {
    eval { require Dist::Conformance; 1 } or plan skip_all => 'Dist::Conformance is not installed';
}

my $ROOT      = "$FindBin::Bin/..";
my $TEMPLATES = "$ROOT/skills/packaging-perl/templates";

my %VARIABLES = (
    DIST             => 'Foo-Bar',
    AUTHOR_NAME      => 'A. Tester',
    AUTHOR_EMAIL     => 'tester@test.test',
    COPYRIGHT_HOLDER => 'Test Co',
    YEAR             => '2026',
    CPAN_ID          => 'TESTER',
    DATE             => '2026-11-03',
);

# Where the scaffold puts each template, whichever flavor it is.
my %WRITES = (
    'dist.ini'              => 'dist.ini',
    'weaver.ini'            => 'weaver.ini',
    'Changes'               => 'Changes',
    'prereqs.yml'           => 'prereqs.yml',
    'LICENSE'               => 'LICENSE',
    'perltidyrc'            => '.perltidyrc',
    'preferred_modules.ini' => '.preferred_modules.ini',
    'pod_stopwords'         => '.pod_stopwords',
    'gitignore'             => '.gitignore',
    'mailmap'               => '.mailmap',
    'pre-commit'            => 'git-hooks/pre-commit',
    'post-commit'           => 'git-hooks/post-commit',
    'tests-covering-map.pl' => '.tests-covering-map.pl',
    'CLAUDE.md'             => 'CLAUDE.md',
    'perl-slop.json'        => '.perl-slop.json',
    'claude-settings.json'  => '.claude/settings.json',
);

my %FLAVOR = (
    'troglodyne-5.040'  => { floor => '5.040', profile => 'perlcriticrc' },
    'troglodyne-compat' => { floor => '5.014', profile => 'perlcriticrc.compat' },
);

sub slurp {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "$path: $!";
    local $/ = undef;
    my $text = <$fh>;
    close($fh);
    return $text;
}

sub spew {
    my ( $path, $text ) = @_;
    open( my $fh, '>', $path ) or die "$path: $!";
    print {$fh} $text;
    close($fh) or die "$path: $!";
    return;
}

# An empty repository whose .conformance.yml names $flavor and %variables, read
# as a distribution reads it, with the standards of this checkout.
sub repository {
    my ( $flavor, %variables ) = @_;
    my $repo = tempdir( CLEANUP => 1 );
    system( qw{git init -q}, $repo ) == 0 or die "git init failed\n";
    spew(
        "$repo/.conformance.yml",
        join "\n",
        "flavor: $flavor",
        'source:',
        '  git: https://github.com/Troglodyne-Internet-Widgets/perl-slop-plugin.git',
        '  path: skills/packaging-perl',
        'variables:',
        ( map {"  $_: '$variables{$_}'"} sort keys %variables ),
        q{}
    );
    return $repo;
}

sub conformance {
    my ($repo) = @_;
    return Dist::Conformance->new( root => $repo, standards => $ROOT, offline => 1 );
}

# The hooks that git would set point a git inside this test at the repository
# being committed to.
my @local = split /\n/, `git rev-parse --local-env-vars`;    ## no critic (ProhibitShellDispatch) -- git is what names them
local @ENV{@local};
delete @ENV{@local};

my %written;
foreach my $flavor ( sort keys %FLAVOR ) {
    subtest "$flavor scaffolds a distribution" => sub {
        my $want = $FLAVOR{$flavor};
        my $repo = repository( $flavor, %VARIABLES );
        my $plan = conformance($repo)->update;

        my @manual = map { @{ $_->{manual} } } @$plan;
        is_deeply( \@manual, [], 'and leaves nothing for a person' ) or diag( explain \@manual );

        my %vars = ( %VARIABLES, PERL_FLOOR => $want->{floor}, VERSION => '0.001' );
        foreach my $template ( sort( keys %WRITES ), $want->{profile} ) {
            my $path = $WRITES{$template} // '.perlcriticrc';
            ( my $expected = slurp("$TEMPLATES/$template") ) =~ s/\{\{(\w+)\}\}/$vars{$1} \/\/ "{{$1}}"/ge;
            ok( -f "$repo/$path", "$path is written" ) or next;
            is( slurp("$repo/$path"), $expected, "$path is $template with its placeholders filled in" );
            $written{$template} = 1;
        }
        like( slurp("$repo/prereqs.yml"), qr/^\s+perl:\s*'\Q$want->{floor}\E'$/m, "prereqs.yml requires perl $want->{floor}" );

        foreach my $hook (qw{pre-commit post-commit}) {
            ok( -x "$repo/git-hooks/$hook", "git-hooks/$hook is executable" );
            is( slurp("$repo/.git/hooks/$hook"), slurp("$repo/git-hooks/$hook"), "and installed in .git/hooks" );
        }

        my @failed = grep { $_->{status} ne 'pass' } @{ conformance($repo)->check };
        is_deeply( \@failed, [], 'conformance check passes the scaffold' ) or diag( explain \@failed );

        my @again = map { @{ $_->{changes} } } @{ conformance($repo)->update };
        is_deeply( \@again, [], 'and a second update changes nothing' ) or diag( explain \@again );
    };
}

subtest 'every template is scaffolded by a flavor' => sub {
    opendir( my $dh, $TEMPLATES ) or die "$TEMPLATES: $!";
    my @templates = sort grep { -f "$TEMPLATES/$_" } readdir $dh;
    closedir $dh;
    is_deeply( [ grep { !$written{$_} } @templates ], [], 'no template is left for a person to copy' );
};

# skill-gates.pl ignores a key that it does not read, so a misspelled gate
# turns the rule off without a word.  The flavor's schema is what catches it.
subtest '.perl-slop.json holds only what the hooks read' => sub {
    my $repo          = repository( 'troglodyne-5.040', %VARIABLES );
    my $config_status = sub {
        my ($json) = @_;
        spew( "$repo/.perl-slop.json", $json );
        my ($result) = grep { $_->{check} eq 'SkillGates' } @{ conformance($repo)->check };
        return $result->{status};
    };

    is( $config_status->('{"before_edit":{"lib/**":["writing-recipes"]},"before_commit":{"templates/**":["provisioning-recipes"]}}'), 'pass', 'the example of the README passes' );
    is( $config_status->('{"before_edit":{"lib/**":"writing-recipes"}}'), 'pass', 'and so does one skill without a list, which the hook also reads' );
    is( $config_status->('{"before_commit":{"docs/**":["simple-english:simple-english"]}}'), 'pass', 'and a skill of another plugin, by its full name' );
    is( $config_status->('{"before_comit":{"lib/**":["x"]}}'),             'fail', 'a misspelled gate fails' );
    is( $config_status->('{"before_edit":["writing-recipes"]}'),           'fail', 'and so does a gate that is not a map of globs' );
    is( $config_status->('{"before_edit":{"lib/**":[{"name":"x"}]}}'),   'fail', 'or a skill that is not a name' );
    is( $config_status->('{"before_edit":'),                               'fail', 'or a file that is not JSON' );
};

# [GithubMeta] takes the account from the origin remote, and user overrides it,
# so the metadata of a repository that moved names the old account.
subtest 'dist.ini lets [GithubMeta] take the account from the remote' => sub {
    my $repo   = repository( 'troglodyne-5.040', %VARIABLES );
    my $result = sub {
        my ($ini) = @_;
        spew( "$repo/dist.ini", $ini );
        my ($result) = grep { $_->{check} eq 'GithubMetaFromRemote' } @{ conformance($repo)->check };
        return $result;
    };

    is( $result->("name = Foo-Bar\n[GithubMeta]\nissues = 1\n")->{status}, 'pass', 'a [GithubMeta] without user passes' );
    my $user = $result->("name = Foo-Bar\n[GithubMeta]\nissues = 1\nuser = someone\n");
    is( $user->{status}, 'fail', 'and one with user fails' );
    like( $user->{detail}, qr{/GithubMeta/user: overrides the account in the URL of the origin remote}, 'and says why' );
    is( $result->("[GithubMeta / Meta]\nuser = someone\n")->{status}, 'fail', 'and so does a [GithubMeta] with a name of its own' );
    is( $result->("[Run::Test]\nrun = a\nrun = b\n")->{status},     'pass', 'a dist.ini without [GithubMeta] passes' );
};

# The gates are only as good as what the hook makes of them, and a gate on a
# skill whose plugin a clone cannot install refuses every edit it covers.
subtest 'the scaffold gates its prose, and can install what the gates ask for' => sub {
    require_ok("$ROOT/hooks/skill-gates.pl");
    my $repo = repository( 'troglodyne-5.040', %VARIABLES );
    conformance($repo)->update;

    foreach my $path (qw{README.md docs/guide.md lib/Foo/Bar.pod Changes}) {
        is_deeply( [ PerlSlop::SkillGates::configured( $repo, 'before_edit', $path ) ], ['simple-english:simple-english'], "an edit of $path needs simple-english" );
    }
    foreach my $path (qw{lib/Foo/Bar.pm t/basic.t dist.ini}) {
        is_deeply( [ PerlSlop::SkillGates::configured( $repo, 'before_edit', $path ) ], [], "an edit of $path does not" );
    }

    my $settings = PerlSlop::SkillGates::read_json( do { open( my $fh, '<', "$repo/.claude/settings.json" ) or die "settings: $!"; $fh } );
    my @enabled  = sort grep { $settings->{enabledPlugins}{$_} } keys %{ $settings->{enabledPlugins} };
    is_deeply( \@enabled, [qw{perl-slop@troglodyne-marketplace simple-english@simple-english}], 'the settings enable perl-slop and simple-english' );
    foreach my $plugin (@enabled) {
        my ($marketplace) = $plugin =~ m/\@(.+)\z/;
        ok( $settings->{extraKnownMarketplaces}{$marketplace}{source}{repo}, "and name the marketplace of $plugin, so a clone can install it" );
    }
};

subtest 'a placeholder that nothing fills stops its file, and says which' => sub {
    my %without = %VARIABLES;
    delete $without{DATE};
    my $repo = repository( 'troglodyne-5.040', %without );
    my $plan = conformance($repo)->update;

    ok( !-e "$repo/Changes", 'Changes is not written with {{DATE}} in it' );
    ok( -e "$repo/dist.ini", 'while the files that do not need it are' );
    my @manual = map { @{ $_->{manual} } } @$plan;
    is( scalar( grep {/DATE/} @manual ), 1, 'and the update names the variable' ) or diag( explain \@manual );
};

done_testing();
