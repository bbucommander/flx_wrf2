#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;

=pod

0.2 Get rid of "common" variables, move them into function arguments 
		This is refactoring, and there is really only one proper way to do this:
		- parse the FORTRAN source in a labeled-block-aware way
		- check which variables from the common block are used
		- put them in the function signature
		- for variables declared outside the block in question, find the ones that are used within the block
		and add them to the function signature as well

Now, I don't have a full FORTRAN parser, but let's see what we can do with some limiting assumptions:
- assume the block is simply identified with a comment "C BEGIN blockname" and "C END blockname"
- assume any line starting with /^\s[\+\&]/ is a continuation line, deal with these first
- assume that _all_ variables in includecom are common, and _all_ variable in includepar are parameters?
That won't do. No, we read the includes, and parse the "common" blocks
- we're only really interested in a few specific intrinsic types: 
/(integer|real|double\s+precision|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/ 

The most difficult bit is finding the variables, I guess \W$varname\W should do?

With these assumptions, we can write a crude parser and function arg identifier as follows:
0. Slurp the source; strip the comments
1. Join up the continuation lines (maybe split lines with ; )
2. Parse the type declarations in the source, create a table %vars
3. Parse includes, recursively doing 0/1/2
4. For includes, parse common blocks, create %commons
5. Split the source based on the block markers
6. Identify which vars are used
	- in both => these become function arguments
	- only in "outer" => do nothing for those
	- only in "inner" => can be removed from outer variable declarations
7. Identify which commons are used in inner, make them function arguments

Not necessarily in this order:
8. When encountering a CALL, recurse and resolve globals (but only that)
9. When encountering a  function call, idem; although I'd prefer it if functions would be pure!
10. F2C-ACC is a bit buggy, so help it a bit: identify which CONTINUE statements are actually END DO
and replace them accordingly; for the other CONTINUE statements, it might be better to 
ensure that instead of CONTINUE, they do nothing in a different way. 
The only reliable way I found is to replace the continue with call noop, where noop is a subroutine that does nothing

How do we replace the args in a subroutine call?

- Find a subroutine call
- first check if we now about it by looking in a list of subroutine calls => We use 'IsSub'
- if we know it, it means we have resolved the globals, the list should be added to the node;
then just add the globals to the call
- otherwise, add the index in the list of source lines to a hash of subs 
- in fact, this can be a hash of "anythings", i.e.
 
    $stref->{'Nodes'}{$filename}{'SubroutineCall'}{$name}={'Pos'=>[$index,...],'Globals'=>[],...};
    
    As this is a "global", I need to pass it around between calls.
- recurse and figure out globals used. also, store the signature in the node hash
- add the globals to the end of the signature, and emit the new code.
- it would be nice to emit the code in a hash 

    $refactored_sources{$filename}=\@lines;
    
- return the list of all the globals to be added to the call
- update the call in %refactored_sources

Maybe I can use "Sources" as "Nodes", basically if it's a subroutine we'll have a Sig field and a Globals field as well?
A better structure us for every source to have Nodes. 

After building this structure, what we need is to go through it an revert it so it becomes index => information

=cut

our $V = 1;

die "Please specifiy FORTRAN source to refactor\n" if not @ARGV;
my $filename = $ARGV[0];

# without '.f'
$filename =~ s/\.f//;
my $stateref = {
	'Commons' => {},
	'Parameters' => {},
	'Sources' => {

		#		 for every file, a list of the source lines.
		#		 $f => {
		#			'Lines' =>[],
		#			'Blocks'=>{$block=>[]},
		#		  'IsIncl'=>0|1
		#		  'HasBlocks'=>0|1
		#		  'IsSub'=>0|1
		#		  'Nodes'=>	{
		#		  	'SubroutineCall'=>{
		#		  		$name=>{'Pos'=>[$index,...],'Globals'=>[],...};
		#            }
		#		    'SubroutineSig'=>{'Pos'=>[$index,...],'Globals'=>[],...};
		#		    'VarDecls'=>
		#		    ...
		#		  }

	},
	'RefactoredSources' => {},
};

# First we analyse the code for use of globals and blocks to be transformed into subroutines
$stateref = parse_fortran_src( $filename, $stateref );

# Then we create an "inverted index" of the information we have gathered, by line of the orginal source.
# One important point is that we must mark all blocks to be refactored as such, so those lines can be skipped!

$stateref = get_info_per_line($stateref);

show_info($stateref);

# Refactor the source
$stateref = refactor_code($stateref);

# Emit the refactored source

exit(0);

sub parse_fortran_src {
	( my $f, my $stref ) = @_;

	$stref = read_fortran_src( $f, $stref );

	my $is_incl    = $stref->{'Sources'}{$f}{'IsIncl'};
	my $has_blocks = $stref->{'Sources'}{$f}{'HasBlocks'};

	#    $stref = mark_comments( $f, $stref );

	# 2. Parse the type declarations in the source, create a table %vars
	$stref = get_var_decls( $f, $stref );

	# 3. Parse includes, recursively doing 0/1/2
	if ( not $is_incl ) {
		$stref = parse_includes( $f, $stref );
		$stref = parse_subroutine_calls( $f, $stref );
		$stref = remove_globals_from_subroutines( $f, $stref );
	}
	else {    # includes
		      # 4. For includes, parse common blocks and parameters, create $stref->{'Commons'}
		$stref = get_commons_params_from_includes( $f, $stref );
	}

    for my $i ( keys %{$stref->{'Sources'}{$f}{'Nodes'}{'Include'} }) {    	
    	if ($stref->{'Sources'}{$i}{'InclType'} eq 'Common') {
    		$stref->{'Sources'}{$f}{'HasCommons'}=1;    		
    		last;
    	}    	
    }
    
# 5. Split the source based on the block markers
# As there could be several blocks (later), use a hash per block
# This could happen in any file except includes; but include processing never comes here
	if ($has_blocks) {
		$stref = refactor_blocks( $f, $stref );
	}
    
	return $stref;

}    # END of parse_fortran_src()

# =============================================================================

=info_refactoring

for every line
- check if it needs changing:
- need to mark the insert points for subroutine calls that replace the refactored blocks! 
This is a node called 'RefactoredSubroutineCall'
- we also need the "entry point" for adding the declarations for the localized global variables 'ExGlobVarDecls'

* SubroutineSig: add the globals to the signature
(* VarDecls: keep as is)
* ExGlobVarDecls: add new var decls
* SubroutineCall: add globals for that subroutine to the call
* RefactoredSubroutineCall: insert a new subroutine call instead of the "begin of block" comment. 
* InBlock: skip; we need to handle the blocks separately
* BeginBlock: insert the new subroutine signature and variable declarations
* EndBlock: insert END
* BeginDo: just remove the label
* EndDo: replace CONTINUE by END DO
(* Break: keep as is; add a comment to identify it as a break)
* BreakTarget: replace CONTINUE with "call noop"


=cut

sub refactor_code {
	if ($V) {
    print "\n\n";
    print "#" x 80, "\n";
    print "Refactoring\n";
    print "#" x 80, "\n\n";
    }
	( my $stref ) = @_;
	for my $f ( keys %{ $stref->{'Sources'} } ) {
		print "\nSOURCE FILE: $f\n\n";
		my @lines = @{ $stref->{'Sources'}{$f}{'Lines'} };
		my @info  = @{ $stref->{'Sources'}{$f}{'Info'} };
		if ($stref->{'Sources'}{$f}{'HasCommons'}) {
		for my $line (@lines) {
			my $tags_lref = shift @info;
			my %tags = (defined $tags_lref ) ? %{$tags_lref} : ('Nil'=>[]);
			my $skip=0;			
			if ( exists $tags{'Comment'}) {
				$skip=1;
			}

				if (exists $tags{'SubroutineSig'}) {
					my $name=$tags{'SubroutineSig'}{'Name'};
					my @args=@{$tags{'SubroutineSig'}{'Args'}};
					my @exglobs = @{ $stref->{'Sources'}{$f}{'Nodes'}{'ExGlobVarDecls'}{'Globals'} };
					print ' ' x 6, 'subroutine ',$name,'(',join(',', (@args,@exglobs)),')',"\n"; 
					$skip=1;
				}
				if (exists $tags{'ExGlobVarDecls'}) {
                    for my $var (@{$tags{'ExGlobVarDecls'}{'Globals'} }) {
                    	print $stref->{'Commons'}{$var}{'Decl'},"\n";
                    }                    
                }
			    if (exists $tags{'Include'} ) {
			    	(my $inc,my $r)= each %{$tags{'Include'}};
			    	if ($stref->{'Sources'}{$inc}{'InclType'} eq 'Common') {
			    		$skip=1;
			    	}
			    }
			print $line,"\n" unless $skip; 
            
		}
		die;
		}
	}
	return $stref;
}

sub show_info {
	   if ($V) {
    print "\n\n";
    print "#" x 80, "\n";
    print "Info\n";
    print "#" x 80, "\n\n";
    }
	( my $stref ) = @_;
	for my $f ( keys %{ $stref->{'Sources'} } ) {
		print "\nSOURCE FILE: $f\n\n";
		if (exists $stref->{'Sources'}{$f}{'Lines'}) {
		my @lines = @{ $stref->{'Sources'}{$f}{'Lines'} };
		my @info  = @{ $stref->{'Sources'}{$f}{'Info'} };
		
		for my $item (@info) {
			if ( defined $item ) {			
				 print join( ',',keys %{$item}), "\n";				
			}
		}
		}
	}
}

# =============================================================================
sub parse_subroutine_calls {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Sources'}{$f}{'Lines'};
	my $index  = 0;
	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}
		if ( $line =~ /call\s(\w+)\((.*)\)/ ) {

			#			print $line, "\n" if $V;
			my $name = $1;
			my $argstr= $2;
			# Not nice, but as we push the index and the args at the same time, it should be OK
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'SubroutineCall'}{$name}
				  {'Pos'} }, $index;
            push @{ $stref->{'Sources'}{$f}{'Nodes'}{'SubroutineCall'}{$name}
                  {'Args'} }, $argstr;				  

			if (   not exists $stref->{'Sources'}{$name}
				or not exists $stref->{'Sources'}{$name}{'IsSub'} )
			{
				$stref->{'Sources'}{$name}{'IsIncl'} = 0;
				$stref->{'Sources'}{$name}{'IsSub'}  = 1;
				print "Processing SUBROUTINE $name\n";
				$stref = parse_fortran_src( $name, $stref );
			}

			#			else {
			#				print "DIED in $f, $name call\n";
			#				die Dumper($stref->{'Sources'}{$f});
			#			}

		}
		$index++;
	}
	return $stref;
}

