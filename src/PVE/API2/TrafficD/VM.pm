package PVE::API2::TrafficD::VM;

# /cluster/trafficd/vms/{vmid}: traffic accounting of one guest, per NIC.
#
# Requests are proxied to the node the guest is on (if online): its daemon has the
# most recent counters. The config does not depend on the guest existing, it is
# kept when a guest is destroyed and used again when the VMID is re-created.

use strict;
use warnings;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::Tools qw(extract_param);

use PVE::TrafficD::Config;
use PVE::TrafficD::Usage;

use base qw(PVE::RESTHandler);

my $net_param = {
    type => 'string',
    pattern => 'net\d+',
    description => "Network device of the guest (netX).",
};

my $nic_data_properties = {
    quota => {
        type => 'integer',
        optional => 1,
        renderer => 'bytes',
        description => "Quota of the counting period in bytes (absent: traffic is only counted).",
    },
    rate => {
        type => 'number',
        optional => 1,
        description => "Limit rate (MB/s) set on the network device.",
    },
    direction => {
        type => 'string',
        enum => [@PVE::TrafficD::Config::DIRECTIONS],
        optional => 1,
        description => "Counted direction set on the network device.",
    },
    'effective-rate' => {
        type => 'number',
        optional => 1,
        description => "Limit rate (MB/s) in effect.",
    },
    'effective-direction' => {
        type => 'string',
        enum => [@PVE::TrafficD::Config::DIRECTIONS],
        optional => 1,
        description => "Counted direction in effect.",
    },
    'last-reset' => {
        type => 'integer',
        optional => 1,
        renderer => 'timestamp',
        description => "Start of the counting period (last reset or creation), UNIX epoch.",
    },
    netin => {
        type => 'integer',
        optional => 1,
        renderer => 'bytes',
        description => "Bytes received by the guest since the last reset.",
    },
    netout => {
        type => 'integer',
        optional => 1,
        renderer => 'bytes',
        description => "Bytes sent by the guest since the last reset.",
    },
    used => {
        type => 'integer',
        optional => 1,
        renderer => 'bytes',
        description => "Bytes counted against the quota.",
    },
    exceeded => {
        type => 'boolean',
        optional => 1,
        description => "The quota is reached.",
    },
    limited => {
        type => 'boolean',
        optional => 1,
        description => "The rate of the network device is limited.",
    },
    'orig-rate' => {
        type => 'number',
        optional => 1,
        description => "Rate of the network device before it was limited (absent: it had none).",
    },
    applied => {
        type => 'number',
        optional => 1,
        description => "Rate (MB/s) the network device is limited to.",
    },
    removing => {
        type => 'boolean',
        optional => 1,
        description => "The config was removed while limited, the original rate is being restored.",
    },
};

sub nic_data_properties {
    return { map { $_ => {$nic_data_properties->{$_}->%*} } keys %$nic_data_properties };
}

