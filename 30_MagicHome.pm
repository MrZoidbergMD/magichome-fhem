#
# 30_MagicHome.pm
# Works for now, v0.1
#
# todo: nichts machen/senden wenn disconnected
# todo: reconnecten wenn man was sendet
#
package main;

use DevIo; 


my %sets = ("on" => "noArg", "off" => "noArg", "RGB" => "colorpicker,RGB", "dim" => "colorpicker,BRI,0,1,100","brightness" => "colorpicker,BRI,0,1,100","WHITE" => "colorpicker,BRI,0,1,255", "dimup" => "noArg", "dimdown" => "noArg","briup" => "noArg", "bridown" => "noArg", "RGBW" => "textField");

sub MagicHome_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "MagicHome_Set";
  $hash->{GetFn}     = "MagicHome_Get";
  $hash->{DefFn}     = "MagicHome_Define";
  $hash->{UndefFn}     = "MagicHome_Undef"; 
  $hash->{ReadFn}   = "MagicHome_Read";
  $hash->{ReadyFn}  = "MagicHome_Ready";
  $hash->{AttrList} =
  "dimStep " . 
  "defaultColor " .
  "IODev " .
  "reconnect:0,1 ".
  $readingFnAttributes;
  # exclusive mode setzt nur rgb oder weiss wenn true
}

sub MagicHome_Define($$)
{
	my ( $hash, $def ) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my $u = "wrong syntax: define <name> MagicHome <host/ip>";
	return $u if(int(@a) != 3);
  
	$hash->{host} = $a[2];
  $hash->{DeviceName} = $a[2].":5577";
  $hash->{nextOpenDelay} = 60;
  
  	# close connection if maybe open (on definition modify)
  	DevIo_CloseDev($hash) if(DevIo_IsOpen($hash));  
  
  	# open connection with custom init function
  	my $ret = DevIo_OpenDev($hash, 0, "MagicHome_Init", "MagicHome_Callback");
    
	return $error;
}

# will be executed upon successful connection establishment (see DevIo_OpenDev())
sub MagicHome_Init($)
{
    my ($hash) = @_;

    Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME}) Init, send request";

    # send a status request to the device
    SendRequest($hash, 0x81, 0x8A, 0x8B);
    
    return undef; 
}

# will be executed if connection establishment fails (see DevIo_OpenDev())
sub MagicHome_Callback($)
{
    my ($hash, $error) = @_;

    # create a log emtry with the error message
    if (defined($error)) {
      Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME})  - error while connecting: $error"; 
    }
    
    return undef; 
}

# called when definition is undefined 
# (config reload, shutdown or delete of definition)
sub MagicHome_Undef($$)
{
  my ($hash, $name) = @_;
 
  # close the connection 
  DevIo_CloseDev($hash);
  
  return undef;
}

# called repeatedly if device disappeared
sub MagicHome_Ready($)
{
  my ($hash) = @_;


  
  $attrReconnect = AttrVal($name, "reconnect", 0) ;
  if($hash->{STATE} eq "disconnected" &&  $attrReconnect == 1)
  {
    #return if(defined($hash->{helper}{NEXT_TRY}) && $hash->{helper}{NEXT_TRY} && time() < $hash->{helper}{NEXT_TRY});
    
    Log3 $hash->{NAME}, 3, "MagicHome ($hash->{NAME}) Ready reconnect";
    my $ret = DevIo_OpenDev($hash, 1, "MagicHome_Init", "MagicHome_Callback");
    return $ret ;
	}
}


