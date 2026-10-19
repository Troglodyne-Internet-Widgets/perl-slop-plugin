package Scratch::Sweep;

use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

Scratch::Sweep - remove a file, or say that you would

=head1 FUNCTIONS

=head2 sweep( $path, %opts )

Removes the file at C<$path>.  With C<< dryrun => 1 >>, it leaves the file in
place.

Returns true when the file existed, and false when there was nothing to
remove.  Dies when the file exists and cannot be removed.

=cut

sub sweep {
    my ( $path, %opts ) = @_;
    return 0 unless -e $path;
    if ( $opts{dryrun} ) {
        print "Would remove $path\n";
        return 1;
    }
    unlink $path or die "Could not remove $path: $!";
    return 1;
}

1;
