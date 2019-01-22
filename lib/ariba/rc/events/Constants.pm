package ariba::rc::events::Constants;

#
# Event-related constants live here. For each constant defined
# create a static method to access it.
#

use strict;
use warnings;

#
# Version number of event system. Can be used later to differentiate
# between old and modern clients.
#
use constant VERSION => '1.0';

#
# Server returns either success or fail when an event is posted
#
use constant SUCCESS => '1';
use constant FAILURE => '0';

#
# Default number of events to keep in one feed
#
use constant MAX_EVENTS => 50;

#
# Expire feeds older than n days
#
use constant EXPIRE_DAYS => 90;

#
# Defaults for event server URL, RSS directories, path to config file
#
use constant EVENT_SERVER => "http://rc.ariba.com:8080/cgi-bin/rss";
use constant SUBSCRIPTION_SERVER => "http://rc.ariba.com:8080/cgi-bin/subscriptions";
use constant ROOT_URL => "http://rc.ariba.com:8080/rss";
use constant ROOT_DIR => "/home/rc/robotswww/rss";
use constant CONFIG_FILE => "/home/rc/etc/events.xml";
use constant ROBOT_RSS_URL => ROOT_URL . "/robots";

#
# Defaults for e-mail messages
# 
use constant EMAIL_FROM => 'Dept_Release <Dept_Release@ariba.com>';
use constant EMAIL_CONTENT_TYPE => 'text/html';

#
# Defaults for event databases
#
use constant EVENT_DB_FILE => "/home/rc/etc/events.db";
use constant EVENT_DB_TABLE_EVENTS => "events";
use constant SUBSCRIPTION_DB_FILE => "/home/rc/etc/subscriptions.db";

#
# Timeout defaults
#
use constant HTTP_TIMEOUT => 30;
use constant LOCKFILE_TIMEOUT => 5;

#
# Pretty-printed server error strings
#
use constant ERROR_HTTP_POST => "HTTP POST FAIL";
use constant ERROR_EMPTY_RESPONSE => "EMPTY RESPONSE FAIL";
use constant ERROR_SERVER_REPLY => "SERVER REPLY FAIL";

#
# Request channels by name
#
use constant CHANNEL_ALL => "all";
use constant CHANNEL_CRITICAL => "critical";
use constant CHANNEL_DEBUG => "debug";
use constant CHANNEL_UNKNOWN => "unknown";
use constant CHANNEL_ROBOT_STATUS => "robot_status";
use constant CHANNEL_DEPLOYMENT => "deployments";

#
# Channel types
#
use constant CHANNEL_TYPE_RSS => "RSS";
use constant CHANNEL_TYPE_AGGREGATOR => "AGGREGATOR";
use constant CHANNEL_TYPE_EMAIL => "EMAIL";

#
# Miscellaneous values
# 
use constant EVENT_UNSUBSCRIBE_SALT => '20100629';

#
# Static methods
#
sub opml_export_url
{
    return EVENT_SERVER . "?event=export_opml";
}

sub schedule_editor_url
{
    return SUBSCRIPTION_SERVER . "?event=schedule";
}

sub view_all_subscriptions_url
{
    return SUBSCRIPTION_SERVER . "?event=list";
}

sub view_subscriptions_by_channel_url
{
    my ($channel_name) = @_;
    return SUBSCRIPTION_SERVER . "?event=list&channel=$channel_name";
}

sub view_all_categories_url
{
    return EVENT_SERVER . "?event=usage&category=_all";
}

sub view_category_url
{
    my ($category_name) = @_;
    return EVENT_SERVER . "?event=usage&category=$category_name";
}

sub view_channel_url
{
    my ($channel_name) = @_;
    return EVENT_SERVER . "?event=feed&channel=" . $channel_name;
}

sub view_event_url
{
    my ($id, $channel_name) = @_;
    return EVENT_SERVER . "?event=item&id=" . $id . "&channel=" . $channel_name;
}

sub subscribe_url
{
    my ($channel_name) = @_;
    return SUBSCRIPTION_SERVER . "?event=subscribe&channel=" . $channel_name;
}

sub unsubscribe_url
{
    my ($channel_name, $email, $key) = @_;
    return SUBSCRIPTION_SERVER . "?event=unsubscribe&channel=" . $channel_name . "&email=$email&key=$key";
}

sub maillog_url
{
	return SUBSCRIPTION_SERVER . "?event=maillog";
}

sub event_db_file
{
    return EVENT_DB_FILE;
}

sub subscription_db_file
{
    return SUBSCRIPTION_DB_FILE;
}

sub event_db_table_events
{
    return EVENT_DB_TABLE_EVENTS;
}

sub channel_deployment
{
    return CHANNEL_DEPLOYMENT;
}

sub channel_type_email
{
    return CHANNEL_TYPE_EMAIL;
}

sub channel_type_aggregator
{
    return CHANNEL_TYPE_AGGREGATOR;
}

sub channel_type_rss
{
    return CHANNEL_TYPE_RSS;
}

sub config_file
{
    return CONFIG_FILE;
}

sub lockfile_timeout
{
    return LOCKFILE_TIMEOUT;
}

sub http_timeout
{
    return HTTP_TIMEOUT;
}

sub version
{
    return VERSION;
}

sub server
{
    return EVENT_SERVER;
}

sub max_events
{
    return MAX_EVENTS;
}

sub root_dir
{
    return ROOT_DIR;
}

sub root_url
{
    return ROOT_URL;
}

sub robot_rss_url
{
    return ROBOT_RSS_URL;
}

sub success
{
    return SUCCESS;
}

sub failure 
{
    return FAILURE;
}

sub error_http_post
{
    return ERROR_HTTP_POST;
}

sub error_empty_response
{
    return ERROR_EMPTY_RESPONSE;
}

sub error_server_reply
{
    return ERROR_SERVER_REPLY;
}

sub channel_all
{
    return CHANNEL_ALL;
}

sub channel_debug
{
    return CHANNEL_DEBUG;
}

sub channel_unknown
{
    return CHANNEL_UNKNOWN;
}

sub channel_critical
{
    return CHANNEL_CRITICAL;
}

sub channel_robot_status
{
    return CHANNEL_ROBOT_STATUS;
}

sub email_content_type
{
    return EMAIL_CONTENT_TYPE;
}

sub email_from
{
    return EMAIL_FROM;
}

sub salt
{
    return EVENT_UNSUBSCRIBE_SALT;
}

sub expire_days
{
    return EXPIRE_DAYS;
}
1;
