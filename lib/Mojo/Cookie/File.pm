package Mojo::Cookie::File;
use Mojo::Base -base;

our $VERSION = 0.011;

use Carp 'croak';
use Mojo::Cookie::Response;
use Mojo::File 'path';
use Mojo::Util qw(decode encode);
use POSIX 'strftime';
use Scalar::Util 'blessed';

has jar => sub { croak 'Need to define cookie jar' };
has file => sub { croak 'Need to define cookie file' };

sub format {
  my ($self, $cookie) = @_;
  return undef unless blessed $cookie;
  return sprintf "%s\t%s\t%s\t%s\t%u\t%s\t%s\n",
      $cookie->domain,
      $cookie->host_only ? 'FALSE' : 'TRUE',
      $cookie->path // '/',
      $cookie->secure ? 'TRUE' : 'FALSE',
      $cookie->expires // 0,
      $cookie->name,
      $cookie->value;
}

sub load {
  my ($self, $file, $pattern) = @_;
  croak 'No path from which to load' unless $file ||= $self->file;
  croak "Cannot read cookie file ($file)" unless -r "$file";

  my $content = decode 'UTF-8', path($file)->slurp;
  my $jar = $self->jar;
  $pattern = qr/$pattern/ if defined $pattern and not ref $pattern;
  defined($_ = $self->parse($_, $pattern)) and $jar->add($_)
    for $content =~ /^.*$/mg;
  return $self;
}

sub parse {
  my ($self, $text, $pattern) = @_;
  return undef unless length($text //= '') and $text !~ /^#/;

  my ($domain, $all, $path, $secure, $expires, $name, $value) =
    $text =~ /^(\S*)\t([A-Z]+)\t(\S+)\t([A-Z]+)\t(\d+)\t(\S+)\s*(.*)/;
  croak "Unrecognised cookie line:\n($text)" unless defined $name;

  return
    if defined($pattern) and (ref $pattern ne 'Regexp' or $domain !~ $pattern);

  return Mojo::Cookie::Response->new(
    domain       => $domain,
    expires      => $expires,
    host_only    => $all ne 'TRUE',
    name         => $name,
    path         => $path,
    secure       => $secure eq 'TRUE',
    value        => $value
  );
}

sub save {
  my ($self, $file, $pattern) = @_;
  croak 'No path to which to save' unless $file ||= $self->file;
  $pattern //= qr/\S/;

  my $content = sprintf "# HTTP Cookie File\n# Cookies saved by %s, %s\n#\n",
      __PACKAGE__, strftime '%Y-%m-%d %H:%M', localtime;
  $_->domain =~ $pattern and $_ = $self->format($_) and $content .= $_
    for @{$self->jar->all};

  path($file)->spurt(encode 'UTF-8', $content);
  undef $content;
  return $self;
}

1;
__END__

=head1 NAME

Mojo::Cookie::File - Read and write cookie files

=head1 SYNOPSIS

  my $cookie_file = Mojo::Cookie::File->new(
    jar  => $agent->cookie_jar,
    file => '/tmp/cookies.txt'
  );
  $cookie_file->load;
  $tx = $agent->post(...);
  $tx = $agent->get(...);
  $cookie_file->save;

  # ...or with CachingUserAgent
  $agent->load_cookies;
  $head = $agent->head_from_post(...);
  $body = $agent->body_from_get(...);
  $agent->save_cookies;

=head1 DESCRIPTION

Persist cookies to a 'Netscape-style' cookie file.

=head1 ATTRIBUTES

All attributes return the invocant when used as setters, so are chainable.

  $mcf->file('/tmp/cookies2.txt')
    ->load

Attributes are typically defined at creation time.

  $mcf = Mojo::Cookie::File->new(file => '/tmp/cookies.txt', jar => ...)

=head2 file

Path to the cookie file.  Can be absolute or relative.

=head2 jar

  $mcf->jar($ua->cookie_jar)

A L<Mojo::UserAgent::CookieJar>.

=head1 METHODS

=head2 format

  $line = $mcf->format($cookie)

Returns a stringified cookie, constituting a cookie file line.

=head2 load

  $mcf->load
  $mcf->load($filename)
  $mcf->load($filename, qr/yahoo/)

Load cookies from either a specified file or the configured file.  If a pattern
is supplied, only cookies having a matching domain are loaded.

=head2 parse

  $cookie = $mcf->parse($line)
  $cookie = $mcf->parse($line, qr/microsoft/)

Returns a L<Mojo::Cookie::Response> from the cookie file line.  Returns false if
a pattern is supplied and the cookie domain does not match.

=head2 save

  $mcf->save
  $mcf->save($filename)
  $mcf->save($filename, qr/yahoo/)

Save cookies to either the specified file or the configured file.  If a pattern
is supplied, only cookies having a matching domain are saved.

=head1 SEE ALSO

L<Mojo::UserAgent::CookieJar::Role::Persistent> has since been created.
