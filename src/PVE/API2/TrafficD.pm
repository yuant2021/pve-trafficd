package PVE::API2::TrafficD;

# /cluster/trafficd: cluster wide options and an overview of all counted NICs

use strict;
use warnings;

use PVE::Cluster;
use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools qw(extract_param);

use PVE::API2::TrafficD::VM;
use PVE::TrafficD::Config;
use PVE::TrafficD::Usage;

use base qw(PVE::RESTHandler);

my $registered;

# called by the PVE::API2::Cluster wrapper module
sub register_api {
    return if $registered;
    $registered = 1;

    require PVE::API2::Cluster;

    PVE::API2::Cluster->register_method({
        subclass => 'PVE::API2::TrafficD',
        path => 'trafficd',
    });
}

__PACKAGE__->register_method({
    subclass => 'PVE::API2::TrafficD::VM',
    path => 'vms/{vmid}',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => { name => { type => 'string' } },
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        return [{ name => 'options' }, { name => 'vms' }];
    },
});

__PACKAGE__->register_method({
    name => 'get_options',
    path => 'options',
    method => 'GET',
    description => "Get the cluster wide traffic accounting defaults.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'object',
        properties => {
            PVE::TrafficD::Config::option_properties()->%*,
            digest => get_standard_option('pve-config-digest'),
        },
    },
    code => sub {
        return PVE::TrafficD::Config::load_options();
    },
});

__PACKAGE__->register_method({
    name => 'set_options',
    path => 'options',
    method => 'PUT',
    protected => 1,
    description => "Update the cluster wide traffic accounting defaults. Limits in place follow"
        . " within seconds.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            PVE::TrafficD::Config::option_properties()->%*,
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                description => "A list of settings you want to reset to their default.",
                optional => 1,
            },
            digest => get_standard_option('pve-config-digest'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');
        my $known = PVE::TrafficD::Config::option_properties();

        PVE::TrafficD::Config::lock_config(sub {
            my $opts = PVE::TrafficD::Config::load_options();
            PVE::TrafficD::Config::assert_digest($opts, $digest);
            delete $opts->{digest};

            for my $key (PVE::Tools::split_list($delete)) {
                raise_param_exc({ delete => "unknown option '$key'" }) if !$known->{$key};
                raise_param_exc({ $key => "cannot set and delete at the same time" })
                    if defined($param->{$key});
                delete $opts->{$key};
            }

            $opts->{rate} = PVE::TrafficD::Config::canonical_number($param->{rate})
                if defined($param->{rate});
            $opts->{direction} = $param->{direction} if defined($param->{direction});

            PVE::TrafficD::Config::write_options($opts);
        });

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'list_vms',
    path => 'vms',
    method => 'GET',
    description => "List the traffic accounting of all configured network devices. Counters of"
        . " guests on other nodes are as recent as their last flush (some seconds).",
    permissions => {
        description => "Only guests with 'VM.Audit' permission are listed.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                vmid => get_standard_option('pve-vmid'),
                net => { type => 'string', description => "Network device." },
                node => {
                    type => 'string',
                    optional => 1,
                    description => "Node the guest config is on.",
                },
                orphan => {
                    type => 'boolean',
                    optional => 1,
                    description => "The guest does not exist (anymore). The data is kept for a"
                        . " guest re-created with this VMID.",
                },
                PVE::API2::TrafficD::VM::nic_data_properties()->%*,
            },
        },
    },
    code => sub {
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $guests = PVE::Cluster::get_vmlist()->{ids} // {};
        my $all = PVE::TrafficD::Config::load_all_vm_configs();
        my $opts = PVE::TrafficD::Config::load_options();
        my $usage = PVE::TrafficD::Usage::cluster_usage(PVE::INotify::nodename());

        my $res = [];
        for my $vmid (sort { $a <=> $b } keys %$all) {
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);
            my $conf = $all->{$vmid} or next;
            my $guest = $guests->{$vmid};
            for my $net (PVE::TrafficD::Config::sorted_nets($conf->{nics})) {
                my $nic = $conf->{nics}->{$net};
                my ($in, $out) = PVE::TrafficD::Usage::nic_total($usage, $vmid, $net, $nic->{'last-reset'});
                my $entry = {
                    PVE::TrafficD::Config::nic_api_data($nic, $opts, $in, $out)->%*,
                    vmid => $vmid + 0,
                    net => $net,
                };
                if ($guest) {
                    $entry->{node} = $guest->{node};
                } else {
                    $entry->{orphan} = 1;
                }
                push @$res, $entry;
            }
        }

        return $res;
    },
});

1;
