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
use JSON;

# Overall Merit is drawn from this distribution: P(1) = 30%, P(2) = 40%,
# P(3) = 15%, P(4) = 10%, P(5) = 5%. Reviewer Expertise is uniform on 1..4.
my @merit_weights = (30, 40, 15, 10, 5);
my $max_expertise = 4;

sub usage {
    select(STDERR);
    print <<EOUsage;

$0 [options]

Generate a conference-style review of a SCIgen paper: Overall Merit (1-5),
Reviewer Expertise (1-4), a paper summary, and comments to the authors.

  Options:

    --help                    Display this help message
    --paper <file>            Review the paper described by this JSON file,
                              as written by \`make-latex.pl --json\`. The
                              review's summary refers to the paper's title,
                              system name, and topics.
    --papers <file>           Review every paper in this JSON array of such
                              objects, writing an array of results
    --shard <k>/<n>           With --papers, review only papers whose index
                              is k mod n, for running shards in parallel
    --title <title>           Set the paper's title (overrides --paper)
    --sysname <name>          Set the paper's system name (overrides --paper)
    --merit <n>               Force the Overall Merit score (1-5)
    --expertise <n>           Force the Reviewer Expertise score (1-4)
    -n, --count <n>           Write this many reviews; the default is 1
    --seed <seed>             Seed the prng with this. With --papers, paper
                              i is seeded with <seed> + i
    -o, --file <file>         Write the review here instead of to stdout
    --json [<file>]           Write JSON instead of text. With no file name,
                              the JSON goes to stdout (or -o).
    --enable <section>        Enable a grammar section (can be repeated)

EOUsage
    exit(1);
}

my %options;
&GetOptions( \%options, "help|?", "paper=s", "papers=s", "shard=s",
    "title=s", "sysname=s", "merit=i", "expertise=i", "count|n=i", "seed=s",
    "file|o|output=s", "json:s", "enable=s@" )
    or &usage;
&usage if $options{"help"} || @ARGV;

my $count = $options{"count"} // 1;
die( "--count must be positive\n" ) if $count < 1;
if( defined $options{"merit"} ) {
    die( "--merit must be between 1 and " . scalar(@merit_weights) . "\n" )
        if $options{"merit"} < 1 || $options{"merit"} > @merit_weights;
}
if( defined $options{"expertise"} ) {
    die( "--expertise must be between 1 and $max_expertise\n" )
        if $options{"expertise"} < 1 || $options{"expertise"} > $max_expertise;
}

my $seed = $options{"seed"} // int rand 0xffffffff;
srand($seed);

# The paper being reviewed.
my ($title, $abstract, $sysname);

# Topic phrases from the paper, and one of them (@subject) that the grammar
# uses as a sentence subject, with its verb forms.
my @things = ();
my @fields = ();
my @subject;
my $sysname_dat;

# Strip the LaTeX that leaks into generated text: \cite{...} disappears,
# \emph{X} and {X} become X, `` and '' become double quotes.
sub detex {
    my ($s) = @_;
    return undef if !defined $s;
    $s =~ s/\s*\\cite\{[^{}]*\}//g;
    $s =~ s/\\(?:emph|textit|textbf|texttt|textsc)\{([^{}]*)\}/$1/g;
    $s =~ s/\\H\{o\}/\x{151}/g;
    $s =~ s/\\&/&/g;
    $s =~ s/``|''/"/g;
    $s =~ s/~/ /g;
    1 while $s =~ s/\{([^{}]*)\}/$1/g;
    $s =~ s/\$([^\$]*)\$/$1/g;
    $s =~ s/\\\\//g;
    $s;
}

sub get_system_name {
    if( !defined $sysname_dat ) {
        my $fh = new IO::File( "<system_names.in" );
        $sysname_dat = scigen->new();
        $sysname_dat->enable( @{$options{"enable"} || []} );
        $sysname_dat->read_rules( $fh, 0 );
    }
    my $name = $sysname_dat->generate( "SYSTEM_NAME" );
    chomp $name;
    $name;
}

# Make $paper, a hash with "title", "abstract", and perhaps "sysname", the
# paper under review. --title and --sysname override it.
sub set_paper {
    my ($paper) = @_;
    $title = $options{"title"} // $paper->{"title"};
    $sysname = $options{"sysname"} // $paper->{"sysname"};
    $abstract = $paper->{"abstract"} // "";
    @things = ();
    @fields = ();
    @subject = ();

    # A system name that make-latex.pl did not record can usually be found
    # in the abstract, where it appears in braces or \emph, or at the end of
    # the title.
    if( !defined $sysname ) {
        my $text = $abstract;
        $text =~ s/\\cite\{[^{}]*\}//g;
        if( $text =~ /\\emph\{([^{}]+)\}/ || $text =~ /\{([A-Za-z][^{}\s]*)\}/ ) {
            $sysname = $1;
        } elsif( defined($title)
                 && ($title =~ /\b(?:using|with)\s+(\S+)\s*\z/i || $title =~ /\A(\S+):\s/) ) {
            $sysname = $1;
        }
    }
    $sysname = get_system_name() if !defined $sysname;
    $sysname = detex( $sysname );
    $title = detex( $title );
}

# Return the entries of the named rules that appear as phrases in $text, as
# [entry, plural] pairs. Entries that refer to other rules are skipped.
sub phrases_in {
    my ($dat, $text, @rules) = @_;
    my %seen;
    my @found;
    foreach my $rule (@rules) {
        my $plural = $rule =~ /_P\z/ ? 1 : 0;
        foreach my $entry (@{$dat->{"rules"}->{$rule} || []}) {
            my $phrase = $entry;
            $phrase =~ s/\A\s+|\s+\z//g;
            $phrase =~ s/\Athe\s+//;
            next if $phrase =~ /_/ || $phrase eq "" || $seen{lc $phrase}++;
            push @found, [$entry, $plural]
                if $text =~ /(?<![\w-])\Q$phrase\E(?![\w-])/i;
        }
    }
    @found;
}

# Bullets that share a template read as padding. Return true if two bullets
# in $text start the same way once numbers, quotes, and the system name are
# ignored.
sub repetitive {
    my ($text) = @_;
    my %seen;
    foreach my $bullet ($text =~ /^- (.*)$/mg) {
        my $sig = $bullet;
        $sig =~ s/"[^"]*"/Q/g;
        $sig =~ s/\Q$sysname\E/S/g;
        $sig =~ s/[\d.,%]+/N/g;
        $sig = join(" ", grep { defined } (split(" ", lc $sig))[0 .. 5]);
        return 1 if $seen{$sig}++;
    }
    0;
}

sub pick_weighted {
    my @weights = @_;
    my $total = 0;
    $total += $_ foreach @weights;
    my $r = rand($total);
    for( my $i = 0; $i < @weights; $i++ ) {
        return $i + 1 if $r < $weights[$i];
        $r -= $weights[$i];
    }
    scalar @weights;
}

sub make_review {
    my ($merit, $expertise) = @_;

    my $dat = scigen->new();
    $dat->enable( @{$options{"enable"} || []} );
    $dat->enable( "merit$merit", "expertise$expertise" );
    $dat->enable( $merit <= 2 ? "negative" : $merit == 3 ? "middling" : "positive" );
    $dat->enable( $expertise <= 2 ? "novice" : "expert" );
    $dat->def( "SYSNAME", $sysname );
    $dat->def( "SCI_TITLE", $title ) if defined $title;
    $dat->read_rules( new IO::File( "<scireview.in" ), 0 );

    if( !defined $title ) {
        $title = detex( scalar $dat->expand( "SCI_TITLE" ) );
        $title =~ s/\s+/ /g;
    }
    $dat->def( "PAPER_TITLE", $title );

    # Topic phrases come from the paper's own title and abstract when they
    # mention things the grammar knows about, and from the grammar otherwise.
    if( !@things ) {
        my $text = "$title $abstract";
        $text =~ s/\s+/ /g;
        @things = phrases_in( $dat, $text, "SCI_THING_S", "SCI_THING_P" );
        if( !@things ) {
            my $rule = rand() < 0.5 ? "SCI_THING_S" : "SCI_THING_P";
            @things = ( [ scalar $dat->expand( $rule ), $rule =~ /_P\z/ ? 1 : 0 ] );
        }
        @subject = @{$things[int rand @things]};
        @fields = map { $_->[0] } phrases_in( $dat, $text, "SCI_FIELD" );
        @fields = ( "SCI_FIELD" ) if !@fields;
    }
    $dat->def( "PAPER_THING", map { $_->[0] } @things );
    $dat->def( "PAPER_SUBJECT", $subject[0] );
    $dat->def( "PAPER_IS_ARE", $subject[1] ? "are" : "is" );
    $dat->def( "PAPER_HAS_HAVE", $subject[1] ? "have" : "has" );
    $dat->def( "PAPER_FIELD", @fields );

    my $summary = detex( scalar $dat->expand( "REV_SUMMARY" ) );
    my $comments;
    for( my $try = 0; $try < 10; $try++ ) {
        $comments = detex( scalar $dat->expand( "REV_COMMENTS" ) );
        last if !repetitive( $comments );
    }
    foreach ($summary, $comments) {
        # Autoformat does not capitalize after a sentence that ends in a
        # number or an all-caps word, and indents bullet continuations by
        # one space rather than under the text.
        s/(?<!\bal)(?<!\be\.g)(?<!\bi\.e)(?<!\bvs)([.?!]["')]?\s+)([a-z])/$1\u$2/g;
        s/^ (?=\S)/  /mg;
        s/[ \t]+$//mg;
        s/\n{3,}/\n\n/g;
        s/\A\n+|\n+\z//g;
    }

    return { "merit" => 0 + $merit, "expertise" => 0 + $expertise,
             "summary" => $summary, "comments" => $comments };
}

sub review_paper {
    my @reviews;
    for( my $i = 0; $i < $count; $i++ ) {
        my $merit = $options{"merit"} // pick_weighted( @merit_weights );
        my $expertise = $options{"expertise"} // (1 + int rand $max_expertise);
        push @reviews, make_review( $merit, $expertise );
    }
    foreach my $r (@reviews) {
        $r->{"title"} = $title;
        $r->{"sysname"} = $sysname;
    }
    @reviews;
}

sub read_json {
    my ($file) = @_;
    my $fh = new IO::File( "<$file" ) or die( "$file: $!\n" );
    local $/;
    JSON->new->utf8->decode( scalar <$fh> );
}

sub print_reviews {
    my ($out, @reviews) = @_;
    my $i = 0;
    foreach my $r (@reviews) {
        print $out "\n", "=" x 72, "\n\n" if $i++;
        print $out "Overall Merit: $r->{merit}\n",
            "Reviewer Expertise: $r->{expertise}\n\n",
            "Paper Summary:\n$r->{summary}\n\n",
            "Comments to Author:\n$r->{comments}\n";
    }
}

my $out = \*STDOUT;
if( defined $options{"json"} && $options{"json"} ne "" ) {
    $out = new IO::File( ">" . $options{"json"} )
        or die( "$options{json}: $!\n" );
} elsif( defined $options{"file"} ) {
    $out = new IO::File( ">" . $options{"file"} )
        or die( "$options{file}: $!\n" );
}
binmode( $out, ":utf8" );
my $json = JSON->new->pretty->canonical;

if( defined $options{"papers"} ) {
    my ($shard, $nshards) = (0, 1);
    if( defined $options{"shard"} ) {
        ($shard, $nshards) = $options{"shard"} =~ /\A(\d+)\/(\d+)\z/
            or die( "--shard wants <k>/<n>\n" );
        die( "--shard <k> must be less than <n>\n" ) if $shard >= $nshards;
    }
    my $papers = read_json( $options{"papers"} );
    die( "$options{papers}: not a JSON array\n" ) if ref($papers) ne "ARRAY";
    my @results;
    for( my $i = 0; $i < @$papers; $i++ ) {
        next if $i % $nshards != $shard;
        srand( $seed + $i );
        set_paper( $papers->[$i] );
        my @reviews = review_paper();
        if( defined $options{"json"} ) {
            my %result = ( "index" => $i, "title" => $title,
                           "sysname" => $sysname, "seed" => $seed + $i,
                           "reviews" => \@reviews );
            my $sub = $papers->[$i]->{"submission"};
            $result{"content_file"} = $sub->{"content_file"}
                if ref($sub) eq "HASH" && defined $sub->{"content_file"};
            push @results, \%result;
        } else {
            print $out "\n", "#" x 72, "\n\n" if @results;
            print $out "Paper $i: $title\n\n";
            print_reviews( $out, @reviews );
            push @results, $i;
        }
    }
    print $out $json->encode( \@results ) if defined $options{"json"};
} else {
    my $paper = defined $options{"paper"} ? read_json( $options{"paper"} ) : {};
    set_paper( $paper );
    my @reviews = review_paper();
    if( defined $options{"json"} ) {
        $_->{"seed"} = $seed foreach @reviews;
        print $out $json->encode( \@reviews );
    } else {
        print_reviews( $out, @reviews );
    }
}

print STDERR "seed=$seed\n" if !defined $options{"seed"};
