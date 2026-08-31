#!/usr/bin/perl -w

#    This file is part of SCIgen.
#
#    SCIgen is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    SCIgen is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with SCIgen; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use Getopt::Long;
use JSON;
use POSIX qw(strftime);
use File::Temp qw(tempdir);
use File::Basename qw(basename);
use File::Copy qw(move);
use FindBin;

my $tmp_dir = tempdir( "scicorpus.XXXXXXXX", TMPDIR => 1, CLEANUP => 1 );

# `mutool merge` takes every source on one command line, so very large corpora
# are merged in chunks and the chunks merged in turn.
my $chunk_size = 500;

sub usage {
    select(STDERR);
    print <<EOUsage;

$0 [options] <title_dir> <full_dir>

Concatenate a corpus of SCIgen papers into one PDF plus a JSON index of what
landed where. The first page of every PDF in <title_dir> is used, then all of
every PDF in <full_dir>. Each paper's metadata is read from its JSON sidecar,
either <paper>.pdf.json or <paper>.json.

  Options:

    --help                    Display this help message
    -o, --output <stem>       Write <stem>.pdf and <stem>.json; the default
                              is ./scicorpus-<date>
    --no-dedup                Skip the `mutool clean -gggg` pass that merges
                              duplicate objects and streams

EOUsage
    exit(1);
}

my %options;
&GetOptions( \%options, "help|?", "output|o=s", "dedup!" )
    or &usage;
&usage if $options{"help"} || @ARGV != 2;

my ($title_dir, $full_dir) = @ARGV;
my $stem = $options{"output"} // ("scicorpus-" . strftime("%Y%m%d", localtime));
my $dedup = $options{"dedup"} // 1;

sub read_dir {
    my ($dir) = @_;
    opendir(my $dh, $dir) or die( "Couldn't read $dir: $!" );
    my @pdfs = sort grep { /\.pdf\z/ } readdir($dh);
    closedir($dh);
    die( "No PDFs in $dir" ) if !@pdfs;
    map { "$dir/$_" } @pdfs;
}

# The sidecar is `<paper>.pdf.json` if `--json <dir>` wrote it, `<paper>.json`
# if the name was given explicitly.
sub read_metadata {
    my ($pdf) = @_;
    my $json = JSON->new->utf8;
    foreach my $f ("$pdf.json", ($pdf =~ s/\.pdf\z/.json/r)) {
        next if !-r $f;
        local $/;
        open(my $fh, "<", $f) or next;
        my $data = eval { $json->decode(<$fh>) };
        close($fh);
        return $data if ref($data) eq "HASH";
        warn( "$f: not a JSON object, ignoring\n" );
    }
    warn( "$pdf: no readable JSON sidecar\n" );
    {};
}

sub count_pages {
    my @pdfs = @_;
    my @counts;
    while (@pdfs) {
        my @batch = splice(@pdfs, 0, $chunk_size);
        my $args = join " ", map { "\Q$_\E" } @batch;
        my @out = split /\n/, `mutool run \Q$FindBin::Bin\E/countpages.js $args`;
        die( "countpages.js failed" ) if $? != 0 || @out != @batch;
        push @counts, @out;
    }
    map { int($_) } @counts;
}

# Merge `<pdf> <pages>` pairs, chunking to keep the command line bounded.
sub merge {
    my ($out, @sources) = @_;
    if (@sources <= $chunk_size) {
        my $args = join " ", map { "\Q$_->[0]\E" . ($_->[1] eq "" ? "" : " $_->[1]") } @sources;
        system( "mutool merge -o \Q$out\E $args" )
            and die( "Couldn't merge into $out" );
        return;
    }
    my @parts;
    while (@sources) {
        my @batch = splice(@sources, 0, $chunk_size);
        my $part = "$tmp_dir/part" . scalar(@parts) . ".pdf";
        &merge($part, @batch);
        push @parts, $part;
    }
    &merge($out, map { [$_, ""] } @parts);
}

my @title_pdfs = &read_dir($title_dir);
my @full_pdfs = &read_dir($full_dir);
my @title_counts = &count_pages(@title_pdfs);
my @full_counts = &count_pages(@full_pdfs);

my @contents;
my @sources;
my $page = 1;
for (my $i = 0; $i <= $#title_pdfs; ++$i) {
    die( "$title_pdfs[$i]: no pages" ) if $title_counts[$i] < 1;
    my $entry = &read_metadata($title_pdfs[$i]);
    $entry->{"source"} = basename($title_pdfs[$i]);
    $entry->{"first_page"} = $page;
    $entry->{"pages"} = 1;
    push @contents, $entry;
    push @sources, [$title_pdfs[$i], "1"];
    ++$page;
}
for (my $i = 0; $i <= $#full_pdfs; ++$i) {
    die( "$full_pdfs[$i]: no pages" ) if $full_counts[$i] < 1;
    my $entry = &read_metadata($full_pdfs[$i]);
    $entry->{"source"} = basename($full_pdfs[$i]);
    $entry->{"first_page"} = $page;
    $entry->{"pages"} = $full_counts[$i];
    push @contents, $entry;
    push @sources, [$full_pdfs[$i], ""];
    $page += $full_counts[$i];
}

my $merged = "$tmp_dir/merged.pdf";
&merge($merged, @sources);

if ($dedup) {
    system( "mutool clean -ggggz \Q$merged\E \Q$stem.pdf\E" )
        and die( "Couldn't clean $merged" );
} else {
    move( $merged, "$stem.pdf" )
        or die( "Couldn't write $stem.pdf: $!" );
}

my ($got) = &count_pages("$stem.pdf");
die( "$stem.pdf has $got pages, expected " . ($page - 1) )
    if $got != $page - 1;

# Every full PDF can then supply every page a paper draws separately, so
# corpus-genpaper.js never has to look for another entry.
my $page_basis = $full_counts[0];
foreach my $c (@full_counts) {
    $page_basis = $c if $c < $page_basis;
}
--$page_basis;

my %index = ("title_count" => scalar(@title_pdfs),
             "count" => scalar(@contents),
             "contents" => \@contents);
if ($page_basis >= 1) {
    $index{"page_basis"} = $page_basis;
} else {
    my $shortest = $page_basis + 1;
    warn( "$full_dir: shortest paper is $shortest page"
          . ($shortest == 1 ? "" : "s") . ", too short for a page basis\n" );
}

open(my $jfh, ">", "$stem.json") or die( "Couldn't write $stem.json: $!" );
print $jfh JSON->new->utf8->pretty->canonical->encode(\%index);
close($jfh);

print "wrote $stem.pdf (", $page - 1, " pages) and $stem.json (",
    scalar(@title_pdfs), " title-only + ", scalar(@full_pdfs), " full",
    ($page_basis >= 1 ? ", page basis $page_basis" : ""), ")\n";
