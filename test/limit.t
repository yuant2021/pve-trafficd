#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::TrafficD::Limit;

my $plan = \&PVE::TrafficD::Limit::plan;

subtest 'apply' => sub {
    is_deeply(
        $plan->({}, 1, 1, 1, undef),
        { limited => 1, 'orig-rate' => undef, applied => 1, set => 1, rate => 1 },
        'unlimited NIC gets the limit rate, nothing to restore later',
    );
    is_deeply(
        $plan->({}, 1, 1, 1, 12.5),
        { limited => 1, 'orig-rate' => 12.5, applied => 1, set => 1, rate => 1 },
        'original rate remembered',
    );
    is_deeply(
        $plan->({}, 1, 1, 1, 0.5),
        { limited => 1, 'orig-rate' => 0.5, applied => 0.5 },
        'a slower NIC is not made faster',
    );
    is_deeply(
        $plan->({}, 1, 1, 1, 0),
        { limited => 1, 'orig-rate' => 0, applied => 1, set => 1, rate => 1 },
        'rate 0 means unlimited',
    );
    is_deeply(
        $plan->({}, 1, 2, 0, undef),
        { limited => 1, 'orig-rate' => undef, applied => 2 },
        'guest without the NIC (being re-created): state only',
    );
};

subtest 'keep in place' => sub {
    my $nic = { limited => 1, 'orig-rate' => 12.5, applied => 1 };
    is_deeply(
        $plan->($nic, 1, 1, 1, 1),
        { limited => 1, 'orig-rate' => 12.5, applied => 1 },
        'nothing to do',
    );
    is_deeply(
        $plan->($nic, 1, 1, 1, undef),
        { limited => 1, 'orig-rate' => undef, applied => 1, set => 1, rate => 1 },
        'guest re-created without rate: limit again, new original',
    );
    is_deeply(
        $plan->($nic, 1, 1, 1, 50),
        { limited => 1, 'orig-rate' => 50, applied => 1, set => 1, rate => 1 },
        'rate edited while limited: becomes the original',
    );
    is_deeply(
        $plan->($nic, 1, 3, 1, 1),
        { limited => 1, 'orig-rate' => 12.5, applied => 3, set => 1, rate => 3 },
        'limit rate changed, original kept',
    );
    is_deeply(
        $plan->($nic, 1, 1, 0, undef),
        { limited => 1, 'orig-rate' => 12.5, applied => 1 },
        'NIC gone for now: state kept',
    );
};

subtest 'lift' => sub {
    is_deeply(
        $plan->({ limited => 1, 'orig-rate' => 12.5, applied => 1 }, 0, 1, 1, 1),
        { limited => 0, set => 1, rate => 12.5 },
        'original rate restored',
    );
    is_deeply(
        $plan->({ limited => 1, applied => 1 }, 0, 1, 1, 1),
        { limited => 0, set => 1, rate => undef },
        'rate removed when there was none',
    );
    is_deeply(
        $plan->({ limited => 1, 'orig-rate' => 12.5, applied => 1 }, 0, 1, 1, 40),
        { limited => 0 },
        'rate changed meanwhile: left alone',
    );
    is_deeply($plan->({}, 0, 1, 1, 7), { limited => 0 }, 'not limited, nothing to do');
};

ok(PVE::TrafficD::Limit::rate_eq(1, 1.0), 'rate equality');
ok(!PVE::TrafficD::Limit::rate_eq(undef, 0), 'no rate differs from rate 0');

done_testing();
