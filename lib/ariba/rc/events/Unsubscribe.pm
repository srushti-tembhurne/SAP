package ariba::rc::events::Unsubscribe;

#
# Static methods for generating/validating checksums used by unsubscribe script
#

use strict;
use warnings;
use Digest::MD5 qw (md5_hex);

{
    #
    # Formal method to generate a key from e-mail address
    # and name of RC event channel. 
    #
    sub make_key
    {
        my ($email, $channel_name) = @_;
        return join ":", $email, $channel_name;
    }

	sub validate_key
	{
		my ($email, $channel_name, $key, $salt, $checksum) = @_;
		return validate (make_key ($email, $channel_name), $key, $salt, $checksum);
	}

    sub generate
    {
        my ($key, $salt) = @_;
        return md5_hex ($key . $salt);
    }

    sub validate
    {
        my ($key, $salt, $checksum) = @_;
        return $checksum eq md5_hex ($key . $salt) ? 1 : 0;
    }
};

1;
