#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'IndieRunner' ) || print "Bail out!
";
}

diag( "Testing IndieRunner $IndieRunner::VERSION, Perl $], $^X" );
