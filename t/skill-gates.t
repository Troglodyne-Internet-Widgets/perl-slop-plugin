#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use re '/aa';

=head1 NAME

t/skill-gates.t - which edits and commits hooks/skill-gates.pl refuses, and what it counts as a loaded skill

=head1 DESCRIPTION

Each case writes a transcript in the shape that Claude Code writes one, and
where a commit is involved, a real git repository in a temporary directory.

=cut

use Test::More;
use File::Temp     qw{tempdir};
use File::Path     qw{make_path};
use File::Basename qw{dirname};
use JSON::PP       ();              ## no critic (PreferredModules) -- the hook it tests is core-only
use FindBin;

require_ok("$FindBin::Bin/../hooks/skill-gates.pl");

my $JSON = JSON::PP->new->canonical;

# --- Transcript lines ---------------------------------------------------------

sub tool_use {
    my ( $id, $name, $input ) = @_;
    return { type => 'assistant', message => { role => 'assistant', content => [ { type => 'tool_use', id => $id, name => $name, input => $input } ] } };
}
sub skill     { my ( $id, $name )    = @_; return tool_use( $id, 'Skill', { skill => $name } ) }
sub bash      { my ( $id, $command ) = @_; return tool_use( $id, 'Bash', { command => $command } ) }
sub result    { my ( $id, $error )   = @_; return { type => 'user', message => { role => 'user', content => [ { type => 'tool_result', tool_use_id => $id, is_error => $error ? JSON::PP::true : JSON::PP::false, content => 'done' } ] } } }
sub said      { my ($text) = @_; return { type => 'user', message => { role => 'user', content => $text } } }
sub compacted { return { type => 'system', subtype => 'compact_boundary', content => 'Conversation compacted' } }

sub transcript {
    my (@entries) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    open( my $fh, '>', "$dir/t.jsonl" ) or die $!;
    print {$fh} $JSON->encode($_), "\n" for @entries;
    close($fh) or die $!;
    return "$dir/t.jsonl";
}

# --- Repositories -------------------------------------------------------------

sub repo {
    my (%files) = @_;
    my $root = tempdir( CLEANUP => 1 );
    git( $root, 'init',   '-q' );
    git( $root, 'config', 'user.email', 'test@test.test' );
    git( $root, 'config', 'user.name',  'Test' );
    write_file( $root, 'README.md', "readme\n" );
    git( $root, 'add', '-A' );
    git( $root, 'commit', '-q', '-m', 'start' );
    write_file( $root, $_, $files{$_} ) for keys %files;
    return $root;
}

sub git {
    my ( $root, @args ) = @_;
    system( 'git', '-C', $root, @args ) == 0 or die "git @args failed";    ## no critic (ProhibitShellDispatch) -- a real repository is what the commit gate reads
    return;
}

sub write_file {
    my ( $root, $name, $content ) = @_;
    make_path( dirname("$root/$name") );
    open( my $fh, '>', "$root/$name" ) or die $!;
    print {$fh} $content;
    close($fh) or die $!;
    return;
}

# --- Asking the hook ----------------------------------------------------------

# The reason the hook gives for refusing, or undef if it allows.
sub refused {
    my (%input) = @_;
    my $out = PerlSlop::SkillGates::decide( { hook_event_name => 'PreToolUse', %input } ) // return;
    return $out->{hookSpecificOutput}{permissionDecisionReason};
}

sub edit {
    my ( $file, $transcript, %more ) = @_;
    return refused( tool_name => 'Edit', tool_input => { file_path => $file }, transcript_path => $transcript, %more );
}

sub run_bash {
    my ( $command, $transcript, %more ) = @_;
    return refused( tool_name => 'Bash', tool_input => { command => $command }, transcript_path => $transcript, tool_use_id => 'current', %more );
}

my @FINISHING = map { "perl-slop:$_" } qw{data-perl testing-perl reviewing-perl};

