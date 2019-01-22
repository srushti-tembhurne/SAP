package ariba::Ops::BusyPageOnHttpVendor;

#               
#   Wished state \ Current state |  Unplanned | Planned | rolling | undef
#   -----------------------------|------------|---------|---------|------    
#         Unplanned              |     OK     |  FORCE  |    OK   |  OK
#   -----------------------------|------------|---------|---------|------                             
#         Planned                |     OK     |   OK    |    OK   |  OK
#   -----------------------------|------------|---------|---------|------                             
#         Rolling                |     OK     |  FORCE  |    OK   |  OK
#   -----------------------------|------------|---------|---------|------                             
#
#




# $Id: //ariba/services/tools/lib/perl/ariba/Ops/BusyPageOnHttpVendor.pm#14 $

use strict;
use ariba::rc::InstalledProduct;
use ariba::rc::Globals;
use ariba::rc::Utils;
use ariba::util::Simplefind;
use File::Basename;
use File::Copy;
use Encode;
use DateTime;

use base qw(ariba::Ops::AbstractBusyPage);

#Constants
my $BUSYPAGEPATH = '/var/tmp/busy-page';


# Initialize a list of files to replace and/or their templates
sub _initializeFilesList {
	my $self = shift;

	my $sf = ariba::util::Simplefind->new($$self{srcPath});
	my @files = $sf->find();

	my @finalFiles;
	foreach my $file (@files) {
		$file =~ s/$$self{srcPath}\///;
		push (@finalFiles, $file);
	}

	return @finalFiles; 

}




