#!/bin/bash

###############################################################################################
# einzelne Abfrage bei eToro machen
curlCrawl () {
  # Variabeln Initalisierung & Konfiguration
  local url="$1"
  local lCount=0
  local lMax=10
  local tDelay=20
  local fetchWorked=0

  while [ $fetchWorked -eq 0 -a $lCount -le $lMax ]; do

    # get a unique number for the request
    local rNumber=`uuid`
 
    # assemble the url for the request
    local urlTot="$url&client_request_id=$rNumber"

    # fetch the data from eToro
    retValCurlCrawl=`curl -b $inFileCookie -s "$urlTot"`

    # check output
    if [[ "$retValCurlCrawl" != *"failureReason"* ]]; then
      fetchWorked=1
    else
      # sleep and try again
      echo "Seems blocked from eToro"
      sleep $((lCount*tDelay))
      ((lCount++))
    fi
  done

  # abort on error
  if [ $fetchWorked -ne 1 ]; then
    echo "Error: New cookie file required"
    if [ "$silentMode" == "false" ]; then
      ./telegram -t $tgAPI -c $tgcID "Maintenance message: New cookie required. Pausing bot."
    else
       echo "Maintenance message: New cookie required. Pausing bot."
    fi
    exit 1
  fi 

  # Check on error message of eToro
  if [[ "$retValCurlCrawl" == *"<title>50"* ]]; then
      echo $retValCurlCrawl
      echo "##########################"
      echo $urlTot
      echo "Error: eToro seems not available"
      if [ "$silentMode" == "false" ]; then
        ./telegram -t $tgAPI -c $tgcID "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
      else
         echo "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
       fi
    ## clean up for the next start (copy the old output back)
    cp "$outFileOld" "$outFileNew"
    rmFile $outFileLock
    exit 1
  fi 
}



###############################################################################################
# Daten von eToro holen

