# ============
# agent.t
# ============
use Mojo::Base -strict;
use Test::More;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use MIME::Base64 'encode_base64url';
use Mojo::CachingUserAgent;
use Mojo::Log;
use Mojo::Server::Daemon;
use Mojo::Util qw(dumper files);

# App
use Mojolicious::Lite;
app->log->level('fatal');

get '/t' => {text => 'works!'};
get '/h' => {inline => '<span id="a">A</span><span id="b">B</span>'};
get '/j' => {json => {a => 'A', b => ['D', 'B']}};
# end of App

my $daemon = Mojo::Server::Daemon->new(
  app    => app,
  ioloop => Mojo::IOLoop->singleton,
  silent => 1
);
$daemon->listen(['http://127.0.0.1'])->start;
my $port = Mojo::IOLoop->acceptor($daemon->acceptors->[0])->port;

my $dir = tempdir CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $dir,
  ioloop    => Mojo::IOLoop->singleton,
  log       => Mojo::Log->new(path => catfile $dir, 'test.log'),
  on_error  => sub {}
);

my $url = "http://127.0.0.1:$port/t";
subtest q{Body} => sub {
  ok my $body = $ua->body_from_get($url), 'got something';
  is $body, 'works!', 'expected content';
  ok my @files = files($dir), 'dir listing';
  ok my $cache = catfile($ua->cache_dir, encode_base64url('GET'. $url)),
      'cache file';
  ok -f $cache, 'cache file exists';
  ok -s $cache, 'cache file has content';
};

$url = "http://127.0.0.1:$port/h";
subtest q{DOM} => sub {
  my $dom;
  $ua->on_error(sub { die pop });
  ok $dom = $ua->dom_from_get($url), 'got something';
  my $length = length($dom->to_string);

  ok $dom = $ua->dom_from_get($url, '#b'), 'result via selector';
  ok length($dom->to_string) < $length, 'shorter';

  is $ua->dom_from_get($url, '#NOTTHERE'), undef, 'missing sub-dom';
};

$url = "http://127.0.0.1:$port/j";
subtest q{JSON} => sub {
  my $json;
  ok $json = $ua->json_from_get($url), 'got something';
  is ref($json), 'HASH', 'hashref';

  ok $json = $ua->json_from_get($url, '/b/1'), 'result via pointer';
  ok !ref($json), 'scalar';

  is $ua->json_from_get($url, '/notthere'), undef, 'missing sub-json';
};

$url = "http://127.0.0.1:$port/t";
subtest q{Body async} => sub {
  my $body;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->body_from_get($url, sub { $body = $_[2] });
  });
  ok !$body, 'no body yet';
  $delay->wait;
  ok $body, 'got a body';
  ok +($body // '') =~ /works/, 'expected content';
};

$url = "http://127.0.0.1:$port/h";
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
    $ua->dom_from_get($url, '#b', sub { $dom = $_[2] });
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

$url = "http://127.0.0.1:$port/j";
subtest q{JSON async} => sub {
  my $json;
  my $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get($url, sub { $json = $_[2] });
  });
  ok !$json, 'no json yet';
  $delay->wait;
  ok $json, 'got a json';
  is ref($json), 'HASH', 'hashref';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get($url, '/b/1', sub { $json = $_[2] });
  });
  ok !$json, 'no json again';
  $delay->wait;
  ok $json, 'got a json via pointer';
  ok !ref($json), 'scalar';

  undef $json;
  $delay = Mojo::IOLoop->delay(sub {
    $ua->json_from_get($url, '/notthere', sub { $json = $_[2] });
  })->wait;
  is $json, undef, 'missing sub-json';
};

done_testing();