# Initialize the tokens usend to customize a file
sub _initializeTokens {
	my $self = shift;

	my $tokenMap = shift;
	my $duration = shift;
	my $beginning = shift;
	my $locale = shift;

	my @abbrMon = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
	my @abbrDay = qw( Sun Mon Tue Wed Thu Fri Sat);


	if ($duration) {
		my $totalDurationInMin = $duration;

		my $minutes = $totalDurationInMin % 60;
		my $hours = ($totalDurationInMin - $minutes) / 60;

		map {$_ = '0' . $_ if (length($_) == 1)} ($hours, $minutes);

		$$tokenMap{DURATION} = $duration;
		$$tokenMap{DURATION_HOURS} = $hours;
		$$tokenMap{DURATION_MINUTES} = $minutes;

	
	} else {
	
		print "Warn : No estimated duration time defined. No token available.\n";
	}


	if ($beginning) {
		my ($lsec,$lmin,$lhour,$lmday,$lmon,$lyear,$lwday,$lyday,$lisdst) = localtime($beginning);

		my $fmt = DateTime::Locale->load($locale)->full_date_format();


		my $dt_local = DateTime->new( year => $lyear + 1900,
											month => $lmon + 1,
											day => $lmday,
											hour => $lhour,
											minute => $lmin,
											second => $lsec,
											locale => $locale);

		my $date_local = $dt_local->strftime($fmt);

		map {$_ = '0' . $_ if (length($_) == 1)} ($lsec, $lmin, $lhour, $lmday, $lmon);

		$$tokenMap{BEGINNING_LOCAL_SEC} = $lsec;
		$$tokenMap{BEGINNING_LOCAL_MIN} = $lmin;
		$$tokenMap{BEGINNING_LOCAL_HOUR} = $lhour;
		$$tokenMap{BEGINNING_LOCAL_DAY} = $lmday;
		$$tokenMap{BEGINNING_LOCAL_DAY_NAME} = $dt_local->day_name;
		$$tokenMap{BEGINNING_LOCAL_DAY_ABBR} = $dt_local->day_abbr;
		$$tokenMap{BEGINNING_LOCAL_MONTH} = $dt_local->month;
		$$tokenMap{BEGINNING_LOCAL_MONTH_NAME} = $dt_local->month_name;
		$$tokenMap{BEGINNING_LOCAL_MONTH_ABBR} = $dt_local->month_abbr;
		$$tokenMap{BEGINNING_LOCAL_YEAR} = $dt_local->year;
		$$tokenMap{BEGINNING_LOCAL_DATE} = $date_local;


		$$tokenMap{BEGINNING_LOCAL_WDAY} = $abbrDay[$lwday];
		$$tokenMap{BEGINNING_LOCAL_ABR_MONTH} = $abbrMon[$lmon];




		my ($gsec,$gmin,$ghour,$gmday,$gmon,$gyear,$gwday,$gyday,$gisdst) = gmtime($beginning);

		my $dt_utc = DateTime->new(   year => $gyear + 1900,
											month => $gmon + 1,
											day => $gmday,
											hour => $ghour,
											minute => $gmin,
											second => $gsec,
											locale => $locale);

		my $date_utc = $dt_utc->strftime($fmt);


		map {$_ = '0' . $_ if (length($_) == 1)} ($gsec, $gmin, $ghour, $gmday, $gmon);

		$$tokenMap{BEGINNING_GMT_SEC} = $gsec;
		$$tokenMap{BEGINNING_GMT_MIN} = $gmin;
		$$tokenMap{BEGINNING_GMT_HOUR} = $ghour;
		$$tokenMap{BEGINNING_GMT_DAY} = $gmday;
		$$tokenMap{BEGINNING_GMT_DAY_NAME} = $dt_utc->day_name;
		$$tokenMap{BEGINNING_GMT_DAY_ABBR} = $dt_utc->day_abbr;
		$$tokenMap{BEGINNING_GMT_MONTH} = $dt_utc->month;
		$$tokenMap{BEGINNING_GMT_MONTH_NAME} = $dt_utc->month_name;
		$$tokenMap{BEGINNING_GMT_MONTH_ABBR} = $dt_utc->month_abbr;
		$$tokenMap{BEGINNING_GMT_YEAR} = $dt_utc->year;
		$$tokenMap{BEGINNING_GMT_DATE} = $date_local;


		$$tokenMap{BEGINNING_GMT_WDAY} = $abbrDay[$gwday];
		$$tokenMap{BEGINNING_GMT_ABR_MONTH} = $abbrMon[$gmon];
	} else {

		print "Impossible to tell when the scheduled downtime has begun.\n";
	}


	if (($beginning) && ($duration)) {

		my $durationInSeconds = $duration * 60;
		my $endTime = $beginning + $durationInSeconds;

		my $fmt = DateTime::Locale->load($locale)->full_date_format();




		my ($lsec,$lmin,$lhour,$lmday,$lmon,$lyear,$lwday,$lyday,$lisdst) = localtime($endTime);


		my $dt_local = DateTime->new( year => $lyear + 1900,
												month => $lmon + 1,
												day => $lmday,
												hour => $lhour,
												minute => $lmin,
												second => $lsec,
												locale => $locale);

		my $date_local = $dt_local->strftime($fmt);



		map {$_ = '0' . $_ if (length($_) == 1)} ($lsec, $lmin, $lhour, $lmday, $lmon);

		$$tokenMap{END_LOCAL_SEC} = $dt_local->second;
		$$tokenMap{END_LOCAL_MIN} = $dt_local->minute;
		$$tokenMap{END_LOCAL_HOUR} = $dt_local->hour;
		$$tokenMap{END_LOCAL_DAY} = $dt_local->day;
		$$tokenMap{END_LOCAL_DAY_NAME} = $dt_local->day_name;
		$$tokenMap{END_LOCAL_DAY_ABBR} = $dt_local->day_abbr;
		$$tokenMap{END_LOCAL_MONTH} = $dt_local->month;
		$$tokenMap{END_LOCAL_MONTH_NAME} = $dt_local->month_name;
		$$tokenMap{END_LOCAL_MONTH_ABBR} = $dt_local->month_abbr;
		$$tokenMap{END_LOCAL_YEAR} = $dt_local->year;
		$$tokenMap{END_LOCAL_DATE} = $date_local;


		$$tokenMap{END_LOCAL_WDAY} = $abbrDay[$lwday];
		$$tokenMap{END_LOCAL_ABR_MONTH} = $abbrMon[$lmon];




		my ($gsec,$gmin,$ghour,$gmday,$gmon,$gyear,$gwday,$gyday,$gisdst) = gmtime($endTime);

		my $dt_utc = DateTime->new(   year => $gyear + 1900,
											month => $gmon + 1,
											day => $gmday,
											hour => $ghour,
											minute => $gmin,
											second => $gsec,
											locale => $locale);

		my $date_utc = $dt_utc->strftime($fmt);



		map {$_ = '0' . $_ if (length($_) == 1)} ($gsec, $gmin, $ghour, $gmday, $gmon);

		$$tokenMap{END_GMT_SEC} = $gsec;
		$$tokenMap{END_GMT_MIN} = $gmin;
		$$tokenMap{END_GMT_HOUR} = $ghour;
		$$tokenMap{END_GMT_DAY} = $gmday;
		$$tokenMap{END_GMT_MONTH} = $gmon + 1;
		$$tokenMap{END_GMT_ABR_MONTH} = $abbrMon[$gmon];
		$$tokenMap{END_GMT_WDAY} = $abbrDay[$gwday];

		$$tokenMap{END_GMT_DAY_NAME} = $dt_utc->day_name;
		$$tokenMap{END_GMT_DAY_ABBR} = $dt_utc->day_abbr;
		$$tokenMap{END_GMT_MONTH_NAME} = $dt_utc->month_name;
		$$tokenMap{END_GMT_MONTH_ABBR} = $dt_utc->month_abbr;
		$$tokenMap{END_GMT_YEAR} = $dt_utc->year;
		$$tokenMap{END_GMT_DATE} = $date_local;


		$$tokenMap{END_GMT_WDAY} = $abbrDay[$gwday];
		$$tokenMap{END_GMT_ABR_MONTH} = $abbrMon[$gmon];

	} else {
		print "Impossible to predict when the scheduled downtime will end.\n";
	}

}

