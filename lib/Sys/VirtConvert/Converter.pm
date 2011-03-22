# Sys::VirtConvert::Converter
# Copyright (C) 2009-2011 Red Hat Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

package Sys::VirtConvert::Converter;

use strict;
use warnings;

use Carp;

use Module::Pluggable sub_name => 'modules',
                      search_path => ['Sys::VirtConvert::Converter'],
                      require => 1;

use Locale::TextDomain 'virt-v2v';

use Sys::VirtConvert::Util;

=pod

=head1 NAME

Sys::VirtConvert::Converter - Convert a guest to run on KVM

=head1 SYNOPSIS

 use Sys::VirtConvert::Converter;

 Sys::VirtConvert::Converter->convert($g, $config, $desc, $dom, $devices);

=head1 DESCRIPTION

Sys::VirtConvert::Converter instantiates an appropriate backend for the target
guest OS, and uses it to convert the guest to run on KVM.

=head1 METHODS

=over

=cut

# Default values for a KVM configuration
use constant KVM_DEFAULT_XML => "
<domain type='kvm'>
  <os>
    <type machine='pc'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' port='-1' listen='127.0.0.1'/>
    <video>
      <model type='cirrus' vram='9216' heads='1'/>
    </video>
    <console type='pty'/>
  </devices>
</domain>
";

=item Sys::VirtConvert::Converter->convert(g, config, desc, dom, devices)

Instantiate an appropriate backend and call convert on it.

=over

=item g

A libguestfs handle to the target.

=item config

An initialised Sys::VirtConvert::Config object.

=item desc

The OS description returned by Sys::Guestfs::Lib.

=item dom

An XML::DOM object resulting from parsing the guests's libvirt domain XML.

=item devices

An arrayref of libvirt storage device names, in the order they will be presented
to the guest.

=back

=cut

sub convert
{
    my $class = shift;

    my ($g, $config, $desc, $dom, $devices) = @_;
    croak("convert called without g argument") unless defined($g);
    croak("convert called without config argument") unless defined($config);
    croak("convert called without desc argument") unless defined($desc);
    croak("convert called without dom argument") unless defined($dom);
    croak("convert called without devices argument") unless defined($devices);

    my $guestcaps;

    # Find a module which can convert the guest and run it
    foreach my $module ($class->modules()) {
        if($module->can_handle($desc)) {
            $guestcaps = $module->convert($g, $config, $desc, $dom, $devices);
            last;
        }
    }

    unless (defined($guestcaps)) {
        my $block = 'ide';
        my $net   = 'rtl8139';
        my $arch  = 'x86_64';

        logmsg WARN, __x('Unable to convert this guest operating system. Its '.
                         'storage will be transfered and a domain created for '.
                         'it, but it may not operate correctly without manual '.
                         'reconfiguration. The domain will present all '.
                         'storage devices as {block}, all network interfaces '.
                         'as {net} and the host as {arch}.',
                         block => $block, net => $net, arch => $arch);

        # Set some conservative defaults
        $guestcaps = {
            'arch'  => $arch,
            'block' => $block,
            'net'   => $net,
            'acpi'  => 1
        };
    }

    # Map network names from config
    _map_networks($dom, $config);

    # Convert the metadata
    _convert_metadata($dom, $desc, $devices, $guestcaps);

    return $guestcaps;
}

sub _convert_metadata
{
    my ($dom, $desc, $devices, $guestcaps) = @_;

    my $default_dom = new XML::DOM::Parser->parse(KVM_DEFAULT_XML);

    # Replace source hypervisor metadata with KVM defaults
    _unconfigure_hvs($dom, $default_dom);

    # Remove any configuration related to a PV kernel bootloader
    _unconfigure_bootloaders($dom);

    # Update storage devices and drivers
    _configure_storage($dom, $devices, $guestcaps->{block});

    # Configure network drivers
    _configure_network($dom, $guestcaps->{net});

    # Ensure guest has a standard set of default devices
    _configure_default_devices($dom, $default_dom);

    # Add a default os section if none exists
    _configure_os($dom, $default_dom, $guestcaps->{arch});

    # Check for weird configs and sanitise them
    _sanity_check($dom);
}

