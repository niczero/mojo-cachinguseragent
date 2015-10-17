use Mojo::Base -strict;
use Test::More;

use_ok 'Mojo::CachingUserAgent';
diag sprintf 'Testing Mojo::CachingUserAgent %s, Perl %s, %s',
    $Mojo::CachingUserAgent::VERSION, $], $^X;

done_testing();
