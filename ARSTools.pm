###################################################
## Remedy::ARSTools.pm
## Andrew N. Hicox
##
## This package contains tools for querying,
## creating, and modifying tickets in an ARS system.
###################################################


## Global Stuff ###################################
  package Remedy::ARSTools;
  use 5.6.0;
  use warnings;
  use Carp;

  require Exporter;
  require ARS;
  use AutoLoader qw(AUTOLOAD);
  
## Class Global Values ############################ 
  our @ISA = qw(Exporter);
  our $VERSION = '0.7';
  our $errstr = ();
  our @EXPORT = qw(&ParseDBDiary &GenerateARSConfig &GetFieldData);
  our @EXPORT_OK = ($VERSION, $errstr);


## new ############################################
sub new {
   #local vars
    my $obj = bless ({@_});
   #required options
    unless (
        (exists ($obj->{'Server'}))	&&
        (exists ($obj->{'User'}))		&&
        (exists ($obj->{'Pass'}))		&&
        (exists ($obj->{'ConfigFile'}))     
    ){
        $errstr = "Server, User, Pass, and ConfigFile are required options to New";
        carp $errstr if $obj->{'Debug'};
        return (undef);     
    }
   #load the config file
    $obj->LoadARSConfig() || do {
        $errstr = $obj->{'errstr'};
        carp $errstr if $obj->{'Debug'};
        return (undef);
    };
   #get a control token
    unless ($obj->{'LoginOverride'}){
        unless ($obj->ARSLogin()){
            $errstr = $obj->{'errstr'};
            carp $errstr if $obj->{'Debug'};
            return (undef);
        }
    }
   #return object
    return ($obj);
}


## LoadARSConfig ##################################
##if you don't have it already, load the ARSConfig from xml
sub LoadARSConfig {
    my ($self, %p) = @_;
   #unless we've been here before
    if (exists($self->{'ARSConfig'})){ return (1); }
   #make sure the file exists
    unless (-e $self->{'ConfigFile'}){
        if ($self->{'GenerateConfig'}){
            unless ($self->GenerateConfig()){
                $self->{'errstr'} = "LoadARSConfig: $self->{'errstr'}";
                carp ($self->{'errstr'}) if $self->{'Debug'};
                return (undef);
            }
        }else{
            $self->{'errstr'} = "LoadARSConfig: specified config file ($self->{'ConfigFile'}) does not exist, ";
            $self->{'errstr'}.= "and you have not given me permission to generate a new ";
            $self->{'errstr'}.= "config file. To give me permission, set the 'GenerateConfig' ";
            $self->{'errstr'}.= "option to a non-zero value at instantiation. ";
            carp ($self->{'errstr'}) if $self->{'Debug'};
            return (undef);
        }
    }
   #open the file
    open (CFG, "$self->{'ConfigFile'}") || do {
        $self->{'errstr'} = "LoadARSConfig: failed to open specified config ($self->{'ConfigFile'}) ";
        $self->{'errstr'}.= $!;
        carp ($self->{'errstr'}) if $self->{'Debug'};
        return (undef);
    };
    my $data = join ('',<CFG>); 
    close (CFG);
   #get an XML parser, unless we have one already
    unless (exists($self->{XMLParser})){
       #if we've got here, than it isn't loaded yet
        require Data::DumpXML::Parser;
        $self->{XMLParser} = Data::DumpXML::Parser->new;
    }
   #parse xml
    $self->{ARSConfig} = $self->{XMLParser}->parsestring($data);
   #we just want the first element
    $self->{ARSConfig} = $self->{ARSConfig}->[0];
    return (1);
}
 

## ARSLogin #######################################
##if not already logged in ... get ars token.
 sub ARSLogin {
    #local vars
     my $self = shift();
     my %p = @_;    
    #are we already logged in?
     if (exists ($self->{ctrl})){ return (1); }
    #set $ENV{'ARTCPPORT'} if it exists, else delete it
     if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
    #we'll be needing ars for this
     unless ($self->{ctrl} = ARS::ars_Login(
         $self->{Server},
         $self->{User},
         $self->{Pass}
     )){
         $self->{errstr} = "ARSLogin failed can't login to ARS server: $ARS::ars_errstr";
         return (undef);
     }
    #it's all good baby bay bay ...
     return (1); 
 }


