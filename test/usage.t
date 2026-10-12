#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::TrafficD::Usage;

subtest 'merge' => sub {
    my $dst = {
        100 => {
            net0 => { reset => '1000.000001', in => 10, out => 50 },
            net1 => { reset => '2000.000000', in => 5, out => 5 },
        },
    };
    my $src = {
        100 => {
            net0 => { reset => '1000.000001', in => 20, out => 30 }, # same period
            net1 => { reset => '1500.000000', in => 99, out => 99 }, # older period
            net2 => { reset => '3000.5', in => 1, out => 2 }, # new entry
            net3 => { reset => 'x', in => 1, out => 2 }, # invalid
        },
        101 => { net0 => { reset => '4000.000002', in => 7, out => 8 } },
        abc => { net0 => { reset => '1', in => 1, out => 1 } },
    };
    PVE::TrafficD::Usage::merge_max($dst, $src);

    is_deeply(
        $dst,
        {
            100 => {
                net0 => { reset => '1000.000001', in => 20, out => 50 },
                net1 => { reset => '2000.000000', in => 5, out => 5 },
                net2 => { reset => '3000.5', in => 1, out => 2 },
            },
            101 => { net0 => { reset => '4000.000002', in => 7, out => 8 } },
        },
        'larger counter of a period wins, older periods and invalid entries ignored',
    );

    PVE::TrafficD::Usage::merge_max($dst, { 100 => { net0 => { reset => '1000.000002', in => 1, out => 1 } } });
    is_deeply(
        $dst->{100}->{net0},
        { reset => '1000.000002', in => 1, out => 1 },
        'newer period replaces (microseconds)',
    );
};

subtest 'totals over nodes' => sub {
    my $by_node = {
        pve1 => { 100 => { net0 => { reset => '1.1', in => 10, out => 1 } } },
        pve2 => { 100 => { net0 => { reset => '1.1', in => 5, out => 2 } } },
        pve3 => { 100 => { net0 => { reset => '0.9', in => 1000, out => 1000 } } }, # before a reset
        pve4 => { 101 => { net0 => { reset => '1.1', in => 1000, out => 1000 } } },
    };
    is_deeply([PVE::TrafficD::Usage::nic_total($by_node, 100, 'net0', '1.1')], [15, 3], 'sum');
    is_deeply([PVE::TrafficD::Usage::nic_total($by_node, 100, 'net1', '1.1')], [0, 0], 'none');
    is_deeply([PVE::TrafficD::Usage::nic_total($by_node, 100, 'net0', undef)], [0, 0], 'no period');
};

subtest 'period order' => sub {
    ok(PVE::TrafficD::Usage::token_newer('1000.000010', '1000.000009'), 'microseconds');
    ok(PVE::TrafficD::Usage::token_newer('1001', '1000.999999'), 'seconds');
    ok(PVE::TrafficD::Usage::token_newer('1000.5', '1000.000005'), 'fraction, not integer');
    ok(!PVE::TrafficD::Usage::token_newer('1000.5', '1000.5'), 'equal');
};

done_testing();
