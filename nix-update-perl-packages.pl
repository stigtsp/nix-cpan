#! /usr/bin/env nix-shell
#! nix-shell -I nixpkgs=/home/sgo/nixpkgs/ -i perl -p perl perlPackages.RegexpCommon perlPackages.Mojolicious perlPackages.SmartComments perlPackages.MetaCPANClient perlPackages.SortVersions perlPackages.HTTPTinyCache perlPackages.TryTiny

use strict;
use v5.32;
use experimental 'signatures';
use Try::Tiny;
use Smart::Comments;
use Sort::Versions;
use Mojo::File;
use Regexp::Common;
use MetaCPAN::Client;
use Data::Dumper;
use HTTP::Tiny::Cache;

my $ua = new HTTP::Tiny::Cache;


my $nix_file = $ARGV[0];
die "no .nix file provided" unless -f $ARGV[0];

my $nix = Mojo::File->new($nix_file)->slurp;
my $mcpan  = MetaCPAN::Client->new( ua => $ua );


my (@modules, @skipped);
while ($nix =~ m/(\w+)\s+=\s+buildPerl(Package|Module)\s+
                 ($RE{balanced}{-parens=>'{}'})/gx) {
    my ($attrname, $type, $part) = ($1, $2, $3);
    push @modules, parse_module($attrname, $type, $part);
}

sub parse_module ($attrname, $type, $part) {

    my $m = {};

    $m->{url}     = get_attr($part, 'url');
    $m->{pname}   = get_attr($part, 'pname');
    $m->{version} = get_attr($part, 'version');
    $m->{sha256}  = get_attr($part, 'sha256');
    $m->{module}  = pname2module($m->{pname});



    unless ($m->{url} =~ m|^mirror://cpan/|) {
        warn "$attrname \$url is not mirror://cpan skipping";
        next;
    }
    unless ($m->{pname} && $m->{url} && $m->{version} && $m->{sha256}) {
        warn "$attrname missing \$version, \$pname, \$url, or \$sha256";
        next;
    }

    my $module = {};
    try {
        my $module = $mcpan->module($m->{module});
        $cpan = $module->{data};
    } catch {
        warn shift();
    };
    $mo->{version} =~ s/^v//;

    if ($m->{version} ne $mo->{version}) {
        try {
            $cpan->{download_url} = $mcpan->download_url($m->{module});
        } finally {};
        printf("%-30s | %-30s | %8s | %8s \n", $m->{pname}, $m->{module}, $m->{version}, $mo->{version});
    }

    return $m;
}



sub pname2module ($pname) {
    $pname=~s/-/::/g;
    return $pname;
}

sub get_attr ($text, $attr) {
    my $cnt = $text =~ m/$attr\s*=\s*$RE{quoted}{-keep};/;
    my $val = $1;
    die "get_attr $attr found more than 1 in text: $text" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
}