# called when data was received
sub MagicHome_Read($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  # read the available data
  my $bufRaw = DevIo_SimpleRead($hash);
    # stop processing if no data is available (device disconnected)
  return if(!defined($bufRaw));

   my( @buf ) = unpack( 'C*', $bufRaw );

  if (@buf[0] == 0x81) {
     Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME})  - received device status"; 

    $statePower = 0;
    $statePower = 1 if (@buf[2] == 0x23);
    updateReadingsRGBWPower($hash, @buf[6], @buf[7], @buf[8], @buf[9], $statePower);
    
  } elsif (@buf[0] == 0xf0) {
    # received power info
    updateReadingsPower($hash, 0) if(@buf[2] == 0x24);
    updateReadingsPower($hash, 1) if(@buf[2] == 0x23);
    
  } elsif (@buf[0] == 0x30) {
    # received info that something has changed
    SendRequest($hash, 0x81, 0x8A, 0x8B);
  } else {
  	# TODO: man bekommt auch nachrichten wenn man es über die app ändert zb. 48 und das live
	  $bufStr = sprintf("%v02X", $bufRaw);
	  Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME})  - received unknown: $bufStr"; 
  }
}

## 
sub MagicHome_Set ($$@)
{
	my ( $hash, $name, $cmd, @args ) = @_;

	return "\"set $name\" needs at least one argument" unless(defined($cmd));

	# Print all available options
	if(!exists($sets{$cmd})) {
		my @setOptions;
		keys %sets; # reset the internal iterator so a prior each() doesn't affect the loop
		while(my($k, $v) = each %sets) { 
		    $cSet = $k.":".$v;
		    push @setOptions, $cSet;
		}

		$setKeys = join(" ", @setOptions);
		return ("Unknown argument $cmd, choose one of $setKeys" );
	}

	# print option for one command
	if(defined($args[0]) && $args[0] eq "?")  {
		return ("$cmd:$sets{$cmd}");
	}
  
  # check if connected
  if($hash->{STATE} eq "disconnected") {
    # try reconnect; TODO: its maybe cleaner to overwrite the next connection interval with something sort
    Log3 $hash->{NAME}, 3, "MagicHome ($hash->{NAME}) _Set() forced reconnect";
    my $ret = DevIo_OpenDev($hash, 1, "MagicHome_Init", "MagicHome_Callback");
    
    return "Error: Not connected.";
  }

  # Power
	SendPowerRequest($hash, 0) if($cmd eq "on");
	SendPowerRequest($hash, 1) if($cmd eq "off");

	
	if($cmd eq "RGB")
	{
	   # RGB parsen/setzen     
		$rgbHex = pack ('H*',$args[0]);
		@rgbColor = unpack ('C*',$rgbHex);
		
		$clrStr = sprintf("%02X%02X%02X.  %d",@rgbColor[0], @rgbColor[1], @rgbColor[2], ReadingsNum($hash->{NAME}, "WHITE", 0));
		Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME})  - Setting color $args[0] to $clrStr   "; 

		SendRGBWRequest($hash, @rgbColor[0], @rgbColor[1], @rgbColor[2], ReadingsNum($hash->{NAME}, "WHITE", 0));
	}
	elsif($cmd eq "RGBW")
	{
	   # RGB parsen/setzen     
		Log3 $hash->{NAME}, 3, "MagicHome ($hash->{NAME})  - Setting RGBW to $args[0]";
		# white level lesen
		# $hash->{READINGS}{WHITE}
		$rgbHex = pack ('H*',$args[0]);
		@rgbColor = unpack ('C*',$rgbHex);

		SendRGBWRequest($hash, @rgbColor[0], @rgbColor[1], @rgbColor[2], @rgbColor[3]);
	   
	}
	elsif($cmd eq "WHITE")
	{
	   # White    
		$rgbHex = pack ('H*',ReadingsVal($hash->{NAME}, "RGB", "000000"));
		@rgbColor = unpack ('C*',$rgbHex);

		SendRGBWRequest($hash, @rgbColor[0], @rgbColor[1], @rgbColor[2], $args[0]);
	}
	elsif($cmd eq "brightness")
	{
	   # dim    
		Log 4, "dim $args[0]";
    
    $dimFactor = $args[0];
     $white = ReadingsNum($hash->{NAME}, "WHITE", 0);
  
    setBrightness($hash, $dimFactor, $white);
	}
  	elsif($cmd eq "briup" || $cmd eq "bridown")
	{
	   # Dimmer    
	   Log 4, "briup/bridown";
      
     # TODO: variable nehme
     $dimFactor = AttrVal($name, "dimStep", 10) ;
     $dimFactor *= -1 if ($cmd eq "dimdown");
     $white = ReadingsNum($hash->{NAME}, "WHITE", 0);
     
     dimBrightness($hash, $dimFactor, $white);

	}
	elsif($cmd eq "dim")
	{
	   # dim    
		Log 4, "dim $args[0]";
    
    $dimFactor = $args[0];
     $white = num_range($dimFactor * 2.55, 0, 255);
  
    setBrightness($hash, $dimFactor, $white);
	}
	elsif($cmd eq "dimup" || $cmd eq "dimdown")
	{
	   # Dimmer    
	   Log 4, "dimup/down";

     # TODO: variable nehme
     $dimFactor = AttrVal($name, "dimStep", 10) ;
     $dimFactor *= -1 if ($cmd eq "dimdown");
     $white = num_range(ReadingsNum($hash->{NAME}, "WHITE", 0) + ($dimFactor * 2.55), 0, 255);
     
     dimBrightness($hash, $dimFactor, $white);

	}
	return ($error);
}