sub remove_globals_from_subroutines {

# we descend in the subroutine
# we resolve all globals
# so all we need to do really here is add a list of the used globals to the Node
# 7. Identify which commons are used in inner, make them function arguments
# This is almost the same as above
	( my $f, my $stref ) = @_;
	my $srcref          = $stref->{'Sources'}{$f}{'Lines'};
	my $index           = 0;
	my @args_from_globs = ();
	my %tvars = %{ $stref->{'Commons'} };    # Hurray for pass-by-value!

	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}

		if ( $line =~ /^\s+subroutine\s+(\w+)\((.*)\)/ ) {
			my $name   = $1;
			my $argstr = $2;
			my @args   = split( /\s*,\s*/, $argstr );

# FIXME: this assumes a single subroutine per file. So we should actually ensure that this is the case!
			$stref->{'Sources'}{$f}{'Nodes'}{'SubroutineSig'}{'Args'} = \@args;
			$stref->{'Sources'}{$f}{'Nodes'}{'SubroutineSig'}{'Name'} = $name;
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'SubroutineSig'}{'Pos'} },
			  $index;
		}
		for my $var ( keys %tvars ) {
			if ( $line =~ /\W$var\W/ ) {
				push @args_from_globs, $var;
				delete $tvars{$var};
			}
		}
		$index++;
	}
	if ($V) {
		print "\nCOMMON VARS in subroutine $f:\n\n";
		for my $var (@args_from_globs) {
			print "$var\n";
		}
	}
	$stref->{'Sources'}{$f}{'Nodes'}{'ExGlobVarDecls'}{'Globals'} = \@args_from_globs;
	return $stref;
}

