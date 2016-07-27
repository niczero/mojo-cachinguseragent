package Mojo::CachingUserAgent;
use Mojo::Base 'Mojo::UserAgent';
use 5.014;

our $VERSION = 0.051;

use Carp 'croak';
use File::Spec::Functions 'catfile';
use MIME::Base64 'encode_base64url';
use Mojo::IOLoop;
use Mojo::JSON 'decode_json';
use Mojo::JSON::Pointer;
use Mojo::Log;
use Mojo::Util qw(decode encode slurp spurt);
use POSIX 'strftime';
use Scalar::Util 'blessed';

# Attributes

has 'cache_dir';
has chain_referer => 0;
has 'cookie_file';
has log => sub { Mojo::Log->new };
sub name {
  my $self = shift;
  return $self->transactor->name unless @_;
  $self->transactor->name(shift);
}
has on_error => sub { sub {
  my ($ua, $loop, $msg) = @_; $ua->log->error($msg);
} };
has 'referer';

# Public methods

sub new {
  my ($proto, %param) = @_;
  my $self = shift->SUPER::new(max_redirects => 3, inactivity_timeout => 30,
      %param);
  $self->name(delete $self->{name}) if exists $self->{name};
  $self->load_cookies if $self->{cookie_file};
  return $self;
}

sub load_cookies {
  my ($self, $domain) = @_;
  croak 'No path from which to load' unless my $file = $self->cookie_file;
  croak "Cannot read cookie file ($file)" unless -r $file;
  my $content = decode 'UTF-8', slurp $file;
  $self->import_cookies(\$content, $domain);
}

sub save_cookies {
  my ($self) = @_;
  croak 'No path to which to save' unless my $file = $self->cookie_file;
  croak "Cannot write cookie file ($file)" unless -w $file;
  spurt encode('UTF-8', ${$self->export_cookies($self->cookie_jar->all)})
      => $file;
  return $self;
}

sub import_cookies {
  my ($self, $content, $domain) = @_;
  croak 'Missing content ref' unless ref $content;
  my $jar = $self->cookie_jar;
  defined($_ = $self->parse_cookie($_)) and $jar->add($_)
    for $$content =~ /^.*$/mg;
  return $self;
}

sub export_cookies {
  my ($self, $cookies) = @_;
  my $content = sprintf "# Cookies saved by Mojo::CachingUserAgent, %s\n#\n",
      strftime '%Y-%m-%d %H:%M', localtime;
  defined($_ = $self->format_cookie($_)) and $content .= $_ for @$cookies;
  return \$content;
}

sub parse_cookie {
  my ($self, $text) = @_;
  $text //= '';
  return undef unless length $text and $text !~ /^#/;

  my ($origin, $all, $path, $secure, $expires, $name, $value) =
    $text =~ /^(\S+)\s+([A-Z]+)\s+(\S+)\s+([A-Z]+)\s+(\d+)\s+(\S+)\s+(.*)/;
  croak "Unrecognised cookie line:\n($text)" unless $name;

  return Mojo::Cookie::Response->new(
    domain => ($origin //= '') =~ s/^\.//r,
    origin => $origin,
    all_machines => $all eq 'TRUE',
    path => $path,
    secure => $secure eq 'TRUE',
    expires => $expires,
    name => $name,
    value => $value
  );
}

sub format_cookie {
  my ($self, $cookie) = @_;
  return undef unless blessed $cookie;
  my $origin = $cookie->origin // $cookie->domain or return "\n";
  return sprintf "%s\t%s\t%s\t%s\t%u\t%s\t%s\n",
      $origin,
      $cookie->{all_machines} // ($origin =~ /^\./) ? 'TRUE' : 'FALSE',
      $cookie->path // '/',
      $cookie->secure ? 'TRUE' : 'FALSE',
      $cookie->expires // 0,
      $cookie->name,
      $cookie->value;
}

sub get_body       { shift->body_from('GET', @_) }  # legacy, deprecated
sub body_from_get  { shift->body_from('GET', @_) }
sub body_from_post { shift->body_from('POST', @_) }

sub get_dom        { shift->dom_from('GET', @_) }  # legacy, deprecated
sub dom_from_get   { shift->dom_from('GET', @_) }
sub dom_from_post  { shift->dom_from('POST', @_) }

sub get_json       { shift->json_from('GET', @_) }  # legacy, deprecated
sub json_from_get  { shift->json_from('GET', @_) }
sub json_from_post { shift->json_from('POST', @_) }

sub head_from_get  { shift->head_from('GET', @_) }
sub head_from_post { shift->head_from('POST', @_) }

sub head_from_head { shift->head_from('HEAD', @_) }

sub body_from {
  my ($self, $method, $url) = (shift, shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $headers = (ref $_[0] eq 'HASH') ? shift : {};

  my $cache_dir = $self->cache_dir;
  my $cache = $cache_dir ? catfile $cache_dir, encode_base64url($method . $url)
      : undef;
  my $log = $self->log;

  if ($cache and -f $cache) {
    # Use cache
    $log->debug("Using cached $url");
    my $body = decode 'UTF-8', slurp $cache;
    return $cb ? Mojo::IOLoop->next_tick(sub { $self->$cb(undef, $body) })
        : $body;
  }
  # Not using cache => fetch

  $headers->{Referer} = $self->referer
    if not exists $headers->{Referer} and $self->referer;

  $log->debug("Fetching $url");
  my $tx = $self->build_tx(uc($method), $url, $headers, @_);

  # blocking
  unless ($cb) {
    $tx = $self->start($tx);
    return undef if $self->_handle_error($tx, $url);
    my $body = $tx->res->body;

    spurt encode('UTF-8', $body) => $cache if $cache;
    $self->referer($url) if $self->chain_referer;
    return $body;
  }

  # non-blocking
  $self->start($tx, sub {
    my ($ua, $tx_) = @_;
    my ($error, $body);
    unless ($error = $self->_handle_error($tx_, $url)) {
      $body = $tx_->res->body;
      spurt encode('UTF-8', $body) => $cache if $cache;
      $self->referer($url) if $self->chain_referer;
      # ^interesting race condition when concurrent
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $body) });
  });
  return undef;
}