sub _mkDestination {
	my $self = shift;

	my $dir = shift ;
	my $file = shift;

	my $dirMiddle = dirname($file) . '/';

	$dir .= "/$dirMiddle" if ($dirMiddle ne './');
	# We check if the destination directory exists
	unless (-d $dir) {
		my $success = mkdirRecursively($dir);

		unless ($success) {
			print "Warning : Unable to create the directory $dir\nSkipping...\n";
			return 0;
		}
	}

	return 1;

}	



sub _replaceTokens {
	my $self = shift;

	my $file = shift; 		 # The name of the file to tokenize
	my $tokenMap = shift;	 # A map : Token -> Value, where the value will replace the token
	my $encoding = shift;	 # Encoding used by this file


	print "Tokens available : [", join(', ', %$tokenMap), "]\n" if ($$self{debug});


	my $srcFile = "$$self{srcPath}/$file";

	my $dstDir  =  $self->busyPagePath();
	my $dstFile = $file;

	return unless ($self->_mkDestination($dstDir, $file));

	print "Replacing tokens : Sourcefile [$srcFile] ; Dstfile [$dstFile]\n" if ($$self{debug});

	open my $FILEIN,  "<:encoding($encoding)", $srcFile  or die;
	my @lines = <$FILEIN>;
	close($FILEIN); 


	open my $FILEOUT,  ">:encoding($encoding)", "$dstDir/$dstFile"  or die;

	foreach my $line (@lines ) {

		foreach my $key (keys(%$tokenMap)) {
			$line =~ s/\*$key\*/$$tokenMap{$key}/g;
		}

		print $FILEOUT $line;
	}   

	close($FILEOUT); 

	return $dstDir;
}


