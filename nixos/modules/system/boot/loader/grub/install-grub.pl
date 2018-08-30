use strict;
use warnings;
use Class::Struct;
use XML::LibXML;
use File::Basename;
use File::Path;
use File::stat;
use File::Copy;
use File::Slurp;
use File::Temp;
require List::Compare;
use POSIX;
use Cwd;

# system.build.toplevel path
my $defaultConfig = $ARGV[1] or die;

# Grub config XML generated by grubConfig function in grub.nix
my $dom = XML::LibXML->load_xml(location => $ARGV[0]);

sub get { my ($name) = @_; return $dom->findvalue("/expr/attrs/attr[\@name = '$name']/*/\@value"); }

sub readFile {
    my ($fn) = @_; local $/ = undef;
    open FILE, "<$fn" or return undef; my $s = <FILE>; close FILE;
    local $/ = "\n"; chomp $s; return $s;
}

sub writeFile {
    my ($fn, $s) = @_;
    open FILE, ">$fn" or die "cannot create $fn: $!\n";
    print FILE $s or die;
    close FILE or die;
}

sub runCommand {
    my ($cmd) = @_;
    open FILE, "$cmd 2>/dev/null |" or die "Failed to execute: $cmd\n";
    my @ret = <FILE>;
    close FILE;
    return ($?, @ret);
}

my $grub = get("grub");
my $grubVersion = int(get("version"));
my $grubTarget = get("grubTarget");
my $extraConfig = get("extraConfig");
my $extraPrepareConfig = get("extraPrepareConfig");
my $extraPerEntryConfig = get("extraPerEntryConfig");
my $extraEntries = get("extraEntries");
my $extraEntriesBeforeNixOS = get("extraEntriesBeforeNixOS") eq "true";
my $extraInitrd = get("extraInitrd");
my $splashImage = get("splashImage");
my $splashMode = get("splashMode");
my $backgroundColor = get("backgroundColor");
my $configurationLimit = int(get("configurationLimit"));
my $copyKernels = get("copyKernels") eq "true";
my $timeout = int(get("timeout"));
my $defaultEntry = get("default");
my $fsIdentifier = get("fsIdentifier");
my $grubEfi = get("grubEfi");
my $grubTargetEfi = get("grubTargetEfi");
my $bootPath = get("bootPath");
my $storePath = get("storePath");
my $canTouchEfiVariables = get("canTouchEfiVariables");
my $efiInstallAsRemovable = get("efiInstallAsRemovable");
my $efiSysMountPoint = get("efiSysMountPoint");
my $gfxmodeEfi = get("gfxmodeEfi");
my $gfxmodeBios = get("gfxmodeBios");
my $bootloaderId = get("bootloaderId");
my $forceInstall = get("forceInstall");
my $font = get("font");
$ENV{'PATH'} = get("path");

die "unsupported GRUB version\n" if $grubVersion != 1 && $grubVersion != 2;

print STDERR "updating GRUB $grubVersion menu...\n";

mkpath("$bootPath/grub", 0, 0700);

# Discover whether the bootPath is on the same filesystem as / and
# /nix/store.  If not, then all kernels and initrds must be copied to
# the bootPath.
if (stat($bootPath)->dev != stat("/nix/store")->dev) {
    $copyKernels = 1;
}

# Discover information about the location of the bootPath
struct(Fs => {
    device => '$',
    type => '$',
    mount => '$',
});
sub PathInMount {
    my ($path, $mount) = @_;
    my @splitMount = split /\//, $mount;
    my @splitPath = split /\//, $path;
    if ($#splitPath < $#splitMount) {
        return 0;
    }
    for (my $i = 0; $i <= $#splitMount; $i++) {
        if ($splitMount[$i] ne $splitPath[$i]) {
            return 0;
        }
    }
    return 1;
}

