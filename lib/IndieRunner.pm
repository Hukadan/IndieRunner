package IndieRunner;

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
use English;

use Carp;
use File::Find::Rule;
use File::Share qw( :all );
use File::Spec::Functions qw( splitpath );
use Readonly;

use IndieRunner::Game;
use IndieRunner::GrandCentral;
use IndieRunner::IdentifyFiles;
use IndieRunner::Info;
use IndieRunner::Io;
use IndieRunner::Platform;

# keep this in sync with return of IndieRunner::Cmdline::init_cli()
Readonly::Hash my %INIT_ATTRIBUTES_DEFAULTS => {
	dllmap		=> '',
	dryrun		=> undef,
	engine		=> undef,
	file		=> '',
	game		=> '',
	game_args	=> undef,
	script		=> undef,
	verbosity	=> 0,
};

sub new ( $class, %init ) {
	my $self = {};

	my $engine;
	my $engine_id_file;

	# set attributes from %init or default
	while ( my ( $k, $v ) = each ( %INIT_ATTRIBUTES_DEFAULTS ) ) {
		$$self{ $k } = $init{ $k } || $v;
	}

	# determine and set mode (Run, Dryrun, or Script)
	my $mode = __PACKAGE__ . '::Mode::' . ( $init{ script } ? 'Script' : ( $init{ dryrun } ? 'Dryrun' : 'Run' ) );
	eval "require $mode" || die "Failed to load module $mode: $@";
	$$self{ mode } = $mode->new(
		verbosity => $$self{ verbosity },
	);

	# detect and load engine
	unless ( $engine = $init{ engine } ) {
		( $engine, $engine_id_file ) = ( detect_engine() );
	}
	my $engine_class = __PACKAGE__ . '::' . $engine;
	eval "require $engine_class" || die "Failed to load module $engine_class: $@";
	$engine_class->new(
		id_file => $engine_id_file || '',
	);

	# set game from cli argument if present
	my $game = $init{ game } || detect_game_name( $$self{ engine } );

	$$self{ game } = ( __PACKAGE__ . '::Game' )->new(
		name => $game,
	);

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
sub detect_game_name ( $engine_module ) {
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
	if ( $engine_module->can( 'detect_game' ) ) {
		return $engine_module->detect_game();
	}

	# XXX: Godot -> name.pck, GZDoom -> name.ipk3
	# HashLink: deadcells.sh, Northgard
	# Mono*: name.exe

	$game_name = IndieRunner::Info::goggame_name();
	($game_name) = IndieRunner::IdentifyFiles::find_file_magic( '^ELF.*executable', glob '*' ) unless $game_name;
	($game_name) = IndieRunner::IdentifyFiles::find_file_magic( '^PE32 executable \(console\)', glob '*' ) unless $game_name;
	$game_name = 'unknown' unless $game_name;	# bail

	return $game_name;
}

sub setup ( $self ) {
	# XXX: Extract archives first, then
	#      after extracting archives, need to check for libraries with
	#      IndieRunner::Java::bundled_libraries()
	if ( $$self{ engine }{ need_to_extract } ) {
		$$self{ mode }->extract( %{ $$self{ engine }{ need_to_extract } } );
	}

	if ( $$self{ engine }{ need_to_remove } ) {
		$$self{ mode }->remove( @{ $$self{ engine }{ need_to_remove } } );
	}

	if ( $$self{ engine }{ need_to_replace } ) {
		$$self{ mode }->replace( %{ $$self{ engine }{ need_to_replace } } );
	}

	if ( $$self{ engine }{ need_to_convert } ) {
		$$self{ mode }->convert( %{ $$self{ engine }{ need_to_convert } } );
	}

	# fork + pledge + unveil for this into a separate process; use waitpid
	# 	to continue once completed
	#
}

sub run ( $self ) {
	confess "Not implemented";

	# configure runtime:
	# - engine-specific, game-specific, and user-provided configuration
	# - elements: environment ( set %{ENV} ), binary, arguments, potentially symlinks
	# - need to know unveil paths
	# - engine-specific pledge exec promises?

	# XXX: Fork + Exec Runtime, unveil +/- pledge as appropriate
}

1;

__END__

=head1 NAME

IndieRunner - Launch your indie games on more platforms

=head1 SYNOPSIS

 use IndieRunner;

 # create IndieRunner object with default values
 chdir path/to/game or die "chdir failed: $!";
 my $indierunner = IndieRunner->new();

 # perform setup of files for the project
 $indierunner->setup();

 # run the project
 $indierunner->run();

=head1 DESCRIPTION

B<IndieRunner> handles the nitty gritty details of running a variety of (indie) games made with certain engines (see engines under SEE ALSO). It performs heuristics to determine the type of engine, its setup needs and runtime configuration. Modes for dryrun and the generation of a statical script to perform setup and run steps are included.

=head1 SEE ALSO

=head2 Engines

L<IndieRunner::FNA>, L<IndieRunner::GZDoom>, L<IndieRunner::Godot>, L<IndieRunner::HashLink>, L<IndieRunner::Java>, L<IndieRunner::Love2D>, L<IndieRunner::Mono>, L<IndieRunner::MonoGame>, L<IndieRunner::XNA>.

=head2 Other

L<IndieRunner::Mode>, L<IndieRunner::GrandCentral>, L<IndieRunner::IdentifyFiles>.

=head1 AUTHOR

Thomas Frohwein
