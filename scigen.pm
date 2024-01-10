package scigen;

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
use IO::File;
use Data::Dumper;
require "./Autoformat.pm";
use vars qw($SCIGEND_PORT %SCIINFO);

#### daemon settings ####
$SCIGEND_PORT = 4724;

sub new {
    my $class = shift;
    return bless {
	"rules" => {},
	"included" => {},
	"nodup" => {},
	"fixed" => {},
	"format" => {},
	"re" => undef
    }, $class;
}

sub read_rules {
    my $self = shift;
    my ($fh, $debug) = @_;
    my $line;
    my $rules = $self->{rules};
    my $format = $self->{format};
    while ($line = <$fh>) {
	next if $line =~ /^#/ ;
	next if $line !~ /\S/ ;

	my @words = split /\s+/, $line;
	my $name = shift @words;
	my $rule = "";

	# non-duplicate rule
	if( $name =~ /\A([^\+.=]*)\!\z/ ) {
	    if (!exists($self->{nodup}->{$1})) {
		$self->{nodup}->{$1} = [];
	    }
	    next;
	}

	# fixed rule
	if( $name =~ /\A([^\+.=]*)\.\z/ ) {
	    if (!exists($self->{fixed}->{$1})) {
		$self->{fixed}->{$1} = undef;
	    }
	    next;
	}

	# formatting instruction
	if ($name =~ /\A([^\+.=]*)=(\w*)\z/) {
	    $format->{$1} = $2;
	    next;
	}

	# include rule
	if( $name =~ /\.include$/ ) {
	    my $file = $words[0];
	    # make sure we haven't already included this file
	    # NOTE: this allows the main file to be included at most twice
	    if( defined $self->{included}->{$file} ) {
		if( $debug > 0 ) {
		    print "Skipping duplicate included file $file\n";
		}
		next;
	    } else {
		$self->{included}->{$file} = 1;
	    }
	    if( $debug > 0 ) {
		print "Opening included file $file\n";
	    }
	    my $inc_fh = new IO::File ("<$file");
	    if( !defined $inc_fh ) {
		die( "Couldn't open included file $file" );
	    }
	    $self->read_rules( $inc_fh, $debug );
	    next; # we don't want to have .include itself be a rule
	}

	# default formatting instruction
	if (!defined($format->{$name})
	    && $name =~ /_(?:PARAGRAPH|PAR)(?=_|\z)/) {
	    $format->{$name} = "text";
	}

	if ($#words == 0 && $words[0] eq '{') {
	    my $end = 0;
	    while ($line = <$fh>) {
		if ($line =~ /^}[\r\n]+$/) {
		    $end = 1;
		    last;
		} else {
		    $rule .= $line;
		}
	    }
	    if (! $end) {
		die "$name: EOF found before close rule\n";
	    }
	} else {
	    $line =~ s/^\S+\s+//; 
	    chomp ($line);
	    $rule = $line;
	}

	# look for the weight
	my $weight = 1;
	if( $name =~ /([^\+]*)\+(\d+)$/ ) {
	    $name = $1;
	    $weight = $2;
	    if( $debug > 10 ) {
		warn "weighting rule by $weight: $name -> $rule\n";
	    }
	}

	do {
	    push @{$rules->{$name}}, $rule;
	} while( --$weight > 0 );
    }
    $self->{re} = undef;
}

sub add {
    my ($self, $name, @options) = @_;
    my $rules = $self->{rules};
    if (!exists($rules->{$name})) {
	$self->{re} = undef;
	$rules->{$name} = [];
    }
    push @{$rules->{$name}}, @options;
}

sub def {
    my ($self, $name, @options) = @_;
    my $rules = $self->{rules};
    if (!exists($rules->{$name})) {
	$self->{re} = undef;
    }
    $rules->{$name} = [@options];
}

sub re {
    my $self = shift;
    if (!defined($self->{re})) {
	# must sort; order matters, and we want to make sure that we get
	# the longest matches first
	my $in = join "|", sort { length ($b) <=> length ($a) } keys %{$self->{rules}};
	$self->{re} = qr/^(.*?)(${in})/s ;
    }
    $self->{re};
}

sub generate {
    my ($self, $start, $pretty, $debug) = @_;


    my $s = $self->expand ($start, $debug);
    if( $pretty ) {
	$s = pretty_print($s);
    }
    return $s;
}

sub pick_rand {
    my ($set) = @_;
    my $n = $#$set + 1;
    my $v =  @$set[int (rand () * $n)];
    return $v;
}

