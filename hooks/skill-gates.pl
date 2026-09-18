#!/usr/bin/env perl
package PerlSlop::SkillGates;

use 5.014;
use strict;
use warnings;
use re '/aa';

use Cwd            ();
use File::Basename ();
use File::Spec     ();
use JSON::PP       ();    ## no critic (PreferredModules) -- core, so the hook runs on any perl; see $JSON_CLASS

=head1 NAME

hooks/skill-gates.pl - refuse an edit or a commit of Perl until the skills that it needs are loaded

=head1 DESCRIPTION

Claude Code runs this as a hook of the perl-slop plugin, for PreToolUse on
Edit, Write, MultiEdit, NotebookEdit and Bash, and for UserPromptSubmit.  It
reads the hook's JSON on standard input, and prints a decision as JSON, or
nothing to allow.  F<README.md> says what each gate asks for and why.

A skill counts as loaded when the transcript shows a Skill call for it, or
the text of the skill that a user's C</name> loads, after the last compaction.

It uses core modules only, because it runs on whatever perl the machine has.
It exits 0 whatever happens, so a fault in it allows the action rather than
stopping work.  C<PERL_SLOP_GATES=0> in the environment turns it off.

=cut

our %BASE = (
    edit   => ['perl-slop:reading-perl'],
    commit => [ 'perl-slop:data-perl', 'perl-slop:testing-perl', 'perl-slop:reviewing-perl' ],
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
        return commit_gate( $input, $dir ) if is_commit($command);
        my @files = written_perl_files( $command, $dir );
        return edit_gate( $input, [ map { [$_] } @files ] ) if @files;
    }
    return;
}

=head2 $output = edit_gate(\%input, \@files)

Refuses an edit to any of C<@files> until C<perl-slop:reading-perl> is loaded,
for a Perl file, and until the skills that F<.perl-slop.json> names under
C<before_edit> for its path are loaded.  Each item of C<@files> is a path and,
for a Write, the content that it writes.

=cut

sub edit_gate {
    my ( $input, $files ) = @_;

    my ( %needed, @perl );
    foreach my $pair (@$files) {
        my ( $file, $content ) = @$pair;
        my $root = checkout_root($file);
        if ( is_perl( $file, $content ) ) {
            $needed{$_} = 1 for @{ $BASE{edit} };
            push @perl, $file;
        }
        $needed{$_} = 1 for configured( $root, 'before_edit', relative( $root, $file ) );
    }
    return if !%needed;

    my $loaded  = session( $input->{transcript_path}, $input->{tool_use_id} )->{loaded};
    my @missing = grep { !is_loaded( $loaded, $_ ) } sort keys %needed;
    return if !@missing;

    my @named = @perl ? @perl : map { $_->[0] } @$files;
    return deny( "Load @{[ list(@missing) ]} with the Skill tool before an edit to " . join( ', ', @named ) . ', then make the edit again.  A skill counts once it is loaded after the last compaction.' );
}

=head2 $output = commit_gate(\%input, $dir)

Refuses a commit in the checkout at C<$dir> until the skills it needs are
loaded after the last commit in the session.  Those are the three finishing
skills when any changed file is Perl, and the skills that F<.perl-slop.json>
names under C<before_commit> for each changed path.

=cut

