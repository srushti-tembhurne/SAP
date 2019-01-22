package ariba::Ops::PageFilter;

# $Id: //ariba/services/tools/lib/perl/ariba/Ops/PageFilter.pm#21 $

use strict;
use ariba::Ops::Constants;
use ariba::Ops::NetworkUtils;
use ariba::Ops::PageRequest;

use base qw(ariba::Ops::InstanceTTLPersistantObject);

my $backingStoreDir = ariba::Ops::Constants->pagedir() . "/pagefilter-storage";

my $unique = 0;

# class methods
sub dir {
    my $class = shift;

    return $backingStoreDir;
}

sub isCurrentlyFilteringAnyOf {
    my $class = shift;
    my $product = shift;
    my $service = shift;
    my $customer = shift;
    my $cluster = shift;

    # this is a quick way for a program like VM to know
    # if a product, service, and or customer is filtered.
    # some of these can be undef

    #XXX this is almost a hack

    my $pr = ariba::Ops::PageRequest->newWithError(
        undef, $product, $service, undef, $customer, $cluster, undef, undef
    );

    return $class->doesPageRequestMatchAnyFilter($pr);
}

sub doesPageRequestMatchAnyFilter {
    my $class = shift;
    my $pageRequest = shift;

    # this is *expensive* !

    my @filters = $class->listObjects();

    for my $filter ( @filters ) {
        if ( $filter->matchesPageRequest($pageRequest) ) {
            return 1;
        }
    }
    return 0;
}

sub newWithDetails {
    my $class = shift;
    my $ttl = shift;
    my $sendingProgram = shift;
    my $product = shift;
    my $service = shift;
    my $customer = shift;
    my $text = shift;
    my $note = shift;
    my $startEpoch = shift;
    my $user = shift;

    my $time = $startEpoch || time(); # if start time is supplied, use it. otherwise current time.
    my $pid  = $$;
    my $host = ariba::Ops::NetworkUtils::hostname();

    my $instanceName = "pagefilter-" . $unique++ . "-" . $host . "-" . $pid . "-" . $time;

    my $self = $class->SUPER::new($instanceName);

    $self->setCreationTime($time);
    $self->setTtl($ttl);
    
    if ($sendingProgram) {
        $sendingProgram =~ s/[[:cntrl:]]+$//;
        # add quotes to protect against leading/trailing whitespace
        $self->setSendingProgram('"' . quotemeta($sendingProgram) . '"');
    }
    $self->setProduct($product) if $product;
    $self->setService($service) if $service;
    $self->setCustomer($customer) if $customer;
    if ($text) {
        $text =~ s/[[:cntrl:]]+$//;
        # add quotes to protect against leading/trailing whitespace
        $self->setText('"' . quotemeta($text) . '"');
    }
    $self->setNote($note) if $note;
    $self->setUser($user) if $user;

    return $self;
}

sub matchesPageRequest {
    my $self = shift;
    my $pageRequest = shift;

    # if filter has not started, it will not match
    return 0 unless ( $self->hasFilterStarted() );

    for my $attr ( 'product', 'service', 'customer' ) {
        my $val = $self->attribute($attr);

        next unless ($val);

        my $prval = $pageRequest->attribute($attr);

        return 0 unless($prval);

        unless ( $val eq $prval ) {
            return 0;
        }
        
    }

    my $sendingProgram = $self->sendingProgram();
    # remove the quotes added in newWithDetails
    $sendingProgram =~ s/^"(.*)"$/$1/;
    my $prsendingProgram = $pageRequest->sendingProgram();
    
    if ( $sendingProgram && $prsendingProgram ) {
        unless ( $prsendingProgram =~ /$sendingProgram/i ) {
            return 0;
        }
    }

    my $text = $self->text();
    # remove the quotes added in newWithDetails
    $text =~ s/^"(.*)"$/$1/;
    my $prsubject = $pageRequest->subject() || "";
    my $prbody = $pageRequest->body() || "";
        my $searchString = $prsubject . $prbody;

        if ( $text ) {
        unless ($searchString && $searchString =~ /$text/si) {
            return 0;
        }
    }

    return 1;
}

sub objectsWithProperties {
    my $class = shift; 
    my %fieldMatchMap = @_; 

    my @quotedFields = qw(text sendingProgram);

    foreach my $field (@quotedFields) {
        $fieldMatchMap{$field} = '"' . $fieldMatchMap{$field} . '"' if ($fieldMatchMap{$field});
    }

    return $class->SUPER::objectsWithProperties(%fieldMatchMap);
}

#    FUNCTION: checks if a filter has started or not
#   ARGUMENTS: none, other than implicit PageFilter object
#     RETURNS: 1 if filter has started, 0 otherwise
sub hasFilterStarted {
    my $self = shift;
    my $creationTime = $self->creationTime();

    return 0 unless ( defined $creationTime && $creationTime =~ /^\d+$/ ); # not sure if we ever hit this case; precautionary
    ( time >= $creationTime ) ? return 1 : return 0; # if current time is greater than creationTime, filter has started
}

1;
