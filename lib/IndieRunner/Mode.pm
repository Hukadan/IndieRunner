package IndieRunner::Mode;

# Copyright (c) 2022-2023 Thomas Frohwein
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use v5.36;
use version 0.77; our $VERSION = version->declare('v0.0.1');

my $verbosity;

sub vsay ( @say_args ) {
	say @say_args if $verbosity > 0;
}

# parent for Mode object constructor
sub new ( $class, %init ) {
	my $self = bless {}, $class;
	%$self = ( %$self, %init );

	# make verbosity available for vsay etc.
	$verbosity = $$self{ verbosity };

	return $self;
}

sub extract ( $self, %files_and_subs ) {
	while ( my ( $k, $v ) = each ( %files_and_subs ) ) {
		vsay "extract file $k with $v";
	}
}

sub remove ( $self, %files ) {
	vsay "remove the following files:";
	foreach my $f ( keys %files ) {
		vsay $f;
	}
	vsay;
}

sub replace ( $self, %target_source ) {
	vsay "Replace files as follows:";
	while ( my ( $k, $v ) = each ( %target_source ) ) {
		vsay "$k with $v";
	}
	vsay;
}

sub convert ( $self, %from_to ) {
	while ( my ( $k, $v ) = each ( %from_to ) ) {
		vsay "convert $k to $v";
	}
}

sub finish ( $self ) {
	# no-op by default
}

sub run ( $self, $game_name, %config ) {
	my @full_command = ( $config{ bin } );
	unshift( @full_command, 'env', @{ $config{ env } } ) if ( @{ $config{ env } } );
	push( @full_command, @{ $config{ args } } ) if ( @{ $config{ args } } );

	vsay "\nLauching $game_name";
	vsay "Executing: " . join( ' ', @full_command ) . "\n";
	return @full_command;
}

1;