sub colorUnpackRGB($) {
  my ( $hexRgbString ) = @_;
  $rgbHex = pack ('H*',$hexRgbString);
		@rgbColor = unpack ('C*',$rgbHex);
    return @rgbColor[0], @rgbColor[1], @rgbColor[2];
}

sub MagicHome_Get($$@)
{
	my ( $hash, $name, $opt, @args ) = @_;

	return "\"get $name\" needs at least one argument" unless(defined($opt));

	if($opt eq "status") 
	{
      if($hash->{STATE} eq "disconnected") {
    # try reconnect; TODO: its maybe cleaner to overwrite the next connection interval with something sort
    Log3 $hash->{NAME}, 3, "MagicHome ($hash->{NAME}) _Set() forced reconnect";
    my $ret = DevIo_OpenDev($hash, 1, "MagicHome_Init", "MagicHome_Callback");
    
    return "Error: Not connected.";
  }
	    SendRequest($hash, 0x81, 0x8A, 0x8B);

	    return undef;
	}
	else
	{
		return "Unknown argument $opt, choose one of status:noArg";
	}
}
#
# brightness utils (used for dimmer)
#
sub setBrightness($$$) {
  my ( $hash, $dimFactor, $white, @args ) = @_;
  
    ($r, $g, $b) = colorUnpackRGB(ReadingsVal($hash->{NAME}, "RGB", "000000"));
    
     $nr, $ng, $nb = adjustBrightness($r, $g, $b, ($dimFactor/100.));
     SendRGBWRequest($hash, $nr, $ng, $nb, $white);
}

sub dimBrightness($$$) {
  my ( $hash, $dimFactor, $white, @args ) = @_;
  
      ($r, $g, $b) = colorUnpackRGB(ReadingsVal($hash->{NAME}, "RGB", "000000"));
     
     $nr, $ng, $nb = substractBrightness($r, $g, $b, $dimFactor);
     SendRGBWRequest($hash, $nr, $ng, $nb, $white);
}

#
# Utils and stuff
#

#powerOff = 0 ist an und 1 ist aus
sub SendPowerRequest($$)
{
	my ($hash, $powerOff) = @_;

	SendRequest($hash, 0x71, 0x23 + $powerOff, 0x0f);

  updateReadingsPower($hash, 1-$powerOff) ;
}
sub SendRGBWRequest($$$$$)
{
	my ($hash, $r, $g, $b, $w) = @_;
	# todo: gucken wie man das mit persistence hnbekommt
	SendRequest($hash, 0x31, $r, $g, $b, $w, 0xf0, 0xf0);
  
  updateReadingsRGBW($hash, $r, $g, $b, $w);
}

