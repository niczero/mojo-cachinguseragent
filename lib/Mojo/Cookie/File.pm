package Mojo::Cookie::File;
use Mojo::Base -base;

our $VERSION = 0.001;

use Carp 'croak';
use Mojo::Cookie::Response;
use Mojo::Util qw(decode encode slurp spurt);
use POSIX 'strftime';
use Scalar::Util 'blessed';

has jar => sub { croak 'Need to define cookie jar' };
has file => sub { croak 'Need to define cookie file' };

sub load {
  my ($self, $domain, $file) = @_;
  croak 'No path from which to load' unless $file ||= $self->file;
  croak "Cannot read cookie file ($file)" unless -r $file;
  my $content = decode 'UTF-8', slurp $file;
  my $jar = $self->jar;
  defined($_ = $self->parse($_)) and $jar->add($_) for $content =~ /^.*$/mg;
  undef $content;
  return $self;
}

sub save {
  my ($self, $jar, $file) = @_;
  return undef unless $jar ||= $self->jar and blessed $jar;
  croak 'No path to which to save' unless $file ||= $self->file;

  my $content = sprintf "# Cookies saved by %s, %s\n#\n",
      __PACKAGE__, strftime '%Y-%m-%d %H:%M', localtime;
  defined($_ = $self->format($_)) and $content .= $_ for @{$jar->all};

  spurt encode('UTF-8', $content) => $file;
  undef $content;
  return $self;
}

sub parse {
  my ($self, $text) = @_;
  return undef unless length($text //= '') and $text !~ /^#/;

  my ($origin, $all, $path, $secure, $expires, $name, $value) =
    $text =~ /^(\S+)\s+([A-Z]+)\s+(\S+)\s+([A-Z]+)\s+(\d+)\s+(\S+)\s+(.*)/;
  croak "Unrecognised cookie line:\n($text)" unless $name;

  return Mojo::Cookie::Response->new(
    all_machines => $all eq 'TRUE',
    domain       => ($origin //= '') =~ s/^\.//r,
    expires      => $expires,
    name         => $name,
    origin       => $origin,
    path         => $path,
    secure       => $secure eq 'TRUE',
    value        => $value
  );
}

sub format {
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

1;
__END__

=head1 NAME

Mojo::Cookie::File - Read and write cookie files

=head1 SYNOPSIS

  # With UserAgent
  my $agent = Mojo::UserAgent->new;
  my $cookie_file = Mojo::Cookie::File->new(
    jar  => $agent->cookie_jar,
    file => '/tmp/cookies.txt'
  );
  $cookie_file->load;
  $tx = $agent->post(...);
  $tx = $agent->get(...);
  $cookie_file->save;

  # ...or with CachingUserAgent
  my $agent = Mojo::CachingUserAgent->new(cookie_file => '/tmp/cookies.txt');
  $agent->load_cookies;
  $head = $agent->head_from_post(...);
  $body = $agent->body_from_get(...);
  $agent->save_cookies;

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
