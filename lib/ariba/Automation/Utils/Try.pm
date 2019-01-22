package ariba::Automation::Utils::Try;

use Time::HiRes;

#
# generic harness to retry a subroutine n times
#
# given:
# - number of retries to attempt
# - problem in the form of a regexp that appears in $@
# - reference to a subroutine
#
# then:
# attempt to call the subroutine n times checking
# for the named problem. give up when we have
# reached the maximum # of retries or if an unexpected
# error occurs.
#
# example:
# my $ok = ariba::rc::events::Utils::retry (10, "resource unavailable", sub { whatever });
#
sub retry 
{
    my ($retries, $problem, $func) = @_;

    attempt: 
    {
        my $result;

        # return true if successful
        return 1 if eval { $result = $func->(); 1 };

        # failed: something bad happened other than what we expected
        return 0 unless $@ =~ /$problem/;

        # stop trying
        last attempt if $retries < 1;

        # sleep then try again
        Time::HiRes::sleep (0.1);
        $retries--;
        redo attempt;
    }

    return 0;
}

1;
