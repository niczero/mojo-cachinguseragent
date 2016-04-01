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

plan skip_all => 'set TEST_ACCESS to enable this test' unless $ENV{TEST_ACCESS};

my $dir = tempdir CLEANUP => 1;
my $ua = Mojo::CachingUserAgent->new(
  cache_dir => '/tmp/x',
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
  ok $dom = $ua->dom_from_get($url, 'geonames code adminCode1')->text, 'got value';
  is $dom, 'ENG', 'expected value';
};

$url = 'https://demo-api.ig.com/gateway/deal/session';
subtest q{head_from_post} => sub {
  my $head;
  ok $head = $ua->head_from_post($url, {
    'Content-Type' => 'application/json;charset=UTF-8',
    Accept => 'application/json;charset=UTF-8',
    'X-IG-API-KEY' => '5FA056D2706634F2B7C6FC66FE17517B',
    Version => 2
  }, json => {
    identifier => 'A12345',
    password => '112233'
  }), 'got something';
  ok $head->cache_control, 'got value';
  is $head->cache_control, 'no-cache, no-store', 'expected value';
};

done_testing();