## Destroy ########################################
 sub Destroy {
     my $self = shift();
    #set $ENV{'ARTCPPORT'} if it exists, else delete it
     if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
     if (exists($self->{ctrl})){ ARS::ars_Logoff($self->{ctrl}); }
     $self = undef;
     return (1);
 }


## True for perl include ##########################
 1;


## AutoLoaded Methods
__END__

## _CheckFieldLengths ##############################
##wrapper for _CheckFieldLengths
##this is unused in version 0.5
##in future versions (hopefully, the next release), 
##this will broker requests to CheckFieldLengths, and 
##handle auto-refreshing the config file when fields or
##schemas are not found in the file.
sub _CheckFieldLengths {
    #local vars
     my ($self, %p) = @_;
    #do the check
     if (my $errors = $self->CheckFieldLengths(%p)){
        #refresh config and try again, if we should
         if ($self->{'AutoConfig'}){
             $self->RefreshConfig() || do { return ($errors); };
             if (my $errors = $self->CheckFieldLengths(%p)){
                 return ($errors);
             }elsif ($self->{'errstr'} eq "ok"){
                 return (undef);
             }else{
                 return (1);
             }
         }
        #bona fide field length errors
         return ($errors);
     }else{
         unless ($self->{errstr} eq "ok"){
             unless ($self->{'AutoConfig'}){ return (undef); }
            #if the error is a unknown schema, we can handle that.
             if ($self->{'errstr'} =~/I don't know the schema/){
                #check to see if the schema is available on the server
                 my @sch = ARS::ars_GetListSchema($self->{'ctrl'});
                 unless (grep {$_ eq $p{'Schema'}} @sch){
                     $self->{'errstr'} = "CheckFieldLengths: The schema: $p{'Schema'} is not available on this server.";
                     carp ($self->{'errstr'}) if $self->{'Debug'};
                     return (undef);
                 }
             }
            #refresh the config with new schema
             @{$self->{'Schemas'}} = keys (%{$self->{ARSConfig}});
             push (@{$self->{'Schemas'}}, $p{'Schema'}); 
             carp ("refreshing config to indclude: $p{'Schema'}") if $self->{'Debug'}; 
             $self->RefreshConfig() || do { 
                 $self->{'errstr'} = "CheckFieldLengths: failed to refresh config: $self->{'errstr'}";
                 carp ($self->{'errstr'}) if $self->{'Debug'};
                 return (undef); 
             };
            #bona fide error
             return (undef);
         }
         return (1);
     }
}

## CheckFieldLengths #############################
sub CheckFieldLengths {
    #Local Vars
     my $self = shift();
     my %p = @_;
     my ($errors) = ();
    #check input for required data
          if (
         (! exists ($p{'Fields'})) || 
         (! exists ($p{'Schema'}))
     ){  
         $self->{errstr} = "CheckFieldLengths missing required data.";
         return (undef);
     }
    #check that Fields is a hash ref
     if (ref($p{'Fields'}) ne "HASH"){
         $self->{errstr} = "CheckFieldLengths: Fields must be a hash reference";
         return (undef);
     }
    #make sure we "know" the schema
     if (! exists ($self->{ARSConfig}->{$p{'Schema'}})){
         $self->{errstr} = "CheckFieldLengths: I don't know the schema: $p{'Schema'}";
         return (undef);
     }
    #loop through the fields
     foreach (keys %{$p{Fields}}){
        #make sure we "know" the field
         unless (exists ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_})){
             $self->{errstr} = "CheckFieldLengths: I don't know this field: $_ in this schema: $p{Schema}";
             return (undef);
         }
        #check the length
         unless (
            #some fields in the config don't have a length, like menus for instance
             (! exists($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{length})) || 
            #fields with 0 length are unlimited
             ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{length} == 0)      ||
            #if the field is too long ...
             (length($p{Fields}->{$_}) <= $self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{length})
         ){
            #something was too big
             $errors .= "CheckFieldLengths: $_ too long (max length is $self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{length})\n";
         }
        #if field is an enum, make sure value is allowed
         if ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{enum}){
            #of course, the value must be a number!
             unless ($p{Fields}->{$_} =~/\d+/){
                 $errors .= "CheckFieldLengths: $_ is an enumerated field, send the enum, not the string";
             }
            #make sure the enum is not out of range
             if (
                 ($p{Fields}->{$_} < 0) ||
                 ($p{Fields}->{$_} > $#{$self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{vals}})
             ){
                 $errors .= ":CheckFieldLengths $_ enum is out of range";
             }
         }
     }
    #did we have errors?
     if ($errors){
         return ($errors);
     }else{
         $self->{errstr} = "ok";
         return (undef);
     }
}

 
## CreateTicket ###################################
sub CreateTicket {
    #Local Vars
     my $self = shift();  
     my %p = @_;
     my ($errors,@update_list,$entry_id) = ();
    #check input for required data
     unless (
         (exists ($p{Fields})) &&
         (exists ($p{Schema}))
     ){
         $self->{errstr} = "Fields is a required option for CreateTicket";
         return (undef); 
     }
    #check field lengths ... this can be nasty
     if ($errors = $self->CheckFieldLengths(
         Fields	=> $p{Fields},
         Schema	=> $p{Schema}
     )){
        #field length errors
         $self->{errstr} = $errors;
         return (undef);
     }else{
        unless ($self->{errstr} eq "ok"){
           #bona fide error
            return (undef);
        }
     }
    #make a field list that ars understands
     foreach (keys %{$p{Fields}}){
         push (
             @update_list,
             ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{id},
             $p{Fields}->{$_})
         );
     }
    #set $ENV{'ARTCPPORT'} if it exists, else delete it
     if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
    #Washington, are you ready to rock and roll?
     if ($entry_id = ARS::ars_CreateEntry(
         $self->{ctrl},
         $p{Schema},
         @update_list
     )){
         return ($entry_id);
     }else{
         $self->{errstr} = "Create Ticket Failed: $ARS::ars_errstr";
         return (undef);
     }
}
  

