package ariba::Automation::autolq::Utilities;

#
# These subroutines are utilities which are independent in their purpose
# 
#############

use ariba::rc::events::client::Event;
use ariba::Automation::autolq::QualManagerController;
use ariba::Automation::autolq::QualManagerHelper;
use MIME::Lite;

# CONSTANTS
#
my $RSS_CHANNEL  = "autolq";
my $CONTROL_DIR = "/home/rc/etc/autolq";
my $MAX_ENTRIES_IN_HISTORY = 30;


#
# reads master password from file under /var/tmp/ in mars
#
sub readMasterPasswordFile {
   my ($pwfile) = @_;

   if ($pwfile) { 
      open(PASSFILE, $pwfile) ||
      die("could not open password file %s: %s", $pwfile, $!);

      while (my $line = <PASSFILE>) {
         chomp($line);
         $password = $line;
      }
      close (PASSFILE);
   }
   return $password;
}


#
# Gets password file from /var/tmp
# File name is in the format : <product>-<service>-cronpwd

sub getMasterPasswordFile {
   my ($product, $service) = @_;
   
   my $passLocation  = "/var/tmp";
   my $password_file = $passLocation ."/". $product ."-". $service ."-cronpwd";
   
   $password_file =~ tr/[A-Z]/[a-z]/;
   
   if(!checkIfFileExists($password_file)) {
      print "\nPassword file : $password_file does not exists !!!\n";
      exit (0);
   }
   return $password_file;
}


#
# To check if the file exists
#
sub checkIfFileExists {
   my $file = shift;

   if(-e "$file") {
      return 1;
   } else {
      return 0;
   }
}


#
# Utility for sending out emails
#
# $from    = From Address
# $to      = To Address
# $cc      = CC list (seperated by semicolon)
# $subject = Single line subject
# $content = \@message (Array of message needs to be passed)
#
sub sendMail {
   my ($from, $to, $cc, $subject, $content) = @_;

   if($from && $to && $subject) {
    #my $msg = MIME::Lite->new(
    #        'From'     => $from,
    #        'To'       => $to,
    #        'Cc'       => $cc || undef,
    #        'Reply-To' => undef,
    #        'Subject'  => $subject,
    #        'Type'     => 'text/html',
    #        'Data'     => $content,
    #        );

			#MIME::Lite->send('smtp', 'phoenix.ariba.com');
			#$msg->send('smtp','phoenix.ariba.com') or print "Error sending message: $!\n";
	#		$msg->send() or print "Error sending message: $!\n";
	#}
     open(MAIL, "| /usr/sbin/sendmail -t") || do {
         print "Could not launch sendmail, $!";
         return 0;
     };
      
      print MAIL "From: AutoLQ <$from>\n";
      print MAIL "To: $to\n";
      print MAIL "Cc: $cc\n" if ($cc);
      print MAIL "Subject: $subject\n";
      print MAIL "\n";
      print MAIL $content;
      print MAIL "\n";
      close(MAIL);
   } else { 
      print "Email could not be sent, please check with RC team\n";
      return 0;
   }

	# Send the RSS event
	sendRSSEvent ($subject,$content);
}


#
# Send event to named channel
#
# $title       = Title for the RSS event
# $description = Array of contents, mostly in HTML format.
#
sub sendRSSEvent {
    my ($title, $description) = @_;

    my $channel = $RSS_CHANNEL;
    my $event   = new ariba::rc::events::client::Event  (
                  {
                    channel     => $channel,
                    title       => $title,
                    description => $description,
                  }
    );
   my $err = $event->publish();
   if ( ! $err) { 
       print "WARNING: Couldn't send RC event: $err" . $event->get_last_error() . "\n";
   }
}

sub getPauseFile
{
	my $key = shift;	
	my $pauseFile = $CONTROL_DIR . "/" . "pause" . $key;
	return $pauseFile;
}

sub getResumeFile
{
    my $key = shift;
    my $resumeFile = $CONTROL_DIR . "/" . "resume" . $key;
    return $resumeFile;
}

sub setPauseFile
{
	my ($key,$user) = @_;
	my $pauseFile = getPauseFile($key);

	my $time = time();	
	open (FILE,">$pauseFile") or return "Unable to open the pause file $pauseFile";
	print FILE $user . "::" . $time;
	close (FILE);

	return "Pause request has been accecpted";
}

sub removePauseFile
{
	my ($key,$user) = @_;
	my $pauseFile = getPauseFile($key);

	my $rc = system ("rm $pauseFile");

	if ($rc == 0 )
	{
		return "Pause file has been removed";
	}
	else
	{
		return "There was an issue in removing the pause file $pauseFile. Please get in touch with ask_rc\@ariba.com";
	}
}

sub setResumeFile
{
	my ($key,$user) = @_;
	my $resumeFile = getResumeFile($key);

    my $time = time();
    open (FILE,">$resumeFile") or return "Unable to open the pause file $pauseFile";
    print FILE $user . "::" . $time;
    close (FILE);

    return "Resume request has been accecpted. It can take upto 5 mins for LQ to resume.";
}

sub getProcessStatus
{
	my $pid = shift;

	my $out = `ps -p $pid h`;
	return 1 if ($out);

	return 0;
}

sub expireOldHistory
{
	my @quals = ariba::Automation::autolq::QualManagerController->listObjects();	
	my @sorted = sort { $b->startTime() <=> $a->startTime()} @quals;	

	while ($#sorted >= $MAX_ENTRIES_IN_HISTORY)
	{
		my $objectToBeExpired = pop (@sorted);
		print "Expiring " . $objectToBeExpired->instance() . "\n";
		$objectToBeExpired->expire();
	}	


}

1;