subtest 'an edit to Perl waits for reading-perl' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my $file = "$root/lib/Foo.pm";

    like( edit( $file, transcript() ), qr/perl-slop:reading-perl/, 'refused, naming the skill, when nothing is loaded' );
    is( edit( $file, transcript( skill( 's1', 'perl-slop:reading-perl' ) ) ), undef, 'allowed once it is loaded' );
    like( edit( $file, transcript( skill( 's1', 'perl-slop:reading-perl' ), compacted() ) ), qr/reading-perl/, 'refused again after a compaction' );

    is( edit( $file, transcript( said("Base directory for this skill: /x/skills/reading-perl\n\nI'm using it") ) ), undef, 'a skill that a user loaded by its /name counts' );
    like(
        edit( $file, transcript( said("The following skills were invoked EARLIER in this session\nBase directory for this skill: /x/skills/reading-perl\n") ) ),
        qr/reading-perl/, 'but not the copy in the reminder after a compaction, which can be cut short'
    );

    is( edit( "$root/README.md", transcript() ), undef, 'an edit to a file that is not Perl is allowed' );

    write_file( $root, 'bin/tool', "#!/usr/bin/env perl\n1;\n" );
    like( edit( "$root/bin/tool", transcript() ), qr/reading-perl/, 'a script is Perl by its shebang' );
    like(
        refused( tool_name => 'Write', tool_input => { file_path => "$root/bin/new", content => "#!/usr/bin/perl\n" }, transcript_path => transcript() ),
        qr/reading-perl/, 'and so is a new file, by the shebang it is written with'
    );
};

subtest 'a Bash command that writes Perl waits for reading-perl too' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my $none = transcript();

    like( run_bash( "sed -i s/a/b/ $root/lib/Foo.pm",                     $none ), qr/reading-perl/, 'sed -i' );
    like( run_bash( "cd $root && python3 - <<'EOF'\np='lib/Foo.pm'\nEOF", $none ), qr/reading-perl/, 'a python edit, resolved against its cd' );
    like( run_bash( "cat > $root/t/new.t <<'EOF'\nEOF",                   $none ), qr/reading-perl/, 'a redirect into a new file' );
    is( run_bash( "perl -c $root/lib/Foo.pm",     $none ), undef, 'perl -c only reads' );
    is( run_bash( "cd $root && prove -l t/",      $none ), undef, 'and so does prove' );
    is( run_bash( "perltidy -b $root/lib/Foo.pm", $none ), undef, 'perltidy changes layout, and is left alone' );
};

subtest 'a commit of Perl waits for the three finishing skills, loaded since the last commit' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my @all  = map { skill( "s$_", $FINISHING[$_] ) } 0 .. $#FINISHING;

    my $why = run_bash( "cd $root && git add -A && git commit -m x", transcript() );
    like( $why, qr/\Q$_\E/, "refused, naming $_" ) for @FINISHING;

    is( run_bash( "cd $root && git add -A && git commit -m x", transcript(@all) ), undef, 'allowed once all three are loaded' );
    like( run_bash( "cd $root && git commit -am x", transcript( @all[ 0, 1 ] ) ), qr/reviewing-perl/, 'two of three is not enough' );

    my $earlier = bash( 'c1', "git commit -m earlier" );
    like( run_bash( "git -C $root commit -m x", transcript( @all, $earlier, result('c1') ) ), qr/data-perl/, 'a commit since they were loaded means loading them again' );
    is( run_bash( "git -C $root commit -m x", transcript( @all, $earlier, result( 'c1', 1 ) ) ), undef, 'but a commit that failed does not' );
    is( run_bash( "git -C $root commit -m x", transcript( @all, bash( 'current', "git -C $root commit -m x" ) ) ), undef, 'and neither does the commit being decided' );
};

