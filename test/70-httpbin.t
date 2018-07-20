# ============
# httpbin.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Spec::Functions 'catfile';
use MIME::Base64 'encode_base64url';
use Mojo::CachingUserAgent;
use Mojo::File qw(path tempdir);
use Mojo::Log;
use Mojo::Util qw(dumper);

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

my $tmpdir = tempdir CLEANUP => 1, EXLOCK => 0, TEMPLATE => 'testXXXXXX';

my $ua = Mojo::CachingUserAgent->new(
  cache_dir => "$tmpdir",
  on_error => sub {},
  log => Mojo::Log->new(path => ''. $tmpdir->child('test.log'))
);
my $url = 'http://httpbin.org';

subtest q{Body} => sub {
  my $body;
  ok $body = $ua->body_from_get($url), 'got something';
  ok $body =~ /\bResponse Service\b/, 'expected content';
  ok my @files = $tmpdir->list, 'dir listing';
  ok my $cache = catfile($ua->cache_dir, encode_base64url('GET'. $url)),
      'cache file';
  ok -f $cache, 'cache file exists';
  ok -s $cache, 'cache file has content';
};

subtest q{DOM} => sub {
  my $dom;
  $ua->on_error(sub { die pop });
  ok $dom = $ua->dom_from_get($url), 'got something';
  my $length = length($dom->to_string);

  ok $dom = $ua->dom_from_get($url, '#swagger-ui'), 'result via selector';
  ok length($dom->to_string) < $length, 'shorter';

  is $ua->dom_from_get($url, '#NOTTHERE'), undef, 'missing sub-dom';
};

subtest q{JSON} => sub {
  my $json;
  ok $json = $ua->json_from_get("$url/ip"), 'got something';
  is ref($json), 'HASH', 'hashref';

  ok $json = $ua->json_from_get("$url/ip", '/origin'), 'result via pointer';
  ok !ref($json), 'scalar';

  is $ua->json_from_get("$url/ip", '/notthere'), undef, 'missing sub-json';
};

subtest q{Body async} => sub {
  my $body;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->body_from_get($url, sub { $body = $_[2] });
  });
  ok !$body, 'no body yet';
  $delay->wait;
  ok $body, 'got a body';
  ok +($body // '') =~ /\bResponse Service\b/, 'expected content';
};

subtest q{DOM async} => sub {
  my $dom;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->dom_from_get($url, sub { $dom = $_[2] });
  });
  ok !$dom, 'no dom yet';
  $delay->wait;
  ok $dom, 'got a dom';
  ok my $length = length($dom), 'has length';

  undef $dom;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->dom_from_get($url, '#swagger-ui', sub { $dom = $_[2] });
  });
  ok !$dom, 'no dom again';
  $delay->wait;
  ok $dom, 'result via selector';
  ok length($dom) < $length, 'shorter';

  undef $dom;
  Mojo::IOLoop->delay(sub {
    $ua->dom_from_get($url, '#NOTTHERE', sub { $dom = $_[2] });
  })->wait;
  is $dom, undef, 'missing sub-dom';
};

subtest q{JSON async} => sub {
  my $json;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get("$url/ip", sub { $json = $_[2] });
  });
  ok !$json, 'no json yet';
  $delay->wait;
  ok $json, 'got a json';
  is ref($json), 'HASH', 'hashref';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get("$url/ip", '/origin', sub { $json = $_[2] });
  });
  ok !$json, 'no json again';
  $delay->wait;
  ok $json, 'got a json via pointer';
  ok !ref($json), 'scalar';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get("$url/ip", '/notthere', sub { $json = $_[2] });
  })->wait;
  is $json, undef, 'missing sub-json';
};

done_testing();
