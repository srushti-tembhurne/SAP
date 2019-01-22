#!/usr/local/bin/perl

package ariba::monitor::CSS::Config;

use base qw( ariba::Ops::PersistantObject );

sub dir { return "/dev/null"; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub newFromConfig {
	my $class = shift;
	my $instance = shift;

	my $self = $class->SUPER::new($instance);
	$self->setConfigFile($instance);

	unless($self->readConfigFile($instance)) {
		return(undef);
	}

	return($self);
}

sub ignore {
	my $self = shift;
	my $string = shift;

	$self->appendToIgnoreList($string);
	my $regex = "(?:" . join('|', $self->ignoreList() ) . ")";
	$self->setIgnoreRegex( $regex );
}

sub configAsString {
	my $self = shift;
	my $node = shift || $self->top();
	my $output = "";
	if( $node->line() && (!$self->ignoreRegex() || $node->line() !~ $self->ignoreRegex()) ) {
		$output = $node->line() . "\n"
	}
	foreach my $n (sort { $a->line() cmp $b->line() } $node->data()) {
		$output .= $self->configAsString($n);
	}
	return($output);
}

sub printConfig {
	my $self = shift;
	print $self->configAsString();
}

sub readConfigFile {
	my $self = shift;
	my $file = shift;
	my $ct = 1;


	open(F, "< $file") || do { 
		print "ERROR: Cannot open $file\n";
		return undef;
	};

	my $indent = -1;
	my @stack;
	my $top;

	while(my $line = <F>) {
		chomp $line;
		next if($line =~ /^\s*$/);
		$line =~ s/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.)\d{1,3}\b/$1XXX/g;
		if($line =~ /^\!\*+ (\w+)/) {
			# new top level node
			$top = ariba::monitor::CSS::ConfigBlock->new() unless($top);
			my $node = ariba::monitor::CSS::ConfigBlock->new($line);
			$node->setLineNumber($ct);
			$top->appendToData($node);
			@stack = ( $node );
			$indent = -1;
		} elsif ($line =~ /^(\s*)[^\s].*/) {
			next unless($top);
			my $tab = length($1);
			if($tab > $indent) {
				# deeper node, do nothing
			} elsif($tab < $indent) {
				$foo = $indent - $tab;
				while($foo) {
					shift(@stack);
					$foo-=2;
				}
				shift(@stack); # one more for same indent,
			} else {
				shift(@stack); # same indent,
			}
			$parent = shift(@stack);
			my $node = ariba::monitor::CSS::ConfigBlock->new($line);
			$node->setLineNumber($ct);
			$parent->appendToData($node);
			unshift(@stack, $parent);
			unshift(@stack, $node);
			$indent = $tab;
		}
		$ct++;
	}
	close(F);

	$self->setTop($top);

	return(1);
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'ignoreList' => '@SCALAR',
	);

	return(\%map);
}

package ariba::monitor::CSS::ConfigBlock;

use base qw( ariba::Ops::PersistantObject );

my $instanceCount=1;

sub dir { return '/dev/null'; }
sub save { return undef; }
sub recursiveSave { return undef; }
sub remove { return undef; }

sub new {
	my $class = shift;
	my $line = shift;
	my $instance = "configBlock-$instanceCount";
	$instanceCount++;

	my $self = $class->SUPER::new($instance);
	$self->setLine($line);

	return($self);
}

sub objectLoadMap {
	my $class = shift;

	my %map = (
		'data' => '@ariba::monitor::CSS::ConfigBlock',
	);

	return(\%map);
}

1;
