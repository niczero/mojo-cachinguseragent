# ============
# utf8.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Temp;
use Mojo::CachingUserAgent;
use Mojo::Log;

plan skip_all => 'set TEST_ONLINE for online tests' unless $ENV{TEST_ONLINE};

my $tmpdir  = File::Temp->newdir('testXXXXXX');
my $tmpfile = File::Temp->new('testXXXXXX');

my $config = {
  cache     => ''. $tmpdir,
  log       => ''. $tmpfile,
  url       => 'http://httpbin.org/encoding/utf8',
  useragent => 'Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36'
    .' (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36'
};

my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $config->{cache},
  log => Mojo::Log->new(path => $config->{log}),
  name => $config->{useragent},
  on_error => sub { die $_[1] }
);

subtest q{body_from_get} => sub {
  ok my $r = $ua->body_from_get($config->{url}), 'got something';
  like $r, qr/\N{U+226A}/, 'much less than';
  like $r, qr/\N{U+2200}\N{U+0078}\N{U+2208}\N{U+211D}/, 'for all x in R';

  ok $r = $ua->body_from_get($config->{url}), 'got something from cache';
  like $r, qr/\N{U+226A}/, 'much less than from cache';
  like $r, qr/\N{U+2200}\N{U+0078}\N{U+2208}\N{U+211D}/,
      'for all x in R from cache';
};

done_testing();