sub parse_includes {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Sources'}{$f}{'Lines'};
	my $index  = 0;
	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}

		if ( $line =~ /^\s*include\s+\'(\w+)\'/ )
		{    # TODO: nested includes not supported!

			my $name = $1;			
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'Include'}{$name}{'Pos'} },
			  $index;

			if (   not exists $stref->{'Sources'}{$name}
				or not exists $stref->{'Sources'}{$name}{'IsIncl'} )
			{
#				$line = 'C ' . $line;
				print $line, "\n" if $V;
				$stref->{'Sources'}{$name}{'IsIncl'} = 1;
				$stref->{'Sources'}{$name}{'IsSub'}  = 0;
				$stref = parse_fortran_src( $name, $stref );
			}
			else {
				print $line, " already processed\n" if $V;
			}

		}
		$index++;
	}
	return $stref;
}

sub get_var_decls {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Sources'}{$f}{'Lines'};

	print "\n VAR DECLS in $f:\n" if $V;
	my %vars  = ();
	my $index = 0;
	my $first = 1;
	for my $line ( @{$srcref} ) {

		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}
# real surfstrn(0:nxmaxn-1,0:nymaxn-1,1,2,maxnests)
		if ( $line =~
/(logical|integer|real|double\s+precision|character|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/
		  )
		{
			my $type   = $1;
			my $varlst = $2;
			my $tvarlst = $varlst;
#			$tvarlst =~ s/\(.*?\)/(0)/g;    # clean up arrays
#            $tvarlst =~ s/\(//;

if ($tvarlst =~/\(((?:[^\(\),]*?,)+[^\(]*?)\)/) {
	while ($tvarlst =~/\(((?:[^\(\),]*?,)+[^\(]*?)\)/) {
	my $chunk=$1;
	my $chunkr=$chunk;
	$chunkr=~s/,/;/g;
	my $pos=index($tvarlst,$chunk);
	substr($tvarlst,$pos,length($chunk),$chunkr);
#	print "FOUND $line:\n$chunk\t$chunkr\n$tvarlst\n";
} }

#			$tvarlst =~ s/\(([^\(\),]*?),([^\(]*?)\)/($1;$2)/g && print $tvarlst ,"\n"; 
			my @tvars = split( /\s*\,\s*/, $tvarlst );
			my $p = '';
			for my $var (@tvars) {				
				$var =~ s/^\s+//;
				$var =~ s/\s+$//;
				my $tvar=$var;
				$tvar =~ s/\(.*?\)/(0)/g;				
				if ( $tvar =~ s/\(.*?\)// ) {
					$tvar =~
					  s/\*\d+//;   # FIXME: char string handling is not correct!
					$vars{$tvar}{'Kind'} = 'Array';
					$p = '()';
				}
				else {
					$vars{$tvar}{'Kind'} = 'Scalar';
				}
				$vars{$tvar}{'Type'} = $type;
				$var=~s/;/,/g;
				$vars{$tvar}{'Decl'} = "      $type $var"; # TODO: this should maybe not be a textual representation
				print $type, $p, "\t<", $tvar, ">: $var\n" if $V;
			}
			
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'VarDecl'}{'Pos'} },
			  $index;
			if ($first) {
				$first = 0;
				push @{ $stref->{'Sources'}{$f}{'Nodes'}{'ExGlobVarDecls'}
					  {'Pos'} },
				  $index;
			}
		}
		
		$index++;
	}
	
	$stref->{'Vars'}{$f} = \%vars;
	return $stref;
}

