# ============
# cookies.t
# ============
use Mojo::Base -strict;
use Test::More;

use Mojo::CachingUserAgent;
use Mojo::File 'tempfile';
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ACCESS to your cookie path to enable this test'
  unless my $cookie_file = $ENV{TEST_ACCESS};

my $tmpfile = tempfile CLEANUP => 1, EXLOCK => 0, TEMPLATE => 'testXXXXXX';

my $config = {
  log       => $tmpfile,
  useragent => 'Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36'
    .' (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36'
};

my $ua = Mojo::CachingUserAgent->new(
  cookie_file => $cookie_file,
  log => Mojo::Log->new(path => $config->{log}),
  name => $config->{useragent},
  on_error => sub { die $_[1] }
);

subtest initial => sub {
  my $cookies = $ua->cookie_jar->all;
  ok @$cookies, 'got some cookies'
    or diag 'No cookies; try again';
};

my $url = 'http://aol.com';
note $url;
subtest getting => sub {
  ok my $head = $ua->max_redirects(9)->head_from_head($url), 'got something';
  ok my $found = $ua->cookie_jar->find(Mojo::URL->new($url));
  ok @$found, 'found some cookies';
  ok $ua->save_cookies, 'saved cookies';
};

subtest 'Mojo::Cookie::File' => sub {
  my $jar = Mojo::UserAgent::CookieJar->new;
  ok my $marshall = Mojo::Cookie::File->new(
    file => $cookie_file,
    jar => $jar
  ), 'paired jar with file';
  ok ! @{$jar->all}, 'no cookies (string)';
  ok $marshall->load, 'loaded (all)';
  ok @{$jar->all}, 'got cookies (all)';

  $jar = Mojo::UserAgent::CookieJar->new;
  ok $marshall = Mojo::Cookie::File->new(
    jar => $jar,
    file => $cookie_file
  ), 'paired jar with file';
  ok $marshall->load(undef, 'aol'), 'loaded (string)';
  ok @{$jar->all}, 'got cookies (string)';

  $jar = Mojo::UserAgent::CookieJar->new;
  ok $marshall = Mojo::Cookie::File->new(
    jar => $jar
  ), 'paired jar with file';
  ok $marshall->load($cookie_file, qr/aol/), 'loaded (regexp)';
  ok @{$jar->all}, 'got cookies (regexp)';
};

subtest load => sub {
  ok $ua->cookie_jar(Mojo::UserAgent::CookieJar->new), 'reset cookie jar';
  my $found = $ua->cookie_jar->find(Mojo::URL->new($url));
  ok ! @$found, 'empty cookie jar';

  ok $ua->load_cookies(qr/aol/), 'load';
  $found = $ua->cookie_jar->all;
  ok @$found, 'found relevant cookies';
};

done_testing;
