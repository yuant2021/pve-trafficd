package PVE::API2::Cluster;

# Installed by pve-trafficd. The PVE::API2::Cluster module of pve-manager is
# diverted (dpkg-divert) to the path below; load it unchanged and register the
# pve-trafficd API paths. Removing pve-trafficd restores the original.

use strict;
use warnings;

BEGIN {
    my $orig = '/usr/share/perl5/PVE/API2/Cluster.pm.pve-trafficd-orig';
    my $res = do $orig;
    die "unable to load $orig - $@" if $@;
    die "unable to load $orig - $!\n" if !defined($res);
}

eval {
    require PVE::API2::TrafficD;
    PVE::API2::TrafficD::register_api();
};
warn "pve-trafficd: unable to register API - $@" if $@;

1;