## ModifyTicket ###################################
sub ModifyTicket {
     #local vars
      my $self = shift();  
      my %p = @_;
      my ($errors,@update_list) = ();
     #check input for required data
      unless (
          (exists ($p{Fields})) &&
          (exists ($p{Schema})) &&
          (exists ($p{Ticket}))
      ){
          $self->{errstr} = "Fields, Schema, and Ticket are required options for ModifyTicket";
          return (undef);
      }
     #check field lengths
      if ($errors = $self->CheckFieldLengths(
         Fields	=> $p{Fields},
         Schema	=> $p{Schema}
     )){
        #field length errors
         $self->{errstr} = $errors;
         return (undef);
     }else{
        unless ($self->{errstr} eq "ok"){
           #bona fide error
            return (undef);
        }
     }
    #make a field list that ars understands
     foreach (keys %{$p{Fields}}){
         push (
             @update_list,
             ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{id},
             $p{Fields}->{$_})
         );
     }
    #set $ENV{'ARTCPPORT'} if it exists, else delete it
     if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
    #Rockin' with Dokken ...
     unless (ARS::ars_SetEntry(
         $self->{ctrl},
         $p{Schema},
         $p{Ticket},
         0,
         @update_list
     )){
         $self->{errstr} = "failed to write values to ticket: $p{Ticket} ";
         $self->{errstr}.= "[ARS Error]: $ARS::ars_errstr";
         return (undef);
     }
    #yea verily, 'tis all good, brethren
     return (1);
}


