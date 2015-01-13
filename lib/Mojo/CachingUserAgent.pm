package Mojo::CachingUserAgent;
use Mojo::Base 'Mojo::UserAgent';

our $VERSION = 0.002;

use File::Spec::Functions 'catfile';
use MIME::Base64 'encode_base64url';
use Mojo::Util qw(slurp spurt);

# Attributes

has cache_dir => sub {};
has chain_referer => 0;
has cookie_dir => sub {};
has log => sub { Mojo::Log->new };
has 'name';
has on_error => sub { my $self = shift; sub { die shift->{message} } };
has 'referer';

# Public methods

sub new {
  my ($proto, %param) = @_;
  my $name = delete $param{name};
  my $self = shift->SUPER::new(max_redirects => 3, inactivity_timeout => 30,
      %param);
  $self->transactor->name($self->{name} = $name) if defined $name;
  return $self;
}

sub get_body {
  my ($self, $url) = (shift, shift);
  my $headers = (ref $_[0] eq 'HASH') ? shift : {};
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  my $cache_dir = $self->cache_dir;
  my $cache = $cache_dir ? catfile $cache_dir, encode_base64url $url : undef;
  if ($cache and -f $cache) {
    # Use cache
    $self->log->debug("Fetching page $url from cache");
    return slurp $cache;
  }

  $headers->{Referer} = $self->{referer} if $self->referer;
  my $tx = $self->start($self->build_tx('GET', $url, $headers), $cb);
  if (my $err = $tx->error) {
    $self->log->info("Fetching page $url");
    $self->log->error(sprintf 'Failure for %s\nGot response %u: %s',
        $url, @$err{'advice', 'message'});
    $self->on_error->($err);
  }
  my $body = $tx->res->body;
  spurt $body => $cache if $cache;
  $self->referer($url) if $self->chain_referer;
  return $body;
}

sub get_dom {
  my $dom = Mojo::DOM->new(shift->get_body);
  return @_ ? $dom->at(shift) : $dom;
}

sub get_json { decode_json(shift->get_body) }

1;
__END__

=head1 NAME

Mojo::CachingUserAgent - Caching user agent

=head1 SYNOPSIS

  use Mojo::CachingUserAgent;
  $ua = Mojo::CachingUserAgent->new(cache_dir => '/var/tmp');
  $json = $ua->get_json('http://example.com/digest');
  $html = $ua->get_body('http://example.com/index');
  $footer = $ua->get_dom('http://example.com/index')->at('div#footer')->content;

  $ua = Mojo::CachingUserAgent->new(
    cache_dir => '/var/tmp',
    chain_referer => 1,
    log => $my_log,
    name => 'Scraperbot/1.0 (+http://myspace.com/inquisitor)',
    referer => 'http://www.example.com/frontpage.html',
    on_error => sub { die shift->{message} }
  );

=head1 DESCRIPTION

A modest extension of L<Mojo::UserAgent> with convenience wrapper methods around
the 'GET' method.  The extended object makes it easier to (a) set a C<Referer>
URL, (b) set an agent 'type' name, and (c) cache results.  When using
C<Referer>, calls to C<get> can either (a1) use a common Referer or (a2) use the
URL of the previous C<get>.

=head1 USAGE


=head1 ATTRIBUTES

All attributes return the invocant when used as setters, so are chainable.

  $ua->cache_dir('/tmp')->cookie_dir('/home/me/.cookies')->...

Attributes are typically defined at creation time.

  $ua = Mojo::CachingUserAgent->new(cache_dir => '/tmp', ...);

=head2 cache_dir

  $ua->cache_dir('/var/tmp');
  $dir = $ua->cache_dir;

  $ua = Mojo::CachingUserAgent->new(cache_dir => '/var/tmp', ...);

The directory in which to cache page bodies.  The filenames are filesystem-safe
base64 (ie using C<-> and C<_>).  Currently there is no means to uncache or
expire these files, other than deleting them yourself, making the mechanism more
useful when prototyping rather than in production.  If this attribute is left
undefined, no caching takes place.  The cache is based on the entire URL, taking
it literally as a string, so if URL attributes change or appear in a different
order, a separate file is cached.

=head2 chain_referer

  $ua = Mojo::CachingUserAgent->new(chain_referer => 1, ...);
  
Whether each URL fetched should become the C<Referer> [sic] of the subsequent
fetch.  Defaults to false, meaning any original referrer defined will be the
C<Referer> of all subsequent fetches.

=head2 cookie_dir

  $ua->cookie_dir($home->rel_dir('data/cookies'));
  $dir = $ua->cookie_dir;

Where to store cookies between invocations.  If left undefined, cookies are lost
between invocations.

=head2 log

  $ua->log($app->log);
  $log = $ua->log;

  $ua = Mojo::CachingUserAgent->new(log => $app->log, ...);
  $ua->log->warn('Logs are filling up!');

A Mojo-compatible (eg Mojar::Log) log object.  Allows you to have the useragent
use the same log as the owning application.

=head2 name

  $ua->name("Scraperbot/$VERSION (+http://my.contact/details.html)");
  $masquerading_as = $ua->name;

The L<useragent
name|http://en.wikipedia.org/wiki/User_agent#User_agent_identification> to
include in the request headers.

=head2 on_error

  $ua->on_error(sub { die shift->{message} });
  $ua->on_error(sub { 'ignore errors' });
  say 'covered' if ref $ua->on_error eq 'CODE';

=head2 referer

  $ua->referer($previous_url);

The URL to include in the headers to denote the referring web page.  [Note that
in the context of web headers, referrer is (mis)spelled C<referer>.]

=head1 SEE ALSO

L<Mojo::UserAgent>, the parent class which provides the majority of
documentation and functionality.