sub _configure_os
{
    my ($dom, $default_dom, $arch) = @_;

    my ($os) = $dom->findnodes('/domain/os');

    # If there's no os element, copy one from the default
    if(!defined($os)) {
        ($os) = $default_dom->findnodes('/domain/os');
        $os = $os->cloneNode(1);
        $os->setOwnerDocument($dom);

        my ($domain) = $dom->findnodes('/domain');
        $domain->appendChild($os);
    }

    my ($type) = $os->findnodes('type');

    # If there's no type element, copy one from the default
    if(!defined($type)) {
        ($type) = $default_dom->findnodes('/domain/os/type');
        $type = $type->cloneNode(1);
        $type->setOwnerDocument($dom);

        $os->appendChild($type);
    }

    # Set type/@arch based on the detected OS architecture
    $type->setAttribute('arch', $arch) if (defined($arch));
}

sub _configure_default_devices
{
    my ($dom, $default_dom) = @_;

    my ($devices) = $dom->findnodes('/domain/devices');

    # Remove any existing input, graphics or video devices
    foreach my $input ($devices->findnodes('input | video | graphics')) {
        $devices->removeChild($input);
    }

    my ($input_devices) = $default_dom->findnodes('/domain/devices');

    # Add new default devices from default XML
    foreach my $input ($input_devices->findnodes('input | video | '.
                                                 'graphics | console')) {
        my $new = $input->cloneNode(1);
        $new->setOwnerDocument($devices->getOwnerDocument());
        $devices->appendChild($new);
    }
}

sub _unconfigure_bootloaders
{
    my ($dom) = @_;

    # A list of paths which relate to assisted booting of a kernel on hvm
    my @bootloader_paths = (
        '/domain/os/loader',
        '/domain/os/kernel',
        '/domain/os/initrd',
        '/domain/os/root',
        '/domain/os/cmdline',
        '/domain/bootloader',
        '/domain/bootloader_args'
    );

    foreach my $path (@bootloader_paths) {
        my ($node) = $dom->findnodes($path);
        $node->getParentNode()->removeChild($node) if defined($node);
    }
}

sub _suffixcmp
{
    my ($a, $b) = @_;

    return 1 if (length($a) > length($b));
    return -1 if (length($a) < length($b));

    return 1 if ($a gt $b);
    return -1 if ($a lt $b);
    return 0;
}

sub _configure_storage
{
    my ($dom, $devices, $block) = @_;

    my $virtio = $block eq 'virtio' ? 1 : 0;
    my $prefix = $virtio == 1 ? 'vd' : 'hd';

    my @removed = ();

    my $suffix = 'a';
    foreach my $device (@$devices) {
        my ($target) = $dom->findnodes("/domain/devices/disk[\@device='disk']/".
                                       "target[\@dev='$device']");

        die("Previously detected drive $device is no longer present in domain ".
            "XML: ".$dom->toString())
            unless (defined($target));

        # Don't add more than 4 IDE disks
        if (!$virtio && _suffixcmp($suffix, 'd') > 0) {
            push(@removed, "$device(disk)");
        } else {
            $target->setAttribute('bus', $block);
            $target->setAttribute('dev', $prefix.$suffix);
            $suffix++; # Perl magic means 'z'++ == 'aa'
        }
    }

    # Convert CD-ROM devices to IDE.
    $suffix = 'a' if ($virtio);
    foreach my $target
        ($dom->findnodes("/domain/devices/disk[\@device='cdrom']/target"))
    {
        if (_suffixcmp($suffix, 'd') <= 0) {
            $target->setAttribute('bus', 'ide');
            $target->setAttribute('dev', "hd$suffix");
            $suffix++;
        } else {
            push(@removed, $target->getAttribute('dev')."(cdrom)");

            my $disk = $target->getParentNode();
            $disk->getParentNode()->removeChild($disk);
        }
    }

    if (@removed > 0) {
        logmsg WARN, __x('Only 4 IDE devices are supported. The following '.
                         'drives have been removed: {list}',
                         list => join(' ', @removed));
    }

    # As we just changed and unified all their underlying controllers, device
    # addresses are no longer relevant
    foreach my $address ($dom->findnodes('/domain/devices/disk/address')) {
        $address->getParentNode()->removeChild($address);
    }
}

