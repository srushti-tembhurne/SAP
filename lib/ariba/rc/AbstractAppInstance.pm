package ariba::rc::AbstractAppInstance;

# $Id: //ariba/services/tools/lib/perl/ariba/rc/AbstractAppInstance.pm#24 $

use strict;
use base qw(ariba::Ops::PersistantObject);
use ariba::rc::Globals;
use ariba::Ops::Constants;


=pod

=head1 NAME

AbstractAppInstance

=head1 VERSION

$Id: //ariba/services/tools/lib/perl/ariba/rc/AbstractAppInstance.pm#24 $

=head1 DESCRIPTION

Abstract Class for modeling different types of App Instances within the Product API.

=head1 SYNOPSIS

This Class should not be directly consumed. Consult poison control center immediately in case of accidental ingestion.

=cut

# We just need PersistantObject's instance variable magic, not the
# persistence capability. Do the same trick that Url.pm does:

sub dir {
    my $class = shift;

    return undef;
}

sub save {
    my $self = shift;

    return undef;
}

sub recursiveSave {
    my $self = shift;

    return undef;
}

sub remove {
    my $self = shift;

    return undef;
}

=pod
   
=item * $self->url()

Return an URL to access the application. 
Sub classes should override if available.

=cut
   
sub url {
    my $self = shift;

    return undef;
}

=pod
   
=item * $self->monitorStatsURL()

Return an URL to monitor the stats of the application. 
Sub classes should overriden if this feature is available.

=cut
   
sub monitorStatsURL {
    my $self = shift;

    return undef;
}

=pod

=item * $self->isUpResponseRegex() 

Returns a regex string for checkIsUp to validate if the app is up against
the response from the monitorStatsURL() or url().

=cut

sub isUpResponseRegex {
    my $self = shift; 

    return '<xml>.*<monitorStatus>|<xml>\s*<monitorStatus>|You may not perform this action from the machine you are on';
}

=pod

=item * $self->checkIsUp() 

Returns true if the app is up.
If the node is up, isUp is set to true.
It also always sets isUpChecked to true if there is a monitorStatsURL() or url() defined. 

If monitorStatsURL() is defined, it is used, otherwise falls back to url(). 
If neither is defined, no check is performed.

=cut

sub checkIsUp {
    my $self = shift;

    my $url = $self->monitorStatsURL() || $self->url();
    return unless ( $url );

    # doing this outside of this function will break 
    # certain cfengine scripts that do not include this in their path
    require "geturl";

    my $urlTimeout = 30;
    my @output;
    my @errors;

    eval { main::geturl('-e', '-q', '-timeout' => $urlTimeout, '-results' => \@output, '-errors' => \@errors, $url); };

    $self->setIsUpChecked(1);
    $self->setIsUp(0);

    if ( !scalar(@errors) && scalar(@output) ) {
        my $xmlString = join('', @output);
        my $isUpResponseRegex = $self->isUpResponseRegex();  
        if ( defined($isUpResponseRegex) && $xmlString =~ m/$isUpResponseRegex/i ) {
            $self->setIsUp(1);
        }
    }

    return $self->isUp();
}

=pod

=item * canCheckIsUp() 

Returns true if the app can be checked for up / down.

=cut

sub canCheckIsUp {
    my $self = shift; 

    return ($self->monitorStatsURL() || $self->url()) && defined($self->isUpResponseRegex());
}

sub recycleGroup {
    my $self = shift;
    my $m = $self->manager();
    my $allocatedBucketName = 'v3allocated-' . $self->cluster();
    unless($m->{$allocatedBucketName}) {
        $m->{$allocatedBucketName} = 1;
        $m->allocateV3Buckets($self->cluster());
    }
    return $self->SUPER::recycleGroup();
}

# Community is special - return undef if the community is default.
sub community {
    my $self = shift;
    
    return undef if $self->attribute('community') && $self->attribute('community') eq 'default';
    return $self->attribute('community');
}