# This clean the $BUSYPAGEPATH. This removes everything inside and can also remove the directory at the end.
sub _cleanBusyPath {
	my $self = shift;

	my $cleanCompletely = shift || 0; # By default we want to suppress everything inside $BUSYPAGEPATH but keep the directory 


	# busyPagePath() is where processed files for planned downtime are.
	if (-d  $self->busyPagePath()) {
		print "Removing " .  $self->busyPagePath() . "\n";
		unless (ariba::rc::Utils::rmdirRecursively( $self->busyPagePath())) {
			print "Cannot remove " . $self->busyPagePath() . "\n";
		}

	}

	# This re-create base directory for processed files for planned downtime
	unless ($cleanCompletely) {
		print "Creating " .  $self->busyPagePath() . "\n";
		ariba::rc::Utils::mkdirRecursively( $self->busyPagePath());
	}

}


sub _createSymLink {
	my $self           = shift;
	my $duringDownTime = shift;

	my $me        = $$self{me};
	my $meRootDir = $$self{meRoot};
	
	my $src = $$self{busySrc} . "/unplanned";
	if ( $duringDownTime ) {
		$src =  $self->busyPagePath();
	}

	if (-l $meRootDir) {
		print "Deleting symbolic link $meRootDir\n";
		unlink "$meRootDir";
	}

	my $directoryDst = (fileparse($meRootDir))[1];
	print "Checking if [$directoryDst] exists\n";
	unless (-e $directoryDst) {

		print "Creating directory [$directoryDst]\n";
		my $success = mkdirRecursively($directoryDst);

		unless ($success) {
			print "Warning : Unable to create the directory $directoryDst\nSkipping...\n";
			return 0;
		}

	}

	print "Creating symbolic link from $src to $meRootDir\n";
	symlink $src, $meRootDir;
	
}

sub _isTemplate {
	my $self = shift;

	my $filename = shift;

	my @templates = ('\.xml\.?', '\.html\.?', '\.cgi\.?');

	foreach my $template (@templates) {
		return 1 if ($filename =~ m/$template/);
	}
	
	return 0;
}

sub _localeForFilename {
	my $self = shift;
	my $filename = shift;
	
	my $locale = $filename;
	$locale =~ m/\.html\.(.*)/;

	$locale = $1;

	return "en_us" unless ($locale);
	return $locale;

}

sub _encodingForFilename {

	my $self = shift;
	my $filename = shift;


	my $encoding = 'iso-8859-1';

	return $encoding unless($filename =~ m/html/i);

	open (FILEIN, $filename);

	while (defined (my $line = <FILEIN>)) {
			$line =~ m/charset=(.*)\"/;
			if ($1) {
				$encoding = $1;
				last;
			}
	}

	close(FILEIN); 

	return $encoding;
}



sub newFromProduct {
	my $class = shift;
	my $product = shift;

	my $me = ariba::rc::InstalledProduct->new();
	my $self = $class->SUPER::new();


	$$self{me} = $me;
	$$self{product} = $product;
	$$self{service} = $me->service();

	my $meRoot = ariba::rc::Globals::rootDir($me->name(), $me->service()) ;

	if ( $me->name() eq 'ws') {

		$$self{meRoot} = "$meRoot/busy";

		$$self{busySrc} = $me->docRoot();
		$$self{srcPath} = $$self{busySrc} . "/template";

	} elsif ($me->name() eq 'ssws') {

		$$self{meRoot} = "$meRoot/busy/$product";

		$$self{busySrc} = $me->docRoot() . "/busy/$product";
		$$self{srcPath} = $$self{busySrc} . "/template";

	}


	unless (-l $$self{meRoot} ) {
		$self->setUnplanned();
	}


	bless($self, $class);
	return $self;

}

sub setUnplanned {
	my $self   = shift;
	my $force  = shift;


	my $currentState = $self->guessState();
	if ($currentState eq $ariba::Ops::AbstractBusyPage::statePlanned && !$force) {
		return 0;
	}


	unless ($$self{testing}) {
		$self->_cleanBusyPath (1);
		$self->_createSymLink (0);
	}

	return 1;
}

