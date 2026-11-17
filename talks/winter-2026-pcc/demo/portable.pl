use v5.16;
use strict;
use warnings;
sub triple { return 3 * shift; }
my @values = (3, 7, 14);
for my $value (@values) {
    say triple($value);
}