sub get_commons_params_from_includes {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Sources'}{$f}{'Lines'};
	my %vars   = %{ $stref->{'Vars'}{$f} };
	my $has_pars=0;
	my $has_commons=0;
	my $index = 0;

	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}

		if ( $line =~ /^\s*common\s+\/[\w\d]+\/\s+(.+)$/ ) {	
			
			my $commonlst = $1;
			$has_commons=1;

			my @tcommons = split( /\s*\,\s*/, $commonlst );
			
			for my $var (@tcommons) {
				if ( not defined $vars{$var} ) {
					print "MISSING: <", $var, ">\n" ;
				}
				else {
#					print $var, "\t",  $vars{$var}{'Type'}, "\n" if $V;
					$stref->{'Commons'}{$var} = $vars{$var};
				}
			}
			         push @{ $stref->{'Sources'}{$f}{'Nodes'}{'Common'}{$f}{'Pos'} },
              $index;
			
		}
		
      if ($line=~/parameter\s*\(\s*(.*)\s*\)/ ) { 
              my $parliststr=$1;
              $has_pars=1;
              my @partups = split(/\s*,\s*/,$parliststr);
              my @pvars=map {s/\s*=.+//;$_} @partups;
              
               for my $var (@pvars) {
                if ( not defined $vars{$var} ) {
                    print "NOT A PARAMETER: <", $var, ">\n" ;
                }
                else {
#                    print $var, "\t",  $vars{$var}{'Type'}, "\n" if $V;
                    $stref->{'Parameters'}{$var} = $vars{$var};
                }
            }
                    push @{ $stref->{'Sources'}{$f}{'Nodes'}{'Parameter'}{$f}{'Pos'} },
              $index;   
            
        }
		
		
		$index++;
	}

	#	if ($V) {
	#		print "\nCOMMON VARS:\n\n" ;
	#		for my $v ( keys %{ $stref->{'Commons'} } ) {
	#			print $stref->{'Commons'}{$v}, "\t", $v, "\n";
	#		}
	#	}
	
	# FIXME!
	# An include file should basically only contain parameters and commons.
	# If it contains commons, we should remove them!
	if ($has_commons && $has_pars){
		die "The include file $f contains both parameters and commons, this is at the moment not supported.\n";
	} elsif ($has_commons) {
		$stref->{'Sources'}{$f}{'InclType'}='Common';
	} elsif ($has_pars) {
		$stref->{'Sources'}{$f}{'InclType'}='Parameter';
	} else {
		die "The include file $f contains neither parameters nor commons, this is at the moment not supported.\n";
	}
	for my $var (keys %vars) {
		if ( 
		  ($has_pars and not exists( $stref->{'Parameters'}{$var})) 
		  or ($has_commons and not exists( $stref->{'Commons'}{$var}) )
		) {
			die "The include $f contains a variable $var that is neither a parameter nor a common variable\n"; 
		}
	}

	return $stref;
}

