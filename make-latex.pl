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
use IO::File;
use Getopt::Long;
use IO::Socket;
use JSON;
use File::Temp qw(tempdir);
use File::Copy qw(move);

# Every intermediate file we or our helper scripts create goes in here,
# and the whole directory is removed when we exit.
my $tmp_dir = tempdir( "scigen.XXXXXXXX", TMPDIR => 1, CLEANUP => 1 );
# Ctrl-C (and other interrupts) stop our helper commands, remove $tmp_dir,
# and kill us with the same signal.
scigen::catch_interrupts( \&File::Temp::cleanup );
my $tex_prefix = "scimakelatex.$$";
my $tmp_pre = "$tmp_dir/$tex_prefix";
my $tex_file = "$tmp_pre.tex";
my $pdf_file = "$tmp_pre.pdf";
my $bib_file = "$tmp_dir/scigenbibfile.bib";
my $class_files = "IEEEtran.cls IEEE.bst usenix-2020-09.sty";
my $figure_tries = 5;
my $have_neato = `which neato 2>/dev/null` ne "";
my @authors;
my $seed;
my $remote = 0;
my $title;
my $out_file;
my $regenerate;

sub usage {
    select(STDERR);
    print <<EOUsage;
    
$0 [options]
  Options:

    --help                    Display this help message
    --author <quoted_name>    An author of the paper (can be specified 
                              multiple times)
    --seed <seed>             Seed the prng with this
    -o, --file <file>         Save the PDF here; the default is
                              ./scigen-<seed>.pdf in the current directory
    --json <file>             Save the paper metadata here as JSON
    --tar <file>              Tar all the files up
    --savedir <dir>           Save the files in a directory; do not latex 
                              or dvips.  Must specify full path
    --remote                  Use a daemon to resolve symbols
    --talk                    Make a talk, instead of a paper
    --long                    Make a long (10-page) paper, with subsections
    --title <title>           Set the title (useful for talks)
    --sysname <name>          Set the system name
    --enable <section>        Enable a configuration section
    --regenerate              Set seed from output name

EOUsage

    exit(1);

}

# Get the user-defined parameters.
# First parse options
my %options;
&GetOptions( \%options, "help|?", "author=s@", "seed=s", "tar=s", "file|o|output=s",
	"json:s", "enable=s@", "regenerate|regen",
	"savedir=s", "remote", "talk", "long", "title=s", "sysname=s" )
    or &usage;

if( $options{"help"} ) {
    &usage();
}
if( defined $options{"author"} ) {
    @authors = @{$options{"author"}};
}
if( defined $options{"remote"} ) {
    $remote = 1;
}
if( defined $options{"title"} ) {
    $title = $options{"title"};
}
if( defined $options{"seed"} ) {
    $seed = $options{"seed"};
} else {
    $seed = int rand 0xffffffff;
}

if( defined $options{"savedir"} ) {
    # --savedir saves the LaTeX source and skips the PDF entirely
} elsif( defined $options{"file"} ) {
    $out_file = $options{"file"};
} else {
    # by default the paper lands in the current directory
    $out_file = ".";
}

if (defined($options{"regenerate"})) {
    if (defined($out_file) && !-d $out_file && $out_file =~ /(?:\/|\A)scigen-(\d+)\.pdf\z/) {
        $seed = int($1);
    } else {
        print STDERR "`--regenerate` requires `-o`\n";
        exit 1;
    }
}

srand($seed);

if (defined($out_file) && -d $out_file) {
    $out_file =~ s/\/\z//;
    $out_file .= "/scigen-$seed.pdf";
}

my $name_dat = undef;

my $sysname;
if( defined $options{"sysname"} ) {
    $sysname = $options{"sysname"};
} else {
    $sysname = &get_system_name();
}

my $enablearg = join "", map { " --enable \"$_\"" } @{$options{"enable"} || []};

my $tex_fh; 
my $start_rule;
if( defined $options{"talk"} ) {
    $tex_fh = new IO::File ("<talkrules.in");
    $start_rule = "SCITALK_LATEX";
} elsif( defined $options{"long"} ) {
    $tex_fh = new IO::File ("<scilongrules.in");
    $start_rule = "SCILONGPAPER_LATEX";
} else {
    $tex_fh = new IO::File ("<scirules.in");
    $start_rule = "SCIPAPER_LATEX";
}

