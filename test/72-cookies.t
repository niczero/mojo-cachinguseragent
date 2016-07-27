# ============
# cookies.t
# ============
use Mojo::Base -strict;
use Test::More;

use Mojo::CachingUserAgent;
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

my $config = {
  cookies   => '/tmp/x/cookies.txt',
  log       => '/tmp/x/uatest.log',
  useragent => 'Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36'
    .' (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36'
};

BAIL_OUT(sprintf
    'Visit http://www.linkedin.com and then export your cookies to %s',
    $config->{cookies}) unless -f $config->{cookies};

my $ua = Mojo::CachingUserAgent->new(
  cookie_file => $config->{cookies},
  log => Mojo::Log->new(path => $config->{log}),
  name => $config->{useragent},
  on_error => sub { die $_[1] }
);

subtest q{all} => sub {
  my $cookies = $ua->cookie_jar->all;
  cmp_ok scalar(@$cookies), '>', 4, 'got a bunch of cookies';
};

my $url = 'http://www.linkedin.com';
subtest q{all} => sub {
  ok my $found = $ua->cookie_jar->find(Mojo::URL->new($url));
  ok scalar(@$found) > 1, 'Found some relevant cookies';
};

$url = 'http://www.google.com';
subtest q{head_from_head} => sub {
  ok my $head = $ua->max_redirects(9)->head_from_head($url), 'got something';
  like $ua->head_from_head($url)->location, qr/google/, 'expected header';
};

ok $ua->save_cookies, 'saved cookies';

done_testing();
__DATA__