subtest 'what a commit is judged by' => sub {
    my $docs = repo( 'docs/x.md' => "words\n" );
    is( run_bash( "cd $docs && git commit -am x", transcript() ), undef, 'a commit with no Perl among the changes is allowed' );

    my $clean = repo();
    is( run_bash( "cd $clean && git commit --allow-empty -m x", transcript() ), undef, 'and so is one with no changes at all' );

    my $untracked = repo( 'lib/New.pm' => "package New;\n1;\n" );
    like( run_bash( "cd $untracked && git add lib/New.pm && git commit -m x", transcript() ), qr/data-perl/, 'a Perl file not added yet counts' );

    is( run_bash( "cd $untracked && git log --grep commit",       transcript() ), undef, 'git log that mentions commit is not a commit' );
    is( run_bash( "cd $untracked && git commit-tree HEAD^{tree}", transcript() ), undef, 'nor is commit-tree' );
};

subtest 'a repository can ask for more skills in .perl-slop.json' => sub {
    my $config = $JSON->encode(
        {
            before_edit   => { 'lib/Recipe/**' => ['writing-recipes'] },
            before_commit => { 'templates/**'  => ['provisioning-recipes'] },
        }
    );
    my $root = repo( '.perl-slop.json' => $config, 'lib/Recipe/Foo.pm' => "package Foo;\n1;\n", 'lib/Other.pm' => "package Other;\n1;\n" );
    git( $root, 'add', '-A' );
    git( $root, 'commit', '-q', '-m', 'config' );

    my $reading = transcript( skill( 's1', 'perl-slop:reading-perl' ) );
    like( edit( "$root/lib/Recipe/Foo.pm", $reading ), qr/writing-recipes/, 'a path the config names needs its skill' );
    is( edit( "$root/lib/Other.pm", $reading ), undef, 'a path it does not name does not' );

    write_file( $root, 'templates/x.tt', "[% x %]\n" );
    like( run_bash( "cd $root && git commit -am x", transcript() ), qr/provisioning-recipes/, 'a template change asks for what the config says, Perl or not' );
    is( run_bash( "cd $root && git commit -am x", transcript( skill( 's2', 'provisioning-recipes' ) ) ), undef, 'and passes once it is loaded' );
};

subtest 'a prompt about speed gets a reminder of profiling-perl' => sub {
    my $root = repo( 'dist.ini' => "name = X\n" );
    my $ask  = sub {
        my ( $prompt, $transcript ) = @_;
        my $out = PerlSlop::SkillGates::decide( { hook_event_name => 'UserPromptSubmit', prompt => $prompt, cwd => $root, transcript_path => $transcript } );
        return $out && $out->{hookSpecificOutput}{additionalContext};
    };

    like( $ask->( 'why is this so slow?', transcript() ), qr/profiling-perl/, 'a slow thing' );
    ok( !$ask->( 'why is this so slow?', transcript( skill( 's1', 'perl-slop:profiling-perl' ) ) ), 'not when the skill is loaded' );
    ok( !$ask->( 'rename this sub',      transcript() ),                                            'not for anything else' );
};

subtest 'the hook as Claude Code runs it' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my $run  = sub {
        my ( $stdin, %env ) = @_;
        local @ENV{ keys %env } = values %env;
        my $dir = tempdir( CLEANUP => 1 );
        open( my $in, '>', "$dir/in" ) or die $!;
        print {$in} $stdin;
        close($in) or die $!;
        my $out = `$^X $FindBin::Bin/../hooks/skill-gates.pl < $dir/in`;    ## no critic (ProhibitShellDispatch) -- run the way Claude Code runs it
        return ( $? >> 8, $out );
    };

    my $input = $JSON->encode( { hook_event_name => 'PreToolUse', tool_name => 'Edit', tool_input => { file_path => "$root/lib/Foo.pm" }, transcript_path => transcript() } );
    my ( $exit, $out ) = $run->($input);
    is( $exit,                                                         0,      'exits 0' );
    is( $JSON->decode($out)->{hookSpecificOutput}{permissionDecision}, 'deny', 'and prints a deny' );

    ( $exit, $out ) = $run->( $input, PERL_SLOP_GATES => '0' );
    is( $out, q{}, 'PERL_SLOP_GATES=0 turns it off' );

    ( $exit, $out ) = $run->('not json');
    is_deeply( [ $exit, $out ], [ 0, q{} ], 'input it cannot read allows, rather than stopping work' );
};

done_testing();
