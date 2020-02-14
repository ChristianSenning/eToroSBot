#!/bin/bash

###############################################################################################
# Standard Konfiguration kann mit einer spezfischen Konfiguration geändert werden
getStdConf () {
  # directories
  dataDir="./data"
  tmpDir="./tmp"
  logDir="./log"

  # config files
  inFileCid="cid.txt"
  inFileAsset="asset.txt"
  inFileCookie="cookies.txt"

  # working files
  outFileNew="$dataDir/newPos.csv"
  outFileOld="$dataDir/oldPos.csv"
  outFilePosOpen="$dataDir/openPos.csv"
  outFilePosClose="$dataDir/closePos.csv"
  outFileCTrades="$dataDir/ctrades.csv"
  outFileChangeTP="$dataDir/changedTP.csv"
  outFileChangeSL="$dataDir/changedSL.csv"
  outFileMsg="$dataDir/msgFile.txt"
  outFileLock="$tmpDir/lock.tmp"

  # parameters
  maxHOpen=1
  nrNotFoundClosedPos=0
  verbosityLevel=0
}


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
    local rNumber=`cat /proc/sys/kernel/random/uuid`
 
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
    cp "$outFileOld" "$outFileNew"
    exit 1
  fi 

  # Check on error message of eToro
  if [[ "$retValCurlCrawl" == *"<title>50"* ]]; then
      echo $retValCurlCrawl
      echo "##########################"
      echo $urlTot
      echo "Error: eToro seems not available"
      
    ## clean up for the next start (copy the old output back)
    revertAndTerminate
  fi 
}


