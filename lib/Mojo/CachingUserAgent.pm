package Mojo::CachingUserAgent;
use Mojo::UserAgent -base;

our $VERSION = 0.211;

use 5.014;  # For MIME::Base64::encode_base64url
use File::Spec::Functions 'catfile';
use MIME::Base64 'encode_base64url';
use Mojo::Cookie::File;
use Mojo::File 'path';
use Mojo::IOLoop;
use Mojo::JSON 'from_json';
use Mojo::JSON::Pointer;
use Mojo::Log;
use Mojo::Util qw(decode);

# Attributes

has 'cache_dir';  # Default to no caching
has caching => 'full';  # Only comes into play if cache_dir defined
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
  $self->load_cookies if $self->{cookie_file} and -r ''. $self->{cookie_file};
  return $self;
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

  my $want_raw;  # whether to provide unencoded content
  $method = $$method and ++$want_raw if ref $method eq 'SCALAR';

  my $cache_dir = $self->cache_dir;
  my $cache = $cache_dir ? catfile $cache_dir, encode_base64url($method . $url)
      : undef;
  my $log = $self->log;

  if ($cache and -f $cache) {
    # Use cache
    $log->debug("Using cached $url");
    my $body = path($cache)->slurp;
    $body = decode 'UTF-8', $body unless $want_raw;
    return $cb ? Mojo::IOLoop->next_tick(sub { $self->$cb(undef, $body) })
        : $body;
  }
  # Not using cache => fetch

  $headers->{Referer} ||= ''. $self->referer if $self->referer;

  $log->debug("Requesting $method $url");
  my $tx = $self->build_tx($method, $url, $headers, @_);

  # blocking
  unless ($cb) {
    $tx = $self->start($tx);
    return undef if $self->_handle_error($tx, $url);
    my $body = $tx->res->body;

    path($cache)->spurt($body) if $cache and $tx->res->code == 200;
    $self->referer($tx->req->url) if $self->chain_referer;
    $body = decode 'UTF-8', $body unless $want_raw;
    return $body;
  }

  # non-blocking
  $self->start($tx, sub {
    my ($ua, $tx_) = @_;
    my ($error, $body);
    unless ($error = $self->_handle_error($tx_, $url)) {
      $body = $tx_->res->body;
      path($cache)->spurt($body)
        if $cache and $tx_->res->code == 200;
      $self->referer($tx_->req->url) if $self->chain_referer;
      # ^interesting race condition when concurrent
      $body = decode 'UTF-8', $body unless $want_raw;
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $body, $tx_) });
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
    my $head = Mojo::Headers->new->parse(path($cache)->slurp);
    return $cb ? Mojo::IOLoop->next_tick(sub { $self->$cb(undef, $head) })
        : $head;
  }
  # Not using cache => fetch

  $headers->{Referer} ||= ''. $self->referer if $self->referer;

  $log->debug("Requesting HEAD $url");
  my $tx = $self->build_tx(uc($method), $url, $headers, @_);

  # blocking
  unless ($cb) {
    $tx = $self->start($tx);
    my $error = $self->_handle_error($tx, $url);
    my $head = $tx->res->headers;
    return $head if $error;

    path($cache)->spurt($head->to_string ."\n")
      if $cache and $tx->res->code == 200;
    $self->referer($tx->req->url) if $self->chain_referer;
    return $head;
  }

  # non-blocking
  $self->start($tx, sub {
    my ($ua, $tx_) = @_;
    my ($error, $head);
    unless ($error = $self->_handle_error($tx_, $url)) {
      $head = $tx_->res->headers;
      path($cache)->spurt($head->to_string ."\n")
        if $cache and $tx_->res->code == 200;
      $self->referer($tx_->req->url) if $self->chain_referer;
      # ^interesting race condition when concurrent
    }
    Mojo::IOLoop->next_tick(sub { $self->$cb($error, $head, $tx_) });
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
    my ($ua, $error, $body, $tx_) = @_;
    my $dom;
    unless ($error) {
      $dom = Mojo::DOM->new($body);
      $dom = $dom->at($selector) if $selector;
    }
    Mojo::IOLoop->next_tick(sub { $ua->$cb($error, $dom, $tx_) });
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
    my $json = from_json($body);
    return $pointer ? Mojo::JSON::Pointer->new($json)->get($pointer) : $json;
  }

  # non-blocking
  $self->body_from($method, @args, sub {
    my ($ua, $error, $body, $tx_) = @_;
    my $json;
    unless ($error) {
      eval {
        $json = from_json($body);
        $json = Mojo::JSON::Pointer->new($json)->get($pointer) if $pointer;
      }
      or do {
        my $error = $@;
        my $url = eval { $tx_->req->url->to_abs } || 'something';
        ($error //= '') .= sprintf 'Failed to de-json %s (%s)', $url, $error;
      };
    }
    Mojo::IOLoop->next_tick(sub { $ua->$cb($error, $json, $tx_) });
  });
  return undef;
}

sub load_cookies {
  my ($self, $domain) = @_;
  Mojo::Cookie::File->new(jar => $self->cookie_jar)
    ->load($self->cookie_file, $domain);
  return $self;
}

sub save_cookies {
  my ($self) = @_;
  Mojo::Cookie::File->new(jar => $self->cookie_jar, file => $self->cookie_file)
    ->save;
  return $self;
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
    name => 'Scraperbot/1.0 (+http://myspace.com/inquisitor)',
    cache_dir => '/var/tmp/cache',
    cookie_file => '/tmp/cookies.txt',
    log => $my_log,
    referer => 'http://www.example.com/frontpage.html',
    chain_referer => 1,
    on_error => sub { $_[0]->log->error($_[1]), die $_[1] }
  );

=head1 DESCRIPTION

An extension of L<Mojo::UserAgent> with convenience wrapper methods around 'GET'
and friends.  The extended object makes it easier to (a) set a C<Referer> URL,
(b) set an agent 'brand' name, and (c) cache results.  When using C<Referer>,
calls can either (a1) use a common Referer or (a2) use the URL of the previous
invocation.

Note that the underlying methods (L<get|Mojo::UserAgent/get>, etc) are left
untouched and therefore are available to be used as you would expect according
to L<Mojo::UserAgent>.  (Any user agent string that has been set will be
utilised even for transactions using underlying methods.  On the other hand,
Referer is ignored when using underlying methods.)

Despite its name, it can be a very useful subclass even if you leave caching
disabled.

=head1 USAGE

This module is aimed at code that wants either C<body>, C<dom>, C<json>, or
C<head> from a page, but not a combination for the same page (otherwise you are
better using the parent module L<Mojo::UserAgent> directly, or at least its
methods).  If you have a reason for calling the pure methods (C<get> et al) or
C<build_tx>, you still can because this subclass makes no change to those calls.

The first decision to make is whether to use cache.  There are several options:

=over 4

=item * No cache

This mode caches nothing.  All your transactions are 'online', so you are
probably using this package because your transactions are simple and you like
the convenience and readability.  This is the default, so all you do is...
erm... never define C<cache_dir>.

  Mojo::CachingUserAgent->new(...)  # cache_dir is undefined

=item * Full (dumb) cache

This mode caches absolutely every response, so only makes sense when
prototyping, and brings the developer two benefits: (a) you avoid upsetting the
source server while you work out how to navigate a complex DOM, XML, or JSON
response, and (b) once you have fetched all responses you can go offline and
continue your development (eg on an underground train or moon shuttle).

All you do is assign a (writeable) filesystem path via C<cache_dir> (and leave
C<caching> at its default level of 2).  If you are using this as a substitute
cache till you implement a real one, you could have an approximation to page
expiry, eg via cron or L<Minion>.

  Mojo::CachingUserAgent->new(cache_dir => ...)  # caching level stays at 2

=item * Partial cache

This is marked EXPERIMENTAL; it remains to be seen whether it results in less
or more confusion.  It is the option closest to what people will expect when
they see 'CachingUserAgent', so if nothing else, this option helps highlight why
full cache (above) is not a real HTTP cache.

This mode caches GET responses that are flagged as cacheable.  You set a
C<cache_dir> and also set C<caching> to 1 (instead of its default level, 2).  In
this mode the cache is only used for {body,dom,json}_from_get and only for those
responses not flagged in their headers as 'no-store'.  (The content for all
foo_from_bar methods is still stored, allowing you to examine structures and
perhaps switch C<caching> to level 2 later and go offline.  For these
transactions it is acting like a log and not like a cache for content reuse.)

  Mojo::CachingUserAgent->new(caching => 1, cache_dir => ...)

You still need to take care of expiry yourself, and there is (currently) not any
support for max-age, no-cache, nor ETag.

=item * On-off

Whatever level C<caching> is set to, you can override it per-request.  This lets
you deviate from your chosen mode either temporarily or for particular requests.
For example, select the 'No cache' option, but override to cache one response
that you need to debug.  Or for example, select the 'Full cache' option, but
override to exclude authentication transactions.

=item * Separate agents

Sometimes there is a clear separation between what you want to reuse and what
must be fetched 'live', and if the flows are separate then the simplest option
could be to use separate agents.  Take care if they are sharing a cookie file;
there is no support (currently) for checking whether something else has updated
the file.

=back

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
results.  One solution is to use multiple agents in that situation.

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

  $ua->load_cookies
  $ua->load_cookies(qr/google/)
  $ua->load_cookies('google.com')

Load cookies from the configured cookie file.  Optionally provide a pattern for
filtering against the cookie domain.

=head2 save_cookies

  $ua->save_cookies

Save cookies to the configured cookie file, replacing the previous content.

=head1 CAVEATS

The caching functionality makes little sense in a production tier.  (Without
caching it provides useful simplicity to any tier.)

There is nothing built-in to prevent you filling up your disk space.

There is no handling of max-age, no-cache, nor ETag.

Take care if relying on Referer chaining or shared cookie file for concurrent
requests.

If caching is used, the contents are stored clear text.  (Perhaps a future
release will support pluggable serialisation, but the priority is helping
developers, not performance.)

There is currently no consideration given to people subclassing this subclass;
that will improve.

=head1 COPYRIGHT AND LICENCE

Copyright (C) 2014--2020, Nic Sandfield.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojo::UserAgent>, the parent class which provides the majority of
documentation and functionality.