sub refactor_blocks {
	( my $f, my $stref ) = @_;
	my $srcref = $stref->{'Sources'}{$f}{'Lines'};
	my %vars   = %{ $stref->{'Vars'}{$f} };
	my %occs   = ();

	#        my %occs=%{$stref->{'Occs'}{$f}};
	my %blocks   = ();
	my $in_block = 0;
	my $block    = 'OUTER';
	my $index    = 0;
	for my $line ( @{$srcref} ) {
		if ( $line =~ /^C\s+/ ) {
			$index++;
			next;
		}

		# skip subroutine decl
		$line =~ /^\s+subroutine/ && next;
		$line =~
/(logical|integer|real|double\s+precision|character|character\*?(?:\d+|\(\*\)))\s+(.+)\s*$/
		  && next;
		if ( $line =~ /^C\s+BEGIN\s+(\w+)/ ) {
			$in_block = 1;
			$block    = $1;
			push @{ $blocks{'OUTER'} }, $line;
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'RefactoredSubroutineCall'}
				  {'Pos'} }, $index;
			$stref->{'Sources'}{$f}{'Nodes'}{'RefactoredSubroutineCall'}
			  {'Name'} = $block;
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'BeginBlock'}{'Pos'} },
			  $index;
			next;
		}
		if ( $line =~ /^C\s+END\s+(\w+)/ ) {
			$in_block = 0;
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'EndBlock'}{'Pos'} },
			  $index;
			next;
		}
		if ($in_block) {
			push @{ $blocks{$block} }, $line;
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'InBlock'}{'Pos'} },
			  $index;
		}
		else {
			push @{ $blocks{'OUTER'} }, $line;
		}
		$index++;
	}
	for my $block ( keys %blocks ) {
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Lines'} = $blocks{$block};
	}

  # So now we have split the file in blocks, we have identified the common vars.

