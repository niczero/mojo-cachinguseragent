# ============
# apis.t
# ============
use Mojo::Base -strict;
use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Mojo::CachingUserAgent;
use Mojo::Log;
use Mojo::Util 'dumper';

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

my $dir = tempdir CLEANUP => 1, EXLOCK => 0;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => $dir,
  on_error => sub {},
  log => Mojo::Log->new(path => catfile $dir, 'test.log')
);

my $url = 'http://api.geonames.org/citiesJSON'
    .'?north=44.1&south=-9.9&east=-22.4&west=55.2&lang=de&username=demo';
subtest q{head_from_head} => sub {
  my $head;
  ok $head = $ua->head_from_head($url), 'got something';
  is $head->content_type, 'application/json;charset=UTF-8', 'expected header';
};

subtest q{json_from_get} => sub {
  my $json;
  ok $json = $ua->json_from_get($url), 'got something';
  ok $json = $ua->json_from_get($url, '/geonames/0/toponymName'), 'got value';
};

$url = 'http://api.geonames.org/postalCodeLookupJSON?postalcode=LS42DD&country=GB&username=demo';
subtest q{json_from_get} => sub {
  my $json;
  ok $json = $ua->json_from_get($url), 'got something';
  ok $json = $ua->json_from_get($url, '/postalcodes/0/placeName'), 'got value';
  is $json, 'Kirkstall Ward', 'expected value';
};

$url = 'http://api.geonames.org/postalCodeSearch?postalcode=LS42DD&country=GB&username=demo';
subtest q{dom_from_get} => sub {
  my $dom;
  ok $dom = $ua->dom_from_get($url), 'got something';
  $dom = $ua->dom_from_get($url, 'geonames code adminCode1');
  if ($dom) {
    ok $dom, 'got value';
    is $dom->text, 'ENG', 'expected value';
  }
  else {
    ok $dom = $ua->dom_from_get($url, 'geonames status'), 'got error value';
    like $dom->{message}, qr/^the (?:daily|hourly) limit /, 'expected value';
  }
};

$url = 'http://api.metacpan.org/v0/author/NICZERO';
subtest q{head_from_get} => sub {
  my $head;
  ok $head = $ua->head_from_get($url, {
    'Content-Type' => 'application/json; charset=UTF-8',
    Accept => 'application/json; charset=UTF-8'
  }), 'got something';
  ok $head->server, 'got value';
  like $head->server, qr/^nginx/, 'expected value'
    or diag dumper $head;
};

done_testing();
