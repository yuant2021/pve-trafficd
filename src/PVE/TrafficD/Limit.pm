package PVE::TrafficD::Limit;

# Applies and lifts the traffic limit of a guest NIC: the 'rate' of the NIC in the
# guest config is changed like 'qm set' would, and applied to the tap device of a
# running guest right away (what qemu-server does for a hot rate change). Runs on
# the node owning the guest config, under the guest config lock and the
# pve-trafficd cluster lock.
#
# The limit state lives in the trafficd NIC config (see PVE::TrafficD::Config).
# When the limit is lifted 'orig-rate' is restored, but only if the guest still has
# the rate we set ('applied'): a rate changed meanwhile is the newer intent.

use strict;
use warnings;

use PVE::TrafficD::Config;

sub rate_eq {
    my ($a, $b) = @_;
    return !defined($b) if !defined($a);
    return defined($b) && abs($a - $b) < 1e-9;
}

sub format_rate {
    my ($rate) = @_;
    return defined($rate) && $rate > 0 ? "$rate MB/s" : 'unlimited';
}

# What to do with a NIC. $want: the limit should be in place, $limit: the limit
# rate, $has_net: the guest has this NIC, $cur: its rate (undef: none). Returns
# the new limit state { limited, orig-rate, applied } plus set => 1 and the
# 'rate' (undef: remove it) if the guest NIC needs a new rate.
sub plan {
    my ($nic, $want, $limit, $has_net, $cur) = @_;

    if (!$want) {
        my $res = { limited => 0 };
        if ($nic->{limited} && $has_net && rate_eq($cur, $nic->{applied})) {
            $res->{set} = 1;
            $res->{rate} = $nic->{'orig-rate'};
        }
        return $res;
    }

    my $orig = $nic->{'orig-rate'};
    # first time, or the guest got another rate meanwhile (re-created or edited)
    $orig = $cur if !$nic->{limited} || ($has_net && !rate_eq($cur, $nic->{applied}));

    # never raise the rate of a NIC that is slower already
    my $applied = defined($orig) && $orig > 0 && $orig < $limit ? $orig : $limit;

    my $res = { limited => 1, 'orig-rate' => $orig, applied => $applied };
    if ($has_net && !rate_eq($cur, $applied)) {
        $res->{set} = 1;
        $res->{rate} = $applied;
    }
    return $res;
}

my sub with_rate {
    my ($value, $rate) = @_;

    my $net = PVE::TrafficD::Config::parse_qemu_net($value) or return undef;
    if (defined($rate)) {
        $net->{rate} = $rate;
    } else {
        delete $net->{rate};
    }
    return PVE::TrafficD::Config::print_qemu_net($net);
}

my sub state_differs {
    my ($nic, $plan) = @_;

    return 1 if ($nic->{limited} ? 1 : 0) != $plan->{limited};
    return 0 if !$plan->{limited};
    return !rate_eq($nic->{'orig-rate'}, $plan->{'orig-rate'})
        || !rate_eq($nic->{applied}, $plan->{applied});
}

