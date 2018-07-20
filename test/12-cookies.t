# ============
# cookies.t
# ============
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use File::Spec::Functions 'catfile';
use File::Temp 'tempfile';
use MIME::Base64 'encode_base64url';
use Mojo::CachingUserAgent;
use Mojo::Cookie::File;
use Mojo::File 'path';
use Mojo::Log;
use Mojo::Server::Daemon;
use Mojo::Util qw(b64_decode decode dumper);

# App
use Mojolicious::Lite;
app->log->level('fatal');

get 'x' => sub {
  my $c = shift;
  $c->session(x => 'citrus');
  $c->render(text => 'selected')
};
# end of App

# Server
my $loop = Mojo::IOLoop->singleton;
my $daemon = Mojo::Server::Daemon->new(
  app    => app,
  ioloop => $loop,
  silent => 1
);
$daemon->listen(['http://127.0.0.1'])->start;
my $port = Mojo::IOLoop->acceptor($daemon->acceptors->[0])->port;

# Tester
my $t = Test::Mojo->new(app);

# Client
my (undef, $cookiefile) = tempfile CLEANUP => 1;
my (undef, $logfile) = tempfile CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cookie_file => $cookiefile,
  ioloop    => $loop,
  log       => Mojo::Log->new(path => $logfile),
  on_error  => sub {}
);

# Quick test of the server for the sake of sanity...
subtest q{App} => sub {
  $t->reset_session;
  $t->get_ok('/x')->status_is(200)->content_is('selected', 'right content');
  ok my $cookie = $t->ua->cookie_jar->find($t->ua->server->url->path('/'))->[0],
      'found session cookie';
  my $payload = (split /--/, $cookie->value, 2)[0];
  is $t->app->sessions->deserialize->(b64_decode $payload)->{x}, 'citrus',
      'right value';
};

# ...then on to the client
my $url = "http://127.0.0.1:$port/x";

subtest q{Jar} => sub {
  ok my $content = $ua->body_from_get($url), 'got something';
  is $content, 'selected', 'right content';

  ok my $cookie = $ua->cookie_jar->find($ua->server->url->path('/'))->[0],
      'found session cookie';
  my $payload = (split /--/, $cookie->value, 2)[0];
  is app->sessions->deserialize->(b64_decode $payload)->{x}, 'citrus',
      'right value';
};

subtest q{Save} => sub {
  ok $ua->save_cookies, 'saved something';
  ok -f $cookiefile, 'cookie file exists';
  ok -s $cookiefile, 'cookie file has content';
  ok my $content = decode 'UTF-8', path($cookiefile)->slurp,
      'got cookie content';
  ok $content =~ /^(127\.0\.0\.1.*)$/m, 'right line';
  ok my $cookie = Mojo::Cookie::File->parse($1), 'materialised cookie';
  my $payload = (split /--/, $cookie->value, 2)[0];
  is app->sessions->deserialize->(b64_decode $payload)->{x}, 'citrus',
      'right value';
};

done_testing();
