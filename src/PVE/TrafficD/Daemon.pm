package PVE::TrafficD::Daemon;

# pve-trafficd: counts the traffic of the guest tap devices on this node and keeps
# the rate limits of the guests whose config is on this node in line with their
# quota.
#
#  - counters: a link dump every $POLL_INTERVAL seconds, plus the final counters
#    of every tap device that goes away (RTM_DELLINK: guest stopped, crashed,
#    migrated away, NIC removed). Baselines are kept per device instance
#    (ifindex) in /run, so a daemon restart neither loses nor double counts.
#  - totals of this node: /run state after every poll (read by the API on this
#    node), node file in pmxcfs plus a local copy every $FLUSH_INTERVAL seconds,
#    within a second after guests stopped, and when the daemon stops.
#  - limits: checked every $CHECK_INTERVAL seconds, see PVE::TrafficD::Limit.
#  - host shutdown: the unit is ordered before pve-guests.service and qemu.slice,
#    so it is stopped only after all guests are and writes everything out.

use strict;
use warnings;

use List::Util qw(max min);
use Time::HiRes qw(time);

use PVE::Cluster;
use PVE::INotify;
use PVE::SafeSyslog;
use PVE::Tools;

use PVE::TrafficD::Config;
use PVE::TrafficD::Limit;
use PVE::TrafficD::Netlink;
use PVE::TrafficD::Usage;

our $CHECK_INTERVAL = 1;
our $POLL_INTERVAL = 5;
our $FLUSH_INTERVAL = 20;
our $RECHECK_INTERVAL = 60; # verify the guest rates of all limited NICs
our $GC_INTERVAL = 600;
my $RETRY_DELAY = 5;
my $REPORT_AFTER = 30; # guests are locked for a while e.g. by a migration, only log lasting errors
my $GONE_POLLS = 3; # forget a device missing from this many dumps (lost notification)

sub log_info {
    my ($msg) = @_;
    chomp($msg);
    syslog('info', '%s', $msg);
}

sub log_err {
    my ($msg) = @_;
    chomp($msg);
    syslog('err', '%s', $msg);
}

sub new {
    my ($class) = @_;

    return bless {
        node => PVE::INotify::nodename(),
        boot => PVE::TrafficD::Usage::boot_id(),
        taps => {}, # ifindex => { name, rx, tx, missing }
        usage => {}, # this node's totals, see PVE::TrafficD::Usage
        configs => {}, # vmid => { key => stat key, conf => trafficd config or undef }
        configs_loaded => 0,
        options => {},
        options_key => undef,
        guests => {}, # pmxcfs guest list
        vm_version => {}, # vmid => guest config version, to notice changes
        remote => {}, # node => { key, usage } of the other nodes' files
        verify => {}, # vmid => 1: check the guest rates of its limited NICs
        failed => {}, # "vmid/net" => { since, retry } after an error
        early_dels => [], # final counters received before the first link dump
        same_boot => 0, # baselines of an earlier daemon of this boot were found
        startup_max_ifindex => 0, # devices up to this one existed before we started
        dirty => 0, # usage changed since the last flush
        state_dirty => 1,
        urgent_flush => 0,
        last_flush => 0,
        next_check => 0,
        next_poll => 0,
        next_recheck => 0,
        next_gc => time() + 60,
        errors => {},
    }, $class;
}

# log an error once (until it changes or is resolved, $msg undef)
sub report {
    my ($self, $key, $msg) = @_;

    my $old = $self->{errors}->{$key};
    if (defined($msg)) {
        chomp($msg);
        log_err($msg) if !defined($old) || $old ne $msg;
        $self->{errors}->{$key} = $msg;
    } elsif (defined($old)) {
        delete $self->{errors}->{$key};
        log_info("resolved: $old");
    }
}

sub guarded {
    my ($self, $key, $code) = @_;
    eval { $code->() };
    $self->report($key, $@ ? "$key: $@" : undef);
}

## configs

my sub stat_key {
    my ($path) = @_;
    my @st = stat($path);
    return @st ? "$st[1]:$st[9]:$st[7]" : '';
}

