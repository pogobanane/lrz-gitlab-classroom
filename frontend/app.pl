#!/usr/bin/env perl
use feature ':5.32';
use strict;
use utf8;
use warnings;

our $VERSION = 2023.0120;

use Carp;
use DBD::SQLite::Constants ':dbd_sqlite_string_mode';
use Digest;
use Mojo::JSON;
use Mojo::JWT;
use Mojo::SQLite;
use Mojo::URL;
use Mojo::Util;
use Mojolicious::Lite -signatures;
use Prometheus::Tiny;
use Scalar::Util;
use File::Spec;

my $GITLAB_HOSTNAME    = Mojo::URL->new('https://gitlab.lrz.de')->to_abs;
my $TUMONLINE_HOSTNAME = Mojo::URL->new('https://campus.tum.de')->to_abs;
my $TUMONLINE_USER_INFO =
  Mojo::URL->new('/tumonline/!co_loc_wsoa2user.userinfo')
  ->base($TUMONLINE_HOSTNAME)->to_abs;
my $TUMONLINE_USER_COURSES =
  Mojo::URL->new('/tumonline/!co_loc_wsoa2user.courses')
  ->base($TUMONLINE_HOSTNAME)->to_abs;

helper 'jwt' =>
  sub ($c) { Mojo::JWT->new( 'secret' => $c->app->secrets->[0] ); };
helper 'sqlite' => sub ($c) {
    state $sql = Mojo::SQLite->new->from_filename(
        Mojo::File->new(
            $ENV{STATE_DIRECTORY}
              // croak 'No STATE_DIRECTORY defined (man 5 systemd.exec)'
        )->child('mojo.db')->to_abs->to_string,
        {
            'sqlite_string_mode' => DBD_SQLITE_STRING_MODE_UNICODE_STRICT,
            'wal_mode'           => 1,
        }
    );
};
helper 'mocked'           => sub { state $mocked = $ENV{CI} && 'mocked'; };
helper 'get_oauth2_state' => sub ($c) {
    $c->b( $c->mocked ? 0 : $c->req->request_id )->md5_sum()->to_string;
};
helper 'prometheus' =>
  sub ($c) { state $prometheus = Prometheus::Tiny->new(); };

plugin 'Config' => {
    'default' => {
        'tumonline'    => $TUMONLINE_HOSTNAME,
        'gitlab'       => $GITLAB_HOSTNAME,
        'gitlab_scope' => (
            $ENV{GITLAB_OAUTH_SCOPE}
              // croak 'Missing GitLab OAuth2 client scope'
        )
    }
};
plugin 'OAuth2' => {
    'gitlab' => {
        'key' => (
            $ENV{GITLAB_OAUTH_CLIENT_ID}
              // croak 'Missing GitLab OAuth2 client ID'
        ),
        'secret' => (
            $ENV{GITLAB_OAUTH_CLIENT_SECRET}
              // croak 'Missing GitLab OAuth2 client secret'
        ),
        'authorize_url' => Mojo::URL->new('/oauth/authorize?response_type=code')
          ->base($GITLAB_HOSTNAME)->to_abs->to_string,
        'token_url' => Mojo::URL->new('/oauth/token')->base($GITLAB_HOSTNAME)
          ->to_abs->to_string,
    },
    'tumonline' => {
        'key' => (
            $ENV{TUMONLINE_OAUTH_CLIENT_ID}
              // croak 'Missing TUMonline OAuth2 client ID'
        ),
        'secret' => (
            $ENV{TUMONLINE_OAUTH_CLIENT_SECRET}
              // croak 'Missing TUMonline OAuth2 client secret'
        ),
        'authorize_url' =>
          Mojo::URL->new('/tumonline/wbOAuth2.authorize?response_type=code')
          ->base($TUMONLINE_HOSTNAME)->to_abs->to_string,
        'token_url' => Mojo::URL->new('/tumonline/wbOAuth2.token')
          ->base($TUMONLINE_HOSTNAME)->to_abs->to_string,
    },
};