###############################################################################################
# Kontrolliert bot beenden
revertAndTerminate() {
   if [ "$silentMode" == "false" ]; then
     ./telegram -t $tgAPI -c $tgcID "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
  else
     echo "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
  fi
  cp "$outFileOld" "$outFileNew"
  rmFile $outFileLock
  exit 1
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

  # Daten prüfen
  if [[ "$retValCurlCrawl" != *"CreditByRealizedEquity"* ]]; then
     echo "Fetch of portfolio did not work. Pausing bot"
     revertAndTerminate
  fi

  # Leerer File sicherstellen
  rmFile "$outFile"

  # sicherstellen, dass positionen vorhanden sind
  if [[ "$retValCurlCrawl" == *"\"AggregatedPositions\":[]"* ]]; then
    echo "Empty portfolio"
    # lockfile entfernen
    rmFile $outFileLock
    exit 0
  fi

  # sicherstellen, dass kein Fehler vorhanden ist
  if [[ "$retValCurlCrawl" == *"ErrorCode"* ]]; then
    echo "Empty portfolio with error code"
    # lockfile entfernen
    rmFile $outFileLock
    exit 0
  fi

  # ausschliesslich die AggregatedPositions herausfiltern
  fContent=$retValCurlCrawl
  fContent=${fContent%%\}],\"AggregatedMirrors*}
  fContent=${fContent##*AggregatedPositions\":[{}

  # jede Asset Klasse durchgehen und alle entsprechenden Trades holen
  for assetClass in $(echo $fContent | sed 's/},{/\n/g'); do
    # Asset Nummer extrahieren
    assetClass=${assetClass%%,\"Direction*}
    assetClass=${assetClass##\"InstrumentID\":}
  
    # URL zusammensetzen
    url=$baseAUrl$assetClass"&cid="$cid

    # Daten abgreifen
    curlCrawl "$url"

    # Daten prüfen
    if [[ "$retValCurlCrawl" != *"PublicPositions"* ]]; then
       echo $retValCurlCrawl
       echo "Fetch of position did not work. Pausing bot"
       revertAndTerminate
    fi

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
  tmpFilePosNew="$tmpDir/newPos.tmp"
  tmpFilePosOld="$tmpDir/oldPos.tmp"
  tmpFilePosDiff="$tmpDir/diffPos.tmp"

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
# Holt sich die geschlossenen Trades der letzten 2 bis 3 Tage 

getCTrades() {
  # get the date of today and yesterday
  dDBYesterday=`date -d "2 day ago" '+%Y-%m-%d'`

  # get uuid for the request
  rNumber=`cat /proc/sys/kernel/random/uuid`

  # get json with the number of closed trades
  urlTot="https://www.etoro.com/sapi/trade-data-real/history/public/credit/flat/aggregated?CID=$cid&StartTime="$dDBYesterday"T00:00:00.000Z&format=json&client_request_id="$rNumber
  retValCurl=`curl -b $inFileCookie -s "$urlTot"`

  # check output
  if [[ "$retValCurl" != *"TotalClosedTrades"* ]]; then
   revertAndTerminate
  fi

  # filter out the number of closed trade
  nrCTrades=${retValCurl%%\,\"TotalClosedManualPositions\"*}
  nrCTrades=${nrCTrades##\{\"TotalClosedTrades\":}

  # reset closed trades file
  rmFile $outFileCTrades
  touch $outFileCTrades

  # get the closed trades
  pageNr=1
  nrCTradesLeft=$nrCTrades
  while [ $nrCTradesLeft -ge 0 ]; do
    # get uuid for the request
    rNumber=`cat /proc/sys/kernel/random/uuid`
    urlTot="https://www.etoro.com/sapi/trade-data-real/history/public/credit/flat?CID="$cid"&ItemsPerPage=30&PageNumber="$pageNr"&StartTime="$dDBYesterday"T00:00:00.000Z&format=json&client_request_id="$rNumber
    retValCurl=`curl -b $inFileCookie -s "$urlTot"`
  
    # update counters
    nrCTradesLeft=$((nrCTradesLeft-30))
    pageNr=$(($pageNr+1))

    # Daten prüfen
    if [[ "$retValCurl" != *"PublicHistoryPositions"* ]]; then
      revertAndTerminate
    fi

    # Daten extrahieren  
    fContent=$retValCurl
    fContent=${fContent%%\}]\}}
    fContent=${fContent##*PublicHistoryPositions\":[{}

    for asset in $(echo $fContent | sed 's/},{/\n/g'); do
      echo $asset >> $outFileCTrades
    done
  done
}

###############################################################################################
# Prüft, ob trades wirklich geschlossen sind

checkPCloseTrades() {
  if [ -f "$outFilePosClose" ]; then

    # get the real closed positions
    getCTrades

    # möglicherweise geschlossene trades in temp file überführen
    mv $outFilePosClose $outFilePosClose"_tmp"

    # check each possibly closed position
    while read line; do
       # get the Position number
       posNr=${line##\"PositionID\":}
       posNr=${posNr%%,\"CID*}

       # search position in the real closed trades
       posClosed=`grep "$posNr" "$outFileCTrades"`
       if [ "$?" -eq "0" ]; then
          # position gefunden daher wirklich beendeter trade
          echo $line >> $outFilePosClose
       else
          # position nicht gefunde, daher weiterhin offener trade
          echo "Position not closed..."
          echo $line >> $outFileNew
          nrNotFoundClosedPos=$((nrNotFoundClosedPos+1))
       fi   
    done <$outFilePosClose"_tmp"

    # clean up
    rmFile $outFilePosClose"_tmp"
  fi
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
  if [[ $bsType == *"true"* ]]; then 
     bs="long"; 
     bsp=1; 
  else 
     bs="short"; 
     bsp=-1; 
  fi
  local tp=`echo $pos | awk -F "," '{print $7}'`
  local cr=`echo $pos | awk -F "," '{print $12}'`
  local sl=`echo $pos | awk -F "," '{print $8}'`
  local levarage=`echo $pos | awk -F "," '{print $16}'`
  local np=`echo $pos | awk -F "," '{print $14}'`
  local np2=${np##*\:}
  local amount=`echo $pos | awk -F "," '{print $11}'`
  amount=${amount##*\:}

  # asset nummer in asset name wandeln
  local asset=`grep -m1 "${assetnr##*\:}" "$inFileAsset"`
  if [ "$?" -ne "0" ]; then
    echo "Error Asset not found"
    exit 1
  fi   
  asset=${asset##*,} 

  open=${open##*\:}
  tp=${tp##*\:}
  cr=${cr##*\:}
  sl=${sl##*\:}
  levarage=${levarage##*\:}

  local tpp=`echo "scale=10;$bsp*100*($tp-$open)/$open*$levarage" | bc`
  local slp=`echo "scale=10;$bsp*100*($sl-$open)/$open*$levarage" | bc`

  cat >>$outFileMsg"_"$(printf "%03d" $index) << EOF
********************
<b>$msgTyp</b> $bs position
  Time:	${time:1:16}
  Asset:	$asset
  open:	$open
  TP: 	$tp   (${tpp:0:7} %)
  CR:   $cr   (${np2:0:7} %)
  SL: 	$sl   (${slp:0:7} %)
  Levarage:	${levarage##*\:}
  Amount:   ${amount:0:4} %
EOF
#  NP:	${np2:0:10}

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
  Trader: $trader
  Date:   $datum
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
      if [ "$nrNotFoundClosedPos" -ne "0" ]; then
        ./telegram -t $tgAPI -c $tgcID "Maintenance message: Possibly closed position found."
      fi
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
# Sicherstellen, dass alle benötigten Dateien vorhanden sind
initFiles () {
  touch $outFileNew
  touch $outFileOld
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

# standard Konfiguration laden
getStdConf

# spezifische Konfiguration laden
source eToroSBot.conf

# Initialisiere die Dateien
initFiles


# Sicherstellen, dass nur einmal ausgeführt und nicht ausführen nach einem Fehler
lockFileGen

# alte Daten sichern
cp "$outFileNew" "$outFileOld"

# Daten von eToro holen
fetchEToroData "$outFileNew"

# Veränderung der Positionen suchen
identDifference 

# geschlossene Trades prüfen
checkPCloseTrades

# Meldungen erstellen
msgCreate 

# send message with telegram
msgSend

# Kopiere alle positionen ins log verzeichnis
if [ "$verbosityLevel" -gt "0" ]; then
  cp "$outFileNew" "$logDir/`date "+%g%m%d__%H_%M"`"
fi

# lockfile entfernen
rmFile $outFileLock