my sub tap_nic {
    my ($name) = @_;
    my ($vmid, $idx) = $name =~ $PVE::TrafficD::Netlink::TAP_RE or return;
    return ($vmid + 0, "net$idx");
}

sub tap_vmids {
    my ($self) = @_;
    my %res;
    for my $tap (values $self->{taps}->%*) {
        my ($vmid) = tap_nic($tap->{name});
        $res{$vmid} = 1 if defined($vmid);
    }
    return keys %res;
}

sub owned_vmids {
    my ($self) = @_;
    my $guests = $self->{guests};
    return grep {
        $guests->{$_}->{node} eq $self->{node} && ($guests->{$_}->{type} // '') eq 'qemu'
    } keys %$guests;
}

# trafficd config of a guest from the cache, (re)loaded if the file changed
sub vm_config {
    my ($self, $vmid) = @_;

    my $key = stat_key(PVE::TrafficD::Config::vm_config_path($vmid));
    my $cached = $self->{configs}->{$vmid};
    return $cached->{conf} if $cached && $cached->{key} eq $key;

    my $conf = $key eq '' ? undef : PVE::TrafficD::Config::load_vm_config($vmid);
    $self->{configs}->{$vmid} = { key => $key, conf => $conf };
    return $conf;
}

my sub periods {
    my ($conf) = @_;
    return '' if !$conf;
    my $nics = $conf->{nics};
    return join(',', map { "$_=$nics->{$_}->{'last-reset'}" } sort keys %$nics);
}

# Re-read what changed in pmxcfs. Returns false if pmxcfs is not available.
sub refresh {
    my ($self) = @_;

    return 0 if !PVE::Cluster::check_cfs_is_mounted(1);
    PVE::Cluster::cfs_update(1);
    my $vmlist = PVE::Cluster::get_vmlist();
    die "unable to read the guest list from pmxcfs\n" if !defined($vmlist->{version});
    $self->{guests} = $vmlist->{ids} // {};

    my $okey = stat_key($PVE::TrafficD::Config::OPTIONS_CFG);
    if (!defined($self->{options_key}) || $okey ne $self->{options_key}) {
        $self->{options} = PVE::TrafficD::Config::load_options();
        $self->{options_key} = $okey;
        $self->{verify}->{$_} = 1 for keys $self->{configs}->%*;
    }

    my %taps = map { $_ => 1 } $self->tap_vmids();
    my %relevant = (%taps, map { $_ => 1 } $self->owned_vmids());

    # A new counting period of a NIC with traffic here: count what happened so far
    # into the old period first.
    my $poll_first = 0;
    for my $vmid (keys %taps) {
        my $cached = $self->{configs}->{$vmid} or next;
        my $key = stat_key(PVE::TrafficD::Config::vm_config_path($vmid));
        next if $key eq $cached->{key};
        my $conf = $key eq '' ? undef : PVE::TrafficD::Config::load_vm_config($vmid);
        $poll_first = 1 if periods($conf) ne periods($cached->{conf});
    }
    $self->poll() if $poll_first && $self->{configs_loaded};

    my $configs = {};
    for my $vmid (keys %relevant) {
        my $old = $self->{configs}->{$vmid};
        my $conf = $self->vm_config($vmid);
        $configs->{$vmid} = $self->{configs}->{$vmid};
        $self->{verify}->{$vmid} = 1 if !$old || $old->{key} ne $configs->{$vmid}->{key};
    }
    $self->{configs} = $configs;
    $self->{configs_loaded} = 1;

    for my $vmid ($self->owned_vmids()) {
        my $version = $self->{guests}->{$vmid}->{version} // 0;
        my $old = $self->{vm_version}->{$vmid};
        $self->{verify}->{$vmid} = 1 if !defined($old) || $old != $version;
        $self->{vm_version}->{$vmid} = $version;
    }
    for my $vmid (keys $self->{vm_version}->%*) {
        delete $self->{vm_version}->{$vmid} if !$relevant{$vmid};
    }

    $self->refresh_remote();

    return 1;
}

# usage files of the other nodes
sub refresh_remote {
    my ($self) = @_;

    my $remote = {};
    my $dir = $PVE::TrafficD::Usage::USAGE_DIR;
    if (-d $dir) {
        PVE::Tools::dir_glob_foreach(
            $dir,
            '([a-zA-Z0-9][a-zA-Z0-9\-.]*)\.json',
            sub {
                my (undef, $node) = @_;
                return if $node eq $self->{node};
                my $path = "$dir/$node.json";
                my $key = stat_key($path);
                my $old = $self->{remote}->{$node};
                if ($old && $old->{key} eq $key) {
                    $remote->{$node} = $old;
                } else {
                    my $usage = PVE::TrafficD::Usage::usage_of(PVE::TrafficD::Usage::read_json($path));
                    $remote->{$node} = { key => $key, usage => $usage };
                }
            },
        );
    }
    $self->{remote} = $remote;
}

## counters

sub account {
    my ($self, $name, $drx, $dtx) = @_;

    return if !$drx && !$dtx;
    my ($vmid, $net) = tap_nic($name) or return;

    # cached for every guest with a tap here, except for taps younger than a second
    my $conf;
    if (my $cached = $self->{configs}->{$vmid}) {
        $conf = $cached->{conf};
    } else {
        $conf = eval { $self->vm_config($vmid) };
        if (my $err = $@) {
            log_err("VM $vmid $net: traffic not counted, unable to read config - $err");
            return;
        }
    }
    my $nic = $conf ? $conf->{nics}->{$net} : undef;
    return if !$nic || $nic->{deleted}; # not counted

    my $token = $nic->{'last-reset'};
    my $entry = $self->{usage}->{$vmid}->{$net};
    if (!$entry || $entry->{reset} ne $token) {
        $entry = $self->{usage}->{$vmid}->{$net} = { reset => $token, in => 0, out => 0 };
    }
    # device rx is what the guest sent
    $entry->{in} += $dtx;
    $entry->{out} += $drx;

    $self->{dirty} = 1;
    $self->{state_dirty} = 1;
}

# Is a device without baseline new, i.e. all of its traffic still uncounted?
sub device_is_new {
    my ($self, $ifindex) = @_;
    return $self->{same_boot} || $ifindex > $self->{startup_max_ifindex};
}

sub update_device {
    my ($self, $link) = @_;

    my $tap = $self->{taps}->{ $link->{index} };
    if (!$tap) {
        my $new = $self->device_is_new($link->{index});
        $tap = $self->{taps}->{ $link->{index} } = {
            name => $link->{name},
            rx => $new ? 0 : $link->{rx},
            tx => $new ? 0 : $link->{tx},
        };
        my ($vmid) = tap_nic($link->{name});
        $self->{verify}->{$vmid} = 1; # guest started or NIC added
    }
    delete $tap->{missing};

    my ($drx, $dtx) = ($link->{rx} - $tap->{rx}, $link->{tx} - $tap->{tx});
    ($drx, $dtx) = (0, 0) if $drx < 0 || $dtx < 0; # not the device we think it is

    $self->account($link->{name}, $drx, $dtx);
    ($tap->{rx}, $tap->{tx}) = ($link->{rx}, $link->{tx});
    $self->{state_dirty} = 1;
}

# final counters of a device that is gone
sub device_removed {
    my ($self, $link) = @_;

    my ($drx, $dtx);
    if (my $tap = delete $self->{taps}->{ $link->{index} }) {
        ($drx, $dtx) = ($link->{rx} - $tap->{rx}, $link->{tx} - $tap->{tx});
        ($drx, $dtx) = (0, 0) if $drx < 0 || $dtx < 0;
    } elsif ($self->device_is_new($link->{index})) {
        # lived shorter than a poll interval
        ($drx, $dtx) = ($link->{rx}, $link->{tx});
    } else {
        return;
    }

    $self->account($link->{name}, $drx, $dtx);
    $self->{state_dirty} = 1;
    $self->{urgent_flush} = 1;
}

sub poll {
    my ($self) = @_;

    # notifications first, they belong to devices that are not in the dump anymore
    $self->process_events();

    my $links = PVE::TrafficD::Netlink::dump_links();
    my %seen;
    for my $link (@$links) {
        $seen{ $link->{index} } = 1;
        $self->update_device($link);
    }
    for my $ifindex (keys $self->{taps}->%*) {
        next if $seen{$ifindex};
        # normally the removal notification is still on its way
        delete $self->{taps}->{$ifindex} if ++$self->{taps}->{$ifindex}->{missing} >= $GONE_POLLS;
    }
    $self->{state_dirty} = 1;
}

sub process_events {
    my ($self) = @_;

    my ($events, $overflow) = PVE::TrafficD::Netlink::read_events($self->{events});
    for my $event (@$events) {
        if ($event->{type} eq 'del') {
            if ($self->{configs_loaded}) {
                $self->device_removed($event);
            } else {
                push $self->{early_dels}->@*, $event;
            }
        } elsif (!$self->{taps}->{ $event->{index} }) {
            # a guest starts or gets a NIC: check its limit right away
            my ($vmid) = tap_nic($event->{name});
            $self->{verify}->{$vmid} = 1;
            $self->{next_check} = 0;
        }
    }
    if ($overflow) {
        $self->report('events', "link notifications were lost, final counters of stopped guests"
            . " may be incomplete");
        $self->{next_poll} = 0;
    }
}

sub nic_total {
    my ($self, $vmid, $net, $token) = @_;

    my $by_node = { map { $_ => $self->{remote}->{$_}->{usage} } keys $self->{remote}->%* };
    $by_node->{ $self->{node} } = $self->{usage};
    return PVE::TrafficD::Usage::nic_total($by_node, $vmid, $net, $token);
}

## persistence

sub write_state {
    my ($self) = @_;

    my $state = {
        boot => $self->{boot},
        node => $self->{node},
        time => int(time()),
        taps => $self->{taps},
        usage => $self->{usage},
    };
    mkdir($PVE::TrafficD::Usage::STATE_DIR, 0755);
    PVE::Tools::file_set_contents(
        $PVE::TrafficD::Usage::STATE_FILE, PVE::TrafficD::Usage::encode($state), 0644,
    );
    $self->{state_dirty} = 0;
}

# Write this node's totals: always to the local copy, to pmxcfs when it is
# writable (quorate), else again next time.
sub flush {
    my ($self) = @_;

    my $raw = PVE::TrafficD::Usage::encode({
        node => $self->{node},
        time => int(time()),
        usage => $self->{usage},
    });

    $self->{last_flush} = time();

    mkdir($PVE::TrafficD::Usage::LIB_DIR, 0755);
    PVE::Tools::file_set_contents($PVE::TrafficD::Usage::LIB_USAGE, $raw, 0644);

    return if !PVE::Cluster::check_cfs_quorum(1);

    mkdir($PVE::TrafficD::Config::CFG_DIR);
    mkdir($PVE::TrafficD::Usage::USAGE_DIR);
    PVE::Tools::file_set_contents(PVE::TrafficD::Usage::node_file($self->{node}), $raw);

    $self->{dirty} = 0;
    $self->{urgent_flush} = 0;
}

## limits

sub enforce {
    my ($self, $now) = @_;

    return if !$self->{configs_loaded} || !PVE::Cluster::check_cfs_quorum(1);

    my $recheck = $now >= $self->{next_recheck};
    $self->{next_recheck} = $now + $RECHECK_INTERVAL if $recheck;

    my $guests = $self->{guests};
    for my $vmid (sort { $a <=> $b } keys $self->{configs}->%*) {
        my $conf = $self->{configs}->{$vmid}->{conf};
        my $guest = $guests->{$vmid};
        next if !$conf || !$guest || $guest->{node} ne $self->{node};
        next if ($guest->{type} // '') ne 'qemu';

        my $verify = delete($self->{verify}->{$vmid}) || $recheck;
        for my $net (PVE::TrafficD::Config::sorted_nets($conf->{nics})) {
            my $nic = $conf->{nics}->{$net};
            my $token = $nic->{'last-reset'};
            my ($in, $out) = $self->nic_total($vmid, $net, $token);
            my $want = PVE::TrafficD::Config::over_quota($nic, $self->{options}, $in, $out);
            my $limited = $nic->{limited} ? 1 : 0;
            my $key = "$vmid/$net";
            my $failed = $self->{failed}->{$key};
            if (!$nic->{deleted} && $want == $limited && !($limited && ($verify || $failed))) {
                if ($failed) { # resolved otherwise, e.g. by a reset
                    delete $self->{failed}->{$key};
                    $self->report("limit:$key", undef);
                }
                next;
            }
            next if $failed && $failed->{retry} > $now;

            my $usage = { reset => $token, in => $in, out => $out };
            my $msg = eval { PVE::TrafficD::Limit::sync_nic($vmid, $net, $usage) };
            if (my $err = $@) {
                $failed = $self->{failed}->{$key} //= { since => $now };
                $failed->{retry} = $now + $RETRY_DELAY;
                $self->report("limit:$key", "VM $vmid $net: unable to update the rate limit - $err")
                    if $now - $failed->{since} >= $REPORT_AFTER;
                next;
            }
            delete $self->{failed}->{$key};
            $self->report("limit:$key", undef);
            if ($msg) {
                log_info($msg);
                $self->{urgent_flush} = 1; # persist the counters the decision was based on
            }
        }
    }

    # guests not owned here or without config
    $self->{verify} = {};
}

## garbage collection

# Drop entries of old periods and removed configs from this node's totals, and
# finish removals of NIC configs whose guest is gone (nothing to restore).
sub gc {
    my ($self) = @_;

    return if !PVE::Cluster::check_cfs_is_mounted(1) || !-d $PVE::TrafficD::Config::CFG_DIR;

    for my $vmid (keys $self->{usage}->%*) {
        my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
        for my $net (keys $self->{usage}->{$vmid}->%*) {
            my $nic = $conf->{nics}->{$net};
            next if $nic && $nic->{'last-reset'} eq $self->{usage}->{$vmid}->{$net}->{reset};
            delete $self->{usage}->{$vmid}->{$net};
            $self->{dirty} = 1;
        }
        delete $self->{usage}->{$vmid} if !scalar(keys $self->{usage}->{$vmid}->%*);
    }

    return if !PVE::Cluster::check_cfs_quorum(1);

    my $guests = $self->{guests};
    for my $vmid (PVE::TrafficD::Config::configured_vmids()->@*) {
        next if $guests->{$vmid};
        my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
        next if !grep { $_->{deleted} } values $conf->{nics}->%*;
        PVE::TrafficD::Config::lock_config(sub {
            PVE::Cluster::cfs_update();
            return if (PVE::Cluster::get_vmlist()->{ids} // {})->{$vmid};
            my $conf = PVE::TrafficD::Config::load_vm_config($vmid);
            for my $net (keys $conf->{nics}->%*) {
                delete $conf->{nics}->{$net} if $conf->{nics}->{$net}->{deleted};
            }
            PVE::TrafficD::Config::write_vm_config($vmid, $conf);
        });
    }
}

## main loop

# Wait for pmxcfs, take over the state of an earlier daemon of this boot, the
# totals of this node and the first link dump.
sub startup {
    my ($self, $stop) = @_;

    # subscribe before the first dump, so no removal goes unnoticed
    $self->{events} = PVE::TrafficD::Netlink::open_events();

    my $state = PVE::TrafficD::Usage::read_state();
    if ($state && ($state->{node} // '') eq $self->{node}) {
        $self->{same_boot} = 1;
        for my $ifindex (keys %{ $state->{taps} // {} }) {
            my $tap = $state->{taps}->{$ifindex};
            next if $ifindex !~ m/^\d+$/ || ref($tap) ne 'HASH' || !defined($tap->{name});
            next if !defined(tap_nic($tap->{name}));
            next if ($tap->{rx} // '') !~ m/^\d+$/ || ($tap->{tx} // '') !~ m/^\d+$/;
            $self->{taps}->{$ifindex} = { name => $tap->{name}, rx => $tap->{rx} + 0, tx => $tap->{tx} + 0 };
        }
        PVE::TrafficD::Usage::merge_max($self->{usage}, PVE::TrafficD::Usage::usage_of($state));
    }
    PVE::TrafficD::Usage::merge_max(
        $self->{usage},
        PVE::TrafficD::Usage::usage_of(PVE::TrafficD::Usage::read_json($PVE::TrafficD::Usage::LIB_USAGE)),
    );

    my $waiting = 0;
    while (!$$stop) {
        my $ok = eval { $self->refresh() };
        last if $ok;
        log_info("waiting for pmxcfs" . ($@ ? " - $@" : '')) if !$waiting++;
        $self->process_events();
        sleep(1);
    }
    return if $$stop;

    PVE::TrafficD::Usage::merge_max(
        $self->{usage},
        PVE::TrafficD::Usage::usage_of(
            PVE::TrafficD::Usage::read_json(PVE::TrafficD::Usage::node_file($self->{node})),
        ),
    );

    # devices that already exist were (partly) counted by an earlier daemon of
    # this boot, or not at all (fresh install): count only from now on then
    my $links = PVE::TrafficD::Netlink::dump_links();
    my @indexes = map { $_->{index} } (@$links, $self->{early_dels}->@*);
    $self->{startup_max_ifindex} = max(0, @indexes);

    for my $event (splice($self->{early_dels}->@*)) {
        $self->device_removed($event);
    }
    my %seen;
    for my $link (@$links) {
        $seen{ $link->{index} } = 1;
        $self->update_device($link);
    }
    for my $ifindex (keys $self->{taps}->%*) {
        delete $self->{taps}->{$ifindex} if !$seen{$ifindex};
    }

    $self->{next_poll} = time() + $POLL_INTERVAL;
    $self->write_state();
    $self->{dirty} = 1; # publish the merged totals
}

sub tick {
    my ($self) = @_;

    my $now = time();

    $self->guarded('events', sub { $self->process_events() });

    if ($now >= $self->{next_check}) {
        $self->{next_check} = $now + $CHECK_INTERVAL;
        $self->guarded('config', sub { $self->refresh() or die "pmxcfs is not mounted\n" });
    }

    if ($now >= $self->{next_poll}) {
        $self->{next_poll} = $now + $POLL_INTERVAL;
        $self->guarded('counters', sub { $self->poll() });
    }

    $self->guarded('limits', sub { $self->enforce($now) });

    if ($self->{state_dirty}) {
        $self->guarded('state', sub { $self->write_state() });
    }

    if ($self->{dirty}) {
        my $due = $self->{last_flush} + ($self->{urgent_flush} ? 1 : $FLUSH_INTERVAL);
        $self->guarded('flush', sub { $self->flush() }) if $now >= $due;
    }

    if ($now >= $self->{next_gc}) {
        $self->{next_gc} = $now + $GC_INTERVAL;
        $self->guarded('gc', sub { $self->gc() });
    }
}

sub wait_for_events {
    my ($self) = @_;

    my $timeout = min($self->{next_check}, $self->{next_poll}) - time();
    $timeout = max(0, min($CHECK_INTERVAL, $timeout));

    my $rin = '';
    vec($rin, fileno($self->{events}), 1) = 1;
    select($rin, undef, undef, $timeout);
}

sub shutdown {
    my ($self) = @_;

    if ($self->{configs_loaded}) {
        $self->guarded('counters', sub { $self->poll() });
    }
    $self->guarded('state', sub { $self->write_state() });
    $self->guarded('flush', sub { $self->flush() }) if $self->{dirty};
}

sub run {
    my $self = __PACKAGE__->new();

    my $stop = 0;
    local $SIG{TERM} = sub { $stop = 1 };
    local $SIG{INT} = sub { $stop = 1 };
    local $SIG{HUP} = sub { $self->{next_recheck} = 0 };

    log_info("pve-trafficd started");

    $self->startup(\$stop);

    while (!$stop) {
        $self->wait_for_events();
        last if $stop;
        $self->tick();
    }

    $self->shutdown();

    log_info("pve-trafficd stopped");
}

1;
