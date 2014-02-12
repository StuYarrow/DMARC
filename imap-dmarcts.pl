#!/usr/bin/perl

###################################################################
#  Forked by StuY, Jan 2014: github.com/StuYarrow/DMARC
#
#  Brought to you by http://www.techsneeze.com
#  Portions of the script are based on info from:
#  http://eric.lubow.org/2007/perl/mailimapclient/
#  ...as well as John Levine's rddmarc:
#  http://www.taugh.com/rddmarc  
###################################################################

# Always be safe
use strict;
use warnings;

# Use these modules
use Data::Dumper;
use Mail::IMAPClient;
use MIME::Parser;
use MIME::Parser::Filer;
use XML::Simple;
use DBI;
use File::Basename;
use Socket qw(inet_pton AF_INET AF_INET6);

# Script Configuration Options
my $debug = 0;
my $imapserver = 'localhost:143';
my $imapuser = '';
my $imappass = '';
my $mvfolder = 'Inbox.processed';
my $readfolder = 'Inbox';
my $dbname = 'dmarc';
my $dbuser = 'dmarc';
my $dbpass = '';

####################################################################
####################################################################
####################################################################
####################################################################

# Setup connections to servers.

my $imap = Mail::IMAPClient->new( Server  => $imapserver,
                                User    => $imapuser,
                              Password  => $imappass)
        # module uses eval, so we use $@ instead of $!
        or die "IMAP Failure: $@";

my $dbh = DBI->connect("DBI:mysql:database=$dbname",
                            $dbuser, $dbpass)
            or die "Cannot connect to database\n";