# This is generic enough that it can be shared.
sub logURL {
    my $self = shift;

    my $host        = $self->host();
    my $productName = $self->productName();

    my $logViewerPort = ariba::Ops::Constants->logViewerPort();
    my $logUrl  = "http://$host:$logViewerPort/lspat/" . 
                    $self->instanceName() .
                    "/" . $self->serviceName() . "/$productName";

    if (ariba::rc::Globals::isASPProduct($productName)) {
        $logUrl .= "/" . $self->customer();
    }

    return $logUrl;
}

# This is generic enough that it can be shared.
sub archivedLogsURL {
    my $self = shift;

    my $url = $self->logURL();
    $url =~ s/lspat/lspatarchive/;
    return $url;
}

# This is generic enough that it can be shared.
sub systemLogsURL {
    my $self = shift;

    my $url = $self->logURL();
    $url =~ s/lspat/lspatsystem/;
    return $url;
}

# Short wrapper methods for our type.
sub _isAppOfClass {
    my $self = shift;
    my $type = shift;

    return $self->isa("ariba::rc::${type}AppInstance") ? 1 : 0;
}

#
# if nightlyRecycle is set to no, always recycle
# else if it's a dispatcher, don't recycle
# else recycle
#
sub needsNightlyRecycle {
    my $self = shift;

    my $needsRecycle = 1;

    # dispatchers don't get recycled
    # However, this can be overridden
    if ($self->isDispatcher()) {
        $needsRecycle = 0;
    }
    
    # 
    # if the instance explicitly sets nightlyrecyle policy,
    # honor it. Default to yes (old behavior)
    # 
    my $nightlyRecycleFlag = $self->nightlyRecycle();
    if (defined($nightlyRecycleFlag)) {
        if (!$nightlyRecycleFlag || $nightlyRecycleFlag eq "no") {
            $needsRecycle = 0;
        } else {
            # explicitly set to override isDispatcher
            $needsRecycle = 1;
        }
    }

    return $needsRecycle;
}

sub isDispatcher {
    my $self = shift;

    #
    # If the appinstance is not being vended via a webserver
    # role, assume it's a dispatcher
    #
    return (!$self->visibleVia());
}

sub isUIApp {
    my $self = shift;

    #
    # If the appinstance is being vended via a webserver
    # role, assume it's a ui app
    #
    return ($self->visibleVia());
}

sub isWOFApp {
    my $self = shift;

    return $self->_isAppOfClass('WOF');
}

sub isJavaApp {
    my $self = shift;

    return $self->_isAppOfClass('Java');
}

sub isPHPApp {
    my $self = shift;

    return $self->_isAppOfClass('PHP');
}

sub isPerlApp {
    my $self = shift;

    return $self->_isAppOfClass('Perl');
}

sub isSpringbootApp {
    my $self = shift;

    return $self->_isAppOfClass('Springboot');
}

sub isWebLogicApp {
    my $self = shift;

    return $self->_isAppOfClass('WebLogic');
}

sub isTomcatApp {
    my $self = shift;

    return $self->_isAppOfClass('Tomcat');
}

sub isOpenOfficeApp {
    my $self = shift;

    return $self->_isAppOfClass('OpenOffice');
}

sub isSeleniumApp {
    my $self = shift;

    return $self->_isAppOfClass('Selenium');
}

sub isAUCSolrApp {
    my $self = shift;

    return $self->_isAppOfClass('AUCSolr');
}

sub isAUCCommunityApp {
    my $self = shift;

    return $self->_isAppOfClass('AUCCommunity');
}

sub supportsRollingRestart {
    my $self = shift;

    #false
    return;
}

=pod

=head1 PUBLIC INSTANCE METHODS

=over 8

=item * appName(), community(), visibleVia(), launchedBy(), etc

These getter methods are the same as the corresponding template definitions in apps.cfg/appflags.cfg

=item * isDispatcher(), isUIApp(), isWOFApp(), isJavaApp(), isWebLogicApp(), isTomcatApp(), isPHPApp(), isPerlApp(), isSpringbootApp().

True/False if an instance is of a specific type.

=back

=head1 SEE ALSO

ariba::rc::Product, ariba::rc::AppInstanceManager

=cut

1;