sub head_from {
  my ($self, $method, $url) = (shift, shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $headers = (ref $_[0] eq 'HASH') ? shift : {};

  my $cache_dir = $self->cache_dir;
  my $cache = $cache_dir
      ? catfile $cache_dir, encode_base64url($url .':HEAD') : undef;
  my $log = $self->log;

  if ($cache and -f $cache) {
    # Use cache
    $log->debug("Using cached $url");
    my $head = Mojo::Headers->new->parse(decode 'UTF-8', slurp $cache);
    return $cb ? Mojo::IOLoop->next_tick(sub { $self->$cb(undef, $head) })
        : $head;
  }
  # Not using cache => fetch

  $headers->{Referer} = $self->referer
    if not exists $headers->{Referer} and $self->referer;

  $log->debug("Fetching head $url");
  my $tx = $self->build_tx(uc($method), $url, $headers, @_);

  # blocking
  unless ($cb) {
    $tx = $self->start($tx);
    my $error = $self->_handle_error($tx, $url);
    my $head = $tx->res->headers;
    return $head if $error;

    spurt encode('UTF-8', $head->to_string ."\n") => $cache if $cache;
    $self->referer($url) if $self->chain_referer;
    return $head;
  }

  # non-blocking
  $self->start($tx, sub {
    my ($ua, $tx_) = @_;
    my ($error, $head);
    unless ($error = $self->_handle_error($tx_, $url)) {
      $head = $tx_->res->headers;
      spurt encode('UTF-8', $head->to_string ."\n") => $cache if $cache;
      $self->referer($url) if $self->chain_referer;
      # ^interesting race condition when concurrent
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $head) });
  });
  return undef;
}

sub dom_from {
  my ($self, $method) = (shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $selector = @_ >= 2 && ! ref $_[-1] ? pop : undef;
  my @args = @_;

  # blocking
  unless ($cb) {
    my $body = $self->body_from($method, @args) or return undef;
    my $dom = Mojo::DOM->new($body);
    return $selector ? $dom->at($selector) : $dom;
  }

  # non-blocking
  $self->body_from($method, @args, sub {
    my ($ua, $error, $body) = @_;
    my $dom;
    unless ($error) {
      $dom = Mojo::DOM->new($body);
      $dom = $dom->at($selector) if $selector;
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $dom) });
  });
  return undef;
}

sub json_from {
  my ($self, $method) = (shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $pointer = @_ >= 2 && ! ref $_[-1] ? pop : undef;
  my @args = @_;

  # blocking
  unless ($cb) {
    my $body = $self->body_from($method, @args) or return undef;
    my $json = decode_json($body);
    return $pointer ? Mojo::JSON::Pointer->new($json)->get($pointer) : $json;
  }

  # non-blocking
  $self->body_from($method, @args, sub {
    my ($ua, $error, $body) = @_;
    my $json;
    unless ($error) {
      $json = decode_json($body);
      $json = Mojo::JSON::Pointer->new($json)->get($pointer) if $pointer;
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $json) });
  });
  return undef;
}

