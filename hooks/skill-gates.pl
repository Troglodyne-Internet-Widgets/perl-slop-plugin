#!/usr/bin/env perl
package PerlSlop::SkillGates;

use 5.014;
use strict;
use warnings;
use re '/aa';

use Cwd            ();
use File::Basename ();
use File::Path     ();
use File::Spec     ();
use JSON::PP       ();    ## no critic (PreferredModules) -- core, so the hook runs on any perl; see $JSON_CLASS
use Time::HiRes    ();
use Time::Local    ();

=head1 NAME

hooks/skill-gates.pl - refuse an edit, a commit or a post until the skills that it needs are loaded

=head1 DESCRIPTION

Claude Code runs this as a hook of the perl-slop plugin, for PreToolUse on
Edit, Write, MultiEdit, NotebookEdit, Bash and MCP tools, and for
UserPromptSubmit.  It reads the hook's JSON on standard input, and prints a
decision as JSON, or nothing to allow.  F<README.md> says what each gate asks for and why.

It also runs for PostToolUse on the Skill tool, to record the load, and for
SessionStart after a compaction, to forget the loads before it.  See
L</record_load(\%input)>.

A skill counts as loaded when the transcript shows a Skill call for it, or
the text of the skill that a user's C</name> loads, or when this hook recorded
the load.  Each counts only after the last compaction.

It uses core modules only, because it runs on whatever perl the machine has.
It exits 0 whatever happens, so a fault in it allows the action rather than
stopping work.  C<PERL_SLOP_GATES=0> in the environment turns it off.

=cut

# edit and commit are for Perl.  prose is for anything written in any
# language, and for anything said to anyone.
our %BASE = (
    edit   => ['perl-slop:reading-perl'],
    commit => [ 'perl-slop:data-perl', 'perl-slop:testing-perl', 'perl-slop:reviewing-perl' ],
    prose  => ['perl-slop:information-security'],
);

our $CONFIG_NAME = '.perl-slop.json';

# The transcript can be tens of megabytes, and JSON::PP is slow on long lines.
# So an XS parser when there is one, and the core one when there is not.
our $JSON_CLASS = ( eval { require Cpanel::JSON::XS; 1 } ? 'Cpanel::JSON::XS' : 'JSON::PP' );

our $PERL_EXT_RX = qr/[.](?:pm|pl|t|psgi)\z/;

# A Bash command that writes a file.  perltidy is left out, because it changes
# layout and not what the code does.
our $WRITES_RX = qr{
    \bsed\s+(?:-\w*\s+)*-\w*i
  | \bperl\s+(?:-\w+\s+)*-\w*i
  | \bpython3?\b
  | \btee\b | \bcp\b | \bmv\b | \binstall\b | \bpatch\b
  | >>?
}x;

