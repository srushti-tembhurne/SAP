package ariba::Ops::TextIndexer;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/TextIndexer.pm#15 $

use strict;
use vars qw($VERSION);
use locale;

use BerkeleyDB;
use File::Path;

$VERSION = '0.7.4';

# optimize. these are subroutine calls.
my $DB_SET      = BerkeleyDB::DB_SET;
my $DB_NEXT     = BerkeleyDB::DB_NEXT;
my $DB_NOTFOUND = BerkeleyDB::DB_NOTFOUND;
my $DB_NEXT_DUP = BerkeleyDB::DB_NEXT_DUP;

my $rangeToken  = '__currentRangeId__';
my $totalToken  = '__totalDocuments__';
my $WORDDB	= 'wordIds';

my %stopwordList     = ();

my $BLOCK	= 16 * 1024;

=pod

=head1 NAME

ariba::Ops::TextIndexer

=head1 SYNOPSIS

=head1 DESCRIPTION

You should create a subclass of this object and implement convertFileToText()

=head1 METHODS

=over 4

=item * new()

=cut

sub setVerbose {
	my $self = shift;
	my $val = shift;

	$self->{'_verbose_'} = $val;
}

sub verbose {
	my $self = shift;
	return $self->{'_verbose_'};
}

sub new {
	my $class = shift;

	bless my $self = {}, $class;

	$self->_faultInStopwordList();

	#
	# if we have a terminal, default to providing feedback
	#
	if(-t STDOUT) {
		$self->setVerbose(1);
	}

	return $self;
}

=pod

=item * (text) = convertFileToText(file)

This method expects some type of object, normally a file path, as input. 
It returns raw text data as a scalar.   

Return undef if the object does not exist.

The default implementation expects a file path and is to just returns
the raw contents with no format conversions.

=cut

sub convertFileToText {
	my ($self,$document) = @_;

	open FH, $document or do {
		print "Can't open document [$document]: $!\n";
		return undef;
	};

	local $/ = undef;
	my $text = <FH>;
	close FH;

	return $text;
}

=pod

=item * parseText(text)

turn the incoming text scalar into a hash of term => term frequency mappings.

Removes non-indexable characters. Does *not* strip html, 
convertFileToText in subclasses does this (see ariba::Ops::MailIndexer, ariba::Ops::OpsWebsiteIndexer).

=cut

sub parseText {
	my ($self,$text) = @_;

	return $text unless $text;

	# lowercase all the terms
	$text =~ tr/A-Z/a-z/;

	# to pass back
	my %terms = ();

	# don't call this everytime in the loop. optimize.
	my $stemming = $self->stemming();

	my $delimiter = $self->delimiter();

	# Pack it again, and remove dashes from the begining and end of words.
	my @terms = split /$delimiter/, $text;

	for my $term (@terms) {

		# strip off trailing commas, etc.
		$term =~ s/\W+$//;

		# skip everything that's not a word, digit, ., _, or -
		next if $term =~ /[^\/\w\d\@\.:_-]+/go;
		next if $term =~ /[\@\$_\.-]{2,}/go;
		#next if $term =~ /^\W/o;

		# don't index just numbers
		# next if $term =~ /^[\d:]+$/o;
		
		# cleanup proper name grammar.
		$term =~ s/'\w*$//o;

		# stoplist processing
		next if exists $stopwordList{$term};

		# stem if asked
		$term = (@{Lingua::Stem::stem($term)})[0] if $stemming;

		# we have nothing!
		next if $term =~ /^\s*$/o;
		
		$terms{$term}++;
	}
	
	# If the page doesn't contain enough content.
        # return undef if scalar @parsed_terms < 5;

	return \%terms;
}

=pod

=item * delimiter(), setDelimiter(dir)

This sets/retrieves the delimiter between words in the document
being indexed.  The default is '\s+', but you might want to
parse on other characters.  This value is in perl regex, and is
passed to the split() function.

=cut

sub delimiter {
	my $self = shift;

	return $self->{'delimiter'} || '\s+';
}

sub setDelimiter {
	my $self = shift;
	my $delimiter = shift;

	$self->{'delimiter'} = $delimiter;
}

