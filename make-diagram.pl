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
require "./scigen.pm";
use Getopt::Long;

my $tmp_dir = "/tmp";
my $tmp_pre = "$tmp_dir/scimakediagram.$$";
my $viz_file = "$tmp_pre.viz";
my $pdf_file = "$tmp_pre.pdf";

my $sysname;
my $filename;
my $seed;

sub usage {
    select(STDERR);
    print <<EOUsage;
    
$0 [options]
  Options:

    --help                    Display this help message
    --seed <seed>             Seed the prng with this
    --file <file>             Save the postscript in this file
    --sysname <file>          What is the system called?

EOUsage

    exit(1);

}

# Get the user-defined parameters.
# First parse options
my %options;
&GetOptions( \%options, "help|?", "seed=s", "file=s", "sysname=s" )
    or &usage;

if( $options{"help"} ) {
    &usage();
}
if( defined $options{"file"} ) {
    $filename = $options{"file"};
}
if( defined $options{"sysname"} ) {
    $sysname = $options{"sysname"};
} else {
    die( "--sysname required" );
}
if( defined $options{"seed"} ) {
    $seed = $options{"seed"};
} else {
    $seed = int rand 0xffffffff;
}
srand($seed);

if( defined $filename ) {
    $pdf_file = $filename;
}

my @label_types = qw( NODE_LABEL_LET NODE_LABEL_PROG 
		      NODE_LABEL_NET NODE_LABEL_IP NODE_LABEL_HW 
		      NODE_LABEL_DEC);
my @edge_label_types = ( "\"\"", "\"\"", "\"\"", "\"\"", "\"\"", 
			 "EDGE_LABEL_YESNO" );
my %types = ("digraph" => "DIR_LAYOUT",
	     "graph" => "UNDIR_LAYOUT" );
my %edges = ("digraph" => "->",
	     "graph" => "--" );

my $fh = new IO::File ("<graphviz.in");
my $scigen = scigen->new();
$scigen->read_rules($fh, 0);

my $num_nodes = $scigen->generate ("NUM_NODES");
my $graph_type = $scigen->generate ("PICK_GRAPH_TYPE");
my $label_type = $scigen->generate ("PICK_LABEL_TYPE");
my $shape_type = $scigen->generate ("PICK_SHAPE_TYPE");
my $edge_label_type = $edge_label_types[$label_type];
$label_type = $label_types[$label_type];
my $dir_rule = $types{$graph_type};
my $edge_type = $edges{$graph_type};
my $program = $scigen->generate ($dir_rule);

#good number of edges: n-1 -> 2n-1
my $num_edges = int rand($num_nodes-1);
$num_edges += $num_nodes;
if( $num_edges > 16 ) {
    $num_edges = 16;
} elsif( $num_edges == 0 ) {
    $num_edges = 1;
}

$scigen->def("GRAPH_DIR", $graph_type);
$scigen->def("NODE_LABEL", $label_type);
$scigen->def("EDGEOP", $edge_type);
# can't be in italics
if( $sysname =~ /\\emph\{(.*)\}/ ) {
    $sysname = $1;
}
$scigen->def("SYSNAME", $sysname);
$scigen->def("SHAPE_TYPE", split(/\s+/, $shape_type));
$scigen->def("EDGE_LABEL", $edge_label_type);
$scigen->def("NODES", "NODES_$num_nodes");
$scigen->def("EDGES", "EDGES_$num_edges");

my $graph_file = $scigen->generate ("GRAPHVIZ");

open( VIZ, ">$viz_file" ) or die( "Can't open $viz_file for writing" );
print VIZ $graph_file;
close( VIZ );

system( "$program -Tpdf -o $pdf_file $viz_file" ) and
    die( "Can't run $program on $viz_file" );

system( "rm -f $tmp_pre*" ) and die( "Couldn't rm" );
