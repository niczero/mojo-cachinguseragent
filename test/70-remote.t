# ============
# remote.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Mojo::CachingUserAgent;
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ACCESS to enable this test (developer only!)'
  unless $ENV{TEST_ACCESS};

my $dir = tempdir CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $dir,
  on_error => sub {},
  log => Mojo::Log->new(path => catfile $dir, 'test.log')
);
my $url = 'http://httpbin.org';

subtest q{Body} => sub {
  my $body;
  ok $body = $ua->get_body($url), 'got something';
  ok $body =~ /\bENDPOINTS\b/, 'expected content';
};

subtest q{DOM} => sub {
  my $dom;
  $ua->on_error(sub { die pop });
  ok $dom = $ua->get_dom($url), 'got something';
  my $length = length($dom->to_string);

  ok $dom = $ua->get_dom($url, '#AUTHOR'), 'result via selector';
  ok length($dom->to_string) < $length, 'shorter';

  is $ua->get_dom($url, '#NOTTHERE'), undef, 'missing sub-dom';
};

subtest q{JSON} => sub {
  my $json;
  ok $json = $ua->get_json("$url/ip"), 'got something';
  is ref($json), 'HASH', 'hashref';

  ok $json = $ua->get_json("$url/ip", '/origin'), 'result via pointer';
  ok !ref($json), 'scalar';

  is $ua->get_json("$url/ip", '/notthere'), undef, 'missing sub-json';
};

subtest q{Body async} => sub {
  my $body;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->get_body($url, sub { $body = $_[2] });
  });
  ok !$body, 'no body yet';
  $delay->wait;
  ok $body, 'got a body';
  ok +($body // '') =~ /\bENDPOINTS\b/, 'expected content';
};

subtest q{DOM async} => sub {
  my $dom;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->get_dom($url, sub { $dom = $_[2] });
  });
  ok !$dom, 'no dom yet';
  $delay->wait;
  ok $dom, 'got a dom';
  ok my $length = length($dom), 'has length';

  undef $dom;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->get_dom($url, '#AUTHOR', sub { $dom = $_[2] });
  });
  ok !$dom, 'no dom again';
  $delay->wait;
  ok $dom, 'result via selector';
  ok length($dom) < $length, 'shorter';

  undef $dom;
  Mojo::IOLoop->delay(sub {
    $ua->get_dom($url, '#NOTTHERE', sub { $dom = $_[2] });
  })->wait;
  is $dom, undef, 'missing sub-dom';
};

subtest q{JSON async} => sub {
  my $json;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->get_json("$url/ip", sub { $json = $_[2] });
  });
  ok !$json, 'no json yet';
  $delay->wait;
  ok $json, 'got a json';
  is ref($json), 'HASH', 'hashref';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->get_json("$url/ip", '/origin', sub { $json = $_[2] });
  });
  ok !$json, 'no json again';
  $delay->wait;
  ok $json, 'got a json via pointer';
  ok !ref($json), 'scalar';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->get_json("$url/ip", '/notthere', sub { $json = $_[2] });
  })->wait;
  is $json, undef, 'missing sub-json';
};

done_testing();