sub _handle_error {
  my ($self, $tx, $url) = @_;
  if (my $err = $tx->error) {
    my $message = sprintf 'Failure for %s; Got %u: %s',
        $url, ($err->{code} || 418), $err->{message};
    my $err_cb = $self->on_error;
    Mojo::IOLoop->next_tick(sub { $self->$err_cb(shift, $message) }) if $err_cb;
    return $message;
  }
}

#TODO: Extend 'get'
#TODO: Only cache 'GET'

1;
__END__

=head1 NAME

Mojo::CachingUserAgent - Caching user agent

=head1 SYNOPSIS

  use Mojo::CachingUserAgent;
  $agent  = Mojo::CachingUserAgent->new(cache_dir => '/var/tmp/mycache');
  $author = $agent->json_from_get('http://example.com/digest', '/author/0');
  $html   = $agent->body_from_get('http://example.com/index');
  $footer = $agent->dom_from_get(...)->at('div#footer')->to_string;
  $auth   = $agent->head_from_post('https://api.example.com/session', json => {
    username => 'me',
    token => '98tb/3+s2.001'
  });

  $agent = Mojo::CachingUserAgent->new(
    cache_dir => '/var/tmp/cache',
    cookie_file => '/var/tmp/cookies.txt',
    chain_referer => 1,
    log => $my_log,
    name => 'Scraperbot/1.0 (+http://myspace.com/inquisitor)',
    referer => 'http://www.example.com/frontpage.html',
    on_error => sub { die $_[1] }
  );

=head1 DESCRIPTION

A modest extension of L<Mojo::UserAgent> with convenience wrapper methods around
'GET' and friends.  The extended object makes it easier to (a) set a C<Referer>
URL, (b) set an agent 'type' name, and (c) cache results.  When using
C<Referer>, calls can either (a1) use a common Referer or (a2) use the URL of
the previous invocation.

Note that the L<get|Mojo::UserAgent/get> method itself is left untouched.

=head1 USAGE

This module is for developers who want either C<body>, C<dom>, C<json>, or
C<head> from a page, but not a combination; otherwise you are better using the
parent module L<Mojo::UserAgent>.  If you have a reason for calling the pure
methods (C<get> et al) or C<build_tx>, you still can, but this module makes no
change to those calls.

This module will happily use its cache (if set) whenever it can.  If you want
some cached and some not cached, create a separate instance without a
C<cache_dir> defined.  (Only 'GET' requests use the cache, of course.)

The usage dictates a boringly simple approach: if caching is enabled and the URL
is in the cache, return the cached content (head or body).  When checking the
URL, query params are taken into account, but headers are not.  You can think of
it like wget with --no-clobber.

If you want a proper (managed) cache, look at L<Mojo::Cache> or the L<CHI>
module.  If you want proper http caching (eg respecting validity periods and
no-cache) then look elsewhere.  If you are looking for something to mock an API
for unit testing, again this module won't satisfy those needs; for example it
cannot play back failure cases.

=head2 Rapid Prototyping

The main use case is the rapid development of website clients.  Setting a
C<cache_dir> means each page is downloaded at most once while you code.

=head2 Fill-or-kill

Sometimes you don't care about handling the transaction; you just want a part of
a web page, or an error.

=head2 Web Scraping

If you are scraping a static site, no sense to download a page more than once.
Be polite and set a meaningful C<name>.  Unfortunately the module doesn't
currently help you respect 'bot' directives.

=head2 Concurrent Requests

Like its big brother, the agent supports asynchronous calls via callbacks.  If
running multiple concurrent requests via the same agent, be aware that the
'referer' is global to the agent so using C<chain_referer> could lead to strange
results.  If you need C<chain_referer> it is usually best to create enough
agents as your concurrency demands.

=head2 Blocking Requests

Like its big brother, the agent also supports synchronous calls.  This case
usually works best if you define an C<on_error> callback that dies, so that you
can catch the exception (unless you want to ignore errors of course).

=head1 ATTRIBUTES

All attributes return the invocant when used as setters, so are chainable.

  $agent->cache_dir('/tmp')->cookie_file('/home/me/.cookies.txt')->...

Attributes are typically defined at creation time.

  $agent = Mojo::CachingUserAgent->new(cache_dir => '/tmp', ...);

=head2 cache_dir

  $agent->cache_dir('/var/tmp');
  $dir = $agent->cache_dir;

  $agent = Mojo::CachingUserAgent->new(cache_dir => '/var/tmp', ...);

