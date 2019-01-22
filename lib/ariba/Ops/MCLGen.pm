package ariba::Ops::MCLGen;

require Exporter;

@ISA = qw(Exporter);

@EXPORT = qw( setBaseDependancy defineStep defineExpando defineRunGroup defineVariable defineAction setStepName stepName incrementStepName nextStepBlock setSubstepInit setDepends depends );

my $allDepends;
my $section;
my $substep;
my $dependency;
my $substepInit = 0;

sub setSubstepInit {
    $substepInit = shift;
}

sub depends {
    return $dependency;
}

sub setDepends {
    $dependency = shift;
}

sub nextStepBlock {
	$section++;
	$substep = $substepInit;
}

sub setStepName {
	$section = shift;
	$substep = shift;
}

sub stepName {
	my $ret = $section . "." . $substep;
	return($ret);
}

sub incrementStepName {
	my $ret = $section . "." . $substep;
	$substep++;

	return($ret);
}

sub setBaseDependancy {
	my $ad = shift;
	$allDepends = $ad;
}

sub defineStep {
	my $name = shift;
	my $title = shift;
	my $depends = shift;
	my $expando = shift;
	my $runGroup = shift;
	my $options = shift || "";
	my $retries = shift;
	my $retryInterval = shift;
	my $other = shift;

	if($allDepends) {
		if($name ne $allDepends && $options !~ /expando/) {
			if($depends) {
				$depends = "$allDepends $depends";
			} else {
				$depends = $allDepends;
			}
		}
	}

	my $ret = "Step $name\n";
	$ret .=   "Title: $title\n";
	$ret .=   "Depends: $depends\n" if($depends);
	$ret .=   "RunGroup: $runGroup\n" if($runGroup);
	$ret .=   "Expando: $expando\n" if($expando);
	$ret .=   "Options: $options\n" if($options);
	$ret .=   "Retries: $retries\n" if($retries);
	$ret .=   "RetryInterval: $retryInterval\n" if($retryInterval);
	$ret .=   "$other\n" if($other);

	return($ret);
}

sub defineExpando {
	my $name = shift;
	my $title = shift;

	my $ret = "Step $name\n";
	$ret .=   "Title: $title\n";
	$ret .=   "Options: expando\n\n";

	return($ret);
}

sub defineRunGroup {
	my $name = shift;
	my $maxParallel = shift;
	my $locked = shift;

	my $ret = "Group: $name {\n";
	$ret .=   "\tMaxParallelProcesses: $maxParallel\n";
	$ret .=   "\tLocked\n" if($locked);
	$ret .=   "}\n\n";

	return($ret);
}

sub defineVariable {
	my $name = shift;
	my $default = shift;

	if(defined($default)) {
		return("Variable: $name=$default\n");
	} else {
		return("Variable: $name\n");
	}
}

sub defineAction {
	my $type = shift;
	my $arg = shift || "";
	my @commands = (@_);

	$arg .= " " if($arg);

	my $ret = "Action: $type $arg {\n";
	foreach my $cmd (@commands) {
		$ret .= "\t$cmd\n";
	}
	$ret .=   "}\n";

	return($ret);
}

1;