# 6. Identify which vars are used
#   - in both => these become function arguments
#   - only in "outer" => do nothing for those
#   - only in "inner" => can be removed from outer variable declarations
# Find all vars used in each block, starting with the outer block
# It is best to loop over all vars per line per block, because we can remove the encountered vars
	for my $block ( keys %blocks ) {
		my @lines = @{ $blocks{$block} };
		my %tvars = %vars;                  # Hurray for pass-by-value!
		print "\nVARS in $block:\n\n" if $V;
		for my $line (@lines) {
			for my $var ( keys %tvars ) {
				if ( $line =~ /\W$var\W/ ) {
					print "$var\n" if $V;
					$occs{$block}{$var} = $var;
					delete $tvars{$var};
				}
			}
		}
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Occs'} = $occs{$block};
	}

	my %args = ();
	for my $block ( keys %occs ) {
		next if $block eq 'OUTER';
		print "\nARGS for $block:\n" if $V;
		for my $var ( keys %{ $occs{$block} } ) {
			if ( exists $occs{'OUTER'}{$var} ) {
				print "$var\n" if $V;
				push @{ $args{$block} }, $var;
			}
		}
	}

	# 7. Identify which commons are used in inner, make them function arguments
	# This is almost the same as above
	for my $block ( keys %blocks ) {
		next if $block eq 'OUTER';
		my @lines = @{ $blocks{$block} };
		my %tvars = %{ $stref->{'Commons'} };    # Hurray for pass-by-value!

		for my $line (@lines) {
			for my $var ( keys %tvars ) {
				if ( $line =~ /\W$var\W/ ) {

					push @{ $args{$block} }, $var;
					delete $tvars{$var};
				}
			}
		}
		if ($V) {
			print "\nCOMMON VARS in block $block:\n\n";
			for my $var ( @{ $args{$block} } ) {
				print "$var\n";
			}
		}
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Args'} = $args{$block};
	}

	# Construct the subroutine signatures
	for my $block ( keys %blocks ) {
		next if $block eq 'OUTER';
		my $sig   = "\tsubroutine $block(\n";
		my $decls = '';
		for my $argv ( @{ $args{$block} } ) {
			$sig .= "     &\t $argv,\n";
			my $type = $vars{$argv} || $stref->{'Commons'}{$argv};
			$decls .= $type . ' ' . $argv . "\n";
		}
		$sig =~ s/\,$/)\n/s;
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Args'}  = $args{$block};
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Sig'}   = $sig;
		$stref->{'Sources'}{$f}{'Blocks'}{$block}{'Decls'} = $decls;
		print $sig   if $V;
		print $decls if $V;
	}
	return $stref;
}    # END of refactor_blocks()

sub read_fortran_src {
	( my $f, my $stref ) = @_;
	my $is_incl = $stref->{'Sources'}{$f}{'IsIncl'} || 0;
	my $ext = $is_incl ? '' : '.f';
    my $ok=1;
	open my $SRC, '<', "$f$ext" or do {
		print STDERR "Can't find $f$ext\n";
		$ok=0;
	};
	if ($ok) {
	my $lines      = [];
	my $prevline   = '';
	my $has_blocks = 0;

	# 0. Slurp the source; standardise the comments
	# 1. Join up the continuation lines
	# TODO: split lines with ;
	my $index = 0;
	my $line  = '';
	while (<$SRC>) {
		$line = $_;
		chomp $line;

		# Skip blanks
		$line =~ /^\s*$/ && next;

		# Detect and standardise comments
		if ( $line =~ /^[C\*\!]/i && $line !~ /C\s+(?:BEGIN|END)\s+\w+/ ) {
			$line =~ s/^[Cc\*\!]/C /;
			push @{$lines}, $line
			  ; # bit half-baked, it might be better to tag the line as being a comment?
			push @{ $stref->{'Sources'}{$f}{'Nodes'}{'Comments'}{'Pos'} },
			  $index;
			$index++;
			next;
		}
		elsif ( $line =~ /C\s+BEGIN\s+\w+/ ) {
			$has_blocks = 1;
		}

		# convert trailing comments into comments on the previous line
		if ( $line =~ /\s+\!.*$/ ) {
			( $line, my $comment ) = split( /\s+\!/, $line );
			push @{$lines}, 'C ' . $comment;
			push
			  @{ $stref->{'Sources'}{$f}{'Nodes'}{'TrailingComments'}{'Pos'} },
			  $index;
			$index++;

			#       $line=~s/\s+\!.*$//;
		}
		if ( $line =~ /^\s+[\+\&]/ ) {    # continuation line
			$line =~ s/^\s+[\+\&]\s*/ /;
			$prevline .= $line;
		}
		else {
			push @{$lines}, lc($prevline);
			$stref->{'Sources'}{$f}{'Info'}->[$index] = { 'Nil'=>[]};
			$index++;
			$prevline = $line;
		}
	}
	if ($line ne $prevline) {
		push @{$lines}, lc($prevline);
	}		
	push @{$lines}, lc($line);	
	$index++;
	
	close $SRC;

	$stref->{'Sources'}{$f}{'Lines'}     = $lines;
	$stref->{'Sources'}{$f}{'HasBlocks'} = $has_blocks;
	}
	return $stref;
}

