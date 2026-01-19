use Mojo::Base -strict;
use Mojo::File qw(curfile);
use Test::Mojo;
use Test::More;

## no critic 'ProhibitMagicNumbers'

my $jwt =
'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJjIjowLCJsIjoxfQ.XxsWmzeBzK3vAER4xc4ghNSgrxUbLqiwxj87i7Vs-_g';
my $state    = 'cfcd208495d565ef66e7dff9f98764da';
my $matrikel = 'external';
my $t        = Test::Mojo->new( curfile->dirname->sibling('app.pl') );
$t->app->sessions->secure(0);    # XXX tests do not use HTTPS

# mock OAuth2 provider
$t->app->plugin( 'OAuth2' => { 'mocked' => { 'key' => 42 } } );

# create a new link
$t->post_ok( '/link', 'json' => { 'c' => 0, 'l' => 1 } )->status_is(200)
  ->json_like( '/url' => qr{http:\/\/.+\/$jwt} );

# test generated link
$t->get_ok( '/t/' . $jwt )->status_is(200)->content_like(qr/<!doctype html>/i);

$t->post_ok(
    '/t/'
      . $jwt => 'form' => {
        'csrf_token' =>
          $t->ua->get( '/t/' . $jwt )->res->dom->at('[name=csrf_token]')->val
      }
)->status_is(302)->header_is( 'location' => '/oauth/tumonline' );


$t->get_ok('/oauth/tumonline')->status_is(302)
  ->header_like( 'location' =>
      qr{\/mocked\/oauth\/authorize\?client_id=42&redirect_uri=.*}
  );

$t->get_ok( '/oauth/tumonline?code=fake' );

# TODO mocked OAuth2 provider does not honor _parse_args overwrite
# TODO calls TUMonline API (if it succeeds )
#->status_is(302)->header_is( 'location' => '/oauth/gitlab' );

$t->get_ok('/oauth/gitlab')->status_is(302)
  ->header_like( 'location' =>
      qr{\/mocked\/oauth\/authorize\?client_id=42&redirect_uri=.*&state=$state}
  );

$t->get_ok( '/oauth/gitlab?code=fake&state=' . $state );

# TODO mocked OAuth2 provider does not honor _parse_args overwrite
#->status_is(302)->header_is( 'location' => '/ack' );

$t->app->routes->get(
    '/pretend-to-have-valid-session' => sub {
        $_[0]->session( 'm' => $matrikel, 'a' => 'fake' );
        return $_[0]->render( 'text' => 'OK' );
    }
);
$t->get_ok('/pretend-to-have-valid-session')->status_is(200)->content_is('OK');

$t->get_ok('/ack')->status_is(200)->content_like(qr/<!doctype html>/i);

$t->get_ok('/metrics')->status_is(200)->content_like(qr/# HELP/i);

done_testing();