####################################################################

   if ($debug == 1) {
   # How many msgs are we going to process
      print "There are ". $imap->message_count($readfolder).
          " messages in the $readfolder folder.\n";
   }

   # Select the mailbox to get messages from
   $imap->select($readfolder)
        or die "IMAP Select Error: $!";

   # Store each message as an array element
   my @msgs = $imap->search('ALL');

   if ($@) {
      die "Error in search: $@\n";
   }

   if (!@msgs) {
      print "No messages found\n";
      exit;
   }

   # Loop through messages
   foreach my $msg (@msgs) {
     if ($debug == 1) {
	print "--------------------------------\n";
	print "The Current Message UID is: ";
	print $imap->message_uid($msg). "\n";
	print "--------------------------------\n";
	
	print $imap->subject($msg). "\n";
	##print $imap->message_string($msg). "\n";
     }
	my $parser = new MIME::Parser;
        $parser->output_dir("/tmp");
	$parser->filer->ignore_filename(1);

        my $ent = $parser->parse_data($imap->message_string($msg));

	my $body = $ent->bodyhandle;
        my $mtype = $ent->mime_type;
        my $subj = $ent->get('subject');

	if ($debug == 1) {
        print " $subj\n";
	print " $mtype\n";
	}
	my $location;
	
	if($mtype eq "application/zip") {
		if ($debug == 1) {
                print "This is a ZIP file \n";
		}

		$location = $body->path;

        } elsif ($mtype eq "multipart/mixed") {
		# at the moment, nease.net messages are multi-part, so we need to breakdown the attachments and find the zip
		if ($debug == 1) {
		print "This is a multipart attachment \n";
		}
		#print Dumper($ent->parts);

		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
                        my $part = $ent->parts($i);
                        my $content_type = $part->mime_type;
 		        
			# Find a zip file to work on...
			if(($part->mime_type eq "application/x-zip-compressed") || ($part->mime_type eq "application/zip") || ($part->mime_type eq "application/gzip")) {
			
				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};

				if ($debug == 1) {
					print $location;
					print "\n";
				}
			} else {
				# Skip the attachment otherwise.
				if($debug == 1) {
					print $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
					print "\n";
				}
				next;
			}
		}
	} else {
		## This is mainly for the random email that might end-up in the inbox, and woult otherwise leave dangling mime parts in /tmp
		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
			if($debug == 1) {	
                        	print $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				print "\n";
			}
                        $ent->parts($i)->{ME_Bodyhandle}->purge;

                }
		next;
	}
		

        if(defined($location)) {
		if ($debug == 1) {
          		print "body is in " . $location . "\n";
		}
        } else {
                next;
        }
	
	# open the zip file and process the XML contained inside.
	my @exts = qw(.gz .zip);
	my ($dir, $name, $ext) = fileparse($location, @exts);
	
	if($ext eq ".zip") {
                open(XML,"unzip -p " . $location . " |")
                                or die "cannot unzip $location";
	}
	elsif($ext eq ".gz") {
		open(XML,"gunzip -c " . $location . " |")
                                or die "cannot gunzip $location";
	}
	else {
		die "unknown archive type $location";
	}
	
        my $xml = "";
	$xml .= $_ while <XML>;
        close XML;

	my $xs = XML::Simple->new();

        my $ref = $xs->XMLin($xml);
        my %xml = %{$ref};
        #print join "\n",keys %xml;
        #print "\n";
        my $from = $xml{'report_metadata'}->{'date_range'}->{'begin'};
        my $to = $xml{'report_metadata'}->{'date_range'}->{'end'};
        my $org = $xml{'report_metadata'}->{'org_name'};
        my $id = $xml{'report_metadata'}->{'report_id'};
        my $domain =  $xml{'policy_published'}->{'domain'};
        # see if already stored
        my ($xorg,$xid) = $dbh->selectrow_array(qq{SELECT org,reportid FROM report WHERE reportid=?}, undef, $id);
        if($xorg) {
                print "Already have $xorg $xid, skipped\n";
		if($body){
                $body->purge;
		}
                $ent->purge;

		# Move Message to processed folder
        	my $newuid = $imap->move($mvfolder, $imap->message_uid($msg))
                or die "Could not move: $@\n";
		
                next;
        }

	my $sql = qq{INSERT INTO report(serial,mindate,maxdate,domain,org,reportid)
                VALUES(NULL,FROM_UNIXTIME(?),FROM_UNIXTIME(?),?,?,?)};
        $dbh->do($sql, undef, $from, $to, $domain, $org, $id)
                        or die "cannot make report" . $dbh->errstr;
        my $serial = $dbh->{'mysql_insertid'} ||  $dbh->{'insertid'};
	if($debug == 1){
        	print " serial $serial ";
	}
        my $record = $xml{'record'};
        sub dorow($$) {
                my ($serial,$recp) = @_;
                my %r = %$recp;

                my $ip = $r{'row'}->{'source_ip'};
                #print "ip $ip\n";
                my $count = $r{'row'}->{'count'};
                my $disp = $r{'row'}->{'policy_evaluated'}->{'disposition'};
                my ($dkim, $dkimresult, $spf, $spfresult, $reason);
                my $rp = $r{'auth_results'}->{'dkim'};
                if(ref $rp eq "HASH") {
                        $dkim = $rp->{'domain'};
                        $dkim = undef if ref $dkim eq "HASH";
                        $dkimresult = $rp->{'result'};
                } else { # array
                        # glom sigs together, report first result
                        $dkim = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"?"": $d } @$rp;
                        $dkimresult = $rp->[0]->{'result'};
                }
                $rp = $r{'auth_results'}->{'spf'};
                if(ref $rp eq "HASH") {
                        $spf = $rp->{'domain'};
                        $spfresult = $rp->{'result'};
                } else { # array
                        # glom domains together, report first result
                        $spf = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"? "": $d } @$rp;
                        $spfresult = $rp->[0]->{'result'};
                }

		                $rp = $r{'row'}->{'policy_evaluated'}->{'reason'};
                if(ref $rp eq "HASH") {
                        $reason = $rp->{'type'};
                } else {
                        $reason = join '/',map { $_->{'type'} } @$rp;
                }
                #print "ip=$ip, count=$count, disp=$disp, r=$reason,";
                #print "dkim=$dkim/$dkimresult, spf=$spf/$spfresult\n";
		
		# What type of IP address?
                my ($nip, $iptype, $ipval);
		if($nip = inet_pton(AF_INET, $ip)) {
	    		$ipval = unpack "N", $nip;
	    		$iptype = "ip";
		} elsif($nip = inet_pton(AF_INET6, $ip)) {
	    		$ipval = "X'" . unpack("H*",$nip) . "'";
	    		$iptype = "ip6";
		} else {
	    		print "??? mystery ip $ip\n";
	    		next;
		}
		
		$dbh->do(qq{INSERT INTO rptrecord(serial,$iptype,rcount,disposition,reason,dkimdomain,dkimresult,spfdomain,spfresult)
		  VALUES(?,$ipval,?,?,?,?,?,?,?)},undef, $serial,$count,$disp,$reason,$dkim,$dkimresult,$spf,$spfresult)
			or die "cannot insert record " . $dbh->{'mysql_error'};
		
		#$dbh->do(qq{INSERT INTO rptrecord(serial,ip,rcount,disposition,reason,dkimdomain,dkimresult,spfdomain,spfresult)
                #  VALUES(?,INET_ATON(?),?,?,?,?,?,?,?)},undef, $serial,$ip,$count,$disp,$reason,$dkim,$dkimresult,$spf,$spfresult)
              	#	or die "cannot insert record " . $dbh->{'mysql_error'};
        }

        if(ref $record eq "HASH") {
		if($debug == 1){
                	print "single record\n";
		}
                dorow($serial,$record);
        } elsif(ref $record eq "ARRAY") {
		if($debug == 1){
                	print "multi record\n";
		}
                foreach my $row (@$record) {
                        dorow($serial,$row);
                }
        } else {
                print "mystery type " . ref($record) . "\n";
        }
	if($body){
		# Purge the temporary file from /tmp
        	$body->purge;
		if($debug == 1){
			print "in body";
		}
	}
        $ent->purge;

	# Move Message to processed folder
	my $newuid = $imap->move($mvfolder, $imap->message_uid($msg))
		or die "Could not move: $@\n"; 
   }

   # Expunge and close the folder
   $imap->expunge($readfolder);
   $imap->close($readfolder);

 # We're all done with IMAP here
 $imap->logout()