sub _configure_network
{
    my ($dom, $net) = @_;

    # Convert network adapters
    # N.B. <interface> is not required to have a <model> element, but <model>
    # is required to have a type attribute

    # Convert interfaces which already have a model element
    foreach my $type
        ($dom->findnodes('/domain/devices/interface/model/@type'))
    {
        $type->setNodeValue($net);
    }

    # Add a model element to interfaces which don't have one
    foreach my $interface
        ($dom->findnodes('/domain/devices/interface[not(model)]'))
    {
        my $model = $dom->createElement('model');
        $model->setAttribute('type', $net);
        $interface->appendChild($model);
    }
}

sub _unconfigure_hvs
{
    my ($dom, $default_dom) = @_;
    die("unconfigure_hvs called without dom argument")
        unless defined($dom);
    die("unconfigure_hvs called without default_dom argument")
        unless defined($default_dom);

    # Remove emulator if it is defined
    foreach my $emulator ($dom->findnodes('/domain/devices/emulator')) {
        $emulator->getParent()->removeChild($emulator);
    }

    # Remove any disk driver element other than 'qemu'
    foreach my $driver
        ($dom->findnodes('/domain/devices/disk/driver[@name != \'qemu\']'))
    {
        $driver->getParentNode()->removeChild($driver);
    }

    _unconfigure_xen_metadata($dom);
}

sub _unconfigure_xen_metadata
{
    my ($dom) = @_;

    # The list of target xen-specific nodes is mostly taken from inspection of
    # domain.rng

    # Remove machine if it has a xen-specific value
    # We could replace it with the generic 'pc', but 'pc' is a moving target
    # across QEMU releases. By removing it entirely, libvirt will automatically
    # add the latest machine type (e.g. pc-0.11), which is stable.
    foreach my $machine_type ($dom->findnodes('/domain/os/type/@machine')) {
        if ($machine_type->getNodeValue() =~ /(xenpv|xenfv|xenner)/) {
            my ($type) = $dom->findnodes('/domain/os/type[@machine = "'.
                                         $machine_type->getNodeValue().'"]');
            $type->getAttributes()->removeNamedItem("machine");
        }
    }

    # Remove the script element if its path attribute is 'vif-bridge'
    foreach my $script ($dom->findnodes('/domain/devices/interface/script[@path = "vif-bridge"]'))
    {
        $script->getParent()->removeChild($script);
    }

    # Other Xen related metadata is handled separately
    # /domain/@type
    # /domain/devices/input/@bus = xen
    # /domain/devices/disk/target/@bus = 'xen'
    # /domain/os/loader = 'xen'
    # /domain/bootloader
    # /domain/bootloader_args
}

sub _map_networks
{
    my ($dom, $config) = @_;

    # Iterate over interfaces
    foreach my $if ($dom->findnodes('/domain/devices/interface'))
    {
        my $type = $if->getAttribute('type');

        my $name;
        if ($type eq 'bridge') {
            ($name) = $if->findnodes('source/@bridge');
        } elsif ($type eq 'network') {
            ($name) = $if->findnodes('source/@network');
        } else {
            v2vdie __x('Unknown interface type {type} in domain XML: {domain}',
                       type => $type, domain => $dom->toString());
        }

        my ($newname, $newtype) = $config->map_network($name->getValue(),
                                                       $type);
        next unless (defined($newname) && defined($newtype));

        my ($source) = $if->findnodes('source');

        # Replace @bridge or @network in the source element with the correct
        # mapped attribute name and value
        $source->removeAttributeNode($name);
        $source->setAttribute($newtype, $newname);

        # Update the type of the interface
        $if->setAttribute('type', $newtype);
    }
}

sub _sanity_check
{
    my ($dom) = shift;

    # Check for multiple boot devices of the same type, which will cause KVM not
    # to start
    # Seen on RHEL 5 Xen
    my %devs;
    foreach my $boot ($dom->findnodes('/domain/os/boot')) {
        my $dev = $boot->getAttribute('dev');

        if (defined($dev) && !exists($devs{$dev})) {
            $devs{$dev} = 1;
            next;
        }

        # Delete nodes with no dev attribute, or that we've seen before
        $boot->getParentNode()->removeChild($boot);
    }
}

=back

=head1 COPYRIGHT

Copyright (C) 2009,2010 Red Hat Inc.

=head1 LICENSE

Please see the file COPYING.LIB for the full license.

=head1 SEE ALSO

L<Sys::VirtConvert::Converter::Linux(3pm)>,
L<Sys::Guestfs::Lib(3pm)>,
L<Sys::Virt(3pm)>,
L<virt-v2v(1)>,
L<http://libguestfs.org/>.

=cut

1;