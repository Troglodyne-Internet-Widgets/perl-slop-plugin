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
Each entry of a transcript is stamped a few seconds from now, one second
apart, and each repository's first commit is an hour old, so a load in a
transcript always comes after the commit at HEAD unless a case says otherwise.

=cut

use Test::More;
use File::Temp     qw{tempdir};
use File::Path     qw{make_path};
use File::Basename qw{dirname};
use JSON::PP       ();              ## no critic (PreferredModules) -- the hook it tests is core-only
use POSIX          ();
use FindBin;

# Where the hook records loads, fresh for this run.
$ENV{CLAUDE_PLUGIN_DATA} = tempdir( CLEANUP => 1 );

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

sub stamp { my ($epoch) = @_; return POSIX::strftime( '%Y-%m-%dT%H:%M:%S.000Z', gmtime $epoch ) }

sub transcript {
    my (@entries) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $at  = time + 10;
    open( my $fh, '>', "$dir/t.jsonl" ) or die $!;
    print {$fh} $JSON->encode( { timestamp => stamp( $at++ ), %$_ } ), "\n" for @entries;
    close($fh) or die $!;
    return "$dir/t.jsonl";
}

# --- Repositories -------------------------------------------------------------

sub repo {
    my (%files) = @_;
    my $root = tempdir( CLEANUP => 1 );
    local @ENV{qw{GIT_AUTHOR_DATE GIT_COMMITTER_DATE}} = ( '@' . ( time - 3600 ) . ' +0000' ) x 2;
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

my @READING   = map { "perl-slop:$_" } qw{reading-perl information-security};
my $PROSE     = 'perl-slop:information-security';
my @FINISHING = ( ( map { "perl-slop:$_" } qw{data-perl testing-perl reviewing-perl} ), $PROSE );

# The Skill calls that an edit to Perl needs.
sub reading { return map { skill( "r$_", $READING[$_] ) } 0 .. $#READING }

subtest 'an edit to Perl waits for reading-perl and information-security' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my $file = "$root/lib/Foo.pm";

    my $why = edit( $file, transcript() );
    like( $why, qr/\Q$_\E/, "refused, naming $_, when nothing is loaded" ) for @READING;
    is( edit( $file, transcript( reading() ) ), undef, 'allowed once both are loaded' );
    like( edit( $file, transcript( skill( 's1', 'perl-slop:reading-perl' ) ) ), qr/information-security/, 'one of two is not enough' );
    like( edit( $file, transcript( reading(), compacted() ) ), qr/reading-perl/, 'refused again after a compaction' );

    my @by_name = map { said("Base directory for this skill: /x/skills/$_\n\nI'm using it") } qw{reading-perl information-security};
    is( edit( $file, transcript(@by_name) ), undef, 'a skill that a user loaded by its /name counts' );
    like(
        edit( $file, transcript( said("The following skills were invoked EARLIER in this session\nBase directory for this skill: /x/skills/reading-perl\n") ) ),
        qr/reading-perl/, 'but not the copy in the reminder after a compaction, which can be cut short'
    );

    like( edit( "$root/README.md", transcript() ), qr/information-security/, 'an edit to a file in any language waits for information-security' );
    unlike( edit( "$root/README.md", transcript() ), qr/reading-perl/, 'but not for reading-perl' );
    is( edit( "$root/README.md", transcript( skill( 's1', $PROSE ) ) ), undef, 'and is allowed once it is loaded' );

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

subtest 'a commit of Perl waits for the finishing skills, loaded since the last commit' => sub {
    my $root = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my @all  = map { skill( "s$_", $FINISHING[$_] ) } 0 .. $#FINISHING;

    my $why = run_bash( "cd $root && git add -A && git commit -m x", transcript() );
    like( $why, qr/\Q$_\E/, "refused, naming $_" ) for @FINISHING;

    is( run_bash( "cd $root && git add -A && git commit -m x", transcript(@all) ), undef, 'allowed once all of them are loaded' );
    like( run_bash( "cd $root && git commit -am x", transcript( @all[ 0 .. 2 ] ) ), qr/information-security/, 'all but one is not enough' );

    # A command that commits and then echoes exits 0 whether the commit
    # happened or not, so the transcript cannot say.  HEAD can.
    my $tried = transcript( @all, bash( 'c1', "git -C $root commit -m x; echo exit=\$?" ), result('c1') );
    is( run_bash( "git -C $root commit -m x", $tried ), undef, 'a git commit in the transcript that made no commit does not count, though it exited 0' );

    {
        local @ENV{qw{GIT_AUTHOR_DATE GIT_COMMITTER_DATE}} = ( '@' . ( time + 3600 ) . ' +0000' ) x 2;
        git( $root, 'add', '-A' );
        git( $root, 'commit', '-q', '-m', 'later' );
    }
    write_file( $root, 'lib/Foo.pm', "package Foo;\n2;\n" );
    like( run_bash( "git -C $root commit -am x", $tried ), qr/data-perl/, 'a commit at HEAD after they were loaded means loading them again' );
};

subtest 'a load that the hook recorded counts before the transcript shows it' => sub {
    my $root   = repo( 'lib/Foo.pm' => "package Foo;\n1;\n" );
    my $record = sub {
        my ( $session, @skills ) = @_;
        PerlSlop::SkillGates::decide( { hook_event_name => 'PostToolUse', tool_name => 'Skill', tool_input => { skill => $_ }, session_id => $session } ) for @skills;
        return;
    };
    my $commit = sub { my ( $session, $transcript ) = @_; return run_bash( "cd $root && git commit -am x", $transcript // transcript(), session_id => $session ) };

    $record->( 'sess-a', @FINISHING, @READING );
    is( $commit->('sess-a'), undef, 'a commit is allowed on the record alone, with nothing in the transcript' );
    like( $commit->('sess-b'), qr/data-perl/, 'but only in the session that loaded them' );
    is( edit( "$root/lib/Foo.pm", transcript(), session_id => 'sess-a' ), undef, 'and an edit counts it too' );

    PerlSlop::SkillGates::decide( { hook_event_name => 'SessionStart', source => 'resume', session_id => 'sess-a' } );
    is( $commit->('sess-a'), undef, 'a session that resumes keeps its loads' );
    PerlSlop::SkillGates::decide( { hook_event_name => 'SessionStart', source => 'compact', session_id => 'sess-a' } );
    like( $commit->('sess-a'), qr/data-perl/, 'and a compaction forgets them' );

    $record->( 'sess-c', @FINISHING );
    like( $commit->( 'sess-c', transcript( compacted() ) ), qr/data-perl/, 'a record from before a compaction in the transcript does not count' );

    $record->( '../escape', @FINISHING );
    my @written = glob("$ENV{CLAUDE_PLUGIN_DATA}/*");
    ok( !grep( { m/escape/ } @written ), 'a session ID that is not a plain name writes nothing' );
};

subtest 'what a commit is judged by' => sub {
    my $docs = repo( 'docs/x.md' => "words\n" );
    my $why  = run_bash( "cd $docs && git commit -am x", transcript() );
    like( $why, qr/information-security/, 'a commit with no Perl among the changes waits for information-security, for its message' );
    unlike( $why, qr/data-perl/, 'but not for the Perl skills' );
    is( run_bash( "cd $docs && git commit -am x", transcript( skill( 's1', $PROSE ) ) ), undef, 'and is allowed once it is loaded' );

    my $clean = repo();
    like( run_bash( "cd $clean && git commit --allow-empty -m x", transcript() ), qr/information-security/, 'and so does one with no changes at all' );

    my $untracked = repo( 'lib/New.pm' => "package New;\n1;\n" );
    like( run_bash( "cd $untracked && git add lib/New.pm && git commit -m x", transcript() ), qr/data-perl/, 'a Perl file not added yet counts' );

    is( run_bash( "cd $untracked && git log --grep commit",       transcript() ), undef, 'git log that mentions commit is not a commit' );
    is( run_bash( "cd $untracked && git commit-tree HEAD^{tree}", transcript() ), undef, 'nor is commit-tree' );

    my $heredoc = "cat > /dev/null <<'EOF'\ncd $untracked && git commit -am x\nEOF\n";
    is( run_bash( $heredoc, transcript() ), undef, 'nor a git commit in the body of a heredoc' );
    is( run_bash( "cat <<EOF\ngit commit -m x\nEOF\necho done", transcript() ), undef, 'nor one before a command that follows the heredoc' );
    like( run_bash( "cat <<EOF\nwords\nEOF\ncd $untracked && git commit -m x", transcript() ), qr/data-perl/, 'but a commit after the heredoc ends is' );
    like( run_bash( "cd $untracked && git commit -F - <<'EOF'\nmessage\nEOF", transcript() ), qr/data-perl/, 'and so is a commit that reads its message from a heredoc' );

    # A newline starts a command as much as a semicolon does.  While it did
    # not, every gate read the first line and stopped there, so each of these
    # was allowed -- with or without a heredoc in front of it.
    like( run_bash( "cd $untracked\ngit commit -m x",       transcript() ), qr/data-perl/, 'a commit on the second line is a commit' );
    like( run_bash( "echo hi\ncd $untracked && git commit", transcript() ), qr/data-perl/, 'and so is one after any other command' );

    # And the directory it is judged against is the one it names, wherever the
    # cd is.  Only a cd at the start of the whole command used to count, so a
    # commit after a heredoc was judged against the wrong repository.
    like( run_bash( "cat <<EOF\nwords\nEOF\ncd $untracked\ngit commit -m x", transcript() ), qr/data-perl/, 'a cd after a heredoc still says which repository' );
};

subtest 'a post to an issue or a pull request waits for information-security' => sub {
    my $none   = transcript();
    my $loaded = transcript( skill( 's1', $PROSE ) );

    foreach my $command ( 'gh pr create --title x --body y', 'gh issue comment 12 --body y', 'cd /x && gh pr review 3 --comment -b y', 'gh api repos/o/r/issues/1/comments -f body=y', 'glab mr note 4 -m y' ) {
        like( run_bash( $command, $none ), qr/information-security/, "refused: $command" );
        is( run_bash( $command, $loaded ), undef, "allowed once it is loaded: $command" );
    }
    is( run_bash( 'gh pr view 3',                   $none ), undef, 'gh that only reads is allowed' );
    is( run_bash( 'gh api repos/o/r/issues/1',      $none ), undef, 'and so is gh api that only reads' );
    is( run_bash( "cat <<EOF\ngh pr create\nEOF\n", $none ), undef, 'and gh in the body of a heredoc' );
    like( run_bash( "echo hi\ngh pr create --title x --body y", $none ), qr/information-security/, 'a post on the second line is a post' );
    like( run_bash( qq{gh pr create --body "\$(cat <<'EOF'\nwords\nEOF\n)"}, $none ), qr/information-security/, 'a body from a heredoc is still a post' );

    my $mcp = sub { my ( $tool, $transcript ) = @_; return refused( tool_name => $tool, tool_input => {}, transcript_path => $transcript ) };
    like( $mcp->( 'mcp__github__add_issue_comment',    $none ), qr/information-security/, 'an MCP tool that comments on an issue' );
    like( $mcp->( 'mcp__github__create_pull_request',  $none ), qr/information-security/, 'an MCP tool that opens a pull request' );
    is( $mcp->( 'mcp__github__create_pull_request',    $loaded ), undef, 'allowed once it is loaded' );
    is( $mcp->( 'mcp__github__get_issue',              $none ), undef, 'an MCP tool that only reads is allowed' );
    is( $mcp->( 'mcp__github__list_issue_comments',    $none ), undef, 'and so is one that lists comments' );
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

    my $reading = transcript( reading() );
    like( edit( "$root/lib/Recipe/Foo.pm", $reading ), qr/writing-recipes/, 'a path the config names needs its skill' );
    is( edit( "$root/lib/Other.pm", $reading ), undef, 'a path it does not name does not' );

    write_file( $root, 'templates/x.tt', "[% x %]\n" );
    like( run_bash( "cd $root && git commit -am x", transcript() ), qr/provisioning-recipes/, 'a template change asks for what the config says, Perl or not' );
    is( run_bash( "cd $root && git commit -am x", transcript( skill( 's2', 'provisioning-recipes' ), skill( 's3', $PROSE ) ) ), undef, 'and passes once it is loaded' );
};

subtest 'a prompt gets reminders of information-security, and of profiling-perl when it is about speed' => sub {
    my $root = repo( 'dist.ini' => "name = X\n" );
    my $ask  = sub {
        my ( $prompt, $transcript ) = @_;
        my $out = PerlSlop::SkillGates::decide( { hook_event_name => 'UserPromptSubmit', prompt => $prompt, cwd => $root, transcript_path => $transcript } );
        return $out && $out->{hookSpecificOutput}{additionalContext};
    };

    my $prose = transcript( skill( 's0', $PROSE ) );
    like( $ask->( 'rename this sub', transcript() ), qr/information-security/, 'information-security for any prompt' );
    ok( !$ask->( 'rename this sub', $prose ), 'until it is loaded' );

    like( $ask->( 'why is this so slow?', $prose ), qr/profiling-perl/, 'profiling-perl for a slow thing' );
    ok( !$ask->( 'why is this so slow?', transcript( skill( 's0', $PROSE ), skill( 's1', 'perl-slop:profiling-perl' ) ) ), 'not when the skill is loaded' );
    my $both = $ask->( 'why is this so slow?', transcript() );
    like( $both, qr/information-security.*profiling-perl/s, 'and both at once when neither is loaded' );
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

    my $data = tempdir( CLEANUP => 1 );
    ( $exit, $out ) = $run->( $JSON->encode( { hook_event_name => 'PostToolUse', tool_name => 'Skill', tool_input => { skill => $PROSE }, session_id => 'sess-run' } ), CLAUDE_PLUGIN_DATA => $data );
    is_deeply( [ $exit, $out ], [ 0, q{} ], 'a PostToolUse on Skill prints nothing' );
    ok( -s "$data/loads-sess-run.jsonl", 'and records the load where CLAUDE_PLUGIN_DATA says' );
};

done_testing();
