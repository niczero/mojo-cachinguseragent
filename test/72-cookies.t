# ============
# cookies.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Mojo::CachingUserAgent;
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ACCESS to enable this test' unless $ENV{TEST_ACCESS};

my $dir = tempdir CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cookie_file => '/tmp/x/cookies.txt',
  on_error => sub {},
#  log => Mojo::Log->new(path => catfile $dir, 'test.log')
  log => Mojo::Log->new(path => '/tmp/x/test.log')
);

my $url = 'http://www.accuweather.com';
subtest q{head_from_get} => sub {
  my $head;
  ok $head = $ua->head_from_get($url), 'got something';
};

ok $ua->save_cookies, 'saved cookies';
done_testing();