my $tex_dat = scigen->new();
$tex_dat->enable(@{$options{"enable"} || []});
$tex_dat->def("SYSNAME", $sysname);
# add in authors
$tex_dat->def("AUTHOR_NAME", @authors);
my $s = "";
for( my $i = 0; $i <= $#authors; $i++ ) {
    $s .= "AUTHOR_NAME";
    if( $i < $#authors-1 ) {
	$s .= ", ";
    } elsif( $i == $#authors-1 ) {
	$s .= " and ";
    }
}
$tex_dat->def("SCIAUTHORS", $s);

$tex_dat->read_rules ($tex_fh, 0);
if( defined $title ) {
	$tex_dat->def("SCI_TITLE", $title);
}
my $tex = $tex_dat->generate ($start_rule);
open( TEX, ">$tex_file" ) or die( "Couldn't open $tex_file for writing" );
print TEX $tex;
close( TEX );

# for every figure you find in the file, generate a figure
open( TEX, "<$tex_file" ) or die( "Couldn't read $tex_file" );
my %citelabels = ();
my @figures = ();
while( <TEX> ) {

    my $line = $_;

    if( /\{(figure.*?pdf)\}/ ) {
	my $figfile = "$tmp_dir/$1";
	my $color = defined $options{"talk"} ? " --color" : "";
	&make_figure( $figfile, sub {
	    "./make-graph.pl --file \"$figfile\" --seed $_[0] " .
		"--tmpdir \"$tmp_dir\"$color$enablearg" } );
	push @figures, $figfile;
    }

    if( /\{(dia.*?pdf)\}/ ) {
	my $figfile = "$tmp_dir/$1";
	&make_figure( $figfile, sub {
	    $have_neato
		? "./make-diagram.pl --sys \"$sysname\" --file \"$figfile\" " .
		  "--seed $_[0] --tmpdir \"$tmp_dir\"$enablearg"
		: "./make-graph.pl --file \"$figfile\" --seed $_[0] " .
		  "--tmpdir \"$tmp_dir\"$enablearg" } );
	push @figures, $figfile;
    }

    if( /[=\{]([^\{]*)-(talkfig[^\,\}]*)[\,\}]/) {
	my $figfile = "$tmp_dir/$1-$2";
	my $type = $1;
	&make_figure( $figfile, sub {
	    "./make-talk-figure.pl --file \"$figfile\" --seed $_[0] " .
		"--type $type --tmpdir \"$tmp_dir\"$enablearg" } );
	push @figures, $figfile;
    }

    # find citations
    while( $line =~ s/(cite\:\d+)[,\}]// ) {
        my $citelabel = $1;
	$citelabels{$citelabel} = 1;
    }
    if( $line =~ /(cite\:\d+)$/ ) {
        my $citelabel = $1;
	$citelabels{$citelabel} = 1;
    }

}
close( TEX );

# generate bibtex 
foreach my $author (@authors) {
    for( my $i = 0; $i < 10; $i++ ) {
	push @{$tex_dat->{rules}->{"SCI_SOURCE"}}, $author;
    }
}
open( BIB, ">$bib_file" ) or die( "Couldn't open $bib_file for writing" );
foreach my $clabel (keys(%citelabels)) {
    my $sysname_cite = &get_system_name();
    $tex_dat->def("SYSNAME", $sysname_cite);
    $tex_dat->def("CITE_LABEL_GIVEN", $clabel);
    my $bib = $tex_dat->generate("BIBTEX_ENTRY");
    print BIB $bib;
    
}
close( BIB );

if( !defined $options{"savedir"} ) {

    $ENV{"TEXPICTS"} = "$tmp_dir:";
    my @class_files = split( /\s+/, $class_files );
    scigen::run_system( "cp", @class_files, $tmp_dir )
	and die( "Couldn't copy class files to $tmp_dir" );
    my @pdflatex = ( "pdflatex", "-interaction=nonstopmode", $tex_prefix );
    foreach my $cmd ( \@pdflatex, [ "bibtex", $tex_prefix ],
		      \@pdflatex, \@pdflatex ) {
	scigen::run_system( { chdir => $tmp_dir }, @$cmd );
    }
    scigen::run_system( { chdir => $tmp_dir }, "rm", "-f", @class_files );

    move( $pdf_file, $out_file )
	or die( "Couldn't write $out_file: $!" );
}

my $seedstring = "seed=$seed ";
foreach my $author (@authors) {
    $seedstring .= "author=$author ";
}

