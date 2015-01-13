use Mojo::Base -strict;
use Test::More;

use_ok 'Mojo::CachingUserAgent';
diag "Testing Mojo::CachingUserAgent $Mojo::CachingUserAgent::VERSION, Perl $],
$^X";

done_testing();
