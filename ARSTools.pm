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

#class global vars
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $errstr);
@ISA 		= qw(Exporter);
@EXPORT		= qw(&ParseDBDiary);
@EXPORT_OK	= qw($VERSION $errstr);
$VERSION	= 1.03;




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
				        if ($tmp->{'dataType'} eq "enum"){
				                #handle enums
				                $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'enum'} = 1;
				                if (ref($tmp->{'limit'}) eq "ARRAY"){
				                        #found it in the old place
				                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'} = $tmp->{'limit'};
                                                }elsif ( defined($tmp->{'limit'}) && defined($tmp->{'limit'}->{'enumLimits'}) && ( ref($tmp->{'limit'}->{'enumLimits'}->{'regularList'}) eq "ARRAY")){
                                                        #found it in the new place
                                                        $self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'} = $tmp->{'limit'}->{'enumLimits'}->{'regularList'};
                                                        
                                                ## EVEN NEWER HOTNESS (1.03)
                                                ## handle enums with custom value lists
                                                }elsif ( defined($tmp->{'limit'}) && defined($tmp->{'limit'}->{'enumLimits'}) && ( ref($tmp->{'limit'}->{'enumLimits'}->{'customList'}) eq "ARRAY")){
                                                        ## this is dirty ... using null values as placeholders
                                                        ## this does open up the possibility of null values passing validation when they shouldn't
                                                        my $highestEnum = 0;
                                                        my %revHash = ();
                                                        foreach my $blah (@{$tmp->{'limit'}->{'enumLimits'}->{'customList'}}){
                                                                if ($blah->{'itemNumber'} > $highestEnum){ $highestEnum = $blah->{'itemNumber'}; }
                                                                $revHash{$blah->{'itemNumber'}} = $blah->{'itemName'};
                                                        }
                                                        my $cnt = 0;
                                                        while ($cnt <= $highestEnum){
                                                                if (exists($revHash{$cnt})){
                                                                        push(@{$self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'}}, $revHash{$cnt});
                                                                }else{
                                                                        push(@{$self->{'ARSConfig'}->{$_}->{'fields'}->{$field}->{'vals'}}, '');
                                                                }
								$cnt ++;
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
	
	#examine each field for length & enum
	foreach (keys %{$p{'Fields'}}){
		
		#make sure we "know" the field
		exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
			
			#if we have 'ReloadConfigOK' in the object ... go for it
			if ($self->{'ReloadConfigOK'} > 0){
				$self->{'staleConfig'} = 1;
				warn("CheckFields: reloading stale config for unknown field: " . $p{'Schema'} . "/" . $_) if $self->{'Debug'};
				$self->LoadARSConfig() || do {
					$self->{'errstr'} = "CheckFields: can't reload config " . $self->{'errstr'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return(undef);
				};
				#if we didn't pick up the field, barf
				exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}) || do {
					$self->{'errstr'} = "CheckFields: I don't know the field: " . $_ . " in the schema: " . $p{'Schema'};
					warn($self->{'errstr'}) if $self->{'Debug'};
					return (undef);
				};
			}
		};
		
		#check length
		if (
			( exists($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'length'}) ) &&
			( $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'length'} > 0 ) &&
			( length($p{'Fields'}->{$_}) <= $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'length'} )
		){
			#field is too long
			if ($p{'TruncateOK'} > 0){
			$p{'Fields'}->{$_} = substr($p{'Fields'}->{$_}, 0, $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'length'});
			}else{
				$errors .= "CheckFieldLengths: " . $_ . "too long (max length is ";
				$errors .= $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'length'} . ")\n";
				next;
			}
		}
		
		#check / translate enum
		if ($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'enum'} > 0){
			
			#if the value is given as the enum
			if ($p{'Fields'}->{$_} =~/^\d+$/){
			
				#make sure the enum's not out of range
				if (
					($p{Fields}->{$_} < 0) ||
					($p{Fields}->{$_} > $#{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'vals'}})
				){
					$errors .= "CheckFieldLengths: " . $_ . " enum is out of range\n";
					next;
				}
			
			#if the value is given as the string
			}else{
				
				#translate it
				my $cnt = 0;
				foreach my $val (@{$self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$_}->{'vals'}}){
					if ($p{'Fields'}->{$_} =~/^$val$/i){ $p{'Fields'}->{$_} = $cnt; last; }
					$cnt ++;
				}
				#if we didn't find it, if it's not translated here
				if ($p{'Fields'}->{$_} !~/^\d+$/){
					$errors .= "CheckFieldLengths: " . $_ . " given value does not match any enumerated value for this field\n";
					next;
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
	my $errors = $self->CheckFields( %p ) || do {
		#careful now! if we're here it's either "ok" or a "real error"
		if ($self->{'errstr'} ne "ok"){
			$self->{'errstr'} = "ModifyTicket: error on CheckFields: " . $self->{'errstr'};
			return (undef);
		}
	};
	if (length($errors) > 0){
		$self->{'errstr'} = "ModifyTicket: error on CheckFields: " . $self->{'errstr'};
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
		
		#if 'convert_date' is set convert the timestamps to localtime
		$timestamp = localtime($timestamp) if ($p{'ConvertDate'} > 0);
		
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
		foreach my $id (keys %values){
			
			#convert field names
			unless ($revMap{$id} eq $id){
				$values{$revMap{$id}} = $values{$id};
				delete ($values{$id});
			}
			
			#translate enums
			if (
				($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$revMap{$id}}->{'enum'} > 0) &&
				($values{$revMap{$id}} =~/^\d+$/)
			){
				$values{$revMap{$id}} = $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$revMap{$id}}->{'vals'}->[$values{$revMap{$id}}];
			}
		}
		
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
		
		#translate field names & enums back to human-readable 
		foreach my $id (keys %values){
			
			#convert field names
			unless ($revMap{$id} eq $id){
				$values{$revMap{$id}} = $values{$id};
				delete ($values{$id});
			}
			
			#translate enums
			if (
				($self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$revMap{$id}}->{'enum'} > 0) &&
				($values{$revMap{$id}} =~/^\d+$/)
			){
				$values{$revMap{$id}} = $self->{'ARSConfig'}->{$p{'Schema'}}->{'fields'}->{$revMap{$id}}->{'vals'}->[$values{$revMap{$id}}];
			}
		}
		
		#push it on list of results
		push (@out, \%values);
		
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


