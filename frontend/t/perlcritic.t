#!/usr/bin/env perl
use v5.36;    # Debian bookworm

use strict;
use utf8;
use warnings;

use English qw(-no_match_vars);

eval {
    require Test::Perl::Critic;    # libtest-perl-critic-perl/bookworm 1.04-2
    Test::Perl::Critic->import(-verbose => 11);
};

if ($EVAL_ERROR) {
    my $msg = 'Test::Perl::Critic required to criticise code';
    plan( skip_all => $msg );
}

Test::Perl::Critic::all_critic_ok(qw(app.pl));