post '/link' => sub ($c) {

    # build JWT-based link from request data
    my $r = $c->req->json;
    croak 'Invalid request; cannot to parse it as JSON.' unless ($r);
    $r->{url} =
      $c->req->url->to_abs->path('/t/')->path( $c->jwt->claims($r)->encode );
    return $c->render( 'json' => $r );
};

get '/t/*jwt' => sub ($c) {

    # XXX override user-facing exception message with something generic
    $c->session( 'exception' => 'Please double check the link.' );

    # try to decode JWT
    my $jwt = $c->jwt->decode( $c->stash->{jwt} );
    $c->session( 'j' => $c->stash->{jwt} );    # XXX JWT, for later
    $c->session( 'c' => $jwt->{c} );           # XXX cohort/semester
    $c->session( 'l' => $jwt->{l} );           # XXX TUMonline pStpSpNr
    $c->session( 'm' => $jwt->{m} )
      if exists $jwt->{m};                     # XXX matrikel number, if present
    $c->stash( 'check_matrikel' => exists $jwt->{m} );
    undef( $c->session->{exception} );
  },
  'confirm_intention';
post '/t/*jwt' => sub ($c) {

    return $c->reply->exception('CSRF token error, please try again')
      ->rendered(403)    ## no critic 'ProhibitMagicNumbers'
      if $c->validation->csrf_protect->has_error('csrf_token');

    my $next_oauth2 = '/oauth/tumonline';

    if (   exists $c->session->{m}
        && exists $c->jwt->decode( $c->session->{j} )->{m} )
    {
        $next_oauth2 = '/oauth/gitlab';

        # check request data matches JWT/session data
        $c->validation->required('matrikel')->in( $c->session->{m} );
        return $c->reply->exception->rendered(
            404)    ## no critic 'ProhibitMagicNumbers'
          if $c->validation->has_error;
    }

    $c->app->log->context('[/t/*jwt]')
      ->debug( 'Redirecting to: ' . $next_oauth2 );
    return $c->redirect_to($next_oauth2);
};