sub pop_first_rule {
    my ($self, $preamble, $input, $rule) = @_;

    $$preamble = undef;
    $$rule = undef;

    my $ret = undef;
    my $RE = $self->re();

    if ($$input =~ s/$RE//s ) {
	$$preamble = $1;
	$$rule = $2;
	return 1;
    }

    return 0;
}

sub break_latex ($$$) {
    my ($text, $reqlen, $fldlen) = @_;
    if( !defined $text ) {
	$text = "";
    }
    ($text, "");
}

sub pretty_print {
    my ($s) = shift;

    my $news = "";
    my @lines = split( /\n/, $s );
    foreach my $line (@lines) {
	$line =~ s/(\s+)([\.\,\?\;\:])/$2/g;
	$line =~ s/(\b)(a)\s+([aeiou])/$1$2n $3/gi;

	if( $line =~ /\S/ && $line !~ /(.*) = \{(.*)\}\,/ ) {
	    $line = 
	      Autoformat::autoformat( $line, { case => 'sentence', 
					       squeeze => 0, 
					       break => \&break_latex,
					       ignore => qr/^\\/m } );
	}

	if( $line !~ /\n$/ ) {
	    $line .= "\n";
	}
	$news .= $line;

    }

    return $news;
}

sub expand {
    my ($self, $start, $debug) = @_;
    my ($rules) = $self->{rules};
    $debug = 0 if !defined($debug);

    # check for special rules ending in + and # 
    # Rules ending in + generate a sequential integer
    # The same rule ending in # chooses a random # from among previously
    # generated integers
    if( $start =~ /(.*)\+$/ ) {
	my $rule = $1;
	my $i = $rules->{$rule};
	if( !defined $i ) {
	    $i = 0;
	    $rules->{$rule} = 1;
	} else {
	    $rules->{$rule} = $i+1;
	}
	return $i;
    }

    if( $start =~ /(.*)\#$/ ) {
	my $rule = $1;
	my $i = $rules->{$rule};
	if( !defined $i ) {
	    $i = 0;
	} else {
	    $i = int rand $i;
	}
	return $i;
    }

    # check for fixed expansion
    if (defined($self->{fixed}->{$start})) {
	return $self->{fixed}->{$start};
    }

    my $format = $self->{format}->{$start};
    my $full_token;
    my $repeat = 0;
    my $count = 0;
    do {

	my $input = pick_rand ($rules->{$start});
	$count++;
	if ($debug >= 5) {
	    warn "$start -> $input\n";
	}

	my ($pre, $rule);
	my @components;
	$repeat = 0;	

	while ($self->pop_first_rule (\$pre, \$input, \$rule)) {
	    my $ex = $self->expand ($rule, $debug);
	    push @components, $pre if length ($pre);
	    push @components, $ex if length ($ex);
	}
	push @components, $input if length ($input);
	$full_token = join "", @components;

	if (defined($format)) {
	    $full_token =~ s/\s+(?=[\.\,\?\;\:])//g;
	    $full_token =~ s/\b(a)\s+(?=[aeiou])/$1n /gi;
	    if ($format eq "title") {
		$full_token = Autoformat::autoformat( $full_token, { case => 'highlight', squeeze => 0  } );
		$full_token =~ s/\s+/ /gs;
		$full_token =~ s/\A\s+|\s+\z//g;
	    } elsif ($format eq "bibtex") {
		$full_token =~ s/(\\\S+|\w*[A-Z][\w\*]*)/\{$1\}/g;
		$full_token = Autoformat::autoformat( $full_token, { case => 'highlight', squeeze => 0  } );
		1 while chomp($full_token);
	    } elsif ($format eq "text") {
		$full_token = Autoformat::autoformat( $full_token, { case => 'sentence',
					       squeeze => 0,
					       break => \&break_latex,
					       ignore => qr/^\\/m } );
		$full_token =~ s/  +/ /g;
		1 while chomp($full_token);
	    }
	}

	my $duplist = $self->{nodup}->{$start};
	if( defined $duplist ) {
	    # make sure we haven't generated this exact token yet
	    foreach my $d (@$duplist) {
		if( $d eq $full_token ) {
		    $repeat = 1;
		}
	    }
	    
	    if( !$repeat ) {
		push @$duplist, $full_token;
	    } elsif( $count > 50 ) {
		$repeat = 0;
	    }
	    
	}

    } while( $repeat );

    if (exists($self->{fixed}->{$start})) {
	$self->{fixed}->{$start} = $full_token;
    }

    return $full_token;
    
}


1;