=pod

=item * primaryDir(), setPrimaryDir(dir), buildDir(), setBuildDir(dir)

Set both primaryDir and buildDir when indexing. buildDir should be a unique
directory, as primaryDir gets linked to it.

Only set primaryDir when searching.

=cut

sub primaryDir {
	my $self = shift;

	return $self->{'primaryDir'} || '';
}

sub setPrimaryDir {
	my ($self,$dir) = @_;

	$self->{'primaryDir'} = $dir;
}

sub buildDir {
	my $self = shift;

	return $self->{'buildDir'} || '';
}

sub setBuildDir {
	my ($self,$dir) = @_;

	$self->{'buildDir'} = $dir;
}

=pod

=item * docIdSplit(), setDocIdSplit(split)

This variable controls how many documents reside in a given postlist.

=cut

sub docIdSplit {
	my $self = shift;

	return $self->{'docIdSplit'} || 1000;
}

sub setDocIdSplit {
	my ($self,$split) = @_;

	$self->{'docIdSplit'} = $split;
}

=pod

=item * stemming(), setStemming()

Use the Porter stemming algorithm?
Requires Lingua::Stem classes.

=cut

sub stemming {
	my $self = shift;
	return $self->{'stemming'} || 0;
}

sub setStemming {
	my ($self,$stemming) = @_;

	if ($stemming) {

		eval {
			require Lingua::Stem;
			Lingua::Stem::stem_caching({ -level => 2 });
		};

		if ($@) {

			print "Lingua::Stem not installed. Stemming is not on!\n";
			$self->{'stemming'} = 0;

		} else {

			$self->{'stemming'} = 1;
		}
	}
}

=pod

=item * debug(), setDebug(0|1)

Set the instance debug level.  0 is off.

=cut

sub debug {
	my $self = shift;
	return $self->{'debug'} || 0;
}

sub setDebug {
	my $self = shift;
	my $debug = shift;

	$self->{'debug'} = $debug;
}

=pod

=item * setReadWrite()

Sets the open permissions to Read/Write

=cut

sub setReadWrite {
	my $self = shift;
	$self->{'OPEN_FLAGS'} = DB_CREATE;
}

=pod

=item * setReadOnly()

Sets the open permissions to Read Only

=cut

sub setReadOnly {
	my $self = shift;
	$self->{'OPEN_FLAGS'} = DB_RDONLY;
}

=pod

=item dbOpenFlags()

returns the current flags used to tie berkleyDBs

=cut

sub dbOpenFlags {
	my $self = shift;
	return( $self->{'OPEN_FLAGS'} || DB_RDONLY );
}

=pod

=item * handle(dbName)

Return a raw BerkeleyDB handle. buildDir() or primaryDir() must be set first!

=cut

