package PVE::TrafficD::Config;

# Configuration of pve-trafficd, stored in the cluster file system:
#
#   /etc/pve/trafficd/options.cfg   cluster wide defaults (limit rate, counted direction)
#   /etc/pve/trafficd/<vmid>.cfg    counted NICs of one guest, one line per NIC:
#
#     net0: last-reset=1791763200.000123,direction=both,quota=1099511627776,rate=1
#
# 'last-reset' is the start of the counting period (epoch with microseconds). It
# doubles as the period id the counters are stored under, see PVE::TrafficD::Usage.
#
# The node owning the guest adds the limit state to the line: 'limited=1' while
# the guest NIC rate is lowered, 'orig-rate' (the NIC rate before, absent if there
# was none) and 'applied' (the rate set). 'deleted=1' marks a NIC whose config was
# removed while limited: the daemon restores the original rate and drops the line.
#
# Nothing in here is removed when a guest is destroyed: a guest re-created with the
# same VMID (reinstall) continues with its counters and limit.

use strict;
use warnings;

use Digest::SHA;
use Time::HiRes;

use PVE::JSONSchema;
use PVE::Tools;

our $CFG_DIR = '/etc/pve/trafficd';
our $OPTIONS_CFG = "$CFG_DIR/options.cfg";

our $DEFAULT_RATE = 1;
our $DEFAULT_DIRECTION = 'both';

our @DIRECTIONS = qw(both in out max);

## sizes

my $binary = { K => 1024, M => 1024**2, G => 1024**3, T => 1024**4, P => 1024**5 };
my $decimal = { K => 1000, M => 1000**2, G => 1000**3, T => 1000**4, P => 1000**5 };

# Bytes of a size string: plain bytes, or a number with unit. K/M/G/T/P with
# optional 'i'/'iB' are binary (like PVE disk sizes), KB/MB/GB/TB/PB decimal.
sub parse_size {
    my ($text) = @_;

    die "missing size\n" if !defined($text) || $text eq '';

    my ($num, $prefix, $suffix) = $text =~ m/^\s*(\d+(?:\.\d+)?)\s*(?:([KMGTP])(i|ib|b)?)?\s*$/i
        or die "invalid size '$text'\n";

    my $factor = 1;
    if (defined($prefix)) {
        $prefix = uc($prefix);
        $factor = (defined($suffix) && lc($suffix) eq 'b') ? $decimal->{$prefix} : $binary->{$prefix};
    }

    my $bytes = $num * $factor;
    die "size '$text' is too large\n" if $bytes >= 2**63;

    return int($bytes);
}

PVE::JSONSchema::register_format('pve-trafficd-size', \&verify_size);

sub verify_size {
    my ($value, $noerr) = @_;

    eval { parse_size($value) };
    if (my $err = $@) {
        return undef if $noerr;
        die $err;
    }
    return $value;
}

## schema

my $quota_desc = "Traffic quota of the counting period. When the counted traffic since the last"
    . " reset reaches it, the rate of the network device is set to the limit rate. Bytes, or with"
    . " unit: K, M, G, T, P are binary (1024), KB, MB, GB, TB, PB decimal (1000).";

my $rate_desc = "Rate limit (MB/s, like the rate of a network device) applied when the quota is"
    . " reached. If the device has a lower rate already, that one is kept.";

my $direction_desc = "Traffic counted against the quota: 'both' (received + sent by the guest),"
    . " 'in' (received), 'out' (sent) or 'max' (the larger of both).";

# NIC settings in the API (quota as size string)
my $nic_properties = {
    quota => {
        type => 'string',
        format => 'pve-trafficd-size',
        format_description => 'SIZE',
        description => $quota_desc,
        optional => 1,
    },
    rate => {
        type => 'number',
        minimum => 0.001,
        description => "$rate_desc Defaults to the cluster wide setting.",
        optional => 1,
    },
    direction => {
        type => 'string',
        enum => [@DIRECTIONS],
        description => "$direction_desc Defaults to the cluster wide setting.",
        optional => 1,
    },
};

sub nic_properties {
    return { map { $_ => {$nic_properties->{$_}->%*} } keys %$nic_properties };
}

# keys of a NIC the API may set or delete
our @NIC_SETTINGS = qw(quota rate direction);

# how a NIC is stored
my $nic_format = {
    quota => { type => 'integer', minimum => 0, optional => 1 },
    rate => { type => 'number', minimum => 0.001, optional => 1 },
    direction => { type => 'string', enum => [@DIRECTIONS], optional => 1 },
    'last-reset' => { type => 'string', pattern => '\d{1,12}(?:\.\d{1,6})?' },
    limited => { type => 'boolean', optional => 1 },
    'orig-rate' => { type => 'number', minimum => 0, optional => 1 },
    applied => { type => 'number', minimum => 0, optional => 1 },
    deleted => { type => 'boolean', optional => 1 },
};