## DeleteTicket ###################################
sub DeleteTicket {
     #local vars
      my $self = shift();  
      my %p = @_;
     #check input for required data
      unless (
          (exists ($p{Schema})) &&
          (exists ($p{Ticket}))
      ){
          $self->{errstr} = "Schema and Ticket are required options for DeleteTicket";
          return (undef);
      }
     #hmm just to safeguard against disaster
      unless ($self->{CanDelete}){
          $self->{errstr} = "The CanDelete option was not set in this object at create time ";
          $self->{errstr}.= "Tickets may not be deleted using this object.";
          return (undef);
      }
     #set $ENV{'ARTCPPORT'} if it exists, else delete it
      if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
     #do the deed
      unless (ARS::ars_DeleteEntry(
          $self->{ctrl},
          $p{Schema},
          $p{Ticket}
      )){
          $self->{errstr} = "Failed to delete ticket: $ARS::ars_errstr";
          return (undef);
      }
     #it's all good
      return (1);
}
 
 
## Query ##########################################
#some old school shiznit. This queries for tickets 
#via the ARS layer. This, in general, is not a good 
#thing. You REALLY SHOULD be querying these directly
#from the underlying database. But alas, some 
#chump-stain who dosen't understand is afraid to give
#us read-only db access, so here we go ...
#additional bit of old school flava: 
#QBE = "Query By Example", that's the remedy-proprietary
#"query string". Fields is the fields you wish to retrieve
#from tickets matching the query.
sub Query {
     #local vars
      my $self = shift();  
      my %p = @_;
      my ($qual,%tickets,@get_list,@out,%revSchema) = ();
     #check input for required data
      unless (
          (exists ($p{QBE})) &&
          (exists ($p{Schema})) &&
          (exists ($p{Fields}))
      ){
          $self->{errstr} = "QBE, Schema, and Fields are required options for Query";
          return (undef);
      }
     #make a list of the fields, which ARS will understand
      foreach (@{$p{Fields}}){
          unless (exists ($self->{ARSConfig}->{$p{Schema}}->{fields}->{$_})){
              $self->{errstr} = "I don't \"know\" the field: $_ in the schema: $p{Schema} ";
              $self->{errstr}.= "if this field actually exists, you may need to refresh the ";
              $self->{errstr}.= "ARSConfig file for this schema";
              return (undef);
          }
         #fields to get
          push (
              @get_list,
              $self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{id},
          );
         #while we're at it make a reverse field map
          $revSchema{$self->{ARSConfig}->{$p{Schema}}->{fields}->{$_}->{id}} = $_;
      }
     #set $ENV{'ARTCPPORT'} if it exists, else delete it
      if (exists($self->{'Port'})){ $ENV{'ARTCPPORT'} = $self->{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
     #okey dokey, let's "qualify" the query
      unless ($qual = ARS::ars_LoadQualifier(
          $self->{ctrl},
          $p{Schema},
          qq!$p{QBE}!
      )){
          $self->{errstr} = "failed to qualify query: $ARS::ars_errstr\n";
          $self->{errstr}.= $p{Query};
          return (undef);
      }
      
     #yes indeedy, old school shiznit! retrieve a list of record numbers!
      unless (%tickets = ARS::ars_GetListEntry(
          $self->{ctrl},
          $p{Schema},
          $qual,
          0
      )){
         #this might be a no-match situation
          if (! $ARS::ars_errstr){
              $self->{errstr} = "no matching records!";
              return (undef);
          }else{
              $self->{errstr} = "can't get ticket list: $ARS::ars_errstr\n";
              return (undef);
          }
      }
      if ($self->{Debug}){
          $num = keys(%tickets);
          carp ("$num matching records") if $self->{'Debug'};
      }
     #now we go back in and retrieve the fields we're looking for
      foreach (keys %tickets){
          my (%values,$f) = ();
          unless (%values = ARS::ars_GetEntry(
              $self->{ctrl},
              $p{Schema},
              $_,
              @get_list
          )){
              $self->{errstr} = "failed to retrieve values for queried ticket $_ ";
              $self->{errstr} = "something is very wrong";
          }
         #ok now translate the fieldID's back to human readable field names
          foreach $f (keys %values){
              unless ($revSchema{$f} eq $f){
                  $values{$revSchema{$f}} = $values{$f};
                  delete ($values{$f});
              }
          }
         #add it to out
          push (@out, \%values);
      }
     #'tis all good
      return (\@out);
}
  

## ParseDBDiary #####################################
##this will parse a raw ARS diary field as it appears
##in the underlying database into the same data 
##structure returned ARS::getField. To refresh your 
##memory, that's: a sorted array of hashes, each hash
##containing a 'timestamp','user', and 'value' field.
##The date is converted to localtime by default, to 
##override, sent 1 on the -OverrideLocaltime option the
##array is sorted by date. This is a non OO version so
##that it can be called by programs which don't need to
##make an object (i.e. actually talk to a remedy server).
##If you are using this module OO, you can call the
##ParseDiary method, which is essentially an OO wrapper
##for this method. Errors are on $Remedy::ARSTools::errstr.
sub ParseDBDiary {
   #local vars
    my %p = @_;
    my $record_separator = chr(03);
    my $meta_separator = chr(04);
    my (@records,@OUT) = ();
   #required option
    unless (exists($p{'Diary'})){
        $errstr = "ParseDBDiary: no diary to parse!";
        carp ($errstr) if $p{'Debug'};
        return (undef);
    }
   #default option
    unless (exists($p{'DateConvert'})){ $p{'DateConvert'} = 1; }
   #if the diary is blank (or just whitespace), it's not really an error!
    if ($p{'Diary'} =~/^[\s]*$/){
       #we note it
        $errstr = "ParseDBDiary: diary was blank!";
        carp ($errstr) if $p{'Debug'};
       #but don't cause trouble
        return (1);
    }
   #split diary into records 
    if ($p{'Diary'} !~/$record_separator/){
       #one record, and no record terminator
       #make sure we have at least a meta separator
        unless ($p{'Diary'}=~/$meta_separator/){
            $errstr = "ParseDBDiary: diary does not contain a record or date/user separator cannot parse";
            carp ($errstr) if $p{'Debug'};
            return (undef);
        }
        push (@records, $p{'Diary'});
    }else{
       #normal
        @records = split (/$record_separator/,$p{'Diary'});
    }
   #parse da entries
    foreach (@records){
        my %hash = ();
        ($hash{timestamp},$hash{user},$hash{value}) = split (/$meta_separator/,$_);
        push (@OUT,\%hash);
    }
   #sort da hash by date
    @OUT = sort { $a->{timestamp} <=> $b->{timestamp} } @OUT;
   #convert dates to human readable
    if ($p{'DateConvert'}){
        foreach (@OUT){ $_->{timestamp} = localtime($_->{timestamp}); }
    }
    return (\@OUT);
}


## ParseDiary #######################################
##OO wrapper for ParseDBDiary
sub ParseDiary {
   #local vars
    my ($self, %p) = @_;
    my $diary = ();
   #pass along the debug option
    if ($self->{'Debug'}){ $p{'Debug'} = 1; }
   #do the dam thang
    unless ($diary = ParseDBDiary(%p)){
        $self->{'errstr'} = "ParseDiary: $errstr";
        carp ($self->{'errstr'}) if $self->{'Debug'};
        return (undef);
    }
    return ($diary);
}


## RefreshConfig ####################################
sub RefreshConfig {
    my ($self, %p) = @_;
   #set port, ctrl and Schemas in %p
    foreach ("Port","ctrl","Schemas"){
        if (exists($self->{$_})){ $p{$_} = $self->{$_}; }
    }
   #do it
    unless (my $data = GetFieldData(%p)){
        $self->{'errstr'} = "RefreshConfig: $errstr";
        carp ($self->{'errstr'}) if $self->{'Debug'};
        return (undef);
    }
   #dump both new and old data down to xml for compare
    require Data::DumpXML::dump_xml;
    my $xml_new = Data::DumpXML::dump_xml($data);
    my $xml_old = Data::DumpXML::dump_xml($self->{'ARSConfig'});
   #if they don't match, write new data to the ConfigFile
    unless ($xml_new eq $xml_old){
       #update in object
        $self->{'ARSConfig'} = $data;
       #update in file, unless WriteFile = 0;
        unless ($p{'WriteFile'}){ return (1); }
        open (CFG, ">$self->{'ConfigFile'}") || do {
            $self->{'errstr'} = "RefreshConfig: unable to update config file ($self->{'ConfigFile'}) ";
            $self->{'errstr'}.= $!;
            carp ($self->{'errstr'}) if $self->{'Debug'};
            return (undef);
        };
        print CFG $xml_new, "\n";
        close (CFG);
        carp ("updated config file: $self->{'ConfigFile'}") if $self->{'Debug'};
    }
    return (1);
}


## GenerateConfig ###################################
##OO wrapper for GenerateARSConfig
sub GenerateConfig {
   #local vars
    my ($self, %p) = @_;
   #pass along the debug option
    if ($self->{'Debug'}){ $p{'Debug'} = 1; }
   #get the server, user, pass, configfile and schemas from object
    foreach (
        "Server",
        "User",
        "Pass",
        "ConfigFile",
        "Schemas",
        "Port",
    ){
        unless (exists($p{$_})){ $p{$_} = $self->{$_}; }
    }
   #do the deed
    GenerateARSConfig(%p) || do {
        $self->{'errstr'} = "GenerateConfig: $errstr";
        carp ($self->{'errstr'}) if $self->{'Debug'};
        return (undef);
    };
    return (1);
}


## GenerateARSConfig ################################
##a procedural method for generating ARS Config files
##procedural so that you can call it without creating
##an object. if you need to run it with an object, use
##the OO wrapper GenerateConfig.
sub GenerateARSConfig {
   #local vars
    my %p = @_;
   #required options
    unless (
        exists($p{'Server'})	&&
        exists($p{'User'})		&&
        exists($p{'Pass'})		&&
        exists($p{'ConfigFile'})
    ){
        $errstr = "GenerateARSConfig: 'Server', 'User', and 'Pass' are required options";
        carp ($errstr) if $p{'Debug'};
        return (undef);
    }
   #set $ENV{'ARTCPPORT'} if it exists, else delete it
    if (exists($p{'Port'})){ $ENV{'ARTCPPORT'} = $p{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
   #log in
    $p{'CTRL'} = ARS::ars_Login($p{'Server'}, $p{'User'}, $p{'Pass'})|| do {
        $errstr = "GenerateARSConfig: failed to login to $p{'Server'}: $ARS::ars_errstr";
        carp ($errstr) if $p{'Debug'};
        return (undef);
    };
   #if Schemas is not defined pull all schemas
    unless (exists($p{'Schemas'})){
        carp ("No user defined Schemas, retrieving all") if $p{'Debug'};
        unless (@{$p{'Schemas'}} = ARS::ars_GetListSchema($p{'CTRL'})){
            $errstr = "GenerateARSConfig failed to retrieve schema list: $ARS::ars_errstr";
            carp ($errstr) if $p{'Debug'};
            return (undef);
        }
    }
   #get the field data
    my $DATA = GetFieldData(%p) || do {
        $errstr = "GenerateARSConfig: $errstr";
        carp ($errstr) if $p{'Debug'};
       #logout before we die
        ARS::ars_Logoff($p{'CTRL'});
        return (undef);
    };
   #export the data structure to XML
    require Data::DumpXML;
    my $xml_data = Data::DumpXML::dump_xml($DATA);
    carp ("exported field data to XML") if $p{'Debug'};
   #okey dokey, write it to a file
    open (CFG, ">$p{'ConfigFile'}") || do {
        $errstr = "GenerateARSConfig: cannot open $p{'ConfigFile'} in write mode: $!";
        carp ($errstr) if $p{'Debug'};
       #logout before we die
        ARS::ars_Logoff($p{'CTRL'});
        return (undef);
    };
    print CFG $xml_data, "\n";
    close (CFG);
    ARS::ars_Logoff($p{'CTRL'});
    return (1);
}


## GetFieldData #####################################
##retrieves the field data for GenerateARSConfig and
##RefreshConfig, given a valid control token.
##also procedural, as it can be called via OO or
##procedural calls.
sub GetFieldData {
   #local vars
    my %p = @_;
    my (%DATA,%TEMP) = ();
   #required options
    unless (
        exists($p{'Schemas'})	&&
        exists($p{'CTRL'})
    ){
        $errstr = "GetFieldData: 'Schemas' and 'CTRL' are required options";
        carp ($errstr) if $p{'Debug'};
        return (undef);
    }
   #set the port if nessecary
    if (exists($p{'Port'})){ $ENV{'ARTCPPORT'} = $p{'Port'}; } else { delete($ENV{'ARTCPPORT'}); }
   #pull the info for each schema
    foreach (@{$p{'Schemas'}}){
        carp ("retrieving field list for $_") if $p{'Debug'};
       #get field table
        unless (%TEMP = ARS::ars_GetFieldTable($p{'CTRL'}, $_)){
            $errstr = "GetFieldData: failed to retrieve table data for $_: $ARS::ars_errstr";
            carp ($errstr) if $p{'Debug'};
            return (undef);
        }
       #get per-field meta data
        foreach my $field (keys %TEMP){
           #set field id info
            $DATA{$_}->{'fields'}->{$field}->{'id'} = $TEMP{$field};
           #get field meta data
            my $field_data = ARS::ars_GetField(
                $p{'CTRL'},
                $_,
                $TEMP{$field} 
            );
           #insert max length if there is one
            if (ref($field_data->{limit}) eq "HASH"){
                $DATA{$_}->{'fields'}->{$field}->{'length'} = $field_data->{limit}->{maxLength};
            }
           #if this is an enumerated field, insert all the valid enums
            if (($field_data->{dataType} eq "enum") && (ref($field_data->{limit}) eq "ARRAY")){
                $DATA{$_}->{'fields'}->{$field}->{'enum'} = 1;
                $DATA{$_}->{'fields'}->{$field}->{'vals'} = $field_data->{limit};
            }
        }
    }
   #give up tha funk ...
    return (\%DATA);
}

