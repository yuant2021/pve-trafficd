PACKAGE = pve-trafficd
VERSION = $(shell dpkg-parsechangelog -S Version)
DEB = $(PACKAGE)_$(VERSION)_all.deb

DESTDIR =
PERLDIR = /usr/share/perl5
SBINDIR = /usr/sbin
SHAREDIR = /usr/share/$(PACKAGE)
WWWDIR = /usr/share/pve-manager/js

PERL_MODULES = \
	PVE/TrafficD/Config.pm \
	PVE/TrafficD/Usage.pm \
	PVE/TrafficD/Netlink.pm \
	PVE/TrafficD/Limit.pm \
	PVE/TrafficD/Daemon.pm \
	PVE/API2/TrafficD.pm \
	PVE/API2/TrafficD/VM.pm \
	PVE/CLI/pve_traffic.pm

all:

.PHONY: install
install:
	for m in $(PERL_MODULES); do install -D -m 0644 src/$$m $(DESTDIR)$(PERLDIR)/$$m; done
	# replaces the module diverted in preinst, see debian/pve-trafficd.preinst
	install -D -m 0644 src/divert/PVE/API2/Cluster.pm $(DESTDIR)$(PERLDIR)/PVE/API2/Cluster.pm
	install -D -m 0755 src/bin/pve-traffic $(DESTDIR)$(SBINDIR)/pve-traffic
	install -D -m 0755 src/bin/pve-trafficd $(DESTDIR)$(SBINDIR)/pve-trafficd
	install -D -m 0644 src/www/pve-trafficd.js $(DESTDIR)$(WWWDIR)/pve-trafficd.js
	install -d $(DESTDIR)$(SHAREDIR)
	sed -e 's/@VERSION@/$(VERSION)/' src/share/index-patch > $(DESTDIR)$(SHAREDIR)/index-patch
	chmod 0755 $(DESTDIR)$(SHAREDIR)/index-patch

.PHONY: check test
check test:
	prove -Isrc -v test/

.PHONY: deb
deb:
	dpkg-buildpackage -b -us -uc
	mv ../$(DEB) .
	rm -f ../$(PACKAGE)_$(VERSION)_*.buildinfo ../$(PACKAGE)_$(VERSION)_*.changes

.PHONY: clean
clean:
	rm -rf debian/$(PACKAGE) debian/.debhelper debian/files debian/*.substvars debian/*.debhelper debian/*.debhelper.log debian/debhelper-build-stamp
	rm -f $(PACKAGE)_*.deb