sub SendRequest($$@)
{
	my ($hash, $func, @args) = @_;
 
	# Form paket
	my $binaryPaket = sprintf("%c", $func);
	$binaryPaket .= pack ('C*', @args);

	$sending = sprintf("%v02X", AppendChecksum($binaryPaket));
	Log3 $hash->{NAME}, 4, "MagicHome ($hash->{NAME})  - SENDING: $sending"; 

  DevIo_SimpleWrite($hash, AppendChecksum($binaryPaket), 0);
}

sub SendRequestRaw($)
{
	my ($hash, $rawPaket) = @_;
	# TODO: check if connected

    DevIo_SimpleWrite($hash, $rawPaket, 0);
}

# checksum paket
sub AppendChecksum($)
{
	my ($pak) = @_;
	my $c = 0;
    foreach my $w (split //, $pak)
    {
		$c += ord($w);
	}
	$c %= 0x100;
	$pak .= sprintf("%c", $c);

    
    return $pak
}

sub getBrightnessFactor($$$) {
    my ($r, $g, $b) = @_;
  $max = $r;
  $max = $g if ($g > $max);
  $max = $b if ($b > $max);
  
  $curFactor = $max / 255.;
  return $curFactor;
}

sub getBrightnessFactorPercent($$$) {
    my ($r, $g, $b) = @_;
  $curFactor = num_range(getBrightnessFactor($r, $g, $b)*100, 0, 100);
  return round($curFactor, 0);
}

# dim describes the percentthat are added
sub substractBrightness($$$$) {
  my ($r, $g, $b, $dim) = @_;
  $curFactor = getBrightnessFactor($r, $g, $b);
  $newFactor = $curFactor + ($dim / 100);
  
  return transformBrightness($r, $g, $b, $curFactor, $newFactor);
}

sub adjustBrightness($$$$) {
  my ($r, $g, $b, $dim) = @_;
  $curFactor = getBrightnessFactor($r, $g, $b);
  return transformBrightness($r, $g, $b, $curFactor, $dim);
}

# ändert eine farbe dessen aktuelle brigthness bekannt ist mit einer neuen
sub transformBrightness($$$$$) {
    my ($r, $g, $b, $curFactor, $newFactor) = @_;
    
  $newFactor = 1 if ($newFactor > 1);
  return (0, 0, 0) if ($newFactor <= 0);
  
  return (255*$newFactor, 255*$newFactor, 255*$newFactor) if ($curFactor == 0);
  
  $nr = ($r/$curFactor)*$newFactor;
  $ng = ($g/$curFactor)*$newFactor;
  $nb = ($b/$curFactor)*$newFactor;
  
  return ($nr, $ng, $nb);
}

#
# helper/wrapper to update readings
#
sub updateReadingsRGBW($$$$$)
{
  my ( $hash, $r, $g, $b, $w) = @_;
  updateReadingsRGBWPower($hash, $r, $g, $b, $w, -1);
}

sub updateReadingsRGBWPower($$$$$$)
{
  my ( $hash, $r, $g, $b, $w, $power) = @_;
  
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", "on") if ($power == 1);
  readingsBulkUpdate($hash, "state", "off") if ($power == 0);
  
  # real values
  readingsBulkUpdate($hash, "RGB", sprintf("%02X%02X%02X",$r, $g, $b));
  readingsBulkUpdate($hash, "WHITE", sprintf("%d",$w));
  
  # calculated
  readingsBulkUpdate($hash, "brightness", getBrightnessFactorPercent($r, $g, $b));
  
  readingsEndUpdate($hash, 1);
}

sub updateReadingsPower($$)
{
  my ( $hash, $power) = @_;
  
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", "on") if ($power == 1);
  readingsBulkUpdate($hash, "state", "off") if ($power == 0);
  
  readingsEndUpdate($hash, 1);
}

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was MYMODULE steuert/unterstützt
=item summary_DE Kurzbeschreibung in Deutsch was MYMODULE steuert/unterstützt

=begin html
 Englische Commandref in HTML
=end html

=begin html_DE
 Deustche Commandref in HTML
=end html

# Ende der Commandref
=cut
