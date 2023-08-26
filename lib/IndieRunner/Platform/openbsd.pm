package IndieRunner::Platform::openbsd;

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
use autodie;

use base qw( Exporter );
our @EXPORT_OK = qw( init );

use Cwd;
use OpenBSD::Unveil;

use IndieRunner::Cmdline qw( cli_dllmap_file cli_tmpdir cli_verbose );

my %unveil_paths = (
	'/usr/libdata/perl5/'			=> 'r',
	'/usr/local/lib/'			=> 'r',
	'/usr/local/libdata/perl5/site_perl/'	=> 'r',
	'/usr/local/share/misc/magic.mgc'	=> 'r',
	'/dev/'					=> 'rw', # for IO::Tty
	);

#sub _pledge () {
#}

sub _unveil () {
	my $verbose = cli_verbose();

	# add work directory to %unveil_paths rwc (ref. cli_userdir)
	$unveil_paths{ getcwd() } = 'rwc';

	# add logfile directory to %unveil_paths wc (ref. cli_tmpdir)
	$unveil_paths{ '/tmp/' } = 'rwc';		# XXX: this is overly broad

	# add unveil x for the runtime binary
	$unveil_paths{ '/usr/local/bin' } = 'x';	# XXX: bin/ is overly broad

	# XXX: add unveil r for configuration files: cli_dllmap_file
	if ( cli_dllmap_file() ) {
		$unveil_paths{ cli_dllmap_file() } = 'r';
	}

	#foreach  my ( $k, $v ) ( %unveil_paths ) {	# for my (...) is experimental
	while ( my ( $k, $v ) = each %unveil_paths ) {
		say "$k: unveil \'$v\'" if $verbose;
		unveil( $k, $v ) || die "$!";
	}
	unveil() || die "$!";
}

sub init ( $self ) {
	_unveil();
	#XXX: _pledge();
	return 1;
}

1;
