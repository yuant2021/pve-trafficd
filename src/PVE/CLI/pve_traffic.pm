package PVE::CLI::pve_traffic;

use strict;
use warnings;

use PVE::CLIFormatter;
use PVE::CLIHandler;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::API2::TrafficD;
use PVE::API2::TrafficD::VM;
use PVE::TrafficD::Config;
use PVE::TrafficD::Limit;
use PVE::TrafficD::Netlink;
use PVE::TrafficD::Usage;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

__PACKAGE__->register_method({
    name => 'status',
    path => 'status',
    method => 'GET',
    description => "Show the tap devices pve-trafficd tracks on this node, with this node's share"
        . " of the traffic of the current counting period.",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                device => { type => 'string' },
                vmid => get_standard_option('pve-vmid'),
                net => { type => 'string' },
                counted => { type => 'boolean' },
                netin => { type => 'integer', renderer => 'bytes', optional => 1 },
                netout => { type => 'integer', renderer => 'bytes', optional => 1 },
            },
        },
    },
    code => sub {
        my $state = PVE::TrafficD::Usage::read_state();
        die "no state of pve-trafficd found - is it running?\n" if !$state;

        my $age = time() - ($state->{time} // 0);
        warn "WARNING: state is $age seconds old - is pve-trafficd running?\n" if $age > 30;

        my $usage = PVE::TrafficD::Usage::usage_of($state);
        my $res = [];
        for my $tap (values %{ $state->{taps} // {} }) {
            my ($vmid, $idx) = ($tap->{name} // '') =~ $PVE::TrafficD::Netlink::TAP_RE or next;
            my $net = "net$idx";
            my $nic = PVE::TrafficD::Config::load_vm_config($vmid)->{nics}->{$net};
            my $entry = { device => $tap->{name}, vmid => $vmid + 0, net => $net, counted => 0 };
            if ($nic && !$nic->{deleted}) {
                $entry->{counted} = 1;
                my $own = $usage->{$vmid}->{$net};
                my $current = $own && $own->{reset} eq $nic->{'last-reset'};
                $entry->{netin} = $current ? $own->{in} : 0;
                $entry->{netout} = $current ? $own->{out} : 0;
            }
            push @$res, $entry;
        }

        return [sort { $a->{vmid} <=> $b->{vmid} || $a->{device} cmp $b->{device} } @$res];
    },
});

__PACKAGE__->register_method({
    name => 'cleanup',
    path => 'cleanup',
    method => 'POST',
    description => "Lift all traffic limits of guests on this node: restore the original rates and"
        . " finish pending removals. Used when uninstalling; stop pve-trafficd first, or it"
        . " applies the limits again.",
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'null' },
    code => sub {
        my $errors = PVE::TrafficD::Limit::lift_all_local($nodename, sub { print "$_[0]\n" });
        die join('', @$errors) if @$errors;
        return undef;
    },
});

my $nic_columns = [
    'used', 'quota', 'netin', 'netout', 'effective-direction', 'effective-rate', 'last-reset',
    'limited',
];

my $print_list = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result(
        $data, $schema, ['vmid', 'net', 'node', @$nic_columns], $options,
    );
};

my $print_vm = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result(
        $data, $schema, ['net', 'configured', @$nic_columns, 'nic-rate', 'missing'], $options,
    );
};

my $print_object = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
};

my $print_options = sub {
    my ($data, $schema, $options) = @_;
    my $effective = {
        rate => $data->{rate} // $PVE::TrafficD::Config::DEFAULT_RATE,
        direction => $data->{direction} // $PVE::TrafficD::Config::DEFAULT_DIRECTION,
    };
    PVE::CLIFormatter::print_api_result($effective, $schema, undef, $options);
};

my $print_status = sub {
    my ($data, $schema, $options) = @_;
    PVE::CLIFormatter::print_api_result(
        $data, $schema, ['device', 'vmid', 'net', 'counted', 'netin', 'netout'], $options,
    );
};

my $std = $PVE::RESTHandler::standard_output_options;

our $cmddef = {
    list => ['PVE::API2::TrafficD', 'list_vms', [], {}, $print_list, $std],
    show => ['PVE::API2::TrafficD::VM', 'index', ['vmid'], {}, $print_vm, $std],
    get => ['PVE::API2::TrafficD::VM', 'read_nic', ['vmid', 'net'], {}, $print_object, $std],
    set => ['PVE::API2::TrafficD::VM', 'update_nic', ['vmid', 'net']],
    delete => ['PVE::API2::TrafficD::VM', 'delete_nic', ['vmid', 'net']],
    reset => ['PVE::API2::TrafficD::VM', 'reset_nic', ['vmid', 'net'], {}, $print_object, $std],
    options => {
        get => ['PVE::API2::TrafficD', 'get_options', [], {}, $print_options, $std],
        set => ['PVE::API2::TrafficD', 'set_options', []],
    },
    status => [__PACKAGE__, 'status', [], {}, $print_status, $std],
    cleanup => [__PACKAGE__, 'cleanup', []],
};

1;
