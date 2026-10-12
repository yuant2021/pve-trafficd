#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::TrafficD::Netlink;

my sub attr {
    my ($type, $data) = @_;
    my $len = 4 + length($data);
    return pack('S S', $len, $type) . $data . ("\0" x ((4 - $len % 4) % 4));
}

my sub msg {
    my ($type, $seq, $payload) = @_;
    return pack('L S S L L', 16 + length($payload), $type, 0x2, $seq, 0) . $payload;
}

my sub link_msg {
    my ($type, $seq, $index, $name, $rx, $tx, $reverse) = @_;

    my @attrs = (
        attr(3, "$name\0"), # IFLA_IFNAME
        attr(4, pack('L', 1500)), # IFLA_MTU
        attr(23, pack('Q*', 7, 8, $rx, $tx, (0) x 20)), # IFLA_STATS64
    );
    @attrs = reverse(@attrs) if $reverse;
    return msg($type, $seq, pack('C C S l L L', 0, 0, 1, $index, 0, 0) . join('', @attrs));
}

subtest 'link messages' => sub {
    my $buf = link_msg(16, 5, 12, 'tap100i0', 1000, 2000)
        . link_msg(16, 5, 2, 'vmbr0', 1, 2)
        . link_msg(17, 5, 13, 'tap101i1', 3 * 2**40, 5, 1)
        . link_msg(16, 5, 14, 'tap102i0x', 1, 1)
        . msg(3, 5, pack('l', 0));

    my $links = [];
    my ($done, $errno) = PVE::TrafficD::Netlink::parse_messages($buf, $links, 5);
    ok($done, 'dump done');
    is($errno, 0, 'no error');
    is_deeply(
        $links,
        [
            { type => 'new', index => 12, name => 'tap100i0', rx => 1000, tx => 2000 },
            { type => 'del', index => 13, name => 'tap101i1', rx => 3 * 2**40, tx => 5 },
        ],
        'only tap devices, 64 bit counters, any attribute order',
    );
};

subtest 'sequence and errors' => sub {
    my $links = [];
    my ($done, $errno) = PVE::TrafficD::Netlink::parse_messages(
        link_msg(16, 4, 12, 'tap100i0', 1, 1) . msg(2, 5, pack('l', -22)), $links, 5,
    );
    is_deeply($links, [], 'other sequence ignored');
    ok($done, 'error ends the dump');
    is($errno, 22, 'errno');

    my $events = [];
    PVE::TrafficD::Netlink::parse_messages(link_msg(17, 0, 3, 'tap7i0', 1, 2) . "\x01\x02", $events);
    is(scalar(@$events), 1, 'notifications without sequence, trailing garbage ignored');
};

done_testing();
