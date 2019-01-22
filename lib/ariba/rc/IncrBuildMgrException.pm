package ariba::rc::IncrBuildMgrException;

use strict;
use warnings;
use Data::Dumper;

# IncrBuildMgrException
#
# Defines a class that the IncrBuildMgr instantiates for exceptions including:
# MetaData Validator inconsistancies
# Compiler errors
# Unexpected errors

# Type codes:
my $PKG_TO_COMPS_INDEX_ERROR = "PKG_TO_COMPS_INDEX_ERROR";
my $META_VALIDATOR_ERROR = "META_VALIDATOR_ERROR";
my $COMP_BUILD_ERROR = "COMP_BUILD_ERROR";
my $UNEXPECTED_ERROR = "UNEXPECTED_ERROR";

#
# Constructor
sub new {
    my $class = shift;
    my $componentName = shift;
    my $errorCode = shift;
    my $errorMessage = shift;
    my $detailObject = shift;
    my $self = {};
    bless ($self, $class);

    $self->setComponentName($componentName);
    $self->setErrorCode($errorCode);
    $self->setErrorMessage($errorMessage);
    $self->setDetailObject($detailObject);
    return $self;
}

sub setPkgToCompsIndexError {
    my ($self) = @_;
    $self->{'type'} = $PKG_TO_COMPS_INDEX_ERROR;
}

# Return 1 if this exception is for a package to comps indexing error; else 0
sub isPkgToCompsIndexError {
    my ($self) = @_;

    if ($self->{'type'} eq $PKG_TO_COMPS_INDEX_ERROR) {
        return 1;
    }
    return 0;
}

#
# Input 1: $missingDependencyListRef reference to list of component names that the component depends on yet doesn't declare as being depended upon
sub setMetaValidatorError {
    my ($self, $missingDependencyListRef) = @_;
    $self->{'type'} = $META_VALIDATOR_ERROR;
    $self->{'missingDependencies'} = $missingDependencyListRef;
}

# Returns reference to list of component names that the component depends on yet doesn't declare as being depended upon
sub getMissingDependencies {
    my ($self) = @_;
    return $self->{'missingDependencies'};

}

# Return 1 if this exception is for a metadata validation mismatch; else 0
sub isMetaValidatorError {
    my ($self) = @_;

    if ($self->{'type'} eq $META_VALIDATOR_ERROR) {
        return 1;
    }
    return 0;
}

sub setCompBuildError {
    my ($self) = @_;
    $self->{'type'} = $COMP_BUILD_ERROR;
}

# Return 1 if this exception is for a component build error; else 0
sub isCompBuildError {
    my ($self) = @_;

    if ($self->{'type'} eq $COMP_BUILD_ERROR) {
        return 1;
    }
    return 0;
}

sub setUnexpectedError {
    my ($self) = @_;
    $self->{'type'} = $UNEXPECTED_ERROR;
}

# Return 1 if this exception is for an unexpected error; else 0
sub isUnexpectedError {
    my ($self) = @_;

    if ($self->{'type'} eq $COMP_BUILD_ERROR) {
        return 0;
    }
    if ($self->{'type'} eq $META_VALIDATOR_ERROR) {
        return 0;
    }
    return 1;
}

sub setComponentName {
    my ($self, $componentName) = @_;
    $self->{'componentName'} = $componentName;
}

sub getComponentName {
    my ($self) = @_;
    return $self->{'componentName'};
}

sub setErrorCode {
    my ($self, $errorCode) = @_;
    $self->{'errorCode'} = $errorCode;
}

sub getErrorCode {
    my ($self) = @_;
    return $self->{'errorCode'};
}

sub setErrorMessage {
    my ($self, $errorMessage) = @_;
    $self->{'errorMessage'} = $errorMessage;
}

sub getErrorMessage {
    my ($self) = @_;
    return $self->{'errorMessage'};
}

sub setDetailObject {
    my ($self, $detailObject) = @_;
    $self->{'detailObject'} = $detailObject;
}

sub getDetailObject {
    my ($self) = @_;
    return $self->{'detailObject'};
}

1;
