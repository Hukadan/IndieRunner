package IndieRunner;

# Copyright (c) 2022 Thomas Frohwein
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

use Carp;
use File::Find::Rule;
use File::Share qw( :all );
use File::Spec::Functions qw( catpath splitpath );
use List::Util qw( first );
use POSIX qw( strftime );

use IndieRunner::Cmdline;
use IndieRunner::FNA;
use IndieRunner::Godot;
use IndieRunner::GrandCentral;
use IndieRunner::GZDoom;
use IndieRunner::HashLink;
use IndieRunner::IdentifyFiles qw( find_file_magic );
use IndieRunner::Info qw( goggame_name );
use IndieRunner::Io qw( script_head pty_cmd write_file );
use IndieRunner::Java;
use IndieRunner::Love2D;
use IndieRunner::Mono;
use IndieRunner::MonoGame;
use IndieRunner::Platform qw( init_platform );
use IndieRunner::XNA;

sub new ( $class ) {
	my $self = { };
	%$self = ( %$self, %{ IndieRunner::Cmdline::init_cli() } );
	my ( $engine, $engine_id_file ) = ( detect_engine() );

	$$self{ engine }		= $engine;
	$$self{ engine_id_file }	= $engine_id_file;
	$$self{ engine_module }		= 'IndieRunner::' . $$self{ engine };
	$$self{ game }			= detect_game( $$self{ engine_module } );
	return bless $self, $class;
}

sub detect_engine () {
	my $engine;
	my $engine_id_file;
	my @files = File::Find::Rule->file()->maxdepth( 3 )->in( '.' );

	# 1st Pass: File Names
	foreach my $f ( @files ) {
		# use just basename of file, as different games put those files
		# in different directories
		my $basename = (splitpath( $f ))[2];
		$engine = IndieRunner::GrandCentral::identify_engine($basename);
		if ( $engine ) {
			$engine_id_file = $f;
			last;
		}
	}
	return ( $engine, $engine_id_file || '' ) if $engine;

	# not FNA, XNA, or MonoGame on 1st pass; check if it could still be Mono
	$engine = 'Mono' if IndieRunner::Mono::get_mono_files() or
		IndieRunner::Mono::get_mono_files('_');
	return ( $engine, $engine_id_file || '' ) if $engine;

	# 2nd Pass: Byte Sequences
	say STDERR "Failed to identify game engine on first pass; performing second pass.";
	foreach my $f ( @files ) {
		$engine = IndieRunner::GrandCentral::identify_engine_thorough($f);
		if ( $engine ) {
			$engine_id_file = $f;
			last;
		}
	}
	return ( $engine, $engine_id_file || '' ) if $engine;

	confess "No game engine identified. Aborting.";
}

# heuristic to determine game name
sub detect_game ( $engine_module ) {
	my $game_name;

	# 1. try to identify known game from Status-Tracker.md
	#    (XXX: may need quirks before this)
	my @known_games = split( "\n", IndieRunner::Io::read_file( dist_file( 'IndieRunner', 'Status-Tracker.md' ) ) );
	@known_games = grep { /^[[:blank:]]*\|/ } @known_games;
	@known_games = grep { !/^[[:blank:]]*\|[[:blank:]]*Game[[:blank:]]*\|/ } @known_games;
	@known_games = grep { !/^[[:blank:]]*\|[\-[:blank:]]*\|/ } @known_games;
	foreach ( @known_games ) {
		s/^[[:blank:]]*\|[[:blank:]]*([^\|]+)\|.*/$1/g;
		s/[[:blank:]]*$//g;
	}

	# look for file names matching anything in @known_games
	foreach my $g ( @known_games ) {
		my @tokenized = split( /[^[:alnum:]]+/, $g );
		my $game_glob = '*' . join( '*', @tokenized ) . '*';
		if ( defined ( glob( $game_glob ) ) ) {
			return $g;
			last;
		}
	}


	# 2. use engine-specific heuristic from the engine module
	if ( my $engine_name_heuristic = $engine_module->can( 'detect_game' ) ) {
		say "class $engine_module has method 'detect_game'";
	}
	else {
		say "class $engine_module does NOT have method 'detect_game'";
	}

	# XXX: Godot -> name.pck, GZDoom -> name.ipk3
	# HashLink: deadcells.sh, Northgard
	# Mono*: name.exe

	$game_name = goggame_name();
	($game_name) = find_file_magic( '^ELF.*executable', glob '*' ) unless $game_name;
	($game_name) = find_file_magic( '^PE32 executable \(console\)', glob '*' ) unless $game_name;
	$game_name = 'unknown' unless $game_name;	# bail
	return $game_name;
}

sub setup ( $self, $eobj ) {	# eobj: engine object
	say 'neuter_files: ' . join( ' ', @{ $$eobj{ neuter_files } } )
		if ( @$eobj{ neuter_files } );

	if ( %$eobj{ symlink_files } ) {
		say 'symlink_files:';
		while ( my ( $k, $v ) = each %{ $$eobj{ symlink_files } } ) {
			say "$k => $v";
		}
	}

	if ( %$eobj{ ffmpeg_convert } ) {
		say 'ffmpeg_convert:';
		while ( my ( $k, $v ) = each %{ $$eobj{ ffmpeg_convert } } ) {
			say "$k => $v";
		}
	}

	if ( %$eobj{ extract_archives } ) {
		say 'extract_archives:';
		while ( my ( $k, $v ) = each %{ $$eobj{ extract_archives } } ) {
			say "Extract $k with $v";
		}
	}

	# execute the neuters, symlinks, and ffmpeg_converts, unless
	#	mode is 'dryrun' or 'script'
	#
	# XXX: Extract archives first, then
	#      after extracting archives, need to check for libraries with
	#      IndieRunner::Java::bundled_libraries()
}

=pod

my @run_cmd = $launch_inst->run_cmd();



say "\nLaunching game: $game_name" unless $mode eq 'script';

# print what will be executed; stop here if $dryrun
say join( ' ', @run_cmd );
$mode eq 'run' ? say '' : exit 0;

# Execute @run_cmd and log output
my $cmd_out = pty_cmd( @run_cmd );

# XXX: remove all of $cmd_out managing if we really abandon this; can probably
#      also purge write_file() then and some submodules for strftime, catpath
if ($cmd_out) {
	#say '';

	# store $cmd_out in $tmpdir
	#my $now = strftime "%Y-%m-%d-%H:%M:%S", localtime;
	#my $logfile = catpath( '', $tmpdir, "${game_name}-${now}.log" );
	#say "storing logs in $logfile" if $verbose;
	#write_file( $cmd_out, $logfile );
}

=cut
1;
