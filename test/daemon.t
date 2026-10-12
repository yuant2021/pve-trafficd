#!/usr/bin/perl

# Counting of device traffic by the daemon: nothing lost, nothing counted twice.

use strict;
use warnings;

use Test::More;

BEGIN {
    # pmxcfs is not touched by the counting code (libpve-cluster-perl is not a
    # build dependency)
    $INC{'PVE/Cluster.pm'} = __FILE__;
}

use PVE::TrafficD::Daemon;

my sub daemon {
    my (%opts) = @_;

    my $d = PVE::TrafficD::Daemon->new();
    $d->{configs_loaded} = 1;
    $d->{startup_max_ifindex} = $opts{max_ifindex} // 0;
    $d->{same_boot} = $opts{same_boot} // 0;
    $d->{configs} = {
        100 => {
            key => 'k',
            conf => {
                nics => {
                    net0 => { 'last-reset' => '1000.000001' },
                    net2 => { 'last-reset' => '1000.000001', deleted => 1, limited => 1 },
                },
            },
        },
        101 => { key => '', conf => undef },
    };
    return $d;
}

my sub dev {
    my ($index, $name, $rx, $tx) = @_;
    return { index => $index, name => $name, rx => $rx, tx => $tx };
}

my sub usage {
    my ($d, $vmid, $net) = @_;
    my $entry = $d->{usage}->{$vmid}->{$net} // return undef;
    return [$entry->{in}, $entry->{out}];
}

subtest 'devices of a running daemon' => sub {
    my $d = daemon(max_ifindex => 10);

    $d->update_device(dev(20, 'tap100i0', 300, 1000));
    is_deeply(usage($d, 100, 'net0'), [1000, 300], 'new device counted from its creation, rx is out');

    $d->update_device(dev(20, 'tap100i0', 350, 1100));
    is_deeply(usage($d, 100, 'net0'), [1100, 350], 'delta of the next poll');

    $d->device_removed(dev(20, 'tap100i0', 360, 1500));
    is_deeply(usage($d, 100, 'net0'), [1500, 360], 'final counters of the removed device');
    ok($d->{urgent_flush}, 'flushed soon after a guest stopped');

    $d->device_removed(dev(21, 'tap100i0', 10, 20));
    is_deeply(usage($d, 100, 'net0'), [1520, 370], 'device that lived shorter than a poll interval');

    $d->update_device(dev(22, 'tap100i0', 5, 5));
    $d->update_device(dev(22, 'tap100i0', 5, 5));
    is_deeply(usage($d, 100, 'net0'), [1525, 375], 'restarted guest, unchanged counters not added again');

    $d->update_device(dev(23, 'tap101i0', 100, 100));
    $d->update_device(dev(24, 'tap100i1', 100, 100));
    $d->update_device(dev(25, 'tap100i2', 100, 100));
    is_deeply([sort keys $d->{usage}->%*], [100], 'unconfigured guest not counted');
    is_deeply([sort keys $d->{usage}->{100}->%*], ['net0'], 'unconfigured and removed NICs not counted');
};

subtest 'fresh start with running guests' => sub {
    my $d = daemon(max_ifindex => 10);

    $d->update_device(dev(7, 'tap100i0', 5000, 9000));
    is(usage($d, 100, 'net0'), undef, 'traffic before the start is not ours to count');
    $d->update_device(dev(7, 'tap100i0', 5100, 9200));
    is_deeply(usage($d, 100, 'net0'), [200, 100], 'counted from the start on');

    $d->device_removed(dev(8, 'tap100i0', 70000, 70000));
    is_deeply(usage($d, 100, 'net0'), [200, 100], 'unknown old device removed: not counted');
};

subtest 'restart within the same boot' => sub {
    my $d = daemon(same_boot => 1);
    $d->{taps} = { 7 => { name => 'tap100i0', rx => 5000, tx => 9000 } };
    $d->{usage} = { 100 => { net0 => { reset => '1000.000001', in => 9000, out => 5000 } } };

    $d->update_device(dev(7, 'tap100i0', 5100, 9200));
    is_deeply(usage($d, 100, 'net0'), [9200, 5100], 'continues from the saved baseline');

    $d->update_device(dev(9, 'tap100i0', 40, 60));
    is_deeply(usage($d, 100, 'net0'), [9260, 5140], 'device created while stopped fully counted');
};

subtest 'removal notification versus dumps' => sub {
    my $d = daemon(max_ifindex => 10);
    $d->update_device(dev(20, 'tap100i0', 0, 0));
    $d->update_device(dev(20, 'tap100i0', 100, 100));

    # dump without the device: the notification is still on its way
    $d->{taps}->{20}->{missing} = 1;
    $d->device_removed(dev(20, 'tap100i0', 150, 170));
    is_deeply(usage($d, 100, 'net0'), [170, 150], 'counted once, from the last baseline');
    ok(!$d->{taps}->{20}, 'baseline gone');
};

subtest 'new counting period' => sub {
    my $d = daemon(max_ifindex => 10);
    $d->update_device(dev(20, 'tap100i0', 100, 100));

    $d->{configs}->{100}->{conf}->{nics}->{net0}->{'last-reset'} = '2000.000001';
    $d->update_device(dev(20, 'tap100i0', 130, 110));
    is_deeply(
        $d->{usage}->{100}->{net0},
        { reset => '2000.000001', in => 10, out => 30 },
        'traffic after the reset starts the new period at zero',
    );
};

done_testing();
