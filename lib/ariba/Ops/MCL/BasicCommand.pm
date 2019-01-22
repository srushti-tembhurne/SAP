#!/usr/local/bin/perl

package ariba::Ops::MCL::BasicCommand;

use strict;
use base qw(ariba::Ops::PersistantObject);

sub dir {
    return('/var/mcl');
}

sub validAccessorMethods {
	my $class = shift;

	my $ref = $class->SUPER::validAccessorMethods();
	my @accessors = qw( actionNumber args commandLine commandNumber commandPrefix errorStrings ignoreExitCode mcl output perlCheck status step successStrings successIfStrings timeout type postString );

	foreach my $accessor (@accessors) {
		$ref->{$accessor} = 1;
	}

	return($ref);
}

sub objectLoadMap {
	my $class = shift;
	my $map = $class->SUPER::objectLoadMap();

	$map->{'errorStrings'} = '@SCALAR';
	$map->{'successStrings'} = '@SCALAR';
	$map->{'successIfStrings'} = '@SCALAR';
	$map->{'postString'} = '@SCALAR';

	return($map);
}

sub _computeBackingStoreForInstanceName {
    my $class = shift;
    my $instance = shift;

    my ($mclname, $stepname, $action, $command) = split(/\-\-/, $instance);
    my $store = "/var/mcl/$mclname/commands/${stepname}-${action}-$command";
    return($store);
}

sub duplicate {
	my $self = shift;
	my $src = shift;
	my $vars = shift;
	my $iterator = shift;

	foreach my $attr(qw(args timeout commandLine ignoreExitCode perlCheck)) {
		my $str = $src->attribute($attr);
		next unless($str);
		foreach my $var (keys %$vars) {
			my $val = $$vars{$var};
			$str =~ s/\$\{$var\}/$val/g;
		}
		while($str =~ /Iterate\(\s*([^\)]+)\s*\)/) {
			my $list = $1;
			$list =~ s/^'//;
			$list =~ s/'$//;
			my $repl = ariba::Ops::MCL::BaseAction::iterate($list, $iterator);
			$str =~ s/Iterate\(\s*([^\)]+)\s*\)/$repl/;
		}
		$self->setAttribute($attr, $str);
	}

	foreach my $attr(qw(errorStrings successStrings successIfStrings postString)) {
		my @foo = $src->attribute($attr);
		next unless(scalar(@foo));
		foreach my $str (@foo) {
			foreach my $var (keys %$vars) {
				my $val = $$vars{$var};
				$str =~ s/\$\{$var\}/$val/g;
			}
			while($str =~ /Iterate\(\s*([^\)]+)\s*\)/) {
				my $list = $1;
				$list =~ s/^'//;
				$list =~ s/'$//;
				my $repl = ariba::Ops::MCL::BaseAction::iterate($list, $iterator);
				$str =~ s/Iterate\(\s*([^\)]+)\s*\)/$repl/;
			}
		}
		$self->setAttribute($attr, @foo);
	}
}

sub newFromParser {
	my $class = shift;
	my $mcl = shift;
	my $step = shift;
	my $actionNumber = shift;
	my $commandNumber = shift;
	my $commandLine = shift;

	my $instance = $mcl . "--" . $step . "--" . $actionNumber . "--" . $commandNumber;

	my $self = $class->SUPER::new($instance);

	$self->setMcl($mcl);
	$self->setStep($step);
	$self->setActionNumber($actionNumber);
	$self->setCommandNumber($commandNumber);
	$self->setCommandLine($commandLine);

	return($self);
}

1;
