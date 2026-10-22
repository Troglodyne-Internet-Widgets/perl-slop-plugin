use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Scratch::Sweep') or BAIL_OUT('Scratch::Sweep does not load');

subtest sweep => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/bogus";
    open( my $fh, '>', $file ) or die "$file: $!";
    print {$fh} "keep me\n";
    close($fh) or die "$file: $!";

    ok( Scratch::Sweep::sweep( $file, dryrun => 1 ), 'dryrun: reports the file as there to remove' );
    ok( -e $file, 'dryrun: leaves the file in place' );

    ok( Scratch::Sweep::sweep($file), 'removes the file' );
    ok( !-e $file, 'the file is gone' );
    ok( !Scratch::Sweep::sweep($file), 'reports nothing to remove the second time' );
};

done_testing();
