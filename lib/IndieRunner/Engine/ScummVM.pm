# Copyright (c) 2022-2024 Thomas Frohwein
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

package IndieRunner::Engine::ScummVM;
use v5.36;
use version 0.77; our $VERSION = version->declare('v0.0.1');

use parent 'IndieRunner::Engine';

use Readonly;

Readonly my $SCUMMVM_BIN	=> '/usr/local/bin/scummvm';
Readonly my $MAX_OUT		=> 64;

my $game;

sub detect_game ( $self ) {
	return $game if $game;	# save cycles if called a second time

	return undef unless -e $SCUMMVM_BIN;

	# output on line 3 is:
	# engine:name		Description
	# if unknown game variant (AGS), maybe on a different (later) line

	my @out = split(/\n/, qx( $SCUMMVM_BIN --detect ), $MAX_OUT);
	return undef unless grep { /^GameID/ } @out;	# no ScummVM game detected

	@out = grep { /^[[:alnum:]]+:([[:alnum:]]+)/ } @out;	# XXX: refine the heuristic more
	$out[0] =~ m/^[[:alnum:]]+:([[:alnum:]]+)/;
	$game = $1;

	return $game;
}

sub get_bin( $self ) { return $SCUMMVM_BIN; }

sub get_args_ref( $self ) {
	my @args = (
		'--path=.',
		$game,
		);
	return \@args;
}

1;