# Everything that has to change for NIC $net of guest config $conf according to
# trafficd config $tconf, or undef if nothing. $usage = { reset, in, out } is the
# traffic of the NIC's period as known by the caller.
my sub evaluate {
    my ($conf, $tconf, $net, $usage, $lift, $opts) = @_;

    my $nic = $tconf->{nics}->{$net} or return undef;

    my ($in, $out) = (0, 0);
    ($in, $out) = ($usage->{in}, $usage->{out}) if $usage && $usage->{reset} eq $nic->{'last-reset'};

    my $want = $lift ? 0 : PVE::TrafficD::Config::over_quota($nic, $opts, $in, $out);
    my $limit = PVE::TrafficD::Config::effective_rate($nic, $opts);

    my $qnet = PVE::TrafficD::Config::parse_qemu_net($conf->{$net});
    my $plan = plan($nic, $want, $limit, defined($qnet), $qnet ? $qnet->{rate} : undef);

    # a pending change of the NIC must not undo the limit at the next start
    if (my $pnet = PVE::TrafficD::Config::parse_qemu_net(($conf->{pending} // {})->{$net})) {
        if ($plan->{limited} && !rate_eq($pnet->{rate}, $plan->{applied})) {
            ($plan->{pending_set}, $plan->{pending_rate}) = (1, $plan->{applied});
        } elsif (!$plan->{limited} && $nic->{limited} && rate_eq($pnet->{rate}, $nic->{applied})) {
            ($plan->{pending_set}, $plan->{pending_rate}) = (1, $nic->{'orig-rate'});
        }
    }

    $plan->{drop} = $nic->{deleted} && !$plan->{limited};
    $plan->{state_changed} = state_differs($nic, $plan) || $plan->{drop};
    return undef if !$plan->{state_changed} && !$plan->{set} && !$plan->{pending_set};

    $plan->{nic} = $nic;
    $plan->{used} = PVE::TrafficD::Config::counted_bytes(
        PVE::TrafficD::Config::effective_direction($nic, $opts), $in, $out,
    );
    return $plan;
}

my sub describe {
    my ($vmid, $net, $nic, $plan) = @_;

    my @what;
    if ($plan->{limited} && !$nic->{limited}) {
        push @what, "traffic quota reached ($plan->{used} of " . ($nic->{quota} // 0)
            . " bytes since the last reset), rate limited to " . format_rate($plan->{applied})
            . " (was " . format_rate($plan->{'orig-rate'}) . ")";
    } elsif ($plan->{limited}) {
        push @what, "rate limit re-applied: " . format_rate($plan->{applied})
            . " (original rate now " . format_rate($plan->{'orig-rate'}) . ")";
    } elsif ($nic->{limited}) {
        push @what, $plan->{set}
            ? "limit lifted, rate restored to " . format_rate($plan->{rate})
            : "limit lifted, rate left as is (changed while limited)";
    }
    push @what, 'traffic accounting removed' if $plan->{drop};

    return @what ? "VM $vmid $net: " . join(', ', @what) : undef;
}

# Bring NIC $net of guest $vmid (config on this node) in line with its trafficd
# config. $usage = { reset, in, out } is the traffic of the NIC's period as known
# by the caller; with $lift the limit is lifted regardless of the quota (used on
# uninstall). Returns a message describing the change, undef if there was nothing
# to do. Dies if the guest cannot be changed right now (e.g. it is locked).
sub sync_nic {
    my ($vmid, $net, $usage, $lift) = @_;

    require PVE::QemuConfig;
    require PVE::Network;

    my ($idx) = $net =~ m/^net(\d+)$/ or die "invalid network device '$net'\n";
    ($vmid) = $vmid =~ m/^(\d+)$/ or die "invalid VMID\n";

    # Mostly there is nothing to do, e.g. when a limited guest starts. Find out
    # without locks, the start of the guest holds its config lock.
    my $check = evaluate(
        PVE::QemuConfig->load_config($vmid),
        PVE::TrafficD::Config::load_vm_config($vmid),
        $net, $usage, $lift, PVE::TrafficD::Config::load_options(),
    );
    return undef if !$check;

    my $msg;
    PVE::QemuConfig->lock_config_full(
        $vmid,
        2,
        sub {
            my $conf = PVE::QemuConfig->load_config($vmid);

            PVE::TrafficD::Config::lock_config(sub {
                my $tconf = PVE::TrafficD::Config::load_vm_config($vmid);
                my $opts = PVE::TrafficD::Config::load_options();
                my $plan = evaluate($conf, $tconf, $net, $usage, $lift, $opts) or return;
                my $nic = { $plan->{nic}->%* }; # state before

                if (my $lock = $conf->{lock}) {
                    # backups read the config at their start, changing it is fine
                    die "VM is locked ($lock)\n" if $lock ne 'backup';
                }

                my $write_state = sub {
                    return if !$plan->{state_changed};
                    if ($plan->{drop}) {
                        delete $tconf->{nics}->{$net};
                    } else {
                        $tconf->{nics}->{$net}->{$_} = $plan->{$_} for qw(limited orig-rate applied);
                    }
                    PVE::TrafficD::Config::write_vm_config($vmid, $tconf);
                };

                my $update_guest = sub {
                    return if !$plan->{set} && !$plan->{pending_set};

                    $conf->{$net} = with_rate($conf->{$net}, $plan->{rate}) if $plan->{set};
                    $conf->{pending}->{$net} = with_rate($conf->{pending}->{$net}, $plan->{pending_rate})
                        if $plan->{pending_set};
                    PVE::QemuConfig->write_config($vmid, $conf);

                    # like a hot rate change of qemu-server
                    my $tap = "tap${vmid}i$idx";
                    PVE::Network::tap_rate_limit($tap, $plan->{rate})
                        if $plan->{set} && -d "/sys/class/net/$tap";
                };

                if ($plan->{limited}) {
                    # remember the original rate before touching the guest
                    $write_state->();
                    $update_guest->();
                } else {
                    # restore the guest first, the state is needed until then
                    $update_guest->();
                    $write_state->();
                }

                $msg = describe($vmid, $net, $nic, $plan);
            });
        },
    );

    return $msg;
}

# Lift all limits of guests on this node and finish pending removals (uninstall).
# Returns the list of errors.
sub lift_all_local {
    my ($nodename, $log) = @_;

    require PVE::Cluster;

    PVE::Cluster::cfs_update();
    my $guests = PVE::Cluster::get_vmlist()->{ids} // {};

    my $errors = [];
    for my $vmid (PVE::TrafficD::Config::configured_vmids()->@*) {
        my $guest = $guests->{$vmid};
        next if !$guest || $guest->{node} ne $nodename || ($guest->{type} // '') ne 'qemu';

        my $tconf = eval { PVE::TrafficD::Config::load_vm_config($vmid) } or next;
        for my $net (PVE::TrafficD::Config::sorted_nets($tconf->{nics})) {
            my $nic = $tconf->{nics}->{$net};
            next if !$nic->{limited} && !$nic->{deleted};
            my $msg = eval { sync_nic($vmid, $net, undef, 1) };
            if (my $err = $@) {
                push @$errors, "VM $vmid $net: $err";
            } elsif ($msg) {
                $log->($msg);
            }
        }
    }
    return $errors;
}

1;
