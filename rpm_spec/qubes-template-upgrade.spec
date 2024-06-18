Name:           qubes-template-upgrade
Version:        0.9.0
Release:        1%{?dist}
Summary:        Upgrade tool for Qubes OS templates

License:        GPL-3.0
URL:            https://github.com/kennethrrosen/qubes-template-upgrade
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       python3, gtk3

%description
This tool provides a GUI and CLI for upgrading Fedora and Debian templates in Qubes OS.

%prep
%setup -q

%install
install -m 755 qubes-template-upgrade-gui %{buildroot}/bin/
install -m 755 qvm-template-upgrade %{buildroot}/bin/

%files
/usr/bin/qubes-template-upgrade-gui
/usr/bin/qvm-template-upgrade

%changelog
* Tue Jun 18 2024 Kenneth R. Rosen <kennethrrosen@proton.me> - 1.0.0-1
- Initial RPM release
