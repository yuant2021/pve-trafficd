package PVE::TrafficD::Netlink;

# Minimal rtnetlink client for the counters of guest tap devices: link dumps and
# link notifications, both with the 64 bit device statistics. The RTM_DELLINK
# notification of a device carries its final counters, so the traffic of a guest
# is complete although its tap device is gone by the time anybody could read /sys.
#
# Device counters are from the host's point of view: rx is what the guest sent,
# tx what it received.

use strict;
use warnings;

use Errno qw(EAGAIN EINTR ENOBUFS EWOULDBLOCK);
use IO::Handle;
use Socket qw(SOCK_RAW SOL_SOCKET SO_RCVBUF);

use constant {
    AF_NETLINK => 16,
    NETLINK_ROUTE => 0,
    RTMGRP_LINK => 1,
    NLMSG_ERROR => 2,
    NLMSG_DONE => 3,
    RTM_NEWLINK => 16,
    RTM_DELLINK => 17,
    RTM_GETLINK => 18,
    NLM_F_REQUEST => 0x1,
    NLM_F_DUMP => 0x300,
    IFLA_IFNAME => 3,
    IFLA_STATS64 => 23,
    SO_RCVBUFFORCE => 33,
};

our $TAP_RE = qr/^tap(\d+)i(\d+)$/;

my $EVENT_RCVBUF = 8 * 1024 * 1024;
my $DUMP_TIMEOUT = 10;

my sub open_socket {
    my ($groups) = @_;

    socket(my $sock, AF_NETLINK, SOCK_RAW, NETLINK_ROUTE)
        or die "unable to create netlink socket - $!\n";
    bind($sock, pack('S S L L', AF_NETLINK, 0, 0, $groups))
        or die "unable to bind netlink socket - $!\n";

    return $sock;
}

# One link message (ifinfomsg at $off, message ends at $end), tap devices only:
# { index, name, rx, tx }
my sub parse_link {
    my ($buf, $off, $end) = @_;

    my $index = unpack('x' . ($off + 4) . ' l', $buf);
    my ($name, $rx, $tx);

    my $attr = $off + 16;
    while ($attr + 4 <= $end) {
        my ($len, $type) = unpack("x$attr S S", $buf);
        last if $len < 4 || $attr + $len > $end;
        $type &= 0x3fff; # NLA_F_NESTED, NLA_F_NET_BYTEORDER

        if ($type == IFLA_IFNAME) {
            $name = unpack('x' . ($attr + 4) . ' Z' . ($len - 4), $buf);
            return undef if $name !~ $TAP_RE;
        } elsif ($type == IFLA_STATS64 && $len >= 4 + 32) {
            # rx_packets, tx_packets, rx_bytes, tx_bytes
            (undef, undef, $rx, $tx) = unpack('x' . ($attr + 4) . ' Q Q Q Q', $buf);
        }
        last if defined($name) && defined($rx);

        $attr += ($len + 3) & ~3;
    }

    return undef if !defined($name) || !defined($rx);
    return { index => $index, name => $name, rx => $rx, tx => $tx };
}

# Parse a buffer of netlink messages. Tap device link messages are pushed to
# @$links as { type => 'new'|'del', index, name, rx, tx }. Returns (done, errno)
# for dump replies; messages with a sequence number other than $seq are ignored
# when $seq is given.
sub parse_messages {
    my ($buf, $links, $seq) = @_;

    my ($done, $errno) = (0, 0);
    my $total = length($buf);
    my $off = 0;

    while ($off + 16 <= $total) {
        my ($len, $type, undef, $msg_seq) = unpack("x$off L S S L", $buf);
        last if $len < 16 || $off + $len > $total;

        if (!defined($seq) || $msg_seq == $seq) {
            if ($type == NLMSG_DONE) {
                $done = 1;
            } elsif ($type == NLMSG_ERROR) {
                $errno = -unpack('x' . ($off + 16) . ' l', $buf);
                $done = 1;
            } elsif (($type == RTM_NEWLINK || $type == RTM_DELLINK) && $len >= 32) {
                if (my $link = parse_link($buf, $off + 16, $off + $len)) {
                    $link->{type} = $type == RTM_DELLINK ? 'del' : 'new';
                    push @$links, $link;
                }
            }
        }

        $off += ($len + 3) & ~3;
    }

    return ($done, $errno);
}

# All tap devices with their counters: [{ index, name, rx, tx }, ...]
sub dump_links {
    my $sock = open_socket(0);

    my $seq = (time() ^ $$) & 0x7fffffff;
    my $req = pack('L S S L L', 32, RTM_GETLINK, NLM_F_REQUEST | NLM_F_DUMP, $seq, 0)
        . pack('C C S l L L', 0, 0, 0, 0, 0, 0);
    send($sock, $req, 0, pack('S S L L', AF_NETLINK, 0, 0, 0))
        or die "unable to send netlink dump request - $!\n";

    my $links = [];
    my $deadline = time() + $DUMP_TIMEOUT;
    while (1) {
        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        my $ready = select($rin, undef, undef, 1);
        if ($ready <= 0) {
            next if $ready < 0 && $! == EINTR && time() < $deadline;
            die "netlink link dump timed out\n" if time() >= $deadline;
            next;
        }

        my $buf;
        if (!defined(recv($sock, $buf, 1 << 20, 0))) {
            next if $! == EINTR;
            die "netlink receive failed - $!\n";
        }

        my ($done, $errno) = parse_messages($buf, $links, $seq);
        if ($errno) {
            local $! = $errno;
            die "netlink link dump failed - $!\n";
        }
        last if $done;
    }
    close($sock);

    delete $_->{type} for @$links;
    return $links;
}

# Non-blocking socket subscribed to link notifications.
sub open_events {
    my $sock = open_socket(RTMGRP_LINK);

    # a host shutdown stops all guests at once, do not drop their final counters
    setsockopt($sock, SOL_SOCKET, SO_RCVBUFFORCE, $EVENT_RCVBUF)
        or setsockopt($sock, SOL_SOCKET, SO_RCVBUF, $EVENT_RCVBUF);
    $sock->blocking(0);

    return $sock;
}

# Pending link notifications of tap devices. Returns ([events], $overflow), with
# $overflow set if the kernel dropped notifications (receive buffer full).
sub read_events {
    my ($sock) = @_;

    my ($events, $overflow) = ([], 0);
    while (1) {
        my $buf;
        if (!defined(recv($sock, $buf, 1 << 20, 0))) {
            last if $! == EAGAIN || $! == EWOULDBLOCK;
            next if $! == EINTR;
            if ($! == ENOBUFS) {
                $overflow = 1;
                next;
            }
            die "netlink receive failed - $!\n";
        }
        last if $buf eq '';
        parse_messages($buf, $events);
    }

    return ($events, $overflow);
}

1;