sub setRolling {
	my $self  = shift;
	my $force = shift;


	my $currentState = $self->guessState();
	if ($currentState eq $ariba::Ops::AbstractBusyPage::statePlanned && !$force) {
		return 0;
	}

	my $busyPath = $$self{meRoot};
	my $rollingPath = $$self{busySrc} . "/rolling";
	
	unless ($$self{testing}) {
		print "Deleting symbolic link $busyPath\n";
		unlink ($busyPath);

		print "Creating symbolic link from $rollingPath to $busyPath\n";
		symlink($rollingPath, $busyPath);
	}


	$self->_cleanBusyPath (1);

	return 1;
}

sub setPlanned {
	my $self = shift;

	my $duration  = shift || undef;
	my $beginning = shift || undef;
	my $force     = shift;


	my $currentState = $self->guessState();
	if ($currentState eq $ariba::Ops::AbstractBusyPage::statePlanned && !$force) {
		return 0;
	}

	my @files;

	
	@files = $self->_initializeFilesList ();


	# We have to check if $BUSYPAGEPATH exists on every webservers :
	#  - If it exists we have to clean it
	#  - If it doesn't exist we have to create it

	$self->_cleanBusyPath ();

	
	foreach my $file (@files) {
		print "file : [$file]\n" if ($$self{debug});

		next unless ($self->_mkDestination( $self->busyPagePath(), $file));
	
		if ( -r "$$self{srcPath}/$file" ) {

			if ( $self->_isTemplate("$$self{srcPath}/$file") ) {


				my %tokenMap;

				
				my $locale = $self->_localeForFilename ("$$self{srcPath}/$file");
				my $encoding = $self->_encodingForFilename ("$$self{srcPath}/$file");




				$self->_initializeTokens ( \%tokenMap, $duration, $beginning, $locale );

				$self->_replaceTokens ( $file, \%tokenMap, $encoding ) unless ($$self{testing});


			} else {
				
				print "Copying [$$self{srcPath}/$file] to [",  $self->busyPagePath() , "/$file]\n";
				copy( "$$self{srcPath}/$file", $self->busyPagePath() . "/$file") unless ($$self{testing});

			}

		} else {

			print "Warning : file $file doesn't exist. Skip it.\n\n";
			next;

		}

	}

	$self->_createSymLink (1);

	return 1;
}

sub guessState {
	my $self = shift;

	my $symlink = readlink($$self{meRoot});
	return undef unless($symlink);

	my $state = basename($symlink);
	

	my $finalState = undef;

	if ($state eq $ariba::Ops::AbstractBusyPage::stateUnplanned) {
		$finalState = $ariba::Ops::AbstractBusyPage::stateUnplanned;

	} elsif ($state eq $ariba::Ops::AbstractBusyPage::stateRolling) {
		$finalState = $ariba::Ops::AbstractBusyPage::stateRolling;

	} elsif ( $state eq basename($self->busyPagePath())) {
		$finalState = $ariba::Ops::AbstractBusyPage::statePlanned;
	}
	
	return $finalState;
}


sub setLinkState {
	my $self = shift;
	my $targetState = shift;
	

	if ($targetState eq $ariba::Ops::AbstractBusyPage::stateUnplanned) {
		return $self->setUnplanned(1);

	} elsif ($targetState eq $ariba::Ops::AbstractBusyPage::stateRolling) {
		return $self->setRolling(1);

	} elsif ( $targetState eq $ariba::Ops::AbstractBusyPage::statePlanned ) {

		# We don't want to call setPlanned() because we don't want to parse any template. 
		# They already exist.
		# We just want to re-create the symlink to the already parsed templates.
		#
		# The parameter '1' means this happens during a downtime
		return $self->_createSymLink (1);
	}

	return undef;
}

sub busyPagePath {
	my $self = shift;

	my $me = $$self{me};
	my $service = $$self{service};

	my $productName = $$self{product};
	$productName = 'ws' if ($me->name() eq 'ws');

	my $path = "$BUSYPAGEPATH-$service/" . $productName;


	return $path;
}


1;