sub commit_gate {
    my ( $input, $dir ) = @_;

    my $root    = checkout_root($dir) // return;
    my @changed = changed_files($root);
    return if !@changed;

    my %needed;
    if ( grep { is_perl( File::Spec->catfile( $root, $_ ) ) } @changed ) {
        $needed{$_} = 1 for @{ $BASE{commit} };
    }
    $needed{$_} = 1 for map { configured( $root, 'before_commit', $_ ) } @changed;
    return if !%needed;

    my $session = session( $input->{transcript_path}, $input->{tool_use_id} );
    my $since   = $session->{last_commit} // 0;
    my @missing = grep { ( is_loaded( $session->{loaded}, $_ ) // -1 ) <= $since } sort keys %needed;
    return if !@missing;

    return deny( "Before this commit, load @{[ list(@missing) ]} with the Skill tool and apply each to the " . 'changes, then commit again.  Each must be loaded after the last commit in this session, ' . 'and after the last compaction.' );
}

=head2 $output = prompt_reminder(\%input)

Adds a reminder of C<perl-slop:profiling-perl> to a prompt about speed, in a
Perl project, when that skill is not loaded.

=cut

sub prompt_reminder {
    my ($input) = @_;

    return if ( $input->{prompt} // q{} ) !~ $SLOW_RX;
    my $root = checkout_root( $input->{cwd} // q{.} ) // return;
    return if !looks_like_perl_project($root);
    return if is_loaded( session( $input->{transcript_path} )->{loaded}, 'perl-slop:profiling-perl' );

    return {
        hookSpecificOutput => {
            hookEventName     => 'UserPromptSubmit',
            additionalContext => 'This is about speed.  Load perl-slop:profiling-perl before concluding ' . 'anything, and measure before and after a change.',
        },
    };
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

The line of the transcript where C<$name> was last loaded, or undef.  A name
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

=head2 \%state = session($transcript_path, $current)

What the transcript says since its last compaction: C<loaded>, each skill by
the line where it was last loaded, and C<last_commit>, the line of the last
commit that succeeded.  C<$current> is the C<tool_use_id> of the call being
decided.  That call is already in the transcript, and it is not a commit that
happened.

=cut

sub session {
    my ( $path, $current ) = @_;

    my %state = ( loaded => {}, last_commit => undef, commit_at => {}, current => $current );
    return \%state if !defined $path;
    open( my $fh, '<', $path ) or return \%state;
    seek_past_compaction($fh)  or return \%state;

    my $json = $JSON_CLASS->new;
    while ( my $line = <$fh> ) {
        next if !worth_decoding( $line, \%state );
        my $entry   = eval { $json->decode($line) } or next;
        my $content = ref $entry->{message} eq 'HASH' ? $entry->{message}{content} : undef;

        if ( defined $content && !ref $content ) {
            note_skill_text( \%state, $content, $. );
        }
        elsif ( ref $content eq 'ARRAY' ) {
            note_block( \%state, $_, $. ) for grep { ref eq 'HASH' } @$content;
        }
    }
    close($fh);
    delete @state{qw{commit_at current}};
    return \%state;
}

=head2 $ok = seek_past_compaction($fh)

Moves C<$fh> to the line after the last compaction, or leaves it at the start
when there is none.  C<$.> goes on counting from the top of the file.  Nothing
before a compaction counts, so it is not decoded.

=cut

sub seek_past_compaction {
    my ($fh) = @_;
    my ( $start, $start_line ) = ( 0, 0 );
    while ( my $line = <$fh> ) {
        ( $start, $start_line ) = ( tell($fh), $. ) if index( $line, '"compact_boundary"' ) >= 0;
    }
    seek( $fh, $start, 0 ) or return;
    $. = $start_line;    ## no critic (RequireLocalizedPunctuationVars) -- the line count of our own handle
    return 1;
}

=head2 $bool = worth_decoding($line, \%state)

Whether C<$line> can hold something that C<session> records, by the strings
in it.  Decoding every line of a long transcript is what makes a scan slow.

=cut

sub worth_decoding {
    my ( $line, $state ) = @_;
    return 1 if index( $line, '"name":"Skill"' ) >= 0;
    return 1 if index( $line, '"name":"Bash"' ) >= 0                  && index( $line, 'commit' ) >= 0;
    return 1 if index( $line, 'Base directory for this skill:' ) >= 0 && index( $line, 'invoked EARLIER' ) < 0;
    return 1 if index( $line, '"tool_result"' ) >= 0 && grep { index( $line, $_ ) >= 0 } keys %{ $state->{commit_at} };
    return 0;
}

=head2 note_block(\%state, \%block, $line)

Records what one block of a message says: a Skill call, a commit, the result
of a commit, or the text of a skill that a user loaded.

=cut

sub note_block {
    my ( $state, $block, $line ) = @_;

    my $type  = $block->{type} // q{};
    my $name  = $block->{name} // q{};
    my $input = ref $block->{input} eq 'HASH' ? $block->{input} : {};

    if ( $type eq 'tool_use' && $name eq 'Skill' && defined $input->{skill} ) {
        $state->{loaded}{ $input->{skill} } = $line;
    }
    elsif ( $type eq 'tool_use' && $name eq 'Bash' && defined $block->{id} ) {
        my $current = $state->{current};
        my $this    = defined $current && $block->{id} eq $current;
        $state->{commit_at}{ $block->{id} } = $line if !$this && is_commit( $input->{command} // q{} );
    }
    elsif ( $type eq 'tool_result' && defined $block->{tool_use_id} && exists $state->{commit_at}{ $block->{tool_use_id} } ) {
        my $at = delete $state->{commit_at}{ $block->{tool_use_id} };
        $state->{last_commit} = $at if !$block->{is_error};
    }
    elsif ( $type eq 'text' ) {
        note_skill_text( $state, $block->{text}, $line );
    }
    return;
}

=head2 note_skill_text(\%state, $text, $line)

Records each skill whose text C<$text> carries.  The reminder that follows a
compaction also carries skill texts, cut short, and does not count.

=cut

sub note_skill_text {
    my ( $state, $text, $line ) = @_;
    return if !defined $text || index( $text, 'invoked EARLIER' ) >= 0;
    $state->{loaded}{$1} = $line while $text =~ m/$SKILL_DIR_RX/g;
    return;
}

=head2 $bool = is_commit($command)

Whether a Bash command runs C<git commit>, at its start or after a separator.
C<git commit-tree>, and a C<git log> that mentions a commit, are not.

=cut

sub is_commit {
    my ($command) = @_;
    return $command =~ m/(?:\A|[;&|(]|\bthen\b|\bdo\b)\s*git\s+(?:-\S+\s+\S+\s+)*commit(?![\w-])/;
}

=head2 $dir = command_dir($command, $cwd)

The directory that a command runs its git in: the one after C<git -C>, or a
leading C<cd>, or C<$cwd>.

=cut

sub command_dir {
    my ( $command, $cwd ) = @_;
    $cwd //= Cwd::getcwd();
    my ($dir) = $command =~ m/\bgit\s+-C\s+("[^"]+"|'[^']+'|\S+)/;
    ($dir) = $command =~ m/\A\s*cd\s+("[^"]+"|'[^']+'|\S+)/ if !defined $dir;
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