sub get_info_per_line {
	if ($V) {
	print "\n\n";
	print "#" x 80, "\n";
	print "Collecting information by line\n";
	print "#" x 80, "\n\n";
	}
	 
	( my $stref ) = @_;

	for my $f ( keys %{ $stref->{'Sources'} } ) {
		print "SOURCE: $f\n" if $V;
		if (exists $stref->{'Sources'}{$f}{'Info'}) {
		my $aref =  $stref->{'Sources'}{$f}{'Info'} || [];
		my @info = @{ $aref } ;
		for my $node ( keys %{ $stref->{'Sources'}{$f}{'Nodes'} } ) {
#			next if $node eq 'Globals';
			print "\tNODE: $node\n" if $V;
			if ( exists $stref->{'Sources'}{$f}{'Nodes'}{$node}{'Pos'} ) {
				my @indices =
				  @{ $stref->{'Sources'}{$f}{'Nodes'}{$node}{'Pos'} };
				for my $index (@indices) {
#					$info[$index]={};
					$info[$index]->{$node} = $stref->{'Sources'}{$f}{'Nodes'}{$node} ;
				}
			}
			else {
				for
				  my $key ( keys %{ $stref->{'Sources'}{$f}{'Nodes'}{$node} } )
				{
					print "\t\tNAME: $key\n" if $V;
					my @indices =
					  @{ $stref->{'Sources'}{$f}{'Nodes'}{$node}{$key}{'Pos'} };
					my @attrs=();  
					my $i=0;
					for my $index (@indices) {
						my $tref={};
	                    for my $kkey (keys %{ $stref->{'Sources'}{$f}{'Nodes'}{$node}{$key} } ){
	                        
	                        # We assume that all these entries are lists with a one-on-one match to Pos
	                        $tref->{$kkey}=$stref->{'Sources'}{$f}{'Nodes'}{$node}{$key}{$kkey}[$i];
	                    }
#						$info[$index]={};
						$info[$index]->{$node}= {$key => $tref};
						$i++;						  
					}
				}
			}
		}
		$stref->{'Sources'}{$f}{'Info'} = \@info;
		} else {
			print "No info for $f\n";
			$stref->{'Sources'}{$f}{'Info'} = [];
		}
#		if ($V) {
#			for my $i ( 0 .. @info - 1 ) {
#				print $i, "\t";
#				if ( defined $info[$i] ) {
#					for my $item ( @{ $info[$i] } ) {
#						print $item->[0], "\t";
#					}
#
#				}
#				else {
#					print "Nil";
#				}
#				print "\n";
#			}
#		}
	}

	return $stref;
}

#sub Info{ (my $f,my $stref) =@_;
#	return $stref->{'Sources'}{$f}{'Info'} ;
#}
#
#sub inBlock { (my $info, my $idx)=@_;
#	for my $item (@{ $info->[$idx] }) {
#			if ($item->[0] eq 'InBlock') {
#				return 1;
#			}
#	}
#	return 0;
#}

sub insert_lines {
	( my $lref, my $srcref, my $idx ) = @_;    # \@lines, \@src_lines, $idx;
	my $nsrc = [ @{$srcref} ];
	splice( @{$nsrc}, $idx, 0, @{$lref} );
	return $nsrc;
}

=info2
We also need a convenience function to split long lines.
- count the number of characters, i.e. length()
- find the last comma before we exceed 64 characters (I guess it's really 72-5?):
=cut

sub split_long_line {
	my $line     = shift;
	my @chunks   = @_;
	my $nchars   = 64;
	my $split_on = ',';
	my $ll       = length($line);
	my $rline    = join( '', reverse( split( '', $line ) ) );
	my $idx      = index( $rline, $split_on, $ll - $nchars );
	push @chunks, substr( $line, 0, $ll - $idx, '' );

	if ( length($line) > $nchars ) {
		&split_long_line( $line, @chunks );
	}
	else {
		push @chunks, $line;
		my @split_lines = ();
		my $fst         = 1;
		for my $chunk (@chunks) {
			if ($fst) {
				$fst = 0;
			}
			else {
				$chunk = '    &   ' . $chunk;
			}
			push @split_lines, $chunk;
		}
		return @split_lines;
	}
}

