#!/usr/local/bin/perl -w

#
# $Id: //ariba/services/tools/lib/perl/ariba/util/Term.pm#17 $
# $Author: bob.mcgowan $
#
# ariba::util::Term;
#
# provides functions for full screen programs.  This is patterned after
# Curses.pm, but includes less functionality and doesn't require Curses.pm
# to be installed.  It uses Term::ReadKey which is already part of the ariba
# perl install.
#
# Includes:
#
# * code to draw and update full screen text, double buffered to minimize
#   flickering during refreshes.
# * code to read and interpret keystrokes.
# * a routine for user keymap configuration.
# * code to grok the termcap for a user's termtype if availible.  It defaults
#   to vt100 if it cannot read termcap since that works in most cases
# * ANSI color suppot
# * A set of constants for special keys and attribute codes to make calling
#   code look prettier
#

use Term::ReadKey;
use Term::Cap;
use POSIX;

package ariba::util::Term;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw (	KEY_LEFT KEY_RIGHT KEY_ENTER KEY_BACKSPACE KEY_UP KEY_DOWN
				KEY_F KEY_HOME KEY_END KEY_DELETE KEY_EOL KEY_INSERT
				KEY_DL KEY_CTRL KEY_ALT KEY_ESCAPE KEY_PAGEUP KEY_PAGEDOWN
				KEY_SHIFT_TAB
				MODE_RESTORE MODE_NORMAL MODE_NOECHO MODE_CBREAK MODE_RAW
				MODE_ULTRARAW
				A_REVERSE A_NORMAL A_BOLD A_UNDERLINE A_COLOR
				COLOR_RED COLOR_BLACK COLOR_GREEN COLOR_BLUE COLOR_MAGENTA
				COLOR_YELLOW COLOR_CYAN COLOR_WHITE
				COLOR_BOLD_RED COLOR_BOLD_BLACK COLOR_BOLD_GREEN
				COLOR_BOLD_BLUE COLOR_BOLD_MAGENTA COLOR_BOLD_YELLOW
				COLOR_BOLD_CYAN COLOR_BOLD_WHITE COLOR_DEFAULT
				attrset addstr addstrEscapeCtrl printable clear refresh
				endwin initscr box move getmaxx getmaxy erase
				getch getchraw pushInput baseAttr setmode displayKeyDebug
				setupUserTerm getText loadFH pageFH pageFile drawScrollBar);

use strict;

my $_debug = 0;
my $pageFileMode;
my @keysPressed;

#
# ZZZ -- these should be object variables, which will later allow for creation
# of additional window objects... but I want to check in and do that devel
# without potentially breaking users of the ocr-tool, since it's a fairly
# involved overhaul.
#
my $termMaxX;
my $termMaxY;
my $termCursX = 0;
my $termCursY = 0;
my $termAttribute = 0;
my $baseTermAttribute = 0;
my %termInfo;
my $oldScreen;
my $newScreenChar;
my $newScreenAttrX;
my $newScreenAttrY;
my $termWinOk = 0;
my $termClear = 0;
my @termInput = ();
my %termKeys;
my %termUserKeys;

my @userKeys = qw ( KEY_LEFT KEY_RIGHT KEY_UP KEY_DOWN KEY_BACKSPACE KEY_ENTER
					KEY_HOME KEY_END KEY_INSERT KEY_DELETE KEY_EOL KEY_SHIFT_TAB
					KEY_DL KEY_PAGEUP KEY_PAGEDOWN KEY_F1 KEY_F2 KEY_F3 KEY_F4
					KEY_F5 KEY_F6 KEY_F7 KEY_F8 KEY_F9 KEY_F10 KEY_F11 KEY_F12
					KEY_CTRL_UP KEY_CTRL_DOWN KEY_CTRL_LEFT KEY_CTRL_RIGHT
					KEY_ALT_UP KEY_ALT_DOWN KEY_ALT_LEFT KEY_ALT_RIGHT
			      );
push(@userKeys, "Exit Term Setup");


sub KEY_LEFT { "KEY_LEFT"; }
sub KEY_RIGHT { "KEY_RIGHT"; }
sub KEY_UP { "KEY_UP"; }
sub KEY_DOWN { "KEY_DOWN"; }
sub KEY_BACKSPACE { "KEY_BACKSPACE"; }
sub KEY_ENTER { "KEY_ENTER"; }
sub KEY_HOME { "KEY_HOME"; }
sub KEY_END { "KEY_END"; }
sub KEY_EOL { "KEY_EOL"; }
sub KEY_DELETE { "KEY_DELETE"; }
sub KEY_DL { "KEY_DL"; }
sub KEY_ESCAPE { "KEY_ESCAPE"; }
sub KEY_PAGEUP { "KEY_PAGEUP"; }
sub KEY_PAGEDOWN { "KEY_PAGEDOWN"; }
sub KEY_INSERT { "KEY_INSERT"; }
sub KEY_SHIFT_TAB { "KEY_SHIFT_TAB"; }
sub PAGER_MODE_UNIFIED { 0; }
sub PAGER_MODE_ORIGINAL { 1; }
sub PAGER_MODE_REVISED { 2; }
sub PAGER_MODE_SIDEBYSIDE { 3; }

sub KEY_F {
	my $num = shift;
	return "KEY_F$num";
}

sub KEY_CTRL {
	my $char = shift;
	return "KEY_CTRL_$char";
}

sub KEY_ALT {
	my $char = shift;
	$char = "BACKSPACE" if ($char eq "\210");
	$char = "SPACE" if ($char eq " ");
	return "KEY_ALT_$char";
}

sub A_REVERSE { "A_REVERSE"; };
sub A_BOLD { "A_BOLD"; };
sub A_UNDERLINE { "A_UNDERLINE"; };
sub A_NORMAL { "A_NORMAL"; };

sub A_COLOR {
	my $fg = shift;
	my $bg = shift;

	return "A_COLOR_${fg}_$bg";
}

sub MODE_RESTORE { 0; }
sub MODE_NORMAL { 1; }
sub MODE_NOECHO { 2; }
sub MODE_CBREAK { 3; }
sub MODE_RAW { 4; }
sub MODE_ULTRARAW { 5; }

sub COLOR_BLACK { return 0; }
sub COLOR_RED { return 1; }
sub COLOR_GREEN { return 2; }
sub COLOR_YELLOW { return 3; }
sub COLOR_BLUE { return 4; }
sub COLOR_MAGENTA { return 5; }
sub COLOR_CYAN { return 6; }
sub COLOR_WHITE { return 7; }
sub COLOR_BOLD_BLACK { return 8; }
sub COLOR_DEFAULT { return 8; } # same as BOLD_BLACK since this is background
sub COLOR_BOLD_RED { return 9; }
sub COLOR_BOLD_GREEN { return 10; }
sub COLOR_BOLD_YELLOW { return 11; }
sub COLOR_BOLD_BLUE { return 12; }
sub COLOR_BOLD_MAGENTA { return 13; }
sub COLOR_BOLD_CYAN { return 14; }
sub COLOR_BOLD_WHITE { return 15; }

sub setDebug {
	my $class = shift;
	my $value = shift;

	$_debug = $value;
}

sub keyHistory {
	return(@keysPressed);
}

#
# This is a bit of a kludge -- I wish Term::Info were installed everywhere.
# Instead, I use infocmp -C to build a termcap file, save it, and then
# point TERMCAP environment variable at it.  This makes Term::Cap (Tgetent)
# read the file that was generated by decompiling the terminfo file.
#
sub getTermInfoFile {
	my $termCapFile = _termUserCapFile();
	unless( -r $termCapFile ) {
		my ($INFO, $F);

		open($INFO, "infocmp -C |") || return;
		my @info = <$INFO>;
		close($INFO);

		open($F, "> $termCapFile") || return;
		print $F join("",@info);
		close($F);
	}
	$ENV{'TERMCAP'} = $termCapFile;
}

