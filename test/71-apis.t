# ============
# apis.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Mojo::CachingUserAgent;
use Mojo::Headers;
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

my $dir = tempdir CLEANUP => 1, EXLOCK => 0;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $dir,
  on_error => sub {},
  log => Mojo::Log->new(path => catfile $dir, 'test.log')
);

my $url = 'http://bnb.data.bl.uk/doc/concept/lcsh/Distributedalgorithms.rdfjson';

subtest q{head_from_head (bnb)} => sub {
  my $head;
  ok $head = $ua->head_from_head($url), 'got something';
  ok $head->can('content_type'), 'method call';
  is $head->content_type, 'text/html; charset=utf-8', 'expected header';
};

$url =~ s/rdfjson$/json/;

subtest q{json_from_get (bnb)} => sub {
  ok my $value = $ua->json_from_get($url), 'got something';
  ok $value = $ua->json_from_get($url, '/result/license'), 'got value';
  ok $value = $ua->json_from_get($url, '/version'), 'got value';
  like $value, qr/^\d+\.\d+$/, 'got version';

  ok $value = $ua->json_from_get($url, '/version'), 'got value from cache';
  like $value, qr/^\d+\.\d+$/, 'got version from cache';
};

$url = 'http://httpbin.org/ip';

subtest q{json_from_get (httpbin)} => sub {
  ok $ua->json_from_get($url), 'got something';
  ok my $value = $ua->json_from_get($url, '/origin'), 'got value';
  like $value, qr/^\d+\.\d+.\d+.\d+$/, 'ip addr';

  ok $value = $ua->json_from_get($url, '/origin'), 'got value from cache';
  like $value, qr/^\d+\.\d+.\d+.\d+$/, 'ip addr from cache';
};

$url = 'http://api.metacpan.org/v1/author/NICZERO';

subtest q{head_from_get (metacpan)} => sub {
  my $head;
  ok $head = $ua->head_from_get($url, {
    'Content-Type' => 'application/json; charset=UTF-8',
    Accept => 'application/json; charset=UTF-8'
  }), 'got something';
  ok $head->server, 'got value';
  like $head->server, qr/^Varnish/, 'expected value'
    or diag dumper $head;
};

$url = 'http://httpbin.org/encoding/utf8';

subtest q{body_from_get} => sub {
  ok my $r = $ua->body_from_get($url), 'got something';
  like $r, qr/\N{U+226A}/, 'much less than';
  like $r, qr/\N{U+2200}\N{U+0078}\N{U+2208}\N{U+211D}/, 'for all x in R';

  ok $r = $ua->body_from_get($url), 'got something from cache';
  like $r, qr/\N{U+226A}/, 'much less than from cache';
  like $r, qr/\N{U+2200}\N{U+0078}\N{U+2208}\N{U+211D}/,
      'for all x in R from cache';
};

done_testing();