The directory in which to cache pages.  The filenames are filesystem-safe base64
(ie using C<-> and C<_>) of the URL.  If this attribute is left undefined, no
caching is done by that agent.  The cache is based on the entire URL (as a
literal string) so if URL attributes change or appear in a different order, a
separate file is cached.

The job of removing old pages from the cache is left to you.  Currently there is
no plan to implement any inspection of page headers to control caching; caching
is all-or-nothing.

=head2 chain_referer

  $agent = Mojo::CachingUserAgent->new(chain_referer => 1, ...);
  
Whether each URL fetched should become the C<Referer> [sic] of the subsequent
fetch.  Defaults to false, meaning any original referrer defined will be the
C<Referer> of all subsequent fetches.

=head2 cookie_file

  $agent->cookie_file($home->rel_file('data/cookies.txt'));
  $filename = $agent->cookie_file;

Where to store cookies between invocations.  If left undefined, cookies are
discarded between runs.

=head2 log

  $agent->log($app->log);
  $log = $agent->log;

  $agent = Mojo::CachingUserAgent->new(log => $app->log, ...);
  $agent->log->warn('Logs are filling up!');

A Mojo-compatible (eg Mojar::Log) log object.  Allows you to have the useragent
use the same log as the owning application.  If you don't want logging, set a
very high log level

  $agent->log(Mojo::Log->new(level => 'fatal'));

or even set a blackhole as destination.

  $agent->log(Mojo::Log->new(path => '/dev/null', level => 'fatal'));

=head2 name

  $agent->name("Scraperbot/$VERSION (+http://my.contact/details.html)");
  $masquerading_as = $agent->name;

The L<useragent
name|http://en.wikipedia.org/wiki/User_agent#User_agent_identification> to
include in the request headers.

=head2 on_error

  $agent->on_error(sub { die $_[1] });
  $agent->on_error(sub { 'ignore errors' });

The action(s) to take when a 'GET' fails (ie status is not 200).  The default
action is to log the error.

=head2 referer

  $agent->referer($previous_url);

The URL to include in the headers to denote the referring web page.  [Note that
in the context of web headers, referrer is (mis)spelled C<referer>.]  If
C<chain_referer> is true, this value will be updated upon each successful
retrieval within that agent.

=head1 METHODS

=head2 body_from_get

  $body = $agent->body_from_get('http://mojolicio.us');
  $body = $agent->body_from_get('http://ab.ie/x2', {Referer => 'http://ab.ie'},
      sub { my ($agent, $error, $body) = @_; ... });

Return the result body from a 'GET' request.  The hashref of headers to use in
the request is optional, as is the callback for asynchronous use.  Uses the
agent's cache if one has been set up.

=head2 dom_from_get

  $dom = $agent->dom_from_get('http://perl.com');
  $dom = $agent->dom_from_get('http://perl.com', '#index');
  $dom = $agent->dom_from_get('http://perl.com', $headers, '#index', sub {
    my ($agent, $error, $dom) = @_;
  });

Return page DOM (see L<Mojo::DOM>) from a 'GET' request.  The hashref of headers
to use in the request is optional, as are the CSS selector and the callback (for
asynchronous use).  If a selector is given, it returns the DOM from the first
found match, otherwise C<undef>.  In the case of retrieval failure, C<$error> is
the resulting message.  Uses the agent's cache if one has been set up.

If both C<$error> and C<$dom> are undefined, it means the agent succeeded in
retrieving nothing, most likely due to a selector not matching anything.

=head2 json_from_get

  $json = $agent->json_from_get('http://httpbin.org/ip');
  $json = $agent->json_from_get('http://httpbin.org/ip', '/origin');
  $json = $agent->json_from_get('http://httpbin.org/ip', $headers, '/origin',
      sub { my ($agent, $error, $json) = @_; ... });

Return JSON (see L<Mojo::JSON>) from a 'GET' request.  The hashref of headers to
use in the request is optional, as are the JSON pointer and the callback (for
asynchronous use).  If a pointer is given, it returns the JSON structure
matching that path, otherwise C<undef>.  Uses the agent's cache if one has been
set up.

If both C<$error> and C<$json> are undefined, it means the agent succeeded in
retrieving nothing, most likely due to a pointer not matching anything.

=head2 body_from_post

=head2 dom_from_post

=head2 json_from_post

=head2 head_from_head

=head2 load_cookies

=head2 save_cookies

=head1 SEE ALSO

L<Mojo::UserAgent>, the parent class which provides the majority of
documentation and functionality.
