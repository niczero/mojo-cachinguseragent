use 5.010001;
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
    requires  => {perl => 5.010001},
    resources => {
      license     => 'http://www.opensource.org/licenses/artistic-license-2.0',
      repository  => 'http://github.com/niczero/mojo-cachinguseragent',
      bugtracker  => 'http://github.com/niczero/mojo-cachinguseragent/issues'
    },
    no_index => {directory => [qw(data test)]}
  },
  BUILD_REQUIRES => {'Test::More' => 0},
  CONFIGURE_REQUIRES => {'ExtUtils::MakeMaker' => 6.3},
  PREREQ_PM => {
    Mojolicious => 5.8
  },
  EXE_FILES => [],
  test => {TESTS => 'test/*.t'}
);