fetchEToroData() {
  # Variabeln Initalisierung & Konfiguration
  outFile="$1"
  basePUrl="https://www.etoro.com/sapi/trade-data-real/live/public/portfolios?format=json&cid="
  baseAUrl="https://www.etoro.com/sapi/trade-data-real/live/public/positions?format=json&InstrumentID="

  # fetch cid from config list
  cid=`grep "$trader" "$inFileCid"`
  if [ "$?" -ne "0" ]; then
    echo "Error: Configuration error, trader not found"
    ./telegram -t $tgAPI -c $tgcID "Error message: Configuration error. Pausing bot."
    exit 1
  fi   
  cid=${cid##*,}

  # URL zusammensetzen
  url="$basePUrl$cid"

  # Daten abgreifen
  retValCurlCrawl=""
  curlCrawl "$url"

  # ausschliesslich die AggregatedPositions herausfiltern
  fContent=$retValCurlCrawl
  fContent=${fContent%%\}],\"AggregatedMirrors*}
  fContent=${fContent##*AggregatedPositions\":[{}

  # Leerer File sicherstellen
  rmFile "$outFile"

  # jede Asset Klasse durchgehen und alle entsprechenden Trades holen
  for assetClass in $(echo $fContent | sed 's/},{/\n/g'); do
    # Asset Nummer extrahieren
    assetClass=${assetClass%%,\"Direction*}
    assetClass=${assetClass##\"InstrumentID\":}
  
    # URL zusammensetzen
    url=$baseAUrl$assetClass"&cid="$cid

    # Daten abgreifen
    curlCrawl "$url"

    # Daten extrahieren  
    fContent=$retValCurlCrawl
    fContent=${fContent%%\}]\}}
    fContent=${fContent##*PublicPositions\":[{}

    for asset in $(echo $fContent | sed 's/},{/\n/g'); do
      echo $asset >> $outFile
    done

  done

  # assure that each line is a resonable line. To this end I check for a key word
  touch $outFile 
  cp $outFile "$outFile"_tmp
  grep "CurrentRate" "$outFile"_tmp > $outFile
  rmFile "$outFile"_tmp
}

###############################################################################################
# Neue Positionen prüfen

checkNewOpen () {
  dSLong=`echo $1 | awk -F "," '{print $3}'`
  dStringPos=${dSLong:16:28}

  dValPos=`date --date="$dStringPos" +%s`
  dValNow=`date +%s`

  dValDiff=$((dValNow-dValPos))
  dValMax=$(($maxHOpen*60*60))
  
  if [ $dValDiff -gt $dValMax ]; then
    echo "Position to long open and therefore ignored"
    return 1
  fi
  return 0
}


###############################################################################################
# Veränderte Positionen erkennen

# neueröffnete, geschlossene und geänderte Positionen identifizieren
identDifference () {
  inFileNew="$outFileNew"
  inFileOld="$outFileOld"

  # Temporäre Dateien erstellen
  tmpFilePosNew=`tempfile -d $tmpDir`
  tmpFilePosOld=`tempfile -d $tmpDir`
  tmpFilePosDiff=`tempfile -d $tmpDir`

  # positionsnummern extrahieren
  sort "$inFileNew" | awk -F "," '{print $1}' > "$tmpFilePosNew"
  sort "$inFileOld" | awk -F "," '{print $1}' > "$tmpFilePosOld"
  diff "$tmpFilePosOld" "$tmpFilePosNew" > "$tmpFilePosDiff"

  # neue Positionen finden
  rmFile "$outFilePosOpen"
  for newPos in $(grep ">" $tmpFilePosDiff | awk '{print $2}'); do
     #grep "$newPos" "$inFileNew" >> "$outFilePosOpen"
    newPosStr=`grep "$newPos" "$inFileNew"`
    checkNewOpen $newPosStr
    rVal=$? 
    if [ "$rVal" -eq "0" ]; then
       echo $newPosStr >> "$outFilePosOpen"
    fi
  done

  # geschlossene Positionen finden
  rmFile "$outFilePosClose"
  for oldPos in $(grep "<" $tmpFilePosDiff | awk '{print $2}'); do
    grep "$oldPos" "$inFileOld" >> "$outFilePosClose"
  done

  # geänderte Positionen finden
  rmFile "$outFileChangeTP"
  rmFile "$outFileChangeSL"
  for posID in $(cat $tmpFilePosNew); do
    posNew=`grep "$posID" "$inFileNew"`
    posOld=`grep "$posID" "$inFileOld"`
    if [ $? -eq 0 ]; then
      # Take Profit geändert
      tpNew=`echo "$posNew" | awk -F "," '{print $7}'`
      tpOld=`echo "$posOld" | awk -F "," '{print $7}'`
      if [ "$tpNew" != "$tpOld" ]; then echo "$posNew" > "$outFileChangeTP"; fi

      # Stop Loss geändert
      slNew=`echo "$posNew" | awk -F "," '{print $8}'`
      slOld=`echo "$posOld" | awk -F "," '{print $8}'`
      if [ "$slNew" != "$slOld" ]; then echo "$posNew" > "$outFileChangeSL"; fi
    fi
  done

  # aufräumen
  rmFile "$tmpFilePosNew"
  rmFile "$tmpFilePosOld"
  rmFile "$tmpFilePosDiff"
}


###############################################################################################
# Meldungen generieren

# Position von etoro in Meldung konvetieren
lineToMessage () {
  local msgTyp="$1"
  local pos="$2"
  local index="$3"

  local assetnr=`echo $pos | awk -F "," '{print $5}'`
  local time=`echo $pos | awk -F "," '{print $3}'`
  local time=${time#*\:}
  local open=`echo $pos | awk -F "," '{print $4}'`
  local bsType=`echo $pos | awk -F "," '{print $6}'`
  if [[ $bsType == *"true"* ]]; then bs="long"; else bs="short"; fi
  local tp=`echo $pos | awk -F "," '{print $7}'`
  local cr=`echo $pos | awk -F "," '{print $12}'`
  local sl=`echo $pos | awk -F "," '{print $8}'`
  local levarage=`echo $pos | awk -F "," '{print $16}'`
  local np=`echo $pos | awk -F "," '{print $14}'`
  local np2=${np##*\:}

  # asset nummer in asset name wandeln
  local asset=`grep -m1 "${assetnr##*\:}" "$inFileAsset"`
  if [ "$?" -ne "0" ]; then
    echo "Error Asset not found"
    exit 1
  fi   
  asset=${asset##*,} 

  
  cat >>$outFileMsg"_"$(printf "%03d" $index) << EOF
********************
<b>$msgTyp</b> $bs position
  Time:	${time:1:16}
  Asset:	$asset
  open:	${open##*\:}
  TP:	${tp##*\:}
  CR:   ${cr##*\:}
  SL:	${sl##*\:}
  Levarage:	${levarage##*\:}
  NP:	${np2:0:10}
EOF
}


# Aus Datei mit Positionen Meldungen erstellen
msgFromFile () {
local fName="$1"
local mType="$2"

if [ -f "$fName" ]; then
  # Header erstellen, falls Datei noch nicht da
  if [ ! -f $outFileMsg"_000" ]; then
    datum=`date`
    cat>>$outFileMsg"_000" << EOL
####################
Position changed
  Trader:$trader
  Date:  $datum
####################
EOL
  fi

  local index=`ls "$outFileMsg"* 2>/dev/null | wc -l`
  for pos in $(cat $fName); do
    lineToMessage "$mType" "$pos" "$index"
    ((index++))
  done
fi
}


# sicherstellen, dass Datei leer
rmFile () {
  local fName="$1"
  touch $fName
  rm $fName
}


# Meldungen für Telegram vorbereiten
msgCreate () {

# sicherstellen, dass Datei leer
rmFile $outFileMsg

# neue Positionen versenden
msgFromFile "$outFilePosOpen" "New"

# geschlossene Positionen versenden
msgFromFile "$outFilePosClose" "Closed"

# TP Änderungen
msgFromFile "$outFileChangeTP" "Changed TP"

# SL Änderungen
msgFromFile "$outFileChangeSL" "Changed SL"
}

# Meldung versenden
msgSend () {
  if [ -f $outFileMsg"_000" ]; then
    local msgFiles=$outFileMsg"_*"
    for msg in $msgFiles; do

      if [ "$silentMode" == "false" ]; then
         cat $msg | ./telegram -H -t $tgAPI -c $tgcID -
      else
         cat $msg
      fi

      rmFile $msg
    done
    if [ "$silentMode" == "false" ]; then
      ./telegram -t $tgAPI -c $tgcID "Portfolio:https://www.etoro.com/people/$trader/portfolio"$'\n'"Donate for bot to: paypal.me/ChristianSenning"
    fi
  fi
}

# Sicherstellen, dass nur einmal ausgeführt und nicht ausführen nach einem Fehler
lockFileGen () {

# prüfen, dass nicht bereits ein lockfile existiert
  if [ -f  $outFileLock ]; then
    # bot beenden
    echo "Info: Lockfile exists. Therefore aborted bot"
    exit 1
  fi

  # lockfile erstellen mit der aktuellen Ausführzeit
  date > $outFileLock

}


###############################################################################################
# Hauptprogramm

# ins arbeitsverzeichnis wechseln
cd "$(dirname "$0")"

# Standard Einstellungen
silentMode=false

while [ -n "$1" ]; do # while loop starts
    case "$1" in
    -s) echo "Using silent mode"
        silentMode=true ;; # Silent mode
#    -b) echo "-b option passed" ;; # Message for -b option
#    -c) echo "-c option passed" ;; # Message for -c option
    *) echo "Option $1 not recognized" ;; # In case you typed a different option other than a,b,c
    esac
    shift
done

# Konfiguration laden
source eToroSBot.conf

# Sicherstellen, dass nur einmal ausgeführt und nicht ausführen nach einem Fehler
lockFileGen

# alte Daten sichern
cp "$outFileNew" "$outFileOld"

# Daten von eToro holen
fetchEToroData "$outFileNew"

# Veränderung der Positionen suchen
identDifference 

# Meldungen erstellen
msgCreate 

# send message with telegram
msgSend

# Kopiere alle positionen ins log verzeichnis
cp "$outFileNew" "$logDir/`date "+%g%m%d__%H_%M"`"

# lockfile entfernen
rmFile $outFileLock
