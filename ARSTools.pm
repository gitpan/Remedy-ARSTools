###################################################
## ARSTools.pm
## Andrew N. Hicox	<andrew@hicox.com>
##
## A perl wrapper class for ARSPerl
## a nice interface for remedy functions.
###################################################


## global stuff ###################################
package Remedy::ARSTools;
use 5.6.0;
use strict;
require Exporter;

use AutoLoader qw(AUTOLOAD);
use ARS;
use Date::Parse;
use Time::Interval;

#class global vars
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $errstr);
@ISA 		= qw(Exporter);
@EXPORT		= qw(&ParseDBDiary &EncodeDBDiary);
@EXPORT_OK	= qw($VERSION $errstr);
$VERSION	= 1.06;




## new ############################################
sub new {
	
	#take the class name off the arg list, if it's called that way
	shift() if ($_[0] =~/^Remedy/);
	
	#bless yourself, baby!
	my $self = bless({@_});
	
	#the following options are required
	foreach ('Server', 'User', 'Pass'){
		exists($self->{$_}) || do {
			$errstr = $_ . " is a required option for creating an object";
			warn($errstr) if $self->{'Debug'};
			return (undef);
		};
	}
	
	#default options
	$self->{'ReloadConfigOK'} = 1 if ($self->{'ReloadConfigOK'} =~/^\s*$/);
	$self->{'GenerateConfig'} = 1 if ($self->{'GenerateConfig'} =~/^\s*$/);
	$self->{'TruncateOK'}     = 1 if ($self->{'TruncateOK'} =~/^\s*$/);
	$self->{'Port'} = undef if ($self->{'Port'} !~/^\d+/);
	$self->{'DateTranslate'}  = 1 if ($self->{'DateTranslate'} =~/^\s*$/);
	$self->{'TwentyFourHourTimeOfDay'} = 0  if ($self->{'TwentyFourHourTimeOfDay'} =~/^\s*$/);
	
	#default options apply only to ARS >= 1.8001
	$self->{'Language'} = undef if ($self->{'Language'} =~/^\s*$/);
	$self->{'AuthString'} = undef if ($self->{'AuthString'} =~/^\s*$/);
	$self->{'RPCNumber'} = undef if ($self->{'RPCNumber'} =~/^\s*$/);
	
	
	#load config file
	$self->LoadARSConfig() || do {
	        $errstr = $self->{'errstr'};
	        warn ($errstr) if $self->{'Debug'};
	        return (undef);
	};
	
	#get a control token (unless 'LoginOverride' is set)
	unless ($self->{'LoginOverride'}){
		$self->ARSLogin() || do {
			$errstr = $self->{'errstr'};
			warn ($errstr) if $self->{'Debug'};
			return (undef)
		};
	}
	
	#bye, now!
	return($self);
	
}




## LoadARSConfig ##################################
## load the config file with field definitions
sub LoadARSConfig {
	
	my ($self, %p) = @_;
	
	#if the file dosen't exist (or is marked stale), load data from Remedy instead
	if ( (! -e $self->{'ConfigFile'}) || ($self->{'staleConfig'} > 0) ) {
		
		#blow away object's current config (if we have one)
		$self->{'ARSConfig'} = ();
		
		#get a control structure if we don't have one
		$self->ARSLogin();
		
		#if no 'Schemas' defined on object, pull data for all
		if (! $self->{'Schemas'}){
			warn ("getting schema list from server") if $self->{'Debug'};
			@{$self->{'Schemas'}} = ARS::ars_GetListSchema($self->{'ctrl'}) || do {
				$self->{'errstr'} = "LoadARSConfig: can't retrieve schema list (all): " . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
		
		#get field data for each schema
		foreach (@{$self->{'Schemas'}}){
			warn ("getting field list for " . $_) if $self->{'Debug'};
			
			#get field list ...
			(my %fields = ARS::ars_GetFieldTable($self->{'ctrl'}, $_)) || do {
				$self->{'errstr'} = "LoadARSConfig: can't retrieve table data for " . $_ . ": " . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
			
			#get meta-data for each field
			foreach my $field (keys %fields){
				
				#set field id
				$self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'id'} = $fields{$field};
				
				#get meta-data
				(my $tmp = ARS::ars_GetField(
					$self->{'ctrl'},	#control token
					$_,			#schema name
					$fields{$field}		#field id
				)) || do {
					$self->{'errstr'} = "LoadARSConfig: can't get field meta-data for " . $_ . " / " . $field .
					          ": " . $ARS::ars_errstr;
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);		  
				};
				
				
				## NEW HOTNESS (1.02)
				## depending on the C-api version that ARSperl was compiled against, the data we're looking 
				## for may be in one of two locations. We'll check both, and take the one that has data
				if ( defined($tmp->{'dataType'}) ){
					
					## some 1.06 hotness ... stash the field dataType too
					$self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'dataType'} = $tmp->{'dataType'};
					
				        if ($tmp->{'dataType'} eq "enum"){
				                #handle enums
				                $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'enum'} = 1;
				                if (ref($tmp->{'limit'}) eq "ARRAY"){
				                        #found it in the old place
				                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'} = $tmp->{'limit'};
                                                }elsif ( defined($tmp->{'limit'}) && defined($tmp->{'limit'}->{'enumLimits'}) && ( ref($tmp->{'limit'}->{'enumLimits'}->{'regularList'}) eq "ARRAY")){
                                                        #found it in the new place
                                                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'} = $tmp->{'limit'}->{'enumLimits'}->{'regularList'};
                                                        
                                                ## EVEN NEWER HOTNESS (1.04)
                                                ## handle enums with custom value lists
                                                }elsif ( defined($tmp->{'limit'}) && defined($tmp->{'limit'}->{'enumLimits'}) && ( ref($tmp->{'limit'}->{'enumLimits'}->{'customList'}) eq "ARRAY")){
                                                        
                                                        
                                                        ## NEW HOTNESS -- we'll just use a hash 
                                                        ## 'ARSConfig'->{schema}->{fields}->{field}->{'enum'} = 1 (regular enum)
                                                        ## 'ARSConfig'->{schema}->{fields}->{field}->{'enum'} = 2 (custom enum -- use the hash)
                                                        ## the hash will be where the 'vals' array used to be. The string will be the key. The enum will be the value
                                                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'enum'} = 2;
                                                        foreach my $blah (@{$tmp->{'limit'}->{'enumLimits'}->{'customList'}}){
                                                                $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'}->{$blah->{'itemName'}} = $blah->{'itemNumber'};
                                                        }
                                                }else {
                                                        #didn't find it at all
                                                        $self->{'errstr'} = "LoadARSConfig: I can't find the enum list for this field! " . $field . "(" . $fields{$field} . ")";
                                                        warn($self->{'errstr'}) if $self->{'Debug'};
                                                        return (undef);
                                                }
				        }else{
				                #handle everything else (we rolls like that, yo)
				                if ( defined($tmp->{'maxLength'}) && ($tmp->{'maxLength'} =~/^\d+$/)){
				                        #found it in the old place
				                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'length'} = $tmp->{'maxLength'};
                                                }elsif (defined($tmp->{'limit'}) && defined($tmp->{'limit'}->{'maxLength'}) && ($tmp->{'limit'}->{'maxLength'} =~/^\d+$/)) {
                                                        #found it in the new place
                                                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'length'} = $tmp->{'limit'}->{'maxLength'};
                                                }
				        }
                                }else{
                                        $self->{'errstr'} = "LoadARSConfig: I can't find field limit data on this version of the API!";
                                        warn($self->{'errstr'}) if $self->{'Debug'};
                                        return (undef);
                                }
			}
		}
		
		#unset staleConfig flag
		$self->{'staleConfig'} = 0;
		
		
		## new for 1.06, keep Remedy::ARSTools::VERSION in the config, so we can know later if we need to upgrade it
		$self->{'ARSConfig'}->{'__Remedy_ARSTools_Version'} = $Remedy::ARSTools::VERSION;
		
		#now that we have our data, write the file (if we have the flag)
		if ($self->{'GenerateConfig'} > 0){
			require Data::DumpXML;
			my $xml = Data::DumpXML::dump_xml($self->{'ARSConfig'});
			warn("LoadARSConfig: exported field data to XML") if $self->{'Debug'};
			open (CFG, ">" . $self->{'ConfigFile'}) || do {
				$self->{'errstr'} = "LoadARSConfig: can't open config file for writing: " . $!;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return(undef);
			};
			print CFG $xml, "\n";
			close(CFG);
			warn("LoadARSConfig: exported field data to config file: " . $self->{'ConfigFile'}) if $self->{'Debug'};
			
			#we're done here
			return (1);
		}
	
	#otherwise, load it from the file
	}else{
		
		#open config file
		open (CFG, $self->{'ConfigFile'}) || do {
			$self->{'errstr'} = "LoadARSConfig: can't open specified config file: "  . $!;
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
		
		#parse it
		require Data::DumpXML::Parser;
		my $parser = Data::DumpXML::Parser->new();
		eval { $self->{ARSConfig} = $parser->parsestring(join("", <CFG>)); };
		if ($@){
			$self->{'errstr'} = "LoadARSConfig: can't parse config data from file: " . $@;
			warn($self->{'errstr'}) if $self->{'Debug'};
		}
		close (CFG);
		
		#actually just the first element will do ;-)
		$self->{'ARSConfig'} = $self->{'ARSConfig'}->[0];
		
		## new for 1.06 ... upgrade the config if it was created with an earlier version of Remedy::ARSTools
		if ($self->{'ARSConfig'}->{'__Remedy_ARSTools_Version'} < 1.06){
			warn("LoadARSConfig: re-generating config generated with earlier version of Remedy::ARSTools") if $self->{'Debug'};
			$self->{'staleConfig'} = 1;
			$self->LoadARSConfig();
		}
		warn("LoadARSConfig: loaded config from file") if $self->{'Debug'};
		return(1);
	}
}




