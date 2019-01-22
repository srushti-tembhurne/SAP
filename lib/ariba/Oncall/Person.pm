package ariba::Oncall::Person;

# $Id: //ariba/services/monitor/lib/ariba/Oncall/Person.pm#8 $

use strict;
use ariba::Ops::PersistantObject;
use ariba::Ops::Constants;
use ariba::Ops::Utils;

use base qw(ariba::Ops::PersistantObject);

# class methods
sub dir {
	return ariba::Ops::Constants->oncallpeopledir();
}

sub new {
	my $class  = shift;
	my $person = shift;

	return undef unless defined($person);

	return $class->SUPER::new($person);
}

sub objectLoadMap {
	my $class  = shift;

        my $map = $class->SUPER::objectLoadMap();

        $map->{'group'} =  'ariba::Oncall::Group';

        return $map;
}

sub emailStringForPerson {
	my $class    = shift;
	my $instance = shift;

	unless ($class->objectWithNameExists($instance)) {
		return undef;
	}

	my $person = $class->new($instance);
	my $pager  = $person->pagerEmail() || $person->email();
	my $name   = $person->fullname()   || $person->instance();

	return "\"$name\" <$pager>";
}

# instance methods
sub emailAddress {
	my $self = shift;

	if ($self->email()) {

		return $self->email();

	} else {

		my $username = $self->username();

		if (!defined $username or $username =~ /^\s*$/) {
			$username = $self->instance();
		}
		
		return $username.'@'.ariba::Ops::Constants->emailDomainName();
	}
}

sub sendPage {
	my ($self,$subject,$body,$replyto) = @_;

	my $to = $self->pagerEmail();
	
	return undef if $to =~ /^\s*$/;

	ariba::Ops::Utils::page($to,$subject,$body,undef,undef,$replyto);
}

sub sendEmail {
	my ($self,$subject,$body) = @_;

	my $to = $self->username();
	
	return undef if $to =~ /^\s*$/;

	$to .= '@' . ariba::Ops::Constants->emailDomainName();

	ariba::Ops::Utils::email($to,$subject,$body);
}

sub save {
	return undef;
}

sub remove {
	return undef;
}

sub cellPhone {
	my $self = shift;

	return _cleanPhoneNumber($self->attribute('cell-phone'));
}

sub homePhone {
	my $self = shift;

	return _cleanPhoneNumber($self->attribute('home-phone'));
}

sub workPhone {
	my $self = shift;

	return _cleanPhoneNumber($self->attribute('work-phone'));
}

sub yahooIm {
	my $self = shift;

	return $self->attribute('yahoo-im');
}

sub aolIm {
	my $self = shift;

	return $self->attribute('aol-im');
}

sub vcard { 
	my $self = shift;

	my $fullName = $self->fullname();
	my $role = $self->role();
	my $group = $self->group();
	my $email = $self->username().'@'.ariba::Ops::Constants->emailDomainName(); 
	my $cellPhone = $self->cellPhone();

	my $pagerEmail;
	if ($self->can("pagerEmail")) {
		$pagerEmail = $self->pagerEmail();

	} 
	my $homePhone = $self->homePhone();
	my $workPhone = $self->workPhone();
	my $yahooIm = $self->yahooIm();
	my $aolIm = $self->aolIm();

	my @nameArr = split(" ", $fullName);
	my $lastName = pop(@nameArr);
	my $firstName = join (" ", @nameArr); 

	my $vcard = "BEGIN:VCARD\n" .
		"FN:$fullName\n" .
		"N:$lastName;$firstName;;;\n";
	$vcard .= "ORG:Ariba;";
	$vcard .= "$group" if $group;
	$vcard .= "\n";
	$vcard .= "TITLE:$role\n" if $role;
	$vcard .= "EMAIL;type=INTERNET;type=WORK;type=pref:$email\n" if $email;
	$vcard .= "TEL;type=WORK:$workPhone\n" if $workPhone;
	$vcard .= "TEL;type=CELL:$cellPhone\n" if $cellPhone;
	$vcard .= "TEL;type=PAGER:$pagerEmail\n" if $pagerEmail;
	$vcard .= "X-AIM;type=HOME:$aolIm\n" if $aolIm;
	$vcard .= "X-YAHOO;type=HOME:$yahooIm\n" if $yahooIm;
	$vcard .= "END:VCARD\n";

	return $vcard;
}


# util subs

sub _cleanPhoneNumber {
	my $number = shift;

	if ( $number && (length($number) > 7) && ($number !~ /^1/) ) {
		$number = "1" . "$number";      # +1 for easy dialing
	}

	return $number;
}

sub pagerEmail {
	my $self = shift;
	return $self->attribute('pager-email');
}

sub hasPagerEmail{
	my $self  = shift;
	my $pager = $self->attribute('pager-email');

	return (defined $pager and $pager !~ /^\s*$/);
}

sub hasEmail{
	my $self  = shift;
	my $email = $self->attribute('username');

	return (defined $email and $email !~ /^\s*$/);
}

1;

__END__