sub handle {
	my ($self,$dbName) = @_;

	# File::Basename is heavy. this is cheap
	my @tmpSplit = (split(/\//, $dbName));
	$dbName = pop @tmpSplit;

	return $self->{'DB_CACHE'}->{$dbName} if defined $self->{'DB_CACHE'}->{$dbName};

	# select the build dir if it's set, ie: we are indexing
	my $dir = $self->buildDir() ? $self->buildDir() : $self->primaryDir();

	if (!$self->buildDir() and !$self->primaryDir()) {
		die "Neither buildDir nor primaryDir are set! Can't continue.\n";
	}

	print "opening BerkeleyDB [$dir/$dbName]\n" if $self->debug();

	my $flags = $self->dbOpenFlags();
	$flags = DB_CREATE unless( -e "$dir/$dbName" );

	$self->{'DB_CACHE'}->{$dbName} = BerkeleyDB::Btree->new(
		-Flags          => $flags,
		-Filename       => "$dir/$dbName",
	) or do {
		print "BerkeleyDB::Btree: [$BerkeleyDB::Error]\n";
		print "When trying to open: [$dir/$dbName]: $!\n";
	};

	return $self->{'DB_CACHE'}->{$dbName};
}

=pod

=item * currentRangeId(), setCurrentRangeId()

Get or set the currentRangeId from the database.

=cut

sub currentRangeId {
	my $self = shift;
	my $currentRangeId = 0;

	return $self->{$rangeToken} if defined $self->{$rangeToken};

	my $dbHandle = $self->handle($WORDDB);
	   $dbHandle->db_get($rangeToken, $currentRangeId);

	return $self->{$rangeToken} = $currentRangeId;
}

sub setCurrentRangeId {
	my ($self,$currentRangeId) = @_;

	my $dbHandle = $self->handle($WORDDB);
	   $dbHandle->db_put($rangeToken, $currentRangeId);
	   $dbHandle->db_sync();

	return $self->{$rangeToken} = $currentRangeId;
}

=pod

=item * lastRunTime()

Return last time index was updated in unix-time format.

=cut

sub lastRunTime {
	my $self = shift;

	my $primaryDir = $self->primaryDir();
	my $currentRangeId = $self->currentRangeId();

	my $postlist = "$primaryDir/postlist.$currentRangeId";

	return (stat($postlist))[9];
}

=pod

=item * setIncrementalIndexMode()

Set the indexer to create incremental changes to the index.  See also lastRunTime(), call that first.
Returns lastRunTime() as a convenience.

=cut

sub setIncrementalIndexMode() {
	my $self = shift;

	my $primaryDir = $self->primaryDir();
	$self->setBuildDir($primaryDir);

	my $currentRangeId = $self->currentRangeId();

	my $lastRunTime = $self->lastRunTime();
	
	$currentRangeId++;
	$self->setCurrentRangeId($currentRangeId);

	return $lastRunTime;
}

=pod

=item * setFullIndexMode()

Set the indexer to create a new index.  The is the default mode.

=cut

sub setFullIndexMode() {
	my $self = shift;
	
	# do nothing.
}


=pod

=item * totalDocuments(), setTotalDocuments()

Get or set the totalDocument count from the database.

=cut

sub totalDocuments {
	my $self = shift;
	my $totalDocuments = 0;

	return $self->{$totalToken} if defined $self->{$totalToken};

	my $dbHandle = $self->handle($WORDDB);
	   $dbHandle->db_get($totalToken, $totalDocuments);

	return $self->{$totalToken} = $totalDocuments;
}

sub setTotalDocuments {
	my ($self,$totalDocuments) = @_;

	my $dbHandle = $self->handle($WORDDB);
	$dbHandle->db_put($totalToken, $totalDocuments);
	$dbHandle->db_sync();

	return $self->{$totalToken} = $totalDocuments;
}

# compress the bdb "holes"
sub packBDB {
	my ($self,$db) = @_;

	print "repacking [$db]\n" if $self->debug;

	my $origHandle = $self->handle($db);
	my $newHandle  = $self->handle("$db.new");
	my $cursor     = $origHandle->db_cursor();

	my ($k,$v) = ('','');

	while ($cursor->c_get($k, $v, $DB_NEXT) == 0) {
		$newHandle->db_put($k,$v);
	}

	$cursor->c_close();
	$origHandle->db_close();
	$newHandle->db_close();

	# select the build dir if it's set, ie: we are indexing
	my $dir = $self->buildDir() ? $self->buildDir() : $self->primaryDir();

	rename("$dir/$db.new", "$dir/$db") or warn "Can't rename [$dir/$db.new] to [$dir/$db]: $!";
}

=pod

=item * incrementalCleanup()

Implement if you need a generic cleanup method.

=cut

sub incrementalCleanup {
	my $self = shift;

	return 1;
}

=pod

=item * incrementalCleanupInterval()

How often does incrementalCleanup() get called during the main index loop

=cut

sub incrementalCleanupInterval {
	my $self = shift;

	return $self->{'cleanupInterval'} || 0;
}

=pod

=item * setIncrementalCleanupInterval()

Set the incrementalCleanup() interval

=cut

sub setIncrementalCleanupInterval {
	my $self     = shift;
	my $interval = shift || 0;
	
	$self->{'cleanupInterval'} = $interval;
}

# cover for this exists because search program needs
# it, not just us

sub docIdHandle {
	my $self = shift;

	return $self->handle('docIds');
}

# stoplist handling. this was a separate module - inlined now.
sub _faultInStopwordList {
	my $self = shift;

	for (map split(' ', $_), <DATA>) {
		  $stopwordList{$_} = 1;
	}
}

sub _isStopword {
	my ($self,$word) = @_;

	#
	# AN is also a stop word
	#
	$word = lc($word);

	if (exists $stopwordList{$word}) {
		return 1;
	} else {
		return 0;
	}
}

# this was in ::PostList - now inline
sub _readPostListOffset {
	my ($self,$postlist, $offset,$length) = @_;

	my $debug = $self->debug();

	print "offset: [$offset] length: $length\n" if $debug;

	open(PL, $postlist) or die "Can't open postlist: [$postlist]: $!";
	sysseek(PL, $offset, 0);
	sysread(PL, my $packedDocIDs, $length);
	close(PL);

	my @unpacked = unpack("w*", $packedDocIDs);

	my (@docIds, @termFreq) = ();

	# these must remain ordered.
	my $lastDocId = 0;

	while (@unpacked) {

		my ($docId, $termFreq) = splice(@unpacked,0,2);
		print "documentId: [$docId] termFreq: [$termFreq]\n" if $debug;

		push @docIds, ($docId + $lastDocId);
		push @termFreq, $termFreq;

		$lastDocId += $docId;
	}

	return (\@docIds,\@termFreq);
}

sub _writePostList {
	my ($self,$postList,$dfList) = @_;

	my $currentRangeId = $self->currentRangeId();
	my $docIdSplit	   = $self->docIdSplit();

	my $dir		   = $self->buildDir();
	my $postListFile   = "$dir/postlist.$currentRangeId";

	# grab a write cursor
	my $dbHandle	   = $self->handle($WORDDB);
	my $cursor	   = $dbHandle->db_cursor();

	my $postListOffset = 0;
	my $indexId	   = 0;
	my $bufferLength   = 0;
	my $bufferString   = '';

	my $indexIdHandle  = $self->handle("$postListFile.btree.I");
	my $allocHandle    = $self->handle("$postListFile.btree.A");

	#
	print "writing out postlist [$postListFile]\n" if $self->debug();
	open PL, ">$postListFile" or die "Can't write [$postListFile]: $!";

	while (my ($word, $data) = each %{$postList}) {

		my $postListLength = length($data);
		   $bufferString  .= $data;
		   $bufferLength  += $postListLength;

		# this isn't exact - we might go over, but we'll be doing fewer syswrites()
		if ($bufferLength >= $BLOCK) {

			my $wrote = syswrite(PL, (substr $bufferString, 0, $BLOCK, ''));

			if ($wrote != $BLOCK) {
				print "wrote and packed lengths don't match!\n";
				print "bufferLength: [$BLOCK] wrote: [$wrote]\n";
				exit;
			}

			$bufferLength = 0;
		}

		# document frequency for this word.
		my $df = $dfList->{$word} || 1;

		# store the word -> df:offset match.
		if ($cursor->c_put("$word,$currentRangeId", "$df:$indexId", DB_KEYLAST) == 0) {

			# manage the postlist
			$indexIdHandle->db_put($indexId, $postListOffset);
			$allocHandle->db_put($postListOffset, $postListLength);

			# increment the offset
			# this *must* be after the db insert above.
			$postListOffset += $postListLength;

			#
			$indexId++;

			delete $postList->{$word};

		} else {
			print  "cursor->c_put for word: [$word] failed.\n";
			printf "status of cursor is: [%s]\n", $cursor->status();
			print  "closing cursor and exiting!\n";
			$cursor->c_close();
			exit;
		}
	}

	# and flush any remaining bits.
	if ($bufferLength > 0) {
		my $wrote = syswrite(PL, $bufferString);
		print "wrote out $wrote bytes.\n" if $self->debug() > 2;
	}
	
	close PL;
	$cursor->c_close();
	$dbHandle->db_sync();
}

=pod

=item * index(documentArrayRef)

Does the indexing work. Expects an array of references to whatever convertFileToText()
expects, normally file names.

=cut

sub index {
	my ($self,$documents) = @_;

	if (!-d $self->buildDir()) {
		mkpath([$self->buildDir()], 0, 0755);
	}

	my $docIdHandle    = $self->docIdHandle();
	my $currentRangeId = $self->currentRangeId();
	my $docIdSplit	   = $self->docIdSplit();
	my $totalDocuments = $self->totalDocuments();

	my %postList  = ();
	my %dfList    = ();
	my %lastDocId = ();
	my $docId     = $totalDocuments + 1;
	my $max	      = scalar(@$documents);
	my $start     = time();

	my $interval  = $self->incrementalCleanupInterval();

	if ( $self->debug() ) {
		print "currentRangeId: [$currentRangeId]\n";
		print "totalDocuments: [$totalDocuments]\n";
		print "starting docId: [$docId]\n";
	}

	# hack
	if ($totalDocuments < ($docIdSplit * $currentRangeId)) {
		$docId = ($docIdSplit * $currentRangeId);
	}

	for my $document (@$documents) {
		print "$docId of $max, ", time - $start, " secs\r"
			if($self->verbose() && (($docId % 25) == 0));

		my $text    = $self->convertFileToText($document) || next;
		my $words   = $self->parseText($text);

		my $maxtf   = 0;

		#
		my $rangeId = int($docId/$docIdSplit);

		# sort needed on docIds if out of order.
		if ($rangeId != $currentRangeId) {

			$self->_writePostList(\%postList, \%dfList);

			$currentRangeId = $self->setCurrentRangeId($rangeId);

			$self->incrementalCleanup();

			# clear these after we flush.
			%postList  = ();
			%dfList	   = ();
			%lastDocId = ();
		}

		# generate the postlist for each document.
		while (my ($word, $termFreq) = each %{$words}) {

			# don't care about words outside this range.
			my $wordLength = length($word);
			next if $wordLength < 2;
			next if $wordLength > 32;

			$lastDocId{$word} = 0 unless defined $lastDocId{$word};

			$postList{$word} .= pack('w2', $docId - $lastDocId{$word}, $termFreq);

			$lastDocId{$word} = $docId;

			# compute the maximum term frequency for this document.
			$maxtf = $termFreq if $termFreq > $maxtf;

			# keep track of document frequency per word
			$dfList{$word}++;
		}

		# let perl reuse this
		%$words = ();

		#
		$docIdHandle->db_put($docId, join($;, ($maxtf,$document)));

		# time for cleanup?
		if ($interval and $docId % $interval) {
			$self->incrementalCleanup();
		}

		#if ($docId != 0 and ($docId % 1000) == 0) {
		#	print "Indexed $docId documents     \n";
		#}

		$docId++;
	}

	# this cleans up if the rangeId hasn't been hit.
	$self->_writePostList(\%postList,\%dfList);

	# cleanup
	%postList = ();
	%dfList	  = ();

	$self->setTotalDocuments($docId);

	$self->setCurrentRangeId($currentRangeId);
	#$self->packBDB($WORDDB);

	$self->incrementalCleanup();

	printf("Indexed a total of %d documents in %d secs\n", 
		scalar(@$documents),
		(time() - $start)
	) if ($self->verbose());

	if ($self->primaryDir() ne $self->buildDir()) {

		if (-l $self->primaryDir()) {
			print "Moving away old directory, and new into place.\n" if $self->debug();
			unlink $self->primaryDir() or warn $!;
		}

		symlink $self->buildDir(), $self->primaryDir() or warn $!;
	}
}

sub merge {
	my ($self) = @_;

	# grab a write cursor
	my $dbHandle	   = $self->handle($WORDDB);
	my $cursor	   = $dbHandle->db_cursor();

	# process the available rangeIds in pairs
	my $currentRangeId = $self->currentRangeId();

	my @rangeIds = ();

	opendir(PRIMARY, $self->primaryDir()) or die "Can't open [".$self->primaryDir()."]: $!\n";
	while (my $file = readdir(PRIMARY)) {

		next unless $file =~ /^postlist\.(\d+)$/;
		push @rangeIds, $1;
	}
	closedir(PRIMARY);

	@rangeIds = sort { $a cmp $b } @rangeIds;

	# loop over the pairs and merge
	for (my $i = 0; $i <= scalar $#rangeIds; $i += 2) {

		my ($range1,$range2) = ($rangeIds[$i], $rangeIds[$i+1]);
	
		my $range1index   = $self->handle("postlist.$range1.btree.I");
		my $range1alloc   = $self->handle("postlist.$range1.btree.A");
		my $range1unalloc = $self->handle("postlist.$range1.btree.U");

		my $range2index   = $self->handle("postlist.$range2.btree.I");
		my $range2alloc   = $self->handle("postlist.$range2.btree.A");
		my $range2unalloc = $self->handle("postlist.$range2.btree.U");

		# walk the new range and get the words prepped.
		my ($k,$v) = ('','');

		while ($cursor->c_get($k, $v, $DB_NEXT) == 0) {
			next unless $k =~ /^(\S+),$range2$/;

			$dbHandle->db_get("$1,$range1", my $range1Id);

			if (defined $range1Id) {

			}
		}
	}

        $cursor->c_close();
}

=item * search(termList)

search for a set of words (normally space seperated) and return the
references to those documents, in whatever namespace index() and convertFileToText()
used at index creation (normally file names).

=cut

sub search {
	my $self    = shift;

	my %scores  = ();
	my @results = ();

	# did we get an array of terms, or a whitespace separated scalar?
	my @terms = @_ > 1 ? @_ : split(/\s+/, $_[0]);

	# get the result set for each term
	for my $term (@terms) {
		push @results, $self->_realSearch($term, \%scores);
	}

	my $required = ();
      
	if (scalar @terms > 1) {
		$required = ariba::Ops::Utils::computeIntersection(\@results);
	} else {
		$required = $results[0];
	}

	# return the real documents
	my @documents = ();

	# sort these according to their score
	for my $docId (sort { $scores{$b}->{'score'} <=> $scores{$a}->{'score'} } @$required) { 

		push @documents, $scores{$docId}->{'name'};
	}

	return \@documents;
}

sub _realSearch {
	my $self    = shift;
	my $term    = lc(shift);
	my $scores  = shift;

	my $debug   = $self->debug();

	my $words   = $self->parseText($term);
	my $word    = (keys %$words)[0];
	#my $word    = $term;

	my @docIds  = ();
	my $count   = 1;
	my $dir     = $self->primaryDir();

	my $documentFrequency = 0;

	my $value    = 0;
	my %results  = ();
	my @results  = ();

	my $docIdHandle = $self->docIdHandle();
	my $dbHandle    = $self->handle($WORDDB);
	my $cursor      = $dbHandle->db_cursor();

	print "word: [$word] - value: [$value]\n" if $debug;

	# retrieve only matching word,\d+ entries.
	if ($cursor->c_get( $word, $value, DB_SET_RANGE ) != $DB_NOTFOUND) {

		my ($newWord,$rangeId) = ($word =~ /^($term,)(\d+)$/);

		# short circuit
		unless (defined $newWord) {
			print "word not found!\n" if $debug;
			return \@results;
		}

		$results{$rangeId} = $value;

		print "\tword: [$word] - value: [$value]\n" if $debug;

		while ($cursor->c_get( $word, $value, $DB_NEXT) != $DB_NOTFOUND) {
			last if $word !~ /^$newWord/;

			($rangeId) = ($word =~ /^(\S+,)(\d+)/)[1];
			$results{$rangeId} = $value if defined $value;
			print "\t\tword: [$word] - value: [$value]\n" if $debug;
		}

	} else {

		print "word not found!\n" if $debug;
		return \@results;
	}

	$cursor->c_close();

	# calculate the documentFrequency
	for my $rangeId (sort keys %results) {

		# document frequency for this term
		my ($df,$offset) = split /:/, $results{$rangeId};

		next if !defined $df or $df !~ /^\d+$/;

		$documentFrequency += $df;
	}

	# idf = inverse document frequency
	my $IDF = log($self->totalDocuments() / $documentFrequency);

	#
	return if $IDF == 0;

	# now pull out the documentIds
	for my $rangeId (sort keys %results) {

		# document frequency for this term
		my ($df,$indexId) = split /:/, $results{$rangeId};

		next if !defined $indexId or $indexId =~ /^\s*$/;

		my $postlist	  = "$dir/postlist.$rangeId";
		my $indexIdHandle = $self->handle("$postlist.btree.I");
		my $allocHandle   = $self->handle("$postlist.btree.A");

		#
		$indexIdHandle->db_get($indexId, my $postListOffset);
		$allocHandle->db_get($postListOffset, my $postListLength);

		print "\nrangeId: [$rangeId] postListOffset: [$postListOffset] documentFrequency: [$documentFrequency]\n" if $debug;

		my ($docIDs,$termFreq) = $self->_readPostListOffset(
			$postlist, $postListOffset, $postListLength
		);

		for (my $i = 0; $i <= scalar $#$docIDs; $i++) {

			my $docId = $docIDs->[$i];

			$docIdHandle->db_get($docId, my $documentData);

			my ($maxtf,$document) = split(/$;/, $documentData);

			# calculate the tf*idf score -- IDF is non-zero for sure since
			# we return if it's zero above.
			if($maxtf) {
				$scores->{$docId}->{'score'} += $termFreq->[$i] / $maxtf * $IDF;
			# } else {
				# XXX not 100% sure what should happen here -- for now I think
				# "nothing" is corrects - if this doc has no maxtf, then I
				# don't think it should get scored.  Checking for zero prevents
				# an occasional odd crash in TM searches.
			}
			$scores->{$docId}->{'name'}   = $document;

			push @results, $docId;
		}
	}

	for (my $i = 0; $i <= scalar $#results; $i++) {

		my $result = $results[$i];

		printf("documentId: %6d Rank: %4d Score %.2f\n", 
			$result, $i, $scores->{$result}->{'score'}
		) if $debug;
	}

	return \@results;
}

1;

__DATA__
a about above according across after afterwards again against albeit
all almost alone along already also although always am among amongst
an and another any anybody anyhow anyone anything anyway anywhere apart
are around as at av be became because become becomes becoming been before
beforehand behind being below beside besides between beyond both but by
can cannot canst certain cf choose contrariwise cos could cu day do does
doesn doing dost doth double down dual during each either else elsewhere
enough et etc even ever every everybody everyone everything everywhere
except excepted excepting exception exclude excluding exclusive far farther
farthest few ff first for formerly forth forward from front further furthermore
furthest get go had halves hardly has hast hath have he hence henceforth her
here hereabouts hereafter hereby herein hereto hereupon hers herself him himself
hindmost his hither hitherto how however howsoever i ie if in inasmuch inc include
included including indeed indoors inside insomuch instead into inward inwards is
it its itself just kind kg km last latter latterly less lest let like little
ltd many may maybe me meantime meanwhile might moreover most mostly more
mr mrs ms much must my myself namely need neither never nevertheless next
no nobody none nonetheless noone nope nor not nothing notwithstanding now
nowadays nowhere of off often ok on once one only onto or other others otherwise
ought our ours ourselves out outside over own per perhaps plenty provide quite
rather really reuter reuters round said sake same sang save saw see seeing seem
seemed seeming seems seen seldom selves sent several shalt she should shown
sideways since slept slew slung slunk smote so some somebody somehow someone
something sometime sometimes somewhat somewhere spake spat spoke spoken sprang
sprung stave staves still such supposing than that the thee their them themselves
then thence thenceforth there thereabout thereabouts thereafter thereby
therefore therein thereof thereon thereto thereupon these they this those
thou though thrice through throughout thru thus thy thyself till to together
too toward towards ugh unable under underneath unless unlike until up upon
upward upwards us use used using very via vs want was we week well were what
whatever whatsoever when whence whenever whensoever where whereabouts whereafter
whereas whereat whereby wherefore wherefrom wherein whereinto whereof whereon
wheresoever whereto whereunto whereupon wherever wherewith whether whew which
whichever whichsoever while whilst whither who whoa whoever whole whom whomever
whomsoever whose whosoever why will wilt with within without worse worst would
wow ye yet year yippee you your yours yourself yourselves 

__END__

=pod

=head1 AUTHOR

Dan Sully <dsully@ariba.com>

=head1 SEE ALSO

BerkeleyDB