get '/oauth/tumonline' => sub ($c) {
    my $tx = $c->render_later->tx;
    $c->session( 's' => $c->session->{s} // $c->get_oauth2_state() );
    return $c->oauth2->get_token_p(
        $c->mocked || 'tumonline' => {
            'scope' => 'GET@loc.user.studentnumber GET@loc.user.courses-query',
            'redirect_uri' =>
              $c->url_for('/oauth/tumonline')->userinfo(undef)->to_abs,
        }
    )->then(
        sub ($response) {
            return $c->reply->exception('Invalid response. Please try again.')
              ->rendered(400)    ## no critic 'ProhibitMagicNumbers'
              unless defined $response;

            $c->app->log->context('[/oauth/tumonline]')
              ->debug('Got OAuth2 response from TUMonline');

            delete( $c->session->{s} );
            $c->app->log->context('[/oauth/tumonline]')
              ->debug( 'TUMonline login successful: '
                  . Mojo::JSON::encode_json($response) );
            return Mojo::Promise->all(

                # validate student is participant in course
                $c->ua->get_p(
                    $TUMONLINE_USER_COURSES->query(
                        'pSemesterId' => $c->session->{c},
                        'pStpSpNr'    => $c->session->{l},
                    ) => {
                        'Authorization' => 'Bearer ' . $response->{access_token}
                    }
                )->then(
                    sub ($tx) {
                        $c->app->log->context('[/oauth/tumonline]')
                          ->debug( 'Got TUMonline course info: '
                              . Mojo::JSON::encode_json( $tx->res->json ) );
                        $c->app->log->context('[/oauth/tumonline]')
                          ->error( 'Got TUMonline course info with error: '
                              . Mojo::JSON::encode_json( $tx->res->json ) )
                          if ( ref( $tx->res->json ) eq 'HASH'
                            && exists( $tx->res->json->{error} ) );
                        die 'Unexpected TUMonline response.'
                          . 'If the error persist, contact lecturers, please.'
                          . "\n"
                          unless ( ref( $tx->res->json ) eq 'ARRAY' );
                        my $head = shift @{ $tx->res->json };
                        die 'Not enrolled in the course, '
                          . 'please register in TUMonline.' . "\n"
                          unless ( ($ENV{IGNORE_ENROLLMENT_CHECK} // '') eq '1' || $head && $head->{angemeldet_flag} eq 'J' );
                        return;
                    },
                    sub ($reason) {
                        $c->app->log->context('[/oauth/tumonline]')
                          ->error( 'TUMonline API request failed: ' . $reason );
                        $c->reply->exception(
                            'TUMonline access error: ' . $reason );
                        return;
                    }
                ),

                # get student matrikel number
                $c->ua->get_p(
                    $TUMONLINE_USER_INFO => {
                        'Authorization' => 'Bearer ' . $response->{access_token}
                    }
                )->then(
                    sub ($tx) {
                        $c->app->log->context('[/oauth/tumonline]')
                          ->debug( 'Got TUMonline user info: '
                              . Mojo::JSON::encode_json( $tx->res->json ) );
                        die 'Unknown matrikel number.' . "\n"
                          unless $tx->res->json->{student_number};
                        $c->session( 'm' => $tx->res->json->{student_number} );
                    },
                    sub ($reason) {
                        $c->app->log->context('[/oauth/tumonline]')
                          ->error( 'TUMonline API request failed: ' . $reason );
                        $c->reply->exception(
                            'TUMonline access error: ' . $reason );
                        return;
                    }
                )
            )->then(
                sub (@results) {
                    $c->app->log->context('[/oauth/tumonline]')
                      ->debug('Matrikel matched, redirecting to GitLab');
                    $c->redirect_to('/oauth/gitlab');
                    return;
                },
                sub ($reason) {
                    $c->app->log->context('[/oauth/tumonline]')
                      ->error( 'TUMonline API request failed: ' . $reason );
                    $c->reply->exception(
                        'TUMonline access error: ' . $reason );
                    return;
                }
            );
        },
        sub ($reason) {
            $c->app->log->context('[/oauth/tumonline]')
              ->error( 'TUMonline OAuth failed: ' . $reason );
            $c->reply->exception(
                'Unable to authenticate with TUMonline. Please try again.');
            return;
        }
    )->catch(
        sub ($exception) {
            {
                # avoid "Transaction already destroyed", see FAQ
                ## no critic 'ProhibitNoWarnings'
                no warnings 'void';
                $tx;
            }
            $c->app->log->context('[/oauth/tumonline]')
              ->error( 'TUMonline login failed: ' . $exception );
            $c->reply->exception($exception);
            return;
        }
    );
};

get '/oauth/gitlab' => sub ($c) {
    my $tx = $c->render_later->tx;
    $c->session( 's' => $c->session->{s} // $c->get_oauth2_state() );
    return $c->oauth2->get_token_p(
        $c->mocked || 'gitlab' => {
            'scope'        => $c->config('gitlab_scope'),
            'redirect_uri' =>
              $c->url_for('/oauth/gitlab')->userinfo(undef)->to_abs,
            'state' => $c->session->{s},
        }
    )->then(
        sub ($response) {
            return $c->reply->exception('Invalid response. Please try again.')
              ->rendered(400)    ## no critic 'ProhibitMagicNumbers'
              unless defined $response;

            $c->app->log->context('[/oauth/gitlab]')
              ->debug('Got OAuth2 response from GitLab');
            die                  ## no critic 'RequireCarping'
              'Invalid OAuth2 state. Please try again.'
              unless defined $c->param('state');
            $c->app->log->context('[/oauth/gitlab]')
              ->debug( 'Comparing OAuth2 response: '
                  . $c->param('state') . ' and '
                  . $c->session->{s} );

            die                  ## no critic 'RequireCarping'
              'Invalid OAuth2 state value. Please try again.'
              unless $c->param('state') eq $c->session->{s};
            delete( $c->session->{s} );
            $c->app->log->context('[/oauth/gitlab]')
              ->debug( 'GitLab login successful: '
                  . Mojo::JSON::encode_json($response) );
            $c->session( 'a' => $response->{access_token} );
            $c->redirect_to('/ack');
            return;
        },
        sub ($reason) {
            $c->app->log->context('[/oauth/gitlab]')
              ->error( 'GitLab OAuth failed: ' . $reason );
            $c->reply->exception(
                'Unable to authenticate with GitLab. Please try again.');
            return;
        }
    )->catch(
        sub ($exception) {
            {
                # avoid "Transaction already destroyed", see FAQ
                ## no critic 'ProhibitNoWarnings'
                no warnings 'void';
                $tx;
            }
            $c->app->log->context('[/oauth/gitlab]')
              ->error( 'GitLab login failed: ' . $exception );
            $c->reply->exception($exception);
            return;
        }
    );
};

get '/ack' => sub ($c) {
    if ( !$c->session->{j} ) {
        $c->app->log->context('[/ack]')->error('No token found in session');
        return $c->reply->exception('Please double check the link.')
          ->rendered(404);    ## no critic 'ProhibitMagicNumbers'
    }
    $c->app->log->context('[/ack]')->debug('Session has JWT');

    # XXX override user-facing exception message with something generic
    $c->session(
        'exception' => 'Unable to schedule request. Please retry later.' );
    my $jwt = Mojo::JSON::encode_json( $c->jwt->decode( $c->session->{j} ) );
    $c->app->log->context('[/ack]')->debug( 'JWT decoded: ' . $jwt );
    my $sql = $c->sqlite->db->insert(
        'requests',
        {
            'matrikel'            => $c->session->{m},
            'gitlab_access_token' => $c->session->{a},
            'jwt'                 => $jwt,
        },
    );
    $c->app->log->context('[/ack]')->debug('Request queued');
    undef( $c->session->{exception} );
    $c->session( 'expires' => 1 );    # delete session
    return $c->render('request_received');
  },
  'request_received';

get '/metrics' =>
  sub ($c) { return $c->render( 'text' => $c->prometheus->format ); };

get '/s/style.css'    => sub ($c) { return $c->reply->static('style.css'); };
get '/s/tum_logo.svg' => sub ($c) { return $c->reply->static('tum_logo.svg'); };
get '/bootstrap/css/bootstrap.min.css' => sub ($c) { return $c->reply->static('bootstrap.min.css'); };

get '/gdpr' => sub ($c) { return $c->render('gdpr'); };

get '/courses' => sub ($c) {
    my $courses_file = Mojo::File->new(
        $ENV{STATE_DIRECTORY}
          // croak 'No STATE_DIRECTORY defined'
    )->child('courses.json');
    return $c->reply->exception('Courses not configured')->rendered(404)
      unless -f $courses_file;

    my $courses = Mojo::JSON::decode_json( $courses_file->slurp );
    $c->stash( 'courses' => $courses );
    return $c->render('courses');
};

get '/' => sub ($c) { return $c->render('landing'); };

app->hook(    # security headers
    'before_dispatch' => sub ($c) {
        $c->res->headers->header('X-Frame-Options' => 'DENY');
        $c->res->headers->header('Content-Security-Policy' => "frame-ancestors 'none'; object-src 'none'; script-src 'none'");
    }
);
app->hook(    # declare metrics
    'before_server_start' => sub ( $server, $app ) {
        $app->prometheus->declare(
            'mojo_http_response_code_for_method',
            'help' => 'Counter of HTTP response code by request method.',
            'type' => 'counter',
        );

        # from prometheus-alertmanager_0.23.0-4/cmd/alertmanager/main.go
        $app->prometheus->declare(
            'mojo_http_request_duration_seconds',
            'help'    => 'Histogram of latencies for HTTP requests.',
            'type'    => 'histogram',
            'buckets' => [    ## no critic 'ProhibitMagicNumbers'
                0.0005, 0.001, 0.0025, 0.005, 0.0075, 0.01, 0.02, 0.05, 0.1,
            ],
        );

        # ensure db file gets created on start
        my $undef_request = {
            'matrikel'            => q{},
            'gitlab_access_token' => q{},
            'jwt'                 => q{},
        };
        $app->sqlite->db->insert( 'requests', $undef_request, );
        $app->sqlite->db->delete( 'requests', $undef_request, );
    }
);
app->hook(    # update metrics after requests
    'after_dispatch' => sub ($c) {
        $c->prometheus->inc(
            'mojo_http_response_code_for_method',
            {
                'method' => $c->req->method,
                'code'   => $c->res->code
            }
        );

        # from Mojolicious::Controller::rendered
        $c->prometheus->histogram_observe( 'mojo_http_request_duration_seconds',
            $c->helpers->timing->elapsed('mojo.timer') // 0 );
    }
);

app->secrets(
    [
        $ENV{SECRET}
          // Digest->new('SHA-512')->add(Mojo::Util::steady_time)->hexdigest()
    ]
);
app->sqlite->auto_migrate(1)->migrations->from_data;
app->sessions->cookie_name('c');
app->sessions->samesite('Lax');
app->sessions->secure(1);
app->renderer->paths( [ $ENV{'TEMPLATE_PATH'} ] ) if $ENV{'TEMPLATE_PATH'};
app->static->paths( [ File::Spec->catfile( $ENV{'TEMPLATE_PATH'}, 'static' ) ] )
  if $ENV{'TEMPLATE_PATH'};
app->log->short( exists $ENV{'INVOCATION_ID'} );
app->start;
__DATA__
@@ migrations
-- 1 up
CREATE TABLE requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  matrikel TEXT NOT NULL,
  gitlab_access_token TEXT NOT NULL,
  jwt TEXT NOT NULL
 );
-- 1 down
DROP TABLE requests;

@@ exception.html.ep
% layout 'default';
% title 'Error';
<div class="alert alert-danger w-50">
	Something went wrong:
	<em>
	% if (my $csfr_token_validation_error = validation->error('csrf_token')) {
		There was an issue with the provided CSRF token.
	% } elsif (my $matrikel_validation_error = validation->error('matrikel')) {
		%= 'Matrikel number is required.' if $matrikel_validation_error->[0] eq 'required'
		%= 'Matrikel number mismatch.' if $matrikel_validation_error->[0] eq 'in'
	% } elsif (my $message = session 'exception') {
		<%= $message %>
	% } elsif (defined Scalar::Util::blessed($exception)) {
		<%= $exception->message %>
	% } else {
		Make sure you granted this service access.
		Should the error persist, please contact your lecturer.
	% }
	</em>
</div>

@@ confirm_intention.html.ep
% layout 'default';
% title 'Welcome';
%= form_for 'tjwt' => ( 'alt' => 'confirm intention' ) => begin
    %= csrf_field
    % if (stash 'check_matrikel') {
        %= text_field 'matrikel', ('id' => 'matrikel', 'class' => 'form-control mb-4', 'placeholder' => 'Personal Identifier', 'autofocus' => 'autofocus')
    % }
    %= submit_button 'Start' => ('class' => 'btn btn-lg btn-outline-primary w-100')
% end
<p class="text-muted fw-light">
Use this service to associate your <a class="text-reset" href="<%= config('tumonline') %>">TUMonline</a> and <a class="text-reset" href="<%= config('gitlab') %>">LRZ GitLab</a> accounts.
For example, to enable your lecturer to grant your LRZ GitLab account access to restricted resources.
To associate accounts, this service requires limited access to them.
Hence, after starting, you will be asked, for each account, to grant this service access.
If you have additional question, please contact your lecturer.
Otherwise, press above button to start.
</p>


@@ request_received.html.ep
% layout 'default';
% title 'Thank you';
<p class="lead">
The request has been received and will be processed soon.
</p>

@@ layouts/default.html.ep
<!doctype html>
<html lang="en">
	<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<link href="/bootstrap/css/bootstrap.min.css" rel="stylesheet" crossorigin="anonymous">
		<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>␖</text></svg>">
		<title><%= title %></title>
	</head>
	<body role="main" class="container">
	    <main class="d-sm-flex flex-column justify-content-center align-items-center min-vh-100 gap-3">
    	<h1 class="h3">Associate TUMonline and LRZ GitLab Accounts</h1>
		<%= content %>
		</main>
	</body>
</html>
