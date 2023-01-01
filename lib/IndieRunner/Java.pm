package IndieRunner::Java;

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
use v5.10;
use version 0.77; our $VERSION = version->declare('v0.0.1');
use autodie;
use Carp;

# XXX: are all of these exports really needed?
use base qw( Exporter );
our @EXPORT_OK = qw( match_bin_file );

use Config;
use File::Find::Rule;
use JSON;
use List::Util qw( max );
use Path::Tiny;
use Readonly;

use IndieRunner::Cmdline qw( cli_dryrun cli_verbose );
use IndieRunner::Java::LibGDX;
use IndieRunner::Java::LWJGL2;
use IndieRunner::Java::LWJGL3;
use IndieRunner::Java::Steamworks4j;
use IndieRunner::Platform qw( get_os );

Readonly::Scalar my $MANIFEST		=> 'META-INF/MANIFEST.MF';

# Java version string examples: '1.8.0_312-b07'
#                               '1.8.0_181-b02'
#                               '11.0.13+8-1'
#                               '17.0.1+12-1'
Readonly::Scalar my $JAVA_VER_REGEX => '\d{1,2}\.\d{1,2}\.\d{1,2}[_\+][\w\-]+';

Readonly::Scalar my $So_Sufx => '.so';
my $Bit_Sufx;

Readonly::Array my @JAVA_LIB_PATH => (
	'/usr/local/lib',
	'/usr/local/share/lwjgl',
	);

my %Valid_Java_Versions = (
	'openbsd'       => [
				'1.8.0',
				'11',
				'17',
			   ],
);

my $game_jar;
my $main_class;
my $class_path;
my @java_frameworks;
my $java_home;
my @jvm_env;
my @jvm_args;
my $os;

my %java_version = (
	bundled	=> undef,
	lwjgl3	=> undef,
	);

sub match_bin_file {
	my $regex               = shift;
	my $file                = shift;
	my $case_insensitive    = defined($_[0]);

	my $out = $1 if ( $case_insensitive ?
		path($file)->slurp_raw =~ /($regex)/i :
		path($file)->slurp_raw =~ /($regex)/ );

	return $out;
}

sub fix_jvm_args {
	my @initial_jvm_args = @jvm_args;

	# replace any '-Djava.library.path=...' with a generic path
	map { $_ = (split( '=' ))[0] . join( ':', @JAVA_LIB_PATH) . ':' . (split( '=' ))[1] }
		grep( /^\-Djava\.library\.path=/, @jvm_args );

	if ( ( join( ' ', @jvm_args ) ne join( ' ', @initial_jvm_args ) )
		and cli_verbose() ) {
			print "\nJVM arguments have been modified: ";
			say join( ' ', @initial_jvm_args ) . " => " .
				join ( ' ', @jvm_args );
	}
}

sub get_bundled_java_version {
	my $bundled_java_bin;

	# find bundled java binary (alternatively libjava.so or libjvm.so)
	($bundled_java_bin) = File::Find::Rule->file->name('java')->in('.');
	return undef unless $bundled_java_bin;

	# fetch version string and trim to format for JAVA_HOME
	my $got_version = match_bin_file($JAVA_VER_REGEX, $bundled_java_bin);
	if ( $os eq 'openbsd' ) {
		# OpenBSD: '1.8.0', '11', '17'
		if (substr($got_version, 0, 2) eq '1.') {
			$java_version{ bundled } = '1.8.0';
		}
		else {
			$java_version{ bundled } = $got_version =~ /^\d{2}/;
		}
	}
	else {
		confess "Unsupported OS: " . $os;
	}
}

sub set_java_home {
	my $v = shift;

	if ( $os eq 'openbsd' ) {
		$java_home = '/usr/local/jdk-' . $v;
	}
	else {
		die "Unsupported OS: " . $os;
	}

	confess "Couldn't locate desired JAVA_HOME directory at $java_home: $!"
		unless ( -d $java_home );
}

sub extract_jar {
	my $ae;
	my @class_path = @_;

	# Notes on options for extracting:
	# - Archive::Extract fails to fix directory permissions +x (Stardash, INC: The Beginning)
	# - jar(1) (JDK 1.8) also fails to fix directory permissions
	# - unzip(1) from packages: use -qq to silence and -o to overwrite existing files
	#   ... but unzip exits with error about overlapping, possible zip bomb (Space Haven)
	# - 7z x -y: verbose output, seems like it can't be quited much (-bd maybe)
	foreach my $cp (@class_path) {
		unless ( -f $cp ) {
			croak "No classpath $cp to extract.";
		}
		say "Extracting $cp ...";
		return if cli_dryrun();
		system( '7z', 'x', '-y', $cp ) and
			confess "Error while attempting to extract $cp";
	}
}

sub has_libgdx { ( glob '*gdx*.{so,dll}' ) ? return 1 : return 0; }
sub has_steamworks4j { ( glob '*steamworks4j*.{so,dll}' ) ? return 1 : return 0; }

sub has_lwjgl_any {
	if ( File::Find::Rule->file
			     ->name( '*lwjgl*.{so,dll}' )
			     ->in( '.' )
	   ) { return 1; }
	return 0;
}

sub lwjgl_2_or_3 {
	if ( File::Find::Rule->file
			     ->name( '*lwjgl_{opengl,remotery,stb,xxhash}.{so,dll}' )
			     ->in( '.' )
	   ) { return 3; }
	return 2;
}