if( defined $options{"tar"} or defined $options{"savedir"} ) {
    my $f = $options{"tar"};
    my $tartmp = "$tmp_dir/tartmp.$$";
    my $all_files = "$tex_file $class_files @figures $bib_file";
    scigen::run_system( "mkdir $tartmp; cp $all_files $tartmp/;" ) and
	die( "Couldn't mkdir $tartmp" );
    $all_files =~ s/\Q$tmp_dir\E\///g;
    scigen::run_system( "echo $seedstring > $tartmp/seed.txt" ) and
	die( "Couldn't cat to $tartmp/seed.txt" );
    $all_files .= " seed.txt";

    if( defined $options{"tar"} ) {
	scigen::run_system( "cd $tartmp; tar -czf $$.tgz $all_files; cd -; " .
		"cp $tartmp/$$.tgz $f; rm -rf $tartmp" ) and 
		    die( "Couldn't tar to $f" );
    } else {
	# saving everything untarred
	my $dir = $options{"savedir"};
	# WARNING: we delete this directory if it exists
	if( -d $dir ) {
	    scigen::run_system( "rm", "-rf", $dir ) and die( "Couldn't rm existing $dir" );
	}
	scigen::run_system( "mv", $tartmp, $dir ) and die( "Couldn't move $tartmp to $dir" );
    }

} else {
    print "$seedstring\n";
}

if (defined $options{"json"}) {
	my ($title) = $tex_dat->expand("SCI_TITLE");
	my ($abstract) = $tex_dat->expand("SCI_ABSTRACT");
	my ($json) = JSON->new->utf8->pretty;
    my ($jfile) = $options{"json"};
    if ($jfile eq "") {
        $jfile = defined($out_file) ? "$out_file.json" : ".";
    }
    if (-d $jfile) {
        $jfile =~ s/\/\z//;
        $jfile .= "/scigen-$seed.pdf.json";
    }
	open(J, ">", $jfile) or die;
    my $pages;
    if (defined $out_file) {
        $pages = `mutool run countpages.js \Q$out_file\E`;
        chomp $pages;
        $pages = $pages =~ /\A[1-9][0-9]*\z/ ? int($pages) : undef;
    }
    my %jdata = ("title" => $title,
                 "abstract" => $abstract);
    $jdata{"pages"} = $pages if defined($pages);
    $jdata{"authors"} = \@authors if @authors;
    print J $json->encode(\%jdata);
	close J;
}


if( defined $out_file ) {
    print "wrote $out_file\n";
}

foreach my $enablement ($tex_dat->list_enabled()) {
    print STDERR "\n***\n*** WARNING: section $enablement not observed\n***\n\n"
        if !$tex_dat->section_observed($enablement);
}

# $tmp_dir, and everything our helpers left in it, goes away here

sub make_figure {
    my ($file, $make_cmd) = @_;
    my $cmd;

    for( my $try = 0; $try < $figure_tries; $try++ ) {
	$cmd = &$make_cmd( int rand 0xffffffff );
	return if scigen::run_system( $cmd ) == 0 and -f $file;
	unlink( $file );
    }

    die( "Couldn't create $file in $figure_tries attempts.\n" .
	 "The last command tried was:\n  $cmd\n" .
	 "Graphs need gnuplot; diagrams also use graphviz's neato.\n" );
}

sub get_system_name {

    if( $remote ) {
	return &get_system_name_remote();
    }

    if( !defined $name_dat ) {
		my $fh = new IO::File ("<system_names.in");
		$name_dat = scigen->new();
        $name_dat->enable(@{$options{"enable"} || []});
		$name_dat->read_rules($fh, 0);
    }

    my $name = $name_dat->generate ("SYSTEM_NAME");
    chomp($name);

    # how about some effects?
    my $rand = rand;
    if( $rand < .1 ) {
	$name = "\\emph{$name}";
    } elsif( length($name) <= 6 and $rand < .4 ) {
	$name = uc($name);
    }

    return $name;
}

sub get_system_name_remote {

	my $port = $scigen::SCIGEND_PORT | $scigen::SCIGEND_PORT;
    my $sock = IO::Socket::INET->new( PeerAddr => "localhost", 
				      PeerPort => $port,
				      Proto => 'tcp' );
    
    my $name;
    if( defined $sock ) {
	$sock->autoflush;
	$sock->print( "SYSTEM_NAME\n" );
	
	while( <$sock> ) { 
	    $name = $_;
	}
	$sock->close();
	undef $sock;
	
    } else {
	print STDERR "socket didn't work\n";
    }

    chomp($name);
    return $name;
}