# node to handle a request for a guest: where it lives, if that node is online
sub guest_node {
    my ($rpcenv, $proxyto, $param) = @_;

    my $guest = (PVE::Cluster::get_vmlist()->{ids} // {})->{ $param->{vmid} } or return 'localhost';
    my $node = $guest->{node};
    return 'localhost' if $node eq PVE::INotify::nodename();

    my $members = PVE::Cluster::get_members() // {};
    return 'localhost' if !$members->{$node} || !$members->{$node}->{online};
    return $node;
}

my sub guest_entry {
    my ($vmid) = @_;
    return (PVE::Cluster::get_vmlist()->{ids} // {})->{$vmid};
}

my sub check_qemu {
    my ($guest, $vmid) = @_;
    raise_param_exc({ vmid => "VM $vmid is not a QEMU virtual machine" })
        if $guest && $guest->{type} ne 'qemu';
}

# config of a QEMU guest, wherever in the cluster it lives (undef: none)
my sub guest_config {
    my ($vmid) = @_;

    my $guest = guest_entry($vmid);
    return undef if !$guest || $guest->{type} ne 'qemu';

    require PVE::QemuConfig;
    my $conf = eval { PVE::QemuConfig->load_config($vmid, $guest->{node}) };
    warn $@ if $@;
    return $conf;
}

my sub nic_data {
    my ($vmid, $net, $nic, $opts, $usage) = @_;

    my ($in, $out) = PVE::TrafficD::Usage::nic_total($usage, $vmid, $net, $nic->{'last-reset'});
    return PVE::TrafficD::Config::nic_api_data($nic, $opts, $in, $out);
}

my sub current_usage {
    return PVE::TrafficD::Usage::cluster_usage(PVE::INotify::nodename());
}

my $write_permissions = {
    description => "Quota and limit are billing controls of the host, so 'Sys.Modify' on '/' is"
        . " required in addition to 'VM.Config.Network' on the guest.",
    check => [
        'and',
        ['perm', '/vms/{vmid}', ['VM.Config.Network']],
        ['perm', '/', ['Sys.Modify']],
    ],
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto_callback => \&guest_node,
    description => "List the network devices of a guest with their traffic accounting: the"
        . " devices of the guest config and all configured ones.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                net => { type => 'string', description => "Network device." },
                configured => {
                    type => 'boolean',
                    description => "Traffic accounting is configured for the device.",
                },
                missing => {
                    type => 'boolean',
                    optional => 1,
                    description => "Configured, but the guest has no such network device.",
                },
                bridge => { type => 'string', optional => 1 },
                tag => { type => 'integer', optional => 1 },
                macaddr => { type => 'string', optional => 1 },
                'nic-rate' => {
                    type => 'number',
                    optional => 1,
                    description => "Rate currently set on the network device of the guest.",
                },
                digest => get_standard_option('pve-config-digest'),
                nic_data_properties()->%*,
            },
        },
        links => [{ rel => 'child', href => "{net}" }],
    },
    code => sub {
        my ($param) = @_;

        my $vmid = $param->{vmid};
        my $qconf = guest_config($vmid) // {};
        my $tconf = PVE::TrafficD::Config::load_vm_config($vmid);
        my $opts = PVE::TrafficD::Config::load_options();
        my $usage = current_usage();

        my %nets = map { $_ => 1 } grep { m/^net\d+$/ } keys %$qconf;
        $nets{$_} = 1 for keys $tconf->{nics}->%*;

        my $res = [];
        for my $net (PVE::TrafficD::Config::sorted_nets(\%nets)) {
            my $entry = { net => $net, configured => 0, digest => $tconf->{digest} };

            if (my $qnet = PVE::TrafficD::Config::parse_qemu_net($qconf->{$net})) {
                $entry->{$_} = $qnet->{$_} for grep { defined($qnet->{$_}) } qw(bridge tag macaddr);
                $entry->{'nic-rate'} = 0 + $qnet->{rate} if defined($qnet->{rate});
            }

            if (my $nic = $tconf->{nics}->{$net}) {
                $entry = { %$entry, nic_data($vmid, $net, $nic, $opts, $usage)->%*, configured => 1 };
                $entry->{missing} = 1 if !defined($qconf->{$net});
            }

            push @$res, $entry;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'read_nic',
    path => '{net}',
    method => 'GET',
    proxyto_callback => \&guest_node,
    description => "Get the traffic accounting config and counters of a network device.",
    permissions => {
        check => ['perm', '/vms/{vmid}', ['VM.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
        },
    },
    returns => {
        type => 'object',
        properties => {
            configured => {
                type => 'boolean',
                description => "Traffic accounting is configured for the device.",
            },
            digest => get_standard_option('pve-config-digest'),
            nic_data_properties()->%*,
        },
    },
    code => sub {
        my ($param) = @_;

        my ($vmid, $net) = $param->@{qw(vmid net)};
        my $tconf = PVE::TrafficD::Config::load_vm_config($vmid);
        my $nic = $tconf->{nics}->{$net};

        my $res = { configured => 0, digest => $tconf->{digest} };
        if ($nic) {
            my $opts = PVE::TrafficD::Config::load_options();
            $res = { %$res, nic_data($vmid, $net, $nic, $opts, current_usage())->%*, configured => 1 };
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'update_nic',
    path => '{net}',
    method => 'PUT',
    protected => 1,
    proxyto_callback => \&guest_node,
    description => "Create or update the traffic accounting of a network device. Creating starts"
        . " a counting period. The limit follows within seconds.",
    permissions => $write_permissions,
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
            PVE::TrafficD::Config::nic_properties()->%*,
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                description => "A list of settings to remove (quota, rate, direction).",
                optional => 1,
            },
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $vmid = extract_param($param, 'vmid');
        my $net = extract_param($param, 'net');
        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');

        my $guest = guest_entry($vmid);
        check_qemu($guest, $vmid);

        my %delete;
        for my $key (PVE::Tools::split_list($delete)) {
            raise_param_exc({ delete => "unknown setting '$key'" })
                if !grep { $_ eq $key } @PVE::TrafficD::Config::NIC_SETTINGS;
            raise_param_exc({ $key => "cannot set and delete at the same time" })
                if defined($param->{$key});
            $delete{$key} = 1;
        }

        my $quota;
        if (defined($param->{quota})) {
            $quota = eval { PVE::TrafficD::Config::parse_size($param->{quota}) };
            raise_param_exc({ quota => $@ }) if $@;
        }

        PVE::TrafficD::Config::lock_config(sub {
            my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
            PVE::TrafficD::Config::assert_digest($conf, $digest);

            my $nic = $conf->{nics}->{$net};
            if (!$nic || $nic->{deleted}) {
                if ($guest && !$nic) {
                    my $qconf = guest_config($vmid);
                    raise_param_exc({ net => "VM $vmid has no network device '$net'" })
                        if $qconf && !defined($qconf->{$net});
                }
                # a pending removal keeps its limit state, the daemon still lifts it
                my $old = $nic // {};
                $nic = { map { $_ => $old->{$_} } grep { defined($old->{$_}) } qw(limited orig-rate applied) };
                $nic->{'last-reset'} = PVE::TrafficD::Config::new_reset_token($old->{'last-reset'});
            }

            delete $nic->{$_} for keys %delete;
            $nic->{quota} = $quota if defined($quota);
            $nic->{rate} = PVE::TrafficD::Config::canonical_number($param->{rate})
                if defined($param->{rate});
            $nic->{direction} = $param->{direction} if defined($param->{direction});

            $conf->{nics}->{$net} = $nic;
            PVE::TrafficD::Config::write_vm_config($vmid, $conf);
        });

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete_nic',
    path => '{net}',
    method => 'DELETE',
    protected => 1,
    proxyto_callback => \&guest_node,
    description => "Remove the traffic accounting of a network device. A limit in place is lifted"
        . " (by the node of the guest, the config stays until then); the counters of the current"
        . " period are discarded.",
    permissions => $write_permissions,
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my ($vmid, $net) = $param->@{qw(vmid net)};

        PVE::TrafficD::Config::lock_config(sub {
            my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
            PVE::TrafficD::Config::assert_digest($conf, $param->{digest});

            my $nic = $conf->{nics}->{$net};
            die "no traffic accounting configured for '$net'\n" if !$nic || $nic->{deleted};

            # cfs_lock_domain() refreshed the guest list
            if ($nic->{limited} && guest_entry($vmid)) {
                $nic->{deleted} = 1;
            } else {
                delete $conf->{nics}->{$net};
            }
            PVE::TrafficD::Config::write_vm_config($vmid, $conf);
        });

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'reset_nic',
    path => '{net}/reset',
    method => 'POST',
    protected => 1,
    proxyto_callback => \&guest_node,
    description => "Reset the traffic counter of a network device: a new counting period starts"
        . " now, a limit in place is lifted within seconds. Returns the traffic of the period that"
        . " ended.",
    permissions => $write_permissions,
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
            net => $net_param,
            quota => {
                PVE::TrafficD::Config::nic_properties()->{quota}->%*,
                description => "Set a new quota for the new period.",
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            'last-reset' => {
                type => 'integer',
                renderer => 'timestamp',
                description => "Start of the period that ended, UNIX epoch.",
            },
            netin => {
                type => 'integer',
                renderer => 'bytes',
                description => "Bytes received by the guest.",
            },
            netout => {
                type => 'integer',
                renderer => 'bytes',
                description => "Bytes sent by the guest.",
            },
            used => {
                type => 'integer',
                renderer => 'bytes',
                description => "Bytes counted against the quota.",
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my ($vmid, $net) = $param->@{qw(vmid net)};

        my $quota;
        if (defined($param->{quota})) {
            $quota = eval { PVE::TrafficD::Config::parse_size($param->{quota}) };
            raise_param_exc({ quota => $@ }) if $@;
        }

        return PVE::TrafficD::Config::lock_config(sub {
            my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
            my $nic = $conf->{nics}->{$net};
            die "no traffic accounting configured for '$net'\n" if !$nic || $nic->{deleted};

            my $opts = PVE::TrafficD::Config::load_options();
            my $data = nic_data($vmid, $net, $nic, $opts, current_usage());

            $nic->{'last-reset'} = PVE::TrafficD::Config::new_reset_token($nic->{'last-reset'});
            $nic->{quota} = $quota if defined($quota);
            PVE::TrafficD::Config::write_vm_config($vmid, $conf);

            return { map { $_ => $data->{$_} } qw(last-reset netin netout used) };
        });
    },
});

1;
