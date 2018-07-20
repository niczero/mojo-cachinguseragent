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
use Mojo::File 'path';
use Mojo::Log;
use Mojo::Server::Daemon;

# App
use Mojolicious::Lite;
app->log->level('fatal');

get 't' => {text => 'works!'};
get 'h' => {inline => '<span id="a">A</span><span id="b">B</span>'};
get 'j' => {json => {a => 'A', b => ['D', 'B']}};
get 'r' => {cb => sub { shift->redirect_to('t') }};
# end of App

my $loop = Mojo::IOLoop->singleton;
my $daemon = Mojo::Server::Daemon->new(
  app    => app,
  ioloop => $loop,
  silent => 1
);
$daemon->listen(['http://127.0.0.1'])->start;
my $port = Mojo::IOLoop->acceptor($daemon->acceptors->[0])->port;

my $dir = tempdir CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $dir,
  ioloop    => $loop,
  log       => Mojo::Log->new(path => catfile $dir, 'test.log'),
  on_error  => sub {}
);

my $url = "http://127.0.0.1:$port/t";
subtest q{Body} => sub {
  ok my $body = $ua->body_from_get($url), 'got something';
  is $body, 'works!', 'expected content';
  ok my @files = path($dir)->list, 'dir listing';
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

$loop->stop;

$url = "http://127.0.0.1:$port/r";
subtest q{redirect} => sub {
  my ($status, $body, $t);
  $ua->max_redirects(0)->body_from_get($url, sub {
    my ($agent, $error, $body_, $tx) = @_;
    $status = $tx->res->code;
    $loop->stop;
  });
  $loop->start;
  is $status, 302, 'redirect status code';

  undef $status;
  $ua->max_redirects(3)->body_from_get($url, sub {
    my ($agent, $error, $body_, $tx) = @_;
    $status = $tx->res->code if $tx;
    $body = $body_;
    $loop->stop;
  });
  $loop->start;
  is $status, 200, 'ok status code';
  is $body, 'works!', 'expected body';

  $ua->body_from_get($url, sub {
    my ($agent, $error, $body_, $tx) = @_;
    $t = $tx;
    $loop->stop;
  });
  $loop->start;
  ok !defined($t), 'No transaction when cached';
};

$url = "http://127.0.0.1:$port/t";
subtest q{Body async} => sub {
  my $body;
  $ua->body_from_get($url, sub { $body = $_[2]; $loop->stop });
  ok !$body, 'no body yet';
  $loop->start;
  ok $body, 'got a body';
  ok +($body // '') =~ /works/, 'expected content';
};

$url = "http://127.0.0.1:$port/h";
subtest q{DOM async} => sub {
  my $dom;
  $ua->dom_from_get($url, sub { $dom = $_[2]; $loop->stop });
  ok !$dom, 'no dom yet';
  $loop->start;
  ok $dom, 'got a dom';
  ok my $length = length($dom), 'has length';

  undef $dom;
  $ua->dom_from_get($url, '#b', sub { $dom = $_[2]; $loop->stop });
  ok !$dom, 'no dom again';
  $loop->start;
  ok $dom, 'result via selector';
  ok length($dom) < $length, 'shorter';

  undef $dom;
  $ua->dom_from_get($url, '#NOTTHERE', sub { $dom = $_[2]; $loop->stop });
  $loop->start;
  is $dom, undef, 'missing sub-dom';
};

$url = "http://127.0.0.1:$port/j";
subtest q{JSON async} => sub {
  my ($error, $json);
  $ua->json_from_get($url, sub { ($error, $json) = @_[1,2]; $loop->stop });
  ok !$json, 'no json yet';
  $loop->start;
  ok $json, 'got a json' or diag $error;
  is ref($json), 'HASH', 'hashref';

  undef $json;
  $ua->json_from_get($url, '/b/1',
      sub { ($error, $json) = @_[1,2]; $loop->stop });
  ok !$json, 'no json again';
  $loop->start;
  ok $json, 'got a json via pointer' or diag $error;
  ok !ref($json), 'scalar';

  undef $json;
  $ua->json_from_get($url, '/not_there', sub { $json = $_[2]; $loop->stop });
  $loop->start;
  ok ! $json, 'missing sub-json';
};

done_testing();