sub myTgetent {
	my ( $entry, $loop, $field, $key, $value);

	%termInfo=();

	getTermInfoFile();
	my $t = Tgetent Term::Cap { TERM => undef };

	foreach $field (keys %$t) {
		next unless($field =~ s/^_//);

		$termInfo{$field} = $t->{"_$field"} || 1;
	}

	$termInfo{'pc'} = "\0" if $termInfo{'pc'} eq '';
	$termInfo{'bc'} = "\b" if $termInfo{'bc'} eq '';

	#
	# Default some common vt codes since they will work in most cases
	# if we don't get valid term info codes
	#
	$termInfo{'cl'} = "\e[H\e[J" unless $termInfo{'cl'};

	$termInfo{'mr'} = "\e[7m" unless $termInfo{'mr'};
	$termInfo{'us'} = "\e[4m" unless $termInfo{'us'};
	$termInfo{'md'} = "\e[1m" unless $termInfo{'md'};
	$termInfo{'me'} = "\e[m" unless $termInfo{'me'};

	$termInfo{"ATTR0"} = $termInfo{'me'};
	$termInfo{"ATTR1"} = $termInfo{'mr'};
	$termInfo{"ATTR2"} = $termInfo{'md'};
	$termInfo{"ATTR3"} = $termInfo{'us'};
	setupColor();

	$termInfo{'cm'} = "\e[%i%d;%dH" unless $termInfo{'cm'};
	$termInfo{'ho'} = "\e[H" unless $termInfo{'ho'};

	for $key (keys %termInfo){ $termInfo{$key}=~s/^\d+//o; }
}

sub setupUserTerm {
	my $force = shift;
	my $ch;

	unless($force) {
		return if($termKeys{'KEY_UP'} || $termUserKeys{'KEY_UP'});
	}

	print "In order to set up your term you will be asked to press\n";
	print "several keys in sequense.  Please press each key once, when\n";
	print "prompted to configure the key mappings.\n";
	print "\n";
	print "Please press the up arrow:\n";
	$termUserKeys{'KEY_UP'} = getchraw();
	print "Please press the down arrow:\n";
	$termUserKeys{'KEY_DOWN'} = getchraw();
	print "Please press the enter key:\n";
	$termUserKeys{'KEY_ENTER'} = getchraw();

	clear();

	my $sel = 0;
	my $maxy = getmaxy();

	my $top = 0;
	my $bot = $maxy-5;


	while(1) {
		_drawSetupUserTerm($sel, $top, $bot);
		$ch = getch();
		if($ch eq KEY_UP) {
			if($sel > 0) {
				$sel--;
			}
			if($sel < $top) {
				$top--;
				$bot--;
			}
		} elsif($ch eq KEY_DOWN) {
			if($userKeys[$sel] ne "Exit Term Setup") {
				$sel++;
			}
			if($sel > $bot) {
				$bot++;
				$top++;
			}
		} elsif($ch eq KEY_ENTER) {
			if($userKeys[$sel] eq "Exit Term Setup") {
				clear();
				_saveTermFile();
				return();
			}
			my $y = $sel - $top + 2;
			addstr($y,2," " . $userKeys[$sel]);
			move($y,20);
			refresh();
			$termUserKeys{$userKeys[$sel]} = getchraw();
			if($termUserKeys{$userKeys[$sel]} eq "x") {
				$termUserKeys{$userKeys[$sel]} = undef;
			}
		}
	}
	
}

sub _saveTermFile {
	open(F, "> " . _termUserFile()) || return;
	foreach my $k (@userKeys) {
		next unless($termUserKeys{$k} && length($termUserKeys{$k}));
		print F $k,"\t",_escape($termUserKeys{$k}),"\n";
	}
	close(F);
}

sub _drawSetupUserTerm {
	my $sel = shift;
	my $top = shift;
	my $bot = shift;
	my $y = 2;

	erase();
	box();
	for(my $i = $top; $i <= $bot; $i++) {
		if($i == $sel) {
			attrset(A_REVERSE);
		}
		addstr($y,2,$userKeys[$i]);
		attrset(A_NORMAL);
		if($termUserKeys{$userKeys[$i]}) {
			addstrEscapeCtrl($y,20,$termUserKeys{$userKeys[$i]});
		}
		$y++;
	}
	move(0,0);
	refresh();
}

sub _termUserFile {
	return "$ENV{'HOME'}/.aribaTerm.TERM_$ENV{'TERM'}";
}

sub _termUserCapFile {
	return "$ENV{'HOME'}/.aribaTerm.TERMCAP_$ENV{'TERM'}";
}

sub mapTermKeys {
	if( -f _termUserFile() ) {
		open(FOO,"< " . _termUserFile());
		while(my $line = <FOO>) {
			chomp $line;
			my ($key, $value) = split('\t', $line);
			$termUserKeys{$key} = _unescape($value);
		}
	}

	$termKeys{'KEY_BACKSPACE'} = $termInfo{'kb'} || "\cH";
	$termKeys{'KEY_DELETE'} = $termInfo{'kD'} || "\c?";
	$termKeys{'KEY_UP'} = $termInfo{'ku'};
	$termKeys{'vtKEY_UP'} = "\c[[A";
	$termKeys{'KEY_DOWN'} = $termInfo{'kd'};
	$termKeys{'vtKEY_DOWN'} = "\c[[B";
	$termKeys{'KEY_LEFT'} = $termInfo{'kl'};
	$termKeys{'vtKEY_LEFT'} = "\c[[D";
	$termKeys{'KEY_RIGHT'} = $termInfo{'kr'};
	$termKeys{'vtKEY_RIGHT'} = "\c[[C";
	$termKeys{'KEY_F0'} = $termInfo{'k0'};
	$termKeys{'KEY_F1'} = $termInfo{'k1'};
	$termKeys{'KEY_F2'} = $termInfo{'k2'};
	$termKeys{'KEY_F3'} = $termInfo{'k3'};
	$termKeys{'KEY_F4'} = $termInfo{'k4'};
	$termKeys{'KEY_F5'} = $termInfo{'k5'};
	$termKeys{'KEY_F6'} = $termInfo{'k6'};
	$termKeys{'KEY_F7'} = $termInfo{'k7'};
	$termKeys{'KEY_F8'} = $termInfo{'k8'};
	$termKeys{'KEY_F9'} = $termInfo{'k9'};
	$termKeys{'KEY_F10'} = $termInfo{'k;'};
	$termKeys{'KEY_HOME'} = $termInfo{'kh'};
	$termKeys{'KEY_END'} = $termInfo{'kH'};
	$termKeys{'KEY_INSERT'} = $termInfo{'kI'};
	$termKeys{'KEY_EOL'} = $termInfo{'kE'};
	$termKeys{'KEY_DL'} = $termInfo{'kL'};
	$termKeys{'KEY_PAGEUP'} = $termInfo{'kP'};
	$termKeys{'KEY_PAGEDOWN'} = $termInfo{'kN'};
	$termKeys{'KEY_ENTER'} = "\cM";
	$termKeys{'altKEY_ENTER'} = "\cJ";
}

sub initscr {
	my $mode = shift || MODE_RAW;
	my ($jnk1, $jnk2);

	my $oldFH = select(STDOUT);
	$| = 1;
	select($oldFH);

	&myTgetent();

	mapTermKeys();

	( $termMaxX, $termMaxY, $jnk1, $jnk2 ) = Term::ReadKey::GetTerminalSize();
	Term::ReadKey::ReadMode($mode);

	$termWinOk = 1;

	eraseOld();
	clear();
}

sub setmode {
	my $mode = shift;
	Term::ReadKey::ReadMode($mode);
}

sub clear {
	die "Not in windowed mode!" unless ($termWinOk);
	erase();
	$termClear = 1;
}

sub erase {
	die "Not in windowed mode!" unless ($termWinOk);

	my $packed = pack("C", $baseTermAttribute);

	for(my $i = 0; $i < $termMaxY; $i++) {
		$newScreenChar->[$i] = " " x $termMaxX;
		$newScreenAttrX->[$i] = $packed x $termMaxX;
		$newScreenAttrY->[$i] = 0;
	}
}

sub eraseOld() {
	die "Not in windowed mode!" unless ($termWinOk);
	for(my $i = 0; $i < $termMaxY; $i++) {
		$oldScreen->[$i] = "";
	}
}

sub getmaxx {
	die "Not in windowed mode!" unless ($termWinOk);
	return $termMaxX;
}

sub getmaxy {
	die "Not in windowed mode!" unless ($termWinOk);
	return $termMaxY;
}

sub addstr {
	my $y = shift;
	my $x = shift;
	my $str = shift;
	my $len = length($str);
	my $attrChar = pack("C", $termAttribute);

	die "Not in windowed mode!" unless ($termWinOk);

	return if($y < 0 || $y >= $termMaxY);
	return if($x < 0 || $x >= $termMaxX);

	if($len > $termMaxX - $x) {
		$str = substr($str, 0, $termMaxX - $x);
		$len = $termMaxX - $x;
	}

	my $packed = pack("C", $termAttribute);

	substr($newScreenChar->[$y], $x, $len, $str);
	substr($newScreenAttrX->[$y], $x, $len, $packed x $len);
	if($termAttribute != $baseTermAttribute) {
		$newScreenAttrY->[$y] = 1;
	}
}

sub addstrEscapeCtrl {
	my $y = shift;
	my $x = shift;
	my $str = shift;
	my %escapes;

	while($str =~ /([^\040-\176])/) {
		my $ctrl = $1;

		my $i = index($str, $ctrl);
		my $repl = printable($ctrl);
		$str =~ s/$ctrl/$repl/;
		$escapes{$i} = $repl;
	}

	addstr($y,$x,$str);
	my $attrib = $termAttribute;
	attrset(A_REVERSE);
	foreach my $k (keys %escapes) {
		addstr($y,$x+$k,$escapes{$k});
	}
	attrset($attrib);

	return($str);
	
}

sub move {
	my $y = shift;
	my $x = shift;

	die "Not in windowed mode!" unless ($termWinOk);

	$termCursY = $y;
	$termCursX = $x;
}

sub box {
	my $vert = shift || '|';
	my $horz = shift || '-';
	my $ulcorner = shift || '+';
	my $urcorner = shift || '+';
	my $llcorner = shift || '+';
	my $lrcorner = shift || '+';

	die "Not in windowed mode!" unless ($termWinOk);

	$vert = substr($vert,0,1);
	$horz = substr($horz,0,1);
	my $len = $termMaxX - 2; # -1 for each corner, -1 for 0 base

	addstr(          0, 0, $ulcorner . $horz x $len . $urcorner);
	addstr($termMaxY-1, 0, $llcorner . $horz x $len . $lrcorner);

	for(my $i = 1; $i < $termMaxY-1; $i++) {
		addstr($i,0,$vert);
		addstr($i,$termMaxX-1,$vert);
	}
}

sub setupColor {
	my $fg;
	my $bg;
	my $bold;

	for($bg = 0; $bg < 9; $bg++) {
		for($bold = 0; $bold < 2; $bold++) {
			for($fg = 0; $fg < 8; $fg++) {
				my $color = ($bg*16) + ($bold*8) + $fg + 10;
				my $bgansi = $bg + 40;
				my $fgansi = $fg + 30;
				if($bg == 8) { # special case -- no background
					if($bold) {
						$termInfo{"ATTR$color"} = "\e[0;1;${fgansi}m";
					} else {
						$termInfo{"ATTR$color"} = "\e[0;${fgansi}m";
					}
				} else {
					if($bold) {
						$termInfo{"ATTR$color"} = "\e[1;$fgansi;${bgansi}m";
					} else {
						$termInfo{"ATTR$color"} = "\e[0;$fgansi;${bgansi}m";
					}
				}
			}
		}
	}
}

sub baseAttr {
	_attrset(\$baseTermAttribute, @_);
}

sub attrset {
	_attrset(\$termAttribute, @_);
}

sub _attrset {
	my $attrVar = shift;
	my $mode = shift;

	die "Not in windowed mode!" unless ($termWinOk);

	if($mode eq 'A_REVERSE') {
		$$attrVar = 1;
	} elsif ($mode eq 'A_BOLD') {
		$$attrVar = 2;
	} elsif ($mode eq 'A_UNDERLINE') {
		$$attrVar = 3;
	} elsif ($mode =~ /A_COLOR_(\d+)_(\d+)/) {
		my $fg = $1;
		my $bg = $2;

		if($fg < 0 || $fg > 15 || $bg < 0 || $bg > 8) {
			$$attrVar = 0;
			return;
		}

		$$attrVar = ($bg*16) + $fg + 10;

	} else {
		$$attrVar = 0;
	}

}

sub refresh {
	my $miny = shift || 0;
	my $maxy = shift || $termMaxY-1;
	die "Not in windowed mode!" unless ($termWinOk);

	print $termInfo{'ho'}, $termInfo{'cl'} if($termClear);
	$termClear = 0;
	my %print;

	#
	# look at the screen info and prepare the screen update.  Only update
	# parts of the screen that have changed since the last refresh
	#
	for(my $i = $miny ; $i <= $maxy; $i++) {
		my $new = outputStr($i);
		if($new ne $oldScreen->[$i]) {
			$print{$i} = $new;
			$oldScreen->[$i] = $new;
		}
	}

	#
	# do the actual screen update in a tight loop to minimize visible signs
	# of the update in progress.
	#
	foreach my $i (sort { $a <=> $b } keys(%print)) { 
		_move($i,0);
		print $print{$i};
	}

	_move($termCursY,$termCursX);
}

sub outputStr {
	my $y = shift;
	my $attr = 0;
	my $ret = "";
	my $offset = 0;
	my $size = 0;

	#
	# no attribute flags so this is easy -- in most cases keeping track of
	# this saves a LOT of computation.
	#
	unless( $newScreenAttrY->[$y] ) {
		if($baseTermAttribute) {
			return($termInfo{"ATTR$baseTermAttribute"} . $newScreenChar->[$y]);
		} else {
			return ($newScreenChar->[$y]);
		}
	}

	my $format = "C" x getmaxx();
	my @attr = unpack($format, $newScreenAttrX->[$y]);

	for(my $x = 0; $x < $termMaxX; $x++) {
		if($attr[$x] != $attr) {
			$attr = $attr[$x];
			$ret .= substr($newScreenChar->[$y],$offset,$size);
			$ret .= $termInfo{"ATTR0"}; # clear it before setting again
			$ret .= $termInfo{"ATTR$attr"};
			$offset += $size;
			$size = 0;
		}
		$size++;
	}

	#
	# get the last chunk of the screen
	#
	$ret .= substr($newScreenChar->[$y],$offset,$size);

	# reset normal at start of line
	$ret .= $termInfo{'me'} if($attr);

	return($ret);
}

sub _move {
	my $y = shift;
	my $x = shift;
	my $result = '';
	my $after = '';
	my $code = '';
	my @tmp = ( $y, $x );
	my $tmp;
	my $online = 0;

	my $string = $termInfo{'cm'};

	while($string =~ /^([^%]*)%(.)(.*)/o ) {
		$result .= $1;
		$code = $2;
		$string = $3;

		if($code eq "d") {
			$result .= sprintf("%d", shift(@tmp));
		} elsif ($code eq ".") {
			$tmp = shift(@tmp);
			if ($tmp == 0 || $tmp == 4 || $tmp == 10) {
				if ($online) {
					++$tmp, $after .= $termInfo{'up'} if $termInfo{'up'};
				} else {
					++$tmp, $after .= $termInfo{'bc'};
				}
			}
            $result .= sprintf("%c",$tmp);
            $online = !$online;
		} elsif ($code eq '+') {
			$result .= sprintf("%c",shift(@tmp)+ord($string));
			$string = substr($string,1,99);
			$online = !$online;
		} elsif ($code eq 'r') {
			($y, $x) = @tmp;
			@tmp = ($x, $y);
			$online = !$online;
		} elsif ($code eq '>') {
			($code,$tmp,$string) = unpack("CCa99",$string);
			if ($tmp[$[] > $code) {
				$tmp[$[] += $tmp;
			}
		} elsif ($code eq "2") {
			$result .= sprintf("%02d",shift(@tmp));
			$online = !$online;
		} elsif ($code eq "3") {
			$result .= sprintf("%03d",shift(@tmp));
			$online = !$online;
		} elsif ($code eq "i") {
			($code,$tmp) = @tmp;
			@tmp = ($code+1,$tmp+1);
		} else {
			return("OOPS");
		}
	}

	print $result . $string . $after;
}

sub getchraw {
	my $ch;
	my $z;
	my $i = 4;

	$ch = Term::ReadKey::ReadKey(0);
	select(undef,undef,undef,.2);
	while( defined ( $z = Term::ReadKey::ReadKey(-1) ) ) {
		$ch .= $z;
	}
	return($ch);
}

sub pushInput {
	my $arg = shift;
	push(@termInput,$arg);
}

sub matchKeyCodes {
	my $code = shift;

	#
	# check user setting FIRST
	#
	foreach my $key (sort { length($termUserKeys{$a}) <=> length($termUserKeys{$b}) } ( keys %termUserKeys )) {
		my $len = length($termUserKeys{$key});
		next unless($len);
		my $test = substr($code,0,$len);
		if($test eq $termUserKeys{$key}) {
			#
			# remove the key we read from the look-ahead buffer
			#
			splice(@termInput,0,$len-1);
			return($key);
		}
	}

	#
	# now look at the term info settings
	#
	foreach my $key (sort { length($termKeys{$a}) <=> length($termKeys{$b}) } ( keys %termKeys )) {
		my $len = length($termKeys{$key});
		next unless($len);
		my $test = substr($code,0,$len);
		if($test eq $termKeys{$key}) {
			#
			# remove the key we read from the look-ahead buffer
			#
			splice(@termInput,0,$len-1);
			$key =~ s/^[^K]+//;
			return($key);
		}
	}

	return undef;
}

sub getch {
	my $noblock = shift;
	my $ch = undef;
	my $z;

	die "Not in windowed mode!" unless ($termWinOk);

	while(!defined($ch)) {
		$ch = shift(@termInput) || Term::ReadKey::ReadKey(-1);
		return(undef) if(!defined($ch) && $noblock);
		select(undef,undef,undef,.01) unless($ch);
	}

	if($ch !~ /[\040-\176]/) {
		if($ch eq "\e") {
			#
			# read ahead to see if we match a special key
			#
			while( defined ( $z = Term::ReadKey::ReadKey(-1) ) ) {
				push(@termInput,$z);
			}
		}
		my $code = $ch . join('',@termInput);

		my $key = matchKeyCodes($code);
		if($key) {
			push(@keysPressed, $key) if($_debug);
			return($key);
		}

		if($ch eq "\e") {
			#
			# we use a 500ms ESC delay to allow the terminal to send
			# the rest of an escape sequence, and then try to match again...
			# this is only done if we fail to match initially.
			#
			select(undef,undef,undef,.05);
			while( defined ( $z = Term::ReadKey::ReadKey(-1) ) ) {
				push(@termInput,$z);
			}
			$code = $ch . join('',@termInput);

			$key = matchKeyCodes($code);
			if($key) {
				push(@keysPressed, $key) if($_debug);
				return($key);
			}
		}

		#
		# now that we've checked special cases, assume we have JUST an ESC
		#
		if($ch eq "\e") {
			push(@keysPressed, "KEY_ESCAPE") if($_debug);
			return("KEY_ESCAPE");
		}

		if($ch =~ tr/[\000-\037\177]/[\100-\137\077]/) {
			push(@keysPressed, KEY_CTRL($ch)) if($_debug);
			return(KEY_CTRL($ch));
		}

		if($ch =~ tr/[\240-\300\341-\372\210\301-\340\373-\376]/[\040-\100\101-\132\210\101-\140\173-\176]/) {
			push(@keysPressed, KEY_ALT($ch)) if($_debug);
			return(KEY_ALT($ch));
		}
	}

	push(@keysPressed, $ch) if($_debug);
	return $ch;
}

sub printable {
	my $arg = shift;

	$arg =~ s/([\000-\037\177])/_convertCtrl($1)/ge;
	$arg =~ s/([\177-\400])/_convertBin($1)/ge;
	$arg =~ s/\^\[/ESC/g;

	return($arg);
}

sub _convertCtrl {
	my $c = shift;

	$c =~ tr|[\000-\037\177]|[\100-\137\077]|;

	$c = "^$c";
	return($c);
}

sub _convertBin {
	my $c = shift;

	$c = unpack("C",$c);
	$c = sprintf("%X",$c);

	$c = "<$c>";
	return($c);
}

sub _convertBinEscape {
	my $c = shift;

	$c = unpack("C",$c);

	$c = "XX${c}XX";
	return($c);
}

sub _unconvertBinEscape {
	my $c = shift;

	$c = pack("C",$c);

	return($c);
}

sub _escape {
	my $arg = shift;
	$arg =~ s/([^\040-\176])/_convertBinEscape($1)/eg;
	return($arg);
}

sub _unescape {
	my $arg = shift;
	$arg =~ s/XX(\d+)XX/_unconvertBinEscape($1)/eg;
	return($arg);
}

sub endwin {
	print $termInfo{'cl'};
	Term::ReadKey::ReadMode(MODE_RESTORE);
	$termWinOk = 0;
	#
	# tell the shell to handle and winch events -- this will correctly
	# reset $COLUMNS and $LINES in the shell
	#
	kill('WINCH',getppid());
}

sub displayKeyDebug {
	my $maxy = getmaxy();
	my $sel = 0;
	my $ch;
	my $maxSel = @keysPressed - ($maxy-5);

	my $saveDebug = $_debug;
	$_debug = 0; # don't record keys in the debugger

	while(1) {
		erase();
		box();
		addstr($maxy-2,3,"ch = '$ch'");
		my $y = 2;
		for(my $i = $sel; $i < $sel+($maxy-5); $i++) {
			last if($i == @keysPressed);
			addstr($y,2,"$i - $keysPressed[$i]");
			$y++;
		}
		refresh();
		
		$ch = getch();
		if($ch eq KEY_ESCAPE) {
			$_debug = $saveDebug;
			return;
		}
		if($ch eq KEY_UP) {
			$sel-- if($sel);
		}
		if($ch eq KEY_DOWN) {
			$sel++ if($sel < $maxSel);
		}
		if($ch eq KEY_PAGEUP || $ch eq 'b') {
			$sel-=($maxy-5);
			$sel = 0 if($sel < 0);
		}
		if($ch eq KEY_PAGEDOWN || $ch eq ' ') {
			$sel+=($maxy-5);
			$sel = $maxSel if($sel > $maxSel);
		}
	}

}

#
# drawScrollBar is a generic scrollbar drawing routine.  
# It takes the y,x (using curses standard for notation) of the
# top left corner of the scrollbar, and then:
#
# winsize -- the vertical size of the display area
# place -- the top of the display view
# bufsize -- the vertical size of the display buffer
#
# in otherwords if you pass in winsize=20, place=50, and bufsize=300,
# then this will draw a 20 high scroll bar reflecting a window that is
# showing lines 50-69 of a 300 line buffer.
#
# NOTE: this assumes that $y is the top of your display area... it's not
# required, but it will be weird if the scroll bar doesn't line up with
# your display.
#
sub drawScrollBar {
	my ($y, $x, $winsize, $place, $bufsize) = @_;

	if($winsize >= $bufsize) {
		return; # it's all on screen, nothing to do
	}

	#
	# whoever said 8th grade math would never be useful?
	#

	#
	# winsize    barsize
	# ------- == -------
	# bufsize    winsize
	#
	my $barsize = ($winsize*$winsize)/$bufsize;
	if($barsize < POSIX::floor($barsize)+0.5) {
		$barsize = POSIX::floor($barsize);
	} else {
		$barsize = POSIX::ceil($barsize);
	}

	#
	# place      barpos
	# ------- == -------
	# bufsize    winsize
	#
	my $barpos;
	$barpos = ($place*$winsize)/$bufsize;
	if($barpos < POSIX::floor($barpos)+0.5) {
		$barpos = POSIX::floor($barpos);
	} else {
		$barpos = POSIX::ceil($barpos);
	}

	for(my $i=0; $i<$winsize; $i++) {
		my $ch;
		if($i == 0) {
			$ch = ' ^ ';
		} elsif($i == $winsize-1) {
			$ch = ' v ';
		} elsif($i >= $barpos && $i <= $barpos+$barsize) {
			$ch = '|#|';
		} else {
			$ch = '| |';
		}
		addstr($y+$i, $x, $ch);
	}
}

#
# getText takes a $y, a $x, and a buffer, and gets a string at those
# coordinates.  It handles scrolling, and will return the entered string.
#
# It handles a small subset of readline, including cut/paste, and cursor
# movement commands.
#
# It also takes a reference to a callback function, which is used to draw
# or redraw the screen, and a hash which is passed to the call back allowing
# args to be passed to the callback function.
#
# Last, it takes a reference to a clipBoard string that is used for any
# cut and paste commands entered.
#
sub getText {
	my $y = shift;
	my $x = shift;
	my $scrollX = shift;
	my $buf = shift;
	my $callback = shift;
	my $callbackArgsHashRef = shift;
	my $clipBd = shift;

	my $lastCopy = undef;
	my $len = $scrollX - $x;
	my $chunk;
	my $disp;
	my $offset;
	my $c;
	my $rest = "";

	if(length($buf) > $len-10) {
		$chunk = length($buf)-10;
	} else {
		$chunk = 0;
	}

	&{$callback}($callbackArgsHashRef);
	while(1) {
		if(length($buf)-$chunk > $len-10) {
			$chunk = length($buf)-10;
		}
		$disp = substr($buf,$chunk); # this should always be end of string
		$offset = length($disp);
		$disp .= substr($rest,0,$len-length($disp));
		$disp .= " " x ($len - length($disp)); # this will erase any artifacts

		addstr($y,$x,$disp);
		move($y,$x+$offset);
		refresh($y,$y);
		$c=getch();

		# end of input
		if($c eq KEY_ENTER) {
			$buf .= $rest;
			return $buf;
		}

		# move left in string
		if($c eq KEY_LEFT && length($buf)) {
			$lastCopy = undef;
			my $char = chop($buf);
			$rest = $char . $rest; # add it to the front of $rest

			# recalc the buffer math
			if($chunk == length($buf)) {
				$chunk=length($buf)-$len+11;
				if($chunk < 0) {
					$chunk=0;
				}
			}
		}

		# move right in string
		if($c eq KEY_RIGHT && length($rest)) {
			$lastCopy = undef;
			my $char = substr($rest,0,1,"");
			$buf .= $char;
		}

		# BACKSPACE -- back delete a character
		if($c eq KEY_BACKSPACE || $c eq KEY_CTRL("?") || $c eq KEY_CTRL("H")) {
			$lastCopy = undef;
			chop($buf);
			if($chunk == length($buf)) {
				$chunk=length($buf)-$len+11;
				if($chunk < 0) {
					$chunk=0;
				}
			}
		}

		# DELETE -- forward delete a character
		if($c eq KEY_DELETE && length($rest)) {
			$lastCopy = undef;
			substr($rest,0,1,"");
		}

		# HOME/CTRL-A -- move to beginning of line
		if($c eq KEY_HOME || $c eq KEY_CTRL("A")) {
			$lastCopy = undef;
			$rest = $buf . $rest;
			$buf = "";
			$chunk = 0;
			$c = "";
		}

		# END/CTRL-E -- move to end of line
		if($c eq KEY_END || $c eq KEY_CTRL("E")) {
			$lastCopy = undef;
			$buf .= $rest;
			$rest = "";
			if(length($buf) > $len-10) {
				$chunk = length($buf)-10;
			} else {
				$chunk = 0;
			}
		}

		# ALT-D -- remove word forward
		if($c eq KEY_ALT("D")) { # Alt-D
			if($rest =~ s/(^\s*[^\s]+)//) {
				if($lastCopy eq "F") {
					$$clipBd .= $1;
				} else {
					$$clipBd = $1;
				}
			}
			$lastCopy = "F";
			$c = "";
		}

		# ALT-BACKSPACE -- remove a word backwards
		if($c eq KEY_ALT("BACKSPACE")) {
			if($buf =~ s/([^\s]+\s*$)//) {
				if($lastCopy eq "B") {
					$$clipBd = $1 . $$clipBd;
				} else {
					$$clipBd = $1;
				}
			}
			$lastCopy = "B";
			if($chunk >= length($buf)) {
				$chunk=length($buf)-$len+11;
				if($chunk < 0) {
					$chunk=0;
				}
			}
			$c="";
		}

		# delete-line or CTRL-U -- delete to beginning of line
		if($c eq KEY_DL || $c eq KEY_CTRL("U")) {
			$lastCopy = undef;
			$$clipBd = $buf;
			$buf = "";
			$chunk = 0;
			$c = "";
		}

		# delete-end-of-line or CTRL-K -- delete to end of line
		if($c eq KEY_EOL || $c eq KEY_CTRL("K")) {
			$lastCopy = undef;
			$$clipBd = $buf;
			$rest = "";
			$c = "";
		}

		# CTRL-Y/CTRL-V -- paste clipBoard
		if($c eq KEY_CTRL("Y") || $c eq KEY_CTRL("V")) {
			$lastCopy = undef;
			$buf .= $$clipBd;
		}

		# CTRL-L -- reinit window
		if($c eq KEY_CTRL("L")) {
			endwin();
			initscr();

			$len = getmaxx() - 20;
			$buf = $buf . $rest;
			$rest = "";
			if(length($buf) > $len-10) {
				$chunk = length($buf)-10;
			} else {
				$chunk = 0;
			}

			my ($newy, $newx, $newScrollX) = &{$callback}($callbackArgsHashRef);
			$y = $newy if($newy);
			$x = $newx if($newx);
			$scrollX = $newScrollX if($newScrollX);
			$len = $scrollX - $x;
			refresh();
		}

		# printable character -- insert into string
		if($c =~ /[\040-\176]/ && length($c) == 1) {
			$lastCopy = undef;
			$buf .= $c;
		}
	}
}

sub pageFH {
	my $fh = shift;
	my $name = shift;
	my $useColor = shift;
	my $diff = shift;
	my $fileNum = shift;
	my $numFiles = shift;
	my (%file, %orig, %new, $size, $ret);

	if($diff) {
		$size = loadFH($fh, \%file, \%orig, \%new);
		$ret = pageFile(\%file, \%orig, \%new, $size, $name, $useColor,
			$fileNum, $numFiles);
	} else {
		$size = loadFH($fh, \%file);
		$ret = pageFile(\%file, undef, undef, $size, $name, $useColor,
			$fileNum, $numFiles);
	}

	return($ret);
}

sub loadFH {
	my $stream = shift;
	my $file = shift;
	my $orig = shift;
	my $new = shift;
	my $size = -1;

	#
	# This function stores a hash of $lineNumber => $text
	#
	# if supplied, %orig and %new are set with $lineNumber => 1 for lines
	# that match /^-/ and /^\+/ respectively, which is used for highlighting
	# and showing side by side mode. (in unified diffs, column one is either
	# '-' (removed line), '+' (added line), or ' ' (no change).
	#
	while(my $line = <$stream>) {
		chomp($line); # we handle newlines ourselves
		next if($orig && $line =~ /^\@\@[ ,\-\d\+]+\@\@$/);
		$size++;
		$file->{$size} = $line;
		next unless($orig);
		$orig->{$size} = 1 if($line =~ /^-/);
		$new->{$size} = 1 if($line =~ /^\+/);
	}

	return($size);
}

sub _convertTabstop {
	my $line = shift;
	my $tabStop = shift;

	my $len = length($line);
	my $stoplen = $tabStop - ($len % $tabStop);

	$line .= " " x $stoplen;

	return($line);
}

sub parseTabs {
	my $file = shift;
	my $orig = shift;
	my $parsed = shift;
	my $tabStop = shift;

	foreach my $k (%{$file}) {
		my $line = $file->{$k};
		my $fc = "";
		
		if($orig) {
			$line =~ s/^(.)//;
			$fc = $1;
		}

		#
		# handle a tab correctly -- what we do is convert a tab to a number
		# of spaces equal to N minus the length of the line before the
		# tab modded by N, where N is the user defined tabstop length
		# This means that (for $tabStop == 4):
		#
		# "aa\tbb"  is replaced by "aa  bb"
		# "\tbb"    is replaced by "    bb"
		# "aaa\tbb" is replaced by "aaa bb"
		#
		# and so forth.
		#
		while($line =~ s/^([^\t]*)\t/_convertTabstop($1,$tabStop)/e) {}

		$parsed->{$k} = "$fc$line";
	}
}

sub sideBySidePrep {
	my $orig = shift;
	my $new = shift;
	my $size = shift;
	my $sideBySide = shift;
	my $j = 0;
	my $i = 0;

	#
	# what we do, is create a mapping hash, that is:
	#
	# sideBySideLineNumber => "$origFileLineNumber,$newFileLineNumber"
	#
	# note that the referenced line numbers are mapped to a unified diff, so
	# line 4 might exist in both, or either of the diffed files
	#
	# The possible results would look like:
	#
	# 4 => "5,5"  # same
	# 10 => "6,8" # different, and shown on same line
	# 12 => "undef,10" # added in new
	# 44 => "30,undef" # removed from old
	#
	# Note that the order in the diffs is -,+ so, parsing you might see:
	# (s represents a "same" line)
	#
	# -,-,+,+,s -- lines 1-2 changed for lines 3-4
	#	=> 1,3 ; 2,4 ; 5,5 ...
	# s,-,-,s  -- lines 2-3 dropped in change
	#	=> 1,1 ; 2,undef ; 3,undef ; 4,4
	# s,+,+,s -- lines 2-3 added in change
	#	=> 1,1 ; undef,2 ; undef,3 ; 4,4
	# -,-,+,+,+,+,s -- lines 1-2 changed for lines 4-6
	#	=> 1,3 ; 2,4 ; undef,5 ; undef,6 ; 7,7
	# -,-,-,-,+,+,s -- lines 1-4 changed for lines 5-6
	#	=> 1,5 ; 2,6 ; 3,undef ; 4,undef ; 7,7
	#
	while ($i<=$size) {
		if($orig->{$i}) {
			#
			# This will be a group of lines removed, followed by 0 or more
			# lines added...
			#
			my $o = $j;
			my $n = $j;
			#
			# gather the lines removed...
			#
			while($orig->{$i}) {
				$sideBySide->{$o++} = "$i";
				$i++;
			}
			#
			# map them to any corresponding added lines... if more lines
			# are added than removed we start marking adds as not having
			# corresponding removes
			#
			while($new->{$i}) {
				$sideBySide->{$n} = "undef" unless(defined($sideBySide->{$n}));
				$sideBySide->{$n++} .= ",$i";
				$i++;
			}
			#
			# if fewer lines are added than removed, mark the rest of the
			# removes as not having corresponding adds
			#
			while($n < $o) {
				$sideBySide->{$n} .= ",undef";
				$n++;
			}
			$j = $n;
		} elsif($new->{$i}) {
			#
			# these are only in the new revision, since there was no orig
			# lines immediately in front of them
			#
			$sideBySide->{$j++} = "undef,$i";
			$i++;
		} else {
			#
			# this line is unchanged in both revisions
			#
			$sideBySide->{$j++} = "$i,$i";
			$i++;
		}
	}

	return($j-1); # -1 is to be consistant with regular size variable
}

sub sidesAreDifferent {
	my $str = shift;

	my ($a, $b) = split(',',$str);
	return($a ne $b);
}

#
# These functions allow us to shift between unified and side by side
# without jumping around in the file, which is confusing... basically
# this causes whatever line is at the top of a unified diff to be the top
# of the side by side when switching.  Going the other way, whatever line
# is the top of the original side will be the top, unless that line is only
# in the revised in which case the revised line will be top.
#
sub unifiedTop {
	my $top = shift;
	my $sh = shift;

	my ($o, $n) = split(',',$sh->{$top});
	return($o) if ($o ne 'undef');
	return($n);
}

sub sideBySideTop {
	my $top = shift;
	my $sh = shift;

	for(my $i = $top; $i >= 0; $i--) {
		my ($o, $n) = split(',', $sh->{$i});
		return($i) if ($top == $o || $top == $n);
	}

	# shouldn't happen
	return($top);
}

sub pageFile {
	my $file = shift;
	my $orig = shift;
	my $new = shift;
	my $size = shift;
	my $name = shift;
	my $useColor = shift;
	my $fileNum = shift;
	my $numFiles = shift;
	my $maxy = $size - getmaxy() + 2;
	$maxy = 0 if($maxy < 0);
	my $top = 0;
	my $x = 0;
	my $mesg;
	my $search;
	my $rawSearch;
	my $clipBd;
	my $lineNums = 0;
	my $parsed = {};
	my %sideBySide;
	my $sideSize;
	my $widthAdjust = 0;
	my %screenCache;

	if($orig) {
		$sideSize = sideBySidePrep($orig,$new,$size,\%sideBySide);
		if(!defined $pageFileMode && getmaxx() > 119) {
			# default to side by side if the terminal is wide
			$pageFileMode = PAGER_MODE_SIDEBYSIDE;
			$maxy = $sideSize - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
		}
	}
	$pageFileMode = PAGER_MODE_UNIFIED unless(defined($pageFileMode));

	parseTabs($file,$orig,$parsed,4);

	while(1) {
		drawPageFile($top,$size,$x,$parsed,$orig,$new,$pageFileMode,$name,$mesg,$search,
			$rawSearch,$useColor,$fileNum,$numFiles,$lineNums,\%sideBySide,
			$sideSize,$widthAdjust);
		$mesg = undef;
		my $ch = getch();
		if($ch eq KEY_CTRL("L")) {
			my $saveMaxX = getmaxx();
			endwin();
			initscr();
			$maxy = $size - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
			$widthAdjust = 0;
			#
			# make some mode decisions based on screen resizes
			#
			if($pageFileMode == PAGER_MODE_UNIFIED && $saveMaxX < 120 && getmaxx() > 119 && $orig) {
				$pageFileMode = PAGER_MODE_SIDEBYSIDE;
				$top = sideBySideTop($top, \%sideBySide);
				$maxy = $sideSize - getmaxy() + 2;
				$maxy = 0 if($maxy < 0);
			} elsif($pageFileMode == PAGER_MODE_SIDEBYSIDE && $saveMaxX > 119 && getmaxx() < 120) {
				$pageFileMode = PAGER_MODE_UNIFIED;
				$top = unifiedTop($top, \%sideBySide);
				$maxy = $size - getmaxy() + 2;
				$maxy = 0 if($maxy < 0);
			}
		} elsif($ch eq KEY_UP || $ch eq "k") {
			$top--;
			if($pageFileMode == PAGER_MODE_ORIGINAL) { while($new->{$top} && $top) { $top-- } }
			if($pageFileMode == PAGER_MODE_REVISED) { while($orig->{$top} && $top) { $top-- } }
		} elsif($ch eq KEY_DOWN || $ch eq "j") {
			$top++;
			if($pageFileMode == PAGER_MODE_ORIGINAL) { while($new->{$top} && $top < $maxy) { $top++ } }
			if($pageFileMode == PAGER_MODE_REVISED) { while($orig->{$top} && $top < $maxy) { $top++ } }
		} elsif($ch eq KEY_LEFT || $ch eq "h") {
			$x-=4 if($x);
		} elsif($ch eq KEY_RIGHT || $ch eq "l") {
			$x+=4;
		} elsif(($ch eq KEY_ALT("LEFT") || $ch eq "<") && $pageFileMode == PAGER_MODE_SIDEBYSIDE) {
			if($widthAdjust > ((getmaxx()-(length($size)*2)-16)*-.5)) {
				$widthAdjust--;
			}
		} elsif(($ch eq KEY_ALT("RIGHT") || $ch eq ">") && $pageFileMode == PAGER_MODE_SIDEBYSIDE) {
			if($widthAdjust < ((getmaxx()-(length($size)*2)-16)*.5)) {
				$widthAdjust++;
			}
		} elsif(($ch eq KEY_F(6) || $ch eq KEY_CTRL("LEFT")) &&
				$pageFileMode == PAGER_MODE_SIDEBYSIDE
		) {
			$widthAdjust = int((getmaxx()-(length($size)*2)-16)*-.5);
		} elsif(($ch eq KEY_F(7) || $ch eq KEY_CTRL("RIGHT")) &&
				$pageFileMode == PAGER_MODE_SIDEBYSIDE
		) {
			$widthAdjust = int((getmaxx()-(length($size)*2)-16)*.5);
		} elsif(($ch eq KEY_CTRL("UP") || $ch eq KEY_CTRL("DOWN") || $ch eq '.')
				&& $pageFileMode == PAGER_MODE_SIDEBYSIDE
		) {
			$widthAdjust = 0;
		} elsif($ch eq KEY_PAGEUP || $ch eq 'b' || $ch eq KEY_CTRL("B")) {
			$top -= (getmaxy() - 2);
		} elsif($ch eq KEY_PAGEDOWN || $ch eq ' ' || $ch eq KEY_CTRL("F")) {
			$top += (getmaxy() - 2);
		} elsif($ch eq KEY_END || $ch eq 'G') {
			$top = $size - getmaxy() + 2;
		} elsif($ch eq KEY_HOME) {
			$top = 0;
		} elsif($ch eq KEY_F(1) && $orig) {
			$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
			$pageFileMode = PAGER_MODE_UNIFIED;
			$mesg = "display set to unified diff output.";
			$maxy = $size - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
		} elsif($ch eq KEY_F(2) && $orig) {
			$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
			$pageFileMode = PAGER_MODE_REVISED;
			$mesg = "display set to revised file.";
			$maxy = $size - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
		} elsif($ch eq KEY_F(3) && $orig) {
			$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
			$pageFileMode = PAGER_MODE_ORIGINAL;
			$mesg = "display set to original file.";
			$maxy = $size - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
		} elsif($ch eq KEY_F(4)) {
			if($lineNums) {
				$lineNums = 0;
				$mesg = "line numbering disabled.";
			} else {
				$lineNums = 1;
				$mesg = "line numbering enabled.";
			}
		} elsif($ch eq KEY_F(5) && $orig) {
			$top = sideBySideTop($top, \%sideBySide) if($pageFileMode != PAGER_MODE_SIDEBYSIDE);
			$pageFileMode = PAGER_MODE_SIDEBYSIDE;
			$mesg = "display set to side by side diff.";
			$maxy = $sideSize - getmaxy() + 2;
			$maxy = 0 if($maxy < 0);
			$widthAdjust = 0;
		} elsif($ch eq 'q' || $ch eq 'Q' || $ch eq KEY_ESCAPE) {
			return(0);
		} elsif($ch eq KEY_CTRL("N") && defined($fileNum)) {
			return(1);
		} elsif($ch eq KEY_CTRL("P") && defined($fileNum)) {
			return(-1);
		} elsif($ch eq "?") {
			drawDisplayHelp();
		} elsif($ch eq "/") {
			my %args = (
				'top'=>$top,
				'size'=>$size,
				'x'=>$x,
				'file'=>$parsed,
				'orig'=>$orig,
				'new'=>$new,
				'mode'=>$pageFileMode,
				'search'=>$search,
				'rawSearch'=>$rawSearch,
				'useColor'=>$useColor,
				'fileNum'=>$fileNum,
				'numFiles'=>$numFiles,
				'lineNums'=>$lineNums,
				'cursor'=>'/',
				'sideBySide'=>\%sideBySide,
				'sideSize'=>$sideSize,
				'widthAdjust'=>$widthAdjust,
			);
			$rawSearch = getText(getmaxy()-1, 1, getmaxx()-5, "", \&callbackSearch, \%args, \$clipBd);
			$search = quotemeta($rawSearch);
			$ch = 'n';
		} elsif($ch eq ":") {
			my %args = (
				'top'=>$top,
				'size'=>$size,
				'x'=>$x,
				'file'=>$parsed,
				'orig'=>$orig,
				'new'=>$new,
				'mode'=>$pageFileMode,
				'search'=>$search,
				'rawSearch'=>$rawSearch,
				'useColor'=>$useColor,
				'fileNum'=>$fileNum,
				'numFiles'=>$numFiles,
				'lineNums'=>$lineNums,
				'cursor'=>':',
				'sideBySide'=>\%sideBySide,
				'sideSize'=>$sideSize,
				'widthAdjust'=>$widthAdjust,
			);
			my $cmd = getText(getmaxy()-1, 1, getmaxx()-5, "", \&callbackSearch, \%args, \$clipBd);
			if($cmd =~ /^\d+$/) {
				if($cmd > $size) {
					$cmd = $size;
				}
				if($pageFileMode == PAGER_MODE_SIDEBYSIDE) {
					$cmd = sideBySideTop($cmd,\%sideBySide);
				}
				$top = $cmd;
			} elsif ( $cmd =~ /^set\s*(.*)/i ) {
				my $set = $1;
				if( $set =~ /^number$/i ) {
					$lineNums = 1;
					$mesg = "line numbering enabled.";
				} elsif ( $set =~ /^nonumber$/i ) {
					$lineNums = 0;
					$mesg = "line numbering disabled.";
				} elsif ( $set =~ /tabstop\s*=\s*(\d+)$/i ) {
					$mesg = "tab spacing set to $1.";
					parseTabs($file,$orig,$parsed,$1);
				} elsif ( $set =~ /^unified/) {
					$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
					$pageFileMode = PAGER_MODE_UNIFIED;
					$mesg = "display set to unified diff output.";
					$maxy = $size - getmaxy() + 2;
					$maxy = 0 if($maxy < 0);
				} elsif ( $set =~ /^sidebyside/ && $orig) {
					$top = sideBySideTop($top, \%sideBySide) if($pageFileMode != PAGER_MODE_SIDEBYSIDE);
					$pageFileMode = PAGER_MODE_SIDEBYSIDE;
					$mesg = "display set to side by side diff.";
					$maxy = $sideSize - getmaxy() + 2;
					$maxy = 0 if($maxy < 0);
					$widthAdjust = 0;
				} elsif ( $set =~ /^original/ && $orig) {
					$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
					$pageFileMode = PAGER_MODE_ORIGINAL;
					$mesg = "display set to original file.";
					$maxy = $size - getmaxy() + 2;
					$maxy = 0 if($maxy < 0);
				} elsif ( $set =~ /^revised/ && $orig) {
					$top = unifiedTop($top, \%sideBySide) if($pageFileMode == PAGER_MODE_SIDEBYSIDE);
					$pageFileMode = PAGER_MODE_REVISED;
					$mesg = "display set to revised file.";
					$maxy = $size - getmaxy() + 2;
					$maxy = 0 if($maxy < 0);
				} else {
					$mesg = "$set is an invalid set argument.";
				}
			} else {
				$mesg = "$cmd is not a valid command.";
			}
		} elsif($ch eq KEY_CTRL("U")) {
			$search = undef; # clear the search term.
		} elsif($ch eq KEY_CTRL("I")) {
			if($pageFileMode == PAGER_MODE_SIDEBYSIDE) {
				my $cur = $top;
				while(sidesAreDifferent($sideBySide{$top})) {
					$top++;
					if($top > $sideSize) {
						$top = 0;
						last;
					}
					last if($top == $cur);
				}
				while(!sidesAreDifferent($sideBySide{$top})) {
					$top++;
					$top=0 if($top > $sideSize);
					last if($top == $cur);
				}
			} else {
				my $cur = $top;
				if($new->{$top}) {
					while($new->{$top}) {
						$top++;
						if($top > $size) { $top=0; last; }
						last if($top == $cur);
					}
				} elsif($orig->{$top}) {
					while($new->{$top} || $orig->{$top}) {
						$top++;
						if($top > $size) { $top=0; last; }
						last if($top == $cur);
					}
				}
				while(!$new->{$top} && !$orig->{$top}) {
					$top++;
					$top=0 if($top > $size);
					last if($top == $cur);
				}
			}
		} elsif($ch eq KEY_BACKSPACE || $ch eq KEY_SHIFT_TAB) {
			if($pageFileMode == PAGER_MODE_SIDEBYSIDE) {
				my $cur = $top;
				while(sidesAreDifferent($sideBySide{$top})) {
					$top--;
					if($top < 0) {
						$top = $sideSize;
						last;
					}
					last if($top == $cur);
				}
				while(!sidesAreDifferent($sideBySide{$top})) {
					$top--;
					$top = $sideSize if($top < 0);
					last if($top == $cur);
				}
				while(sidesAreDifferent($sideBySide{$top})) {
					$top--;
					last if($top < 0);
					last if($top == $cur);
				}
				$top++ if($top != $cur);
			} else {
				my $cur = $top;
				if($orig->{$top}) {
					while($orig->{$top}) {
						$top--;
						if($top < 0) { $top=$size; last; }
						last if($top == $cur);
					}
				} elsif($new->{$top}) {
					while($new->{$top} || $orig->{$top}) {
						$top--;
						if($top < 0) { $top=$size; last; }
						last if($top == $cur);
					}
				}
				while(!$new->{$top} && !$orig->{$top}) {
					$top--;
					$top=$size if($top < 0);
					last if($top == $cur);
				}
				while($new->{$top} || $orig->{$top}) {
					$top--;
					last if($top < 0);
					last if($top == $cur);
				}
				$top++ if($top != $cur);
			}
		} elsif($ch ne 'n') {
			$mesg = "Press '?' for a list of commands.";
		}
		if($ch eq 'n') {
			my $cur = $top;
			while(1) {
				$top++;
				last if($top == $cur);
				if($top > $size) {
					$top = -1;
					$mesg = "Search Wrapped ";
				}
				next if($pageFileMode == PAGER_MODE_ORIGINAL && $new->{$top});
				next if($pageFileMode == PAGER_MODE_REVISED && $orig->{$top});
				if($pageFileMode != PAGER_MODE_SIDEBYSIDE) {
					last if($file->{$top} =~ /$search/);
				} else {
					my ($a, $b) = split(',',$sideBySide{$top});
					last if($file->{$a} =~ /$search/);
					last if($file->{$b} =~ /$search/);
				}
			}
			if($pageFileMode != PAGER_MODE_SIDEBYSIDE) {
				if($top == $cur && $file->{$top} !~ /$search/) {
					$mesg = "Search Term Not Found. ";
				}
			} else {
				my ($a, $b) = split(',',$sideBySide{$top});
				if($top == $cur && $file->{$a} !~ /$search/
					&& $file->{$b} !~ /$search/
				) {
						$mesg = "Search Term Not Found. ";
				}
			}
		}
		$top = 0 if($top < 0);
		$top = $maxy if($top > $maxy && $ch ne KEY_CTRL("I") && $ch ne 'n');
	}
}

sub callbackSearch {
	my $a = shift;
	drawPageFile(
		$a->{'top'},
		$a->{'size'},
		$a->{'x'},
		$a->{'file'},
		$a->{'orig'},
		$a->{'new'},
		$a->{'mode'},
		"",
		$a->{'cursor'},
		$a->{'search'},
		$a->{'rawSearch'},
		$a->{'useColor'},
		$a->{'fileNum'},
		$a->{'numFiles'},
		$a->{'lineNums'},
		$a->{'sideBySide'},
		$a->{'sideSize'},
		$a->{'widthAdjust'},
	);
	return(getmaxy()-1, undef, getmaxx()-5); # y and scroll change, x does not
}

sub drawPageFile {
	my $top = shift;
	my $size = shift;
	my $x = shift;
	my $file = shift;
	my $orig = shift;
	my $new = shift;
	my $mode = shift;
	my $filename = shift;
	my $mesg = shift;
	my $search = shift;
	my $rawSearch = shift;
	my $useColor = shift;
	my $fileNum = shift;
	my $numFiles = shift;
	my $lineNums = shift;
	my $sideBySide = shift;
	my $sideSize = shift;
	my $widthAdjust = shift;
	my $y = 0;
	my $i = $top-1;
	#
	# these variables are for side by side diffing
	#
	my ($origX, $newX, $width, $origWidth, $newWidth);

	if($mode == PAGER_MODE_SIDEBYSIDE) {
		if($lineNums) {
			my $spacer = length($size) + 3;
			$origX = $spacer+1;
			$width = (getmaxx()-3-($spacer*2)) / 2; $width =~ s/\.5$//;
		} else {
			$origX = 0;
			$width = (getmaxx()-1) / 2; $width =~ s/\.5$//;
		}
		$origWidth = $width + $widthAdjust;
		$newWidth = $width - $widthAdjust;
		$newX = $origX+$origWidth+1;
	}

	erase();
	while(1) {
		$i++;
		last if($y == getmaxy()-1);
		last if($mode != PAGER_MODE_SIDEBYSIDE && $i > $size);
		last if($mode == PAGER_MODE_SIDEBYSIDE && $i > $sideSize);
		next if($mode == PAGER_MODE_ORIGINAL && $new->{$i});
		next if($mode == PAGER_MODE_REVISED && $orig->{$i});
		my $str;
		if($mode == PAGER_MODE_SIDEBYSIDE) {
			#
			# $oi and $ni are the indexes of the main file that this "line"
			# points back at.  If $oi ne $ni then this line represents a diff
			#
			my $spacer = 0;
			my ($oi, $ni) = split(',',$sideBySide->{$i});
			origDiffColor($useColor,1) if($oi ne $ni);
			if($lineNums) {
				$spacer = length($size) + 2;
				my $str;
				if($oi ne 'undef') {
					$str = sprintf(" %-${spacer}d|",$oi);
				} else {
					$str = sprintf(" %${spacer}s|","");
					attrset(A_NORMAL);
				}
				addstr($y,0,$str);
			}
			my $dstr;
			if($file->{$oi}) {
				$dstr = sprintf("%-${origWidth}s",substr($file->{$oi},$x+1,$origWidth));
				$str .= addstrEscapeCtrl($y,$origX,$dstr);
			} else {
				$str .= " " x $origWidth;
			}
			diffGlueColor($useColor,$sideBySide,$i) if($oi ne $ni);
			addstr($y,$newX-1,"|");
			$str .= "|";
			newDiffColor($useColor) if($oi ne $ni);
			if($lineNums) {
				my $str2;
				if($ni ne 'undef') {
					$str2 = sprintf(" %-${spacer}d|",$ni);
				} else {
					$str2 = sprintf(" %${spacer}s|","");
					attrset(A_NORMAL);
				}
				$str .= $str2;
				addstr($y,$newX,$str2);
				$spacer += 2; # account for the leading space and the |
			}
			if($file->{$ni}) {
				$dstr = sprintf("%-${newWidth}s",substr($file->{$ni},$x+1,$newWidth));
			} else {
				$dstr = "";
			}
			$str .= addstrEscapeCtrl($y,$newX+$spacer,$dstr);
		} else {
			if($lineNums) {
				my $spacer = length($size) + 3;
				$str = substr($file->{$i},$x,getmaxx()-$spacer);
				$spacer--;
				$str = sprintf(" %-${spacer}d%s",$i,$str);
			} else {
				$str = substr($file->{$i},$x,getmaxx());
			}
			origDiffColor($useColor) if($orig->{$i});
			newDiffColor($useColor) if($new->{$i});
			$str = addstrEscapeCtrl($y,0,$str);
		}
		if($search) {
			my $offset = 0;
			while(($offset = index($str,$rawSearch,$offset)) > -1) {
				searchColor($useColor);
				if($mode != PAGER_MODE_SIDEBYSIDE) {
					searchColorOrigDiff($useColor) if($orig->{$i});
					searchColorNewDiff($useColor) if($new->{$i});
				}
				addstr($y,$offset,$rawSearch);
				$offset++;
			}
		}
		$y++;
		attrset(A_NORMAL);
	}

	attrset(A_REVERSE);
	my $fileCt = "";
	$fileCt = "FILE $fileNum/$numFiles - " if(defined($fileNum));
	my $dispLine = $top;
	if($mode == PAGER_MODE_SIDEBYSIDE) {
		my ($o, $n) = split(',',$sideBySide->{$top});
		if($o ne 'undef') {
			$dispLine = $o;
		} else {
			$dispLine = $n;
		}
	}
	my $footerStr = "${fileCt}LINE ${dispLine}/$size - $filename ";
	if($mode == PAGER_MODE_SIDEBYSIDE) {
		my $spaceStr = " " x (getmaxx()-1);
		addstr(getmaxy()-1,0,$spaceStr);
	}
	if($mesg) {
		if($mesg eq "/" || $mesg eq ':') {
			attrset(A_NORMAL);
			addstr(getmaxy()-1,0,$mesg);
		} else {
			if($mode != PAGER_MODE_SIDEBYSIDE || length($footerStr) > $width) {
				addstr(getmaxy()-1,0,$mesg);
			} else {
				addstr(getmaxy()-1,$origX + $width - int(length($footerStr)/2), $mesg);
			}
		}
	} else {
		if($mode != PAGER_MODE_SIDEBYSIDE || length($footerStr) > $width) {
			addstr(getmaxy()-1,0,$footerStr);
		} else {
			addstr(getmaxy()-1,$origX + $width - int(length($footerStr)/2), $footerStr);
		}
	}
	move(getmaxy(),getmaxx());
	attrset(A_NORMAL);
	refresh();
}

sub drawDisplayHelp {
	erase();
	box();
	addstr(2,3,  "General Command Keys:");
	addstr(4,5,  "up    : move up one line.");
	addstr(5,5,  "down  : move down one line.");
	addstr(6,5,  "left  : move left one line.");
	addstr(7,5,  "right : move right one line.");
	addstr(8,5,  "pgup  : move up one page.");
	addstr(9,5,  "pgdn  : move down one page.");
	addstr(11,5, "bksp  : move to previous diff.");
	addstr(12,5, "/     : enter search term.");
	addstr(13,5, "n     : find next occurance.");
	addstr(14,5, "Ctr-N : view next file.");
	addstr(15,5, "Ctr-P : view previous file.");
	addstr(17,5, "ESC   : exit viewer. (also \"q\")");

	addstr(2,37, "Diff Commands:");
	addstr(4,39, "F1    : view unified diff.");
	addstr(5,39, "F2    : view changed file.");
	addstr(6,39, "F3    : view original file.");
	addstr(7,39, "F4    : view line numbers (toggle).");
	addstr(8,39, "F5    : view side by side diff.");
	addstr(9,39, "F6    : stretch revised side.");
	addstr(10,39,"F7    : stretch original side.");
	addstr(11,39,"C-Left: slide separator left. (or '<')");
	addstr(12,39,"C-Rght: slide separator right. (or '>')"); 
	addstr(13,39,"tab   : move to next diff.");

	move(0,0);
	refresh();
	getch();
}

sub origDiffColor {
	my $useColor = shift;
	my $sideBySide = shift;

	if($useColor) {
		attrset(A_COLOR(COLOR_BOLD_WHITE,COLOR_BLUE));
		return;
	}
	if($sideBySide) {
		attrset(A_REVERSE);
		return;
	}
	attrset(A_UNDERLINE);
}

sub newDiffColor {
	my $useColor = shift;
	if($useColor) {
		attrset(A_COLOR(COLOR_BOLD_YELLOW,COLOR_RED));
		return;
	}
	attrset(A_REVERSE);
}

sub dominantDiffColor {
	my $useColor = shift;
	my $sh = shift;
	my $i = shift;
	my ($a, $b);

	while(1) {
		last unless(defined($sh->{$i}));
		my ($a, $b) = split(',',$sh->{$i});
		if($a eq 'undef') {
			newDiffColor($useColor);
			return;
		}
		if($b eq 'undef') {
			origDiffColor($useColor);
			return;
		}
		last if($a == $b);
		$i++;
	}

	newDiffColor($useColor); # default to red
}

sub diffGlueColor {
	my $useColor = shift;
	my $sh = shift;
	my $i = shift;

	if($useColor) {
		dominantDiffColor($useColor,$sh,$i);
		return;
	}
	attrset(A_REVERSE);
}

sub searchColor {
	my $useColor = shift;
	if($useColor) {
		attrset(A_COLOR(COLOR_BLACK,COLOR_CYAN));
		return;
	}
	attrset(A_REVERSE);
}

sub searchColorOrigDiff {
	my $useColor = shift;
	if($useColor) {
		attrset(A_COLOR(COLOR_BOLD_BLACK,COLOR_BLUE));
		return;
	}
	attrset(A_REVERSE);
}

sub searchColorNewDiff {
	my $useColor = shift;
	if($useColor) {
		attrset(A_COLOR(COLOR_BOLD_BLACK,COLOR_RED));
		return;
	}
	attrset(A_BOLD);
}

1;
