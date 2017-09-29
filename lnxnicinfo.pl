#!/usr/bin/perl
 
use Data::Dumper;
use Socket;
use Sys::Hostname;
use IPC::Cmd qw[can_run run];

# run as root only
die "$0 must run as root user" if $< != 0;
 
$hostname = hostname();
$index = 1;
$indexvlan = 1;

 
# get interfaces into array
open my $proc_dev, "<", "/proc/net/dev" or die "cannot open /proc/net/dev: $!"; 
@proc_net_devs = grep {!/(sit|lo)/} <$proc_dev>; 
close $proc_dev;

# system commands needed
our $cdpr_fullpath = can_run('cdpr');
our $ip_fullpath = can_run('ip') or die "ip systemcmd not found";
our $ethtool_fullpath = can_run('ethtool') or die "ethtool systemcmd not found";


foreach (@proc_net_devs) {
   if (/\s*(.+?):.+/) {
     $dev = $1;
     ($rc_ip, $rc_mask) = &getip($dev);
     $net_devs{$hostname}{$dev}{IP} = $rc_ip;
     $net_devs{$hostname}{$dev}{MASK} = $rc_mask;
     $rc_speed = &getspeed($dev);
     $net_devs{$hostname}{$dev}{SPEED} = $rc_speed;
     getpkgstats($dev, $hostname, \%net_devs);

     if (($rc_virtphys = &isvirtphys($dev)) > 0) {
       $net_devs{$hostname}{$dev}{VoP} = "phys";
       $rc_mac = &getmac($dev);
       $net_devs{$hostname}{$dev}{MAC} = $rc_mac;
       # get cdpr info
       if ($cdpr_fullpath) {
         cdpr($dev, \%{$net_devs{$hostname}}) if $net_devs{$hostname}{$dev}{SPEED} && $ARGV[0] eq '-cdp';
       }
     }
     else {
       $net_devs{$hostname}{$dev}{VoP} = "virt";
     }
 
     if (-r "/proc/net/bonding/$dev") {
       $net_devs{$hostname}{$dev}{INDEX} = $index;
       $index++;
 
       @rc_bonddev = &findbonddev($dev);
       $net_devs{$hostname}{$dev}{"SLAVE" . $i++} = $_ foreach @rc_bonddev;
       undef $i;
       $rc_bondpolicy = &findbondpolicy($dev);
       #writing the policy to the actual slave device not the bond itself
       foreach (grep(/SLAVE\d+$/, keys %{$net_devs{$hostname}{$dev}})) {
         $slave_dev = $net_devs{$hostname}{$dev}{$_};
         $net_devs{$hostname}{$slave_dev}{POLICY} = $rc_bondpolicy;
       }

     }
 
     if (-r "/proc/net/vlan/$dev") {
       $net_devs{$hostname}{$dev}{INDEX} = $index;
       $index++;
 
       $rc_vlandev = &findvlandev($dev);
       $net_devs{$hostname}{$dev}{SLAVE . $i++} = $rc_vlandev;
       undef $i;
 
       $rc_vid = &findvid($dev);
       $net_devs{$hostname}{$dev}{VID} = $rc_vid;
     }
 
     if ($net_devs{$hostname}{$dev}{IP}) {
       $rc_host = &gethost($dev);
       $net_devs{$hostname}{$dev}{HOST} = $rc_host;
     }
   }
}
 
foreach (keys %{$net_devs{$hostname}}) {
  $i=1;
  &createindex($_);
  &getslavemac($_) if -r "/proc/net/bonding/$_";
}
 
 
sub getpkgstats {
my ($dev, $hostname, $h_ref) = @_;

my @netstat_lines = `netstat  -i`;
my @netstat_stats = grep {/$dev/} @netstat_lines; 
(undef, undef, undef, $$h_ref{$hostname}{$dev}{stats}{rxok}, $$h_ref{$hostname}{$dev}{stats}{rxerr}, $$h_ref{$hostname}{$dev}{stats}{rxdrp}, undef, $$h_ref{$hostname}{$dev}{stats}{txok}, $$h_ref{$hostname}{$dev}{stats}{txerr}, $$h_ref{$hostname}{$dev}{stats}{txdrp}, undef, undef) = split(/\s+/, $netstat_stats[0]);

return 0;
} 

sub getmac {
my ($dev) = @_;
my @lines = `$ip_fullpath a l $dev`;
my $line = join('', grep {/ether/} @lines);
my $mac = $1 if $line =~ /((?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2})/i;
$mac =~ s/://g;
return ($mac);
}
 
sub getip {
my ($dev) = @_;
my @lines = `$ip_fullpath a l $dev`;
my $line = join('', grep {/inet/} @lines);
#my $ip = $1 if $line =~ /inet\s(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})/;
$line =~ /inet\s(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})/;
return($1, $2);
}
 
sub findbonddev {
my ($dev) = @_;
my @slaves;
open my $bonding_dev, "<", "/proc/net/bonding/$dev" or die "cannot open /proc/net/bonding/$dev: $!"; 
my @lines = grep {/Slave/} <$bonding_dev>; 
close $bonding_dev;
foreach (@lines) {
  push(@slaves, $1) if /Slave Interface:\s(.+$)/;
}
return(@slaves);
}
 
sub getspeed {
my ($dev) = @_;
my @lines = `$ethtool_fullpath $dev`;
my $line = join('', grep {/Speed:\s/} @lines);
my $speed = $1 if $line =~ /Speed:\s(\d{3,5})/;
return($speed);
}
 
