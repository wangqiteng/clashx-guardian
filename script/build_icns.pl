#!/usr/bin/perl

use strict;
use warnings;

my ($iconset, $output) = @ARGV;
die "usage: $0 <AppIcon.iconset> <AppIcon.icns>\n" unless $iconset && $output;

my @entries = (
    ['icp4', 'icon_16x16.png'],
    ['ic11', 'icon_16x16@2x.png'],
    ['icp5', 'icon_32x32.png'],
    ['ic12', 'icon_32x32@2x.png'],
    ['ic07', 'icon_128x128.png'],
    ['ic13', 'icon_128x128@2x.png'],
    ['ic08', 'icon_256x256.png'],
    ['ic14', 'icon_256x256@2x.png'],
    ['ic09', 'icon_512x512.png'],
    ['ic10', 'icon_512x512@2x.png'],
);

my $payload = '';
for my $entry (@entries) {
    my ($type, $filename) = @$entry;
    my $path = "$iconset/$filename";
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $png = <$fh>;
    close $fh;
    die "$path is not a PNG file\n" unless substr($png, 0, 8) eq "\x89PNG\r\n\x1a\n";
    $payload .= $type . pack('N', 8 + length($png)) . $png;
}

open my $out, '>:raw', $output or die "cannot write $output: $!\n";
print {$out} 'icns', pack('N', 8 + length($payload)), $payload;
close $out or die "cannot finish $output: $!\n";
