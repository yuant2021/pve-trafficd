package PVE::TrafficD::Usage;

# Traffic counters. Each node counts the traffic of the tap devices it hosts and
# keeps its own totals per guest NIC and counting period:
#
#   { <vmid> => { <netX> => { reset => <last-reset of the NIC config>, in => bytes, out => bytes } } }
#
# 'in' is what the guest received, 'out' what it sent. Stored in:
#
#   /etc/pve/trafficd/usage/<node>.json   written by that node only, so no cluster lock
#   /var/lib/pve-trafficd/usage.json      local copy, survives a reboot without quorum
#   /run/pve-trafficd/state.json          daemon state of the running boot: tap device
#                                         baselines and the latest totals (every few seconds)
#
# The traffic of a NIC is the sum over all nodes of the entries of its current
# period. It follows the guest through migrations, survives the guest being
# destroyed and re-created and the failure of a node (minus what that node had not
# flushed yet). A reset just starts a new period, older entries are ignored and
# garbage collected by their node.

use strict;
use warnings;

use JSON;

use PVE::Tools;

our $USAGE_DIR = '/etc/pve/trafficd/usage';
our $LIB_DIR = '/var/lib/pve-trafficd';
our $LIB_USAGE = "$LIB_DIR/usage.json";
our $STATE_DIR = '/run/pve-trafficd';
our $STATE_FILE = "$STATE_DIR/state.json";

my $json = JSON->new->utf8->canonical;

sub encode {
    my ($data) = @_;
    return $json->encode($data);
}

sub read_json {
    my ($path) = @_;

    return undef if !-f $path;
    my $raw = eval { PVE::Tools::file_get_contents($path, 64 * 1024 * 1024) };
    if (my $err = $@) {
        warn "unable to read '$path' - $err";
        return undef;
    }
    my $data = eval { $json->decode($raw) };
    if ($@ || ref($data) ne 'HASH') {
        warn "ignoring invalid '$path'\n";
        return undef;
    }
    return $data;
}

sub boot_id {
    my $id = PVE::Tools::file_read_firstline('/proc/sys/kernel/random/boot_id') // '';
    chomp($id);
    return $id;
}

sub node_file {
    my ($node) = @_;
    ($node) = ($node // '') =~ m/^([a-zA-Z0-9][a-zA-Z0-9\-.]*)$/ or die "invalid node name\n";
    return "$USAGE_DIR/$node.json";
}

# usage hash of a node file / local copy / state
sub usage_of {
    my ($data) = @_;
    my $usage = ref($data) eq 'HASH' ? $data->{usage} : undef;
    return ref($usage) eq 'HASH' ? $usage : {};
}

# newer period? Ids are "<sec>.<fraction>" strings (6 digits when we create them).
sub token_newer {
    my ($a, $b) = @_;
    my ($as, $af) = split(/\./, $a, 2);
    my ($bs, $bf) = split(/\./, $b, 2);
    return $as > $bs if $as != $bs;
    return substr(($af // '') . '000000', 0, 6) > substr(($bf // '') . '000000', 0, 6);
}

my sub valid_entry {
    my ($entry) = @_;
    return ref($entry) eq 'HASH'
        && defined($entry->{reset})
        && $entry->{reset} =~ m/^\d+(?:\.\d+)?$/
        && ($entry->{in} // '') =~ m/^\d+$/
        && ($entry->{out} // '') =~ m/^\d+$/;
}

# Merge usage $src into $dst. Counters only grow within a period, so for the same
# period the larger value is the more recent one; a newer period replaces an older.
sub merge_max {
    my ($dst, $src) = @_;

    for my $vmid (keys %{ $src // {} }) {
        next if $vmid !~ m/^\d+$/ || ref($src->{$vmid}) ne 'HASH';
        for my $net (keys $src->{$vmid}->%*) {
            my $entry = $src->{$vmid}->{$net};
            next if $net !~ m/^net\d+$/ || !valid_entry($entry);

            my $cur = $dst->{$vmid}->{$net};
            if (!$cur || token_newer($entry->{reset}, $cur->{reset})) {
                $dst->{$vmid}->{$net} = {
                    reset => "$entry->{reset}",
                    in => $entry->{in} + 0,
                    out => $entry->{out} + 0,
                };
            } elsif ($entry->{reset} eq $cur->{reset}) {
                $cur->{in} = $entry->{in} + 0 if $entry->{in} > $cur->{in};
                $cur->{out} = $entry->{out} + 0 if $entry->{out} > $cur->{out};
            }
        }
    }

    return $dst;
}

# (in, out) of a NIC in period $token, summed over { node => usage }
sub nic_total {
    my ($by_node, $vmid, $net, $token) = @_;

    my ($in, $out) = (0, 0);
    return ($in, $out) if !defined($token);
    for my $usage (values %$by_node) {
        my $entry = $usage->{$vmid}->{$net} or next;
        next if $entry->{reset} ne $token;
        $in += $entry->{in};
        $out += $entry->{out};
    }
    return ($in, $out);
}

# { node => usage } of all node files
sub read_node_files {
    my $res = {};
    return $res if !-d $USAGE_DIR;
    PVE::Tools::dir_glob_foreach(
        $USAGE_DIR,
        '([a-zA-Z0-9][a-zA-Z0-9\-.]*)\.json',
        sub {
            my (undef, $node) = @_;
            $res->{$node} = usage_of(read_json("$USAGE_DIR/$node.json"));
        },
    );
    return $res;
}

# Daemon state of the running boot, or undef.
sub read_state {
    my $state = read_json($STATE_FILE) or return undef;
    return undef if ($state->{boot} // '') ne boot_id();
    return $state;
}

# Best known usage of all nodes for the API: the node files, with the totals of
# this node's daemon (refreshed every few seconds) for the local node.
sub cluster_usage {
    my ($nodename) = @_;

    my $res = read_node_files();
    if (my $state = read_state()) {
        if (($state->{node} // '') eq $nodename) {
            $res->{$nodename} = merge_max($res->{$nodename} // {}, usage_of($state));
        }
    }
    return $res;
}

1;
