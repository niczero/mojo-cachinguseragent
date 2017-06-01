use 5.010_001;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Mojo::CachingUserAgent',
  VERSION_FROM => 'lib/Mojo/CachingUserAgent.pm',
  ABSTRACT     => 'An async useragent that can cache pages',
  AUTHOR       => 'Nic Sandfield <niczero@cpan.org>',
  LICENSE      => 'artistic_2',
  META_MERGE   => {
    requires  => {perl => 5.014},
    resources => {
      bugtracker  => 'https://github.com/niczero/mojo-cachinguseragent/issues',
      license     => 'http://www.opensource.org/licenses/artistic-license-2.0',
      repository  => 'https://github.com/niczero/mojo-cachinguseragent'
    },
    no_index => {directory => [qw(data test)]}
  },
  BUILD_REQUIRES => {'Test::More' => 0},
  CONFIGURE_REQUIRES => {'ExtUtils::MakeMaker' => 6.3},
  PREREQ_PM => {
    'IO::Socket::SSL' => 1.94,
    Mojolicious       => 7.15
  },
  test => {TESTS => 'test/*.t'}
);