sub findvlandev {
my ($dev) = @_;
open my $vlan_dev, "<", "/proc/net/vlan/$dev" or die "cannot open /proc/net/vlan/$dev: $!"; 
my @lines = grep {/^Device/} <$vlan_dev>; 
close $vlan_dev;
my $vlan_master = $1 if $lines[0] =~ /Device:\s(.+)$/;
return($vlan_master);
}
 
sub findvid {
my ($dev) = @_;
open my $vlan_dev, "<", "/proc/net/vlan/$dev" or die "cannot open /proc/net/vlan/$dev: $!"; 
my @lines = grep {/VID/} <$vlan_dev>; 
close $vlan_dev;
my $vid = $1 if $lines[0] =~ /\sVID:\s(\d+)\s+/;
return($vid);
}
 
sub gethost {
my ($dev) = @_;
my $ipaddr = inet_aton($net_devs{$hostname}{$dev}{IP});
my $host = gethostbyaddr($ipaddr, AF_INET);
return($host);
}
 

sub createindex {
my ($dev) = @_;
if ($net_devs{$hostname}{$dev}{INDEX}) {
  foreach $slave (keys %{$net_devs{$hostname}{$dev}}) {
    if ($slave =~ /SLAVE\d+/) {
      $slave_dev = $net_devs{$hostname}{$dev}{$slave};
      if (!$net_devs{$hostname}{$slave_dev}{INDEX}) {
          $net_devs{$hostname}{$slave_dev}{INDEX} = $net_devs{$hostname}{$dev}{INDEX};
      }
      elsif ($net_devs{$hostname}{$slave_dev}{INDEX}) {
        $net_devs{$hostname}{$dev}{INDEX} = $net_devs{$hostname}{$slave_dev}{INDEX};
      }
    }
  }
}
}
 
sub isvirtphys {
my ($dev) = @_;
my @out = `$ethtool_fullpath $dev`;
my ($rc) = join('', grep {/PHYAD/} @out) =~ /PHYAD:\s+(\d+)/;
return($rc);
}

sub cdpr {
my ($dev, $net_devs_ref) = @_;
my @out = `$cdpr_fullpath -d $dev`;
my $i;
foreach (@out) {
	$i++;

	if (/^Device ID/) {
		chomp $out[$i];
		$out[$i] =~ s/\s*value:\s+(.+$)/$1/;
		$$net_devs_ref{$dev}{switch_device_id} = $out[$i];
	} 
	elsif (/^Addresses/) {
		chomp $out[$i];
		$out[$i] =~ s/\s*value:\s+(.+$)/$1/;
		$$net_devs_ref{$dev}{switch_address} = $out[$i];
	}
	elsif (/^Port ID/) {
		chomp $out[$i];
		$out[$i] =~ s/\s*value:\s+(.+$)/$1/;
		$$net_devs_ref{$dev}{switch_port_id} = $out[$i];
	}
}
  

}





 
sub findbondpolicy {
my ($dev) = @_;
open my $bonding_dev, "<", "/proc/net/bonding/$dev" or die "cannot open /proc/net/bonding/$dev: $!"; 
my @lines = grep {/^Bonding Mode:/} <$bonding_dev>; 
close $bonding_dev;
my $policy = $1 if $lines[0] =~ /^Bonding Mode:\s(.+$)/;
return($policy);
}
 
sub getslavemac {
my ($dev) = @_;
my $line = `cat /proc/net/bonding/$dev`;
$line =~ s/\n//g;
foreach $slave (keys %{$net_devs{$hostname}{$dev}}) {
  if ($slave =~ /SLAVE\d+/) {
    my $slave_dev = $net_devs{$hostname}{$dev}{$slave};
    $line =~ /Slave Interface: ($slave_dev).+?Permanent HW addr:\s((?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2})/i;
    my $mac = $2;
#    print "$slave_dev $mac\n";
    $mac =~ s/://g;
    $net_devs{$hostname}{$slave_dev}{MAC} = $mac;
  }
}
}
 
 
 

#print Dumper(\%net_devs);
 
##################OUTPUT CSV##############
 
 
print "hostname;MAC;Speed;devicename;fqdn;IP;VID;MASK;INDEX;VirtOrPhys;bondpolicy;switch_device_id;switch_address;switch_port_id;rx-ok,rx-err,rx-drp\n";
foreach $dev (keys %{$net_devs{$hostname}}) {
print "$hostname;$net_devs{$hostname}{$dev}{MAC};$net_devs{$hostname}{$dev}{SPEED};$dev;$net_devs{$hostname}{$dev}{HOST};$net_devs{$hostname}{$dev}{IP};$net_devs{$hostname}{$dev}{VID};$net_devs{$hostname}{$dev}{MASK};$net_devs{$hostname}{$dev}{INDEX};$net_devs{$hostname}{$dev}{VoP};$net_devs{$hostname}{$dev}{POLICY};$net_devs{$hostname}{$dev}{switch_device_id};$net_devs{$hostname}{$dev}{switch_address};$net_devs{$hostname}{$dev}{switch_port_id};$net_devs{$hostname}{$dev}{stats}{rxok};$net_devs{$hostname}{$dev}{stats}{rxerr};$net_devs{$hostname}{$dev}{stats}{rxdrp}\n" if ($net_devs{$hostname}{$dev}{HOST} or $net_devs{$hostname}{$dev}{IP} or $net_devs{$hostname}{$dev}{MASK} or $net_devs{$hostname}{$dev}{VID} or $net_devs{$hostname}{$dev}{SPEED} or $net_devs{$hostname}{$dev}{INDEX});
}