## ARSLogin #######################################
## if not already logged in ... get ars token.
## this is a sneaky hack to get around perl compiler
## errors thrown on behalf of the function prototypes
## in ARSperl, which change based on the version 
## installed.
sub ARSLogin {
	my $self = shift();
	
	#actually, just distribute the call based on the ARSperl version
	if ($ARS::VERSION < 1.8001){
		return ($self->ARSLoginOld(@_));
	}else{
		return ($self->ARSLoginNew(@_));
	}
}

## Query ###########################################
## return selected fields from records matching the
## given QBE string in the specified schema.
## this is also a sneaky hack to call the correct
## syntax for ars_GetListEntry based on the ARSperl
## version number
sub Query {
	my $self = shift();
	
	#actually, just distribute the call based on the ARSperl version
	if ($ARS::VERSION < 1.8001){
		return ($self->QueryOld(@_));
	}else{
		return ($self->QueryNew(@_));
	}
}
 
 
 
## Destroy ########################################
## log off remedy gracefully and destroy object
sub Destroy {
	my $self = shift();
    ARS::ars_Logoff($self->{ctrl}) if exists($self->{ctrl});
	$self = undef;
	return (1);
}




## True for perl include ##########################
1;



__END__

## AutoLoaded Methods




## CheckFields #####################################
## check the length of each presented field value
## against the remedy field's length in the config
## if we find that we don't have the schema or field
## in the config, refresh it. If we have TruncateOK
## truncate the field values to the remedy field
## length without error. Translate enum values
## to their integers. If we have errors, return
## astring containing (all of) them. If we don't 
## have errors return undef with errstr "ok".
## If we have real errors, return undef with the
## errstr on errstr.
## new for 1.06: convert date, datetime & time_of_day
## values to integers of seconds (which the API wants,
## and will not do for you).
sub CheckFields {
	my ($self, %p) = @_;
	my $errors = ();
	
	#both Fields and Schema are required
	foreach ('Fields', 'Schema'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "CheckFields: " . $_ . " is a required option";
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}

	#set object's default TruncateOK if not set on arg list
	$p{'TruncateOK'} = $self->{'TruncateOK'} if (! exists($p{'TruncateOK'}));
	
	#if we don't "know" the schema
	exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
		
		#if we have 'ReloadConfigOK' in the object ... go for it
		if ($self->{'ReloadConfigOK'} > 0){
			$self->{'staleConfig'} = 1;
			warn("CheckFields: reloading stale config for unknown schema: " . $p{'Schema'}) if $self->{'Debug'};
			$self->LoadARSConfig() || do {
				$self->{'errstr'} = "CheckFields: can't reload config " . $self->{'errstr'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return(undef);
			};
			#if we didn't pick up the schema, barf
			exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
				$self->{'errstr'} = "CheckFields: I don't know the schema: " . $p{'Schema'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
	};
	
	#examine each field for length, enum & datetime conversion
	foreach my $field (keys %{$p{'Fields'}}){
		
		#make sure we "know" the field
		exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}) || do {
			
			#if we have 'ReloadConfigOK' in the object ... go for it
			if ($self->{'ReloadConfigOK'} > 0){
				$self->{'staleConfig'} = 1;
				warn("CheckFields: reloading stale config for unknown field: " . $p{'Schema'} . "/" . $field) if $self->{'Debug'};
				$self->LoadARSConfig() || do {
					$self->{'errstr'} = "CheckFields: can't reload config " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				};
				#if we didn't pick up the field, barf
				exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}) || do {
					$self->{'errstr'} = "CheckFields: I don't know the field: " . $field . " in the schema: " . $p{'Schema'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
		};
		
		#1.06 hotness: check and convert datetime, date & time_of_day
		if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'dataType'} eq "time"){
			
			##straight up epoch conversion, son (if it's not already)
			if ($p{'Fields'}->{$field} !~/^\d{1,10}&/){
				my $epoch = str2time($p{'Fields'}->{$field}) || do {
					$errors .= "CheckFields epoch conversion: cannot convert datetime value: " . $p{'Fields'}->{$field};
					next;
				};
				$p{'Fields'}->{$field} = $epoch;
			}
			
		}elsif($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'dataType'} eq "date"){
			
			##the number of days elapsed since 1/1/4713, BCE (ya rly)
			##note: this will only work with dates > 1 BCE. (sorry, historians with remedy systems).
			if ($p{'Fields'}->{$field} !~/^\d{1,7}$/){
				my $epoch = str2time($p{'Fields'}->{$field}) || do {
					$errors .= "CheckFields epoch conversion: cannot convert datetime value: " . $p{'Fields'}->{$field};
					next;
				};
				my $tmpDate = parseInterval(seconds => $epoch);
				$p{'Fields'}->{$field} = ($tmpDate->{'days'} + 2440588);
			}
			
		}elsif($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'dataType'} eq "time_of_day"){
			
			##the number of seconds since midnight
			##we are going to accept one string format: hh:mm:ss AM/PM
			##otherwise you need to send your own int value 
			$p{'Fields'}->{$field} =~s/\s+//g;
			if ($p{'Fields'}->{$field} =~/(\d{1,2}):(\d{1,2}):(\d{1,2})\s*(A|P)*/i){
				## we got hh:mm:ss A/P
				my ($hours, $minutes, $seconds, $ampm) = ($1, $2, $3, $4);
				
				## if we're in am, the hour must be < 12 (and if it's 12, that's really 0)
				## if we're in pm, the hour must be < 11
				## if we don't have an ampm, then the hour must be < 23
				## minutes and seconds must be < 60 of course.
				
				#handle hours
				if ($ampm =~/^a$/i){
					if ($hours > 12){
						## ERROR: out of range hour value
						$errors .= "CheckFields time-of-day conversion: hour out of range for AM";
						next;
					}elsif ($hours == 12){
						$hours = 0;
					}
				}elsif ($ampm =~/^p$/i){
					if ($hours > 11){
						## ERROR: out of range hour value
						$errors .= "CheckFields time-of-day conversion: hour out of range for PM";
						next;
					}else{
						$hours += 12;
					}
				}elsif ($ampm =~/^\s*$/){
					if ($hours > 23){
						## ERROR: out of range hour value
						$errors .= "CheckFields time-of-day conversion: hour out of range for 24 hour notation";
						next;
					}
				}
				$hours = $hours * 60 * 60;
				#handle minutes
				if ($minutes > 60){
					## ERROR: out of range minutes value
					$errors .= "CheckFields time-of-day conversion: minute value out of range";
					next;
				}else{
					$minutes = $minutes * 60;
				}
				#handle seconds
				if ($seconds > 60){
					## ERROR: out of range seconds value
					$errors .= "CheckFields time-of-day conversion: seconds value out of range";
					next;
				}
				
				#here it is muchacho!
				$p{'Fields'}->{$field} = $hours + $minutes + $seconds;
				
			}elsif($p{'Fields'}->{$field} =~/^(\d{1,5})$/){
				## we got an integer
				my $seconds = $1;
				if ($seconds > 86400){
					## ERROR: out of range integer value
					$errors .= "CheckFields time-of-day: out of range integer second value";
					next;
				}else{
					$p{'Fields'}->{$field} = $seconds;
				}
			}else{
				## ERROR: we have no idea what this is but the API isn't gonna like it
				$errors .= "CheckFields time-of-day: unparseable time-of-day string";
				next;
			}
		}
		
		#1.06 hotness: convert diary fields to strings. This is useful for MergeTicket where we're trying
		#to write an entire diary field at once rather than insert an entry, which the API will do for us
		if (
			($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'dataType'} eq "diary") &&
			(ref($p{'Fields'}->{$field}) eq "ARRAY")
		){
			$p{'Fields'}->{$field} = $self->EncodeDBDiary(Diary => $p{'Fields'}->{$field}) || do {
				$errors .= "CheckFields diary conversion: " . $self->{'errstr'};
				next;
			};
		}
		
		#check length
		if (
			( exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'length'}) ) &&
			( $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'length'} > 0 ) &&
			( length($p{'Fields'}->{$field}) <= $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'length'} )
		){
			#field is too long
			if ($p{'TruncateOK'} > 0){
			$p{'Fields'}->{$field} = substr($p{'Fields'}->{$field}, 0, $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'length'});
			}else{
				$errors .= "CheckFieldLengths: " . $field . "too long (max length is ";
				$errors .= $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'length'} . ")\n";
				next;
			}
		}
		
		#check / translate enum
		if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'enum'} > 0){
		        
			#if the value is given as the enum
			#the thought occurs that some asshat will make an enum field where the values are integers.
			#but for now, whatever ... "git-r-done"
			if ($p{'Fields'}->{$field} =~/^\d+$/){
			
			        #if it's a customized enum list ...
			        if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'enum'} == 2){
			        
                                        #make sure we know it (enum is the hash value, string literal is the key)
                                        my $found = 0;
                                        foreach my $chewbacca (keys %{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}}){
                                                if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}->{$chewbacca} eq $p{'Fields'}->{$field}){ 
                                                        $found = 1; 
                                                        last; 
                                                }
                                        }
                                        if ($found == 0){
                                                $errors .= "CheckFieldLengths: " . $field . " enum value is not known (custom enum list)\n";
                                                next;
                                        }
			                
			        #if it's a vanilla linear enum list ...
			        }else{
                                        #make sure the enum's not out of range
                                        if (
                                                ($p{Fields}->{$field} < 0) ||
                                                ($p{Fields}->{$field} > $#{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}})
                                        ){
                                                $errors .= "CheckFieldLengths: " . $field . " enum is out of range\n";
                                                next;
                                        }
                                }
			
			#if the value is given as the string (modified for 1.031)
			}elsif ($p{'Fields'}->{$field} !~/^\s*$/){
				
			        #if it's a custom enum list ...
			        if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'enum'} == 2){
			                #translate it (custom enum lists do not enjoy case-insensitive matching this go-round)
			                if (exists ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}->{$p{'Fields'}->{$field}})){
			                        $p{'Fields'}->{$field} = $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}->{$p{'Fields'}->{$field}};
			                }else{
			                        $errors .= "CheckFieldLengths: " . $field . " given value does not match any enumerated value for this field (custom enum list)\n";
			                        next;
                                        }
			                
                                #if its not ...
                                }else{
                                        #translate it
                                        my $cnt = 0; my $found = 0;
                                        foreach my $val (@{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field}->{'vals'}}){
                                                if ($p{'Fields'}->{$field} =~/^$val$/i){ $p{'Fields'}->{$field} = $cnt; $found = 1; last; }
                                                $cnt ++;
                                        }
                                        
                                        #if we didn't find it
                                        if ($found != 1){
                                                $errors .= "CheckFieldLengths: " . $field . " given value does not match any enumerated value for this field\n";
                                                next;
                                        }
                                }
			}
		}
	}
	
	#if we had errors, return those
	return ($errors) if ($errors);
	
	#if we didn't have any errors, return undef with "ok"
	$self->{'errstr'} = "ok";
	return (undef);
}