my $option_properties = {
    rate => {
        type => 'number',
        minimum => 0.001,
        description => $rate_desc,
        default => $DEFAULT_RATE,
        optional => 1,
    },
    direction => {
        type => 'string',
        enum => [@DIRECTIONS],
        description => $direction_desc,
        default => $DEFAULT_DIRECTION,
        optional => 1,
    },
};

sub option_properties {
    return { map { $_ => {$option_properties->{$_}->%*} } keys %$option_properties };
}

## values

# canonical number string, e.g. '01.50' -> '1.5'
sub canonical_number {
    my ($value) = @_;
    return undef if !defined($value);
    return 0 + $value;
}

# New period id. Microseconds make it unique, also when a config is removed and
# created again right away (old counters must not come back).
sub new_reset_token {
    my ($old) = @_;

    while (1) {
        my ($sec, $usec) = Time::HiRes::gettimeofday();
        my $token = sprintf('%d.%06d', $sec, $usec);
        return $token if !defined($old) || $token ne $old;
        Time::HiRes::usleep(1);
    }
}

sub reset_time {
    my ($token) = @_;
    return undef if !defined($token);
    my ($sec) = $token =~ m/^(\d+)/;
    return defined($sec) ? $sec + 0 : undef;
}

sub effective_rate {
    my ($nic, $opts) = @_;
    return 0 + ($nic->{rate} // $opts->{rate} // $DEFAULT_RATE);
}

sub effective_direction {
    my ($nic, $opts) = @_;
    return $nic->{direction} // $opts->{direction} // $DEFAULT_DIRECTION;
}

# bytes counted against the quota
sub counted_bytes {
    my ($direction, $in, $out) = @_;

    return $in if $direction eq 'in';
    return $out if $direction eq 'out';
    return $in > $out ? $in : $out if $direction eq 'max';
    return $in + $out;
}

sub over_quota {
    my ($nic, $opts, $in, $out) = @_;

    return 0 if $nic->{deleted} || !defined($nic->{quota});
    return counted_bytes(effective_direction($nic, $opts), $in, $out) >= $nic->{quota} ? 1 : 0;
}

# API view of a NIC config and its traffic ($in/$out: bytes of the current period)
sub nic_api_data {
    my ($nic, $opts, $in, $out) = @_;

    my $direction = effective_direction($nic, $opts);
    my $res = {
        'effective-rate' => effective_rate($nic, $opts),
        'effective-direction' => $direction,
        'last-reset' => reset_time($nic->{'last-reset'}),
        netin => $in,
        netout => $out,
        used => counted_bytes($direction, $in, $out),
        exceeded => over_quota($nic, $opts, $in, $out),
        limited => $nic->{limited} ? 1 : 0,
    };
    $res->{quota} = $nic->{quota} + 0 if defined($nic->{quota});
    $res->{rate} = 0 + $nic->{rate} if defined($nic->{rate});
    $res->{direction} = $nic->{direction} if defined($nic->{direction});
    if ($nic->{limited}) {
        $res->{'orig-rate'} = 0 + $nic->{'orig-rate'} if defined($nic->{'orig-rate'});
        $res->{applied} = 0 + $nic->{applied} if defined($nic->{applied});
    }
    $res->{removing} = 1 if $nic->{deleted};

    return $res;
}

## parsing / writing

sub parse_nic {
    my ($value) = @_;

    my $nic = PVE::JSONSchema::parse_property_string($nic_format, $value);
    for my $key (qw(limited deleted)) {
        delete $nic->{$key} if !$nic->{$key};
    }
    if (!$nic->{limited}) {
        delete $nic->{$_} for qw(orig-rate applied);
    }
    for my $key (qw(rate orig-rate applied)) {
        $nic->{$key} = canonical_number($nic->{$key}) if defined($nic->{$key});
    }
    $nic->{quota} += 0 if defined($nic->{quota});

    return $nic;
}

sub print_nic {
    my ($nic) = @_;

    my $data = { map { $_ => $nic->{$_} } grep { defined($nic->{$_}) } keys %$nic_format };
    for my $key (qw(limited deleted)) {
        delete $data->{$key} if !$data->{$key};
    }
    if (!$data->{limited}) {
        delete $data->{$_} for qw(orig-rate applied);
    }

    return PVE::JSONSchema::print_property_string($data, $nic_format);
}

my sub sort_nets {
    return sort { ($a =~ s/^net//r) <=> ($b =~ s/^net//r) } @_;
}

sub sorted_nets {
    my ($nics) = @_;
    return sort_nets(keys %$nics);
}

# the key: value config format shared by both files
my sub parse_lines {
    my ($filename, $raw, $handler) = @_;

    for my $line (split(/\n/, $raw // '')) {
        next if $line =~ m/^\s*(?:#.*)?$/;
        if ($line =~ m/^([a-z][a-z0-9\-]*):\s*(\S.*?)\s*$/) {
            my ($key, $value) = ($1, $2);
            eval { $handler->($key, $value) };
            warn "$filename: ignoring '$key' - $@" if $@;
        } else {
            warn "$filename: ignoring invalid line '$line'\n";
        }
    }
}

sub parse_vm_config {
    my ($filename, $raw) = @_;

    my $conf = { nics => {}, digest => Digest::SHA::sha1_hex($raw // '') };

    parse_lines(
        $filename,
        $raw,
        sub {
            my ($key, $value) = @_;
            die "unknown key\n" if $key !~ m/^net\d+$/;
            $conf->{nics}->{$key} = parse_nic($value);
        },
    );

    return $conf;
}

sub write_vm_config_string {
    my ($conf) = @_;

    my $raw = '';
    for my $netid (sorted_nets($conf->{nics})) {
        $raw .= "$netid: " . print_nic($conf->{nics}->{$netid}) . "\n";
    }
    return $raw;
}

sub parse_options {
    my ($filename, $raw) = @_;

    my $opts = { digest => Digest::SHA::sha1_hex($raw // '') };

    parse_lines(
        $filename,
        $raw,
        sub {
            my ($key, $value) = @_;
            if ($key eq 'rate') {
                die "invalid rate\n" if $value !~ m/^\d+(?:\.\d+)?$/ || $value < 0.001;
                $value = canonical_number($value);
            } elsif ($key eq 'direction') {
                die "invalid direction\n" if !grep { $_ eq $value } @DIRECTIONS;
            } else {
                die "unknown option\n";
            }
            $opts->{$key} = $value;
        },
    );

    return $opts;
}

sub write_options_string {
    my ($opts) = @_;

    my $raw = '';
    for my $key (sort keys %$option_properties) {
        $raw .= "$key: $opts->{$key}\n" if defined($opts->{$key});
    }
    return $raw;
}

## file access

sub vm_config_path {
    my ($vmid) = @_;
    ($vmid) = ($vmid // '') =~ m/^(\d+)$/ or die "invalid VMID\n";
    return "$CFG_DIR/$vmid.cfg";
}

my sub read_file {
    my ($path) = @_;
    return undef if !-f $path;
    return PVE::Tools::file_get_contents($path);
}

sub load_vm_config {
    my ($vmid) = @_;

    my $path = vm_config_path($vmid);
    return parse_vm_config($path, read_file($path));
}

sub write_vm_config {
    my ($vmid, $conf) = @_;

    my $path = vm_config_path($vmid);
    my $raw = write_vm_config_string($conf);

    if ($raw eq '') {
        unlink($path) or $!{ENOENT} or die "unable to delete '$path' - $!\n";
    } else {
        mkdir($CFG_DIR) if !-d $CFG_DIR;
        PVE::Tools::file_set_contents($path, $raw);
    }
}

sub configured_vmids {
    my $res = [];
    return $res if !-d $CFG_DIR;
    PVE::Tools::dir_glob_foreach($CFG_DIR, '(\d+)\.cfg', sub { push @$res, $_[1] + 0 });
    return [sort { $a <=> $b } @$res];
}

sub load_all_vm_configs {
    my $res = {};
    for my $vmid (configured_vmids()->@*) {
        $res->{$vmid} = eval { load_vm_config($vmid) };
        warn $@ if $@;
    }
    return $res;
}

sub load_options {
    return parse_options($OPTIONS_CFG, read_file($OPTIONS_CFG));
}

sub write_options {
    my ($opts) = @_;
    mkdir($CFG_DIR) if !-d $CFG_DIR;
    PVE::Tools::file_set_contents($OPTIONS_CFG, write_options_string($opts));
}

# cluster wide lock for all writes to the config files
sub lock_config {
    my ($code, @param) = @_;

    require PVE::Cluster;
    my $res = PVE::Cluster::cfs_lock_domain('trafficd', 10, $code, @param);
    die $@ if $@;
    return $res;
}

sub assert_digest {
    my ($conf, $digest) = @_;
    PVE::Tools::assert_if_modified($conf->{digest}, $digest) if $digest;
}

## guest NIC helpers (qemu-server)

my sub net_module {
    if (eval { require PVE::QemuServer::Network; 1 } && PVE::QemuServer::Network->can('print_net')) {
        return 'PVE::QemuServer::Network';
    }
    require PVE::QemuServer;
    return 'PVE::QemuServer';
}

sub parse_qemu_net {
    my ($value) = @_;
    return undef if !defined($value);
    return net_module()->can('parse_net')->($value, 1);
}

sub print_qemu_net {
    my ($net) = @_;
    return net_module()->can('print_net')->($net);
}

1;
