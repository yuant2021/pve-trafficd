#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::TrafficD::Config;

my $GiB = 1024**3;

subtest 'sizes' => sub {
    my $parse = \&PVE::TrafficD::Config::parse_size;
    is($parse->('1099511627776'), 1024**4, 'plain bytes');
    is($parse->('500G'), 500 * $GiB, 'G is binary, like PVE disk sizes');
    is($parse->('1.5TiB'), 1.5 * 1024**4, 'TiB');
    is($parse->('2Ti'), 2 * 1024**4, 'Ti');
    is($parse->('1TB'), 10**12, 'TB is decimal');
    is($parse->('100 gb'), 100 * 10**9, 'case and blank');
    is($parse->('0'), 0, 'zero');
    for my $bad ('', '1X', '-1G', '1.G', 'G', '1 G B', '9000P') {
        eval { $parse->($bad) };
        ok($@, "'$bad' rejected");
    }
};

subtest 'NIC property string' => sub {
    my $nic = PVE::TrafficD::Config::parse_nic(
        'quota=1073741824,rate=01.50,direction=max,last-reset=1791763200.000123',
    );
    is($nic->{quota}, $GiB, 'quota');
    is($nic->{rate}, 1.5, 'rate canonical');
    is($nic->{'last-reset'}, '1791763200.000123', 'period id kept as string');

    my $limited = PVE::TrafficD::Config::parse_nic(
        'last-reset=1791763200.5,limited=1,orig-rate=12.5,applied=1',
    );
    is_deeply(
        $limited,
        { 'last-reset' => '1791763200.5', limited => 1, 'orig-rate' => 12.5, applied => 1 },
        'limit state',
    );

    my $stale = PVE::TrafficD::Config::parse_nic('last-reset=1,limited=0,orig-rate=3,applied=1');
    is_deeply($stale, { 'last-reset' => '1' }, 'limit details without limited dropped');

    my $raw = PVE::TrafficD::Config::write_vm_config_string({
        nics => {
            net10 => $limited,
            net2 => { %$nic, limited => 0, applied => 7 },
        },
    });
    is(
        $raw,
        "net2: last-reset=1791763200.000123,direction=max,quota=1073741824,rate=1.5\n"
            . "net10: last-reset=1791763200.5,applied=1,limited=1,orig-rate=12.5\n",
        'written sorted by index, inactive state dropped',
    );
    my $conf = PVE::TrafficD::Config::parse_vm_config('test', $raw);
    is_deeply($conf->{nics}->{net10}, $limited, 'roundtrip');

    eval { PVE::TrafficD::Config::parse_nic('quota=1') };
    ok($@, 'last-reset is required');
    eval { PVE::TrafficD::Config::parse_nic('last-reset=1,rate=0') };
    ok($@, 'limit rate 0 rejected');
};

subtest 'options' => sub {
    local $SIG{__WARN__} = sub { };
    my $opts = PVE::TrafficD::Config::parse_options(
        'test', "rate: 0.25\ndirection: out\nbogus: 1\n",
    );
    is($opts->{rate}, 0.25, 'rate');
    is($opts->{direction}, 'out', 'direction');
    ok(!exists($opts->{bogus}), 'unknown option ignored');

    my $bad = PVE::TrafficD::Config::parse_options('test', "rate: 0\ndirection: sideways\n");
    ok(!defined($bad->{rate}) && !defined($bad->{direction}), 'invalid values ignored');

    is(PVE::TrafficD::Config::write_options_string($opts), "direction: out\nrate: 0.25\n", 'write');
};

subtest 'effective values and quota' => sub {
    my $opts = { rate => 2 };
    my $nic = { quota => 100, 'last-reset' => '1' };

    is(PVE::TrafficD::Config::effective_rate($nic, $opts), 2, 'cluster rate');
    is(PVE::TrafficD::Config::effective_rate({ rate => 0.5 }, $opts), 0.5, 'NIC rate wins');
    is(PVE::TrafficD::Config::effective_rate({}, {}), 1, 'built-in rate');
    is(PVE::TrafficD::Config::effective_direction($nic, $opts), 'both', 'built-in direction');

    my $counted = \&PVE::TrafficD::Config::counted_bytes;
    is($counted->('both', 30, 50), 80, 'both');
    is($counted->('in', 30, 50), 30, 'in');
    is($counted->('out', 30, 50), 50, 'out');
    is($counted->('max', 70, 50), 70, 'max');

    my $over = \&PVE::TrafficD::Config::over_quota;
    ok(!$over->($nic, $opts, 49, 50), 'below quota');
    ok($over->($nic, $opts, 50, 50), 'reaching the quota limits');
    ok(!$over->({ %$nic, direction => 'in' }, $opts, 99, 1000), 'only counted direction');
    ok(!$over->({ 'last-reset' => '1' }, $opts, 10**15, 10**15), 'no quota, no limit');
    ok(!$over->({ %$nic, deleted => 1 }, $opts, 100, 100), 'removed NIC is never limited');
    ok($over->({ %$nic, quota => 0 }, $opts, 0, 0), 'quota 0 limits right away');

    my $data = PVE::TrafficD::Config::nic_api_data(
        { %$nic, limited => 1, 'orig-rate' => 10, applied => 2 }, $opts, 60, 40,
    );
    is_deeply(
        $data,
        {
            quota => 100,
            'effective-rate' => 2,
            'effective-direction' => 'both',
            'last-reset' => 1,
            netin => 60,
            netout => 40,
            used => 100,
            exceeded => 1,
            limited => 1,
            'orig-rate' => 10,
            applied => 2,
        },
        'API data',
    );
};

subtest 'period ids' => sub {
    my $first = PVE::TrafficD::Config::new_reset_token();
    like($first, qr/^\d+\.\d{6}$/, 'seconds with microseconds');
    my $next = PVE::TrafficD::Config::new_reset_token($first);
    isnt($next, $first, 'never equal to the previous one');
    is(PVE::TrafficD::Config::reset_time('1791763200.000123'), 1791763200, 'reset time');
};

done_testing();