# Figure out what filesystem is used for the directory with init/initrd/kernel files
sub GetFs {
    my ($dir) = @_;
    my $bestFs = Fs->new(device => "", type => "", mount => "");
    foreach my $fs (read_file("/proc/self/mountinfo")) {
        chomp $fs;
        my @fields = split / /, $fs;
        my $mountPoint = $fields[4];
        next unless -d $mountPoint;
        my @mountOptions = split /,/, $fields[5];

        # Skip the optional fields.
        my $n = 6; $n++ while $fields[$n] ne "-"; $n++;
        my $fsType = $fields[$n];
        my $device = $fields[$n + 1];
        my @superOptions = split /,/, $fields[$n + 2];

        # Skip the bind-mount on /nix/store.
        next if $mountPoint eq "/nix/store" && (grep { $_ eq "rw" } @superOptions);
        # Skip mount point generated by systemd-efi-boot-generator?
        next if $fsType eq "autofs";

        # Ensure this matches the intended directory
        next unless PathInMount($dir, $mountPoint);

        # Is it better than our current match?
        if (length($mountPoint) > length($bestFs->mount)) {
            $bestFs = Fs->new(device => $device, type => $fsType, mount => $mountPoint);
        }
    }
    return $bestFs;
}
struct (Grub => {
    path => '$',
    search => '$',
});
my $driveid = 1;
sub GrubFs {
    my ($dir) = @_;
    my $fs = GetFs($dir);
    my $path = substr($dir, length($fs->mount));
    if (substr($path, 0, 1) ne "/") {
      $path = "/$path";
    }
    my $search = "";

    if ($grubVersion > 1) {
        # ZFS is completely separate logic as zpools are always identified by a label
        # or custom UUID
        if ($fs->type eq 'zfs') {
            my $sid = index($fs->device, '/');

            if ($sid < 0) {
                $search = '--label ' . $fs->device;
                $path = '/@' . $path;
            } else {
                $search = '--label ' . substr($fs->device, 0, $sid);
                $path = '/' . substr($fs->device, $sid) . '/@' . $path;
            }
        } else {
            my %types = ('uuid' => '--fs-uuid', 'label' => '--label');

            if ($fsIdentifier eq 'provided') {
                # If the provided dev is identifying the partition using a label or uuid,
                # we should get the label / uuid and do a proper search
                my @matches = $fs->device =~ m/\/dev\/disk\/by-(label|uuid)\/(.*)/;
                if ($#matches > 1) {
                    die "Too many matched devices"
                } elsif ($#matches == 1) {
                    $search = "$types{$matches[0]} $matches[1]"
                }
            } else {
                # Determine the identifying type
                $search = $types{$fsIdentifier} . ' ';

                # Based on the type pull in the identifier from the system
                my ($status, @devInfo) = runCommand("@utillinux@/bin/blkid -o export @{[$fs->device]}");
                if ($status != 0) {
                    die "Failed to get blkid info (returned $status) for @{[$fs->mount]} on @{[$fs->device]}";
                }
                my @matches = join("", @devInfo) =~ m/@{[uc $fsIdentifier]}=([^\n]*)/;
                if ($#matches != 0) {
                    die "Couldn't find a $types{$fsIdentifier} for @{[$fs->device]}\n"
                }
                $search .= $matches[0];
            }

            # BTRFS is a special case in that we need to fix the referrenced path based on subvolumes
            if ($fs->type eq 'btrfs') {
                my ($status, @id_info) = runCommand("@btrfsprogs@/bin/btrfs subvol show @{[$fs->mount]}");
                if ($status != 0) {
                    die "Failed to retrieve subvolume info for @{[$fs->mount]}\n";
                }
                my @ids = join("\n", @id_info) =~ m/^(?!\/\n).*Subvolume ID:[ \t\n]*([0-9]+)/s;
                if ($#ids > 0) {
                    die "Btrfs subvol name for @{[$fs->device]} listed multiple times in mount\n"
                } elsif ($#ids == 0) {
                    my ($status, @path_info) = runCommand("@btrfsprogs@/bin/btrfs subvol list @{[$fs->mount]}");
                    if ($status != 0) {
                        die "Failed to find @{[$fs->mount]} subvolume id from btrfs\n";
                    }
                    my @paths = join("", @path_info) =~ m/ID $ids[0] [^\n]* path ([^\n]*)/;
                    if ($#paths > 0) {
                        die "Btrfs returned multiple paths for a single subvolume id, mountpoint @{[$fs->mount]}\n";
                    } elsif ($#paths != 0) {
                        die "Btrfs did not return a path for the subvolume at @{[$fs->mount]}\n";
                    }
                    $path = "/$paths[0]$path";
                }
            }
        }
        if (not $search eq "") {
            $search = "search --set=drive$driveid " . $search;
            $path = "(\$drive$driveid)$path";
            $driveid += 1;
        }
    }
    return Grub->new(path => $path, search => $search);
}
my $grubBoot = GrubFs($bootPath);
my $grubStore;
if ($copyKernels == 0) {
    $grubStore = GrubFs($storePath);
}
my $extraInitrdPath;
if ($extraInitrd) {
    if (! -f $extraInitrd) {
        print STDERR "Warning: the specified extraInitrd " . $extraInitrd . " doesn't exist. Your system won't boot without it.\n";
    }
    $extraInitrdPath = GrubFs($extraInitrd);
}