sub setup {
	my ($self) = @_;

	my $dryrun = cli_dryrun();
	my $verbose = cli_verbose();

	my $config_file;

	# 1. Check OS and initialize basic variables
	$os = get_os();
	die "OS not recognized: " . $os unless ( exists $Valid_Java_Versions{$os} );
	get_bundled_java_version();

	$Bit_Sufx = ( $Config{'use64bitint'} ? '64' : '' ) . $So_Sufx;
	say "Library suffix:\t$Bit_Sufx" if $verbose;

	# 2. Get data on main JAR file and more
	# 	a. first check JSON config file
	if ( -f 'config.json' ) {	# commonly config.json, but sometimes e.g. TFD.json
		$config_file = 'config.json';
	}
	else {
		($config_file) = glob '*.json';
	}

	if ( -f $config_file ) {
		my $config_data		= decode_json(path($config_file)->slurp_utf8)
			or die "unable to read config data from $config_file: $!";
		$main_class		= $$config_data{'mainClass'}
			or die "Unable to get configuration for mainClass: $!";
		$class_path		= $$config_data{'classPath'}
			or die "Unable to get configuration for classPath: $!";
		$game_jar		= $$config_data{'jar'} if ( exists($$config_data{'jar'}) );
		@jvm_args = @{$$config_data{'vmArgs'}} if ( exists($$config_data{'vmArgs'}) );
	}
	#	b. check shellscripts for the data
	else {
		#	e.g. Puppy Games LWJGL game, like Titan Attacks, Ultratron (ultratron.sh)
		#	e.g. Delver (run-delver.sh)

		# find and slurp .sh file
		my @sh_files = glob '*.sh';
		my $content;
		my @lines;
		my @java_lines;
		foreach my $sh ( @sh_files ) {
			# slurp and format content of file
			$content = path( $sh )->slurp_utf8;
			$content =~ s/\s*\\\n\s*/ /g;	# rm escaped newlines

			@lines = split( /\n/, $content );
			@lines = grep { !/^#/ } @lines;	# rm comments
			@java_lines = grep { /^java\s/ } @lines;	# find java invocation

			last if scalar @java_lines == 1;

			if ( scalar @java_lines > 1 ) {
				confess "XXX: Not implemented";
			}
		}

		# extract important stuff from the java invocation
		if ( $java_lines[0] =~ m/\-jar\s+\"?(\S+\.jar)\"?/i ) {
			$game_jar = $1;
		}
		my @java_components = split( /\s+/, $java_lines[0] );
		push @jvm_args, grep { /^\-D/ } @java_components;
	}

	# 3. Extract JAR file if not done previously
	unless (-f $MANIFEST ) {
		if ( $game_jar ) {
			extract_jar $game_jar;
		}
		elsif ( $class_path ) {
			extract_jar @{$class_path}[0];
		}
		else {
			confess "no JAR file to extract";
		}
	}

	# 4. Enumerate frameworks (LibGDX, LWJGL{2,3}, Steamworks4j)

	if ( has_libgdx() ) {
		push( @java_frameworks, 'LibGDX' );
		push( @java_frameworks, 'LWJGL' . lwjgl_2_or_3() );	# LibGDX implies LWJGL
	}
	elsif ( has_lwjgl_any() ) {
		push( @java_frameworks, 'LWJGL' . lwjgl_2_or_3() );
	}
	push @java_frameworks, 'Steamworks4j' if has_steamworks4j();
	say 'Bundled Java Frameworks: ' . join( ' ', @java_frameworks) if $verbose;

	# 5. Call specific setup for each framework
	foreach my $f ( @java_frameworks ) {
		my $module = "IndieRunner::Java::$f";
		$module->setup();
	}
}

sub run_cmd {
	my ($self, $game_file) = @_;
	my $verbose = cli_verbose();

	# XXX: may need a way to inherit classpath from setup when config is read
	my @jvm_classpath;

	# adjust JVM invocation for LWJGL3
	if ( grep { /^\QLWJGL3\E$/ } @java_frameworks ) {
		$java_version{ lwjgl3 } =
			IndieRunner::Java::LWJGL3::get_java_version_preference();
		push @jvm_classpath, IndieRunner::Java::LWJGL3::add_classpath();
	}

	# validate java versions
	foreach my $k ( keys %java_version ) {
		if ( grep( /^\Q$java_version{ $k }\E$/, @{$Valid_Java_Versions{$os}} ) ) {
			$java_version{ $k } = version->declare( $java_version{ $k } );
		}
		else {
			$java_version{ $k } = undef
		}
	}

	# pick best java version
	my $os_java_version = max( values %java_version );
	$os_java_version = '1.8.0' unless $os_java_version;
	if ( $verbose ) {
		say "Bundled Java version:\t\t$java_version{ bundled }";
		say "LWJGL3 preferred Java version:\t$java_version{ lwjgl3 }";
		say "Java version to be used:\t$os_java_version";
	}

	set_java_home( $os_java_version );
	say "Java Home:\t\t\t$java_home" if $verbose;
	@jvm_env = ( "JAVA_HOME=" . $java_home, );
	fix_jvm_args();

	# more effort to figure out $main_class if not set
	unless ( $main_class ) {
		my @mlines = path( $MANIFEST )->lines_utf8;
		map { /^\QMain-Class:\E\s+(\S+)/ and $main_class = $1 } @mlines;
	}
	confess "Unable to identify main class for JVM execution" unless $main_class;

	return( 'env', @jvm_env, $java_home . '/bin/java', @jvm_args, '-cp',
	        join( ':', @jvm_classpath, '.' ), $main_class );
}

1;