## CreateTicket ###################################
## create a new ticket in the given schema with
## the given field values. return the new ticket
## number
sub CreateTicket {
	
	my ($self, %p) = @_;
	
	#both Fields and Schema are required
	foreach ('Fields', 'Schema'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "ModifyTicket: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}

	#set object's default TruncateOK if not set on arg list
	$p{'TruncateOK'} = $self->{'TruncateOK'} if (! exists($p{'TruncateOK'}));
	
	#spew field values in debug
	if ($self->{'Debug'}) {
		my $str = "Field Values Submitted for new ticket in " . $p{'Schema'} . "\n";
		foreach (keys %{$p{'Fields'}}){ $str .= "\t[" . $_ . "]: " . $p{'Fields'}->{$_} . "\n"; }
		warn ($str);
	}
	
	#check the fields
	my $errors = $self->CheckFields( %p ) || do {
		#careful now! if we're here it's either "ok" or a "real error"
		if ($self->{'errstr'} ne "ok"){
			$self->{'errstr'} = "CreateTicket: error on CheckFields: " . $self->{'errstr'};
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	};
	if (length($errors) > 0){
		$self->{'errstr'} = "CreateTicket: error on CheckFields: " . $errors;
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return ($errors);
	}
	
	#ars wants an argument list like ctrl, schema, field_name, field_value ...
	my @args = ();
	
	#insert field list
	foreach (keys %{$p{'Fields'}}){
		push (
			@args,
			($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'},
			$p{'Fields'}->{$_})
		);
	}
	
	#for those about to rock, we solute you!
	my $entry_id = ();
	$entry_id = ARS::ars_CreateEntry( $self->{'ctrl'}, $p{'Schema'}, @args ) || do {
		
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("CreateTicket: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "CreateTicket: failed reload stale login: " . $self->{'errstr'};
				warn ($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
			#try it again
			$entry_id = ARS::ars_CreateEntry( $self->{'ctrl'}, $p{'Schema'}, @args ) || do {
				$self->{'errstr'} = "CreateTicket: can't create ticket in: " . $p{'Schema'} . " / " . $ARS::ars_errstr;
				return (undef);
				warn ($self->{'errstr'}) if $self->{'Debug'};
			};
		}
		$self->{'errstr'} = "CreateTicket: can't create ticket in: " . $p{'Schema'} . " / " . $ARS::ars_errstr;
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	#back at ya, baby!
	return ($entry_id);
}




## ModifyTicket ###################################
sub ModifyTicket{
	
	my ($self, %p) = @_;
	
	#Fields, Schema & Ticket are required
	foreach ('Fields', 'Schema', 'Ticket'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "ModifyTicket: " . $_ . " is a required option";
			return (undef);
		}
	}

	#set object's default TruncateOK if not set on arg list
	$p{'TruncateOK'} = $self->{'TruncateOK'} if (! exists($p{'TruncateOK'}));
	
	#spew field values in debug
	if ($self->{'Debug'}) {
		my $str = "Field Values To Change in " . $p{'Schema'} . "/" . $p{'Ticket'} . "\n";
		foreach (keys %{$p{'Fields'}}){ $str .= "\t[" . $_ . "]: " . $p{'Fields'}->{$_} . "\n"; }
		warn ($str);
	}
	
	#check the fields
	my $errors = ();
	$errors = $self->CheckFields( %p ) || do {
		#careful now! if we're here it's either "ok" or a "real error"
		if ($self->{'errstr'} ne "ok"){
			$self->{'errstr'} = "ModifyTicket: error on CheckFields: " . $errors . " / " . $self->{'errstr'};
			return (undef);
		}
	};
	if (length($errors) > 0){
		$self->{'errstr'} = "ModifyTicket: error on CheckFields: " . $errors . " / " . $self->{'errstr'};
		return (undef);
	}
	
	#ars wants an argument list like ctrl, schema, ticket_no, field, value ...
	my @args = ();
	
	#insert field list
	foreach (keys %{$p{'Fields'}}){
		push (
			@args,
			($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'},
			$p{'Fields'}->{$_})
		);
	}
	
	#it's rockin' like dokken
	ARS::ars_SetEntry( $self->{'ctrl'}, $p{'Schema'}, $p{'Ticket'}, 0, @args ) || do {
		
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("ModifyTicket: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "ModifyTicket: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			ARS::ars_SetEntry( $self->{'ctrl'}, $p{'Schema'}, $p{'Ticket'}, @args ) || do {
				$self->{'errstr'} = "ModifyTicket: can't modify : " . $p{'Schema'} . " / " .
				                    $p{'Ticket'} . ": " . $ARS::ars_errstr;
				return (undef);
			};
		}
		$self->{'errstr'} = "ModifyTicket: can't modify : " . $p{'Schema'} . " / " .
				            $p{'Ticket'} . ": " . $ARS::ars_errstr;
		return (undef);
	};
	
	#the sweet one-ness of success!
	return (1);
}




## DeleteTicket ###################################
## delete the ticket from remedy
## obviously if your user dosen't have admin rights
## this is going to fail.
sub DeleteTicket {
	my ($self, %p) = @_;
	
	#both Fields and Schema are required
	foreach ('Ticket', 'Schema'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "DeleteTicket: " . $_ . " is a required option";
			return (undef);
		}
	}
	
	#dirty deeds, done ... well dirt cheap, really
	ARS::ars_DeleteEntry( $self->{'ctrl'}, $p{'Schema'}, $p{'Ticket'} ) || do {
		
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("DeleteTicket: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "DeleteTicket: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			ARS::ars_DeleteEntry( $self->{'ctrl'}, $p{'Schema'}, $p{'Ticket'} ) || do {
				$self->{'errstr'} = "DeleteTicket: can't delete: " . $p{'Schema'} . " / " . 
				                    $p{'Ticket'} . ": " .$ARS::ars_errstr;
				return (undef);
			};
		}
		$self->{'errstr'} = "DeleteTicket: can't delete: " . $p{'Schema'} . " / " . 
				            $p{'Ticket'} . ": " .$ARS::ars_errstr;
		return (undef);
	};
	
	#buh bye, now!
	return (1);
}
 
 
## EncodeDBDiary #####################################
## this is the inverse of ParseDBDiary. This will take
## a perl data structure, the likes of which is returned
## by ParseDBDiary or Query (when returning a diary field)
## and it will output a formatted text field suitable for
## manually inserting directly into a database table,
## also for setting a diary field with MergeTicket (though
## Remedy::ARSTools will call this for you out of CheckFields
## if you send an array of hashes on a diary field value).
sub EncodeDBDiary {
	
	## as with ParseDBDiary, this is also exported procedural
	## for your git-r-done pleasure
	my ($self, %p) = ();
	if (ref($_[0]) eq "Remedy::ARSTools"){
		#oo mode
		($self, %p) = @_;
	}else{
		#procedural mode
		$self = bless({});
		%p = @_;
	}
	
	my ($record_separator, $meta_separator) = (chr(03), chr(04));
	my @records = ();
	
	#Diary is the only required option and it must be an array of hashes
	#each containing 'timestamp', 'user' and 'value
	exists($p{'Diary'}) || do {
		$errstr = $self->{'errstr'} = "EncodeDBDiary: 'Diary' is a required option";
		warn($self->{'errstr'}) if $self->{'debug'};
		return (undef);
	};
	if (ref($p{'Diary'}) ne "ARRAY"){
		$errstr = $self->{'errstr'} = "EncodeDBDiary: 'Diary' must be an ARRAY reference";
		warn($self->{'errstr'}) if $self->{'debug'};
		return (undef);
	}
	
	#I guess we otter check that each array element is a hash ref with the required data ...
	foreach my $entry (@{$p{'Diary'}}){
		if (ref($entry) ne "HASH"){
			$errstr = $self->{'errstr'} = "EncodeDBDiary: 'Diary' must be an ARRAY or HASH references";
			warn($self->{'errstr'}) if $self->{'debug'};
			return (undef);
		}
		foreach ('timestamp', 'user', 'value'){ 
			if (! exists($entry->{$_})){
				$errstr = $self->{'errstr'} = "EncodeDBDiary: 'Diary' contains incomplete records!";
				warn($self->{'errstr'}) if $self->{'debug'};
				return (undef);
			}
		}
	}
	
	#let's do this ... sort the thang in reverse chronological order, build a string for each
	#entry then join the whole thang with the record separator. and return it
	@{$p{'Diary'}} = sort{ $a->{'timestamp'} <=> $b->{'timestamp'} } @{$p{'Diary'}};
	my @skrangz = ();
	foreach my $entry (@{$p{'Diary'}}){
		
		#if 'timestamp' is not an integer ...
		if ($entry->{'timestamp'} !~/^\d{1,10}$/){
			$entry->{'timestamp'} = str2time($entry->{'timestamp'}) || do {
				$errstr = $self->{'errstr'} = "EncodeDBDiary: contains an entry with an unparseable 'timestamp': " . $entry->{'timestamp'};
				warn($self->{'errstr'}) if $self->{'debug'};
				return (undef);
			};
		}
		
		my $tmp = join($meta_separator, $entry->{'timestamp'}, $entry->{'user'}, $entry->{'value'});
		push(@skrangz, $tmp);
	}
	my $big_diary_string = join($record_separator, @skrangz);
	return($big_diary_string . $record_separator); 		## <-- yeah it always sticks one at the end for some reason
}

  

## ParseDBDiary #####################################
## this will parse a raw ARS diary field as it appears
## in the underlying database into the same data 
## structure returned ARS::getField. To refresh your 
## memory, that's: a sorted array of hashes, each hash
## containing a 'timestamp','user', and 'value' field.
## The date is converted to localtime by default, to 
## override, sent 1 on the -OverrideLocaltime option the
## array is sorted by date. This is a non OO version so
## that it can be called by programs which don't need to
## make an object (i.e. actually talk to a remedy server).
## If you are using this module OO, you can call the
## ParseDiary method, which is essentially an OO wrapper
## for this method. Errors are on $Remedy::ARSTools::errstr.
sub ParseDBDiary {
	
	#this is exported procedural, as well as an OO method
	my ($self, %p) = ();
	if (ref($_[0]) eq "Remedy::ARSTools"){
		#oo mode
		($self, %p) = @_;
	}else{
		#procedural mode
		$self = bless({});
		%p = @_;
	}
		
	my ($record_separator, $meta_separator) = (chr(03), chr(04));
	my @records = ();
	
	exists($p{'Diary'}) || do {
		$errstr = $self->{'errstr'} = "ParseDBDiary: 'Diary' is a required option";
		warn($self->{'errstr'}) if $self->{'debug'};
		return (undef);
	};
	
	#we expect at least 'Diary' and possibly 'ConvertDate'
	
	#if we got DateConversionTimeZone, sanity check it
	if ($p{'DateConversionTimeZone'} !~/^\s*$/){
		if ($p{'DateConversionTimeZone'} =~/(\+|\-)(\d{1,2})/){
			($p{'plusminus'}, $p{'offset'}) = ($1, $2);
			if ($p{'offset'} > 24){
				$self->{'errstr'} = "ParseDBDiary: 'DateConversionTimeZone' is out of range (" . $p{'DateConversionTimeZone'} . ")";
				warn ($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			}
		}else{
			$self->{'errstr'} = "ParseDBDiary: 'DateConversionTimeZone' is unparseable (" . $p{'DateConversionTimeZone'} . ")";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#it might be one record with no separator
	if ($p{'Diary'} !~/$record_separator/){
		
		#we need at least one meta_separator though
		if ($p{'Diary'} !~/$meta_separator/){
			$errstr = $self->{'errstr'} = "ParseDBDiary: non-null diary contains malformed record";
			warn($self->{'errstr'}) if $self->{'debug'};
			return(undef);
		};
		
		#otherwise, just put it on the records stack
		push (@records, $p{'Diary'});
	
	}else{
		
		#do the split
		@records = split(/$record_separator/, $p{'Diary'});
	
	}
		
	#parse the entries
	foreach (@records){
		my ($timestamp, $user, $value) = split(/$meta_separator/, $_);
		
		#if 'ConvertDate' and 'DateConversionTimeZone' are set, do the math
		if ($p{'ConvertDate'} > 0) {
		
			if ($p{'DateConversionTimeZone'} !~/^\s*$/){
				if ($p{'plusminus'} eq "+"){
					$timestamp += ($p{'offset'} * 60 * 60);
				}elsif ($p{'plusminus'} eq "-"){
					$timestamp -= ($p{'offset'} * 60 * 60);
				}
			}
			
			#convert that thang to GMT
			$timestamp = gmtime($timestamp);
			$timestamp .= "GMT";
			
			#tack on the offset if we had one
			if ($p{'DateConversionTimeZone'} !~/^\s*$/){
				$p{'offset'} = sprintf("%02d", $p{'offset'});
				$timestamp .= " " . $p{'plusminus'} . $p{'offset'} . "00";
			}
		}
		
		#put it back on the stack as a hash reference
		$_ = {
			'timestamp'	=> $timestamp,
			'user'		=> $user,
			'value'		=> $value
		}
	}
	
	#make sure we're sorted by date
	@records  = sort{ $a->{'timestamp'} <=> $b->{'timestamp'} } @records;
	
	#send 'em back
	return (\@records);
}



## ARSLoginOld ####################################
## for ARSPerl installs < 1.8001
sub ARSLoginOld {
	
	my ($self, %p) = @_;
	
	#return if already logged in and not marked stale
	if ( (exists($self->{'ctrl'})) && ($self->{'staleLogin'} != 1) ){ return(1); }
	
	#if it's a stale login, try to logoff first
	if ( (exists($self->{'ctrl'})) && ($self->{'staleLogin'} = 1) ){ ARS::ars_Logoff($self->{'ctrl'}); }
	
	#if we have Port, set it in the environment, otherwise delete it in the environment
	if ($self->{'Port'} =~/\d+/){ $ENV{'ARTCPPORT'} = $self->{'Port'}; }else{ delete($ENV{'ARTCPPORT'}); }
	
	#get a control structure
	$self->{'ctrl'} = ARS::ars_Login(
		$self->{'Server'},
		$self->{'User'},
		$self->{'Pass'}
	) || do {
		$self->{'errstr'} = "ARSLoginOld: can't login to remedy server: " . $ARS::ars_errstr;
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	#debug
	warn("ARSLoginOld: logged in " . $self->{'Server'} . ":" . $self->{'Port'} . " " . $self->{'User'}) if $self->{'Debug'};
	
	#unset stale login
	$self->{'staleLogin'} = 0;

	#it's all good baby bay bay ...
	return (1); 
}




## ARSLoginNew ####################################
## for ARSperl installs >= 1.8001
sub ARSLoginNew {
my ($self, %p) = @_;
	
	#return if already logged in and not marked stale
	if ( (exists($self->{'ctrl'})) && ($self->{'staleLogin'} != 1) ){ return(1); }
	
	#if it's a stale login, try to logoff first
	if ( (exists($self->{'ctrl'})) && ($self->{'staleLogin'} = 1) ){ ARS::ars_Logoff($self->{'ctrl'}); }
	
	#get a control structure
	$self->{'ctrl'} = ARS::ars_Login(
		$self->{'Server'},
		$self->{'User'},
		$self->{'Pass'},
		$self->{'Language'},
		$self->{'AuthString'},
		$self->{'Port'},
		$self->{'RPCNumber'}
	) || do {
		$self->{'errstr'} = "ARSLoginNew: can't login to remedy server: " . $ARS::ars_errstr;
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	#debug
	warn("ARSLoginNew: logged in " . $self->{'Server'} . ":" . $self->{'Port'} . " " . $self->{'User'}) if $self->{'Debug'};
	
	#unset stale login
	$self->{'staleLogin'} = 0;

	#it's all good baby bay bay ...
	return (1); 
}




## QueryOld #######################################
## issue a query through the ARS api using the 
## QBE ("query by example") string
## NOTE: this is NOT the same thing as an SQL
## 'where' clause. Also NOTE: that this will present
## significantly more overhead than directly querying
## the database, but I presume you have your reasons ... ;-)
## do it using the pre 1.8001 argument list for ars_getListEntry
sub QueryOld {
	my ($self, %p) = @_;
	
	#QBE, Schema & Fields are required
	foreach ('Fields', 'Schema', 'QBE'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "QueryOld: " . $_ . " is a required option";
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#we need to make sure we 'know' the schema
	exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
		
		#if we have 'ReloadConfigOK' in the object ... go for it
		if ($self->{'ReloadConfigOK'} > 0){
			$self->{'staleConfig'} = 1;
			warn("QueryOld: reloading stale config for unknown schema: " . $p{'Schema'}) if $self->{'Debug'};
			$self->LoadARSConfig() || do {
				$self->{'errstr'} = "QueryOld: can't reload config " . $self->{'errstr'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return(undef);
			};
			#if we didn't pick up the schema, barf
			exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
				$self->{'errstr'} = "QueryOld: I don't know the schema: " . $p{'Schema'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
	};
	
	#get field list translated to field_id
	my @get_list = ();
	my %revMap   = ();
	foreach (@{$p{'Fields'}}){
		
		#make sure we "know" the field
		exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
			
			#if we have 'ReloadConfigOK' in the object ... go for it
			if ($self->{'ReloadConfigOK'} > 0){
				$self->{'staleConfig'} = 1;
				warn("QueryOld: reloading stale config for unknown field: " . $p{'Schema'} . "/" . $_) if $self->{'Debug'};
				$self->LoadARSConfig() || do {
					$self->{'errstr'} = "QueryOld: can't reload config " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				};
				#if we didn't pick up the field, barf
				exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
					$self->{'errstr'} = "QueryOld: I don't know the field: " . $_ . " in the schema: " . $p{'Schema'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
		};
		
		#put field_id in the get_list
		push (@get_list, $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'});
		
		#also make a hash based on device_id (to re-encode results)
		$revMap{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'}} = $_;
	}
	
	#qualify the query
	my $qual = ();
	$qual = ARS::ars_LoadQualifier($self->{'ctrl'}, $p{'Schema'}, $p{'QBE'}) || do {
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("QueryOld: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "QueryOld: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			$qual = ARS::ars_LoadQualifier($self->{'ctrl'}, $p{'Schema'}, $p{'QBE'}) || do {
				$self->{'errstr'} = "QueryOld: can't qualify Query: " . $p{'Schema'} . " / " .
				                    $p{'QBE'} . "/" . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
		$self->{'errstr'} = "QueryOld: can't qualify Query: " . $p{'Schema'} . " / " .
		$p{'QBE'} . "/" . $ARS::ars_errstr;
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	#okay now we get the list of record numbers ...
	my %tickets = ();
	(%tickets = ARS::ars_GetListEntry($self->{'ctrl'}, $p{'Schema'}, $qual, 0)) || do {
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("QueryOld: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "QueryOld: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			(%tickets = ARS::ars_GetListEntry($self->{'ctrl'}, $p{'Schema'}, $qual, 0)) || do {
				$self->{'errstr'} = "QueryOld: can't get ticket list: " . $p{'Schema'} . " / " .
				                    $p{'QBE'} . "/" . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
		
		if (! $ARS::ars_errstr){
			$self->{'errstr'} = "QueryOld: no matching records";
		}else{
			$self->{'errstr'} = "QueryOld: can't get ticket list: " . $p{'Schema'} . " / " .
			$p{'QBE'} . "/" . $ARS::ars_errstr;
		}
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	if ($self->{'Debug'}){
		my $num = keys(%tickets);
		warn ($num . " matching records") if $self->{'Debug'};
	}
	
	#and now, finally, we go and get the selected fields out of each ticket
	my @out = ();
	foreach (keys %tickets){
		my %values = ();
		(%values = ARS::ars_GetEntry($self->{'ctrl'}, $p{'Schema'}, $_, @get_list)) || do {
			#if it was an ARERR 161 (staleLogin), reconnect and try it again
			if ($ARS::ars_errstr =~/ARERR \#161/){
				warn("QueryOld: reloading stale login") if $self->{'Debug'};
				$self->{'staleLogin'} = 1;
				$self->ARSLogin() || do {
					$self->{'errstr'} = "QueryOld: failed reload stale login: " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
				#try it again
				(%values = ARS::ars_GetEntry($self->{'ctrl'}, $p{'Schema'}, $_, @get_list)) || do {
					$self->{'errstr'} = "QueryOld: can't get ticket fields: " . $p{'Schema'} . " / " .
										$p{'QBE'} . "/" . $_ . ": " . $ARS::ars_errstr;
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
			$self->{'errstr'} = "QueryOld: can't get ticket fields: " . $p{'Schema'} . " / " .
			$p{'QBE'} . "/" . $_ . ": " . $ARS::ars_errstr;
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
		
		#translate field names & enums back to human-readable 
		my $converted_row_data = $self->ConvertFieldsToHumanReadable(
			Schema			=> $p{'Schema'},
			Fields			=> \%values,
			DateConversionTimeZone	=> $p{'DateConversionTimeZone'}
		) || do {
			$self->{'errstr'} = "QueryOld: can't convert data returned on API (this should not happen!): " . $self->{'errstr'};
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
		
		#push it on list of results
		push (@out, $converted_row_data);
		
		#push it on list of results
		push (@out, \%values);
	}
	
	#return the list of results
	return (\@out);
}


## QueryNew #######################################
## issue a query through the ARS api using the 
## QBE ("query by example") string
## NOTE: this is NOT the same thing as an SQL
## 'where' clause. Also NOTE: that this will present
## significantly more overhead than directly querying
## the database, but I presume you have your reasons ... ;-)
## do it with post 1.8001 ars_getListEntry argument list
sub QueryNew {
	my ($self, %p) = @_;
	
	#QBE, Schema & Fields are required
	foreach ('Fields', 'Schema', 'QBE'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "QueryNew: " . $_ . " is a required option";
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#we need to make sure we 'know' the schema
	exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
		
		#if we have 'ReloadConfigOK' in the object ... go for it
		if ($self->{'ReloadConfigOK'} > 0){
			$self->{'staleConfig'} = 1;
			warn("QueryNew: reloading stale config for unknown schema: " . $p{'Schema'}) if $self->{'Debug'};
			$self->LoadARSConfig() || do {
				$self->{'errstr'} = "QueryNew: can't reload config " . $self->{'errstr'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return(undef);
			};
			#if we didn't pick up the schema, barf
			exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
				$self->{'errstr'} = "QueryNew: I don't know the schema: " . $p{'Schema'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
	};
	
	#get field list translated to field_id
	my @get_list = ();
	my %revMap   = ();
	foreach (@{$p{'Fields'}}){
		
		#make sure we "know" the field
		exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
			
			#if we have 'ReloadConfigOK' in the object ... go for it
			if ($self->{'ReloadConfigOK'} > 0){
				$self->{'staleConfig'} = 1;
				warn("QueryNew: reloading stale config for unknown field: " . $p{'Schema'} . "/" . $_) if $self->{'Debug'};
				$self->LoadARSConfig() || do {
					$self->{'errstr'} = "QueryNew: can't reload config " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				};
				#if we didn't pick up the field, barf
				exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
					$self->{'errstr'} = "QueryNew: I don't know the field: " . $_ . " in the schema: " . $p{'Schema'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
		};
		
		#put field_id in the get_list
		push (@get_list, $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'});
		
		#also make a hash based on device_id (to re-encode results)
		$revMap{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'}} = $_;
	}
	
	#qualify the query
	my $qual = ();
	$qual = ARS::ars_LoadQualifier($self->{'ctrl'}, $p{'Schema'}, $p{'QBE'}) || do {
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("QueryNew: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "QueryNew: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			$qual = ARS::ars_LoadQualifier($self->{'ctrl'}, $p{'Schema'}, $p{'QBE'}) || do {
				$self->{'errstr'} = "QueryNew: can't qualify Query: " . $p{'Schema'} . " / " .
				                    $p{'QBE'} . "/" . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
		$self->{'errstr'} = "QueryNew: can't qualify Query: " . $p{'Schema'} . " / " .
		$p{'QBE'} . "/" . $ARS::ars_errstr;
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	#okay now we get the list of record numbers ...
	my %tickets = ();
	(%tickets = ARS::ars_GetListEntry($self->{'ctrl'}, $p{'Schema'}, $qual, 0, 0)) || do {
		#if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("QueryNew: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "QueryNew: failed reload stale login: " . $self->{'errstr'};
				return (undef);
			};
			#try it again
			(%tickets = ARS::ars_GetListEntry($self->{'ctrl'}, $p{'Schema'}, $qual, 0, 0)) || do {
				$self->{'errstr'} = "QueryNew: can't get ticket list: " . $p{'Schema'} . " / " .
				                    $p{'QBE'} . "/" . $ARS::ars_errstr;
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
		
		if (! $ARS::ars_errstr){
			$self->{'errstr'} = "QueryNew: no matching records";
		}else{
			$self->{'errstr'} = "QueryNew: can't get ticket list: " . $p{'Schema'} . " / " .
			$p{'QBE'} . "/" . $ARS::ars_errstr;
		}
		warn($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	if ($self->{'Debug'}){
		my $num = keys(%tickets);
		warn ($num . " matching records") if $self->{'Debug'};
	}
	
	#and now, finally, we go and get the selected fields out of each ticket
	my @out = ();
	foreach (keys %tickets){
		my %values = ();
		(%values = ARS::ars_GetEntry($self->{'ctrl'}, $p{'Schema'}, $_, @get_list)) || do {
			#if it was an ARERR 161 (staleLogin), reconnect and try it again
			if ($ARS::ars_errstr =~/ARERR \#161/){
				warn("QueryNew: reloading stale login") if $self->{'Debug'};
				$self->{'staleLogin'} = 1;
				$self->ARSLogin() || do {
					$self->{'errstr'} = "QueryNew: failed reload stale login: " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
				#try it again
				(%values = ARS::ars_GetEntry($self->{'ctrl'}, $p{'Schema'}, $_, @get_list)) || do {
					$self->{'errstr'} = "QueryNew: can't get ticket fields: " . $p{'Schema'} . " / " .
										$p{'QBE'} . "/" . $_ . ": " . $ARS::ars_errstr;
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
			$self->{'errstr'} = "QueryNew: can't get ticket fields: " . $p{'Schema'} . " / " .
			$p{'QBE'} . "/" . $_ . ": " . $ARS::ars_errstr;
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
		
		my $converted_row_data = $self->ConvertFieldsToHumanReadable(
			Schema			=> $p{'Schema'},
			Fields			=> \%values,
			DateConversionTimeZone	=> $p{'DateConversionTimeZone'}
		) || do {
			$self->{'errstr'} = "QueryNew: can't convert data returned on API (this should not happen!): " . $self->{'errstr'};
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
		
		#push it on list of results
		push (@out, $converted_row_data);
		
	}
	
	#return the list of results
	return (\@out);
}

## MergeTicket ###################################
## just like CreateTicket, but a Merge transaction
## Fields                       list o' fields (same as CreateTicket)
## Schema                       target form for the transaction (same as CreateTicket)
## MergeCreateMode              specifies how to handle record creation if the specified entry-id (fieldid 1) value exists"
##      'Error'                 -- throw an error
##      'Create'                -- spawn new (different) entry-id value
##      'Overwrite'             -- overwrite the existing entry-id
## AllowNullFields              (default false) if set true, allows the merge transaction to bypass required non-null fields
## SkipFieldPatternCheck        (default false) if set true, allows the merge transaction to bypass field pattern checking
sub MergeTicket {
        
        my ($self, %p) = @_;
	
	#Fields, Schema, MergeMode are required
	foreach ('Fields', 'Schema', 'MergeCreateMode'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "MergeTicket: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#handle MergeMode
	my $arsMergeCode = 0;
	if ($p{'MergeCreateMode'} eq "Error"){
	        $arsMergeCode += 1;
        }elsif ($p{'MergeCreateMode'} eq "Create"){
                $arsMergeCode += 2;
        }elsif ($p{'MergeCreateMode'} eq "Overwrite"){
                $arsMergeCode += 3;
        }else{
                $self->{'errstr'} = "MergeTicket: " . $_ . " unknown Merge mode: options are Error, Create, Overwrite";
                warn ($self->{'errstr'}) if $self->{'Debug'};
                return (undef);
        }
        
        #handle AllowNullFields
        if ($p{'AllowNullFields'} !~/^\s*$/){
                $arsMergeCode += 1024;
        }
        
        #handle SkipFieldPatternCheck
        if ($p{'SkipFieldPatternCheck'} !~/^\s*$/){
                $arsMergeCode += 2048;
        }

	#set object's default TruncateOK if not set on arg list
	$p{'TruncateOK'} = $self->{'TruncateOK'} if (! exists($p{'TruncateOK'}));
	
	#spew field values in debug
	if ($self->{'Debug'}) {
		my $str = "Field Values Submitted for merged ticket in " . $p{'Schema'} . "\n";
		foreach (keys %{$p{'Fields'}}){ $str .= "\t[" . $_ . "]: " . $p{'Fields'}->{$_} . "\n"; }
		warn ($str);
	}
	
	#check the fields
	my $errors = $self->CheckFields( %p ) || do {
		#careful now! if we're here it's either "ok" or a "real error"
		if ($self->{'errstr'} ne "ok"){
			$self->{'errstr'} = "MergeTicket: error on CheckFields: " . $self->{'errstr'};
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	};
	if (length($errors) > 0){
		$self->{'errstr'} = "MergeTicket: error on CheckFields: " . $errors;
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return ($errors);
	}
	
	#was it over when the Germans bombed Pearl Harbor???!
	if ($self->{'doubleSecretDebug'}) {
                my $str = "field values after translation: " . $p{'Schema'} . "\n";
                foreach (keys %{$p{'Fields'}}){ $str .= "\t[" . $_ . "]: " . $p{'Fields'}->{$_} . "\n"; }
                warn ($str);
                $self->{'errstr'} = "exit for doubleSecretDebug";
                return (undef);
        }
	
	#ars wants an argument list like ctrl, schema, field_name, field_value ...
	my @args = ();
	
	#insert field list
	foreach (keys %{$p{'Fields'}}){
		push (
			@args,
			($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'id'},
			$p{'Fields'}->{$_})
		);
	}
	
	#for those about to rock, we solute you!
	my $entry_id = ();
	$entry_id = ARS::ars_MergeEntry($self->{'ctrl'}, $p{'Schema'}, $arsMergeCode, @args) || do {
	        #if it was an ARERR 161 (staleLogin), reconnect and try it again
		if ($ARS::ars_errstr =~/ARERR \#161/){
			warn("MergeTicket: reloading stale login") if $self->{'Debug'};
			$self->{'staleLogin'} = 1;
			$self->ARSLogin() || do {
				$self->{'errstr'} = "MergeTicket: failed reload stale login: " . $self->{'errstr'};
				warn ($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
			#try it again
			$entry_id = ARS::ars_MergeEntry($self->{'ctrl'}, $p{'Schema'}, $arsMergeCode, @args) || do {
			        
			        ##this thing might legitimately return null
			        if ($ARS::ars_errstr !~/^\s*$/){
                                        $self->{'errstr'} = "MergeTicket: can't merge record in: " . $p{'Schema'} . " / " . $ARS::ars_errstr;
                                        warn ($self->{'errstr'}) if $self->{'Debug'};
                                        return (undef);
                                }
			};
		} elsif ($ARS::ars_errstr !~/^\s*$/){
                        $self->{'errstr'} = "MergeTicket: can't merge record in: " . $p{'Schema'} . " / " . $ARS::ars_errstr;
                        warn ($self->{'errstr'}) if $self->{'Debug'};
                        return (undef);
                } else {
                        warn ("successful merge in overwrite mode") if $self->{'Debug'};
                        $entry_id = "overwritten";
                }
	};
	
	#back at ya, baby!
	return ($entry_id);
}


## ConvertFieldsToHumanReadable #################
## this takes a big hash of field_id -> value pairs
## for a given schema and:
##	1) converts all the field_id values to Field Names for the specified schema
##	2) converts integer-specified enum values to human-readable strings
##	3) converts date, datetime & time_of_day integer values to strings
##	4) converts packed diary fields to the standard diary field structure (see ParseDiary)
## required arguments:
##	'Fields'		=> a hash reference containing field_id => value pairs not unlike what comes out of ars_GetEntry
##	'Schema'		=> the name of the Schema (or "Form" in today's parlance) from whence the 'Fields' data originated
## optional arguments:
##	'DateConversionTimeZone' => number of hours offset from GMT for datetime conversion (default = 0 = GMT)
## on success return a hash reference containing the converted field list 
## else undef + errstr
sub ConvertFieldsToHumanReadable {
	my ($self, %p) = @_;
	
	#Fields and Schema are required
	foreach ('Fields', 'Schema'){ 
		if (! exists($p{$_})){ 
			$self->{'errstr'} = "ConvertFieldsToHumanReadable: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#if we got DateConversionTimeZone, sanity check it
	if ($p{'DateConversionTimeZone'} !~/^\s*$/){
		if ($p{'DateConversionTimeZone'} =~/(\+|\-)(\d{1,2})/){
			($p{'plusminus'}, $p{'offset'}) = ($1, $2);
			if ($p{'offset'} > 24){
				$self->{'errstr'} = "ConvertFieldsToHumanReadable: 'DateConversionTimeZone' is out of range (" . $p{'DateConversionTimeZone'} . ")";
				warn ($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			}
		}else{
			$self->{'errstr'} = "ConvertFieldsToHumanReadable: 'DateConversionTimeZone' is unparseable (" . $p{'DateConversionTimeZone'} . ")";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#yeah ...
	my @month_converter = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @weekday_converter = qw(Sun Mon Tue Wed Thu Fri Sat);
	
	#make sure we 'know' the schema
	exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
		
		#if we have 'ReloadConfigOK' in the object ... go for it
		if ($self->{'ReloadConfigOK'} > 0){
			$self->{'staleConfig'} = 1;
			warn("ConvertFieldsToHumanReadable: reloading stale config for unknown schema: " . $p{'Schema'}) if $self->{'Debug'};
			$self->LoadARSConfig() || do {
				$self->{'errstr'} = "ConvertFieldsToHumanReadable: can't reload config " . $self->{'errstr'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return(undef);
			};
			#if we didn't pick up the schema, barf
			exists($self->{'ARSConfig'}->{$p{'Schema'}}) || do {
				$self->{'errstr'} = "ConvertFieldsToHumanReadable: I don't know the schema: " . $p{'Schema'};
				warn($self->{'errstr'}) if $self->{'Debug'};
				return (undef);
			};
		}
	};
	
	#gonna be easier and faster to make a reverse hash
	my %fieldIDIndex = ();
	foreach my $field_name (keys %{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}}){
		$fieldIDIndex{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'id'}} = $field_name;
	}
	
	#translate field_ids to field_names
	my %translated = ();
	foreach my $field_id (keys %{$p{'Fields'}}){
		#we're either gonna know it and translate it or we're gonna throw an error
		if (exists($fieldIDIndex{$field_id})){
			$translated{$fieldIDIndex{$field_id}} = $p{'Fields'}->{$field_id};
		}else{
			$self->{'errstr'} = "ConvertFieldsToHumanReadable: I don't know the field: '" . $field_id . "' in the schema '" . $p{'Schema'} . "'";
			warn($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#translate date, datetime & time_of_day -> string
	if ($self->{'DateTranslate'} > 0){
		foreach my $field_name (keys %translated){
			
			if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'dataType'} eq "time"){
			
				#apply the GMT offset should we have one
				if ($p{'DateConversionTimeZone'} !~/^\s*$/){
					if ($p{'plusminus'} eq "+"){
						$translated{$field_name} += ($p{'offset'} * 60 * 60);
					}elsif ($p{'plusminus'} eq "-"){
						$translated{$field_name} -= ($p{'offset'} * 60 * 60);
					}
				}
				
				#datetime conversion
				my $gmt_str = gmtime($translated{$field_name}) || do {
					$self->{'errstr'} = "ConvertFieldsToHumanReadable: can't convert epoch integer (" . $translated{$field_name} . ") to GMT time string: " . $!;
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
				$translated{$field_name} = $gmt_str . " GMT";
				if ($p{'DateConversionTimeZone'} !~/^\s*$/){
					$p{'offset'} = sprintf("%02d", $p{'offset'});
					$translated{$field_name} .= " " . $p{'plusminus'} . $p{'offset'} . "00";
				}
				
			}elsif($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'dataType'} eq "date"){
				
				#date ... so convoluted
				#get us back on this side of the first christmas :-/
				$translated{$field_name} -= 2440588;
				my @tmp = gmtime($translated{$field_name} * 86400);
				my $month = $month_converter[$tmp[4]];
				my $year = $tmp[5] + 1900;
				my $weekday = $weekday_converter[$tmp[6]];
				$translated{$field_name} = $weekday . ", " . $month . " " . $tmp[3] . " " . $year;
				
			}elsif($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'dataType'} eq "time_of_day"){
				
				#time_of_day
				my $tmp = parseInterval(seconds => $translated{$field_name}) || do {
					$self->{'errstr'} = "ConvertFieldsToHumanReadable: can't parse time_of_day integer (" .  $translated{$field_name} . ")";
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
				
				#single zero-padding, muchacho!
				foreach ('hours', 'minutes', 'seconds'){ $tmp->{$_} = sprintf("%02d", $tmp->{$_}); }
				
				#ok, and I guess we'll let 'em turn off civilian time conversion if they can dig it
				if ($self->{'TwentyFourHourTimeOfDay'} != 1){
					my $ampm = "AM";
					if ($tmp->{'hours'} > 12){
						$ampm = "PM";
						$tmp->{'hours'} -= 12;
					};
				
					$translated{$field_name} = $tmp->{'hours'} . ":" . $tmp->{'minutes'} . ":" . $tmp->{'seconds'} . " " . $ampm;
				}else{
					$translated{$field_name} = $tmp->{'hours'} . ":" . $tmp->{'minutes'} . ":" . $tmp->{'seconds'};
				}
			}
		}
	}
	
	#translate enum -> string
	foreach my $field_name (keys %translated){
		if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'dataType'} eq "enum"){
			
			if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'enum'} == 2){
			
				# deal with customized non-sequential enum value lists (sheesh, BMC)
				my %inverse = ();
				foreach my $t3 (keys %{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'vals'}}){
					$inverse{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'vals'}->{$t3}} = $t3;
				}
				if (exists($inverse{$translated{$field_name}})){
					$translated{$field_name} = $inverse{$translated{$field_name}};
				}else{
					$self->{'errstr'} = "ConvertFieldsToHumanReadable: non-sequential custom enum list, cannot match enum value (" . $field_name . "/" . $translated{$field_name} . ")";
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				}
			}else{
				# just a straight up array position, as god intended.
				if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'vals'}->[$translated{$field_name}] =~/^\s*$/){
					$self->{'errstr'} = "ConvertFieldsToHumanReadable: sequential custom enum list, cannot match enum value (" . $field_name . "/" . $translated{$field_name} . ")";
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				}else{
					$translated{$field_name} = $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$field_name}->{'vals'}->[$translated{$field_name}];
				}
			}
		}
	}
	
	#send the translated data back
	return(\%translated);
}

## DeleteObjectFromServer #######################
## for chrissakes ... be careful with this one!
## ObjectName	=> "Remedy:ARSTools:CrazyActiveLink",
## ObjectName	=> "active_link"
sub DeleteObjectFromServer {
	my ($self, %p) = @_;
	
	#make sure we got our required and default options, yadda yadda
	foreach ('ObjectName', 'ObjectType'){
		if ((! exists($p{$_})) || ($p{$_} =~/^\s*$/)){
			$self->{'errstr'} = "DeleteObjectFromServer: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	#here we go
	if 	($p{'ObjectType'} =~/^active_link$/i){
		#ars_DeleteActiveLink
		ARS::ars_DeleteActiveLink( $self->{'ctrl'}, $p{'ObjectName'} ) || do {
			$self->{'errstr'} = "DeleteObjectFromServer: failed to delete object from server: " . $ARS::ars_errstr;
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
	}elsif	($p{'ObjectType'} =~/^char_menu$/i){
		#ars_DeleteCharMenu
		ARS::ars_DeleteCharMenu( $self->{'ctrl'}, $p{'ObjectName'} ) || do {
			$self->{'errstr'} = "DeleteObjectFromServer: failed to delete object from server: " . $ARS::ars_errstr;
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
	}elsif	($p{'ObjectType'} =~/^escalation$/i){
		#ars_DeleteEscalation
		ARS::ars_DeleteEscalation( $self->{'ctrl'}, $p{'ObjectName'} ) || do {
			$self->{'errstr'} = "DeleteObjectFromServer: failed to delete object from server: " . $ARS::ars_errstr;
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
	}elsif	($p{'ObjectType'} =~/^filter$/i){
		#ars_DeleteFilter
		ARS::ars_DeleteFilter( $self->{'ctrl'}, $p{'ObjectName'} ) || do {
			$self->{'errstr'} = "DeleteObjectFromServer: failed to delete object from server: " . $ARS::ars_errstr;
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
	}elsif	($p{'ObjectType'} =~/^schema$/i){
		#ars_DeleteSchema
		ARS::ars_DeleteSchema( $self->{'ctrl'}, $p{'ObjectName'}, 1 ) || do {
			
			## NOTE: setting deleteOption to 1 (force_delete). whoo chile! be careful!
			
			$self->{'errstr'} = "DeleteObjectFromServer: failed to delete object from server: " . $ARS::ars_errstr;
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		};
	}else{
		$self->{'errstr'} = "DeleteObjectFromServer: I don't know how to delete the specified ObjectType: " . $p{'ObjectType'};
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	}
	
	return (1);
	
}


## ExportDefinition #############################
## export a serialized ARS Object from the ARServer in def or xml format
## on success return the serialized object, on error undef
## ObjectName	=> "Remedy:ARSTools:CrazyActiveLink",
## ObjectType	=> "active_link",
## DefinitionType	=> "xml"
## NOTE: ISS04238696 on BMC ... XML export will not work with overlays on form defs
sub ExportDefinition {
	my ($self, %p) = @_;
	
	#make sure we got our required and default options, yadda yadda
	foreach ('DefinitionType', 'ObjectName', 'ObjectType'){
		if ((! exists($p{$_})) || ($p{$_} =~/^\s*$/)){
			$self->{'errstr'} = "ExportDefinition: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	if ($p{'DefinitionType'} =~/^xml$/){
		$p{'DefinitionType'} = "xml";
		$p{'DefinitionType'} = "xml_" . $p{'ObjectType'}; ## <-- yeah that's how it works
	}elsif ($p{'DefinitionType'} =~/^def$/){
		$p{'DefinitionType'} = "def";
	}else{
		$self->{'errstr'} = "ExportDefinition: unknown 'DefinitionType' value: " . $p{'DefinitionType'};
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	}
	
	#"don't dude me, bro!" -- ghost adventures
	(my $def = ARS::ars_Export(
		$self->{'ctrl'},
		'',			## <-- '' = NULL = "get definition including all views" (if it's a form of course)
		'',			## <-- arsperl says '' is the same as &ARS::AR_VUI_TYPE_NONE, and I can dig it
		$p{'ObjectType'},
		$p{'ObjectName'}
	)) || do {
		$self->{'errstr'} = "ExportDefinition: failed to export definition: " . $ARS::ars_errstr;
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	};
	
	return($def);
}


## ImportDefinition #############################
## import a serialized ARS Object, this will be either in *.def or *.xml format
## return 1 on success. return undef on failure.
## I s'pose it goes without saying, but you know ...
## be careful, m'kay?
## options:
##	* Definition			=> $string_containing_serialized_def
##	* DefinitionType		=> "xml" | "def"
##	* ObjectName			=> $the_name_of_the_object_to_import
##	* ObjectType			=> "schema" | "filter" | "active_link" | "char_menu" | "escalation" | "dist_map" | "container" | "dist_pool" 
##	* UpdateCache			=> 1 | 0 (default 0)
##	* OverwriteExistingObject	=> 1 | 0 (default 0)
sub ImportDefinition {
	
	my ($self, %p) = @_;
	
	#make sure we got our required and default options, yadda yadda
	foreach ('Definition', 'DefinitionType', 'ObjectName', 'ObjectType'){
		if ((! exists($p{$_})) || ($p{$_} =~/^\s*$/)){
			$self->{'errstr'} = "ImportDefinition: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	$p{'UpdateCache'} = 0 if ($p{'UpdateCache'}) != 1;
	$p{'OverwriteExistingObject'} = 0 if ($p{'OverwriteExistingObject'}) != 1;
	if ($p{'DefinitionType'} =~/^xml$/){
		$p{'DefinitionType'} = "xml";
		$p{'ObjectType'} = "xml_" . $p{'ObjectType'}; ## <-- yeah that's how it works
	}elsif ($p{'DefinitionType'} =~/^def$/){
		$p{'DefinitionType'} = "def";
	}else{
		$self->{'errstr'} = "ImportDefinition: unknown 'DefinitionType' value: " . $p{'DefinitionType'};
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return (undef);
	}
	
	#set up the import mode
	my $import_mode = \&ARS::AR_IMPORT_OPT_CREATE;
	if ($p{'OverwriteExistingObject'} == 1){ $import_mode = \&ARS::AR_IMPORT_OPT_OVERWRITE; }
	
	#like the shoe company says ...
	(my $result = ARS::ars_Import(
		$self->{'ctrl'},
		$import_mode,
		$p{'Definition'},
		$p{'ObjectType'},
		$p{'ObjectName'}
	)) || do {
		$self->{'errstr'} = "ImportDefinition: failed to import definition: " . $ARS::ars_errstr;
		warn ($self->{'errstr'}) if $self->{'Debug'};
		return(undef);
	};
	
	#deal with updating the cache if we gotta
	if (($p{'UpdateCache'} == 1) && (($p{'ObjectType'} eq "schema") || ($p{'ObjectType'} eq "xml_schema"))){
		
		#see if we got it in our schema list already
		my $found = ();
		foreach my $schema (@{$self->{'Schemas'}}){ if ($schema eq $p{'ObjectName'}){ $found = 1; last; } }
		if ($found =~/^\s*$/){ push (@{$self->{'Schemas'}}, $p{'ObjectName'}); }
		$self->{'staleConfig'} = 1;
		warn ("ImportDefinition: inserting new object into cache ...") if ($self->{'Debug'});
		$self->LoadARSConfig();

	}
	
	return(1);
}

## TunnelSQL ####################################
## tunnel some sql on the API
sub TunnelSQL {
	my ($self, %p) = @_;
	
	#make sure we got our required and default options, yadda yadda
	foreach ('SQL'){
		if ((! exists($p{$_})) || ($p{$_} =~/^\s*$/)){
			$self->{'errstr'} = "TunnelSQL: " . $_ . " is a required option";
			warn ($self->{'errstr'}) if $self->{'Debug'};
			return (undef);
		}
	}
	
	my $data = ARS::ars_GetListSQL(
		$self->{'ctrl'},
		$p{'SQL'}
	) || do {
		$self->{'errstr'} = "TunnelSQL: failed SQL: " . $ARS::ars_errstr;
		warn ($self->{'errstr'}) if ($self->{'Debug'});
		return (undef);
	};
	
	#we might not have gotten anything
	if ($data->{'numMatches'} == 0){
		$self->{'errstr'} = "no records returned";
		warn ($self->{'errstr'}) if ($self->{'Debug'});
		return(undef);
	}else{
		return($data->{'rows'});
	}
}