# Where a new command can start in a Bash command line.
# A newline starts a command as much as a semicolon does.  Without it here,
# every gate read only the first line of a multi-line command: `echo hi\ngit
# commit -m x` was not a commit, and the same on the far side of a heredoc was
# not either.
our $COMMAND_START_RX = qr/(?:\A|[;&|(\n]|\bthen\b|\bdo\b)\s*/;

# A Bash command that posts to an issue, a pull request, a release or a gist.
our $PUBLISH_RX = qr{
    $COMMAND_START_RX
    (?: gh\s+(?:issue|pr)\s+(?:create|comment|edit|review|close|reopen|merge)
      | gh\s+(?:release|gist)\s+(?:create|edit)
      | glab\s+(?:issue|mr)\s+(?:create|note|update|close|reopen|merge)
    )(?![\w-])
  | $COMMAND_START_RX
    gh\s+api\b [^;&|\n]*? \s (?: -[fF] | --(?:raw-)?field | --input | -X\s*(?:POST|PATCH|PUT) | --method[=\s]+(?:POST|PATCH|PUT) )(?![\w-])
}x;

# An MCP tool that posts to an issue, a pull request, a review or a comment,
# such as mcp__github__add_issue_comment.  Tools that only read are left out.
our $PUBLISH_VERB_RX = qr/create|add|update|edit|post|submit|reply|merge/;
our $PUBLISH_NOUN_RX = qr/issue|pull|merge_request|comment|review|discussion|release|note/;
our $PUBLISH_TOOL_RX = qr/\Amcp__.*(?:$PUBLISH_VERB_RX.*$PUBLISH_NOUN_RX|$PUBLISH_NOUN_RX.*$PUBLISH_VERB_RX)/i;

our $SLOW_RX = qr/\b(?:slow(?:er|ly|ness)?|profil\w*|time[ds]?[ -]?out|timing out|performance|takes? (?:too )?long|faster)\b/i;

our $SKILL_DIR_RX = qr{Base directory for this skill: \S*/([^/\s]+)\s};

exit main() unless caller;

=head1 SUBROUTINES

=head2 main()

Reads the hook's input, prints the decision, and returns 0.

=cut

sub main {
    return 0 if ( $ENV{PERL_SLOP_GATES} // q{} ) eq '0';

    my $input = read_json( \*STDIN );
    return 0 if ref $input ne 'HASH';

    my $out = eval { decide($input) };
    print JSON::PP->new->canonical->encode($out) if $out;
    return 0;
}

=head2 $output = decide(\%input)

Returns what to print for this hook event, or undef to allow it and say
nothing.

=cut

sub decide {
    my ($input) = @_;

    my $event = $input->{hook_event_name} // q{};
    return prompt_reminder($input) if $event eq 'UserPromptSubmit';
    return record_load($input)     if $event eq 'PostToolUse' && ( $input->{tool_name} // q{} ) eq 'Skill';
    return forget_loads($input)    if $event eq 'SessionStart';
    return                         if $event ne 'PreToolUse';

    my $tool = $input->{tool_name}  // q{};
    my $args = $input->{tool_input} // {};

    if ( $tool =~ m/\A(?:Edit|Write|MultiEdit|NotebookEdit)\z/ ) {
        my $file = $args->{file_path} // $args->{notebook_path} // return;
        return edit_gate( $input, [ [ $file, $args->{content} ] ] );
    }

    if ( $tool eq 'Bash' ) {
        my $command = $args->{command} // return;
        my $dir     = command_dir( $command, $input->{cwd} );
        if ( is_commit($command) ) {
            my $out = commit_gate( $input, $dir );
            return $out if $out;
        }
        return publish_gate($input) if is_publish($command);
        my @files = written_perl_files( $command, $dir );
        return edit_gate( $input, [ map { [$_] } @files ] ) if @files;
    }

    return publish_gate($input) if $tool =~ $PUBLISH_TOOL_RX;
    return;
}

=head2 $output = edit_gate(\%input, \@files)

Refuses an edit to any of C<@files> until C<perl-slop:information-security>
is loaded, for a file in any language, and C<perl-slop:reading-perl> too, for
a Perl file, and until the skills that F<.perl-slop.json> names under
C<before_edit> for its path are loaded.  Each item of C<@files> is a path and,
for a Write, the content that it writes.

=cut

sub edit_gate {
    my ( $input, $files ) = @_;

    my ( %needed, @perl );
    $needed{$_} = 1 for @{ $BASE{prose} };
    foreach my $pair (@$files) {
        my ( $file, $content ) = @$pair;
        my $root = checkout_root($file);
        if ( is_perl( $file, $content ) ) {
            $needed{$_} = 1 for @{ $BASE{edit} };
            push @perl, $file;
        }
        $needed{$_} = 1 for configured( $root, 'before_edit', relative( $root, $file ) );
    }

    my $loaded  = session( $input->{transcript_path}, $input->{session_id} )->{loaded};
    my @missing = grep { !defined is_loaded( $loaded, $_ ) } sort keys %needed;
    return if !@missing;

    my @named = @perl ? @perl : map { $_->[0] } @$files;
    return deny( "Load @{[ list(@missing) ]} with the Skill tool before an edit to " . join( ', ', @named ) . ', then make the edit again.  A skill counts once it is loaded after the last compaction.' );
}

=head2 $output = commit_gate(\%input, $dir)

Refuses a commit in the checkout at C<$dir> until the skills it needs are
loaded after the commit at its C<HEAD>.  Those are
C<perl-slop:information-security> for any commit, because every commit has a
message, the three finishing skills when any changed file is Perl, and the
skills that F<.perl-slop.json> names under C<before_commit> for each changed
path.

The last commit is the one at C<HEAD>, by its commit time, and not a
C<git commit> in the transcript.  A command that runs C<git commit> and then
something else exits with the status of the last command, so its result in
the transcript does not say whether the commit happened.  Only a commit that
happened moves C<HEAD>.

=cut

sub commit_gate {
    my ( $input, $dir ) = @_;

    my $root    = checkout_root($dir) // return;
    my @changed = changed_files($root);

    my %needed = map { $_ => 1 } @{ $BASE{prose} };
    if ( grep { is_perl( File::Spec->catfile( $root, $_ ) ) } @changed ) {
        $needed{$_} = 1 for @{ $BASE{commit} };
    }
    $needed{$_} = 1 for map { configured( $root, 'before_commit', $_ ) } @changed;

    my $loaded  = session( $input->{transcript_path}, $input->{session_id} )->{loaded};
    my $since   = head_time($root) // -1;
    my @missing = grep { ( is_loaded( $loaded, $_ ) // -2 ) <= $since } sort keys %needed;
    return if !@missing;

    return deny( "Before this commit, load @{[ list(@missing) ]} with the Skill tool and apply each to the " . 'changes, then commit again.  Each must be loaded after the last commit in this repository, ' . 'and after the last compaction.' );
}

=head2 $output = publish_gate(\%input)

Refuses a post to an issue, a pull request, a review, a release or a gist
until C<perl-slop:information-security> is loaded.

=cut

sub publish_gate {
    my ($input) = @_;

    my $loaded  = session( $input->{transcript_path}, $input->{session_id} )->{loaded};
    my @missing = grep { !defined is_loaded( $loaded, $_ ) } @{ $BASE{prose} };
    return if !@missing;

    return deny( "Load @{[ list(@missing) ]} with the Skill tool before a post to an issue, a pull request, " . 'a review, a release or a gist, then post again.  A skill counts once it is loaded after the last compaction.' );
}

=head2 $output = prompt_reminder(\%input)

Adds a reminder of C<perl-slop:information-security> to every prompt until
it is loaded, because a reply to the user is prose too.  Adds a reminder of
C<perl-slop:profiling-perl> to a prompt about speed, in a Perl project, when
that skill is not loaded.

=cut

sub prompt_reminder {
    my ($input) = @_;

    my $loaded = session( $input->{transcript_path}, $input->{session_id} )->{loaded};
    my @context;
    if ( my @missing = grep { !defined is_loaded( $loaded, $_ ) } @{ $BASE{prose} } ) {
        push @context, "Load @{[ list(@missing) ]} before you reply, and before you write any code, comment, " . 'commit message, issue or pull request.';
    }
    if ( is_about_speed( $input->{prompt}, $input->{cwd} ) && !defined is_loaded( $loaded, 'perl-slop:profiling-perl' ) ) {
        push @context, 'This is about speed.  Load perl-slop:profiling-perl before concluding ' . 'anything, and measure before and after a change.';
    }
    return if !@context;

    return {
        hookSpecificOutput => {
            hookEventName     => 'UserPromptSubmit',
            additionalContext => join( '  ', @context ),
        },
    };
}

=head2 $bool = is_about_speed($prompt, $cwd)

Whether C<$prompt> is about speed, and C<$cwd> is in a Perl project.

=cut

sub is_about_speed {
    my ( $prompt, $cwd ) = @_;
    return if ( $prompt // q{} ) !~ $SLOW_RX;
    my $root = checkout_root( $cwd // q{.} ) // return;
    return looks_like_perl_project($root);
}

=head2 $output = deny($reason)

The PreToolUse output that refuses the call.  Claude Code gives C<$reason> to
the model.

=cut

sub deny {
    my ($reason) = @_;
    return {
        hookSpecificOutput => {
            hookEventName            => 'PreToolUse',
            permissionDecision       => 'deny',
            permissionDecisionReason => $reason,
        },
    };
}

=head2 $text = list(@names)

The names joined for a sentence: C<a>, C<a and b>, C<a, b and c>.

=cut

sub list {
    my (@names) = @_;
    return $names[0] if @names == 1;
    return join( ', ', @names[ 0 .. $#names - 1 ] ) . " and $names[-1]";
}

=head2 $line = is_loaded(\%loaded, $name)

The time, in epoch seconds, when C<$name> was last loaded, or undef.  A name
with a plugin prefix is also satisfied by the bare name, which is how the text
of a skill names its own directory.

=cut

sub is_loaded {
    my ( $loaded, $name ) = @_;
    my ($bare) = $name =~ m/([^:]+)\z/;
    my @at     = grep { defined } $loaded->{$name}, $loaded->{$bare};
    return if !@at;
    my ($last) = sort { $b <=> $a } @at;
    return $last;
}

=head2 \%state = session($transcript_path, $session_id)

What is known since the last compaction: C<loaded>, each skill by the time
when it was last loaded, in epoch seconds.  It reads the transcript, and adds
the loads that C<record_load> wrote for C<$session_id>.

The transcript alone is not enough.  Claude Code writes it some time after the
fact, so the Skill calls since the last Bash call are often not in it when the
next hook runs.  A load that only the transcript can show is then missed, and
the gate refuses a commit whose skills were loaded a moment before.

=cut

sub session {
    my ( $path, $session_id ) = @_;

    my %state = ( loaded => {} );
    my $since = transcript_loads( \%state, $path );
    recorded_loads( \%state, $session_id, $since );
    return \%state;
}

=head2 $since = transcript_loads(\%state, $transcript_path)

Adds to C<$state{loaded}> each load that the transcript shows after its last
compaction.  Returns the time of that compaction, or 0 when there is none.

=cut

sub transcript_loads {
    my ( $state, $path ) = @_;

    return 0 if !defined $path;
    open( my $fh, '<', $path ) or return 0;
    my $since = seek_past_compaction($fh);

    my $json = $JSON_CLASS->new;
    while ( my $line = <$fh> ) {
        next if !worth_decoding($line);
        my $entry   = eval { $json->decode($line) } or next;
        my $content = ref $entry->{message} eq 'HASH' ? $entry->{message}{content} : undef;
        my $at      = entry_time($entry);

        if ( defined $content && !ref $content ) {
            note_skill_text( $state, $content, $at );
        }
        elsif ( ref $content eq 'ARRAY' ) {
            note_block( $state, $_, $at ) for grep { ref eq 'HASH' } @$content;
        }
    }
    close($fh);
    return $since;
}

=head2 $since = seek_past_compaction($fh)

Moves C<$fh> to the line after the last compaction, and returns the time of
that compaction.  With no compaction, it leaves C<$fh> at the start and
returns 0.  Nothing before a compaction counts, so it is not decoded.

=cut

sub seek_past_compaction {
    my ($fh) = @_;
    my ( $start, $boundary ) = ( 0, undef );
    while ( my $line = <$fh> ) {
        ( $start, $boundary ) = ( tell($fh), $line ) if index( $line, '"compact_boundary"' ) >= 0;
    }
    seek( $fh, $start, 0 ) or return 0;
    return 0 if !defined $boundary;
    return entry_time( eval { $JSON_CLASS->new->decode($boundary) } // {} );
}

=head2 $seconds = entry_time(\%entry)

The C<timestamp> of a transcript entry in epoch seconds, or 0 when it has none
that this can read.

=cut

sub entry_time {
    my ($entry) = @_;
    my ( $y, $mo, $d, $h, $mi, $s, $frac ) = ( $entry->{timestamp} // q{} ) =~ m/\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)([.]\d+)?Z\z/
      or return 0;
    return Time::Local::timegm( $s, $mi, $h, $d, $mo - 1, $y ) + ( $frac // 0 );
}

=head2 $bool = worth_decoding($line)

Whether C<$line> can hold a load, by the strings in it.  Decoding every line
of a long transcript is what makes a scan slow.

=cut

sub worth_decoding {
    my ($line) = @_;
    return 1 if index( $line, '"name":"Skill"' ) >= 0;
    return 1 if index( $line, 'Base directory for this skill:' ) >= 0 && index( $line, 'invoked EARLIER' ) < 0;
    return 0;
}

=head2 note_block(\%state, \%block, $at)

Records a load that one block of a message shows, at the time C<$at>: a Skill
call, or the text of a skill that a user loaded.

=cut

sub note_block {
    my ( $state, $block, $at ) = @_;

    my $type  = $block->{type} // q{};
    my $name  = $block->{name} // q{};
    my $input = ref $block->{input} eq 'HASH' ? $block->{input} : {};

    if ( $type eq 'tool_use' && $name eq 'Skill' && defined $input->{skill} ) {
        note_load( $state, $input->{skill}, $at );
    }
    elsif ( $type eq 'text' ) {
        note_skill_text( $state, $block->{text}, $at );
    }
    return;
}

=head2 note_skill_text(\%state, $text, $at)

Records each skill whose text C<$text> carries.  The reminder that follows a
compaction also carries skill texts, cut short, and does not count.

=cut

sub note_skill_text {
    my ( $state, $text, $at ) = @_;
    return if !defined $text || index( $text, 'invoked EARLIER' ) >= 0;
    note_load( $state, $1, $at ) while $text =~ m/$SKILL_DIR_RX/g;
    return;
}

=head2 note_load(\%state, $name, $at)

Records that C<$name> was loaded at C<$at>, unless a later load of it is
already recorded.

=cut

sub note_load {
    my ( $state, $name, $at ) = @_;
    my $known = $state->{loaded}{$name};
    $state->{loaded}{$name} = $at if !defined $known || $at > $known;
    return;
}

=head2 record_load(\%input)

For PostToolUse on the Skill tool.  Appends the skill and the time to the file
of loads for the session, which C<recorded_loads> reads.  Returns undef, so
the hook prints nothing.

The hook runs just after the load, so the record is there for the next call.
The transcript can take longer.  See C<session>.

=cut

sub record_load {
    my ($input) = @_;

    my $skill = ref $input->{tool_input} eq 'HASH' ? $input->{tool_input}{skill} : undef;
    my $file  = loads_file( $input->{session_id} );
    return if !defined $skill || !defined $file;

    File::Path::make_path( File::Basename::dirname($file) );
    open( my $fh, '>>', $file ) or return;
    print {$fh} JSON::PP->new->canonical->encode( { skill => $skill, at => Time::HiRes::time() } ), "\n";
    close($fh);
    return;
}

=head2 forget_loads(\%input)

For SessionStart.  After a compaction, removes the file of loads for the
session, because a compaction takes the skills out of the context.  Returns
undef.

=cut

sub forget_loads {
    my ($input) = @_;
    return if ( $input->{source} // q{} ) ne 'compact';
    my $file = loads_file( $input->{session_id} ) // return;
    unlink $file;
    return;
}

=head2 recorded_loads(\%state, $session_id, $since)

Adds to C<$state{loaded}> each load that C<record_load> wrote for
C<$session_id> after the time C<$since>.  The time is a second guard after
C<forget_loads>, for a compaction that happened while the hook was not
installed.

=cut

sub recorded_loads {
    my ( $state, $session_id, $since ) = @_;

    my $file = loads_file($session_id) // return;
    open( my $fh, '<', $file ) or return;
    while ( my $line = <$fh> ) {
        my $load = eval { JSON::PP->new->decode($line) } or next;
        next if ref $load ne 'HASH' || !defined $load->{skill} || ( $load->{at} // 0 ) <= $since;
        note_load( $state, $load->{skill}, $load->{at} );
    }
    close($fh);
    return;
}

=head2 $file = loads_file($session_id)

The file of loads for C<$session_id>, in C<CLAUDE_PLUGIN_DATA>, or in a
F<perl-slop> directory in the temporary directory when that is not set.
Undef for a session ID that is not letters, digits, C<_> and C<->, because it
becomes part of a path.

=cut

sub loads_file {
    my ($session_id) = @_;
    return if !defined $session_id || $session_id !~ m/\A[\w-]+\z/;
    my $dir = $ENV{CLAUDE_PLUGIN_DATA} || File::Spec->catdir( File::Spec->tmpdir, 'perl-slop' );
    return File::Spec->catfile( $dir, "loads-$session_id.jsonl" );
}

=head2 $seconds = head_time($root)

The commit time of C<HEAD> in the checkout at C<$root>, in epoch seconds, or
undef when it has no commit or there is no C<git> on the C<PATH>.

=cut

sub head_time {
    my ($root) = @_;
    open( my $git, '-|', 'git', '-C', $root, 'log', '-1', '--format=%ct', 'HEAD' ) or return;
    my $time = <$git>;
    close($git);
    return defined $time && $time =~ m/\A(\d+)/ ? $1 : undef;
}

=head2 $bool = is_commit($command)

Whether a Bash command runs C<git commit>, at its start or after a separator.
C<git commit-tree>, a C<git log> that mentions a commit, and a C<git commit>
in the body of a heredoc, are not.

=cut

sub is_commit {
    my ($command) = @_;
    return without_heredocs($command) =~ m/${COMMAND_START_RX}git\s+(?:-\S+\s+\S+\s+)*commit(?![\w-])/;
}

=head2 $bool = is_publish($command)

Whether a Bash command posts to an issue, a pull request, a release or a gist
with C<gh> or C<glab>.  Text in the body of a heredoc does not count.

=cut

sub is_publish {
    my ($command) = @_;
    return without_heredocs($command) =~ $PUBLISH_RX;
}

=head2 $command = without_heredocs($command)

C<$command> with the body of each heredoc taken out.  The line that starts a
heredoc stays, and so does its terminator line.  A body is data that goes to
a command, and not a command that the shell runs.

=cut

sub without_heredocs {
    my ($command) = @_;

    my ( @kept, @ends );
    foreach my $line ( split m/(?<=\n)/, $command ) {
        if (@ends) {
            next if $line !~ m/\A\s*\Q$ends[0]\E\s*\z/;
            shift @ends;
        }
        push @kept, $line;

        # <<< is a here string, and << between numbers is a shift.
        push @ends, $2 while $line =~ m/(?<!<)<<(?!<)-?\s*(['"]?)([A-Za-z_][\w.-]*)\1/g;
    }
    return join q{}, @kept;
}

=head2 $dir = command_dir($command, $cwd)

The directory that a command runs its git in: the one after C<git -C>, or the
last C<cd> that starts a command, or C<$cwd>.

The last rather than the first, because C<cd a && cd b> ends up in b.  Any
command start rather than the start of the whole string, because a C<cd> on the
second line is as real as one on the first -- and while only the first was
matched, a commit after a heredoc was judged against whatever directory the
shell happened to be in rather than the repository it names.

A C<cd> in the body of a heredoc is data, so it is taken out first.

=cut

sub command_dir {
    my ( $command, $cwd ) = @_;
    $cwd //= Cwd::getcwd();

    my $said = without_heredocs($command);

    my ($dir) = $said =~ m/\bgit\s+-C\s+("[^"]+"|'[^']+'|\S+)/;
    if ( !defined $dir ) {
        while ( $said =~ m/${COMMAND_START_RX}cd\s+("[^"]+"|'[^']+'|\S+)/g ) { $dir = $1 }
    }
    return $cwd if !defined $dir;
    $dir =~ s/\A(["'])(.*)\1\z/$2/;
    $dir =~ s{\A~(?=/|\z)}{$ENV{HOME} // q{~}}e;
    return File::Spec->file_name_is_absolute($dir) ? $dir : File::Spec->catdir( $cwd, $dir );
}

=head2 @files = written_perl_files($command, $dir)

The Perl files that a Bash command names, when it writes anything at all,
relative to C<$dir>.

=cut

sub written_perl_files {
    my ( $command, $dir ) = @_;
    return if $command !~ $WRITES_RX;

    my %seen;
    my @files = grep { !$seen{$_}++ } $command =~ m{((?:[\w.~/-]+/)?[\w.-]+[.](?:pm|pl|t|psgi))\b}g;
    return map { File::Spec->file_name_is_absolute($_) ? $_ : File::Spec->catfile( $dir, $_ ) } @files;
}

=head2 $bool = is_perl($file, $content)

Whether C<$file> is Perl: by its extension, or by a C<perl> shebang in
C<$content> or in the file on disk.

=cut

sub is_perl {
    my ( $file, $content ) = @_;
    return 1 if $file =~ $PERL_EXT_RX;

    my $first;
    if ( defined $content ) {
        ($first) = $content =~ m/\A([^\n]*)/;
    }
    elsif ( open( my $fh, '<', $file ) ) {
        $first = <$fh>;
        close($fh);
    }
    return defined $first && $first =~ m/\A#!.*\bperl\b/;
}

=head2 $root = checkout_root($path)

The nearest directory at or above C<$path> with a F<.git> in it, which a
worktree has as a file, or undef.  C<$path> is a file, or a directory to start
from.

=cut

sub checkout_root {
    my ($path) = @_;
    my $dir = File::Spec->rel2abs($path);
    $dir = File::Basename::dirname($dir) if !-d $dir;
    while (1) {
        return $dir if -e File::Spec->catfile( $dir, '.git' );
        my $up = File::Basename::dirname($dir);
        return if $up eq $dir;
        $dir = $up;
    }
}

=head2 $relative = relative($root, $file)

C<$file> relative to C<$root>, or C<$file> as it is when there is no root.

=cut

sub relative {
    my ( $root, $file ) = @_;
    return defined $root ? File::Spec->abs2rel( File::Spec->rel2abs($file), $root ) : $file;
}

=head2 @paths = changed_files($root)

Every file that differs from HEAD, staged or not, and every untracked file.
All of them, and not only what is staged, because a command that adds and
commits has not added anything yet when this runs.

It asks C<git status>, because no core module reads a git index.  Without
C<git> on the C<PATH> it returns nothing, and the commit gate allows the
commit.

=cut

sub changed_files {
    my ($root) = @_;
    open( my $git, '-|', 'git', '-C', $root, 'status', '--porcelain', '--untracked-files=all' ) or return;
    my @files = map { m/\A..\s(?:.*\s->\s)?(.+)\z/ ? $1 : () } map { s/\s+\z//r } <$git>;
    close($git);
    return map { s/\A"(.*)"\z/$1/r } @files;
}

=head2 @skills = configured($root, $gate, $path)

The skills that F<.perl-slop.json> at C<$root> names under C<$gate> for the
globs that C<$path> matches.

=cut

sub configured {
    my ( $root, $gate, $path ) = @_;
    return if !defined $root || !defined $path;

    my $file = File::Spec->catfile( $root, $CONFIG_NAME );
    open( my $fh, '<', $file ) or return;
    my $config = read_json($fh);
    close($fh);
    return if ref $config ne 'HASH' || ref $config->{$gate} ne 'HASH';

    my @skills;
    foreach my $glob ( sort keys %{ $config->{$gate} } ) {
        my $names = $config->{$gate}{$glob};
        push @skills, ref $names eq 'ARRAY' ? @$names : $names if $path =~ glob_rx($glob);
    }
    return @skills;
}

=head2 $data = read_json($fh)

The JSON that the rest of C<$fh> holds, or undef if it is not JSON.

=cut

sub read_json {
    my ($fh) = @_;
    return eval {
        JSON::PP->new->decode( do { local $/ = undef; <$fh> } );
    };
}

=head2 $rx = glob_rx($glob)

A pattern for a path glob: C<**> is any path, C<*> is any name, and C<?> is
one character of a name.

=cut

sub glob_rx {
    my ($glob) = @_;
    my $rx     = join q{}, map { $_ eq '**' ? '.*' : $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta } split m/(\*\*|\*|\?)/, $glob;
    return qr/\A$rx\z/;
}

=head2 $bool = looks_like_perl_project($root)

Whether C<$root> has the files of a Perl distribution, or a F<lib/>.

=cut

sub looks_like_perl_project {
    my ($root) = @_;
    return 1 if grep { -e File::Spec->catfile( $root, $_ ) } qw{dist.ini Makefile.PL Build.PL cpanfile META.json};
    return -d File::Spec->catdir( $root, 'lib' );
}

1;