# Generate the header.
my $conf .= "# Automatically generated.  DO NOT EDIT THIS FILE!\n";

if ($grubVersion == 1) {
    $conf .= "
        default $defaultEntry
        timeout $timeout
    ";
    if ($splashImage) {
        copy $splashImage, "$bootPath/background.xpm.gz" or die "cannot copy $splashImage to $bootPath\n";
        $conf .= "splashimage " . $grubBoot->path . "/background.xpm.gz\n";
    }
}

else {
    if ($copyKernels == 0) {
        $conf .= "
            " . $grubStore->search;
    }
    # FIXME: should use grub-mkconfig.
    $conf .= "
        " . $grubBoot->search . "
        if [ -s \$prefix/grubenv ]; then
          load_env
        fi

        # ‘grub-reboot’ sets a one-time saved entry, which we process here and
        # then delete.
        if [ \"\${next_entry}\" ]; then
          set default=\"\${next_entry}\"
          set next_entry=
          save_env next_entry
          set timeout=1
        else
          set default=$defaultEntry
          set timeout=$timeout
        fi

        # Setup the graphics stack for bios and efi systems
        if [ \"\${grub_platform}\" = \"efi\" ]; then
          insmod efi_gop
          insmod efi_uga
        else
          insmod vbe
        fi
    ";

    if ($font) {
        copy $font, "$bootPath/converted-font.pf2" or die "cannot copy $font to $bootPath\n";
        $conf .= "
            insmod font
            if loadfont " . $grubBoot->path . "/converted-font.pf2; then
              insmod gfxterm
              if [ \"\${grub_platform}\" = \"efi\" ]; then
                set gfxmode=$gfxmodeEfi
                set gfxpayload=keep
              else
                set gfxmode=$gfxmodeBios
                set gfxpayload=text
              fi
              terminal_output gfxterm
            fi
        ";
    }
    if ($splashImage) {
        # Keeps the image's extension.
        my ($filename, $dirs, $suffix) = fileparse($splashImage, qr"\..[^.]*$");
        # The module for jpg is jpeg.
        if ($suffix eq ".jpg") {
            $suffix = ".jpeg";
        }
		if ($backgroundColor) {
			$conf .= "
		    background_color '$backgroundColor'
		    ";
		}
        copy $splashImage, "$bootPath/background$suffix" or die "cannot copy $splashImage to $bootPath\n";
        $conf .= "
            insmod " . substr($suffix, 1) . "
            if background_image --mode '$splashMode' " . $grubBoot->path . "/background$suffix; then
              set color_normal=white/black
              set color_highlight=black/white
            else
              set menu_color_normal=cyan/blue
              set menu_color_highlight=white/blue
            fi
        ";
    }
}

$conf .= "$extraConfig\n";


# Generate the menu entries.
$conf .= "\n";

my %copied;
mkpath("$bootPath/kernels", 0, 0755) if $copyKernels;

sub copyToKernelsDir {
    my ($path) = @_;
    return $grubStore->path . substr($path, length("/nix/store")) unless $copyKernels;
    $path =~ /\/nix\/store\/(.*)/ or die;
    my $name = $1; $name =~ s/\//-/g;
    my $dst = "$bootPath/kernels/$name";
    # Don't copy the file if $dst already exists.  This means that we
    # have to create $dst atomically to prevent partially copied
    # kernels or initrd if this script is ever interrupted.
    if (! -e $dst) {
        my $tmp = "$dst.tmp";
        copy $path, $tmp or die "cannot copy $path to $tmp\n";
        rename $tmp, $dst or die "cannot rename $tmp to $dst\n";
    }
    $copied{$dst} = 1;
    return $grubBoot->path . "/kernels/$name";
}

sub addEntry {
    my ($name, $path) = @_;
    return unless -e "$path/kernel" && -e "$path/initrd";

    my $kernel = copyToKernelsDir(Cwd::abs_path("$path/kernel"));
    my $initrd = copyToKernelsDir(Cwd::abs_path("$path/initrd"));
    if ($extraInitrd) {
        $initrd .= " " .$extraInitrdPath->path;
    }
    my $xen = -e "$path/xen.gz" ? copyToKernelsDir(Cwd::abs_path("$path/xen.gz")) : undef;

    # FIXME: $confName

    my $kernelParams =
        "systemConfig=" . Cwd::abs_path($path) . " " .
        "init=" . Cwd::abs_path("$path/init") . " " .
        readFile("$path/kernel-params");
    my $xenParams = $xen && -e "$path/xen-params" ? readFile("$path/xen-params") : "";

    if ($grubVersion == 1) {
        $conf .= "title $name\n";
        $conf .= "  $extraPerEntryConfig\n" if $extraPerEntryConfig;
        $conf .= "  kernel $xen $xenParams\n" if $xen;
        $conf .= "  " . ($xen ? "module" : "kernel") . " $kernel $kernelParams\n";
        $conf .= "  " . ($xen ? "module" : "initrd") . " $initrd\n\n";
    } else {
        $conf .= "menuentry \"$name\" {\n";
        $conf .= $grubBoot->search . "\n";
        if ($copyKernels == 0) {
            $conf .= $grubStore->search . "\n";
        }
        if ($extraInitrd) {
            $conf .= $extraInitrdPath->search . "\n";
        }
        $conf .= "  $extraPerEntryConfig\n" if $extraPerEntryConfig;
        $conf .= "  multiboot $xen $xenParams\n" if $xen;
        $conf .= "  " . ($xen ? "module" : "linux") . " $kernel $kernelParams\n";
        $conf .= "  " . ($xen ? "module" : "initrd") . " $initrd\n";
        $conf .= "}\n\n";
    }
}


# Add default entries.
$conf .= "$extraEntries\n" if $extraEntriesBeforeNixOS;

addEntry("NixOS - Default", $defaultConfig);

$conf .= "$extraEntries\n" unless $extraEntriesBeforeNixOS;

my $grubBootPath = $grubBoot->path;
# extraEntries could refer to @bootRoot@, which we have to substitute
$conf =~ s/\@bootRoot\@/$grubBootPath/g;

# Emit submenus for all system profiles.
sub addProfile {
    my ($profile, $description) = @_;

    # Add entries for all generations of this profile.
    $conf .= "submenu \"$description\" {\n" if $grubVersion == 2;

    sub nrFromGen { my ($x) = @_; $x =~ /\/\w+-(\d+)-link/; return $1; }

    my @links = sort
        { nrFromGen($b) <=> nrFromGen($a) }
        (glob "$profile-*-link");

    my $curEntry = 0;
    foreach my $link (@links) {
        last if $curEntry++ >= $configurationLimit;
        if (! -e "$link/nixos-version") {
            warn "skipping corrupt system profile entry ‘$link’\n";
            next;
        }
        my $date = strftime("%F", localtime(lstat($link)->mtime));
        my $version =
            -e "$link/nixos-version"
            ? readFile("$link/nixos-version")
            : basename((glob(dirname(Cwd::abs_path("$link/kernel")) . "/lib/modules/*"))[0]);
        addEntry("NixOS - Configuration " . nrFromGen($link) . " ($date - $version)", $link);
    }

    $conf .= "}\n" if $grubVersion == 2;
}

addProfile "/nix/var/nix/profiles/system", "NixOS - All configurations";

if ($grubVersion == 2) {
    for my $profile (glob "/nix/var/nix/profiles/system-profiles/*") {
        my $name = basename($profile);
        next unless $name =~ /^\w+$/;
        addProfile $profile, "NixOS - Profile '$name'";
    }
}

# Run extraPrepareConfig in sh
if ($extraPrepareConfig ne "") {
  system((get("shell"), "-c", $extraPrepareConfig));
}

# write the GRUB config.
my $confFile = $grubVersion == 1 ? "$bootPath/grub/menu.lst" : "$bootPath/grub/grub.cfg";
my $tmpFile = $confFile . ".tmp";
writeFile($tmpFile, $conf);


# check whether to install GRUB EFI or not
sub getEfiTarget {
    if ($grubVersion == 1) {
        return "no"
    } elsif (($grub ne "") && ($grubEfi ne "")) {
        # EFI can only be installed when target is set;
        # A target is also required then for non-EFI grub
        if (($grubTarget eq "") || ($grubTargetEfi eq "")) { die }
        else { return "both" }
    } elsif (($grub ne "") && ($grubEfi eq "")) {
        # TODO: It would be safer to disallow non-EFI grub installation if no taget is given.
        #       If no target is given, then grub auto-detects the target which can lead to errors.
        #       E.g. it seems as if grub would auto-detect a EFI target based on the availability
        #       of a EFI partition.
        #       However, it seems as auto-detection is currently relied on for non-x86_64 and non-i386
        #       architectures in NixOS. That would have to be fixed in the nixos modules first.
        return "no"
    } elsif (($grub eq "") && ($grubEfi ne "")) {
        # EFI can only be installed when target is set;
        if ($grubTargetEfi eq "") { die }
        else {return "only" }
    } else {
        # prevent an installation if neither grub nor grubEfi is given
        return "neither"
    }
}

my $efiTarget = getEfiTarget();

# Append entries detected by os-prober
if (get("useOSProber") eq "true") {
    my $targetpackage = ($efiTarget eq "no") ? $grub : $grubEfi;
    system(get("shell"), "-c", "pkgdatadir=$targetpackage/share/grub $targetpackage/etc/grub.d/30_os-prober >> $tmpFile");
}

# Atomically switch to the new config
rename $tmpFile, $confFile or die "cannot rename $tmpFile to $confFile\n";


# Remove obsolete files from $bootPath/kernels.
foreach my $fn (glob "$bootPath/kernels/*") {
    next if defined $copied{$fn};
    print STDERR "removing obsolete file $fn\n";
    unlink $fn;
}


#
# Install GRUB if the parameters changed from the last time we installed it.
#

struct(GrubState => {
    name => '$',
    version => '$',
    efi => '$',
    devices => '$',
    efiMountPoint => '$',
});
sub readGrubState {
    my $defaultGrubState = GrubState->new(name => "", version => "", efi => "", devices => "", efiMountPoint => "" );
    open FILE, "<$bootPath/grub/state" or return $defaultGrubState;
    local $/ = "\n";
    my $name = <FILE>;
    chomp($name);
    my $version = <FILE>;
    chomp($version);
    my $efi = <FILE>;
    chomp($efi);
    my $devices = <FILE>;
    chomp($devices);
    my $efiMountPoint = <FILE>;
    chomp($efiMountPoint);
    close FILE;
    my $grubState = GrubState->new(name => $name, version => $version, efi => $efi, devices => $devices, efiMountPoint => $efiMountPoint );
    return $grubState
}

sub getDeviceTargets {
    my @devices = ();
    foreach my $dev ($dom->findnodes('/expr/attrs/attr[@name = "devices"]/list/string/@value')) {
        $dev = $dev->findvalue(".") or die;
        push(@devices, $dev);
    }
    return @devices;
}
my @deviceTargets = getDeviceTargets();
my $prevGrubState = readGrubState();
my @prevDeviceTargets = split/,/, $prevGrubState->devices;

my $devicesDiffer = scalar (List::Compare->new( '-u', '-a', \@deviceTargets, \@prevDeviceTargets)->get_symmetric_difference());
my $nameDiffer = get("fullName") ne $prevGrubState->name;
my $versionDiffer = get("fullVersion") ne $prevGrubState->version;
my $efiDiffer = $efiTarget ne $prevGrubState->efi;
my $efiMountPointDiffer = $efiSysMountPoint ne $prevGrubState->efiMountPoint;
if (($ENV{'NIXOS_INSTALL_GRUB'} // "") eq "1") {
    warn "NIXOS_INSTALL_GRUB env var deprecated, use NIXOS_INSTALL_BOOTLOADER";
    $ENV{'NIXOS_INSTALL_BOOTLOADER'} = "1";
}
my $requireNewInstall = $devicesDiffer || $nameDiffer || $versionDiffer || $efiDiffer || $efiMountPointDiffer || (($ENV{'NIXOS_INSTALL_BOOTLOADER'} // "") eq "1");

# install a symlink so that grub can detect the boot drive
my $tmpDir = File::Temp::tempdir(CLEANUP => 1) or die "Failed to create temporary space";
symlink "$bootPath", "$tmpDir/boot" or die "Failed to symlink $tmpDir/boot";

# install non-EFI GRUB
if (($requireNewInstall != 0) && ($efiTarget eq "no" || $efiTarget eq "both")) {
    foreach my $dev (@deviceTargets) {
        next if $dev eq "nodev";
        print STDERR "installing the GRUB $grubVersion boot loader on $dev...\n";
        my @command = ("$grub/sbin/grub-install", "--recheck", "--root-directory=$tmpDir", Cwd::abs_path($dev));
        if ($forceInstall eq "true") {
            push @command, "--force";
        }
        if ($grubTarget ne "") {
            push @command, "--target=$grubTarget";
        }
        (system @command) == 0 or die "$0: installation of GRUB on $dev failed\n";
    }
}


# install EFI GRUB
if (($requireNewInstall != 0) && ($efiTarget eq "only" || $efiTarget eq "both")) {
    print STDERR "installing the GRUB $grubVersion EFI boot loader into $efiSysMountPoint...\n";
    my @command = ("$grubEfi/sbin/grub-install", "--recheck", "--target=$grubTargetEfi", "--boot-directory=$bootPath", "--efi-directory=$efiSysMountPoint");
    if ($forceInstall eq "true") {
        push @command, "--force";
    }
    if ($canTouchEfiVariables eq "true") {
        push @command, "--bootloader-id=$bootloaderId";
    } else {
        push @command, "--no-nvram";
        push @command, "--removable" if $efiInstallAsRemovable eq "true";
    }

    (system @command) == 0 or die "$0: installation of GRUB EFI into $efiSysMountPoint failed\n";
}


# update GRUB state file
if ($requireNewInstall != 0) {
    open FILE, ">$bootPath/grub/state" or die "cannot create $bootPath/grub/state: $!\n";
    print FILE get("fullName"), "\n" or die;
    print FILE get("fullVersion"), "\n" or die;
    print FILE $efiTarget, "\n" or die;
    print FILE join( ",", @deviceTargets ), "\n" or die;
    print FILE $efiSysMountPoint, "\n" or die;
    close FILE or die;
}
